//! The lookup contract (BRC-24 LookupService, issues #36, #50): a lookup
//! service is a program, pluggable in the submission flow as topic managers
//! are. It keeps its own storage — named maps (the shared MST module,
//! the SDK chain library's store.zig) under its own head `<app>/ls_<service>`
//! (the app it is part of: the engine names it, `app`, in every call), a record
//!
//!   {kind: "lookup-state", service, maps: {name: root | null}}
//!
//! — written only through its hooks, which the overlay engine calls (in-VM
//! calls, in the step that admits a submission or applies a rejection) with
//! CIDs, never bytes; the service reads the transactions through `get`:
//!
//!   fn "admitted"  {kind: "lookup-hook", app, service, topic, tx: <bitcoin-tx CID>, outputsToAdmit: [vout], coinsRetained: [input index]}
//!   fn "spent"     {kind: "lookup-hook", app, service, topic, outpoint: {tx: <CID>, vout}, spendingTx: <CID>}
//!   fn "rejected"  {kind: "lookup-hook", app, service, topic, tx: <CID>}
//!
//! (each may be a no-op), and answers queries from them — a read (#40): the
//! `/lookup` route calls fn "lookup" with
//!
//!   {kind: "lookup-call", app, service, query}          (query: the client's JSON as dag-cbor)
//!
//! and the answer is the call's answer (dag-cbor on stdout), one of
//!
//!   {kind: "lookup-answer", type: "output-list", outputs: [{beef, outputIndex, context?}]}
//!   {kind: "lookup-answer", type: "freeform", result}
//!
//! Each output's `beef` is the Atomic BEEF of its transaction, built from the
//! chain app's records (its head `chain/state`, read only: ancestry back to
//! proven transactions, with their BUMPs).
//!
//! A service is `pub fn main() u8 { return lookup.main(spec); }` with a
//! `Spec`: its map names, `answer`, and the hooks it implements. This file is
//! the module `lookup` of the skein-overlay package (`@import("lookup")`).
const std = @import("std");
const c = @import("chain");

const cbor = c.cbor;
const Value = cbor.Value;
/// The chain app's state (shruggr/skein-chain), read only.
pub const Chain = c.state.State;
const Store = c.store.Store;
const Map = c.store.Map;
const Transaction = c.bsvz.transaction.Transaction;
const Allocator = std.mem.Allocator;

/// The head the chain state lives under (the chain app's).
pub const chain_head = "chain/state";

pub const Output = struct { txid: [32]u8, vout: u32, context: ?[]const u8 = null };

pub const Answer = union(enum) {
    output_list: []const Output,
    freeform: Value,
};

/// A transaction a hook is about: its CID, txid, and the transaction its block decodes to.
pub const Tx = struct { cid: []const u8, txid: [32]u8, tx: Transaction };

pub const Outpoint = struct { txid: [32]u8, vout: u32 };

/// The head a service's state lives under: `<app>/ls_<service>` — a head under its app's name
/// (a service named `ls_x` is `<app>/ls_x`).
pub fn headName(a: Allocator, app: []const u8, service: []const u8) ![]u8 {
    if (std.mem.startsWith(u8, service, "ls_")) return std.mem.concat(a, u8, &.{ app, "/", service });
    return std.mem.concat(a, u8, &.{ app, "/ls_", service });
}

/// The app a call names (`app`; none: "overlay").
pub fn appOf(arg: Value) []const u8 {
    return arg.getText("app") orelse "overlay";
}

