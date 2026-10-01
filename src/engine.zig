//! overlay: the overlay engine (issues #36, #50, #57). Called (#40), it is the
//! overlay's front-door route handlers (routes.zig: submit, lookup, the
//! listings and documentation); stepped, a handler program for the plain
//! entries admitted into it (sender-less subscriptions) and a status
//! provider's messages (#65):
//!
//!   box `submit`  {kind: "submit", txid, txs, nodes, proofs, topics, offChainValues?}   what POST /submit admits (submit.zig)
//!   box `chain`   {kind: "header" | "proof", …}                                         the chain feed (docs/WALLET.md),
//!                                                                                       for an instance without a wallet program
//!   box `status`  {kind: "status", txid, txStatus, …}                                   a status provider's message (subscribed
//!                                                                                       to its key), the same
//!
//! The state is the instance's chain+settlement core: the record the head
//! `wallet` names (the SDK's wallet library: headers, transactions, proofs, settlement, and
//! the overlay's maps, overlay.zig), shared with a wallet in the same
//! instance. Each lookup service keeps its own state under its own head
//! (`ls:<service>`, lookup.zig). The topics and lookup services are the
//! app's (#72, config.zig): `config.overlay` of the app record the engine
//! was installed as, read at every step and call — {topics: {"tm_x":
//! "<role>"}, lookups: {"ls_x": {"program": "<role>", "topics": ["tm_x",
//! …]}} (or "ls_x": "<role>": every served topic), gossip?} — the roles its
//! `programs`. A genesis-wired engine (no app record) reads the genesis
//! config instead: defaults.overlayTopics, defaults.overlayLookups,
//! defaults.overlayGossip (JSON in a string, the same shapes; program names
//! the genesis's).
//!
//! A submit step, after the route decoded and judged it in its call
//! (submit.zig): hold the records the entry carries; unless the entry proves
//! the transaction mined, broadcast it (#65: an event, the host's wiring
//! carries it) and leave it pending. There is no setting (#73): admission is
//! the first of a status provider's word that the network has it, or its
//! proof — either records each topic's judgement (overlay.apply) and calls
//! the listening lookup services' hooks (`admitted`, `spent`); save. Until
//! then the thread awaits the transaction's CID, with a deadline at its abandonment
//! (defaults.walletAbandonMs): its proof, a status provider's message, or
//! the deadline steps the same thread — admitting it, or rejecting it. Once
//! admitted or rejected the thread finishes (#66): the request that launched
//! it (POST /submit), and any resubmission awaiting it, answer from the state
//! — the STEAK from the `applied` records, or the rejection. A later status
//! or proof (mined, a double spend) settles it through the chain feed or the
//! status subscription (below): a rejection unwinds the admittances through
//! `admits` (#37) and calls `rejected` for each judgement it removed.
//! Gossip (#74, gossip.zig): an admission publishes the raw submission on
//! `<topic>` (unless it arrived by gossip there) and the verdict on
//! `<topic>-admit`; a proof recorded for an admitted transaction (not one
//! from `-proof`) publishes `<topic>-proof` — messages to the libp2p
//! provider, per topic with `defaults.overlayGossip` on. A `peer-admit`
//! event (box `submit`, from the `-admit` route) is recorded under the head
//! `overlay:gossip`.
//!
//! Every step keeps its result record and prints its CID:
//!
//!   {kind: "overlay-result", op: "submit" | "callback", txid, gate, outcome, txStatus?, steak?, awaiting?, event? | woke?, published?, refs, state}
//!   {kind: "overlay-result", op: "event", event, …, published?, state}      the chain feed
//!   {kind: "overlay-result", op: "peer-admit", topic, txid, record, state}  a peer's admit (the gossip state)
//!   {kind: "overlay-result", op, error}                         refused
const std = @import("std");
const w = @import("wallet");
const vm = @import("vm.zig");
const routes = @import("routes.zig");
const submit = @import("submit.zig");
const gossip = @import("gossip.zig");

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

/// A peer's `<topic>-admit` verdict (#74), admitted by the route (routes.zig `peerAdmit`) as a
/// `peer-admit` event: recorded under the head `overlay:gossip` (key topic ‖ txid ‖ from). Nothing is
/// admitted from it: a read for a lookup or a UI (who else admitted this transaction).
fn peerAdmitted(a: std.mem.Allocator, ev: Value) !void {
    const s = vm.store();
    var st = try gossip.State.load(a, s, try vm.head(a, gossip.state_head));
    const rec = try st.record(ev);
    try vm.keep(rec);
    const new_state = try st.save();
    try vm.advance(gossip.state_head, new_state);
    _ = try vm.finish(a, s, try resultRecord(a, "peer-admit", &.{
        .{ .key = "topic", .value = .{ .text = ev.getText("topic") orelse "" } },
        .{ .key = "txid", .value = .{ .text = ev.getText("txid") orelse "" } },
        .{ .key = "record", .value = .{ .cid = rec } },
        .{ .key = "state", .value = .{ .cid = new_state } },
    }));
}

