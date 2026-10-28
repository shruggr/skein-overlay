//! Configured topics and lookup services beat (0.17.0, shruggr/skein-amm#4): a topic in
//! `config.overlay.topics` and a lookup service in `config.overlay.lookups` get liveness and a
//! beacon on `<name>-live` exactly as a registered one does (topics.zig `roleEvents`: the topic's
//! beat body over its view, the lookup program's fn "beat"), so an instance whose topic comes from
//! its configuration at birth (a token instance: `tm_color_<tokenId>`) is found by its beats as a
//! registered one is. Until 0.16.1 a configured name was served but did not beat.
//!
//! The engine declares them on its first step after it sees the configuration, and keeps what it
//! declared as the root record of the head `<app>/configured`:
//!
//!   {kind: "overlay-configured", topics: [<topic>, …], lookups: [<service>, …], terms?}
//!
//! in the configuration's order (`terms` the configuration's `config.overlay.terms`, when it names
//! one). At every step the record the configuration makes now is compared with the head's: the same,
//! nothing happens (idempotent: one declaration per change, the intents stand in the log and the
//! host folds them back after a restart, as a registered topic's); else every configured name is
//! declared again (a beacon replaces its previous one), a name no longer configured (a reinstall
//! dropped it) gets `unliveness` and `unbeacon`, and the head is written. A name that is registered
//! too (the head `<app>/topics` or `<app>/lookups`) is the registration's, not here: the registered
//! path is as before. A genesis-wired engine (no app record) has no configuration of its own here.
//!
//! The logic, natively testable; engine.zig runs it in a step.
const std = @import("std");
const c = @import("chain");
const topics = @import("topics.zig");
const lookups = @import("lookups.zig");

const cbor = c.cbor;
const Value = cbor.Value;
const Allocator = std.mem.Allocator;
const eql = std.mem.eql;

/// The head the declared set lives under, after the app's name: `<app>/configured`.
pub const head_suffix = "configured";
pub const record_kind = "overlay-configured";

pub fn headName(a: Allocator, app: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "{s}/{s}", .{ app, head_suffix });
}

/// What the configuration asks to beat now: its topics (each with its role) and lookup services
/// (each with its program's role), the registered ones left out, and its `terms`.
pub const Now = struct {
    topics: []const topics.Entry = &.{},
    lookups: []const lookups.Entry = &.{},
    terms: ?Value = null,
};

/// The app record's `config.overlay` → what beats now (`Now`), the names in `registered_topics` /
/// `registered_services` left out. A configuration that is not a map: nothing.
pub fn of(a: Allocator, app: Value, registered_topics: []const topics.Entry, registered_services: []const []const u8) !Now {
    const ov: Value = if (app.get("config")) |cf| cf.get("overlay") orelse .null else .null;
    if (ov != .map) return .{};
    var ts: std.ArrayList(topics.Entry) = .empty;
    if (ov.get("topics")) |m| if (m == .map) for (m.map) |e| {
        if (e.value != .text) continue;
        if (findTopic(registered_topics, e.key)) continue;
        try ts.append(a, .{ .topic = e.key, .program = e.value.text });
    };
    var ls: std.ArrayList(lookups.Entry) = .empty;
    if (ov.get("lookups")) |m| if (m == .map) for (m.map) |e| {
        const role = switch (e.value) {
            .text => |t| t,
            .map => e.value.getText("program") orelse continue,
            else => continue,
        };
        if (findName(registered_services, e.key)) continue;
        try ls.append(a, .{ .service = e.key, .program = role });
    };
    const terms: ?Value = if (ov.get("terms")) |t| (if (t == .map) t else null) else null;
    return .{ .topics = ts.items, .lookups = ls.items, .terms = terms };
}

fn findTopic(list: []const topics.Entry, name: []const u8) bool {
    for (list) |e| if (eql(u8, e.topic, name)) return true;
    return false;
}

fn findName(list: []const []const u8, name: []const u8) bool {
    for (list) |x| if (eql(u8, x, name)) return true;
    return false;
}

/// The head's record for `now`.
pub fn recordOf(a: Allocator, now: Now) !Value {
    const ts = try a.alloc(Value, now.topics.len);
    for (now.topics, ts) |e, *o| o.* = .{ .text = e.topic };
    const ls = try a.alloc(Value, now.lookups.len);
    for (now.lookups, ls) |e, *o| o.* = .{ .text = e.service };
    var es: std.ArrayList(cbor.Entry) = .empty;
    try es.appendSlice(a, &.{
        .{ .key = "kind", .value = .{ .text = record_kind } },
        .{ .key = "topics", .value = .{ .array = ts } },
        .{ .key = "lookups", .value = .{ .array = ls } },
    });
    if (now.terms) |t| try es.append(a, .{ .key = "terms", .value = t });
    return .{ .map = es.items };
}

