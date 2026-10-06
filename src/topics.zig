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
//! Market and validator (David, 2026-10-06 evening): with
//! `config.overlay.market: {window}` set, a register that changes the set
//! also emits `liveness {topic: <topic>-live, window}`; with
//! `config.overlay.validator: {every}`, `beacon {topic: <topic>-live, every,
//! body: <empty>}`. A deregister that changes it emits `unliveness` /
//! `unbeacon` likewise (`withRoles`). Nothing at a start or re-read: the
//! intents stand in the log.
//!
//! The owner's switch (David, 2026-10-07: "this shouldn't have been a config
//! in the manifest. This should be a setting that the user is configuring";
//! 0.9.2): `market {window} | {off: true}` and `validator {every} | {off:
//! true}`, taken where register is, kept in this same record beside
//! `topics`:
//!
//!   {kind: "overlay-topics", topics: [...], market?: {window} | {off: true}, validator?: {every} | {off: true}}
//!
//! A role switched has precedence over the manifest's value (`effective`);
//! one never switched is the manifest's. Turned on, `liveness` / `beacon` for
//! every registered topic; off, `unliveness` / `unbeacon` (`switchRole`).
//!
//! Seeding (0.7.8): `register {topic, program, seed?: [txid hex, …]}` — after
//! the topic is registered (or found registered with the same program), each
//! `seed` transaction the chain state holds is judged under that topic alone,
//! as a submission of it would be (submit.zig `seed`): oldest first over what
//! is held — the seed's held ancestors the topic takes, then the seed — and
//! admitted from the state, the chain app having it already. The answer adds
//! `seeded` (the seeds the topic holds now), `missing` (the seeds the chain
//! state does not hold, or holds rejected) and `untaken` (held, but the topic
//! takes nothing of them; only when there is one). A seed already admitted
//! under the topic is not judged again. A `seed` that is not a list of txids
//! (64 hex digits) is refused, nothing written.
//!
//! One box per function class (shruggr/skein#128, 0.6.2; 0.7.5): either
//! message is taken only in the box the manifest names `register` (resolved
//! `<app>/register`; 0.7.7, was `overlay`), from the row `{address: "register", sender: "$owner",
//! program: "overlay"}`; in any other box (the app's own `<app>`,
//! `<app>/submit`, …) it is refused with `bad-args`, writing and emitting
//! nothing. `submit` is the other class: taken in any box a row routes to
//! the engine — the stock manifest's `<app>/submit`, where POST /submit
//! admits its submission event too (0.7.6). The app is the step's, never the box's; the answer goes back
//! in the box the message came in.
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

/// The set's record, with no switch set (`recordWith`).
pub fn recordOf(a: Allocator, list: []const Entry) !Value {
    return recordWith(a, list, .{});
}

/// The set's record with the owner's switches (0.9.2): `market: {window} | {off: true}` and
/// `validator: {every} | {off: true}` beside `topics`, each only once switched.
pub fn recordWith(a: Allocator, list: []const Entry, sw: Switches) !Value {
    const ts = try a.alloc(Value, list.len);
    for (list, ts) |e, *v| v.* = .{ .map = try a.dupe(cbor.Entry, &.{
        .{ .key = "topic", .value = .{ .text = e.topic } },
        .{ .key = "program", .value = .{ .text = e.program } },
    }) };
    var es: std.ArrayList(cbor.Entry) = .empty;
    try es.appendSlice(a, &.{
        .{ .key = "kind", .value = .{ .text = record_kind } },
        .{ .key = "topics", .value = .{ .array = ts } },
    });
    inline for (.{ Role.market, Role.validator }) |r| {
        if (try switchValue(a, sw.get(r), r)) |v| try es.append(a, .{ .key = @tagName(r), .value = v });
    }
    return .{ .map = es.items };
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
    done: struct { list: ?[]const Entry, events: []const Value, answer: Value, seed: ?[]const [32]u8 = null },
};

/// A register's `seed` (0.7.8): null when absent; a list of txids (hex), each once, in order. Not
/// that shape: error.BadSeed.
pub fn seedOf(a: Allocator, args: Value) !?[]const [32]u8 {
    const v = args.get("seed") orelse return null;
    if (v == .null) return null;
    if (v != .array) return error.BadSeed;
    var out: std.ArrayList([32]u8) = .empty;
    outer: for (v.array) |x| {
        if (x != .text or x.text.len != 64) return error.BadSeed;
        const t = c.header.fromHex(x.text) catch return error.BadSeed;
        for (out.items) |y| if (eql(u8, &y, &t)) continue :outer;
        try out.append(a, t);
    }
    return out.items;
}

