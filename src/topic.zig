//! The topic contract (BRC-22 TopicManager, issues #36, #50): a topic
//! manager is a program the overlay calls — an in-VM call of fn "identify",
//! in the front door's `/submit` call (writing nothing: if no topic takes the
//! transaction, nothing persists) and, only if its previous coins moved
//! before the entry was processed, again in that step (submit.zig) — with
//!
//!   {kind: "topic-call", topic, tx: <bitcoin-tx CID>, previousCoins: [input index], offChainValues?: bytes, unheld?: [txid hex]}
//!
//! where previousCoins are the inputs spending outputs live in the topic
//! (BRC-22 step 4), and `unheld` (0.19.0) the input sources the instance does
//! not have — neither in the submitted BEEF nor held by the chain app — which
//! `Call.transaction` / `sourceOutput` / `lacking` treat as unreadable whatever
//! the store holds (a replay's store holds what came later). No BEEF crosses into the topic: it reads the transaction
//! and its inputs' source outputs as records, through `get` (in the submit's
//! call, through the call's in-memory overlay, where the BEEF was decoded).
//! The call's answer (dag-cbor on stdout):
//!
//!   {kind: "admittance", topic, txid, outputsToAdmit: [output index], coinsToRetain: [input index], ancillaryTxids?: [txid hex]}
//!
//! identify(tx: cid, previousCoins, offChain?) → {outputsToAdmit, coinsToRetain, ancillaryTxids}.
//!
//! **Missing parents** (0.19.0; David 2026-10-30: "we don't mark items which are undecided as
//! invalid"): a topic manager that cannot decide because it cannot read an input's source (not in
//! the submitted BEEF, not held) FAILS, as any refusal fails (an error: the program exits 1, its
//! last stderr line the caller's error), with the error `MissingParents` naming every source it
//! lacks: the line `topic: MissingParents: <txid hex>[,<txid hex>…]`. `identify` returns
//! `missingParents(call.lacking())` (or its own list). It is no verdict: the engine pauses the
//! submission, wants those transactions, and judges it again as each arrives; nothing is recorded
//! as rejected. Admitted and rejected stay the only verdicts. `needsOf` reads the list back out of
//! the caller's error text.
//! `ancillaryTxids` (skein-overlay#4; go-overlay-services' AdmittanceInstructions.AncillaryTxids)
//! names transactions the topic read and relied on that it does not admit — for a 1Sat ordinal
//! transfer, the funding parents that fix the satoshi's offset. Each must be one the topic could
//! read (in the submitted BEEF, or held); the engine keeps them on the admittance. Empty: omitted.
//! A topic program is `pub fn main() u8 { return topic.main(identify); }`
//! with `identify(arena, Call) !Instructions` — the TopicManager's
//! identifyAdmissibleOutputs. `judge` is the same over any store (tests).
//!
//! A topic manager answers its own metadata and documentation (the
//! TopicManager's getMetaData and getDocumentation): the engine's listing and
//! documentation routes call fn "metadata" or fn "documentation" with
//!
//!   {kind: "topic-describe", topic}
//!
//! and the answer is
//!
//!   {kind: "metadata", name, shortDescription, iconURL?, version?, informationURL?}
//!   {kind: "documentation", documentation: <markdown>}
//!
//! A program may define, beside `main`,
//!
//!   pub fn metadata(a, topic: []const u8) !topic.Metadata
//!   pub fn documentation(a, topic: []const u8) ![]const u8
//!
//! and `main` finds them. One it does not define answers the default: name
//! the configured topic name, shortDescription "", documentation "". How a
//! program answers is its own: a literal, or a file it reads from its tree.
//!
//! This file is the module `topic` of the skein-overlay package: an overlay
//! app's own topic manager depends on skein-overlay by URL+hash and does
//! `const topic = @import("topic");`.
const std = @import("std");
const c = @import("chain");

