//! The engine's configuration as it reads it, and its calls of the app's
//! topic managers and lookup services (#50): which topics and services it
//! runs (`defaults.overlay*`, JSON in a string: from the app record's
//! `config.overlay` or a genesis's, config.zig), which programs they are, and
//! the lookup hooks (`admitted`, `spent`, `rejected`) — in-VM calls with
//! CIDs, never bytes. Every hook and lookup-call carries `app`: the app the
//! engine runs as, under whose name the service keeps its index, and
//! `program`: the role the service is called as (lookup.zig `indexOf`).
//!
//! The hooks reach each lookup program once per admitted transaction and
//! topic, not once per service name (skein-overlay 0.11.0): a program serving
//! many names (configured, or registered with `registerLookup`) keeps one
//! index (`hookTargets`). The reference engine (@bsv/overlay) notifies every
//! lookup service per admitted output; a program here is not called again for
//! each of its names.
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
    /// The last failed call's error text (the callee's last stderr line, as the kernel reports it:
    /// `call <program>.<fn>: …`), read when `call` failed; none: only the error's name is known.
    errorFn: ?*const fn (ctx: *anyopaque) []const u8 = null,

    pub fn call(self: Caller, a: Allocator, program: []const u8, func: []const u8, arg: Value) !Value {
        return self.callFn(self.ctx, a, program, func, arg);
    }

    /// The text of the error the last `call` failed with: the callee's, else the error's name.
    pub fn errorText(self: Caller, e: anyerror) []const u8 {
        if (self.errorFn) |f| {
            const t = f(self.ctx);
            if (t.len > 0) return t;
        }
        return @errorName(e);
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
    return programNamed(in, (try configuredRole(map, name)) orelse return null);
}

/// A configured name's role (its program's name in `programs`), or null when the map names it not.
pub fn configuredRole(map: std.json.ObjectMap, name: []const u8) !?[]const u8 {
    const v = map.get(name) orelse return null;
    return switch (v) {
        .string => |s| s,
        .object => |o| if (o.get("program")) |p| (if (p == .string) p.string else return error.BadConfig) else return error.BadConfig,
        else => return error.BadConfig,
    };
}

/// A lookup service that listens to a topic: its name, its program record, the role it is.
pub const Listener = struct { service: []const u8, program: []const u8, role: []const u8 = "" };

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
        const role = (try configuredRole(lookups, e.key_ptr.*)).?;
        try out.append(a, .{ .service = e.key_ptr.*, .program = (try programNamed(in, role)).?, .role = role });
    }
    return out.items;
}

/// The lookup programs a topic's hooks reach: each program listening to `topic` once, by its
/// program record, in the config's order — the first of its names that listens (`service`) and
/// its role. A program with several names keeps one index (lookup.zig `indexOf`).
pub fn hookTargets(a: Allocator, in: Value, topic: []const u8) ![]Listener {
    var out: std.ArrayList(Listener) = .empty;
    outer: for (try listeners(a, in, topic)) |l| {
        for (out.items) |x| if (std.mem.eql(u8, x.program, l.program)) continue :outer;
        try out.append(a, l);
    }
    return out.items;
}

fn uints(a: Allocator, xs: []const u32) ![]Value {
    const out = try a.alloc(Value, xs.len);
    for (xs, out) |x, *o| o.* = .{ .uint = x };
    return out;
}

fn hookArg(a: Allocator, in: Value, l: Listener, topic: []const u8, rest: []const cbor.Entry) !Value {
    return hookArgOf(a, in, l, topic, rest, false);
}

/// A hook's argument; `reindex` (0.23.0): the reindex thread's, `reindex: true` (lookup.zig: the
/// service's state the head `<head>.reindex`).
fn hookArgOf(a: Allocator, in: Value, l: Listener, topic: []const u8, rest: []const cbor.Entry, reindex: bool) !Value {
    var es: std.ArrayList(cbor.Entry) = .empty;
    try es.appendSlice(a, &.{
        .{ .key = "kind", .value = .{ .text = "lookup-hook" } },
        .{ .key = "app", .value = .{ .text = appOf(in) } },
        .{ .key = "service", .value = .{ .text = l.service } },
        .{ .key = "program", .value = .{ .text = l.role } },
        .{ .key = "topic", .value = .{ .text = topic } },
    });
    try es.appendSlice(a, rest);
    if (reindex) try es.append(a, .{ .key = "reindex", .value = .{ .boolean = true } });
    return .{ .map = es.items };
}

