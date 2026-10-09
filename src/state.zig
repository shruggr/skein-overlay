//! The overlay's state (#36, re-split by skein #79): what its topics
//! admitted, under the app's own name — and nothing about the chain. The
//! chain state (headers, transactions, proofs, spends, settlement) is the
//! chain app's (shruggr/skein-chain, the head `chain/state`, the SDK's
//! `chain.state.State`), read here by CID and never written: a submission is
//! SPV-checked against its headers, an admitted output's spender is its
//! `spent`, a lookup's BEEF is built from its records. Two overlay apps on one
//! instance each keep their own record under their own name and share the one
//! chain.
//!
//! The record, the root of `<app>/state`:
//!
//!   {kind: "overlay-state", maps: {admitted, applied, pending, wants, views}}
//!
//! The maps (keys bytes, ordered bytewise; `tp` = len ‖ topic):
//!   admitted   tp ‖ txid ‖ vout → admittance record {kind: "admitted", topic, txid, vout, script, satoshis, admittedAt, tx, refs}
//!   applied    tp ‖ txid → applied record {kind: "applied", topic, txid, outputsToAdmit, coinsToRetain, coinsRemoved, at, tx, beef, refs}
//!                (beef: the submission's BEEF as the overlay was handed it — the door's envelope
//!                 {form, beef: <pointer record>, subject?, vout?} as a block (shruggr/skein#121,
//!                 #146), or the raw block of the bytes — for internalizing; a
//!                 lookup's BEEF is the chain state's, `beefFor`)
//!   pending    txid → {kind: "submission", txid, thread?, submission, ingest?, heard?, via?, waiting?, event?}
//!                a transaction of a submission handed to the chain app and not yet admitted (or
//!                rejected): `submission` the submission's subject (hex), `ingest` its own ingest
//!                message, `heard` the chain app's admitting answer while an earlier transaction of
//!                the same submission is still pending (skein-overlay#1); or a submission paused on
//!                parents neither in its BEEF nor held (`waiting`: their txids, hex; `event`: the
//!                submit event to route again)
//!   wants      wanted txid ‖ tp ‖ peer? → [subject txid (bytes)]   a want (skein-overlay#1, shruggr/skein#112):
//!                a parent the paused submissions `subject` wait on, wanted under the topic `tp`,
//!                to be asked of `peer` (the libp2p peer ID's multihash, a gossip message's
//!                `from`), which announced one of them or something needing it; no peer (a
//!                submission by message or HTTP): the host asks peers from its mesh for the topic
//!   views      tp → bytes(40): count (8 bytes, big-endian) ‖ digest (32 bytes)   the topic's VIEW
//!                DIGEST (0.12.0, David 2026-10-09): `count` the topic's admitted-and-unspent
//!                outputs, `digest` an order-independent running digest of them — each outpoint's
//!                hash `sha256(txid (32 bytes, internal byte order) ‖ vout (4 bytes, little-endian))`,
//!                read as a 256-bit big-endian number, ADDED mod 2^256 when the topic admits the
//!                output and SUBTRACTED when it is spent; written as 32 bytes big-endian (`View`).
//!                Kept incrementally as the topic admits and spends (`apply`, `unapply`): read in
//!                one lookup, no sort, no log read. "Spent" is the topic's own view of it: a
//!                previous coin a transaction the topic admits consumes (BRC-22), retained or not;
//!                a rejection (`unapply`) takes its transaction's outputs out and gives the coins
//!                it consumed back. An empty topic: count 0, digest 32 zero bytes. The beat body
//!                on `<topic>-live` carries it (topics.zig `beatBody`).
//!
//! Nothing here is derived from the chain: whether an admitted output is
//! spent is the chain state's `spent` (the first held spender that is not
//! rejected), read when asked (`inTopic`, `previousCoins`). A rejected
//! transaction's judgements are removed when the chain app answers
//! `rejected` (`unapply`); a rejected spend gives the coins it consumed back
//! by itself (the chain's `spent` no longer counts it). The records carry
//! `refs: [{to: <tx CID>, rel: "admits"}]`, so the step that keeps them gives
//! the kernel the edges (skein docs/VM.md "Edges").
const std = @import("std");
const c = @import("chain");
const topic = @import("topic");

const bsvz = c.bsvz;
const cbor = c.cbor;
const hdr = c.header;
const beef_mod = c.beef;
const merkle = c.merkle;
const store_mod = c.store;
const Store = store_mod.Store;
const Map = store_mod.Map;
const Value = cbor.Value;
const Transaction = bsvz.transaction.Transaction;
const Allocator = std.mem.Allocator;

pub const Instructions = topic.Instructions;
/// The chain app's state, read only.
pub const Chain = c.state.State;
pub const Network = c.chain.Network;

/// The head the chain state lives under: the chain app's (its name is `chain`).
pub const chain_head = "chain/state";

pub const map_names = [_][]const u8{ "admitted", "applied", "pending", "wants", "views" };

/// A topic's view digest (the map `views`, 0.12.0): how many outputs the topic holds admitted and
/// unspent, and the sum (mod 2^256) of their outpoints' hashes (`outpointHash`). Two topics holding
/// the same outputs have the same view, whatever order they were admitted and spent in.
pub const View = struct {
    count: u64 = 0,
    digest: [32]u8 = .{0} ** 32,

    pub fn eql(x: View, y: View) bool {
        return x.count == y.count and std.mem.eql(u8, &x.digest, &y.digest);
    }

    /// The output `(txid, vout)` folded in (`in`: admitted) or out (spent).
    pub fn fold(self: *View, txid: [32]u8, vout: u32, in: bool) void {
        const h = std.mem.readInt(u256, &outpointHash(txid, vout), .big);
        const d = std.mem.readInt(u256, &self.digest, .big);
        std.mem.writeInt(u256, &self.digest, if (in) d +% h else d -% h, .big);
        if (in) self.count += 1 else self.count -|= 1;
    }

    pub fn bytes(self: View) [40]u8 {
        var out: [40]u8 = undefined;
        std.mem.writeInt(u64, out[0..8], self.count, .big);
        @memcpy(out[8..], &self.digest);
        return out;
    }

    pub fn parse(b: []const u8) !View {
        if (b.len != 40) return error.BadIndex;
        return .{ .count = std.mem.readInt(u64, b[0..8], .big), .digest = b[8..40].* };
    }
};

/// An outpoint's hash in the view digest: sha256(txid (32 bytes, internal byte order) ‖ vout (4
/// bytes, little-endian)) — the outpoint as a Bitcoin input serializes it.
pub fn outpointHash(txid: [32]u8, vout: u32) [32]u8 {
    var buf: [36]u8 = undefined;
    @memcpy(buf[0..32], &txid);
    std.mem.writeInt(u32, buf[32..36], vout, .little);
    var out: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&buf, &out, .{});
    return out;
}

/// A topic whose view a step changed: what it was before the step, and what it is now.
pub const ViewChange = struct { topic: []const u8, before: View, now: View };

