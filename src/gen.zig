const std = @import("std");
const schema = @import("schema.zig");

const ARG_COUNT_MAX = 64;

pub const ParseError = error{
    OutOfMemory,
    ArgumentsUnavailable,
    CommandNotFound,
    ArgumentNotFound,
    MissingRequiredArgument,
    MissingOptionValue,
    TooManyArguments,
};

pub fn Generate(comptime cli: schema.Cli, comptime ResultType: type) type {
    validateResult(cli, ResultType);

    return struct {
        pub const Result = ResultType;

        pub fn programName() []const u8 {
            return cli.name;
        }

        /// Parses process arguments. `arena` must be arena-style: the returned
        /// result borrows the converted argument strings.
        pub fn parse(
            io: std.Io,
            arena: std.mem.Allocator,
            args: std.process.Args,
        ) ParseError!Result {
            const slice = args.toSlice(arena) catch |err| switch (err) {
                error.OutOfMemory => return ParseError.OutOfMemory,
                else => return ParseError.ArgumentsUnavailable,
            };

            var help_requested = false;
            for (slice[1..]) |arg| {
                if (std.mem.eql(u8, arg, "--help")) {
                    help_requested = true;
                    break;
                }
            }
            if (help_requested) {
                if (slice.len >= 2) {
                    inline for (cli.commands) |command| {
                        if (std.mem.eql(u8, slice[1], command.name)) {
                            printHelp(io, command);
                        }
                    }
                }
                printHelp(io, null);
            }

            return parseSlice(arena, slice);
        }

        /// Writes help for the program, or for `command` when provided.
        pub fn writeHelp(
            writer: *std.Io.Writer,
            comptime command: ?schema.Command,
        ) std.Io.Writer.Error!void {
            try writeHelpText(cli, writer, command);
        }

        fn printHelp(io: std.Io, comptime command: ?schema.Command) noreturn {
            var buffer: [4096]u8 = undefined;
            var file_writer: std.Io.File.Writer = .init(.stdout(), io, &buffer);
            writeHelpText(cli, &file_writer.interface, command) catch {};
            file_writer.interface.flush() catch {};
            std.process.exit(0);
        }

        fn parseSlice(
            allocator: std.mem.Allocator,
            args: []const [:0]const u8,
        ) ParseError!Result {
            if (args.len <= 1) return ParseError.CommandNotFound;

            inline for (cli.commands) |command| {
                if (std.mem.eql(u8, args[1], command.name)) {
                    const value = try parseCommand(
                        command,
                        @FieldType(ResultType, command.name),
                        allocator,
                        args[2..],
                    );
                    return @unionInit(ResultType, command.name, value);
                }
            }

            return ParseError.CommandNotFound;
        }

        /// Releases slices allocated for repeated positional arguments and options.
        pub fn deinit(result: *Result, allocator: std.mem.Allocator) void {
            const tag = std.meta.activeTag(result.*);
            inline for (cli.commands) |command| {
                if (tag == @field(@TypeOf(tag), command.name)) {
                    freeCommandSlices(command, allocator, &@field(result.*, command.name));
                    return;
                }
            }
            unreachable;
        }
    };
}

fn writeHelpText(
    comptime cli: schema.Cli,
    writer: *std.Io.Writer,
    comptime command: ?schema.Command,
) std.Io.Writer.Error!void {
    if (command) |cmd| {
        try writeCommandHelp(cli, writer, cmd);
    } else {
        try writeProgramHelp(cli, writer);
    }
}

fn writeProgramHelp(comptime cli: schema.Cli, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    if (cli.version) |version| {
        try writer.print("{s} {s}\n", .{ cli.name, version });
    }
    if (cli.about.len != 0) {
        try writer.writeAll(cli.about);
        try writer.writeByte('\n');
    }
    if (cli.long_about) |long_about| {
        try writer.writeByte('\n');
        try writer.writeAll(long_about);
        try writer.writeByte('\n');
    }

    if (cli.about.len != 0 or cli.version != null or cli.long_about != null) {
        try writer.writeByte('\n');
    }
    try writer.print("Usage: {s} <command> [options]\n", .{cli.name});

    try writer.writeAll("\nCommands:\n");
    inline for (cli.commands) |command| {
        try writer.print("  {s}  {s}\n", .{ command.name, command.about });
    }

    try writer.writeAll("\nOptions:\n  --help  Print help\n");
}

