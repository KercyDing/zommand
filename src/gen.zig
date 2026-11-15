const std = @import("std");
const builtin = @import("builtin.zig");
const output = @import("output.zig");
const parser = @import("parse.zig");
const schema = @import("schema.zig");

/// Errors returned when parsing process arguments fails.
pub const ParseError = parser.ParseError;

/// Errors returned when writing help for an unknown command.
pub const HelpError = error{UnknownCommand} || std.Io.Writer.Error;

/// Generates a typed parser for a CLI schema, its program-level arguments, and
/// the application result union.
///
/// `GlobalsType` must contain one field for each program-level argument.
/// `ResultType` must contain one field for each command.
pub fn Generate(
    comptime cli: schema.Cli,
    comptime GlobalsType: type,
    comptime ResultType: type,
) type {
    validateSchema(cli);
    validateGlobals(cli, GlobalsType);
    validateResult(cli, ResultType);

    return struct {
        /// Program-level argument values.
        pub const Globals = GlobalsType;
        /// The application result union returned by `parse`.
        pub const Result = ResultType;
        /// Result of a successful parse.
        pub const Parsed = parser.ParsedType(Globals, Result);
        /// Result of parsing a slice: either parsed values, or a request to
        /// show help/version.
        pub const Outcome = parser.OutcomeType(Globals, Result);

        /// Returns the program name declared in the CLI schema.
        pub fn programName() []const u8 {
            return cli.name;
        }

        /// Returns the configured program version.
        pub fn version() []const u8 {
            return cli.version;
        }

        /// Parses process arguments, printing help/version or diagnostics and
        /// exiting. Usage errors exit with code 2; argument read errors exit
        /// with code 1.
        pub fn parseOrExit(
            io: std.Io,
            arena: std.mem.Allocator,
            args: std.process.Args,
        ) Parsed {
            var failure: parser.Failure = .{};
            const slice = args.toSlice(arena) catch |err| switch (err) {
                error.OutOfMemory => {
                    writeDiagnostic(io, ParseError.OutOfMemory, &failure);
                    std.process.exit(1);
                },
                else => {
                    writeDiagnostic(io, ParseError.ArgumentsUnavailable, &failure);
                    std.process.exit(1);
                },
            };

            const outcome = parser.parse(
                cli,
                Globals,
                Result,
                arena,
                slice,
                &failure,
            ) catch |err| {
                writeDiagnostic(io, err, &failure);
                std.process.exit(switch (err) {
                    error.OutOfMemory, error.ArgumentsUnavailable => 1,
                    else => 2,
                });
            };

            switch (outcome) {
                .parsed => |parsed| return parsed,
                .help => |command| showHelp(io, command),
                .version => builtin.showVersion(io, cli),
            }
        }

        /// Parses an explicit argument slice, including the program name at
        /// index 0. Does not print diagnostics or exit.
        pub fn parseArgs(
            arena: std.mem.Allocator,
            argv: []const [:0]const u8,
        ) ParseError!Outcome {
            var failure: parser.Failure = .{};
            return parser.parse(cli, Globals, Result, arena, argv, &failure);
        }

        /// Writes program help or command help to `writer`.
        pub fn writeHelp(
            writer: *std.Io.Writer,
            command_name: ?[]const u8,
        ) HelpError!void {
            if (command_name) |name| {
                inline for (cli.commands) |command| {
                    if (std.mem.eql(u8, command.name, name)) {
                        return builtin.writeHelp(cli, command, writer);
                    }
                }
                return error.UnknownCommand;
            }
            return builtin.writeHelp(cli, null, writer);
        }

        /// Writes the configured program version to `writer`.
        pub fn writeVersion(writer: *std.Io.Writer) std.Io.Writer.Error!void {
            return builtin.writeVersion(cli, writer);
        }

        /// Releases slices allocated for repeated positional arguments and options.
        pub fn deinit(parsed: *Parsed, allocator: std.mem.Allocator) void {
            parser.deinit(cli, Globals, Result, parsed, allocator);
        }

        fn showHelp(io: std.Io, command: ?schema.Command) noreturn {
            if (command) |target| {
                inline for (cli.commands) |candidate| {
                    if (std.mem.eql(u8, candidate.name, target.name)) {
                        builtin.showHelp(io, cli, candidate);
                    }
                }
            }
            builtin.showHelp(io, cli, null);
        }

        fn writeDiagnostic(io: std.Io, err: ParseError, failure: *const parser.Failure) void {
            var message_buffer: [256]u8 = undefined;
            var label_buffer: [256]u8 = undefined;

            const body = switch (err) {
                error.OutOfMemory => "out of memory",
                error.ArgumentsUnavailable => "unable to read command-line arguments",
                error.MissingCommand => "a command is required",
                error.UnknownCommand => std.fmt.bufPrint(
                    &message_buffer,
                    "unknown command '{s}'",
                    .{failure.token orelse ""},
                ) catch "unknown command",
                error.UnknownArgument => std.fmt.bufPrint(
                    &message_buffer,
                    "unknown argument '{s}'",
                    .{failure.token orelse ""},
                ) catch "unknown argument",
                error.UnexpectedArgument => std.fmt.bufPrint(
                    &message_buffer,
                    "unexpected argument '{s}'",
                    .{failure.token orelse ""},
                ) catch "unexpected argument",
                error.MissingRequiredArgument => std.fmt.bufPrint(
                    &message_buffer,
                    "missing required argument '{s}'",
                    .{argLabel(failure.arg.?, &label_buffer)},
                ) catch "missing required argument",
                error.MissingOptionValue => std.fmt.bufPrint(
                    &message_buffer,
                    "argument '{s}' requires a value",
                    .{argLabel(failure.arg.?, &label_buffer)},
                ) catch "missing option value",
                error.UnexpectedValue => std.fmt.bufPrint(
                    &message_buffer,
                    "argument '{s}' does not take a value",
                    .{argLabel(failure.arg.?, &label_buffer)},
                ) catch "unexpected value",
                error.DuplicateArgument => std.fmt.bufPrint(
                    &message_buffer,
                    "argument '{s}' cannot be used multiple times",
                    .{argLabel(failure.arg.?, &label_buffer)},
                ) catch "duplicate argument",
            };

            switch (err) {
                error.OutOfMemory, error.ArgumentsUnavailable => {
                    output.printError(io, "{s}", .{body});
                },
                else => output.printError(
                    io,
                    "{s}\nTry '{s} --help' for more information.",
                    .{ body, cli.name },
                ),
            }
        }
    };
}

