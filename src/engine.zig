//! overlay: the overlay engine (issues #36, #50, #57; re-split by skein #79).
//! Called (#40), it is the overlay's front-door route handlers (routes.zig:
//! submit, lookup, the listings and documentation); stepped, it is:
//!
//!   a submission              the message {fn: "submit", args: {beef, topics, offChainValues?}} in
//!                             a box a row routes to the engine (the app's own `<app>`, open to
//!                             anyone), or the `submission` event POST /submit admits into box
//!                             `<app>` carrying the same message (shruggr/skein#112; 0.7.3): routed —
//!                             its thread launched, paused, or answered at once; its answers go to
//!                             the sender (submit.zig `received`).
//!   the submission's thread   launched by a submission (args {event, box: "submit"}), or by the
//!                             submit event the `libp2p:<topic>` route admits (box `<app>`, row
//!                             from `event`): first step `begin` — the BEEF to the chain app (a
//!                             message to the instance itself, box `chain`: {fn: "ingest", args:
//!                             {beef}}), the submission pending; then each answer of the chain app
//!                             (input `reply`) — admitted on accepted or proven, nothing on rejected
//!                             (submit.zig). It finishes once admitted or rejected.
//!   a watch                   the message {fn: "watch", args: {txid, ingest}} in box `<app>` from
//!                             the instance itself (row from `$self`): sent by a submission admitted
//!                             on `accepted`; later answers to the same ingest message — proven
//!                             (`<topic>-proof`), rejected (the judgements removed, `rejected` hooks).
//!   a resume                  the message {fn: "resume", args: {txid}} in box `<app>` from the
//!                             instance itself (skein-overlay#1): a paused submission's parent has
//!                             come; it is routed again — its thread launched, paused again, or dropped.
//!   a peer's admit            the `peer-admit` event the `-admit` route admits (box `<app>`):
//!                             recorded under `<app>/gossip`.
//!   register / deregister     a message in any box a row routes to the engine (`<app>`, or e.g.
//!                             `<app>/overlay`, shruggr/skein#128), {fn: "register", args: {topic,
//!                             program}} or {fn: "deregister", args: {topic}}, from whoever that row
//!                             admits (topics.zig, shruggr/skein#120): the registered set under
//!                             `<app>/topics`, the subscribe / unsubscribe events; answered {topic, active}.
//!
//! The state is the overlay's own, under its app's name (state.zig: `<app>/state`), over the
//! chain app's (`chain/state`), read only. The topics and lookup services are the app's (#72,
//! config.zig): `config.overlay` of the app record `<app>/app` and the topics registered under
//! `<app>/topics`, read at every step and call. A
//! genesis-wired engine (no app record) reads the genesis config instead
//! (defaults.overlayTopics, defaults.overlayLookups, defaults.overlayGossip) and its heads are
//! under its program's name.
//!
//! Every step keeps its result record and prints its CID:
//!
//!   {kind: "overlay-result", op: "submit" | "answer" | "watch" | "watched", txid, ingest?, heard?,
//!    admitted?, steak?, unapplied?, watch?, awaiting?, published?, answers?, refs, state}
//!   {kind: "overlay-result", op: "received" | "resume", txid?, outcome, …, answers?, state}
//!   {kind: "overlay-result", op: "peer-admit", topic, txid, record, state}
//!   {kind: "overlay-result", op: "register" | "deregister", topic, active, changed, topics?}
//!   {kind: "overlay-result", op, error}                         refused
const std = @import("std");
const c = @import("chain");
const vm = @import("sk");
const ev_ = @import("engine_vm.zig");
const routes = @import("routes.zig");
const submit = @import("submit.zig");
const gossip = @import("gossip.zig");
const calls = @import("calls.zig");
const config = @import("config.zig");
const topics = @import("topics.zig");

const cbor = c.cbor;
const Value = cbor.Value;
const Allocator = std.mem.Allocator;
const eql = std.mem.eql;

pub fn main() u8 {
    return vm.main("overlay", run);
}

fn uints(a: Allocator, xs: []const u32) ![]Value {
    const out = try a.alloc(Value, xs.len);
    for (xs, out) |x, *o| o.* = .{ .uint = x };
    return out;
}

