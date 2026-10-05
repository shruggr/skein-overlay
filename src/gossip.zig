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
//!                  under the head `<app>/gossip`; never admits anything.
//!   <topic>-proof  the proof of an admitted transaction, published when the
//!                  chain app answers that it is proven (once: a reorg's
//!                  re-proof is the chain app's, not re-published here):
//!                    {txid (hex), blockHash (hex), blockHeight, bump: bytes (BRC-74, this txid's path alone)}
//!                  Received (`peerProof`): checked against this instance's
//!                  own chain state (the chain app's, read only) and admitted
//!                  as the `proof` event in box `chain` — the chain app's
//!                  event row, the same as the host's broadcaster admits (#65).
//!
//! Statuses never propagate. Publishing is a message to the libp2p provider
//! (`publish {topic, body}`, docs/MESSAGES.md "The providers"), emitted from
//! the step and not awaited: its answer is recorded and runs nothing. With no
//! libp2p provider in the address book nothing is published.
//!
//! Config: `config.overlay.gossip` (genesis-wired: `defaults.overlayGossip`,
//! a JSON object in a string), `{"<topic>": false}` turns a topic's
//! publishing off; a topic not named publishes (the default is on).
//! Receiving is the dispatch rows `libp2p` `<topic>`, `<topic>-admit`,
//! `<topic>-proof` (an installed app's are derived from config.overlay).
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

pub const admit_suffix = "-admit";
pub const proof_suffix = "-proof";

/// The head the peer-admit records live under: `<app>/gossip` → `{kind: "overlay-gossip", maps: {peerAdmits: root | null}}`.
pub fn stateHead(a: Allocator, app: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "{s}/gossip", .{app});
}

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
        .{ .key = "txid", .value = .{ .text = try a.dupe(u8, &c.header.toHex(txid)) } },
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

/// Where a submission came from (the submit event's `source`, routes.zig, submit.zig):
/// {transport: "libp2p" | "mailbox" | "http", topic? (a libp2p topic), protocol? (a libp2p stream
/// protocol: the answer to a want, skein-overlay#1), from? (the libp2p peer that published it or
/// sent it on the stream: bytes, the peer ID's multihash), sender?, box? (a submission by message,
/// or over HTTP on a session: whom its answers go to, and in which box), request: <the message's
/// or the request record's CID>}.
pub const Source = struct { transport: []const u8 = "", topic: []const u8 = "", protocol: []const u8 = "", from: ?[]const u8 = null, request: ?[]const u8 = null };

pub fn sourceOf(ev: Value) Source {
    const s = ev.get("source") orelse return .{};
    return .{
        .transport = s.getText("transport") orelse "",
        .topic = s.getText("topic") orelse "",
        .protocol = s.getText("protocol") orelse "",
        .from = if (eql(u8, s.getText("transport") orelse "", "libp2p")) s.getBytes("from") else null,
        .request = s.getCid("request"),
    };
}

/// What one admission publishes, per topic that admitted it with gossip on:
/// the raw submission on `<topic>` (the submit event's `beef`: the BEEF as
/// received; not when it arrived by gossip on that topic), then the verdict
/// on `<topic>-admit` (the raw submission not either when it came on a stream, the answer to a
/// want, skein-overlay#1: its holders published it long since). `subject`: the transaction is the submission's subject;
/// a transaction admitted before it from the same BEEF (skein-overlay#1)
/// publishes its verdict only — the raw submission goes with the subject's,
/// and a peer judges what it carries oldest first itself. → how many messages.
pub fn admitted(a: Allocator, out: Out, st: *st_mod.State, in: Value, ev: Value, txid: [32]u8, subject: bool, topics: []const []const u8, applied: []const st_mod.Applied) !usize {
    const src = sourceOf(ev);
    var n: usize = 0;
    for (topics, applied) |t, ap| {
        if (ap.records.len == 0 or !(try st.isApplied(t, txid))) continue;
        if (!try enabled(a, in, t)) continue;
        if (subject and !(eql(u8, src.transport, "libp2p") and (eql(u8, src.topic, t) or src.protocol.len > 0))) {
            // The BEEF as received: from its pointer record (shruggr/skein#121: `beefOf` gives the exact
            // bytes back from the blocks), or the bytes the event carries.
            const b = if (ev.getCid("beef")) |rc| try c.record.beefOf(a, st.store, rc) else ev.getBytes("beef") orelse (try st.ch.beefOf(txid)) orelse return error.UnknownTransaction;
            try out.publish(a, t, b);
            n += 1;
        }
        try out.publish(a, try std.mem.concat(a, u8, &.{ t, admit_suffix }), try admitBody(a, txid, t, ap.outputs_to_admit, ap.coins_to_retain));
        n += 1;
    }
    return n;
}

