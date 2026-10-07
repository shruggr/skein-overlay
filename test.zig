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
const routes = @import("src/routes.zig");

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

/// Messages to the instance itself, recorded (box, body); each gets a CID of its own. The answers to
/// submitters (shruggr/skein#112), recorded (to, box, body).
const FakeWire = struct {
    a: Allocator,
    sent: std.ArrayList(Sent) = .empty,
    answers: std.ArrayList(Answered) = .empty,
    const Sent = struct { box: []const u8, body: Value, cid: []const u8 };
    const Answered = struct { to: []const u8, box: []const u8, body: Value };

    fn answer(ctx: *anyopaque, _: Allocator, to: []const u8, box: []const u8, body: Value) anyerror!void {
        const self: *FakeWire = @ptrCast(@alignCast(ctx));
        try self.answers.append(self.a, .{ .to = try self.a.dupe(u8, to), .box = try self.a.dupe(u8, box), .body = body });
    }
    /// The result of the last answer (its `result`), or its `error`.
    fn lastAnswer(self: *FakeWire) Value {
        const b = self.answers.items[self.answers.items.len - 1].body;
        return b.get("result") orelse b.get("error").?;
    }

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
        return .{ .ctx = self, .sendFn = send, .answerFn = answer };
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
    /// What the last submission thread's first step did.
    begun: submit.Begun = .{},
    /// The last step's want / unwant events (state.zig `wantEvents`, shruggr/skein#112).
    events: []const Value = &.{},
    /// The peers' admits (`<app>/gossip`), when a test sets them.
    gossip_: ?*gossip.State = null,

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
        return .{ .a = self.a, .caller = self.caller(), .wire = self.wire_.wire(), .out = if (with_out) self.out_.out() else null, .st = st, .in = self.in, .thread = &cbor.cidOf("the thread"), .gossip = self.gossip_ };
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
        const b = try submit.begin(self.cx(&st, true), ev);
        self.events = try st.wantEvents();
        self.ov_root = try st.save();
        self.begun = b;
        // Each item's own ingest message (skein-overlay#1), by its txid: the subject's last.
        const its = try submit.itemsOf(self.a, ev);
        for (its, b.ingests) |it, m| try self.threads.put(self.a, it.txid, .{ .ev = ev, .ingest = m });
        return if (b.ingests.len > 0) b.ingests[b.ingests.len - 1] else "";
    }

    /// The submission's thread stepped with the chain app's answer.
    fn answer(self: *Instance, txid: [32]u8, ans: submit.Answer) !submit.Stepped {
        const t = self.threads.get(txid).?;
        var st = try self.load();
        const done = try submit.answered(self.cx(&st, true), t.ev, t.ingest, ans);
        self.events = try st.wantEvents();
        self.ov_root = try st.save();
        return done;
    }

    fn watchStart(self: *Instance, txid: [32]u8) !submit.Stepped {
        return self.watchStartOf(.{ .txid = txid, .ingest = "" });
    }
    fn watched(self: *Instance, txid: [32]u8, ans: submit.Answer) !submit.Stepped {
        return self.watchedOf(.{ .txid = txid, .ingest = "" }, ans);
    }
    /// A watch as its message names it (shruggr/skein#112: with the submission's source, `proven`).
    fn watchStartOf(self: *Instance, w: submit.Watch) !submit.Stepped {
        var st = try self.load();
        const done = try submit.watchStart(self.cx(&st, true), w);
        self.ov_root = try st.save();
        return done;
    }
    fn watchedOf(self: *Instance, w: submit.Watch, ans: submit.Answer) !submit.Stepped {
        var st = try self.load();
        const done = try submit.watched(self.cx(&st, true), w, ans);
        self.ov_root = try st.save();
        return done;
    }

    /// A peer's `-admit` for `txid` seen (the `peer-admit` step's want half, shruggr/skein#112).
    fn admitSeen(self: *Instance, txid: [32]u8, peer: []const u8) !void {
        var st = try self.load();
        try submit.admitSeen(self.cx(&st, true), "tm_demo", txid, peer);
        self.events = try st.wantEvents();
        self.ov_root = try st.save();
    }

    /// A submission by message (shruggr/skein#112): the step on `{fn: "submit", args}` from `source`.
    fn received(self: *Instance, args: Value, source: Value) !submit.Resumed {
        var st = try self.load();
        const r = try submit.received(self.cx(&st, true), args, source);
        self.events = try st.wantEvents();
        self.ov_root = try st.save();
        return r;
    }

    /// A `resume` step (skein-overlay#1): the paused submission of this subject routed again.
    fn resumed(self: *Instance, txid: [32]u8) !submit.Resumed {
        var st = try self.load();
        const r = try submit.resumed(self.cx(&st, true), txid);
        self.events = try st.wantEvents();
        self.ov_root = try st.save();
        return r;
    }

    /// POST /submit's handler (0.9.1): the first call, or a call again (`again`), over a write cache of its own.
    fn http(self: *Instance, req: Value, again: bool) !routes.HttpNext {
        var ovl = Overlay{ .inner = self.ms.store(), .arena = self.a };
        self.current = ovl.store();
        defer self.current = self.ms.store();
        const ch = try state.chainView(self.a, ovl.store(), self.chain_root, .regtest);
        var st = try state.State.load(self.a, ovl.store(), self.ov_root, ch);
        st.now = self.now;
        const sub = (try routes.httpRequest(self.a, req)).ok;
        const source = try mapOf(self.a, &.{
            .{ .key = "transport", .value = .{ .text = "http" } },
            .{ .key = "request", .value = .{ .cid = req.getCid("request").? } },
        });
        return if (again) routes.httpAgain(self.a, self.caller(), &st, self.in, sub, source) else routes.httpFirst(self.a, self.caller(), &st, self.in, sub, source);
    }

    /// A `wait` message's step (0.9.1): `w` about `txid`.
    fn waitOn(self: *Instance, txid: [32]u8, w: []const u8) !@typeInfo(@typeInfo(@TypeOf(submit.waitOn)).@"fn".return_type.?).error_union.payload {
        var st = try self.load();
        const r = try submit.waitOn(self.cx(&st, true), txid, w);
        self.ov_root = try st.save();
        return r;
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
        try std.testing.expectEqual(@as(usize, 2), inst.count("identify")); // the funding transaction, then the subject (oldest first, skein-overlay#1)
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
        _ = try gs.record(try gossip.peerAdmitRecord(a, "tm_demo", m, &pa, null));
        _ = try gs.record(try gossip.peerAdmitRecord(a, "tm_demo", m, &pb, null));
        _ = try gs.record(try gossip.peerAdmitRecord(a, "tm_demo", m, &pa, null));
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

    // A read route's filter (shruggr/skein#143: /lookup, the listings): the route names no program,
    // only its app; the app record's config, the engine its role `overlay`.
    const read_arg = try mapOf(a, &.{.{ .key = "match", .value = try mapOf(a, &.{
        .{ .key = "transport", .value = .{ .text = "http" } },
        .{ .key = "address", .value = .{ .text = "/amm/lookup" } },
        .{ .key = "app", .value = .{ .text = "amm" } },
    }) }});
    const read = try config.resolve(a, s, hm.heads(), genesis_in, read_arg);
    try std.testing.expectEqualStrings("amm", calls.appOf(read));
    try std.testing.expectEqual(@as(usize, 1), (try calls.configObject(a, read, "overlayTopics")).count());
    try std.testing.expectEqualSlices(u8, amm_engine, read.getCid("engine").?);

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
    try std.testing.expectEqual(@as(usize, 2), inst.count("identify")); // the funding transaction, then the subject (oldest first, skein-overlay#1)

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

    // register: the set, the three subscribes with the engine's role and its function for each;
    // `filter: "beef"` on `<topic>` only (its body is the BEEF; `-admit` / `-proof` are dag-cbor).
    const reg = (try topics_mod.register(a, &.{}, try args(a, "tm_reg", "topic-demo"), programs, self)).done;
    try std.testing.expectEqual(@as(usize, 1), reg.list.?.len);
    try std.testing.expectEqualStrings("topic-demo", reg.list.?[0].program);
    try std.testing.expect(reg.answer.get("active").?.boolean);
    try std.testing.expectEqualStrings("tm_reg", reg.answer.getText("topic").?);
    const want = [_][2][]const u8{ .{ "tm_reg", "submit" }, .{ "tm_reg-admit", "peerAdmit" }, .{ "tm_reg-proof", "peerProof" } };
    const want_filter = [_]?[]const u8{ "beef", null, null };
    try std.testing.expectEqual(@as(usize, 3), reg.events.len);
    for (reg.events, want, want_filter) |ev, w, wf| {
        try std.testing.expectEqual(@as(usize, if (wf == null) 4 else 5), ev.map.len);
        if (wf) |f| try std.testing.expectEqualStrings(f, ev.getText("filter").?) else try std.testing.expect(ev.get("filter") == null);
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
    try std.testing.expectEqual(@as(usize, 2), inst.count("identify")); // the funding transaction, then the subject (oldest first, skein-overlay#1)
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

test "register / deregister (skein #128): the set is the step's app's, the answer in the box it came in" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var ms = c.store.MemStore.init(std.testing.allocator);
    defer ms.deinit();
    const s = ms.store();
    const prog = try s.putValue(a, try mapOf(a, &.{.{ .key = "kind", .value = .{ .text = "program" } }}));
    const programs = try mapOf(a, &.{.{ .key = "topic-demo", .value = .{ .cid = prog } }});
    const app = "amm";

    for ([_][]const u8{ "amm/register", "amm" }) |box| {
        const args = try mapOf(a, &.{.{ .key = "box", .value = .{ .text = box } }});
        const reg = try mapOf(a, &.{
            .{ .key = "fn", .value = .{ .text = "register" } },
            .{ .key = "args", .value = try mapOf(a, &.{
                .{ .key = "topic", .value = .{ .text = "tm_x" } },
                .{ .key = "program", .value = .{ .text = "topic-demo" } },
            }) },
        });
        try std.testing.expectEqual(topics_mod.Asked.register, topics_mod.asked(reg));
        try std.testing.expectEqualStrings(box, topics_mod.answerBox(args, app));
        // The set is the step's app's, whatever the box.
        try std.testing.expectEqualStrings("amm/topics", try topics_mod.headName(a, app));
        const done = (try topics_mod.register(a, &.{}, reg.get("args").?, programs, "overlay")).done;
        try std.testing.expectEqual(@as(usize, 1), done.list.?.len);
        try std.testing.expect(done.answer.get("active").?.boolean);

        const dereg = try mapOf(a, &.{
            .{ .key = "fn", .value = .{ .text = "deregister" } },
            .{ .key = "args", .value = try mapOf(a, &.{.{ .key = "topic", .value = .{ .text = "tm_x" } }}) },
        });
        try std.testing.expectEqual(topics_mod.Asked.deregister, topics_mod.asked(dereg));
        const gone = (try topics_mod.deregister(a, done.list.?, dereg.get("args").?)).done;
        try std.testing.expectEqual(@as(usize, 0), gone.list.?.len);
        try std.testing.expect(!gone.answer.get("active").?.boolean);

        // Anything else is not a registration (the engine's watch path: the instance itself only).
        try std.testing.expectEqual(topics_mod.Asked.other, topics_mod.asked(try mapOf(a, &.{.{ .key = "fn", .value = .{ .text = "watch" } }})));
    }
    // No box on the step: the answer goes to the app's own.
    try std.testing.expectEqualStrings(app, topics_mod.answerBox(try mapOf(a, &.{}), app));
}


test "market and validator (skein #120, 0.9.0): config.overlay.market / .validator drive liveness / beacon on <topic>-live at register, unliveness / unbeacon at deregister; neither, nothing extra" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var ms = c.store.MemStore.init(std.testing.allocator);
    defer ms.deinit();
    const inst = try Instance.init(a, &ms);
    const s = ms.store();

    const engine = try s.putValue(a, try mapOf(a, &.{
        .{ .key = "kind", .value = .{ .text = "program" } },
        .{ .key = "name", .value = .{ .text = "overlay" } },
        .{ .key = "app", .value = .{ .text = "overlay" } },
    }));
    const genesis_in = try mapOf(a, &.{.{ .key = "defaults", .value = try mapOf(a, &.{
        .{ .key = "walletNetwork", .value = .{ .text = "regtest" } },
        // A genesis default the app's config replaces: an app naming no market is no market.
        .{ .key = "overlayMarket", .value = .{ .text = "{\"window\":5000}" } },
    }) }});
    const in = try withThread(a, s, genesis_in, engine);
    const reg_args = try mapOf(a, &.{
        .{ .key = "topic", .value = .{ .text = "tm_r" } },
        .{ .key = "program", .value = .{ .text = "topic-demo" } },
    });
    const dereg_args = try mapOf(a, &.{.{ .key = "topic", .value = .{ .text = "tm_r" } }});

    const Case = struct { market: ?u64, validator: ?u64 };
    for ([_]Case{ .{ .market = 40_000, .validator = null }, .{ .market = null, .validator = 30_000 }, .{ .market = 40_000, .validator = 30_000 }, .{ .market = null, .validator = null } }) |case| {
        var hm = HeadMap{};
        var ov: std.ArrayList(cbor.Entry) = .empty;
        if (case.market) |w| try ov.append(a, .{ .key = "market", .value = try mapOf(a, &.{.{ .key = "window", .value = .{ .uint = w } }}) });
        if (case.validator) |e| try ov.append(a, .{ .key = "validator", .value = try mapOf(a, &.{.{ .key = "every", .value = .{ .uint = e } }}) });
        try hm.m.put(a, "overlay/app", try s.putValue(a, try mapOf(a, &.{
            .{ .key = "kind", .value = .{ .text = "app" } },
            .{ .key = "name", .value = .{ .text = "overlay" } },
            .{ .key = "programs", .value = try mapOf(a, &.{
                .{ .key = "engine", .value = .{ .cid = engine } },
                .{ .key = "topic-demo", .value = .{ .cid = inst.topic_prog } },
            }) },
            .{ .key = "config", .value = try mapOf(a, &.{.{ .key = "overlay", .value = .{ .map = ov.items } }}) },
        })));
        const step = try config.resolve(a, s, hm.heads(), in, null);
        const roles = try config.rolesOf(a, step);
        try std.testing.expectEqual(case.market, roles.market);
        try std.testing.expectEqual(case.validator, roles.validator);
        const programs = step.get("programs").?;
        const self = try config.selfRole(a, s, step, null);

        // register: the three subscribes, then liveness (a market), then beacon (a validator), on tm_r-live.
        const reg = (try topics_mod.withRoles(a, try topics_mod.register(a, &.{}, reg_args, programs, self), true, roles)).done;
        const extra = @as(usize, if (case.market != null) 1 else 0) + @as(usize, if (case.validator != null) 1 else 0);
        try std.testing.expectEqual(3 + extra, reg.events.len);
        for (reg.events[0..3]) |ev| try std.testing.expectEqualStrings("subscribe", ev.getText("event").?);
        var i: usize = 3;
        if (case.market) |w| {
            const ev = reg.events[i];
            i += 1;
            try std.testing.expectEqual(@as(usize, 3), ev.map.len);
            try std.testing.expectEqualStrings("liveness", ev.getText("event").?);
            try std.testing.expectEqualStrings("tm_r-live", ev.getText("topic").?);
            try std.testing.expectEqual(w, ev.getUint("window").?);
        }
        if (case.validator) |e| {
            const ev = reg.events[i];
            try std.testing.expectEqual(@as(usize, 4), ev.map.len);
            try std.testing.expectEqualStrings("beacon", ev.getText("event").?);
            try std.testing.expectEqualStrings("tm_r-live", ev.getText("topic").?);
            try std.testing.expectEqual(e, ev.getUint("every").?);
            try std.testing.expectEqual(@as(usize, 0), ev.getBytes("body").?.len); // the beat needs no body
        }
        // Idempotent: registered already, nothing emitted, the roles' events neither.
        const again = (try topics_mod.withRoles(a, try topics_mod.register(a, reg.list.?, reg_args, programs, self), true, roles)).done;
        try std.testing.expect(again.list == null and again.events.len == 0);
        // A refusal stays one.
        try std.testing.expect(try topics_mod.withRoles(a, try topics_mod.register(a, &.{}, try mapOf(a, &.{}), programs, self), true, roles) == .refused);

        // deregister reverses: the three unsubscribes, then unliveness, then unbeacon.
        const dereg = (try topics_mod.withRoles(a, try topics_mod.deregister(a, reg.list.?, dereg_args), false, roles)).done;
        try std.testing.expectEqual(3 + extra, dereg.events.len);
        i = 3;
        if (case.market != null) {
            try std.testing.expectEqualStrings("unliveness", dereg.events[i].getText("event").?);
            try std.testing.expectEqualStrings("tm_r-live", dereg.events[i].getText("topic").?);
            try std.testing.expectEqual(@as(usize, 2), dereg.events[i].map.len);
            i += 1;
        }
        if (case.validator != null) {
            try std.testing.expectEqualStrings("unbeacon", dereg.events[i].getText("event").?);
            try std.testing.expectEqualStrings("tm_r-live", dereg.events[i].getText("topic").?);
            try std.testing.expectEqual(@as(usize, 2), dereg.events[i].map.len);
        }
        const none = (try topics_mod.withRoles(a, try topics_mod.deregister(a, dereg.list.?, dereg_args), false, roles)).done;
        try std.testing.expect(none.list == null and none.events.len == 0);
    }

    // A bad shape, or a window outside 1 000 ms .. a day: error.BadRoles (the engine refuses the registration).
    for ([_][]const u8{ "{\"window\":10}", "{}", "{\"window\":\"40s\"}", "40000" }) |text| {
        const bad = try mapOf(a, &.{.{ .key = "defaults", .value = try mapOf(a, &.{.{ .key = "overlayMarket", .value = .{ .text = text } }}) }});
        try std.testing.expectError(error.BadRoles, config.rolesOf(a, bad));
    }
    // A genesis-wired engine reads its defaults as they are.
    const wired = try config.rolesOf(a, genesis_in);
    try std.testing.expectEqual(@as(?u64, 5000), wired.market);
    try std.testing.expectEqual(@as(?u64, null), wired.validator);
}