fn resultRecord(a: Allocator, op: []const u8, fields: []const cbor.Entry) !Value {
    var es: std.ArrayList(cbor.Entry) = .empty;
    try es.appendSlice(a, &.{
        .{ .key = "kind", .value = .{ .text = "overlay-result" } },
        .{ .key = "op", .value = .{ .text = op } },
    });
    try es.appendSlice(a, fields);
    return .{ .map = es.items };
}

/// A peer's `<topic>-admit` verdict (#74), admitted by the route as a `peer-admit` event: recorded
/// under the head `<app>/gossip` (key topic ‖ txid ‖ from). Nothing is admitted from it.
fn peerAdmitted(a: Allocator, step: Value, ev: Value) !void {
    const s = vm.store();
    const head = try gossip.stateHead(a, calls.appOf(step));
    var gs = try gossip.State.load(a, s, try vm.head(a, head));
    const rec = try gs.record(ev);
    try vm.keep(rec);
    const new_state = try gs.save();
    try vm.advance(head, new_state);
    // shruggr/skein#112: a submission of that transaction paused here wants its parents from that peer too.
    var fields: std.ArrayList(cbor.Entry) = .empty;
    if (ev.getBytes("peer")) |peer| {
        const txid = c.header.fromHex(ev.getText("txid") orelse return error.BadEvent) catch return error.BadEvent;
        var loaded = try ev_.load(a, step);
        const cx = submit.Ctx{ .a = a, .caller = ev_.caller(), .wire = try ev_.wire(step), .st = &loaded.st, .in = step };
        try submit.admitSeen(cx, ev.getText("topic") orelse return error.BadEvent, txid, peer);
        const wanted = try emitWants(a, &loaded.st);
        if (wanted > 0) {
            const ns = try loaded.st.save();
            try vm.advance(try ev_.stateHead(a, step), ns);
            try fields.append(a, .{ .key = "wanted", .value = .{ .uint = wanted } });
        }
    }
    try fields.appendSlice(a, &.{
        .{ .key = "topic", .value = .{ .text = ev.getText("topic") orelse "" } },
        .{ .key = "txid", .value = .{ .text = ev.getText("txid") orelse "" } },
        .{ .key = "record", .value = .{ .cid = rec } },
        .{ .key = "state", .value = .{ .cid = new_state } },
    });
    _ = try vm.finish(a, s, try resultRecord(a, "peer-admit", fields.items));
}

/// The step's want / unwant events (state.zig `wantEvents`, shruggr/skein#112), emitted. → how many.
fn emitWants(a: Allocator, st: *@import("state.zig").State) !usize {
    const evs = try st.wantEvents();
    for (evs) |w| _ = try vm.emitEvent(a, w);
    return evs.len;
}

/// The answers to submitters this step made, for its result record (shruggr/skein#112).
fn answersField(fields: *std.ArrayList(cbor.Entry), a: Allocator) !void {
    if (ev_.answers.items.len > 0) try fields.append(a, .{ .key = "answers", .value = .{ .array = ev_.answers.items } });
}

