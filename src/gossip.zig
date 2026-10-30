//! The standard overlay gossip (#74): per overlay topic `<topic>` an overlay
//! runs, three GossipSub topics.
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
//!   <topic>-proof  the proof of an admitted transaction, published every time the chain app
//!                  answers that it is proven (0.20.0: a reorg's new proof too):
//!                    {txid (hex), blockHash (hex), blockHeight, bump: bytes (BRC-74, this txid's path alone)}
//!                  Received (`peerProof`): checked against this instance's
//!                  own chain state (the chain app's, read only) and admitted
//!                  as the `proof` event in box `chain` — the chain app's
//!                  event row, the same as the host's broadcaster admits (#65).
//!                  A proof that came this way is not published again (GossipSub forwarded it).
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
//! Receiving is the subscriptions `<topic>` (fn `submit`: the host's, see
//! above) and `<topic>-proof` (fn `peerProof`) a register emits (topics.zig), or
//! an installed app's routes derived from config.overlay.
const std = @import("std");
const c = @import("chain");
const st_mod = @import("state.zig");
const calls = @import("calls.zig");

const cbor = c.cbor;
const Value = cbor.Value;
const Store = c.store.Store;
const Chain = st_mod.Chain;
const Allocator = std.mem.Allocator;
const eql = std.mem.eql;

pub const proof_suffix = "-proof";

/// Whether this overlay publishes for `topic` (defaults.overlayGossip; on unless `false`).
pub fn enabled(a: Allocator, in: Value, topic: []const u8) !bool {
    const m = try calls.configObject(a, in, "overlayGossip");
    const v = m.get(topic) orelse return true;
    return switch (v) {
        .bool => |b| b,
        else => error.BadConfig,
    };
}

/// The overlay topic a gossip topic carries `suffix` for, or null.
pub fn baseOf(gossip_topic: []const u8, suffix: []const u8) ?[]const u8 {
    if (gossip_topic.len <= suffix.len or !std.mem.endsWith(u8, gossip_topic, suffix)) return null;
    return gossip_topic[0 .. gossip_topic.len - suffix.len];
}

/// Where a publish goes: the libp2p provider (vm.zig's emits a message to it; a test's records it).
pub const Out = struct {
    ctx: *anyopaque,
    /// Publish `body` (dag-cbor bytes: an `admit` message on <topic>, a proof on -proof) on `topic`.
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

/// `<topic>-proof`: {txid, blockHash, blockHeight, bump} (dag-cbor).
pub fn proofBody(a: Allocator, txid: [32]u8, block_hash: [32]u8, height: u32, bump: []const u8) ![]const u8 {
    return cbor.encode(a, .{ .map = try a.dupe(cbor.Entry, &.{
        .{ .key = "txid", .value = .{ .text = try a.dupe(u8, &c.header.toHex(txid)) } },
        .{ .key = "blockHash", .value = .{ .text = try a.dupe(u8, &c.header.toHex(block_hash)) } },
        .{ .key = "blockHeight", .value = .{ .uint = height } },
        .{ .key = "bump", .value = .{ .bytes = bump } },
    }) });
}

pub const Proof = struct { txid: [32]u8, block_hash: [32]u8, height: u32, bump: []const u8 };

pub fn parseProof(a: Allocator, body: []const u8) !Proof {
    const v = cbor.decode(a, body) catch return error.BadMessage;
    if (v != .map) return error.BadMessage;
    const h = v.getUint("blockHeight") orelse return error.BadMessage;
    if (h > std.math.maxInt(u32)) return error.BadMessage;
    return .{
        .txid = c.header.fromHex(v.getText("txid") orelse return error.BadMessage) catch return error.BadMessage,
        .block_hash = c.header.fromHex(v.getText("blockHash") orelse return error.BadMessage) catch return error.BadMessage,
        .height = @intCast(h),
        .bump = v.getBytes("bump") orelse return error.BadMessage,
    };
}

/// A `-proof` message checked against this instance's own chain state (the
/// chain app's, read only: the route's call): the transaction is held there,
/// the BUMP is at the height it names and flags the txid, its root is our
/// header's merkle root at that height, and that header's hash is the
/// message's `blockHash`. → the `proof` event to admit in box `chain` (the
/// host's broadcaster's shape, #65, plus `via`), or why it is ignored. A
/// missing header is not the publisher's fault (ours may be behind): every
/// refusal is `ignore`.
pub fn checkProof(a: Allocator, ch: *Chain, p: Proof, via: []const u8) !union(enum) { event: Value, ignore: []const u8 } {
    if (!(try ch.holds(p.txid))) return .{ .ignore = "the transaction is not held here" };
    if (try ch.proofBlock(p.txid)) |b| if (eql(u8, &b, &p.block_hash) and (try ch.status(p.txid)) == .proven) return .{ .ignore = "already proven in that block" };
    const path = c.bsvz.spv.MerklePath.parse(a, p.bump) catch return .{ .ignore = "the bump does not parse" };
    if (path.block_height != p.height) return .{ .ignore = "the bump is not at blockHeight" };
    const root = c.beef.rootFor(a, path, p.txid) orelse return .{ .ignore = "the bump does not prove the txid" };
    const at = (try ch.chain().at(p.height)) orelse return .{ .ignore = "no header held at blockHeight" };
    if (!eql(u8, &at.hash, &p.block_hash)) return .{ .ignore = "blockHash is not our header at blockHeight" };
    if (!eql(u8, &root, &(try c.header.Header.parse(&at.raw)).merkle_root)) return .{ .ignore = "the bump's root is not our header's merkle root" };
    return .{ .event = .{ .map = try a.dupe(cbor.Entry, &.{
        .{ .key = "kind", .value = .{ .text = "proof" } },
        .{ .key = "subject", .value = .{ .cid = try a.dupe(u8, &c.store.hashCid(.tx, p.txid)) } },
        .{ .key = "txid", .value = .{ .text = try a.dupe(u8, &c.header.toHex(p.txid)) } },
        .{ .key = "path", .value = .{ .bytes = p.bump } },
        .{ .key = "blockHash", .value = .{ .text = try a.dupe(u8, &c.header.toHex(p.block_hash)) } },
        .{ .key = "blockHeight", .value = .{ .uint = p.height } },
        .{ .key = "via", .value = .{ .text = via } },
    }) } };
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

/// The chain app answered that `txid` is proven (not by a proof that came by gossip on `-proof`:
/// `via`) — each time it does (0.20.0: a reorg's new proof too): `<topic>-proof` for each served
/// topic that admitted it, with gossip on. The BUMP is this
/// txid's path alone, rebuilt from the chain state's merkle nodes (`State.proofFor`). → how many
/// messages.
pub fn proven(a: Allocator, out: Out, st: *st_mod.State, in: Value, txid: [32]u8) !usize {
    if ((try st.ch.status(txid)) != .proven) return 0;
    const block = (try st.ch.proofBlock(txid)) orelse return 0;
    const path = (try st.ch.proofFor(txid)) orelse return 0;
    var bump: ?[]const u8 = null;
    var n: usize = 0;
    const served = try calls.configObject(a, in, "overlayTopics");
    var it = served.iterator();
    while (it.next()) |e| {
        const t = e.key_ptr.*;
        if (!(try st.isApplied(t, txid)) or !(try enabled(a, in, t))) continue;
        if (bump == null) bump = try path.bytes(a);
        try out.publish(a, try std.mem.concat(a, u8, &.{ t, proof_suffix }), try proofBody(a, txid, block, path.block_height, bump.?));
        n += 1;
    }
    return n;
}
