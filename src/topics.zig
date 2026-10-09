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
//! (0.9.2 to 0.11.0 kept the owner's `market` / `validator` switches beside
//! `topics`; 0.12.0 neither writes nor reads them.)
//!
//! `program` is the role in `programs` (the app's) whose topic manager
//! judges the topic: a dynamic overlay's manifest lists no topics, so the
//! caller names it. config.zig reads the set at every step and call and
//! serves each topic as if `config.overlay.topics` named it (a declared
//! topic keeps its own program).
//!
//! `register {topic, program}` adds it and emits the skein #119 events
//! `subscribe {topic, program, fn}` for `<topic>` (fn `submit`: one mesh,
//! two kinds of message, `submit` and `admit`, David 2026-10-09; gossip.zig)
//! and `<topic>-proof` (`peerProof`), dag-cbor bodies, no filter (the door
//! does not look inside a dag-cbor body: a `submit` message's BEEF is the
//! engine's to decode), where
//! `program` is the engine's own role (the handler the kernel routes the
//! topic's messages to); `deregister {topic}` removes it and emits
//! `unsubscribe {topic}` for the two. Until 0.12.0 a third, `<topic>-admit`
//! (`peerAdmit`), carried the verdicts. Both are idempotent: a topic already
//! registered with the same program, or not registered, changes nothing and
//! emits nothing. The answer is `{topic, active}` (whether the topic is in
//! the registered set now).
//!
//! Market and validator, always (David, 2026-10-09: "every skein is
//! marketplace AND validator from install, always"; 0.12.0 removed the
//! owner's `market` / `validator` switch of 0.9.2 and its stored state): a
//! register that changes the set also emits `liveness {topic: <topic>-live,
//! window}` and `beacon {topic: <topic>-live, every, body}`; a deregister that
//! changes it emits `unliveness` and `unbeacon` (`withRoles`). `window` and
//! `every` are `config.overlay.market: {window}` and `config.overlay.validator:
//! {every}`, else 40 000 and 30 000 ms (config.zig `rolesOf`): defaults, never
//! off. Nothing at a start or re-read: the intents stand in the log.
//!
//! The beat (0.12.0, David 2026-10-09: "beats ARE libp2p service discovery;
//! they replace SHIP/SLAP on the libp2p network" — not SHIP/SLAP, and no
//! SHIP/SLAP ad is published p2p). A topic's beat body is dag-cbor
//!
//!   {view: {count: uint, digest: bytes(32)}, terms?}
//!
//! the topic's VIEW DIGEST (state.zig `View`: its admitted-and-unspent
//! outputs, counted and summed), kept in the topic's state record and put in
//! the body when the beacon is declared (`beatBody`). The host publishes the
//! declared body and reads no state at beat time, so the engine re-declares
//! the beacon when the view changes (on admit and spend): an app's new
//! `beacon {topic, every, body}` replaces its previous one (skein
//! src/host/p2p.ts), and a receiver's liveness tool keeps the latest beat per
//! sender — one logged event per change (`beatEvents`). `terms` (0.12.1) is
//! `config.overlay.terms` as configured, opaque to the engine; absent, no
//! field. (`origin` is the host's.)
//!
//! Each registered lookup service beats too, on `<service>-live` (lookups.zig;
//! `registerLookup` declares its beacon, `deregisterLookup` ends it, every
//! `every` ms as the topics; and, 0.12.1, keeps liveness on it with the
//! market's window, as for a topic: a skein keeps the other peers' lookup
//! beats as it keeps topic beats), its body the lookup program's own:
//! fn "beat" answers it at the declaration, and a hook's answer may carry a
//! new one (`{beats: {<service>: bytes}}`, lookup.zig).
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
const st_mod = @import("state.zig");

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
    var es: std.ArrayList(cbor.Entry) = .empty;
    try es.appendSlice(a, &.{
        .{ .key = "kind", .value = .{ .text = record_kind } },
        .{ .key = "topics", .value = .{ .array = ts } },
    });
    return .{ .map = es.items };
}

fn find(list: []const Entry, topic: []const u8) ?Entry {
    for (list) |e| if (eql(u8, e.topic, topic)) return e;
    return null;
}

fn lessThan(_: void, x: Entry, y: Entry) bool {
    return std.mem.order(u8, x.topic, y.topic) == .lt;
}

