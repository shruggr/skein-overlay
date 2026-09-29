//! A submission, from the wire to the state (#50). Two halves:
//!
//! - **The route** (`route`, the front door's `/submit` handler: an in-VM
//!   call, writing nothing). The BEEF is decoded once, into records
//!   (wallet-zig overlay.decode: `bitcoin-tx` blocks and merkle nodes, put
//!   into the call's in-memory overlay), checked over them
//!   (overlay.verifyDecoded: SPV read through `get`), and judged: each
//!   requested topic this instance serves and has not judged it before is
//!   called (`identify`, topic.zig) on the transaction's CID with its
//!   previous coins, reading the records through the same overlay. If no
//!   topic takes anything, the call refuses and the overlay is dropped:
//!   nothing persists. Otherwise it returns the entry for the host to admit.
//! - **The step** (`step`, the engine stepped on that entry). It holds the
//!   decoded records the entry carries (overlay.holdDecoded: kept, so #42's
//!   edges appear), records each topic's judgement (`applied`, the
//!   admittances), and calls each listening lookup service's hooks
//!   (`admitted`, then `spent` for each previous coin consumed) — all in the
//!   one step. A judgement is taken again, in the step, only if the topic's
//!   previous coins moved between the call and the step.
//!
//! The entry (box `submit`) carries records, not a BEEF:
//!
//!   {kind: "submit", txid (hex), txs: [bytes], nodes: [bytes], proofs: [{txid: bytes, height}],
//!    topics: [{topic, previousCoins, outputsToAdmit, coinsToRetain}], offChainValues?: bytes}
//!
//! Only the host admits plain entries (the front door's answer, the feeds),
//! so the judgements it carries are the route's.
const std = @import("std");
const w = @import("wallet");
const topic_mod = @import("topic.zig");

const cbor = w.cbor;
const Value = cbor.Value;
const Wallet = w.wallet.Wallet;
const ov = w.overlay;
const Allocator = std.mem.Allocator;

/// Decode the BEEF into records (the one parse) and verify them: → the decoded records and the subject.
pub fn decodeAndVerify(wal: *Wallet, beef: []const u8) !struct { decoded: ov.Decoded, subject: ov.Subject } {
    const d = try ov.decode(wal.arena, wal.store, beef);
    return .{ .decoded = d, .subject = try ov.verifyDecoded(wal, d) };
}

fn uints(a: Allocator, xs: []const u32) ![]Value {
    const out = try a.alloc(Value, xs.len);
    for (xs, out) |x, *o| o.* = .{ .uint = x };
    return out;
}

fn uintList(a: Allocator, v: ?Value) ![]u32 {
    const items = if (v) |x| (if (x == .array) x.array else return error.BadEvent) else return &.{};
    const out = try a.alloc(u32, items.len);
    for (items, out) |it, *o| o.* = if (it == .uint and it.uint <= std.math.maxInt(u32)) @intCast(it.uint) else return error.BadEvent;
    return out;
}

/// A topic's judgement of the transaction: its previous coins then, and what it said.
pub const Judged = struct { topic: []const u8, previous: []const u32, ins: ov.Instructions };

/// Call a topic's program (fn "identify") on the transaction's CID → its instructions.
pub fn identify(a: Allocator, caller: ov.Caller, program: []const u8, topic: []const u8, sub: ov.Subject, previous: []const u32, off: ?[]const u8) !ov.Instructions {
    var es: std.ArrayList(cbor.Entry) = .empty;
    try es.appendSlice(a, &.{
        .{ .key = "kind", .value = .{ .text = "topic-call" } },
        .{ .key = "topic", .value = .{ .text = topic } },
        .{ .key = "tx", .value = .{ .cid = sub.cid } },
        .{ .key = "previousCoins", .value = .{ .array = try uints(a, previous) } },
    });
    if (off) |o| try es.append(a, .{ .key = "offChainValues", .value = .{ .bytes = o } });
    return topic_mod.instructionsOf(a, try caller.call(a, program, "identify", .{ .map = es.items }));
}

