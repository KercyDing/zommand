const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize: std.lang.Optimize = .fast;

    const zommand = b.dependency("zommand", .{
        .target = target,
        .optimize = optimize,
    });

    const generate = b.addRunArtifact(zommand.artifact("command-codegen"));
    generate.addFileArg(b.path("src/cli.zon"));
    const cli = b.createModule(.{
        .root_source_file = generate.addOutputFileArg("cli.zig"),
        .imports = &.{
            .{ .name = "command", .module = zommand.module("command") },
        },
    });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "cli", .module = cli },
        },
    });

    const exe = b.addExecutable(.{
        .name = "scaffold",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "cli", .module = cli },
        },
    });
    const tests = b.addTest(.{
        .root_module = test_mod,
    });

    const test_step = b.step("test", "Run scaffold tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
