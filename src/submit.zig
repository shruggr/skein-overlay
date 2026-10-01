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
//!   edges appear), then gates on broadcast (#57): a subject the entry
//!   proves is mined and goes straight on; otherwise it is posted to the
//!   broadcaster (#70, #67: a message to the address book's `broadcast`
//!   provider, the host's Arcade, #58) and the broadcast record marked
//!   `pending`, nothing admitted yet.
//! - **The awaiting thread** (`awaited`). While the transaction is pending
//!   the engine awaits what it asked the broadcaster, and the transaction's
//!   CID, with a deadline: the broadcaster's answer (ARC's), a `status` /
//!   `proof` entry for it, or the deadline (the broadcaster asked again)
//!   steps the same thread. ARC takes it: the broadcast record, then the
//!   admission — each topic's judgement recorded (`applied`, the
//!   admittances) and each listening lookup service's hooks called
//!   (`admitted`, then `spent` for each previous coin consumed). ARC rejects
//!   it: the rejection (Wallet.reject), nothing admitted. A transient
//!   failure: still `pending`. A judgement is taken again, at admission,
//!   only if the topic's previous coins moved since the call.
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
    /// Every served topic judged it before (a dupe): nothing new; the answer is its judgements, from the state.
    unchanged: [32]u8,
    /// Held and awaiting ARC, nothing admitted yet (#57): a resubmission adds nothing; the answer is read from the state.
    pending: [32]u8,
    /// The entry to admit (the topics that were dupes are answered from their `applied` records).
    admit: struct { event: Value, txid: [32]u8 },
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
    return .{ .admit = .{ .event = try event(a, c.decoded, judged.items, off), .txid = c.subject.txid } };
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

/// An answer of the broadcaster (#70: the provider's signed message, its
/// body {replyTo, status, body}): Arcade's HTTP status and JSON, as the
/// host's broadcaster (#58) had them — status 0 when no answer came ({error}).
pub const Reply = struct { status: u64, body: []const u8 };

/// The broadcaster as the gate sees it (#70, #67): the address book's
/// `broadcast` provider, reached by emitting to it (vm.zig's), or a test's.
/// Each question is a message about the transaction; its answer is an entry
/// that steps the submission's thread again (`Wake.answer`).
pub const Broadcaster = struct {
    ctx: *anyopaque,
    /// Emit to the broadcaster in `box` about `txid` with `body`: the
    /// message's CID (the thread awaits it). No broadcaster: error.NoBroadcaster.
    emitFn: *const fn (ctx: *anyopaque, a: Allocator, box: []const u8, txid: [32]u8, body: Value) anyerror![]const u8,

    /// Post the transaction (box "broadcast", {tx: <the Atomic BEEF>}).
    pub fn broadcast(self: Broadcaster, a: Allocator, txid: [32]u8, beef: []const u8) ![]const u8 {
        return self.emitFn(self.ctx, a, "broadcast", txid, .{ .map = try a.dupe(cbor.Entry, &.{.{ .key = "tx", .value = .{ .bytes = beef } }}) });
    }

    /// Ask after it (box "status", {txid}).
    pub fn ask(self: Broadcaster, a: Allocator, txid: [32]u8) ![]const u8 {
        return self.emitFn(self.ctx, a, "status", txid, .{ .map = try a.dupe(cbor.Entry, &.{.{ .key = "txid", .value = .{ .text = try a.dupe(u8, &w.header.toHex(txid)) } }}) });
    }
};

/// The broadcast gate's settings, from genesis `defaults`: how often a
/// submission awaiting the broadcaster is asked about again
/// (`overlayRecheckMs`, default 30 000: a client told 503 retries on that
/// scale), and when an unmined one is given up (`walletAbandonMs`, default
/// 86 400 000: the chain core's rule). The broadcaster itself is the address
/// book's (#70).
pub const Gate = struct {
    recheck_ms: i64 = 30_000,
    abandon_ms: i64 = 86_400_000,

    pub fn of(in: Value) !Gate {
        const d = in.get("defaults") orelse return .{};
        return .{
            .recheck_ms = std.fmt.parseInt(i64, d.getText("overlayRecheckMs") orelse "30000", 10) catch return error.BadConfig,
            .abandon_ms = std.fmt.parseInt(i64, d.getText("walletAbandonMs") orelse "86400000", 10) catch return error.BadConfig,
        };
    }

    /// The Retry-After a pending submission is answered with: the re-ask interval, in whole seconds (at least 1).
    pub fn retryAfter(g: Gate) u64 {
        return @intCast(@max(1, @divFloor(g.recheck_ms + 999, 1000)));
    }
};

