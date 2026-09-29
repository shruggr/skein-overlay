// The overlay programs (issue #36): Zig 0.16.0, wasm32-wasi, over wallet-zig
// (the chain+settlement core and the overlay's maps, a path dependency).
//
//   zig build         → zig-out/bin/overlay.wasm (the engine), topic-demo.wasm (tm_demo), lookup-demo.wasm (ls_demo)
//   zig build test    the topic and lookup contracts, natively
//
// bsvz comes through wallet-zig (../../.build/bsvz: scripts/fetch-bsvz.sh).
const std = @import("std");

pub fn build(b: *std.Build) void {
    const wasi = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .wasi });
    const wallet = b.dependency("wallet", .{ .target = wasi, .optimize = .ReleaseSafe }).module("wallet");
    for ([_][2][]const u8{ .{ "overlay", "src/engine.zig" }, .{ "topic-demo", "src/topic_demo.zig" }, .{ "lookup-demo", "src/lookup_demo.zig" } }) |p| {
        const exe = b.addExecutable(.{
            .name = p[0],
            .root_module = b.createModule(.{
                .root_source_file = b.path(p[1]),
                .target = wasi,
                .optimize = .ReleaseSafe,
                .strip = true,
                .imports = &.{.{ .name = "wallet", .module = wallet }},
            }),
        });
        b.installArtifact(exe);
    }

    const target = b.standardTargetOptions(.{});
    const native = b.dependency("wallet", .{ .target = target, .optimize = .Debug }).module("wallet");
    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("test.zig"),
        .target = target,
        .optimize = .Debug,
        .imports = &.{.{ .name = "wallet", .module = native }},
    }) });
    const test_step = b.step("test", "The topic and lookup contracts, natively");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
