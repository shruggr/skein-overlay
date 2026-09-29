//! The overlay's submission flow natively (#36, #50), as the engine runs it:
//! the route's half over an in-memory overlay (the front-door call: dropped
//! afterwards), the step's half over the store, the tm_demo topic and the
//! ls_demo lookup service called through a dispatch table in place of the
//! VM's `call`. Checked: the BEEF is parsed once per submit; a refused
//! submit leaves the store as it was; an admitted one persists exactly the
//! decoded blocks, the judgement and the service's map; ls_demo answers from
//! its own map (by topic, by script hash, by outpoint) with BEEF that
//! verifies; a spend reaches it through `spent`, a rejection through `rejected`.
const std = @import("std");
const w = @import("wallet");
const topic = @import("src/topic.zig");
const lookup = @import("src/lookup.zig");
const demo = @import("src/topic_demo.zig");
const ls = @import("src/lookup_demo.zig");
const submit = @import("src/submit.zig");

const bsvz = w.bsvz;
const beef = w.beef;
const hdr = w.header;
const cbor = w.cbor;
const Value = cbor.Value;
const Store = w.store.Store;
const Allocator = std.mem.Allocator;

fn mine(prev: [32]u8, root: [32]u8, time: u32) [80]u8 {
    var h = hdr.Header{ .version = 1, .prev_hash = prev, .merkle_root = root, .time = time, .bits = 0x207fffff, .nonce = 0 };
    while (true) : (h.nonce += 1) {
        const raw = h.serialize();
        if (hdr.powOk(&raw)) return raw;
    }
}

fn soloPath(a: Allocator, height: u32, txid: [32]u8) ![]const u8 {
    var path: std.ArrayList(u8) = .empty;
    try path.appendSlice(a, &.{ @intCast(height), 0x01, 0x01, 0x00, 0x02 });
    try path.appendSlice(a, &txid);
    return path.items;
}

const Spent = struct { tx: bsvz.transaction.Transaction, raw: []const u8, txid: [32]u8 };

fn spend(a: Allocator, src: *const bsvz.transaction.Transaction, vout: u32, outs: []const struct { u64, []const u8 }, priv: [32]u8) !Spent {
    var b = bsvz.transaction.Builder.init(a);
    try b.addInputFromTx(src, vout);
    for (outs) |o| try b.addOutput(.{ .satoshis = @intCast(o[0]), .locking_script = bsvz.script.Script.init(try a.dupe(u8, o[1])) });
    var tx = try b.build();
    const prev = src.outputs[vout];
    const sp = bsvz.transaction.templates.p2pkh_spend;
    const u = try sp.signAndBuildUnlockingScript(a, &tx, 0, prev.locking_script, prev.satoshis, try bsvz.crypto.PrivateKey.fromBytes(priv), sp.default_scope);
    @constCast(tx.inputs)[0].unlocking_script = u;
    const raw = try tx.serialize(a);
    return .{ .tx = tx, .raw = raw, .txid = beef.txidOf(raw) };
}

fn atomic(a: Allocator, t: Spent) ![]const u8 {
    const e = try a.dupe(beef.Entry, &.{.{ .txid = t.txid, .format = .raw, .raw = t.raw, .tx = t.tx }});
    return beef.serialize(a, .{ .version = beef.V2, .atomic = t.txid, .bumps = &.{}, .entries = e });
}

