//! The overlay natively (#36, #50; re-split by skein #79), as the engine runs
//! it, with a chain state in memory standing in for the chain app
//! (shruggr/skein-chain: its headers, its `ingest`, the statuses and proofs
//! it records) and the answers it would send driven by hand. The route's
//! half runs over an in-memory write cache (in the VM, the front door's
//! step on the request, #68; dropped afterwards here), the threads' steps
//! over the store; the tm_demo topic and the ls_demo lookup service are
//! called through a dispatch table in place of the VM's `call`; the messages
//! to the instance itself (the ingest, the watch) and the gossip out are
//! recorded. Checked: the BEEF is parsed once per submit; a refused submit
//! leaves the store as it was; nothing is admitted until the chain app
//! answers accepted or proven (#73), the first of them, and a rejection
//! admits nothing; admitted on `accepted`, a watch hears the later proof
//! (`-proof`) or rejection (the judgements removed, `rejected` hooks);
//! ls_demo answers from its own map with BEEF that verifies; a spend reaches
//! it through `spent`, a rejection through `rejected`; the gossip shapes; a
//! peer's proof checked against the chain state; the configuration (the app
//! record at `<app>/app`, the genesis defaults without one).
const std = @import("std");
const c = @import("chain");
const topic = @import("topic");
const lookup = @import("lookup");
const demo = @import("src/topic_demo.zig");
const ls = @import("src/lookup_demo.zig");
const state = @import("src/state.zig");
const submit = @import("src/submit.zig");
const gossip = @import("src/gossip.zig");
const config = @import("src/config.zig");
const topics_mod = @import("src/topics.zig");
const calls = @import("src/calls.zig");

const bsvz = c.bsvz;
const beef = c.beef;
const hdr = c.header;
const cbor = c.cbor;
const Value = cbor.Value;
const Store = c.store.Store;
const Chain = c.state.State;
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

fn identityKey(priv: [32]u8) ![33]u8 {
    return (try (try bsvz.primitives.ec.PrivateKey.fromBytes(priv)).publicKey()).toCompressedSec1();
}

fn p2pkhOf(pubkey: [33]u8) [25]u8 {
    var s: [25]u8 = undefined;
    s[0..3].* = .{ 0x76, 0xa9, 0x14 };
    s[3..23].* = bsvz.crypto.hash.hash160(&pubkey).bytes;
    s[23..25].* = .{ 0x88, 0xac };
    return s;
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

/// A funding transaction (outputs of 10 000 sats to `p2pkh`), mined alone at height 1 of a regtest chain.
const Fund = struct { tx: bsvz.transaction.Transaction, raw: []const u8, txid: [32]u8, h1: [80]u8, entry: beef.Entry, bumps: []bsvz.spv.MerklePath };

fn fund(a: Allocator, seed: u8, n: u8, p2pkh: []const u8) !Fund {
    var raw: std.ArrayList(u8) = .empty;
    try raw.appendSlice(a, &.{ 1, 0, 0, 0, 1 });
    try raw.appendSlice(a, &(.{seed} ** 32));
    try raw.appendSlice(a, &.{ 0, 0, 0, 0, 1, 0x51, 0xff, 0xff, 0xff, 0xff, n });
    for (0..n) |_| {
        var sats: [8]u8 = undefined;
        std.mem.writeInt(u64, &sats, 10_000, .little);
        try raw.appendSlice(a, &sats);
        try raw.append(a, @intCast(p2pkh.len));
        try raw.appendSlice(a, p2pkh);
    }
    try raw.appendSlice(a, &.{ 0, 0, 0, 0 });
    const tx = try bsvz.transaction.Transaction.parse(a, raw.items);
    const txid = beef.txidOf(raw.items);
    const h1 = mine(hdr.hash(&c.chain.Network.regtest.genesis()), txid, 1_700_000_600);
    const bumps = try a.dupe(bsvz.spv.MerklePath, &.{try bsvz.spv.MerklePath.parse(a, try soloPath(a, 1, txid))});
    return .{ .tx = tx, .raw = raw.items, .txid = txid, .h1 = h1, .entry = .{ .txid = txid, .format = .raw_with_bump, .bump = 0, .raw = raw.items, .tx = tx }, .bumps = bumps };
}

fn withFund(a: Allocator, f: Fund, t: Spent) ![]const u8 {
    return beef.serialize(a, .{ .version = beef.V2, .bumps = f.bumps, .entries = try a.dupe(beef.Entry, &.{ f.entry, .{ .txid = t.txid, .format = .raw, .raw = t.raw, .tx = t.tx } }) });
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
        if (c.store.bitcoinHash(cid)) |h| if (!std.mem.eql(u8, &h, &c.store.dblSha256(bytes))) return error.HashMismatch;
        try self.blocks.put(self.arena, try self.arena.dupe(u8, cid), try self.arena.dupe(u8, bytes));
    }
    fn keep(_: *anyopaque, _: []const u8) anyerror!void {
        return error.ReadOnly; // a call keeps nothing
    }
    fn edges(ptr: *anyopaque, a: Allocator, to: []const u8, rel: ?[]const u8) anyerror![]const c.store.Edge {
        const self: *Overlay = @ptrCast(@alignCast(ptr));
        return self.inner.edges(a, to, rel);
    }
};

/// Messages to the instance itself, recorded (box, body); each gets a CID of its own.
const FakeWire = struct {
    a: Allocator,
    sent: std.ArrayList(Sent) = .empty,
    const Sent = struct { box: []const u8, body: Value, cid: []const u8 };

    fn send(ctx: *anyopaque, _: Allocator, box: []const u8, body: Value) anyerror![]const u8 {
        const self: *FakeWire = @ptrCast(@alignCast(ctx));
        const bytes = try cbor.encode(self.a, .{ .map = try self.a.dupe(cbor.Entry, &.{
            .{ .key = "box", .value = .{ .text = box } },
            .{ .key = "body", .value = body },
            .{ .key = "n", .value = .{ .uint = self.sent.items.len } },
        }) });
        const cid = try self.a.dupe(u8, &cbor.cidOf(bytes));
        try self.sent.append(self.a, .{ .box = try self.a.dupe(u8, box), .body = body, .cid = cid });
        return cid;
    }
    fn wire(self: *FakeWire) submit.Wire {
        return .{ .ctx = self, .sendFn = send };
    }
    fn last(self: *FakeWire) Sent {
        return self.sent.items[self.sent.items.len - 1];
    }
};

/// The gossip out (#74) as the engine sees it: the publishes, recorded (topic, body).
const FakeOut = struct {
    a: Allocator,
    sent: std.ArrayList(Pub) = .empty,
    const Pub = struct { topic: []const u8, body: []const u8 };

    fn publish(ctx: *anyopaque, _: Allocator, t: []const u8, body: []const u8) anyerror!void {
        const self: *FakeOut = @ptrCast(@alignCast(ctx));
        try self.sent.append(self.a, .{ .topic = try self.a.dupe(u8, t), .body = try self.a.dupe(u8, body) });
    }
    fn out(self: *FakeOut) gossip.Out {
        return .{ .ctx = self, .publishFn = publish };
    }
};

