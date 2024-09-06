const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const bearssl = b.dependency("bearssl", .{
        .target = target,
        .optimize = optimize,
        // Without this, you get an illegal instruction error on certain paths.
        // This makes it slightly.slower but prevents faults.
        .BR_LE_UNALIGNED = false,
        .BR_BE_UNALIGNED = false,
    }).artifact("bearssl");

    const zzz = b.addModule("zzz", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    zzz.linkLibrary(bearssl);

    addExample(b, "basic", false, target, optimize, zzz);
    addExample(b, "custom", false, target, optimize, zzz);
    addExample(b, "tls", true, target, optimize, zzz);
    addExample(b, "minram", false, target, optimize, zzz);
    addExample(b, "fs", false, target, optimize, zzz);
    addExample(b, "multithread", false, target, optimize, zzz);
    addExample(b, "benchmark", false, target, optimize, zzz);
    addExample(b, "valgrind", true, target, optimize, zzz);

    const tests = b.addTest(.{
        .name = "tests",
        .root_source_file = b.path("./src/test.zig"),
    });

    const run_test = b.addRunArtifact(tests);
    run_test.step.dependOn(&tests.step);

    const test_step = b.step("test", "Run general unit tests");
    test_step.dependOn(&run_test.step);
}

fn addExample(
    b: *std.Build,
    name: []const u8,
    link_libc: bool,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.Mode,
    zzz_module: *std.Build.Module,
) void {
    const example = b.addExecutable(.{
        .name = b.fmt("zzz_example_{s}", .{name}),
        .root_source_file = b.path(b.fmt("src/examples/{s}/main.zig", .{name})),
        .target = target,
        .optimize = optimize,
    });

    if (link_libc) {
        example.linkLibC();
    }

    example.root_module.addImport("zzz", zzz_module);
    const install_artifact = b.addInstallArtifact(example, .{});

    const run_cmd = b.addRunArtifact(example);
    run_cmd.step.dependOn(&install_artifact.step);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step(b.fmt("run_{s}", .{name}), b.fmt("Run zzz example ({s})", .{name}));
    run_step.dependOn(&run_cmd.step);
}
