//! The engine's configuration (skein #72): which topics and lookup services
//! it runs, and which programs they are — read from the app it was installed
//! as, at every step and call, so a reinstall with a changed manifest takes
//! effect at the next one (no restart).
//!
//! Where the engine finds its app (skein docs/APPS.md §2): the program
//! records `skein-host install` writes carry `app: <name>`; the app's root
//! head is `<name>/app` (skein #77), and every head the engine writes is
//! under that name (`<name>/state`, `<name>/gossip`, `<name>/ls_<service>`).
//! The engine's own record is
//!
//!   a step    the thread's `program` (the step's `thread` is the origin record)
//!   a call    the matched dispatch row's `program` (`match`, the front door's)
//!
//! and the head's root is the app record: {kind: "app", name, programs:
//! {<role>: <program record>}, config: {overlay: {topics, lookups, status?,
//! gossip?}}, …}. Its `config.overlay` replaces the genesis defaults, and its
//! roles are the program names the config uses:
//!
//!   config.overlay.topics    {<topic>: <role>}                                   (was defaults.overlayTopics)
//!   config.overlay.lookups   {<service>: <role> | {program: <role>, topics?}}    (was defaults.overlayLookups)
//!   config.overlay.gossip    {<topic>: bool}                                     (was defaults.overlayGossip)
//!   config.overlay.prefixes  {<prefix>: {program: <role>, active: <head>}}       (defaults.overlayPrefixes)
//!
//! A prefix serves the topics an app activates live (skein #119, #120: a
//! topic per token, `tm_<txid>`, cannot be listed at install). `active` names
//! a head under the app's name, `<app>/<active>`, whose root record lists the
//! topics served now: `{topics: [<topic>, …]}` (the app's own program writes
//! it). Each listed topic that starts with the prefix is served as if
//! `topics` named it, judged by `program`; a topic `topics` names itself
//! keeps its own program. A lookup service in the object form may name
//! `prefixes: [<prefix>]`: it also listens to every active topic under them.
//! `resolve` expands them: the rest of the engine sees `overlayTopics` and
//! `overlayLookups` with the active topics in, read at every step and call.
//!
//! No app record — a program record without `app` (a genesis-wired engine:
//! its programs and config are the genesis's; its name is its program
//! record's `name`), a host's call with no route, a head that is not an app
//! — and the genesis `defaults` are the config, as before. `resolve` returns
//! the input as the rest of the engine reads it, with `app` (the name its
//! heads are under: the app's, else the program's, else "overlay"):
//! `defaults.overlayTopics`/`overlayLookups`/`overlayGossip` (JSON text, the
//! calls.zig `configObject`), `programs` (the app's roles), and
//! `engine`: the engine's own program record (what a submission's thread is
//! launched as).
const std = @import("std");
const c = @import("chain");

const cbor = c.cbor;
const Value = cbor.Value;
const Store = c.store.Store;
const Allocator = std.mem.Allocator;
const eql = std.mem.eql;

/// The heads as the engine reads them: the VM's `head` import, a map in the tests.
pub const Heads = struct {
    ctx: *anyopaque,
    headFn: *const fn (ctx: *anyopaque, a: Allocator, name: []const u8) anyerror!?[]const u8,

    pub fn head(self: Heads, a: Allocator, name: []const u8) !?[]const u8 {
        return self.headFn(self.ctx, a, name);
    }
};

/// The genesis default each `config.overlay` key replaces.
const keys = [_][2][]const u8{ .{ "topics", "overlayTopics" }, .{ "lookups", "overlayLookups" }, .{ "gossip", "overlayGossip" }, .{ "prefixes", "overlayPrefixes" } };

/// The engine's own program record: a step's thread's `program`, a route call's `match.program`; null for a host's call.
pub fn selfProgram(a: Allocator, s: Store, in: Value, arg: ?Value) !?[]const u8 {
    if (in.getCid("thread")) |t| return (try s.getValue(a, t)).getCid("program");
    if (arg) |x| if (x.get("match")) |m| return m.getCid("program");
    return null;
}

