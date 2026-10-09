//! The overlay's front-door routes (#40): the overlay-express wire contract,
//! as route handlers the front door calls (an in-VM call with the request;
//! the app's dispatch rows name them, open (sender `*`), as overlay-express is).
//! The addresses are the app's own (`/<app>/submit`, …: its BRC-23 base URL).
//!
//!   POST /submit      fn "submit"   body BEEF, X-Topics (comma list or JSON array),
//!                                   x-includes-off-chain-values: true → VarInt(len) ‖ BEEF ‖ off-chain values
//!                                   → the STEAK {topic: {outputsToAdmit, coinsToRetain, coinsRemoved}}: BRC-22,
//!                                   synchronous (0.9.1, shruggr/skein#112) — the request waits on the
//!                                   submission's thread; 503 + Retry-After when nothing is decided
//!   libp2p:<topic>    fn "submit"   one mesh, two kinds (0.12.0; `gossip` below, gossip.zig): {kind: "submit",
//!                                   beef} the same submit as a GossipSub message (#57), the message's topic
//!                                   requested; {kind: "admit", txid, topics} a peer's verdict (#74), recorded
//!                                   as a `peer-admit` record, never admitting → {verdict, admit?}
//!   libp2p:<topic>-admit   fn "peerAdmit"   a peer's verdict on its own topic, before 0.12.0: read
//!                                           as an `admit` message is
//!   libp2p:<topic>-proof   fn "peerProof"   a peer's proof (#74): checked against the chain state,
//!                                           admitted as the `proof` event in box `chain` → {verdict, admit?}
//!   libp2p:/skein/overlay/beef/1.0.0   fn "submit"   a direct stream (skein-overlay#1, shruggr/skein#112):
//!                                           a peer answering a want, one Atomic BEEF per frame (the
//!                                           wanted txid its subject), submitted as from that peer
//!                                           with the topics its waiters requested → {verdict, admit?}
//!   POST /lookup      fn "lookup"   {service, query} (JSON) → {type: "output-list", outputs: [{beef, outputIndex, context?}]}
//!                                   X-Aggregation: yes → the compact octet-stream form (count, [txid, index, context], one BEEF)
//!   GET  /listTopicManagers, /listLookupServiceProviders         fn "listTopicManagers" / "listLookupServiceProviders"
//!   GET  /getDocumentationForTopicManager?manager=…              fn "topicDocumentation"
//!   GET  /getDocumentationForLookupServiceProvider?lookupService=…  fn "lookupDocumentation"
//!
//! Every request is appended, and the front door's step calls these (#68).
//! A submit over HTTP is BRC-22 (0.9.1, shruggr/skein#112, David 2026-10-07: "the HTTP
//! `/submit` route is BRC-22 or it does not exist"; 0.7.1's route restored): the handler runs the
//! route's half (submit.zig `route`) and launches the submission's thread, answering {wait:
//! true}: the request's thread waits on it (#66), and called again (`resolved`) it answers
//! from the state — the STEAK; 400 if the chain app rejected it; 503 with Retry-After if
//! nothing is decided (`httpFirst`, `httpAgain`). A bad BEEF answers 400; a valid
//! transaction no topic took, 200 with the empty STEAK; judged before, the STEAK from the
//! state, nothing run again; in progress (a resubmission), a wait on its thread. A missing
//! parent pauses the submission (its thread records the pause); the request then sends the
//! instance itself `wait {txid}` and awaits it: the engine answers it when the pause ends
//! (submit.zig `waitOn`), and the request reads the state again.
//!
//! A lookup is a read: the service's program is called (fn "lookup", the
//! lookup contract, lookup.zig) and its answer shaped for the wire; it
//! writes nothing but the request's own record. Listings and documentation
//! are the programs' own answers: each configured topic's or service's
//! program is called (fn "metadata" / "documentation", topic.zig and
//! lookup.zig) and its answer shaped for the wire; they read no file.
const std = @import("std");
const c = @import("chain");
const vm = @import("sk");
const ev_ = @import("engine_vm.zig");
const submit_mod = @import("submit.zig");
const gossip_mod = @import("gossip.zig");
const calls = @import("calls.zig");
const state = @import("state.zig");

const cbor = c.cbor;
const Value = cbor.Value;
const State = state.State;
const Allocator = std.mem.Allocator;
const eql = std.mem.eql;

// ---------------------------------------------------------------- answers

fn respond(a: Allocator, status: u64, typ: []const u8, body: []const u8) !Value {
    return .{ .map = try a.dupe(cbor.Entry, &.{
        .{ .key = "status", .value = .{ .uint = status } },
        .{ .key = "type", .value = .{ .text = typ } },
        .{ .key = "body", .value = .{ .bytes = body } },
    }) };
}

fn jsonOf(a: Allocator, v: anytype) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    try std.json.Stringify.value(v, .{}, &out.writer);
    return out.written();
}

/// overlay-express's error form: {status: "error", message}.
fn failure(a: Allocator, status: u64, message: []const u8) !Value {
    return respond(a, status, "application/json", try jsonOf(a, .{ .status = "error", .message = message }));
}

