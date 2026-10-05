//! The engine's configuration as it reads it, and its calls of the app's
//! topic managers and lookup services (#50): which topics and services it
//! runs (`defaults.overlay*`, JSON in a string: from the app record's
//! `config.overlay` or a genesis's, config.zig), which programs they are, and
//! the lookup hooks (`admitted`, `spent`, `rejected`) — in-VM calls with
//! CIDs, never bytes. Every hook and lookup-call carries `app`: the app the
//! engine runs as, whose head `<app>/ls_<service>` the service keeps.
const std = @import("std");
const c = @import("chain");
const st = @import("state.zig");

const cbor = c.cbor;
const Value = cbor.Value;
const store_mod = c.store;
const Allocator = std.mem.Allocator;

/// An in-VM call (#40) as the overlay makes it: `program`'s function `func`
/// on `arg` → its answer. The VM's `call` import in a program; a dispatch
/// table in the native tests.
pub const Caller = struct {
    ctx: *anyopaque,
    callFn: *const fn (ctx: *anyopaque, a: Allocator, program: []const u8, func: []const u8, arg: Value) anyerror!Value,

    pub fn call(self: Caller, a: Allocator, program: []const u8, func: []const u8, arg: Value) !Value {
        return self.callFn(self.ctx, a, program, func, arg);
    }
};

/// The app the engine runs as (config.zig sets `app`): its heads are `<app>/…`.
pub fn appOf(in: Value) []const u8 {
    return in.getText("app") orelse "overlay";
}

/// A config map (defaults.<key>: a JSON object in a string).
pub fn configObject(a: Allocator, in: Value, key: []const u8) !std.json.ObjectMap {
    const text = if (in.get("defaults")) |d| d.getText(key) orelse "{}" else "{}";
    const j = std.json.parseFromSliceLeaky(std.json.Value, a, text, .{}) catch return error.BadConfig;
    if (j != .object) return error.BadConfig;
    return j.object;
}

/// The topics this engine serves, in the config's order.
pub fn servedTopics(a: Allocator, in: Value) ![]const []const u8 {
    const m = try configObject(a, in, "overlayTopics");
    return a.dupe([]const u8, m.keys());
}

/// A program record by its name (the step's or call's `programs`: the app's roles, or the genesis's).
pub fn programNamed(in: Value, name: []const u8) !?[]const u8 {
    const progs = in.get("programs") orelse return error.BadConfig;
    return progs.getCid(name) orelse {
        std.log.err("config names program {s}, not in the programs", .{name});
        return error.BadConfig;
    };
}

/// A configured name's program: the value is the program's name, or (lookups) an object `{program, topics?}`.
pub fn configuredProgram(in: Value, map: std.json.ObjectMap, name: []const u8) !?[]const u8 {
    const v = map.get(name) orelse return null;
    const prog = switch (v) {
        .string => |s| s,
        .object => |o| if (o.get("program")) |p| (if (p == .string) p.string else return error.BadConfig) else return error.BadConfig,
        else => return error.BadConfig,
    };
    return programNamed(in, prog);
}

/// A lookup service that listens to a topic.
pub const Listener = struct { service: []const u8, program: []const u8 };

/// The lookup services listening to `topic`: `{"ls_x": {"program": "<name>", "topics": ["tm_x", …]}}`;
/// the short form `{"ls_x": "<name>"}` listens to every topic served. In the config's order.
pub fn listeners(a: Allocator, in: Value, topic: []const u8) ![]Listener {
    const lookups = try configObject(a, in, "overlayLookups");
    const topics = try configObject(a, in, "overlayTopics");
    var out: std.ArrayList(Listener) = .empty;
    var it = lookups.iterator();
    while (it.next()) |e| {
        const listens = switch (e.value_ptr.*) {
            .string => topics.contains(topic),
            .object => |o| blk: {
                const ts = o.get("topics") orelse break :blk topics.contains(topic);
                if (ts != .array) return error.BadConfig;
                for (ts.array.items) |t| {
                    if (t != .string) return error.BadConfig;
                    if (std.mem.eql(u8, t.string, topic)) break :blk true;
                }
                break :blk false;
            },
            else => return error.BadConfig,
        };
        if (!listens) continue;
        try out.append(a, .{ .service = e.key_ptr.*, .program = (try configuredProgram(in, lookups, e.key_ptr.*)).? });
    }
    return out.items;
}

