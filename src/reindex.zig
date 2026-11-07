//! A lookup service's index derived again from the topic's admitted history (0.23.0; 0.23.1 the
//! re-cut, David 2026-11-07: "Yes, simple."): root's message `{fn: "reindex", args: {service}}` in the
//! box `<app>/reindex` (the route's function `reindex`, gated by root) starts a thread of the engine
//! that walks every transaction its topics admitted, in admission order, and runs the service's
//! lookup hooks over each again exactly as admission ran them — the same hooks, the same arguments,
//! the same index head, `at` the time admission gave them. Same instance, same log; nothing is
//! fetched; no other head is touched. There is one index head: no second head, no switch, no hook
//! mode. While the walk runs the instance is the host's to keep from the outside (open-exchange: the
//! router answers 503 "reindexing" for it until the done answer): nothing here knows of that.
//!
//! The thread (engine.zig `reindexStep`):
//!
//!   step 1   root's message: refused unless the service is configured or registered here
//!            (`targetOf`) and no reindex of it runs (the record below); else the service entered as
//!            running, the cursor at the start of each of its topics, and the thread rests on a
//!            deadline (the step's time + 1 ms: the runtime's waker answers it — the kernel's
//!            `deadline` intention, as a shell's sleep).
//!   step n   woken: its cursor is the result record its last step kept (the input's `tip`, as the
//!            chain app reads what it awaits). One transaction (`next`): the program's hooks
//!            `admitted`, then `spent` for each previous coin (calls.zig `hookAdmittedTo`): the
//!            arguments admission gave them, from the topic's applied record, `at` its `at`; what they
//!            answer (beats, events) is not emitted (the walk re-applies history; it announces
//!            nothing). The cursor moves past it; the thread rests again.
//!   last     `next` finds nothing in any topic: the service's entry done, root answered
//!            `{fn: "reindex", request, replyTo, result: {service, transactions, steps, from, to}}`.
//!
//! The order (`next`): per topic, the transactions `mined` names, by (height, offset), past the cursor;
//! then the topic's tail (`State.tailTxids`: admitted and not mined, by admission time) not walked yet —
//! read again at every step. A candidate one of whose inputs spends a tail transaction not walked yet
//! gives way to that parent (two transactions admitted in one step share their admission time, and a
//! mined child's proof may land before its parent's): a parent before its child, as admission ran them.
//!
//! An error in a step (a hook's, a read's) ends the thread at that step: the entry done with `error`,
//! root answered `error: {code: "failed", message}`. Nothing is undone and nothing is retried: the
//! index stays as far as the walk came (the host keeps the instance shut and logs the error).
//!
//! The record of the head `<app>/reindex` (the engine's):
//!
//!   {kind: "overlay-reindex", running: {<service>: {thread, role, from}},
//!    last: {<service>: {transactions, steps, from, to} | {error, steps, from, to}}}
//!
//! `running` is what refuses a second reindex of a service ("reindex in progress") and what a host
//! reads at its start to know a reindex runs; `last` is what each one came to.
const std = @import("std");
const c = @import("chain");
const calls = @import("calls.zig");
const state = @import("state.zig");

const cbor = c.cbor;
const Value = cbor.Value;
const Allocator = std.mem.Allocator;
const eql = std.mem.eql;

/// The box root's message comes in: `<app>/reindex`.
pub const box = "reindex";

/// The head of the engine's record: `<app>/reindex`.
pub fn headName(a: Allocator, app: []const u8) ![]u8 {
    return std.mem.concat(a, u8, &.{ app, "/", box });
}

/// Whether the step's message came in the box `<app>/reindex`.
pub fn isBox(args: Value, app: []const u8) bool {
    const b = args.getText("box") orelse return false;
    return b.len == app.len + 1 + box.len and std.mem.startsWith(u8, b, app) and b[app.len] == '/' and eql(u8, b[app.len + 1 ..], box);
}

// ---------------------------------------------------------------- what is reindexed

