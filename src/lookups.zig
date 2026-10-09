//! Registered lookup services (skein-overlay 0.11.0; David Case, 2026-10-08:
//! "separate registration calls in the engine"): the lookup services the
//! engine serves beyond the ones its manifest declares
//! (`config.overlay.lookups`), added and removed at runtime by their own pair
//! of calls, apart from the topics' `register` / `deregister` (topics.zig):
//!
//!   {fn: "registerLookup",   args: {service, program, topics?}}
//!   {fn: "deregisterLookup", args: {service}}
//!
//! taken where `register` is (the box `<app>/register`, the same root gating),
//! idempotent, answered `{service, active}`. `program` is the role in
//! `programs` whose lookup program answers the service; `topics`, when given,
//! the topics whose admissions it hears (else every topic the engine serves,
//! as a configured service without `topics`).
//!
//! The set is the engine's own, the root record of the head `<app>/lookups`
//! (beside `<app>/topics`):
//!
//!   {kind: "overlay-lookups", lookups: [{service, program, topics?}, …]}     sorted by service, each once
//!
//! config.zig reads it at every step and call and serves each as if
//! `config.overlay.lookups` named it (a declared service keeps its own
//! entry): `/lookup` routes it, `listLookupServiceProviders` lists it, and the
//! admitted-output hooks reach its program — once per program, not once per
//! name (calls.zig `hookTargets`); a program serving many names keeps one
//! index (lookup.zig `indexOf`). A name neither declared nor registered is
//! not served: `/lookup` answers 400 "Lookup service not supported" (there is
//! no wildcard: under BRC-207 an empty answer means "not spendable", so an
//! unregistered name must never answer an empty list).
//!
//! No events: a lookup service subscribes to nothing (its topics' messages
//! are the topics' registration's). A refusal writes nothing.
//!
//! The logic, natively testable; engine.zig runs it in a step.
const std = @import("std");
const c = @import("chain");

const cbor = c.cbor;
const Value = cbor.Value;
const Allocator = std.mem.Allocator;
const eql = std.mem.eql;

/// The head the set lives under, after the app's name: `<app>/lookups`.
pub const head_suffix = "lookups";
pub const record_kind = "overlay-lookups";

/// One registered lookup service: its name, the role whose program answers it, the topics it
/// hears (null: every topic served).
pub const Entry = struct { service: []const u8, program: []const u8, topics: ?[]const []const u8 = null };

/// The head of the set for app `app`.
pub fn headName(a: Allocator, app: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "{s}/{s}", .{ app, head_suffix });
}

/// The entries a set record holds (null: no set yet, none).
pub fn entriesOf(a: Allocator, rec: ?Value) ![]const Entry {
    const r = rec orelse return &.{};
    if (!eql(u8, r.getText("kind") orelse "", record_kind)) return error.BadLookupSet;
    const ls = r.getArray("lookups") orelse return error.BadLookupSet;
    const out = try a.alloc(Entry, ls.len);
    for (ls, out) |l, *o| o.* = .{
        .service = l.getText("service") orelse return error.BadLookupSet,
        .program = l.getText("program") orelse return error.BadLookupSet,
        .topics = if (l.get("topics")) |t| (topicsOf(a, t) catch return error.BadLookupSet) else null,
    };
    return out;
}

/// The set's record.
pub fn recordOf(a: Allocator, list: []const Entry) !Value {
    const ls = try a.alloc(Value, list.len);
    for (list, ls) |e, *v| {
        var es: std.ArrayList(cbor.Entry) = .empty;
        try es.appendSlice(a, &.{
            .{ .key = "service", .value = .{ .text = e.service } },
            .{ .key = "program", .value = .{ .text = e.program } },
        });
        if (e.topics) |ts| {
            const xs = try a.alloc(Value, ts.len);
            for (ts, xs) |t, *x| x.* = .{ .text = t };
            try es.append(a, .{ .key = "topics", .value = .{ .array = xs } });
        }
        v.* = .{ .map = es.items };
    }
    return .{ .map = try a.dupe(cbor.Entry, &.{
        .{ .key = "kind", .value = .{ .text = record_kind } },
        .{ .key = "lookups", .value = .{ .array = ls } },
    }) };
}

