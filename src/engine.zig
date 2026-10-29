//! overlay: the overlay engine (issues #36, #50, #57; re-split by skein #79).
//! Called (#40), it is the overlay's front-door route handlers (routes.zig:
//! submit, lookup, the listings and documentation); stepped, it is:
//!
//!   a submission              the message {fn: "submit", args: {beef, topics, offChainValues?}} in
//!                             a box a row routes to the engine (the stock manifest's: the
//!                             submission box `<app>/submit`, open to anyone), or the `submission`
//!                             event POST /submit admits into that same box `<app>/submit`
//!                             carrying the same message (shruggr/skein#112; 0.7.3; the box 0.7.6,
//!                             one box per function class, #128): routed — its thread launched,
//!                             paused, or answered at once; its answers go to the sender, in the
//!                             box it came in (submit.zig `received`).
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
//!                             come (or, skein-overlay#6, a parent in flight was answered for: admitted,
//!                             rejected, failed); it is routed again — its thread launched, paused
//!                             again, or dropped.
//!   a wait                    the message {fn: "wait", args: {txid}} in box `<app>` from the
//!                             instance itself (0.9.1): a POST /submit request waiting on a paused
//!                             submission — one of its waiters, answered when the pause ends, or
//!                             answered at once (submit.zig `waitOn`).
//!   a rebeat                  the message {fn: "rebeat"} in box `<app>` from the instance itself
//!                             (0.16.0): sent by the app's program that wrote the head `<app>/terms`
//!                             (the beat's terms); every registered topic's beacon re-declared.
//!   a peer's admit            the `peer-admit` event an `admit` message on `<topic>` (or one on a
//!                             `-admit` route, before 0.12.0) admits (box `<app>`): recorded under
//!                             `<app>/gossip`.
//!   register / deregister     a message in the box `<app>/register` only (one box per function
//!                             class, shruggr/skein#128, 0.7.5; refused `bad-args` elsewhere),
//!                             {fn: "register", args: {topic, program, seed?}} or {fn: "deregister",
//!                             args: {topic}}, from whoever that row admits (topics.zig,
//!                             shruggr/skein#120): the registered set under `<app>/topics`, the
//!                             subscribe / unsubscribe events, and liveness / beacon (unliveness /
//!                             unbeacon) on `<topic>-live` (0.9.0; always, 0.12.0: the beat body
//!                             the topic's view digest); answered {topic, active}; with
//!                             `seed` (0.7.8), the held seeds judged under the topic
//!                             (submit.zig `seed`), answered {…, seeded, missing, untaken?}.
//!                             The same four are taken as a call too (0.18.0, skein-overlay#10;
//!                             registry.zig `byCall`): from a program of the instance in its step.
//!   registerLookup /          a message in the box `<app>/register` only, as register (0.11.0, David
//!   deregisterLookup          2026-10-08: "separate registration calls"): {fn: "registerLookup", args:
//!                             {service, program, topics?}} or {fn: "deregisterLookup", args:
//!                             {service}} (lookups.zig): the registered set under `<app>/lookups`,
//!                             served as config.overlay.lookups is; liveness (0.12.1) and a beacon
//!                             on `<service>-live` (0.12.0: its body the lookup program's fn
//!                             "beat"), unliveness and unbeacon on deregister; answered {service, active}.
//!
//!   configured topics and    (0.17.0, configured.zig) every step first declares the topics and
//!   lookups                  lookup services `config.overlay` names (not registered) — liveness and
//!                            a beacon on `<name>-live`, as a registration's — when the configuration
//!                            differs from what the head `<app>/configured` says was declared; a
//!                            dropped name gets unliveness / unbeacon.
//!
//! The market / validator switch (0.9.2) is gone (0.12.0, David 2026-10-09: "every skein is
//! marketplace AND validator from install, always"): a message {fn: "market" | "validator"} is
//! no function of the engine. A step that changes a registered topic's view digest (an admission,
//! a rejection, a seed) re-declares its beacon with the new body, and one whose lookup hooks
//! answered new beat bodies re-declares those services' beacons (topics.zig `beatEvents`).
//!
//! The state is the overlay's own, under its app's name (state.zig: `<app>/state`), over the
//! chain app's (`chain/state`), read only. The topics and lookup services are the app's (#72,
//! config.zig): `config.overlay` of the app record `<app>/app`, the topics registered under
//! `<app>/topics` and the lookup services registered under `<app>/lookups`, read at every step
//! and call. A
//! genesis-wired engine (no app record) reads the genesis config instead
//! (defaults.overlayTopics, defaults.overlayLookups, defaults.overlayGossip) and its heads are
//! under its program's name.
//!
//! Every step keeps its result record and prints its CID:
//!
//!   {kind: "overlay-result", op: "submit" | "answer" | "watch" | "watched", txid, ingest?, heard?,
//!    admitted?, steak?, unapplied?, watch?, awaiting?, published?, beats?, answers?, refs, state}
//!   {kind: "overlay-result", op: "received" | "resume", txid?, outcome, …, answers?, state}
//!   {kind: "overlay-result", op: "peer-admit", topic, txid, record, state}
//!   {kind: "overlay-result", op: "register" | "deregister", topic, active, changed, topics?,
//!    seeded?, missing?, untaken?, admissions?, watches?, state?}
//!   {kind: "overlay-result", op: "registerLookup" | "deregisterLookup", service, active, changed,
//!    lookups?}
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
const lookups = @import("lookups.zig");
const configured = @import("configured.zig");
const registry = @import("registry.zig");