fn argLabel(arg: schema.Arg, buffer: []u8) []const u8 {
    return switch (arg) {
        .positional => |value| std.fmt.bufPrint(
            buffer,
            "<{s}>",
            .{value.placeholder orelse value.name},
        ) catch "argument",
        .flag => |value| std.fmt.bufPrint(
            buffer,
            "--{s}",
            .{value.name},
        ) catch "argument",
        .option => |value| std.fmt.bufPrint(
            buffer,
            "--{s}",
            .{value.name},
        ) catch "argument",
    };
}

fn validateSchema(comptime cli: schema.Cli) void {
    if (cli.commands.len == 0) {
        @compileError("CLI must contain at least one command");
    }

    validateArgs(cli.args, "program");

    inline for (cli.commands, 0..) |command, index| {
        validateCommand(command);

        inline for (cli.commands[0..index]) |previous| {
            if (std.mem.eql(u8, command.name, previous.name)) {
                @compileError(std.fmt.comptimePrint(
                    "duplicate command name '{s}'",
                    .{command.name},
                ));
            }
            if (std.mem.eql(u8, schema.commandId(command), schema.commandId(previous))) {
                @compileError(std.fmt.comptimePrint(
                    "commands '{s}' and '{s}' derive the same field '{s}'",
                    .{ previous.name, command.name, schema.commandId(command) },
                ));
            }
        }
    }

    inline for (cli.args) |global_arg| {
        inline for (cli.commands) |command| {
            inline for (command.args) |command_arg| {
                if (!isNamed(global_arg) or !isNamed(command_arg)) continue;

                if (std.mem.eql(
                    u8,
                    schema.argName(global_arg),
                    schema.argName(command_arg),
                )) {
                    @compileError(std.fmt.comptimePrint(
                        "program argument '--{s}' conflicts with command '{s}'",
                        .{ schema.argName(global_arg), command.name },
                    ));
                }

                if (argShort(global_arg)) |global_short| {
                    if (argShort(command_arg)) |command_short| {
                        if (std.mem.eql(u8, global_short, command_short)) {
                            @compileError(std.fmt.comptimePrint(
                                "program argument '-{s}' conflicts with command '{s}'",
                                .{ global_short, command.name },
                            ));
                        }
                    }
                }
            }
        }
    }
}