/// The app record the engine was installed as (its program record's `app` → the head `<app>/app`'s root), or null.
pub fn appRecord(a: Allocator, s: Store, heads: Heads, program: ?[]const u8) !?Value {
    const p = program orelse return null;
    const name = (try s.getValue(a, p)).getText("app") orelse return null;
    const root = (try heads.head(a, try std.fmt.allocPrint(a, "{s}/app", .{name}))) orelse return null;
    const app = try s.getValue(a, root);
    return if (eql(u8, app.getText("kind") orelse "", "app")) app else null;
}

/// The name the engine's heads are under: its program record's `app`, else its `name` (a
/// genesis-wired engine), else "overlay".
pub fn appName(a: Allocator, s: Store, program: ?[]const u8) ![]const u8 {
    const p = program orelse return "overlay";
    const rec = try s.getValue(a, p);
    return rec.getText("app") orelse rec.getText("name") orelse "overlay";
}

/// The input as the engine reads its configuration: from its app record if it has one (`fromApp`),
/// else as it is — with `app`, the name its heads are under.
pub fn resolve(a: Allocator, s: Store, heads: Heads, in: Value, arg: ?Value) !Value {
    const self = try selfProgram(a, s, in, arg);
    const name = try appName(a, s, self);
    const base = if (try appRecord(a, s, heads, self)) |app| try fromApp(a, in, app, self) else in;
    return withApp(a, try withPrefixes(a, s, heads, base, name), name);
}

/// A JSON default (`defaults.<key>`, an object in a string), parsed; `{}` when absent.
fn defaultObject(a: Allocator, in: Value, key: []const u8) !std.json.ObjectMap {
    const text = if (in.get("defaults")) |d| d.getText(key) orelse "{}" else "{}";
    const j = std.json.parseFromSliceLeaky(std.json.Value, a, text, .{}) catch return error.BadConfig;
    if (j != .object) return error.BadConfig;
    return j.object;
}

/// The topics active under a prefix: the root record of `<app>/<active>`, its `topics` that start
/// with the prefix (longer than it). None when the head is not there yet.
pub fn activeTopics(a: Allocator, s: Store, heads: Heads, app: []const u8, prefix: []const u8, active: []const u8) ![]const []const u8 {
    const root = (try heads.head(a, try std.fmt.allocPrint(a, "{s}/{s}", .{ app, active }))) orelse return &.{};
    const rec = try s.getValue(a, root);
    const list = rec.getArray("topics") orelse return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    for (list) |t| {
        if (t != .text) return error.BadConfig;
        if (t.text.len > prefix.len and std.mem.startsWith(u8, t.text, prefix)) try out.append(a, t.text);
    }
    return out.items;
}

/// `in` with `defaults.overlayPrefixes` expanded: each prefix's active topics added to
/// `overlayTopics` (judged by its program, unless named there already) and to the `topics` of every
/// lookup service in the object form whose `prefixes` names it.
pub fn withPrefixes(a: Allocator, s: Store, heads: Heads, in: Value, app: []const u8) !Value {
    const prefixes = try defaultObject(a, in, "overlayPrefixes");
    if (prefixes.count() == 0) return in;
    var topics = try defaultObject(a, in, "overlayTopics");
    var lookups = try defaultObject(a, in, "overlayLookups");
    var it = prefixes.iterator();
    while (it.next()) |e| {
        const prefix = e.key_ptr.*;
        if (prefix.len == 0 or e.value_ptr.* != .object) return error.BadConfig;
        const o = e.value_ptr.object;
        const prog = o.get("program") orelse return error.BadConfig;
        const active = o.get("active") orelse return error.BadConfig;
        if (prog != .string or active != .string or active.string.len == 0) return error.BadConfig;
        const live = try activeTopics(a, s, heads, app, prefix, active.string);
        for (live) |t| {
            if (!topics.contains(t)) try topics.put(a, t, .{ .string = prog.string });
        }
        var lt = lookups.iterator();
        while (lt.next()) |l| {
            if (l.value_ptr.* != .object) continue;
            const ps = l.value_ptr.object.get("prefixes") orelse continue;
            if (ps != .array) return error.BadConfig;
            const names = for (ps.array.items) |p| {
                if (p != .string) return error.BadConfig;
                if (eql(u8, p.string, prefix)) break true;
            } else false;
            if (!names) continue;
            var list: std.json.Array = .init(a);
            if (l.value_ptr.object.get("topics")) |ts| {
                if (ts != .array) return error.BadConfig;
                try list.appendSlice(ts.array.items);
            }
            for (live) |t| try list.append(.{ .string = t });
            try l.value_ptr.object.put(a, "topics", .{ .array = list });
        }
    }
    var es: std.ArrayList(cbor.Entry) = .empty;
    if (in.get("defaults")) |d| if (d == .map) for (d.map) |e| {
        if (eql(u8, e.key, "overlayTopics") or eql(u8, e.key, "overlayLookups")) continue;
        try es.append(a, e);
    };
    try es.append(a, .{ .key = "overlayTopics", .value = .{ .text = try std.json.Stringify.valueAlloc(a, std.json.Value{ .object = topics }, .{}) } });
    try es.append(a, .{ .key = "overlayLookups", .value = .{ .text = try std.json.Stringify.valueAlloc(a, std.json.Value{ .object = lookups }, .{}) } });
    var out: std.ArrayList(cbor.Entry) = .empty;
    if (in == .map) for (in.map) |e| {
        if (!eql(u8, e.key, "defaults")) try out.append(a, e);
    };
    try out.append(a, .{ .key = "defaults", .value = .{ .map = es.items } });
    return .{ .map = out.items };
}