/// A dag-cbor value as JSON (bytes as a number array, links as {"/": hex}).
fn writeJson(a: Allocator, jw: *std.json.Stringify, v: Value) !void {
    switch (v) {
        .uint => |n| try jw.write(n),
        .nint => |n| try jw.write(-1 - @as(i128, n)),
        .text => |t| try jw.write(t),
        .boolean => |b| try jw.write(b),
        .null => try jw.write(null),
        .float => |f| try jw.write(f),
        .bytes => |b| {
            try jw.beginArray();
            for (b) |x| try jw.write(x);
            try jw.endArray();
        },
        .cid => |cv| {
            try jw.beginObject();
            try jw.objectField("/");
            try jw.write(try vm.hexAlloc(a, cv));
            try jw.endObject();
        },
        .array => |xs| {
            try jw.beginArray();
            for (xs) |x| try writeJson(a, jw, x);
            try jw.endArray();
        },
        .map => |es| {
            try jw.beginObject();
            for (es) |e| {
                try jw.objectField(e.key);
                try writeJson(a, jw, e.value);
            }
            try jw.endObject();
        },
    }
}

fn toJson(a: Allocator, v: Value) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    var jw: std.json.Stringify = .{ .writer = &out.writer };
    try writeJson(a, &jw, v);
    return out.written();
}

/// Client JSON → dag-cbor: integers stay integers; a non-integral number is refused (dag-cbor floats are not canonical here).
fn fromJson(a: Allocator, j: std.json.Value) !Value {
    return switch (j) {
        .null => .null,
        .bool => |b| .{ .boolean = b },
        .integer => |i| if (i >= 0) .{ .uint = @intCast(i) } else .{ .nint = @intCast(-1 - i) },
        .float, .number_string => error.NonIntegralNumber,
        .string => |s| .{ .text = s },
        .array => |arr| blk: {
            const out = try a.alloc(Value, arr.items.len);
            for (arr.items, out) |x, *o| o.* = try fromJson(a, x);
            break :blk .{ .array = out };
        },
        .object => |o| blk: {
            var es: std.ArrayList(cbor.Entry) = .empty;
            var it = o.iterator();
            while (it.next()) |e| try es.append(a, .{ .key = e.key_ptr.*, .value = try fromJson(a, e.value_ptr.*) });
            break :blk .{ .map = es.items };
        },
    };
}

// ---------------------------------------------------------------- the request

fn header(req: Value, name: []const u8) ?[]const u8 {
    const hs = req.get("headers") orelse return null;
    return hs.getText(name);
}

/// One query parameter, percent-decoded.
fn param(a: Allocator, req: Value, name: []const u8) !?[]const u8 {
    const q = req.getText("query") orelse return null;
    var it = std.mem.splitScalar(u8, if (std.mem.startsWith(u8, q, "?")) q[1..] else q, '&');
    while (it.next()) |kv| {
        const i = std.mem.indexOfScalar(u8, kv, '=') orelse continue;
        if (!eql(u8, kv[0..i], name)) continue;
        const v = try a.dupe(u8, kv[i + 1 ..]);
        for (v) |*ch| if (ch.* == '+') {
            ch.* = ' ';
        };
        return std.Uri.percentDecodeInPlace(v);
    }
    return null;
}

/// X-Topics: a JSON array of names, or (the SDK's form) a comma-separated list.
fn parseTopics(a: Allocator, text: []const u8) ![]const []const u8 {
    const v = std.mem.trim(u8, text, " \t");
    var out: std.ArrayList([]const u8) = .empty;
    if (std.mem.startsWith(u8, v, "[")) {
        const j = std.json.parseFromSliceLeaky(std.json.Value, a, v, .{}) catch return error.BadTopics;
        if (j != .array) return error.BadTopics;
        for (j.array.items) |t| {
            if (t != .string or t.string.len == 0) return error.BadTopics;
            try out.append(a, t.string);
        }
    } else {
        var it = std.mem.splitScalar(u8, v, ',');
        while (it.next()) |t| {
            const x = std.mem.trim(u8, t, " \t");
            if (x.len == 0) return error.BadTopics;
            try out.append(a, x);
        }
    }
    return out.items;
}

fn readVarInt(b: []const u8, pos: *usize) !u64 {
    if (pos.* >= b.len) return error.Truncated;
    const f = b[pos.*];
    pos.* += 1;
    const n: usize = switch (f) {
        0xfd => 2,
        0xfe => 4,
        0xff => 8,
        else => return f,
    };
    if (pos.* + n > b.len) return error.Truncated;
    var v: u64 = 0;
    for (0..n) |i| v |= @as(u64, b[pos.* + i]) << @intCast(8 * i);
    pos.* += n;
    return v;
}

fn writeVarInt(a: Allocator, out: *std.ArrayList(u8), v: u64) !void {
    if (v < 0xfd) return out.append(a, @intCast(v));
    const n: usize, const f: u8 = if (v <= 0xffff) .{ 2, 0xfd } else if (v <= 0xffff_ffff) .{ 4, 0xfe } else .{ 8, 0xff };
    try out.append(a, f);
    for (0..n) |i| try out.append(a, @truncate(v >> @intCast(8 * i)));
}

// ---------------------------------------------------------------- config

/// A name → program map from the config (defaults.<key>, a JSON object in a string: the app record's
/// `config.overlay` or the genesis's, config.zig).
pub const configMap = calls.configObject;

/// The program record a served name runs: `programs` (the app's roles, or the genesis's) by the configured name.
pub const programFor = calls.configuredProgram;

/// The overlay's state over the chain state, through the call's store (its write cache).
fn load(a: Allocator, in: Value) !State {
    var l = try ev_.load(a, in);
    l.st.now = @intCast(in.getUint("now") orelse 0);
    return l.st;
}