fn validateCommand(comptime command: schema.Command) void {
    validateCommandName(command.name);
    _ = schema.commandId(command);
    validateArgs(command.args, command.name);
}

fn validateArgs(comptime args: []const schema.Arg, comptime owner: []const u8) void {
    var multiple_positional = false;
    var optional_positional = false;

    inline for (args, 0..) |arg, index| {
        _ = schema.argId(arg);

        switch (arg) {
            .positional => |value| {
                if (std.mem.eql(u8, owner, "program")) {
                    @compileError("program-level arguments must be flags or options");
                }
                if (multiple_positional) {
                    @compileError("multiple positional argument must be the last positional argument");
                }
                if (value.required and optional_positional) {
                    @compileError("required positional argument cannot follow an optional one");
                }
                if (!value.required) optional_positional = true;
                multiple_positional = value.multiple;

                if (value.placeholder) |name| validateDisplayName(name, owner);
            },
            .flag => |value| {
                const long = value.name;
                validateLongName(long, owner);
                if (std.mem.eql(u8, long, "help") or std.mem.eql(u8, long, "version")) {
                    @compileError("argument name 'help' or 'version' is reserved");
                }
                if (value.short) |short| validateShort(short, owner);
            },
            .option => |value| {
                const long = value.name;
                validateLongName(long, owner);
                if (std.mem.eql(u8, long, "help") or std.mem.eql(u8, long, "version")) {
                    @compileError("argument name 'help' or 'version' is reserved");
                }
                if (value.short) |short| validateShort(short, owner);
                if (value.required and value.default != null) {
                    @compileError(std.fmt.comptimePrint(
                        "option '--{s}' cannot be required and have a default",
                        .{long},
                    ));
                }
                if (value.multiple and value.default != null) {
                    @compileError("multiple option cannot have a default value");
                }
                if (value.placeholder) |name| validateDisplayName(name, owner);
            },
        }

        inline for (args[0..index]) |previous| {
            if (std.mem.eql(u8, schema.argId(arg), schema.argId(previous))) {
                @compileError(std.fmt.comptimePrint(
                    "arguments '{s}' and '{s}' both derive field '{s}' in '{s}'",
                    .{ schema.argName(previous), schema.argName(arg), schema.argId(arg), owner },
                ));
            }

            if (isNamed(arg) and isNamed(previous)) {
                if (std.mem.eql(u8, schema.argName(arg), schema.argName(previous))) {
                    @compileError(std.fmt.comptimePrint(
                        "duplicate argument name '--{s}' in '{s}'",
                        .{ schema.argName(arg), owner },
                    ));
                }

                if (argShort(arg)) |short| {
                    if (argShort(previous)) |previous_short| {
                        if (std.mem.eql(u8, short, previous_short)) {
                            @compileError(std.fmt.comptimePrint(
                                "duplicate short argument '-{s}' in '{s}'",
                                .{ short, owner },
                            ));
                        }
                    }
                }
            }
        }
    }
}

fn validateCommandName(comptime name: []const u8) void {
    if (name.len == 0 or name[0] == '-') {
        @compileError("command name must not be empty or start with '-'");
    }
    for (name) |byte| {
        if (byte == '=' or std.ascii.isWhitespace(byte)) {
            @compileError("command name must not contain '=' or whitespace");
        }
    }
}

fn validateLongName(comptime name: []const u8, comptime owner: []const u8) void {
    if (name.len == 0 or name[0] == '-') {
        @compileError(std.fmt.comptimePrint(
            "argument name must not be empty or start with '-' in '{s}'",
            .{owner},
        ));
    }
    for (name) |byte| {
        if (byte == '=' or std.ascii.isWhitespace(byte)) {
            @compileError(std.fmt.comptimePrint(
                "argument name must not contain '=' or whitespace in '{s}'",
                .{owner},
            ));
        }
    }
}

fn validateDisplayName(comptime name: []const u8, comptime owner: []const u8) void {
    if (name.len == 0) {
        @compileError(std.fmt.comptimePrint(
            "value name must not be empty in '{s}'",
            .{owner},
        ));
    }
    for (name) |byte| {
        if (std.ascii.isWhitespace(byte)) {
            @compileError(std.fmt.comptimePrint(
                "value name must not contain whitespace in '{s}'",
                .{owner},
            ));
        }
    }
}

