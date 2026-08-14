const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const ziggy_dep = b.dependency("ziggy", .{
        .target = target,
        .optimize = optimize,
    });

    const command_mod = b.addModule("command", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const schema_mod = b.createModule(.{
        .root_source_file = b.path("src/schema.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });

    const codegen_mod = b.createModule(.{
        .root_source_file = b.path("codegen/main.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
        .imports = &.{
            .{ .name = "ziggy", .module = ziggy_dep.module("ziggy") },
            .{ .name = "schema", .module = schema_mod },
        },
    });
    const codegen = b.addExecutable(.{
        .name = "command-codegen",
        .root_module = codegen_mod,
    });
    b.installArtifact(codegen);

    const test_mod = b.addTest(.{
        .root_module = command_mod,
    });

    const run_tests = b.addRunArtifact(test_mod);

    const test_step = b.step("test", "Run libcommand tests");
    test_step.dependOn(&run_tests.step);
}

comptime {
    const minimum_zig_version = "0.16.0";
    const minimum = std.SemanticVersion.parse(minimum_zig_version) catch unreachable;

    if (builtin.zig_version.order(minimum) == .lt) {
        @compileError(std.fmt.comptimePrint(
            \\Your version of Zig is too old.
            \\Minimum required version: {s}
        , .{minimum_zig_version}));
    }
}