test "the owner's switch (0.9.2, David 2026-10-07): market / validator on emits for every registered topic, off reverses; over config.overlay; idempotent; kept beside the set" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const list = [_]topics_mod.Entry{ .{ .topic = "tm_a", .program = "topic-demo" }, .{ .topic = "tm_b", .program = "topic-demo" } };
    const window = try mapOf(a, &.{.{ .key = "window", .value = .{ .uint = 40_000 } }});
    const every = try mapOf(a, &.{.{ .key = "every", .value = .{ .uint = 30_000 } }});
    const off = try mapOf(a, &.{.{ .key = "off", .value = .{ .boolean = true } }});
    const none: topics_mod.Roles = .{};

    try std.testing.expectEqual(topics_mod.Asked.market, topics_mod.asked(try mapOf(a, &.{.{ .key = "fn", .value = .{ .text = "market" } }})));
    try std.testing.expectEqual(topics_mod.Asked.validator, topics_mod.asked(try mapOf(a, &.{.{ .key = "fn", .value = .{ .text = "validator" } }})));

    // On, with two topics registered: liveness for each on <topic>-live; the answer the roles in effect.
    const on = (try topics_mod.switchRole(a, &list, .{}, none, .market, window)).done;
    try std.testing.expectEqual(topics_mod.Switch{ .on = 40_000 }, on.switches.?.market);
    try std.testing.expectEqual(topics_mod.Switch.unset, on.switches.?.validator);
    try std.testing.expectEqual(@as(usize, 2), on.events.len);
    for (on.events, [_][]const u8{ "tm_a-live", "tm_b-live" }) |ev, t| {
        try std.testing.expectEqualStrings("liveness", ev.getText("event").?);
        try std.testing.expectEqualStrings(t, ev.getText("topic").?);
        try std.testing.expectEqual(@as(u64, 40_000), ev.getUint("window").?);
    }
    try std.testing.expectEqual(@as(u64, 40_000), on.answer.get("market").?.getUint("window").?);
    try std.testing.expect(on.answer.get("validator") == null);
    // Idempotent: the same switch again writes and emits nothing; the answer the same.
    const again = (try topics_mod.switchRole(a, &list, on.switches.?, none, .market, window)).done;
    try std.testing.expect(again.switches == null and again.events.len == 0);
    try std.testing.expectEqual(@as(u64, 40_000), again.answer.get("market").?.getUint("window").?);
    // A new window replaces (the kernel keys liveness by (app, topic)): liveness again for each.
    const wider = (try topics_mod.switchRole(a, &list, on.switches.?, none, .market, try mapOf(a, &.{.{ .key = "window", .value = .{ .uint = 60_000 } }}))).done;
    try std.testing.expectEqual(@as(usize, 2), wider.events.len);
    try std.testing.expectEqual(@as(u64, 60_000), wider.events[0].getUint("window").?);

    // The validator likewise: beacon for each, the empty body.
    const v = (try topics_mod.switchRole(a, &list, on.switches.?, none, .validator, every)).done;
    try std.testing.expectEqual(@as(usize, 2), v.events.len);
    for (v.events) |ev| {
        try std.testing.expectEqualStrings("beacon", ev.getText("event").?);
        try std.testing.expectEqual(@as(u64, 30_000), ev.getUint("every").?);
        try std.testing.expectEqual(@as(usize, 0), ev.getBytes("body").?.len);
    }
    try std.testing.expect(v.answer.get("market") != null and v.answer.get("validator") != null);

    // Off reverses: unliveness for each, the market's switch kept as off; the validator untouched.
    const down = (try topics_mod.switchRole(a, &list, v.switches.?, none, .market, off)).done;
    try std.testing.expectEqual(topics_mod.Switch.off, down.switches.?.market);
    try std.testing.expectEqual(topics_mod.Switch{ .on = 30_000 }, down.switches.?.validator);
    try std.testing.expectEqual(@as(usize, 2), down.events.len);
    for (down.events, [_][]const u8{ "tm_a-live", "tm_b-live" }) |ev, t| {
        try std.testing.expectEqualStrings("unliveness", ev.getText("event").?);
        try std.testing.expectEqualStrings(t, ev.getText("topic").?);
        try std.testing.expectEqual(@as(usize, 2), ev.map.len);
    }
    try std.testing.expect(down.answer.get("market") == null and down.answer.get("validator") != null);
    const vdown = (try topics_mod.switchRole(a, &list, down.switches.?, none, .validator, off)).done;
    for (vdown.events) |ev| try std.testing.expectEqualStrings("unbeacon", ev.getText("event").?);
    try std.testing.expectEqual(@as(usize, 0), vdown.answer.map.len);
    // Off when off: nothing.
    const still = (try topics_mod.switchRole(a, &list, vdown.switches.?, none, .validator, off)).done;
    try std.testing.expect(still.switches == null and still.events.len == 0);

    // Precedence over the configuration: a manifest market, switched off, is off — unliveness for each;
    // register / deregister from then on emit by the roles in effect (none for the market).
    const cfg: topics_mod.Roles = .{ .market = 40_000 };
    const over = (try topics_mod.switchRole(a, &list, .{}, cfg, .market, off)).done;
    try std.testing.expectEqual(@as(usize, 2), over.events.len);
    try std.testing.expectEqualStrings("unliveness", over.events[0].getText("event").?);
    const eff = topics_mod.effective(over.switches.?, cfg);
    try std.testing.expectEqual(@as(?u64, null), eff.market);
    try std.testing.expectEqual(@as(?u64, 40_000), topics_mod.effective(.{}, cfg).market); // never switched: the manifest's
    var ms = c.store.MemStore.init(std.testing.allocator);
    defer ms.deinit();
    const prog = try ms.store().putValue(a, try mapOf(a, &.{.{ .key = "kind", .value = .{ .text = "program" } }}));
    const programs = try mapOf(a, &.{.{ .key = "topic-demo", .value = .{ .cid = prog } }});
    const reg_args = try mapOf(a, &.{ .{ .key = "topic", .value = .{ .text = "tm_c" } }, .{ .key = "program", .value = .{ .text = "topic-demo" } } });
    const reg = (try topics_mod.withRoles(a, try topics_mod.register(a, &list, reg_args, programs, "overlay"), true, eff)).done;
    try std.testing.expectEqual(@as(usize, 3), reg.events.len); // the subscribes only
    // Switched on at the manifest's own value: written (precedence from then on), nothing emitted.
    const same = (try topics_mod.switchRole(a, &list, .{}, cfg, .market, window)).done;
    try std.testing.expect(same.switches != null and same.events.len == 0);
    // Switched on over a manifest that names none: the switch's value.
    const reg2 = (try topics_mod.withRoles(a, try topics_mod.register(a, &list, reg_args, programs, "overlay"), true, topics_mod.effective(on.switches.?, none))).done;
    try std.testing.expectEqualStrings("liveness", reg2.events[3].getText("event").?);
    // No topic registered: the switch is kept, nothing emitted.
    const empty = (try topics_mod.switchRole(a, &.{}, .{}, none, .validator, every)).done;
    try std.testing.expect(empty.switches != null and empty.events.len == 0);

    // Kept beside the set in <app>/topics, read back; a record without them is unswitched.
    const rec = try topics_mod.recordWith(a, &list, down.switches.?);
    try std.testing.expectEqualDeep(@as([]const topics_mod.Entry, &list), try topics_mod.entriesOf(a, rec));
    const back = try topics_mod.switchesOf(rec);
    try std.testing.expectEqual(topics_mod.Switch.off, back.market);
    try std.testing.expectEqual(topics_mod.Switch{ .on = 30_000 }, back.validator);
    try std.testing.expect(rec.get("market").?.get("off").?.boolean);
    try std.testing.expectEqual(@as(u64, 30_000), rec.get("validator").?.getUint("every").?);
    const plain = try topics_mod.switchesOf(try topics_mod.recordOf(a, &list));
    try std.testing.expectEqual(topics_mod.Switch.unset, plain.market);
    try std.testing.expectEqual(topics_mod.Switch.unset, plain.validator);
    try std.testing.expectEqual(topics_mod.Switch.unset, (try topics_mod.switchesOf(null)).market);

    // Refused: another shape, a value outside 1 000 ms .. a day, the other role's field, off: false.
    for ([_]Value{
        try mapOf(a, &.{.{ .key = "window", .value = .{ .uint = 10 } }}),
        try mapOf(a, &.{}),
        every,
        try mapOf(a, &.{.{ .key = "off", .value = .{ .boolean = false } }}),
        .{ .text = "on" },
    }) |bad| try std.testing.expect(try topics_mod.switchRole(a, &list, .{}, none, .market, bad) == .refused);
}

