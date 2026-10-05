//! Registered topics (shruggr/skein#120, David 2026-10-05: "Topic
//! registration is a one call. Register this topic, deregister this
//! topic."): the topics the engine serves beyond the ones its manifest
//! declares (`config.overlay.topics`), added and removed at runtime. A
//! dynamic overlay (one topic per token, `tm_<txid>`) declares none; one may
//! still pre-configure topics (OpNS: one global topic).
//!
//! The set is the engine's own, the root record of the head `<app>/topics`:
//!
//!   {kind: "overlay-topics", topics: [{topic, program}, …]}     sorted by topic, each once
//!
//! `program` is the role in `programs` (the app's) whose topic manager
//! judges the topic: a dynamic overlay's manifest lists no topics, so the
//! caller names it. config.zig reads the set at every step and call and
//! serves each topic as if `config.overlay.topics` named it (a declared
//! topic keeps its own program).
//!
//! `register {topic, program}` adds it and emits the skein #119 events
//! `subscribe {topic, program, fn, filter?}` for `<topic>` (fn `submit`,
//! `filter: "beef"`: the body is the submission's BEEF, decoded at the
//! kernel's door as for the `/submit` row, skein #121), `<topic>-admit`
//! (`peerAdmit`) and `<topic>-proof` (`peerProof`; dag-cbor bodies, no
//! filter), where
//! `program` is the engine's own role (the handler the kernel routes the
//! topic's messages to); `deregister {topic}` removes it and emits
//! `unsubscribe {topic}` for the three. Both are idempotent: a topic already
//! registered with the same program, or not registered, changes nothing and
//! emits nothing. The answer is `{topic, active}` (whether the topic is in
//! the registered set now).
//!
//! Either message is handled in whatever box a dispatch row delivers it to
//! the engine's program (shruggr/skein#128, 0.6.2): the app's own box
//! `<app>`, or another of its boxes, e.g. `<app>/overlay` from the manifest
//! row `{address: "overlay", sender: "$owner", program: "overlay"}`. The app
//! is the step's, never the box's; the answer goes back in the box the
//! message came in.
//!
//! The logic, natively testable; engine.zig runs it in a step.
const std = @import("std");
const c = @import("chain");

const cbor = c.cbor;
const Value = cbor.Value;
const Allocator = std.mem.Allocator;
const eql = std.mem.eql;

/// The head the set lives under, after the app's name: `<app>/topics`.
pub const head_suffix = "topics";
pub const record_kind = "overlay-topics";

/// One registered topic and the role whose topic manager judges it.
pub const Entry = struct { topic: []const u8, program: []const u8 };

/// The head of the set for app `app`.
pub fn headName(a: Allocator, app: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "{s}/{s}", .{ app, head_suffix });
}

/// The entries a set record holds (null: no set yet, none).
pub fn entriesOf(a: Allocator, rec: ?Value) ![]const Entry {
    const r = rec orelse return &.{};
    if (!eql(u8, r.getText("kind") orelse "", record_kind)) return error.BadTopicSet;
    const ts = r.getArray("topics") orelse return error.BadTopicSet;
    const out = try a.alloc(Entry, ts.len);
    for (ts, out) |t, *o| o.* = .{
        .topic = t.getText("topic") orelse return error.BadTopicSet,
        .program = t.getText("program") orelse return error.BadTopicSet,
    };
    return out;
}

/// The set's record.
pub fn recordOf(a: Allocator, list: []const Entry) !Value {
    const ts = try a.alloc(Value, list.len);
    for (list, ts) |e, *v| v.* = .{ .map = try a.dupe(cbor.Entry, &.{
        .{ .key = "topic", .value = .{ .text = e.topic } },
        .{ .key = "program", .value = .{ .text = e.program } },
    }) };
    return .{ .map = try a.dupe(cbor.Entry, &.{
        .{ .key = "kind", .value = .{ .text = record_kind } },
        .{ .key = "topics", .value = .{ .array = ts } },
    }) };
}

fn find(list: []const Entry, topic: []const u8) ?Entry {
    for (list) |e| if (eql(u8, e.topic, topic)) return e;
    return null;
}

fn lessThan(_: void, x: Entry, y: Entry) bool {
    return std.mem.order(u8, x.topic, y.topic) == .lt;
}

/// The three GossipSub topics of one overlay topic, the engine's function for each (routes.zig), and
/// the door's filter for its body: `beef` for `<topic>` (the submission's BEEF), none for the
/// dag-cbor `-admit` / `-proof` bodies.
pub const gossip_topics = [_]struct { suffix: []const u8, func: []const u8, filter: ?[]const u8 = null }{
    .{ .suffix = "", .func = "submit", .filter = "beef" },
    .{ .suffix = "-admit", .func = "peerAdmit" },
    .{ .suffix = "-proof", .func = "peerProof" },
};