/// `register {topic, program}` / `deregister {topic}` (topics.zig, shruggr/skein#120): a message in
/// any box a row routes to the engine (shruggr/skein#128), `{fn, args}`, from whoever the row admits;
/// the app is the step's, not the box's. The set written under
/// `<app>/topics` and the events emitted when it changes; the answer `{fn, request, replyTo,
/// result: {topic, active} | error: {code, message}}` (skein docs/APPS.md §4) to the sender when a
/// message can reach it. A refusal writes and emits nothing.
fn registration(a: Allocator, step: Value, args: Value, body: Value, func: []const u8) !void {
    const s = vm.store();
    const head = try topics.headName(a, calls.appOf(step));
    const root = try vm.head(a, head);
    const list = try topics.entriesOf(a, if (root) |r| try s.getValue(a, r) else null);
    const fargs: Value = body.get("args") orelse .{ .map = &.{} };
    const change = if (eql(u8, func, "register"))
        try topics.register(a, list, fargs, step.get("programs") orelse return error.BadConfig, try config.selfRole(a, s, step, null))
    else
        try topics.deregister(a, list, fargs);
    const message = args.getCid("message") orelse return error.BadInput;
    var ans: std.ArrayList(cbor.Entry) = .empty;
    try ans.appendSlice(a, &.{
        .{ .key = "fn", .value = .{ .text = func } },
        .{ .key = "request", .value = .{ .cid = message } },
        .{ .key = "replyTo", .value = .{ .cid = message } },
    });
    var fields: std.ArrayList(cbor.Entry) = .empty;
    switch (change) {
        .refused => |why| {
            try ans.append(a, .{ .key = "error", .value = .{ .map = try a.dupe(cbor.Entry, &.{
                .{ .key = "code", .value = .{ .text = "bad-args" } },
                .{ .key = "message", .value = .{ .text = why } },
            }) } });
            try fields.append(a, .{ .key = "error", .value = .{ .text = why } });
        },
        .done => |d| {
            if (d.list) |l| {
                const rc = try s.putValue(a, try topics.recordOf(a, l));
                try vm.advance(head, rc);
                try fields.append(a, .{ .key = "topics", .value = .{ .cid = rc } });
            }
            for (d.events) |ev| _ = try vm.emitEvent(a, ev);
            try ans.append(a, .{ .key = "result", .value = d.answer });
            try fields.appendSlice(a, &.{
                .{ .key = "topic", .value = d.answer.get("topic").? },
                .{ .key = "active", .value = d.answer.get("active").? },
                .{ .key = "changed", .value = .{ .boolean = d.list != null } },
            });
        },
    }
    if (args.getBytes("sender")) |sender| if (try ev_.reaches(a, step, sender)) {
        _ = try vm.send(a, sender, topics.answerBox(args, calls.appOf(step)), .{ .map = ans.items });
    };
    _ = try vm.finish(a, s, try resultRecord(a, func, fields.items));
}