/// The front-door call's world: reads fall through to the store; what is put stays here.
const Overlay = struct {
    inner: Store,
    blocks: std.StringHashMapUnmanaged([]const u8) = .empty,
    arena: Allocator,

    fn store(self: *Overlay) Store {
        return .{ .ptr = self, .getFn = get, .putFn = put, .putBlockFn = putBlock, .keepFn = keep, .edgesFn = edges };
    }
    fn get(ptr: *anyopaque, a: Allocator, cid: []const u8) anyerror![]const u8 {
        const self: *Overlay = @ptrCast(@alignCast(ptr));
        if (self.blocks.get(cid)) |b| return a.dupe(u8, b);
        return self.inner.get(a, cid);
    }
    fn put(ptr: *anyopaque, a: Allocator, bytes: []const u8) anyerror![]const u8 {
        const self: *Overlay = @ptrCast(@alignCast(ptr));
        const canon = try cbor.encode(self.arena, try cbor.decode(self.arena, bytes));
        const cid = cbor.cidOf(canon);
        try self.blocks.put(self.arena, try self.arena.dupe(u8, &cid), canon);
        return a.dupe(u8, &cid);
    }
    fn putBlock(ptr: *anyopaque, cid: []const u8, bytes: []const u8) anyerror!void {
        const self: *Overlay = @ptrCast(@alignCast(ptr));
        if (w.store.bitcoinHash(cid)) |h| if (!std.mem.eql(u8, &h, &w.store.dblSha256(bytes))) return error.HashMismatch;
        try self.blocks.put(self.arena, try self.arena.dupe(u8, cid), try self.arena.dupe(u8, bytes));
    }
    fn keep(_: *anyopaque, _: []const u8) anyerror!void {
        return error.ReadOnly; // a call keeps nothing
    }
    fn edges(ptr: *anyopaque, a: Allocator, to: []const u8, rel: ?[]const u8) anyerror![]const w.store.Edge {
        const self: *Overlay = @ptrCast(@alignCast(ptr));
        return self.inner.edges(a, to, rel); // a call reads the index only
    }
};