const cbor = c.cbor;
const Value = cbor.Value;
const Store = c.store.Store;
const Transaction = c.bsvz.transaction.Transaction;

/// A topic's decision on one transaction (BRC-22 AdmittanceInstructions):
/// output indices to admit, input indices whose admitted predecessors stay
/// queryable for history, and the transactions it relied on that are not
/// admitted (skein-overlay#4).
pub const Instructions = struct {
    outputs_to_admit: []const u32 = &.{},
    coins_to_retain: []const u32 = &.{},
    ancillary_txids: []const [32]u8 = &.{},
};

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
    /// The input sources the engine knows the instance does not have (0.19.0, the topic-call's
    /// `unheld`): neither in the submitted BEEF nor held by the chain app. Never read, though a
    /// block of one may be in the store (reads are global by CID, and a replay's store holds what
    /// came later): what the topic reads must be what the instance has, the same in a replay.
    unheld: []const [32]u8 = &.{},

    /// A transaction by txid, read through `get` (in the submit's call, its overlay), or null —
    /// null for one the engine names `unheld`.
    pub fn transaction(self: Call, txid: [32]u8) ?Transaction {
        for (self.unheld) |u| if (std.mem.eql(u8, &u, &txid)) return null;
        const raw = self.store.tryGet(self.arena, &c.store.hashCid(.tx, txid)) orelse return null;
        return Transaction.parse(self.arena, raw) catch null;
    }

    /// The input sources this call cannot read (not in the BEEF, not held), each once, in input
    /// order: what a topic manager that cannot decide without them names (`missingParents`).
    pub fn lacking(self: Call) ![][32]u8 {
        var out: std.ArrayList([32]u8) = .empty;
        outer: for (self.tx.inputs) |in| {
            const t = in.previous_outpoint.txid.bytes;
            for (out.items) |x| if (std.mem.eql(u8, &x, &t)) continue :outer;
            if (self.transaction(t) != null) continue;
            try out.append(self.arena, t);
        }
        return out.items;
    }

    /// The output an input spends, when its source transaction is readable.
    pub fn sourceOutput(self: Call, input_index: usize) ?c.bsvz.transaction.Output {
        if (input_index >= self.tx.inputs.len) return null;
        const in = self.tx.inputs[input_index];
        const src = self.transaction(in.previous_outpoint.txid.bytes) orelse return null;
        if (in.previous_outpoint.index >= src.outputs.len) return null;
        return src.outputs[in.previous_outpoint.index];
    }
};

/// A topic manager's metadata (BRC-22/24's listing entry). `name` null: the configured topic name.
pub const Metadata = struct {
    name: ?[]const u8 = null,
    short_description: []const u8 = "",
    icon_url: ?[]const u8 = null,
    version: ?[]const u8 = null,
    information_url: ?[]const u8 = null,
};

pub const Identify = fn (a: std.mem.Allocator, call: Call) anyerror!Instructions;

/// The error name a topic manager that cannot decide fails with (0.19.0).
pub const missing_parents = "MissingParents";

var needs_buf: std.ArrayList([32]u8) = .empty;

/// Fail the call as undecided: `needs` are the input sources it could not read (all of them; it
/// need not classify them). → `error.MissingParents`; `main` writes the line
/// `topic: MissingParents: <hex>,<hex>…`, and a native caller reads them with `lastNeeds`.
pub fn missingParents(needs: []const [32]u8) error{MissingParents} {
    needs_buf.clearRetainingCapacity();
    needs_buf.appendSlice(std.heap.page_allocator, needs) catch {};
    return error.MissingParents;
}

/// The transactions the last `missingParents` named (a native caller's read; the VM's is the
/// error line).
pub fn lastNeeds() []const [32]u8 {
    return needs_buf.items;
}

/// The error text of a call that failed with `MissingParents`: `MissingParents: <hex>,<hex>…`.
pub fn missingText(a: std.mem.Allocator, needs: []const [32]u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, missing_parents ++ ": ");
    for (needs, 0..) |n, i| {
        if (i > 0) try out.append(a, ',');
        try out.appendSlice(a, &c.header.toHex(n));
    }
    return out.items;
}

