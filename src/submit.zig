//! A submission's records (#50). The front door's `/submit` handler decodes
//! the BEEF once, into records (wallet-zig overlay.decode: `bitcoin-tx`
//! blocks and merkle nodes, put into the call's in-memory overlay), and
//! checks it over them (overlay.verifyDecoded: SPV read through `get`). The
//! entry it returns for the host to admit carries the decoded records — the
//! transactions' bytes and the merkle nodes, not a BEEF — and the step that
//! processes it holds them (overlay.holdDecoded: kept, so #42's edges appear)
//! without parsing anything but the transactions themselves.
//!
//!   {kind: "submit", txid (hex), txs: [bytes], nodes: [bytes], proofs: [{txid: bytes, height}],
//!    topics: [text], offChainValues?: bytes}
const std = @import("std");
const w = @import("wallet");

const cbor = w.cbor;
const Value = cbor.Value;
const Wallet = w.wallet.Wallet;
const ov = w.overlay;

/// Decode the BEEF into records (the one parse) and verify them: → the decoded records and the subject.
pub fn decodeAndVerify(wal: *Wallet, beef: []const u8) !struct { decoded: ov.Decoded, subject: ov.Subject } {
    const d = try ov.decode(wal.arena, wal.store, beef);
    return .{ .decoded = d, .subject = try ov.verifyDecoded(wal, d) };
}

fn texts(a: std.mem.Allocator, xs: []const []const u8) ![]Value {
    const out = try a.alloc(Value, xs.len);
    for (xs, out) |x, *o| o.* = .{ .text = x };
    return out;
}

/// The submit entry's event: the decoded records, the topics, the off-chain values.
pub fn event(a: std.mem.Allocator, d: ov.Decoded, topics: []const []const u8, off: ?[]const u8) !Value {
    const txs = try a.alloc(Value, d.txs.len);
    for (d.txs, txs) |t, *o| o.* = .{ .bytes = t.raw };
    const nodes = try a.alloc(Value, d.nodes.len);
    for (d.nodes, nodes) |n, *o| o.* = .{ .bytes = try a.dupe(u8, &n.bytes) };
    const proofs = try a.alloc(Value, d.proven.len);
    for (d.proven, proofs) |p, *o| o.* = .{ .map = try a.dupe(cbor.Entry, &.{
        .{ .key = "txid", .value = .{ .bytes = try a.dupe(u8, &p.txid) } },
        .{ .key = "height", .value = .{ .uint = p.height } },
    }) };
    var es: std.ArrayList(cbor.Entry) = .empty;
    try es.appendSlice(a, &.{
        .{ .key = "kind", .value = .{ .text = "submit" } },
        .{ .key = "txid", .value = .{ .text = try a.dupe(u8, &w.header.toHex(d.subject)) } },
        .{ .key = "txs", .value = .{ .array = txs } },
        .{ .key = "nodes", .value = .{ .array = nodes } },
        .{ .key = "proofs", .value = .{ .array = proofs } },
        .{ .key = "topics", .value = .{ .array = try texts(a, topics) } },
    });
    if (off) |o| try es.append(a, .{ .key = "offChainValues", .value = .{ .bytes = o } });
    return .{ .map = es.items };
}

/// Hold the records a submit event carries (in the step that admits it): → the subject, now held.
pub fn hold(wal: *Wallet, ev: Value) !ov.Subject {
    const a = wal.arena;
    const txs_v = ev.getArray("txs") orelse return error.BadEvent;
    const nodes_v = ev.getArray("nodes") orelse return error.BadEvent;
    const proofs_v = ev.getArray("proofs") orelse return error.BadEvent;
    const txs = try a.alloc([]const u8, txs_v.len);
    for (txs_v, txs) |v, *o| o.* = if (v == .bytes) v.bytes else return error.BadEvent;
    const nodes = try a.alloc([]const u8, nodes_v.len);
    for (nodes_v, nodes) |v, *o| o.* = if (v == .bytes) v.bytes else return error.BadEvent;
    const proven = try a.alloc(ov.Proven, proofs_v.len);
    for (proofs_v, proven) |v, *o| {
        const t = v.getBytes("txid") orelse return error.BadEvent;
        if (t.len != 32) return error.BadEvent;
        o.* = .{ .txid = t[0..32].*, .height = @intCast(v.getUint("height") orelse return error.BadEvent) };
    }
    try ov.holdDecoded(wal, txs, nodes, proven);
    return ov.subjectOf(wal, try w.header.fromHex(ev.getText("txid") orelse return error.BadEvent));
}