/// An instance, natively: the store, the heads `chain/state` (the chain app's, here written by
/// the test), `overlay/state` and `overlay/ls_demo`, the config, and the programs behind the `call`s.
const Instance = struct {
    a: Allocator,
    ms: *c.store.MemStore,
    current: Store,
    chain_root: ?[]const u8 = null,
    ov_root: ?[]const u8 = null,
    ls_state: ?[]const u8 = null,
    in: Value,
    now: i64 = 1000,
    topic_prog: []const u8,
    lookup_prog: []const u8,
    /// The topics a submission requests (X-Topics, or the gossip message's).
    topics: []const []const u8 = &.{"tm_demo"},
    calls_: std.StringHashMapUnmanaged(usize) = .empty,
    wire_: *FakeWire,
    out_: *FakeOut,
    /// The submission threads' events and ingest messages, by txid.
    threads: std.AutoHashMapUnmanaged([32]u8, struct { ev: Value, ingest: []const u8 }) = .empty,

    fn init(a: Allocator, ms: *c.store.MemStore) !Instance {
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
            .{ .key = "app", .value = .{ .text = "overlay" } },
        }) };
        const wire_ = try a.create(FakeWire);
        wire_.* = .{ .a = a };
        const out_ = try a.create(FakeOut);
        out_.* = .{ .a = a };
        return .{ .a = a, .ms = ms, .current = ms.store(), .in = in, .topic_prog = tp, .lookup_prog = lp, .wire_ = wire_, .out_ = out_ };
    }

    fn callImpl(ctx: *anyopaque, a: Allocator, program: []const u8, func: []const u8, arg: Value) anyerror!Value {
        const self: *Instance = @ptrCast(@alignCast(ctx));
        const gop = try self.calls_.getOrPut(self.a, try self.a.dupe(u8, func));
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* += 1;
        if (std.mem.eql(u8, program, self.topic_prog)) {
            if (!std.mem.eql(u8, func, "identify")) return error.UnknownFunction;
            return topic.judge(a, self.current, demo.identify, arg);
        }
        if (std.mem.eql(u8, program, self.lookup_prog)) {
            try std.testing.expectEqualStrings("overlay", arg.getText("app").?);
            const h = try lookup.handle(a, ls.spec, self.current, .regtest, self.ls_state, self.chain_root, func, arg);
            if (h.state) |sc| self.ls_state = sc;
            return h.answer;
        }
        return error.UnknownProgram;
    }
    fn caller(self: *Instance) calls.Caller {
        return .{ .ctx = self, .callFn = callImpl };
    }
    fn count(self: *Instance, func: []const u8) usize {
        return self.calls_.get(func) orelse 0;
    }

    // ------------------------------------------------ the chain app, standing in

    fn chain(self: *Instance) !Chain {
        var ch = try Chain.load(self.a, self.ms.store(), self.chain_root, .regtest);
        ch.now = self.now;
        return ch;
    }
    fn headers(self: *Instance, raws: []const []const u8) !void {
        var ch = try self.chain();
        _ = try ch.addHeaders(raws);
        self.chain_root = try ch.save();
    }
    /// The chain app takes an ingest message: → the subject's status.
    fn ingest(self: *Instance, bytes: []const u8) !c.state.Status {
        var ch = try self.chain();
        const got = try ch.ingest(bytes);
        self.chain_root = try ch.save();
        return got.status;
    }
    /// A status (or a proof, "MINED" with its path) reaching the chain app.
    fn chainStatus(self: *Instance, txid: [32]u8, tx_status: []const u8, path: ?[]const u8) !Chain.Outcome {
        var ch = try self.chain();
        const o = try ch.applyStatus(txid, tx_status, path);
        self.chain_root = try ch.save();
        return o;
    }

    // ------------------------------------------------ the overlay

    /// POST /submit's handler: a call over a write cache of its own, dropped afterwards.
    fn route(self: *Instance, bytes: []const u8) !submit.Routed {
        return self.routeFrom(bytes, null);
    }
    fn routeFrom(self: *Instance, bytes: []const u8, source: ?Value) !submit.Routed {
        return self.routeWith(.{ .bytes = bytes }, source);
    }
    /// The kernel's door wrote the BEEF's pointer record (skein #121): the handler gets its CID.
    fn routeRecord(self: *Instance, rc: []const u8) !submit.Routed {
        return self.routeWith(.{ .record = rc }, null);
    }
    fn routeWith(self: *Instance, input: submit.Input, source: ?Value) !submit.Routed {
        var ovl = Overlay{ .inner = self.ms.store(), .arena = self.a };
        self.current = ovl.store();
        defer self.current = self.ms.store();
        const ch = try state.chainView(self.a, ovl.store(), self.chain_root, .regtest);
        var st = try state.State.load(self.a, ovl.store(), self.ov_root, ch);
        st.now = self.now;
        return submit.route(self.a, self.caller(), &st, self.in, input, self.topics, null, source);
    }

    /// A step: the context over the store as it stands, then the state saved.
    fn cx(self: *Instance, st: *state.State, with_out: bool) submit.Ctx {
        return .{ .a = self.a, .caller = self.caller(), .wire = self.wire_.wire(), .out = if (with_out) self.out_.out() else null, .st = st, .in = self.in, .thread = &cbor.cidOf("the thread") };
    }
    fn load(self: *Instance) !state.State {
        self.current = self.ms.store();
        const ch = try state.chainView(self.a, self.ms.store(), self.chain_root, .regtest);
        var st = try state.State.load(self.a, self.ms.store(), self.ov_root, ch);
        st.now = self.now;
        return st;
    }

    /// The submission's thread, first step (the event read back as the host stores it).
    fn begin(self: *Instance, event: Value) ![]const u8 {
        const ev = try cbor.decode(self.a, try cbor.encode(self.a, event));
        var st = try self.load();
        const m = try submit.begin(self.cx(&st, true), ev);
        self.ov_root = try st.save();
        try self.threads.put(self.a, try submit.txidOf(ev), .{ .ev = ev, .ingest = m });
        return m;
    }

    /// The submission's thread stepped with the chain app's answer.
    fn answer(self: *Instance, txid: [32]u8, ans: submit.Answer) !submit.Stepped {
        const t = self.threads.get(txid).?;
        var st = try self.load();
        const done = try submit.answered(self.cx(&st, true), t.ev, t.ingest, ans);
        self.ov_root = try st.save();
        return done;
    }

    fn watchStart(self: *Instance, txid: [32]u8) !submit.Stepped {
        var st = try self.load();
        const done = try submit.watchStart(self.cx(&st, true), txid);
        self.ov_root = try st.save();
        return done;
    }
    fn watched(self: *Instance, txid: [32]u8, ans: submit.Answer) !submit.Stepped {
        var st = try self.load();
        const done = try submit.watched(self.cx(&st, true), txid, ans);
        self.ov_root = try st.save();
        return done;
    }

    fn pending(self: *Instance, txid: [32]u8) !bool {
        var st = try self.load();
        return st.isPending(txid);
    }
    fn applied(self: *Instance, txid: [32]u8) !bool {
        var st = try self.load();
        return st.isApplied("tm_demo", txid);
    }

    /// Route, then the thread's first step: → its ingest message.
    fn submitted(self: *Instance, bytes: []const u8) ![]const u8 {
        const r = try self.route(bytes);
        if (r != .admit) {
            std.debug.print("not admitted: {any}\n", .{r});
            return error.NotAdmitted;
        }
        return self.begin(r.admit.event);
    }

    /// Submitted, ingested by the chain app, accepted (a RECEIVED status), and the answer stepped.
    fn admitted(self: *Instance, bytes: []const u8, txid: [32]u8) !submit.Stepped {
        _ = try self.submitted(bytes);
        _ = try self.ingest(bytes);
        try std.testing.expectEqual(Chain.Outcome.accepted, try self.chainStatus(txid, "RECEIVED", null));
        return self.answer(txid, .accepted);
    }

    /// A lookup (fn "lookup" of the service): the outputs.
    fn look(self: *Instance, fields: []const cbor.Entry) ![]const Value {
        const ans = try self.caller().call(self.a, self.lookup_prog, "lookup", try calls.lookupArg(self.a, self.in, "ls_demo", .{ .map = try self.a.dupe(cbor.Entry, fields) }));
        try std.testing.expectEqualStrings("output-list", ans.getText("type").?);
        return ans.getArray("outputs").?;
    }
    fn lookTopic(self: *Instance) !usize {
        return (try self.look(&.{.{ .key = "topic", .value = .{ .text = "tm_demo" } }})).len;
    }

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

const Keys = struct { priv: [32]u8, p2pkh: [25]u8, token: [34]u8, token_hash: [32]u8 };

fn keys(seed: u8) !Keys {
    const priv: [32]u8 = .{seed} ** 32;
    const pub_key = try identityKey(priv);
    const pkh = bsvz.crypto.hash.hash160(&pub_key).bytes;
    const token: [34]u8 = demo.tag.* ++ [_]u8{ 0x76, 0xa9, 0x14 } ++ pkh ++ [_]u8{ 0x88, 0xac };
    var th: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&token, &th, .{});
    return .{ .priv = priv, .p2pkh = p2pkhOf(pub_key), .token = token, .token_hash = th };
}

