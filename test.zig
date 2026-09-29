//! The topic and lookup contracts, natively: the demo topic judging
//! topic-call args, the engine's recording of its answer (wallet-zig's
//! overlay), and the demo lookup's answers carrying BEEF that verifies
//! against the chain.
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
const Value = w.cbor.Value;

fn mine(prev: [32]u8, root: [32]u8, time: u32) [80]u8 {
    var h = hdr.Header{ .version = 1, .prev_hash = prev, .merkle_root = root, .time = time, .bits = 0x207fffff, .nonce = 0 };
    while (true) : (h.nonce += 1) {
        const raw = h.serialize();
        if (hdr.powOk(&raw)) return raw;
    }
}

fn soloPath(a: std.mem.Allocator, height: u32, txid: [32]u8) ![]const u8 {
    var path: std.ArrayList(u8) = .empty;
    try path.appendSlice(a, &.{ @intCast(height), 0x01, 0x01, 0x00, 0x02 });
    try path.appendSlice(a, &txid);
    return path.items;
}

fn spend(a: std.mem.Allocator, src: *const bsvz.transaction.Transaction, vout: u32, outs: []const struct { u64, []const u8 }, priv: [32]u8) !struct { tx: bsvz.transaction.Transaction, raw: []const u8, txid: [32]u8 } {
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

fn args(a: std.mem.Allocator, t: []const u8, txid: [32]u8, previous: []const u32) !Value {
    const pc = try a.alloc(Value, previous.len);
    for (previous, pc) |p, *v| v.* = .{ .uint = p };
    return .{ .map = try a.dupe(w.cbor.Entry, &.{
        .{ .key = "kind", .value = .{ .text = "topic-call" } },
        .{ .key = "topic", .value = .{ .text = t } },
        .{ .key = "tx", .value = .{ .cid = try a.dupe(u8, &w.store.hashCid(.tx, txid)) } },
        .{ .key = "previousCoins", .value = .{ .array = pc } },
    }) };
}

/// A submission as the engine takes it (#50): decoded once and verified (the route), then held (the step).
fn submitted(a: std.mem.Allocator, wal: *w.wallet.Wallet, bytes: []const u8) !w.overlay.Subject {
    const before = beef.parses;
    const c = try submit.decodeAndVerify(wal, bytes);
    const sub = try submit.hold(wal, try submit.event(a, c.decoded, &.{"tm_demo"}, null));
    try std.testing.expectEqual(before + 1, beef.parses);
    try std.testing.expectEqualSlices(u8, &c.subject.txid, &sub.txid);
    return sub;
}

fn query(a: std.mem.Allocator, fields: []const w.cbor.Entry) !Value {
    return .{ .map = try a.dupe(w.cbor.Entry, &.{
        .{ .key = "kind", .value = .{ .text = "lookup-call" } },
        .{ .key = "service", .value = .{ .text = "ls_demo" } },
        .{ .key = "query", .value = .{ .map = try a.dupe(w.cbor.Entry, fields) } },
    }) };
}

test "topic and lookup contracts: tm_demo judges, the engine records, ls_demo answers with BEEF that verifies" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var ms = w.store.MemStore.init(std.testing.allocator);
    defer ms.deinit();
    const s = ms.store();

    const priv: [32]u8 = .{0x42} ** 32;
    const pub_key = try w.brc29.identityKey(priv);
    const pkh = bsvz.crypto.hash.hash160(&pub_key).bytes;
    const p2pkh = w.brc29.p2pkh(pub_key);
    const token: [34]u8 = demo.tag.* ++ [_]u8{ 0x76, 0xa9, 0x14 } ++ pkh ++ [_]u8{ 0x88, 0xac };

    // A funding transaction mined alone at height 1 of a regtest chain (root = its txid).
    var fund_raw: std.ArrayList(u8) = .empty;
    try fund_raw.appendSlice(a, &.{ 1, 0, 0, 0, 1 });
    try fund_raw.appendSlice(a, &(.{0x11} ** 32));
    try fund_raw.appendSlice(a, &.{ 0, 0, 0, 0, 1, 0x51, 0xff, 0xff, 0xff, 0xff, 1 });
    var sats: [8]u8 = undefined;
    std.mem.writeInt(u64, &sats, 50_000, .little);
    try fund_raw.appendSlice(a, &sats);
    try fund_raw.append(a, p2pkh.len);
    try fund_raw.appendSlice(a, &p2pkh);
    try fund_raw.appendSlice(a, &.{ 0, 0, 0, 0 });
    const fund_tx = try bsvz.transaction.Transaction.parse(a, fund_raw.items);
    const fund_txid = beef.txidOf(fund_raw.items);
    var wal = try w.wallet.Wallet.load(a, s, null, .regtest);
    const h1 = mine(hdr.hash(&w.chain.Network.regtest.genesis()), fund_txid, 1_700_000_600);
    _ = try wal.addHeaders(&.{&h1});
    const s0 = try wal.save();
    const bump = try bsvz.spv.MerklePath.parse(a, try soloPath(a, 1, fund_txid));

    // T1: a token and change. Submitted as BEEF V2 with the funding's BUMP.
    const t1 = try spend(a, &fund_tx, 0, &.{ .{ 1, &token }, .{ 49_000, &p2pkh } }, priv);
    const bumps = try a.dupe(bsvz.spv.MerklePath, &.{bump});
    const e1 = try a.dupe(beef.Entry, &.{
        .{ .txid = fund_txid, .format = .raw_with_bump, .bump = 0, .raw = fund_raw.items, .tx = fund_tx },
        .{ .txid = t1.txid, .format = .raw, .raw = t1.raw, .tx = t1.tx },
    });
    const t1_beef = try beef.serialize(a, .{ .version = beef.V2, .bumps = bumps, .entries = e1 });

    // The topic contract: args in, admittance record out.
    wal = try w.wallet.Wallet.load(a, s, s0, .regtest);
    const sub1 = try submitted(a, &wal, t1_beef);
    const rec1 = try topic.judge(a, s, demo.identify, try args(a, "tm_demo", t1.txid, &.{}));
    try std.testing.expectEqualStrings("admittance", rec1.getText("kind").?);
    try std.testing.expectEqualStrings(&hdr.toHex(t1.txid), rec1.getText("txid").?);
    const ins1 = try topic.instructionsOf(a, rec1);
    try std.testing.expectEqualSlices(u32, &.{0}, ins1.outputs_to_admit);
    try std.testing.expectEqual(@as(usize, 0), ins1.coins_to_retain.len);
    try std.testing.expectError(error.BadArgs, topic.judge(a, s, demo.identify, .{ .map = &.{} }));
    try std.testing.expectError(error.UnknownTransaction, topic.judge(a, s, demo.identify, try args(a, "tm_demo", .{0x5a} ** 32, &.{})));

    // The engine's part: record.
    _ = try w.overlay.apply(&wal, sub1, "tm_demo", &.{}, ins1);
    const s1 = try wal.save();

    // The lookup contract: by topic, by script hash, by outpoint.
    {
        const ans = try lookup.answerRecord(a, &wal, ls.answer, try query(a, &.{.{ .key = "topic", .value = .{ .text = "tm_demo" } }}));
        try std.testing.expectEqualStrings("output-list", ans.getText("type").?);
        const outs = ans.getArray("outputs").?;
        try std.testing.expectEqual(@as(usize, 1), outs.len);
        try std.testing.expectEqual(@as(u64, 0), outs[0].getUint("outputIndex").?);
        const b = try beef.parse(a, outs[0].getBytes("beef").?);
        try std.testing.expectEqualSlices(u8, &t1.txid, &b.atomic.?);
        var fresh = try w.wallet.Wallet.load(a, s, s0, .regtest); // only the headers
        var ctx = w.wallet.Wallet.SpvCtx{ .w = &fresh };
        _ = try w.spv.verify(a, b, .{ .ptr = &ctx, .rootAtFn = w.wallet.Wallet.SpvCtx.rootAt, .knownRawFn = w.wallet.Wallet.SpvCtx.knownRaw });
        var sh: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(&token, &sh, .{});
        const by_script = try lookup.answerRecord(a, &wal, ls.answer, try query(a, &.{.{ .key = "scriptHash", .value = .{ .text = &std.fmt.bytesToHex(sh, .lower) } }}));
        try std.testing.expectEqual(@as(usize, 1), by_script.getArray("outputs").?.len);
        const by_op = try lookup.answerRecord(a, &wal, ls.answer, try query(a, &.{
            .{ .key = "topic", .value = .{ .text = "tm_demo" } },
            .{ .key = "txid", .value = .{ .text = &hdr.toHex(t1.txid) } },
            .{ .key = "outputIndex", .value = .{ .uint = 1 } },
        }));
        try std.testing.expectEqual(@as(usize, 0), by_op.getArray("outputs").?.len); // the change was not admitted
        try std.testing.expectError(error.UnknownService, lookup.answerRecord(a, &wal, ls.answer, .{ .map = try a.dupe(w.cbor.Entry, &.{
            .{ .key = "kind", .value = .{ .text = "lookup-call" } },
            .{ .key = "service", .value = .{ .text = "ls_other" } },
            .{ .key = "query", .value = .null },
        }) }));
    }

    // T2 spends the token and admits none: the previous coin is removed, not retained.
    const t2 = try spend(a, &t1.tx, 0, &.{.{ 1, &p2pkh }}, priv);
    const e2 = try a.dupe(beef.Entry, &.{.{ .txid = t2.txid, .format = .raw, .raw = t2.raw, .tx = t2.tx }});
    const t2_beef = try beef.serialize(a, .{ .version = beef.V2, .atomic = t2.txid, .bumps = &.{}, .entries = e2 });
    wal = try w.wallet.Wallet.load(a, s, s1, .regtest);
    const sub2 = try submitted(a, &wal, t2_beef);
    const prev = try w.overlay.previousCoins(&wal, "tm_demo", sub2.tx);
    try std.testing.expectEqualSlices(u32, &.{0}, prev);
    const ins2 = try topic.instructionsOf(a, try topic.judge(a, s, demo.identify, try args(a, "tm_demo", t2.txid, prev)));
    try std.testing.expectEqual(@as(usize, 0), ins2.outputs_to_admit.len);
    try std.testing.expectEqual(@as(usize, 0), ins2.coins_to_retain.len);
    const applied = try w.overlay.apply(&wal, sub2, "tm_demo", prev, ins2);
    try std.testing.expectEqualSlices(u32, &.{0}, applied.coins_removed);
    _ = try wal.save();
    const empty = try lookup.answerRecord(a, &wal, ls.answer, try query(a, &.{.{ .key = "topic", .value = .{ .text = "tm_demo" } }}));
    try std.testing.expectEqual(@as(usize, 0), empty.getArray("outputs").?.len);
}
