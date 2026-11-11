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
//!   on the transaction's CID with its previous coins. The route writes
//!   nothing (a call); it returns the submit event (0.25.0: a transaction no topic takes is an item
//!   while the chain app does not hold it, D6).
//! - **The intake** (`begin`, 0.28.0, David 2026-11-11: "The instance has done all it can do to
//!   validate when it announces a broadcast"). In the step that routed it — every path: a message
//!   submission, POST /submit (its handler, an in-VM call from the front door's step), the in-VM
//!   `intake` call of a program of the instance (the amm-validator's), a paused one taken whole —
//!   each item is handed to the chain app (an in-VM call of its `ingest` `{beef}`, skein-chain
//!   0.10.0: recorded, its broadcast emitted) and, the chain state read again, every item it holds
//!   and does not reject is **admitted in that same step**, oldest first — each topic's judgement
//!   recorded (`applied`, the admittances), the listening lookup services' hooks called
//!   (`admitted`, then `spent`), the facts emitted, the gossip out. Nothing waits on a status: no
//!   thread rests on the transaction. Instead each item the chain app holds gets its context
//!   recorded (`pending`: the submission and its submit event) and the engine's app **subscribes**
//!   its fn `chainTx` to the item's `chain/tx/<txid>` (the kernel's `on(name, fn)`, as the chain
//!   app wires its own). An ingest call that fails fails the item (its verdict `rejected`).
//! - **Later** (`heard`, the subscription's step, fn `chainTx`): the chain app's next fact about it
//!   is only rejected or mined (David 2026-11-11) — the step reads the state and acts. Admitted, a
//!   **mined** places it (`mined`, the anchors) and relays the proof to the submitter (once per
//!   place); a **seen** (skein-chain 0.12.0: only after a reorg) puts it back in the tail; a
//!   **rejected** unwinds it (`State.unapply`, the lookup services' `rejected`, the verdict
//!   `reverted`). Not admitted (rejected at intake, or unwound), a later fact the chain state no
//!   longer rejects on — **mined** (a proof overrides a rejection, skein-sdk 0.18.0), or a revived
//!   `pending` — admits it again.
//! - **The facts** (0.24.0): `<app>/topic/tx/<txid>` `{verdict: undecided | admitted | rejected |
//!   reverted}` at each verdict change, and `<app>/topic/output/<txid>.<vout>` `{state: admitted |
//!   spent | reverted, spentBy?}`. 0.25.0 (D6): the overlay's state is the verdict; the facts are the
//!   wake-ups, emitted for every transaction a submission walks, whoever listens.
//!
//! skein-overlay#1: the route walks the BEEF oldest first and judges every transaction before the
//! subject too; each one a topic takes is an item, and (0.25.0, D6) so is each one no topic takes
//! while the chain app does not hold it (0.24.0: only when a paused submission waited on it, found
//! by a scan) — ingested on its own and admitted (or, taken by none, its verdict `rejected`), in
//! order, on the chain state. A BEEF lacking a parent (neither in it nor held) is **paused**, however
//! it came: pending with the parents it waits on, its thread resting on each one's verdict
//! `<app>/topic/tx/<parent>`. Nothing is asked of anyone for them (0.20.0): a parent arrives by any
//! path. Its verdict wakes the thread and the paused submission is routed again in that same thread
//! (`wokeOn`, 0.25.0: no fresh thread): begun whole, or paused again for what it still lacks.
//! A copy of a subject paused here is a duplicate, ignored (`pending`). 0.28.0: nothing is in
//! flight (skein-overlay#6's in-flight parents are gone: a parent handed to the chain app was
//! admitted, or not, in that step); a parent paused here is waited on (the event's `held`).
//!
//! 0.19.0 (David 2026-10-30, "undecided is not rejected"): a topic's `identify` that fails
//! `MissingParents` (topic.zig) is no verdict. The walk gathers the sources it names; those neither
//! in the BEEF nor held pause the whole submission as a missing parent does (woken on each
//! arrival, judged again); nothing is recorded as rejected. A parent that is itself paused here is
//! waited on (`State.isPaused`). A submission whose sources exist nowhere stays
//! one undecided record (David: "not a big deal"): never admitted, judged the moment they arrive.
//!
//! shruggr/skein#112 (0.7.2): a submission is a message, `{fn: "submit",
//! args: {beef, topics, offChainValues?}}`, into a box a row routes to the
//! engine (`received`); POST /submit is the other path (0.9.1: BRC-22,
//! synchronous, routes.zig; 0.28.0: answered in its own call, at admission; a
//! paused one still waits by `wait`, `waitOn`, answered when the pause ends); the
//! in-VM `intake` the third (0.28.0, routes.zig: answered with the verdict). A
//! message submission's answers go to the sender, in the box it came in (skein
//! docs/APPS.md §4: `{fn: "submit", request, replyTo, result}`): **admitted**
//! with status `pending` (0.28.0: at intake; `proven` when it came proven), the
//! STEAK per topic; then **every proof** (`proven`, a reorg's proof another);
//! or **rejected**. A pause is internal: the submitter hears nothing of it.
//!
//! The submit event (box `<app>` from the libp2p route; or the args of the
//! thread a submission launches):
//!
//!   {kind: "submit", txid (hex), beef: <the pointer record> | bytes (the BEEF as received, the off-chain framing taken off),
//!    topics: [{topic, previousCoins, outputsToAdmit, coinsToRetain, ancillaryTxids?}] (the subject's),
//!    earlier?: [{txid, topics}] (the items before it, oldest first), wanted?: true (no topic took
//!    it: a paused submission waits on it), requested?: [topic] (paused: the topics it is routed
//!    with again), waiting?: [txid hex] (paused), held?: [txid hex] (of `waiting`, those paused
//!    here), offChainValues?: bytes,
//!    source?: {transport, topic?, request: <the request record>}}
//!
//! `source` (#74) says where the submission came from (whom a submitter's
//! answers go to). At admission the verdict is published on each topic that
//! admitted it (`admit`, gossip.zig); the BEEF never is (0.20.0).
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
pub const chain_app = "chain";

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
pub fn identify(a: Allocator, caller: calls.Caller, program: []const u8, topic: []const u8, sub: state.Subject, previous: []const u32, off: ?[]const u8, unheld: []const [32]u8) !topic_mod.Instructions {
    var es: std.ArrayList(cbor.Entry) = .empty;
    try es.appendSlice(a, &.{
        .{ .key = "kind", .value = .{ .text = "topic-call" } },
        .{ .key = "topic", .value = .{ .text = topic } },
        .{ .key = "tx", .value = .{ .cid = sub.cid } },
        .{ .key = "previousCoins", .value = .{ .array = try uints(a, previous) } },
    });
    if (off) |o| try es.append(a, .{ .key = "offChainValues", .value = .{ .bytes = o } });
    if (unheld.len > 0) {
        const xs = try a.alloc(Value, unheld.len);
        for (unheld, xs) |u, *v| v.* = try hexText(a, u);
        try es.append(a, .{ .key = "unheld", .value = .{ .array = xs } });
    }
    return topic_mod.instructionsOf(a, try caller.call(a, program, "identify", .{ .map = es.items }));
}

/// The input sources of `tx` the instance does not have (0.19.0): neither a transaction of the
/// submitted BEEF (`d`, none: a step's re-judgement or a seed) nor held by the chain app. Each once.
fn unheldOf(a: Allocator, st: *State, d: ?state.Decoded, tx: c.bsvz.transaction.Transaction) ![]const [32]u8 {
    var out: std.ArrayList([32]u8) = .empty;
    for (tx.inputs) |in| {
        const t = in.previous_outpoint.txid.bytes;
        if (contains(out.items, t)) continue;
        if (d) |dd| if (inBeef(dd, t)) continue;
        if (try st.ch.holds(t)) continue;
        try out.append(a, t);
    }
    return out.items;
}

pub const Routed = union(enum) {
    /// The BEEF does not decode or verify: the error message (400).
    refused: []const u8,
    /// A valid transaction no served topic admitted: answered `rejected` (shruggr/skein#112); the reasons.
    nothing: []const u8,
    /// Every served topic judged it before (a dupe): nothing new; the answer is its judgements, from the state.
    unchanged: [32]u8,
    /// A copy of a subject paused here (0.28.0: only a pause; nothing is in flight): it adds nothing.
    pending: [32]u8,
    /// Parents neither in the BEEF nor held by the chain app (skein-overlay#1): the event of a
    /// paused submission (its thread notes it pending, `waiting` on them).
    paused: struct { event: Value, txid: [32]u8, waiting: []const [32]u8 },
    /// The event to admit (the topics that were dupes are answered from their `applied` records).
    admit: struct { event: Value, txid: [32]u8 },
};

