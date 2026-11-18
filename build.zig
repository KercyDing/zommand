const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib_mod = b.addModule("command", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const codegen_mod = b.createModule(.{
        .root_source_file = b.path("src/codegen.zig"),
        .target = b.graph.host,
        .optimize = .debug,
    });
    const codegen = b.addExecutable(.{
        .name = "codegen",
        .root_module = codegen_mod,
    });
    b.installArtifact(codegen);

    const lib_tests = b.addTest(.{
        .root_module = lib_mod,
    });

    const test_step = b.step("test", "Run zommand tests");
    test_step.dependOn(&b.addRunArtifact(lib_tests).step);
    test_step.dependOn(&codegen.step);

    const invalid_fixtures = .{
        "test/invalid/case-command.zon",
        "test/invalid/empty-name.zon",
        "test/invalid/missing-help.zon",
    };

    inline for (invalid_fixtures) |fixture| {
        const invalid = b.addRunArtifact(codegen);
        invalid.addFileArg(b.path(fixture));
        _ = invalid.addOutputFileArg("cli.zig");
        invalid.expectExitCode(1);
        test_step.dependOn(&invalid.step);
    }

    const dispatch_failures = .{
        .{ .name = "missing_handler", .expect = "app has no handler for command 'foo' (expected `pub fn handleFoo(...)`, or list it in `App.unhandled`)" },
        .{ .name = "unknown_unhandled", .expect = "unhandled entry 'typo' does not match any command" },
        .{ .name = "malformed_unhandled", .expect = "App.unhandled must be a tuple or array of command names" },
        .{ .name = "field_injection", .expect = "cannot be supplied by dispatch (expected 'App', '*App', '*const App', std.process.Init, globals, or the command payload)" },
        .{ .name = "bad_return", .expect = "handler 'handleFoo' must return 'void' or '!void'" },
    };

    inline for (dispatch_failures) |fixture| {
        const fail_mod = b.createModule(.{
            .root_source_file = b.path("test/dispatch/" ++ fixture.name ++ ".zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "command", .module = lib_mod },
            },
        });
        const fail = b.addExecutable(.{
            .name = fixture.name,
            .root_module = fail_mod,
        });
        fail.expect_errors = .{ .contains = fixture.expect };
        test_step.dependOn(&fail.step);
    }
}

/// Creates a module from a `.zon` CLI schema.
pub fn createCli(
    b: *std.Build,
    options: struct {
        target: std.Build.ResolvedTarget,
        optimize: std.lang.Optimize,
        schema: std.Build.LazyPath,
    },
) *std.Build.Module {
    const dependency = b.dependency("zommand", .{
        .target = options.target,
        .optimize = options.optimize,
    });

    const generate = b.addRunArtifact(dependency.artifact("codegen"));
    generate.addFileArg(options.schema);

    return b.createModule(.{
        .root_source_file = generate.addOutputFileArg("cli.zig"),
        .imports = &.{
            .{ .name = "command", .module = dependency.module("command") },
        },
    });
}

comptime {
    const minimum_zig_version = "0.17.1";
    const minimum = std.SemanticVersion.parse(minimum_zig_version) catch unreachable;

    if (builtin.zig_version.order(minimum) == .lt) {
        @compileError(std.fmt.comptimePrint(
            \\Your version of Zig is too old.
            \\Minimum required version: {s}
        , .{minimum_zig_version}));
    }
}
