const std = @import("std");
const builtin = @import("builtin.zig");
const dispatcher = @import("dispatch.zig");
const output = @import("output.zig");
const parser = @import("parse.zig");
const schema = @import("schema.zig");
const util = @import("util.zig");
const validate = @import("validate.zig");

/// Errors returned when parsing process arguments fails.
pub const ParseError = parser.ParseError;

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
    @setEvalBranchQuota(comptime util.evalBranchQuota(cli));
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

        /// Parses process arguments from `std.process.Init`, printing
        /// help/version or diagnostics and exiting when needed.
        pub fn parseOrExit(init: std.process.Init) Parsed {
            return parseOrExitArgs(init.io, init.arena.allocator(), init.minimal.args);
        }

        fn parseOrExitArgs(
            io: std.Io,
            arena: std.mem.Allocator,
            args: std.process.Args,
        ) Parsed {
            @setEvalBranchQuota(comptime util.evalBranchQuota(cli));
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

            if (slice.len == 1) {
                writeNoCommandHelp(io);
                std.process.exit(2);
            }

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
            @setEvalBranchQuota(comptime util.evalBranchQuota(cli));
            var failure: parser.Failure = .{};
            return parser.parse(cli, Globals, Result, arena, argv, &failure);
        }

        /// Releases slices allocated for repeated positional arguments and options.
        pub fn deinit(parsed: *Parsed, allocator: std.mem.Allocator) void {
            @setEvalBranchQuota(comptime util.evalBranchQuota(cli));
            parser.deinit(cli, Globals, Result, parsed, allocator);
        }

        /// Parses process arguments and calls the matching `handle<Command>`
        /// method on `app`. Missing handlers must be listed in `App.unhandled`;
        /// listed commands fail at runtime.
        pub fn run(init: std.process.Init, app: anytype) !void {
            const parsed = parseOrExit(init);
            if (dispatcher.unhandledCommand(&parsed, app)) |command_id| {
                std.log.err(
                    "command '{s}' is not implemented",
                    .{commandDisplayName(cli, command_id)},
                );
                std.process.exit(1);
            }
            return dispatcher.dispatchWithQuota(
                comptime util.evalBranchQuota(cli),
                init,
                &parsed,
                app,
            );
        }

        /// Calls the matching `handle<Command>` method on `app` for `parsed`.
        pub fn dispatch(init: std.process.Init, parsed: *const Parsed, app: anytype) !void {
            return dispatcher.dispatchWithQuota(
                comptime util.evalBranchQuota(cli),
                init,
                parsed,
                app,
            );
        }

        fn writeNoCommandHelp(io: std.Io) void {
            var buffer: [4096]u8 = undefined;
            const locked = io.lockStderr(&buffer, null) catch return;
            defer io.unlockStderr();
            const terminal = locked.terminal();

            builtin.writeHelp(cli, null, terminal.writer) catch {};
            terminal.writer.writeByte('\n') catch {};
            std.log.defaultLogFileTerminal(
                .err,
                .default,
                "expected command argument",
                .{},
                terminal,
            ) catch {};
        }

        fn showHelp(io: std.Io, command: ?schema.Command) noreturn {
            if (command) |target| {
                inline for (cli.commands) |candidate| {
                    if (std.mem.eql(u8, candidate.name, target.name)) {
                        builtin.showHelp(io, cli, candidate);
                    }
                }
                unreachable;
            }
            builtin.showHelp(io, cli, null);
        }

        fn writeDiagnostic(io: std.Io, err: ParseError, failure: *const parser.Failure) void {
            var message_buffer: [1024]u8 = undefined;
            var label_buffer: [1024]u8 = undefined;
            const body = diagnosticBody(err, failure, &message_buffer, &label_buffer);

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

fn argKind(arg: schema.Arg) []const u8 {
    return switch (arg) {
        .positional => "argument",
        .flag => "flag",
        .option => "option",
    };
}

fn argLabel(arg: schema.Arg, buffer: []u8) []const u8 {
    return switch (arg) {
        .positional => |value| std.fmt.bufPrint(
            buffer,
            "<{s}>",
            .{value.placeholder orelse value.name},
        ) catch unreachable,
        .flag => |value| std.fmt.bufPrint(
            buffer,
            "--{s}",
            .{value.name},
        ) catch unreachable,
        .option => |value| std.fmt.bufPrint(
            buffer,
            "--{s}",
            .{value.name},
        ) catch unreachable,
    };
}

fn diagnosticBody(
    err: ParseError,
    failure: *const parser.Failure,
    message_buffer: []u8,
    label_buffer: []u8,
) []const u8 {
    return switch (err) {
        error.OutOfMemory => "out of memory",
        error.ArgumentsUnavailable => "unable to read command-line arguments",
        error.MissingCommand => "expected command argument",
        error.UnknownCommand => std.fmt.bufPrint(
            message_buffer,
            "unrecognized command '{s}'",
            .{failure.token orelse ""},
        ) catch "unrecognized command",
        error.UnknownArgument => std.fmt.bufPrint(
            message_buffer,
            "unrecognized option '{s}'",
            .{failure.token orelse ""},
        ) catch "unrecognized option",
        error.UnexpectedArgument => std.fmt.bufPrint(
            message_buffer,
            "unexpected positional argument '{s}'",
            .{failure.token orelse ""},
        ) catch "unexpected positional argument",
        error.MissingRequiredArgument => std.fmt.bufPrint(
            message_buffer,
            "missing required {s} '{s}'",
            .{
                argKind(failure.arg.?),
                argLabel(failure.arg.?, label_buffer),
            },
        ) catch "missing required argument",
        error.MissingOptionValue => std.fmt.bufPrint(
            message_buffer,
            "expected value after '{s}'",
            .{argLabel(failure.arg.?, label_buffer)},
        ) catch "missing option value",
        error.UnexpectedValue => std.fmt.bufPrint(
            message_buffer,
            "{s} '{s}' does not take a value",
            .{
                argKind(failure.arg.?),
                argLabel(failure.arg.?, label_buffer),
            },
        ) catch "unexpected value",
        error.DuplicateArgument => std.fmt.bufPrint(
            message_buffer,
            "{s} '{s}' cannot be used multiple times",
            .{
                argKind(failure.arg.?),
                argLabel(failure.arg.?, label_buffer),
            },
        ) catch "duplicate argument",
    };
}

fn validateSchema(comptime cli: schema.Cli) void {
    if (validate.check(cli)) |issue| @compileError(issueMessage(issue));
}

fn issueMessage(comptime issue: validate.Issue) []const u8 {
    return switch (issue) {
        .invalid_version => |version| std.fmt.comptimePrint(
            "version '{s}' is not a valid semantic version",
            .{version},
        ),
        .invalid_program_name => |name| std.fmt.comptimePrint(
            "invalid program name '{s}'",
            .{name},
        ),
        .missing_commands => "CLI must contain at least one command",
        .invalid_command_name => |name| std.fmt.comptimePrint(
            "invalid command name '{s}'",
            .{name},
        ),
        .invalid_identifier => |value| std.fmt.comptimePrint(
            "name '{s}' is invalid: it must convert to a Zig identifier",
            .{value.name},
        ),
        .missing_command_help => |name| std.fmt.comptimePrint(
            "command '{s}' must have help text",
            .{name},
        ),
        .missing_argument_help => |value| std.fmt.comptimePrint(
            "argument '{s}' in '{s}' must have help text",
            .{ value.name, value.owner },
        ),
        .program_positional => "program-level arguments must be flags or options",
        .multiple_positional => "multiple positional argument must be the last positional argument",
        .required_after_optional => "required positional argument cannot follow an optional one",
        .invalid_placeholder => |value| std.fmt.comptimePrint(
            "invalid placeholder '{s}' in '{s}'",
            .{ value.name, value.owner },
        ),
        .reserved_argument_name => "argument name 'help' or 'version' is reserved",
        .invalid_short => |value| std.fmt.comptimePrint(
            "invalid short argument '{s}' in '{s}'",
            .{ value.short, value.owner },
        ),
        .required_default => |value| std.fmt.comptimePrint(
            "option '--{s}' cannot be required and have a default",
            .{value.name},
        ),
        .multiple_default => "multiple option cannot have a default value",
        .duplicate_command_name => |name| std.fmt.comptimePrint(
            "duplicate command name '{s}'",
            .{name},
        ),
        .duplicate_command_id => |value| std.fmt.comptimePrint(
            "commands '{s}' and '{s}' derive the same field '{s}'",
            .{ value.previous, value.current, value.id },
        ),
        .duplicate_command_case => |value| std.fmt.comptimePrint(
            "commands '{s}' and '{s}' differ only by case",
            .{ value.previous, value.current },
        ),
        .duplicate_argument_id => |value| std.fmt.comptimePrint(
            "arguments '{s}' and '{s}' both derive field '{s}' in '{s}'",
            .{ value.previous, value.current, value.id, value.owner },
        ),
        .duplicate_argument_name => |value| std.fmt.comptimePrint(
            "duplicate argument name '--{s}' in '{s}'",
            .{ value.name, value.owner },
        ),
        .duplicate_short => |value| std.fmt.comptimePrint(
            "duplicate short argument '-{s}' in '{s}'",
            .{ value.short, value.owner },
        ),
        .program_name_conflict => |value| std.fmt.comptimePrint(
            "program argument '--{s}' conflicts with command '{s}'",
            .{ value.name, value.command },
        ),
        .program_short_conflict => |value| std.fmt.comptimePrint(
            "program argument '-{s}' conflicts with command '{s}'",
            .{ value.short, value.command },
        ),
    };
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

        .flag => bool,

        .option => |value| if (value.multiple)
            []const []const u8
        else if (value.required or value.default != null)
            []const u8
        else
            ?[]const u8,
    };
}

