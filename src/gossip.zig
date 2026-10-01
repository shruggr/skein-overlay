//! The standard overlay gossip (#74): per overlay topic `<topic>` an overlay
//! runs, three GossipSub topics, three meanings.
//!
//!   <topic>        the raw submission (the BEEF as received). Re-published by
//!                  an overlay after it **admits** a submission that did not
//!                  arrive by gossip on that topic (HTTP; GossipSub already
//!                  forwarded one that did), whichever gate admitted it (#73).
//!                  Judged on arrival by the overlay's `submit` (routes.zig).
//!   <topic>-admit  this overlay's verdict, for submitters to count — the STEAK
//!                  and the txid only, no BEEF:
//!                    {txid (hex), topics: {<topic>: {outputsToAdmit: [vout], coinsToRetain: [input index]}}}
//!                  Received (`peerAdmit`): recorded as a `peer-admit` record
//!                  under the head `overlay:gossip`; never admits anything.
//!   <topic>-proof  the proof of an admitted transaction, published on
//!                  recording it (its first proof, and again when a reorg
//!                  re-proves it in another block):
//!                    {txid (hex), blockHash (hex), blockHeight, bump: bytes (BRC-74, this txid's path alone)}
//!                  Received (`peerProof`): checked against this instance's
//!                  own chain and admitted as the `chain` proof event the
//!                  host's feed admits (#65) — specific wiring, not an open box.
//!
//! Statuses never propagate. Publishing is a message to the libp2p provider
//! (`publish {topic, body}`, docs/MESSAGES.md "The providers"), emitted from
//! the step and not awaited: its answer is recorded and runs nothing. With no
//! libp2p provider in the address book nothing is published.
//!
//! Config: genesis `defaults.overlayGossip`, a JSON object in a string,
//! `{"<topic>": false}` turns a topic's publishing off; a topic not named
//! publishes (the default is on). Receiving is the routes: `libp2p:<topic>`,
//! `libp2p:<topic>-admit`, `libp2p:<topic>-proof` in etc/routes.json and the
//! topics in etc/config.json `libp2p.topics`.
const std = @import("std");
const w = @import("wallet");

const cbor = w.cbor;
const Value = cbor.Value;
const Wallet = w.wallet.Wallet;
const Store = w.store.Store;
const ov = w.overlay;
const Allocator = std.mem.Allocator;
const eql = std.mem.eql;

pub const admit_suffix = "-admit";
pub const proof_suffix = "-proof";

/// The head the peer-admit records live under: `{kind: "overlay-gossip", maps: {peerAdmits: root | null}}`.
pub const state_head = "overlay:gossip";