fn uints(a: Allocator, xs: []const u32) ![]Value {
    const out = try a.alloc(Value, xs.len);
    for (xs, out) |x, *o| o.* = .{ .uint = x };
    return out;
}

fn hookArg(a: Allocator, in: Value, service: []const u8, topic: []const u8, rest: []const cbor.Entry) !Value {
    var es: std.ArrayList(cbor.Entry) = .empty;
    try es.appendSlice(a, &.{
        .{ .key = "kind", .value = .{ .text = "lookup-hook" } },
        .{ .key = "app", .value = .{ .text = appOf(in) } },
        .{ .key = "service", .value = .{ .text = service } },
        .{ .key = "topic", .value = .{ .text = topic } },
    });
    try es.appendSlice(a, rest);
    return .{ .map = es.items };
}

/// A topic admitted a transaction (in the step that recorded it): each of its lookup services'
/// `admitted(topic, tx, outputsToAdmit, coinsRetained)`, then `spent(topic, outpoint, spendingTx)`
/// for each previous coin it consumed.
pub fn hookAdmitted(a: Allocator, caller: Caller, in: Value, topic: []const u8, sub: st.Subject, previous: []const u32, applied: st.Applied) !void {
    for (try listeners(a, in, topic)) |l| {
        _ = try caller.call(a, l.program, "admitted", try hookArg(a, in, l.service, topic, &.{
            .{ .key = "tx", .value = .{ .cid = sub.cid } },
            .{ .key = "outputsToAdmit", .value = .{ .array = try uints(a, applied.outputs_to_admit) } },
            .{ .key = "coinsRetained", .value = .{ .array = try uints(a, applied.coins_to_retain) } },
        }));
        for (previous) |p| {
            const in_ = sub.tx.inputs[p];
            _ = try caller.call(a, l.program, "spent", try hookArg(a, in, l.service, topic, &.{
                .{ .key = "outpoint", .value = .{ .map = try a.dupe(cbor.Entry, &.{
                    .{ .key = "tx", .value = .{ .cid = try a.dupe(u8, &store_mod.hashCid(.tx, in_.previous_outpoint.txid.bytes)) } },
                    .{ .key = "vout", .value = .{ .uint = in_.previous_outpoint.index } },
                }) } },
                .{ .key = "spendingTx", .value = .{ .cid = sub.cid } },
            }));
        }
    }
}

/// The judgements a rejection removed (`State.unapply`): each topic's lookup services' `rejected(topic, tx)`.
pub fn hookRejected(a: Allocator, caller: Caller, in: Value, gone: []const st.Unapplied) !void {
    for (gone) |g| {
        const tc = try a.dupe(u8, &store_mod.hashCid(.tx, g.txid));
        for (try listeners(a, in, g.topic)) |l| {
            _ = try caller.call(a, l.program, "rejected", try hookArg(a, in, l.service, g.topic, &.{.{ .key = "tx", .value = .{ .cid = tc } }}));
        }
    }
}

/// A lookup-call's argument for `service` (the `/lookup` route's): `query` the client's JSON as dag-cbor.
pub fn lookupArg(a: Allocator, in: Value, service: []const u8, query: Value) !Value {
    return .{ .map = try a.dupe(cbor.Entry, &.{
        .{ .key = "kind", .value = .{ .text = "lookup-call" } },
        .{ .key = "app", .value = .{ .text = appOf(in) } },
        .{ .key = "service", .value = .{ .text = service } },
        .{ .key = "query", .value = query },
    }) };
}

/// The argument of fn "metadata" / "documentation" for a configured topic (`overlayTopics`: {kind:
/// "topic-describe", topic}) or lookup service (`overlayLookups`: {kind: "lookup-describe", app, service}).
pub fn describeArg(a: Allocator, in: Value, key: []const u8, name: []const u8) !Value {
    if (std.mem.eql(u8, key, "overlayTopics")) return .{ .map = try a.dupe(cbor.Entry, &.{
        .{ .key = "kind", .value = .{ .text = "topic-describe" } },
        .{ .key = "topic", .value = .{ .text = name } },
    }) };
    return .{ .map = try a.dupe(cbor.Entry, &.{
        .{ .key = "kind", .value = .{ .text = "lookup-describe" } },
        .{ .key = "app", .value = .{ .text = appOf(in) } },
        .{ .key = "service", .value = .{ .text = name } },
    }) };
}