/// The service a reindex names: its role (its program's name), its program record, and the topics it
/// listens to, each with the listener the hooks reach there (`calls.hookTargets`'s entry for its
/// program: the name admission calls it as).
pub const Target = struct {
    service: []const u8,
    role: []const u8,
    program: []const u8,
    topics: []const []const u8,
    listeners: []const calls.Listener,
};

/// The service configured (`config.overlay.lookups`) or registered (`<app>/lookups`) here — both are
/// in `defaults.overlayLookups` of the configured input — or null.
pub fn targetOf(a: Allocator, in: Value, service: []const u8) !?Target {
    const lookups = try calls.configObject(a, in, "overlayLookups");
    const role = (try calls.configuredRole(lookups, service)) orelse return null;
    const program = (try calls.programNamed(in, role)) orelse return null;
    var topics: std.ArrayList([]const u8) = .empty;
    var ls: std.ArrayList(calls.Listener) = .empty;
    for (try calls.servedTopics(a, in)) |t| {
        const hears = for (try calls.listeners(a, in, t)) |l| {
            if (eql(u8, l.service, service)) break true;
        } else false;
        if (!hears) continue;
        const l = for (try calls.hookTargets(a, in, t)) |x| {
            if (eql(u8, x.program, program)) break x;
        } else continue;
        try topics.append(a, t);
        try ls.append(a, l);
    }
    return .{ .service = service, .role = role, .program = program, .topics = topics.items, .listeners = ls.items };
}

// ---------------------------------------------------------------- the record `<app>/reindex`

fn entriesOf(rec: ?Value, field: []const u8) []const cbor.Entry {
    const r = rec orelse return &.{};
    const m = r.get(field) orelse return &.{};
    return if (m == .map) m.map else &.{};
}

/// The running reindex of `service` (`{thread, role, from}`), or null.
pub fn running(rec: ?Value, service: []const u8) ?Value {
    for (entriesOf(rec, "running")) |e| if (eql(u8, e.key, service)) return e.value;
    return null;
}

/// What the last reindex of `service` came to, or null.
pub fn last(rec: ?Value, service: []const u8) ?Value {
    for (entriesOf(rec, "last")) |e| if (eql(u8, e.key, service)) return e.value;
    return null;
}

fn without(a: Allocator, es: []const cbor.Entry, key: []const u8) ![]cbor.Entry {
    var out: std.ArrayList(cbor.Entry) = .empty;
    for (es) |e| if (!eql(u8, e.key, key)) try out.append(a, e);
    return out.items;
}

fn sorted(es: []cbor.Entry) []cbor.Entry {
    std.mem.sort(cbor.Entry, es, {}, struct {
        fn lt(_: void, x: cbor.Entry, y: cbor.Entry) bool {
            return std.mem.order(u8, x.key, y.key) == .lt;
        }
    }.lt);
    return es;
}

fn recordOf(a: Allocator, run: []cbor.Entry, done: []cbor.Entry) !Value {
    return .{ .map = try a.dupe(cbor.Entry, &.{
        .{ .key = "kind", .value = .{ .text = "overlay-reindex" } },
        .{ .key = "running", .value = .{ .map = sorted(run) } },
        .{ .key = "last", .value = .{ .map = sorted(done) } },
    }) };
}

/// The record with `service` running: its thread, its program's role, since `from`.
pub fn withRunning(a: Allocator, rec: ?Value, service: []const u8, thread: []const u8, role: []const u8, from: u64) !Value {
    var run: std.ArrayList(cbor.Entry) = .empty;
    try run.appendSlice(a, try without(a, entriesOf(rec, "running"), service));
    try run.append(a, .{ .key = service, .value = .{ .map = try a.dupe(cbor.Entry, &.{
        .{ .key = "thread", .value = .{ .cid = thread } },
        .{ .key = "role", .value = .{ .text = role } },
        .{ .key = "from", .value = .{ .uint = from } },
    }) } });
    return recordOf(a, run.items, try a.dupe(cbor.Entry, entriesOf(rec, "last")));
}