fn run(a: Allocator) anyerror!void {
    const s = vm.store();
    const in = try vm.input(a);
    if (eql(u8, in.getText("kind") orelse "", "call")) return routes.call(a, in);
    // The topics, lookup services, programs and the app's name: the app record's (config.zig), else the genesis's.
    const step = try ev_.configured(a, in, null);
    const args = step.get("args") orelse return error.BadInput;
    const reply: ?Value = if (step.get("reply")) |r| (if (r == .map) r else null) else null;

    var op: []const u8 = undefined;
    var ev: Value = .null;
    var watch_args: Value = .null;
    if (args.getCid("event")) |ec| {
        ev = try s.getValue(a, ec);
        const kind = ev.getText("kind") orelse return error.BadEvent;
        if (eql(u8, kind, "peer-admit")) return peerAdmitted(a, step, ev);
        // POST /submit's submission (0.7.3): the message step's, its source from the event.
        if (eql(u8, kind, "submission")) {
            const m = try submit.submissionOf(a, ev, args.getText("box") orelse calls.appOf(step));
            return submissionStep(a, step, m.body, m.source);
        }
        if (!eql(u8, kind, "submit")) return error.BadEvent;
        op = if (reply == null) "submit" else "answer";
    } else if (args.getCid("body")) |bc| {
        const body = try s.getValue(a, bc);
        // A submission (shruggr/skein#112): from anyone a row admits, in any box routed here.
        if (eql(u8, body.getText("fn") orelse "", "submit")) return submissionStep(a, step, body, try messageSource(a, step, args));
        // Register or deregister a topic, in whatever box a row routed it here (skein #128); in the
        // app's own box, open to anyone for submissions, from the instance itself only.
        switch (topics.asked(body)) {
            .register, .deregister => if (!topics.mayRegister(args, calls.appOf(step), vm.selfKey(step))) return error.NotAdmitted,
            .other => {},
        }
        switch (topics.asked(body)) {
            .register => return registration(a, step, args, body, "register"),
            .deregister => return registration(a, step, args, body, "deregister"),
            .other => {},
        }
        // Any other message in the app's box: from the instance itself (its own watch, a resume), nothing else.
        const me = vm.selfKey(step) orelse return error.NoIdentity;
        if (!eql(u8, args.getBytes("sender") orelse "", me)) return error.NotFromThisInstance;
        const func = body.getText("fn") orelse "";
        if (eql(u8, func, "resume")) return resumeStep(a, step, body.get("args") orelse return error.BadInput);
        if (!eql(u8, func, "watch")) return error.UnknownFn;
        watch_args = body.get("args") orelse return error.BadInput;
        op = if (reply == null) "watch" else "watched";
    } else return error.BadInput;

    var loaded = try ev_.load(a, step);
    const st = &loaded.st;
    st.now = @intCast(step.getUint("at") orelse return error.BadInput);
    const cx = submit.Ctx{
        .a = a,
        .caller = ev_.caller(),
        .wire = try ev_.wire(step),
        .out = try ev_.gossipOut(a),
        .st = st,
        .in = step,
        .thread = step.getCid("thread"),
        .gossip = try ev_.gossipState(a, step),
    };

    var fields: std.ArrayList(cbor.Entry) = .empty;
    // The ingest message this step heard (or, for a watch, awaits) the answers of.
    var ingest: ?[]const u8 = null;
    var done: submit.Stepped = undefined;
    if (eql(u8, op, "submit")) {
        const begun = try submit.begin(cx, ev);
        done = .{ .txid = try submit.txidOf(ev), .awaiting = begun.ingests, .done = begun.ingests.len == 0 };
        if (begun.ingests.len > 0) ingest = begun.ingests[begun.ingests.len - 1];
        try fields.append(a, .{ .key = "ingests", .value = .{ .array = try cids(a, begun.ingests) } });
        if (begun.paused) try fields.appendSlice(a, &.{
            .{ .key = "waiting", .value = .{ .array = try hexes(a, begun.waiting) } },
            .{ .key = "wanted", .value = .{ .uint = begun.wants.len } },
        });
    } else if (eql(u8, op, "answer")) {
        ingest = reply.?.getCid("replyTo") orelse return error.BadInput;
        const body = try s.getValue(a, reply.?.getCid("body") orelse return error.BadInput);
        done = try submit.answered(cx, ev, ingest.?, submit.answerOf(body));
    } else {
        const w = try submit.watchOf(watch_args);
        ingest = w.ingest;
        if (reply) |r| {
            done = try submit.watched(cx, w, submit.answerOf(try s.getValue(a, r.getCid("body") orelse return error.BadInput)));
        } else done = try submit.watchStart(cx, w);
        if (!done.done) done.awaiting = try a.dupe([]const u8, &.{ingest.?});
    }

    for (done.records) |r| try vm.keep(r);
    const tx_cid = try a.dupe(u8, &c.store.hashCid(.tx, done.txid));
    try fields.appendSlice(a, &.{
        .{ .key = "txid", .value = .{ .text = try a.dupe(u8, &c.header.toHex(done.txid)) } },
        .{ .key = "refs", .value = .{ .array = try a.dupe(Value, &.{.{ .map = try a.dupe(cbor.Entry, &.{
            .{ .key = "to", .value = .{ .cid = tx_cid } },
            .{ .key = "rel", .value = .{ .text = "mentions" } },
        }) }}) } },
    });
    if (ingest) |m| try fields.append(a, .{ .key = "ingest", .value = .{ .cid = m } });
    if (done.heard.len > 0) try fields.append(a, .{ .key = "heard", .value = .{ .text = done.heard } });
    if (done.admitted) {
        try fields.appendSlice(a, &.{
            .{ .key = "admitted", .value = .{ .boolean = true } },
            .{ .key = "steak", .value = try steakOf(a, done.topics, done.applied) },
        });
        // skein-overlay#1: every transaction this step admitted, oldest first.
        if (done.admissions.len > 1) {
            const xs = try a.alloc(Value, done.admissions.len);
            for (done.admissions, xs) |adm, *x| x.* = .{ .map = try a.dupe(cbor.Entry, &.{
                .{ .key = "txid", .value = .{ .text = try a.dupe(u8, &c.header.toHex(adm.txid)) } },
                .{ .key = "steak", .value = try steakOf(a, adm.topics, adm.applied) },
            }) };
            try fields.append(a, .{ .key = "admissions", .value = .{ .array = xs } });
        }
    }
    if (done.unapplied.len > 0) {
        const gone = try a.alloc(Value, done.unapplied.len);
        for (done.unapplied, gone) |u, *g| g.* = .{ .text = u.topic };
        try fields.append(a, .{ .key = "unapplied", .value = .{ .array = gone } });
    }
    if (done.watch) |wc| try fields.append(a, .{ .key = "watch", .value = .{ .cid = wc } });
    if (done.resumes.len > 0) try fields.append(a, .{ .key = "resumes", .value = .{ .array = try cids(a, done.resumes) } });
    if (done.published > 0) try fields.append(a, .{ .key = "published", .value = .{ .uint = done.published } });
    if (!done.done) {
        // Rest until the chain app answers the ingest messages still pending (again).
        for (done.awaiting) |m| try vm.awaitRecord(m);
        try fields.append(a, .{ .key = "awaiting", .value = .{ .boolean = true } });
    }
    const wanted = try emitWants(a, st);
    if (wanted > 0 and !eql(u8, op, "submit")) try fields.append(a, .{ .key = "wanted", .value = .{ .uint = wanted } });
    try answersField(&fields, a);

    const new_state = try st.save();
    if (loaded.head == null or !eql(u8, loaded.head.?, new_state)) try vm.advance(try ev_.stateHead(a, step), new_state);
    try fields.append(a, .{ .key = "state", .value = .{ .cid = new_state } });
    _ = try vm.finish(a, s, try resultRecord(a, op, fields.items));
}

