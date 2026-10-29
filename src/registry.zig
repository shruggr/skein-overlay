//! register / deregister / registerLookup / deregisterLookup (topics.zig, lookups.zig): what a
//! registration does, taken two ways —
//!
//!   a message   {fn, args} in the box `<app>/register` (engine.zig; one box per function class,
//!               shruggr/skein#128): `gate` the refusal of any other box (topics.zig `notHere`);
//!               answered to the sender by message, the result record the step's (`finish`).
//!   a call      (0.18.0, skein-overlay#10) fn "register" | "deregister" | "registerLookup" |
//!               "deregisterLookup", `arg` what the message's `args` is, from a program of the
//!               instance in a step (an in-VM call, skein docs/VM.md "Calls"; routes.zig `call`):
//!               no box, no role or grant check — only a program of the instance can call in a
//!               step. The engine's app is the calling step's: the program of its thread
//!               (`step.thread`), whose app record names the engine (its role `overlay`). Answered
//!               `{fn, result}` or `{fn, error: {code: "bad-args", message}}` (the message form's
//!               answer without `request` / `replyTo`: there is no message); the result record kept
//!               on the step, with the call's `caller` (the kernel's: the calling step's thread). A
//!               kernel call (no `step`: it writes nothing) is answered `bad-args`, nothing kept.
//!
//! Either way the same: the set under `<app>/topics` (`<app>/lookups`), the subscribe / liveness /
//! beacon events (or their ends) emitted on the step, `seed` judged under the topic; the effects
//! through `Fx` (engine_vm.zig `effects`: the `skein` imports; test.zig: in memory).
const std = @import("std");
const c = @import("chain");
const config = @import("config.zig");
const calls = @import("calls.zig");
const submit = @import("submit.zig");
const state = @import("state.zig");
const topics = @import("topics.zig");
const lookups = @import("lookups.zig");

const cbor = c.cbor;
const Value = cbor.Value;
const Store = c.store.Store;
const Allocator = std.mem.Allocator;
const eql = std.mem.eql;

/// The overlay's state as a step loads it (engine_vm.zig `load`): `head` the CID it loaded.
pub const Loaded = struct { st: state.State, head: ?[]const u8 };

/// What a registration reads and writes: the store and heads, the calls of topic and lookup
/// programs, the head moves, events, kept records, the overlay's state, messages to the instance.
pub const Fx = struct {
    ctx: *anyopaque,
    store: Store,
    heads: config.Heads,
    caller: calls.Caller,
    advanceFn: *const fn (ctx: *anyopaque, name: []const u8, cid: []const u8) anyerror!void,
    emitFn: *const fn (ctx: *anyopaque, a: Allocator, ev: Value) anyerror![]const u8,
    keepFn: *const fn (ctx: *anyopaque, cid: []const u8) anyerror!void,
    loadFn: *const fn (ctx: *anyopaque, a: Allocator, in: Value) anyerror!Loaded,
    wireFn: *const fn (ctx: *anyopaque, in: Value) anyerror!submit.Wire,

    pub fn advance(self: Fx, name: []const u8, cid: []const u8) !void {
        return self.advanceFn(self.ctx, name, cid);
    }
    pub fn emit(self: Fx, a: Allocator, ev: Value) ![]const u8 {
        return self.emitFn(self.ctx, a, ev);
    }
    pub fn keep(self: Fx, cid: []const u8) !void {
        return self.keepFn(self.ctx, cid);
    }
    pub fn load(self: Fx, a: Allocator, in: Value) !Loaded {
        return self.loadFn(self.ctx, a, in);
    }
    pub fn wire(self: Fx, in: Value) !submit.Wire {
        return self.wireFn(self.ctx, in);
    }
};

// ---------------------------------------------------------------- shared helpers

pub fn uints(a: Allocator, xs: []const u32) ![]Value {
    const out = try a.alloc(Value, xs.len);
    for (xs, out) |x, *o| o.* = .{ .uint = x };
    return out;
}

