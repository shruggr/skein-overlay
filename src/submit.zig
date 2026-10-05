//! A submission, from the wire to the state (#50, re-split by skein #79).
//! Three parts:
//!
//! - **The route** (`route`, the front door's `/submit` handler, and the
//!   `libp2p:<topic>` one: an in-VM call, writing nothing). The BEEF comes
//!   as the pointer record the kernel's door wrote (shruggr/skein#121: the
//!   transactions are `bitcoin-tx` blocks in the store, every BUMP checked
//!   against the chain app's headers there) and is read, not proven again;
//!   bytes (a body framed with off-chain values, or a host with no door) are
//!   decoded once into records and checked against the headers. Then SPV for
//!   the unproven transactions (state.zig `verifyDecoded`, read through
//!   `get`, the chain state read only), and the judgement: each requested topic this overlay
//!   serves and has not judged it before is called (`identify`, topic.zig)
//!   on the transaction's CID with its previous coins. If no topic takes
//!   anything, nothing persists. Otherwise it returns the submit event.
//! - **The submission's thread** (`begin`, then `answered`). Its first step
//!   hands the BEEF to the chain app — the message `{fn: "ingest", args:
//!   {beef}}` to the instance itself, box `chain` — notes the submission
//!   `pending`, and rests awaiting that message's answers. Nothing is
//!   admitted until the chain app answers (#73's rule, the chain app's
//!   answer): **accepted** (a status provider's word that the network has it)
//!   or **proven** (its proof, validated by the chain app against its
//!   headers) admits it — each topic's judgement recorded (`applied`, the
//!   admittances), the listening lookup services' hooks called (`admitted`,
//!   then `spent`), the gossip out; **rejected** admits nothing. Either way
//!   the thread finishes (#66: the request that launched it, and any
//!   resubmission awaiting it, answer from the state). Admitted on
//!   `accepted`, its last step sends the overlay itself a `watch` message, so
//!   what the chain app says later is still heard.
//! - **The watch thread** (`watchStart`, then `watched`): the message
//!   `{fn: "watch", args: {txid, ingest}}` in the app's box, from the
//!   instance itself. It reads the chain state first (what was said in
//!   between), then awaits the same ingest message's later answers:
//!   **proven** publishes `<topic>-proof`; **rejected** (a status, a
//!   competing proof, abandonment, a rejected input) removes the
//!   judgements (`State.unapply`) and calls each topic's lookup services'
//!   `rejected`. Then it finishes.
//!
//! The submit event (box `<app>` from the libp2p route; or the args of the
//! thread POST /submit launches):
//!
//!   {kind: "submit", txid (hex), beef: <the pointer record> | bytes (the BEEF as received, the off-chain framing taken off),
//!    topics: [{topic, previousCoins, outputsToAdmit, coinsToRetain}], offChainValues?: bytes,
//!    source?: {transport, topic?, request: <the request record>}}
//!
//! `source` (#74) says where the submission came from: at admission it is
//! re-published on each topic that admitted it, unless it arrived by gossip
//! on that topic (gossip.zig).
const std = @import("std");
const c = @import("chain");
const topic_mod = @import("topic");
const state = @import("state.zig");
const calls = @import("calls.zig");
const gossip = @import("gossip.zig");

const cbor = c.cbor;
const Value = cbor.Value;
const State = state.State;
const Allocator = std.mem.Allocator;
const eql = std.mem.eql;

/// The chain app's box: an ingest message goes there (to the instance itself).
pub const chain_box = "chain";

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
pub const Judged = struct { topic: []const u8, previous: []const u32, ins: topic_mod.Instructions };

/// Call a topic's program (fn "identify") on the transaction's CID → its instructions.
pub fn identify(a: Allocator, caller: calls.Caller, program: []const u8, topic: []const u8, sub: state.Subject, previous: []const u32, off: ?[]const u8) !topic_mod.Instructions {
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
    /// Handed to the chain app, nothing admitted yet: a resubmission adds nothing; the answer is read from the state.
    pending: [32]u8,
    /// The event to admit (the topics that were dupes are answered from their `applied` records).
    admit: struct { event: Value, txid: [32]u8 },
};