/// fund (mined) → t1 (mints a token) → t2 (spends it into a new one), both unproven.
const Chain3 = struct { k: Keys, f: Fund, t1: Spent, t2: Spent };

fn chain3(a: Allocator, inst: *Instance) !Chain3 {
    const k = try keys(0x42);
    const f = try fund(a, 0x33, 1, &k.p2pkh);
    try inst.headers(&.{&f.h1});
    const t1 = try spend(a, &f.tx, 0, &.{ .{ 1, &k.token }, .{ 9_000, &k.p2pkh } }, k.priv);
    const t2 = try spend(a, &t1.tx, 0, &.{.{ 1, &k.token }}, k.priv);
    return .{ .k = k, .f = f, .t1 = t1, .t2 = t2 };
}

fn uintsOf(v: ?Value) ![]const u64 {
    const xs = v.?.array;
    const out = try std.testing.allocator.alloc(u64, xs.len);
    for (xs, out) |x, *o| o.* = x.uint;
    return out;
}

fn expectUints(want: []const u64, v: ?Value) !void {
    const got = try uintsOf(v);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualSlices(u64, want, got);
}

test "oldest first (skein-overlay#1): a two-transaction BEEF judged in order, each ingested on its own, admitted in order on its own answer" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var ms = c.store.MemStore.init(std.testing.allocator);
    defer ms.deinit();
    var inst = try Instance.init(a, &ms);
    const x = try chain3(a, &inst);
    const two = try beef.serialize(a, .{ .version = beef.V2, .bumps = x.f.bumps, .entries = try a.dupe(beef.Entry, &.{
        x.f.entry,
        .{ .txid = x.t1.txid, .format = .raw, .raw = x.t1.raw, .tx = x.t1.tx },
        .{ .txid = x.t2.txid, .format = .raw, .raw = x.t2.raw, .tx = x.t2.tx },
    }) });

    // The route: fund, t1, t2 judged in that order; t2's previous coins count t1's token, which the
    // walk took before it (not admitted yet).
    const r = try inst.route(two);
    try std.testing.expectEqual(@as(usize, 3), inst.count("identify"));
    const ev = r.admit.event;
    try std.testing.expectEqualSlices(u8, &x.t2.txid, &r.admit.txid);
    const earlier = ev.getArray("earlier").?;
    try std.testing.expectEqual(@as(usize, 1), earlier.len);
    try std.testing.expectEqualStrings(&hdr.toHex(x.t1.txid), earlier[0].getText("txid").?);
    try expectUints(&.{0}, earlier[0].getArray("topics").?[0].get("outputsToAdmit"));
    try expectUints(&.{}, earlier[0].getArray("topics").?[0].get("previousCoins"));
    const subj = ev.getArray("topics").?[0];
    try expectUints(&.{0}, subj.get("previousCoins"));
    try expectUints(&.{0}, subj.get("coinsToRetain"));
    try expectUints(&.{0}, subj.get("outputsToAdmit"));

    // The thread: one ingest each, oldest first — t1's Atomic BEEF cut from the submission, then
    // the submission's BEEF as handed for the subject.
    const sent0 = inst.wire_.sent.items.len;
    _ = try inst.begin(ev);
    try std.testing.expectEqual(@as(usize, 2), inst.begun.ingests.len);
    try std.testing.expectEqual(sent0 + 2, inst.wire_.sent.items.len);
    const m1 = inst.wire_.sent.items[sent0];
    try std.testing.expectEqualStrings("chain", m1.box);
    const cut = try beef.parse(a, m1.body.get("args").?.getBytes("beef").?);
    try std.testing.expectEqualSlices(u8, &x.t1.txid, &cut.atomic.?);
    try std.testing.expectEqual(@as(usize, 2), cut.entries.len);
    try std.testing.expectEqual(@as(usize, 1), cut.bumps.len);
    try std.testing.expectEqualSlices(u8, two, inst.wire_.sent.items[sent0 + 1].body.get("args").?.getBytes("beef").?);
    try std.testing.expect(try inst.pending(x.t1.txid));
    try std.testing.expect(try inst.pending(x.t2.txid));
    // The chain app takes both (the Atomic BEEF verifies as a BEEF of its own).
    try std.testing.expectEqual(c.state.Status.unproven, try inst.ingest(m1.body.get("args").?.getBytes("beef").?));
    try std.testing.expectEqual(c.state.Status.unproven, try inst.ingest(two));

    // t2 accepted first: heard, not admitted — t1, before it, is unanswered.
    _ = try inst.chainStatus(x.t2.txid, "RECEIVED", null);
    const first = try inst.answer(x.t2.txid, .accepted);
    try std.testing.expect(!first.admitted and !first.done);
    // It awaits both ingests still: t1's answer, and t2's later ones (a proof would replace `heard`).
    try std.testing.expectEqual(@as(usize, 2), first.awaiting.len);
    try std.testing.expectEqualSlices(u8, inst.threads.get(x.t1.txid).?.ingest, first.awaiting[0]);
    try std.testing.expectEqual(@as(usize, 0), inst.count("admitted"));
    var st = try inst.load();
    try std.testing.expectEqualStrings("accepted", (try st.pendingRecord(x.t2.txid)).?.getText("heard").?);

    // t1 accepted: t1 admitted, then t2 — in order, in this step; a watch each; t2 retains t1's token.
    _ = try inst.chainStatus(x.t1.txid, "RECEIVED", null);
    const both = try inst.answer(x.t1.txid, .accepted);
    try std.testing.expect(both.admitted and both.done);
    try std.testing.expectEqual(@as(usize, 2), both.admissions.len);
    try std.testing.expectEqualSlices(u8, &x.t1.txid, &both.admissions[0].txid);
    try std.testing.expectEqualSlices(u8, &x.t2.txid, &both.admissions[1].txid);
    try std.testing.expectEqualSlices(u32, &.{0}, both.admissions[1].applied[0].coins_to_retain);
    try std.testing.expectEqual(@as(usize, 2), both.watches.len);
    try std.testing.expectEqual(@as(usize, 2), inst.count("admitted"));
    try std.testing.expectEqual(@as(usize, 1), inst.count("spent"));
    // Gossip: t1's verdict; the submission (raw) and t2's verdict.
    try std.testing.expectEqual(@as(usize, 3), both.published);
    st = try inst.load();
    try std.testing.expect(try st.isApplied("tm_demo", x.t1.txid));
    try std.testing.expect(try st.isApplied("tm_demo", x.t2.txid));
    const sp = (try st.spender("tm_demo", x.t1.txid, 0)).?;
    try std.testing.expect(sp.retained and std.mem.eql(u8, &sp.txid, &x.t2.txid));
    try std.testing.expectEqual(@as(usize, 1), (try st.inTopic("tm_demo", false)).len);
    // Resubmitted: judged before.
    try std.testing.expect((try inst.route(two)) == .unchanged);
}

/// A libp2p peer (its peer ID's multihash, as a gossip message's `from` carries it), by a letter.
fn peerId(comptime letter: u8) []const u8 {
    return &([_]u8{ 0x00, 0x25, 0x08, 0x02, 0x12, 0x21, 0x02 } ++ [_]u8{letter} ** 32);
}

/// A gossip message's source (routes.zig `sourceOf`): published on tm_demo by `peer`.
fn fromGossip(a: Allocator, peer: []const u8) !Value {
    return .{ .map = try a.dupe(cbor.Entry, &.{
        .{ .key = "transport", .value = .{ .text = "libp2p" } },
        .{ .key = "topic", .value = .{ .text = "tm_demo" } },
        .{ .key = "from", .value = .{ .bytes = peer } },
    }) };
}

/// A frame on the overlay's want-answer stream (skein-overlay#1): sent by `peer`.
fn fromStream(a: Allocator, peer: []const u8) !Value {
    return .{ .map = try a.dupe(cbor.Entry, &.{
        .{ .key = "transport", .value = .{ .text = "libp2p" } },
        .{ .key = "protocol", .value = .{ .text = "/skein/overlay/beef/1.0.0" } },
        .{ .key = "from", .value = .{ .bytes = peer } },
    }) };
}

/// An Atomic BEEF of `t` with its funding transaction (mined, its BUMP) — what a holder sends for a want.
fn atomicWithFund(a: Allocator, f: Fund, t: Spent) ![]const u8 {
    return beef.serialize(a, .{ .version = beef.V2, .atomic = t.txid, .bumps = f.bumps, .entries = try a.dupe(beef.Entry, &.{ f.entry, .{ .txid = t.txid, .format = .raw, .raw = t.raw, .tx = t.tx } }) });
}

/// The pause and its resume, recorded: the want events, the messages, the state.
const PauseRun = struct { root: []const u8, wants: []const []const u8, sent: []const []const u8 };