// ---------------------------------------------------------------- the handlers

/// A call of the engine (input kind "call"): the route handlers above.
pub fn call(a: Allocator, call_in: Value) !void {
    const func = call_in.getText("fn") orelse return error.BadInput;
    const arg = try vm.callArg(a, call_in);
    // The topics, lookup services and programs: the app record's (#72, config.zig; the route names the
    // engine's program record), else the genesis's.
    const in = try ev_.configured(a, call_in, arg);
    const out = if (eql(u8, func, "submit"))
        try submit(a, in, arg)
    else if (eql(u8, func, "peerAdmit"))
        try peerAdmit(a, in, arg)
    else if (eql(u8, func, "peerProof"))
        try peerProof(a, in, arg)
    else if (eql(u8, func, "lookup"))
        try lookup(a, in, arg)
    else if (eql(u8, func, "listTopicManagers"))
        try listing(a, in, "overlayTopics")
    else if (eql(u8, func, "listLookupServiceProviders"))
        try listing(a, in, "overlayLookups")
    else if (eql(u8, func, "topicDocumentation"))
        try documentation(a, in, "overlayTopics", (try param(a, arg, "manager")) orelse "", "Topic manager")
    else if (eql(u8, func, "lookupDocumentation"))
        try documentation(a, in, "overlayLookups", (try param(a, arg, "lookupService")) orelse "", "Lookup service")
    else
        return error.UnknownFunction;
    // A read route's filter (shruggr/skein#143: /lookup, the listings, the documentation): the
    // http answer as the filter's `{answer: …}` (the request ends there; nothing is logged).
    try vm.answer(a, if (isFilter(call_in)) try asFilterAnswer(a, out) else out);
}

/// Whether this call is a filter's: the input's `filter: true` (skein docs/APPS.md §2 "Filters").
pub fn isFilter(in: Value) bool {
    const f = in.get("filter") orelse return false;
    return f == .boolean and f.boolean;
}

/// An http answer `{status, type, body}` as a filter's `{answer: {status, type, body}}`.
pub fn asFilterAnswer(a: Allocator, http: Value) !Value {
    return .{ .map = try a.dupe(cbor.Entry, &.{.{ .key = "answer", .value = http }}) };
}

/// The requested topics this instance serves, in request order, once each.
fn served(a: Allocator, requested: []const []const u8, map: std.json.ObjectMap) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    outer: for (requested) |t| {
        if (!map.contains(t)) continue;
        for (out.items) |x| if (eql(u8, x, t)) continue :outer;
        try out.append(a, t);
    }
    return out.items;
}

fn submit(a: Allocator, in: Value, req: Value) !Value {
    if (eql(u8, req.getText("transport") orelse "", "libp2p")) {
        if (req.getText("protocol") != null) return stream(a, in, req);
        return gossip(a, in, req);
    }
    const sub = switch (try httpRequest(a, req)) {
        .refused => |answer| return answer,
        .ok => |x| x,
    };
    var st = try load(a, in);
    const source = try sourceOf(a, req, null);
    const next = if (httpWoken(req))
        try httpAgain(a, ev_.caller(), &st, in, sub, source)
    else
        try httpFirst(a, ev_.caller(), &st, in, sub, source);
    switch (next) {
        .answer => |v| return v,
        // The submission's thread, launched by this request's step, which waits on it (#66); its
        // answer, when it comes to rest, is the state's (`httpAgain`).
        .launch => |ev| {
            const self = in.getCid("engine") orelse (in.get("programs") orelse return error.BadInput).getCid("overlay") orelse return error.NoOverlayProgram;
            const ec = try vm.store().putValue(a, ev);
            const args = try vm.store().putValue(a, .{ .map = try a.dupe(cbor.Entry, &.{
                .{ .key = "event", .value = .{ .cid = ec } },
                .{ .key = "box", .value = .{ .text = "submit" } },
            }) });
            _ = try vm.launch(a, self, args);
            return waiting(a);
        },
        // In progress in a thread of its own (a resubmission, #66): this request waits on that same
        // thread. At rest already (the kernel refuses the await): the state answers.
        .await_thread => |t| {
            vm.awaitRecord(t) catch return (try steakAnswer(a, &st, try httpSubject(a, &st, sub), try served(a, sub.requested, try configMap(a, in, "overlayTopics")))) orelse undecided(a);
            return waiting(a);
        },
        // Paused on a parent it lacks: this request waits for the pause to end — the message
        // `wait {txid}` to the instance itself, awaited; the engine answers it when the pause ends.
        .wait_pause => |txid| {
            const w = try (try ev_.wire(in)).send(a, calls.appOf(in), try submit_mod.waitBody(a, txid));
            try vm.awaitRecord(w);
            return waiting(a);
        },
    }
}

/// The Retry-After (whole seconds) of a 503: a submission still undecided past the host's bound.
pub const retry_after = 30;

/// POST /submit, read: the topics requested (X-Topics) and the BEEF — the door's envelope
/// (shruggr/skein#121, #146, the route's `kernel.beef`), or bytes (a body framed with off-chain values,
/// the framing taken off). Not a submission: the 400 answer.
pub const HttpSubmit = struct { beef: submit_mod.Input, requested: []const []const u8, off: ?[]const u8 = null };