fn writeCommandHelp(
    comptime cli: schema.Cli,
    writer: *std.Io.Writer,
    comptime command: schema.Command,
) std.Io.Writer.Error!void {
    if (command.about.len != 0) {
        try writer.writeAll(command.about);
        try writer.writeByte('\n');
    }
    if (command.long_about) |long_about| {
        try writer.writeByte('\n');
        try writer.writeAll(long_about);
        try writer.writeByte('\n');
    }

    if (command.about.len != 0 or command.long_about != null) {
        try writer.writeByte('\n');
    }
    try writer.print("Usage: {s} {s}", .{ cli.name, command.name });
    inline for (command.args) |arg| {
        switch (arg) {
            .positional => |positional| {
                try writer.writeAll(if (positional.required) " <" else " [<");
                try writer.writeAll(positional.id);
                try writer.writeAll(if (positional.required) ">" else ">]");
                if (positional.multiple) try writer.writeAll("...");
            },
            .flag, .option => {},
        }
    }
    if (commandHasNamed(command)) try writer.writeAll(" [options]");
    try writer.writeByte('\n');

    if (commandHasPositionals(command)) {
        try writer.writeAll("\nArguments:\n");
        inline for (command.args) |arg| {
            switch (arg) {
                .positional => |positional| {
                    try writer.print("  <{s}>  {s}\n", .{ positional.id, positional.help });
                },
                else => {},
            }
        }
    }

    if (commandHasNamed(command)) {
        try writer.writeAll("\nOptions:\n");
        inline for (command.args) |arg| {
            switch (arg) {
                .flag => |flag| {
                    try writer.writeAll("  ");
                    if (flag.short) |short| try writer.print("-{s}, ", .{short});
                    try writer.print("--{s}  {s}\n", .{ flag.id, flag.help });
                },
                .option => |option| {
                    try writer.writeAll("  ");
                    if (option.short) |short| try writer.print("-{s}, ", .{short});
                    try writer.print("--{s} <value>  {s}", .{ option.id, option.help });
                    if (option.required) try writer.writeAll(" (required)");
                    if (option.default) |default| try writer.print(" (default: {s})", .{default});
                    try writer.writeByte('\n');
                },
                .positional => {},
            }
        }
    }
}

fn commandHasNamed(comptime command: schema.Command) bool {
    for (command.args) |arg| {
        switch (arg) {
            .flag, .option => return true,
            .positional => {},
        }
    }
    return false;
}

fn commandHasPositionals(comptime command: schema.Command) bool {
    for (command.args) |arg| {
        switch (arg) {
            .positional => return true,
            .flag, .option => {},
        }
    }
    return false;
}

fn validateResult(comptime cli: schema.Cli, comptime ResultType: type) void {
    if (cli.commands.len == 0) {
        @compileError("CLI must contain at least one command!");
    }

    const union_info = switch (@typeInfo(ResultType)) {
        .@"union" => |info| info,
        else => @compileError("result type must be a union(enum)"),
    };
    if (union_info.tag_type == null) {
        @compileError("result type must be a union(enum)");
    }
    if (union_info.field_names.len != cli.commands.len) {
        @compileError("result union must contain exactly one field per command");
    }

    inline for (cli.commands) |command| {
        if (!hasField(union_info.field_names, command.name)) {
            @compileError(std.fmt.comptimePrint(
                "result union is missing field '{s}'",
                .{command.name},
            ));
        }
        validateCommand(command);
        validateCommandType(command, @FieldType(ResultType, command.name));
    }
}