fn pauseAndResume(a: Allocator, ms: *c.store.MemStore) !PauseRun {
    var inst = try Instance.init(a, ms);
    const x = try chain3(a, &inst);
    var wants: std.ArrayList([]const u8) = .empty;
    const child = try atomic(a, x.t2);

    // ------------------------------------------------ t2 alone: its parent t1 is neither in the BEEF nor held — paused
    const peer_a = peerId('A');
    const r = try inst.routeFrom(child, try fromGossip(a, peer_a));
    try std.testing.expect(r == .paused);
    try std.testing.expectEqual(@as(usize, 1), r.paused.waiting.len);
    try std.testing.expectEqualSlices(u8, &x.t1.txid, &r.paused.waiting[0]);
    try std.testing.expectEqual(@as(usize, 0), inst.count("identify")); // judged by nothing yet
    const ev = r.paused.event;
    try std.testing.expectEqualStrings("tm_demo", ev.getArray("requested").?[0].text);
    try std.testing.expectEqualStrings(&hdr.toHex(x.t1.txid), ev.getArray("waiting").?[0].text);
    const sent0 = inst.wire_.sent.items.len;
    _ = try inst.begin(ev);
    try std.testing.expect(inst.begun.paused);
    try std.testing.expectEqual(sent0, inst.wire_.sent.items.len); // nothing to the chain app
    try std.testing.expectEqual(@as(usize, 1), inst.begun.wants.len);
    const w = inst.begun.wants[0];
    try std.testing.expectEqualStrings("want", w.getText("event").?);
    try std.testing.expectEqualStrings(&hdr.toHex(x.t1.txid), w.getText("txid").?);
    try std.testing.expectEqualStrings("tm_demo", w.getText("topic").?);
    try std.testing.expectEqualSlices(u8, peer_a, w.getBytes("peer").?);
    try std.testing.expectEqual(@as(usize, 4), w.map.len);
    try wants.append(a, try cbor.encode(a, w));
    // The pending record: the submission, waiting on t1, its event to route again; no ingest.
    var st = try inst.load();
    const rec = (try st.pendingRecord(x.t2.txid)).?;
    try std.testing.expectEqualStrings("submission", rec.getText("kind").?);
    try std.testing.expectEqualStrings(&hdr.toHex(x.t1.txid), rec.getArray("waiting").?[0].text);
    try std.testing.expect(rec.getCid("event") != null and rec.getCid("ingest") == null);
    try std.testing.expect(try st.isPaused(x.t2.txid));
    try std.testing.expect(try st.isWanted(x.t1.txid));
    try std.testing.expect(try st.hasWant(x.t1.txid, "tm_demo", peer_a));
    // Resubmitted as it was by the same peer: paused again; (t1, A) stands already, so no second `want`.
    const again = try inst.routeFrom(child, try fromGossip(a, peer_a));
    _ = try inst.begin(again.paused.event);
    try std.testing.expectEqual(@as(usize, 0), inst.begun.wants.len);

    // ------------------------------------------------ t1 arrives by a later submission: admitted, and the paused t2 resumed
    const parent = try withFund(a, x.f, x.t1);
    const rp = try inst.route(parent);
    _ = try inst.begin(rp.admit.event);
    _ = try inst.ingest(parent);
    _ = try inst.chainStatus(x.t1.txid, "RECEIVED", null);
    const got = try inst.answer(x.t1.txid, .accepted);
    try std.testing.expect(got.admitted and got.done);
    try std.testing.expectEqual(@as(usize, 1), got.resumes.len);
    const rm = inst.wire_.last();
    try std.testing.expectEqualSlices(u8, rm.cid, got.resumes[0]);
    try std.testing.expectEqualStrings("overlay", rm.box);
    try std.testing.expectEqualStrings("resume", rm.body.getText("fn").?);
    try std.testing.expectEqualStrings(&hdr.toHex(x.t2.txid), rm.body.get("args").?.getText("txid").?);
    st = try inst.load();
    try std.testing.expect(!(try st.isWanted(x.t1.txid)));

    // The resume step: t2 routed again — whole now (t1 held), judged with t1's token live — the
    // submission's thread launched on the new event; the pause dropped.
    const res = try inst.resumed(x.t2.txid);
    try std.testing.expect(res == .launch);
    try std.testing.expect(!(try inst.pending(x.t2.txid)));
    try expectUints(&.{0}, res.launch.getArray("topics").?[0].get("previousCoins"));
    _ = try inst.begin(res.launch);
    _ = try inst.ingest(child);
    _ = try inst.chainStatus(x.t2.txid, "RECEIVED", null);
    const done = try inst.answer(x.t2.txid, .accepted);
    try std.testing.expect(done.admitted and done.done);
    try std.testing.expectEqualSlices(u32, &.{0}, done.applied[0].coins_to_retain);
    // Resumed again (a stale resume): not paused, nothing to do.
    try std.testing.expect((try inst.resumed(x.t2.txid)) == .none);

    var sent: std.ArrayList([]const u8) = .empty;
    for (inst.wire_.sent.items) |m| try sent.append(a, try cbor.encode(a, .{ .map = try a.dupe(cbor.Entry, &.{
        .{ .key = "box", .value = .{ .text = m.box } },
        .{ .key = "body", .value = m.body },
    }) }));
    return .{ .root = inst.ov_root.?, .wants = wants.items, .sent = sent.items };
}

test "a missing parent pauses (skein-overlay#1): the pending record, one `want`; the parent by a later submission resumes it; replayed, identical" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var ms1 = c.store.MemStore.init(std.testing.allocator);
    defer ms1.deinit();
    var ms2 = c.store.MemStore.init(std.testing.allocator);
    defer ms2.deinit();
    const one = try pauseAndResume(a, &ms1);
    const two = try pauseAndResume(a, &ms2);
    // The same inputs, the same records: the state, the events and the messages.
    try std.testing.expectEqualSlices(u8, one.root, two.root);
    try std.testing.expectEqual(one.wants.len, two.wants.len);
    for (one.wants, two.wants) |x, y| try std.testing.expectEqualSlices(u8, x, y);
    try std.testing.expectEqual(one.sent.len, two.sent.len);
    for (one.sent, two.sent) |x, y| try std.testing.expectEqualSlices(u8, x, y);
    try std.testing.expectEqual(ms1.count(), ms2.count());
}

test "a wanted parent no topic takes (skein-overlay#1): ingested all the same, and the paused child resumed" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var ms = c.store.MemStore.init(std.testing.allocator);
    defer ms.deinit();
    var inst = try Instance.init(a, &ms);
    const k = try keys(0x42);
    const f = try fund(a, 0x44, 1, &k.p2pkh);
    try inst.headers(&.{&f.h1});
    const plain = try spend(a, &f.tx, 0, &.{.{ 9_500, &k.p2pkh }}, k.priv);
    const mint = try spend(a, &plain.tx, 0, &.{.{ 1, &k.token }}, k.priv);
    const child = try atomic(a, mint);
    _ = try inst.begin((try inst.routeFrom(child, try fromGossip(a, peerId('A')))).paused.event);
    try std.testing.expectEqual(@as(usize, 1), inst.begun.wants.len);
    // The parent's own BEEF: no topic takes it, but it is wanted — the subject, ingested.
    const pb = try withFund(a, f, plain);
    const rp = try inst.route(pb);
    try std.testing.expect(rp.admit.event.getBool("wanted").?);
    try std.testing.expectEqual(@as(usize, 0), rp.admit.event.getArray("topics").?.len);
    _ = try inst.begin(rp.admit.event);
    try std.testing.expectEqual(@as(usize, 1), inst.begun.ingests.len);
    _ = try inst.ingest(pb);
    _ = try inst.chainStatus(plain.txid, "RECEIVED", null);
    const got = try inst.answer(plain.txid, .accepted);
    try std.testing.expect(got.done);
    try std.testing.expectEqual(@as(usize, 1), got.resumes.len);
    try std.testing.expect(!(try inst.applied(plain.txid)));
    const res = try inst.resumed(mint.txid);
    try std.testing.expect(res == .launch);
    try expectUints(&.{0}, res.launch.getArray("topics").?[0].get("outputsToAdmit"));
}

test "wants by (txid, topic, peer) (shruggr/skein#112): each gossiping peer its own want; the answer on the stream resumes the pause and clears them" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var ms = c.store.MemStore.init(std.testing.allocator);
    defer ms.deinit();
    var inst = try Instance.init(a, &ms);
    const x = try chain3(a, &inst);
    const child = try atomic(a, x.t2);
    const pa = peerId('A');
    const pb = peerId('B');

    // Gossiped by A, then by B: two wants for t1, one per peer, each with its own event.
    _ = try inst.begin((try inst.routeFrom(child, try fromGossip(a, pa))).paused.event);
    try std.testing.expectEqual(@as(usize, 1), inst.begun.wants.len);
    var st = try inst.load();
    try std.testing.expect(try st.wantsFrom(x.t2.txid, &.{x.t1.txid}, &.{"tm_demo"}, pa)); // the route would ignore A again
    try std.testing.expect(!(try st.wantsFrom(x.t2.txid, &.{x.t1.txid}, &.{"tm_demo"}, pb)));
    _ = try inst.begin((try inst.routeFrom(child, try fromGossip(a, pb))).paused.event);
    try std.testing.expectEqual(@as(usize, 1), inst.begun.wants.len);
    try std.testing.expectEqualSlices(u8, pb, inst.begun.wants[0].getBytes("peer").?);
    st = try inst.load();
    const from = try st.wantedFrom(x.t1.txid);
    try std.testing.expectEqual(@as(usize, 2), from.len);
    try std.testing.expectEqualSlices(u8, pa, from[0]);
    try std.testing.expectEqualSlices(u8, pb, from[1]);
    try std.testing.expectEqual(@as(usize, 2), try st.map("wants").count());
    const ws = try st.waitersOf(x.t1.txid);
    try std.testing.expectEqual(@as(usize, 1), ws.len);
    try std.testing.expectEqualSlices(u8, &x.t2.txid, &ws[0]);

    // An early resume (t1 not here yet): its wants cleared and recorded again, against A and B; no new event.
    const early = try inst.resumed(x.t2.txid);
    try std.testing.expect(early == .paused);
    try std.testing.expectEqual(@as(usize, 0), early.paused.wants.len);
    st = try inst.load();
    try std.testing.expectEqual(@as(usize, 2), try st.map("wants").count());
    try std.testing.expect(try st.hasWant(x.t1.txid, "tm_demo", pa) and try st.hasWant(x.t1.txid, "tm_demo", pb));

    // The stream's route is in the manifest (shruggr/skein#143): kernel.beef, then overlay.submit.
    const stream_route = (try manifestRoute(a, "libp2p", "/skein/overlay/beef/1.0.0")).?;
    try std.testing.expectEqualStrings("overlay.submit", stream_route.get("handler").?.string);
    try expectFilters(stream_route, &.{"kernel.beef"});

    // B answers on the stream: t1's Atomic BEEF, routed with the topics its waiter requested, as from B.
    const pbeef = try atomicWithFund(a, x.f, x.t1);
    const wanted = try submit.wantedTopics(a, &st, x.t1.txid);
    try std.testing.expectEqual(@as(usize, 1), wanted.len);
    try std.testing.expectEqualStrings("tm_demo", wanted[0]);
    try std.testing.expectEqual(@as(usize, 0), (try submit.wantedTopics(a, &st, x.f.txid)).len); // not wanted: the route ignores it
    inst.topics = wanted;
    const rp = try inst.routeFrom(pbeef, try fromStream(a, pb));
    try std.testing.expect(rp == .admit);
    _ = try inst.begin(rp.admit.event);
    _ = try inst.ingest(pbeef);
    _ = try inst.chainStatus(x.t1.txid, "RECEIVED", null);
    const got = try inst.answer(x.t1.txid, .accepted);
    try std.testing.expect(got.admitted and got.done);
    // Its verdict on tm_demo-admit; the BEEF itself not published again (it came on a stream).
    try std.testing.expectEqual(@as(usize, 1), got.published);
    try std.testing.expectEqual(@as(usize, 1), got.resumes.len);
    st = try inst.load();
    try std.testing.expectEqual(@as(usize, 0), try st.map("wants").count()); // every want for t1 cleared
    const res = try inst.resumed(x.t2.txid);
    try std.testing.expect(res == .launch);
    try std.testing.expect(!(try inst.pending(x.t2.txid)));
}