const cbor = c.cbor;
const Value = cbor.Value;
const Allocator = std.mem.Allocator;
const eql = std.mem.eql;

pub fn main() u8 {
    return vm.main("overlay", run);
}

const resultRecord = registry.resultRecord;
const cids = registry.cids;
const hexes = registry.hexes;
const steakOf = registry.steakOf;

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

/// The beacons the step re-declares (0.12.0, topics.zig `beatEvents`): each registered topic whose beat
/// (view digest, tip anchor, tail) it changed, each registered lookup service its hooks gave a new body; emitted. → how
/// many.
fn emitBeats(a: Allocator, step: Value, st: *@import("state.zig").State) !usize {
    const changes = try st.beatChanges();
    if (changes.len == 0 and st.lookup_beats.items.len == 0) return 0;
    const s = vm.store();
    const app = calls.appOf(step);
    const troot = try vm.head(a, try topics.headName(a, app));
    const tl = try topics.entriesOf(a, if (troot) |r| try s.getValue(a, r) else null);
    const services = try lookupNames(a, step);
    const roles = (try rolesNow(a, step)) orelse return 0; // a bad configuration: registering is refused
    // 0.17.0: the configured topics and services beat as the registered ones (configured.zig).
    const conf = try configuredNow(a, step, tl, services);
    const evs = try topics.beatEvents(a, roles, try std.mem.concat(a, topics.Entry, &.{ tl, conf.topics }), try std.mem.concat(a, []const u8, &.{ services, try configured.lookupNames(a, conf) }), changes, st.lookup_beats.items);
    for (evs) |e| _ = try vm.emitEvent(a, e);
    return evs.len;
}

/// The engine's roles (config.zig `rolesOf`; null: a bad configuration, error.BadRoles) with the
/// beat's terms (0.16.0): the record of the head `<app>/terms` the app writes (config.zig `termsOf`),
/// read now, at each beacon declaration.
fn rolesNow(a: Allocator, step: Value) !?topics.Roles {
    return registry.roles(a, ev_.effects(), step);
}

/// `rebeat` (0.16.0): the message `{fn: "rebeat"}` in box `<app>` from the instance itself, sent by
/// the app's program that wrote the head `<app>/terms` (skein-amm's amm-validator, on root's `terms`):
/// the engine sees no other program's head change in a step of its own, so the writer tells it.
/// Every registered topic's beacon is re-declared with its beat body now (`topics.rebeatEvents`: the
/// terms the head's, or none); the lookup services' beacons are their programs' and stay. Nothing
/// is written. Result `{op: "rebeat", beats}`, or `{op, error}` on a bad configuration.
fn rebeatStep(a: Allocator, step: Value) !void {
    const s = vm.store();
    var fields: std.ArrayList(cbor.Entry) = .empty;
    if (try rolesNow(a, step)) |roles| {
        const troot = try vm.head(a, try topics.headName(a, calls.appOf(step)));
        const registered = try topics.entriesOf(a, if (troot) |r| try s.getValue(a, r) else null);
        // 0.17.0: the configured topics' beacons too (configured.zig).
        const tl = try std.mem.concat(a, topics.Entry, &.{ registered, (try configuredNow(a, step, registered, try lookupNames(a, step))).topics });
        var loaded = try ev_.load(a, step);
        const beats = try a.alloc(@import("state.zig").Beat, tl.len);
        for (tl, beats) |e, *b| b.* = try loaded.st.beat(e.topic);
        const evs = try topics.rebeatEvents(a, roles, tl, beats);
        for (evs) |e| _ = try vm.emitEvent(a, e);
        try fields.append(a, .{ .key = "beats", .value = .{ .uint = evs.len } });
    } else try fields.append(a, .{ .key = "error", .value = .{ .text = "rebeat: the configuration's roles are config.overlay.market {window: <ms>} and config.overlay.validator {every: <ms>}, each from 1000 ms to a day" } });
    _ = try vm.finish(a, s, try resultRecord(a, "rebeat", fields.items));
}