/// An instance, natively: the store, the heads `wallet` and `ls:ls_demo`, the
/// genesis config, and the programs behind the `call`s.
const Instance = struct {
    a: Allocator,
    ms: *w.store.MemStore,
    /// The store programs see now: the call's overlay during a route, the store in a step.
    current: Store,
    wallet: ?[]const u8 = null,
    ls_state: ?[]const u8 = null,
    in: Value,
    now: i64 = 1000,
    topic_prog: []const u8,
    lookup_prog: []const u8,
    /// Calls made, by fn.
    calls: std.StringHashMapUnmanaged(usize) = .empty,

    fn init(a: Allocator, ms: *w.store.MemStore) !Instance {
        const tp = try a.dupe(u8, &cbor.cidOf("topic-demo"));
        const lp = try a.dupe(u8, &cbor.cidOf("lookup-demo"));
        const in: Value = .{ .map = try a.dupe(cbor.Entry, &.{
            .{ .key = "defaults", .value = .{ .map = try a.dupe(cbor.Entry, &.{
                .{ .key = "walletNetwork", .value = .{ .text = "regtest" } },
                .{ .key = "overlayTopics", .value = .{ .text = "{\"tm_demo\":\"topic-demo\"}" } },
                .{ .key = "overlayLookups", .value = .{ .text = "{\"ls_demo\":{\"program\":\"lookup-demo\",\"topics\":[\"tm_demo\"]}}" } },
            }) } },
            .{ .key = "programs", .value = .{ .map = try a.dupe(cbor.Entry, &.{
                .{ .key = "lookup-demo", .value = .{ .cid = lp } },
                .{ .key = "topic-demo", .value = .{ .cid = tp } },
            }) } },
        }) };
        return .{ .a = a, .ms = ms, .current = ms.store(), .in = in, .topic_prog = tp, .lookup_prog = lp };
    }

    fn callImpl(ctx: *anyopaque, a: Allocator, program: []const u8, func: []const u8, arg: Value) anyerror!Value {
        const self: *Instance = @ptrCast(@alignCast(ctx));
        const gop = try self.calls.getOrPut(self.a, try self.a.dupe(u8, func));
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* += 1;
        if (std.mem.eql(u8, program, self.topic_prog)) {
            if (!std.mem.eql(u8, func, "identify")) return error.UnknownFunction;
            return topic.judge(a, self.current, demo.identify, arg);
        }
        if (std.mem.eql(u8, program, self.lookup_prog)) {
            const h = try lookup.handle(a, ls.spec, self.current, .regtest, self.ls_state, self.wallet, func, arg);
            if (h.state) |c| self.ls_state = c;
            return h.answer;
        }
        return error.UnknownProgram;
    }
    fn caller(self: *Instance) w.overlay.Caller {
        return .{ .ctx = self, .callFn = callImpl };
    }
    fn count(self: *Instance, func: []const u8) usize {
        return self.calls.get(func) orelse 0;
    }

    /// A chain for the wallet state (headers only).
    fn headers(self: *Instance, raws: []const []const u8) !void {
        var wal = try w.wallet.Wallet.load(self.a, self.ms.store(), self.wallet, .regtest);
        _ = try wal.addHeaders(raws);
        self.wallet = try wal.save();
    }

    /// POST /submit's handler: a call over an overlay of its own, dropped afterwards.
    fn route(self: *Instance, bytes: []const u8) !submit.Routed {
        var ovl = Overlay{ .inner = self.ms.store(), .arena = self.a };
        self.current = ovl.store();
        defer self.current = self.ms.store();
        var wal = try w.wallet.Wallet.load(self.a, ovl.store(), self.wallet, .regtest);
        wal.now = self.now;
        return submit.route(self.a, self.caller(), &wal, self.in, bytes, &.{"tm_demo"}, null);
    }

    /// The engine stepped on the admitted entry.
    fn step(self: *Instance, ev: Value) !submit.Stepped {
        self.current = self.ms.store();
        var wal = try w.wallet.Wallet.load(self.a, self.ms.store(), self.wallet, .regtest);
        wal.now = self.now;
        const done = try submit.step(self.a, self.caller(), &wal, self.in, ev);
        self.wallet = try wal.save();
        return done;
    }

    /// Route then step, as the host does for an admitted submit.
    fn submitted(self: *Instance, bytes: []const u8) !submit.Stepped {
        const r = try self.route(bytes);
        if (r != .admit) {
            std.debug.print("not admitted: {any}\n", .{r});
            return error.NotAdmitted;
        }
        // The entry as the host puts it: a dag-cbor record, read back.
        return self.step(try cbor.decode(self.a, try cbor.encode(self.a, r.admit.event)));
    }

    /// A `status` entry: the chain feed's rejection, the removed judgements' services told.
    fn status(self: *Instance, txid: [32]u8, tx_status: []const u8) !void {
        self.current = self.ms.store();
        var wal = try w.wallet.Wallet.load(self.a, self.ms.store(), self.wallet, .regtest);
        wal.now = self.now;
        _ = try wal.applyStatus(txid, tx_status, null);
        try w.overlay.hookRejected(self.a, self.caller(), self.in, wal.unapplied.items);
        self.wallet = try wal.save();
    }

    /// A lookup (fn "lookup" of the service): the outputs as (txid, vout), and their BEEF.
    fn look(self: *Instance, fields: []const cbor.Entry) ![]const Value {
        const ans = try self.caller().call(self.a, self.lookup_prog, "lookup", .{ .map = try self.a.dupe(cbor.Entry, &.{
            .{ .key = "kind", .value = .{ .text = "lookup-call" } },
            .{ .key = "service", .value = .{ .text = "ls_demo" } },
            .{ .key = "query", .value = .{ .map = try self.a.dupe(cbor.Entry, fields) } },
        }) });
        try std.testing.expectEqualStrings("output-list", ans.getText("type").?);
        return ans.getArray("outputs").?;
    }

    /// Every block in the store, by CID.
    fn snapshot(self: *Instance) !std.StringHashMapUnmanaged([]const u8) {
        var out: std.StringHashMapUnmanaged([]const u8) = .empty;
        var it = self.ms.blocks.iterator();
        while (it.next()) |e| try out.put(self.a, try self.a.dupe(u8, e.key_ptr.*), try self.a.dupe(u8, e.value_ptr.*));
        return out;
    }
};

fn subjectOf(a: Allocator, v: Value) ![32]u8 {
    return (try beef.parse(a, v.getBytes("beef").?)).subject().?;
}

/// The dag-cbor blocks reachable from `roots` (links followed; bitcoin blocks counted, not walked).
fn reachable(a: Allocator, s: Store, roots: []const []const u8) !std.StringHashMapUnmanaged(void) {
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var queue: std.ArrayList([]const u8) = .empty;
    try queue.appendSlice(a, roots);
    while (queue.pop()) |c| {
        if (seen.contains(c)) continue;
        const bytes = s.tryGet(a, c) orelse continue;
        try seen.put(a, c, {});
        if (c.len < 2 or c[1] != 0x71) continue;
        try links(a, try cbor.decode(a, bytes), &queue);
    }
    return seen;
}