/// The names a declared record lists under `key` (`topics` or `lookups`); none for no record.
pub fn namesOf(a: Allocator, rec: ?Value, key: []const u8) ![]const []const u8 {
    const r = rec orelse return &.{};
    const xs = r.getArray(key) orelse return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    for (xs) |x| if (x == .text) try out.append(a, x.text);
    return out.items;
}

/// Whether the declared record `prev` is the one `now` makes (nothing to declare).
pub fn same(a: Allocator, prev: ?Value, now: Value) !bool {
    const p = prev orelse return false;
    return eql(u8, try cbor.encode(a, p), try cbor.encode(a, now));
}

/// Whether the configuration's terms differ between `prev` and `now` (a change re-declares the
/// registered topics' beacons too: their bodies carry the terms when the head `<app>/terms` is unset).
pub fn termsChanged(a: Allocator, prev: ?Value, now: Value) !bool {
    const p: Value = if (prev) |x| x.get("terms") orelse .null else .null;
    const n: Value = now.get("terms") orelse .null;
    return !eql(u8, try cbor.encode(a, p), try cbor.encode(a, n));
}

/// The names in `before` that are not in `now`: undeclared.
pub fn dropped(a: Allocator, before: []const []const u8, now: []const []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (before) |b| if (!findName(now, b)) try out.append(a, b);
    return out.items;
}

/// The topics `now` beats, as names.
pub fn topicNames(a: Allocator, now: Now) ![]const []const u8 {
    const out = try a.alloc([]const u8, now.topics.len);
    for (now.topics, out) |e, *o| o.* = e.topic;
    return out;
}

/// The lookup services `now` beats, as names.
pub fn lookupNames(a: Allocator, now: Now) ![]const []const u8 {
    const out = try a.alloc([]const u8, now.lookups.len);
    for (now.lookups, out) |e, *o| o.* = e.service;
    return out;
}

const testing = std.testing;

fn appWith(a: Allocator, ov: Value) !Value {
    return .{ .map = try a.dupe(cbor.Entry, &.{
        .{ .key = "kind", .value = .{ .text = "app" } },
        .{ .key = "config", .value = .{ .map = try a.dupe(cbor.Entry, &.{.{ .key = "overlay", .value = ov }}) } },
    }) };
}

test "configured: the configuration's topics and lookups, the registered left out, its terms" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const terms: Value = .{ .map = try a.dupe(cbor.Entry, &.{.{ .key = "lpFeeBps", .value = .{ .uint = 30 } }}) };
    const ov: Value = .{ .map = try a.dupe(cbor.Entry, &.{
        .{ .key = "topics", .value = .{ .map = try a.dupe(cbor.Entry, &.{
            .{ .key = "tm_a", .value = .{ .text = "topic-demo" } },
            .{ .key = "tm_b", .value = .{ .text = "topic-demo" } },
        }) } },
        .{ .key = "lookups", .value = .{ .map = try a.dupe(cbor.Entry, &.{
            .{ .key = "ls_a", .value = .{ .map = try a.dupe(cbor.Entry, &.{
                .{ .key = "program", .value = .{ .text = "lookup-demo" } },
                .{ .key = "topics", .value = .{ .array = try a.dupe(Value, &.{.{ .text = "tm_a" }}) } },
            }) } },
            .{ .key = "ls_b", .value = .{ .text = "lookup-demo" } },
        }) } },
        .{ .key = "terms", .value = terms },
    }) };
    const now = try of(a, try appWith(a, ov), &.{.{ .topic = "tm_b", .program = "topic-demo" }}, &.{"ls_b"});
    try testing.expectEqual(@as(usize, 1), now.topics.len);
    try testing.expectEqualStrings("tm_a", now.topics[0].topic);
    try testing.expectEqual(@as(usize, 1), now.lookups.len);
    try testing.expectEqualStrings("ls_a", now.lookups[0].service);
    try testing.expectEqualStrings("lookup-demo", now.lookups[0].program);
    try testing.expect(now.terms != null);

    const rec = try recordOf(a, now);
    try testing.expect(try same(a, rec, try recordOf(a, now)));
    try testing.expect(!try same(a, null, rec));
    try testing.expect(!try termsChanged(a, rec, rec));
    try testing.expect(try termsChanged(a, null, rec));
    const without = try recordOf(a, .{ .topics = now.topics });
    try testing.expect(!try same(a, rec, without));
    try testing.expect(try termsChanged(a, rec, without));
    const names = try namesOf(a, rec, "topics");
    try testing.expectEqual(@as(usize, 1), names.len);
    const gone = try dropped(a, &.{ "tm_a", "tm_old" }, names);
    try testing.expectEqual(@as(usize, 1), gone.len);
    try testing.expectEqualStrings("tm_old", gone[0]);
}

test "configured: no configuration, nothing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const now = try of(a, .{ .map = &.{} }, &.{}, &.{});
    try testing.expectEqual(@as(usize, 0), now.topics.len + now.lookups.len);
    try testing.expect(now.terms == null);
}