/// The beat bodies a hook's answer carries (`{beats: {<service>: bytes}}`, lookup.zig, 0.12.0), onto
/// `out` in order. Anything else in `beats` is passed over.
pub fn beatsOf(a: Allocator, answer: Value, out: *std.ArrayList(st.LookupBeat)) !void {
    const bs = answer.get("beats") orelse return;
    if (bs != .map) return;
    for (bs.map) |e| if (e.value == .bytes) try out.append(a, .{ .service = e.key, .body = e.value.bytes });
}

/// The events a hook's answer carries (`{events: [map]}`, lookup.zig, 0.20.4), onto `out` in order.
/// An entry that is not a map with a text `event` is passed over.
pub fn eventsOf(a: Allocator, answer: Value, out: *std.ArrayList(Value)) !void {
    const es = answer.get("events") orelse return;
    if (es != .array) return;
    for (es.array) |e| if (e == .map and e.getText("event") != null) try out.append(a, e);
}

/// A hook's answer: its beat bodies onto `st.lookup_beats`, its events onto `st.lookup_events`.
fn hooked(a: Allocator, answer: Value, out: *st.State) !void {
    try beatsOf(a, answer, &out.lookup_beats);
    try eventsOf(a, answer, &out.lookup_events);
}

/// A topic admitted a transaction (in the step that recorded it): each of its lookup programs'
/// (once each, `hookTargets`) `admitted(topic, tx, outputsToAdmit, coinsRetained)`, then
/// `spent(topic, outpoint, spendingTx)` for each previous coin it consumed. The beat bodies the
/// hooks answer go onto `out.lookup_beats` (0.12.0), their events onto `out.lookup_events` (0.20.4).
pub fn hookAdmitted(a: Allocator, caller: Caller, in: Value, topic: []const u8, sub: st.Subject, previous: []const u32, applied: st.Applied, out: *st.State) !void {
    for (try hookTargets(a, in, topic)) |l| try hookAdmittedTo(a, caller, in, l, topic, sub, previous, applied, out, false);
}

/// One lookup program's `admitted`, then its `spent` for each previous coin, as `hookAdmitted` calls
/// them; `reindex` (0.23.0, reindex.zig): the reindex thread's call — `reindex: true` on each
/// argument, and what the hooks answer (beats, events) dropped (`out` is not touched).
pub fn hookAdmittedTo(a: Allocator, caller: Caller, in: Value, l: Listener, topic: []const u8, sub: st.Subject, previous: []const u32, applied: st.Applied, out: *st.State, reindex: bool) !void {
    const ans = try caller.call(a, l.program, "admitted", try hookArgOf(a, in, l, topic, &.{
        .{ .key = "tx", .value = .{ .cid = sub.cid } },
        .{ .key = "outputsToAdmit", .value = .{ .array = try uints(a, applied.outputs_to_admit) } },
        .{ .key = "coinsRetained", .value = .{ .array = try uints(a, applied.coins_to_retain) } },
    }, reindex));
    if (!reindex) try hooked(a, ans, out);
    for (previous) |p| {
        const in_ = sub.tx.inputs[p];
        const sp = try caller.call(a, l.program, "spent", try hookArgOf(a, in, l, topic, &.{
            .{ .key = "outpoint", .value = .{ .map = try a.dupe(cbor.Entry, &.{
                .{ .key = "tx", .value = .{ .cid = try a.dupe(u8, &store_mod.hashCid(.tx, in_.previous_outpoint.txid.bytes)) } },
                .{ .key = "vout", .value = .{ .uint = in_.previous_outpoint.index } },
            }) } },
            .{ .key = "spendingTx", .value = .{ .cid = sub.cid } },
        }, reindex));
        if (!reindex) try hooked(a, sp, out);
    }
}