pub fn resultRecord(a: Allocator, op: []const u8, fields: []const cbor.Entry) !Value {
    var es: std.ArrayList(cbor.Entry) = .empty;
    try es.appendSlice(a, &.{
        .{ .key = "kind", .value = .{ .text = "overlay-result" } },
        .{ .key = "op", .value = .{ .text = op } },
    });
    try es.appendSlice(a, fields);
    return .{ .map = es.items };
}

pub fn cids(a: Allocator, xs: []const []const u8) ![]Value {
    const out = try a.alloc(Value, xs.len);
    for (xs, out) |x, *o| o.* = .{ .cid = x };
    return out;
}

pub fn hexes(a: Allocator, xs: []const [32]u8) ![]Value {
    const out = try a.alloc(Value, xs.len);
    for (xs, out) |x, *o| o.* = .{ .text = try a.dupe(u8, &c.header.toHex(x)) };
    return out;
}

pub fn steakOf(a: Allocator, topics_: []const []const u8, applied: []const state.Applied) !Value {
    var steak: std.ArrayList(cbor.Entry) = .empty;
    for (topics_, applied) |t, ap| try steak.append(a, .{ .key = t, .value = .{ .map = try a.dupe(cbor.Entry, &.{
        .{ .key = "outputsToAdmit", .value = .{ .array = try uints(a, ap.outputs_to_admit) } },
        .{ .key = "coinsToRetain", .value = .{ .array = try uints(a, ap.coins_to_retain) } },
        .{ .key = "coinsRemoved", .value = .{ .array = try uints(a, ap.coins_removed) } },
    }) } });
    return .{ .map = steak.items };
}

/// The engine's roles (config.zig `rolesOf`; null: a bad configuration, error.BadRoles) with the
/// beat's terms (0.16.0): the record of the head `<app>/terms` the app writes (config.zig `termsOf`),
/// read now, at each beacon declaration.
pub fn roles(a: Allocator, fx: Fx, step: Value) !?topics.Roles {
    var r = config.rolesOf(a, step) catch |e| switch (e) {
        error.BadRoles => return null,
        else => |x| return x,
    };
    r.terms = try config.termsOf(a, fx.store, fx.heads, calls.appOf(step));
    return r;
}

/// The registered lookup services' names (`<app>/lookups`).
pub fn lookupNames(a: Allocator, fx: Fx, step: Value) ![]const []const u8 {
    const root = try fx.heads.head(a, try lookups.headName(a, calls.appOf(step)));
    const ll = try lookups.entriesOf(a, if (root) |r| try fx.store.getValue(a, r) else null);
    const out = try a.alloc([]const u8, ll.len);
    for (ll, out) |l, *o| o.* = l.service;
    return out;
}

fn rolesRefusal(a: Allocator, func: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "{s}: the configuration's roles are config.overlay.market {{window: <ms>}} and config.overlay.validator {{every: <ms>}}, each from 1000 ms to a day", .{func});
}

/// A topic's beat body as the state holds its beat now (0.12.0, 0.14.0, topics.zig `beatBody`), with the
/// terms (0.16.0: the head `<app>/terms`'s record, `roles`): the register's `topic` (none: the empty view).
fn topicBeat(a: Allocator, fx: Fx, step: Value, fargs: Value, r: topics.Roles) ![]const u8 {
    const t = fargs.getText("topic") orelse return topics.beatBody(a, .{}, r.terms);
    if (t.len == 0) return topics.beatBody(a, .{}, r.terms);
    var loaded = try fx.load(a, step);
    return topics.beatBody(a, try loaded.st.beat(t), r.terms);
}

/// A registration's outcome: its result (`{topic | service, active, seeded?, missing?, untaken?}`)
/// or why it was refused (nothing written, nothing emitted); the result record's fields either way.
pub const Done = struct {
    result: ?Value = null,
    refused: ?[]const u8 = null,
    fields: []const cbor.Entry,
};

// ---------------------------------------------------------------- the registrations