pub fn httpRequest(a: Allocator, req: Value) !union(enum) { refused: Value, ok: HttpSubmit } {
    const th = header(req, "x-topics") orelse return .{ .refused = try failure(a, 400, "Missing x-topics header") };
    const requested = parseTopics(a, th) catch return .{ .refused = try failure(a, 400, "Invalid x-topics header: expected a comma-separated list or JSON string array") };
    if (submit_mod.Input.of(req.get("body"))) |i| if (i == .envelope) return .{ .ok = .{ .beef = i, .requested = requested } };
    var body = req.getBytes("body") orelse "";
    if (body.len == 0) return .{ .refused = try failure(a, 400, "Missing or empty BEEF body") };
    var off: ?[]const u8 = null;
    if (eql(u8, header(req, "x-includes-off-chain-values") orelse "", "true")) {
        var pos: usize = 0;
        const n64 = readVarInt(body, &pos) catch return .{ .refused = try failure(a, 400, "Invalid off-chain values framing") };
        if (n64 > body.len - pos) return .{ .refused = try failure(a, 400, "Invalid off-chain values framing") };
        const n: usize = @intCast(n64);
        off = body[pos + n ..];
        body = body[pos .. pos + n];
    }
    return .{ .ok = .{ .beef = .{ .bytes = body }, .requested = requested, .off = off } };
}

/// What POST /submit's handler does next (0.9.1, shruggr/skein#112, David 2026-10-07: BRC-22,
/// synchronous): answer now, launch the submission's thread and wait on it, wait on the thread
/// already carrying it, or wait for its pause to end.
pub const HttpNext = union(enum) {
    answer: Value,
    /// The submit event to launch the submission's thread on (a paused one's records the pause).
    launch: Value,
    /// The thread carrying the submission (its pending record's `thread`): await it.
    await_thread: []const u8,
    /// The paused submission of this subject: wait for the pause to end (`wait`).
    wait_pause: [32]u8,
};

/// Whether the handler is called again (#66): the thread it waited on came to rest (`resolved`),
/// the answer to its `wait` (`reply`), a deadline (`woke`).
pub fn httpWoken(req: Value) bool {
    return req.get("resolved") != null or req.get("reply") != null or req.get("woke") != null;
}

/// The first call: the route's half (verify, judge), then what it came to. A bad BEEF answers 400;
/// a valid transaction no topic took, 200 with the empty STEAK (BRC-22); judged before, the STEAK
/// from the state, nothing run again; in progress, a wait on its thread; paused already, a wait
/// for the pause to end; whole, its thread launched (a pause, its thread launched to record it).
/// Only transactions before the subject taken (the subject by no topic): 200 with the empty STEAK
/// now, the submit event admitted into the app's box for its thread.
pub fn httpFirst(a: Allocator, caller: calls.Caller, st: *State, in: Value, sub: HttpSubmit, source: Value) !HttpNext {
    const topics = try served(a, sub.requested, try configMap(a, in, "overlayTopics"));
    return switch (try submit_mod.route(a, caller, st, in, sub.beef, topics, sub.off, source)) {
        .refused => |why| .{ .answer = try failure(a, 400, why) },
        .nothing => .{ .answer = try emptySteak(a, topics) },
        .unchanged => |t| .{ .answer = (try steakAnswer(a, st, t, topics)) orelse try emptySteak(a, topics) },
        .pending => |t| try onThread(a, st, t, topics),
        .paused => |p| if (try st.isPaused(p.txid)) .{ .wait_pause = p.txid } else .{ .launch = p.event },
        .admit => |x| if (submit_mod.subjectTaken(x.event)) .{ .launch = x.event } else blk: {
            var answer = try emptySteak(a, topics);
            answer.map = try std.mem.concat(a, cbor.Entry, &.{ answer.map, &.{.{ .key = "admit", .value = try admitOne(a, x.event, calls.appOf(in)) }} });
            break :blk .{ .answer = answer };
        },
    };
}

/// Called again (#66): what the state says now. Judged → the STEAK; in a thread → wait on it;
/// paused → wait for the pause to end; rejected by the chain app → 400; held, taken by no topic →
/// the empty STEAK; else the route's answer for what it is now (refused → 400, taken by nothing →
/// the empty STEAK) or, nothing decided, 503 with Retry-After — the client resubmits, a poll on
/// the same flow. Nothing is launched again.
pub fn httpAgain(a: Allocator, caller: calls.Caller, st: *State, in: Value, sub: HttpSubmit, source: Value) !HttpNext {
    const topics = try served(a, sub.requested, try configMap(a, in, "overlayTopics"));
    const txid = httpSubject(a, st, sub) catch return .{ .answer = try failure(a, 400, "Invalid BEEF") };
    if (try steakAnswer(a, st, txid, topics)) |v| return .{ .answer = v };
    if (try st.isPaused(txid)) return .{ .wait_pause = txid };
    if (try st.isPending(txid)) return onThread(a, st, txid, topics);
    if (try st.ch.settlementCid(txid)) |sc| {
        const rec = try st.store.getValue(a, sc);
        return .{ .answer = try failure(a, 400, try std.fmt.allocPrint(a, "Transaction rejected: {s}", .{rec.getText("reason") orelse "rejected"})) };
    }
    if (try st.ch.holds(txid)) return .{ .answer = try emptySteak(a, topics) };
    return switch (try submit_mod.route(a, caller, st, in, sub.beef, topics, sub.off, source)) {
        .refused => |why| .{ .answer = try failure(a, 400, why) },
        .nothing => .{ .answer = try emptySteak(a, topics) },
        .unchanged => |t| .{ .answer = (try steakAnswer(a, st, t, topics)) orelse try emptySteak(a, topics) },
        else => .{ .answer = try undecided(a) },
    };
}