fn run(a: std.mem.Allocator) anyerror!void {
    const s = vm.store();
    const in = try vm.input(a);
    if (std.mem.eql(u8, in.getText("kind") orelse "", "call")) return routes.call(a, in);
    // The topics, lookup services and programs: the app record's (#72, config.zig), else the genesis's.
    const step = try vm.configured(a, in, null);
    const args = step.get("args") orelse return error.BadInput;
    // A plain entry (args.event), or a status provider's message by subscription (#65: args.body in box `status`).
    const ev_cid = args.getCid("event") orelse if (std.mem.eql(u8, args.getText("box") orelse "", "status")) args.getCid("body") orelse return error.BadInput else return error.BadInput;
    const ev = try s.getValue(a, ev_cid);
    const kind = ev.getText("kind") orelse return error.BadEvent;
    // A peer's verdict from `<topic>-admit` (#74): recorded under the head `overlay:gossip`, nothing admitted.
    if (std.mem.eql(u8, kind, "peer-admit")) return peerAdmitted(a, ev);
    const state = try vm.head(a, vm.state_head);
    var wal = try Wallet.load(a, s, state, try vm.network(step));
    wal.now = @intCast(step.getUint("at") orelse return error.BadInput);
    var fields: std.ArrayList(cbor.Entry) = .empty;
    // A submission's awaiting thread (#57, #65) steps again on an event about its transaction (its
    // proof), a status provider's message about it (routed by its subject), or at its deadline.
    const wake: ?submit.Wake = if (step.get("event")) |e|
        .{ .event = try s.getValue(a, e.getCid("event") orelse return error.BadInput) }
    else if (step.get("message")) |m|
        .{ .status = try s.getValue(a, m.getCid("body") orelse return error.BadInput) }
    else if (step.getBool("woke") orelse false) .deadline else null;
    var op: []const u8 = "event";
    // The gossip out (#74): the libp2p provider, if the address book has one.
    const out = try vm.gossipOut(a);
    var published: usize = 0;

    if (std.mem.eql(u8, kind, "submit")) {
        // Hold the records; broadcast unless mined; admit on the first of a status or the proof (submit.zig).
        op = if (wake == null) "submit" else "callback";
        const proof_before = try wal.proofBlock(try w.header.fromHex(ev.getText("txid") orelse return error.BadEvent));
        const done = (if (wake) |wk|
            submit.awaited(a, vm.caller(), &wal, step, ev, wk)
        else
            submit.step(a, vm.caller(), vm.wire(), &wal, step, ev)) catch |e| return refused(a, op, e);
        for (done.records) |c| try vm.keep(c);
        try fields.appendSlice(a, &.{
            .{ .key = "txid", .value = .{ .text = try a.dupe(u8, &w.header.toHex(done.subject.txid)) } },
            .{ .key = "gate", .value = .{ .text = @tagName(done.gate) } },
            .{ .key = "outcome", .value = .{ .text = @tagName(done.outcome) } },
            .{ .key = "refs", .value = .{ .array = try a.dupe(Value, &.{.{ .map = try a.dupe(cbor.Entry, &.{
                .{ .key = "to", .value = .{ .cid = done.subject.cid } },
                .{ .key = "rel", .value = .{ .text = "mentions" } },
            }) }}) } },
        });
        if (wake) |wk| switch (wk) {
            .event => |e| try fields.append(a, .{ .key = "event", .value = .{ .text = e.getText("kind") orelse "" } }),
            .status => try fields.append(a, .{ .key = "event", .value = .{ .text = "status" } }),
            .deadline => try fields.append(a, .{ .key = "woke", .value = .{ .boolean = true } }),
        };
        if (done.tx_status.len > 0) try fields.append(a, .{ .key = "txStatus", .value = .{ .text = done.tx_status } });
        if (done.admitted) {
            var steak: std.ArrayList(cbor.Entry) = .empty;
            for (done.topics, done.applied) |t, ap| try steak.append(a, .{ .key = t, .value = .{ .map = try a.dupe(cbor.Entry, &.{
                .{ .key = "outputsToAdmit", .value = .{ .array = try uints(a, ap.outputs_to_admit) } },
                .{ .key = "coinsToRetain", .value = .{ .array = try uints(a, ap.coins_to_retain) } },
                .{ .key = "coinsRemoved", .value = .{ .array = try uints(a, ap.coins_removed) } },
            }) } });
            try fields.append(a, .{ .key = "steak", .value = .{ .map = steak.items } });
        }
        if (out) |o| {
            // Admitted: the raw submission on `<topic>` (unless it came by gossip there) and the verdict on
            // `<topic>-admit`; a proof recorded in this step (not one from `-proof`): `<topic>-proof` (gossip.zig).
            if (done.admitted) published += try gossip.admitted(a, o, s, &wal, step, ev, done.subject.txid, done.topics, done.applied);
            const via_gossip = if (wake) |wk| switch (wk) {
                .event => |e| e.get("via") != null,
                else => false,
            } else false;
            published += try gossip.proven(a, o, &wal, step, done.subject.txid, proof_before, via_gossip);
        }
        if (done.gate == .pending) {
            // Not admitted yet: rest until its proof or a status provider's message (the
            // transaction's CID is its txid), or its abandonment. Once the gate is decided — admitted
            // or rejected — the submission's thread finishes (#66: a client waiting on it is
            // answered); a later status or proof settles it through the chain feed or the status
            // subscription, nobody waiting.
            try vm.awaitRecord(done.subject.cid);
            if (try (try submit.Gate.of(step)).deadline(&wal, done.subject.txid)) |until| try vm.deadline(until);
            try fields.append(a, .{ .key = "awaiting", .value = .{ .boolean = true } });
        }
    } else if (wake != null) {
        return error.BadInput; // only a submission's thread awaits
    } else if (std.mem.eql(u8, kind, "header") or std.mem.eql(u8, kind, "proof") or std.mem.eql(u8, kind, "status")) {
        // The chain feed and the status provider's messages, as the wallet takes them (an instance
        // with a wallet routes `chain` and `status` to the wallet instead).
        try fields.append(a, .{ .key = "event", .value = .{ .text = kind } });
        if (std.mem.eql(u8, kind, "header")) {
            // One header (`raw`), or a run of them, parents first (`raws`): a reorg's heavier branch
            // arrives as one run, since its first header alone is no heavier than ours.
            var raws: std.ArrayList([]const u8) = .empty;
            if (ev.getArray("raws")) |rs| {
                for (rs) |r| try raws.append(a, if (r == .bytes) r.bytes else return error.BadEvent);
            } else try raws.append(a, ev.getBytes("raw") orelse return error.BadEvent);
            const res = try wal.addHeaders(raws.items);
            try fields.appendSlice(a, &.{
                .{ .key = "added", .value = .{ .uint = res.added } },
                .{ .key = "tip", .value = .{ .uint = res.tip } },
            });
        } else {
            const txid = if (ev.getCid("subject")) |c| w.store.bitcoinHash(c) orelse return error.BadEvent else try w.header.fromHex(ev.getText("txid") orelse return error.BadEvent);
            const proof_before = try wal.proofBlock(txid);
            const outcome = if (std.mem.eql(u8, kind, "proof"))
                try wal.applyStatus(txid, "MINED", ev.getBytes("path") orelse return error.BadEvent)
            else
                try wal.applyStatus(txid, ev.getText("txStatus") orelse "", ev.getBytes("merklePath"));
            try fields.appendSlice(a, &.{
                .{ .key = "txid", .value = .{ .text = try a.dupe(u8, &w.header.toHex(txid)) } },
                .{ .key = "outcome", .value = .{ .text = @tagName(outcome) } },
            });
            // A proof (the first, or a reorg's re-proof in another block) of a transaction a topic admitted:
            // `<topic>-proof`, unless it came by gossip on `-proof` (#74). Statuses never propagate.
            if (out) |o| if (std.mem.eql(u8, kind, "proof")) {
                published += try gossip.proven(a, o, &wal, step, txid, proof_before, ev.get("via") != null);
            };
        }
    } else return error.BadEvent;
    if (published > 0) try fields.append(a, .{ .key = "published", .value = .{ .uint = published } });
    // The judgements a rejection removed (a status, a competing proof, abandonment): each topic's lookup services are told (#50).
    try w.overlay.hookRejected(a, vm.caller(), step, wal.unapplied.items);

    const new_state = try wal.save();
    try vm.advance(vm.state_head, new_state);
    try fields.append(a, .{ .key = "state", .value = .{ .cid = new_state } });
    _ = try vm.finish(a, s, try resultRecord(a, op, fields.items));
}