test "the submission flow: parse once, persist only on admission, a lookup service's own map through its hooks" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var ms = c.store.MemStore.init(std.testing.allocator);
    defer ms.deinit();
    var inst = try Instance.init(a, &ms);
    const k = try keys(0x42);
    const f = try fund(a, 0x11, 2, &k.p2pkh);
    try inst.headers(&.{&f.h1});

    // ------------------------------------------------ refused: tm_demo takes nothing, nothing persists
    {
        const plain = try spend(a, &f.tx, 1, &.{.{ 9_000, &k.p2pkh }}, k.priv);
        const bytes = try withFund(a, f, plain);
        const before = try inst.snapshot();
        const parses = beef.parses;
        const r = try inst.route(bytes);
        try std.testing.expect(r == .nothing);
        try std.testing.expect(std.mem.startsWith(u8, r.nothing, "NotAdmitted"));
        try std.testing.expectEqual(parses + 1, beef.parses);
        try std.testing.expectEqual(@as(usize, 1), inst.count("identify"));
        try std.testing.expectEqual(before.count(), ms.count());
        var it = before.iterator();
        while (it.next()) |e| try std.testing.expectEqualSlices(u8, e.value_ptr.*, ms.blocks.get(e.key_ptr.*).?);
        const bad = try inst.route(&.{ 1, 2, 3 });
        try std.testing.expectEqualStrings("InvalidBeef", bad.refused);
        try std.testing.expectEqual(before.count(), ms.count());
        try std.testing.expectEqual(@as(usize, 0), inst.wire_.sent.items.len);
    }

    // ------------------------------------------------ T1 admits a token: the BEEF to the chain app, admitted on its answer
    const t1 = try spend(a, &f.tx, 0, &.{ .{ 1, &k.token }, .{ 9_000, &k.p2pkh } }, k.priv);
    const t1_beef = try withFund(a, f, t1);
    {
        const parses = beef.parses;
        const r = try inst.route(t1_beef);
        try std.testing.expectEqual(parses + 1, beef.parses);
        const ev = r.admit.event;
        try std.testing.expectEqualSlices(u8, t1_beef, ev.getBytes("beef").?);
        try std.testing.expect(ev.get("txs") == null);
        const m = try inst.begin(ev);
        // The ingest message: box `chain`, {fn: "ingest", args: {beef}}.
        const sent = inst.wire_.last();
        try std.testing.expectEqualStrings("chain", sent.box);
        try std.testing.expectEqualSlices(u8, m, sent.cid);
        try std.testing.expectEqualStrings("ingest", sent.body.getText("fn").?);
        try std.testing.expectEqualSlices(u8, t1_beef, sent.body.get("args").?.getBytes("beef").?);
        try std.testing.expect(try inst.pending(t1.txid));
        try std.testing.expect(!(try inst.applied(t1.txid)));
        try std.testing.expectEqual(@as(usize, 0), inst.count("admitted"));
        // The pending record names the thread and the message.
        var st = try inst.load();
        const rec = (try st.pendingRecord(t1.txid)).?;
        try std.testing.expectEqualSlices(u8, m, rec.getCid("ingest").?);
        try std.testing.expectEqualSlices(u8, &cbor.cidOf("the thread"), rec.getCid("thread").?);

        // The chain app ingests it (unproven: broadcast) and the status provider's RECEIVED accepts it.
        try std.testing.expectEqual(c.state.Status.unproven, try inst.ingest(t1_beef));
        _ = try inst.chainStatus(t1.txid, "RECEIVED", null);
        const done = try inst.answer(t1.txid, .accepted);
        try std.testing.expect(done.admitted and done.done);
        try std.testing.expectEqualSlices(u32, &.{0}, done.applied[0].outputs_to_admit);
        try std.testing.expectEqual(@as(usize, 1), inst.count("admitted"));
        try std.testing.expectEqual(@as(usize, 0), inst.count("spent"));
        try std.testing.expect(!(try inst.pending(t1.txid)));
        // Admitted on its acceptance: a watch to the app's own box.
        const w = inst.wire_.last();
        try std.testing.expectEqualStrings("overlay", w.box);
        try std.testing.expectEqualSlices(u8, w.cid, done.watch.?);
        try std.testing.expectEqualStrings("watch", w.body.getText("fn").?);
        try std.testing.expectEqualStrings(&hdr.toHex(t1.txid), w.body.get("args").?.getText("txid").?);
        try std.testing.expectEqualSlices(u8, m, w.body.get("args").?.getCid("ingest").?);
        // The records are in the overlay's state; the transaction is the chain app's.
        for (done.records) |rc| try std.testing.expect(ms.blocks.contains(rc));
        try std.testing.expect(ms.blocks.contains(&c.store.hashCid(.tx, t1.txid)));
        // A dupe: nothing new, nothing called.
        const calls_before = inst.count("identify");
        try std.testing.expect((try inst.route(t1_beef)) == .unchanged);
        try std.testing.expectEqual(calls_before, inst.count("identify"));
    }

    // ------------------------------------------------ ls_demo answers from its own map
    {
        const by_topic = try inst.look(&.{.{ .key = "topic", .value = .{ .text = "tm_demo" } }});
        try std.testing.expectEqual(@as(usize, 1), by_topic.len);
        try std.testing.expectEqualSlices(u8, &t1.txid, &(try subjectOf(a, by_topic[0])));
        // Its BEEF verifies against a node that holds only the headers.
        var headers_only = c.store.MemStore.init(std.testing.allocator);
        defer headers_only.deinit();
        var hc = try Chain.load(a, headers_only.store(), null, .regtest);
        _ = try hc.addHeaders(&.{&f.h1});
        var sctx = Chain.SpvCtx{ .st = &hc };
        _ = try c.spv.verify(a, try beef.parse(a, by_topic[0].getBytes("beef").?), .{ .ptr = &sctx, .rootAtFn = Chain.SpvCtx.rootAt, .knownRawFn = Chain.SpvCtx.knownRaw });
        const by_script = try inst.look(&.{.{ .key = "scriptHash", .value = .{ .text = &std.fmt.bytesToHex(k.token_hash, .lower) } }});
        try std.testing.expectEqual(@as(usize, 1), by_script.len);
        const by_op = try inst.look(&.{
            .{ .key = "topic", .value = .{ .text = "tm_demo" } },
            .{ .key = "txid", .value = .{ .text = &hdr.toHex(t1.txid) } },
            .{ .key = "outputIndex", .value = .{ .uint = 1 } },
        });
        try std.testing.expectEqual(@as(usize, 0), by_op.len);
        // The overlay's own view: unspent.
        var st = try inst.load();
        const in_topic = try st.inTopic("tm_demo", true);
        try std.testing.expectEqual(@as(usize, 1), in_topic.len);
        try std.testing.expect(!in_topic[0].spent);
    }

    // ------------------------------------------------ T2 spends the token into a new one: `spent`
    const t2 = try spend(a, &t1.tx, 0, &.{.{ 1, &k.token }}, k.priv);
    {
        inst.now = 2000;
        const done = try inst.admitted(try atomic(a, t2), t2.txid);
        try std.testing.expectEqualSlices(u32, &.{0}, done.applied[0].coins_to_retain);
        try std.testing.expectEqual(@as(usize, 1), inst.count("spent"));
        try std.testing.expectEqual(@as(usize, 1), try inst.lookTopic());
        const all = try inst.look(&.{ .{ .key = "topic", .value = .{ .text = "tm_demo" } }, .{ .key = "includeSpent", .value = .{ .boolean = true } } });
        try std.testing.expectEqual(@as(usize, 2), all.len);
        var st = try inst.load();
        const sp = (try st.spender("tm_demo", t1.txid, 0)).?;
        try std.testing.expectEqualSlices(u8, &t2.txid, &sp.txid);
        try std.testing.expect(sp.retained and sp.judged);
        try std.testing.expectEqual(@as(usize, 1), (try st.inTopic("tm_demo", false)).len);
    }

    // ------------------------------------------------ T2 rejected later (its watch hears it): `rejected`, T1's token live again
    {
        inst.now = 3000;
        try std.testing.expect(!(try inst.watchStart(t2.txid)).done);
        _ = try inst.chainStatus(t2.txid, "DOUBLE_SPEND_ATTEMPTED", null);
        const done = try inst.watched(t2.txid, .{ .rejected = "DOUBLE_SPEND_ATTEMPTED" });
        try std.testing.expect(done.done);
        try std.testing.expectEqual(@as(usize, 1), done.unapplied.len);
        try std.testing.expectEqual(@as(usize, 1), inst.count("rejected"));
        try std.testing.expect(!(try inst.applied(t2.txid)));
        const live = try inst.look(&.{ .{ .key = "topic", .value = .{ .text = "tm_demo" } }, .{ .key = "includeSpent", .value = .{ .boolean = true } } });
        try std.testing.expectEqual(@as(usize, 1), live.len);
        try std.testing.expectEqualSlices(u8, &t1.txid, &(try subjectOf(a, live[0])));
        var st = try inst.load();
        try std.testing.expect((try st.spender("tm_demo", t1.txid, 0)) == null);
        // Resubmitting it admits nothing (200, empty STEAK).
        try std.testing.expectEqualStrings("TransactionRejected", (try inst.route(try atomic(a, t2))).nothing);
    }

    // ------------------------------------------------ T3 spends the token and admits none: the coin removed
    {
        inst.now = 4000;
        const t3 = try spend(a, &t1.tx, 0, &.{.{ 1, &k.p2pkh }}, k.priv);
        const done = try inst.admitted(try atomic(a, t3), t3.txid);
        try std.testing.expectEqual(@as(usize, 0), done.applied[0].outputs_to_admit.len);
        try std.testing.expectEqualSlices(u32, &.{0}, done.applied[0].coins_removed);
        try std.testing.expectEqual(@as(usize, 2), inst.count("spent"));
        try std.testing.expectEqual(@as(usize, 0), try inst.lookTopic());
    }
}

