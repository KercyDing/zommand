const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const strip = b.option(bool, "strip", "Strip debug symbols") orelse false;
    const static = b.option(bool, "static", "Link libcurl statically") orelse true;

    const command_dep = b.dependency("libcommand", .{
        .target = target,
        .optimize = optimize,
    });
    const command_codegen = command_dep.artifact("command-codegen");
    const generate_schema = b.addRunArtifact(command_codegen);
    generate_schema.addFileArg(b.path("zis.ziggy"));
    const generated_schema = generate_schema.addOutputFileArg("zis_schema.zig");

    const curl_dep = b.dependency("curl", .{
        .target = target,
        .optimize = optimize,
        // The default setting is static.
        .link_vendor = static,
    });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .imports = &.{
            .{ .name = "command", .module = command_dep.module("command") },
            .{ .name = "curl", .module = curl_dep.module("curl") },
        },
    });

    if (!static) {
        exe_mod.linkSystemLibrary("curl", .{});
    }

    const schema_mod = b.createModule(.{
        .root_source_file = generated_schema,
        .imports = &.{
            .{ .name = "command", .module = command_dep.module("command") },
        },
    });
    exe_mod.addImport("zis_schema", schema_mod);

    const exe = b.addExecutable(.{
        .name = "zis",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run zis");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    run_step.dependOn(&run_cmd.step);

    const init_test_mod = b.createModule(.{
        .root_source_file = b.path("src/init.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zis_schema", .module = schema_mod },
        },
    });
    const init_tests = b.addTest(.{
        .root_module = init_test_mod,
    });
    const run_init_tests = b.addRunArtifact(init_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_init_tests.step);
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
