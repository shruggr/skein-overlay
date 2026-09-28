//! tm_demo: an example topic manager (issue #36). A demo token is an output
//! whose locking script starts with the push "tm_demo" and OP_DROP (then any
//! spending condition, e.g. P2PKH), carrying at least one satoshi. Every such
//! output is admitted; when a transaction admits a token, the tokens it spends
//! are retained (the history of a token moving); a spend that admits none
//! removes them.
const std = @import("std");
const topic = @import("topic.zig");

pub const tag = "\x07tm_demo\x75";

pub fn isToken(script: []const u8, satoshis: i64) bool {
    return satoshis >= 1 and script.len > tag.len and std.mem.startsWith(u8, script, tag);
}

pub fn identify(a: std.mem.Allocator, call: topic.Call) anyerror!topic.Instructions {
    var admit: std.ArrayList(u32) = .empty;
    for (call.tx.outputs, 0..) |o, i| if (isToken(o.locking_script.bytes, o.satoshis)) try admit.append(a, @intCast(i));
    return .{ .outputs_to_admit = admit.items, .coins_to_retain = if (admit.items.len > 0) call.previous_coins else &.{} };
}

pub fn main() u8 {
    return topic.main(identify);
}
