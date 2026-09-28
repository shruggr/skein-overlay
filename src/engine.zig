//! overlay: the overlay engine (issue #36). Called (#40), it is the
//! overlay's front-door route handlers (routes.zig: submit, lookup, the
//! listings and documentation); stepped, a handler program for the plain
//! entries admitted into it (sender-less subscriptions):
//!
//!   box `submit`  {kind: "submit", beef, topics: [text], offChainValues?}   what POST /submit admits
//!   box `chain`   {kind: "header" | "proof" | "status", …}                  the chain feed (docs/WALLET.md),
//!                                                                          for an instance without a wallet program
//!
//! The state is the instance's chain+settlement core: the record the head
//! `wallet` names (wallet-zig: headers, transactions, proofs, settlement, and
//! the overlay's maps, overlay.zig), shared with a wallet in the same
//! instance. The topics and lookup services it serves are genesis config:
//! defaults.overlayTopics = JSON {"tm_x": "<bin/ program name>", …},
//! defaults.overlayLookups = JSON {"ls_x": "<bin/ program name>", …}.
//!
//! A submit is two steps. First: verify the BEEF against the held headers
//! (SPV), and for each requested topic this instance serves and has not
//! judged the transaction for, launch the topic's program (topic.zig's
//! contract) with the transaction and its previous coins; the thread waits
//! on them. Then, with their admittance records (`resolved`): record each
//! topic's judgement (overlay.apply: held transactions, admitted outputs,
//! consumed coins, rel `admits`), save. The route's `then` call reads the
//! STEAK back from the `applied` records. Every step keeps its result record
//! and prints its CID:
//!
//!   {kind: "overlay-result", op: "submit", txid, steak: {topic: {outputsToAdmit, coinsToRetain, coinsRemoved}}, refs}
//!   {kind: "overlay-result", op, error}                   refused (bad BEEF, SPV …)
const std = @import("std");
const w = @import("wallet");
const vm = @import("vm.zig");
const topic = @import("topic.zig");
const routes = @import("routes.zig");

const cbor = w.cbor;
const Value = cbor.Value;
const Wallet = w.wallet.Wallet;

pub fn main() u8 {
    return vm.main("overlay", run);
}

const configMap = routes.configMap;
const programFor = routes.programFor;

fn txCid(txid: [32]u8) [37]u8 {
    return .{ 0x01, 0xb1, 0x01, 0x56, 0x20 } ++ txid;
}

fn uints(a: std.mem.Allocator, xs: []const u32) ![]Value {
    const out = try a.alloc(Value, xs.len);
    for (xs, out) |x, *o| o.* = .{ .uint = x };
    return out;
}

fn resultRecord(a: std.mem.Allocator, op: []const u8, fields: []const cbor.Entry) !Value {
    var es: std.ArrayList(cbor.Entry) = .empty;
    try es.appendSlice(a, &.{
        .{ .key = "kind", .value = .{ .text = "overlay-result" } },
        .{ .key = "op", .value = .{ .text = op } },
    });
    try es.appendSlice(a, fields);
    return .{ .map = es.items };
}

fn refused(a: std.mem.Allocator, op: []const u8, e: anyerror) !void {
    _ = try vm.finish(a, vm.store(), try resultRecord(a, op, &.{.{ .key = "error", .value = .{ .text = @errorName(e) } }}));
}

/// The requested topics this instance serves, in request order, once each.
fn servedTopics(a: std.mem.Allocator, ev: Value, served: std.json.ObjectMap) ![]const []const u8 {
    const req = ev.getArray("topics") orelse return error.BadEvent;
    var out: std.ArrayList([]const u8) = .empty;
    outer: for (req) |t| {
        if (t != .text) return error.BadEvent;
        if (!served.contains(t.text)) continue;
        for (out.items) |x| if (std.mem.eql(u8, x, t.text)) continue :outer;
        try out.append(a, t.text);
    }
    return out.items;
}