fn answerOf(a: Allocator, topic: []const u8, active: bool) !Value {
    return .{ .map = try a.dupe(cbor.Entry, &.{
        .{ .key = "topic", .value = .{ .text = topic } },
        .{ .key = "active", .value = .{ .boolean = active } },
    }) };
}

fn refused(a: Allocator, comptime fmt: []const u8, args: anytype) !Change {
    return .{ .refused = try std.fmt.allocPrint(a, fmt, args) };
}

/// `register {topic, program, seed?}`: `program` a role in `programs` (the app's roles, or the
/// genesis's); `self` the engine's own role. An unknown role is refused; so is a topic registered
/// already with another program (deregister it first), and a `seed` that is not a list of txids.
/// The seeds (0.7.8) are the engine's to judge once the set is written (`done.seed`).
pub fn register(a: Allocator, list: []const Entry, args: Value, programs: Value, self: []const u8) !Change {
    const topic = args.getText("topic") orelse return refused(a, "register: want {{topic, program, seed?}}", .{});
    const program = args.getText("program") orelse return refused(a, "register: want {{topic, program, seed?}}", .{});
    if (topic.len == 0) return refused(a, "register: the topic is empty", .{});
    if (programs.getCid(program) == null) return refused(a, "register: program {s} is not a role in programs", .{program});
    const seed = seedOf(a, args) catch return refused(a, "register: seed is a list of txids (64 hex digits)", .{});
    if (find(list, topic)) |e| {
        if (!eql(u8, e.program, program)) return refused(a, "register: {s} is registered with program {s}: deregister it first", .{ topic, e.program });
        return .{ .done = .{ .list = null, .events = &.{}, .answer = try answerOf(a, topic, true), .seed = seed } };
    }
    const out = try a.alloc(Entry, list.len + 1);
    @memcpy(out[0..list.len], list);
    out[list.len] = .{ .topic = topic, .program = program };
    std.mem.sort(Entry, out, {}, lessThan);
    return .{ .done = .{ .list = out, .events = try a.dupe(Value, &try events(a, true, topic, self)), .answer = try answerOf(a, topic, true), .seed = seed } };
}

/// What a mailbox message asks of the engine, by its body's `fn` alone; where it may be taken is
/// `mayRegister`'s (one box per function class, shruggr/skein#128, 0.7.5).
pub const Asked = enum { register, deregister, market, validator, other };

pub fn asked(body: Value) Asked {
    const f = body.getText("fn") orelse return .other;
    if (eql(u8, f, "register")) return .register;
    if (eql(u8, f, "deregister")) return .deregister;
    if (eql(u8, f, "market")) return .market;
    if (eql(u8, f, "validator")) return .validator;
    return .other;
}

/// The box, after the app's name, the manifest names for registrations: `register`, resolved
/// `<app>/register` (0.7.7; was `overlay`, which for an app named `overlay` is the app's own box).
pub const register_box = "register";

/// Whether a registration may be taken here (one box per function class, shruggr/skein#128,
/// 0.7.5, 0.7.7): only in the box `<app>/register`, from whoever the manifest's row for it admits (the
/// stock manifest: `$owner`). In any other box — the app's own `<app>`, `<app>/submit`, … — it is
/// refused (`notHere`), whoever sent it.
pub fn mayRegister(args: Value, app: []const u8) bool {
    const box = args.getText("box") orelse return false;
    return box.len == app.len + 1 + register_box.len and std.mem.startsWith(u8, box, app) and
        box[app.len] == '/' and eql(u8, box[app.len + 1 ..], register_box);
}

/// Why a registration in another box is refused (the answer's `bad-args` message).
pub fn notHere(a: Allocator, func: []const u8, args: Value, app: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "{s}: not taken in box {s}; send it in {s}/{s}", .{ func, answerBox(args, app), app, register_box });
}

/// The box a registration's answer goes back in: the one the message came in (the step's
/// `args.box`), else the app's own.
pub fn answerBox(args: Value, app: []const u8) []const u8 {
    return args.getText("box") orelse app;
}

/// The engine's roles (shruggr/skein#120, David 2026-10-06 evening: "a skein runs as a market and/or
/// a validator by two settings in the engine's configuration"): `config.overlay.market: {window}` and
/// `config.overlay.validator: {every}`, each in ms, each optional (config.zig `rolesOf`).
pub const Roles = struct { market: ?u64 = null, validator: ?u64 = null };

/// The topic the roles' events name for an overlay topic: `<topic>-live`.
pub const live_suffix = "-live";