/// A lookup service's beat body, as a hook of its program answered it (`{beats: {<service>:
/// bytes}}`, calls.zig): the engine re-declares the beacon on `<service>-live` with it (topics.zig
/// `beatEvents`).
pub const LookupBeat = struct { service: []const u8, body: []const u8 };

/// What a topic's judgement came to (the STEAK's entry for it).
pub const Applied = struct {
    outputs_to_admit: []const u32 = &.{},
    coins_to_retain: []const u32 = &.{},
    /// The previous coins not retained (BRC-22 `coinsRemoved`).
    coins_removed: []const u32 = &.{},
    /// Judged before: nothing recorded again.
    dupe: bool = false,
    /// The records this judgement wrote (admittances, then the applied record): the step keeps them.
    records: []const []const u8 = &.{},
};

/// A transaction being judged: its txid, its CID (bitcoin-tx), and the transaction as its block decodes.
pub const Subject = struct {
    txid: [32]u8,
    cid: []const u8,
    tx: Transaction,
};

/// A transaction a submission carried, as decoded: its txid and block bytes.
pub const DecodedTx = struct { txid: [32]u8, raw: []const u8 };
/// A BUMP's block, as the submission's merkle nodes reach it: its height and root.
pub const Bump = struct { height: u32, root: [32]u8 };
/// A transaction a BUMP proves, at that BUMP's height and its position in it.
pub const Proven = struct { txid: [32]u8, height: u32, pos: merkle.Position };

/// A submitted BEEF decoded into records (#50): each transaction a
/// `bitcoin-tx` block, each BUMP the merkle nodes it reveals (64-byte
/// `bitcoin-tx` blocks). The blocks are put when decoded — in a front-door
/// call they land in the call's in-memory overlay, and nothing persists
/// unless the chain app ingests the submission.
pub const Decoded = struct {
    subject: [32]u8,
    /// Every transaction with its bytes, in BEEF order (parents first).
    txs: []const DecodedTx,
    /// The merkle nodes the BUMPs reveal, each once.
    nodes: []const merkle.Node,
    /// The BUMPs that prove something here.
    bumps: []const Bump,
    proven: []const Proven,
    /// Entries that named a txid only (the chain must hold them).
    txid_only: []const [32]u8,
};

/// A topic's judgement a rejection removed: its lookup services are told (`rejected`).
pub const Unapplied = struct { topic: []const u8, txid: [32]u8 };

pub fn topicPrefix(a: Allocator, t: []const u8) ![]u8 {
    if (t.len == 0) return error.BadTopic;
    return store_mod.nameKey(a, t, &.{});
}

/// `peer` onto `out` unless there already.
pub fn addPeer(a: Allocator, out: *std.ArrayList([]const u8), peer: []const u8) !void {
    for (out.items) |p| if (std.mem.eql(u8, p, peer)) return;
    try out.append(a, peer);
}

/// A want (shruggr/skein#112): the wanted txid, the topic it is wanted under, the peer to ask (none:
/// the host asks peers from its mesh for the topic).
pub const Want = struct { txid: [32]u8, topic: []const u8, peer: ?[]const u8 };

/// A `wants` key read back: txid ‖ tp ‖ peer.
pub fn wantOf(key: []const u8) !Want {
    if (key.len < 34) return error.BadIndex;
    const n = key[32];
    if (n == 0 or key.len < 33 + @as(usize, n)) return error.BadIndex;
    const rest = key[33 + @as(usize, n) ..];
    return .{ .txid = key[0..32].*, .topic = key[33 .. 33 + @as(usize, n)], .peer = if (rest.len > 0) rest else null };
}

/// The event of a want (`kind` "want") or of its end ("unwant"): `{event, txid (hex), topic, peer?
/// (bytes: the libp2p peer ID's multihash)}`.
pub fn wantEvent(a: Allocator, kind: []const u8, w: Want) !Value {
    var es: std.ArrayList(cbor.Entry) = .empty;
    try es.appendSlice(a, &.{
        .{ .key = "event", .value = .{ .text = kind } },
        .{ .key = "txid", .value = .{ .text = try a.dupe(u8, &hdr.toHex(w.txid)) } },
        .{ .key = "topic", .value = .{ .text = w.topic } },
    });
    if (w.peer) |p| try es.append(a, .{ .key = "peer", .value = .{ .bytes = p } });
    return .{ .map = es.items };
}

fn cat(a: Allocator, parts: []const []const u8) ![]u8 {
    return std.mem.concat(a, u8, parts);
}

fn contains(xs: []const u32, x: u32) bool {
    for (xs) |y| if (y == x) return true;
    return false;
}

fn uints(a: Allocator, xs: []const u32) ![]Value {
    const out = try a.alloc(Value, xs.len);
    for (xs, out) |x, *o| o.* = .{ .uint = x };
    return out;
}

/// The chain state the root names (null: none yet, an empty chain on `network`), read only. Its own
/// record says which network it is on.
pub fn chainView(a: Allocator, s: Store, root: ?[]const u8, network: Network) !*Chain {
    var net = network;
    if (root) |r| net = Network.parse((try s.getValue(a, r)).getText("network") orelse "") orelse return error.BadChainState;
    const ch = try a.create(Chain);
    ch.* = try Chain.load(a, s, root, net);
    return ch;
}

/// A transaction's block, read (`get`: in a call, through its overlay) and decoded.
pub fn subjectOf(a: Allocator, s: Store, txid: [32]u8) !Subject {
    const tc = try a.dupe(u8, &store_mod.hashCid(.tx, txid));
    const raw = s.get(a, tc) catch return error.MissingInput;
    return .{ .txid = txid, .cid = tc, .tx = Transaction.parse(a, raw) catch return error.InvalidBeef };
}