fn run(a: std.mem.Allocator) anyerror!void {
    const s = vm.store();
    const step = try vm.input(a);
    if (std.mem.eql(u8, step.getText("kind") orelse "", "call")) return routes.call(a, step);
    const args = step.get("args") orelse return error.BadInput;
    const ev_cid = args.getCid("event") orelse return error.BadInput;
    const ev = try s.getValue(a, ev_cid);
    const kind = ev.getText("kind") orelse return error.BadEvent;
    const state = try vm.head(a, vm.state_head);
    var wal = try Wallet.load(a, s, state, try vm.network(step));
    wal.now = @intCast(step.getUint("at") orelse return error.BadInput);
    const resolved = step.getArray("resolved");

    if (std.mem.eql(u8, kind, "submit")) {
        const served = try configMap(a, step, "overlayTopics");
        const topics = try servedTopics(a, ev, served);
        const sub = w.overlay.verify(&wal, ev.getBytes("beef") orelse return error.BadEvent) catch |e| return refused(a, "submit", e);
        // Previous coins per topic, from the state as it stands before any judgement.
        const previous = try a.alloc([]const u32, topics.len);
        for (topics, previous) |t, *p| p.* = try w.overlay.previousCoins(&wal, t, sub.tx);

        if (resolved == null) {
            // Step one: launch each topic that has not judged this transaction.
            var launched: usize = 0;
            for (topics, previous) |t, p| {
                if (try w.overlay.isApplied(&wal, t, sub.txid)) continue;
                const prog = (try programFor(step, served, t)).?;
                var es: std.ArrayList(cbor.Entry) = .empty;
                try es.appendSlice(a, &.{
                    .{ .key = "kind", .value = .{ .text = "topic-call" } },
                    .{ .key = "topic", .value = .{ .text = t } },
                    .{ .key = "beef", .value = .{ .bytes = ev.getBytes("beef").? } },
                    .{ .key = "txid", .value = .{ .text = try a.dupe(u8, &w.header.toHex(sub.txid)) } },
                    .{ .key = "previousCoins", .value = .{ .array = try uints(a, p) } },
                });
                if (ev.getBytes("offChainValues")) |o| try es.append(a, .{ .key = "offChainValues", .value = .{ .bytes = o } });
                _ = try vm.launch(a, prog, try s.putValue(a, .{ .map = es.items }));
                launched += 1;
            }
            if (launched > 0) return; // waiting on the topics
        }

        // Step two (or nothing to launch): each topic's admittance, recorded.
        var steak: std.ArrayList(cbor.Entry) = .empty;
        var mutated = false;
        for (topics, previous) |t, p| {
            var ins: ?w.overlay.Instructions = null;
            if (resolved) |rs| for (rs) |r| {
                const res = r.get("result") orelse continue;
                if (!std.mem.eql(u8, r.getText("state") orelse "", "finished")) continue;
                const out = std.mem.trim(u8, res.getBytes("stdout") orelse continue, " \n");
                const cid = try a.alloc(u8, out.len / 2);
                _ = std.fmt.hexToBytes(cid, out) catch continue;
                const rec = s.getValue(a, cid) catch continue;
                if (!std.mem.eql(u8, rec.getText("topic") orelse "", t)) continue;
                ins = topic.instructionsOf(a, rec) catch null;
            };
            // A topic that failed, or whose instructions do not fit the transaction, admits nothing.
            const applied: w.overlay.Applied = if (ins) |i| w.overlay.apply(&wal, sub, t, p, i) catch |e| switch (e) {
                error.BadInstructions => .{},
                else => return e,
            } else .{};
            for (applied.records) |c| try vm.keep(c);
            mutated = mutated or applied.records.len > 0;
            try steak.append(a, .{ .key = t, .value = .{ .map = try a.dupe(cbor.Entry, &.{
                .{ .key = "outputsToAdmit", .value = .{ .array = try uints(a, applied.outputs_to_admit) } },
                .{ .key = "coinsToRetain", .value = .{ .array = try uints(a, applied.coins_to_retain) } },
                .{ .key = "coinsRemoved", .value = .{ .array = try uints(a, applied.coins_removed) } },
            }) } });
        }
        var fields: std.ArrayList(cbor.Entry) = .empty;
        try fields.appendSlice(a, &.{
            .{ .key = "txid", .value = .{ .text = try a.dupe(u8, &w.header.toHex(sub.txid)) } },
            .{ .key = "steak", .value = .{ .map = steak.items } },
            .{ .key = "refs", .value = .{ .array = try a.dupe(Value, &.{.{ .map = try a.dupe(cbor.Entry, &.{
                .{ .key = "to", .value = .{ .cid = try a.dupe(u8, &txCid(sub.txid)) } },
                .{ .key = "rel", .value = .{ .text = "mentions" } },
            }) }}) } },
        });
        if (mutated) {
            const new_state = try wal.save();
            try vm.advance(vm.state_head, new_state);
            try fields.append(a, .{ .key = "state", .value = .{ .cid = new_state } });
        }
        _ = try vm.finish(a, s, try resultRecord(a, "submit", fields.items));
    } else if (std.mem.eql(u8, kind, "header") or std.mem.eql(u8, kind, "proof") or std.mem.eql(u8, kind, "status")) {
        // The chain feed, as the wallet takes it (an instance with a wallet routes `chain` to the wallet instead).
        var fields: std.ArrayList(cbor.Entry) = .empty;
        try fields.append(a, .{ .key = "event", .value = .{ .text = kind } });
        if (std.mem.eql(u8, kind, "header")) {
            const res = try wal.addHeaders(&.{ev.getBytes("raw") orelse return error.BadEvent});
            try fields.appendSlice(a, &.{
                .{ .key = "added", .value = .{ .uint = res.added } },
                .{ .key = "tip", .value = .{ .uint = res.tip } },
            });
        } else {
            const txid = if (ev.getCid("subject")) |c| w.store.bitcoinHash(c) orelse return error.BadEvent else try w.header.fromHex(ev.getText("txid") orelse return error.BadEvent);
            const outcome = if (std.mem.eql(u8, kind, "proof"))
                try wal.applyStatus(txid, "MINED", ev.getBytes("path") orelse return error.BadEvent)
            else
                try wal.applyStatus(txid, ev.getText("txStatus") orelse "", ev.getBytes("merklePath"));
            try fields.appendSlice(a, &.{
                .{ .key = "txid", .value = .{ .text = try a.dupe(u8, &w.header.toHex(txid)) } },
                .{ .key = "outcome", .value = .{ .text = @tagName(outcome) } },
            });
        }
        const new_state = try wal.save();
        try vm.advance(vm.state_head, new_state);
        try fields.append(a, .{ .key = "state", .value = .{ .cid = new_state } });
        _ = try vm.finish(a, s, try resultRecord(a, "event", fields.items));
    } else return error.BadEvent;
}
