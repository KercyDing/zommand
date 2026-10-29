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

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .imports = &.{
            .{ .name = "cli", .module = cli },
        },
    });

    const exe = b.addExecutable(.{
        .name = "greeting",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);
}