fn validateCommandType(comptime command: schema.Command, comptime Command: type) void {
    const struct_info = switch (@typeInfo(Command)) {
        .@"struct" => |info| info,
        else => @compileError(std.fmt.comptimePrint(
            "command '{s}' must be represented by a struct",
            .{command.name},
        )),
    };
    if (struct_info.field_names.len != command.args.len) {
        @compileError(std.fmt.comptimePrint(
            "command '{s}' must have exactly one field per argument",
            .{command.name},
        ));
    }

    inline for (command.args) |arg| {
        const id = argId(arg);
        if (!hasField(struct_info.field_names, id)) {
            @compileError(std.fmt.comptimePrint(
                "command '{s}' is missing field '{s}'",
                .{ command.name, id },
            ));
        }
        if (@FieldType(Command, id) != expectedType(arg)) {
            @compileError(std.fmt.comptimePrint(
                "field '{s}' of command '{s}' has an unexpected type",
                .{ id, command.name },
            ));
        }
    }
}

fn hasField(comptime fields: anytype, comptime name: []const u8) bool {
    inline for (fields) |field| {
        if (std.mem.eql(u8, field, name)) return true;
    }
    return false;
}

fn argId(comptime arg: schema.Arg) []const u8 {
    return switch (arg) {
        .positional => |value| value.id,
        .flag => |value| value.id,
        .option => |value| value.id,
    };
}

fn expectedType(comptime arg: schema.Arg) type {
    return switch (arg) {
        .positional => |value| if (value.multiple)
            []const []const u8
        else if (value.required)
            []const u8
        else
            ?[]const u8,

        .flag => |value| if (value.multiple)
            usize
        else
            bool,

        .option => |value| if (value.multiple)
            []const []const u8
        else if (value.required or value.default != null)
            []const u8
        else
            ?[]const u8,
    };
}

fn validateCommand(comptime command: schema.Command) void {
    var multi_positional = false;

    for (command.args) |arg| {
        switch (arg) {
            .positional => |positional| {
                if (multi_positional) {
                    @compileError("multiple positional argument must be the last positional argument");
                }
                multi_positional = positional.multiple;
            },
            else => {},
        }
    }
}

fn parseCommand(
    comptime command: schema.Command,
    comptime Command: type,
    allocator: std.mem.Allocator,
    args: []const [:0]const u8,
) ParseError!Command {
    if (comptime command.args.len == 0) {
        if (args.len != 0) return ParseError.ArgumentNotFound;
        return .{};
    } else {
        var counts: [command.args.len]usize = @splat(0);
        var positional_index: usize = 0;
        var match_count: usize = 0;
        var index: usize = 0;

        while (index < args.len) {
            const match = try matchArg(command, args, index, &positional_index);
            match_count += 1;
            if (match_count > ARG_COUNT_MAX) return ParseError.TooManyArguments;
            counts[match.arg_index] += 1;
            index += match.consumed;
        }

        inline for (command.args, 0..) |arg, arg_index| {
            const required = switch (arg) {
                .positional => |value| value.required,
                .flag => false,
                .option => |value| value.required and value.default == null,
            };
            if (required and counts[arg_index] == 0) {
                return ParseError.MissingRequiredArgument;
            }
        }

        var result: Command = undefined;

        inline for (command.args) |arg| {
            switch (arg) {
                .positional => |positional| {
                    @field(result, positional.id) = if (positional.multiple)
                        &.{}
                    else if (positional.required)
                        ""
                    else
                        null;
                },
                .flag => |flag| {
                    @field(result, flag.id) = if (flag.multiple) 0 else false;
                },
                .option => |option| {
                    @field(result, option.id) = if (option.multiple)
                        &.{}
                    else if (option.default) |default|
                        default
                    else if (option.required)
                        ""
                    else
                        null;
                },
            }
        }

        errdefer freeCommandSlices(command, allocator, &result);

        inline for (command.args, 0..) |arg, arg_index| {
            switch (arg) {
                .positional => |positional| {
                    if (positional.multiple) {
                        @field(result, positional.id) = allocator.alloc(
                            []const u8,
                            counts[arg_index],
                        ) catch return ParseError.OutOfMemory;
                    }
                },
                .flag => {},
                .option => |option| {
                    if (option.multiple) {
                        @field(result, option.id) = allocator.alloc(
                            []const u8,
                            counts[arg_index],
                        ) catch return ParseError.OutOfMemory;
                    }
                },
            }
        }

        var fill_counts: [command.args.len]usize = @splat(0);
        positional_index = 0;
        index = 0;
        while (index < args.len) {
            const match = try matchArg(command, args, index, &positional_index);
            inline for (command.args, 0..) |arg, arg_index| {
                if (match.arg_index == arg_index) {
                    switch (arg) {
                        .positional => |positional| {
                            if (positional.multiple) {
                                const values: [][]const u8 = @constCast(@field(result, positional.id));
                                values[fill_counts[arg_index]] = match.value.?;
                                fill_counts[arg_index] += 1;
                            } else {
                                @field(result, positional.id) = match.value.?;
                            }
                        },
                        .flag => |flag| {
                            if (flag.multiple) {
                                @field(result, flag.id) += 1;
                            } else {
                                @field(result, flag.id) = true;
                            }
                        },
                        .option => |option| {
                            if (option.multiple) {
                                const values: [][]const u8 = @constCast(@field(result, option.id));
                                values[fill_counts[arg_index]] = match.value.?;
                                fill_counts[arg_index] += 1;
                            } else {
                                @field(result, option.id) = match.value.?;
                            }
                        },
                    }
                }
            }
            index += match.consumed;
        }

        return result;
    }
}