/// What the configuration beats now (configured.zig `of`): its topics and lookup services beside the
/// registered ones (`registered`, `services`), and its terms. No app record (a genesis-wired engine): nothing.
fn configuredNow(a: Allocator, step: Value, registered: []const topics.Entry, services: []const []const u8) !configured.Now {
    const s = vm.store();
    const app = (try config.appRecord(a, s, ev_.heads(), try config.selfProgram(a, s, step, null))) orelse return .{};
    return configured.of(a, app, registered, services);
}

/// 0.17.0 (shruggr/skein-amm#4): the configured topics and lookup services declared — liveness and a
/// beacon on `<name>-live`, as a registration's (topics.zig `roleEvents`) — on the engine's first
/// step after it sees the configuration, and again whenever it changes (configured.zig: the head
/// `<app>/configured` keeps what was declared; a name dropped from the configuration gets unliveness
/// and unbeacon). A change of `config.overlay.terms` re-declares the registered topics' beacons too
/// (their bodies carry the terms while the head `<app>/terms` is unset). Nothing configured and
/// nothing declared before: nothing written. → the events emitted.
fn declareConfigured(a: Allocator, step: Value) !usize {
    const s = vm.store();
    const app = calls.appOf(step);
    const troot = try vm.head(a, try topics.headName(a, app));
    const registered = try topics.entriesOf(a, if (troot) |r| try s.getValue(a, r) else null);
    const now = try configuredNow(a, step, registered, try lookupNames(a, step));
    const head = try configured.headName(a, app);
    const proot = try vm.head(a, head);
    const prev: ?Value = if (proot) |r| try s.getValue(a, r) else null;
    const rec = try configured.recordOf(a, now);
    if (prev == null and now.topics.len == 0 and now.lookups.len == 0 and now.terms == null) return 0;
    if (try configured.same(a, prev, rec)) return 0;
    const roles = (try rolesNow(a, step)) orelse return 0; // a bad configuration: as a register, nothing declared
    var evs: std.ArrayList(Value) = .empty;
    for (try configured.dropped(a, try configured.namesOf(a, prev, "topics"), try configured.topicNames(a, now))) |t|
        try evs.appendSlice(a, try topics.roleEvents(a, false, t, roles, ""));
    for (try configured.dropped(a, try configured.namesOf(a, prev, "lookups"), try configured.lookupNames(a, now))) |l|
        try evs.appendSlice(a, try topics.roleEvents(a, false, l, roles, ""));
    var loaded = try ev_.load(a, step);
    for (now.topics) |e| try evs.appendSlice(a, try topics.roleEvents(a, true, e.topic, roles, try topics.beatBody(a, try loaded.st.beat(e.topic), roles.terms)));
    for (now.lookups) |e| try evs.appendSlice(a, try topics.roleEvents(a, true, e.service, roles, try calls.lookupBeat(a, ev_.caller(), step, e.service, e.program)));
    if (try configured.termsChanged(a, prev, rec)) {
        const beats = try a.alloc(@import("state.zig").Beat, registered.len);
        for (registered, beats) |e, *b| b.* = try loaded.st.beat(e.topic);
        try evs.appendSlice(a, try topics.rebeatEvents(a, roles, registered, beats));
    }
    for (evs.items) |e| _ = try vm.emitEvent(a, e);
    try vm.advance(head, try s.putValue(a, rec));
    return evs.items.len;
}

