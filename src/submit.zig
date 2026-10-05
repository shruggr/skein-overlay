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
//! skein-overlay#1: the route walks the BEEF oldest first and judges every
//! transaction before the subject too; each one a topic takes (or a paused
//! submission wants) is an item, ingested on its own and admitted, in order,
//! on its own answer. A BEEF lacking a parent (neither in it nor held) is
//! **paused**, however it came: pending with the parents it waits on, and a
//! want per (parent, topic, peer?) — the event `{event: "want", txid, topic,
//! peer?}` (shruggr/skein#112) — `peer` each peer that announced it (its
//! publisher, the peers whose `-admit` for it was seen, more as admits
//! arrive) or something needing it, the host asking that peer on a direct
//! stream; no peer (a submission by message or HTTP): the host asks peers
//! from its mesh for the topic. When the chain app answers for a wanted
//! parent, every want for it is removed and the thread sends the app itself
//! `{fn: "resume", args: {txid}}`; the paused submission is routed again
//! (`resumed`): its wants cleared, and recorded again for what it still
//! lacks. Each want that ends is cleared by the event `{event: "unwant",
//! txid, topic, peer?}` in the step that ends it (`State.wantEvents`).
//!
//! shruggr/skein#112 (0.7.2): a submission is a message, `{fn: "submit",
//! args: {beef, topics, offChainValues?}}`, into a box a row routes to the
//! engine (`received`); POST /submit carries the same message. Its answers go
//! to the sender, in the box it came in (skein docs/APPS.md §4: `{fn:
//! "submit", request, replyTo, result}`): **admitted** with status `pending`
//! (the chain app's `accepted`; `proven` when admitted at its proof), the
//! STEAK per topic; then **every proof** (`proven`, a reorg's proof another);
//! or **rejected**. A pause is internal: the submitter hears nothing of it.
//!
//! The submit event (box `<app>` from the libp2p route; or the args of the
//! thread a submission launches):
//!
//!   {kind: "submit", txid (hex), beef: <the pointer record> | bytes (the BEEF as received, the off-chain framing taken off),
//!    topics: [{topic, previousCoins, outputsToAdmit, coinsToRetain}] (the subject's),
//!    earlier?: [{txid, topics}] (the items before it, oldest first), wanted?: true,
//!    requested?: [topic], waiting?: [txid hex] (paused), offChainValues?: bytes,
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
    /// A valid transaction no served topic admitted: answered `rejected` (shruggr/skein#112); the reasons.
    nothing: []const u8,
    /// Every served topic judged it before (a dupe): nothing new; the answer is its judgements, from the state.
    unchanged: [32]u8,
    /// Handed to the chain app, nothing admitted yet: a resubmission adds nothing; the answer is read from the state.
    pending: [32]u8,
    /// Parents neither in the BEEF nor held by the chain app (skein-overlay#1): the event of a
    /// paused submission (its thread notes it pending, `waiting` on them, and records the wants).
    paused: struct { event: Value, txid: [32]u8, waiting: []const [32]u8 },
    /// The event to admit (the topics that were dupes are answered from their `applied` records).
    admit: struct { event: Value, txid: [32]u8 },
};

/// One transaction of a submission a topic took (or a paused submission wants: no judgements),
/// in the walk's order (skein-overlay#1): each is ingested on its own and admitted on its own answer.
pub const Item = struct { txid: [32]u8, judged: []const Judged, subject: bool };

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

/// The route's half (a call; a `resume` step too): verify, judge. `st` is the overlay's state over
/// the call's store; `topics` are the requested ones this overlay serves; `in` is the call's input
/// (`defaults`, `programs`); `beef` is the BEEF (its pointer record, or bytes with no framing);
/// `source` is carried on the event (#74). A pointer record is read, not decoded again, and its
/// BUMPs are not proven again (the door did, #121); bytes are decoded once (#50) and checked.
///
/// skein-overlay#1: a BEEF with parents neither in it nor held by the chain app (`missingParents`)
/// is **paused**, judged by nothing yet, however it came (shruggr/skein#112). Otherwise the BEEF is walked oldest first, up to and
/// including the subject: each transaction every requested topic has not judged, and that is not
/// pending in a submission of its own, is judged by each such topic, with the previous coins it
/// would have once the transactions before it are admitted (`previousCoinsWith`: the outputs the
/// topic took earlier in the walk count as live). A transaction a topic takes is an item of the
/// event; so is one a paused submission wants, judged or not, so that the chain app holds it.
pub fn route(a: Allocator, caller: calls.Caller, st: *State, in: Value, beef: Input, topics: []const []const u8, off: ?[]const u8, source: ?Value) !Routed {
    const d = switch (beef) {
        .record => |rc| state.decodeRecord(a, st.store, rc),
        .bytes => |b| state.decode(a, st.store, b),
    } catch |e| return .{ .refused = @errorName(e) };
    const missing = state.missingParents(a, st.ch, d) catch |e| return .{ .refused = @errorName(e) };
    if (missing.len > 0 and topics.len > 0) {
        if (try st.isPending(d.subject) and !(try st.isPaused(d.subject))) return .{ .pending = d.subject };
        var all = true;
        for (topics) |t| all = all and try st.isApplied(t, d.subject);
        if (all) return .{ .unchanged = d.subject };
        return .{ .paused = .{ .event = try pausedEvent(a, d.subject, beef, topics, missing, off, source), .txid = d.subject, .waiting = missing } };
    }
    const sub = state.verifyDecoded(a, st.store, st.ch, d, beef == .record) catch |e| switch (e) {
        // A known-rejected transaction is a valid request that admits nothing (answered `rejected`).
        error.TransactionRejected => return .{ .nothing = @errorName(e) },
        else => return .{ .refused = @errorName(e) },
    };
    if (try st.isPending(sub.txid) and !(try st.isPaused(sub.txid))) return .{ .pending = sub.txid };
    const served = try calls.configObject(a, in, "overlayTopics");
    var dupes: usize = 0;
    for (topics) |t| {
        if (try st.isApplied(t, sub.txid)) dupes += 1;
    }
    if (dupes == topics.len) return .{ .unchanged = sub.txid };
    // The outputs each topic took earlier in the walk.
    const walked = try a.alloc(std.ArrayList([36]u8), topics.len);
    for (walked) |*w| w.* = .empty;
    var items: std.ArrayList(Item) = .empty;
    var why: std.ArrayList(u8) = .empty;
    for (d.txs) |dt| {
        const is_subject = std.mem.eql(u8, &dt.txid, &sub.txid);
        if (!is_subject and try st.isPending(dt.txid)) continue; // its own submission's
        const tx = if (is_subject) sub else try state.subjectOf(a, st.store, dt.txid);
        var judged: std.ArrayList(Judged) = .empty;
        for (topics, walked) |t, *w| {
            if (try st.isApplied(t, dt.txid)) continue;
            const prog = (try calls.configuredProgram(in, served, t)) orelse continue;
            const previous = try st.previousCoinsWith(t, tx.tx, w.items);
            const ins = identify(a, caller, prog, t, tx, previous, if (is_subject) off else null) catch |e| {
                if (is_subject) try why.print(a, "{s}{s}: {s}", .{ if (why.items.len > 0) "; " else "", t, @errorName(e) });
                continue;
            };
            state.check(tx.tx, previous, ins) catch |e| {
                if (is_subject) try why.print(a, "{s}{s}: {s}", .{ if (why.items.len > 0) "; " else "", t, @errorName(e) });
                continue;
            };
            if (!state.takes(previous, ins)) continue;
            try judged.append(a, .{ .topic = t, .previous = previous, .ins = ins });
            for (ins.outputs_to_admit) |o| try w.append(a, c.store.outpointKey(dt.txid, o));
        }
        if (judged.items.len > 0 or try st.isWanted(dt.txid))
            try items.append(a, .{ .txid = dt.txid, .judged = judged.items, .subject = is_subject });
        if (is_subject) break;
    }
    if (items.items.len == 0) {
        if (dupes > 0) return .{ .unchanged = sub.txid };
        return .{ .nothing = if (why.items.len > 0) why.items else "NotAdmitted: no topic admitted an output or consumed a previous coin" };
    }
    return .{ .admit = .{ .event = try event(a, sub.txid, beef, items.items, off, source), .txid = sub.txid } };
}