/// The roles' events for one change, after the subscribes: on register, `liveness {topic:
/// <topic>-live, window}` when a market and `beacon {topic: <topic>-live, every, body: <empty>}` when
/// a validator (the beat needs no body: the frame carries the sender's identity key, the gossip
/// message the peer id); on deregister, `unliveness` / `unbeacon` likewise.
pub fn roleEvents(a: Allocator, subscribe: bool, topic: []const u8, roles: Roles) ![]const Value {
    const t: Value = .{ .text = try std.mem.concat(a, u8, &.{ topic, live_suffix }) };
    var out: std.ArrayList(Value) = .empty;
    if (roles.market) |window| try out.append(a, .{ .map = if (subscribe) try a.dupe(cbor.Entry, &.{
        .{ .key = "event", .value = .{ .text = "liveness" } },
        .{ .key = "topic", .value = t },
        .{ .key = "window", .value = .{ .uint = window } },
    }) else try a.dupe(cbor.Entry, &.{
        .{ .key = "event", .value = .{ .text = "unliveness" } },
        .{ .key = "topic", .value = t },
    }) });
    if (roles.validator) |every| try out.append(a, .{ .map = if (subscribe) try a.dupe(cbor.Entry, &.{
        .{ .key = "event", .value = .{ .text = "beacon" } },
        .{ .key = "topic", .value = t },
        .{ .key = "every", .value = .{ .uint = every } },
        .{ .key = "body", .value = .{ .bytes = "" } },
    }) else try a.dupe(cbor.Entry, &.{
        .{ .key = "event", .value = .{ .text = "unbeacon" } },
        .{ .key = "topic", .value = t },
    }) });
    return out.items;
}

/// A register's or deregister's change with the roles' events added (`roleEvents`), only when the set
/// changes: an idempotent one emits nothing, a refusal stays one.
pub fn withRoles(a: Allocator, change: Change, subscribe: bool, roles: Roles) !Change {
    if (change != .done or change.done.list == null) return change;
    var d = change.done;
    const extra = try roleEvents(a, subscribe, d.answer.getText("topic").?, roles);
    if (extra.len == 0) return change;
    d.events = try std.mem.concat(a, Value, &.{ d.events, extra });
    return .{ .done = d };
}

/// `deregister {topic}`.
pub fn deregister(a: Allocator, list: []const Entry, args: Value) !Change {
    const topic = args.getText("topic") orelse return refused(a, "deregister: want {{topic}}", .{});
    if (find(list, topic) == null) return .{ .done = .{ .list = null, .events = &.{}, .answer = try answerOf(a, topic, false) } };
    var out: std.ArrayList(Entry) = .empty;
    for (list) |e| if (!eql(u8, e.topic, topic)) try out.append(a, e);
    return .{ .done = .{ .list = out.items, .events = try a.dupe(Value, &try events(a, false, topic, "")), .answer = try answerOf(a, topic, false) } };
}

/// The owner's switches (David, 2026-10-07: "this shouldn't have been a config in the manifest. This
/// should be a setting that the user is configuring"; 0.9.2). Each role is switched by an owner's
/// message in `<app>/register` — `market {window}` / `market {off: true}`, `validator {every}` /
/// `validator {off: true}` — and kept in the set's record `<app>/topics` beside `topics`. A switch,
/// once sent, has precedence over `config.overlay.market` / `.validator` (the manifest's: the initial
/// value); `unset` is the manifest's.
pub const Role = enum { market, validator };

/// One role's switch: never sent (the manifest decides), off, or on with its ms.
pub const Switch = union(enum) { unset, off, on: u64 };

pub const Switches = struct {
    market: Switch = .unset,
    validator: Switch = .unset,

    pub fn get(self: Switches, r: Role) Switch {
        return switch (r) {
            .market => self.market,
            .validator => self.validator,
        };
    }

    pub fn set(self: *Switches, r: Role, v: Switch) void {
        switch (r) {
            .market => self.market = v,
            .validator => self.validator = v,
        }
    }
};

/// The field of a role's switch and of its `config.overlay` value: market `window`, validator `every`.
pub fn fieldOf(r: Role) []const u8 {
    return switch (r) {
        .market => "window",
        .validator => "every",
    };
}

/// The shortest and longest window or beat the kernel takes (ms; skein docs/MESSAGES.md "Beacons", "Liveness").
pub const role_min_ms: u64 = 1000;
pub const role_max_ms: u64 = 86_400_000;