/// The subject of the request's BEEF.
fn httpSubject(a: Allocator, st: *State, sub: HttpSubmit) ![32]u8 {
    return switch (sub.beef) {
        .envelope => |e| try envelopeSubject(a, st.store, e),
        .bytes => |b| (try c.beef.parse(a, b)).subject() orelse error.BadBeef,
    };
}

/// The subject of the door's envelope (shruggr/skein#146): the envelope's, else the pointer
/// record's last transaction (skein-sdk `record.subjectOf`).
fn envelopeSubject(a: Allocator, s: c.store.Store, envelope: Value) ![32]u8 {
    const e = c.record.envelopeOf(envelope) orelse return error.BadBeef;
    return c.record.subjectOf(e, try s.getValue(a, e.beef)) orelse error.BadBeef;
}

/// In progress in a thread (its pending record's): wait on it; no thread named → undecided.
fn onThread(a: Allocator, st: *State, txid: [32]u8, topics: []const []const u8) !HttpNext {
    const rec = (try st.pendingRecord(txid)) orelse return .{ .answer = (try steakAnswer(a, st, txid, topics)) orelse try undecided(a) };
    const thread = rec.getCid("thread") orelse return .{ .answer = try undecided(a) };
    return .{ .await_thread = thread };
}

/// A route handler's "not yet" (#66): it launched, or awaits, what its answer depends on.
fn waiting(a: Allocator) !Value {
    return .{ .map = try a.dupe(cbor.Entry, &.{.{ .key = "wait", .value = .{ .boolean = true } }}) };
}

/// 503 with Retry-After: nothing decided yet; the client resubmits.
pub fn undecided(a: Allocator) !Value {
    return .{ .map = try a.dupe(cbor.Entry, &.{
        .{ .key = "status", .value = .{ .uint = 503 } },
        .{ .key = "type", .value = .{ .text = "application/json" } },
        .{ .key = "headers", .value = .{ .map = try a.dupe(cbor.Entry, &.{.{ .key = "retry-after", .value = .{ .text = try std.fmt.allocPrint(a, "{d}", .{retry_after}) } }}) } },
        .{ .key = "body", .value = .{ .bytes = try jsonOf(a, .{ .status = "error", .message = "Not yet decided: nothing is admitted until the network accepts it. Resubmit after Retry-After seconds." }) } },
    }) };
}

/// BRC-22's STEAK: `{<topic>: {outputsToAdmit, coinsToRetain, coinsRemoved}}`.
const Steak = struct {
    topics: []const []const u8,
    entries: []const [3][]const u64,

    pub fn jsonStringify(s: Steak, jw: anytype) !void {
        try jw.beginObject();
        for (s.topics, s.entries) |t, e| {
            try jw.objectField(t);
            try jw.write(.{ .outputsToAdmit = e[0], .coinsToRetain = e[1], .coinsRemoved = e[2] });
        }
        try jw.endObject();
    }
};

/// 200 with the empty STEAK: a valid transaction no topic took (BRC-22).
fn emptySteak(a: Allocator, topics: []const []const u8) !Value {
    const entries = try a.alloc([3][]const u64, topics.len);
    for (entries) |*e| e.* = .{ &.{}, &.{}, &.{} };
    return respond(a, 200, "application/json", try jsonOf(a, Steak{ .topics = topics, .entries = entries }));
}

/// 200 with the STEAK from the state (each topic's `applied` record; empty for a topic that took
/// nothing), or null when no topic has judged it.
fn steakAnswer(a: Allocator, st: *State, txid: [32]u8, topics: []const []const u8) !?Value {
    const entries = try a.alloc([3][]const u64, topics.len);
    var any = false;
    for (topics, entries) |t, *e| {
        e.* = .{ &.{}, &.{}, &.{} };
        const rec = (try st.appliedRecord(t, txid)) orelse continue;
        any = true;
        e.* = .{ try uintsJson(a, rec.getArray("outputsToAdmit") orelse &.{}), try uintsJson(a, rec.getArray("coinsToRetain") orelse &.{}), try uintsJson(a, rec.getArray("coinsRemoved") orelse &.{}) };
    }
    if (!any) return null;
    return try respond(a, 200, "application/json", try jsonOf(a, Steak{ .topics = topics, .entries = entries }));
}

fn uintsJson(a: Allocator, xs: []const Value) ![]u64 {
    const out = try a.alloc(u64, xs.len);
    for (xs, out) |x, *o| o.* = if (x == .uint) x.uint else return error.BadState;
    return out;
}

/// The box, after the app's name, submissions come in (one box per function class,
/// shruggr/skein#128, 0.7.6): `submit`, resolved `<app>/submit`.
pub const submit_box = "submit";

/// `<app>/submit`: where POST /submit admits its submission event.
pub fn submitBox(a: Allocator, app: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "{s}/{s}", .{ app, submit_box });
}