/// A lookup program's fn "reindex" (0.23.0, lookup.zig `reindexOp`): `op` begin, switch or abort, for
/// the listener `l` → its answer.
pub fn reindexCall(a: Allocator, caller: Caller, in: Value, l: Listener, op: []const u8) !Value {
    return caller.call(a, l.program, "reindex", .{ .map = try a.dupe(cbor.Entry, &.{
        .{ .key = "kind", .value = .{ .text = "lookup-reindex" } },
        .{ .key = "app", .value = .{ .text = appOf(in) } },
        .{ .key = "service", .value = .{ .text = l.service } },
        .{ .key = "program", .value = .{ .text = l.role } },
        .{ .key = "op", .value = .{ .text = op } },
    }) });
}

/// The judgements a rejection removed (`State.unapply`): each topic's lookup programs' (once each,
/// `hookTargets`) `rejected(topic, tx)`. The beat bodies the hooks answer go onto `out.lookup_beats`
/// (0.12.0), their events onto `out.lookup_events` (0.20.4).
pub fn hookRejected(a: Allocator, caller: Caller, in: Value, gone: []const st.Unapplied, out: *st.State) !void {
    for (gone) |g| {
        const tc = try a.dupe(u8, &store_mod.hashCid(.tx, g.txid));
        for (try hookTargets(a, in, g.topic)) |l| {
            try hooked(a, try caller.call(a, l.program, "rejected", try hookArg(a, in, l, g.topic, &.{.{ .key = "tx", .value = .{ .cid = tc } }})), out);
            // 0.23.0: a program being reindexed (`out.reindexing`, its role) hears the rejection in its
            // reindex's state too — the walk may have passed the transaction already; a hook that was
            // never told of the transaction does nothing with it. What it answers is dropped.
            for (out.reindexing) |r| if (std.mem.eql(u8, r, l.role)) {
                _ = try caller.call(a, l.program, "rejected", try hookArgOf(a, in, l, g.topic, &.{.{ .key = "tx", .value = .{ .cid = tc } }}, true));
            };
        }
    }
}

/// A lookup service's beat body at its beacon's declaration (0.12.0): its program's fn "beat"
/// (`{kind: "lookup-beat", app, service, program}` → `{body: bytes}`, lookup.zig). A program that
/// answers none (one built before 0.12.0) beats an empty body.
pub fn lookupBeat(a: Allocator, caller: Caller, in: Value, service: []const u8, role: []const u8) ![]const u8 {
    const program = (programNamed(in, role) catch return "") orelse return "";
    const ans = caller.call(a, program, "beat", .{ .map = try a.dupe(cbor.Entry, &.{
        .{ .key = "kind", .value = .{ .text = "lookup-beat" } },
        .{ .key = "app", .value = .{ .text = appOf(in) } },
        .{ .key = "service", .value = .{ .text = service } },
        .{ .key = "program", .value = .{ .text = role } },
    }) }) catch return "";
    return ans.getBytes("body") orelse "";
}

/// A lookup-call's argument for `service` (the `/lookup` route's): `query` the client's JSON as
/// dag-cbor; `program` the role the configuration (declared or registered) names for it.
pub fn lookupArg(a: Allocator, in: Value, service: []const u8, query: Value) !Value {
    var es: std.ArrayList(cbor.Entry) = .empty;
    try es.appendSlice(a, &.{
        .{ .key = "kind", .value = .{ .text = "lookup-call" } },
        .{ .key = "app", .value = .{ .text = appOf(in) } },
        .{ .key = "service", .value = .{ .text = service } },
    });
    if (try configuredRole(try configObject(a, in, "overlayLookups"), service)) |role| try es.append(a, .{ .key = "program", .value = .{ .text = role } });
    try es.append(a, .{ .key = "query", .value = query });
    return .{ .map = es.items };
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
