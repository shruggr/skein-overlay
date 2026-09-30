//! The overlay's front-door routes (#40): the overlay-express wire contract,
//! as route handlers the front door calls (an in-VM call with the request;
//! routes.json names them, all `auth: "none"`, as overlay-express is open).
//!
//!   POST /submit      fn "submit"   body BEEF, X-Topics (comma list or JSON array),
//!                                   x-includes-off-chain-values: true → VarInt(len) ‖ BEEF ‖ off-chain values
//!                                   → the STEAK {topic: {outputsToAdmit, coinsToRetain, coinsRemoved}}
//!   libp2p:<topic>    fn "submit"   the same submit as a GossipSub message (#57): the message's topic
//!                                   requested, its body the BEEF → {verdict, admit?} (`gossip` below)
//!   POST /lookup      fn "lookup"   {service, query} (JSON) → {type: "output-list", outputs: [{beef, outputIndex, context?}]}
//!                                   X-Aggregation: yes → the compact octet-stream form (count, [txid, index, context], one BEEF)
//!   GET  /listTopicManagers, /listLookupServiceProviders         fn "listTopicManagers" / "listLookupServiceProviders"
//!   GET  /getDocumentationForTopicManager?manager=…              fn "topicDocumentation"
//!   GET  /getDocumentationForLookupServiceProvider?lookupService=…  fn "lookupDocumentation"
//!
//! A submit is the one write (#50, submit.zig). The handler decodes the BEEF
//! once into records in its call's in-memory overlay, checks SPV over them,
//! and calls each requested topic this instance serves and has not judged
//! the transaction for (fn "identify", on the transaction's CID). Nothing is
//! written when nothing is new: a bad BEEF answers 400; a valid transaction
//! no topic took, or a dupe everywhere, answers 200 with the empty STEAK
//! (BRC-22); the overlay is dropped. Otherwise it returns the entry for the host to admit — the plain
//! event {kind: "submit", txid, txs, nodes, proofs, topics: [judgement],
//! offChainValues?} in box `submit`, which engine.zig steps on (holding the
//! records, recording the judgements, calling the lookup services' hooks) —
//! and `then`: a call of fn "submitted" the host makes once that entry is
//! processed, which reads the STEAK from the state (each topic's `applied`
//! record; a dupe's is empty).
//!
//! A lookup is a read: the service's program is called (fn "lookup", the
//! lookup contract, lookup.zig) and its answer shaped for the wire; nothing
//! is written. Listings and documentation are the program records'
//! `description`.
const std = @import("std");
const w = @import("wallet");
const vm = @import("vm.zig");
const submit_mod = @import("submit.zig");