const ArgMatch = struct {
    arg_index: usize,
    value: ?[]const u8,
    consumed: usize,
};

fn matchArg(
    comptime command: schema.Command,
    args: []const [:0]const u8,
    index: usize,
    positional_index: *usize,
) ParseError!ArgMatch {
    const raw: []const u8 = args[index];
    if (!isNamedArg(raw)) return matchPositional(command, raw, positional_index);

    const arg_index = findNamedArg(command, raw) orelse return ParseError.ArgumentNotFound;
    return switch (command.args[arg_index]) {
        .positional => unreachable,
        .flag => .{ .arg_index = arg_index, .value = null, .consumed = 1 },
        .option => blk: {
            if (index + 1 >= args.len) return ParseError.MissingOptionValue;

            const value: []const u8 = args[index + 1];
            if (isNamedArg(value) and findNamedArg(command, value) != null) {
                return ParseError.MissingOptionValue;
            }
            break :blk .{ .arg_index = arg_index, .value = value, .consumed = 2 };
        },
    };
}

fn matchPositional(
    comptime command: schema.Command,
    value: []const u8,
    positional_index: *usize,
) ParseError!ArgMatch {
    var found_index: usize = 0;
    inline for (command.args, 0..) |arg, arg_index| {
        switch (arg) {
            .positional => |positional| {
                if (found_index == positional_index.*) {
                    if (!positional.multiple) positional_index.* += 1;
                    return .{ .arg_index = arg_index, .value = value, .consumed = 1 };
                }
                found_index += 1;
            },
            else => {},
        }
    }
    return ParseError.ArgumentNotFound;
}

fn findNamedArg(comptime command: schema.Command, raw: []const u8) ?usize {
    const name = stripHyphen(raw);
    inline for (command.args, 0..) |arg, arg_index| {
        const matches = switch (arg) {
            .positional => false,
            .flag => |flag| std.mem.eql(u8, flag.id, name) or
                (flag.short != null and std.mem.eql(u8, flag.short.?, name)),
            .option => |option| std.mem.eql(u8, option.id, name) or
                (option.short != null and std.mem.eql(u8, option.short.?, name)),
        };
        if (matches) return arg_index;
    }
    return null;
}

fn isNamedArg(value: []const u8) bool {
    return value.len > 1 and value[0] == '-';
}

fn stripHyphen(value: []const u8) []const u8 {
    if (std.mem.startsWith(u8, value, "--")) return value[2..];
    if (std.mem.startsWith(u8, value, "-")) return value[1..];
    return value;
}

