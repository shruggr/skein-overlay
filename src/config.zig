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
const keys = [_][2][]const u8{ .{ "topics", "overlayTopics" }, .{ "lookups", "overlayLookups" }, .{ "gossip", "overlayGossip" } };

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
    return withApp(a, base, name);
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
