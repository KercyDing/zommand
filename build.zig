const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

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
        .root_source_file = b.path("src/codegen/main.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
        .imports = &.{
            .{ .name = "schema", .module = schema_mod },
        },
    });
    const codegen = b.addExecutable(.{
        .name = "command-codegen",
        .root_module = codegen_mod,
    });
    b.installArtifact(codegen);

    const lib_tests = b.addTest(.{
        .root_module = command_mod,
    });

    const test_step = b.step("test", "Run zommand tests");
    test_step.dependOn(&b.addRunArtifact(lib_tests).step);
}

comptime {
    const minimum_zig_version = "0.17.0";
    const minimum = std.SemanticVersion.parse(minimum_zig_version) catch unreachable;

    if (builtin.zig_version.order(minimum) == .lt) {
        @compileError(std.fmt.comptimePrint(
            \\Your version of Zig is too old.
            \\Minimum required version: {s}
        , .{minimum_zig_version}));
    }
}
