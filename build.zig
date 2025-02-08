const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zzz = b.addModule("zzz", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    const tardy = b.dependency("tardy", .{
        .target = target,
        .optimize = optimize,
    }).module("tardy");

    zzz.addImport("tardy", tardy);

    const bearssl = b.dependency("bearssl", .{
        .target = target,
        .optimize = optimize,
        // Without this, you get an illegal instruction error on certain paths.
        // This makes it slightly slower but prevents faults.
        .BR_LE_UNALIGNED = false,
        .BR_BE_UNALIGNED = false,
    }).artifact("bearssl");

    zzz.linkLibrary(bearssl);

    add_example(b, "basic", false, target, optimize, zzz);
    add_example(b, "cookies", false, target, optimize, zzz);
    add_example(b, "form", false, target, optimize, zzz);
    add_example(b, "fs", false, target, optimize, zzz);
    add_example(b, "middleware", false, target, optimize, zzz);
    add_example(b, "sse", false, target, optimize, zzz);
    add_example(b, "tls", true, target, optimize, zzz);

    if (target.result.os.tag != .windows) {
        add_example(b, "unix", false, target, optimize, zzz);
    }

    const tests = b.addTest(.{
        .name = "unit-test",
        .root_source_file = b.path("./src/unit_test.zig"),
    });
    tests.root_module.addImport("tardy", tardy);
    tests.root_module.linkLibrary(bearssl);

    const run_test = b.addRunArtifact(tests);
    run_test.step.dependOn(&tests.step);

    const test_step = b.step("test", "Run general unit tests");
    test_step.dependOn(&run_test.step);
}

fn add_example(
    b: *std.Build,
    name: []const u8,
    link_libc: bool,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.Mode,
    zzz_module: *std.Build.Module,
) void {
    const example = b.addExecutable(.{
        .name = name,
        .root_source_file = b.path(b.fmt("./examples/{s}/main.zig", .{name})),
        .target = target,
        .optimize = optimize,
        .strip = false,
    });

    if (link_libc) {
        example.linkLibC();
    }

    example.root_module.addImport("zzz", zzz_module);

    const install_artifact = b.addInstallArtifact(example, .{});
    b.getInstallStep().dependOn(&install_artifact.step);

    const build_step = b.step(b.fmt("{s}", .{name}), b.fmt("Build zzz example ({s})", .{name}));
    build_step.dependOn(&install_artifact.step);

    const run_artifact = b.addRunArtifact(example);
    run_artifact.step.dependOn(&install_artifact.step);

    const run_step = b.step(b.fmt("run_{s}", .{name}), b.fmt("Run zzz example ({s})", .{name}));
    run_step.dependOn(&install_artifact.step);
    run_step.dependOn(&run_artifact.step);
}
