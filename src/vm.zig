//! The skein calls as a program sees them (preview1 `skein` imports,
//! kernel-zig program.zig), and the few helpers every overlay program needs:
//! the step's (or call's) input, the store as wallet-zig's `Store`,
//! keep-and-print of a result record, in-VM calls and a call's answer.
//! wasm32-wasi only.
const std = @import("std");
const w = @import("wallet");

const cbor = w.cbor;
const Value = cbor.Value;

pub const sk = struct {
    pub extern "skein" fn input(out: [*]u8, cap: u32) i32;
    pub extern "skein" fn get(cid: [*]const u8, cid_len: u32, out: [*]u8, cap: u32) i32;
    pub extern "skein" fn put(data: [*]const u8, len: u32, out: [*]u8, cap: u32) i32;
    pub extern "skein" fn putblock(cid: [*]const u8, cid_len: u32, data: [*]const u8, len: u32) i32;
    pub extern "skein" fn keep(cid: [*]const u8, cid_len: u32) i32;
    pub extern "skein" fn launch(prog: [*]const u8, prog_len: u32, args: [*]const u8, args_len: u32, out: [*]u8, cap: u32) i32;
    pub extern "skein" fn head(name: [*]const u8, name_len: u32, out: [*]u8, cap: u32) i32;
    pub extern "skein" fn advance(name: [*]const u8, name_len: u32, tree: [*]const u8, tree_len: u32) i32;
    pub extern "skein" fn call(prog: [*]const u8, prog_len: u32, func: [*]const u8, func_len: u32, arg: [*]const u8, arg_len: u32, out: [*]u8, cap: u32) i32;
    pub extern "skein" fn take(out: [*]u8, cap: u32) i32;
    pub extern "skein" fn @"error"(out: [*]u8, cap: u32) i32;
    pub extern "skein" fn edges(to: [*]const u8, to_len: u32, rel: [*]const u8, rel_len: u32, out: [*]u8, cap: u32) i32;
};

var last_error: [1024]u8 = undefined;
var last_error_len: usize = 0;

pub fn failed() error{ImportFailed} {
    const n = sk.@"error"(&last_error, last_error.len);
    last_error_len = if (n < 0) 0 else @min(@as(usize, @intCast(n)), last_error.len);
    return error.ImportFailed;
}

pub fn lastError() []const u8 {
    return last_error[0..last_error_len];
}

/// Run an import that writes (out, cap), taking the held result when it did not fit.
pub fn result(arena: std.mem.Allocator, import: anytype, args: anytype) ![]u8 {
    var buf = try arena.alloc(u8, 4096);
    const n = @call(.auto, import, args ++ .{ buf.ptr, @as(u32, @intCast(buf.len)) });
    if (n < 0) return failed();
    const len: usize = @intCast(n);
    if (len <= buf.len) return buf[0..len];
    buf = try arena.alloc(u8, len);
    if (sk.take(buf.ptr, @intCast(len)) != n) return failed();
    return buf;
}

fn getImpl(_: *anyopaque, arena: std.mem.Allocator, cid: []const u8) anyerror![]const u8 {
    return result(arena, sk.get, .{ cid.ptr, @as(u32, @intCast(cid.len)) });
}
fn putImpl(_: *anyopaque, arena: std.mem.Allocator, bytes: []const u8) anyerror![]const u8 {
    return result(arena, sk.put, .{ bytes.ptr, @as(u32, @intCast(bytes.len)) });
}
fn putBlockImpl(_: *anyopaque, cid: []const u8, bytes: []const u8) anyerror!void {
    if (sk.putblock(cid.ptr, @intCast(cid.len), bytes.ptr, @intCast(bytes.len)) < 0) return failed();
}
fn keepImpl(_: *anyopaque, cid: []const u8) anyerror!void {
    if (sk.keep(cid.ptr, @intCast(cid.len)) < 0) return failed();
}
fn edgesImpl(_: *anyopaque, arena: std.mem.Allocator, to: []const u8, rel: ?[]const u8) anyerror![]const w.store.Edge {
    const r = rel orelse "";
    return w.store.decodeEdges(arena, try result(arena, sk.edges, .{ to.ptr, @as(u32, @intCast(to.len)), r.ptr, @as(u32, @intCast(r.len)) }));
}
var dummy: u8 = 0;