/// A lookup service's own storage: its named maps, loaded from its state record (null: new).
pub const Service = struct {
    arena: Allocator,
    store: Store,
    name: []const u8,
    names: []const []const u8,
    maps: *c.store.Maps,
    m: []Map,

    pub fn load(a: Allocator, s: Store, name: []const u8, names: []const []const u8, state: ?[]const u8) !Service {
        const maps = try c.store.Maps.create(a, s);
        var roots: ?Value = null;
        if (state) |sc| {
            const v = try s.getValue(a, sc);
            if (!std.mem.eql(u8, v.getText("kind") orelse "", "lookup-state")) return error.BadState;
            if (!std.mem.eql(u8, v.getText("service") orelse "", name)) return error.BadState;
            roots = v.get("maps") orelse return error.BadState;
        }
        const m = try a.alloc(Map, names.len);
        for (names, m) |n, *x| x.* = maps.map(if (roots) |r| r.getCid(n) else null);
        return .{ .arena = a, .store = s, .name = name, .names = names, .maps = maps, .m = m };
    }

    pub fn map(self: *Service, name: []const u8) *Map {
        for (self.names, self.m) |n, *x| if (std.mem.eql(u8, n, name)) return x;
        std.debug.panic("lookup service {s}: no map {s}", .{ self.name, name });
    }

    pub fn dirty(self: *const Service) bool {
        for (self.m) |x| if (x.dirty) return true;
        return false;
    }

    /// Flush the maps' new nodes and put the state record naming their roots; → its CID.
    pub fn save(self: *Service) ![]const u8 {
        const es = try self.arena.alloc(cbor.Entry, self.names.len);
        for (self.names, self.m, es) |n, *x, *e| {
            try x.flush();
            e.* = .{ .key = n, .value = if (x.root) |r| .{ .cid = r } else .null };
        }
        return self.store.putValue(self.arena, .{ .map = try self.arena.dupe(cbor.Entry, &.{
            .{ .key = "kind", .value = .{ .text = "lookup-state" } },
            .{ .key = "service", .value = .{ .text = self.name } },
            .{ .key = "maps", .value = .{ .map = es } },
        }) });
    }

    /// A transaction by CID, read through `get` and decoded.
    pub fn tx(self: *Service, tc: []const u8) !Tx {
        const txid = c.store.bitcoinHash(tc) orelse return error.BadArgs;
        const raw = self.store.get(self.arena, tc) catch return error.UnknownTransaction;
        return .{ .cid = tc, .txid = txid, .tx = Transaction.parse(self.arena, raw) catch return error.BadTransaction };
    }
};

pub const Spec = struct {
    /// The names of the service's maps (its state record's `maps`).
    maps: []const []const u8,
    /// `ch`: the chain state, read only (an output's spender, its BEEF).
    answer: *const fn (a: Allocator, svc: *Service, ch: *Chain, query: Value) anyerror!Answer,
    admitted: ?*const fn (a: Allocator, svc: *Service, topic: []const u8, tx: Tx, outputs_to_admit: []const u32, coins_retained: []const u32) anyerror!void = null,
    spent: ?*const fn (a: Allocator, svc: *Service, topic: []const u8, outpoint: Outpoint, spending: Tx) anyerror!void = null,
    rejected: ?*const fn (a: Allocator, svc: *Service, topic: []const u8, tx: Tx) anyerror!void = null,
};

fn uintList(a: Allocator, v: ?Value) ![]u32 {
    const items = if (v) |x| (if (x == .array) x.array else return error.BadArgs) else return &.{};
    const out = try a.alloc(u32, items.len);
    for (items, out) |it, *o| o.* = if (it == .uint and it.uint <= std.math.maxInt(u32)) @intCast(it.uint) else return error.BadArgs;
    return out;
}

/// Run one hook (fn "admitted" / "spent" / "rejected") on the service's storage.
pub fn hook(a: Allocator, spec: Spec, svc: *Service, func: []const u8, arg: Value) !void {
    if (!std.mem.eql(u8, arg.getText("kind") orelse "", "lookup-hook")) return error.BadArgs;
    const topic = arg.getText("topic") orelse return error.BadArgs;
    if (std.mem.eql(u8, func, "admitted")) {
        const f = spec.admitted orelse return;
        return f(a, svc, topic, try svc.tx(arg.getCid("tx") orelse return error.BadArgs), try uintList(a, arg.get("outputsToAdmit")), try uintList(a, arg.get("coinsRetained")));
    } else if (std.mem.eql(u8, func, "spent")) {
        const f = spec.spent orelse return;
        const op = arg.get("outpoint") orelse return error.BadArgs;
        const src = c.store.bitcoinHash(op.getCid("tx") orelse return error.BadArgs) orelse return error.BadArgs;
        const vout = op.getUint("vout") orelse return error.BadArgs;
        return f(a, svc, topic, .{ .txid = src, .vout = @intCast(vout) }, try svc.tx(arg.getCid("spendingTx") orelse return error.BadArgs));
    } else if (std.mem.eql(u8, func, "rejected")) {
        const f = spec.rejected orelse return;
        return f(a, svc, topic, try svc.tx(arg.getCid("tx") orelse return error.BadArgs));
    } else return error.UnknownFunction;
}