test "the gate (#73, the chain app's answer): admitted on the first of accepted or proven; rejected, failed, a later rejection, proven at once" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var ms = c.store.MemStore.init(std.testing.allocator);
    defer ms.deinit();
    var inst = try Instance.init(a, &ms);
    const k = try keys(0x42);
    const f = try fund(a, 0x22, 5, &k.p2pkh);
    try inst.headers(&.{&f.h1});

    // ------------------------------------------------ (a) pending; a resubmission joins the same thread; accepted admits; the proof proves
    const ta = try spend(a, &f.tx, 0, &.{.{ 1, &k.token }}, k.priv);
    const h2 = mine(hdr.hash(&f.h1), ta.txid, 1_700_001_200);
    {
        const bytes = try withFund(a, f, ta);
        _ = try inst.submitted(bytes);
        try std.testing.expect(try inst.pending(ta.txid));
        try std.testing.expectEqualSlices(u8, &ta.txid, &(try inst.route(bytes)).pending);
        _ = try inst.ingest(bytes);
        // An answer the engine does not act on: still awaiting.
        const other = try inst.answer(ta.txid, .other);
        try std.testing.expect(!other.done and !other.admitted);
        try std.testing.expect(try inst.pending(ta.txid));
        _ = try inst.chainStatus(ta.txid, "RECEIVED", null);
        const ok = try inst.answer(ta.txid, .accepted);
        try std.testing.expect(ok.admitted);
        try std.testing.expectEqual(@as(usize, 1), try inst.lookTopic());
        // Gossip: the BEEF on tm_demo, the verdict on tm_demo-admit; no proof yet.
        try std.testing.expectEqual(@as(usize, 2), ok.published);
        try std.testing.expectEqualStrings("tm_demo", inst.out_.sent.items[0].topic);
        try std.testing.expectEqualSlices(u8, bytes, inst.out_.sent.items[0].body);
        try std.testing.expectEqualStrings("tm_demo-admit", inst.out_.sent.items[1].topic);
        // Its watch: the chain state says unproven — it awaits; accepted again — still awaits; the proof — `-proof`.
        try std.testing.expect(!(try inst.watchStart(ta.txid)).done);
        try std.testing.expect(!(try inst.watched(ta.txid, .accepted)).done);
        try inst.headers(&.{&h2});
        try std.testing.expectEqual(Chain.Outcome.proven, try inst.chainStatus(ta.txid, "MINED", try soloPath(a, 2, ta.txid)));
        const mined = try inst.watched(ta.txid, .{ .proven = .{} });
        try std.testing.expect(mined.done);
        try std.testing.expectEqual(@as(usize, 1), mined.published);
        const p = try gossip.parseProof(a, inst.out_.sent.items[2].body);
        try std.testing.expectEqualStrings("tm_demo-proof", inst.out_.sent.items[2].topic);
        try std.testing.expectEqualSlices(u8, &ta.txid, &p.txid);
        try std.testing.expectEqualSlices(u8, &hdr.hash(&h2), &p.block_hash);
        try std.testing.expectEqualSlices(u8, try soloPath(a, 2, ta.txid), p.bump);
        try std.testing.expectEqual(@as(usize, 1), inst.count("admitted"));
    }

    // ------------------------------------------------ (b) rejected: nothing admitted, no hook
    {
        const tb = try spend(a, &f.tx, 1, &.{.{ 1, &k.token }}, k.priv);
        const n = inst.count("admitted");
        const bytes = try withFund(a, f, tb);
        _ = try inst.submitted(bytes);
        _ = try inst.ingest(bytes);
        _ = try inst.chainStatus(tb.txid, "REJECTED", null);
        const done = try inst.answer(tb.txid, .{ .rejected = "REJECTED" });
        try std.testing.expect(done.done and !done.admitted);
        try std.testing.expectEqual(n, inst.count("admitted"));
        try std.testing.expectEqual(@as(usize, 0), inst.count("rejected"));
        try std.testing.expect(!(try inst.pending(tb.txid)));
        try std.testing.expect(!(try inst.applied(tb.txid)));
        try std.testing.expectEqualStrings("TransactionRejected", (try inst.route(bytes)).nothing);
    }

    // ------------------------------------------------ (c) proven first (no status): admitted at once, `-proof` too, no watch
    const tc = try spend(a, &f.tx, 2, &.{.{ 1, &k.token }}, k.priv);
    const h3 = mine(hdr.hash(&h2), tc.txid, 1_700_001_800);
    {
        const bytes = try withFund(a, f, tc);
        const sent = inst.wire_.sent.items.len;
        _ = try inst.submitted(bytes);
        _ = try inst.ingest(bytes);
        try inst.headers(&.{&h3});
        _ = try inst.chainStatus(tc.txid, "MINED", try soloPath(a, 3, tc.txid));
        const pubs = inst.out_.sent.items.len;
        const done = try inst.answer(tc.txid, .{ .proven = .{} });
        try std.testing.expect(done.admitted and done.done);
        try std.testing.expect(done.watch == null);
        try std.testing.expectEqual(sent + 1, inst.wire_.sent.items.len); // the ingest only
        try std.testing.expectEqual(pubs + 3, inst.out_.sent.items.len);
        try std.testing.expectEqualStrings("tm_demo-proof", inst.out_.sent.items[pubs + 2].topic);
        // A later answer to the same ingest (none awaits it: the thread finished) — were it stepped, nothing again.
        try std.testing.expect(!(try inst.answer(tc.txid, .{ .proven = .{} })).admitted);
    }

    // ------------------------------------------------ (d) proven by a peer's proof (`via`): admitted, no `-proof` re-published
    const td = try spend(a, &f.tx, 3, &.{.{ 1, &k.token }}, k.priv);
    const h4 = mine(hdr.hash(&h3), td.txid, 1_700_002_000);
    {
        const bytes = try withFund(a, f, td);
        _ = try inst.submitted(bytes);
        _ = try inst.ingest(bytes);
        try inst.headers(&.{&h4});
        _ = try inst.chainStatus(td.txid, "MINED", try soloPath(a, 4, td.txid));
        const pubs = inst.out_.sent.items.len;
        const done = try inst.answer(td.txid, .{ .proven = .{ .via = "libp2p:tm_demo-proof" } });
        try std.testing.expect(done.admitted);
        try std.testing.expectEqual(pubs + 2, inst.out_.sent.items.len);
        try std.testing.expectEqualStrings("tm_demo-admit", inst.out_.sent.items[pubs + 1].topic);
    }

    // ------------------------------------------------ (e) an error answer: nothing admitted, no longer pending; a later watch on a rejection unwinds
    {
        const te = try spend(a, &f.tx, 4, &.{.{ 1, &k.token }}, k.priv);
        const bytes = try withFund(a, f, te);
        _ = try inst.submitted(bytes);
        const done = try inst.answer(te.txid, .{ .failed = "ingest: UnknownHeader" });
        try std.testing.expect(done.done and !done.admitted);
        try std.testing.expect(!(try inst.pending(te.txid)));
        // Submitted again: admitted on acceptance, then the chain rejects it before its watch's first step.
        _ = try inst.submitted(bytes);
        _ = try inst.ingest(bytes);
        _ = try inst.chainStatus(te.txid, "RECEIVED", null);
        try std.testing.expect((try inst.answer(te.txid, .accepted)).admitted);
        const n = try inst.lookTopic();
        _ = try inst.chainStatus(te.txid, "REJECTED", null);
        const w = try inst.watchStart(te.txid);
        try std.testing.expect(w.done);
        try std.testing.expectEqual(@as(usize, 1), w.unapplied.len);
        try std.testing.expectEqual(n - 1, try inst.lookTopic());
    }

    // ------------------------------------------------ the answer bodies as the chain app sends them
    {
        const body = struct {
            fn of(al: Allocator, result: []const cbor.Entry) !Value {
                return .{ .map = try al.dupe(cbor.Entry, &.{
                    .{ .key = "fn", .value = .{ .text = "ingest" } },
                    .{ .key = "result", .value = .{ .map = try al.dupe(cbor.Entry, result) } },
                }) };
            }
        }.of;
        try std.testing.expect(submit.answerOf(try body(a, &.{.{ .key = "state", .value = .{ .text = "accepted" } }})) == .accepted);
        const pv = submit.answerOf(try body(a, &.{ .{ .key = "state", .value = .{ .text = "proven" } }, .{ .key = "via", .value = .{ .text = "x" } } }));
        try std.testing.expectEqualStrings("x", pv.proven.via.?);
        try std.testing.expectEqualStrings("abandoned", submit.answerOf(try body(a, &.{ .{ .key = "state", .value = .{ .text = "rejected" } }, .{ .key = "reason", .value = .{ .text = "abandoned" } } })).rejected);
        const err: Value = .{ .map = try a.dupe(cbor.Entry, &.{.{ .key = "error", .value = .{ .map = try a.dupe(cbor.Entry, &.{ .{ .key = "code", .value = .{ .text = "failed" } }, .{ .key = "message", .value = .{ .text = "ingest: InvalidBeef" } } }) } }}) };
        try std.testing.expectEqualStrings("ingest: InvalidBeef", submit.answerOf(err).failed);
        try std.testing.expect(submit.answerOf(try body(a, &.{.{ .key = "state", .value = .{ .text = "unknown" } }})) == .other);
    }
}

test "the topic contract: identify on a CID, reading records" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var ms = c.store.MemStore.init(std.testing.allocator);
    defer ms.deinit();
    const s = ms.store();
    try std.testing.expectError(error.BadArgs, topic.judge(a, s, demo.identify, .{ .map = &.{} }));
    const missing: Value = .{ .map = try a.dupe(cbor.Entry, &.{
        .{ .key = "kind", .value = .{ .text = "topic-call" } },
        .{ .key = "topic", .value = .{ .text = "tm_demo" } },
        .{ .key = "tx", .value = .{ .cid = try a.dupe(u8, &c.store.hashCid(.tx, .{0x5a} ** 32)) } },
    }) };
    try std.testing.expectError(error.UnknownTransaction, topic.judge(a, s, demo.identify, missing));
}