/// The libp2p peer a submission came from (its source's `from`), or null (HTTP, a host's own).
pub fn peerOf(source: ?Value) ?[]const u8 {
    const src = source orelse return null;
    if (!eql(u8, src.getText("transport") orelse "", "libp2p")) return null;
    const f = src.getBytes("from") orelse return null;
    return if (f.len > 0) f else null;
}

/// The topics a BEEF answering a want is routed with (skein-overlay#1, the libp2p stream): those
/// the paused submissions waiting on its subject requested, each once, in their order. None: no
/// one wants it.
pub fn wantedTopics(a: Allocator, st: *State, txid: [32]u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (try st.waitersOf(txid)) |w| {
        const rec = (try st.pendingRecord(w)) orelse continue;
        const ev = try st.store.getValue(a, rec.getCid("event") orelse continue);
        outer: for (ev.getArray("requested") orelse &.{}) |r| {
            const t = if (r == .text) r.text else continue;
            for (out.items) |x| if (eql(u8, x, t)) continue :outer;
            try out.append(a, t);
        }
    }
    return out.items;
}

fn judgements(a: Allocator, judged: []const Judged) ![]Value {
    const out = try a.alloc(Value, judged.len);
    for (judged, out) |j, *o| o.* = .{ .map = try a.dupe(cbor.Entry, &.{
        .{ .key = "topic", .value = .{ .text = j.topic } },
        .{ .key = "previousCoins", .value = .{ .array = try uints(a, j.previous) } },
        .{ .key = "outputsToAdmit", .value = .{ .array = try uints(a, j.ins.outputs_to_admit) } },
        .{ .key = "coinsToRetain", .value = .{ .array = try uints(a, j.ins.coins_to_retain) } },
    }) };
    return out;
}

fn hexText(a: Allocator, txid: [32]u8) !Value {
    return .{ .text = try a.dupe(u8, &c.header.toHex(txid)) };
}

/// The submit event: the subject's txid, the BEEF (its pointer record's link, or bytes), the
/// subject's judgements (`topics`: none when no topic took the subject), the transactions before
/// it the walk took or a paused submission wants (`earlier`, oldest first, each `{txid, topics}`;
/// absent when none), `wanted: true` when no topic took the subject but a paused submission wants
/// it (it is ingested all the same), the off-chain values, the source.
pub fn event(a: Allocator, txid: [32]u8, beef: Input, items: []const Item, off: ?[]const u8, source: ?Value) !Value {
    var subject: []const Judged = &.{};
    var wanted = false;
    var earlier: std.ArrayList(Value) = .empty;
    for (items) |it| {
        if (it.subject) {
            subject = it.judged;
            wanted = it.judged.len == 0;
            continue;
        }
        try earlier.append(a, .{ .map = try a.dupe(cbor.Entry, &.{
            .{ .key = "txid", .value = try hexText(a, it.txid) },
            .{ .key = "topics", .value = .{ .array = try judgements(a, it.judged) } },
        }) });
    }
    var es: std.ArrayList(cbor.Entry) = .empty;
    try es.appendSlice(a, &.{
        .{ .key = "kind", .value = .{ .text = "submit" } },
        .{ .key = "txid", .value = try hexText(a, txid) },
        .{ .key = "beef", .value = beef.value() },
        .{ .key = "topics", .value = .{ .array = try judgements(a, subject) } },
    });
    if (earlier.items.len > 0) try es.append(a, .{ .key = "earlier", .value = .{ .array = earlier.items } });
    if (wanted) try es.append(a, .{ .key = "wanted", .value = .{ .boolean = true } });
    if (off) |o| try es.append(a, .{ .key = "offChainValues", .value = .{ .bytes = o } });
    if (source) |src| try es.append(a, .{ .key = "source", .value = src });
    return .{ .map = es.items };
}