/// A submission's BEEF (shruggr/skein#121): the pointer record the kernel's door wrote — its CID;
/// the transactions and BUMPs are blocks in the store already, every BUMP checked against the
/// chain state's headers at the door — or the bytes (a body framed with off-chain values, whose
/// leading bytes are no BEEF pattern; a host with no door), decoded and checked here as before.
pub const Input = union(enum) {
    record: []const u8,
    bytes: []const u8,

    /// The value the submit event and the ingest message carry: the record's link, or the bytes.
    pub fn value(self: Input) Value {
        return switch (self) {
            .record => |c_| .{ .cid = c_ },
            .bytes => |b| .{ .bytes = b },
        };
    }

    /// An event's or a message's `beef` field read back.
    pub fn of(v: ?Value) ?Input {
        const x = v orelse return null;
        return switch (x) {
            .cid => |c_| .{ .record = c_ },
            .bytes => |b| .{ .bytes = b },
            else => null,
        };
    }
};

/// The route's half (a call): verify, judge. `st` is the overlay's state over the call's store;
/// `topics` are the requested ones this overlay serves; `in` is the call's input (`defaults`,
/// `programs`); `beef` is the BEEF (its pointer record, or bytes with no framing); `source` is
/// carried on the event (#74). A pointer record is read, not decoded again, and its BUMPs are not
/// proven again (the door did, #121); bytes are decoded once (#50) and checked.
pub fn route(a: Allocator, caller: calls.Caller, st: *State, in: Value, beef: Input, topics: []const []const u8, off: ?[]const u8, source: ?Value) !Routed {
    const d = switch (beef) {
        .record => |rc| state.decodeRecord(a, st.store, rc),
        .bytes => |b| state.decode(a, st.store, b),
    } catch |e| return .{ .refused = @errorName(e) };
    const sub = state.verifyDecoded(a, st.store, st.ch, d, beef == .record) catch |e| switch (e) {
        // A known-rejected transaction is a valid request that admits nothing (200, empty STEAK).
        error.TransactionRejected => return .{ .nothing = @errorName(e) },
        else => return .{ .refused = @errorName(e) },
    };
    if (try st.isPending(sub.txid)) return .{ .pending = sub.txid };
    const served = try calls.configObject(a, in, "overlayTopics");
    var dupes: usize = 0;
    var judged: std.ArrayList(Judged) = .empty;
    var why: std.ArrayList(u8) = .empty;
    for (topics) |t| {
        if (try st.isApplied(t, sub.txid)) {
            dupes += 1;
            continue;
        }
        const previous = try st.previousCoins(t, sub.tx);
        const prog = (try calls.configuredProgram(in, served, t)) orelse continue;
        const ins = identify(a, caller, prog, t, sub, previous, off) catch |e| {
            try why.print(a, "{s}{s}: {s}", .{ if (why.items.len > 0) "; " else "", t, @errorName(e) });
            continue;
        };
        state.check(sub.tx, previous, ins) catch |e| {
            try why.print(a, "{s}{s}: {s}", .{ if (why.items.len > 0) "; " else "", t, @errorName(e) });
            continue;
        };
        if (state.takes(previous, ins)) try judged.append(a, .{ .topic = t, .previous = previous, .ins = ins });
    }
    if (dupes == topics.len or (judged.items.len == 0 and dupes > 0)) return .{ .unchanged = sub.txid };
    if (judged.items.len == 0) return .{ .nothing = if (why.items.len > 0) why.items else "NotAdmitted: no topic admitted an output or consumed a previous coin" };
    return .{ .admit = .{ .event = try event(a, sub.txid, beef, judged.items, off, source), .txid = sub.txid } };
}

/// The submit event: the BEEF (its pointer record's link, or bytes), the judgements, the off-chain values, the source.
pub fn event(a: Allocator, txid: [32]u8, beef: Input, judged: []const Judged, off: ?[]const u8, source: ?Value) !Value {
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
        .{ .key = "txid", .value = .{ .text = try a.dupe(u8, &c.header.toHex(txid)) } },
        .{ .key = "beef", .value = beef.value() },
        .{ .key = "topics", .value = .{ .array = topics } },
    });
    if (off) |o| try es.append(a, .{ .key = "offChainValues", .value = .{ .bytes = o } });
    if (source) |src| try es.append(a, .{ .key = "source", .value = src });
    return .{ .map = es.items };
}

/// The event's transaction.
pub fn txidOf(ev: Value) ![32]u8 {
    return c.header.fromHex(ev.getText("txid") orelse return error.BadEvent) catch error.BadEvent;
}

// ---------------------------------------------------------------- the threads

/// Messages to the instance itself (skein #79: looped back; another app of the instance takes
/// them as from the instance): vm.zig's `send` to `self.identity`; a test's records them.
pub const Wire = struct {
    ctx: *anyopaque,
    /// `body` to the instance itself in `box` → the message's CID.
    sendFn: *const fn (ctx: *anyopaque, a: Allocator, box: []const u8, body: Value) anyerror![]const u8,

    pub fn send(self: Wire, a: Allocator, box: []const u8, body: Value) ![]const u8 {
        return self.sendFn(self.ctx, a, box, body);
    }
};

