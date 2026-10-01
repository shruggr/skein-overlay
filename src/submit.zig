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
//!   edges appear), then gates on broadcast (#57, #65, #73): a subject the
//!   entry proves is mined and goes straight on; otherwise it is broadcast
//!   (an event: {event: "broadcast", tx, beef}, the host's wiring carries it)
//!   and left pending — nothing admitted — until either signal arrives.
//!   There is no setting: the gate is **the first of** a status provider's
//!   acceptance or the transaction's proof (#73). Admission on validation
//!   alone is not a mode; an instance with no status feed subscribed simply
//!   never hears one, so it admits at the proof.
//! - **The awaiting thread** (`awaited`). While the transaction is pending
//!   the engine awaits its CID, with a deadline at its abandonment: a proof
//!   event, a status provider's message, or the deadline steps the same
//!   thread. **Admits on the first of them**: a status that is not a
//!   rejection, or a validated proof — whichever arrives first; the other,
//!   arriving after, only settles or notes it (no double admission). Each
//!   admission records the broadcast record, then each topic's judgement
//!   (`applied`, the admittances) and each listening lookup service's hooks
//!   (`admitted`, then `spent` for each previous coin consumed). Rejected
//!   (the provider's REJECTED, DOUBLE_SPEND_ATTEMPTED, …; a competing proof;
//!   abandonment): the rejection (Wallet.reject), nothing admitted. A
//!   judgement is taken again, at admission, only if the topic's previous
//!   coins moved since the call.
//!
//! The entry (box `submit`) carries records, not a BEEF:
//!
//!   {kind: "submit", txid (hex), txs: [bytes], nodes: [bytes], proofs: [{txid: bytes, height}],
//!    topics: [{topic, previousCoins, outputsToAdmit, coinsToRetain}], offChainValues?: bytes,
//!    source?: {transport, topic?, request: <the request record>}}
//!
//! `source` (#74) says where the submission came from: at admission it is
//! re-published on each topic that admitted it (the BEEF as received: the
//! request's body), unless it arrived by gossip on that topic (gossip.zig).
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
    /// Every served topic judged it before (a dupe): nothing new; the answer is its judgements, from the state.
    unchanged: [32]u8,
    /// Held and awaiting ARC, nothing admitted yet (#57): a resubmission adds nothing; the answer is read from the state.
    pending: [32]u8,
    /// The entry to admit (the topics that were dupes are answered from their `applied` records).
    admit: struct { event: Value, txid: [32]u8 },
};

