//! The overlay's front-door routes (#40): the overlay-express wire contract,
//! as route handlers the front door calls (an in-VM call with the request;
//! the app's dispatch rows name them, open (sender `*`), as overlay-express is).
//! The addresses are the app's own (`/<app>/submit`, …: its BRC-23 base URL).
//!
//!   POST /submit      fn "submit"   body BEEF, X-Topics (comma list or JSON array),
//!                                   x-includes-off-chain-values: true → VarInt(len) ‖ BEEF ‖ off-chain values
//!                                   → 200 {id}: delivered (shruggr/skein#112) — the submission is the
//!                                   message {fn: "submit", args: {beef, topics, offChainValues?}}, its
//!                                   answers go to the submitter's box, never on this connection
//!   libp2p:<topic>    fn "submit"   the same submit as a GossipSub message (#57): the message's topic
//!                                   requested, its body the BEEF → {verdict, admit?} (`gossip` below)
//!   libp2p:<topic>-admit   fn "peerAdmit"   a peer's verdict (#74, gossip.zig): recorded as a
//!                                           `peer-admit` record, never admitting → {verdict, admit?}
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
//! A submit over HTTP (shruggr/skein#112) is a transport for the submission
//! message: the handler checks only that it is one (X-Topics, a body, the
//! off-chain framing; else 400), launches the engine on the message
//! `{fn: "submit", args: {beef, topics, offChainValues?}}` as a message step
//! would be (args `{body, box: <app>, message: <the request record>, sender?:
//! <the session's identity>, transport: "http"}`), and answers 200 `{id}`:
//! the request record's CID, which every answer names (`request`). The
//! engine routes it (submit.zig `received`) and answers the submitter by
//! message — admitted (pending), each proof, or rejected — when a message
//! reaches it; an open route has no caller, so its answers are in the log
//! only. No STEAK is answered here, and no 503.
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
    try vm.answer(a, out);
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
    const sub = switch (try httpSubmission(a, req, calls.appOf(in))) {
        .refused => |answer| return answer,
        .message => |m| m,
    };
    // The submission message, and the engine launched on it as a message step is (submit.zig `received`).
    const s = vm.store();
    const largs = try a.dupe(cbor.Entry, sub.args.map);
    largs[0].value = .{ .cid = try s.putValue(a, sub.body) };
    const self = in.getCid("engine") orelse (in.get("programs") orelse return error.BadInput).getCid("overlay") orelse return error.NoOverlayProgram;
    _ = try vm.launch(a, self, try s.putValue(a, .{ .map = largs }));
    return sub.answer;
}

/// POST /submit as a transport for the submission message (shruggr/skein#112): the request is
/// checked for being one (X-Topics, a body, the off-chain framing; else the 400 answer, `refused`);
/// then `message`: its `body`, `{fn: "submit", args: {beef, topics, offChainValues?}}`; the `args`
/// the engine is launched on, as a message step gets them — `{body: <the body's CID, filled in by
/// the caller>, box: <app>, message: <the request record>, transport: "http", sender?: <the
/// session's identity>}`; and the `answer`: 200 `{id: <the request record's CID, hex>}`.
pub fn httpSubmission(a: Allocator, req: Value, app: []const u8) !union(enum) { refused: Value, message: struct { body: Value, args: Value, answer: Value } } {
    const th = header(req, "x-topics") orelse return .{ .refused = try failure(a, 400, "Missing x-topics header") };
    const requested = parseTopics(a, th) catch return .{ .refused = try failure(a, 400, "Invalid x-topics header: expected a comma-separated list or JSON string array") };
    // shruggr/skein#121: the kernel's door put the BEEF's pointer record where its bytes were (the row's
    // `filter: "beef"`); bytes are a body it did not take as a BEEF (framed with off-chain values).
    var beef: Value = undefined;
    var off: ?[]const u8 = null;
    if (req.getCid("body")) |rc| {
        beef = .{ .cid = rc };
    } else {
        var body = req.getBytes("body") orelse "";
        if (body.len == 0) return .{ .refused = try failure(a, 400, "Missing or empty BEEF body") };
        if (eql(u8, header(req, "x-includes-off-chain-values") orelse "", "true")) {
            var pos: usize = 0;
            const n64 = readVarInt(body, &pos) catch return .{ .refused = try failure(a, 400, "Invalid off-chain values framing") };
            if (n64 > body.len - pos) return .{ .refused = try failure(a, 400, "Invalid off-chain values framing") };
            const n: usize = @intCast(n64);
            off = body[pos + n ..];
            body = body[pos .. pos + n];
        }
        beef = .{ .bytes = body };
    }
    const request = req.getCid("request") orelse return error.BadInput;
    const ts = try a.alloc(Value, requested.len);
    for (requested, ts) |t, *o| o.* = .{ .text = t };
    var fargs: std.ArrayList(cbor.Entry) = .empty;
    try fargs.appendSlice(a, &.{
        .{ .key = "beef", .value = beef },
        .{ .key = "topics", .value = .{ .array = ts } },
    });
    if (off) |o| try fargs.append(a, .{ .key = "offChainValues", .value = .{ .bytes = o } });
    var largs: std.ArrayList(cbor.Entry) = .empty;
    try largs.appendSlice(a, &.{
        .{ .key = "body", .value = .null },
        .{ .key = "box", .value = .{ .text = app } },
        .{ .key = "message", .value = .{ .cid = request } },
        .{ .key = "transport", .value = .{ .text = "http" } },
    });
    if (req.getBytes("caller")) |k| try largs.append(a, .{ .key = "sender", .value = .{ .bytes = k } });
    return .{ .message = .{
        .body = .{ .map = try a.dupe(cbor.Entry, &.{
            .{ .key = "fn", .value = .{ .text = "submit" } },
            .{ .key = "args", .value = .{ .map = fargs.items } },
        }) },
        .args = .{ .map = largs.items },
        .answer = try respond(a, 200, "application/json", try jsonOf(a, .{ .id = try vm.hexAlloc(a, request) })),
    } };
}