test "metadata and documentation: the program's own, else the default" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const in: Value = .{ .map = try a.dupe(cbor.Entry, &.{.{ .key = "app", .value = .{ .text = "overlay" } }}) };
    const ta = try calls.describeArg(a, in, "overlayTopics", "tm_demo");
    const la = try calls.describeArg(a, in, "overlayLookups", "ls_demo");

    const tm = try topic.describe(a, demo, "metadata", ta);
    try std.testing.expectEqualStrings("metadata", tm.getText("kind").?);
    try std.testing.expectEqualStrings("tm_demo", tm.getText("name").?);
    try std.testing.expectEqualStrings((try demo.metadata(a, "tm_demo")).short_description, tm.getText("shortDescription").?);
    try std.testing.expect(tm.get("iconURL") == null);
    try std.testing.expect(std.mem.startsWith(u8, (try topic.describe(a, demo, "documentation", ta)).getText("documentation").?, "# tm_demo"));

    const lm = try lookup.describe(a, ls, "metadata", la);
    try std.testing.expectEqualStrings("ls_demo", lm.getText("name").?);
    try std.testing.expect(lm.getText("shortDescription").?.len > 0);
    try std.testing.expect(std.mem.startsWith(u8, (try lookup.describe(a, ls, "documentation", la)).getText("documentation").?, "# ls_demo"));

    // A program that defines neither: its configured name, "" and "".
    const None = struct {};
    const dm = try topic.describe(a, None, "metadata", ta);
    try std.testing.expectEqualStrings("tm_demo", dm.getText("name").?);
    try std.testing.expectEqualStrings("", dm.getText("shortDescription").?);
    try std.testing.expectEqualStrings("", (try lookup.describe(a, None, "documentation", la)).getText("documentation").?);
    try std.testing.expectEqualStrings("ls_demo", (try lookup.describe(a, None, "metadata", la)).getText("name").?);

    // Optional fields when the program gives them.
    const Full = struct {
        pub fn metadata(_: Allocator, _: []const u8) anyerror!topic.Metadata {
            return .{ .name = "Full", .short_description = "s", .icon_url = "i", .version = "1", .information_url = "u" };
        }
    };
    const fm = try topic.describe(a, Full, "metadata", ta);
    try std.testing.expectEqualStrings("Full", fm.getText("name").?);
    try std.testing.expectEqualStrings("i", fm.getText("iconURL").?);
    try std.testing.expectEqualStrings("1", fm.getText("version").?);
    try std.testing.expectEqualStrings("u", fm.getText("informationURL").?);

    try std.testing.expectError(error.BadArgs, topic.describe(a, demo, "metadata", la));
    try std.testing.expectError(error.UnknownFunction, lookup.describe(a, ls, "nope", la));
}

/// The config with `defaults.<key>` set to `value`.
fn withDefault(a: Allocator, in: Value, key: []const u8, value: []const u8) !Value {
    const es = try a.dupe(cbor.Entry, in.map);
    for (es) |*e| if (std.mem.eql(u8, e.key, "defaults")) {
        e.value = .{ .map = try std.mem.concat(a, cbor.Entry, &.{ e.value.map, &.{.{ .key = key, .value = .{ .text = value } }} }) };
    };
    return .{ .map = es };
}

test "gossip (#74): the three topics' shapes; what an admission publishes; a peer's proof checked against the chain state; a late duplicate judged once" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var ms = c.store.MemStore.init(std.testing.allocator);
    defer ms.deinit();
    var inst = try Instance.init(a, &ms);
    const k = try keys(0x42);
    const f = try fund(a, 0x33, 2, &k.p2pkh);
    try inst.headers(&.{&f.h1});

    // ------------------------------------------------ the shapes (dag-cbor), exactly
    {
        const txid: [32]u8 = .{0xab} ** 32;
        const ad = try cbor.decode(a, try gossip.admitBody(a, txid, "tm_demo", &.{ 0, 2 }, &.{1}));
        try std.testing.expectEqual(@as(usize, 2), ad.map.len);
        try std.testing.expectEqualStrings(&hdr.toHex(txid), ad.getText("txid").?);
        const e = ad.get("topics").?.get("tm_demo").?;
        try std.testing.expectEqual(@as(usize, 2), e.map.len);
        const back = try gossip.parseAdmit(a, try gossip.admitBody(a, txid, "tm_demo", &.{ 0, 2 }, &.{1}), "tm_demo");
        try std.testing.expectEqualSlices(u32, &.{ 0, 2 }, back.outputs_to_admit);
        try std.testing.expectError(error.NotThisTopic, gossip.parseAdmit(a, try gossip.admitBody(a, txid, "tm_demo", &.{}, &.{}), "tm_other"));
        try std.testing.expectError(error.BadMessage, gossip.parseAdmit(a, "not cbor", "tm_demo"));
        const pr = try cbor.decode(a, try gossip.proofBody(a, txid, .{0xcd} ** 32, 7, "BUMP"));
        try std.testing.expectEqual(@as(usize, 4), pr.map.len);
        try std.testing.expectEqual(@as(u64, 7), pr.getUint("blockHeight").?);
        const pp = try gossip.parseProof(a, try gossip.proofBody(a, txid, .{0xcd} ** 32, 7, "BUMP"));
        try std.testing.expectEqualSlices(u8, &txid, &pp.txid);
        try std.testing.expectEqualStrings("tm_demo", gossip.baseOf("tm_demo-proof", gossip.proof_suffix).?);
        try std.testing.expect(gossip.baseOf("-proof", gossip.proof_suffix) == null);
        try std.testing.expectEqualStrings("overlay/gossip", try gossip.stateHead(a, "overlay"));
    }

    // ------------------------------------------------ gossip off for a topic: nothing published
    {
        const off_in = try withDefault(a, inst.in, "overlayGossip", "{\"tm_demo\":false}");
        try std.testing.expect(!(try gossip.enabled(a, off_in, "tm_demo")));
        try std.testing.expect(try gossip.enabled(a, inst.in, "tm_demo"));
        try std.testing.expectError(error.BadConfig, gossip.enabled(a, try withDefault(a, inst.in, "overlayGossip", "{\"tm_demo\":\"no\"}"), "tm_demo"));
    }

    // ------------------------------------------------ a submission that came by gossip on `tm_demo`: only the verdict;
    // a peer's proof for it checked against the chain state
    const tb = try spend(a, &f.tx, 1, &.{.{ 1, &k.token }}, k.priv);
    const tb_beef = try withFund(a, f, tb);
    const h2 = mine(hdr.hash(&f.h1), tb.txid, 1_700_001_800);
    {
        const source: Value = .{ .map = try a.dupe(cbor.Entry, &.{
            .{ .key = "transport", .value = .{ .text = "libp2p" } },
            .{ .key = "topic", .value = .{ .text = "tm_demo" } },
        }) };
        const r = try inst.routeFrom(tb_beef, source);
        _ = try inst.begin(r.admit.event);
        _ = try inst.ingest(tb_beef);
        var ch = try inst.chain();
        const proof = gossip.Proof{ .txid = tb.txid, .block_hash = hdr.hash(&h2), .height = 2, .bump = try soloPath(a, 2, tb.txid) };
        try std.testing.expectEqualStrings("no header held at blockHeight", (try gossip.checkProof(a, &ch, proof, "libp2p:tm_demo-proof")).ignore);
        try inst.headers(&.{&h2});
        ch = try inst.chain();
        try std.testing.expectEqualStrings("the transaction is not held here", (try gossip.checkProof(a, &ch, .{ .txid = .{0x77} ** 32, .block_hash = hdr.hash(&h2), .height = 2, .bump = proof.bump }, "x")).ignore);
        try std.testing.expectEqualStrings("the bump does not parse", (try gossip.checkProof(a, &ch, .{ .txid = tb.txid, .block_hash = hdr.hash(&h2), .height = 2, .bump = "junk" }, "x")).ignore);
        try std.testing.expectEqualStrings("the bump is not at blockHeight", (try gossip.checkProof(a, &ch, .{ .txid = tb.txid, .block_hash = hdr.hash(&h2), .height = 1, .bump = proof.bump }, "x")).ignore);
        try std.testing.expectEqualStrings("blockHash is not our header at blockHeight", (try gossip.checkProof(a, &ch, .{ .txid = tb.txid, .block_hash = hdr.hash(&f.h1), .height = 2, .bump = proof.bump }, "x")).ignore);
        const other = gossip.Proof{ .txid = tb.txid, .block_hash = hdr.hash(&f.h1), .height = 1, .bump = try soloPath(a, 1, tb.txid) };
        try std.testing.expectEqualStrings("the bump's root is not our header's merkle root", (try gossip.checkProof(a, &ch, other, "x")).ignore);
        const good = (try gossip.checkProof(a, &ch, proof, "libp2p:tm_demo-proof")).event;
        try std.testing.expectEqualStrings("proof", good.getText("kind").?);
        try std.testing.expectEqualSlices(u8, &c.store.hashCid(.tx, tb.txid), good.getCid("subject").?);
        try std.testing.expectEqualStrings("libp2p:tm_demo-proof", good.getText("via").?);
        // The chain app records it (the event in box `chain`) and answers proven, with `via`.
        _ = try inst.chainStatus(tb.txid, "MINED", good.getBytes("path").?);
        const ok = try inst.answer(tb.txid, .{ .proven = .{ .via = "libp2p:tm_demo-proof" } });
        try std.testing.expect(ok.admitted);
        // Only `tm_demo-admit`: the submission came by gossip on `tm_demo`, the proof by gossip on `-proof`.
        try std.testing.expectEqual(@as(usize, 1), ok.published);
        try std.testing.expectEqualStrings("tm_demo-admit", inst.out_.sent.items[inst.out_.sent.items.len - 1].topic);
        try std.testing.expectEqualSlices(u8, try gossip.admitBody(a, tb.txid, "tm_demo", &.{0}, &.{}), inst.out_.sent.items[inst.out_.sent.items.len - 1].body);
        // Now proven in that block: a peer's copy is ignored.
        ch = try inst.chain();
        try std.testing.expectEqualStrings("already proven in that block", (try gossip.checkProof(a, &ch, proof, "libp2p:tm_demo-proof")).ignore);

        // A late duplicate on `tm_demo`: one decode, "already judged" (`unchanged`) — no topic manager runs.
        const identifies = inst.count("identify");
        const parses = beef.parses;
        try std.testing.expect((try inst.routeFrom(tb_beef, source)) == .unchanged);
        try std.testing.expectEqual(identifies, inst.count("identify"));
        try std.testing.expectEqual(parses + 1, beef.parses);
    }

    // ------------------------------------------------ peers' admits, recorded under `<app>/gossip` (key topic ‖ txid ‖ from)
    {
        var gs = try gossip.State.load(a, ms.store(), null);
        const m = try gossip.parseAdmit(a, try gossip.admitBody(a, tb.txid, "tm_demo", &.{0}, &.{}), "tm_demo");
        const pa: [33]u8 = .{0x02} ++ .{0xaa} ** 32;
        const pb: [33]u8 = .{0x03} ++ .{0xbb} ** 32;
        _ = try gs.record(try gossip.peerAdmitRecord(a, "tm_demo", m, &pa));
        _ = try gs.record(try gossip.peerAdmitRecord(a, "tm_demo", m, &pb));
        _ = try gs.record(try gossip.peerAdmitRecord(a, "tm_demo", m, &pa));
        const saved = try gs.save();
        var again = try gossip.State.load(a, ms.store(), saved);
        const admits = try again.admitsOf("tm_demo", tb.txid);
        try std.testing.expectEqual(@as(usize, 2), admits.len);
        const rec = try ms.store().getValue(a, admits[0]);
        try std.testing.expectEqualStrings("peer-admit", rec.getText("kind").?);
        try std.testing.expectEqualSlices(u8, &pa, rec.getBytes("from").?);
    }
}