test "a BEEF on the stream that lacks a parent itself (skein-overlay#1): paused, its wants against the sender and every peer that announced what needs it; the chain resumes in order" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var ms = c.store.MemStore.init(std.testing.allocator);
    defer ms.deinit();
    var inst = try Instance.init(a, &ms);
    const x = try chain3(a, &inst);
    const pa = peerId('A');
    const pr = peerId('R');

    // t2 gossiped by A, lacking t1: (t1, A).
    _ = try inst.begin((try inst.routeFrom(try atomic(a, x.t2), try fromGossip(a, pa))).paused.event);
    // R answers with t1 alone: it lacks the funding transaction — paused, wanted from R and from A.
    const t1_only = try atomic(a, x.t1);
    const r1 = try inst.routeFrom(t1_only, try fromStream(a, pr));
    try std.testing.expect(r1 == .paused);
    _ = try inst.begin(r1.paused.event);
    try std.testing.expectEqual(@as(usize, 2), inst.begun.wants.len);
    var st = try inst.load();
    try std.testing.expect(try st.hasWant(x.f.txid, "tm_demo", pa) and try st.hasWant(x.f.txid, "tm_demo", pr));
    try std.testing.expect(try st.hasWant(x.t1.txid, "tm_demo", pa));

    // A answers with the funding transaction (mined): wanted, no topic takes it — ingested; t1 resumed.
    const fbeef = try beef.serialize(a, .{ .version = beef.V2, .atomic = x.f.txid, .bumps = x.f.bumps, .entries = try a.dupe(beef.Entry, &.{x.f.entry}) });
    inst.topics = try submit.wantedTopics(a, &st, x.f.txid);
    const rf = try inst.routeFrom(fbeef, try fromStream(a, pa));
    try std.testing.expect(rf == .admit);
    _ = try inst.begin(rf.admit.event);
    _ = try inst.ingest(fbeef);
    const gf = try inst.answer(x.f.txid, .{ .proven = .{} });
    try std.testing.expectEqual(@as(usize, 1), gf.resumes.len);
    const r1b = try inst.resumed(x.t1.txid);
    try std.testing.expect(r1b == .launch);
    st = try inst.load();
    try std.testing.expect(!(try st.isWanted(x.f.txid)));
    try std.testing.expect(try st.hasWant(x.t1.txid, "tm_demo", pa)); // t2's want stands until t1 comes

    // t1 admitted: t2 resumed, whole.
    _ = try inst.begin(r1b.launch);
    _ = try inst.ingest(t1_only);
    _ = try inst.chainStatus(x.t1.txid, "RECEIVED", null);
    const g1 = try inst.answer(x.t1.txid, .accepted);
    try std.testing.expect(g1.admitted);
    try std.testing.expectEqual(@as(usize, 1), g1.resumes.len);
    try std.testing.expect((try inst.resumed(x.t2.txid)) == .launch);
    st = try inst.load();
    try std.testing.expectEqual(@as(usize, 0), try st.map("wants").count());
}

// ---------------------------------------------------------------- 0.7.2 (shruggr/skein#112)

/// A submission's source by message: from `sender` in box `overlay`, about the message `request`.
fn byMessage(a: Allocator, sender: []const u8, request: []const u8) !Value {
    return mapOf(a, &.{
        .{ .key = "transport", .value = .{ .text = "mailbox" } },
        .{ .key = "box", .value = .{ .text = "overlay" } },
        .{ .key = "sender", .value = .{ .bytes = sender } },
        .{ .key = "request", .value = .{ .cid = request } },
    });
}

/// The submission message's args: `{beef, topics: ["tm_demo"]}`.
fn submitArgs(a: Allocator, bytes: []const u8) !Value {
    return mapOf(a, &.{
        .{ .key = "beef", .value = .{ .bytes = bytes } },
        .{ .key = "topics", .value = .{ .array = try a.dupe(Value, &.{.{ .text = "tm_demo" }}) } },
    });
}

fn expectWant(ev: Value, kind: []const u8, txid: [32]u8, peer: ?[]const u8) !void {
    try std.testing.expectEqualStrings(kind, ev.getText("event").?);
    try std.testing.expectEqualStrings(&hdr.toHex(txid), ev.getText("txid").?);
    try std.testing.expectEqualStrings("tm_demo", ev.getText("topic").?);
    if (peer) |p| {
        try std.testing.expectEqualSlices(u8, p, ev.getBytes("peer").?);
        try std.testing.expectEqual(@as(usize, 4), ev.map.len);
    } else {
        try std.testing.expect(ev.get("peer") == null);
        try std.testing.expectEqual(@as(usize, 3), ev.map.len);
    }
}

test "wants {txid, topic, peer?} (shruggr/skein#112): a gossip pause wants the parent from its publisher and every peer whose -admit was seen, more as admits arrive; each want cleared by `unwant` when the parent comes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var ms = c.store.MemStore.init(std.testing.allocator);
    defer ms.deinit();
    var inst = try Instance.init(a, &ms);
    const x = try chain3(a, &inst);
    const child = try atomic(a, x.t2);
    const pa = peerId('A');
    const pb = peerId('B');
    const pc = peerId('C');

    // B's `-admit` for t2 was seen before A's gossip of it arrives.
    var gs = try gossip.State.load(a, ms.store(), null);
    const kb: [33]u8 = .{0x02} ++ .{'B'} ** 32;
    _ = try gs.record(try gossip.peerAdmitRecord(a, "tm_demo", .{ .txid = x.t2.txid, .outputs_to_admit = &.{0}, .coins_to_retain = &.{0} }, &kb, pb));
    inst.gossip_ = &gs;

    // Gossiped by A: paused; two wants for t1 under tm_demo — A (the publisher) and B (its admit).
    _ = try inst.begin((try inst.routeFrom(child, try fromGossip(a, pa))).paused.event);
    try std.testing.expectEqual(@as(usize, 2), inst.events.len);
    try expectWant(inst.events[0], "want", x.t1.txid, pa);
    try expectWant(inst.events[1], "want", x.t1.txid, pb);
    try std.testing.expectEqual(@as(usize, 2), inst.begun.wants.len);

    // C's admit of t2 arrives: one more want; a second sighting of C, none.
    try inst.admitSeen(x.t2.txid, pc);
    try std.testing.expectEqual(@as(usize, 1), inst.events.len);
    try expectWant(inst.events[0], "want", x.t1.txid, pc);
    try inst.admitSeen(x.t2.txid, pc);
    try std.testing.expectEqual(@as(usize, 0), inst.events.len);
    var st = try inst.load();
    try std.testing.expectEqual(@as(usize, 3), try st.map("wants").count());
    // An admit of something not paused here wants nothing.
    try inst.admitSeen(x.t1.txid, pc);
    try std.testing.expectEqual(@as(usize, 0), inst.events.len);

    // t1 comes (a submission of it): admitted; every want for it ends — an `unwant` each — and t2 is resumed.
    const parent = try withFund(a, x.f, x.t1);
    _ = try inst.begin((try inst.route(parent)).admit.event);
    _ = try inst.ingest(parent);
    _ = try inst.chainStatus(x.t1.txid, "RECEIVED", null);
    const got = try inst.answer(x.t1.txid, .accepted);
    try std.testing.expectEqual(@as(usize, 1), got.resumes.len);
    try std.testing.expectEqual(@as(usize, 3), inst.events.len);
    try expectWant(inst.events[0], "unwant", x.t1.txid, pa);
    try expectWant(inst.events[1], "unwant", x.t1.txid, pb);
    try expectWant(inst.events[2], "unwant", x.t1.txid, pc);
    // The resume: whole now, launched; no want left to clear.
    try std.testing.expect((try inst.resumed(x.t2.txid)) == .launch);
    try std.testing.expectEqual(@as(usize, 0), inst.events.len);
    st = try inst.load();
    try std.testing.expectEqual(@as(usize, 0), try st.map("wants").count());
}

/// A POST /submit request as the front door hands it: X-Topics `tm_demo`, the BEEF, the request record.
fn httpReq(a: Allocator, bytes: []const u8, name: []const u8) !Value {
    return mapOf(a, &.{
        .{ .key = "headers", .value = try mapOf(a, &.{.{ .key = "x-topics", .value = .{ .text = "tm_demo" } }}) },
        .{ .key = "body", .value = .{ .bytes = bytes } },
        .{ .key = "request", .value = .{ .cid = try a.dupe(u8, &cbor.cidOf(name)) } },
    });
}

/// The answer's status and its JSON body.
fn httpAnswer(a: Allocator, next: routes.HttpNext) !struct { status: u64, json: std.json.Value, v: Value } {
    const v = next.answer;
    return .{ .status = v.getUint("status").?, .json = try std.json.parseFromSliceLeaky(std.json.Value, a, v.getBytes("body").?, .{}), .v = v };
}

test "POST /submit is BRC-22 and synchronous (0.9.1, shruggr/skein#112, David 2026-10-07): the thread launched and waited on, the STEAK; several waiters on one thread; a resubmission judged before answered from the state, nothing run again; undecided 503 with Retry-After; rejected 400; no topic 200 with the empty STEAK" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var ms = c.store.MemStore.init(std.testing.allocator);
    defer ms.deinit();
    var inst = try Instance.init(a, &ms);
    const x = try chain3(a, &inst);
    const parent = try withFund(a, x.f, x.t1);

    // Not a submission, or not a BEEF: 400 at once.
    const no_topics = try mapOf(a, &.{.{ .key = "body", .value = .{ .bytes = parent } }});
    try std.testing.expectEqual(@as(u64, 400), (try routes.httpRequest(a, no_topics)).refused.getUint("status").?);
    const junk = try inst.http(try httpReq(a, "junk", "r0"), false);
    try std.testing.expectEqual(@as(u64, 400), (try httpAnswer(a, junk)).status);

    // Whole: the submission's thread launched on the submit event; the request waits on it (#66).
    const first = try inst.http(try httpReq(a, parent, "r1"), false);
    try std.testing.expect(first == .launch);
    try std.testing.expectEqualStrings("submit", first.launch.getText("kind").?);
    try std.testing.expect(first.launch.get("source").?.getCid("request") != null);
    _ = try inst.begin(first.launch);
    const thread = cbor.cidOf("the thread"); // the thread the harness steps (Instance.cx)
    // Called again before a verdict (a deadline, say): the thread carries it — wait on it.
    const mid = try inst.http(try httpReq(a, parent, "r1"), true);
    try std.testing.expectEqualSlices(u8, &thread, mid.await_thread);
    // A second request for the same submission while it is in progress: waits on that same thread.
    const second = try inst.http(try httpReq(a, parent, "r2"), false);
    try std.testing.expectEqualSlices(u8, &thread, second.await_thread);
    const judged = inst.count("identify");

    // The chain app accepts it: admitted; the thread comes to rest and every waiter answers the STEAK.
    _ = try inst.ingest(parent);
    _ = try inst.chainStatus(x.t1.txid, "RECEIVED", null);
    try std.testing.expect((try inst.answer(x.t1.txid, .accepted)).admitted);
    for ([_][]const u8{ "r1", "r2" }) |r| {
        const ans = try httpAnswer(a, try inst.http(try httpReq(a, parent, r), true));
        try std.testing.expectEqual(@as(u64, 200), ans.status);
        const steak = ans.json.object.get("tm_demo").?.object;
        try std.testing.expectEqual(@as(usize, 1), steak.get("outputsToAdmit").?.array.items.len);
        try std.testing.expectEqual(@as(i64, 0), steak.get("outputsToAdmit").?.array.items[0].integer);
    }
    // Completed: a resubmission is answered from the state with the first submission's STEAK, nothing re-run.
    const again = try httpAnswer(a, try inst.http(try httpReq(a, parent, "r3"), false));
    try std.testing.expectEqual(@as(u64, 200), again.status);
    try std.testing.expectEqual(@as(usize, 1), again.json.object.get("tm_demo").?.object.get("outputsToAdmit").?.array.items.len);
    try std.testing.expectEqual(judged, inst.count("identify"));

    // Nothing decided: the thread ended without a verdict (the chain app's error answer) — 503 with Retry-After; nothing launched again.
    const child = try spend(a, &x.t1.tx, 0, &.{.{ 1, &x.k.token }}, x.k.priv);
    const child_beef = try atomic(a, child);
    const c1 = try inst.http(try httpReq(a, child_beef, "r4"), false);
    try std.testing.expect(c1 == .launch);
    _ = try inst.begin(c1.launch);
    _ = try inst.answer(child.txid, .{ .failed = "the chain app could not take it" });
    const undecided = try httpAnswer(a, try inst.http(try httpReq(a, child_beef, "r4"), true));
    try std.testing.expectEqual(@as(u64, 503), undecided.status);
    try std.testing.expectEqualStrings("30", undecided.v.get("headers").?.getText("retry-after").?);

    // Rejected by the chain app: 400.
    const c2 = try inst.http(try httpReq(a, child_beef, "r5"), false);
    try std.testing.expect(c2 == .launch);
    _ = try inst.begin(c2.launch);
    _ = try inst.ingest(child_beef);
    _ = try inst.chainStatus(child.txid, "REJECTED", null);
    _ = try inst.answer(child.txid, .{ .rejected = "REJECTED" });
    const rejected = try httpAnswer(a, try inst.http(try httpReq(a, child_beef, "r5"), true));
    try std.testing.expectEqual(@as(u64, 400), rejected.status);

    // Valid, taken by no topic (a plain payment): 200 with the empty STEAK (BRC-22), nothing launched.
    const pay = try spend(a, &x.t1.tx, 1, &.{.{ 500, &x.k.p2pkh }}, x.k.priv);
    const none = try httpAnswer(a, try inst.http(try httpReq(a, try atomic(a, pay), "r6"), false));
    try std.testing.expectEqual(@as(u64, 200), none.status);
    try std.testing.expectEqual(@as(usize, 0), none.json.object.get("tm_demo").?.object.get("outputsToAdmit").?.array.items.len);
}