/// One transaction of a submission a topic took (or a paused submission waits on: no judgements),
/// in the walk's order (skein-overlay#1): each is ingested on its own and admitted on its own answer.
pub const Item = struct { txid: [32]u8, judged: []const Judged, subject: bool };

/// A submission's BEEF: the envelope the kernel's door put where the bytes were (shruggr/skein#121,
/// #146: `{form, beef: <pointer record CID>, subject?, vout?}` — the transactions and BUMPs are
/// blocks in the store already, every BUMP checked against the chain state's headers at the door;
/// the pointer record is the BEEF alone, the envelope beside it) — or the bytes (a body framed with
/// off-chain values, whose leading bytes are no BEEF pattern; a gossip message's `beef`, inside
/// its dag-cbor body, which the door does not reach; a host with no door), decoded and checked here
/// as before.
pub const Input = union(enum) {
    envelope: Value,
    bytes: []const u8,

    /// The value the submit event and the ingest message carry: the envelope, or the bytes.
    pub fn value(self: Input) Value {
        return switch (self) {
            .envelope => |e| e,
            .bytes => |b| .{ .bytes = b },
        };
    }

    /// An event's or a message's `beef` field read back: an envelope, or bytes.
    pub fn of(v: ?Value) ?Input {
        const x = v orelse return null;
        return switch (x) {
            .map => if (c.record.envelopeOf(x) != null) .{ .envelope = x } else null,
            .bytes => |b| .{ .bytes = b },
            else => null,
        };
    }

    /// The bytes as received: an envelope's exact wire bytes (skein-sdk `chain.record.wireOf`: its
    /// prefix, then the BEEF its pointer record stands for), or the bytes.
    pub fn wire(self: Input, a: Allocator, s: c.store.Store) ![]const u8 {
        return switch (self) {
            .envelope => |e| c.record.wireOf(a, s, e),
            .bytes => |b| b,
        };
    }
};

/// The route's half (a call; a paused submission routed again, too): verify, judge. `st` is the overlay's state over
/// the call's store; `topics` are the requested ones this overlay serves; `in` is the call's input
/// (`defaults`, `programs`); `beef` is the BEEF (its pointer record, or bytes with no framing);
/// `source` is carried on the event (#74). A pointer record is read, not decoded again, and its
/// BUMPs are not proven again (the door did, #121); bytes are decoded once (#50) and checked.
///
/// skein-overlay#1: a BEEF with parents neither in it nor held by the chain app (`missingParents`)
/// is **paused**, judged by nothing yet, however it came (shruggr/skein#112). So is one with parents
/// paused here (`heldParents`, 0.19.0), waiting on them too (`held` in its event). Otherwise the
/// BEEF is walked oldest first, up to and including the subject: each transaction every requested
/// topic has not judged, and that is not paused in a submission of its own, is judged by each such topic, with the previous coins it
/// would have once the transactions before it are admitted (`previousCoinsWith`: the outputs the
/// topic took earlier in the walk count as live). A transaction a topic takes is an item of the
/// event; so is one a paused submission waits on, judged or not, so that the chain app holds it.
pub fn route(a: Allocator, caller: calls.Caller, st: *State, in: Value, beef: Input, topics: []const []const u8, off: ?[]const u8, source: ?Value) !Routed {
    return routeOf(a, caller, st, in, beef, topics, off, source, false);
}

/// `route`, or (`again`) a paused submission routed again by its own thread (0.25.0): its own
/// pause is not a copy of it.
pub fn routeOf(a: Allocator, caller: calls.Caller, st: *State, in: Value, beef: Input, topics: []const []const u8, off: ?[]const u8, source: ?Value, again: bool) !Routed {
    const d = switch (beef) {
        .envelope => |e| state.decodeRecord(a, st.store, st.ch, e),
        .bytes => |b| state.decode(a, st.store, st.ch, b),
    } catch |e| return .{ .refused = @errorName(e) };
    // A copy of a subject paused here is a duplicate, ignored. 0.28.0: nothing else is in flight —
    // a submission handed to the chain app was admitted (or not) in that step; a copy of one is
    // judged as any (judged before: `unchanged`; rejected: the chain state refuses it).
    if (!again and topics.len > 0 and try st.isPaused(d.subject)) return .{ .pending = d.subject };
    const lacking = state.missingParents(a, st.ch, d) catch |e| return .{ .refused = @errorName(e) };
    // Parents paused here are waited on too (0.19.0).
    const held = state.heldParents(a, st, d) catch |e| return .{ .refused = @errorName(e) };
    var waiting: std.ArrayList([32]u8) = .empty;
    for (lacking) |m| if (!contains(held, m)) try waiting.append(a, m);
    try waiting.appendSlice(a, held);
    if (waiting.items.len > 0 and topics.len > 0) {
        var all = true;
        for (topics) |t| all = all and try st.isApplied(t, d.subject);
        if (all) return .{ .unchanged = d.subject };
        return .{ .paused = .{ .event = try pausedEvent(a, d.subject, beef, topics, waiting.items, held, off, source), .txid = d.subject, .waiting = waiting.items } };
    }
    const sub = state.verifyDecoded(a, st.store, st.ch, d, beef == .envelope) catch |e| switch (e) {
        // A known-rejected transaction is a valid request that admits nothing (answered `rejected`).
        error.TransactionRejected => return .{ .nothing = @errorName(e) },
        else => return .{ .refused = @errorName(e) },
    };
    // 0.20.5 / 0.26.0 (David 2026-11-09): an unproven subject spending an output a transaction held
    // here already spends — the chain state's spender not rejected — is refused, the input and its
    // spender named; a proven one never is.
    if (try spentHere(a, st, d, sub.txid, sub.tx)) |spent| return .{ .refused = spent };
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
    // 0.19.0: the sources a topic could not decide without (its `MissingParents` failure).
    var needs: std.ArrayList([32]u8) = .empty;
    for (d.txs) |dt| {
        const is_subject = std.mem.eql(u8, &dt.txid, &sub.txid);
        if (!is_subject and try st.isPaused(dt.txid)) continue; // its own submission's
        const tx = if (is_subject) sub else try state.subjectOf(a, st.store, dt.txid);
        var judged: std.ArrayList(Judged) = .empty;
        for (topics, walked) |t, *w| {
            if (try st.isApplied(t, dt.txid)) continue;
            const prog = (try calls.configuredProgram(in, served, t)) orelse continue;
            const previous = try st.previousCoinsWith(t, tx.tx, w.items);
            const ins = identify(a, caller, prog, t, tx, previous, if (is_subject) off else null, try unheldOf(a, st, d, tx.tx)) catch |e| {
                // Undecided (0.19.0): no verdict, nothing recorded; the submission pauses on them.
                if (try missingOf(a, caller, e)) |ns| {
                    for (ns) |n| if (!contains(needs.items, n)) try needs.append(a, n);
                    continue;
                }
                if (is_subject) try why.print(a, "{s}{s}: {s}", .{ if (why.items.len > 0) "; " else "", t, @errorName(e) });
                continue;
            };
            check(a, st.store, tx.tx, previous, ins) catch |e| {
                if (is_subject) try why.print(a, "{s}{s}: {s}", .{ if (why.items.len > 0) "; " else "", t, @errorName(e) });
                continue;
            };
            if (!state.takes(previous, ins)) continue;
            try judged.append(a, .{ .topic = t, .previous = previous, .ins = ins });
            for (ins.outputs_to_admit) |o| try w.append(a, c.store.outpointKey(dt.txid, o));
        }
        // 0.25.0 (D6, David 2026-11-09): a transaction the walk comes to that no topic takes is an
        // item all the same while the chain app does not hold it — ingested on its own, its verdict
        // the fact `rejected` once the chain app has it, whoever listens (0.24.0: only when a paused
        // submission waited on it). Held already, it had its verdict then.
        if (judged.items.len > 0 or (!(try allApplied(st, topics, dt.txid)) and !(try st.ch.holds(dt.txid))))
            try items.append(a, .{ .txid = dt.txid, .judged = judged.items, .subject = is_subject });
        if (is_subject) break;
    }
    if (needs.items.len > 0) {
        // What a topic could not read and the instance does not hold: waited on; the whole submission
        // paused on them, judged again from the start of the walk as each arrives (0.19.0).
        var lacking_now: std.ArrayList([32]u8) = .empty;
        for (needs.items) |n| {
            if (inBeef(d, n) or try st.ch.holds(n)) continue;
            try lacking_now.append(a, n);
        }
        if (lacking_now.items.len > 0)
            return .{ .paused = .{ .event = try pausedEvent(a, sub.txid, beef, topics, lacking_now.items, &.{}, off, source), .txid = sub.txid, .waiting = lacking_now.items } };
        // A topic named only transactions that are here: not undecided after all; it took nothing.
        try why.print(a, "{s}MissingParents of transactions held here", .{if (why.items.len > 0) "; " else ""});
    }
    // 0.26.0 (Q1 (b), David 2026-11-09): every unproven transaction the submission would ingest is
    // held to the same rule; one already spent here refuses the whole submission — nothing of it is
    // stored or broadcast.
    for (items.items) |it| {
        if (it.subject) continue;
        const tx = try state.subjectOf(a, st.store, it.txid);
        if (try spentHere(a, st, d, it.txid, tx.tx)) |spent| return .{ .refused = spent };
    }
    if (items.items.len == 0) {
        if (dupes > 0) return .{ .unchanged = sub.txid };
        return .{ .nothing = if (why.items.len > 0) why.items else "NotAdmitted: no topic admitted an output or consumed a previous coin" };
    }
    var ev = try event(a, sub.txid, beef, items.items, off, source);
    // No topic took the subject (0.25.0: an item all the same, D6): why, for its submitter.
    if (!subjectTaken(ev)) ev = .{ .map = try std.mem.concat(a, cbor.Entry, &.{ ev.map, &.{.{ .key = "reason", .value = .{ .text = if (why.items.len > 0) why.items else not_admitted } }} }) };
    return .{ .admit = .{ .event = ev, .txid = sub.txid } };
}