/// A paused submission's event (skein-overlay#1): the subject, the BEEF, no judgement, the topics
/// requested (`requested`: routed again with them), the parents it waits on (`waiting`, hex).
fn pausedEvent(a: Allocator, txid: [32]u8, beef: Input, topics: []const []const u8, waiting: []const [32]u8, off: ?[]const u8, source: ?Value) !Value {
    const req = try a.alloc(Value, topics.len);
    for (topics, req) |t, *o| o.* = .{ .text = t };
    const ws = try a.alloc(Value, waiting.len);
    for (waiting, ws) |w, *o| o.* = try hexText(a, w);
    var es: std.ArrayList(cbor.Entry) = .empty;
    try es.appendSlice(a, &.{
        .{ .key = "kind", .value = .{ .text = "submit" } },
        .{ .key = "txid", .value = try hexText(a, txid) },
        .{ .key = "beef", .value = beef.value() },
        .{ .key = "topics", .value = .{ .array = &.{} } },
        .{ .key = "requested", .value = .{ .array = req } },
        .{ .key = "waiting", .value = .{ .array = ws } },
    });
    if (off) |o| try es.append(a, .{ .key = "offChainValues", .value = .{ .bytes = o } });
    if (source) |src| try es.append(a, .{ .key = "source", .value = src });
    return .{ .map = es.items };
}

/// An event's items, in the walk's order: `earlier`, then the subject when a topic took it (or it is `wanted`).
pub const EventItem = struct { txid: [32]u8, topics: []const Value, subject: bool };

pub fn itemsOf(a: Allocator, ev: Value) ![]EventItem {
    var out: std.ArrayList(EventItem) = .empty;
    for (ev.getArray("earlier") orelse &.{}) |e| try out.append(a, .{
        .txid = c.header.fromHex(e.getText("txid") orelse return error.BadEvent) catch return error.BadEvent,
        .topics = e.getArray("topics") orelse return error.BadEvent,
        .subject = false,
    });
    const js = ev.getArray("topics") orelse return error.BadEvent;
    if (js.len > 0 or (ev.getBool("wanted") orelse false)) try out.append(a, .{ .txid = try txidOf(ev), .topics = js, .subject = true });
    return out.items;
}

fn hexList(a: Allocator, v: ?Value) ![][32]u8 {
    const x_ = v orelse return &.{};
    const xs = if (x_ == .array) x_.array else return error.BadEvent;
    const out = try a.alloc([32]u8, xs.len);
    for (xs, out) |x, *o| o.* = c.header.fromHex(if (x == .text) x.text else return error.BadEvent) catch return error.BadEvent;
    return out;
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
    /// An answer to a submitter (shruggr/skein#112): `body` to `to` in `box`, sent when a message
    /// can reach `to` (the instance itself, an address-book entry), else in the step's result only.
    answerFn: ?*const fn (ctx: *anyopaque, a: Allocator, to: []const u8, box: []const u8, body: Value) anyerror!void = null,

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
    /// The thread this step is of (the submission's).
    thread: ?[]const u8 = null,
    /// The peers' admits (`<app>/gossip`, read only): whom a paused submission's parents are
    /// wanted from beside its publisher (shruggr/skein#112). None: no admits seen.
    gossip: ?*gossip.State = null,
};

/// The ingest message's body: `{fn: "ingest", args: {beef}}` — the pointer record's CID (#121), or bytes.
pub fn ingestBody(a: Allocator, beef: Input) !Value {
    return .{ .map = try a.dupe(cbor.Entry, &.{
        .{ .key = "fn", .value = .{ .text = "ingest" } },
        .{ .key = "args", .value = .{ .map = try a.dupe(cbor.Entry, &.{.{ .key = "beef", .value = beef.value() }}) } },
    }) };
}

/// A watch (the message `{fn: "watch", args}` to the app itself): the transaction, the ingest
/// message whose later answers it awaits, the submission's `source` when the submission has a
/// submitter to answer (shruggr/skein#112), and `proven` when a proof was relayed already (the
/// watch then awaits a later proof only: a reorg's).
pub const Watch = struct { txid: [32]u8, ingest: []const u8, source: ?Value = null, proven: bool = false };

/// The watch message's body: `{fn: "watch", args: {txid (hex), ingest: <the ingest message>, source?, proven?: true}}`.
pub fn watchBody(a: Allocator, w: Watch) !Value {
    var es: std.ArrayList(cbor.Entry) = .empty;
    try es.appendSlice(a, &.{
        .{ .key = "txid", .value = try hexText(a, w.txid) },
        .{ .key = "ingest", .value = .{ .cid = w.ingest } },
    });
    if (w.source) |src| try es.append(a, .{ .key = "source", .value = src });
    if (w.proven) try es.append(a, .{ .key = "proven", .value = .{ .boolean = true } });
    return .{ .map = try a.dupe(cbor.Entry, &.{
        .{ .key = "fn", .value = .{ .text = "watch" } },
        .{ .key = "args", .value = .{ .map = es.items } },
    }) };
}

/// A watch message's args read back.
pub fn watchOf(args: Value) !Watch {
    return .{
        .txid = c.header.fromHex(args.getText("txid") orelse return error.BadInput) catch return error.BadInput,
        .ingest = args.getCid("ingest") orelse return error.BadInput,
        .source = args.get("source"),
        .proven = args.getBool("proven") orelse false,
    };
}

/// The resume message's body (skein-overlay#1): `{fn: "resume", args: {txid (hex)}}` — a paused
/// submission, whose subject this is, to be routed again: a parent it waited on has come.
pub fn resumeBody(a: Allocator, txid: [32]u8) !Value {
    return .{ .map = try a.dupe(cbor.Entry, &.{
        .{ .key = "fn", .value = .{ .text = "resume" } },
        .{ .key = "args", .value = .{ .map = try a.dupe(cbor.Entry, &.{.{ .key = "txid", .value = try hexText(a, txid) }}) } },
    }) };
}

/// What a submission thread's first step did.
pub const Begun = struct {
    /// The ingest messages sent, oldest first (the subject's last): the thread awaits them.
    ingests: []const []const u8 = &.{},
    /// Paused: the parents it waits on; the step's `want` / `unwant` events (`State.wantEvents`).
    paused: bool = false,
    waiting: []const [32]u8 = &.{},
    wants: []const Value = &.{},
};