fn cids(a: Allocator, xs: []const []const u8) ![]Value {
    const out = try a.alloc(Value, xs.len);
    for (xs, out) |x, *o| o.* = .{ .cid = x };
    return out;
}

fn hexes(a: Allocator, xs: []const [32]u8) ![]Value {
    const out = try a.alloc(Value, xs.len);
    for (xs, out) |x, *o| o.* = .{ .text = try a.dupe(u8, &c.header.toHex(x)) };
    return out;
}

fn steakOf(a: Allocator, topics_: []const []const u8, applied: []const @import("state.zig").Applied) !Value {
    var steak: std.ArrayList(cbor.Entry) = .empty;
    for (topics_, applied) |t, ap| try steak.append(a, .{ .key = t, .value = .{ .map = try a.dupe(cbor.Entry, &.{
        .{ .key = "outputsToAdmit", .value = .{ .array = try uints(a, ap.outputs_to_admit) } },
        .{ .key = "coinsToRetain", .value = .{ .array = try uints(a, ap.coins_to_retain) } },
        .{ .key = "coinsRemoved", .value = .{ .array = try uints(a, ap.coins_removed) } },
    }) } });
    return .{ .map = steak.items };
}

/// `resume {txid}` (skein-overlay#1), a message from the instance itself in the app's box: a parent a
/// paused submission waited on has come. Its submission routed again (submit.zig `resumed`): whole
/// now, the submission's thread launched on its event (args `{event, box: "submit"}`); still
/// missing parents, paused again; routed to nothing, the pause dropped (and its submitter answered).
fn resumeStep(a: Allocator, step: Value, rargs: Value) !void {
    const txid = c.header.fromHex(rargs.getText("txid") orelse return error.BadInput) catch return error.BadInput;
    var loaded = try ev_.load(a, step);
    loaded.st.now = @intCast(step.getUint("at") orelse return error.BadInput);
    const cx = try stepCtx(a, step, &loaded.st);
    var fields: std.ArrayList(cbor.Entry) = .empty;
    try fields.append(a, .{ .key = "txid", .value = .{ .text = try a.dupe(u8, &c.header.toHex(txid)) } });
    try settled(a, step, &loaded, try submit.resumed(cx, txid), &fields, "resume");
}