/// `topics`: a list of non-empty topic names, each once, in order. Anything else: error.BadTopics.
fn topicsOf(a: Allocator, v: Value) ![]const []const u8 {
    if (v != .array) return error.BadTopics;
    var out: std.ArrayList([]const u8) = .empty;
    outer: for (v.array) |x| {
        if (x != .text or x.text.len == 0) return error.BadTopics;
        for (out.items) |y| if (eql(u8, y, x.text)) continue :outer;
        try out.append(a, x.text);
    }
    return out.items;
}

fn sameTopics(x: ?[]const []const u8, y: ?[]const []const u8) bool {
    if (x == null or y == null) return x == null and y == null;
    if (x.?.len != y.?.len) return false;
    for (x.?, y.?) |p, q| if (!eql(u8, p, q)) return false;
    return true;
}

fn find(list: []const Entry, service: []const u8) ?Entry {
    for (list) |e| if (eql(u8, e.service, service)) return e;
    return null;
}

fn lessThan(_: void, x: Entry, y: Entry) bool {
    return std.mem.order(u8, x.service, y.service) == .lt;
}

/// What a registerLookup or deregisterLookup does: the set to write (null: unchanged), the
/// answer `{service, active}`. Or why it is refused (nothing written).
pub const Change = union(enum) {
    refused: []const u8,
    done: struct { list: ?[]const Entry, answer: Value },
};

fn answerOf(a: Allocator, service: []const u8, active: bool) !Value {
    return .{ .map = try a.dupe(cbor.Entry, &.{
        .{ .key = "service", .value = .{ .text = service } },
        .{ .key = "active", .value = .{ .boolean = active } },
    }) };
}

fn refused(a: Allocator, comptime fmt: []const u8, args: anytype) !Change {
    return .{ .refused = try std.fmt.allocPrint(a, fmt, args) };
}

/// `registerLookup {service, program, topics?}`: `program` a role in `programs` (the app's roles,
/// or the genesis's). Refused: no service or program, an unknown role, `topics` not a list of
/// topic names, a service registered already with another program or other topics (deregister it
/// first). The same again changes nothing.
pub fn register(a: Allocator, list: []const Entry, args: Value, programs: Value) !Change {
    const service = args.getText("service") orelse return refused(a, "registerLookup: want {{service, program, topics?}}", .{});
    const program = args.getText("program") orelse return refused(a, "registerLookup: want {{service, program, topics?}}", .{});
    if (service.len == 0) return refused(a, "registerLookup: the service is empty", .{});
    if (programs.getCid(program) == null) return refused(a, "registerLookup: program {s} is not a role in programs", .{program});
    const topics: ?[]const []const u8 = if (args.get("topics")) |t| (if (t == .null) null else topicsOf(a, t) catch return refused(a, "registerLookup: topics is a list of topic names", .{})) else null;
    if (find(list, service)) |e| {
        if (!eql(u8, e.program, program) or !sameTopics(e.topics, topics))
            return refused(a, "registerLookup: {s} is registered with program {s}{s}: deregisterLookup it first", .{ service, e.program, if (sameTopics(e.topics, topics)) "" else " and other topics" });
        return .{ .done = .{ .list = null, .answer = try answerOf(a, service, true) } };
    }
    const out = try a.alloc(Entry, list.len + 1);
    @memcpy(out[0..list.len], list);
    out[list.len] = .{ .service = service, .program = program, .topics = topics };
    std.mem.sort(Entry, out, {}, lessThan);
    return .{ .done = .{ .list = out, .answer = try answerOf(a, service, true) } };
}

/// `deregisterLookup {service}`. Not registered: nothing changes.
pub fn deregister(a: Allocator, list: []const Entry, args: Value) !Change {
    const service = args.getText("service") orelse return refused(a, "deregisterLookup: want {{service}}", .{});
    if (find(list, service) == null) return .{ .done = .{ .list = null, .answer = try answerOf(a, service, false) } };
    var out: std.ArrayList(Entry) = .empty;
    for (list) |e| if (!eql(u8, e.service, service)) try out.append(a, e);
    return .{ .done = .{ .list = out.items, .answer = try answerOf(a, service, false) } };
}