/// The record with `service` no longer running and `result` what it came to.
pub fn withDone(a: Allocator, rec: ?Value, service: []const u8, result: Value) !Value {
    var done: std.ArrayList(cbor.Entry) = .empty;
    try done.appendSlice(a, try without(a, entriesOf(rec, "last"), service));
    try done.append(a, .{ .key = service, .value = result });
    return recordOf(a, try without(a, entriesOf(rec, "running"), service), done.items);
}

// ---------------------------------------------------------------- the cursor

/// Where the walk stands in one topic: the `mined` key of the last mined transaction walked (null:
/// none yet) and the tail transactions walked.
pub const TopicCursor = struct { topic: []const u8, mined: ?[]const u8 = null, tail: []const [32]u8 = &.{} };

/// The thread's own state, kept in each step's result record (`cursor`).
pub const Cursor = struct { topics: []TopicCursor };

pub fn start(a: Allocator, topics: []const []const u8) !Cursor {
    const out = try a.alloc(TopicCursor, topics.len);
    for (topics, out) |t, *o| o.* = .{ .topic = t };
    return .{ .topics = out };
}

pub fn cursorValue(a: Allocator, cur: Cursor) !Value {
    const ts = try a.alloc(Value, cur.topics.len);
    for (cur.topics, ts) |t, *o| {
        const tail = try a.alloc(Value, t.tail.len);
        for (t.tail, tail) |x, *y| y.* = .{ .bytes = try a.dupe(u8, &x) };
        o.* = .{ .map = try a.dupe(cbor.Entry, &.{
            .{ .key = "topic", .value = .{ .text = t.topic } },
            .{ .key = "mined", .value = if (t.mined) |m| .{ .bytes = m } else .null },
            .{ .key = "tail", .value = .{ .array = tail } },
        }) };
    }
    return .{ .map = try a.dupe(cbor.Entry, &.{.{ .key = "topics", .value = .{ .array = ts } }}) };
}

pub fn cursorOf(a: Allocator, v: Value) !Cursor {
    const ts = v.getArray("topics") orelse return error.BadCursor;
    const out = try a.alloc(TopicCursor, ts.len);
    for (ts, out) |t, *o| {
        const tail = t.getArray("tail") orelse return error.BadCursor;
        const xs = try a.alloc([32]u8, tail.len);
        for (tail, xs) |x, *y| {
            if (x != .bytes or x.bytes.len != 32) return error.BadCursor;
            y.* = x.bytes[0..32].*;
        }
        o.* = .{ .topic = t.getText("topic") orelse return error.BadCursor, .mined = t.getBytes("mined"), .tail = xs };
    }
    return .{ .topics = out };
}

// ---------------------------------------------------------------- the walk

/// The next transaction to walk: in topic `topic` (the cursor's index), `mined` its `mined` key when
/// the walk takes it from there (else it is a tail transaction).
pub const Item = struct { topic: usize, txid: [32]u8, mined: ?[]const u8 = null };

fn contains(xs: []const [32]u8, x: [32]u8) bool {
    for (xs) |y| if (eql(u8, &y, &x)) return true;
    return false;
}

