//! ls_demo: an example lookup service (issue #36) over the admitted maps.
//! Queries (JSON on the wire, dag-cbor here):
//!   {topic}                             every unspent output admitted into the topic
//!   {scriptHash (hex sha256 of the locking script), topic?}   unspent outputs with that script
//!   {txid (hex), outputIndex, topic?}    that output, if admitted and unspent
//! Spent outputs too with `includeSpent: true`. Answers are output-lists.
const std = @import("std");
const w = @import("wallet");
const lookup = @import("lookup.zig");

const Value = w.cbor.Value;

fn outputs(a: std.mem.Allocator, xs: []const w.overlay.Admitted) ![]lookup.Output {
    const out = try a.alloc(lookup.Output, xs.len);
    for (xs, out) |x, *o| o.* = .{ .txid = x.txid, .vout = x.vout };
    return out;
}

pub fn answer(a: std.mem.Allocator, wal: *w.wallet.Wallet, service: []const u8, query: Value) anyerror!lookup.Answer {
    if (!std.mem.eql(u8, service, "ls_demo")) return error.UnknownService;
    if (query != .map) return error.BadQuery;
    const spent = query.getBool("includeSpent") orelse false;
    const t = query.getText("topic");
    if (query.getText("scriptHash")) |hex| {
        // The sha256 as written (not reversed, unlike a txid).
        var hash: [32]u8 = undefined;
        if (hex.len != 64) return error.BadQuery;
        _ = std.fmt.hexToBytes(&hash, hex) catch return error.BadQuery;
        return .{ .output_list = try outputs(a, try w.overlay.byScriptHash(wal, hash, t, spent)) };
    }
    if (query.getText("txid")) |hex| {
        const txid = w.header.fromHex(hex) catch return error.BadQuery;
        const vout = query.getUint("outputIndex") orelse return error.BadQuery;
        var found: std.ArrayList(lookup.Output) = .empty;
        const topics: []const []const u8 = if (t) |x| &.{x} else return error.BadQuery;
        for (topics) |tp| for (try w.overlay.inTopic(wal, tp, spent)) |x| {
            if (std.mem.eql(u8, &x.txid, &txid) and x.vout == vout) try found.append(a, .{ .txid = x.txid, .vout = x.vout });
        };
        return .{ .output_list = found.items };
    }
    const topic = t orelse return error.BadQuery;
    return .{ .output_list = try outputs(a, try w.overlay.inTopic(wal, topic, spent)) };
}

pub fn main() u8 {
    return lookup.main(answer);
}