const cbor = w.cbor;
const Value = cbor.Value;
const Wallet = w.wallet.Wallet;
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
        .cid => |c| {
            try jw.beginObject();
            try jw.objectField("/");
            try jw.write(try vm.hexAlloc(a, c));
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
        for (v) |*c| if (c.* == '+') {
            c.* = ' ';
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

/// A name → program map from genesis defaults (a JSON object in a string).
pub const configMap = w.overlay.configObject;

/// The program record a served name runs: genesis `programs` by the configured name.
pub const programFor = w.overlay.configuredProgram;

/// The `bin/` program name a configured name runs (a string, or `{program, …}`).
fn programName(v: std.json.Value) ![]const u8 {
    return switch (v) {
        .string => |s| s,
        .object => |o| if (o.get("program")) |p| (if (p == .string) p.string else error.BadConfig) else error.BadConfig,
        else => error.BadConfig,
    };
}

fn load(a: Allocator, in: Value) !Wallet {
    var wal = try Wallet.load(a, vm.store(), try vm.head(a, vm.state_head), try vm.network(in));
    wal.now = @intCast(in.getUint("now") orelse 0);
    return wal;
}

// ---------------------------------------------------------------- the handlers

/// A call of the engine (input kind "call"): the route handlers above.
pub fn call(a: Allocator, in: Value) !void {
    const func = in.getText("fn") orelse return error.BadInput;
    const arg = try vm.callArg(a, in);
    const out = if (eql(u8, func, "submit"))
        try submit(a, in, arg)
    else if (eql(u8, func, "submitted"))
        try submitted(a, in, arg)
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

fn uintsJson(a: Allocator, xs: []const Value) ![]u64 {
    const out = try a.alloc(u64, xs.len);
    for (xs, out) |x, *o| o.* = if (x == .uint) x.uint else 0;
    return out;
}

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

fn submit(a: Allocator, in: Value, req: Value) !Value {
    if (eql(u8, req.getText("transport") orelse "", "libp2p")) return gossip(a, in, req);
    const th = header(req, "x-topics") orelse return failure(a, 400, "Missing x-topics header");
    const requested = parseTopics(a, th) catch return failure(a, 400, "Invalid x-topics header: expected a comma-separated list or JSON string array");
    var body = req.getBytes("body") orelse "";
    if (body.len == 0) return failure(a, 400, "Missing or empty BEEF body");
    var off: ?[]const u8 = null;
    if (eql(u8, header(req, "x-includes-off-chain-values") orelse "", "true")) {
        var pos: usize = 0;
        const n64 = readVarInt(body, &pos) catch return failure(a, 400, "Invalid off-chain values framing");
        if (n64 > body.len - pos) return failure(a, 400, "Invalid off-chain values framing");
        const n: usize = @intCast(n64);
        off = body[pos + n ..];
        body = body[pos .. pos + n];
    }
    const map = try configMap(a, in, "overlayTopics");
    const topics = try served(a, requested, map);
    var wal = try load(a, in);
    // The BEEF decoded once into records in this call's overlay, verified, judged by the topics (#50).
    // Refused, or a dupe everywhere: the call answers, no entry, the overlay is dropped — nothing persists.
    const routed = switch (try submit_mod.route(a, vm.caller(), &wal, in, body, topics, off)) {
        .refused => |why| return failure(a, 400, why),
        // Valid but admitted nowhere, or a dupe everywhere: BRC-22's answer is 200 with an empty STEAK.
        .nothing, .unchanged => {
            const entries = try a.alloc([3][]const u64, topics.len);
            for (entries) |*e| e.* = .{ &.{}, &.{}, &.{} };
            return respond(a, 200, "application/json", try jsonOf(a, Steak{ .topics = topics, .entries = entries }));
        },
        .admit => |x| x,
    };
    const names = try a.alloc(Value, topics.len);
    for (topics, names) |t, *n| n.* = .{ .text = t };
    const dupes = try a.alloc(Value, routed.dupes.len);
    for (routed.dupes, dupes) |t, *n| n.* = .{ .text = t };
    const ev = routed.event;
    const self = (in.get("programs") orelse return error.BadInput).getCid("overlay") orelse return error.NoOverlayProgram;
    const then_arg = try cbor.encode(a, .{ .map = try a.dupe(cbor.Entry, &.{
        .{ .key = "txid", .value = .{ .text = try a.dupe(u8, &w.header.toHex(routed.txid)) } },
        .{ .key = "topics", .value = .{ .array = names } },
        .{ .key = "dupes", .value = .{ .array = dupes } },
    }) });
    return .{ .map = try a.dupe(cbor.Entry, &.{
        .{ .key = "status", .value = .{ .uint = 202 } },
        .{ .key = "type", .value = .{ .text = "application/json" } },
        .{ .key = "body", .value = .{ .bytes = "{}" } },
        .{ .key = "admit", .value = .{ .array = try a.dupe(Value, &.{.{ .map = try a.dupe(cbor.Entry, &.{
            .{ .key = "event", .value = ev },
            .{ .key = "box", .value = .{ .text = "submit" } },
        }) }}) } },
        .{ .key = "then", .value = .{ .map = try a.dupe(cbor.Entry, &.{
            .{ .key = "program", .value = .{ .cid = self } },
            .{ .key = "fn", .value = .{ .text = "submitted" } },
            .{ .key = "arg", .value = .{ .bytes = then_arg } },
        }) } },
    }) };
}

/// The same submit, arriving as a GossipSub message on a `libp2p:<topic>` route (#57): the message's
/// topic is the one requested, its body the BEEF (no off-chain values), and the route's half runs
/// unchanged. The answer is the libp2p handler contract (docs/MESSAGES.md, "libp2p"): accept with the
/// same submit entry POST /submit returns (the front door forwards it after the message's own `p2p`
/// entry); ignore — no forward, no penalty — when nothing is new or the BEEF is refused (a refusal may
/// be this instance's missing headers, not the publisher's fault). No `then`: nothing to answer.
fn gossip(a: Allocator, in: Value, req: Value) !Value {
    const t = req.getText("topic") orelse return verdictOf(a, "ignore", "not a topic message");
    const body = req.getBytes("body") orelse "";
    if (body.len == 0) return verdictOf(a, "ignore", "Missing or empty BEEF body");
    const topics = try served(a, &.{t}, try configMap(a, in, "overlayTopics"));
    if (topics.len == 0) return verdictOf(a, "ignore", "the topic is not served here");
    var wal = try load(a, in);
    const routed = switch (try submit_mod.route(a, vm.caller(), &wal, in, body, topics, null)) {
        .refused => |why| return verdictOf(a, "ignore", why),
        .nothing => |why| return verdictOf(a, "ignore", why),
        .unchanged => return verdictOf(a, "ignore", "already judged"),
        .admit => |x| x,
    };
    return .{ .map = try a.dupe(cbor.Entry, &.{
        .{ .key = "verdict", .value = .{ .text = "accept" } },
        .{ .key = "admit", .value = .{ .array = try a.dupe(Value, &.{.{ .map = try a.dupe(cbor.Entry, &.{
            .{ .key = "event", .value = routed.event },
            .{ .key = "box", .value = .{ .text = "submit" } },
        }) }}) } },
    }) };
}

fn verdictOf(a: Allocator, v: []const u8, reason: []const u8) !Value {
    return .{ .map = try a.dupe(cbor.Entry, &.{
        .{ .key = "verdict", .value = .{ .text = v } },
        .{ .key = "reason", .value = .{ .text = reason } },
    }) };
}

/// After the submit entry is processed: the STEAK from each topic's `applied` record (a dupe, or a topic that admitted nothing: empty).
fn submitted(a: Allocator, in: Value, arg: Value) !Value {
    var wal = try load(a, in);
    const txid = try w.header.fromHex(arg.getText("txid") orelse return error.BadInput);
    const topics_v = arg.getArray("topics") orelse return error.BadInput;
    const dupes = arg.getArray("dupes") orelse &.{};
    const topics = try a.alloc([]const u8, topics_v.len);
    const entries = try a.alloc([3][]const u64, topics_v.len);
    for (topics_v, topics, entries) |tv, *t, *e| {
        t.* = if (tv == .text) tv.text else return error.BadInput;
        e.* = .{ &.{}, &.{}, &.{} };
        const dupe = for (dupes) |d| {
            if (d == .text and eql(u8, d.text, t.*)) break true;
        } else false;
        if (dupe) continue;
        const key = try std.mem.concat(a, u8, &.{ try w.overlay.topicPrefix(a, t.*), &txid });
        const rec_cid = (try wal.map("applied").link(key)) orelse continue;
        const rec = try vm.store().getValue(a, rec_cid);
        e.* = .{
            try uintsJson(a, rec.getArray("outputsToAdmit") orelse &.{}),
            try uintsJson(a, rec.getArray("coinsToRetain") orelse &.{}),
            try uintsJson(a, rec.getArray("coinsRemoved") orelse &.{}),
        };
    }
    return respond(a, 200, "application/json", try jsonOf(a, Steak{ .topics = topics, .entries = entries }));
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
    const ans = vm.call(a, prog, "lookup", .{ .map = try a.dupe(cbor.Entry, &.{
        .{ .key = "kind", .value = .{ .text = "lookup-call" } },
        .{ .key = "service", .value = .{ .text = name } },
        .{ .key = "query", .value = query },
    }) }) catch |e| return failure(a, 400, if (e == error.ImportFailed) vm.lastError() else @errorName(e));
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
    var wal = try load(a, in);
    var out: std.ArrayList(u8) = .empty;
    var txids: std.ArrayList([32]u8) = .empty;
    try writeVarInt(a, &out, outs.len);
    for (outs) |o| {
        const b = try w.beef.parse(a, o.getBytes("beef") orelse return error.BadAnswer);
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
    try out.appendSlice(a, try wal.beefOfMany(txids.items));
    return respond(a, 200, "application/octet-stream", out.items);
}

fn description(a: Allocator, in: Value, program: []const u8) ![]const u8 {
    const progs = in.get("programs") orelse return "";
    const cid = progs.getCid(program) orelse return "";
    const rec = vm.store().getValue(a, cid) catch return "";
    return rec.getText("description") orelse "";
}

fn listing(a: Allocator, in: Value, key: []const u8) !Value {
    const map = try configMap(a, in, key);
    var out: std.Io.Writer.Allocating = .init(a);
    var jw: std.json.Stringify = .{ .writer = &out.writer };
    try jw.beginObject();
    var it = map.iterator();
    while (it.next()) |e| {
        const d = try description(a, in, try programName(e.value_ptr.*));
        const first = std.mem.trim(u8, d[0 .. std.mem.indexOfScalar(u8, d, '\n') orelse d.len], " \t\r");
        try jw.objectField(e.key_ptr.*);
        try jw.write(.{ .name = e.key_ptr.*, .shortDescription = first });
    }
    try jw.endObject();
    return respond(a, 200, "application/json", out.written());
}

fn documentation(a: Allocator, in: Value, key: []const u8, name: []const u8, what: []const u8) !Value {
    const map = try configMap(a, in, key);
    const v = map.get(name) orelse return failure(a, 400, try std.fmt.allocPrint(a, "{s} not found: {s}", .{ what, name }));
    return respond(a, 200, "text/markdown", try description(a, in, try programName(v)));
}