/// The GossipSub topics an overlay topic is subscribed on, and the engine's function for each
/// (routes.zig; 0.12.0, David 2026-10-09): `<topic>` one mesh for both kinds, `submit` and `admit`
/// (the function reads the kind), and `<topic>-proof` its own (people waiting on a proof do not track
/// admittance). Dag-cbor bodies, no door filter. (`<topic>-live`, the liveness topic, is the runtime's
/// beacon and liveness tool: `roleEvents`.)
pub const gossip_topics = [_]struct { suffix: []const u8, func: []const u8, filter: ?[]const u8 = null }{
    .{ .suffix = "", .func = "submit" },
    .{ .suffix = "-proof", .func = "peerProof" },
};

/// The events of one change: `subscribe {topic, program: <self>, fn, filter?}` for each of the
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
/// `mayRegister`'s (one box per function class, shruggr/skein#128, 0.7.5). `registerLookup` /
/// `deregisterLookup` (0.11.0, lookups.zig) are taken where `register` is.
pub const Asked = enum { register, deregister, registerLookup, deregisterLookup, other };

pub fn asked(body: Value) Asked {
    const f = body.getText("fn") orelse return .other;
    if (eql(u8, f, "register")) return .register;
    if (eql(u8, f, "deregister")) return .deregister;
    if (eql(u8, f, "registerLookup")) return .registerLookup;
    if (eql(u8, f, "deregisterLookup")) return .deregisterLookup;
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

/// The engine's roles (shruggr/skein#120; 0.12.0, David 2026-10-09: "every skein is marketplace AND
/// validator from install, always"): the market's liveness window and the validator's beat, in ms —
/// `config.overlay.market: {window}` and `config.overlay.validator: {every}`, else the defaults
/// (config.zig `rolesOf`).
pub const Roles = struct {
    market: u64 = default_window_ms,
    validator: u64 = default_every_ms,
    /// `config.overlay.terms` (0.12.1): opaque, copied into each topic's beat body as `terms`; null: none.
    terms: ?Value = null,
};

/// The topic the roles' events name for an overlay topic: `<topic>-live`.
pub const live_suffix = "-live";

/// The roles' events for one change, after the subscribes: on register, `liveness {topic:
/// <topic>-live, window}` (the market) and `beacon {topic: <topic>-live, every, body}` (the
/// validator; `body` the topic's beat body, `beatBody`: the frame carries the sender's identity key,
/// the gossip message the peer id); on deregister, `unliveness` and `unbeacon`.
pub fn roleEvents(a: Allocator, subscribe: bool, topic: []const u8, roles: Roles, body: []const u8) ![]const Value {
    const t: Value = .{ .text = try std.mem.concat(a, u8, &.{ topic, live_suffix }) };
    var out: std.ArrayList(Value) = .empty;
    try out.append(a, .{ .map = if (subscribe) try a.dupe(cbor.Entry, &.{
        .{ .key = "event", .value = .{ .text = "liveness" } },
        .{ .key = "topic", .value = t },
        .{ .key = "window", .value = .{ .uint = roles.market } },
    }) else try a.dupe(cbor.Entry, &.{
        .{ .key = "event", .value = .{ .text = "unliveness" } },
        .{ .key = "topic", .value = t },
    }) });
    try out.append(a, if (subscribe) try beaconEvent(a, topic, roles.validator, body) else try unbeaconEvent(a, topic));
    return out.items;
}

/// `beacon {topic: <name>-live, every, body}`: declared, or re-declared with a new body (an app's
/// new beacon for the same topic replaces its previous one).
pub fn beaconEvent(a: Allocator, name: []const u8, every: u64, body: []const u8) !Value {
    return .{ .map = try a.dupe(cbor.Entry, &.{
        .{ .key = "event", .value = .{ .text = "beacon" } },
        .{ .key = "topic", .value = .{ .text = try std.mem.concat(a, u8, &.{ name, live_suffix }) } },
        .{ .key = "every", .value = .{ .uint = every } },
        .{ .key = "body", .value = .{ .bytes = body } },
    }) };
}

/// `unbeacon {topic: <name>-live}`.
pub fn unbeaconEvent(a: Allocator, name: []const u8) !Value {
    return .{ .map = try a.dupe(cbor.Entry, &.{
        .{ .key = "event", .value = .{ .text = "unbeacon" } },
        .{ .key = "topic", .value = .{ .text = try std.mem.concat(a, u8, &.{ name, live_suffix }) } },
    }) };
}

/// A topic's beat body (0.12.0): dag-cbor `{view: {count, digest}, terms?}`, the topic's view digest
/// (state.zig `View`) and (0.12.1) `config.overlay.terms` as configured, when it is.
pub fn beatBody(a: Allocator, v: st_mod.View, terms: ?Value) ![]const u8 {
    var es: std.ArrayList(cbor.Entry) = .empty;
    try es.append(a, .{ .key = "view", .value = .{ .map = try a.dupe(cbor.Entry, &.{
        .{ .key = "count", .value = .{ .uint = v.count } },
        .{ .key = "digest", .value = .{ .bytes = try a.dupe(u8, &v.digest) } },
    }) } });
    if (terms) |t| try es.append(a, .{ .key = "terms", .value = t });
    return cbor.encode(a, .{ .map = es.items });
}

/// A register's or deregister's change with the roles' events added (`roleEvents`), only when the set
/// changes: an idempotent one emits nothing, a refusal stays one. `body`: the topic's beat body.
pub fn withRoles(a: Allocator, change: Change, subscribe: bool, roles: Roles, body: []const u8) !Change {
    if (change != .done or change.done.list == null) return change;
    var d = change.done;
    const extra = try roleEvents(a, subscribe, d.answer.getText("topic").?, roles, body);
    if (extra.len == 0) return change;
    d.events = try std.mem.concat(a, Value, &.{ d.events, extra });
    return .{ .done = d };
}

/// The beacons a step re-declares (0.12.0), each beating every `roles.validator` ms: one per registered topic
/// whose view the step changed (`changes`, state.zig `viewChanges`: the body over its view now), then
/// one per registered lookup service a hook gave a new body (`lookup_beats`, the last one per
/// service). Nothing for a topic or service not registered (`topics`, `services`).
pub fn beatEvents(a: Allocator, roles: Roles, topics: []const Entry, services: []const []const u8, changes: []const st_mod.ViewChange, lookup_beats: []const st_mod.LookupBeat) ![]const Value {
    const ms = roles.validator;
    var out: std.ArrayList(Value) = .empty;
    for (changes) |ch| {
        if (find(topics, ch.topic) == null) continue;
        try out.append(a, try beaconEvent(a, ch.topic, ms, try beatBody(a, ch.now, roles.terms)));
    }
    for (lookup_beats, 0..) |lb, i| {
        const registered = for (services) |x| {
            if (eql(u8, x, lb.service)) break true;
        } else false;
        if (!registered) continue;
        const later = for (lookup_beats[i + 1 ..]) |y| {
            if (eql(u8, y.service, lb.service)) break true;
        } else false;
        if (later) continue;
        try out.append(a, try beaconEvent(a, lb.service, ms, lb.body));
    }
    return out.items;
}

/// `deregister {topic}`.
pub fn deregister(a: Allocator, list: []const Entry, args: Value) !Change {
    const topic = args.getText("topic") orelse return refused(a, "deregister: want {{topic}}", .{});
    if (find(list, topic) == null) return .{ .done = .{ .list = null, .events = &.{}, .answer = try answerOf(a, topic, false) } };
    var out: std.ArrayList(Entry) = .empty;
    for (list) |e| if (!eql(u8, e.topic, topic)) try out.append(a, e);
    return .{ .done = .{ .list = out.items, .events = try a.dupe(Value, &try events(a, false, topic, "")), .answer = try answerOf(a, topic, false) } };
}

/// The shortest and longest window or beat the kernel takes (ms; skein docs/MESSAGES.md "Beacons", "Liveness").
pub const role_min_ms: u64 = 1000;
pub const role_max_ms: u64 = 86_400_000;

/// The window and the beat when the configuration names none (0.12.0): a liveness window of 40 s,
/// a beat every 30 s (the values the owner's switch on the Mandala tokens page asked for, until
/// 0.12.0 removed the switch).
pub const default_window_ms: u64 = 40_000;
pub const default_every_ms: u64 = 30_000;