test "POST /submit whose subject no topic takes, only a transaction before it (0.9.1): 200 with the empty STEAK at once, the submit event admitted into the app's box for its thread (nothing launched)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var ms = c.store.MemStore.init(std.testing.allocator);
    defer ms.deinit();
    var inst = try Instance.init(a, &ms);
    const x = try chain3(a, &inst);
    const pay = try spend(a, &x.t1.tx, 1, &.{.{ 500, &x.k.p2pkh }}, x.k.priv);
    const both = try beef.serialize(a, .{ .version = beef.V2, .bumps = x.f.bumps, .entries = try a.dupe(beef.Entry, &.{
        x.f.entry,
        .{ .txid = x.t1.txid, .format = .raw, .raw = x.t1.raw, .tx = x.t1.tx },
        .{ .txid = pay.txid, .format = .raw, .raw = pay.raw, .tx = pay.tx },
    }) });
    const next = try inst.http(try httpReq(a, both, "r1"), false);
    const ans = try httpAnswer(a, next);
    try std.testing.expectEqual(@as(u64, 200), ans.status);
    try std.testing.expectEqual(@as(usize, 0), ans.json.object.get("tm_demo").?.object.get("outputsToAdmit").?.array.items.len);
    const admit = ans.v.getArray("admit").?;
    try std.testing.expectEqual(@as(usize, 1), admit.len);
    try std.testing.expectEqualStrings("overlay", admit[0].getText("box").?);
    const ev = admit[0].get("event").?;
    try std.testing.expectEqualStrings("submit", ev.getText("kind").?);
    try std.testing.expectEqual(@as(usize, 0), ev.getArray("topics").?.len);
    try std.testing.expectEqual(@as(usize, 1), ev.getArray("earlier").?.len);
}

test "POST /submit on a paused submission (0.9.1): the pause recorded by its thread, the request waits for it to end (`wait`), several waiters; paused again they wait on; the parent comes, the resumed thread wakes them, each waits on it and answers the STEAK" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var ms = c.store.MemStore.init(std.testing.allocator);
    defer ms.deinit();
    var inst = try Instance.init(a, &ms);
    const x = try chain3(a, &inst);
    const child = try atomic(a, x.t2);

    // t2 lacks t1: no 400 — the paused event's thread launched (it records the pause and its want of no peer).
    const first = try inst.http(try httpReq(a, child, "r1"), false);
    try std.testing.expect(first == .launch);
    try std.testing.expect(first.launch.get("waiting") != null);
    _ = try inst.begin(first.launch);
    try std.testing.expect(inst.begun.paused);
    try std.testing.expectEqual(@as(usize, 1), inst.begun.wants.len);
    try expectWant(inst.begun.wants[0], "want", x.t1.txid, null);
    // That thread at rest, the request waits for the pause to end; so does a second request.
    const r1 = try inst.http(try httpReq(a, child, "r1"), true);
    try std.testing.expectEqualSlices(u8, &x.t2.txid, &r1.wait_pause);
    const r2 = try inst.http(try httpReq(a, child, "r2"), false);
    try std.testing.expectEqualSlices(u8, &x.t2.txid, &r2.wait_pause);
    // Their `wait` messages: each joins the pause's waiters (once).
    const w1 = try a.dupe(u8, &cbor.cidOf("wait 1"));
    const w2 = try a.dupe(u8, &cbor.cidOf("wait 2"));
    try std.testing.expectEqualStrings("waiting", @tagName(try inst.waitOn(x.t2.txid, w1)));
    try std.testing.expectEqualStrings("waiting", @tagName(try inst.waitOn(x.t2.txid, w2)));
    try std.testing.expectEqualStrings("waiting", @tagName(try inst.waitOn(x.t2.txid, w2)));
    var st = try inst.load();
    try std.testing.expectEqual(@as(usize, 2), (try submit.wakesOf(a, (try st.pendingRecord(x.t2.txid)).?)).len);
    try std.testing.expect(try st.isPaused(x.t2.txid));
    const waits = submit.waitBody;
    try std.testing.expectEqualStrings("wait", (try waits(a, x.t2.txid)).getText("fn").?);

    // Routed again while t1 is still missing (a stale resume): paused again, the waiters kept, none answered.
    const sent0 = inst.wire_.sent.items.len;
    try std.testing.expect((try inst.resumed(x.t2.txid)) == .paused);
    st = try inst.load();
    try std.testing.expectEqual(@as(usize, 2), (try submit.wakesOf(a, (try st.pendingRecord(x.t2.txid)).?)).len);
    try std.testing.expectEqual(sent0, inst.wire_.sent.items.len);

    // t1 comes: t2 resumed whole; its thread's first step answers both waits (replyTo), once its pending record names it.
    const parent = try withFund(a, x.f, x.t1);
    _ = try inst.begin((try inst.route(parent)).admit.event);
    _ = try inst.ingest(parent);
    _ = try inst.chainStatus(x.t1.txid, "RECEIVED", null);
    try std.testing.expectEqual(@as(usize, 1), (try inst.answer(x.t1.txid, .accepted)).resumes.len);
    const res = try inst.resumed(x.t2.txid);
    try std.testing.expect(res == .launch);
    try std.testing.expectEqual(@as(usize, 2), res.launch.getArray("wakes").?.len);
    const before = inst.wire_.sent.items.len;
    _ = try inst.begin(res.launch);
    var woken: usize = 0;
    for (inst.wire_.sent.items[before..]) |m| {
        if (!std.mem.eql(u8, m.body.getText("fn") orelse "", "wait")) continue;
        try std.testing.expectEqualStrings("overlay", m.box);
        const to = m.body.getCid("replyTo").?;
        try std.testing.expect(std.mem.eql(u8, to, w1) or std.mem.eql(u8, to, w2));
        try std.testing.expectEqualStrings(&hdr.toHex(x.t2.txid), m.body.get("result").?.getText("txid").?);
        woken += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), woken);
    // Woken, each request waits on the resumed thread, then answers the STEAK.
    const thread = cbor.cidOf("the thread");
    try std.testing.expectEqualSlices(u8, &thread, (try inst.http(try httpReq(a, child, "r1"), true)).await_thread);
    _ = try inst.ingest(child);
    _ = try inst.chainStatus(x.t2.txid, "RECEIVED", null);
    try std.testing.expect((try inst.answer(x.t2.txid, .accepted)).admitted);
    for ([_][]const u8{ "r1", "r2" }) |r| {
        const ans = try httpAnswer(a, try inst.http(try httpReq(a, child, r), true));
        try std.testing.expectEqual(@as(u64, 200), ans.status);
        try std.testing.expectEqual(@as(usize, 1), ans.json.object.get("tm_demo").?.object.get("outputsToAdmit").?.array.items.len);
    }
    // A `wait` once the pause is over is answered at once.
    const late = try a.dupe(u8, &cbor.cidOf("wait 3"));
    try std.testing.expectEqualStrings("answered", @tagName(try inst.waitOn(x.t2.txid, late)));
    try std.testing.expectEqualSlices(u8, late, inst.wire_.last().body.getCid("replyTo").?);
}

test "a submission by message is unchanged by the synchronous route (0.9.1): `<app>/submit` routes it, answered by messages; 0.7.3–0.9.0's POST /submit `submission` event (a log written then) is still stepped as one" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var ms = c.store.MemStore.init(std.testing.allocator);
    defer ms.deinit();
    var inst = try Instance.init(a, &ms);
    const x = try chain3(a, &inst);
    const child = try atomic(a, x.t2);
    const request = try a.dupe(u8, &cbor.cidOf("the request"));
    const ev = try mapOf(a, &.{
        .{ .key = "kind", .value = .{ .text = "submission" } },
        .{ .key = "body", .value = try mapOf(a, &.{
            .{ .key = "fn", .value = .{ .text = "submit" } },
            .{ .key = "args", .value = try submitArgs(a, child) },
        }) },
        .{ .key = "request", .value = .{ .cid = request } },
        .{ .key = "transport", .value = .{ .text = "http" } },
    });
    const m = try submit.submissionOf(a, ev, "overlay/submit");
    try std.testing.expectEqualStrings("overlay/submit", m.source.getText("box").?);
    try std.testing.expectEqualSlices(u8, request, m.source.getCid("request").?);
    // t2 lacks t1 — paused, no 400; one want, no peer; a pause is internal.
    const r = try inst.received(m.body.get("args").?, m.source);
    try std.testing.expect(r == .paused);
    try std.testing.expectEqual(@as(usize, 1), inst.events.len);
    try expectWant(inst.events[0], "want", x.t1.txid, null);
    try std.testing.expectEqual(@as(usize, 0), inst.wire_.answers.items.len);
    // t1 comes: the want ends; t2 resumed and launched.
    const parent = try withFund(a, x.f, x.t1);
    _ = try inst.begin((try inst.route(parent)).admit.event);
    _ = try inst.ingest(parent);
    _ = try inst.chainStatus(x.t1.txid, "RECEIVED", null);
    const got = try inst.answer(x.t1.txid, .accepted);
    try std.testing.expectEqual(@as(usize, 1), got.resumes.len);
    try expectWant(inst.events[0], "unwant", x.t1.txid, null);
    try std.testing.expect((try inst.resumed(x.t2.txid)) == .launch);
}