/// The chain app answered that `txid` is proven (not by a proof that came by gossip on `-proof`:
/// `via`): `<topic>-proof` for each served topic that admitted it, with gossip on. The BUMP is this
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

// ---------------------------------------------------------------- peers' admits, recorded

/// The peer-admit event the `-admit` route admits (box `<app>`), and the record the engine keeps:
/// {kind: "peer-admit", topic, txid (hex), from: bytes(33) (the publisher's peer key), peer?: bytes
/// (its peer ID's multihash, the message's `from`: whom a want is asked of, shruggr/skein#112),
/// outputsToAdmit, coinsToRetain}.
pub fn peerAdmitRecord(a: Allocator, topic: []const u8, m: Admit, from: []const u8, peer: ?[]const u8) !Value {
    var es: std.ArrayList(cbor.Entry) = .empty;
    try es.appendSlice(a, &.{
        .{ .key = "kind", .value = .{ .text = "peer-admit" } },
        .{ .key = "topic", .value = .{ .text = topic } },
        .{ .key = "txid", .value = .{ .text = try a.dupe(u8, &c.header.toHex(m.txid)) } },
        .{ .key = "from", .value = .{ .bytes = from } },
    });
    if (peer) |p| try es.append(a, .{ .key = "peer", .value = .{ .bytes = p } });
    try es.appendSlice(a, &.{
        .{ .key = "outputsToAdmit", .value = .{ .array = try uints(a, m.outputs_to_admit) } },
        .{ .key = "coinsToRetain", .value = .{ .array = try uints(a, m.coins_to_retain) } },
    });
    return .{ .map = es.items };
}

/// The gossip state (head `<app>/gossip`): the map `peerAdmits`, key tp ‖ txid ‖ from → the peer-admit record.
pub const State = struct {
    arena: Allocator,
    store: Store,
    peer_admits: c.store.Map,

    pub fn load(a: Allocator, s: Store, state: ?[]const u8) !State {
        const maps = try c.store.Maps.create(a, s);
        var root: ?[]const u8 = null;
        if (state) |sc| {
            const v = try s.getValue(a, sc);
            if (!eql(u8, v.getText("kind") orelse "", "overlay-gossip")) return error.BadState;
            root = (v.get("maps") orelse return error.BadState).getCid("peerAdmits");
        }
        return .{ .arena = a, .store = s, .peer_admits = maps.map(root) };
    }

    pub fn key(a: Allocator, topic: []const u8, txid: [32]u8, from: []const u8) ![]u8 {
        return std.mem.concat(a, u8, &.{ try st_mod.topicPrefix(a, topic), &txid, from });
    }

    /// Record a peer's admit (a later one from the same peer for the same transaction replaces it). → the record's CID.
    pub fn record(self: *State, rec: Value) ![]const u8 {
        const topic = rec.getText("topic") orelse return error.BadEvent;
        const txid = c.header.fromHex(rec.getText("txid") orelse return error.BadEvent) catch return error.BadEvent;
        const from = rec.getBytes("from") orelse return error.BadEvent;
        const rc = try self.store.putValue(self.arena, rec);
        try self.peer_admits.putLink(try key(self.arena, topic, txid, from), rc);
        return rc;
    }

    /// The peers that admitted `txid` under `topic`: their peer-admit records' CIDs.
    pub fn admitsOf(self: *State, topic: []const u8, txid: [32]u8) ![]const []const u8 {
        const kvs = try self.peer_admits.prefixed(try std.mem.concat(self.arena, u8, &.{ try st_mod.topicPrefix(self.arena, topic), &txid }));
        const out = try self.arena.alloc([]const u8, kvs.len);
        for (kvs, out) |kv, *o| o.* = if (kv.value == .cid) kv.value.cid else return error.BadIndex;
        return out;
    }

    /// The peers whose `-admit` for `txid` under `topic` was seen: their peer IDs (the records'
    /// `peer`; a record without one, from before 0.7.2, names none).
    pub fn peersOf(self: *State, topic: []const u8, txid: [32]u8) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        for (try self.admitsOf(topic, txid)) |rc| {
            const p = (try self.store.getValue(self.arena, rc)).getBytes("peer") orelse continue;
            try st_mod.addPeer(self.arena, &out, p);
        }
        return out.items;
    }

    pub fn save(self: *State) ![]const u8 {
        try self.peer_admits.flush();
        return self.store.putValue(self.arena, .{ .map = try self.arena.dupe(cbor.Entry, &.{
            .{ .key = "kind", .value = .{ .text = "overlay-gossip" } },
            .{ .key = "maps", .value = .{ .map = try self.arena.dupe(cbor.Entry, &.{.{ .key = "peerAdmits", .value = if (self.peer_admits.root) |r| .{ .cid = r } else .null }}) } },
        }) });
    }
};