fn validateShort(comptime short: []const u8, comptime owner: []const u8) void {
    if (short.len != 1) {
        @compileError(std.fmt.comptimePrint(
            "short argument must be exactly one byte in '{s}'",
            .{owner},
        ));
    }
    if (short[0] == '-' or short[0] == '=') {
        @compileError(std.fmt.comptimePrint(
            "invalid short argument '-{s}' in '{s}'",
            .{ short, owner },
        ));
    }
    if (short[0] == 'h' or short[0] == 'V') {
        @compileError("short argument 'h' or 'V' is reserved");
    }
}

fn validateGlobals(comptime cli: schema.Cli, comptime GlobalsType: type) void {
    const struct_info = switch (@typeInfo(GlobalsType)) {
        .@"struct" => |info| info,
        else => @compileError("globals type must be a struct"),
    };
    if (struct_info.field_names.len != cli.args.len) {
        @compileError("globals struct must contain exactly one field per program argument");
    }

    inline for (cli.args) |arg| {
        const id = schema.argId(arg);
        if (!hasField(struct_info.field_names, id)) {
            @compileError(std.fmt.comptimePrint(
                "globals struct is missing field '{s}'",
                .{id},
            ));
        }
        if (@FieldType(GlobalsType, id) != expectedType(arg)) {
            @compileError(std.fmt.comptimePrint(
                "field '{s}' of globals has an unexpected type",
                .{id},
            ));
        }
    }
}

fn validateResult(comptime cli: schema.Cli, comptime ResultType: type) void {
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
        const id = schema.commandId(command);
        if (!hasField(union_info.field_names, id)) {
            @compileError(std.fmt.comptimePrint(
                "result union is missing field '{s}'",
                .{id},
            ));
        }
        validateCommandType(command, @FieldType(ResultType, id));
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
        const id = schema.argId(arg);
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

fn isNamed(comptime arg: schema.Arg) bool {
    return switch (arg) {
        .positional => false,
        .flag, .option => true,
    };
}

fn argShort(comptime arg: schema.Arg) ?[]const u8 {
    return switch (arg) {
        .positional => null,
        .flag => |value| value.short,
        .option => |value| value.short,
    };
}

fn hasField(comptime fields: anytype, comptime name: []const u8) bool {
    inline for (fields) |field| {
        if (std.mem.eql(u8, field, name)) return true;
    }
    return false;
}

test "parse supports equals, terminator, and clusters" {
    const Globals = struct { verbose: usize };
    const Run = struct {
        target: ?[]const u8,
        name: ?[]const u8,
        include: []const []const u8,
    };
    const Result = union(enum) { run: Run };

    const Cli = Generate(.{
        .name = "p",
        .version = "0.0.1",
        .args = &.{
            .{ .flag = .{ .name = "verbose", .short = "v", .multiple = true } },
        },
        .commands = &.{.{
            .name = "run",
            .args = &.{
                .{ .positional = .{ .name = "target" } },
                .{ .option = .{ .name = "name", .short = "n" } },
                .{ .option = .{ .name = "include", .short = "i", .multiple = true } },
            },
        }},
    }, Globals, Result);

    var parsed = switch (try Cli.parseArgs(
        std.testing.allocator,
        &.{ "p", "-vv", "run", "-n=alice", "--", "-1" },
    )) {
        .parsed => |value| value,
        else => unreachable,
    };
    defer Cli.deinit(&parsed, std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), parsed.globals.verbose);
    try std.testing.expectEqualStrings("alice", parsed.command.run.name.?);
    try std.testing.expectEqualStrings("-1", parsed.command.run.target.?);
}

test "parse supports attached short values and repeated options" {
    const Globals = struct {};
    const Run = struct { include: []const []const u8 };
    const Result = union(enum) { run: Run };

    const Cli = Generate(.{
        .name = "p",
        .version = "0.0.1",
        .commands = &.{.{
            .name = "run",
            .args = &.{
                .{ .option = .{ .name = "include", .short = "i", .multiple = true } },
            },
        }},
    }, Globals, Result);

    var parsed = switch (try Cli.parseArgs(
        std.testing.allocator,
        &.{ "p", "run", "-isrc", "--include", "tests" },
    )) {
        .parsed => |value| value,
        else => unreachable,
    };
    defer Cli.deinit(&parsed, std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), parsed.command.run.include.len);
    try std.testing.expectEqualStrings("src", parsed.command.run.include[0]);
    try std.testing.expectEqualStrings("tests", parsed.command.run.include[1]);
}