/// A GossipSub message on `libp2p:<topic>` (#57; one mesh, two kinds since 0.12.0, David
/// 2026-10-09; gossip.zig): its dag-cbor body's `kind` says which.
///
///   submit  {kind: "submit", beef: bytes}: the same submit, the message's topic the one requested,
///           its `beef` the BEEF (no off-chain values; inside the body, so the engine decodes and
///           checks it itself, submit.zig `Input.bytes`), and the route's half runs unchanged. The
///           answer is the libp2p handler contract (skein docs/MESSAGES.md, "libp2p"): accept,
///           admitting the submit event in box `<app>` (routed after the message's own `p2p` event:
///           the app's row from `event` launches the same engine thread a submission launches), so
///           the verdict goes back at once — GossipSub's validator waits on nothing further;
///           ignore — no forward, no penalty — when nothing is new or the BEEF is refused (a
///           refusal may be this instance's missing headers, not the publisher's fault).
///   admit   {kind: "admit", txid, topics}: a peer's verdict, recorded as `peerAdmit` records one
///           arriving on `<topic>-admit` (before 0.12.0).
///
/// Anything else (not dag-cbor, no or another kind) is ignored. The topic is the message's; it is
/// served when the configuration names it: declared (`config.overlay.topics`) or registered
/// (`<app>/topics`, config.zig adds them), as for `peerProof`.
fn gossip(a: Allocator, in: Value, req: Value) !Value {
    const t = req.getText("topic") orelse return verdictOf(a, "ignore", "not a topic message");
    const body = req.getBytes("body") orelse "";
    if (body.len == 0) return verdictOf(a, "ignore", "Missing or empty body");
    const m = gossip_mod.messageOf(a, body) catch return verdictOf(a, "ignore", "not a submit or admit message (dag-cbor {kind: \"submit\" | \"admit\", …})");
    const topics = try served(a, &.{t}, try configMap(a, in, "overlayTopics"));
    if (topics.len == 0) return verdictOf(a, "ignore", "the topic is not served here");
    switch (m) {
        .admit => |b| return admitOf(a, in, req, t, b),
        .submit => |b| {
            var st = try load(a, in);
            return libp2pRouted(a, in, &st, .{ .bytes = b }, topics, try sourceOf(a, req, t), req);
        },
    }
}

/// The route's half for a libp2p submission (a topic message, a stream frame) → its verdict.
/// skein-overlay#1: a BEEF lacking parents is accepted as any submission (its thread pauses it and
/// records the wants against the peer); ignored when that peer is asked for them on its behalf already.
fn libp2pRouted(a: Allocator, in: Value, st: *State, beef: submit_mod.Input, topics: []const []const u8, source: Value, req: Value) !Value {
    const routed = switch (try submit_mod.route(a, ev_.caller(), st, in, beef, topics, null, source)) {
        .refused => |why| return verdictOf(a, "ignore", why),
        .nothing => |why| return verdictOf(a, "ignore", why),
        .unchanged => return verdictOf(a, "ignore", "already judged"),
        .pending => return verdictOf(a, "ignore", "already submitted: awaiting the chain app"),
        .paused => |p| if (try samePause(st, p.txid, p.waiting) and try st.wantsFrom(p.txid, p.waiting, topics, req.getBytes("from") orelse ""))
            return verdictOf(a, "ignore", "already submitted by this peer: waiting for its parents")
        else
            p.event,
        .admit => |x| x.event,
    };
    return accepting(a, routed, calls.appOf(in));
}

/// A frame on the direct stream `/skein/overlay/beef/1.0.0` (skein-overlay#1, shruggr/skein#112):
/// a peer answering a want, one Atomic BEEF per frame, the wanted txid its subject. Submitted as
/// from that peer (the stream's remote, `from`), with the topics the paused submissions waiting on
/// it requested (`wantedTopics`); it may itself pause and want. Not wanted here: ignore. The answer
/// is the route's verdict as for a topic message (no reply frame: no `body`).
fn stream(a: Allocator, in: Value, req: Value) !Value {
    // shruggr/skein#146: the door's envelope (the route's `kernel.beef`), or the bytes as received.
    const beef: submit_mod.Input = submit_mod.Input.of(req.get("body")) orelse .{ .bytes = "" };
    if (beef == .bytes and beef.bytes.len == 0) return verdictOf(a, "ignore", "Missing or empty BEEF body");
    const subject = switch (beef) {
        .envelope => |e| envelopeSubject(a, vm.store(), e) catch return verdictOf(a, "ignore", "Invalid BEEF"),
        .bytes => |b| (c.beef.parse(a, b) catch return verdictOf(a, "ignore", "Invalid BEEF")).subject() orelse return verdictOf(a, "ignore", "Invalid BEEF: no subject"),
    };
    var st = try load(a, in);
    const topics = try served(a, try submit_mod.wantedTopics(a, &st, subject), try configMap(a, in, "overlayTopics"));
    if (topics.len == 0) return verdictOf(a, "ignore", "not wanted here");
    return libp2pRouted(a, in, &st, beef, topics, try sourceOf(a, req, null), req);
}

