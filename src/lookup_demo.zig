//! ls_demo: an example lookup service (issues #36, #50) that keeps its own
//! index through the hooks, under its head `<app>/ls_demo`. `tp` = len ‖ topic,
//! an outpoint = txid (internal order) ‖ vout (u32 BE):
//!
//!   outputs    tp ‖ outpoint → sha256(locking script) [‖ spending txid]     what it was told was admitted
//!   byTopic    tp ‖ 0 (unspent) | 1 (spent) ‖ outpoint → null
//!   byScript   sha256(locking script) ‖ tp ‖ 0 | 1 ‖ outpoint → null
//!
//! `admitted` adds a topic's admitted outputs (unspent), `spent` moves one to
//! spent (naming its spender), `rejected` drops a rejected transaction's
//! outputs and gives back the ones it had spent. Queries (JSON on the wire,
//! dag-cbor here), answered from these maps alone:
//!   {topic}                             every unspent output admitted into the topic
//!   {scriptHash (hex sha256 of the locking script), topic?}   unspent outputs with that script
//!   {txid (hex), outputIndex, topic}    that output, if admitted and unspent
//! Spent outputs too with `includeSpent: true`. Answers are output-lists.
const std = @import("std");
const c = @import("chain");
const lookup = @import("lookup");

const Value = c.cbor.Value;
const Allocator = std.mem.Allocator;
const Service = lookup.Service;

pub const spec: lookup.Spec = .{
    .maps = &.{ "outputs", "byTopic", "byScript" },
    // Its index, whatever name it is served as (skein-overlay 0.11.0): the head `<app>/ls_demo`.
    .index = "ls_demo",
    .answer = answer,
    .admitted = admitted,
    .spent = spent,
    .rejected = rejected,
};

fn topicPrefix(a: Allocator, topic: []const u8) ![]u8 {
    if (topic.len == 0) return error.BadTopic;
    return c.store.nameKey(a, topic, &.{});
}

fn cat(a: Allocator, parts: []const []const u8) ![]u8 {
    return std.mem.concat(a, u8, parts);
}

fn scriptHash(script: []const u8) [32]u8 {
    var h: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(script, &h, .{});
    return h;
}

/// An output's keys under a state (0 unspent, 1 spent): byTopic, byScript.
fn keys(a: Allocator, tp: []const u8, sh: []const u8, op: []const u8, state: u8) ![2][]u8 {
    return .{ try cat(a, &.{ tp, &.{state}, op }), try cat(a, &.{ sh, tp, &.{state}, op }) };
}

fn move(a: Allocator, svc: *Service, tp: []const u8, sh: []const u8, op: []const u8, to: u8) !void {
    const old = try keys(a, tp, sh, op, 1 - to);
    const new = try keys(a, tp, sh, op, to);
    _ = try svc.map("byTopic").remove(old[0]);
    _ = try svc.map("byScript").remove(old[1]);
    try svc.map("byTopic").add(new[0]);
    try svc.map("byScript").add(new[1]);
}

fn admitted(a: Allocator, svc: *Service, topic: []const u8, tx: lookup.Tx, outputs_to_admit: []const u32, _: []const u32) anyerror!void {
    const tp = try topicPrefix(a, topic);
    for (outputs_to_admit) |vout| {
        if (vout >= tx.tx.outputs.len) return error.BadArgs;
        const sh = scriptHash(tx.tx.outputs[vout].locking_script.bytes);
        const op = c.store.outpointKey(tx.txid, vout);
        try svc.map("outputs").put(try cat(a, &.{ tp, &op }), .{ .bytes = try a.dupe(u8, &sh) });
        try move(a, svc, tp, &sh, &op, 0);
    }
}

fn spent(a: Allocator, svc: *Service, topic: []const u8, outpoint: lookup.Outpoint, spending: lookup.Tx) anyerror!void {
    const tp = try topicPrefix(a, topic);
    const op = c.store.outpointKey(outpoint.txid, outpoint.vout);
    const key = try cat(a, &.{ tp, &op });
    const v = (try svc.map("outputs").get(key)) orelse return; // not one it was told of
    if (v != .bytes or v.bytes.len < 32) return error.BadIndex;
    const sh = v.bytes[0..32];
    try svc.map("outputs").put(key, .{ .bytes = try cat(a, &.{ sh, &spending.txid }) });
    try move(a, svc, tp, sh, &op, 1);
}