/// What a step works with.
pub const Ctx = struct {
    a: Allocator,
    caller: calls.Caller,
    wire: Wire,
    /// The gossip out (none: a host without libp2p).
    out: ?gossip.Out = null,
    st: *State,
    /// The configuration (calls.zig: `defaults.overlay*`, `programs`, `app`).
    in: Value,
    /// The thread this step is of (the submission's: a resubmission's client waits on it).
    thread: ?[]const u8 = null,
};

/// The ingest message's body: `{fn: "ingest", args: {beef}}` — the pointer record's CID (#121), or bytes.
pub fn ingestBody(a: Allocator, beef: Input) !Value {
    return .{ .map = try a.dupe(cbor.Entry, &.{
        .{ .key = "fn", .value = .{ .text = "ingest" } },
        .{ .key = "args", .value = .{ .map = try a.dupe(cbor.Entry, &.{.{ .key = "beef", .value = beef.value() }}) } },
    }) };
}

/// The watch message's body: `{fn: "watch", args: {txid (hex), ingest: <the ingest message>}}`.
pub fn watchBody(a: Allocator, txid: [32]u8, ingest: []const u8) !Value {
    return .{ .map = try a.dupe(cbor.Entry, &.{
        .{ .key = "fn", .value = .{ .text = "watch" } },
        .{ .key = "args", .value = .{ .map = try a.dupe(cbor.Entry, &.{
            .{ .key = "txid", .value = .{ .text = try a.dupe(u8, &c.header.toHex(txid)) } },
            .{ .key = "ingest", .value = .{ .cid = ingest } },
        }) } },
    }) };
}

/// The submission thread's first step: the BEEF to the chain app (the ingest message), the
/// submission pending. → the ingest message's CID: the thread awaits it.
pub fn begin(cx: Ctx, ev: Value) ![]const u8 {
    const txid = try txidOf(ev);
    const beef = Input.of(ev.get("beef")) orelse return error.BadEvent;
    const m = try cx.wire.send(cx.a, chain_box, try ingestBody(cx.a, beef));
    try cx.st.putPending(txid, cx.thread, m);
    return m;
}

/// What the chain app said: an answer body `{fn, request, replyTo, result: {txid, tx, state, …}}`
/// or `{…, error: {code, message}}`.
pub const Answer = union(enum) {
    accepted,
    proven: struct { via: ?[]const u8 = null },
    rejected: []const u8,
    failed: []const u8,
    /// Anything else (a state this engine does not act on): the thread awaits on.
    other,
};

pub fn answerOf(body: Value) Answer {
    if (body.get("error")) |e| return .{ .failed = e.getText("message") orelse e.getText("code") orelse "failed" };
    const r = body.get("result") orelse return .other;
    const s = r.getText("state") orelse return .other;
    if (eql(u8, s, "accepted")) return .accepted;
    if (eql(u8, s, "proven")) return .{ .proven = .{ .via = r.getText("via") } };
    if (eql(u8, s, "rejected")) return .{ .rejected = r.getText("reason") orelse "rejected" };
    return .other;
}

/// What a step of a submission's (or a watch's) thread came to.
pub const Stepped = struct {
    txid: [32]u8,
    /// The answer acted on (its state), for the result record.
    heard: []const u8 = "",
    /// Whether this step admitted the submission (recorded its judgements, called the hooks).
    admitted: bool = false,
    /// The event's topics and each one's judgement as recorded, when admitted.
    topics: []const []const u8 = &.{},
    applied: []const state.Applied = &.{},
    /// The records the judgements wrote: the step keeps them.
    records: []const []const u8 = &.{},
    /// The judgements a rejection removed.
    unapplied: []const state.Unapplied = &.{},
    /// The watch message this step sent (admitted on `accepted`).
    watch: ?[]const u8 = null,
    published: usize = 0,
    /// The thread is done: it finishes (else it awaits the ingest message again).
    done: bool = true,
};