/// The submission thread's first step. Each item of the event (oldest first) to the chain app — an
/// ingest message of its own: the subject's carries the submission's BEEF as handed, each earlier
/// one its Atomic BEEF cut from it (`state.atomicFor`) — and noted pending. A paused submission
/// (`waiting`) is noted pending with its event and the parents it waits on, and its wants recorded
/// (`pause`); nothing goes to the chain app. A paused submission taken whole now has its wants cleared.
pub fn begin(cx: Ctx, ev: Value) !Begun {
    const a = cx.a;
    const txid = try txidOf(ev);
    if (ev.get("waiting") != null) return pause(cx, ev, txid);
    try unwantAll(cx.st, txid);
    const beef = Input.of(ev.get("beef")) orelse return error.BadEvent;
    const its = try itemsOf(a, ev);
    var bytes: ?[]const u8 = null;
    var ms: std.ArrayList([]const u8) = .empty;
    var has_subject = false;
    for (its) |it| {
        has_subject = has_subject or it.subject;
        const b: Input = if (it.subject) beef else blk: {
            if (bytes == null) bytes = switch (beef) {
                .record => |rc| try c.record.beefOf(a, cx.st.store, rc),
                .bytes => |x| x,
            };
            break :blk .{ .bytes = try state.atomicFor(a, bytes.?, it.txid) };
        };
        const m = try cx.wire.send(a, chain_box, try ingestBody(a, b));
        try cx.st.putPending(it.txid, .{ .thread = cx.thread, .submission = txid, .ingest = m });
        try ms.append(a, m);
    }
    // A paused submission whose subject no topic takes now: no longer paused.
    if (!has_subject and try cx.st.isPaused(txid)) try unpause(cx.st, txid);
    return .{ .ingests = ms.items, .wants = try cx.st.wantEvents() };
}

/// A paused submission's wants (shruggr/skein#112): one per (parent it waits on, topic requested,
/// peer). The peers: every one that announced it — the event's `from`, the peers whose `-admit`
/// for it was seen (`<app>/gossip`), the peers its wants stood against already (an earlier
/// announcement; a resume) — or something needing it (the peers its own subject is wanted from).
/// No peer (a submission by message or HTTP, or one whose wants had none): the want with no peer
/// too, the host asking its mesh for the topic. Its earlier wants are cleared first; the step's
/// events are the difference (`State.wantEvents`).
fn pause(cx: Ctx, ev: Value, txid: [32]u8) !Begun {
    const a = cx.a;
    const st = cx.st;
    const waiting = try hexList(a, ev.get("waiting"));
    const topics = try textList(a, ev.get("requested"));
    var peers: std.ArrayList([]const u8) = .empty;
    const own = peerOf(ev.get("source"));
    if (own) |p| try state.addPeer(a, &peers, p);
    if (cx.gossip) |g| for (topics) |t| for (try g.peersOf(t, txid)) |p| try state.addPeer(a, &peers, p);
    const before = try waitingOf(a, st, txid);
    const had = try st.peersOf(txid, before);
    for (had.peers) |p| try state.addPeer(a, &peers, p);
    for (try st.wantedFrom(txid)) |p| try state.addPeer(a, &peers, p);
    const none = own == null or had.none;
    try st.unwant(txid, before);
    const ec = try st.store.putValue(a, ev);
    try st.putPending(txid, .{ .thread = cx.thread, .waiting = waiting, .event = ec });
    for (waiting) |w| for (topics) |t| {
        if (none) try st.want(w, t, null, txid);
        for (peers.items) |p| try st.want(w, t, p, txid);
    };
    return .{ .paused = true, .waiting = waiting, .wants = try st.wantEvents() };
}

fn textList(a: Allocator, v: ?Value) ![]const []const u8 {
    const xs = (v orelse return &.{}).array;
    const out = try a.alloc([]const u8, xs.len);
    for (xs, out) |x, *o| o.* = if (x == .text) x.text else return error.BadEvent;
    return out;
}

/// A peer's `-admit` for `txid` under `topic` was seen (shruggr/skein#112, the `peer-admit` step):
/// if a submission of that subject is paused and requested the topic, its parents are wanted from
/// that peer too.
pub fn admitSeen(cx: Ctx, topic: []const u8, txid: [32]u8, peer: []const u8) !void {
    const rec = (try cx.st.pendingRecord(txid)) orelse return;
    if (rec.get("waiting") == null) return;
    const ev = try cx.st.store.getValue(cx.a, rec.getCid("event") orelse return error.BadState);
    for (try textList(cx.a, ev.get("requested"))) |t| {
        if (!eql(u8, t, topic)) continue;
        for (try hexList(cx.a, rec.get("waiting"))) |w| try cx.st.want(w, t, peer, txid);
    }
}

/// The parents a paused submission of this subject waits on (none: not paused).
fn waitingOf(a: Allocator, st: *State, txid: [32]u8) ![]const [32]u8 {
    const rec = (try st.pendingRecord(txid)) orelse return &.{};
    return hexList(a, rec.get("waiting"));
}

/// A paused submission's wants, all cleared (it is routed to something else now).
fn unwantAll(st: *State, txid: [32]u8) !void {
    const w = try waitingOf(st.arena, st, txid);
    if (w.len > 0) try st.unwant(txid, w);
}

/// The pause of this subject ended: its wants cleared, its pending record dropped.
fn unpause(st: *State, txid: [32]u8) !void {
    try unwantAll(st, txid);
    try st.dropPending(txid);
}

/// What the chain app said: an answer body `{fn, request, replyTo, result: {txid, tx, state, …}}`
/// or `{…, error: {code, message}}`.
pub const Answer = union(enum) {
    accepted,
    /// `result`: the chain app's (`block`, `height`): relayed to the submitter as its proof.
    proven: struct { via: ?[]const u8 = null, result: ?Value = null },
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
    if (eql(u8, s, "proven")) return .{ .proven = .{ .via = r.getText("via"), .result = r } };
    if (eql(u8, s, "rejected")) return .{ .rejected = r.getText("reason") orelse "rejected" };
    return .other;
}

// ---------------------------------------------------------------- answers to the submitter (shruggr/skein#112)

/// Whom a submission's answers go to: its `source`'s sender (a message's; an HTTP request's
/// session identity), in its box, about its request (the message, or the request record).
pub const Submitter = struct { to: []const u8, box: []const u8, request: []const u8 };

pub fn submitterOf(source: ?Value) ?Submitter {
    const src = source orelse return null;
    return .{
        .to = src.getBytes("sender") orelse return null,
        .box = src.getText("box") orelse return null,
        .request = src.getCid("request") orelse return null,
    };
}