/// The registered lookup services' names (`<app>/lookups`).
fn lookupNames(a: Allocator, step: Value) ![]const []const u8 {
    return registry.lookupNames(a, ev_.effects(), step);
}

/// The answers to submitters this step made, for its result record (shruggr/skein#112).
fn answersField(fields: *std.ArrayList(cbor.Entry), a: Allocator) !void {
    if (ev_.answers.items.len > 0) try fields.append(a, .{ .key = "answers", .value = .{ .array = ev_.answers.items } });
}

/// `register {topic, program}` / `deregister {topic}` (topics.zig, shruggr/skein#120): a message in
/// the box `<app>/register` (one box per function class, shruggr/skein#128, 0.7.5), `{fn, args}`, from
/// whoever its row admits; in any other box refused (`bad-args`); the app is the step's. What it does
/// is registry.zig `topic` (as a call from a program of the instance, 0.18.0); the answer `{fn,
/// request, replyTo, result: {topic, active} | error: {code, message}}` (skein docs/APPS.md §4) to the
/// sender when a message can reach it. A refusal writes and emits nothing.
fn registration(a: Allocator, step: Value, args: Value, body: Value, func: []const u8) !void {
    const fargs: Value = body.get("args") orelse .{ .map = &.{} };
    const gate: ?[]const u8 = if (!topics.mayRegister(args, calls.appOf(step))) try topics.notHere(a, func, args, calls.appOf(step)) else null;
    const message = args.getCid("message") orelse return error.BadInput;
    const done = try registry.topic(a, ev_.effects(), step, fargs, func, gate);
    return answered(a, step, args, func, message, done);
}

/// `registerLookup {service, program, topics?}` / `deregisterLookup {service}` (0.11.0, lookups.zig):
/// a message in the box `<app>/register`, as register (refused `bad-args` elsewhere); registry.zig
/// `lookup`. The answer `{fn, request, replyTo, result: {service, active} | error: {code, message}}`
/// to the sender when a message can reach it. A refusal writes and emits nothing.
fn lookupRegistration(a: Allocator, step: Value, args: Value, body: Value, func: []const u8) !void {
    const fargs: Value = body.get("args") orelse .{ .map = &.{} };
    const gate: ?[]const u8 = if (!topics.mayRegister(args, calls.appOf(step))) try topics.notHere(a, func, args, calls.appOf(step)) else null;
    const message = args.getCid("message") orelse return error.BadInput;
    const done = try registry.lookup(a, ev_.effects(), step, fargs, func, gate);
    return answered(a, step, args, func, message, done);
}

/// A registration message's answer to its sender (when a message reaches it) and the step's result record.
fn answered(a: Allocator, step: Value, args: Value, func: []const u8, message: []const u8, done: registry.Done) !void {
    var ans: std.ArrayList(cbor.Entry) = .empty;
    try ans.appendSlice(a, &.{
        .{ .key = "fn", .value = .{ .text = func } },
        .{ .key = "request", .value = .{ .cid = message } },
        .{ .key = "replyTo", .value = .{ .cid = message } },
    });
    if (done.refused) |why| {
        try ans.append(a, .{ .key = "error", .value = .{ .map = try a.dupe(cbor.Entry, &.{
            .{ .key = "code", .value = .{ .text = "bad-args" } },
            .{ .key = "message", .value = .{ .text = why } },
        }) } });
    } else try ans.append(a, .{ .key = "result", .value = done.result.? });
    if (args.getBytes("sender")) |sender| if (try ev_.reaches(a, step, sender)) {
        _ = try vm.send(a, sender, topics.answerBox(args, calls.appOf(step)), .{ .map = ans.items });
    };
    _ = try vm.finish(a, vm.store(), try resultRecord(a, func, done.fields));
}