/// A submission by message (shruggr/skein#112): `{fn: "submit", args: {beef, topics,
/// offChainValues?}}` from anyone a row admits — or POST /submit's `submission` event in box
/// `<app>` (0.7.3, submit.zig `submissionOf`), which carries the same message. Its source names
/// whom the answers go to: the sender, in the box it came in, about the message (submit.zig
/// `received`).
fn submissionStep(a: Allocator, step: Value, body: Value, source: Value) !void {
    var loaded = try ev_.load(a, step);
    loaded.st.now = @intCast(step.getUint("at") orelse return error.BadInput);
    const cx = try stepCtx(a, step, &loaded.st);
    var fields: std.ArrayList(cbor.Entry) = .empty;
    try settled(a, step, &loaded, try submit.received(cx, body.get("args") orelse .null, source), &fields, "received");
}

/// A message step's source: `{transport, box, sender?, request: <the message>}`.
fn messageSource(a: Allocator, step: Value, args: Value) !Value {
    var src: std.ArrayList(cbor.Entry) = .empty;
    try src.appendSlice(a, &.{
        .{ .key = "transport", .value = .{ .text = args.getText("transport") orelse "mailbox" } },
        .{ .key = "box", .value = .{ .text = args.getText("box") orelse calls.appOf(step) } },
    });
    if (args.getBytes("sender")) |sender| try src.append(a, .{ .key = "sender", .value = .{ .bytes = sender } });
    try src.append(a, .{ .key = "request", .value = .{ .cid = args.getCid("message") orelse return error.BadInput } });
    return .{ .map = src.items };
}

fn stepCtx(a: Allocator, step: Value, st: *@import("state.zig").State) !submit.Ctx {
    return .{ .a = a, .caller = ev_.caller(), .wire = try ev_.wire(step), .st = st, .in = step, .thread = step.getCid("thread"), .gossip = try ev_.gossipState(a, step) };
}

/// A routed submission acted on (a resume, a submission by message): its thread launched, or paused,
/// or answered; the step's want events emitted; the state saved; the result kept.
fn settled(a: Allocator, step: Value, loaded: anytype, outcome: submit.Resumed, fields: *std.ArrayList(cbor.Entry), op: []const u8) !void {
    const s = vm.store();
    switch (outcome) {
        .none => try fields.append(a, .{ .key = "outcome", .value = .{ .text = "none" } }),
        .paused => |b| try fields.appendSlice(a, &.{
            .{ .key = "outcome", .value = .{ .text = "paused" } },
            .{ .key = "waiting", .value = .{ .array = try hexes(a, b.waiting) } },
        }),
        .launch => |ev| {
            const thread = step.getCid("thread") orelse return error.BadInput;
            const self = (try s.getValue(a, thread)).getCid("program") orelse return error.BadInput;
            const ec = try s.putValue(a, ev);
            const largs = try s.putValue(a, .{ .map = try a.dupe(cbor.Entry, &.{
                .{ .key = "event", .value = .{ .cid = ec } },
                .{ .key = "box", .value = .{ .text = "submit" } },
            }) });
            const t = try vm.launch(a, self, largs);
            try fields.appendSlice(a, &.{
                .{ .key = "outcome", .value = .{ .text = "launched" } },
                .{ .key = "event", .value = .{ .cid = ec } },
                .{ .key = "launched", .value = .{ .cid = t } },
            });
        },
        .dropped => |why| try fields.appendSlice(a, &.{
            .{ .key = "outcome", .value = .{ .text = "dropped" } },
            .{ .key = "why", .value = .{ .text = why } },
        }),
        .woke => try fields.append(a, .{ .key = "outcome", .value = .{ .text = "woke" } }),
    }
    const wanted = try emitWants(a, &loaded.st);
    if (wanted > 0) try fields.append(a, .{ .key = "wanted", .value = .{ .uint = wanted } });
    try answersField(fields, a);
    const new_state = try loaded.st.save();
    if (loaded.head == null or !eql(u8, loaded.head.?, new_state)) try vm.advance(try ev_.stateHead(a, step), new_state);
    try fields.append(a, .{ .key = "state", .value = .{ .cid = new_state } });
    _ = try vm.finish(a, s, try resultRecord(a, op, fields.items));
}