pub const State = struct {
    arena: Allocator,
    store: Store,
    maps: *store_mod.Maps,
    m: [map_names.len]Map,
    /// The chain state, read only.
    ch: *Chain,
    /// The step's time (ms): admittances and judgements are stamped with it.
    now: i64 = 0,
    /// The wants this step touched, and whether each stood before (`wantEvents`).
    want_log: std.ArrayList(struct { key: []const u8, stood: bool }) = .empty,
    /// The topics whose view this step touched, and each one's view before its first touch (`viewChanges`).
    view_log: std.ArrayList(struct { topic: []const u8, before: View }) = .empty,
    /// The lookup beat bodies this step's hooks answered, in order (`LookupBeat`).
    lookup_beats: std.ArrayList(LookupBeat) = .empty,

    /// The state the record names (null: a new one), over the chain state `ch`.
    pub fn load(arena: Allocator, s: Store, state: ?[]const u8, ch: *Chain) !State {
        const maps = try store_mod.Maps.create(arena, s);
        var st = State{ .arena = arena, .store = s, .maps = maps, .m = undefined, .ch = ch };
        var roots: ?Value = null;
        if (state) |sc| {
            const v = try s.getValue(arena, sc);
            if (!std.mem.eql(u8, v.getText("kind") orelse "", "overlay-state")) return error.BadState;
            roots = v.get("maps") orelse return error.BadState;
        }
        for (map_names, 0..) |n, i| st.m[i] = maps.map(if (roots) |r| r.getCid(n) else null);
        return st;
    }

    pub fn map(self: *State, comptime name: []const u8) *Map {
        inline for (map_names, 0..) |n, i| if (comptime std.mem.eql(u8, n, name)) return &self.m[i];
        @compileError("no map " ++ name);
    }

    /// Put every new map node and a state record naming the maps' roots; → its CID.
    pub fn save(self: *State) ![]const u8 {
        const es = try self.arena.alloc(cbor.Entry, map_names.len);
        for (map_names, &self.m, es) |n, *mp, *e| {
            try mp.flush();
            e.* = .{ .key = n, .value = if (mp.root) |r| .{ .cid = r } else .null };
        }
        return self.store.putValue(self.arena, .{ .map = try self.arena.dupe(cbor.Entry, &.{
            .{ .key = "kind", .value = .{ .text = "overlay-state" } },
            .{ .key = "maps", .value = .{ .map = es } },
        }) });
    }

    pub fn record(self: *State, cid: []const u8) !Value {
        return self.store.getValue(self.arena, cid);
    }

    // ------------------------------------------------------------ pending submissions

    /// A pending record's fields (skein-overlay#1). A transaction handed to the chain app: `ingest`
    /// (the message its answers name), `submission` (the subject of the submission it came in;
    /// the thread carrying it), `heard` (an admitting
    /// answer heard while an earlier transaction of the submission is still pending). A paused
    /// submission: `waiting` (the parents neither in its BEEF nor held) and `event` (the submit
    /// event, routed again when one of them arrives).
    pub const Pending = struct {
        thread: ?[]const u8 = null,
        submission: ?[32]u8 = null,
        ingest: ?[]const u8 = null,
        heard: ?[]const u8 = null,
        via: ?[]const u8 = null,
        waiting: []const [32]u8 = &.{},
        event: ?[]const u8 = null,
        /// A paused submission's waiters (0.9.1): the `wait` messages of the HTTP requests waiting on
        /// it, each answered (`replyTo`) when the pause ends.
        wakes: []const []const u8 = &.{},
    };

    pub fn putPending(self: *State, txid: [32]u8, p: Pending) !void {
        const a = self.arena;
        var fields: std.ArrayList(cbor.Entry) = .empty;
        try fields.appendSlice(a, &.{
            .{ .key = "kind", .value = .{ .text = "submission" } },
            .{ .key = "txid", .value = .{ .text = try a.dupe(u8, &hdr.toHex(txid)) } },
            .{ .key = "submission", .value = .{ .text = try a.dupe(u8, &hdr.toHex(p.submission orelse txid)) } },
        });
        if (p.ingest) |m| try fields.append(a, .{ .key = "ingest", .value = .{ .cid = m } });
        if (p.thread) |t| try fields.append(a, .{ .key = "thread", .value = .{ .cid = t } });
        if (p.heard) |h| try fields.append(a, .{ .key = "heard", .value = .{ .text = h } });
        if (p.via) |v| try fields.append(a, .{ .key = "via", .value = .{ .text = v } });
        if (p.waiting.len > 0) {
            const ws = try a.alloc(Value, p.waiting.len);
            for (p.waiting, ws) |w, *o| o.* = .{ .text = try a.dupe(u8, &hdr.toHex(w)) };
            try fields.append(a, .{ .key = "waiting", .value = .{ .array = ws } });
        }
        if (p.event) |e| try fields.append(a, .{ .key = "event", .value = .{ .cid = e } });
        if (p.wakes.len > 0) {
            const ws = try a.alloc(Value, p.wakes.len);
            for (p.wakes, ws) |w, *o| o.* = .{ .cid = w };
            try fields.append(a, .{ .key = "wakes", .value = .{ .array = ws } });
        }
        try self.map("pending").putLink(&txid, try self.store.putValue(a, .{ .map = fields.items }));
    }

    pub fn pendingRecord(self: *State, txid: [32]u8) !?Value {
        const pc = (try self.map("pending").link(&txid)) orelse return null;
        return try self.record(pc);
    }

    pub fn isPending(self: *State, txid: [32]u8) !bool {
        return self.map("pending").has(&txid);
    }

    /// Whether the submission of this subject is paused on parents it lacks (skein-overlay#1).
    pub fn isPaused(self: *State, txid: [32]u8) !bool {
        const rec = (try self.pendingRecord(txid)) orelse return false;
        return rec.get("waiting") != null;
    }

    pub fn dropPending(self: *State, txid: [32]u8) !void {
        _ = try self.map("pending").remove(&txid);
    }

    // ------------------------------------------------------------ wanted parents (skein-overlay#1)

    fn subjectsValue(self: *State, subs: []const [32]u8) !store_mod.MValue {
        const vs = try self.arena.alloc(store_mod.MValue, subs.len);
        for (subs, vs) |s_, *o| o.* = .{ .bytes = try self.arena.dupe(u8, &s_) };
        return .{ .array = vs };
    }

    fn subjects(self: *State, v: store_mod.MValue) ![][32]u8 {
        const xs = if (v == .array) v.array else return error.BadIndex;
        const out = try self.arena.alloc([32]u8, xs.len);
        for (xs, out) |x, *o| o.* = if (x == .bytes and x.bytes.len == 32) x.bytes[0..32].* else return error.BadIndex;
        return out;
    }

    /// A want's key: txid ‖ tp ‖ peer (no peer: nothing after the topic).
    pub fn wantKey(self: *State, txid: [32]u8, t: []const u8, peer: ?[]const u8) ![]u8 {
        return cat(self.arena, &.{ &txid, try topicPrefix(self.arena, t), peer orelse "" });
    }

    /// Whether the want (`txid`, `topic`, `peer`) stands (null: the want with no peer).
    pub fn hasWant(self: *State, txid: [32]u8, t: []const u8, peer: ?[]const u8) !bool {
        return self.map("wants").has(try self.wantKey(txid, t, peer));
    }

    /// The step's journal of wants it touched: whether each stood before its first touch. The
    /// `want` / `unwant` events are the difference at the end of the step (`wantEvents`).
    fn touchWant(self: *State, key: []const u8) !void {
        for (self.want_log.items) |x| if (std.mem.eql(u8, x.key, key)) return;
        try self.want_log.append(self.arena, .{ .key = try self.arena.dupe(u8, key), .stood = try self.map("wants").has(key) });
    }

    fn putWant(self: *State, key: []const u8, subs: []const [32]u8) !void {
        try self.touchWant(key);
        try self.map("wants").put(key, try self.subjectsValue(subs));
    }

    fn dropWant(self: *State, key: []const u8) !void {
        try self.touchWant(key);
        _ = try self.map("wants").remove(key);
    }

    /// Note that the paused submission `subject` waits on `txid`, wanted under `topic` from `peer`
    /// (null: from no peer — the host asks its mesh for the topic).
    pub fn want(self: *State, txid: [32]u8, t: []const u8, peer: ?[]const u8, subject: [32]u8) !void {
        const key = try self.wantKey(txid, t, peer);
        const cur = try self.map("wants").get(key);
        var subs: std.ArrayList([32]u8) = .empty;
        if (cur) |v| for (try self.subjects(v)) |x| {
            if (std.mem.eql(u8, &x, &subject)) return;
            try subs.append(self.arena, x);
        };
        try subs.append(self.arena, subject);
        try self.putWant(key, subs.items);
    }

    /// Whether `peer` is asked for every one of `waiting` under each of `topics` on `subject`'s behalf already.
    pub fn wantsFrom(self: *State, subject: [32]u8, waiting: []const [32]u8, topics: []const []const u8, peer: []const u8) !bool {
        for (waiting) |w| for (topics) |t| {
            const v = (try self.map("wants").get(try self.wantKey(w, t, peer))) orelse return false;
            for (try self.subjects(v)) |x| {
                if (std.mem.eql(u8, &x, &subject)) break;
            } else return false;
        };
        return true;
    }

    pub fn isWanted(self: *State, txid: [32]u8) !bool {
        return (try self.map("wants").prefixed(&txid)).len > 0;
    }

    /// The peers wants for `txid` stand against (those that announced something needing it), each
    /// once, in key order; a want with no peer is not one.
    pub fn wantedFrom(self: *State, txid: [32]u8) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        for (try self.map("wants").prefixed(&txid)) |kv| {
            const k = try wantOf(kv.key);
            if (k.peer) |p| try addPeer(self.arena, &out, p);
        }
        return out.items;
    }

    /// The paused submissions waiting on `txid` (each once, in key order).
    pub fn waitersOf(self: *State, txid: [32]u8) ![][32]u8 {
        var out: std.ArrayList([32]u8) = .empty;
        for (try self.map("wants").prefixed(&txid)) |kv| {
            _ = try wantOf(kv.key);
            outer: for (try self.subjects(kv.value)) |x| {
                for (out.items) |y| if (std.mem.eql(u8, &x, &y)) continue :outer;
                try out.append(self.arena, x);
            }
        }
        return out.items;
    }

    /// The peers `subject`'s wants on `waiting` stand against (those that announced it, or
    /// something needing it), each once, in key order; `none`: whether one of them has no peer.
    pub fn peersOf(self: *State, subject: [32]u8, waiting: []const [32]u8) !struct { peers: []const []const u8, none: bool } {
        var out: std.ArrayList([]const u8) = .empty;
        var none = false;
        for (waiting) |w| for (try self.map("wants").prefixed(&w)) |kv| {
            for (try self.subjects(kv.value)) |x| {
                if (!std.mem.eql(u8, &x, &subject)) continue;
                const k = try wantOf(kv.key);
                if (k.peer) |p| try addPeer(self.arena, &out, p) else none = true;
                break;
            }
        };
        return .{ .peers = out.items, .none = none };
    }

    /// `subject`'s wants (on each of `waiting`) cleared: the subject out of each want's value, a
    /// want left with no subject removed.
    pub fn unwant(self: *State, subject: [32]u8, waiting: []const [32]u8) !void {
        for (waiting) |w| for (try self.map("wants").prefixed(&w)) |kv| {
            var rest: std.ArrayList([32]u8) = .empty;
            var had = false;
            for (try self.subjects(kv.value)) |x| {
                if (std.mem.eql(u8, &x, &subject)) had = true else try rest.append(self.arena, x);
            }
            if (!had) continue;
            if (rest.items.len == 0) try self.dropWant(kv.key) else try self.putWant(kv.key, rest.items);
        };
    }

    /// `txid` has arrived (the chain app answered for it): its waiters, each once, and every want
    /// for it (whatever the topic and peer) removed.
    pub fn takeWants(self: *State, txid: [32]u8) ![][32]u8 {
        const out = try self.waitersOf(txid);
        for (try self.map("wants").prefixed(&txid)) |kv| try self.dropWant(kv.key);
        return out;
    }

    /// The step's want events (shruggr/skein#112): for each want it touched, `{event: "want", txid,
    /// topic, peer?}` if it stands now and did not before, `{event: "unwant", …}` if it stood and
    /// does not now; nothing for one that stood before and stands still. In the order first touched.
    pub fn wantEvents(self: *State) ![]Value {
        var out: std.ArrayList(Value) = .empty;
        for (self.want_log.items) |x| {
            const now = try self.map("wants").has(x.key);
            if (now == x.stood) continue;
            try out.append(self.arena, try wantEvent(self.arena, if (now) "want" else "unwant", try wantOf(x.key)));
        }
        return out.items;
    }

    // ------------------------------------------------------------ judgements

    /// Whether the topic judged this transaction already (a dupe: BRC-22 answers it with nothing new).
    pub fn isApplied(self: *State, t: []const u8, txid: [32]u8) !bool {
        return self.map("applied").has(try cat(self.arena, &.{ try topicPrefix(self.arena, t), &txid }));
    }

    /// The applied record of (topic, txid), or null.
    pub fn appliedRecord(self: *State, t: []const u8, txid: [32]u8) !?Value {
        const rc = (try self.map("applied").link(try cat(self.arena, &.{ try topicPrefix(self.arena, t), &txid }))) orelse return null;
        return try self.record(rc);
    }

    /// Whether a transaction the chain holds, other than `tx` and not rejected, spends `op`.
    fn spentByOther(self: *State, op: [36]u8, tx: [32]u8) !bool {
        for (try self.ch.spendersOf(op)) |sp| {
            if (std.mem.eql(u8, &sp, &tx)) continue;
            if (!(try self.ch.map("rejected").has(&sp))) return true;
        }
        return false;
    }

    /// The input indices of `tx` that spend an output live in the topic (admitted, and not spent by
    /// another transaction the chain holds that is not rejected): BRC-22's `previousCoins`.
    pub fn previousCoins(self: *State, t: []const u8, tx: Transaction) ![]u32 {
        return self.previousCoinsWith(t, tx, &.{});
    }

    /// `previousCoins`, counting as live in the topic also `walked`: the outputs this topic took in
    /// the transactions of the same submission judged before this one (skein-overlay#1: judged
    /// oldest first, admitted only when the chain app answers for each).
    pub fn previousCoinsWith(self: *State, t: []const u8, tx: Transaction, walked: []const [36]u8) ![]u32 {
        const a = self.arena;
        const tp = try topicPrefix(a, t);
        const self_txid = (try tx.txid(a)).bytes;
        var out: std.ArrayList(u32) = .empty;
        for (tx.inputs, 0..) |in, i| {
            const op = store_mod.outpointKey(in.previous_outpoint.txid.bytes, in.previous_outpoint.index);
            const in_walk = for (walked) |w| {
                if (std.mem.eql(u8, &w, &op)) break true;
            } else false;
            if (in_walk) {
                try out.append(a, @intCast(i));
                continue;
            }
            if (!(try self.map("admitted").has(try cat(a, &.{ tp, &op })))) continue;
            if (try self.spentByOther(op, self_txid)) continue;
            try out.append(a, @intCast(i));
        }
        return out.items;
    }

    /// Record a topic's judgement of a submission the chain app has (accepted or proven): each
    /// admitted output as an admittance record, the judgement in `applied`. `previous` is
    /// `previousCoins` for this topic, taken before any judgement of this step. A transaction the
    /// topic judged before is a dupe: nothing is written. `beef`: the submission's BEEF (its CID:
    /// the door's envelope as a block, shruggr/skein#146, or the raw block of the bytes, `putRaw`),
    /// named by the applied record.
    pub fn apply(self: *State, sub: Subject, t: []const u8, previous: []const u32, ins: Instructions, beef: []const u8) !Applied {
        const a = self.arena;
        if (try self.isApplied(t, sub.txid)) return .{ .dupe = true };
        try check(sub.tx, previous, ins);
        var removed: std.ArrayList(u32) = .empty;
        for (previous) |p| if (!contains(ins.coins_to_retain, p)) try removed.append(a, p);
        if (!takes(previous, ins)) return .{};

        const tp = try topicPrefix(a, t);
        const txid_hex = try a.dupe(u8, &hdr.toHex(sub.txid));
        var records: std.ArrayList([]const u8) = .empty;
        // The view (0.12.0): each previous coin it consumes out (retained or not: spent), each output it admits in.
        var v = try self.touchView(t);
        for (previous) |p| {
            const po = sub.tx.inputs[p].previous_outpoint;
            if (try self.counted(t, po.txid.bytes, po.index)) v.fold(po.txid.bytes, po.index, false);
        }
        const sorted = try a.dupe(u32, ins.outputs_to_admit);
        std.mem.sort(u32, sorted, {}, std.sort.asc(u32));
        for (sorted) |vout| {
            const out = sub.tx.outputs[vout];
            const rec = try self.store.putValue(a, .{ .map = try a.dupe(cbor.Entry, &.{
                .{ .key = "kind", .value = .{ .text = "admitted" } },
                .{ .key = "topic", .value = .{ .text = t } },
                .{ .key = "txid", .value = .{ .text = txid_hex } },
                .{ .key = "vout", .value = .{ .uint = vout } },
                .{ .key = "script", .value = .{ .bytes = out.locking_script.bytes } },
                .{ .key = "satoshis", .value = .{ .uint = @intCast(out.satoshis) } },
                .{ .key = "admittedAt", .value = .{ .uint = @intCast(@max(self.now, 0)) } },
                .{ .key = "tx", .value = .{ .cid = sub.cid } },
                .{ .key = "refs", .value = try admitsRef(a, sub.cid) },
            }) });
            try self.map("admitted").putLink(try cat(a, &.{ tp, &store_mod.outpointKey(sub.txid, vout) }), rec);
            try records.append(a, rec);
            v.fold(sub.txid, vout, true);
        }
        try self.putView(t, v);
        const retained = try a.dupe(u32, ins.coins_to_retain);
        std.mem.sort(u32, retained, {}, std.sort.asc(u32));
        const applied = try self.store.putValue(a, .{ .map = try a.dupe(cbor.Entry, &.{
            .{ .key = "kind", .value = .{ .text = "applied" } },
            .{ .key = "topic", .value = .{ .text = t } },
            .{ .key = "txid", .value = .{ .text = txid_hex } },
            .{ .key = "outputsToAdmit", .value = .{ .array = try uints(a, sorted) } },
            .{ .key = "coinsToRetain", .value = .{ .array = try uints(a, retained) } },
            .{ .key = "coinsRemoved", .value = .{ .array = try uints(a, removed.items) } },
            .{ .key = "at", .value = .{ .uint = @intCast(@max(self.now, 0)) } },
            .{ .key = "tx", .value = .{ .cid = sub.cid } },
            .{ .key = "beef", .value = .{ .cid = beef } },
            .{ .key = "refs", .value = try admitsRef(a, sub.cid) },
        }) });
        try self.map("applied").putLink(try cat(a, &.{ tp, &sub.txid }), applied);
        try records.append(a, applied);
        return .{ .outputs_to_admit = sorted, .coins_to_retain = retained, .coins_removed = removed.items, .records = records.items };
    }

    /// The chain app answered `rejected` for `txid`: each of `topics` that judged it loses the
    /// judgement and the outputs it admitted. → the judgements removed (their lookup services are told).
    /// The view (0.12.0): the outputs it admitted (those still counted) out, then the coins it
    /// consumed back in (those still admitted and consumed by no other judgement of the topic).
    pub fn unapply(self: *State, topics: []const []const u8, txid: [32]u8) ![]Unapplied {
        const a = self.arena;
        var out: std.ArrayList(Unapplied) = .empty;
        for (topics) |t| {
            const tp = try topicPrefix(a, t);
            const key = try cat(a, &.{ tp, &txid });
            const rc = (try self.map("applied").link(key)) orelse continue;
            var v = try self.touchView(t);
            for (try self.map("admitted").prefixed(key)) |kv| {
                const o = try store_mod.outpointOf(kv.key[tp.len..]);
                if (try self.counted(t, o.txid, o.vout)) v.fold(o.txid, o.vout, false);
            }
            _ = try self.map("applied").remove(key);
            for (try self.map("admitted").prefixed(key)) |kv| _ = try self.map("admitted").remove(kv.key);
            const rec = try self.record(rc);
            const raw = self.store.get(a, rec.getCid("tx") orelse return error.BadRecord) catch return error.BadRecord;
            const tx = Transaction.parse(a, raw) catch return error.BadRecord;
            for ([_][]const u8{ "coinsToRetain", "coinsRemoved" }) |field| for (rec.getArray(field) orelse &.{}) |x| {
                if (x != .uint or x.uint >= tx.inputs.len) return error.BadRecord;
                const po = tx.inputs[@intCast(x.uint)].previous_outpoint;
                if (try self.counted(t, po.txid.bytes, po.index)) v.fold(po.txid.bytes, po.index, true);
            };
            try self.putView(t, v);
            try out.append(a, .{ .topic = t, .txid = txid });
        }
        return out.items;
    }

    // ------------------------------------------------------------ the view digest (0.12.0)

    /// The topic's view as the state holds it (never touched: empty).
    pub fn view(self: *State, t: []const u8) !View {
        const v = (try self.map("views").get(try topicPrefix(self.arena, t))) orelse return .{};
        return View.parse(if (v == .bytes) v.bytes else return error.BadIndex);
    }

    fn putView(self: *State, t: []const u8, v: View) !void {
        const b = v.bytes();
        try self.map("views").put(try topicPrefix(self.arena, t), .{ .bytes = try self.arena.dupe(u8, &b) });
    }

    /// The topic's view, noted in the step's journal (its value before the step's first touch).
    fn touchView(self: *State, t: []const u8) !View {
        const v = try self.view(t);
        for (self.view_log.items) |x| if (std.mem.eql(u8, x.topic, t)) return v;
        try self.view_log.append(self.arena, .{ .topic = try self.arena.dupe(u8, t), .before = v });
        return v;
    }

    /// Whether the output is in the topic's view: admitted under it, and consumed by no transaction
    /// the topic has a judgement of (its `applied`).
    fn counted(self: *State, t: []const u8, txid: [32]u8, vout: u32) !bool {
        const a = self.arena;
        const tp = try topicPrefix(a, t);
        const op = store_mod.outpointKey(txid, vout);
        if (!(try self.map("admitted").has(try cat(a, &.{ tp, &op })))) return false;
        for (try self.ch.spendersOf(op)) |sp| if (try self.map("applied").has(try cat(a, &.{ tp, &sp }))) return false;
        return true;
    }

    /// The topics whose view this step changed (before ≠ now), in the order first touched.
    pub fn viewChanges(self: *State) ![]ViewChange {
        var out: std.ArrayList(ViewChange) = .empty;
        for (self.view_log.items) |x| {
            const now = try self.view(x.topic);
            if (now.eql(x.before)) continue;
            try out.append(self.arena, .{ .topic = x.topic, .before = x.before, .now = now });
        }
        return out.items;
    }

    /// Who spent an admitted output, as the topic sees it: the chain's `spent` (the first held
    /// spender not rejected) joined to the topic's judgement of that spender (whether it retained
    /// the coin). Null while it is unspent (or not admitted).
    pub fn spender(self: *State, t: []const u8, txid: [32]u8, vout: u32) !?struct { txid: [32]u8, retained: bool, judged: bool } {
        const a = self.arena;
        const tp = try topicPrefix(a, t);
        const op = store_mod.outpointKey(txid, vout);
        if (!(try self.map("admitted").has(try cat(a, &.{ tp, &op })))) return null;
        const sp = (try self.ch.spentBy(txid, vout)) orelse return null;
        const rc = (try self.map("applied").link(try cat(a, &.{ tp, &sp }))) orelse return .{ .txid = sp, .retained = false, .judged = false };
        const raw = (try self.ch.txRaw(sp)) orelse return error.BadRecord;
        const tx = try Transaction.parse(a, raw);
        var retained = false;
        for ((try self.record(rc)).getArray("coinsToRetain") orelse &.{}) |x| {
            if (x != .uint or x.uint >= tx.inputs.len) continue;
            const in = tx.inputs[@intCast(x.uint)];
            retained = retained or std.mem.eql(u8, &store_mod.outpointKey(in.previous_outpoint.txid.bytes, in.previous_outpoint.index), &op);
        }
        return .{ .txid = sp, .retained = retained, .judged = true };
    }

    /// An admitted output as a lookup sees it.
    pub const Admitted = struct { topic: []const u8, txid: [32]u8, vout: u32, spent: bool, record: Value };

    /// The outputs admitted into a topic: the unspent ones (the chain's `spent` names no spender),
    /// and the spent ones too with `include_spent`, each group in outpoint order.
    pub fn inTopic(self: *State, t: []const u8, include_spent: bool) ![]Admitted {
        const a = self.arena;
        const tp = try topicPrefix(a, t);
        var unspent: std.ArrayList(Admitted) = .empty;
        var spent: std.ArrayList(Admitted) = .empty;
        for (try self.map("admitted").prefixed(tp)) |kv| {
            const o = try store_mod.outpointOf(kv.key[tp.len..]);
            const is_spent = (try self.ch.spentBy(o.txid, o.vout)) != null;
            if (is_spent and !include_spent) continue;
            const rec = try self.record(if (kv.value == .cid) kv.value.cid else return error.BadIndex);
            try (if (is_spent) &spent else &unspent).append(a, .{ .topic = t, .txid = o.txid, .vout = o.vout, .spent = is_spent, .record = rec });
        }
        try unspent.appendSlice(a, spent.items);
        return unspent.items;
    }
};