pub const Routed = union(enum) {
    /// The BEEF does not decode or verify: the error message (400).
    refused: []const u8,
    /// A valid transaction no served topic admitted (BRC-22: 200 with an empty STEAK); the reasons, for the log.
    nothing: []const u8,
    /// Every served topic judged it before (a dupe): nothing new.
    unchanged,
    /// The entry to admit, and the topics that were dupes.
    admit: struct { event: Value, txid: [32]u8, dupes: []const []const u8 },
};

/// The route's half (a call): decode once, verify, judge. `topics` are the
/// requested ones this instance serves; `in` is the call's input (genesis
/// `defaults`, `programs`).
pub fn route(a: Allocator, caller: ov.Caller, wal: *Wallet, in: Value, beef: []const u8, topics: []const []const u8, off: ?[]const u8) !Routed {
    const c = decodeAndVerify(wal, beef) catch |e| switch (e) {
        // A known-rejected transaction is a valid request that admits nothing (200, empty STEAK).
        error.TransactionRejected => return .{ .nothing = @errorName(e) },
        else => return .{ .refused = @errorName(e) },
    };
    const served = try ov.configObject(a, in, "overlayTopics");
    var dupes: std.ArrayList([]const u8) = .empty;
    var judged: std.ArrayList(Judged) = .empty;
    var why: std.ArrayList(u8) = .empty;
    for (topics) |t| {
        if (try ov.isApplied(wal, t, c.subject.txid)) {
            try dupes.append(a, t);
            continue;
        }
        const previous = try ov.previousCoins(wal, t, c.subject.tx);
        const prog = (try ov.configuredProgram(in, served, t)) orelse continue;
        const ins = identify(a, caller, prog, t, c.subject, previous, off) catch |e| {
            try why.print(a, "{s}{s}: {s}", .{ if (why.items.len > 0) "; " else "", t, @errorName(e) });
            continue;
        };
        ov.check(c.subject.tx, previous, ins) catch |e| {
            try why.print(a, "{s}{s}: {s}", .{ if (why.items.len > 0) "; " else "", t, @errorName(e) });
            continue;
        };
        if (ov.takes(previous, ins)) try judged.append(a, .{ .topic = t, .previous = previous, .ins = ins });
    }
    if (dupes.items.len == topics.len) return .unchanged;
    if (judged.items.len == 0) return .{ .nothing = if (why.items.len > 0) why.items else "NotAdmitted: no topic admitted an output or consumed a previous coin" };
    return .{ .admit = .{ .event = try event(a, c.decoded, judged.items, off), .txid = c.subject.txid, .dupes = dupes.items } };
}

/// The submit entry's event: the decoded records, the judgements, the off-chain values.
pub fn event(a: Allocator, d: ov.Decoded, judged: []const Judged, off: ?[]const u8) !Value {
    const txs = try a.alloc(Value, d.txs.len);
    for (d.txs, txs) |t, *o| o.* = .{ .bytes = t.raw };
    const nodes = try a.alloc(Value, d.nodes.len);
    for (d.nodes, nodes) |n, *o| o.* = .{ .bytes = try a.dupe(u8, &n.bytes) };
    const proofs = try a.alloc(Value, d.proven.len);
    for (d.proven, proofs) |p, *o| o.* = .{ .map = try a.dupe(cbor.Entry, &.{
        .{ .key = "txid", .value = .{ .bytes = try a.dupe(u8, &p.txid) } },
        .{ .key = "height", .value = .{ .uint = p.height } },
    }) };
    const topics = try a.alloc(Value, judged.len);
    for (judged, topics) |j, *o| o.* = .{ .map = try a.dupe(cbor.Entry, &.{
        .{ .key = "topic", .value = .{ .text = j.topic } },
        .{ .key = "previousCoins", .value = .{ .array = try uints(a, j.previous) } },
        .{ .key = "outputsToAdmit", .value = .{ .array = try uints(a, j.ins.outputs_to_admit) } },
        .{ .key = "coinsToRetain", .value = .{ .array = try uints(a, j.ins.coins_to_retain) } },
    }) };
    var es: std.ArrayList(cbor.Entry) = .empty;
    try es.appendSlice(a, &.{
        .{ .key = "kind", .value = .{ .text = "submit" } },
        .{ .key = "txid", .value = .{ .text = try a.dupe(u8, &w.header.toHex(d.subject)) } },
        .{ .key = "txs", .value = .{ .array = txs } },
        .{ .key = "nodes", .value = .{ .array = nodes } },
        .{ .key = "proofs", .value = .{ .array = proofs } },
        .{ .key = "topics", .value = .{ .array = topics } },
    });
    if (off) |o| try es.append(a, .{ .key = "offChainValues", .value = .{ .bytes = o } });
    return .{ .map = es.items };
}