test "program arguments work before and after the command" {
    const Globals = struct { verbose: bool };
    const Run = struct { target: ?[]const u8 };
    const Result = union(enum) { run: Run };

    const Cli = Generate(.{
        .name = "p",
        .version = "0.0.1",
        .args = &.{
            .{ .flag = .{ .name = "verbose", .short = "v" } },
        },
        .commands = &.{.{
            .name = "run",
            .args = &.{.{
                .positional = .{ .name = "target" },
            }},
        }},
    }, Globals, Result);

    var before = switch (try Cli.parseArgs(
        std.testing.allocator,
        &.{ "p", "--verbose", "run", "x" },
    )) {
        .parsed => |value| value,
        else => unreachable,
    };
    defer Cli.deinit(&before, std.testing.allocator);

    try std.testing.expect(before.globals.verbose);
    try std.testing.expectEqualStrings("x", before.command.run.target.?);

    var after = switch (try Cli.parseArgs(
        std.testing.allocator,
        &.{ "p", "run", "-v", "x" },
    )) {
        .parsed => |value| value,
        else => unreachable,
    };
    defer Cli.deinit(&after, std.testing.allocator);

    try std.testing.expect(after.globals.verbose);
}

test "repeated non-multiple arguments are rejected" {
    const Globals = struct {};
    const Run = struct { name: ?[]const u8 };
    const Result = union(enum) { run: Run };

    const Cli = Generate(.{
        .name = "p",
        .version = "0.0.1",
        .commands = &.{.{
            .name = "run",
            .args = &.{.{
                .option = .{ .name = "name", .short = "n" },
            }},
        }},
    }, Globals, Result);

    try std.testing.expectError(
        ParseError.DuplicateArgument,
        Cli.parseArgs(
            std.testing.allocator,
            &.{ "p", "run", "--name", "a", "--name", "b" },
        ),
    );
}

test "help and version requests" {
    const Globals = struct {};
    const Run = struct { target: ?[]const u8 };
    const Result = union(enum) { run: Run };

    const command: schema.Command = .{
        .name = "run",
        .args = &.{.{ .positional = .{ .name = "target" } }},
    };
    const Cli = Generate(.{
        .name = "p",
        .version = "0.0.1",
        .commands = &.{command},
    }, Globals, Result);

    const program_help = try Cli.parseArgs(std.testing.allocator, &.{ "p", "--help" });
    try std.testing.expectEqual(@as(?schema.Command, null), program_help.help);

    const command_help = try Cli.parseArgs(std.testing.allocator, &.{ "p", "run", "-h" });
    try std.testing.expectEqualStrings("run", command_help.help.?.name);

    const version = try Cli.parseArgs(std.testing.allocator, &.{ "p", "-V" });
    try std.testing.expect(version == .version);
}

test "help used as an option value is not a request" {
    const Globals = struct {};
    const Run = struct { name: ?[]const u8, target: ?[]const u8 };
    const Result = union(enum) { run: Run };

    const Cli = Generate(.{
        .name = "p",
        .version = "0.0.1",
        .commands = &.{.{
            .name = "run",
            .args = &.{
                .{ .positional = .{ .name = "target" } },
                .{ .option = .{ .name = "name", .short = "n" } },
            },
        }},
    }, Globals, Result);

    try std.testing.expectError(
        ParseError.MissingOptionValue,
        Cli.parseArgs(
            std.testing.allocator,
            &.{ "p", "run", "--name", "--help" },
        ),
    );

    var parsed = switch (try Cli.parseArgs(
        std.testing.allocator,
        &.{ "p", "run", "--", "--help" },
    )) {
        .parsed => |value| value,
        else => unreachable,
    };
    defer Cli.deinit(&parsed, std.testing.allocator);
    try std.testing.expectEqualStrings("--help", parsed.command.run.target.?);
}