/// The route's half (a call): decode once, verify, judge. `topics` are the
/// requested ones this instance serves; `in` is the call's input (genesis
/// `defaults`, `programs`); `source` is carried on the entry (#74).
pub fn route(a: Allocator, caller: ov.Caller, wal: *Wallet, in: Value, beef: []const u8, topics: []const []const u8, off: ?[]const u8, source: ?Value) !Routed {
    const c = decodeAndVerify(wal, beef) catch |e| switch (e) {
        // A known-rejected transaction is a valid request that admits nothing (200, empty STEAK).
        error.TransactionRejected => return .{ .nothing = @errorName(e) },
        else => return .{ .refused = @errorName(e) },
    };
    if (try isPending(wal, c.subject.txid)) return .{ .pending = c.subject.txid };
    const served = try ov.configObject(a, in, "overlayTopics");
    var dupes: usize = 0;
    var judged: std.ArrayList(Judged) = .empty;
    var why: std.ArrayList(u8) = .empty;
    for (topics) |t| {
        if (try ov.isApplied(wal, t, c.subject.txid)) {
            dupes += 1;
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
    // Nothing new, but judged before by some topic: that judgement is the answer (from the state).
    if (dupes == topics.len or (judged.items.len == 0 and dupes > 0)) return .{ .unchanged = c.subject.txid };
    if (judged.items.len == 0) return .{ .nothing = if (why.items.len > 0) why.items else "NotAdmitted: no topic admitted an output or consumed a previous coin" };
    return .{ .admit = .{ .event = try event(a, c.decoded, judged.items, off, source), .txid = c.subject.txid } };
}

/// The submit entry's event: the decoded records, the judgements, the off-chain values, the source.
pub fn event(a: Allocator, d: ov.Decoded, judged: []const Judged, off: ?[]const u8, source: ?Value) !Value {
    const txs = try a.alloc(Value, d.txs.len);
    for (d.txs, txs) |t, *o| o.* = .{ .bytes = t.raw };
    const nodes = try a.alloc(Value, d.nodes.len);
    for (d.nodes, nodes) |n, *o| o.* = .{ .bytes = try a.dupe(u8, &n.bytes) };
    const proofs = try a.alloc(Value, d.proven.len);
    for (d.proven, proofs) |p, *o| o.* = .{ .map = try a.dupe(cbor.Entry, &.{
        .{ .key = "txid", .value = .{ .bytes = try a.dupe(u8, &p.txid) } },
        .{ .key = "height", .value = .{ .uint = p.height } },
        .{ .key = "depth", .value = .{ .uint = p.pos.depth } },
        .{ .key = "position", .value = .{ .uint = p.pos.offset } },
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
    if (source) |src| try es.append(a, .{ .key = "source", .value = src });
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
        const depth = v.getUint("depth") orelse return error.BadEvent;
        if (depth > 64) return error.BadEvent;
        o.* = .{
            .txid = t[0..32].*,
            .height = @intCast(v.getUint("height") orelse return error.BadEvent),
            .pos = .{ .depth = @intCast(depth), .offset = v.getUint("position") orelse return error.BadEvent },
        };
    }
    try ov.holdDecoded(wal, txs, nodes, proven);
    return ov.subjectOf(wal, try w.header.fromHex(ev.getText("txid") orelse return error.BadEvent));
}

// ---------------------------------------------------------------- the step: broadcast, then admit (#57)

/// The broadcast wiring as the gate sees it (#65): broadcasting is an
/// event, addressed to no one (vm.zig's emits it; a test's records it).
pub const Wire = struct {
    ctx: *anyopaque,
    /// Broadcast the transaction: the event {event: "broadcast", tx: <its CID>, beef}.
    broadcastFn: *const fn (ctx: *anyopaque, a: Allocator, txid: [32]u8, beef: []const u8) anyerror!void,

    pub fn broadcast(self: Wire, a: Allocator, txid: [32]u8, beef: []const u8) !void {
        return self.broadcastFn(self.ctx, a, txid, beef);
    }
};

/// The broadcast gate's settings, from genesis `defaults`: when an unmined
/// submission is given up (`walletAbandonMs`, default 86 400 000; 0: never —
/// the chain core's rule). There is no admission setting (#73): the gate is
/// always the first of a status provider's acceptance or the proof.
pub const Gate = struct {
    abandon_ms: i64 = 86_400_000,

    pub fn of(in: Value) !Gate {
        const d = in.get("defaults") orelse return .{};
        return .{
            .abandon_ms = std.fmt.parseInt(i64, d.getText("walletAbandonMs") orelse "86400000", 10) catch return error.BadConfig,
        };
    }

    /// The Retry-After a submission still pending is answered with (whole
    /// seconds): a client told 503 resubmits on this scale, and is answered
    /// from the state (the same thread) until it is admitted or rejected.
    pub fn retryAfter(_: Gate) u64 {
        return 30;
    }

    /// When a pending submission's thread wakes to abandon it: its first
    /// broadcast + `abandon_ms`; null: never (0), or nothing awaits it.
    pub fn deadline(g: Gate, wal: *Wallet, txid: [32]u8) !?i64 {
        if (g.abandon_ms <= 0) return null;
        const r = (try wal.awaitingRecord(txid)) orelse return null;
        const since: i64 = @intCast(r.getUint("since") orelse return null);
        return @max(since + g.abandon_ms, wal.now + 1);
    }
};

/// How the broadcast gate went: `mined` (the entry carried the subject's
/// proof, or its proof came: admitted), `accepted` (a status provider said
/// the network has it: admitted), `rejected`, `pending` (nothing admitted
/// yet: the thread awaits — either its proof, or a status provider's word).
pub const Gated = enum { mined, accepted, rejected, pending };

/// What a submit step (or a step of its awaiting thread) came to.
pub const Stepped = struct {
    subject: ov.Subject,
    /// The entry's topics, and each one's judgement as recorded: set when this step admitted it.
    topics: []const []const u8 = &.{},
    applied: []const ov.Applied = &.{},
    /// Whether this step admitted the submission (recorded its judgements, called the hooks).
    admitted: bool = false,
    gate: Gated,
    /// The status this step heard of the transaction (a status provider's), if any.
    tx_status: []const u8 = "",
    /// The transaction's settlement now: its thread awaits it while pending.
    outcome: Wallet.Outcome,
    /// The records the judgements wrote (admittances, applied): the step keeps them.
    records: []const []const u8 = &.{},
};

/// The step's half, on the `submit` entry (#57, #65, #73): hold the records;
/// unless the subject is mined, broadcast it (an event) and leave it
/// pending, nothing admitted: the thread awaits the transaction's CID (a
/// status provider's word, its proof) with a deadline — admitted on the
/// first of them (`awaited`).
pub fn step(a: Allocator, caller: ov.Caller, wire: Wire, wal: *Wallet, in: Value, ev: Value) !Stepped {
    const sub = try hold(wal, ev);
    var out = Stepped{ .subject = sub, .gate = .mined, .outcome = .pending };
    switch (try wal.status(sub.txid)) {
        // Mined: the entry carried its proof; nothing to broadcast.
        .proven => {
            out.outcome = .proven;
            try admit(a, caller, wal, in, ev, &out);
            return out;
        },
        // Rejected between the call and the step (a status, a competing proof): nothing admitted.
        .rejected => {
            out.gate = .rejected;
            out.outcome = .rejected;
            return out;
        },
        .unproven => {},
    }
    const beef = (try wal.beefOf(sub.txid)) orelse return error.UnknownTransaction;
    try wire.broadcast(a, sub.txid, beef);
    try wal.noteSubmission(sub.txid, "", "pending", in.getCid("thread"));
    out.gate = .pending;
    return out;
}

/// Whether a submission is held and awaiting ARC with nothing admitted yet: its broadcast record says `pending`.
pub fn isPending(wal: *Wallet, txid: [32]u8) !bool {
    const r = (try wal.awaitingRecord(txid)) orelse return false;
    return std.mem.eql(u8, r.getText("submission") orelse "", "pending");
}

/// What steps a submission's awaiting thread (#65): an event about its
/// transaction (its proof, from the host's wiring), a status provider's
/// message about it (the body: {kind: "status", txid, txStatus, …}), or its
/// deadline (abandonment).
pub const Wake = union(enum) { event: Value, status: Value, deadline };

/// A step of the submission's awaiting thread (as the wallet's
/// awaiting-callback thread, docs/WALLET.md); `ev` is the submit entry the
/// thread began with. **Not yet admitted, the gate (#73): the first of**
/// a status that is not a rejection (admits), or a validated proof (admits;
/// a path whose header we do not hold yet leaves it pending); a rejection
/// status rejects it; at the deadline it is abandoned if due. A status
/// message only ever arrives here through a subscribed provider, so an
/// instance with none simply never hears one and admits at the proof.
/// **Already admitted:** the status or proof is only applied (a merkle path
/// proves it; a rejection unwinds the admittances through `admits`) — no
/// second admission.
pub fn awaited(a: Allocator, caller: ov.Caller, wal: *Wallet, in: Value, ev: Value, wake: Wake) !Stepped {
    const sub = try ov.subjectOf(wal, try w.header.fromHex(ev.getText("txid") orelse return error.BadEvent));
    const txid = sub.txid;
    const pending = try isPending(wal, txid);
    var out = Stepped{ .subject = sub, .gate = if (pending) .pending else .accepted, .outcome = .pending };
    switch (wake) {
        .event => |e| {
            const kind = e.getText("kind") orelse return error.BadEvent;
            if (!std.mem.eql(u8, kind, "proof")) return error.BadEvent;
            const path = e.getBytes("path") orelse return error.BadEvent;
            out.tx_status = "MINED";
            out.outcome = try wal.applyStatus(txid, "MINED", path);
            if (pending) switch (out.outcome) {
                .proven => {
                    out.gate = .mined;
                    try admit(a, caller, wal, in, ev, &out);
                },
                .rejected => out.gate = .rejected,
                // A path whose header we do not hold yet: still pending (and still marked so).
                .pending => try wal.noteSubmission(txid, "MINED", "pending", in.getCid("thread")),
            };
        },
        .status => |b| {
            const st = b.getText("txStatus") orelse return error.BadEvent;
            out.tx_status = st;
            if (!pending) {
                out.outcome = try wal.applyStatus(txid, st, null);
            } else if (Wallet.isRejection(st)) {
                _ = try wal.reject(txid, st);
                out.gate = .rejected;
                out.outcome = .rejected;
            } else {
                // The network has it, says the status provider: admitted — the first of the two
                // signals (#73); its proof, arriving after, only settles it (the `!pending` branch above).
                try wal.noteSubmission(txid, st, "admitted", in.getCid("thread"));
                out.gate = .accepted;
                out.outcome = try wal.applyStatus(txid, st, null);
                if (out.outcome != .rejected) try admit(a, caller, wal, in, ev, &out);
            }
        },
        .deadline => {
            if ((try wal.awaitingRecord(txid)) == null) {
                // Settled by another step (a proof on the chain feed, a rejection's walk).
                out.outcome = switch (try wal.status(txid)) {
                    .proven => .proven,
                    .rejected => .rejected,
                    .unproven => .pending,
                };
                if (out.outcome == .rejected) out.gate = .rejected;
                return out;
            }
            if (try wal.abandonIfDue(txid, (try Gate.of(in)).abandon_ms)) {
                out.gate = .rejected;
                out.outcome = .rejected;
                return out;
            }
        },
    }
    return out;
}

/// The admission: each topic's judgement the entry carries recorded
/// (`applied`, the admittances), and the listening lookup services' hooks
/// called (`admitted`, then `spent` for each previous coin consumed) — once
/// the gate lets it through (#65, #73: mined, or the first of a status
/// provider's word and the proof). A judgement is taken again only if the
/// topic's previous coins moved since the call.
fn admit(a: Allocator, caller: ov.Caller, wal: *Wallet, in: Value, ev: Value, out: *Stepped) !void {
    const sub = out.subject;
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
    out.topics = topics;
    out.applied = applied;
    out.records = records.items;
    out.admitted = true;
}