fn admitsRef(a: Allocator, tx_cid: []const u8) !Value {
    const refs = try a.alloc(Value, 1);
    refs[0] = .{ .map = try a.dupe(cbor.Entry, &.{
        .{ .key = "to", .value = .{ .cid = tx_cid } },
        .{ .key = "rel", .value = .{ .text = "admits" } },
    }) };
    return .{ .array = refs };
}

/// Check a topic's instructions against the transaction: output indices in
/// range and distinct, retained coins among the previous coins.
pub fn check(tx: Transaction, previous: []const u32, ins: Instructions) !void {
    for (ins.outputs_to_admit, 0..) |o, i| {
        if (o >= tx.outputs.len) return error.BadInstructions;
        if (contains(ins.outputs_to_admit[0..i], o)) return error.BadInstructions;
    }
    for (ins.coins_to_retain, 0..) |x, i| {
        if (!contains(previous, x)) return error.BadInstructions;
        if (contains(ins.coins_to_retain[0..i], x)) return error.BadInstructions;
    }
}

/// Whether a topic's instructions take anything: an output admitted, or a
/// previous coin consumed (retained or removed). One that takes nothing
/// records nothing.
pub fn takes(previous: []const u32, ins: Instructions) bool {
    return ins.outputs_to_admit.len > 0 or previous.len > 0;
}