test "answers to the submitter's box (shruggr/skein#112): admitted with status pending and the STEAK; a proof; a reorg's proof; rejected; a dupe; a refusal; bad args" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var ms = c.store.MemStore.init(std.testing.allocator);
    defer ms.deinit();
    var inst = try Instance.init(a, &ms);
    const x = try chain3(a, &inst);
    const alice: [33]u8 = .{0x03} ++ .{0xa1} ** 32;
    const m1 = try a.dupe(u8, &cbor.cidOf("message 1"));
    const src1 = try byMessage(a, &alice, m1);

    // ------------------------------------------------ t1 by message: launched; accepted → admitted, pending, its STEAK
    const parent = try withFund(a, x.f, x.t1);
    const r = try inst.received(try submitArgs(a, parent), src1);
    try std.testing.expect(r == .launch);
    try std.testing.expectEqualSlices(u8, &alice, r.launch.get("source").?.getBytes("sender").?);
    try std.testing.expectEqual(@as(usize, 0), inst.wire_.answers.items.len); // nothing until the chain app answers
    _ = try inst.begin(r.launch);
    _ = try inst.ingest(parent);
    _ = try inst.chainStatus(x.t1.txid, "RECEIVED", null);
    const got = try inst.answer(x.t1.txid, .accepted);
    try std.testing.expect(got.admitted);
    try std.testing.expectEqual(@as(usize, 1), inst.wire_.answers.items.len);
    const ans = inst.wire_.answers.items[0];
    try std.testing.expectEqualSlices(u8, &alice, ans.to);
    try std.testing.expectEqualStrings("overlay", ans.box);
    try std.testing.expectEqualStrings("submit", ans.body.getText("fn").?);
    try std.testing.expectEqualSlices(u8, m1, ans.body.getCid("request").?);
    try std.testing.expectEqualSlices(u8, m1, ans.body.getCid("replyTo").?);
    const adm = ans.body.get("result").?;
    try std.testing.expectEqualStrings("admitted", adm.getText("state").?);
    try std.testing.expectEqualStrings("pending", adm.getText("status").?);
    try std.testing.expectEqualStrings(&hdr.toHex(x.t1.txid), adm.getText("txid").?);
    try expectUints(&.{0}, adm.get("steak").?.get("tm_demo").?.get("outputsToAdmit"));

    // The watch it sent carries the submitter; at its start (unproven) it awaits.
    const wm = inst.wire_.sent.items[inst.wire_.sent.items.len - 1];
    try std.testing.expectEqualStrings("watch", wm.body.getText("fn").?);
    const w = try submit.watchOf(wm.body.get("args").?);
    try std.testing.expectEqualSlices(u8, &alice, w.source.?.getBytes("sender").?);
    try std.testing.expect(!(try inst.watchStartOf(w)).done);

    // ------------------------------------------------ a proof: relayed; the watch hands over to one for the next proof
    const block1 = try a.dupe(u8, &c.store.hashCid(.block, .{0x11} ** 32));
    const p1 = try mapOf(a, &.{ .{ .key = "state", .value = .{ .text = "proven" } }, .{ .key = "block", .value = .{ .cid = block1 } }, .{ .key = "height", .value = .{ .uint = 2 } } });
    const one = try inst.watchedOf(w, .{ .proven = .{ .result = p1 } });
    try std.testing.expect(one.done);
    var pr = inst.wire_.lastAnswer();
    try std.testing.expectEqualStrings("proven", pr.getText("state").?);
    try std.testing.expectEqualStrings(&hdr.toHex(x.t1.txid), pr.getText("txid").?);
    try std.testing.expectEqualSlices(u8, block1, pr.getCid("block").?);
    try std.testing.expectEqual(@as(u64, 2), pr.getUint("height").?);
    const w2 = try submit.watchOf(inst.wire_.last().body.get("args").?);
    try std.testing.expect(w2.proven);
    // The next watch, at its start, does not relay the same proof again.
    const n_answers = inst.wire_.answers.items.len;
    try std.testing.expect(!(try inst.watchStartOf(w2)).done);
    try std.testing.expectEqual(n_answers, inst.wire_.answers.items.len);

    // ------------------------------------------------ a reorg: another proof, a different block — relayed too, not re-published
    const block2 = try a.dupe(u8, &c.store.hashCid(.block, .{0x22} ** 32));
    const p2 = try mapOf(a, &.{ .{ .key = "state", .value = .{ .text = "proven" } }, .{ .key = "block", .value = .{ .cid = block2 } }, .{ .key = "height", .value = .{ .uint = 3 } } });
    const pubs = inst.out_.sent.items.len;
    _ = try inst.watchedOf(w2, .{ .proven = .{ .result = p2 } });
    pr = inst.wire_.lastAnswer();
    try std.testing.expectEqualStrings("proven", pr.getText("state").?);
    try std.testing.expectEqualSlices(u8, block2, pr.getCid("block").?);
    try std.testing.expectEqual(@as(u64, 3), pr.getUint("height").?);
    try std.testing.expectEqual(pubs, inst.out_.sent.items.len);
    try std.testing.expectEqual(n_answers + 1, inst.wire_.answers.items.len);

    // ------------------------------------------------ the same t1 again: judged before — admitted, from the state
    const m2 = try a.dupe(u8, &cbor.cidOf("message 2"));
    try std.testing.expect((try inst.received(try submitArgs(a, parent), try byMessage(a, &alice, m2))) == .dropped);
    const dup = inst.wire_.lastAnswer();
    try std.testing.expectEqualStrings("admitted", dup.getText("state").?);
    try std.testing.expectEqualStrings("pending", dup.getText("status").?);
    try expectUints(&.{0}, dup.get("steak").?.get("tm_demo").?.get("outputsToAdmit"));

    // ------------------------------------------------ t2 by message, rejected by the chain app: rejected, with the reason
    const m3 = try a.dupe(u8, &cbor.cidOf("message 3"));
    const r2 = try inst.received(try submitArgs(a, try atomic(a, x.t2)), try byMessage(a, &alice, m3));
    try std.testing.expect(r2 == .launch);
    _ = try inst.begin(r2.launch);
    _ = try inst.answer(x.t2.txid, .{ .rejected = "DOUBLE_SPEND_ATTEMPTED" });
    const rej = inst.wire_.answers.items[inst.wire_.answers.items.len - 1];
    try std.testing.expectEqualSlices(u8, m3, rej.body.getCid("request").?);
    try std.testing.expectEqualStrings("rejected", rej.body.get("result").?.getText("state").?);
    try std.testing.expectEqualStrings("DOUBLE_SPEND_ATTEMPTED", rej.body.get("result").?.getText("reason").?);
    try std.testing.expectEqualStrings(&hdr.toHex(x.t2.txid), rej.body.get("result").?.getText("txid").?);

    // ------------------------------------------------ a BEEF that does not decode: rejected at once; not that shape: bad-args
    const m4 = try a.dupe(u8, &cbor.cidOf("message 4"));
    _ = try inst.received(try submitArgs(a, "not a beef"), try byMessage(a, &alice, m4));
    const ref = inst.wire_.lastAnswer();
    try std.testing.expectEqualStrings("rejected", ref.getText("state").?);
    try std.testing.expect(ref.get("txid") == null);
    _ = try inst.received(try mapOf(a, &.{}), try byMessage(a, &alice, m4));
    try std.testing.expectEqualStrings("bad-args", inst.wire_.lastAnswer().getText("code").?);

    // A submission with no sender (an open HTTP route) is answered nowhere: the log only.
    const before = inst.wire_.answers.items.len;
    const anon = try mapOf(a, &.{ .{ .key = "transport", .value = .{ .text = "http" } }, .{ .key = "box", .value = .{ .text = "overlay" } }, .{ .key = "request", .value = .{ .cid = m4 } } });
    _ = try inst.received(try submitArgs(a, "not a beef"), anon);
    try std.testing.expectEqual(before, inst.wire_.answers.items.len);
}

test "a submission by message is answered once (0.7.4): one `admitted`; the step's wake at its thread's end answers nothing" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var ms = c.store.MemStore.init(std.testing.allocator);
    defer ms.deinit();
    var inst = try Instance.init(a, &ms);
    const x = try chain3(a, &inst);
    const alice: [33]u8 = .{0x03} ++ .{0xa1} ** 32;
    const m1 = try a.dupe(u8, &cbor.cidOf("message 1"));
    const src1 = try byMessage(a, &alice, m1);
    const parent = try withFund(a, x.f, x.t1);
    const args = try submitArgs(a, parent);

    // The message step: the submission's thread launched, nobody answered yet.
    const r = try inst.received(args, src1);
    try std.testing.expect(r == .launch);
    // The thread: begun, ingested, accepted → admitted, answered once.
    _ = try inst.begin(r.launch);
    _ = try inst.ingest(parent);
    _ = try inst.chainStatus(x.t1.txid, "RECEIVED", null);
    try std.testing.expect((try inst.answer(x.t1.txid, .accepted)).admitted);
    // The message step again, woken at that thread's end (`resolved`): nothing routed, nothing answered.
    const first = inst.in;
    var es: std.ArrayList(cbor.Entry) = .empty;
    try es.appendSlice(a, first.map);
    try es.append(a, .{ .key = "resolved", .value = .{ .array = try a.dupe(Value, &.{try mapOf(a, &.{
        .{ .key = "thread", .value = .{ .cid = try a.dupe(u8, &cbor.cidOf("the submission's thread")) } },
        .{ .key = "state", .value = .{ .text = "finished" } },
    })}) } });
    inst.in = .{ .map = es.items };
    try std.testing.expect((try inst.received(args, src1)) == .woke);
    inst.in = first;

    var admitted: usize = 0;
    for (inst.wire_.answers.items) |ans| {
        if (ans.body.get("result")) |res| {
            if (std.mem.eql(u8, res.getText("state") orelse "", "admitted")) admitted += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), admitted);
    try std.testing.expectEqual(@as(usize, 1), inst.wire_.answers.items.len);
}

test "one box per function class (skein #128, 0.7.5, 0.7.7): register only in `<app>/register`, refused in `<app>` and `<app>/submit`; submit in any box, `<app>/submit` too" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const me: [33]u8 = .{0x02} ++ .{0x01} ** 32;
    const other: [33]u8 = .{0x02} ++ .{0x02} ** 32;
    // Accepted in `<app>/register` (0.7.7; was `<app>/overlay`), from whoever its row admits.
    const owner_box = try mapOf(a, &.{ .{ .key = "box", .value = .{ .text = "amm/register" } }, .{ .key = "sender", .value = .{ .bytes = &other } } });
    try std.testing.expect(topics_mod.mayRegister(owner_box, "amm"));
    // Refused in the app's own box, even from the instance itself, and in `<app>/submit`.
    for ([_][]const u8{ "amm", "amm/submit", "amm/overlay", "amm/registerx", "ammx/register", "register" }) |box| {
        for ([_][]const u8{ &me, &other }) |sender| {
            const args = try mapOf(a, &.{ .{ .key = "box", .value = .{ .text = box } }, .{ .key = "sender", .value = .{ .bytes = sender } } });
            try std.testing.expect(!topics_mod.mayRegister(args, "amm"));
        }
    }
    // An app named `overlay` (why 0.7.7 renamed the box): `overlay/register` accepted, its own box `overlay` refused.
    try std.testing.expect(topics_mod.mayRegister(try mapOf(a, &.{.{ .key = "box", .value = .{ .text = "overlay/register" } }}), "overlay"));
    try std.testing.expect(!topics_mod.mayRegister(try mapOf(a, &.{.{ .key = "box", .value = .{ .text = "overlay" } }}), "overlay"));
    // No box: the app's own, refused.
    try std.testing.expect(!topics_mod.mayRegister(try mapOf(a, &.{}), "amm"));
    const why = try topics_mod.notHere(a, "register", try mapOf(a, &.{.{ .key = "box", .value = .{ .text = "amm/submit" } }}), "amm");
    try std.testing.expectEqualStrings("register: not taken in box amm/submit; send it in amm/register", why);
    // The manifest's routes (shruggr/skein#143): registrations in `register`, the handler
    // overlay.register gated by root (with the switches); submissions in `submit` (0.7.6), anyone
    // whose BEEF validates (kernel.beef); no route of its own on the app's box (the derived ones).
    const reg = (try manifestRoute(a, "mailbox", "register")).?;
    try std.testing.expectEqualStrings("overlay.register", reg.get("handler").?.string);
    try std.testing.expect(reg.get("filters") == null);
    const sub = (try manifestRoute(a, "mailbox", "submit")).?;
    try std.testing.expectEqualStrings("overlay.submit", sub.get("handler").?.string);
    try expectFilters(sub, &.{"kernel.beef"});
    try std.testing.expect((try manifestRoute(a, "mailbox", "")) == null);
    const mj = try std.json.parseFromSliceLeaky(std.json.Value, a, @embedFile("etc/app.json"), .{});
    const gated = mj.object.get("roles").?.object.get("root").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), gated.len);
    for ([_][]const u8{ "register", "market", "validator" }, gated) |w, g| try std.testing.expectEqualStrings(w, g.string);
    try std.testing.expect(mj.object.get("dispatch") == null and mj.object.get("reads") == null);

    // Submit accepted in `<app>/submit`: launched, the submitter answered in that box.
    var ms = c.store.MemStore.init(std.testing.allocator);
    defer ms.deinit();
    var inst = try Instance.init(a, &ms);
    const x = try chain3(a, &inst);
    const alice: [33]u8 = .{0x03} ++ .{0xa1} ** 32;
    const m1 = try a.dupe(u8, &cbor.cidOf("message in submit"));
    const src = try mapOf(a, &.{
        .{ .key = "transport", .value = .{ .text = "mailbox" } },
        .{ .key = "box", .value = .{ .text = "overlay/submit" } },
        .{ .key = "sender", .value = .{ .bytes = &alice } },
        .{ .key = "request", .value = .{ .cid = m1 } },
    });
    const parent = try withFund(a, x.f, x.t1);
    const r = try inst.received(try submitArgs(a, parent), src);
    try std.testing.expect(r == .launch);
    _ = try inst.begin(r.launch);
    _ = try inst.ingest(parent);
    _ = try inst.chainStatus(x.t1.txid, "RECEIVED", null);
    try std.testing.expect((try inst.answer(x.t1.txid, .accepted)).admitted);
    const ans = inst.wire_.answers.items[0];
    try std.testing.expectEqualStrings("overlay/submit", ans.box);
    try std.testing.expectEqualStrings("admitted", ans.body.get("result").?.getText("state").?);
}