/// The same submit, arriving as a GossipSub message on a `libp2p:<topic>` route (#57): the message's
/// topic is the one requested, its body the BEEF (no off-chain values), and the route's half runs
/// unchanged. The answer is the libp2p handler contract (skein docs/MESSAGES.md, "libp2p"): accept,
/// admitting the submit event in box `<app>` (routed after the message's own `p2p` event: the app's
/// row from `event` launches the same engine thread a submission launches), so the verdict goes
/// back at once — GossipSub's validator waits on nothing further; ignore — no forward, no penalty —
/// when nothing is new or the BEEF is refused (a refusal may be this instance's missing headers, not
/// the publisher's fault).
///
/// The topic is the message's; it is served when the configuration names it: declared
/// (`config.overlay.topics`) or registered (`<app>/topics`, config.zig adds them), as for
/// `peerAdmit` and `peerProof`.
fn gossip(a: Allocator, in: Value, req: Value) !Value {
    const t = req.getText("topic") orelse return verdictOf(a, "ignore", "not a topic message");
    // shruggr/skein#121: the door's pointer record (the row's `filter: "beef"`), or the bytes as received.
    const beef: submit_mod.Input = if (req.getCid("body")) |rc| .{ .record = rc } else .{ .bytes = req.getBytes("body") orelse "" };
    if (beef == .bytes and beef.bytes.len == 0) return verdictOf(a, "ignore", "Missing or empty BEEF body");
    const topics = try served(a, &.{t}, try configMap(a, in, "overlayTopics"));
    if (topics.len == 0) return verdictOf(a, "ignore", "the topic is not served here");
    var st = try load(a, in);
    return libp2pRouted(a, in, &st, beef, topics, try sourceOf(a, req, t), req);
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
    const beef: submit_mod.Input = if (req.getCid("body")) |rc| .{ .record = rc } else .{ .bytes = req.getBytes("body") orelse "" };
    if (beef == .bytes and beef.bytes.len == 0) return verdictOf(a, "ignore", "Missing or empty BEEF body");
    const subject = switch (beef) {
        .record => |rc| c.record.subjectOf(vm.store().getValue(a, rc) catch return verdictOf(a, "ignore", "Invalid BEEF")),
        .bytes => |b| (c.beef.parse(a, b) catch return verdictOf(a, "ignore", "Invalid BEEF")).subject(),
    } orelse return verdictOf(a, "ignore", "Invalid BEEF: no subject");
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

/// A peer's verdict on `libp2p:<topic>-admit` (#74): {txid, topics: {<topic>: {outputsToAdmit,
/// coinsToRetain}}}. Never admits anything: accept admits a `peer-admit` event (box `<app>`) the
/// engine records under the head `<app>/gossip` (gossip.zig), a read for a lookup or a UI. Ignore
/// when the topic is not served here or the body is not that shape.
fn peerAdmit(a: Allocator, in: Value, req: Value) !Value {
    if (!eql(u8, req.getText("transport") orelse "", "libp2p")) return failure(a, 400, "peerAdmit takes libp2p topic messages");
    const gt = req.getText("topic") orelse return verdictOf(a, "ignore", "not a topic message");
    const t = gossip_mod.baseOf(gt, gossip_mod.admit_suffix) orelse return verdictOf(a, "ignore", "not an -admit topic");
    if (!(try configMap(a, in, "overlayTopics")).contains(t)) return verdictOf(a, "ignore", "the topic is not served here");
    const from = req.getBytes("key") orelse return verdictOf(a, "ignore", "no publisher key");
    const m = gossip_mod.parseAdmit(a, req.getBytes("body") orelse "", t) catch |e| return verdictOf(a, "ignore", @errorName(e));
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
        .{ .key = "admit", .value = .{ .array = try a.dupe(Value, &.{.{ .map = try a.dupe(cbor.Entry, &.{
            .{ .key = "event", .value = ev },
            .{ .key = "box", .value = .{ .text = box } },
        }) }}) } },
    }) };
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