/// ARC's answer (the broadcaster passes Arcade's own): the HTTP status, its
/// txStatus, a merkle path if mined, and its reason.
pub const ArcAnswer = struct {
    http_status: u64,
    tx_status: []const u8 = "",
    merkle_path: ?[]const u8 = null,
    extra: []const u8 = "",

    pub fn value(self: ArcAnswer, a: Allocator) !Value {
        var es: std.ArrayList(cbor.Entry) = .empty;
        try es.appendSlice(a, &.{
            .{ .key = "status", .value = .{ .uint = self.http_status } },
            .{ .key = "txStatus", .value = .{ .text = self.tx_status } },
            .{ .key = "extraInfo", .value = .{ .text = self.extra } },
        });
        if (self.merkle_path) |p| try es.append(a, .{ .key = "merklePath", .value = .{ .bytes = p } });
        return .{ .map = es.items };
    }
};

/// Read ARC's JSON answer as the wallet program does: txStatus, merklePath
/// (hex), and extraInfo (else Arcade's reason / detail / title).
pub fn arcAnswer(a: Allocator, reply: Reply) !ArcAnswer {
    var ans = ArcAnswer{ .http_status = reply.status };
    const j = std.json.parseFromSliceLeaky(std.json.Value, a, reply.body, .{}) catch return ans;
    if (j != .object) return ans;
    if (j.object.get("txStatus")) |t| if (t == .string) {
        ans.tx_status = t.string;
    };
    for ([_][]const u8{ "extraInfo", "reason", "detail", "title" }) |k| if (j.object.get(k)) |t| if (t == .string and t.string.len > 0) {
        ans.extra = t.string;
        break;
    };
    if (j.object.get("merklePath")) |t| if (t == .string and t.string.len > 0) {
        const p = try a.alloc(u8, t.string.len / 2);
        _ = std.fmt.hexToBytes(p, t.string) catch return error.BadHttpResponse;
        ans.merkle_path = p;
    };
    return ans;
}

/// What ARC's answer says about a submission: **accepted** (a 2xx whose
/// txStatus is not a rejection — RECEIVED, a duplicate's SEEN or MINED);
/// **rejected** (a 4xx, or REJECTED / DOUBLE_SPEND_ATTEMPTED / INVALID /
/// MALFORMED); **transient** (anything else: a 503 for backpressure, the
/// broadcaster's 503 for an Arcade it cannot reach, no answer at all).
pub const Verdict = enum { accepted, rejected, transient };

pub fn verdictOf(ans: ArcAnswer) Verdict {
    if (Wallet.isRejection(ans.tx_status)) return .rejected;
    if (ans.http_status >= 200 and ans.http_status < 300) return .accepted;
    if (ans.http_status >= 400 and ans.http_status < 500) return .rejected;
    return .transient;
}

/// How the broadcast gate went: `mined` (the entry carried the subject's
/// proof: no broadcast), `accepted`, `rejected`, `pending` (ARC has not
/// taken it yet: nothing admitted, the thread awaits and asks again).
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
    /// ARC's answer, when this step had one (the broadcaster's).
    arc: ?ArcAnswer = null,
    /// What this step asked the broadcaster (#70): the messages, whose answers the thread awaits.
    asked: []const []const u8 = &.{},
    /// The transaction's settlement now: its thread awaits it while pending.
    outcome: Wallet.Outcome,
    /// The records the judgements wrote (admittances, applied): the step keeps them.
    records: []const []const u8 = &.{},
};

/// The step's half, on the `submit` entry (#57): hold the records; unless
/// the subject is mined, post it to the broadcaster (#70: a message) and
/// leave it pending, nothing admitted: the thread awaits the broadcaster's
/// answer (and the transaction's CID, with a deadline), which admits it once
/// ARC takes it.
pub fn step(a: Allocator, caller: ov.Caller, bc: Broadcaster, wal: *Wallet, in: Value, ev: Value) !Stepped {
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
    const asked = try bc.broadcast(a, sub.txid, beef);
    try wal.noteSubmission(sub.txid, "broadcast", "", "pending", in.getCid("thread"));
    out.gate = .pending;
    out.asked = try a.dupe([]const u8, &.{asked});
    return out;
}

/// ARC's word on a submission not yet admitted (its answer to the post or to
/// a question, or a status entry): accepted → the broadcast record, the
/// status applied, the judgements admitted; rejected → the rejection (#37's
/// walk: the transaction and whatever depends on it), nothing admitted;
/// transient → the broadcast record with `submission: "pending"`, nothing
/// admitted.
fn gated(a: Allocator, caller: ov.Caller, wal: *Wallet, in: Value, ev: Value, ans: ArcAnswer, out: *Stepped) !void {
    const txid = out.subject.txid;
    out.arc = ans;
    switch (verdictOf(ans)) {
        .accepted => {
            out.gate = .accepted;
            try wal.noteSubmission(txid, "broadcast", ans.tx_status, "admitted", in.getCid("thread"));
            out.outcome = try wal.applyStatus(txid, ans.tx_status, ans.merkle_path);
            if (out.outcome != .rejected) try admit(a, caller, wal, in, ev, out);
        },
        .rejected => {
            out.gate = .rejected;
            _ = try wal.reject(txid, if (ans.tx_status.len > 0) ans.tx_status else "REJECTED");
            out.outcome = .rejected;
        },
        .transient => {
            out.gate = .pending;
            try wal.noteSubmission(txid, "broadcast", ans.tx_status, "pending", in.getCid("thread"));
            out.outcome = .pending;
        },
    }
}