// ---------------------------------------------------------------- a submission's BEEF, decoded once (#50)

/// Whether the BUMP flags this txid as a transaction (not just a sibling hash).
fn flagged(p: merkle.MerklePath, txid: [32]u8) bool {
    if (p.path.len == 0) return false;
    for (p.path[0]) |leaf| if (leaf.hash) |h| if (std.mem.eql(u8, &h.bytes, &txid)) return leaf.txid orelse false;
    return false;
}

/// Decode a submitted BEEF (V1, V2 or Atomic: the subject is the Atomic
/// BEEF's, else the last transaction) into records, parsing it once (#50):
/// each transaction put as its `bitcoin-tx` block, each BUMP as the merkle
/// nodes it reveals. Nothing is kept here: in a front-door call the blocks
/// live in the call's overlay. Structure is checked (parents first, a BUMP
/// that names a transaction holds it); the chain and the scripts are
/// `verifyDecoded`'s.
pub fn decode(a: Allocator, s: Store, bytes: []const u8) !Decoded {
    const b = beef_mod.parse(a, bytes) catch return error.InvalidBeef;
    const subject = b.subject() orelse return error.InvalidBeef;
    const entry = b.find(subject) orelse return error.InvalidBeef;
    if (entry.raw == null) return error.InvalidBeef; // a txid-only subject
    if (!beef_mod.parentsFirst(b)) return error.NotParentsFirst;

    var bumps: std.ArrayList(Bump) = .empty;
    var nodes: std.ArrayList(merkle.Node) = .empty;
    const bump_of = try a.alloc(?usize, b.bumps.len);
    for (b.bumps, bump_of) |p, *bi| {
        bi.* = null;
        if (p.path.len == 0) return error.RootMismatch;
        var relevant = false;
        for (p.path[0]) |leaf| {
            const h = leaf.hash orelse continue;
            relevant = relevant or (leaf.txid orelse false) or b.find(h.bytes) != null;
        }
        if (!relevant) continue;
        const rev = merkle.reveal(a, p) catch return error.RootMismatch;
        outer: for (rev.nodes) |n| {
            for (nodes.items) |m| if (std.mem.eql(u8, &m.hash, &n.hash)) continue :outer;
            try nodes.append(a, n);
        }
        bi.* = bumps.items.len;
        try bumps.append(a, .{ .height = p.block_height, .root = rev.root });
    }
    for (nodes.items) |n| try s.putBlock(&merkle.nodeCid(n.hash), &n.bytes);

    var txs: std.ArrayList(DecodedTx) = .empty;
    var proven: std.ArrayList(Proven) = .empty;
    var txid_only: std.ArrayList([32]u8) = .empty;
    for (b.entries) |e| {
        switch (e.format) {
            .txid_only => {
                try txid_only.append(a, e.txid);
                continue;
            },
            .raw_with_bump => {
                const i = e.bump.?;
                if (!beef_mod.bumpHas(b.bumps[i], e.txid)) return error.NotInBump;
                const pos = merkle.positionIn(b.bumps[i], e.txid) orelse return error.NotInBump;
                try proven.append(a, .{ .txid = e.txid, .height = bumps.items[bump_of[i].?].height, .pos = pos });
            },
            .raw => for (b.bumps, bump_of) |p, bi| {
                const i = bi orelse continue;
                if (!flagged(p, e.txid)) continue;
                const pos = merkle.positionIn(p, e.txid) orelse return error.NotInBump;
                try proven.append(a, .{ .txid = e.txid, .height = bumps.items[i].height, .pos = pos });
                break;
            },
        }
        const raw = e.raw.?;
        try s.putBlock(&store_mod.hashCid(.tx, e.txid), raw);
        try txs.append(a, .{ .txid = e.txid, .raw = raw });
    }
    return .{ .subject = subject, .txs = txs.items, .nodes = nodes.items, .bumps = bumps.items, .proven = proven.items, .txid_only = txid_only.items };
}

