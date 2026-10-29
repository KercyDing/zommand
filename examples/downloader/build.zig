const std = @import("std");
const zommand = @import("zommand");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const strip = b.option(bool, "strip", "Strip debug symbols") orelse false;

    const cli = zommand.createCli(b, .{
        .target = target,
        .optimize = optimize,
        .schema = b.path("cli.zon"),
    });

    const dusty = b.dependency("dusty", .{
        .target = target,
        .optimize = optimize,
    });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .imports = &.{
            .{ .name = "cli", .module = cli },
            .{ .name = "dusty", .module = dusty.module("dusty") },
        },
    });

    const exe = b.addExecutable(.{
        .name = "downloader",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "cli", .module = cli },
            .{ .name = "dusty", .module = dusty.module("dusty") },
        },
    });
    const tests = b.addTest(.{
        .root_module = test_mod,
    });

    const test_step = b.step("test", "Run downloader tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
