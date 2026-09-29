//! overlay: the overlay engine (issues #36, #50). Called (#40), it is the
//! overlay's front-door route handlers (routes.zig: submit, lookup, the
//! listings and documentation); stepped, a handler program for the plain
//! entries admitted into it (sender-less subscriptions):
//!
//!   box `submit`  {kind: "submit", txid, txs, nodes, proofs, topics, offChainValues?}   what POST /submit admits (submit.zig)
//!   box `chain`   {kind: "header" | "proof" | "status", …}                               the chain feed (docs/WALLET.md),
//!                                                                                       for an instance without a wallet program
//!
//! The state is the instance's chain+settlement core: the record the head
//! `wallet` names (wallet-zig: headers, transactions, proofs, settlement, and
//! the overlay's maps, overlay.zig), shared with a wallet in the same
//! instance. Each lookup service keeps its own state under its own head
//! (`ls:<service>`, lookup.zig). The topics and lookup services are genesis
//! config: defaults.overlayTopics = JSON {"tm_x": "<bin/ program name>", …},
//! defaults.overlayLookups = JSON {"ls_x": {"program": "<bin/ program name>",
//! "topics": ["tm_x", …]}, …} (or "ls_x": "<name>": every served topic).
//!
//! A submit is one step, after the route decoded and judged it in its call
//! (submit.zig): hold the records the entry carries, record each topic's
//! judgement (overlay.apply), call the listening lookup services' hooks
//! (`admitted`, `spent`), save. A rejection (a `status` entry, a competing
//! proof) calls `rejected` for each judgement it removed. The route's `then`
//! call reads the STEAK back from the `applied` records. Every step keeps
//! its result record and prints its CID:
//!
//!   {kind: "overlay-result", op: "submit", txid, steak: {topic: {outputsToAdmit, coinsToRetain, coinsRemoved}}, refs, state}
//!   {kind: "overlay-result", op, error}                   refused
const std = @import("std");
const w = @import("wallet");
const vm = @import("vm.zig");
const routes = @import("routes.zig");
const submit = @import("submit.zig");

const cbor = w.cbor;
const Value = cbor.Value;
const Wallet = w.wallet.Wallet;

pub fn main() u8 {
    return vm.main("overlay", run);
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
    var fields: std.ArrayList(cbor.Entry) = .empty;

    if (std.mem.eql(u8, kind, "submit")) {
        // The records the route decoded, held; each judgement recorded; the lookup services' hooks (#50).
        const done = submit.step(a, vm.caller(), &wal, step, ev) catch |e| return refused(a, "submit", e);
        for (done.records) |c| try vm.keep(c);
        var steak: std.ArrayList(cbor.Entry) = .empty;
        for (done.topics, done.applied) |t, ap| try steak.append(a, .{ .key = t, .value = .{ .map = try a.dupe(cbor.Entry, &.{
            .{ .key = "outputsToAdmit", .value = .{ .array = try uints(a, ap.outputs_to_admit) } },
            .{ .key = "coinsToRetain", .value = .{ .array = try uints(a, ap.coins_to_retain) } },
            .{ .key = "coinsRemoved", .value = .{ .array = try uints(a, ap.coins_removed) } },
        }) } });
        try fields.appendSlice(a, &.{
            .{ .key = "txid", .value = .{ .text = try a.dupe(u8, &w.header.toHex(done.subject.txid)) } },
            .{ .key = "steak", .value = .{ .map = steak.items } },
            .{ .key = "refs", .value = .{ .array = try a.dupe(Value, &.{.{ .map = try a.dupe(cbor.Entry, &.{
                .{ .key = "to", .value = .{ .cid = done.subject.cid } },
                .{ .key = "rel", .value = .{ .text = "mentions" } },
            }) }}) } },
        });
    } else if (std.mem.eql(u8, kind, "header") or std.mem.eql(u8, kind, "proof") or std.mem.eql(u8, kind, "status")) {
        // The chain feed, as the wallet takes it (an instance with a wallet routes `chain` to the wallet instead).
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
    } else return error.BadEvent;

    const new_state = try wal.save();
    try vm.advance(vm.state_head, new_state);
    try fields.append(a, .{ .key = "state", .value = .{ .cid = new_state } });
    _ = try vm.finish(a, s, try resultRecord(a, if (std.mem.eql(u8, kind, "submit")) "submit" else "event", fields.items));
}