fn freeCommandSlices(
    comptime command: schema.Command,
    allocator: std.mem.Allocator,
    result: anytype,
) void {
    inline for (command.args) |arg| {
        const multiple = switch (arg) {
            .positional => |value| value.multiple,
            .flag => false,
            .option => |value| value.multiple,
        };
        if (multiple) {
            const id = switch (arg) {
                .positional => |value| value.id,
                .flag => unreachable,
                .option => |value| value.id,
            };
            const values = @field(result.*, id);
            if (values.len > 0) allocator.free(values);
        }
    }
}

test "generate and parse explicit result" {
    const Fetch = struct {
        url: []const u8,
        force: bool,
    };
    const Result = union(enum) { fetch: Fetch };

    const Cli = Generate(.{
        .name = "zommand",
        .commands = &.{.{
            .name = "fetch",
            .args = &.{
                .{ .positional = .{ .id = "url", .required = true } },
                .{ .flag = .{ .id = "force", .short = "f" } },
            },
        }},
    }, Result);

    try std.testing.expectEqualStrings(
        "zommand",
        Cli.programName(),
    );

    var value = try Cli.parseSlice(
        std.testing.allocator,
        &.{ "zommand", "fetch", "--force", "https://example.com" },
    );
    defer Cli.deinit(&value, std.testing.allocator);

    try std.testing.expectEqualStrings(
        "https://example.com",
        value.fetch.url,
    );
    try std.testing.expect(value.fetch.force);
}

test "deinit frees repeated values" {
    const Build = struct {
        include: []const []const u8,
    };
    const Result = union(enum) { build: Build };

    const Cli = Generate(.{
        .name = "zommand",
        .commands = &.{.{
            .name = "build",
            .args = &.{
                .{ .option = .{ .id = "include", .multiple = true } },
            },
        }},
    }, Result);

    var value = try Cli.parseSlice(
        std.testing.allocator,
        &.{ "zommand", "build", "--include", "src", "--include", "tests" },
    );
    defer Cli.deinit(&value, std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), value.build.include.len);
    try std.testing.expectEqualStrings("src", value.build.include[0]);
    try std.testing.expectEqualStrings("tests", value.build.include[1]);
}

test "parse command without arguments" {
    const World = struct {};
    const Result = union(enum) { world: World };

    const Cli = Generate(.{
        .name = "hello",
        .commands = &.{.{
            .name = "world",
        }},
    }, Result);

    var value = try Cli.parseSlice(std.testing.allocator, &.{ "hello", "world" });
    defer Cli.deinit(&value, std.testing.allocator);
    try std.testing.expectEqual(World{}, value.world);

    try std.testing.expectError(
        ParseError.ArgumentNotFound,
        Cli.parseSlice(std.testing.allocator, &.{ "hello", "world", "extra" }),
    );
}

test "program help" {
    const Fetch = struct {};
    const Result = union(enum) { fetch: Fetch };
    const Cli = Generate(.{
        .name = "zommand",
        .version = "0.0.1",
        .about = "Build CLIs.",
        .commands = &.{.{
            .name = "fetch",
            .about = "Fetch a package.",
        }},
    }, Result);

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try Cli.writeHelp(&out.writer, null);
    const text = out.writer.buffered();

    try std.testing.expect(std.mem.startsWith(u8, text, "zommand 0.0.1\nBuild CLIs.\n"));
    try std.testing.expect(std.mem.indexOf(u8, text, "fetch  Fetch a package.") != null);
}

test "command help" {
    const Download = struct { url: []const u8, path: []const u8 };
    const Result = union(enum) { download: Download };
    const command: schema.Command = .{
        .name = "download",
        .about = "Download a file.",
        .args = &.{
            .{ .positional = .{ .id = "url", .help = "File URL", .required = true } },
            .{ .option = .{ .id = "path", .short = "p", .help = "Directory", .default = "." } },
        },
    };
    const Cli = Generate(.{
        .name = "downloader",
        .commands = &.{command},
    }, Result);

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try Cli.writeHelp(&out.writer, command);
    const text = out.writer.buffered();

    try std.testing.expect(std.mem.indexOf(
        u8,
        text,
        "Usage: downloader download <url> [options]",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "<url>  File URL") != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        text,
        "-p, --path <value>  Directory (default: .)",
    ) != null);
}