/// The refusal of an unproven transaction whose input a held transaction already spends (0.26.0):
/// `InputSpent: input <txid>.<vout> is already spent by <txid>`; null when proven (by the BEEF or the
/// chain state) or when no input is spent here.
fn spentHere(a: Allocator, st: *State, d: state.Decoded, txid: [32]u8, tx: c.bsvz.transaction.Transaction) !?[]const u8 {
    if (state.provenIn(d, txid) or (try st.ch.status(txid)) == .proven) return null;
    const sp = (try st.spentInput(txid, tx)) orelse return null;
    const o = try c.store.outpointOf(&sp.op);
    return try std.fmt.allocPrint(a, "{s}: input {s}.{d} is already spent by {s}", .{ input_spent, &c.header.toHex(o.txid), o.vout, &c.header.toHex(sp.by) });
}

/// The refusal's name (0.26.0, David 2026-11-09: an explicit "input already spent" failure).
pub const input_spent = "InputSpent";

/// The transactions a topic's failed `identify` names as missing parents (topic.zig
/// `MissingParents`, 0.19.0) — the VM's call fails `ImportFailed` with the callee's error line; a
/// native caller's with `MissingParents` — or null when the failure is another (a refusal).
fn missingOf(a: Allocator, caller: calls.Caller, e: anyerror) !?[][32]u8 {
    if (e != error.ImportFailed and e != error.MissingParents) return null;
    return topic_mod.needsOf(a, caller.errorText(e));
}

/// Whether every requested topic judged `txid` before.
fn allApplied(st: *State, topics: []const []const u8, txid: [32]u8) !bool {
    for (topics) |t| if (!(try st.isApplied(t, txid))) return false;
    return true;
}

fn inBeef(d: state.Decoded, txid: [32]u8) bool {
    for (d.txs) |t| if (eql(u8, &t.txid, &txid)) return true;
    return false;
}

fn contains(xs: []const [32]u8, x: [32]u8) bool {
    for (xs) |y| if (eql(u8, &x, &y)) return true;
    return false;
}

/// A topic's instructions checked against the transaction (`state.check`) and its ancillary txids
/// resolved (`state.resolveAncillary`: in the route's call, the BEEF's blocks or the held ones).
fn check(a: Allocator, s: c.store.Store, tx: c.bsvz.transaction.Transaction, previous: []const u32, ins: topic_mod.Instructions) !void {
    try state.check(tx, previous, ins);
    _ = try state.resolveAncillary(a, s, ins.ancillary_txids);
}

fn judgements(a: Allocator, judged: []const Judged) ![]Value {
    const out = try a.alloc(Value, judged.len);
    for (judged, out) |j, *o| {
        var es: std.ArrayList(cbor.Entry) = .empty;
        try es.appendSlice(a, &.{
            .{ .key = "topic", .value = .{ .text = j.topic } },
            .{ .key = "previousCoins", .value = .{ .array = try uints(a, j.previous) } },
            .{ .key = "outputsToAdmit", .value = .{ .array = try uints(a, j.ins.outputs_to_admit) } },
            .{ .key = "coinsToRetain", .value = .{ .array = try uints(a, j.ins.coins_to_retain) } },
        });
        if (j.ins.ancillary_txids.len > 0) {
            const xs = try a.alloc(Value, j.ins.ancillary_txids.len);
            for (j.ins.ancillary_txids, xs) |x, *v| v.* = try hexText(a, x);
            try es.append(a, .{ .key = "ancillaryTxids", .value = .{ .array = xs } });
        }
        o.* = .{ .map = es.items };
    }
    return out;
}

fn hexText(a: Allocator, txid: [32]u8) !Value {
    return .{ .text = try a.dupe(u8, &c.header.toHex(txid)) };
}