/// An answer `{fn: "submit", request, replyTo, result}` (skein docs/APPS.md §4) to the submitter,
/// if the submission has one; the wire sends it when a message can reach it.
fn answerTo(cx: Ctx, source: ?Value, result: Value) !void {
    const sub = submitterOf(source) orelse return;
    const f = cx.wire.answerFn orelse return;
    try f(cx.wire.ctx, cx.a, sub.to, sub.box, try submitAnswer(cx.a, sub.request, .{ .result = result }));
}

/// The body of an answer to a submission: `{fn: "submit", request, replyTo, result | error}`.
pub fn submitAnswer(a: Allocator, request: []const u8, r: union(enum) { result: Value, err: Value }) !Value {
    return .{ .map = try a.dupe(cbor.Entry, &.{
        .{ .key = "fn", .value = .{ .text = "submit" } },
        .{ .key = "request", .value = .{ .cid = request } },
        .{ .key = "replyTo", .value = .{ .cid = request } },
        switch (r) {
            .result => |v| .{ .key = "result", .value = v },
            .err => |v| .{ .key = "error", .value = v },
        },
    }) };
}

fn steakEntry(a: Allocator, outs: []const u32, retain: []const u32, removed: []const u32) !Value {
    return .{ .map = try a.dupe(cbor.Entry, &.{
        .{ .key = "outputsToAdmit", .value = .{ .array = try uints(a, outs) } },
        .{ .key = "coinsToRetain", .value = .{ .array = try uints(a, retain) } },
        .{ .key = "coinsRemoved", .value = .{ .array = try uints(a, removed) } },
    }) };
}

/// **admitted**: `{txid, state: "admitted", status: "pending" | "proven", steak: {<topic>:
/// {outputsToAdmit, coinsToRetain, coinsRemoved}}}`.
fn admittedResult(a: Allocator, txid: [32]u8, status: []const u8, steak: []const cbor.Entry) !Value {
    return .{ .map = try a.dupe(cbor.Entry, &.{
        .{ .key = "txid", .value = try hexText(a, txid) },
        .{ .key = "state", .value = .{ .text = "admitted" } },
        .{ .key = "status", .value = .{ .text = status } },
        .{ .key = "steak", .value = .{ .map = try a.dupe(cbor.Entry, steak) } },
    }) };
}

fn answerAdmitted(cx: Ctx, source: ?Value, adm: Admission, status: []const u8) !void {
    if (submitterOf(source) == null) return;
    var steak: std.ArrayList(cbor.Entry) = .empty;
    for (adm.topics, adm.applied) |t, ap| try steak.append(cx.a, .{ .key = t, .value = try steakEntry(cx.a, ap.outputs_to_admit, ap.coins_to_retain, ap.coins_removed) });
    try answerTo(cx, source, try admittedResult(cx.a, adm.txid, status, steak.items));
}

/// A resubmission of a transaction every requested topic judged before: admitted, its STEAK from
/// the `applied` records (empty for a topic that took nothing), and its proof if it is proven.
fn answerJudged(cx: Ctx, source: ?Value, txid: [32]u8, topics: []const []const u8) !void {
    if (submitterOf(source) == null) return;
    const a = cx.a;
    var steak: std.ArrayList(cbor.Entry) = .empty;
    for (topics) |t| {
        const rec = (try cx.st.appliedRecord(t, txid)) orelse {
            try steak.append(a, .{ .key = t, .value = try steakEntry(a, &.{}, &.{}, &.{}) });
            continue;
        };
        try steak.append(a, .{ .key = t, .value = try steakEntry(a, try uintList(a, rec.get("outputsToAdmit")), try uintList(a, rec.get("coinsToRetain")), try uintList(a, rec.get("coinsRemoved"))) });
    }
    const proven = (try cx.st.ch.status(txid)) == .proven;
    try answerTo(cx, source, try admittedResult(a, txid, if (proven) "proven" else "pending", steak.items));
    if (proven) try answerProof(cx, source, txid, null);
}

/// **proven**: `{txid, state: "proven", block: <the header's CID>, height}` — the chain app's
/// answer's (`result`), else the chain state's proof. A reorg's proof is another, a different block.
fn answerProof(cx: Ctx, source: ?Value, txid: [32]u8, result: ?Value) !void {
    if (submitterOf(source) == null) return;
    const a = cx.a;
    var block: ?[]const u8 = null;
    var height: ?u64 = null;
    if (result) |r| {
        block = r.getCid("block");
        height = r.getUint("height");
    }
    if (block == null) if (try cx.st.ch.proofRecord(txid)) |pr| {
        block = pr.block;
        if (c.store.bitcoinHash(pr.block)) |h| if (try cx.st.ch.chain().heightOf(h)) |ht| {
            height = ht;
        };
    };
    var es: std.ArrayList(cbor.Entry) = .empty;
    try es.appendSlice(a, &.{
        .{ .key = "txid", .value = try hexText(a, txid) },
        .{ .key = "state", .value = .{ .text = "proven" } },
    });
    if (block) |b| try es.append(a, .{ .key = "block", .value = .{ .cid = b } });
    if (height) |h| try es.append(a, .{ .key = "height", .value = .{ .uint = h } });
    try answerTo(cx, source, .{ .map = es.items });
}

/// **rejected**: `{txid?, state: "rejected", reason}` (no txid: a BEEF that did not decode).
fn answerRejected(cx: Ctx, source: ?Value, txid: ?[32]u8, reason: []const u8) !void {
    if (submitterOf(source) == null) return;
    var es: std.ArrayList(cbor.Entry) = .empty;
    if (txid) |t| try es.append(cx.a, .{ .key = "txid", .value = try hexText(cx.a, t) });
    try es.appendSlice(cx.a, &.{
        .{ .key = "state", .value = .{ .text = "rejected" } },
        .{ .key = "reason", .value = .{ .text = reason } },
    });
    try answerTo(cx, source, .{ .map = es.items });
}

/// No topic took the subject (only transactions before it, or it is only wanted): the submitter
/// hears `rejected`, at once; the items go on.
const not_admitted = "NotAdmitted: no topic admitted an output or consumed a previous coin";

fn subjectTaken(ev: Value) bool {
    const js = ev.getArray("topics") orelse return false;
    return js.len > 0;
}

/// One transaction admitted in a step: its topics and each one's judgement as recorded.
pub const Admission = struct { txid: [32]u8, topics: []const []const u8, applied: []const state.Applied };