/// Whether a submission is held and awaiting ARC with nothing admitted yet: its broadcast record says `pending`.
pub fn isPending(wal: *Wallet, txid: [32]u8) !bool {
    const r = (try wal.awaitingRecord(txid)) orelse return false;
    return std.mem.eql(u8, r.getText("submission") orelse "", "pending");
}

/// What steps a submission's awaiting thread: a `status` / `proof` entry for
/// its transaction, the broadcaster's answer to what it asked (#70: in the
/// box it asked in, "broadcast" or "status"), or its deadline.
pub const Wake = union(enum) { event: Value, answer: struct { box: []const u8, reply: Reply }, deadline };

/// A step of the submission's awaiting thread (as the wallet's
/// awaiting-callback thread, docs/WALLET.md); `ev` is the submit entry the
/// thread began with. **Not yet admitted:** the broadcaster's answer, or a
/// status entry, is ARC's word on it (a rejection rejects; anything else
/// means ARC has it, and it is admitted); a 404 to a question (ARC never
/// took it) posts it again; at the deadline it is abandoned if due, else the
/// broadcaster is asked again. **Admitted:** the status is applied (a merkle
/// path proves it; a rejection unwinds the admittances through `admits`).
pub fn awaited(a: Allocator, caller: ov.Caller, bc: Broadcaster, wal: *Wallet, in: Value, ev: Value, wake: Wake) !Stepped {
    const sub = try ov.subjectOf(wal, try w.header.fromHex(ev.getText("txid") orelse return error.BadEvent));
    const txid = sub.txid;
    const pending = try isPending(wal, txid);
    var out = Stepped{ .subject = sub, .gate = if (pending) .pending else .accepted, .outcome = .pending };
    switch (wake) {
        .event => |e| {
            const kind = e.getText("kind") orelse return error.BadEvent;
            const ans: ArcAnswer = if (std.mem.eql(u8, kind, "proof"))
                .{ .http_status = 200, .tx_status = "MINED", .merkle_path = e.getBytes("path") orelse return error.BadEvent }
            else if (std.mem.eql(u8, kind, "status"))
                .{ .http_status = 200, .tx_status = e.getText("txStatus") orelse "", .merkle_path = e.getBytes("merklePath") }
            else
                return error.BadEvent;
            if (pending) {
                try gated(a, caller, wal, in, ev, ans, &out);
                out.arc = null; // an entry, not the broadcaster's answer
            } else out.outcome = try wal.applyStatus(txid, ans.tx_status, ans.merkle_path);
        },
        .answer => |x| {
            const ans = try arcAnswer(a, x.reply);
            if (std.mem.eql(u8, x.box, "status") and ans.http_status == 404) {
                // 404: ARC never took it (the post failed transiently, or it lost its history): post it again.
                out.arc = ans;
                out.asked = try a.dupe([]const u8, &.{try bc.broadcast(a, txid, (try wal.beefOf(txid)) orelse return error.UnknownTransaction)});
                out.outcome = switch (try wal.status(txid)) {
                    .proven => .proven,
                    .rejected => .rejected,
                    .unproven => .pending,
                };
            } else if (pending) {
                try gated(a, caller, wal, in, ev, ans, &out);
            } else {
                out.arc = ans;
                out.outcome = try wal.applyStatus(txid, if (verdictOf(ans) == .rejected and ans.tx_status.len == 0) "REJECTED" else ans.tx_status, ans.merkle_path);
            }
        },
        .deadline => {
            if ((try wal.awaitingRecord(txid)) == null) {
                // Settled by another step (a proof on the chain feed, a rejection's walk): nothing to ask.
                out.outcome = switch (try wal.status(txid)) {
                    .proven => .proven,
                    .rejected => .rejected,
                    .unproven => .pending,
                };
                return out;
            }
            if (try wal.abandonIfDue(txid, (try Gate.of(in)).abandon_ms)) {
                out.outcome = .rejected;
                return out;
            }
            // Ask the broadcaster again: its answer steps the thread.
            out.asked = try a.dupe([]const u8, &.{try bc.ask(a, txid)});
        },
    }
    return out;
}

/// The admission: each topic's judgement the entry carries recorded
/// (`applied`, the admittances), and the listening lookup services' hooks
/// called (`admitted`, then `spent` for each previous coin consumed) — once
/// ARC took the transaction, or it is mined. A judgement is taken again only
/// if the topic's previous coins moved since the call.
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