test "kebab-case names derive fields" {
    const Globals = struct {};
    const NewProject = struct { dry_run: bool };
    const Result = union(enum) { new_project: NewProject };

    const Cli = Generate(.{
        .name = "p",
        .version = "0.0.1",
        .commands = &.{.{
            .name = "new-project",
            .args = &.{.{
                .flag = .{ .name = "dry-run" },
            }},
        }},
    }, Globals, Result);

    var parsed = switch (try Cli.parseArgs(
        std.testing.allocator,
        &.{ "p", "new-project", "--dry-run" },
    )) {
        .parsed => |value| value,
        else => unreachable,
    };
    defer Cli.deinit(&parsed, std.testing.allocator);
    try std.testing.expect(parsed.command.new_project.dry_run);
}

test "version defaults to 0.0.1" {
    const Globals = struct {};
    const Run = struct {};
    const Result = union(enum) { run: Run };

    const Cli = Generate(.{
        .name = "p",
        .commands = &.{.{ .name = "run" }},
    }, Globals, Result);

    try std.testing.expectEqualStrings("0.0.1", Cli.version());

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try Cli.writeVersion(&out.writer);
    try std.testing.expectEqualStrings("0.0.1\n", out.writer.buffered());
}

test "writeHelp looks up a command at runtime" {
    const Globals = struct {};
    const Run = struct {};
    const Result = union(enum) { run: Run };

    const Cli = Generate(.{
        .name = "p",
        .commands = &.{.{ .name = "run" }},
    }, Globals, Result);

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try Cli.writeHelp(&out.writer, "run");
    try std.testing.expect(std.mem.indexOf(
        u8,
        out.writer.buffered(),
        "Usage: p run [options]",
    ) != null);

    try std.testing.expectError(
        error.UnknownCommand,
        Cli.writeHelp(&out.writer, "missing"),
    );
}

test "program help" {
    const Globals = struct { verbose: bool };
    const Fetch = struct {};
    const Result = union(enum) { fetch: Fetch };

    const Cli = Generate(.{
        .name = "zommand",
        .version = "0.0.1",
        .help = "Build CLIs.\nFast and small.",
        .args = &.{.{ .flag = .{ .name = "verbose", .short = "v", .help = "Verbose output" } }},
        .commands = &.{.{
            .name = "fetch",
            .help = "Fetch a package.",
        }},
    }, Globals, Result);

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try Cli.writeHelp(&out.writer, null);
    const text = out.writer.buffered();

    try std.testing.expect(std.mem.startsWith(
        u8,
        text,
        "Build CLIs.\nFast and small.\n\nUsage: zommand [options] <command> [args]\n",
    ));
    try std.testing.expect(std.mem.indexOf(u8, text, "  fetch            Fetch a package.") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "  -v, --verbose    Verbose output") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "  -h, --help       Print help") != null);
}

test "program help starts with usage without help" {
    const Globals = struct {};
    const Run = struct {};
    const Result = union(enum) { run: Run };

    const Cli = Generate(.{
        .name = "p",
        .version = "0.0.1",
        .commands = &.{.{ .name = "run" }},
    }, Globals, Result);

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try Cli.writeHelp(&out.writer, null);
    const text = out.writer.buffered();

    try std.testing.expect(std.mem.startsWith(
        u8,
        text,
        "Usage: p [options] <command> [args]\n",
    ));
}

test "command help" {
    const Globals = struct {};
    const Download = struct { url: []const u8, path: []const u8 };
    const Result = union(enum) { download: Download };
    const command: schema.Command = .{
        .name = "download",
        .help = "Download a file.",
        .args = &.{
            .{ .positional = .{
                .name = "url",
                .placeholder = "URL",
                .help = "File URL",
                .required = true,
            } },
            .{ .option = .{
                .name = "path",
                .short = "p",
                .placeholder = "dir",
                .help = "Directory",
                .default = ".",
            } },
        },
    };
    const Cli = Generate(.{
        .name = "downloader",
        .version = "0.0.1",
        .commands = &.{command},
    }, Globals, Result);

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try Cli.writeHelp(&out.writer, command.name);
    const text = out.writer.buffered();

    try std.testing.expect(std.mem.indexOf(
        u8,
        text,
        "Usage: downloader download <URL> [options]",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "  <URL>            File URL") != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        text,
        "  -p, --path <dir> Directory (default: .)",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        text,
        "  -h, --help       Print help",
    ) != null);
}