fn hasField(comptime fields: anytype, comptime name: []const u8) bool {
    inline for (fields) |field| {
        if (std.mem.eql(u8, field, name)) return true;
    }
    return false;
}

fn commandDisplayName(comptime cli: schema.Cli, command_id: []const u8) []const u8 {
    inline for (cli.commands) |command| {
        var buffer: [util.max_name_len]u8 = undefined;
        const id = util.toSnake(command.name, &buffer) orelse unreachable;
        if (std.mem.eql(u8, id, command_id)) return command.name;
    }
    unreachable;
}

test "command display name keeps dashes" {
    const cli: schema.Cli = .{
        .name = "p",
        .commands = &.{.{ .name = "new-project", .help = "New project" }},
    };

    try std.testing.expectEqualStrings("new-project", commandDisplayName(cli, "new_project"));
}

test "dispatch calls app handlers" {
    const Globals = struct { verbose: bool };
    const Run = struct { target: []const u8 };
    const Result = union(enum) { run: Run };

    const Cli = Generate(.{
        .name = "p",
        .version = "0.0.1",
        .args = &.{.{ .flag = .{ .name = "verbose", .short = "v", .help = "Verbose output" } }},
        .commands = &.{.{
            .name = "run",
            .help = "Run command",
            .args = &.{.{
                .positional = .{ .name = "target", .help = "Target", .required = true },
            }},
        }},
    }, Globals, Result);

    const App = struct {
        calls: usize = 0,
        target: []const u8 = "",

        pub fn handleRun(self: *@This(), args: Run, globals: Globals) void {
            self.calls += 1;
            self.target = args.target;
            _ = globals;
        }
    };

    var parsed = switch (try Cli.parseArgs(
        std.testing.allocator,
        &.{ "p", "--verbose", "run", "x" },
    )) {
        .parsed => |value| value,
        else => unreachable,
    };
    defer Cli.deinit(&parsed, std.testing.allocator);

    var app = App{};
    const init: std.process.Init = undefined;
    try Cli.dispatch(init, &parsed, &app);

    try std.testing.expectEqual(@as(usize, 1), app.calls);
    try std.testing.expectEqualStrings("x", app.target);
}

