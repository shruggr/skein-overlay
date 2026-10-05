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
//!   {kind: "overlay-state", maps: {admitted, applied, pending}}
//!
//! The maps (keys bytes, ordered bytewise; `tp` = len ‖ topic):
//!   admitted   tp ‖ txid ‖ vout → admittance record {kind: "admitted", topic, txid, vout, script, satoshis, admittedAt, tx, refs}
//!   applied    tp ‖ txid → applied record {kind: "applied", topic, txid, outputsToAdmit, coinsToRetain, coinsRemoved, at, tx, refs}
//!   pending    txid → {kind: "submission", txid, thread, ingest}   a submission the chain app has not yet
//!                                                                   answered with accepted or proven
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

pub const map_names = [_][]const u8{ "admitted", "applied", "pending" };

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

    /// A submission handed to the chain app (its ingest message) and not yet admitted: the thread
    /// carrying it (a resubmission's client waits on it, #66) and the message its answers name.
    pub fn putPending(self: *State, txid: [32]u8, thread: ?[]const u8, ingest: []const u8) !void {
        const a = self.arena;
        var fields: std.ArrayList(cbor.Entry) = .empty;
        try fields.appendSlice(a, &.{
            .{ .key = "kind", .value = .{ .text = "submission" } },
            .{ .key = "txid", .value = .{ .text = try a.dupe(u8, &hdr.toHex(txid)) } },
            .{ .key = "ingest", .value = .{ .cid = ingest } },
        });
        if (thread) |t| try fields.append(a, .{ .key = "thread", .value = .{ .cid = t } });
        try self.map("pending").putLink(&txid, try self.store.putValue(a, .{ .map = fields.items }));
    }

    pub fn pendingRecord(self: *State, txid: [32]u8) !?Value {
        const pc = (try self.map("pending").link(&txid)) orelse return null;
        return try self.record(pc);
    }

    pub fn isPending(self: *State, txid: [32]u8) !bool {
        return self.map("pending").has(&txid);
    }

    pub fn dropPending(self: *State, txid: [32]u8) !void {
        _ = try self.map("pending").remove(&txid);
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
        const a = self.arena;
        const tp = try topicPrefix(a, t);
        const self_txid = (try tx.txid(a)).bytes;
        var out: std.ArrayList(u32) = .empty;
        for (tx.inputs, 0..) |in, i| {
            const op = store_mod.outpointKey(in.previous_outpoint.txid.bytes, in.previous_outpoint.index);
            if (!(try self.map("admitted").has(try cat(a, &.{ tp, &op })))) continue;
            if (try self.spentByOther(op, self_txid)) continue;
            try out.append(a, @intCast(i));
        }
        return out.items;
    }

    /// Record a topic's judgement of a submission the chain app has (accepted or proven): each
    /// admitted output as an admittance record, the judgement in `applied`. `previous` is
    /// `previousCoins` for this topic, taken before any judgement of this step. A transaction the
    /// topic judged before is a dupe: nothing is written.
    pub fn apply(self: *State, sub: Subject, t: []const u8, previous: []const u32, ins: Instructions) !Applied {
        const a = self.arena;
        if (try self.isApplied(t, sub.txid)) return .{ .dupe = true };
        try check(sub.tx, previous, ins);
        var removed: std.ArrayList(u32) = .empty;
        for (previous) |p| if (!contains(ins.coins_to_retain, p)) try removed.append(a, p);
        if (!takes(previous, ins)) return .{};

        const tp = try topicPrefix(a, t);
        const txid_hex = try a.dupe(u8, &hdr.toHex(sub.txid));
        var records: std.ArrayList([]const u8) = .empty;
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
        }
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
            .{ .key = "refs", .value = try admitsRef(a, sub.cid) },
        }) });
        try self.map("applied").putLink(try cat(a, &.{ tp, &sub.txid }), applied);
        try records.append(a, applied);
        return .{ .outputs_to_admit = sorted, .coins_to_retain = retained, .coins_removed = removed.items, .records = records.items };
    }

    /// The chain app answered `rejected` for `txid`: each of `topics` that judged it loses the
    /// judgement and the outputs it admitted. → the judgements removed (their lookup services are told).
    pub fn unapply(self: *State, topics: []const []const u8, txid: [32]u8) ![]Unapplied {
        const a = self.arena;
        var out: std.ArrayList(Unapplied) = .empty;
        for (topics) |t| {
            const tp = try topicPrefix(a, t);
            const key = try cat(a, &.{ tp, &txid });
            if (!(try self.map("applied").remove(key))) continue;
            for (try self.map("admitted").prefixed(key)) |kv| _ = try self.map("admitted").remove(kv.key);
            try out.append(a, .{ .topic = t, .txid = txid });
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

/// A submission the kernel's door decoded (shruggr/skein#121): its pointer record, read. The
/// transactions are blocks in the store already; every BUMP was checked against the chain state's
/// headers at the door, so `proven` names the transactions its BUMPs prove (the record's `proves`)
/// and nothing is proven again (`verifyDecoded`'s `door`). A txid-only subject is refused.
pub fn decodeRecord(a: Allocator, s: Store, rc: []const u8) !Decoded {
    const rec = s.getValue(a, rc) catch return error.InvalidBeef;
    if (!c.record.isRecord(rec)) return error.InvalidBeef;
    const subject = c.record.subjectOf(rec) orelse return error.InvalidBeef;
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