/// The next transaction of the walk, or null: nothing left in any topic (`next`, above).
pub fn next(a: Allocator, st: *state.State, cur: Cursor) !?Item {
    for (cur.topics, 0..) |tc, i| {
        const tp = try state.topicPrefix(a, tc.topic);
        // The tail not walked yet, in its order.
        var open: std.ArrayList([32]u8) = .empty;
        for (try st.tailTxids(tc.topic)) |t| if (!contains(tc.tail, t)) try open.append(a, t);
        // The first mined transaction past the cursor, judged by the topic and not walked from the tail.
        const lo: []const u8 = if (tc.mined) |m| try std.mem.concat(a, u8, &.{ m, &.{0} }) else tp;
        const hi = try std.mem.concat(a, u8, &.{ tp, &([_]u8{0xff} ** 13) });
        for (try st.map("mined").range(lo, hi)) |kv| {
            if (kv.value != .bytes or kv.value.bytes.len != 32) return error.BadIndex;
            const txid = kv.value.bytes[0..32].*;
            if (contains(tc.tail, txid) or !(try st.isApplied(tc.topic, txid))) continue;
            const first = try parentFirst(a, st, txid, open.items);
            if (!eql(u8, &first, &txid)) return .{ .topic = i, .txid = first };
            return .{ .topic = i, .txid = txid, .mined = kv.key };
        }
        if (open.items.len > 0) return .{ .topic = i, .txid = try parentFirst(a, st, open.items[0], open.items) };
    }
    return null;
}

/// `txid`, or the earliest (in `open`'s order) of the not-yet-walked tail transactions it spends, and
/// so on up: a parent before its child.
fn parentFirst(a: Allocator, st: *state.State, txid: [32]u8, open: []const [32]u8) ![32]u8 {
    var cur = txid;
    var hops: usize = 0;
    while (hops <= open.len) : (hops += 1) {
        const sub = try state.subjectOf(a, st.store, cur);
        var best: ?usize = null;
        for (sub.tx.inputs) |in| {
            const p = in.previous_outpoint.txid.bytes;
            if (eql(u8, &p, &cur)) continue;
            for (open, 0..) |o, k| if (eql(u8, &o, &p)) {
                if (best == null or k < best.?) best = k;
            };
        }
        cur = open[best orelse return cur];
    }
    return cur;
}

/// The cursor past `item`.
pub fn advance(a: Allocator, cur: Cursor, item: Item) !Cursor {
    const ts = try a.dupe(TopicCursor, cur.topics);
    const t = &ts[item.topic];
    if (item.mined) |m| t.mined = try a.dupe(u8, m) else t.tail = try std.mem.concat(a, [32]u8, &.{ t.tail, &.{item.txid} });
    return .{ .topics = ts };
}

fn uintList(a: Allocator, v: ?[]const Value) ![]u32 {
    const xs = v orelse return &.{};
    const out = try a.alloc(u32, xs.len);
    for (xs, out) |x, *o| o.* = if (x == .uint and x.uint <= std.math.maxInt(u32)) @intCast(x.uint) else return error.BadRecord;
    return out;
}

/// Walk one transaction: the target's hooks over it as its admission ran them — from the topic's
/// applied record: `outputsToAdmit`, `coinsToRetain`, the previous coins (retained and removed, in
/// input order) for `spent`, and `at`, the time it was admitted. A transaction no longer applied
/// (rejected since `next` found it) is passed over. → whether it was walked.
pub fn walk(a: Allocator, caller: calls.Caller, in: Value, st: *state.State, t: Target, cur: Cursor, item: Item) !bool {
    const topic = cur.topics[item.topic].topic;
    const rec = (try st.appliedRecord(topic, item.txid)) orelse return false;
    const outs = try uintList(a, rec.getArray("outputsToAdmit"));
    const retained = try uintList(a, rec.getArray("coinsToRetain"));
    const removed = try uintList(a, rec.getArray("coinsRemoved"));
    const at = rec.getUint("at") orelse return error.BadRecord;
    const previous = try std.mem.concat(a, u32, &.{ retained, removed });
    std.mem.sort(u32, previous, {}, std.sort.asc(u32));
    const l = for (t.topics, t.listeners) |x, y| {
        if (eql(u8, x, topic)) break y;
    } else return error.TopicNotHeard; // the service no longer listens to a topic the walk began on
    const sub = try state.subjectOf(a, st.store, item.txid);
    try calls.hookAdmittedTo(a, caller, in, l, topic, sub, previous, .{ .outputs_to_admit = outs, .coins_to_retain = retained, .coins_removed = removed }, @intCast(at), st);
    return true;
}