test "one box per function class (skein #128, 0.7.6): a message submission comes in `<app>/submit`; the step there launches, the sender answered in that box" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var ms = c.store.MemStore.init(std.testing.allocator);
    defer ms.deinit();
    var inst = try Instance.init(a, &ms);
    const x = try chain3(a, &inst);
    const parent = try withFund(a, x.f, x.t1);
    const bob: [33]u8 = .{0x03} ++ .{0xb0} ** 32;
    // An app whose own box is another program's (skein-amm): the HTTP submission still lands in `amm/submit`.
    const request = try a.dupe(u8, &cbor.cidOf("an http submission"));
    const req = try mapOf(a, &.{
        .{ .key = "headers", .value = try mapOf(a, &.{.{ .key = "x-topics", .value = .{ .text = "tm_demo" } }}) },
        .{ .key = "body", .value = .{ .bytes = parent } },
        .{ .key = "request", .value = .{ .cid = request } },
        .{ .key = "caller", .value = .{ .bytes = &bob } },
    });
    try std.testing.expectEqualStrings("amm/submit", try routes.submitBox(a, "amm"));
    _ = req;
    // A submission by message from bob in `amm/submit` (the source a message step builds).
    const m = .{ .body = try mapOf(a, &.{ .{ .key = "fn", .value = .{ .text = "submit" } }, .{ .key = "args", .value = try submitArgs(a, parent) } }), .source = try mapOf(a, &.{
        .{ .key = "transport", .value = .{ .text = "mailbox" } },
        .{ .key = "box", .value = .{ .text = "amm/submit" } },
        .{ .key = "sender", .value = .{ .bytes = &bob } },
        .{ .key = "request", .value = .{ .cid = request } },
    }) };
    try std.testing.expectEqualStrings("amm/submit", m.source.getText("box").?);
    const r = try inst.received(m.body.get("args").?, m.source);
    try std.testing.expect(r == .launch);
    _ = try inst.begin(r.launch);
    _ = try inst.ingest(parent);
    _ = try inst.chainStatus(x.t1.txid, "RECEIVED", null);
    try std.testing.expect((try inst.answer(x.t1.txid, .accepted)).admitted);
    const ans = inst.wire_.answers.items[0];
    try std.testing.expectEqualSlices(u8, &bob, ans.to);
    try std.testing.expectEqualStrings("amm/submit", ans.box);
    try std.testing.expectEqualStrings("admitted", ans.body.get("result").?.getText("state").?);
    try std.testing.expectEqualSlices(u8, request, ans.body.getCid("request").?);
}

test "seeding a registered topic (0.7.8): a held seed judged under the new topic only, oldest first over its held ancestry, admitted from the state; a seed not held is missing; again, nothing twice" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var ms = c.store.MemStore.init(std.testing.allocator);
    defer ms.deinit();
    var inst = try Instance.init(a, &ms);
    // The lookup service lists no topics: it listens to every topic, registered ones too.
    for (inst.in.get("defaults").?.map) |*e| if (std.mem.eql(u8, e.key, "overlayLookups")) {
        @constCast(e).value = .{ .text = "{\"ls_demo\":{\"program\":\"lookup-demo\"}}" };
    };

    // The chain app holds fund (mined) → t1 (mints a token) → t2 (moves it), never submitted to this overlay.
    const x = try chain3(a, &inst);
    const both = try beef.serialize(a, .{ .version = beef.V2, .bumps = x.f.bumps, .entries = try a.dupe(beef.Entry, &.{
        x.f.entry,
        .{ .txid = x.t1.txid, .format = .raw, .raw = x.t1.raw, .tx = x.t1.tx },
        .{ .txid = x.t2.txid, .format = .raw, .raw = x.t2.raw, .tx = x.t2.tx },
    }) });
    _ = try inst.ingest(both);
    _ = try inst.chainStatus(x.t1.txid, "RECEIVED", null);
    _ = try inst.chainStatus(x.t2.txid, "RECEIVED", null);

    // register {topic, program, seed}: the set, then the seeds.
    const programs = inst.in.get("programs").?;
    const t2_hex = try a.dupe(u8, &hdr.toHex(x.t2.txid));
    const absent: [32]u8 = .{0xee} ** 32;
    const absent_hex = try a.dupe(u8, &hdr.toHex(absent));
    const rargs = try mapOf(a, &.{
        .{ .key = "topic", .value = .{ .text = "tm_seed" } },
        .{ .key = "program", .value = .{ .text = "topic-demo" } },
        .{ .key = "seed", .value = .{ .array = try a.dupe(Value, &.{ .{ .text = t2_hex }, .{ .text = absent_hex }, .{ .text = t2_hex } }) } },
    });
    const reg = (try topics_mod.register(a, &.{}, rargs, programs, "overlay")).done;
    try std.testing.expectEqual(@as(usize, 2), reg.seed.?.len); // each once
    // A seed that is not a list of txids: refused, nothing written.
    try std.testing.expect(try topics_mod.register(a, &.{}, try mapOf(a, &.{
        .{ .key = "topic", .value = .{ .text = "tm_seed" } },
        .{ .key = "program", .value = .{ .text = "topic-demo" } },
        .{ .key = "seed", .value = .{ .array = try a.dupe(Value, &.{.{ .text = "zz" }}) } },
    }), programs, "overlay") == .refused);
    // No seed: none to judge.
    try std.testing.expect((try topics_mod.register(a, &.{}, try mapOf(a, &.{
        .{ .key = "topic", .value = .{ .text = "tm_seed" } },
        .{ .key = "program", .value = .{ .text = "topic-demo" } },
    }), programs, "overlay")).done.seed == null);

    const in = try config.withTopics(a, inst.in, reg.list.?);
    const seedStep = struct {
        fn run(i: *Instance, cfg: Value, seeds: []const [32]u8) !submit.Seeding {
            var st = try i.load();
            var cx_ = i.cx(&st, false);
            cx_.in = cfg;
            const sd = try submit.seed(cx_, "tm_seed", seeds);
            i.ov_root = try st.save();
            return sd;
        }
    }.run;
    const before_identify = inst.count("identify");
    const sent_before = inst.wire_.sent.items.len;
    const sd = try seedStep(&inst, in, reg.seed.?);
    try std.testing.expectEqual(@as(usize, 1), sd.seeded.len);
    try std.testing.expectEqualSlices(u8, &x.t2.txid, &sd.seeded[0]);
    try std.testing.expectEqual(@as(usize, 1), sd.missing.len);
    try std.testing.expectEqualSlices(u8, &absent, &sd.missing[0]);
    try std.testing.expectEqual(@as(usize, 0), sd.untaken.len);
    // Oldest first: fund (taken by nothing), t1 (mints), t2 (moves it) — t1 then t2 admitted.
    try std.testing.expectEqual(before_identify + 3, inst.count("identify"));
    try std.testing.expectEqual(@as(usize, 2), sd.admissions.len);
    try std.testing.expectEqualSlices(u8, &x.t1.txid, &sd.admissions[0].txid);
    try std.testing.expectEqualSlices(u8, &x.t2.txid, &sd.admissions[1].txid);
    try std.testing.expectEqualSlices(u32, &.{0}, sd.admissions[1].applied[0].coins_to_retain);
    // Both unproven: each an ingest to the chain app and a watch, as a submission admitted on `accepted`.
    try std.testing.expectEqual(@as(usize, 2), sd.watches.len);
    try std.testing.expectEqual(sent_before + 4, inst.wire_.sent.items.len);
    try std.testing.expectEqualStrings("chain", inst.wire_.sent.items[sent_before].box);
    try std.testing.expectEqualStrings("watch", inst.wire_.last().body.getText("fn").?);
    // Under the new topic only; the lookup sees the token, t1's spent.
    var st = try inst.load();
    try std.testing.expect(try st.isApplied("tm_seed", x.t2.txid));
    try std.testing.expect(!(try st.isApplied("tm_demo", x.t2.txid)));
    inst.in = in;
    try std.testing.expectEqual(@as(usize, 1), (try inst.look(&.{.{ .key = "topic", .value = .{ .text = "tm_seed" } }})).len);

    // Again (a second register with the same seed): nothing judged, nothing admitted; still seeded.
    const root = inst.ov_root;
    const again = try seedStep(&inst, in, reg.seed.?);
    try std.testing.expectEqual(before_identify + 3, inst.count("identify"));
    try std.testing.expectEqual(@as(usize, 0), again.admissions.len);
    try std.testing.expectEqual(@as(usize, 1), again.seeded.len);
    try std.testing.expectEqual(@as(usize, 1), again.missing.len);
    try std.testing.expectEqualStrings(root.?, inst.ov_root.?);
    try std.testing.expectEqual(@as(usize, 1), (try inst.look(&.{.{ .key = "topic", .value = .{ .text = "tm_seed" } }})).len);
}

test "the listings and documentation are read routes (shruggr/skein#143, 0.10.0): an http route with no handler, its filter the engine's function" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const j = try std.json.parseFromSliceLeaky(std.json.Value, a, @embedFile("etc/app.json"), .{});
    const want = [_][2][]const u8{
        .{ "/listTopicManagers", "listTopicManagers" },
        .{ "/listLookupServiceProviders", "listLookupServiceProviders" },
        .{ "/getDocumentationForTopicManager", "topicDocumentation" },
        .{ "/getDocumentationForLookupServiceProvider", "lookupDocumentation" },
    };
    const filters = j.object.get("filters").?.object;
    for (want) |w| {
        const r = (try manifestRoute(a, "http", w[0])).?;
        try std.testing.expect(r.get("handler") == null);
        try expectFilters(r, &.{w[1]});
        try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "overlay.{s}", .{w[1]}), filters.get(w[1]).?.string);
    }
    // /submit and /lookup are derived (config.overlay), not the manifest's; `lookup` the derived filter.
    try std.testing.expect((try manifestRoute(a, "http", "/submit")) == null);
    try std.testing.expect((try manifestRoute(a, "http", "/lookup")) == null);
    try std.testing.expect(filters.get("lookup") == null);
}

test "a read called as a filter answers {answer: <the http answer>}; a plain call the http answer (shruggr/skein#143)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const http = try mapOf(a, &.{ .{ .key = "status", .value = .{ .uint = 200 } }, .{ .key = "type", .value = .{ .text = "application/json" } }, .{ .key = "body", .value = .{ .bytes = "{}" } } });
    try std.testing.expect(routes.isFilter(try mapOf(a, &.{ .{ .key = "kind", .value = .{ .text = "call" } }, .{ .key = "filter", .value = .{ .boolean = true } } })));
    try std.testing.expect(!routes.isFilter(try mapOf(a, &.{.{ .key = "kind", .value = .{ .text = "call" } }})));
    const ans = try routes.asFilterAnswer(a, http);
    try std.testing.expectEqual(@as(usize, 1), ans.map.len);
    try std.testing.expectEqual(@as(u64, 200), ans.get("answer").?.getUint("status").?);
    try std.testing.expectEqualStrings("{}", ans.get("answer").?.getBytes("body").?);
}

/// The manifest's route at (transport, address) — transport absent is mailbox — or null.
fn manifestRoute(a: Allocator, transport: []const u8, address: []const u8) !?std.json.ObjectMap {
    const j = try std.json.parseFromSliceLeaky(std.json.Value, a, @embedFile("etc/app.json"), .{});
    for (j.object.get("routes").?.array.items) |r| {
        try std.testing.expect(r.object.get("sender") == null and r.object.get("program") == null);
        const t = if (r.object.get("transport")) |x| x.string else "mailbox";
        if (std.mem.eql(u8, t, transport) and std.mem.eql(u8, r.object.get("address").?.string, address)) return r.object;
    }
    return null;
}

fn expectFilters(r: std.json.ObjectMap, want: []const []const u8) !void {
    const fs = r.get("filters").?.array.items;
    try std.testing.expectEqual(want.len, fs.len);
    for (want, fs) |w, f| try std.testing.expectEqualStrings(w, f.string);
}