fn run(a: Allocator) anyerror!void {
    const s = vm.store();
    const in = try vm.input(a);
    if (eql(u8, in.getText("kind") orelse "", "call")) return routes.call(a, in);
    // The topics, lookup services, programs and the app's name: the app record's (config.zig), else the genesis's.
    const step = try ev_.configured(a, in, null);
    // 0.17.0: the configured topics and lookups beat, declared on the first step that sees them.
    _ = try declareConfigured(a, step);
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
        // Register or deregister a topic: taken only in the box `<app>/register` (one box per
        // function class, skein #128, 0.7.5); in any other, refused (`bad-args`).
        switch (topics.asked(body)) {
            .register => return registration(a, step, args, body, "register"),
            .deregister => return registration(a, step, args, body, "deregister"),
            .registerLookup => return lookupRegistration(a, step, args, body, "registerLookup"),
            .deregisterLookup => return lookupRegistration(a, step, args, body, "deregisterLookup"),
            .other => {},
        }
        // Any other message in the app's box: from the instance itself (its own watch, a resume), nothing else.
        const me = vm.selfKey(step) orelse return error.NoIdentity;
        if (!eql(u8, args.getBytes("sender") orelse "", me)) return error.NotFromThisInstance;
        const func = body.getText("fn") orelse "";
        if (eql(u8, func, "resume")) return resumeStep(a, step, body.get("args") orelse return error.BadInput);
        if (eql(u8, func, "wait")) return waitStep(a, step, args, body);
        if (eql(u8, func, "rebeat")) return rebeatStep(a, step);
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
        done = .{ .txid = try submit.txidOf(ev), .awaiting = begun.ingests, .done = begun.ingests.len == 0, .resumes = begun.resumes };
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
    const beats = try emitBeats(a, step, st);
    if (beats > 0) try fields.append(a, .{ .key = "beats", .value = .{ .uint = beats } });
    try answersField(&fields, a);

    const new_state = try st.save();
    if (loaded.head == null or !eql(u8, loaded.head.?, new_state)) try vm.advance(try ev_.stateHead(a, step), new_state);
    try fields.append(a, .{ .key = "state", .value = .{ .cid = new_state } });
    _ = try vm.finish(a, s, try resultRecord(a, op, fields.items));
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

/// `wait {txid}` (0.9.1), a message from the instance itself in the app's box: an HTTP request waiting
/// on a paused submission (POST /submit, routes.zig). While it is paused the message joins its
/// waiters, answered when the pause ends; else it is answered now (submit.zig `waitOn`). An answer
/// to a `wait` (`replyTo`) that found no request awaiting it is routed here too: nothing to do.
fn waitStep(a: Allocator, step: Value, args: Value, body: Value) !void {
    const s = vm.store();
    if (body.get("replyTo") != null) {
        _ = try vm.finish(a, s, try resultRecord(a, "wait", &.{.{ .key = "outcome", .value = .{ .text = "late" } }}));
        return;
    }
    const wargs = body.get("args") orelse return error.BadInput;
    const txid = c.header.fromHex(wargs.getText("txid") orelse return error.BadInput) catch return error.BadInput;
    const w = args.getCid("message") orelse return error.BadInput;
    var loaded = try ev_.load(a, step);
    loaded.st.now = @intCast(step.getUint("at") orelse return error.BadInput);
    const cx = try stepCtx(a, step, &loaded.st);
    const outcome = try submit.waitOn(cx, txid, w);
    var fields: std.ArrayList(cbor.Entry) = .empty;
    try fields.appendSlice(a, &.{
        .{ .key = "txid", .value = .{ .text = try a.dupe(u8, &c.header.toHex(txid)) } },
        .{ .key = "outcome", .value = .{ .text = @tagName(outcome) } },
    });
    const new_state = try loaded.st.save();
    if (loaded.head == null or !eql(u8, loaded.head.?, new_state)) try vm.advance(try ev_.stateHead(a, step), new_state);
    try fields.append(a, .{ .key = "state", .value = .{ .cid = new_state } });
    _ = try vm.finish(a, s, try resultRecord(a, "wait", fields.items));
}

/// A submission by message (shruggr/skein#112): `{fn: "submit", args: {beef, topics,
/// offChainValues?}}` from anyone a row admits — or POST /submit's `submission` event in box
/// `<app>/submit` (0.7.3; that box 0.7.6; submit.zig `submissionOf`), which carries the same message. Its source names
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
    const beats = try emitBeats(a, step, &loaded.st);
    if (beats > 0) try fields.append(a, .{ .key = "beats", .value = .{ .uint = beats } });
    try answersField(fields, a);
    const new_state = try loaded.st.save();
    if (loaded.head == null or !eql(u8, loaded.head.?, new_state)) try vm.advance(try ev_.stateHead(a, step), new_state);
    try fields.append(a, .{ .key = "state", .value = .{ .cid = new_state } });
    _ = try vm.finish(a, s, try resultRecord(a, op, fields.items));
}