/// The transactions a failed call's error text names as missing parents (`MissingParents: <hex>,…`
/// anywhere in it, as the kernel prefixes it: `call <program>.identify: topic: MissingParents: …`),
/// or null when the error is another (a refusal).
pub fn needsOf(a: std.mem.Allocator, text: []const u8) !?[][32]u8 {
    const tag = missing_parents ++ ": ";
    const at = std.mem.indexOf(u8, text, tag) orelse return null;
    var rest = std.mem.trim(u8, text[at + tag.len ..], " \r\n");
    var out: std.ArrayList([32]u8) = .empty;
    while (rest.len > 0) {
        const end = std.mem.indexOfScalar(u8, rest, ',') orelse rest.len;
        const h = std.mem.trim(u8, rest[0..end], " ");
        try out.append(a, c.header.fromHex(h) catch return null);
        rest = if (end < rest.len) rest[end + 1 ..] else "";
    }
    if (out.items.len == 0) return null;
    return out.items;
}

fn uintList(a: std.mem.Allocator, v: ?Value) ![]u32 {
    const items = if (v) |x| (if (x == .array) x.array else return error.BadArgs) else return &.{};
    const out = try a.alloc(u32, items.len);
    for (items, out) |it, *o| o.* = if (it == .uint and it.uint <= std.math.maxInt(u32)) @intCast(it.uint) else return error.BadArgs;
    return out;
}

fn txidList(a: std.mem.Allocator, v: ?Value) ![][32]u8 {
    const items = if (v) |x| (if (x == .array) x.array else return error.BadArgs) else return &.{};
    const out = try a.alloc([32]u8, items.len);
    for (items, out) |it, *o| o.* = c.header.fromHex(if (it == .text) it.text else return error.BadArgs) catch return error.BadArgs;
    return out;
}

fn hexes(a: std.mem.Allocator, xs: []const [32]u8) ![]Value {
    const out = try a.alloc(Value, xs.len);
    for (xs, out) |x, *o| o.* = .{ .text = try a.dupe(u8, &c.header.toHex(x)) };
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
    const tx_cid = args.getCid("tx") orelse return error.BadArgs;
    const txid = c.store.bitcoinHash(tx_cid) orelse return error.BadArgs;
    const raw = s.get(a, tx_cid) catch return error.UnknownTransaction;
    return .{
        .arena = a,
        .store = s,
        .topic = args.getText("topic") orelse return error.BadArgs,
        .tx_cid = tx_cid,
        .txid = txid,
        .tx = Transaction.parse(a, raw) catch return error.BadTransaction,
        .previous_coins = try uintList(a, args.get("previousCoins")),
        .off_chain_values = args.getBytes("offChainValues"),
        .unheld = try txidList(a, args.get("unheld")),
    };
}

/// Judge a topic-call: the admittance record's value.
pub fn judge(a: std.mem.Allocator, s: Store, identify: Identify, args: Value) !Value {
    const call = try callOf(a, s, args);
    const ins = try identify(a, call);
    var es: std.ArrayList(cbor.Entry) = .empty;
    try es.appendSlice(a, &.{
        .{ .key = "kind", .value = .{ .text = "admittance" } },
        .{ .key = "topic", .value = .{ .text = call.topic } },
        .{ .key = "txid", .value = .{ .text = try a.dupe(u8, &c.header.toHex(call.txid)) } },
        .{ .key = "outputsToAdmit", .value = .{ .array = try uints(a, ins.outputs_to_admit) } },
        .{ .key = "coinsToRetain", .value = .{ .array = try uints(a, ins.coins_to_retain) } },
    });
    if (ins.ancillary_txids.len > 0) try es.append(a, .{ .key = "ancillaryTxids", .value = .{ .array = try hexes(a, ins.ancillary_txids) } });
    return .{ .map = es.items };
}

