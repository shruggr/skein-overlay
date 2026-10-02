// skein-overlay (#36, split out of skein by #71, re-split by #79): the overlay
// services engine, a skein app, with the example topic manager and lookup
// service it is tested with. Zig 0.16.0, wasm32-wasi, over the SDK's chain
// library (skein-sdk `chain`: BEEF, SPV, merkle paths, the record store and
// the chain app's state, read only; a URL+hash dependency). No chain tracker,
// no wallet library: the chain state is the chain app's (shruggr/skein-chain).
//
// Modules (an app depends on skein-overlay by URL+hash, as on the SDK, and
// `b.dependency("skein_overlay", .{ .target = t, .optimize = o }).module(name)`):
//
//   topic    the topic manager contract: `topic.main(identify)`        src/topic.zig
//   lookup   the lookup service contract: `lookup.main(spec)`         src/lookup.zig
//   sk       the `skein` imports as an overlay program sees them      src/vm.zig
//            (topic and lookup import it; an app's program may too)
//
//   zig build         → zig-out/bin/overlay.wasm (the engine), topic-demo.wasm (tm_demo), lookup-demo.wasm (ls_demo)
//   zig build bin     the same, written to bin/*.wasm (the app tree's modules; committed)
//   zig build test    the submission flow and the topic and lookup contracts, natively
//
// bsvz comes through the SDK (its lazy URL dependency).
const std = @import("std");

const Mods = struct { chain: *std.Build.Module, sk: *std.Build.Module, topic: *std.Build.Module, lookup: *std.Build.Module };

/// The contract modules for one target, over the SDK's `chain` for that target.
fn mods(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, exported: bool) Mods {
    const chain = b.dependency("skein_sdk", .{ .target = target, .optimize = optimize }).module("chain");
    const mk = struct {
        fn f(bb: *std.Build, name: []const u8, path: []const u8, t: std.Build.ResolvedTarget, o: std.builtin.OptimizeMode, ex: bool, imps: []const std.Build.Module.Import) *std.Build.Module {
            const opts: std.Build.Module.CreateOptions = .{ .root_source_file = bb.path(path), .target = t, .optimize = o, .imports = imps };
            return if (ex) bb.addModule(name, opts) else bb.createModule(opts);
        }
    }.f;
    const sk = mk(b, "sk", "src/vm.zig", target, optimize, exported, &.{.{ .name = "chain", .module = chain }});
    const topic = mk(b, "topic", "src/topic.zig", target, optimize, exported, &.{ .{ .name = "chain", .module = chain }, .{ .name = "sk", .module = sk } });
    const lookup = mk(b, "lookup", "src/lookup.zig", target, optimize, exported, &.{ .{ .name = "chain", .module = chain }, .{ .name = "sk", .module = sk } });
    return .{ .chain = chain, .sk = sk, .topic = topic, .lookup = lookup };
}

fn imports(m: Mods) [4]std.Build.Module.Import {
    return .{ .{ .name = "chain", .module = m.chain }, .{ .name = "sk", .module = m.sk }, .{ .name = "topic", .module = m.topic }, .{ .name = "lookup", .module = m.lookup } };
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // The exported modules (what a dependent app imports), for the target it asks for.
    _ = mods(b, target, optimize, true);

    const wasi = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .wasi });
    const wm = mods(b, wasi, .ReleaseSafe, false);
    const wi = imports(wm);
    const bin = b.addUpdateSourceFiles();
    for ([_][2][]const u8{ .{ "overlay", "src/engine.zig" }, .{ "topic-demo", "src/topic_demo.zig" }, .{ "lookup-demo", "src/lookup_demo.zig" } }) |p| {
        const exe = b.addExecutable(.{
            .name = p[0],
            .root_module = b.createModule(.{
                .root_source_file = b.path(p[1]),
                .target = wasi,
                .optimize = .ReleaseSafe,
                .strip = true,
                .imports = &wi,
            }),
        });
        b.installArtifact(exe);
        bin.addCopyFileToSource(exe.getEmittedBin(), b.fmt("bin/{s}.wasm", .{p[0]}));
    }
    b.step("bin", "write the modules into the app tree: bin/{overlay,topic-demo,lookup-demo}.wasm").dependOn(&bin.step);

    const nm = mods(b, target, .Debug, false);
    const ni = imports(nm);
    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("test.zig"),
        .target = target,
        .optimize = .Debug,
        .imports = &ni,
    }) });
    const test_step = b.step("test", "The submission flow and the topic and lookup contracts, natively");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