/// The answer record for a lookup-call: outputs with their transactions' BEEF.
pub fn answerRecord(a: Allocator, spec: Spec, svc: *Service, ch: *Chain, args: Value) !Value {
    if (!std.mem.eql(u8, args.getText("kind") orelse "", "lookup-call")) return error.BadArgs;
    const ans = try spec.answer(a, svc, ch, args.get("query") orelse .null);
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
                if (!gop.found_existing) gop.value_ptr.* = (try ch.beefOf(o.txid)) orelse return error.UnknownTransaction;
                var es: std.ArrayList(cbor.Entry) = .empty;
                try es.appendSlice(a, &.{
                    .{ .key = "beef", .value = .{ .bytes = gop.value_ptr.* } },
                    .{ .key = "outputIndex", .value = .{ .uint = o.vout } },
                });
                if (o.context) |cx| try es.append(a, .{ .key = "context", .value = .{ .bytes = cx } });
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

/// What a call of the service comes to: its answer, and its state record if a hook changed it.
pub const Handled = struct { answer: Value, state: ?[]const u8 = null };

/// One call of the service (fn "lookup" or a hook) over its storage (`state`:
/// its head's record) and, for a lookup, the chain state (`chain`: the head
/// `chain/state`'s record; its network is its own, else `network`). What
/// `main` runs; the tests call it directly.
pub fn handle(a: Allocator, spec: Spec, s: Store, network: c.chain.Network, state: ?[]const u8, chain: ?[]const u8, func: []const u8, arg: Value) !Handled {
    const service = arg.getText("service") orelse return error.BadArgs;
    var svc = try Service.load(a, s, service, spec.maps, state);
    if (std.mem.eql(u8, func, "lookup")) {
        var net = network;
        if (chain) |r| net = c.chain.Network.parse((try s.getValue(a, r)).getText("network") orelse "") orelse return error.BadChainState;
        var ch = try Chain.load(a, s, chain, net);
        return .{ .answer = try answerRecord(a, spec, &svc, &ch, arg) };
    }
    try hook(a, spec, &svc, func, arg);
    const done: Value = .{ .map = try a.dupe(cbor.Entry, &.{
        .{ .key = "kind", .value = .{ .text = "lookup-hooked" } },
        .{ .key = "fn", .value = .{ .text = func } },
    }) };
    return .{ .answer = done, .state = if (svc.dirty()) try svc.save() else null };
}

/// The program's main: a call — fn "lookup" (a read) or a hook (in a step:
/// the service's head `<app>/ls_<service>` advances when its maps changed —
/// a head under its own app's name, so the kernel lets it).
pub fn main(comptime spec: Spec) u8 {
    const vm = @import("sk");
    const S = struct {
        fn run(a: Allocator) anyerror!void {
            const in = try vm.input(a);
            if (!std.mem.eql(u8, in.getText("kind") orelse "", "call")) return error.CalledOnly;
            const func = in.getText("fn") orelse return error.BadInput;
            const arg = try vm.callArg(a, in);
            const head = try headName(a, appOf(arg), arg.getText("service") orelse return error.BadArgs);
            const chain_state = if (std.mem.eql(u8, func, "lookup")) try vm.head(a, chain_head) else null;
            const net_name = if (in.get("defaults")) |d| d.getText("walletNetwork") orelse "main" else "main";
            const network = c.chain.Network.parse(net_name) orelse return error.BadConfig;
            const h = try handle(a, spec, vm.store(), network, try vm.head(a, head), chain_state, func, arg);
            if (h.state) |sc| try vm.advance(head, sc);
            try vm.answer(a, h.answer);
        }
    };
    return vm.main("lookup", S.run);
}