/// The events of one change: `subscribe {topic, program: <self>, fn, filter?}` for each of the three
/// topics (register), or `unsubscribe {topic}` (deregister).
pub fn events(a: Allocator, subscribe: bool, topic: []const u8, self: []const u8) ![gossip_topics.len]Value {
    var out: [gossip_topics.len]Value = undefined;
    for (gossip_topics, &out) |g, *o| {
        const t: Value = .{ .text = try std.mem.concat(a, u8, &.{ topic, g.suffix }) };
        o.* = .{ .map = if (subscribe) sub: {
            var es: std.ArrayList(cbor.Entry) = .empty;
            try es.appendSlice(a, &.{
                .{ .key = "event", .value = .{ .text = "subscribe" } },
                .{ .key = "topic", .value = t },
                .{ .key = "program", .value = .{ .text = self } },
                .{ .key = "fn", .value = .{ .text = g.func } },
            });
            if (g.filter) |f| try es.append(a, .{ .key = "filter", .value = .{ .text = f } });
            break :sub es.items;
        } else try a.dupe(cbor.Entry, &.{
            .{ .key = "event", .value = .{ .text = "unsubscribe" } },
            .{ .key = "topic", .value = t },
        }) };
    }
    return out;
}

/// What a register or deregister does: the set to write (null: unchanged), the events to emit, the
/// answer. Or why it is refused (nothing written, nothing emitted).
pub const Change = union(enum) {
    refused: []const u8,
    done: struct { list: ?[]const Entry, events: []const Value, answer: Value },
};

fn answerOf(a: Allocator, topic: []const u8, active: bool) !Value {
    return .{ .map = try a.dupe(cbor.Entry, &.{
        .{ .key = "topic", .value = .{ .text = topic } },
        .{ .key = "active", .value = .{ .boolean = active } },
    }) };
}

fn refused(a: Allocator, comptime fmt: []const u8, args: anytype) !Change {
    return .{ .refused = try std.fmt.allocPrint(a, fmt, args) };
}

/// `register {topic, program}`: `program` a role in `programs` (the app's roles, or the genesis's);
/// `self` the engine's own role. An unknown role is refused; so is a topic registered already with
/// another program (deregister it first).
pub fn register(a: Allocator, list: []const Entry, args: Value, programs: Value, self: []const u8) !Change {
    const topic = args.getText("topic") orelse return refused(a, "register: want {{topic, program}}", .{});
    const program = args.getText("program") orelse return refused(a, "register: want {{topic, program}}", .{});
    if (topic.len == 0) return refused(a, "register: the topic is empty", .{});
    if (programs.getCid(program) == null) return refused(a, "register: program {s} is not a role in programs", .{program});
    if (find(list, topic)) |e| {
        if (!eql(u8, e.program, program)) return refused(a, "register: {s} is registered with program {s}: deregister it first", .{ topic, e.program });
        return .{ .done = .{ .list = null, .events = &.{}, .answer = try answerOf(a, topic, true) } };
    }
    const out = try a.alloc(Entry, list.len + 1);
    @memcpy(out[0..list.len], list);
    out[list.len] = .{ .topic = topic, .program = program };
    std.mem.sort(Entry, out, {}, lessThan);
    return .{ .done = .{ .list = out, .events = try a.dupe(Value, &try events(a, true, topic, self)), .answer = try answerOf(a, topic, true) } };
}

/// What a mailbox message asks of the engine, by its body's `fn` alone: the box it came in plays no
/// part (shruggr/skein#128): `register` / `deregister` in any box a row routes to the engine.
pub const Asked = enum { register, deregister, other };

pub fn asked(body: Value) Asked {
    const f = body.getText("fn") orelse return .other;
    if (eql(u8, f, "register")) return .register;
    if (eql(u8, f, "deregister")) return .deregister;
    return .other;
}

/// Whether a registration may be taken here (shruggr/skein#112): in the app's own box `<app>` —
/// open to anyone since 0.7.2, for submissions — only from the instance itself (`self`); in any
/// other box a row routes to the engine, from whoever that row admits.
pub fn mayRegister(args: Value, app: []const u8, self: ?[]const u8) bool {
    if (!eql(u8, answerBox(args, app), app)) return true;
    const me = self orelse return false;
    return eql(u8, args.getBytes("sender") orelse "", me);
}

/// The box a registration's answer goes back in: the one the message came in (the step's
/// `args.box`), else the app's own.
pub fn answerBox(args: Value, app: []const u8) []const u8 {
    return args.getText("box") orelse app;
}

/// `deregister {topic}`.
pub fn deregister(a: Allocator, list: []const Entry, args: Value) !Change {
    const topic = args.getText("topic") orelse return refused(a, "deregister: want {{topic}}", .{});
    if (find(list, topic) == null) return .{ .done = .{ .list = null, .events = &.{}, .answer = try answerOf(a, topic, false) } };
    var out: std.ArrayList(Entry) = .empty;
    for (list) |e| if (!eql(u8, e.topic, topic)) try out.append(a, e);
    return .{ .done = .{ .list = out.items, .events = try a.dupe(Value, &try events(a, false, topic, "")), .answer = try answerOf(a, topic, false) } };
}