/// `register {topic, program, seed?}` / `deregister {topic}` (`func`), `fargs` its arguments; `gate`
/// a refusal decided before (the message form's box). The set written under `<app>/topics` and the
/// events emitted when it changes; with `seed`, the held seeds judged (`seeding`).
pub fn topic(a: Allocator, fx: Fx, step: Value, fargs: Value, func: []const u8, gate: ?[]const u8) !Done {
    const s = fx.store;
    const head = try topics.headName(a, calls.appOf(step));
    const root = try fx.heads.head(a, head);
    const rec: ?Value = if (root) |r| try s.getValue(a, r) else null;
    const list = try topics.entriesOf(a, rec);
    // The roles: always a market and a validator (0.12.0), at config.overlay.market / .validator's ms or the defaults.
    const rl: ?topics.Roles = try roles(a, fx, step); // null: error.BadRoles
    const change: topics.Change = if (gate) |why|
        .{ .refused = why }
    else if (rl == null)
        .{ .refused = try rolesRefusal(a, func) }
    else if (eql(u8, func, "register"))
        try topics.withRoles(a, try topics.register(a, list, fargs, step.get("programs") orelse return error.BadConfig, try config.selfRole(a, s, step, null)), true, rl.?, try topicBeat(a, fx, step, fargs, rl.?))
    else
        try topics.withRoles(a, try topics.deregister(a, list, fargs), false, rl.?, "");
    var fields: std.ArrayList(cbor.Entry) = .empty;
    switch (change) {
        .refused => |why| {
            try fields.append(a, .{ .key = "error", .value = .{ .text = why } });
            return .{ .refused = why, .fields = fields.items };
        },
        .done => |d| {
            if (d.list) |l| {
                const rc = try s.putValue(a, try topics.recordOf(a, l));
                try fx.advance(head, rc);
                try fields.append(a, .{ .key = "topics", .value = .{ .cid = rc } });
            }
            for (d.events) |ev| _ = try fx.emit(a, ev);
            var answer = d.answer;
            if (d.seed) |seeds| answer = try seeding(a, fx, step, d.list orelse list, answer, seeds, &fields, rl.?);
            try fields.appendSlice(a, &.{
                .{ .key = "topic", .value = d.answer.get("topic").? },
                .{ .key = "active", .value = d.answer.get("active").? },
                .{ .key = "changed", .value = .{ .boolean = d.list != null } },
            });
            return .{ .result = answer, .fields = fields.items };
        },
    }
}

/// `registerLookup {service, program, topics?}` / `deregisterLookup {service}` (0.11.0, lookups.zig),
/// `gate` as `topic`'s. The set written under `<app>/lookups` when it changes, and (0.12.0) the
/// service's beacon on `<service>-live` declared (its body the program's fn "beat", calls.zig
/// `lookupBeat`) or ended.
pub fn lookup(a: Allocator, fx: Fx, step: Value, fargs: Value, func: []const u8, gate: ?[]const u8) !Done {
    const s = fx.store;
    const head = try lookups.headName(a, calls.appOf(step));
    const root = try fx.heads.head(a, head);
    const list = try lookups.entriesOf(a, if (root) |r| try s.getValue(a, r) else null);
    const rl: ?topics.Roles = try roles(a, fx, step); // null: error.BadRoles
    const change: lookups.Change = if (gate) |why|
        .{ .refused = why }
    else if (rl == null)
        .{ .refused = try rolesRefusal(a, func) }
    else if (eql(u8, func, "registerLookup"))
        try lookups.register(a, list, fargs, step.get("programs") orelse return error.BadConfig)
    else
        try lookups.deregister(a, list, fargs);
    var fields: std.ArrayList(cbor.Entry) = .empty;
    switch (change) {
        .refused => |why| {
            try fields.append(a, .{ .key = "error", .value = .{ .text = why } });
            return .{ .refused = why, .fields = fields.items };
        },
        .done => |d| {
            if (d.list) |l| {
                const rc = try s.putValue(a, try lookups.recordOf(a, l));
                try fx.advance(head, rc);
                try fields.append(a, .{ .key = "lookups", .value = .{ .cid = rc } });
                // Liveness and the beacon on `<service>-live` (0.12.0, 0.12.1), as a topic's.
                const service = d.answer.getText("service").?;
                const reg = eql(u8, func, "registerLookup");
                const beat = if (reg) try calls.lookupBeat(a, fx.caller, try config.withLookups(a, step, l), service, fargs.getText("program") orelse "") else "";
                for (try topics.roleEvents(a, reg, service, rl.?, beat)) |ev| _ = try fx.emit(a, ev);
            }
            try fields.appendSlice(a, &.{
                .{ .key = "service", .value = d.answer.get("service").? },
                .{ .key = "active", .value = d.answer.get("active").? },
                .{ .key = "changed", .value = .{ .boolean = d.list != null } },
            });
            return .{ .result = d.answer, .fields = fields.items };
        },
    }
}