/// The submit event: the subject's txid, the BEEF (its pointer record's link, or bytes), the
/// subject's judgements (`topics`: none when no topic took the subject), the transactions before
/// it the walk took or a paused submission waits on (`earlier`, oldest first, each `{txid, topics}`;
/// absent when none), `wanted: true` when no topic took the subject but a paused submission waits on
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
/// requested (`requested`: routed again with them), the parents it waits on (`waiting`, hex), those
/// of them in flight (`held`, hex, skein-overlay#6: no want; absent when none).
fn pausedEvent(a: Allocator, txid: [32]u8, beef: Input, topics: []const []const u8, waiting: []const [32]u8, held: []const [32]u8, off: ?[]const u8, source: ?Value) !Value {
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
    if (held.len > 0) {
        const hs = try a.alloc(Value, held.len);
        for (held, hs) |h, *o| o.* = try hexText(a, h);
        try es.append(a, .{ .key = "held", .value = .{ .array = hs } });
    }
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
/// them as from the instance): vm.zig's `send` to `self.identity`; a test's records them. The
/// facts the step emits (0.24.0: `<app>/topic/tx/<txid>`, `<app>/topic/output/<outpoint>`), and the
/// names its thread rests on (skein 0.5.4 `on(name)`: `chain/tx/<txid>`, `<app>/topic/tx/<txid>`).
pub const Wire = struct {
    ctx: *anyopaque,
    /// `body` to the instance itself in `box` → the message's CID.
    sendFn: *const fn (ctx: *anyopaque, a: Allocator, box: []const u8, body: Value) anyerror![]const u8,
    /// An answer to a submitter (shruggr/skein#112): `body` to `to` in `box`, sent when a message
    /// can reach `to` (the instance itself, an address-book entry), else in the step's result only.
    answerFn: ?*const fn (ctx: *anyopaque, a: Allocator, to: []const u8, box: []const u8, body: Value) anyerror!void = null,
    /// A fact `{event: <name>, …fields}` (skein 0.5.0's event index).
    emitFn: ?*const fn (ctx: *anyopaque, a: Allocator, ev: Value) anyerror!void = null,
    /// The step's thread rests on `name` (skein 0.5.4): every fact under it wakes the thread (a
    /// paused submission's, on its parents' verdicts).
    restFn: ?*const fn (ctx: *anyopaque, a: Allocator, name: []const u8) anyerror!void = null,
    /// 0.28.0: the engine's app subscribes its fn `chainTx` to `name` (the kernel's `on(name, fn)`):
    /// every fact under it steps that fn; no thread rests.
    subscribeFn: ?*const fn (ctx: *anyopaque, a: Allocator, name: []const u8) anyerror!void = null,
    /// The chain app's `ingest`, an in-VM call in this step (0.26.0, skein-chain 0.10.0): `arg`
    /// `{beef}` → its answer `{txid, status, height?, reason?, by?}`; an error when it refuses.
    ingestFn: *const fn (ctx: *anyopaque, a: Allocator, arg: Value) anyerror!Value,
    /// A failed ingest call's text (the callee's error line), else the error's name.
    ingestErrorFn: ?*const fn (ctx: *anyopaque, e: anyerror) []const u8 = null,
    /// The chain app's state as this step sees it now (the head `chain/state`, moved by an ingest call).
    chainHeadFn: *const fn (ctx: *anyopaque, a: Allocator) anyerror!?[]const u8,

    pub fn send(self: Wire, a: Allocator, box: []const u8, body: Value) ![]const u8 {
        return self.sendFn(self.ctx, a, box, body);
    }
    pub fn emit(self: Wire, a: Allocator, ev: Value) !void {
        if (self.emitFn) |f| try f(self.ctx, a, ev);
    }
    pub fn rest(self: Wire, a: Allocator, name: []const u8) !void {
        if (self.restFn) |f| try f(self.ctx, a, name);
    }
    pub fn subscribe(self: Wire, a: Allocator, name: []const u8) !void {
        if (self.subscribeFn) |f| try f(self.ctx, a, name);
    }
    pub fn ingest(self: Wire, a: Allocator, arg: Value) !Value {
        return self.ingestFn(self.ctx, a, arg);
    }
    pub fn ingestError(self: Wire, e: anyerror) []const u8 {
        if (self.ingestErrorFn) |f| {
            const t = f(self.ctx, e);
            if (t.len > 0) return t;
        }
        return @errorName(e);
    }
    pub fn chainHead(self: Wire, a: Allocator) !?[]const u8 {
        return self.chainHeadFn(self.ctx, a);
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
};

/// The chain app's `ingest` call's argument (0.26.0): `{beef}` — the door's envelope (#121), or bytes.
pub fn ingestArg(a: Allocator, beef: Input) !Value {
    return .{ .map = try a.dupe(cbor.Entry, &.{.{ .key = "beef", .value = beef.value() }}) };
}

// ---------------------------------------------------------------- the names (0.24.0)

/// The engine's fn its app subscribes to each item's `chain/tx/<txid>` (0.28.0): the step that reads
/// the chain state when the chain app's next fact about it lands (`heard`).
pub const chain_tx_fn = "chainTx";

/// The chain app's fact about a transaction (skein-chain 0.8.0): `chain/tx/<txid hex>`.
pub fn chainTxName(a: Allocator, txid: [32]u8) ![]const u8 {
    return std.fmt.allocPrint(a, "{s}/tx/{s}", .{ chain_app, &c.header.toHex(txid) });
}

/// The overlay's verdict on a transaction (0.24.0, David 2026-11-09): `<app>/topic/tx/<txid hex>`.
pub fn topicTxName(a: Allocator, app: []const u8, txid: [32]u8) ![]const u8 {
    return std.fmt.allocPrint(a, "{s}/topic/tx/{s}", .{ app, &c.header.toHex(txid) });
}

/// The overlay's state of an output: `<app>/topic/output/<txid hex>.<vout>`.
pub fn topicOutputName(a: Allocator, app: []const u8, txid: [32]u8, vout: u32) ![]const u8 {
    return std.fmt.allocPrint(a, "{s}/topic/output/{s}.{d}", .{ app, &c.header.toHex(txid), vout });
}

/// The transaction a `chain/tx/<txid>` or `<app>/topic/tx/<txid>` name is about.
pub fn txidOfName(name: []const u8) ?[32]u8 {
    const i = std.mem.lastIndexOfScalar(u8, name, '/') orelse return null;
    return c.header.fromHex(name[i + 1 ..]) catch null;
}

pub const Verdict = enum { undecided, admitted, rejected, reverted };

/// The fact `<app>/topic/tx/<txid>` {verdict}: the overlay's verdict on it changed.
fn emitVerdict(cx: Ctx, txid: [32]u8, v: Verdict) !void {
    try cx.wire.emit(cx.a, .{ .map = try cx.a.dupe(cbor.Entry, &.{
        .{ .key = "event", .value = .{ .text = try topicTxName(cx.a, calls.appOf(cx.in), txid) } },
        .{ .key = "verdict", .value = .{ .text = @tagName(v) } },
    }) });
}

pub const OutputState = enum { admitted, spent, reverted };

/// The fact `<app>/topic/output/<txid>.<vout>` {state, spentBy?}.
fn emitOutput(cx: Ctx, txid: [32]u8, vout: u32, s: OutputState, by: ?[32]u8) !void {
    var es: std.ArrayList(cbor.Entry) = .empty;
    try es.appendSlice(cx.a, &.{
        .{ .key = "event", .value = .{ .text = try topicOutputName(cx.a, calls.appOf(cx.in), txid, vout) } },
        .{ .key = "state", .value = .{ .text = @tagName(s) } },
    });
    if (by) |t| try es.append(cx.a, .{ .key = "spentBy", .value = try hexText(cx.a, t) });
    try cx.wire.emit(cx.a, .{ .map = es.items });
}

/// An admission's facts: the transaction admitted; each output a topic admitted `admitted`; each
/// previous coin a topic consumed (retained or not) `spent`, by it. Each outpoint once.
fn emitAdmitted(cx: Ctx, sub: state.Subject, previous: []const []const u32, applied: []const state.Applied) !void {
    try emitVerdict(cx, sub.txid, .admitted);
    var outs: std.ArrayList(u32) = .empty;
    var spent: std.ArrayList([36]u8) = .empty;
    for (applied, previous) |ap, prev| {
        if (ap.records.len == 0) continue;
        for (ap.outputs_to_admit) |o| if (std.mem.indexOfScalar(u32, outs.items, o) == null) try outs.append(cx.a, o);
        for (prev) |i| {
            const po = sub.tx.inputs[i].previous_outpoint;
            const op = c.store.outpointKey(po.txid.bytes, po.index);
            for (spent.items) |x| {
                if (eql(u8, &x, &op)) break;
            } else try spent.append(cx.a, op);
        }
    }
    for (outs.items) |o| try emitOutput(cx, sub.txid, o, .admitted, null);
    for (spent.items) |op| {
        const o = try c.store.outpointOf(&op);
        try emitOutput(cx, o.txid, o.vout, .spent, sub.txid);
    }
}

/// What an admission of `txid` consumed and admitted, read before its judgements are removed: the
/// outputs any served topic admitted, and the previous coins any consumed.
const Undone = struct { outs: []const u32, coins: []const [36]u8 };

fn admissionOf(cx: Ctx, txid: [32]u8) !Undone {
    const a = cx.a;
    var outs: std.ArrayList(u32) = .empty;
    var coins: std.ArrayList([36]u8) = .empty;
    for (try calls.servedTopics(a, cx.in)) |t| {
        const rec = (try cx.st.appliedRecord(t, txid)) orelse continue;
        for (try uintList(a, rec.get("outputsToAdmit"))) |o| if (std.mem.indexOfScalar(u32, outs.items, o) == null) try outs.append(a, o);
        const raw = cx.st.store.get(a, rec.getCid("tx") orelse return error.BadRecord) catch return error.BadRecord;
        const tx = c.bsvz.transaction.Transaction.parse(a, raw) catch return error.BadRecord;
        for ([_][]const u8{ "coinsToRetain", "coinsRemoved" }) |f| for (try uintList(a, rec.get(f))) |i| {
            if (i >= tx.inputs.len) return error.BadRecord;
            const po = tx.inputs[i].previous_outpoint;
            const op = c.store.outpointKey(po.txid.bytes, po.index);
            for (coins.items) |x| {
                if (eql(u8, &x, &op)) break;
            } else try coins.append(a, op);
        };
    }
    return .{ .outs = outs.items, .coins = coins.items };
}

/// An admitted transaction rejected by the chain app: its judgements removed (`State.unapply`), the
/// lookup services told; the facts — the transaction `reverted`, each output it admitted
/// `reverted`, each coin it consumed `admitted` again where a topic still holds it.
fn unwind(cx: Ctx, txid: [32]u8, out: *Stepped) !void {
    const un = try admissionOf(cx, txid);
    out.unapplied = try cx.st.unapply(try calls.servedTopics(cx.a, cx.in), txid);
    try calls.hookRejected(cx.a, cx.caller, cx.in, out.unapplied, cx.st);
    if (out.unapplied.len == 0) return;
    try emitVerdict(cx, txid, .reverted);
    for (un.outs) |o| try emitOutput(cx, txid, o, .reverted, null);
    for (un.coins) |op| {
        const o = try c.store.outpointOf(&op);
        if (try heldByATopic(cx, op)) try emitOutput(cx, o.txid, o.vout, .admitted, null);
    }
}

/// Whether a coin a rejected transaction gave back is live again in a served topic: admitted, and
/// consumed by no other judgement of the topic (`State.counted`, the view's rule). 0.26.0: a proven
/// spender may hold a judgement of it while the loser is unwound — then it stays spent, by it.
fn heldByATopic(cx: Ctx, op: [36]u8) !bool {
    const o = try c.store.outpointOf(&op);
    for (try calls.servedTopics(cx.a, cx.in)) |t| if (try cx.st.counted(t, o.txid, o.vout)) return true;
    return false;
}

/// What a step that begins (or pauses) a submission did.
pub const Begun = struct {
    /// The items handed to the chain app (its `ingest`, an in-VM call: 0.26.0), oldest first.
    ingested: []const [32]u8 = &.{},
    /// Paused: the parents it waits on.
    paused: bool = false,
    waiting: []const [32]u8 = &.{},
    /// The submit event this step worked on, put in the store: its CID (0.28.0: the context each
    /// item's subscription step reads, from its `pending` record).
    submission: ?[]const u8 = null,
    /// What the step admitted (0.28.0: every item the chain app holds and does not reject, in this
    /// step). Null: paused.
    stepped: ?Stepped = null,
    /// The subject's ingest call failed: the callee's error text (0.28.0: for an in-VM caller's or
    /// POST /submit's answer).
    failed: ?[]const u8 = null,
};

/// The intake (0.28.0, David 2026-11-11: "when we admit, we also broadcast"): the step that routed
/// the submission (a message, POST /submit's handler, the in-VM `intake`, or a paused submission's
/// own thread taking it whole) hands each item of the event (oldest first) to the chain app by an
/// in-VM CALL of its `ingest` in this step (0.26.0; skein-chain 0.10.0: recorded and its broadcast
/// emitted in this step) — the subject with the submission's BEEF as handed, each earlier one its
/// Atomic BEEF cut from it (`state.atomicFor`). A call that fails fails the item: its verdict
/// `rejected`, its submitter answered. Then, the chain state read again (the calls moved it), every
/// item the chain app holds gets its context recorded (`pending`: the submission's subject and its
/// submit event) and the engine's app subscribes fn `chainTx` to its `chain/tx/<txid>` — no thread
/// rests on it — and every item the chain state does not reject is admitted now, oldest first
/// (`admitHeard`). One the chain app rejects at intake (a proven conflict, a rejected parent) is
/// not admitted; its verdict comes with the chain app's fact, in its subscription's step. A paused
/// submission (`waiting`) is recorded and its thread rests on the parents (`pause`); nothing goes to
/// the chain app. The HTTP waiters of a pause this ends are answered: they read the state again.
pub fn begin(cx: Ctx, ev: Value) !Begun {
    const a = cx.a;
    const txid = try txidOf(ev);
    if (ev.get("waiting") != null) return pause(cx, ev, txid);
    // A paused submission of this subject taken whole now: its pause ends; its waiters are answered
    // at the end of this step.
    var wakes: std.ArrayList([]const u8) = .empty;
    if (try cx.st.isPaused(txid)) {
        for (try wakesOf(a, (try cx.st.pendingRecord(txid)).?)) |w| try wakes.append(a, w);
        try unpause(cx.st, txid);
    }
    const beef = Input.of(ev.get("beef")) orelse return error.BadEvent;
    const its = try itemsOf(a, ev);
    const submission = try cx.st.store.putValue(a, ev);
    var bytes: ?[]const u8 = null;
    var done: std.ArrayList([32]u8) = .empty;
    var failed: std.ArrayList(struct { txid: [32]u8, why: []const u8 }) = .empty;
    for (its) |it| {
        if (bytes == null) bytes = try beef.wire(a, cx.st.store);
        const b: Input = if (it.subject) beef else .{ .bytes = try state.atomicFor(a, bytes.?, it.txid) };
        if (cx.wire.ingest(a, try ingestArg(a, b))) |_| {} else |e| try failed.append(a, .{ .txid = it.txid, .why = try a.dupe(u8, cx.wire.ingestError(e)) });
        try done.append(a, it.txid);
    }
    // The chain state as the calls left it (a head a callee advanced reads back as moved).
    if (done.items.len > 0) try cx.st.reopenChain(try cx.wire.chainHead(a));
    // Each item the chain app holds: its context, and the subscription that steps it on the chain
    // app's next fact about it.
    for (done.items) |t| {
        if (!(try cx.st.ch.holds(t))) continue;
        try cx.st.putPending(t, .{ .submission = txid, .event = submission });
        try cx.wire.subscribe(a, try chainTxName(a, t));
    }
    var out = Stepped{ .txid = txid, .heard = "ingested" };
    var subject_failed: ?[]const u8 = null;
    for (failed.items) |f| {
        try emitVerdict(cx, f.txid, .rejected);
        if (eql(u8, &f.txid, &txid)) {
            subject_failed = f.why;
            if (subjectTaken(ev)) try answerRejected(cx, ev.get("source"), f.txid, f.why);
        }
    }
    try admitHeard(cx, ev, null, &out, true);
    for (wakes.items) |w| _ = try cx.wire.send(a, calls.appOf(cx.in), try wakeBody(a, w, txid));
    return .{ .ingested = done.items, .submission = submission, .stepped = out, .failed = subject_failed };
}

/// A paused submission recorded: its pending record with its event and the parents it waits on;
/// the thread rests on each parent's `<app>/topic/tx/<txid>` (0.24.0: no `waits` index): the
/// parent's verdict, when it comes, wakes it and it is routed again (`wokeOn`) — in this same thread
/// (0.25.0). Its verdict is the fact `undecided` the first time. Nothing is asked of anyone. A parent
/// settled here since the route (paused then, or missing then and held now) will bring no fact this
/// thread hears: the submission is routed again at once.
fn pause(cx: Ctx, ev: Value, txid: [32]u8) anyerror!Begun {
    const a = cx.a;
    const st = cx.st;
    const waiting = try hexList(a, ev.get("waiting"));
    const held = try hexList(a, ev.get("held"));
    for (waiting) |w| {
        if (try st.isPaused(w)) continue;
        if (!contains(held, w) and !(try st.ch.holds(w))) continue;
        // Settled since the route: routed again now, in this thread.
        const beef = Input.of(ev.get("beef")) orelse return error.BadEvent;
        const topics = try textList(a, ev.get("requested"));
        const r = try routeOf(a, cx.caller, st, cx.in, beef, topics, ev.getBytes("offChainValues"), ev.get("source"), true);
        return switch (try settle(cx, r, txid, topics, ev.get("source"))) {
            .paused, .begun => |b| b,
            else => .{},
        };
    }
    const first = !(try st.isPaused(txid));
    const ec = try st.store.putValue(a, ev);
    // Paused again: its waiters wait on (0.9.1).
    const wakes = if (try st.pendingRecord(txid)) |prior| try wakesOf(a, prior) else &.{};
    try st.putPending(txid, .{ .waiting = waiting, .event = ec, .wakes = wakes });
    for (waiting) |w| try cx.wire.rest(a, try topicTxName(a, calls.appOf(cx.in), w));
    if (first) try emitVerdict(cx, txid, .undecided);
    return .{ .paused = true, .waiting = waiting, .submission = ec };
}

fn textList(a: Allocator, v: ?Value) ![]const []const u8 {
    const xs = (v orelse return &.{}).array;
    const out = try a.alloc([]const u8, xs.len);
    for (xs, out) |x, *o| o.* = if (x == .text) x.text else return error.BadEvent;
    return out;
}

/// The pause of this subject ended: its pending record dropped.
fn unpause(st: *State, txid: [32]u8) !void {
    try st.dropPending(txid);
}

// ---------------------------------------------------------------- waiting on a pause (0.9.1)

/// A pending record's waiters (`State.Pending.wakes`): the `wait` messages of the HTTP requests
/// waiting on it.
pub fn wakesOf(a: Allocator, rec: Value) ![]const []const u8 {
    const ws = rec.getArray("wakes") orelse return &.{};
    const out = try a.alloc([]const u8, ws.len);
    for (ws, out) |w, *o| o.* = if (w == .cid) w.cid else return error.BadState;
    return out;
}

/// The message an HTTP request waiting on a submission sends the instance itself (box `<app>`) and
/// awaits (0.9.1): `{fn: "wait", args: {txid (hex)}}`. Its answer wakes the request, which reads
/// the state again.
pub fn waitBody(a: Allocator, txid: [32]u8) !Value {
    return .{ .map = try a.dupe(cbor.Entry, &.{
        .{ .key = "fn", .value = .{ .text = "wait" } },
        .{ .key = "args", .value = .{ .map = try a.dupe(cbor.Entry, &.{.{ .key = "txid", .value = try hexText(a, txid) }}) } },
    }) };
}

/// The answer to a `wait` message `w`: `{fn: "wait", request: w, replyTo: w, result: {txid}}`, to the
/// instance itself in box `<app>` (routed by its `replyTo` to the request awaiting it).
pub fn wakeBody(a: Allocator, w: []const u8, txid: [32]u8) !Value {
    return .{ .map = try a.dupe(cbor.Entry, &.{
        .{ .key = "fn", .value = .{ .text = "wait" } },
        .{ .key = "request", .value = .{ .cid = w } },
        .{ .key = "replyTo", .value = .{ .cid = w } },
        .{ .key = "result", .value = .{ .map = try a.dupe(cbor.Entry, &.{.{ .key = "txid", .value = try hexText(a, txid) }}) } },
    }) };
}

/// The pause of this subject ends (resumed whole, routed to nothing, judged before): each waiter
/// answered. → how many.
fn wakeWaiters(cx: Ctx, txid: [32]u8) !usize {
    const rec = (try cx.st.pendingRecord(txid)) orelse return 0;
    const ws = try wakesOf(cx.a, rec);
    for (ws) |w| _ = try cx.wire.send(cx.a, calls.appOf(cx.in), try wakeBody(cx.a, w, txid));
    return ws.len;
}

/// A `wait` message `w` about `txid` (0.9.1), from an HTTP request of the instance: while the
/// submission is paused, `w` joins its waiters (answered when the pause ends); otherwise it is
/// answered at once (the request reads the state again). 0.28.0: nothing is in flight — a
/// submission handed to the chain app was decided in that step.
pub fn waitOn(cx: Ctx, txid: [32]u8, w: []const u8) !enum { waiting, answered } {
    if (try cx.st.isPaused(txid)) {
        const rec = (try cx.st.pendingRecord(txid)).?;
        var p = try pendingOf(cx.st, rec);
        p.waiting = try hexList(cx.a, rec.get("waiting"));
        p.event = rec.getCid("event");
        const prior = try wakesOf(cx.a, rec);
        for (prior) |x| if (eql(u8, x, w)) return .waiting;
        p.wakes = try std.mem.concat(cx.a, []const u8, &.{ prior, &.{w} });
        try cx.st.putPending(txid, p);
        return .waiting;
    }
    _ = try cx.wire.send(cx.a, calls.appOf(cx.in), try wakeBody(cx.a, w, txid));
    return .answered;
}

/// The chain app's fact `chain/tx/<txid>` as the subscription's step acts on it (skein-chain
/// 0.12.0: `pending`, `seen` — only with reason "reorged" after a reorg, acted on as an unmined-again
/// transaction is —, `mined` with its `height`, `rejected` with its reason and `by`), or a failed
/// ingest call (`failed`).
pub const Answer = union(enum) {
    pending,
    seen,
    /// `result`: what to relay to the submitter as its proof (`height`; the block is read from the chain state).
    mined: struct { result: ?Value = null },
    rejected: []const u8,
    failed: []const u8,
    /// Anything else: nothing to act on.
    other,
};

/// The fact `chain/tx/<txid>` read: its `status` (and `height`); a rejection's reason (and the
/// transaction `by`, a double spend's winner or an input's rejected root) from the fact, else the
/// chain state's settlement record.
pub fn factOf(a: Allocator, st: *State, txid: [32]u8, fact: Value) !Answer {
    const s = fact.getText("status") orelse return .other;
    if (eql(u8, s, "pending")) return .pending;
    if (eql(u8, s, "seen")) return .seen;
    if (eql(u8, s, "mined")) {
        const h = fact.getUint("height") orelse return .{ .mined = .{} };
        return .{ .mined = .{ .result = .{ .map = try a.dupe(cbor.Entry, &.{.{ .key = "height", .value = .{ .uint = h } }}) } } };
    }
    if (eql(u8, s, "rejected")) {
        const reason = fact.getText("reason") orelse blk: {
            const sc = (try st.ch.settlementCid(txid)) orelse break :blk "rejected";
            break :blk (try st.store.getValue(a, sc)).getText("reason") orelse "rejected";
        };
        if (fact.getText("by")) |by| return .{ .rejected = try std.fmt.allocPrint(a, "{s} by {s}", .{ reason, by }) };
        return .{ .rejected = reason };
    }
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
    try answerTo(cx, source, try judgedResult(cx, txid, topics));
    if ((try cx.st.ch.status(txid)) == .proven) try answerProof(cx, source, txid, null);
}

/// **admitted**, read from the state: the STEAK per topic from its `applied` record (empty for a
/// topic that took nothing), `status` proven or pending.
fn judgedResult(cx: Ctx, txid: [32]u8, topics: []const []const u8) !Value {
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
    return admittedResult(a, txid, if (proven) "proven" else "pending", steak.items);
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
    try answerTo(cx, source, try rejectedResult(cx.a, txid, reason));
}

fn rejectedResult(a: Allocator, txid: ?[32]u8, reason: []const u8) !Value {
    var es: std.ArrayList(cbor.Entry) = .empty;
    if (txid) |t| try es.append(a, .{ .key = "txid", .value = try hexText(a, t) });
    try es.appendSlice(a, &.{
        .{ .key = "state", .value = .{ .text = "rejected" } },
        .{ .key = "reason", .value = .{ .text = reason } },
    });
    return .{ .map = es.items };
}

/// No topic took the subject (only transactions before it, or it is only wanted): the submitter
/// hears `rejected`, at once; the items go on.
const not_admitted = "NotAdmitted: no topic admitted an output or consumed a previous coin";

pub fn subjectTaken(ev: Value) bool {
    const js = ev.getArray("topics") orelse return false;
    return js.len > 0;
}

/// One transaction admitted in a step: its topics and each one's judgement as recorded.
pub const Admission = struct { txid: [32]u8, topics: []const []const u8, applied: []const state.Applied };

/// What a step of a submission's thread came to.
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
    published: usize = 0,
};

fn pendingOf(st: *State, rec: Value) !State.Pending {
    return .{
        .submission = if (rec.getText("submission")) |h| c.header.fromHex(h) catch return error.BadState else null,
        .wakes = try wakesOf(st.arena, rec),
    };
}

/// Whether this item's own judgements are recorded (0.25.0): one of its topics has applied it.
/// An item no topic took (judged by none) is never applied.
fn itemApplied(st: *State, it: EventItem) !bool {
    for (it.topics) |j| if (try st.isApplied(j.getText("topic") orelse return error.BadEvent, it.txid)) return true;
    return false;
}

/// What the chain state says of a transaction now (0.25.0, David 2026-11-09: "There is no deciding.
/// There is reading the state"): mined (its proof on our best chain), held (0.28.0: unproven and
/// not rejected — the instance has done all it can to validate it, and admits it), rejected (its
/// latest status), or absent (not held: its ingest failed).
const ChainNow = enum { mined, held, rejected, absent };

fn chainNow(st: *State, txid: [32]u8) !ChainNow {
    if (!(try st.ch.holds(txid))) return .absent;
    return switch (try st.ch.status(txid)) {
        .proven => .mined,
        .rejected => .rejected,
        .unproven => .held,
    };
}

/// The step of an item's subscription (fn `chainTx`, 0.28.0) on the chain app's fact
/// `chain/tx/<txid>` about it — `ev` the submission it came in (its `pending` record's `event`).
/// Nothing is decided and deleted (0.25.0); the step reads the state and acts. The item admitted
/// already (one of its topics applied it): mined places it where the chain state has it (`mined`,
/// the anchors) and the submitter (the subject's) is answered the proof — once per place; seen
/// (reorged) places it back in the topic's tail; rejected unwinds it (the facts `reverted`) and the
/// submitter is answered `rejected`. Not admitted: rejected is the fact `rejected`, the submitter
/// answered `rejected`. Then, oldest first, every item the chain state holds and does not reject
/// and that is not admitted is admitted (`admitHeard`: a proof overrides a rejection; a revived
/// item), up to the first it does not: an item is never admitted before the ones before it in the
/// BEEF are, so its previous coins are those it was judged with. Each admission or rejection is a
/// fact (`<app>/topic/tx/<txid>`, and its outputs' `<app>/topic/output/<outpoint>`): the threads
/// resting on it (a paused child) wake.
///
/// The submitter (shruggr/skein#112) hears about the subject: admitted (at intake, `pending`; or
/// `proven` admitted at its proof, then the proof), each later proof (a reorg's another), or
/// rejected (a rejection, a failed ingest, a later rejection).
pub fn heard(cx: Ctx, ev: Value, txid: [32]u8, ans: Answer) !Stepped {
    const a = cx.a;
    const st = cx.st;
    const subject = try txidOf(ev);
    const source = ev.get("source");
    var out = Stepped{ .txid = subject, .heard = @tagName(ans) };
    const its = try itemsOf(a, ev);
    var unapplied: std.ArrayList(state.Unapplied) = .empty;
    var proof_result: ?Value = null;
    for (its) |it| {
        if (!eql(u8, &it.txid, &txid)) continue;
        out.txid = it.txid;
        const answering = it.subject and subjectTaken(ev) and submitterOf(source) != null;
        if (try itemApplied(st, it)) {
            // Admitted already: what the chain app says later.
            switch (ans) {
                .mined => |p| if (try st.settleMined(try calls.servedTopics(a, cx.in), it.txid)) {
                    if (answering) try answerProof(cx, source, it.txid, p.result);
                },
                // Unmined again (a reorg: `seen`, reason "reorged"): back in the tail where it was mined.
                .seen => _ = try st.settleMined(try calls.servedTopics(a, cx.in), it.txid),
                .rejected => |why| {
                    var o = Stepped{ .txid = it.txid };
                    try unwind(cx, it.txid, &o);
                    try unapplied.appendSlice(a, o.unapplied);
                    if (answering and o.unapplied.len > 0) try answerRejected(cx, source, it.txid, why);
                },
                .pending, .failed, .other => {},
            }
        } else switch (ans) {
            .mined => |p| if (it.subject) {
                proof_result = p.result;
            },
            .rejected, .failed => |why| {
                // Not admitted: the verdict `rejected`; nothing deleted (a later proof admits it).
                try emitVerdict(cx, it.txid, .rejected);
                if (it.subject and subjectTaken(ev)) try answerRejected(cx, source, it.txid, why);
            },
            .pending, .seen, .other => {},
        }
        break;
    }
    out.unapplied = unapplied.items;
    try admitHeard(cx, ev, proof_result, &out, false);
    return out;
}

/// Admit, oldest first, every item the chain state holds and does not reject (0.28.0: unproven or
/// proven) and its own topics have not applied yet, up to the first it does not (0.25.0: the state
/// read, not an answer noted). `intake`: the step that handed the items to the chain app — an item
/// no topic took gets its verdict (`rejected`) there, once; on a later step it is passed over. One
/// admitted before and unwound by a rejection, then proven (or revived), is admitted again. The facts
/// of each admission; the subject's submitter answered.
fn admitHeard(cx: Ctx, ev: Value, proof_result: ?Value, out: *Stepped, at_intake: bool) !void {
    const a = cx.a;
    const st = cx.st;
    const source = ev.get("source");
    const its = try itemsOf(a, ev);
    var admissions: std.ArrayList(Admission) = .empty;
    var records: std.ArrayList([]const u8) = .empty;
    var beef_cid: ?[]const u8 = null;
    for (its) |it| {
        if (try itemApplied(st, it)) continue;
        // An item no topic took has nothing to admit after its intake (its verdict given there).
        if (it.topics.len == 0 and !at_intake) continue;
        const now = try chainNow(st, it.txid);
        if (now == .absent or now == .rejected) break;
        if (beef_cid == null) beef_cid = try beefCid(cx, ev);
        const adm = try admitItem(cx, ev, it, beef_cid.?, &records);
        const proven = now == .mined;
        // The submitter's answers: the subject's, when a topic took it.
        const answering = it.subject and subjectTaken(ev) and submitterOf(source) != null;
        // 0.20.5: an admission that applied nothing in any topic (no topic took it, or its previous
        // coins moved since the route and no topic takes it now) is answered `rejected`, as the
        // route answers a transaction no topic takes; its verdict the fact `rejected` — once, at its
        // intake.
        if (appliedNothing(adm)) {
            if (at_intake) {
                try emitVerdict(cx, it.txid, .rejected);
                if (answering) try answerRejected(cx, source, it.txid, not_admitted);
            }
            continue;
        }
        try admissions.append(a, adm);
        if (cx.out) |o| out.published += try gossip.admitted(a, o, st, cx.in, it.txid, adm.topics, adm.applied);
        if (answering) {
            try answerAdmitted(cx, source, adm, if (proven) "proven" else "pending");
            if (proven) try answerProof(cx, source, it.txid, if (it.subject) proof_result else null);
        }
    }
    if (admissions.items.len > 0) {
        const last = admissions.items[admissions.items.len - 1];
        // The result names the transaction its STEAK is of: the last admitted.
        out.txid = last.txid;
        out.admitted = true;
        out.topics = last.topics;
        out.applied = last.applied;
    }
    out.admissions = try std.mem.concat(a, Admission, &.{ out.admissions, admissions.items });
    out.records = try std.mem.concat(a, []const u8, &.{ out.records, records.items });
}

/// Whether an admission recorded no judgement in any topic (none took anything, none had judged it before).
fn appliedNothing(adm: Admission) bool {
    for (adm.applied) |ap| if (ap.dupe or ap.records.len > 0) return false;
    return true;
}

/// What routing a submission came to (a parent's verdict woke it, a submission by message).
pub const Resumed = union(enum) {
    /// Not paused (any more), or a copy of a subject paused here: nothing to do.
    none,
    /// Missing parents, or parents not settled here: paused (again), in this thread.
    paused: Begun,
    /// Whole: begun in this step (0.28.0: every path — the intake is the step that routed it).
    begun: Begun,
    /// Routed to nothing (refused, taken by no topic, judged before): a pause dropped; why. The
    /// submitter was answered.
    dropped: []const u8,
    /// The step's wake at the end of a thread it launched (`resolved` in its input): nothing routed
    /// again, nothing answered.
    woke,
};

/// Whether a step is its thread's wake at the end of a thread it launched (docs/VM.md "Waiting on
/// a thread": `resolved: [{thread, state, result, error}]`), not a new message.
pub fn woke(in: Value) bool {
    const r = in.get("resolved") orelse return false;
    return r == .array and r.array.len > 0;
}

/// The route's outcome, acted on in the step that routed it (a parent's verdict, a submission by
/// message, POST /submit's handler, the in-VM `intake`): begin (0.28.0: in this step, every path —
/// no thread is launched for it), pause, or answer. Every outcome but a pause or a begin drops a
/// pause of the subject; refused or taken by nothing, its verdict is the fact `rejected` (D6,
/// 0.25.0: always, whoever listens).
pub fn settle(cx: Ctx, r: Routed, txid_: ?[32]u8, topics: []const []const u8, source: ?Value) anyerror!Resumed {
    switch (r) {
        .paused => |p| return .{ .paused = try begin(cx, p.event) },
        .admit => |x| {
            if (!subjectTaken(x.event)) try answerRejected(cx, source, x.txid, x.event.getText("reason") orelse not_admitted);
            // A pause of the subject ends in `begin` (its waiters answered there).
            return .{ .begun = try begin(cx, x.event) };
        },
        .pending => return .none,
        .refused => |why| {
            if (txid_) |t| try unpauseIf(cx, t, true);
            try answerRejected(cx, source, txid_, why);
            return .{ .dropped = why };
        },
        .nothing => |why| {
            if (txid_) |t| try unpauseIf(cx, t, true);
            try answerRejected(cx, source, txid_, why);
            return .{ .dropped = why };
        },
        .unchanged => |t| {
            try unpauseIf(cx, t, false);
            try answerJudged(cx, source, t, topics);
            return .{ .dropped = "judged before" };
        },
    }
}

/// A pause of this subject dropped (taken by nothing, refused, judged before): its waiters answered.
/// Refused or taken by nothing (`rejected`): its verdict the fact `rejected` (0.25.0, D6: always,
/// paused or not) — the submissions paused on it here wake and are routed again.
fn unpauseIf(cx: Ctx, txid: [32]u8, rejected: bool) !void {
    if (try cx.st.isPaused(txid)) {
        _ = try wakeWaiters(cx, txid);
        try unpause(cx.st, txid);
    }
    if (rejected) try emitVerdict(cx, txid, .rejected);
}

/// The paused submission of this subject routed again by its own thread (0.25.0), as the route
/// does, with its BEEF, the topics requested, its off-chain values and source: begun whole in this
/// thread, paused again (it rests again on what it still lacks), or dropped.
pub fn resumed(cx: Ctx, txid: [32]u8) !Resumed {
    if (woke(cx.in)) return .woke;
    const a = cx.a;
    const rec = (try cx.st.pendingRecord(txid)) orelse return .none;
    if (rec.get("waiting") == null) return .none;
    const ev = try cx.st.store.getValue(a, rec.getCid("event") orelse return error.BadState);
    const beef = Input.of(ev.get("beef")) orelse return error.BadEvent;
    const topics = try textList(a, ev.get("requested"));
    const r = try routeOf(a, cx.caller, cx.st, cx.in, beef, topics, ev.getBytes("offChainValues"), ev.get("source"), true);
    return settle(cx, r, txid, topics, ev.get("source"));
}

/// A thread resting on a parent's verdict woken by it (`<app>/topic/tx/<parent>`, 0.24.0; 0.25.0,
/// David 2026-11-09: one thread per submission — no scan of the pending records): the submission
/// this thread works on (`ev`, its current submit event), when it is paused and waits on the parent,
/// is routed again (`resumed`) — begun whole in this thread, paused again, or dropped. Otherwise
/// (not paused any more, or not waiting on it) nothing.
pub fn wokeOn(cx: Ctx, ev: Value, parent: [32]u8) !Resumed {
    const txid = try txidOf(ev);
    const rec = (try cx.st.pendingRecord(txid)) orelse return .none;
    const ws = rec.getArray("waiting") orelse return .none;
    const hex = c.header.toHex(parent);
    for (ws) |w| if (w == .text and eql(u8, w.text, &hex)) return resumed(cx, txid);
    return .none;
}

/// A submission by message (shruggr/skein#112): `{fn: "submit", args: {beef, topics,
/// offChainValues?}}` in a box a row routes to the engine — or the paused POST /submit's event,
/// which carries the same message. `source` is `{transport, box, sender?, request}`: whom the
/// answers go to. Routed as any submission: whole, begun in this step (0.28.0: admitted here);
/// lacking parents, paused in this thread (the submitter hears nothing of it); else answered at
/// once (rejected; or, judged before, admitted).
/// A `bad-args` error answer for a body that is not that shape. The step's wake at the end of the
/// thread it launched answers nothing (`woke`): the submitter is answered once per state change.
pub fn received(cx: Ctx, args: Value, source: Value) !Resumed {
    if (woke(cx.in)) return .woke;
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

/// The in-VM entry (0.28.0, David 2026-11-11): a program of the instance (skein-amm's
/// amm-validator) hands a transaction to its overlay in its own step — `fn "intake"`, `args` the
/// message form's `{beef, topics, offChainValues?}` and the `app` whose overlay it is (routes.zig
/// `intakeCall`) — and the same intake runs as for every other
/// submission (`route`, `settle`, `begin`: the chain app's ingest and its broadcast, the admission,
/// the subscriptions), in the caller's step. The call RETURNS with the verdict, read from the state:
///   `{txid, state: "admitted", status: "pending" | "proven", steak}` — a requested topic applied it
///     (now, or before);
///   `{txid?, state: "rejected", reason}` — refused (`InputSpent: …`, a bad BEEF), taken by no
///     topic, rejected by the chain app at intake, or its ingest failed (the callee's error);
///   `{txid, state: "undecided", waiting}` — it lacks parents (or one is paused here): a pause rests
///     a thread on its parents' verdicts, and the caller's thread is its caller's, so nothing is
///     recorded and nothing is handed to the chain app.
/// No submitter (`source` none): nobody is answered by message. `done`: what the step admitted (the
/// records to keep), null when nothing was begun.
pub fn intake(cx: Ctx, args: Value) !struct { result: Value, done: ?Stepped } {
    const a = cx.a;
    const bad = "intake: want {beef: <envelope> | bytes, topics: [string], offChainValues?: bytes}";
    const beef = Input.of(args.get("beef")) orelse return .{ .result = try rejectedResult(a, null, bad), .done = null };
    const tv = args.get("topics") orelse return .{ .result = try rejectedResult(a, null, bad), .done = null };
    if (tv != .array) return .{ .result = try rejectedResult(a, null, bad), .done = null };
    const requested = textList(a, tv) catch return .{ .result = try rejectedResult(a, null, bad), .done = null };
    const topics = try servedOf(a, cx.in, requested);
    if (topics.len == 0) return .{ .result = try rejectedResult(a, null, "no topic requested is served here"), .done = null };
    const r = try route(a, cx.caller, cx.st, cx.in, beef, topics, args.getBytes("offChainValues"), null);
    switch (r) {
        .paused => |p| return .{ .result = try undecidedResult(a, p.txid, p.waiting), .done = null },
        .pending => |t| return .{ .result = try undecidedResult(a, t, &.{}), .done = null },
        else => {},
    }
    const txid: ?[32]u8 = switch (r) {
        .unchanged => |t| t,
        .admit => |x| x.txid,
        else => null,
    };
    const outcome = try settle(cx, r, txid, topics, null);
    const done: ?Stepped = if (outcome == .begun) outcome.begun.stepped else null;
    return .{ .result = switch (r) {
        .refused, .nothing => |why| try rejectedResult(a, null, why),
        .unchanged => |t| try judgedResult(cx, t, topics),
        .admit => |x| try verdictNow(cx, x.txid, topics, if (outcome == .begun) outcome.begun.failed else null, x.event.getText("reason")),
        .paused, .pending => unreachable,
    }, .done = done };
}

/// A begun subject's verdict as the state has it now (0.28.0, for an in-VM caller): admitted by a
/// requested topic; else why not — its ingest failed (`failed`), the chain app rejected it, or no
/// topic took it (`why`).
pub fn verdictNow(cx: Ctx, txid: [32]u8, topics: []const []const u8, failed: ?[]const u8, why: ?[]const u8) !Value {
    for (topics) |t| if (try cx.st.isApplied(t, txid)) return judgedResult(cx, txid, topics);
    if (failed) |f| return rejectedResult(cx.a, txid, f);
    if ((try cx.st.ch.holds(txid)) and (try cx.st.ch.status(txid)) == .rejected) {
        const reason = if (try cx.st.ch.rejectionOf(txid)) |rj| rj.reason else "rejected";
        return rejectedResult(cx.a, txid, if (reason.len > 0) reason else "rejected");
    }
    return rejectedResult(cx.a, txid, why orelse not_admitted);
}

/// **undecided**: `{txid, state: "undecided", waiting: [txid hex]}` (0.28.0: an in-VM caller's
/// submission that would pause; nothing recorded).
fn undecidedResult(a: Allocator, txid: [32]u8, waiting: []const [32]u8) !Value {
    const ws = try a.alloc(Value, waiting.len);
    for (waiting, ws) |w, *o| o.* = try hexText(a, w);
    return .{ .map = try a.dupe(cbor.Entry, &.{
        .{ .key = "txid", .value = try hexText(a, txid) },
        .{ .key = "state", .value = .{ .text = "undecided" } },
        .{ .key = "waiting", .value = .{ .array = ws } },
    }) };
}

/// The submission event POST /submit admits into box `<app>/submit` (0.7.3: the route launches
/// nothing; the box since 0.7.6, one box per function class, shruggr/skein#128):
/// `{kind: "submission", body: {fn: "submit", args: {beef, topics, offChainValues?}}, request:
/// <the request record>, transport: "http", sender?: <the session's identity>}`. Its step is the
/// message step's (`received`): `body` the message, `source` `{transport, box: <the box it was
/// admitted in>, sender?, request}`.
pub fn submissionOf(a: Allocator, ev: Value, box: []const u8) !struct { body: Value, source: Value } {
    const body = ev.get("body") orelse return error.BadEvent;
    var src: std.ArrayList(cbor.Entry) = .empty;
    try src.appendSlice(a, &.{
        .{ .key = "transport", .value = .{ .text = ev.getText("transport") orelse "http" } },
        .{ .key = "box", .value = .{ .text = box } },
    });
    if (ev.getBytes("sender")) |sender| try src.append(a, .{ .key = "sender", .value = .{ .bytes = sender } });
    try src.append(a, .{ .key = "request", .value = .{ .cid = ev.getCid("request") orelse return error.BadEvent } });
    return .{ .body = body, .source = .{ .map = src.items } };
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

/// The submission's BEEF as handed, named by each `applied` record (for internalizing;
/// skein-overlay#3): the door's envelope as a block of its own (dag-cbor `{form, beef: <pointer
/// record>, subject?, vout?}`, shruggr/skein#146; `wireOf` gives the bytes back), or the raw block
/// of the bytes.
fn beefCid(cx: Ctx, ev: Value) ![]const u8 {
    return switch (Input.of(ev.get("beef")) orelse return error.BadEvent) {
        .envelope => |e| try cx.st.store.putValue(cx.a, e),
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
    const prevs = try a.alloc([]const u32, it.topics.len);
    for (it.topics, topics, applied, prevs) |j, *t, *ap, *pv| {
        t.* = j.getText("topic") orelse return error.BadEvent;
        ap.* = .{};
        pv.* = &.{};
        const previous = try st.previousCoins(t.*, sub.tx);
        pv.* = previous;
        const ins: topic_mod.Instructions = if (std.mem.eql(u32, previous, try uintList(a, j.get("previousCoins"))))
            .{ .outputs_to_admit = try uintList(a, j.get("outputsToAdmit")), .coins_to_retain = try uintList(a, j.get("coinsToRetain")), .ancillary_txids = try hexList(a, j.get("ancillaryTxids")) }
        else blk: {
            const prog = (try calls.configuredProgram(cx.in, served, t.*)) orelse continue;
            break :blk identify(a, cx.caller, prog, t.*, sub, previous, if (it.subject) ev.getBytes("offChainValues") else null, try unheldOf(a, st, null, sub.tx)) catch continue;
        };
        ap.* = st.apply(sub, t.*, previous, ins, beef) catch |e| switch (e) {
            error.BadInstructions, error.UnknownAncillary => continue,
            else => return e,
        };
        if (ap.records.len == 0) continue;
        try records.appendSlice(a, ap.records);
        try calls.hookAdmitted(a, cx.caller, cx.in, t.*, sub, previous, ap.*, cx.st);
    }
    // 0.24.0: the admission's facts (the transaction, its outputs, the coins it consumed).
    for (applied) |ap| if (ap.records.len > 0) {
        try emitAdmitted(cx, sub, prevs, applied);
        break;
    };
    return .{ .txid = it.txid, .topics = topics, .applied = applied };
}
