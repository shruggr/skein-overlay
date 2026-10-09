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
//!   config.overlay.market    {window: <ms>}   optional: a market (defaults.overlayMarket; `rolesOf`)
//!   config.overlay.validator {every: <ms>}    optional: a validator (defaults.overlayValidator)
//!
//! The two roles (shruggr/skein#120, David 2026-10-06 evening): registering
//! a topic is the one act that drives both — topics.zig `withRoles`. The
//! manifest's value is only the initial one (David, 2026-10-07: "this
//! should be a setting that the user is configuring"; 0.9.2): the owner's
//! switch (`market` / `validator` in `<app>/register`), kept in the record
//! `<app>/topics`, has precedence once sent (topics.zig `effective`).
//!
//! Beside the declared topics, the engine serves the topics registered at
//! runtime (shruggr/skein#120; topics.zig): the root record of the head
//! `<app>/topics`, `{kind: "overlay-topics", topics: [{topic, program}]}`,
//! written by the engine's own `register` / `deregister`. `resolve` adds each
//! to `overlayTopics` (judged by its `program`; a declared topic keeps its
//! own), read at every step and call: the rest of the engine sees one set.
//! The lookup services registered at runtime (skein-overlay 0.11.0;
//! lookups.zig) likewise: the root record of the head `<app>/lookups`,
//! `{kind: "overlay-lookups", lookups: [{service, program, topics?}]}`, each
//! added to `overlayLookups` as `{program, topics?}` (a declared service keeps
//! its own).
//!
//! A root route (shruggr/skein#143: root's own route, no `app`) reaches the
//! engine too (skein-overlay 0.11.0): `POST /submit` at the origin's root,
//! its handler the app's engine program record (`match.program`: the record
//! names its `app`), and the read route `/lookup` at the root, its filter
//! `<app>.lookup` (`match.filters`: the app is the one the filter names,
//! `matchedApp`).
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
const topics = @import("topics.zig");
const lookups = @import("lookups.zig");

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
/// The roles' keys (shruggr/skein#120, 2026-10-06 evening), each optional: set only when the app's config names it.
const role_keys = [_][2][]const u8{ .{ "market", "overlayMarket" }, .{ "validator", "overlayValidator" } };

const role_min_ms = topics.role_min_ms;
const role_max_ms = topics.role_max_ms;

/// The engine's roles from its configuration (`defaults.overlayMarket` / `overlayValidator`, JSON
/// text: an app's `config.overlay.market: {window}` / `config.overlay.validator: {every}`): each
/// absent, or its ms. Another shape, or a value outside 1 000 ms .. a day: error.BadRoles.
pub fn rolesOf(a: Allocator, in: Value) error{BadRoles}!topics.Roles {
    return .{
        .market = try roleMs(a, in, "overlayMarket", "window"),
        .validator = try roleMs(a, in, "overlayValidator", "every"),
    };
}

fn roleMs(a: Allocator, in: Value, key: []const u8, field: []const u8) error{BadRoles}!?u64 {
    const text = (if (in.get("defaults")) |d| d.getText(key) else null) orelse return null;
    const j = std.json.parseFromSliceLeaky(std.json.Value, a, text, .{}) catch return error.BadRoles;
    if (j == .null) return null;
    if (j != .object) return error.BadRoles;
    const v = j.object.get(field) orelse return error.BadRoles;
    if (v != .integer or v.integer < role_min_ms or v.integer > role_max_ms) return error.BadRoles;
    return @intCast(v.integer);
}

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
    // A read route's filter (shruggr/skein#143: /lookup, the listings, the documentation): the route
    // names no program, only its `app`; the engine is that app's role `overlay`.
    if (try matchedApp(a, heads, s, in, arg)) |m| return withApp(a, try withRegistered(a, s, heads, try fromApp(a, in, m.app, m.engine), m.name), m.name);
    const self = try selfProgram(a, s, in, arg);
    const name = try appName(a, s, self);
    const base = if (try appRecord(a, s, heads, self)) |app| try fromApp(a, in, app, self) else in;
    return withApp(a, try withRegistered(a, s, heads, base, name), name);
}

/// The engine's role in an app's `programs` (skein src/host/manifest.ts: an overlay app's engine is the role `overlay`).
pub const engine_role = "overlay";

/// A call whose route names no program (a read route: its filters answer, shruggr/skein#143) but
/// its `app`: that app's record, name and engine (its role `overlay`); null for a step, a call
/// whose route names its program, or no app record. A root route (no `app`: root's own, e.g. the
/// read route `/lookup` at the origin's root, skein-overlay 0.11.0) names its app by its filter
/// instead: the first of `match.filters` that is an app's (`<app>.<filter>`, not `kernel.…`)
/// whose app record lists that filter.
pub fn matchedApp(a: Allocator, heads: Heads, s: Store, in: Value, arg: ?Value) !?struct { app: Value, name: []const u8, engine: ?[]const u8 } {
    if (in.getCid("thread") != null) return null;
    const m = (arg orelse return null).get("match") orelse return null;
    if (m.getCid("program") != null) return null;
    const name = m.getText("app") orelse (try filterApp(a, heads, s, m)) orelse return null;
    const app = (try appNamed(a, heads, s, name)) orelse return null;
    const engine = if (app.get("programs")) |ps| ps.getCid(engine_role) else null;
    return .{ .app = app, .name = name, .engine = engine };
}

/// The app record at `<name>/app`, or null.
fn appNamed(a: Allocator, heads: Heads, s: Store, name: []const u8) !?Value {
    const root = (try heads.head(a, try std.fmt.allocPrint(a, "{s}/app", .{name}))) orelse return null;
    const app = try s.getValue(a, root);
    return if (eql(u8, app.getText("kind") orelse "", "app")) app else null;
}

