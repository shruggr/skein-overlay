// skein-overlay (#36, split out of skein by #71): the overlay services engine,
// a skein app, with the example topic manager and lookup service it is tested
// with. Zig 0.16.0, wasm32-wasi, over the SDK's wallet library (skein-sdk
// `wallet`: the chain+settlement core and the overlay's maps; a URL+hash
// dependency).
//
//   zig build         → zig-out/bin/overlay.wasm (the engine), topic-demo.wasm (tm_demo), lookup-demo.wasm (ls_demo)
//   zig build bin     the same, written to bin/*.wasm (the app tree's modules; committed)
//   zig build test    the submission flow and the topic and lookup contracts, natively
//
// bsvz comes through the SDK (its lazy URL dependency).
const std = @import("std");

pub fn build(b: *std.Build) void {
    const wasi = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .wasi });
    const wallet = b.dependency("skein_sdk", .{ .target = wasi, .optimize = .ReleaseSafe }).module("wallet");
    const bin = b.addUpdateSourceFiles();
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
        bin.addCopyFileToSource(exe.getEmittedBin(), b.fmt("bin/{s}.wasm", .{p[0]}));
    }
    b.step("bin", "write the modules into the app tree: bin/{overlay,topic-demo,lookup-demo}.wasm").dependOn(&bin.step);

    const target = b.standardTargetOptions(.{});
    const native = b.dependency("skein_sdk", .{ .target = target, .optimize = .Debug }).module("wallet");
    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("test.zig"),
        .target = target,
        .optimize = .Debug,
        .imports = &.{.{ .name = "wallet", .module = native }},
    }) });
    const test_step = b.step("test", "The submission flow and the topic and lookup contracts, natively");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