fn links(a: Allocator, v: Value, out: *std.ArrayList([]const u8)) !void {
    switch (v) {
        .cid => |c| try out.append(a, c),
        .array => |xs| for (xs) |x| try links(a, x, out),
        .map => |es| for (es) |e| try links(a, e.value, out),
        else => {},
    }
}

test "the submission flow: parse once, persist only on admission, a lookup service's own map through its hooks" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var ms = w.store.MemStore.init(std.testing.allocator);
    defer ms.deinit();
    var inst = try Instance.init(a, &ms);

    const priv: [32]u8 = .{0x42} ** 32;
    const pub_key = try w.brc29.identityKey(priv);
    const pkh = bsvz.crypto.hash.hash160(&pub_key).bytes;
    const p2pkh = w.brc29.p2pkh(pub_key);
    const token: [34]u8 = demo.tag.* ++ [_]u8{ 0x76, 0xa9, 0x14 } ++ pkh ++ [_]u8{ 0x88, 0xac };
    var token_hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&token, &token_hash, .{});

    // A funding transaction mined alone at height 1 of a regtest chain (root = its txid).
    var fund_raw: std.ArrayList(u8) = .empty;
    try fund_raw.appendSlice(a, &.{ 1, 0, 0, 0, 1 });
    try fund_raw.appendSlice(a, &(.{0x11} ** 32));
    try fund_raw.appendSlice(a, &.{ 0, 0, 0, 0, 1, 0x51, 0xff, 0xff, 0xff, 0xff, 2 });
    for ([_]u64{ 50_000, 20_000 }) |v| {
        var sats: [8]u8 = undefined;
        std.mem.writeInt(u64, &sats, v, .little);
        try fund_raw.appendSlice(a, &sats);
        try fund_raw.append(a, p2pkh.len);
        try fund_raw.appendSlice(a, &p2pkh);
    }
    try fund_raw.appendSlice(a, &.{ 0, 0, 0, 0 });
    const fund_tx = try bsvz.transaction.Transaction.parse(a, fund_raw.items);
    const fund_txid = beef.txidOf(fund_raw.items);
    const h1 = mine(hdr.hash(&w.chain.Network.regtest.genesis()), fund_txid, 1_700_000_600);
    try inst.headers(&.{&h1});
    const bump = try bsvz.spv.MerklePath.parse(a, try soloPath(a, 1, fund_txid));
    const fund_entry: beef.Entry = .{ .txid = fund_txid, .format = .raw_with_bump, .bump = 0, .raw = fund_raw.items, .tx = fund_tx };
    const bumps = try a.dupe(bsvz.spv.MerklePath, &.{bump});

    // ------------------------------------------------ refused: tm_demo takes nothing, nothing persists
    {
        const plain = try spend(a, &fund_tx, 1, &.{.{ 19_000, &p2pkh }}, priv);
        const bytes = try beef.serialize(a, .{ .version = beef.V2, .bumps = bumps, .entries = try a.dupe(beef.Entry, &.{ fund_entry, .{ .txid = plain.txid, .format = .raw, .raw = plain.raw, .tx = plain.tx } }) });
        const before = try inst.snapshot();
        const parses = beef.parses;
        const r = try inst.route(bytes);
        try std.testing.expect(r == .refused);
        try std.testing.expect(std.mem.startsWith(u8, r.refused, "NotAdmitted"));
        try std.testing.expectEqual(parses + 1, beef.parses);
        try std.testing.expectEqual(@as(usize, 1), inst.count("identify")); // the topic was asked, in the call
        // The store is as it was, block for block.
        try std.testing.expectEqual(before.count(), ms.count());
        var it = before.iterator();
        while (it.next()) |e| try std.testing.expectEqualSlices(u8, e.value_ptr.*, ms.blocks.get(e.key_ptr.*).?);
        // A BEEF that does not verify is refused the same way.
        const bad = try inst.route(&.{ 1, 2, 3 });
        try std.testing.expectEqualStrings("InvalidBeef", bad.refused);
        try std.testing.expectEqual(before.count(), ms.count());
    }

    // ------------------------------------------------ T1 admits a token: persisted exactly, the service told
    const t1 = try spend(a, &fund_tx, 0, &.{ .{ 1, &token }, .{ 49_000, &p2pkh } }, priv);
    const t1_beef = try beef.serialize(a, .{ .version = beef.V2, .bumps = bumps, .entries = try a.dupe(beef.Entry, &.{ fund_entry, .{ .txid = t1.txid, .format = .raw, .raw = t1.raw, .tx = t1.tx } }) });
    {
        const before = try inst.snapshot();
        const wallet_before = inst.wallet.?;
        const parses = beef.parses;
        const done = try inst.submitted(t1_beef);
        // Parsed once: the route decoded it; the topic, the step and the hooks read records.
        try std.testing.expectEqual(parses + 1, beef.parses);
        try std.testing.expectEqualSlices(u32, &.{0}, done.applied[0].outputs_to_admit);
        try std.testing.expectEqual(@as(usize, 1), inst.count("admitted"));
        try std.testing.expectEqual(@as(usize, 0), inst.count("spent"));
        // What the step persisted: the decoded blocks (the transactions; this BUMP reveals no node:
        // a one-transaction block), the judgement and admittance (reachable from the new wallet
        // state), the service's map (from its new state) — and nothing else.
        const decoded = [_][37]u8{ w.store.hashCid(.tx, fund_txid), w.store.hashCid(.tx, t1.txid) };
        const kept = try reachable(a, ms.store(), &.{ inst.wallet.?, inst.ls_state.? });
        var fresh: usize = 0;
        var it = ms.blocks.iterator();
        while (it.next()) |e| {
            if (before.contains(e.key_ptr.*)) continue;
            fresh += 1;
            const is_decoded = for (decoded) |d| {
                if (std.mem.eql(u8, &d, e.key_ptr.*)) break true;
            } else false;
            if (!is_decoded and !kept.contains(e.key_ptr.*)) {
                std.debug.print("unaccounted block {x}\n", .{e.key_ptr.*});
                return error.Unaccounted;
            }
        }
        for (decoded) |d| try std.testing.expect(ms.blocks.contains(&d) and !before.contains(&d));
        for (done.records) |r| try std.testing.expect(kept.contains(r) and !before.contains(r));
        try std.testing.expect(fresh > done.records.len + decoded.len);
        try std.testing.expect(!std.mem.eql(u8, wallet_before, inst.wallet.?));
        // The funding's proof is recorded from the header (its block's root is its txid).
        var wal = try w.wallet.Wallet.load(a, ms.store(), inst.wallet, .regtest);
        try std.testing.expectEqual(w.wallet.Status.proven, try wal.status(fund_txid));
        // A dupe: nothing new, nothing called.
        const calls = inst.count("identify");
        try std.testing.expect((try inst.route(t1_beef)) == .unchanged);
        try std.testing.expectEqual(calls, inst.count("identify"));
    }

    // ------------------------------------------------ ls_demo answers from its own map
    {
        const by_topic = try inst.look(&.{.{ .key = "topic", .value = .{ .text = "tm_demo" } }});
        try std.testing.expectEqual(@as(usize, 1), by_topic.len);
        try std.testing.expectEqualSlices(u8, &t1.txid, &(try subjectOf(a, by_topic[0])));
        try std.testing.expectEqual(@as(u64, 0), by_topic[0].getUint("outputIndex").?);
        // Its BEEF verifies against a node that holds only the headers.
        var headers_only = w.store.MemStore.init(std.testing.allocator);
        defer headers_only.deinit();
        var hw = try w.wallet.Wallet.load(a, headers_only.store(), null, .regtest);
        _ = try hw.addHeaders(&.{&h1});
        var ctx = w.wallet.Wallet.SpvCtx{ .w = &hw };
        _ = try w.spv.verify(a, try beef.parse(a, by_topic[0].getBytes("beef").?), .{ .ptr = &ctx, .rootAtFn = w.wallet.Wallet.SpvCtx.rootAt, .knownRawFn = w.wallet.Wallet.SpvCtx.knownRaw });
        const by_script = try inst.look(&.{.{ .key = "scriptHash", .value = .{ .text = &std.fmt.bytesToHex(token_hash, .lower) } }});
        try std.testing.expectEqual(@as(usize, 1), by_script.len);
        const by_op = try inst.look(&.{
            .{ .key = "topic", .value = .{ .text = "tm_demo" } },
            .{ .key = "txid", .value = .{ .text = &hdr.toHex(t1.txid) } },
            .{ .key = "outputIndex", .value = .{ .uint = 1 } },
        });
        try std.testing.expectEqual(@as(usize, 0), by_op.len); // the change was not admitted
        // The shared wallet maps no longer index by script (#50): the service does.
        for (w.wallet.map_names) |n| try std.testing.expect(!std.mem.eql(u8, n, "byScript"));
    }

    // ------------------------------------------------ T2 spends the token into a new one: `spent`
    const t2 = try spend(a, &t1.tx, 0, &.{.{ 1, &token }}, priv);
    {
        inst.now = 2000;
        const done = try inst.submitted(try atomic(a, t2));
        try std.testing.expectEqualSlices(u32, &.{0}, done.applied[0].coins_to_retain);
        try std.testing.expectEqual(@as(usize, 1), inst.count("spent"));
        const live = try inst.look(&.{.{ .key = "topic", .value = .{ .text = "tm_demo" } }});
        try std.testing.expectEqual(@as(usize, 1), live.len);
        try std.testing.expectEqualSlices(u8, &t2.txid, &(try subjectOf(a, live[0])));
        const all = try inst.look(&.{ .{ .key = "topic", .value = .{ .text = "tm_demo" } }, .{ .key = "includeSpent", .value = .{ .boolean = true } } });
        try std.testing.expectEqual(@as(usize, 2), all.len);
        const by_script = try inst.look(&.{.{ .key = "scriptHash", .value = .{ .text = &std.fmt.bytesToHex(token_hash, .lower) } }});
        try std.testing.expectEqual(@as(usize, 1), by_script.len);
    }

    // ------------------------------------------------ T2 rejected (a status entry): `rejected`, T1's token live again
    {
        inst.now = 3000;
        try inst.status(t2.txid, "DOUBLE_SPEND_ATTEMPTED");
        try std.testing.expectEqual(@as(usize, 1), inst.count("rejected"));
        const live = try inst.look(&.{ .{ .key = "topic", .value = .{ .text = "tm_demo" } }, .{ .key = "includeSpent", .value = .{ .boolean = true } } });
        try std.testing.expectEqual(@as(usize, 1), live.len);
        try std.testing.expectEqualSlices(u8, &t1.txid, &(try subjectOf(a, live[0])));
        // Resubmitting it is refused.
        const r = try inst.route(try atomic(a, t2));
        try std.testing.expectEqualStrings("TransactionRejected", r.refused);
    }

    // ------------------------------------------------ T3 spends the token and admits none: the coin removed
    {
        inst.now = 4000;
        const t3 = try spend(a, &t1.tx, 0, &.{.{ 1, &p2pkh }}, priv);
        const done = try inst.submitted(try atomic(a, t3));
        try std.testing.expectEqual(@as(usize, 0), done.applied[0].outputs_to_admit.len);
        try std.testing.expectEqualSlices(u32, &.{0}, done.applied[0].coins_removed);
        try std.testing.expectEqual(@as(usize, 2), inst.count("spent"));
        try std.testing.expectEqual(@as(usize, 0), (try inst.look(&.{.{ .key = "topic", .value = .{ .text = "tm_demo" } }})).len);
        try std.testing.expectEqual(@as(usize, 1), (try inst.look(&.{ .{ .key = "topic", .value = .{ .text = "tm_demo" } }, .{ .key = "includeSpent", .value = .{ .boolean = true } } })).len);
    }
}

test "the topic contract: identify on a CID, reading records" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var ms = w.store.MemStore.init(std.testing.allocator);
    defer ms.deinit();
    const s = ms.store();
    try std.testing.expectError(error.BadArgs, topic.judge(a, s, demo.identify, .{ .map = &.{} }));
    const missing: Value = .{ .map = try a.dupe(cbor.Entry, &.{
        .{ .key = "kind", .value = .{ .text = "topic-call" } },
        .{ .key = "topic", .value = .{ .text = "tm_demo" } },
        .{ .key = "tx", .value = .{ .cid = try a.dupe(u8, &w.store.hashCid(.tx, .{0x5a} ** 32)) } },
    }) };
    try std.testing.expectError(error.UnknownTransaction, topic.judge(a, s, demo.identify, missing));
}