/// `in` with `app` set.
pub fn withApp(a: Allocator, in: Value, name: []const u8) !Value {
    var es: std.ArrayList(cbor.Entry) = .empty;
    if (in == .map) for (in.map) |e| {
        if (!eql(u8, e.key, "app")) try es.append(a, e);
    };
    try es.append(a, .{ .key = "app", .value = .{ .text = name } });
    return .{ .map = es.items };
}

/// `in` with the app record's configuration: `defaults.overlay*` from `config.overlay` (an absent key
/// is `{}`; the other defaults kept), `programs` = the app's roles, `engine` = `self`.
pub fn fromApp(a: Allocator, in: Value, app: Value, self: ?[]const u8) !Value {
    const ov: Value = if (app.get("config")) |cf| cf.get("overlay") orelse .null else .null;
    if (ov != .map and ov != .null) return error.BadConfig;
    var defaults: std.ArrayList(cbor.Entry) = .empty;
    if (in.get("defaults")) |d| if (d == .map) for (d.map) |e| {
        for (keys) |k| {
            if (eql(u8, e.key, k[1])) break;
        } else try defaults.append(a, e);
    };
    for (keys) |k| try defaults.append(a, .{ .key = k[1], .value = .{ .text = if (ov.get(k[0])) |v| try json(a, v) else "{}" } });
    const programs = app.get("programs") orelse return error.BadConfig;
    if (programs != .map) return error.BadConfig;
    var es: std.ArrayList(cbor.Entry) = .empty;
    if (in == .map) for (in.map) |e| {
        if (eql(u8, e.key, "defaults") or eql(u8, e.key, "programs") or eql(u8, e.key, "engine")) continue;
        try es.append(a, e);
    };
    try es.appendSlice(a, &.{
        .{ .key = "defaults", .value = .{ .map = defaults.items } },
        .{ .key = "programs", .value = programs },
    });
    if (self) |e| try es.append(a, .{ .key = "engine", .value = .{ .cid = e } });
    return .{ .map = es.items };
}

/// A configuration value (maps of text, lists, text, numbers, booleans) as JSON text.
pub fn json(a: Allocator, v: Value) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    var jw: std.json.Stringify = .{ .writer = &out.writer };
    try write(&jw, v);
    return out.written();
}

fn write(jw: *std.json.Stringify, v: Value) !void {
    switch (v) {
        .map => |es| {
            try jw.beginObject();
            for (es) |e| {
                try jw.objectField(e.key);
                try write(jw, e.value);
            }
            try jw.endObject();
        },
        .array => |xs| {
            try jw.beginArray();
            for (xs) |x| try write(jw, x);
            try jw.endArray();
        },
        .text => |t| try jw.write(t),
        .boolean => |b| try jw.write(b),
        .uint => |n| try jw.write(n),
        .nint => |n| try jw.write(-1 - @as(i128, n)),
        .null => try jw.write(null),
        else => return error.BadConfig,
    }
}