/// A submission the kernel's door decoded (shruggr/skein#121, #146): its envelope `{form, beef:
/// <pointer record>, subject?, vout?}` and the pointer record it names, read. The transactions are
/// blocks in the store already; every BUMP was checked against the chain state's headers at the
/// door, so `proven` names the transactions its BUMPs prove (the record's `proves`) and nothing is
/// proven again (`verifyDecoded`'s `door`). The subject is the envelope's (an Atomic, Outpoint or
/// Subject BEEF), else the record's last transaction (skein-sdk `record.subjectOf`). A txid-only
/// subject is refused.
pub fn decodeRecord(a: Allocator, s: Store, envelope: Value) !Decoded {
    const env = c.record.envelopeOf(envelope) orelse return error.InvalidBeef;
    const rec = s.getValue(a, env.beef) catch return error.InvalidBeef;
    if (!c.record.isRecord(rec)) return error.InvalidBeef;
    const subject = c.record.subjectOf(env, rec) orelse return error.InvalidBeef;
    const tv = rec.getArray("txs") orelse return error.InvalidBeef;
    const marks = rec.getArray("marks") orelse return error.InvalidBeef;
    if (marks.len != tv.len) return error.InvalidBeef;
    const by = c.record.provenBy(a, rec) catch return error.InvalidBeef;
    const bv = rec.getArray("bumps") orelse &.{};
    var txs: std.ArrayList(DecodedTx) = .empty;
    var proven: std.ArrayList(Proven) = .empty;
    var txid_only: std.ArrayList([32]u8) = .empty;
    var has_subject = false;
    for (tv, marks, by) |t, m, p| {
        const tc = if (t == .cid) t.cid else return error.InvalidBeef;
        const txid = store_mod.bitcoinHash(tc) orelse return error.InvalidBeef;
        if (m == .text) {
            try txid_only.append(a, txid);
            continue;
        }
        const raw = s.get(a, tc) catch return error.InvalidBeef;
        try txs.append(a, .{ .txid = txid, .raw = raw });
        has_subject = has_subject or std.mem.eql(u8, &txid, &subject);
        if (p) |i| try proven.append(a, .{ .txid = txid, .height = @intCast(bv[i].getUint("height") orelse return error.InvalidBeef), .pos = .{ .depth = 0, .offset = 0 } });
    }
    if (!has_subject) return error.InvalidBeef; // a txid-only subject
    return .{ .subject = subject, .txs = txs.items, .nodes = &.{}, .bumps = &.{}, .proven = proven.items, .txid_only = txid_only.items };
}