/// What a step of a submission's (or a watch's) thread came to.
pub const Stepped = struct {
    /// The transaction the answer was about (the subject's, when none of the submission's is).
    txid: [32]u8,
    /// The answer acted on (its state), for the result record.
    heard: []const u8 = "",
    /// Whether this step admitted a transaction (recorded its judgements, called the hooks).
    admitted: bool = false,
    /// The last transaction admitted: its topics and each one's judgement as recorded.
    topics: []const []const u8 = &.{},
    applied: []const state.Applied = &.{},
    /// Every transaction this step admitted, oldest first.
    admissions: []const Admission = &.{},
    /// The records the judgements wrote: the step keeps them.
    records: []const []const u8 = &.{},
    /// The judgements a rejection removed.
    unapplied: []const state.Unapplied = &.{},
    /// The watch messages this step sent (a transaction admitted on `accepted`, a proof relayed to a
    /// submitter); `watch` the last.
    watch: ?[]const u8 = null,
    watches: []const []const u8 = &.{},
    /// The resume messages this step sent (a paused submission's parent came, skein-overlay#1).
    resumes: []const []const u8 = &.{},
    published: usize = 0,
    /// The ingest messages the thread still awaits answers to.
    awaiting: []const []const u8 = &.{},
    /// The thread is done: it finishes (else it awaits `awaiting`).
    done: bool = true,
};

/// Whether a pending record is one of this submission's transactions handed to the chain app (not
/// a paused submission; a record written before skein-overlay#1 names no `submission`: its own).
fn ours(rec: Value, subject_hex: []const u8) bool {
    if (rec.getCid("ingest") == null) return false;
    return eql(u8, rec.getText("submission") orelse rec.getText("txid") orelse "", subject_hex);
}

fn pendingOf(rec: Value) !State.Pending {
    return .{
        .thread = rec.getCid("thread"),
        .submission = if (rec.getText("submission")) |h| c.header.fromHex(h) catch return error.BadState else null,
        .ingest = rec.getCid("ingest"),
        .heard = rec.getText("heard"),
        .via = rec.getText("via"),
    };
}

/// The submission thread stepped with the chain app's answer to one of its ingest messages,
/// `ingest` (skein-overlay#1: one per item). The answer is about that item's transaction:
/// accepted or proven is noted on its pending record (`heard`); rejected or an error answer
/// resolves it (nothing admitted). Then, oldest first, every item whose answer admits it is
/// admitted, up to the first still unanswered: an item is never admitted before the ones before it
/// in the BEEF are resolved, so its previous coins are those it was judged with. Each one admitted
/// or rejected resumes the paused submissions waiting on it. It finishes when none of its items is pending.
///
/// The submitter (shruggr/skein#112) hears about the subject: admitted (status `pending` on
/// `accepted`, `proven` at its proof, then the proof), or rejected (a rejection, an error answer).
/// A subject admitted with a submitter gets a watch either way: its later proofs (a reorg's) and
/// a later rejection reach the submitter through it.
pub fn answered(cx: Ctx, ev: Value, ingest: []const u8, ans: Answer) !Stepped {
    const a = cx.a;
    const st = cx.st;
    const subject = try txidOf(ev);
    const subject_hex = &c.header.toHex(subject);
    const source = ev.get("source");
    var out = Stepped{ .txid = subject, .heard = @tagName(ans) };
    const its = try itemsOf(a, ev);
    var resumes: std.ArrayList([]const u8) = .empty;
    var unapplied: std.ArrayList(state.Unapplied) = .empty;
    var proof_result: ?Value = null;
    for (its) |it| {
        const rec = (try st.pendingRecord(it.txid)) orelse continue;
        if (!ours(rec, subject_hex) or !eql(u8, rec.getCid("ingest").?, ingest)) continue;
        out.txid = it.txid;
        switch (ans) {
            .accepted, .proven => {
                var p = try pendingOf(rec);
                if (p.heard == null or ans == .proven) {
                    p.heard = @tagName(ans);
                    if (ans == .proven) p.via = ans.proven.via;
                    try st.putPending(it.txid, p);
                }
                if (ans == .proven and it.subject) proof_result = ans.proven.result;
            },
            .rejected => |why| {
                try st.dropPending(it.txid);
                const u = try st.unapply(try calls.servedTopics(a, cx.in), it.txid);
                try calls.hookRejected(a, cx.caller, cx.in, u);
                try unapplied.appendSlice(a, u);
                try resumeWaiters(cx, it.txid, &resumes);
                if (it.subject and subjectTaken(ev)) try answerRejected(cx, source, it.txid, why);
            },
            .failed => |why| {
                try st.dropPending(it.txid);
                if (it.subject and subjectTaken(ev)) try answerRejected(cx, source, it.txid, why);
            },
            .other => {},
        }
        break;
    }
    out.unapplied = unapplied.items;

    // Admit, oldest first, up to the first item the chain app has not answered for.
    var admissions: std.ArrayList(Admission) = .empty;
    var records: std.ArrayList([]const u8) = .empty;
    var watches: std.ArrayList([]const u8) = .empty;
    var beef_cid: ?[]const u8 = null;
    for (its) |it| {
        const rec = (try st.pendingRecord(it.txid)) orelse continue;
        if (!ours(rec, subject_hex)) continue;
        const heard = rec.getText("heard") orelse break;
        try st.dropPending(it.txid);
        if (beef_cid == null) beef_cid = try beefCid(cx, ev);
        const adm = try admitItem(cx, ev, it, beef_cid.?, &records);
        try admissions.append(a, adm);
        if (cx.out) |o| out.published += try gossip.admitted(a, o, st, cx.in, ev, it.txid, it.subject, adm.topics, adm.applied);
        const proven = eql(u8, heard, "proven");
        // The submitter's answers: the subject's, when a topic took it.
        const answering = it.subject and subjectTaken(ev) and submitterOf(source) != null;
        if (answering) {
            try answerAdmitted(cx, source, adm, if (proven) "proven" else "pending");
            if (proven) try answerProof(cx, source, it.txid, proof_result);
        }
        if (proven) {
            if (rec.getText("via") == null) if (cx.out) |o| {
                out.published += try gossip.proven(a, o, st, cx.in, it.txid);
            };
        }
        if (!proven or answering) {
            // Admitted on its acceptance: what the chain app says later goes to a watch; and a
            // submitter's later proofs (a reorg's) after one relayed.
            const w = try cx.wire.send(a, calls.appOf(cx.in), try watchBody(a, .{
                .txid = it.txid,
                .ingest = rec.getCid("ingest").?,
                .source = if (answering) source else null,
                .proven = proven,
            }));
            try watches.append(a, w);
        }
        try resumeWaiters(cx, it.txid, &resumes);
    }
    if (admissions.items.len > 0) {
        const last = admissions.items[admissions.items.len - 1];
        out.admitted = true;
        out.topics = last.topics;
        out.applied = last.applied;
    }
    out.admissions = admissions.items;
    out.records = records.items;
    out.watches = watches.items;
    if (watches.items.len > 0) out.watch = watches.items[watches.items.len - 1];
    out.resumes = resumes.items;

    var awaiting: std.ArrayList([]const u8) = .empty;
    for (its) |it| {
        const rec = (try st.pendingRecord(it.txid)) orelse continue;
        if (ours(rec, subject_hex)) try awaiting.append(a, rec.getCid("ingest").?);
    }
    out.awaiting = awaiting.items;
    out.done = awaiting.items.len == 0;
    return out;
}