test "parse supports equals, terminator, and clusters" {
    const Globals = struct { verbose: bool, dry: bool };
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
            .{ .flag = .{ .name = "verbose", .short = "v", .help = "Verbose output" } },
            .{ .flag = .{ .name = "dry", .short = "d", .help = "Dry run" } },
        },
        .commands = &.{.{
            .name = "run",
            .help = "Run command",
            .args = &.{
                .{ .positional = .{ .name = "target", .help = "Target" } },
                .{ .option = .{ .name = "name", .short = "n", .help = "Name" } },
                .{ .option = .{ .name = "include", .short = "i", .help = "Include path", .multiple = true } },
            },
        }},
    }, Globals, Result);

    var parsed = switch (try Cli.parseArgs(
        std.testing.allocator,
        &.{ "p", "-vd", "run", "-n=alice", "--", "-1" },
    )) {
        .parsed => |value| value,
        else => unreachable,
    };
    defer Cli.deinit(&parsed, std.testing.allocator);

    try std.testing.expect(parsed.globals.verbose);
    try std.testing.expect(parsed.globals.dry);
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
            .help = "Run command",
            .args = &.{
                .{ .option = .{ .name = "include", .short = "i", .help = "Include path", .multiple = true } },
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
            .{ .flag = .{ .name = "verbose", .short = "v", .help = "Verbose output" } },
        },
        .commands = &.{.{
            .name = "run",
            .help = "Run command",
            .args = &.{.{
                .positional = .{ .name = "target", .help = "Target" },
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
            .help = "Run command",
            .args = &.{.{
                .option = .{ .name = "name", .short = "n", .help = "Name" },
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
        .help = "Run command",
        .args = &.{.{ .positional = .{ .name = "target", .help = "Target" } }},
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
            .help = "Run command",
            .args = &.{
                .{ .positional = .{ .name = "target", .help = "Target" } },
                .{ .option = .{ .name = "name", .short = "n", .help = "Name" } },
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

test "command named program accepts positionals" {
    const Globals = struct {};
    const Program = struct { value: []const u8 };
    const Result = union(enum) { program: Program };

    const Cli = Generate(.{
        .name = "p",
        .commands = &.{.{
            .name = "program",
            .help = "Program command",
            .args = &.{.{
                .positional = .{ .name = "value", .help = "Value", .required = true },
            }},
        }},
    }, Globals, Result);

    var parsed = switch (try Cli.parseArgs(
        std.testing.allocator,
        &.{ "p", "program", "value" },
    )) {
        .parsed => |value| value,
        else => unreachable,
    };
    defer Cli.deinit(&parsed, std.testing.allocator);

    try std.testing.expectEqualStrings("value", parsed.command.program.value);
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
            .help = "Create a project",
            .args = &.{.{
                .flag = .{ .name = "dry-run", .help = "Dry run" },
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

test "help wraps long lines" {
    const long_help =
        "This is a deliberately long help sentence that must wrap onto " ++
        "multiple lines instead of overflowing the terminal width.";
    const command: schema.Command = .{
        .name = "run",
        .help = long_help,
        .args = &.{.{
            .option = .{ .name = "output", .help = long_help },
        }},
    };
    const cli: schema.Cli = .{
        .name = "p",
        .commands = &.{command},
    };

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try builtin.writeHelp(cli, command, &out.writer);
    const text = out.writer.buffered();

    var lines = std.mem.splitScalar(u8, text, '\n');
    var line_count: usize = 0;
    while (lines.next()) |line| {
        try std.testing.expect(line.len <= 80);
        line_count += 1;
    }
    try std.testing.expect(line_count > 4);
}

test "program help" {
    const cli: schema.Cli = .{
        .name = "zommand",
        .version = "0.0.1",
        .help = "Build CLIs.\nFast and small.",
        .args = &.{.{ .flag = .{ .name = "verbose", .short = "v", .help = "Verbose output" } }},
        .commands = &.{.{
            .name = "fetch",
            .help = "Fetch a package.",
        }},
    };

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try builtin.writeHelp(cli, null, &out.writer);
    const text = out.writer.buffered();

    try std.testing.expect(std.mem.startsWith(
        u8,
        text,
        "Build CLIs.\nFast and small.\n\nUsage: zommand [options] <command> [args]\n",
    ));
    try std.testing.expect(std.mem.indexOf(u8, text, "  fetch") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Fetch a package.") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "  -v, --verbose") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Verbose output") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "  -h, --help") != null);

    const fetch_column = helpDescriptionColumn(text, "fetch").?;
    const verbose_column = helpDescriptionColumn(text, "-v, --verbose").?;
    try std.testing.expectEqual(fetch_column, verbose_column);
    try std.testing.expectEqual(4, verbose_column - (2 + "-v, --verbose".len));
}

test "program help starts with usage without help" {
    const cli: schema.Cli = .{
        .name = "p",
        .version = "0.0.1",
        .commands = &.{.{ .name = "run", .help = "Run command" }},
    };

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try builtin.writeHelp(cli, null, &out.writer);
    const text = out.writer.buffered();

    try std.testing.expect(std.mem.startsWith(
        u8,
        text,
        "Usage: p [options] <command> [args]\n",
    ));
}

test "command help" {
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
    const cli: schema.Cli = .{
        .name = "downloader",
        .version = "0.0.1",
        .commands = &.{command},
    };

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try builtin.writeHelp(cli, command, &out.writer);
    const text = out.writer.buffered();

    try std.testing.expect(std.mem.indexOf(
        u8,
        text,
        "Usage: downloader download <URL> [options]",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "  <URL>") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "File URL") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "  -p, --path <dir>") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Directory (default: .)") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "  -h, --help") != null);

    const url_column = helpDescriptionColumn(text, "<URL>").?;
    const path_column = helpDescriptionColumn(text, "-p, --path <dir>").?;
    try std.testing.expectEqual(url_column, path_column);
    try std.testing.expectEqual(4, path_column - (2 + "-p, --path <dir>".len));
}

test "command help sizes only from displayed options" {
    const command: schema.Command = .{
        .name = "use",
        .help = "Select an installed model profile",
        .args = &.{.{ .positional = .{
            .name = "profile",
            .help = "Model profile",
            .required = true,
        } }},
    };
    const cli: schema.Cli = .{
        .name = "kocr",
        .version = "0.0.1",
        .commands = &.{command},
    };

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try builtin.writeHelp(cli, command, &out.writer);
    const text = out.writer.buffered();

    const profile_column = helpDescriptionColumn(text, "<profile>").?;
    const help_column = helpDescriptionColumn(text, "-h, --help").?;
    try std.testing.expectEqual(profile_column, help_column);
    try std.testing.expectEqual(4, help_column - (2 + "-h, --help".len));
}

test "large schema parses within quota" {
    const args: []const schema.Arg = &.{
        .{ .positional = .{ .name = "path", .help = "Path", .required = true } },
        .{ .flag = .{ .name = "flag0", .help = "Flag 0" } },
        .{ .flag = .{ .name = "flag1", .help = "Flag 1" } },
        .{ .flag = .{ .name = "flag2", .help = "Flag 2" } },
        .{ .flag = .{ .name = "flag3", .help = "Flag 3" } },
        .{ .flag = .{ .name = "flag4", .help = "Flag 4" } },
        .{ .flag = .{ .name = "flag5", .help = "Flag 5" } },
        .{ .flag = .{ .name = "flag6", .help = "Flag 6" } },
        .{ .flag = .{ .name = "flag7", .help = "Flag 7" } },
        .{ .flag = .{ .name = "flag8", .help = "Flag 8" } },
        .{ .flag = .{ .name = "flag9", .help = "Flag 9" } },
    };
    const Payload = struct {
        path: []const u8,
        flag0: bool,
        flag1: bool,
        flag2: bool,
        flag3: bool,
        flag4: bool,
        flag5: bool,
        flag6: bool,
        flag7: bool,
        flag8: bool,
        flag9: bool,
    };
    const Result = union(enum) {
        a: Payload,
        b: Payload,
        c: Payload,
        d: Payload,
        e: Payload,
    };
    const Cli = Generate(.{
        .name = "big",
        .version = "0.0.1",
        .commands = &.{
            .{ .name = "a", .help = "A", .args = args },
            .{ .name = "b", .help = "B", .args = args },
            .{ .name = "c", .help = "C", .args = args },
            .{ .name = "d", .help = "D", .args = args },
            .{ .name = "e", .help = "E", .args = args },
        },
    }, struct {}, Result);

    const argv = [_][:0]const u8{ "big", "a", "input.txt", "--flag0" };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const parsed = switch (try Cli.parseArgs(arena.allocator(), &argv)) {
        .parsed => |value| value,
        else => return error.UnexpectedOutcome,
    };
    try std.testing.expectEqualStrings("input.txt", parsed.command.a.path);
    try std.testing.expect(parsed.command.a.flag0);
    try std.testing.expect(!parsed.command.a.flag1);
}

fn helpDescriptionColumn(text: []const u8, label: []const u8) ?usize {
    const start = std.mem.lastIndexOf(u8, text, label) orelse return null;
    var index = start + label.len;
    while (index < text.len and text[index] == ' ') : (index += 1) {}
    if (index == text.len or text[index] == '\n') return null;

    const line_start = if (std.mem.lastIndexOfScalar(u8, text[0..start], '\n')) |pos| pos + 1 else 0;
    return index - line_start;
}
