//! The standard overlay gossip (#74): per overlay topic `<topic>` an overlay
//! runs, two GossipSub topics.
//!
//!   <topic>        the announcements (0.20.0, David 2026-10-30: "announce, then fetch"):
//!                    {kind: "admit", txid (hex), topics: {<topic>: {outputsToAdmit: [vout],
//!                        coinsToRetain: [input index]}}}   this overlay's verdict — the STEAK and
//!                        the txid only, no BEEF — published once by the step that admits a
//!                        transaction, whatever path it came by. It is the HOST's to read: a node
//!                        that hears one fetches the BEEF from the announcing peer (the sync
//!                        protocol's `tx` request, skein src/host/sync.ts) unless it holds the
//!                        transaction, and hands it in through the receive row; once it admits
//!                        it, it publishes its own `admit`. The host does not deliver admits to
//!                        the instance: one that reaches the engine's `<topic>` route anyway is
//!                        ignored, nothing admitted (routes.zig).
//!                  Before 0.20.0 the mesh carried the BEEF too ({kind: "submit", beef}) and a
//!                  received admit was recorded under the head `<app>/gossip`; both are gone.
//!   (<topic>-proof, 0.20.0 to 0.24.0, the proofs by gossip: gone in 0.25.0, David 2026-11-09 —
//!   proofs reach an instance by the host's Arcade feed and by its pull of a peer's mined history,
//!   skein src/host/sync.ts, as `proof` events in box `chain`.)
//!   <topic>-live   the liveness beats (topics.zig `roleEvents`): the runtime's
//!                  beacon and liveness tool, unlogged; nothing here.
//!
//! Statuses never propagate. Publishing is a message to the libp2p provider
//! (`publish {topic, body}`, docs/MESSAGES.md "The providers"), emitted from
//! the step and not awaited: its answer is recorded and runs nothing. With no
//! libp2p provider in the address book nothing is published.
//!
//! Config: `config.overlay.gossip` (genesis-wired: `defaults.overlayGossip`,
//! a JSON object in a string), `{"<topic>": false}` turns a topic's
//! publishing off; a topic not named publishes (the default is on).
//! Receiving is the subscription `<topic>` (fn `submit`: the host's, see
//! above) a register emits (topics.zig), or an installed app's routes derived
//! from config.overlay.
const std = @import("std");
const c = @import("chain");
const st_mod = @import("state.zig");
const calls = @import("calls.zig");

const cbor = c.cbor;
const Value = cbor.Value;
const Allocator = std.mem.Allocator;

/// Whether this overlay publishes for `topic` (defaults.overlayGossip; on unless `false`).
pub fn enabled(a: Allocator, in: Value, topic: []const u8) !bool {
    const m = try calls.configObject(a, in, "overlayGossip");
    const v = m.get(topic) orelse return true;
    return switch (v) {
        .bool => |b| b,
        else => error.BadConfig,
    };
}

/// Where a publish goes: the libp2p provider (vm.zig's emits a message to it; a test's records it).
pub const Out = struct {
    ctx: *anyopaque,
    /// Publish `body` (dag-cbor bytes: an `admit` message on <topic>) on `topic`.
    publishFn: *const fn (ctx: *anyopaque, a: Allocator, topic: []const u8, body: []const u8) anyerror!void,

    pub fn publish(self: Out, a: Allocator, topic: []const u8, body: []const u8) !void {
        return self.publishFn(self.ctx, a, topic, body);
    }
};

fn uints(a: Allocator, xs: []const u32) ![]Value {
    const out = try a.alloc(Value, xs.len);
    for (xs, out) |x, *o| o.* = .{ .uint = x };
    return out;
}

fn uintList(a: Allocator, v: ?Value) ![]u32 {
    const items = if (v) |x| (if (x == .array) x.array else return error.BadMessage) else return error.BadMessage;
    const out = try a.alloc(u32, items.len);
    for (items, out) |it, *o| o.* = if (it == .uint and it.uint <= std.math.maxInt(u32)) @intCast(it.uint) else return error.BadMessage;
    return out;
}

// ---------------------------------------------------------------- the messages

/// The kind of the message on `<topic>`.
pub const admit_kind = "admit";

/// An `admit` message on `<topic>`: {kind: "admit", txid, topics: {<topic>: {outputsToAdmit,
/// coinsToRetain}}} (dag-cbor).
pub fn admitBody(a: Allocator, txid: [32]u8, topic: []const u8, outputs_to_admit: []const u32, coins_to_retain: []const u32) ![]const u8 {
    return cbor.encode(a, .{ .map = try a.dupe(cbor.Entry, &.{
        .{ .key = "kind", .value = .{ .text = admit_kind } },
        .{ .key = "txid", .value = .{ .text = try a.dupe(u8, &c.header.toHex(txid)) } },
        .{ .key = "topics", .value = .{ .map = try a.dupe(cbor.Entry, &.{.{ .key = topic, .value = .{ .map = try a.dupe(cbor.Entry, &.{
            .{ .key = "outputsToAdmit", .value = .{ .array = try uints(a, outputs_to_admit) } },
            .{ .key = "coinsToRetain", .value = .{ .array = try uints(a, coins_to_retain) } },
        }) } }}) } },
    }) });
}

pub const Admit = struct { txid: [32]u8, outputs_to_admit: []const u32, coins_to_retain: []const u32 };

/// An `admit` message's body read for `topic`: its txid and that topic's STEAK entry.
pub fn parseAdmit(a: Allocator, body: []const u8, topic: []const u8) !Admit {
    const v = cbor.decode(a, body) catch return error.BadMessage;
    if (v != .map) return error.BadMessage;
    const txid = c.header.fromHex(v.getText("txid") orelse return error.BadMessage) catch return error.BadMessage;
    const ts = v.get("topics") orelse return error.BadMessage;
    if (ts != .map) return error.BadMessage;
    const e = ts.get(topic) orelse return error.NotThisTopic;
    if (e != .map) return error.BadMessage;
    return .{ .txid = txid, .outputs_to_admit = try uintList(a, e.get("outputsToAdmit")), .coins_to_retain = try uintList(a, e.get("coinsToRetain")) };
}

// ---------------------------------------------------------------- what a step publishes

/// What one admission publishes, per topic that admitted it with gossip on: its verdict, an
/// `admit` message on `<topic>` (0.20.0: never the BEEF; a peer fetches it). → how many messages.
pub fn admitted(a: Allocator, out: Out, st: *st_mod.State, in: Value, txid: [32]u8, topics: []const []const u8, applied: []const st_mod.Applied) !usize {
    var n: usize = 0;
    for (topics, applied) |t, ap| {
        if (ap.records.len == 0 or !(try st.isApplied(t, txid))) continue;
        if (!try enabled(a, in, t)) continue;
        try out.publish(a, t, try admitBody(a, txid, t, ap.outputs_to_admit, ap.coins_to_retain));
        n += 1;
    }
    return n;
}