/// Hold the records a submit event carries (in the step that admits it): → the subject, now held.
pub fn hold(wal: *Wallet, ev: Value) !ov.Subject {
    const a = wal.arena;
    const txs_v = ev.getArray("txs") orelse return error.BadEvent;
    const nodes_v = ev.getArray("nodes") orelse return error.BadEvent;
    const proofs_v = ev.getArray("proofs") orelse return error.BadEvent;
    const txs = try a.alloc([]const u8, txs_v.len);
    for (txs_v, txs) |v, *o| o.* = if (v == .bytes) v.bytes else return error.BadEvent;
    const nodes = try a.alloc([]const u8, nodes_v.len);
    for (nodes_v, nodes) |v, *o| o.* = if (v == .bytes) v.bytes else return error.BadEvent;
    const proven = try a.alloc(ov.Proven, proofs_v.len);
    for (proofs_v, proven) |v, *o| {
        const t = v.getBytes("txid") orelse return error.BadEvent;
        if (t.len != 32) return error.BadEvent;
        o.* = .{ .txid = t[0..32].*, .height = @intCast(v.getUint("height") orelse return error.BadEvent) };
    }
    try ov.holdDecoded(wal, txs, nodes, proven);
    return ov.subjectOf(wal, try w.header.fromHex(ev.getText("txid") orelse return error.BadEvent));
}

/// What the step came to, per topic in the entry.
pub const Stepped = struct {
    subject: ov.Subject,
    topics: []const []const u8,
    applied: []const ov.Applied,
    /// The records the judgements wrote (admittances, applied): the step keeps them.
    records: []const []const u8,
};

/// The step's half: hold the records, record each judgement, call the lookup services' hooks.
pub fn step(a: Allocator, caller: ov.Caller, wal: *Wallet, in: Value, ev: Value) !Stepped {
    const sub = try hold(wal, ev);
    const served = try ov.configObject(a, in, "overlayTopics");
    const js = ev.getArray("topics") orelse return error.BadEvent;
    const topics = try a.alloc([]const u8, js.len);
    const applied = try a.alloc(ov.Applied, js.len);
    var records: std.ArrayList([]const u8) = .empty;
    for (js, topics, applied) |j, *t, *ap| {
        t.* = j.getText("topic") orelse return error.BadEvent;
        ap.* = .{};
        const previous = try ov.previousCoins(wal, t.*, sub.tx);
        // The route's judgement, unless the topic's previous coins moved since: then the topic is asked again.
        const ins: ov.Instructions = if (std.mem.eql(u32, previous, try uintList(a, j.get("previousCoins"))))
            .{ .outputs_to_admit = try uintList(a, j.get("outputsToAdmit")), .coins_to_retain = try uintList(a, j.get("coinsToRetain")) }
        else blk: {
            const prog = (try ov.configuredProgram(in, served, t.*)) orelse continue;
            break :blk identify(a, caller, prog, t.*, sub, previous, ev.getBytes("offChainValues")) catch continue;
        };
        ap.* = ov.apply(wal, sub, t.*, previous, ins) catch |e| switch (e) {
            error.BadInstructions => continue,
            else => return e,
        };
        if (ap.records.len == 0) continue;
        try records.appendSlice(a, ap.records);
        try ov.hookAdmitted(a, caller, in, t.*, sub, previous, ap.*);
    }
    return .{ .subject = sub, .topics = topics, .applied = applied, .records = records.items };
}