fn provenAt(d: Decoded, txid: [32]u8) ?u32 {
    for (d.proven) |p| if (std.mem.eql(u8, &p.txid, &txid)) return p.height;
    return null;
}

fn rootAtHeight(d: Decoded, height: u32) ?[32]u8 {
    for (d.bumps) |b| if (b.height == height) return b.root;
    return null;
}

/// The parents a submission lacks (skein-overlay#1): for every transaction its BUMPs do not prove,
/// each input's source that is neither a transaction decoded before it nor held by the chain app;
/// and each txid-only entry the chain app does not hold. Each once, in BEEF order. Every input
/// counts, not only those spending outputs live in a topic: an input whose source is missing cannot
/// have its script verified, and the chain app's ingest refuses the BEEF (`MissingInput`) — and an
/// output live in a topic is always held (it was admitted on the chain app's answer).
pub fn missingParents(a: Allocator, ch: *Chain, d: Decoded) ![][32]u8 {
    var out: std.ArrayList([32]u8) = .empty;
    const add = struct {
        fn f(al: Allocator, o: *std.ArrayList([32]u8), t: [32]u8) !void {
            for (o.items) |x| if (std.mem.eql(u8, &x, &t)) return;
            try o.append(al, t);
        }
    }.f;
    for (d.txid_only) |t| if (!(try ch.holds(t))) try add(a, &out, t);
    for (d.txs, 0..) |t, i| {
        if (provenAt(d, t.txid) != null) continue;
        const tx = Transaction.parse(a, t.raw) catch return error.InvalidBeef;
        for (tx.inputs) |in| {
            const src = in.previous_outpoint.txid.bytes;
            const earlier = for (d.txs[0..i]) |x| {
                if (std.mem.eql(u8, &x.txid, &src)) break true;
            } else false;
            if (earlier or try ch.holds(src)) continue;
            try add(a, &out, src);
        }
    }
    return out.items;
}