/// Where a submission came from, carried on its entry (#74: an admission re-publishes it on `<topic>`
/// unless it arrived by gossip on that topic, or on a stream): {transport, topic? (the libp2p
/// topic), protocol? (a libp2p stream's), from? (the libp2p peer: whom its wants are asked of,
/// skein-overlay#1), request}.
fn sourceOf(a: Allocator, req: Value, topic: ?[]const u8) !Value {
    var es: std.ArrayList(cbor.Entry) = .empty;
    const transport = req.getText("transport") orelse "http";
    try es.append(a, .{ .key = "transport", .value = .{ .text = transport } });
    if (topic) |t| try es.append(a, .{ .key = "topic", .value = .{ .text = t } });
    if (eql(u8, transport, "libp2p")) {
        if (req.getText("protocol")) |p| try es.append(a, .{ .key = "protocol", .value = .{ .text = p } });
        if (req.getBytes("from")) |f| try es.append(a, .{ .key = "from", .value = .{ .bytes = f } });
    }
    if (req.getCid("request")) |rc| try es.append(a, .{ .key = "request", .value = .{ .cid = rc } });
    return .{ .map = es.items };
}

/// A peer's verdict on `libp2p:<topic>-admit` (#74; before 0.12.0 — now an `admit` message on
/// `<topic>`, `gossip`): {txid, topics: {<topic>: {outputsToAdmit, coinsToRetain}}}. Read as one on
/// `<topic>` is (`admitOf`). Ignore when not an `-admit` topic.
fn peerAdmit(a: Allocator, in: Value, req: Value) !Value {
    if (!eql(u8, req.getText("transport") orelse "", "libp2p")) return failure(a, 400, "peerAdmit takes libp2p topic messages");
    const gt = req.getText("topic") orelse return verdictOf(a, "ignore", "not a topic message");
    const t = gossip_mod.baseOf(gt, gossip_mod.admit_suffix) orelse return verdictOf(a, "ignore", "not an -admit topic");
    return admitOf(a, in, req, t, req.getBytes("body") orelse "");
}

/// A peer's verdict for `t` (#74). Never admits anything: accept admits a `peer-admit` event (box
/// `<app>`) the engine records under the head `<app>/gossip` (gossip.zig), a read for a lookup or
/// a UI. Ignore when the topic is not served here or the body is not that shape.
fn admitOf(a: Allocator, in: Value, req: Value, t: []const u8, body: []const u8) !Value {
    if (!(try configMap(a, in, "overlayTopics")).contains(t)) return verdictOf(a, "ignore", "the topic is not served here");
    const from = req.getBytes("key") orelse return verdictOf(a, "ignore", "no publisher key");
    const m = gossip_mod.parseAdmit(a, body, t) catch |e| return verdictOf(a, "ignore", @errorName(e));
    return accepting(a, try gossip_mod.peerAdmitRecord(a, t, m, from, req.getBytes("from")), calls.appOf(in));
}

/// A peer's proof on `libp2p:<topic>-proof` (#74): {txid, blockHash, blockHeight, bump}. The proof-in
/// wiring of #65 for the topics this overlay runs: checked against the chain app's state (the
/// transaction held there, the BUMP's root our header's at blockHeight, that header's hash blockHash)
/// and admitted as the `proof` event in box `chain` — the chain app's event row, as the host's
/// broadcaster admits one; the chain app records it, and its answer (`proven`, with `via`) admits a
/// pending submission (#73). Anything else is ignore, never reject: a proof we cannot check may be our
/// missing headers.
fn peerProof(a: Allocator, in: Value, req: Value) !Value {
    if (!eql(u8, req.getText("transport") orelse "", "libp2p")) return failure(a, 400, "peerProof takes libp2p topic messages");
    const gt = req.getText("topic") orelse return verdictOf(a, "ignore", "not a topic message");
    const t = gossip_mod.baseOf(gt, gossip_mod.proof_suffix) orelse return verdictOf(a, "ignore", "not a -proof topic");
    if (!(try configMap(a, in, "overlayTopics")).contains(t)) return verdictOf(a, "ignore", "the topic is not served here");
    const p = gossip_mod.parseProof(a, req.getBytes("body") orelse "") catch |e| return verdictOf(a, "ignore", @errorName(e));
    var st = try load(a, in);
    // Only for a transaction this overlay admitted under the topic, or holds pending.
    if (!(try st.isApplied(t, p.txid)) and !(try st.isPending(p.txid))) return verdictOf(a, "ignore", "not admitted under this topic, nor pending here");
    return switch (try gossip_mod.checkProof(a, st.ch, p, try std.fmt.allocPrint(a, "libp2p:{s}", .{gt}))) {
        .ignore => |why| verdictOf(a, "ignore", why),
        .event => |ev| accepting(a, ev, "chain"),
    };
}

/// Accept, admitting one event into `box` (after the message's own `p2p` event, which the front door admits first).
fn accepting(a: Allocator, ev: Value, box: []const u8) !Value {
    return .{ .map = try a.dupe(cbor.Entry, &.{
        .{ .key = "verdict", .value = .{ .text = "accept" } },
        .{ .key = "admit", .value = try admitOne(a, ev, box) },
    }) };
}

/// A handler's `admit`: one event into `box` (skein docs/MESSAGES.md: `{event: <record>, box}`).
fn admitOne(a: Allocator, ev: Value, box: []const u8) !Value {
    return .{ .array = try a.dupe(Value, &.{.{ .map = try a.dupe(cbor.Entry, &.{
        .{ .key = "event", .value = ev },
        .{ .key = "box", .value = .{ .text = box } },
    }) }}) };
}

fn verdictOf(a: Allocator, v: []const u8, reason: []const u8) !Value {
    return .{ .map = try a.dupe(cbor.Entry, &.{
        .{ .key = "verdict", .value = .{ .text = v } },
        .{ .key = "reason", .value = .{ .text = reason } },
    }) };
}

