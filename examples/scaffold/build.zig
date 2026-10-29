const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize: std.lang.Optimize = .fast;

    const zommand = b.dependency("zommand", .{
        .target = target,
        .optimize = optimize,
    });

    const generate_schema = b.addRunArtifact(zommand.artifact("command-codegen"));
    generate_schema.addFileArg(b.path("cli.ziggy"));
    const generated_schema = generate_schema.addOutputFileArg("cli_schema.zig");

    const cli_schema = b.createModule(.{
        .root_source_file = generated_schema,
        .imports = &.{
            .{ .name = "command", .module = zommand.module("command") },
        },
    });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "cli_schema", .module = cli_schema },
        },
    });

    const exe = b.addExecutable(.{
        .name = "scaffold",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.addPassthruArgs();

    const run_step = b.step("run", "Run scaffold");
    run_step.dependOn(&run_cmd.step);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "cli_schema", .module = cli_schema },
        },
    });
    const tests = b.addTest(.{
        .root_module = test_mod,
    });

    const test_step = b.step("test", "Run scaffold tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