fn rejected(a: Allocator, svc: *Service, topic: []const u8, tx: lookup.Tx) anyerror!void {
    const tp = try topicPrefix(a, topic);
    // Its outputs vanish.
    for (0..tx.tx.outputs.len) |vout| {
        const op = c.store.outpointKey(tx.txid, @intCast(vout));
        const key = try cat(a, &.{ tp, &op });
        const v = (try svc.map("outputs").get(key)) orelse continue;
        if (v != .bytes or v.bytes.len < 32) return error.BadIndex;
        for ([_]u8{ 0, 1 }) |state| {
            const k = try keys(a, tp, v.bytes[0..32], &op, state);
            _ = try svc.map("byTopic").remove(k[0]);
            _ = try svc.map("byScript").remove(k[1]);
        }
        _ = try svc.map("outputs").remove(key);
    }
    // What it spent is unspent again.
    for (tx.tx.inputs) |in| {
        const op = c.store.outpointKey(in.previous_outpoint.txid.bytes, in.previous_outpoint.index);
        const key = try cat(a, &.{ tp, &op });
        const v = (try svc.map("outputs").get(key)) orelse continue;
        if (v != .bytes or v.bytes.len != 64 or !std.mem.eql(u8, v.bytes[32..64], &tx.txid)) continue;
        const sh = v.bytes[0..32];
        try svc.map("outputs").put(key, .{ .bytes = try a.dupe(u8, sh) });
        try move(a, svc, tp, sh, &op, 0);
    }
}

pub fn answer(a: Allocator, svc: *Service, _: *lookup.Chain, query: Value) anyerror!lookup.Answer {
    if (!std.mem.eql(u8, svc.name, "ls_demo")) return error.UnknownService;
    if (query != .map) return error.BadQuery;
    const include_spent = query.getBool("includeSpent") orelse false;
    const t = query.getText("topic");
    var out: std.ArrayList(lookup.Output) = .empty;
    if (query.getText("scriptHash")) |hex| {
        // The sha256 as written (not reversed, unlike a txid).
        var hash: [32]u8 = undefined;
        if (hex.len != 64) return error.BadQuery;
        _ = std.fmt.hexToBytes(&hash, hex) catch return error.BadQuery;
        const prefix = if (t) |x| try cat(a, &.{ &hash, try topicPrefix(a, x) }) else try a.dupe(u8, &hash);
        for (try svc.map("byScript").prefixed(prefix)) |kv| {
            const rest = kv.key[32..];
            const tl = 1 + @as(usize, rest[0]);
            if (rest.len != tl + 1 + 36) return error.BadIndex;
            if (rest[tl] == 1 and !include_spent) continue;
            const o = try c.store.outpointOf(rest[tl + 1 ..]);
            try out.append(a, .{ .txid = o.txid, .vout = o.vout });
        }
        return .{ .output_list = out.items };
    }
    const topic = t orelse return error.BadQuery;
    const tp = try topicPrefix(a, topic);
    if (query.getText("txid")) |hex| {
        const txid = c.header.fromHex(hex) catch return error.BadQuery;
        const vout = query.getUint("outputIndex") orelse return error.BadQuery;
        const v = (try svc.map("outputs").get(try cat(a, &.{ tp, &c.store.outpointKey(txid, @intCast(vout)) }))) orelse return .{ .output_list = &.{} };
        if (v != .bytes) return error.BadIndex;
        if (v.bytes.len > 32 and !include_spent) return .{ .output_list = &.{} };
        try out.append(a, .{ .txid = txid, .vout = @intCast(vout) });
        return .{ .output_list = out.items };
    }
    for ([_]u8{ 0, 1 }) |state| {
        if (state == 1 and !include_spent) continue;
        for (try svc.map("byTopic").prefixed(try cat(a, &.{ tp, &.{state} }))) |kv| {
            const o = try c.store.outpointOf(kv.key[tp.len + 1 ..]);
            try out.append(a, .{ .txid = o.txid, .vout = o.vout });
        }
    }
    return .{ .output_list = out.items };
}

pub fn metadata(_: Allocator, _: []const u8) anyerror!lookup.Metadata {
    return .{ .short_description = "Example index of tm_demo tokens: by topic, by script hash, or by outpoint." };
}

pub fn documentation(_: Allocator, _: []const u8) anyerror![]const u8 {
    return
    \\# ls_demo
    \\
    \\An example lookup service. It indexes the outputs its topics admit, through the
    \\`admitted`, `spent` and `rejected` hooks, and answers output-lists. Queries:
    \\
    \\- `{"topic": "tm_demo"}`: every unspent output admitted into the topic
    \\- `{"scriptHash": "<hex sha256 of the locking script>", "topic"?: …}`: unspent outputs with that script
    \\- `{"txid": "<hex>", "outputIndex": n, "topic": "tm_demo"}`: that output, if admitted and unspent
    \\
    \\Add `"includeSpent": true` for spent outputs too.
    \\
    ;
}

pub fn main() u8 {
    return lookup.main(spec);
}