/// SPV over the decoded records (#50), against the chain state's headers (read only): every BUMP's
/// root is our header's at its height (an unknown height is refused) and each proven transaction is
/// reached from it through the merkle nodes; every other transaction's inputs come from a
/// transaction decoded before it or held by the chain app, read through `get`, with their scripts
/// verified; a txid-only entry names a transaction the chain holds. A subject the chain has
/// rejected, or spending an output a proven transaction spends, is refused. → the subject.
/// `door`: the kernel's door proved the BUMPs (shruggr/skein#121: a pointer record, `decodeRecord`):
/// they are not proven again.
pub fn verifyDecoded(a: Allocator, s: Store, ch: *Chain, d: Decoded, door: bool) !Subject {
    if (!door) {
        for (d.bumps) |b| {
            const want = (try ch.chain().rootAt(b.height)) orelse return error.UnknownHeader;
            if (!std.mem.eql(u8, &want, &b.root)) return error.RootMismatch;
        }
        for (d.proven) |p| {
            const root = rootAtHeight(d, p.height) orelse return error.NotInBump;
            if ((try merkle.pathFor(a, s, root, p.height, p.txid, p.pos)) == null) return error.NotInBump;
        }
    }
    for (d.txid_only) |t| if ((try ch.txRaw(t)) == null) return error.UnknownTxidOnly;
    for (d.txs, 0..) |t, i| {
        if (provenAt(d, t.txid) != null) continue;
        const sub = try subjectOf(a, s, t.txid);
        for (sub.tx.inputs, 0..) |in, k| {
            const src_txid = in.previous_outpoint.txid.bytes;
            const earlier = for (d.txs[0..i]) |x| {
                if (std.mem.eql(u8, &x.txid, &src_txid)) break true;
            } else false;
            if (!earlier and !(try ch.holds(src_txid))) return error.MissingInput;
            const src = try subjectOf(a, s, src_txid);
            if (in.previous_outpoint.index >= src.tx.outputs.len) return error.MissingInput;
            const ok = bsvz.script.interpreter.verifyPrevout(.{
                .allocator = a,
                .tx = &sub.tx,
                .input_index = k,
                .previous_output = src.tx.outputs[in.previous_outpoint.index],
                .unlocking_script = in.unlocking_script,
            }) catch false;
            if (!ok) return error.ScriptFailed;
        }
    }
    const subject = try subjectOf(a, s, d.subject);
    if (try ch.map("rejected").has(&d.subject)) return error.TransactionRejected;
    for (subject.tx.inputs) |in| {
        const op = store_mod.outpointKey(in.previous_outpoint.txid.bytes, in.previous_outpoint.index);
        for (try ch.spendersOf(op)) |other| {
            if (std.mem.eql(u8, &other, &d.subject)) continue;
            if ((try ch.status(other)) == .proven) return error.DoubleSpend;
        }
    }
    return subject;
}

// ---------------------------------------------------------------- a submission's bytes, kept

/// The bytes of a BEEF that came as bytes (no pointer record: a body framed with off-chain values,
/// a host with no door), put as a raw block (CIDv1 raw, sha2-256) → its CID: what the `applied`
/// records name.
pub fn putRaw(a: Allocator, s: Store, bytes: []const u8) ![]const u8 {
    var cid: [36]u8 = .{ 0x01, 0x55, 0x12, 0x20 } ++ @as([32]u8, undefined);
    std.crypto.hash.sha2.Sha256.hash(bytes, cid[4..36], .{});
    const out = try a.dupe(u8, &cid);
    try s.putBlock(out, bytes);
    return out;
}

/// The Atomic BEEF (V2) of one transaction a submission's BEEF carries (skein-overlay#1: each
/// transaction judged before the subject is ingested on its own, so the chain app answers for it):
/// the transaction and its ancestors in that BEEF, in its order, back to the ones its BUMPs prove
/// (and txid-only entries); the BUMPs those name. Nothing is added that the BEEF did not carry.
pub fn atomicFor(a: Allocator, bytes: []const u8, txid: [32]u8) ![]const u8 {
    const b = beef_mod.parse(a, bytes) catch return error.InvalidBeef;
    const keep = try a.alloc(bool, b.entries.len);
    @memset(keep, false);
    const at = b.indexOf(txid) orelse return error.InvalidBeef;
    keep[at] = true;
    var i = at + 1;
    while (i > 0) {
        i -= 1;
        if (!keep[i]) continue;
        const e = b.entries[i];
        if (e.format != .raw) continue; // proven by its BUMP, or txid-only: no further
        if (provedIn(b, e.txid) != null) continue;
        for ((e.tx orelse return error.InvalidBeef).inputs) |in| {
            if (b.indexOf(in.previous_outpoint.txid.bytes)) |j| keep[j] = true;
        }
    }
    var bumps: std.ArrayList(bsvz.spv.MerklePath) = .empty;
    const remap = try a.alloc(?usize, b.bumps.len);
    @memset(remap, null);
    var entries: std.ArrayList(beef_mod.Entry) = .empty;
    for (b.entries, keep) |e, k| {
        if (!k) continue;
        var out = e;
        const bi = e.bump orelse provedIn(b, e.txid);
        if (bi) |x| {
            if (remap[x] == null) {
                remap[x] = bumps.items.len;
                try bumps.append(a, b.bumps[x]);
            }
            if (e.bump != null) out.bump = remap[x];
        }
        try entries.append(a, out);
    }
    return beef_mod.serialize(a, .{ .version = beef_mod.V2, .atomic = txid, .bumps = bumps.items, .entries = entries.items });
}

/// The BUMP of a BEEF that flags this txid as a transaction, if any.
fn provedIn(b: beef_mod.Beef, txid: [32]u8) ?usize {
    for (b.bumps, 0..) |p, i| if (flagged(p, txid)) return i;
    return null;
}

// ---------------------------------------------------------------- BEEF out (a lookup's answer), from the chain state

/// The Atomic BEEF of a transaction the chain holds: its ancestry back to proven transactions.
pub fn beefFor(ch: *Chain, txid: [32]u8) ![]const u8 {
    return (try ch.beefOf(txid)) orelse error.UnknownTransaction;
}

/// One BEEF (V2, not atomic) of several transactions the chain holds, with their ancestry back to
/// proven ones: an aggregated lookup answer's.
pub fn beefOfMany(ch: *Chain, txids: []const [32]u8) ![]const u8 {
    var acc = BeefAcc{ .ch = ch };
    for (txids) |t| try acc.visit(t);
    acc.flagLeaves();
    return beef_mod.serialize(ch.arena, .{ .version = beef_mod.V2, .bumps = acc.bumps.items, .entries = acc.entries.items });
}

const BeefAcc = struct {
    ch: *Chain,
    entries: std.ArrayList(beef_mod.Entry) = .empty,
    bumps: std.ArrayList(bsvz.spv.MerklePath) = .empty,

    fn visit(acc: *BeefAcc, txid: [32]u8) anyerror!void {
        const a = acc.ch.arena;
        for (acc.entries.items) |e| if (std.mem.eql(u8, &e.txid, &txid)) return;
        const raw = (try acc.ch.txRaw(txid)) orelse return error.MissingAncestor;
        const tx = try Transaction.parse(a, raw);
        if ((try acc.ch.status(txid)) == .proven) {
            const p = (try acc.ch.proofFor(txid)) orelse return error.MissingProof;
            const idx = for (acc.bumps.items, 0..) |*b, i| {
                if (b.block_height != p.block_height) continue;
                b.combine(&p, a) catch continue;
                break i;
            } else blk: {
                try acc.bumps.append(a, p);
                break :blk acc.bumps.items.len - 1;
            };
            try acc.entries.append(a, .{ .txid = txid, .format = .raw_with_bump, .bump = idx, .raw = raw, .tx = tx });
            return;
        }
        for (tx.inputs) |in| try acc.visit(in.previous_outpoint.txid.bytes);
        try acc.entries.append(a, .{ .txid = txid, .format = .raw, .raw = raw, .tx = tx });
    }

    fn flagLeaves(acc: *BeefAcc) void {
        for (acc.entries.items) |e| {
            const bi = e.bump orelse continue;
            for (acc.bumps.items[bi].path[0]) |*l| if (l.hash) |h| if (std.mem.eql(u8, &h.bytes, &e.txid)) {
                l.txid = true;
            };
        }
    }
};