/// A register's `seed` (0.7.8, submit.zig `seed`): each seed the chain state holds judged under the
/// topic just registered, with the configuration as it is with the set `list` (the one this step
/// wrote); the records kept, the state saved. → the answer with `seeded`, `missing` (and `untaken`
/// when a held seed is taken by nothing); the result record gets them and `state`.
fn seeding(a: Allocator, fx: Fx, step: Value, list: []const topics.Entry, answer: Value, seeds: []const [32]u8, fields: *std.ArrayList(cbor.Entry), rl: topics.Roles) !Value {
    const t = answer.getText("topic").?;
    const in = try config.withTopics(a, step, list);
    var loaded = try fx.load(a, in);
    loaded.st.now = @intCast(step.getUint("at") orelse 0);
    const cx = submit.Ctx{ .a = a, .caller = fx.caller, .wire = try fx.wire(in), .st = &loaded.st, .in = in };
    const sd = try submit.seed(cx, t, seeds);
    for (sd.records) |r| try fx.keep(r);
    // The view the seeds changed: the beacons re-declared (0.12.0), over the set this step wrote.
    const beats = try topics.beatEvents(a, rl, list, try lookupNames(a, fx, step), try loaded.st.beatChanges(), loaded.st.lookup_beats.items);
    for (beats) |e| _ = try fx.emit(a, e);
    if (beats.len > 0) try fields.append(a, .{ .key = "beats", .value = .{ .uint = beats.len } });
    const new_state = try loaded.st.save();
    if (loaded.head == null or !eql(u8, loaded.head.?, new_state)) try fx.advance(try stateHead(a, in), new_state);
    var out: std.ArrayList(cbor.Entry) = .empty;
    try out.appendSlice(a, answer.map);
    try out.appendSlice(a, &.{
        .{ .key = "seeded", .value = .{ .array = try hexes(a, sd.seeded) } },
        .{ .key = "missing", .value = .{ .array = try hexes(a, sd.missing) } },
    });
    if (sd.untaken.len > 0) try out.append(a, .{ .key = "untaken", .value = .{ .array = try hexes(a, sd.untaken) } });
    try fields.appendSlice(a, out.items[answer.map.len..]);
    if (sd.admissions.len > 0) {
        const xs = try a.alloc(Value, sd.admissions.len);
        for (sd.admissions, xs) |adm, *x| x.* = .{ .map = try a.dupe(cbor.Entry, &.{
            .{ .key = "txid", .value = .{ .text = try a.dupe(u8, &c.header.toHex(adm.txid)) } },
            .{ .key = "steak", .value = try steakOf(a, adm.topics, adm.applied) },
        }) };
        try fields.append(a, .{ .key = "admissions", .value = .{ .array = xs } });
    }
    if (sd.watches.len > 0) try fields.append(a, .{ .key = "watches", .value = .{ .array = try cids(a, sd.watches) } });
    try fields.append(a, .{ .key = "state", .value = .{ .cid = new_state } });
    return .{ .map = out.items };
}

/// The head the overlay's state lives under: `<app>/state` (engine_vm.zig `stateHead`).
fn stateHead(a: Allocator, in: Value) ![]const u8 {
    return std.fmt.allocPrint(a, "{s}/state", .{calls.appOf(in)});
}