/// Heads by name, for config.zig.
const HeadMap = struct {
    m: std.StringHashMapUnmanaged([]const u8) = .empty,
    fn head(ctx: *anyopaque, _: Allocator, name: []const u8) anyerror!?[]const u8 {
        const self: *HeadMap = @ptrCast(@alignCast(ctx));
        return self.m.get(name);
    }
    fn heads(self: *HeadMap) config.Heads {
        return .{ .ctx = self, .headFn = head };
    }
};

fn mapOf(a: Allocator, es: []const cbor.Entry) !Value {
    return .{ .map = try a.dupe(cbor.Entry, es) };
}

/// An app record (the head `<app>/app`'s root, as an install writes it): the roles and config.overlay.
fn appRecordOf(a: Allocator, s: Store, name: []const u8, engine: []const u8, tp: []const u8, lp: []const u8, topics: []const cbor.Entry, gossip_: []const cbor.Entry) ![]const u8 {
    return s.putValue(a, try mapOf(a, &.{
        .{ .key = "kind", .value = .{ .text = "app" } },
        .{ .key = "name", .value = .{ .text = name } },
        .{ .key = "programs", .value = try mapOf(a, &.{
            .{ .key = "overlay", .value = .{ .cid = engine } },
            .{ .key = "topic-demo", .value = .{ .cid = tp } },
            .{ .key = "lookup-demo", .value = .{ .cid = lp } },
        }) },
        .{ .key = "config", .value = try mapOf(a, &.{.{ .key = "overlay", .value = try mapOf(a, &.{
            .{ .key = "topics", .value = try mapOf(a, topics) },
            .{ .key = "lookups", .value = try mapOf(a, &.{.{ .key = "ls_demo", .value = try mapOf(a, &.{
                .{ .key = "program", .value = .{ .text = "lookup-demo" } },
                .{ .key = "topics", .value = .{ .array = try a.dupe(Value, &.{.{ .text = "tm_demo" }}) } },
            }) }}) },
            .{ .key = "gossip", .value = try mapOf(a, gossip_) },
        }) }}) },
    }));
}

/// `in` stepped on a thread whose origin runs `program`.
fn withThread(a: Allocator, s: Store, in: Value, program: []const u8) !Value {
    const t = try s.putValue(a, try mapOf(a, &.{
        .{ .key = "kind", .value = .{ .text = "thread" } },
        .{ .key = "program", .value = .{ .cid = program } },
    }));
    return .{ .map = try std.mem.concat(a, cbor.Entry, &.{ in.map, &.{.{ .key = "thread", .value = .{ .cid = t } }} }) };
}

test "the configuration (skein #72, #79): an installed engine's config.overlay from its app record at <app>/app, its heads under its app's name; the genesis defaults only without one" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var ms = c.store.MemStore.init(std.testing.allocator);
    defer ms.deinit();
    var inst = try Instance.init(a, &ms);
    const s = ms.store();
    var hm = HeadMap{};

    // Two overlay apps' engines on one instance: `overlay` and `amm`, each its own app record.
    const engine = try s.putValue(a, try mapOf(a, &.{
        .{ .key = "kind", .value = .{ .text = "program" } },
        .{ .key = "name", .value = .{ .text = "overlay" } },
        .{ .key = "app", .value = .{ .text = "overlay" } },
    }));
    const amm_engine = try s.putValue(a, try mapOf(a, &.{
        .{ .key = "kind", .value = .{ .text = "program" } },
        .{ .key = "name", .value = .{ .text = "overlay" } },
        .{ .key = "app", .value = .{ .text = "amm" } },
    }));
    const genesis_engine = try s.putValue(a, try mapOf(a, &.{
        .{ .key = "kind", .value = .{ .text = "program" } },
        .{ .key = "name", .value = .{ .text = "overlay" } },
    }));
    const two = [_]cbor.Entry{ .{ .key = "tm_demo", .value = .{ .text = "topic-demo" } }, .{ .key = "tm_two", .value = .{ .text = "topic-demo" } } };
    try hm.m.put(a, "overlay/app", try appRecordOf(a, s, "overlay", engine, inst.topic_prog, inst.lookup_prog, &two, &.{.{ .key = "tm_two", .value = .{ .boolean = false } }}));
    try hm.m.put(a, "amm/app", try appRecordOf(a, s, "amm", amm_engine, inst.topic_prog, inst.lookup_prog, two[1..], &.{}));
    // The bare name is no head (the #77 alias is gone): an app record there is not read.
    try hm.m.put(a, "overlay", try appRecordOf(a, s, "overlay", engine, inst.topic_prog, inst.lookup_prog, two[0..1], &.{}));

    const genesis_in = try mapOf(a, &.{
        .{ .key = "defaults", .value = try mapOf(a, &.{
            .{ .key = "walletNetwork", .value = .{ .text = "regtest" } },
            .{ .key = "overlayTopics", .value = .{ .text = "{\"tm_genesis\":\"topic-demo\"}" } },
        }) },
        .{ .key = "programs", .value = try mapOf(a, &.{.{ .key = "overlay", .value = .{ .cid = genesis_engine } }}) },
    });

    // A step (its thread's program is the installed engine): the app's config, the roles as programs, `app`.
    const step = try config.resolve(a, s, hm.heads(), try withThread(a, s, genesis_in, engine), null);
    const topics = try calls.configObject(a, step, "overlayTopics");
    try std.testing.expectEqual(@as(usize, 2), topics.count());
    try std.testing.expect(topics.contains("tm_demo") and topics.contains("tm_two") and !topics.contains("tm_genesis"));
    try std.testing.expectEqualStrings("overlay", calls.appOf(step));
    try std.testing.expectEqualStrings("regtest", step.get("defaults").?.getText("walletNetwork").?);
    try std.testing.expectEqualSlices(u8, inst.topic_prog, (try calls.programNamed(step, "topic-demo")).?);
    const ls_ = try calls.listeners(a, step, "tm_demo");
    try std.testing.expectEqual(@as(usize, 1), ls_.len);
    try std.testing.expectEqualStrings("ls_demo", ls_[0].service);
    try std.testing.expectEqual(@as(usize, 0), (try calls.listeners(a, step, "tm_two")).len);
    try std.testing.expect(try gossip.enabled(a, step, "tm_demo"));
    try std.testing.expect(!try gossip.enabled(a, step, "tm_two"));
    try std.testing.expectEqualSlices(u8, engine, step.getCid("engine").?);
    try std.testing.expectEqualStrings("overlay/ls_demo", try lookup.headName(a, calls.appOf(step), "ls_demo"));

    // The other app's engine: its own config, its own name — its heads `amm/…`.
    const amm = try config.resolve(a, s, hm.heads(), try withThread(a, s, genesis_in, amm_engine), null);
    try std.testing.expectEqualStrings("amm", calls.appOf(amm));
    try std.testing.expectEqual(@as(usize, 1), (try calls.configObject(a, amm, "overlayTopics")).count());
    try std.testing.expectEqualStrings("amm/ls_demo", try lookup.headName(a, calls.appOf(amm), "ls_demo"));
    try std.testing.expectEqualStrings("amm/gossip", try gossip.stateHead(a, calls.appOf(amm)));

    // A route's call (no thread; the matched dispatch row names the engine): the same.
    const arg = try mapOf(a, &.{.{ .key = "match", .value = try mapOf(a, &.{
        .{ .key = "address", .value = .{ .text = "tm_demo" } },
        .{ .key = "program", .value = .{ .cid = engine } },
        .{ .key = "fn", .value = .{ .text = "submit" } },
        .{ .key = "app", .value = .{ .text = "overlay" } },
    }) }});
    const called = try config.resolve(a, s, hm.heads(), genesis_in, arg);
    try std.testing.expectEqual(@as(usize, 2), (try calls.configObject(a, called, "overlayTopics")).count());

    // A genesis-wired engine (its record names no app), or a host's call: the genesis defaults; its name the program's.
    const wired = try config.resolve(a, s, hm.heads(), try withThread(a, s, genesis_in, genesis_engine), null);
    try std.testing.expect((try calls.configObject(a, wired, "overlayTopics")).contains("tm_genesis"));
    try std.testing.expect(wired.get("engine") == null);
    try std.testing.expectEqualStrings("overlay", calls.appOf(wired));
    try std.testing.expect((try calls.configObject(a, try config.resolve(a, s, hm.heads(), genesis_in, null), "overlayTopics")).contains("tm_genesis"));

    // A submission judged with the app's config: tm_demo is served.
    inst.in = called;
    const k = try keys(0x5a);
    const f = try fund(a, 0x72, 1, &k.p2pkh);
    try inst.headers(&.{&f.h1});
    const tok = try spend(a, &f.tx, 0, &.{ .{ 1, &k.token }, .{ 9_000, &k.p2pkh } }, k.priv);
    try std.testing.expect((try inst.route(try withFund(a, f, tok))) == .admit);
    try std.testing.expectEqual(@as(usize, 1), inst.count("identify"));

    // A reinstall (a new app record under `overlay/app`, tm_demo gone): read at the next call.
    try hm.m.put(a, "overlay/app", try appRecordOf(a, s, "overlay", engine, inst.topic_prog, inst.lookup_prog, two[1..], &.{}));
    const after = try config.resolve(a, s, hm.heads(), genesis_in, arg);
    const now_topics = try calls.configObject(a, after, "overlayTopics");
    try std.testing.expect(!now_topics.contains("tm_demo") and now_topics.contains("tm_two"));
}