/// `txid` has come (the chain app answered for it: admitted or rejected): each paused submission
/// waiting on it is sent a `resume` (box `<app>`, to the instance itself). Every want for it ends.
fn resumeWaiters(cx: Ctx, txid: [32]u8, out: *std.ArrayList([]const u8)) !void {
    for (try cx.st.takeWants(txid)) |w| {
        if (!(try cx.st.isPaused(w))) continue;
        try out.append(cx.a, try cx.wire.send(cx.a, calls.appOf(cx.in), try resumeBody(cx.a, w)));
    }
}

/// What routing a submission came to (a `resume`, a submission by message).
pub const Resumed = union(enum) {
    /// Not paused (any more), or pending already in a submission of its own: nothing to do.
    none,
    /// Missing parents: paused (again) (its wants recorded; the step's want / unwant events).
    paused: Begun,
    /// Whole: the submit event to launch the submission's thread on (a pause is dropped).
    launch: Value,
    /// Routed to nothing (refused, taken by no topic, judged before): a pause dropped; why. The
    /// submitter was answered.
    dropped: []const u8,
};

/// The route's outcome, acted on in a step (a `resume`, a submission by message): launch, pause,
/// or answer. Every outcome but a pause or a launch drops a pause of the subject.
fn settle(cx: Ctx, r: Routed, txid_: ?[32]u8, topics: []const []const u8, source: ?Value) !Resumed {
    switch (r) {
        .paused => |p| return .{ .paused = try begin(cx, p.event) },
        .admit => |x| {
            try unpauseIf(cx.st, x.txid);
            if (!subjectTaken(x.event)) try answerRejected(cx, source, x.txid, not_admitted);
            return .{ .launch = x.event };
        },
        .pending => return .none,
        .refused => |why| {
            if (txid_) |t| try unpauseIf(cx.st, t);
            try answerRejected(cx, source, txid_, why);
            return .{ .dropped = why };
        },
        .nothing => |why| {
            if (txid_) |t| try unpauseIf(cx.st, t);
            try answerRejected(cx, source, txid_, why);
            return .{ .dropped = why };
        },
        .unchanged => |t| {
            try unpauseIf(cx.st, t);
            try answerJudged(cx, source, t, topics);
            return .{ .dropped = "judged before" };
        },
    }
}

fn unpauseIf(st: *State, txid: [32]u8) !void {
    if (try st.isPaused(txid)) try unpause(st, txid);
}

/// A `resume` step: the paused submission of this subject routed again, as the route does, with
/// its BEEF, the topics requested, its off-chain values and source. Its wants are cleared; paused
/// again, they are recorded again for what it still lacks, against every peer that announced it or
/// something needing it by now.
pub fn resumed(cx: Ctx, txid: [32]u8) !Resumed {
    const a = cx.a;
    const rec = (try cx.st.pendingRecord(txid)) orelse return .none;
    if (rec.get("waiting") == null) return .none;
    const ev = try cx.st.store.getValue(a, rec.getCid("event") orelse return error.BadState);
    const beef = Input.of(ev.get("beef")) orelse return error.BadEvent;
    const topics = try textList(a, ev.get("requested"));
    const r = try route(a, cx.caller, cx.st, cx.in, beef, topics, ev.getBytes("offChainValues"), ev.get("source"));
    return settle(cx, r, txid, topics, ev.get("source"));
}

/// A submission by message (shruggr/skein#112): `{fn: "submit", args: {beef, topics,
/// offChainValues?}}` in a box a row routes to the engine — or POST /submit, which carries the same
/// message. `source` is `{transport, box, sender?, request}`: whom the answers go to. Routed as
/// any submission: whole, its thread is launched (`launch`); lacking parents, paused (the
/// submitter hears nothing of it); else answered at once (rejected; or, judged before, admitted).
/// A `bad-args` error answer for a body that is not that shape.
pub fn received(cx: Ctx, args: Value, source: Value) !Resumed {
    const a = cx.a;
    const beef = Input.of(args.get("beef")) orelse return badArgs(cx, source, "submit: want {beef: bytes, topics: [string], offChainValues?: bytes}");
    const tv = args.get("topics") orelse return badArgs(cx, source, "submit: want {beef, topics: [string]}");
    if (tv != .array) return badArgs(cx, source, "submit: topics is a list of strings");
    const requested = textList(a, tv) catch return badArgs(cx, source, "submit: topics is a list of strings");
    const topics = try servedOf(a, cx.in, requested);
    const r = try route(a, cx.caller, cx.st, cx.in, beef, topics, args.getBytes("offChainValues"), source);
    const txid: ?[32]u8 = switch (r) {
        .unchanged, .pending => |t| t,
        .paused => |p| p.txid,
        .admit => |x| x.txid,
        .refused, .nothing => null,
    };
    if (topics.len == 0) {
        try answerRejected(cx, source, txid, "no topic requested is served here");
        return .{ .dropped = "no topic requested is served here" };
    }
    return settle(cx, r, txid, topics, source);
}