/// The submission thread stepped with the chain app's answer to its ingest message `ingest`.
pub fn answered(cx: Ctx, ev: Value, ingest: []const u8, ans: Answer) !Stepped {
    const txid = try txidOf(ev);
    var out = Stepped{ .txid = txid, .heard = @tagName(ans) };
    const pending = try cx.st.isPending(txid);
    switch (ans) {
        .accepted, .proven => {
            if (!pending) return out; // admitted by another submission's thread
            try cx.st.dropPending(txid);
            try admit(cx, ev, &out);
            if (cx.out) |o| out.published += try gossip.admitted(cx.a, o, cx.st, cx.in, ev, txid, out.topics, out.applied);
            switch (ans) {
                .proven => |p| if (p.via == null) if (cx.out) |o| {
                    out.published += try gossip.proven(cx.a, o, cx.st, cx.in, txid);
                },
                // Admitted on its acceptance: what the chain app says later goes to a watch.
                else => out.watch = try cx.wire.send(cx.a, calls.appOf(cx.in), try watchBody(cx.a, txid, ingest)),
            }
        },
        .rejected => {
            if (pending) try cx.st.dropPending(txid);
            try unwind(cx, txid, &out);
        },
        .failed => if (pending) try cx.st.dropPending(txid),
        .other => out.done = false,
    }
    return out;
}

/// The watch thread's first step: what the chain state says now (proven, rejected) is acted on at
/// once; else it awaits the ingest message's answers (`done` false).
pub fn watchStart(cx: Ctx, txid: [32]u8) !Stepped {
    var out = Stepped{ .txid = txid };
    switch (try cx.st.ch.status(txid)) {
        .proven => {
            out.heard = "proven";
            if (cx.out) |o| out.published += try gossip.proven(cx.a, o, cx.st, cx.in, txid);
        },
        .rejected => {
            out.heard = "rejected";
            try unwind(cx, txid, &out);
        },
        .unproven => out.done = false,
    }
    return out;
}

/// The watch thread stepped with a later answer.
pub fn watched(cx: Ctx, txid: [32]u8, ans: Answer) !Stepped {
    var out = Stepped{ .txid = txid, .heard = @tagName(ans) };
    switch (ans) {
        .proven => |p| if (p.via == null) if (cx.out) |o| {
            out.published += try gossip.proven(cx.a, o, cx.st, cx.in, txid);
        },
        .rejected => try unwind(cx, txid, &out),
        .failed => {},
        .accepted, .other => out.done = false,
    }
    return out;
}

/// Rejected: each served topic's judgement of it removed, their lookup services told.
fn unwind(cx: Ctx, txid: [32]u8, out: *Stepped) !void {
    out.unapplied = try cx.st.unapply(try calls.servedTopics(cx.a, cx.in), txid);
    try calls.hookRejected(cx.a, cx.caller, cx.in, out.unapplied);
}

/// The admission: each topic's judgement the event carries recorded (`applied`, the
/// admittances), and the listening lookup services' hooks called (`admitted`, then `spent` for
/// each previous coin consumed). The transaction is the chain app's now (it put and kept the
/// blocks). A judgement is taken again only if the topic's previous coins moved since the route.
fn admit(cx: Ctx, ev: Value, out: *Stepped) !void {
    const a = cx.a;
    const st = cx.st;
    const sub = try state.subjectOf(a, st.store, out.txid);
    const served = try calls.configObject(a, cx.in, "overlayTopics");
    const js = ev.getArray("topics") orelse return error.BadEvent;
    const topics = try a.alloc([]const u8, js.len);
    const applied = try a.alloc(state.Applied, js.len);
    var records: std.ArrayList([]const u8) = .empty;
    for (js, topics, applied) |j, *t, *ap| {
        t.* = j.getText("topic") orelse return error.BadEvent;
        ap.* = .{};
        const previous = try st.previousCoins(t.*, sub.tx);
        const ins: topic_mod.Instructions = if (std.mem.eql(u32, previous, try uintList(a, j.get("previousCoins"))))
            .{ .outputs_to_admit = try uintList(a, j.get("outputsToAdmit")), .coins_to_retain = try uintList(a, j.get("coinsToRetain")) }
        else blk: {
            const prog = (try calls.configuredProgram(cx.in, served, t.*)) orelse continue;
            break :blk identify(a, cx.caller, prog, t.*, sub, previous, ev.getBytes("offChainValues")) catch continue;
        };
        ap.* = st.apply(sub, t.*, previous, ins) catch |e| switch (e) {
            error.BadInstructions => continue,
            else => return e,
        };
        if (ap.records.len == 0) continue;
        try records.appendSlice(a, ap.records);
        try calls.hookAdmitted(a, cx.caller, cx.in, t.*, sub, previous, ap.*);
    }
    out.topics = topics;
    out.applied = applied;
    out.records = records.items;
    out.admitted = true;
}
