//! The lookup contract (BRC-24 LookupService, issue #36): a lookup service
//! is a program. The overlay engine launches it on each `/lookup` naming the
//! service, with args
//!
//!   {kind: "lookup-call", service, query}          (query: the client's JSON as dag-cbor)
//!
//! and it answers over the admitted maps — the overlay's state in the
//! instance's chain+settlement core (the head `wallet`, read only) — with a
//! record, kept in its thread and its CID printed on stdout:
//!
//!   {kind: "lookup-answer", type: "output-list", outputs: [{beef, outputIndex, context?}]}
//!   {kind: "lookup-answer", type: "freeform", result}
//!
//! Each output's `beef` is the Atomic BEEF of its transaction, built from the
//! held records (ancestry back to proven transactions, with their BUMPs).
//! A service is `pub fn main() u8 { return lookup.main(answer); }` with
//! `answer(arena, *Wallet, service, query) !Answer`.
const std = @import("std");
const w = @import("wallet");

const cbor = w.cbor;
const Value = cbor.Value;
const Wallet = w.wallet.Wallet;

pub const Output = struct { txid: [32]u8, vout: u32, context: ?[]const u8 = null };

pub const Answer = union(enum) {
    output_list: []const Output,
    freeform: Value,
};

pub const AnswerFn = fn (a: std.mem.Allocator, wal: *Wallet, service: []const u8, query: Value) anyerror!Answer;

/// The answer record for a lookup-call: outputs with their transactions' BEEF.
pub fn answerRecord(a: std.mem.Allocator, wal: *Wallet, answer: AnswerFn, args: Value) !Value {
    if (!std.mem.eql(u8, args.getText("kind") orelse "", "lookup-call")) return error.BadArgs;
    const service = args.getText("service") orelse return error.BadArgs;
    const ans = try answer(a, wal, service, args.get("query") orelse .null);
    switch (ans) {
        .freeform => |v| return .{ .map = try a.dupe(cbor.Entry, &.{
            .{ .key = "kind", .value = .{ .text = "lookup-answer" } },
            .{ .key = "type", .value = .{ .text = "freeform" } },
            .{ .key = "result", .value = v },
        }) },
        .output_list => |outs| {
            // One BEEF per transaction, shared by its outputs.
            var beefs = std.AutoHashMap([32]u8, []const u8).init(a);
            const items = try a.alloc(Value, outs.len);
            for (outs, items) |o, *it| {
                const gop = try beefs.getOrPut(o.txid);
                if (!gop.found_existing) gop.value_ptr.* = try w.overlay.beefFor(wal, o.txid);
                var es: std.ArrayList(cbor.Entry) = .empty;
                try es.appendSlice(a, &.{
                    .{ .key = "beef", .value = .{ .bytes = gop.value_ptr.* } },
                    .{ .key = "outputIndex", .value = .{ .uint = o.vout } },
                });
                if (o.context) |c| try es.append(a, .{ .key = "context", .value = .{ .bytes = c } });
                it.* = .{ .map = es.items };
            }
            return .{ .map = try a.dupe(cbor.Entry, &.{
                .{ .key = "kind", .value = .{ .text = "lookup-answer" } },
                .{ .key = "type", .value = .{ .text = "output-list" } },
                .{ .key = "outputs", .value = .{ .array = items } },
            }) };
        },
    }
}

/// The program's main: answer the step's lookup-call over the shared state
/// (read only: no head moves), keep and print the answer record.
pub fn main(comptime answer: AnswerFn) u8 {
    const vm = @import("vm.zig");
    const S = struct {
        fn run(a: std.mem.Allocator) anyerror!void {
            const step = try vm.input(a);
            const s = vm.store();
            var wal = try Wallet.load(a, s, try vm.head(a, vm.state_head), try vm.network(step));
            const rec = try answerRecord(a, &wal, answer, step.get("args") orelse return error.BadInput);
            _ = try vm.finish(a, s, rec);
        }
    };
    return vm.main("lookup", S.run);
}