/// The pointer record the kernel's door would write for `wire` (skein kernel-zig/src/beef.zig
/// `record`), its blocks put: each transaction under its txid, each BUMP's bytes as a raw block,
/// and every BUMP proving what it holds (the door checked it against chain/state).
fn pointerOf(a: Allocator, s: Store, wire: []const u8) ![]const u8 {
    const b = try beef.parse(a, wire);
    const txs = try a.alloc(Value, b.entries.len);
    const marks = try a.alloc(Value, b.entries.len);
    for (b.entries, txs, marks) |e, *t, *m| {
        const tc = try a.dupe(u8, &c.store.hashCid(.tx, e.txid));
        if (e.raw) |r| try s.putBlock(tc, r);
        t.* = .{ .cid = tc };
        m.* = switch (e.format) {
            .txid_only => .{ .text = "txid" },
            .raw_with_bump => .{ .uint = e.bump.? },
            .raw => .null,
        };
    }
    const bumps = try a.alloc(Value, b.bumps.len);
    for (b.bumps, bumps, 0..) |*p, *v, i| {
        const pb = try p.bytes(a);
        var d: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(pb, &d, .{});
        const pc = try a.dupe(u8, &([_]u8{ 0x01, 0x55, 0x12, 0x20 } ++ d));
        try s.putBlock(pc, pb);
        var proves: std.ArrayList(Value) = .empty;
        for (b.entries, 0..) |e, k| if (e.bump == i or (e.format == .raw and beef.bumpHas(p.*, e.txid))) try proves.append(a, .{ .uint = k });
        v.* = .{ .map = try a.dupe(cbor.Entry, &.{
            .{ .key = "height", .value = .{ .uint = p.block_height } },
            .{ .key = "path", .value = .{ .cid = pc } },
            .{ .key = "block", .value = .null },
            .{ .key = "proves", .value = .{ .array = proves.items } },
        }) };
    }
    return s.putValue(a, .{ .map = try a.dupe(cbor.Entry, &.{
        .{ .key = "kind", .value = .{ .text = "beef" } },
        .{ .key = "form", .value = .{ .text = if (b.atomic != null) "atomic" else "beef" } },
        .{ .key = "version", .value = .{ .uint = if (b.version == beef.V1) 1 else 2 } },
        .{ .key = "subject", .value = .{ .cid = try a.dupe(u8, &c.store.hashCid(.tx, b.subject().?)) } },
        .{ .key = "txs", .value = .{ .array = txs } },
        .{ .key = "marks", .value = .{ .array = marks } },
        .{ .key = "bumps", .value = .{ .array = bumps } },
    }) });
}

test "a submission by its pointer record (skein #121): read, not parsed or proven again; the event and the ingest carry its CID; beefOf gives the bytes back" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var ms = c.store.MemStore.init(std.testing.allocator);
    defer ms.deinit();
    var inst = try Instance.init(a, &ms);
    const k = try keys(0x42);
    const f = try fund(a, 0x11, 2, &k.p2pkh);
    try inst.headers(&.{&f.h1});
    const t1 = try spend(a, &f.tx, 0, &.{ .{ 1, &k.token }, .{ 9_000, &k.p2pkh } }, k.priv);
    const wire = try withFund(a, f, t1);
    const rc = try pointerOf(a, ms.store(), wire);
    const parses = beef.parses;
    const r = try inst.routeRecord(rc);
    try std.testing.expectEqual(parses, beef.parses);
    const ev = r.admit.event;
    try std.testing.expectEqualSlices(u8, rc, ev.getCid("beef").?);
    try std.testing.expect(ev.getBytes("beef") == null);
    _ = try inst.begin(ev);
    const sent = inst.wire_.last();
    try std.testing.expectEqualStrings("ingest", sent.body.getText("fn").?);
    try std.testing.expectEqualSlices(u8, rc, sent.body.get("args").?.getCid("beef").?);
    // The bytes the chain app and the gossip read back: exactly the submitted BEEF.
    try std.testing.expectEqualSlices(u8, wire, try c.record.beefOf(a, ms.store(), rc));
    // A record of something else: refused.
    const junk = try ms.store().putValue(a, .{ .map = try a.dupe(cbor.Entry, &.{.{ .key = "kind", .value = .{ .text = "other" } }}) });
    try std.testing.expectEqualStrings("InvalidBeef", (try inst.routeRecord(junk)).refused);
}

test "the applied record names the submission's BEEF as handed (#3): its pointer record, or the raw block of the bytes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var ms = c.store.MemStore.init(std.testing.allocator);
    defer ms.deinit();
    var inst = try Instance.init(a, &ms);
    const k = try keys(0x42);
    const f = try fund(a, 0x55, 2, &k.p2pkh);
    try inst.headers(&.{&f.h1});
    // By its pointer record: the record's CID.
    const t1 = try spend(a, &f.tx, 0, &.{.{ 1, &k.token }}, k.priv);
    const w1 = try withFund(a, f, t1);
    const rc = try pointerOf(a, ms.store(), w1);
    {
        const r = try inst.routeRecord(rc);
        _ = try inst.begin(r.admit.event);
        _ = try inst.ingest(w1);
        try std.testing.expectEqual(Chain.Outcome.accepted, try inst.chainStatus(t1.txid, "RECEIVED", null));
        const done = try inst.answer(t1.txid, .accepted);
        try std.testing.expect(done.admitted);
        var st = try inst.load();
        try std.testing.expectEqualSlices(u8, rc, (try st.appliedRecord("tm_demo", t1.txid)).?.getCid("beef").?);
    }
    // As bytes: a raw block of exactly the bytes received.
    const t2 = try spend(a, &f.tx, 1, &.{.{ 1, &k.token }}, k.priv);
    const w2 = try withFund(a, f, t2);
    _ = try inst.admitted(w2, t2.txid);
    var st = try inst.load();
    const b2 = (try st.appliedRecord("tm_demo", t2.txid)).?.getCid("beef").?;
    try std.testing.expectEqualSlices(u8, w2, ms.blocks.get(b2).?);
}