/// Whether this overlay publishes for `topic` (defaults.overlayGossip; on unless `false`).
pub fn enabled(a: Allocator, in: Value, topic: []const u8) !bool {
    const m = try ov.configObject(a, in, "overlayGossip");
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
    /// Publish `body` (bytes: dag-cbor for -admit/-proof, the BEEF for <topic>) on `topic`.
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

/// `<topic>-admit`: {txid, topics: {<topic>: {outputsToAdmit, coinsToRetain}}} (dag-cbor).
pub fn admitBody(a: Allocator, txid: [32]u8, topic: []const u8, outputs_to_admit: []const u32, coins_to_retain: []const u32) ![]const u8 {
    return cbor.encode(a, .{ .map = try a.dupe(cbor.Entry, &.{
        .{ .key = "txid", .value = .{ .text = try a.dupe(u8, &w.header.toHex(txid)) } },
        .{ .key = "topics", .value = .{ .map = try a.dupe(cbor.Entry, &.{.{ .key = topic, .value = .{ .map = try a.dupe(cbor.Entry, &.{
            .{ .key = "outputsToAdmit", .value = .{ .array = try uints(a, outputs_to_admit) } },
            .{ .key = "coinsToRetain", .value = .{ .array = try uints(a, coins_to_retain) } },
        }) } }}) } },
    }) });
}

pub const Admit = struct { txid: [32]u8, outputs_to_admit: []const u32, coins_to_retain: []const u32 };

/// A `<topic>-admit` body read for `topic`: its txid and that topic's STEAK entry.
pub fn parseAdmit(a: Allocator, body: []const u8, topic: []const u8) !Admit {
    const v = cbor.decode(a, body) catch return error.BadMessage;
    if (v != .map) return error.BadMessage;
    const txid = w.header.fromHex(v.getText("txid") orelse return error.BadMessage) catch return error.BadMessage;
    const ts = v.get("topics") orelse return error.BadMessage;
    if (ts != .map) return error.BadMessage;
    const e = ts.get(topic) orelse return error.NotThisTopic;
    if (e != .map) return error.BadMessage;
    return .{ .txid = txid, .outputs_to_admit = try uintList(a, e.get("outputsToAdmit")), .coins_to_retain = try uintList(a, e.get("coinsToRetain")) };
}

/// `<topic>-proof`: {txid, blockHash, blockHeight, bump} (dag-cbor).
pub fn proofBody(a: Allocator, txid: [32]u8, block_hash: [32]u8, height: u32, bump: []const u8) ![]const u8 {
    return cbor.encode(a, .{ .map = try a.dupe(cbor.Entry, &.{
        .{ .key = "txid", .value = .{ .text = try a.dupe(u8, &w.header.toHex(txid)) } },
        .{ .key = "blockHash", .value = .{ .text = try a.dupe(u8, &w.header.toHex(block_hash)) } },
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
        .txid = w.header.fromHex(v.getText("txid") orelse return error.BadMessage) catch return error.BadMessage,
        .block_hash = w.header.fromHex(v.getText("blockHash") orelse return error.BadMessage) catch return error.BadMessage,
        .height = @intCast(h),
        .bump = v.getBytes("bump") orelse return error.BadMessage,
    };
}

/// A `-proof` message checked against this instance's own chain (read only:
/// the route's call): the transaction is held, the BUMP is at the height it
/// names and flags the txid, its root is our header's merkle root at that
/// height, and that header's hash is the message's `blockHash`. → the
/// `chain` proof event to admit (the host feed's shape, #65, plus `via`), or
/// why it is ignored. A missing header is not the publisher's fault (ours
/// may be behind): every refusal is `ignore`.
pub fn checkProof(a: Allocator, wal: *Wallet, p: Proof, via: []const u8) !union(enum) { event: Value, ignore: []const u8 } {
    if ((try wal.txRaw(p.txid)) == null) return .{ .ignore = "the transaction is not held here" };
    if (try wal.proofBlock(p.txid)) |b| if (eql(u8, &b, &p.block_hash) and (try wal.status(p.txid)) == .proven) return .{ .ignore = "already proven in that block" };
    const path = w.bsvz.spv.MerklePath.parse(a, p.bump) catch return .{ .ignore = "the bump does not parse" };
    if (path.block_height != p.height) return .{ .ignore = "the bump is not at blockHeight" };
    const root = w.beef.rootFor(a, path, p.txid) orelse return .{ .ignore = "the bump does not prove the txid" };
    const at = (try wal.chain().at(p.height)) orelse return .{ .ignore = "no header held at blockHeight" };
    if (!eql(u8, &at.hash, &p.block_hash)) return .{ .ignore = "blockHash is not our header at blockHeight" };
    if (!eql(u8, &root, &(try w.header.Header.parse(&at.raw)).merkle_root)) return .{ .ignore = "the bump's root is not our header's merkle root" };
    return .{ .event = .{ .map = try a.dupe(cbor.Entry, &.{
        .{ .key = "kind", .value = .{ .text = "proof" } },
        .{ .key = "subject", .value = .{ .cid = try a.dupe(u8, &w.store.hashCid(.tx, p.txid)) } },
        .{ .key = "txid", .value = .{ .text = try a.dupe(u8, &w.header.toHex(p.txid)) } },
        .{ .key = "path", .value = .{ .bytes = p.bump } },
        .{ .key = "blockHash", .value = .{ .text = try a.dupe(u8, &w.header.toHex(p.block_hash)) } },
        .{ .key = "blockHeight", .value = .{ .uint = p.height } },
        .{ .key = "via", .value = .{ .text = via } },
    }) } };
}

// ---------------------------------------------------------------- what a step publishes

/// Where a submission came from (the submit event's `source`, routes.zig):
/// {transport, topic? (a libp2p topic), request: <the request record's CID>}.
pub const Source = struct { transport: []const u8 = "", topic: []const u8 = "", request: ?[]const u8 = null };

pub fn sourceOf(ev: Value) Source {
    const s = ev.get("source") orelse return .{};
    return .{ .transport = s.getText("transport") orelse "", .topic = s.getText("topic") orelse "", .request = s.getCid("request") };
}

/// The submission's BEEF as received: its request record's body (an HTTP
/// submit's off-chain values framing taken off). Null when the source names
/// no request.
pub fn receivedBeef(a: Allocator, s: Store, src: Source) !?[]const u8 {
    const rc = src.request orelse return null;
    const req = try s.getValue(a, rc);
    const body = req.getBytes("body") orelse return null;
    const framed = if (req.get("headers")) |hs| eql(u8, hs.getText("x-includes-off-chain-values") orelse "", "true") else false;
    if (!framed) return body;
    var pos: usize = 0;
    const n = try readVarInt(body, &pos);
    if (n > body.len - pos) return error.BadFraming;
    return body[pos .. pos + @as(usize, @intCast(n))];
}

fn readVarInt(b: []const u8, pos: *usize) !u64 {
    if (pos.* >= b.len) return error.BadFraming;
    const f = b[pos.*];
    pos.* += 1;
    const n: usize = switch (f) {
        0xfd => 2,
        0xfe => 4,
        0xff => 8,
        else => return f,
    };
    if (pos.* + n > b.len) return error.BadFraming;
    var v: u64 = 0;
    for (0..n) |i| v |= @as(u64, b[pos.* + i]) << @intCast(8 * i);
    pos.* += n;
    return v;
}

/// What one admission publishes, per topic that admitted it with gossip on:
/// the raw submission on `<topic>` (unless it arrived by gossip on that
/// topic), then the verdict on `<topic>-admit`. `topics`/`applied` are the
/// step's (submit.Stepped). → how many messages.
pub fn admitted(a: Allocator, out: Out, s: Store, wal: *Wallet, in: Value, ev: Value, txid: [32]u8, topics: []const []const u8, applied: []const ov.Applied) !usize {
    const src = sourceOf(ev);
    var n: usize = 0;
    var beef: ?[]const u8 = null;
    for (topics, applied) |t, ap| {
        if (ap.records.len == 0 or !(try ov.isApplied(wal, t, txid))) continue;
        if (!try enabled(a, in, t)) continue;
        if (!(eql(u8, src.transport, "libp2p") and eql(u8, src.topic, t))) {
            if (beef == null) beef = (try receivedBeef(a, s, src)) orelse try wal.beefOf(txid);
            if (beef) |b| {
                try out.publish(a, t, b);
                n += 1;
            }
        }
        try out.publish(a, try std.mem.concat(a, u8, &.{ t, admit_suffix }), try admitBody(a, txid, t, ap.outputs_to_admit, ap.coins_to_retain));
        n += 1;
    }
    return n;
}

/// After a step that may have recorded a proof for `txid`: if the proof's
/// block changed in the step (`before` → now, proven on our best chain) and
/// it did not arrive by gossip on `-proof`, publish `<topic>-proof` for each
/// served topic that admitted the transaction, with gossip on. The BUMP is
/// this txid's path alone, rebuilt from the held merkle nodes
/// (`Wallet.proofFor`). → how many messages.
pub fn proven(a: Allocator, out: Out, wal: *Wallet, in: Value, txid: [32]u8, before: ?[32]u8, via_gossip: bool) !usize {
    if (via_gossip) return 0;
    if ((try wal.status(txid)) != .proven) return 0;
    const block = (try wal.proofBlock(txid)) orelse return 0;
    if (before) |b| if (eql(u8, &b, &block)) return 0;
    const path = (try wal.proofFor(txid)) orelse return 0;
    var bump: ?[]const u8 = null;
    var n: usize = 0;
    const served = try ov.configObject(a, in, "overlayTopics");
    var it = served.iterator();
    while (it.next()) |e| {
        const t = e.key_ptr.*;
        if (!(try ov.isApplied(wal, t, txid)) or !(try enabled(a, in, t))) continue;
        if (bump == null) bump = try path.bytes(a);
        try out.publish(a, try std.mem.concat(a, u8, &.{ t, proof_suffix }), try proofBody(a, txid, block, path.block_height, bump.?));
        n += 1;
    }
    return n;
}

// ---------------------------------------------------------------- peers' admits, recorded

/// The peer-admit event the `-admit` route admits (box `submit`), and the record the engine keeps:
/// {kind: "peer-admit", topic, txid (hex), from: bytes(33) (the publisher's peer key), outputsToAdmit, coinsToRetain}.
pub fn peerAdmitRecord(a: Allocator, topic: []const u8, m: Admit, from: []const u8) !Value {
    return .{ .map = try a.dupe(cbor.Entry, &.{
        .{ .key = "kind", .value = .{ .text = "peer-admit" } },
        .{ .key = "topic", .value = .{ .text = topic } },
        .{ .key = "txid", .value = .{ .text = try a.dupe(u8, &w.header.toHex(m.txid)) } },
        .{ .key = "from", .value = .{ .bytes = from } },
        .{ .key = "outputsToAdmit", .value = .{ .array = try uints(a, m.outputs_to_admit) } },
        .{ .key = "coinsToRetain", .value = .{ .array = try uints(a, m.coins_to_retain) } },
    }) };
}

/// The gossip state (head `overlay:gossip`): the map `peerAdmits`, key tp ‖ txid ‖ from → the peer-admit record.
pub const State = struct {
    arena: Allocator,
    store: Store,
    peer_admits: w.store.Map,

    pub fn load(a: Allocator, s: Store, state: ?[]const u8) !State {
        const maps = try w.store.Maps.create(a, s);
        var root: ?[]const u8 = null;
        if (state) |c| {
            const v = try s.getValue(a, c);
            if (!eql(u8, v.getText("kind") orelse "", "overlay-gossip")) return error.BadState;
            root = (v.get("maps") orelse return error.BadState).getCid("peerAdmits");
        }
        return .{ .arena = a, .store = s, .peer_admits = maps.map(root) };
    }

    pub fn key(a: Allocator, topic: []const u8, txid: [32]u8, from: []const u8) ![]u8 {
        return std.mem.concat(a, u8, &.{ try ov.topicPrefix(a, topic), &txid, from });
    }

    /// Record a peer's admit (a later one from the same peer for the same transaction replaces it). → the record's CID.
    pub fn record(self: *State, rec: Value) ![]const u8 {
        const topic = rec.getText("topic") orelse return error.BadEvent;
        const txid = w.header.fromHex(rec.getText("txid") orelse return error.BadEvent) catch return error.BadEvent;
        const from = rec.getBytes("from") orelse return error.BadEvent;
        const c = try self.store.putValue(self.arena, rec);
        try self.peer_admits.putLink(try key(self.arena, topic, txid, from), c);
        return c;
    }

    /// The peers that admitted `txid` under `topic`: their peer-admit records' CIDs.
    pub fn admitsOf(self: *State, topic: []const u8, txid: [32]u8) ![]const []const u8 {
        const kvs = try self.peer_admits.prefixed(try std.mem.concat(self.arena, u8, &.{ try ov.topicPrefix(self.arena, topic), &txid }));
        const out = try self.arena.alloc([]const u8, kvs.len);
        for (kvs, out) |kv, *o| o.* = if (kv.value == .cid) kv.value.cid else return error.BadIndex;
        return out;
    }

    pub fn save(self: *State) ![]const u8 {
        try self.peer_admits.flush();
        return self.store.putValue(self.arena, .{ .map = try self.arena.dupe(cbor.Entry, &.{
            .{ .key = "kind", .value = .{ .text = "overlay-gossip" } },
            .{ .key = "maps", .value = .{ .map = try self.arena.dupe(cbor.Entry, &.{.{ .key = "peerAdmits", .value = if (self.peer_admits.root) |r| .{ .cid = r } else .null }}) } },
        }) });
    }
};
