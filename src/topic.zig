//! The topic contract (BRC-22 TopicManager, issues #36, #50): a topic
//! manager is a program. The overlay engine (engine.zig) launches it on each
//! submitted transaction that names its topic, with args
//!
//!   {kind: "topic-call", topic, tx: <bitcoin-tx CID>, previousCoins: [input index], offChainValues?: bytes}
//!
//! where previousCoins are the inputs spending outputs live in the topic
//! (BRC-22 step 4). No BEEF crosses into the topic: it reads the transaction
//! and its inputs' source outputs as records, through `get` (a transaction's
//! block, decoded). The program answers with a record, kept in its thread and
//! its CID printed on stdout:
//!
//!   {kind: "admittance", topic, txid, outputsToAdmit: [output index], coinsToRetain: [input index]}
//!
//! A topic program is `pub fn main() u8 { return topic.main(identify); }`
//! with `identify(arena, Call) !Instructions` — the TopicManager's
//! identifyAdmissibleOutputs. `judge` is the same over any store (tests).
//! Documentation and metadata are the program record's (bin/<name>.json
//! `description`): the router serves them without running anything.
const std = @import("std");
const w = @import("wallet");

const cbor = w.cbor;
const Value = cbor.Value;
const Store = w.store.Store;
const Transaction = w.bsvz.transaction.Transaction;
pub const Instructions = w.overlay.Instructions;

/// What a topic judges.
pub const Call = struct {
    arena: std.mem.Allocator,
    store: Store,
    topic: []const u8,
    /// The transaction's CID (bitcoin-tx: the txid) and the transaction its block decodes to.
    tx_cid: []const u8,
    txid: [32]u8,
    tx: Transaction,
    /// Inputs spending outputs live in the topic.
    previous_coins: []const u32,
    off_chain_values: ?[]const u8 = null,

    /// A transaction by txid, read through `get` (in the submit's call, its overlay), or null.
    pub fn transaction(self: Call, txid: [32]u8) ?Transaction {
        const raw = self.store.tryGet(self.arena, &w.store.hashCid(.tx, txid)) orelse return null;
        return Transaction.parse(self.arena, raw) catch null;
    }

    /// The output an input spends, when its source transaction is readable.
    pub fn sourceOutput(self: Call, input_index: usize) ?w.bsvz.transaction.Output {
        if (input_index >= self.tx.inputs.len) return null;
        const in = self.tx.inputs[input_index];
        const src = self.transaction(in.previous_outpoint.txid.bytes) orelse return null;
        if (in.previous_outpoint.index >= src.outputs.len) return null;
        return src.outputs[in.previous_outpoint.index];
    }
};

pub const Identify = fn (a: std.mem.Allocator, call: Call) anyerror!Instructions;

fn uintList(a: std.mem.Allocator, v: ?Value) ![]u32 {
    const items = if (v) |x| (if (x == .array) x.array else return error.BadArgs) else return &.{};
    const out = try a.alloc(u32, items.len);
    for (items, out) |it, *o| o.* = if (it == .uint and it.uint <= std.math.maxInt(u32)) @intCast(it.uint) else return error.BadArgs;
    return out;
}

fn uints(a: std.mem.Allocator, xs: []const u32) ![]Value {
    const out = try a.alloc(Value, xs.len);
    for (xs, out) |x, *o| o.* = .{ .uint = x };
    return out;
}

/// The call a topic-call args record describes: its transaction read from the store.
pub fn callOf(a: std.mem.Allocator, s: Store, args: Value) !Call {
    if (!std.mem.eql(u8, args.getText("kind") orelse "", "topic-call")) return error.BadArgs;
    const cid = args.getCid("tx") orelse return error.BadArgs;
    const txid = w.store.bitcoinHash(cid) orelse return error.BadArgs;
    const raw = s.get(a, cid) catch return error.UnknownTransaction;
    return .{
        .arena = a,
        .store = s,
        .topic = args.getText("topic") orelse return error.BadArgs,
        .tx_cid = cid,
        .txid = txid,
        .tx = Transaction.parse(a, raw) catch return error.BadTransaction,
        .previous_coins = try uintList(a, args.get("previousCoins")),
        .off_chain_values = args.getBytes("offChainValues"),
    };
}

/// Judge a topic-call: the admittance record's value.
pub fn judge(a: std.mem.Allocator, s: Store, identify: Identify, args: Value) !Value {
    const call = try callOf(a, s, args);
    const ins = try identify(a, call);
    return .{ .map = try a.dupe(cbor.Entry, &.{
        .{ .key = "kind", .value = .{ .text = "admittance" } },
        .{ .key = "topic", .value = .{ .text = call.topic } },
        .{ .key = "txid", .value = .{ .text = try a.dupe(u8, &w.header.toHex(call.txid)) } },
        .{ .key = "outputsToAdmit", .value = .{ .array = try uints(a, ins.outputs_to_admit) } },
        .{ .key = "coinsToRetain", .value = .{ .array = try uints(a, ins.coins_to_retain) } },
    }) };
}

/// An admittance record's instructions (the engine reads them back).
pub fn instructionsOf(a: std.mem.Allocator, rec: Value) !Instructions {
    if (!std.mem.eql(u8, rec.getText("kind") orelse "", "admittance")) return error.BadAdmittance;
    return .{ .outputs_to_admit = try uintList(a, rec.get("outputsToAdmit")), .coins_to_retain = try uintList(a, rec.get("coinsToRetain")) };
}

/// The program's main: judge the step's args, keep and print the admittance record.
pub fn main(comptime identify: Identify) u8 {
    const vm = @import("vm.zig");
    const S = struct {
        fn run(a: std.mem.Allocator) anyerror!void {
            const step = try vm.input(a);
            const rec = try judge(a, vm.store(), identify, step.get("args") orelse return error.BadInput);
            _ = try vm.finish(a, vm.store(), rec);
        }
    };
    return vm.main("topic", S.run);
}