test "register and deregister (skein #120): the set under <app>/topics, the events with their handler, idempotent, an unknown role refused; a registered topic judged and seen by a lookup with no topic list" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var ms = c.store.MemStore.init(std.testing.allocator);
    defer ms.deinit();
    var inst = try Instance.init(a, &ms);
    const s = ms.store();
    var hm = HeadMap{};

    // A dynamic overlay: its manifest declares no topic; its lookup service names no topic list.
    const engine = try s.putValue(a, try mapOf(a, &.{
        .{ .key = "kind", .value = .{ .text = "program" } },
        .{ .key = "name", .value = .{ .text = "overlay" } },
        .{ .key = "app", .value = .{ .text = "overlay" } },
    }));
    try hm.m.put(a, "overlay/app", try s.putValue(a, try mapOf(a, &.{
        .{ .key = "kind", .value = .{ .text = "app" } },
        .{ .key = "name", .value = .{ .text = "overlay" } },
        .{ .key = "programs", .value = try mapOf(a, &.{
            .{ .key = "engine", .value = .{ .cid = engine } },
            .{ .key = "topic-demo", .value = .{ .cid = inst.topic_prog } },
            .{ .key = "lookup-demo", .value = .{ .cid = inst.lookup_prog } },
        }) },
        .{ .key = "config", .value = try mapOf(a, &.{.{ .key = "overlay", .value = try mapOf(a, &.{
            .{ .key = "lookups", .value = try mapOf(a, &.{.{ .key = "ls_demo", .value = try mapOf(a, &.{.{ .key = "program", .value = .{ .text = "lookup-demo" } }}) }}) },
        }) }}) },
    })));
    const genesis_in = try mapOf(a, &.{.{ .key = "defaults", .value = try mapOf(a, &.{.{ .key = "walletNetwork", .value = .{ .text = "regtest" } }}) }});
    const in = try withThread(a, s, genesis_in, engine);

    const before = try config.resolve(a, s, hm.heads(), in, null);
    try std.testing.expectEqual(@as(usize, 0), (try calls.configObject(a, before, "overlayTopics")).count());
    try std.testing.expectEqual(@as(usize, 0), (try calls.listeners(a, before, "tm_reg")).len);
    // The engine's own role is the app's name for its program record (here `engine`), what the events name.
    const self = try config.selfRole(a, s, before, null);
    try std.testing.expectEqualStrings("engine", self);
    const programs = before.get("programs").?;
    const args = struct {
        fn of(al: Allocator, topic_: []const u8, program: ?[]const u8) !Value {
            var es: std.ArrayList(cbor.Entry) = .empty;
            try es.append(al, .{ .key = "topic", .value = .{ .text = topic_ } });
            if (program) |p| try es.append(al, .{ .key = "program", .value = .{ .text = p } });
            return .{ .map = es.items };
        }
    }.of;

    // register: the set, the three subscribes with the engine's role and its function for each.
    const reg = (try topics_mod.register(a, &.{}, try args(a, "tm_reg", "topic-demo"), programs, self)).done;
    try std.testing.expectEqual(@as(usize, 1), reg.list.?.len);
    try std.testing.expectEqualStrings("topic-demo", reg.list.?[0].program);
    try std.testing.expect(reg.answer.get("active").?.boolean);
    try std.testing.expectEqualStrings("tm_reg", reg.answer.getText("topic").?);
    const want = [_][2][]const u8{ .{ "tm_reg", "submit" }, .{ "tm_reg-admit", "peerAdmit" }, .{ "tm_reg-proof", "peerProof" } };
    try std.testing.expectEqual(@as(usize, 3), reg.events.len);
    for (reg.events, want) |ev, w| {
        try std.testing.expectEqual(@as(usize, 4), ev.map.len);
        try std.testing.expectEqualStrings("subscribe", ev.getText("event").?);
        try std.testing.expectEqualStrings(w[0], ev.getText("topic").?);
        try std.testing.expectEqualStrings("engine", ev.getText("program").?);
        try std.testing.expectEqualStrings(w[1], ev.getText("fn").?);
    }
    // Idempotent: again, nothing written, nothing emitted.
    const again = (try topics_mod.register(a, reg.list.?, try args(a, "tm_reg", "topic-demo"), programs, self)).done;
    try std.testing.expect(again.list == null and again.events.len == 0 and again.answer.get("active").?.boolean);
    // Refused: an unknown role, no program, another program for a registered topic.
    try std.testing.expect(try topics_mod.register(a, reg.list.?, try args(a, "tm_x", "nope"), programs, self) == .refused);
    try std.testing.expect(try topics_mod.register(a, reg.list.?, try args(a, "tm_x", null), programs, self) == .refused);
    try std.testing.expect(try topics_mod.register(a, reg.list.?, try args(a, "tm_reg", "lookup-demo"), programs, self) == .refused);

    // The engine writes the set under `overlay/topics`: served from the next step or call on.
    const rec = try topics_mod.recordOf(a, reg.list.?);
    try std.testing.expectEqualDeep(reg.list.?, try topics_mod.entriesOf(a, rec));
    try std.testing.expectEqualStrings("overlay/topics", try topics_mod.headName(a, "overlay"));
    try hm.m.put(a, "overlay/topics", try s.putValue(a, rec));
    const now = try config.resolve(a, s, hm.heads(), in, null);
    const served = try calls.configObject(a, now, "overlayTopics");
    try std.testing.expectEqual(@as(usize, 1), served.count());
    try std.testing.expectEqualSlices(u8, inst.topic_prog, (try calls.configuredProgram(now, served, "tm_reg")).?);
    const ls_ = try calls.listeners(a, now, "tm_reg");
    try std.testing.expectEqual(@as(usize, 1), ls_.len);
    try std.testing.expectEqualStrings("ls_demo", ls_[0].service);
    try std.testing.expect(try gossip.enabled(a, now, "tm_reg"));

    // A submission to the registered topic: judged by its program, admitted, and the lookup sees it.
    inst.in = now;
    inst.topics = &.{"tm_reg"};
    const k = try keys(0x3c);
    const f = try fund(a, 0x4d, 1, &k.p2pkh);
    try inst.headers(&.{&f.h1});
    const tok = try spend(a, &f.tx, 0, &.{ .{ 1, &k.token }, .{ 9_000, &k.p2pkh } }, k.priv);
    const done = try inst.admitted(try withFund(a, f, tok), tok.txid);
    try std.testing.expect(done.admitted);
    try std.testing.expectEqual(@as(usize, 1), inst.count("identify"));
    var st = try inst.load();
    try std.testing.expect(try st.isApplied("tm_reg", tok.txid));
    try std.testing.expectEqual(@as(usize, 1), (try inst.look(&.{.{ .key = "topic", .value = .{ .text = "tm_reg" } }})).len);

    // deregister: the set without it, three unsubscribes {event, topic}; again, nothing.
    const dereg = (try topics_mod.deregister(a, reg.list.?, try args(a, "tm_reg", null))).done;
    try std.testing.expectEqual(@as(usize, 0), dereg.list.?.len);
    try std.testing.expect(!dereg.answer.get("active").?.boolean);
    for (dereg.events, want) |ev, w| {
        try std.testing.expectEqual(@as(usize, 2), ev.map.len);
        try std.testing.expectEqualStrings("unsubscribe", ev.getText("event").?);
        try std.testing.expectEqualStrings(w[0], ev.getText("topic").?);
    }
    const none = (try topics_mod.deregister(a, dereg.list.?, try args(a, "tm_reg", null))).done;
    try std.testing.expect(none.list == null and none.events.len == 0 and !none.answer.get("active").?.boolean);
    try hm.m.put(a, "overlay/topics", try s.putValue(a, try topics_mod.recordOf(a, dereg.list.?)));
    try std.testing.expect(!(try calls.configObject(a, try config.resolve(a, s, hm.heads(), in, null), "overlayTopics")).contains("tm_reg"));

    // A declared topic keeps its own program; a genesis-wired engine's role is its record's name.
    try hm.m.put(a, "overlay/topics", try s.putValue(a, try topics_mod.recordOf(a, &.{.{ .topic = "tm_demo", .program = "lookup-demo" }})));
    const g = try s.putValue(a, try mapOf(a, &.{ .{ .key = "kind", .value = .{ .text = "program" } }, .{ .key = "name", .value = .{ .text = "overlay" } } }));
    const wired = try mapOf(a, &.{
        .{ .key = "defaults", .value = try mapOf(a, &.{.{ .key = "overlayTopics", .value = .{ .text = "{\"tm_demo\":\"topic-demo\"}" } }}) },
        .{ .key = "programs", .value = try mapOf(a, &.{.{ .key = "topic-demo", .value = .{ .cid = inst.topic_prog } }}) },
    });
    const w = try config.resolve(a, s, hm.heads(), try withThread(a, s, wired, g), null);
    try std.testing.expectEqualStrings("overlay", try config.selfRole(a, s, w, null));
    const wt = try calls.configObject(a, w, "overlayTopics");
    try std.testing.expectEqualStrings("topic-demo", wt.get("tm_demo").?.string);
}