fn badArgs(cx: Ctx, source: Value, why: []const u8) !Resumed {
    if (submitterOf(source)) |sub| if (cx.wire.answerFn) |f| try f(cx.wire.ctx, cx.a, sub.to, sub.box, try submitAnswer(cx.a, sub.request, .{ .err = .{ .map = try cx.a.dupe(cbor.Entry, &.{
        .{ .key = "code", .value = .{ .text = "bad-args" } },
        .{ .key = "message", .value = .{ .text = why } },
    }) } }));
    return .{ .dropped = why };
}

/// The requested topics this overlay serves, in request order, once each.
pub fn servedOf(a: Allocator, in: Value, requested: []const []const u8) ![]const []const u8 {
    const map = try calls.configObject(a, in, "overlayTopics");
    var out: std.ArrayList([]const u8) = .empty;
    outer: for (requested) |t| {
        if (!map.contains(t)) continue;
        for (out.items) |x| if (eql(u8, x, t)) continue :outer;
        try out.append(a, t);
    }
    return out.items;
}

/// The watch thread's first step: what the chain state says now (proven, rejected) is acted on at
/// once; else it awaits the ingest message's answers (`done` false). A watch after a relayed proof
/// (`proven`) awaits a later one only.
pub fn watchStart(cx: Ctx, w: Watch) !Stepped {
    var out = Stepped{ .txid = w.txid };
    switch (try cx.st.ch.status(w.txid)) {
        .proven => {
            if (w.proven) {
                out.done = false;
                return out;
            }
            out.heard = "proven";
            if (cx.out) |o| out.published += try gossip.proven(cx.a, o, cx.st, cx.in, w.txid);
            try proofHeard(cx, w, null, &out);
        },
        .rejected => {
            out.heard = "rejected";
            try unwind(cx, w.txid, &out);
            try answerRejected(cx, w.source, w.txid, try rejectionOf(cx, w.txid));
        },
        .unproven => out.done = false,
    }
    return out;
}

fn rejectionOf(cx: Ctx, txid: [32]u8) ![]const u8 {
    const sc = (try cx.st.ch.settlementCid(txid)) orelse return "rejected";
    return (try cx.st.store.getValue(cx.a, sc)).getText("reason") orelse "rejected";
}

/// A proof heard by a watch: relayed to the submitter, and — with one to answer — a new watch
/// (`proven`) for the next (a reorg's), as this one finishes.
fn proofHeard(cx: Ctx, w: Watch, result: ?Value, out: *Stepped) !void {
    if (submitterOf(w.source) == null) return;
    try answerProof(cx, w.source, w.txid, result);
    const m = try cx.wire.send(cx.a, calls.appOf(cx.in), try watchBody(cx.a, .{ .txid = w.txid, .ingest = w.ingest, .source = w.source, .proven = true }));
    out.watch = m;
    out.watches = try cx.a.dupe([]const u8, &.{m});
}

/// The watch thread stepped with a later answer.
pub fn watched(cx: Ctx, w: Watch, ans: Answer) !Stepped {
    var out = Stepped{ .txid = w.txid, .heard = @tagName(ans) };
    switch (ans) {
        .proven => |p| {
            // Published once per transaction (a reorg's proof is not published again).
            if (p.via == null and !w.proven) if (cx.out) |o| {
                out.published += try gossip.proven(cx.a, o, cx.st, cx.in, w.txid);
            };
            try proofHeard(cx, w, p.result, &out);
        },
        .rejected => |why| {
            try unwind(cx, w.txid, &out);
            try answerRejected(cx, w.source, w.txid, why);
        },
        .failed => |why| try answerRejected(cx, w.source, w.txid, why),
        .accepted, .other => out.done = false,
    }
    return out;
}

/// Rejected: each served topic's judgement of it removed, their lookup services told.
fn unwind(cx: Ctx, txid: [32]u8, out: *Stepped) !void {
    out.unapplied = try cx.st.unapply(try calls.servedTopics(cx.a, cx.in), txid);
    try calls.hookRejected(cx.a, cx.caller, cx.in, out.unapplied);
}

/// The submission's BEEF as handed, named by each `applied` record (for internalizing;
/// skein-overlay#3): its pointer record, or the raw block of the bytes.
fn beefCid(cx: Ctx, ev: Value) ![]const u8 {
    return switch (Input.of(ev.get("beef")) orelse return error.BadEvent) {
        .record => |rc| rc,
        .bytes => |b| try state.putRaw(cx.a, cx.st.store, b),
    };
}

/// The admission of one item: each topic's judgement recorded (`applied`, naming the submission's
/// BEEF; the admittances), and the listening lookup services' hooks called (`admitted`, then
/// `spent` for each previous coin consumed). The transaction is the chain app's now (it put and
/// kept the blocks). A judgement is taken again only if the topic's previous coins moved since the
/// route.
fn admitItem(cx: Ctx, ev: Value, it: EventItem, beef: []const u8, records: *std.ArrayList([]const u8)) !Admission {
    const a = cx.a;
    const st = cx.st;
    const sub = try state.subjectOf(a, st.store, it.txid);
    const served = try calls.configObject(a, cx.in, "overlayTopics");
    const topics = try a.alloc([]const u8, it.topics.len);
    const applied = try a.alloc(state.Applied, it.topics.len);
    for (it.topics, topics, applied) |j, *t, *ap| {
        t.* = j.getText("topic") orelse return error.BadEvent;
        ap.* = .{};
        const previous = try st.previousCoins(t.*, sub.tx);
        const ins: topic_mod.Instructions = if (std.mem.eql(u32, previous, try uintList(a, j.get("previousCoins"))))
            .{ .outputs_to_admit = try uintList(a, j.get("outputsToAdmit")), .coins_to_retain = try uintList(a, j.get("coinsToRetain")) }
        else blk: {
            const prog = (try calls.configuredProgram(cx.in, served, t.*)) orelse continue;
            break :blk identify(a, cx.caller, prog, t.*, sub, previous, if (it.subject) ev.getBytes("offChainValues") else null) catch continue;
        };
        ap.* = st.apply(sub, t.*, previous, ins, beef) catch |e| switch (e) {
            error.BadInstructions => continue,
            else => return e,
        };
        if (ap.records.len == 0) continue;
        try records.appendSlice(a, ap.records);
        try calls.hookAdmitted(a, cx.caller, cx.in, t.*, sub, previous, ap.*);
    }
    return .{ .txid = it.txid, .topics = topics, .applied = applied };
}