/// An admittance record's instructions (the engine reads them back).
pub fn instructionsOf(a: std.mem.Allocator, rec: Value) !Instructions {
    if (!std.mem.eql(u8, rec.getText("kind") orelse "", "admittance")) return error.BadAdmittance;
    return .{
        .outputs_to_admit = try uintList(a, rec.get("outputsToAdmit")),
        .coins_to_retain = try uintList(a, rec.get("coinsToRetain")),
        .ancillary_txids = try txidList(a, rec.get("ancillaryTxids")),
    };
}

/// A metadata record (`{kind: "metadata", …}`): `name` the configured name unless `m` names one.
pub fn metadataRecord(a: std.mem.Allocator, name: []const u8, m: Metadata) !Value {
    var es: std.ArrayList(cbor.Entry) = .empty;
    try es.appendSlice(a, &.{
        .{ .key = "kind", .value = .{ .text = "metadata" } },
        .{ .key = "name", .value = .{ .text = m.name orelse name } },
        .{ .key = "shortDescription", .value = .{ .text = m.short_description } },
    });
    if (m.icon_url) |x| try es.append(a, .{ .key = "iconURL", .value = .{ .text = x } });
    if (m.version) |x| try es.append(a, .{ .key = "version", .value = .{ .text = x } });
    if (m.information_url) |x| try es.append(a, .{ .key = "informationURL", .value = .{ .text = x } });
    return .{ .map = es.items };
}

/// Answer fn "metadata" or fn "documentation" from `Program`'s own (a namespace: the program's
/// root; `main` passes it), else the default.
pub fn describe(a: std.mem.Allocator, comptime Program: type, func: []const u8, args: Value) !Value {
    if (!std.mem.eql(u8, args.getText("kind") orelse "", "topic-describe")) return error.BadArgs;
    const name = args.getText("topic") orelse return error.BadArgs;
    if (std.mem.eql(u8, func, "metadata")) {
        const m: Metadata = if (@hasDecl(Program, "metadata")) try Program.metadata(a, name) else .{};
        return metadataRecord(a, name, m);
    }
    if (std.mem.eql(u8, func, "documentation")) {
        const d: []const u8 = if (@hasDecl(Program, "documentation")) try Program.documentation(a, name) else "";
        return .{ .map = try a.dupe(cbor.Entry, &.{
            .{ .key = "kind", .value = .{ .text = "documentation" } },
            .{ .key = "documentation", .value = .{ .text = d } },
        }) };
    }
    return error.UnknownFunction;
}

/// The program's main: a call of fn "identify" (its answer the admittance record), or of fn
/// "metadata" / "documentation" (the program's own, else the default). A `MissingParents` failure
/// ends the call with exit 1 and the line `topic: MissingParents: <hex>,…` (0.19.0).
pub fn main(comptime identify: Identify) u8 {
    const vm = @import("sk");
    const S = struct {
        fn run(a: std.mem.Allocator) anyerror!void {
            const in = try vm.input(a);
            if (!std.mem.eql(u8, in.getText("kind") orelse "", "call")) return error.CalledOnly;
            const func = in.getText("fn") orelse "";
            const arg = try vm.callArg(a, in);
            if (std.mem.eql(u8, func, "identify")) return vm.answer(a, try judge(a, vm.store(), identify, arg));
            try vm.answer(a, try describe(a, @import("root"), func, arg));
        }
        fn guarded(a: std.mem.Allocator) anyerror!void {
            run(a) catch |e| {
                if (e != error.MissingParents) return e;
                const line = try std.mem.concat(a, u8, &.{ "topic: ", try missingText(a, lastNeeds()), "\n" });
                std.Io.File.stderr().writeStreamingAll(vm.io(), line) catch {};
                return error.Undecided;
            };
        }
    };
    return vm.mainQuiet("topic", S.guarded, error.Undecided);
}