/// The record store through the `skein` get/put/putblock/keep imports: the
/// bitcoin blocks held are kept, so their links are the kernel's edges (#42).
pub fn store() w.store.Store {
    return .{ .ptr = &dummy, .getFn = getImpl, .putFn = putImpl, .putBlockFn = putBlockImpl, .keepFn = keepImpl, .edgesFn = edgesImpl };
}

/// The step's input record (kernel-zig scheduler.zig stepBody).
pub fn input(a: std.mem.Allocator) !Value {
    return cbor.decode(a, try result(a, sk.input, .{}));
}

/// The record a head names, or null.
pub fn head(a: std.mem.Allocator, name: []const u8) !?[]const u8 {
    const c = try result(a, sk.head, .{ name.ptr, @as(u32, @intCast(name.len)) });
    return if (c.len > 0) c else null;
}

pub fn advance(name: []const u8, cid: []const u8) !void {
    if (sk.advance(name.ptr, @intCast(name.len), cid.ptr, @intCast(cid.len)) < 0) return failed();
}

pub fn keep(cid: []const u8) !void {
    if (sk.keep(cid.ptr, @intCast(cid.len)) < 0) return failed();
}

/// Launch `program` (a program record's CID) on `args` (a record's CID): a child thread; the step then waits on it.
pub fn launch(a: std.mem.Allocator, program: []const u8, args: []const u8) ![]u8 {
    return result(a, sk.launch, .{ program.ptr, @as(u32, @intCast(program.len)), args.ptr, @as(u32, @intCast(args.len)) });
}

/// An in-VM call (#40): `program`'s function `func` on `arg` (dag-cbor) → its answer (dag-cbor), or the callee's error (`lastError`).
pub fn call(a: std.mem.Allocator, program: []const u8, func: []const u8, arg: Value) !Value {
    const bytes = try cbor.encode(a, arg);
    return cbor.decode(a, try result(a, sk.call, .{ program.ptr, @as(u32, @intCast(program.len)), func.ptr, @as(u32, @intCast(func.len)), bytes.ptr, @as(u32, @intCast(bytes.len)) }));
}

/// The answer of a call: dag-cbor on stdout.
pub fn answer(a: std.mem.Allocator, v: Value) !void {
    try std.fs.File.stdout().writeAll(try cbor.encode(a, v));
}

/// A call's argument: the input's `arg` bytes as dag-cbor.
pub fn callArg(a: std.mem.Allocator, in: Value) !Value {
    return cbor.decode(a, in.getBytes("arg") orelse return error.BadInput);
}

pub fn hexAlloc(a: std.mem.Allocator, b: []const u8) ![]u8 {
    const out = try a.alloc(u8, b.len * 2);
    const digits = "0123456789abcdef";
    for (b, 0..) |x, i| {
        out[2 * i] = digits[x >> 4];
        out[2 * i + 1] = digits[x & 15];
    }
    return out;
}

/// Put a result record, keep it in the thread, and print its CID (hex) on
/// stdout: what the thread's parent (or the router) reads.
pub fn finish(a: std.mem.Allocator, s: w.store.Store, rec: Value) ![]const u8 {
    const c = try s.putValue(a, rec);
    try keep(c);
    try std.fs.File.stdout().writeAll(try std.mem.concat(a, u8, &.{ try hexAlloc(a, c), "\n" }));
    return c;
}

/// A program's main around `run`: an error ends the step with exit 1 and a line on stderr.
pub fn main(comptime name: []const u8, comptime run: fn (std.mem.Allocator) anyerror!void) u8 {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.wasm_allocator);
    defer arena_state.deinit();
    run(arena_state.allocator()) catch |e| {
        var buf: [1400]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, name ++ ": {s}{s}{s}\n", .{ @errorName(e), if (last_error_len > 0) ": " else "", last_error[0..last_error_len] }) catch name ++ ": error\n";
        std.fs.File.stderr().writeAll(msg) catch {};
        return 1;
    };
    return 0;
}

/// The network the shared chain is on (genesis defaults.walletNetwork, else main).
pub fn network(step: Value) !w.chain.Network {
    const name = if (step.get("defaults")) |d| d.getText("walletNetwork") orelse "main" else "main";
    return w.chain.Network.parse(name) orelse error.BadConfig;
}

/// The chain + settlement core's state (the head `wallet`, #29/#37), shared with a wallet in the same instance.
pub const state_head = "wallet";
