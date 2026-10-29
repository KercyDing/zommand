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

    const curl = b.dependency("curl", .{
        .target = target,
        .optimize = optimize,
        .link_vendor = true,
    });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "cli", .module = cli },
            .{ .name = "curl", .module = curl.module("curl") },
        },
    });

    const exe = b.addExecutable(.{
        .name = "pack-fetch",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "cli", .module = cli },
            .{ .name = "curl", .module = curl.module("curl") },
        },
    });
    const tests = b.addTest(.{
        .root_module = test_mod,
    });

    const test_step = b.step("test", "Run pack-fetch tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