fn switchValue(a: Allocator, sw: Switch, r: Role) !?Value {
    return switch (sw) {
        .unset => null,
        .off => .{ .map = try a.dupe(cbor.Entry, &.{.{ .key = "off", .value = .{ .boolean = true } }}) },
        .on => |ms| .{ .map = try a.dupe(cbor.Entry, &.{.{ .key = fieldOf(r), .value = .{ .uint = ms } }}) },
    };
}

/// The switches a set record holds (null: no set yet, none switched).
pub fn switchesOf(rec: ?Value) !Switches {
    const r = rec orelse return .{};
    var out: Switches = .{};
    inline for (.{ Role.market, Role.validator }) |role| {
        if (r.get(@tagName(role))) |v| out.set(role, parseSwitch(v, role) catch return error.BadTopicSet);
    }
    return out;
}

/// `{off: true}` → off; `{window: <ms>}` (market) / `{every: <ms>}` (validator), 1 000 ms .. a day → on.
/// Anything else: error.BadSwitch.
pub fn parseSwitch(v: Value, r: Role) error{BadSwitch}!Switch {
    if (v != .map) return error.BadSwitch;
    if (v.get("off")) |off| {
        if (off != .boolean or !off.boolean or v.map.len != 1) return error.BadSwitch;
        return .off;
    }
    const ms = v.getUint(fieldOf(r)) orelse return error.BadSwitch;
    if (v.map.len != 1 or ms < role_min_ms or ms > role_max_ms) return error.BadSwitch;
    return .{ .on = ms };
}

/// The roles in effect: a switch sent has precedence; `unset` is the configuration's.
pub fn effective(sw: Switches, cfg: Roles) Roles {
    const pick = struct {
        fn f(s: Switch, c_: ?u64) ?u64 {
            return switch (s) {
                .unset => c_,
                .off => null,
                .on => |ms| ms,
            };
        }
    }.f;
    return .{ .market = pick(sw.market, cfg.market), .validator = pick(sw.validator, cfg.validator) };
}

/// The answer to a switch (and the roles as the owner reads them): `{market?: {window}, validator?:
/// {every}}`, the roles in effect, each present only when on.
pub fn rolesAnswer(a: Allocator, roles: Roles) !Value {
    var es: std.ArrayList(cbor.Entry) = .empty;
    if (roles.market) |w| try es.append(a, .{ .key = "market", .value = .{ .map = try a.dupe(cbor.Entry, &.{.{ .key = "window", .value = .{ .uint = w } }}) } });
    if (roles.validator) |e| try es.append(a, .{ .key = "validator", .value = .{ .map = try a.dupe(cbor.Entry, &.{.{ .key = "every", .value = .{ .uint = e } }}) } });
    return .{ .map = es.items };
}

/// What a switch does: the switches to write (null: unchanged), the events to emit, the answer
/// (`rolesAnswer`, after it). Or why it is refused (nothing written, nothing emitted).
pub const SwitchChange = union(enum) {
    refused: []const u8,
    done: struct { switches: ?Switches, events: []const Value, answer: Value },
};

/// `market {window} | {off: true}` / `validator {every} | {off: true}` (0.9.2): the role `r` switched
/// for the registered set `list`. Turned on (or its ms changed), `liveness` / `beacon` for every
/// topic registered (the kernel keys them by (app, topic): a new ms replaces the old); turned off,
/// `unliveness` / `unbeacon` for them. Idempotent: the same switch again writes and emits nothing; a
/// switch that leaves the role in effect as it was (the manifest's value made explicit) is written
/// (it has precedence from then on) and emits nothing.
pub fn switchRole(a: Allocator, list: []const Entry, sw: Switches, cfg: Roles, r: Role, args: Value) !SwitchChange {
    const want = parseSwitch(args, r) catch return .{ .refused = try std.fmt.allocPrint(a, "{s}: want {{{s}: <ms>}} (1000 ms to a day) or {{off: true}}", .{ @tagName(r), fieldOf(r) }) };
    const before = effective(sw, cfg);
    var next = sw;
    next.set(r, want);
    const after = effective(next, cfg);
    const same = std.meta.eql(sw.get(r), want);
    var evs: std.ArrayList(Value) = .empty;
    const was = switch (r) {
        .market => before.market,
        .validator => before.validator,
    };
    const now = switch (r) {
        .market => after.market,
        .validator => after.validator,
    };
    if (!std.meta.eql(was, now)) {
        const only: Roles = switch (r) {
            .market => .{ .market = now orelse was },
            .validator => .{ .validator = now orelse was },
        };
        for (list) |e| try evs.appendSlice(a, try roleEvents(a, now != null, e.topic, only));
    }
    return .{ .done = .{ .switches = if (same) null else next, .events = evs.items, .answer = try rolesAnswer(a, after) } };
}