/// A root route's app (no `app` on the route): the app of the first filter `<app>.<filter>` in
/// `match.filters` whose app record lists `<filter>` under `filters`. Null: none.
pub fn filterApp(a: Allocator, heads: Heads, s: Store, m: Value) !?[]const u8 {
    const fs = m.getArray("filters") orelse return null;
    for (fs) |f| {
        if (f != .text or std.mem.startsWith(u8, f.text, "kernel.")) continue;
        const dot = std.mem.lastIndexOfScalar(u8, f.text, '.') orelse continue;
        if (dot == 0 or dot + 1 == f.text.len) continue;
        const app = (try appNamed(a, heads, s, f.text[0..dot])) orelse continue;
        const listed = app.get("filters") orelse continue;
        if (listed.get(f.text[dot + 1 ..]) == null) continue;
        return f.text[0..dot];
    }
    return null;
}

/// `in` with the registered topics (the head `<app>/topics`, topics.zig) added to
/// `defaults.overlayTopics`, each judged by its program unless the config names it already, and
/// the registered lookup services (the head `<app>/lookups`, lookups.zig) to
/// `defaults.overlayLookups` likewise.
pub fn withRegistered(a: Allocator, s: Store, heads: Heads, in: Value, app: []const u8) !Value {
    var out = in;
    if (try heads.head(a, try topics.headName(a, app))) |root| out = try withTopics(a, out, try topics.entriesOf(a, try s.getValue(a, root)));
    if (try heads.head(a, try lookups.headName(a, app))) |root| out = try withLookups(a, out, try lookups.entriesOf(a, try s.getValue(a, root)));
    return out;
}

/// `in` with the registered lookup services `list` added to `defaults.overlayLookups`, each as
/// `{program, topics?}` unless the config names it already.
pub fn withLookups(a: Allocator, in: Value, list: []const lookups.Entry) !Value {
    if (list.len == 0) return in;
    const text = if (in.get("defaults")) |d| d.getText("overlayLookups") orelse "{}" else "{}";
    const j = std.json.parseFromSliceLeaky(std.json.Value, a, text, .{}) catch return error.BadConfig;
    if (j != .object) return error.BadConfig;
    var map = j.object;
    for (list) |e| {
        if (map.contains(e.service)) continue;
        var o: std.json.ObjectMap = .empty;
        try o.put(a, "program", .{ .string = e.program });
        if (e.topics) |ts| {
            var arr = std.json.Array.init(a);
            for (ts) |t| try arr.append(.{ .string = t });
            try o.put(a, "topics", .{ .array = arr });
        }
        try map.put(a, e.service, .{ .object = o });
    }
    return withDefault(a, in, "overlayLookups", try std.json.Stringify.valueAlloc(a, std.json.Value{ .object = map }, .{}));
}

/// `in` with `defaults.<key>` set to `text` (the other defaults kept).
fn withDefault(a: Allocator, in: Value, key: []const u8, text: []const u8) !Value {
    var es: std.ArrayList(cbor.Entry) = .empty;
    if (in.get("defaults")) |d| if (d == .map) for (d.map) |e| {
        if (!eql(u8, e.key, key)) try es.append(a, e);
    };
    try es.append(a, .{ .key = key, .value = .{ .text = text } });
    var out: std.ArrayList(cbor.Entry) = .empty;
    if (in == .map) for (in.map) |e| {
        if (!eql(u8, e.key, "defaults")) try out.append(a, e);
    };
    try out.append(a, .{ .key = "defaults", .value = .{ .map = es.items } });
    return .{ .map = out.items };
}

/// `in` with the registered set `list` added (`withRegistered`'s, from a set in hand: a register
/// step's own, written in that step, 0.7.8).
pub fn withTopics(a: Allocator, in: Value, list: []const topics.Entry) !Value {
    if (list.len == 0) return in;
    const text = if (in.get("defaults")) |d| d.getText("overlayTopics") orelse "{}" else "{}";
    const j = std.json.parseFromSliceLeaky(std.json.Value, a, text, .{}) catch return error.BadConfig;
    if (j != .object) return error.BadConfig;
    var map = j.object;
    for (list) |e| {
        if (!map.contains(e.topic)) try map.put(a, e.topic, .{ .string = e.program });
    }
    return withDefault(a, in, "overlayTopics", try std.json.Stringify.valueAlloc(a, std.json.Value{ .object = map }, .{}));
}

/// The engine's own role: the key in `programs` naming its program record (`engine`, else the
/// step's or call's own: `selfProgram`), else that record's `name`, else "overlay". What its
/// `subscribe` events name as the handler.
pub fn selfRole(a: Allocator, s: Store, in: Value, arg: ?Value) ![]const u8 {
    const p = in.getCid("engine") orelse (try selfProgram(a, s, in, arg)) orelse return "overlay";
    if (in.get("programs")) |ps| if (ps == .map) for (ps.map) |e| {
        if (e.value == .cid and eql(u8, e.value.cid, p)) return e.key;
    };
    return (try s.getValue(a, p)).getText("name") orelse "overlay";
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
        for (keys ++ role_keys) |k| {
            if (eql(u8, e.key, k[1])) break;
        } else try defaults.append(a, e);
    };
    for (keys) |k| try defaults.append(a, .{ .key = k[1], .value = .{ .text = if (ov.get(k[0])) |v| try json(a, v) else "{}" } });
    for (role_keys) |k| if (ov.get(k[0])) |v| try defaults.append(a, .{ .key = k[1], .value = .{ .text = try json(a, v) } });
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
