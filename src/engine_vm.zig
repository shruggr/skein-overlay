//! The engine's wiring over the `skein` imports (the `sk` module, vm.zig):
//! its configuration (config.zig, through the `head` import), its calls of
//! topics and lookup services (`call`), messages to the instance itself
//! (`emit` to `self.identity`: the chain app's ingest, its own watch), the
//! gossip out (`emit` to the libp2p provider), and the chain state and the
//! overlay's state as a step or a call loads them. wasm32-wasi only.
const std = @import("std");
const c = @import("chain");
const vm = @import("sk");
const skein = @import("skein");
const config = @import("config.zig");
const calls = @import("calls.zig");
const gossip = @import("gossip.zig");
const state = @import("state.zig");
const submit = @import("submit.zig");

const cbor = c.cbor;
const Value = cbor.Value;
const Allocator = std.mem.Allocator;

var dummy: u8 = 0;

fn headImpl(_: *anyopaque, a: Allocator, name: []const u8) anyerror!?[]const u8 {
    return vm.head(a, name);
}

/// The heads through the `head` import (config.zig reads the engine's app record).
pub fn heads() config.Heads {
    return .{ .ctx = &dummy, .headFn = headImpl };
}

/// The input as the engine reads its configuration (#72, config.zig): from the app record it was
/// installed as (a call's `arg` names its dispatch row), else the genesis's; `app` set.
pub fn configured(a: Allocator, in: Value, arg: ?Value) !Value {
    return config.resolve(a, vm.store(), heads(), in, arg);
}

fn callerImpl(_: *anyopaque, a: Allocator, program: []const u8, func: []const u8, arg: Value) anyerror!Value {
    return vm.call(a, program, func, arg);
}

/// The overlay's calls of topics and lookup services (#50), over the `call` import.
pub fn caller() calls.Caller {
    return .{ .ctx = &dummy, .callFn = callerImpl };
}

var self_key: []const u8 = "";

fn sendImpl(_: *anyopaque, a: Allocator, box: []const u8, body: Value) anyerror![]const u8 {
    return vm.send(a, self_key, box, body);
}

var step_in: Value = .null;
/// The answers to submitters this step made (shruggr/skein#112), for its result record: `{to, box,
/// body, sent}` — `sent` false when no message reaches `to` (the answer is in the log only).
pub var answers: std.ArrayList(Value) = .empty;

fn answerImpl(_: *anyopaque, a: Allocator, to: []const u8, box: []const u8, body: Value) anyerror!void {
    const sent = try reaches(a, step_in, to);
    var es: std.ArrayList(cbor.Entry) = .empty;
    try es.appendSlice(a, &.{
        .{ .key = "to", .value = .{ .bytes = to } },
        .{ .key = "box", .value = .{ .text = box } },
    });
    if (sent) {
        try es.append(a, .{ .key = "message", .value = .{ .cid = try vm.send(a, to, box, body) } });
    } else try es.append(a, .{ .key = "body", .value = body });
    try es.append(a, .{ .key = "sent", .value = .{ .boolean = sent } });
    try answers.append(a, .{ .map = es.items });
}

/// Messages to the instance itself (the input's `self.identity`): looped back by the host; and the
/// answers to submitters, sent when a message reaches them.
pub fn wire(in: Value) !submit.Wire {
    self_key = vm.selfKey(in) orelse return error.NoIdentity;
    step_in = in;
    return .{ .ctx = &dummy, .sendFn = sendImpl, .answerFn = answerImpl };
}

/// The libp2p provider's key: the address book's entry at ("local", "libp2p") (the SDK's `peerAt`;
/// the address book has no roles, shruggr/skein#126), or null.
fn libp2pProvider(a: Allocator) !?[]const u8 {
    return skein.peerAt(a, "local", "libp2p");
}

/// Whether a message can reach `key`: the instance itself (looped back), or an entry of the address book.
pub fn reaches(a: Allocator, in: Value, key: []const u8) !bool {
    if (vm.selfKey(in)) |me| if (std.mem.eql(u8, me, key)) return true;
    return (try skein.peerOf(a, key)) != null;
}

var provider_key: []const u8 = "";

/// Publish on a GossipSub topic (#74): a message to the libp2p provider, box `publish`, body {topic,
/// body}. Not awaited — the provider's answer is recorded and runs nothing. Goes out when the step ends.
fn publishImpl(_: *anyopaque, a: Allocator, topic: []const u8, body: []const u8) anyerror!void {
    _ = try vm.send(a, provider_key, "publish", .{ .map = try a.dupe(cbor.Entry, &.{
        .{ .key = "topic", .value = .{ .text = topic } },
        .{ .key = "body", .value = .{ .bytes = body } },
    }) });
}

/// The overlay's gossip out (#74), over `emit` to the libp2p provider; null when the address book has
/// none (a host without libp2p): nothing is published.
pub fn gossipOut(a: Allocator) !?gossip.Out {
    provider_key = (try libp2pProvider(a)) orelse return null;
    return .{ .ctx = &dummy, .publishFn = publishImpl };
}

/// The network a chain state not yet written is on (genesis defaults.walletNetwork, else main).
pub fn network(in: Value) !c.chain.Network {
    const name = if (in.get("defaults")) |d| d.getText("walletNetwork") orelse "main" else "main";
    return c.chain.Network.parse(name) orelse error.BadConfig;
}

/// The head the overlay's state lives under: `<app>/state`.
pub fn stateHead(a: Allocator, in: Value) ![]const u8 {
    return std.fmt.allocPrint(a, "{s}/state", .{calls.appOf(in)});
}

/// The peers' admits (`<app>/gossip`, read only here): whom a pause's parents are wanted from.
pub fn gossipState(a: Allocator, in: Value) !*gossip.State {
    const g = try a.create(gossip.State);
    g.* = try gossip.State.load(a, vm.store(), try vm.head(a, try gossip.stateHead(a, calls.appOf(in))));
    return g;
}

/// The overlay's state (`<app>/state`) over the chain app's (`chain/state`, read only), as the store
/// sees them now; `head` the overlay state's CID it loaded.
pub fn load(a: Allocator, in: Value) !struct { st: state.State, head: ?[]const u8 } {
    const s = vm.store();
    const ch = try state.chainView(a, s, try vm.head(a, state.chain_head), try network(in));
    const h = try vm.head(a, try stateHead(a, in));
    return .{ .st = try state.State.load(a, s, h, ch), .head = h };
}