/// Whether the submission of this subject is paused already on exactly these parents (skein-overlay#1).
fn samePause(st: *State, txid: [32]u8, wanted: []const [32]u8) !bool {
    const rec = (try st.pendingRecord(txid)) orelse return false;
    const ws = rec.getArray("waiting") orelse return false;
    if (ws.len != wanted.len) return false;
    for (ws, wanted) |w, x| if (!eql(u8, if (w == .text) w.text else return false, &c.header.toHex(x))) return false;
    return true;
}

fn lookup(a: Allocator, in: Value, req: Value) !Value {
    const j = std.json.parseFromSliceLeaky(std.json.Value, a, req.getBytes("body") orelse "", .{}) catch return failure(a, 400, "Invalid request: the body is not JSON");
    const service = if (j == .object) j.object.get("service") else null;
    const q = if (j == .object) j.object.get("query") else null;
    if (service == null or service.? != .string or q == null) return failure(a, 400, "Invalid request: body must contain \"service\" (string) and \"query\" fields");
    const name = service.?.string;
    const prog = (try programFor(in, try configMap(a, in, "overlayLookups"), name)) orelse
        return failure(a, 400, try std.fmt.allocPrint(a, "Lookup service not supported: {s}", .{name}));
    const query = fromJson(a, q.?) catch return failure(a, 400, "the query has a non-integral number");
    const ans = vm.call(a, prog, "lookup", try calls.lookupArg(a, in, name, query)) catch |e| return failure(a, 400, if (e == error.ImportFailed) vm.lastError() else @errorName(e));
    const typ = ans.getText("type") orelse return error.BadAnswer;
    if (!eql(u8, typ, "output-list")) {
        return respond(a, 200, "application/json", try toJson(a, .{ .map = try a.dupe(cbor.Entry, &.{
            .{ .key = "type", .value = .{ .text = typ } },
            .{ .key = "result", .value = ans.get("result") orelse .null },
        }) }));
    }
    const outs = ans.getArray("outputs") orelse &.{};
    if (!eql(u8, header(req, "x-aggregation") orelse "", "yes")) {
        return respond(a, 200, "application/json", try toJson(a, .{ .map = try a.dupe(cbor.Entry, &.{
            .{ .key = "type", .value = .{ .text = "output-list" } },
            .{ .key = "outputs", .value = .{ .array = outs } },
        }) }));
    }
    // The compact form (overlay-express): count, each [txid, index, context], then one BEEF of them all.
    const st = try load(a, in);
    var out: std.ArrayList(u8) = .empty;
    var txids: std.ArrayList([32]u8) = .empty;
    try writeVarInt(a, &out, outs.len);
    for (outs) |o| {
        const b = try c.beef.parse(a, o.getBytes("beef") orelse return error.BadAnswer);
        const txid = b.subject() orelse return error.BadAnswer;
        var display = txid;
        std.mem.reverse(u8, &display);
        try out.appendSlice(a, &display);
        try writeVarInt(a, &out, o.getUint("outputIndex") orelse return error.BadAnswer);
        const ctx = o.getBytes("context") orelse "";
        try writeVarInt(a, &out, ctx.len);
        try out.appendSlice(a, ctx);
        for (txids.items) |t| {
            if (eql(u8, &t, &txid)) break;
        } else try txids.append(a, txid);
    }
    try out.appendSlice(a, try state.beefOfMany(st.ch, txids.items));
    return respond(a, 200, "application/octet-stream", out.items);
}

/// A configured topic's or service's answer to fn "metadata" / "documentation" (its program's call).
fn describe(a: Allocator, in: Value, key: []const u8, prog: []const u8, name: []const u8, func: []const u8) !Value {
    return vm.call(a, prog, func, try calls.describeArg(a, in, key, name));
}

fn callFailure(a: Allocator, e: anyerror) !Value {
    return failure(a, 500, if (e == error.ImportFailed) vm.lastError() else @errorName(e));
}

fn listing(a: Allocator, in: Value, key: []const u8) !Value {
    const map = try configMap(a, in, key);
    var es: std.ArrayList(cbor.Entry) = .empty;
    for (map.keys()) |name| {
        const prog = (try programFor(in, map, name)).?;
        const m = describe(a, in, key, prog, name, "metadata") catch |e| return callFailure(a, e);
        var fs: std.ArrayList(cbor.Entry) = .empty;
        try fs.appendSlice(a, &.{
            .{ .key = "name", .value = .{ .text = m.getText("name") orelse name } },
            .{ .key = "shortDescription", .value = .{ .text = m.getText("shortDescription") orelse "" } },
        });
        for ([_][]const u8{ "iconURL", "version", "informationURL" }) |f| {
            if (m.getText(f)) |x| try fs.append(a, .{ .key = f, .value = .{ .text = x } });
        }
        try es.append(a, .{ .key = name, .value = .{ .map = fs.items } });
    }
    return respond(a, 200, "application/json", try toJson(a, .{ .map = es.items }));
}

fn documentation(a: Allocator, in: Value, key: []const u8, name: []const u8, what: []const u8) !Value {
    const map = try configMap(a, in, key);
    const prog = (try programFor(in, map, name)) orelse return failure(a, 400, try std.fmt.allocPrint(a, "{s} not found: {s}", .{ what, name }));
    const d = describe(a, in, key, prog, name, "documentation") catch |e| return callFailure(a, e);
    return respond(a, 200, "text/markdown", d.getText("documentation") orelse "");
}