// ---------------------------------------------------------------- by call (0.18.0)

/// Whether `func` is a registration's (taken by call as by message).
pub fn isRegistration(func: []const u8) bool {
    return eql(u8, func, "register") or eql(u8, func, "deregister") or
        eql(u8, func, "registerLookup") or eql(u8, func, "deregisterLookup");
}

/// A call's input as a registration reads it: the engine of the calling step's app — its thread's
/// program's app record (`<app>/app`), its role `overlay` — configured as a step of that engine is
/// (config.zig `fromApp`, the registered sets), with the step's `at`. Null: no `step` (a kernel
/// call), or the thread's program is of no app with an overlay engine.
pub fn callStep(a: Allocator, s: Store, heads: config.Heads, call_in: Value) !?Value {
    const sv = call_in.get("step") orelse return null;
    const thread = sv.getCid("thread") orelse return error.BadInput;
    const program = (try s.getValue(a, thread)).getCid("program") orelse return null;
    const app = (try config.appRecord(a, s, heads, program)) orelse return null;
    const engine = (app.get("programs") orelse return null).getCid(config.engine_role) orelse return null;
    const name = try config.appName(a, s, program);
    var es: std.ArrayList(cbor.Entry) = .empty;
    if (call_in == .map) for (call_in.map) |e| {
        if (!eql(u8, e.key, "at")) try es.append(a, e);
    };
    try es.append(a, .{ .key = "at", .value = .{ .uint = sv.getUint("at") orelse 0 } });
    return try config.withApp(a, try config.withRegistered(a, s, heads, try config.fromApp(a, .{ .map = es.items }, app, engine), name), name);
}

fn errorAnswer(a: Allocator, func: []const u8, why: []const u8) !Value {
    return .{ .map = try a.dupe(cbor.Entry, &.{
        .{ .key = "fn", .value = .{ .text = func } },
        .{ .key = "error", .value = .{ .map = try a.dupe(cbor.Entry, &.{
            .{ .key = "code", .value = .{ .text = "bad-args" } },
            .{ .key = "message", .value = .{ .text = why } },
        }) } },
    }) };
}

/// A registration by call (0.18.0, skein-overlay#10): `func` on `arg` (the message form's `args`)
/// from a program of the instance in a step. → the call's answer `{fn, result}` or `{fn, error:
/// {code: "bad-args", message}}`; the result record (op `func`, `caller` the call's) kept.
pub fn byCall(a: Allocator, fx: Fx, call_in: Value, func: []const u8, arg: Value) !Value {
    if (call_in.get("step") == null)
        return errorAnswer(a, func, try std.fmt.allocPrint(a, "{s}: by call only from a step (a kernel call writes nothing)", .{func}));
    var done: Done = undefined;
    if (try callStep(a, fx.store, fx.heads, call_in)) |step| {
        done = if (eql(u8, func, "register") or eql(u8, func, "deregister"))
            try topic(a, fx, step, arg, func, null)
        else
            try lookup(a, fx, step, arg, func, null);
    } else {
        const why = try std.fmt.allocPrint(a, "{s}: by call, the calling thread's program is of no app with an overlay engine (role `{s}`)", .{ func, config.engine_role });
        done = .{ .refused = why, .fields = try a.dupe(cbor.Entry, &.{.{ .key = "error", .value = .{ .text = why } }}) };
    }
    var fields: std.ArrayList(cbor.Entry) = .empty;
    try fields.appendSlice(a, done.fields);
    if (call_in.getBytes("caller")) |by| try fields.append(a, .{ .key = "caller", .value = .{ .bytes = by } });
    try fx.keep(try fx.store.putValue(a, try resultRecord(a, func, fields.items)));
    if (done.refused) |why| return errorAnswer(a, func, why);
    return .{ .map = try a.dupe(cbor.Entry, &.{
        .{ .key = "fn", .value = .{ .text = func } },
        .{ .key = "result", .value = done.result.? },
    }) };
}
