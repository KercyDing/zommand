const std = @import("std");
const schema = @import("schema.zig");

/// Errors returned when parsing process arguments fails.
pub const ParseError = error{
    OutOfMemory,
    ArgumentsUnavailable,
    MissingCommand,
    UnknownCommand,
    UnknownArgument,
    UnexpectedArgument,
    MissingRequiredArgument,
    MissingOptionValue,
    UnexpectedValue,
    DuplicateArgument,
};

/// Context collected for the most recent parse failure.
pub const Failure = struct {
    token: ?[]const u8 = null,
    arg: ?schema.Arg = null,
    /// Command selected when the failure occurred, so diagnostics suggest
    /// options of the command instead of another command's.
    selected: ?usize = null,
};

/// Values returned by a successful parse.
pub fn ParsedType(comptime Globals: type, comptime Result: type) type {
    return struct {
        globals: Globals,
        command: Result,
    };
}

/// Either parsed values, or a request to show help/version.
pub fn OutcomeType(comptime Globals: type, comptime Result: type) type {
    return union(enum) {
        parsed: ParsedType(Globals, Result),
        help: ?schema.Command,
        version: void,
    };
}

const Scope = enum { global, command };

const Match = struct {
    scope: Scope,
    arg_index: usize,
    value: ?[]const u8,
};

const Target = struct {
    scope: Scope,
    arg_index: usize,
    arg: schema.Arg,
};

const Request = union(enum) {
    help: ?schema.Command,
    version: void,
};

/// Parses an explicit argument slice, including the program name at index 0.
/// Does not print diagnostics or exit.
pub fn parse(
    comptime cli: schema.Cli,
    comptime Globals: type,
    comptime Result: type,
    allocator: std.mem.Allocator,
    argv: []const [:0]const u8,
    failure: *Failure,
) ParseError!OutcomeType(Globals, Result) {
    if (argv.len <= 1) return ParseError.MissingCommand;

    var matches: std.ArrayList(Match) = .empty;
    defer matches.deinit(allocator);

    var selected: ?usize = null;
    var positional_index: usize = 0;
    var options_done = false;
    var index: usize = 1;

    while (index < argv.len) : (index += 1) {
        const token: []const u8 = argv[index];
        failure.selected = selected;

        if (!options_done and std.mem.eql(u8, token, "--")) {
            options_done = true;
            continue;
        }

        if (!options_done and token.len > 1 and token[0] == '-') {
            const request = try matchNamed(
                cli,
                selected,
                argv,
                &index,
                token,
                failure,
                &matches,
                allocator,
            );
            if (request) |value| {
                return switch (value) {
                    .help => |command| .{ .help = command },
                    .version => .{ .version = {} },
                };
            }
            continue;
        }

        if (selected) |command_index| {
            inline for (cli.commands, 0..) |command, candidate| {
                if (command_index == candidate) {
                    const arg_index = try matchPositional(
                        command,
                        token,
                        &positional_index,
                        failure,
                    );
                    try matches.append(allocator, .{
                        .scope = .command,
                        .arg_index = arg_index,
                        .value = token,
                    });
                }
            }
        } else {
            selected = findCommand(cli, token) orelse {
                failure.token = token;
                return ParseError.UnknownCommand;
            };
            positional_index = 0;
        }
    }

    const command_index = selected orelse return ParseError.MissingCommand;

    var parsed: ParsedType(Globals, Result) = undefined;
    failure.selected = null;
    parsed.globals = try finalizeArgs(
        cli.args,
        Globals,
        matches.items,
        .global,
        allocator,
        failure,
    );
    errdefer freeArgs(cli.args, Globals, &parsed.globals, allocator);

    inline for (cli.commands, 0..) |command, candidate| {
        if (command_index == candidate) {
            const id = comptime schema.commandId(command);
            failure.selected = candidate;
            const command_value = try finalizeArgs(
                command.args,
                @FieldType(Result, id),
                matches.items,
                .command,
                allocator,
                failure,
            );
            parsed.command = @unionInit(Result, id, command_value);
        }
    }

    return .{ .parsed = parsed };
}

/// Releases slices allocated for repeated positional arguments and options.
pub fn deinit(
    comptime cli: schema.Cli,
    comptime Globals: type,
    comptime Result: type,
    parsed: *ParsedType(Globals, Result),
    allocator: std.mem.Allocator,
) void {
    freeArgs(cli.args, Globals, &parsed.globals, allocator);

    const tag = std.meta.activeTag(parsed.command);
    inline for (cli.commands) |command| {
        const id = comptime schema.commandId(command);
        if (tag == @field(@TypeOf(tag), id)) {
            freeArgs(
                command.args,
                @FieldType(Result, id),
                &@field(parsed.command, id),
                allocator,
            );
            return;
        }
    }
}

fn matchNamed(
    comptime cli: schema.Cli,
    selected: ?usize,
    argv: []const [:0]const u8,
    index: *usize,
    token: []const u8,
    failure: *Failure,
    matches: *std.ArrayList(Match),
    allocator: std.mem.Allocator,
) ParseError!?Request {
    if (std.mem.startsWith(u8, token, "--")) {
        const body = token[2..];
        const equals = std.mem.indexOfScalar(u8, body, '=');
        const name = if (equals) |position| body[0..position] else body;
        const attached = if (equals) |position| body[position + 1 ..] else null;

        if (std.mem.eql(u8, name, "help")) {
            if (attached != null) {
                failure.token = token;
                return ParseError.UnknownArgument;
            }
            return .{ .help = selectedCommand(cli, selected) };
        }
        if (std.mem.eql(u8, name, "version")) {
            if (attached != null) {
                failure.token = token;
                return ParseError.UnknownArgument;
            }
            return .{ .version = {} };
        }

        const target = findLong(cli, selected, name) orelse {
            failure.token = token;
            return ParseError.UnknownArgument;
        };
        try appendNamed(argv, index, target, attached, failure, matches, allocator);
        return null;
    }

    const body = token[1..];
    const equals = std.mem.indexOfScalar(u8, body, '=');
    if (equals) |position| {
        const name = body[0..position];
        if (name.len != 1) {
            failure.token = token;
            return ParseError.UnknownArgument;
        }

        const short = name[0];
        if (short == 'h' or short == 'V') {
            failure.token = token;
            return ParseError.UnknownArgument;
        }

        const target = findShort(cli, selected, short) orelse {
            failure.token = token;
            return ParseError.UnknownArgument;
        };
        try appendNamed(
            argv,
            index,
            target,
            body[position + 1 ..],
            failure,
            matches,
            allocator,
        );
        return null;
    }

    var position: usize = 0;
    while (position < body.len) : (position += 1) {
        const short = body[position];
        if (short == 'h') return .{ .help = selectedCommand(cli, selected) };
        if (short == 'V') return .{ .version = {} };

        const target = findShort(cli, selected, short) orelse {
            failure.token = token;
            return ParseError.UnknownArgument;
        };

        switch (target.arg) {
            .positional => unreachable,
            .flag => {
                try matches.append(allocator, .{
                    .scope = target.scope,
                    .arg_index = target.arg_index,
                    .value = null,
                });
            },
            .option => {
                const attached: ?[]const u8 =
                    if (position + 1 < body.len) body[position + 1 ..] else null;
                try appendNamed(
                    argv,
                    index,
                    target,
                    attached,
                    failure,
                    matches,
                    allocator,
                );
                return null;
            },
        }
    }

    return null;
}

fn appendNamed(
    argv: []const [:0]const u8,
    index: *usize,
    target: Target,
    attached: ?[]const u8,
    failure: *Failure,
    matches: *std.ArrayList(Match),
    allocator: std.mem.Allocator,
) ParseError!void {
    switch (target.arg) {
        .positional => unreachable,
        .flag => {
            if (attached != null) {
                failure.arg = target.arg;
                return ParseError.UnexpectedValue;
            }
            try matches.append(allocator, .{
                .scope = target.scope,
                .arg_index = target.arg_index,
                .value = null,
            });
        },
        .option => {
            const value = attached orelse try consumeValue(
                argv,
                index,
                target.arg,
                failure,
            );
            try matches.append(allocator, .{
                .scope = target.scope,
                .arg_index = target.arg_index,
                .value = value,
            });
        },
    }
}

fn consumeValue(
    argv: []const [:0]const u8,
    index: *usize,
    arg: schema.Arg,
    failure: *Failure,
) ParseError![]const u8 {
    if (index.* + 1 >= argv.len) {
        failure.arg = arg;
        return ParseError.MissingOptionValue;
    }

    const value: []const u8 = argv[index.* + 1];
    if (isNamedToken(value)) {
        failure.arg = arg;
        return ParseError.MissingOptionValue;
    }

    index.* += 1;
    return value;
}

fn isNamedToken(value: []const u8) bool {
    return value.len > 1 and value[0] == '-';
}

fn selectedCommand(comptime cli: schema.Cli, selected: ?usize) ?schema.Command {
    return if (selected) |index| cli.commands[index] else null;
}

fn findCommand(comptime cli: schema.Cli, name: []const u8) ?usize {
    inline for (cli.commands, 0..) |command, index| {
        if (std.mem.eql(u8, command.name, name)) return index;
    }
    return null;
}

fn findLong(
    comptime cli: schema.Cli,
    selected: ?usize,
    name: []const u8,
) ?Target {
    inline for (cli.args, 0..) |arg, index| {
        if (isNamed(arg) and std.mem.eql(u8, schema.argName(arg), name)) {
            return .{ .scope = .global, .arg_index = index, .arg = arg };
        }
    }

    if (selected) |command_index| {
        inline for (cli.commands, 0..) |command, candidate| {
            if (command_index == candidate) {
                inline for (command.args, 0..) |arg, index| {
                    if (isNamed(arg) and std.mem.eql(u8, schema.argName(arg), name)) {
                        return .{ .scope = .command, .arg_index = index, .arg = arg };
                    }
                }
            }
        }
    }

    return null;
}

fn findShort(
    comptime cli: schema.Cli,
    selected: ?usize,
    short: u8,
) ?Target {
    inline for (cli.args, 0..) |arg, index| {
        if (argShort(arg)) |value| {
            if (value[0] == short) {
                return .{ .scope = .global, .arg_index = index, .arg = arg };
            }
        }
    }

    if (selected) |command_index| {
        inline for (cli.commands, 0..) |command, candidate| {
            if (command_index == candidate) {
                inline for (command.args, 0..) |arg, index| {
                    if (argShort(arg)) |value| {
                        if (value[0] == short) {
                            return .{ .scope = .command, .arg_index = index, .arg = arg };
                        }
                    }
                }
            }
        }
    }

    return null;
}

fn matchPositional(
    comptime command: schema.Command,
    value: []const u8,
    positional_index: *usize,
    failure: *Failure,
) ParseError!usize {
    var found: usize = 0;
    inline for (command.args, 0..) |arg, arg_index| {
        switch (arg) {
            .positional => |positional| {
                if (found == positional_index.*) {
                    if (!positional.multiple) positional_index.* += 1;
                    return arg_index;
                }
                found += 1;
            },
            else => {},
        }
    }

    failure.token = value;
    return ParseError.UnexpectedArgument;
}

fn finalizeArgs(
    comptime args: []const schema.Arg,
    comptime T: type,
    matches: []const Match,
    scope: Scope,
    allocator: std.mem.Allocator,
    failure: *Failure,
) ParseError!T {
    var result: T = undefined;

    inline for (args) |arg| {
        switch (arg) {
            .positional => |value| {
                @field(result, schema.argId(arg)) = if (value.multiple)
                    &.{}
                else if (value.required)
                    ""
                else
                    null;
            },
            .flag => {
                @field(result, schema.argId(arg)) = false;
            },
            .option => |value| {
                @field(result, schema.argId(arg)) = if (value.multiple)
                    &.{}
                else if (value.default) |default|
                    default
                else if (value.required)
                    ""
                else
                    null;
            },
        }
    }
    errdefer freeArgs(args, T, &result, allocator);

    inline for (args, 0..) |arg, arg_index| {
        const count = countMatches(matches, scope, arg_index);
        switch (arg) {
            .positional => |value| {
                if (value.required and count == 0) {
                    failure.arg = arg;
                    return ParseError.MissingRequiredArgument;
                }
                if (!value.multiple and count > 1) {
                    failure.arg = arg;
                    return ParseError.DuplicateArgument;
                }
            },
            .flag => {
                if (count > 1) {
                    failure.arg = arg;
                    return ParseError.DuplicateArgument;
                }
            },
            .option => |value| {
                if (value.required and value.default == null and count == 0) {
                    failure.arg = arg;
                    return ParseError.MissingRequiredArgument;
                }
                if (!value.multiple and count > 1) {
                    failure.arg = arg;
                    return ParseError.DuplicateArgument;
                }
            },
        }

        switch (arg) {
            .positional => |value| {
                if (value.multiple and count > 0) {
                    const values = allocator.alloc([]const u8, count) catch {
                        return ParseError.OutOfMemory;
                    };
                    @field(result, schema.argId(arg)) = values;
                }
            },
            .flag => {},
            .option => |value| {
                if (value.multiple and count > 0) {
                    const values = allocator.alloc([]const u8, count) catch {
                        return ParseError.OutOfMemory;
                    };
                    @field(result, schema.argId(arg)) = values;
                }
            },
        }
    }

    var fill_counts: [args.len]usize = @splat(0);
    for (matches) |match| {
        if (match.scope != scope) continue;

        inline for (args, 0..) |arg, arg_index| {
            if (match.arg_index == arg_index) switch (arg) {
                .positional => |value| {
                    if (value.multiple) {
                        const values: [][]const u8 = @constCast(@field(result, schema.argId(arg)));
                        values[fill_counts[arg_index]] = match.value.?;
                        fill_counts[arg_index] += 1;
                    } else {
                        @field(result, schema.argId(arg)) = match.value.?;
                    }
                },
                .flag => {
                    @field(result, schema.argId(arg)) = true;
                },
                .option => |value| {
                    if (value.multiple) {
                        const values: [][]const u8 = @constCast(@field(result, schema.argId(arg)));
                        values[fill_counts[arg_index]] = match.value.?;
                        fill_counts[arg_index] += 1;
                    } else {
                        @field(result, schema.argId(arg)) = match.value.?;
                    }
                },
            };
        }
    }

    return result;
}

fn freeArgs(
    comptime args: []const schema.Arg,
    comptime T: type,
    result: *const T,
    allocator: std.mem.Allocator,
) void {
    inline for (args) |arg| {
        switch (arg) {
            .positional => |value| {
                if (value.multiple) {
                    const values = @field(result.*, schema.argId(arg));
                    if (values.len > 0) allocator.free(values);
                }
            },
            .flag => {},
            .option => |value| {
                if (value.multiple) {
                    const values = @field(result.*, schema.argId(arg));
                    if (values.len > 0) allocator.free(values);
                }
            },
        }
    }
}

fn countMatches(matches: []const Match, scope: Scope, arg_index: usize) usize {
    var count: usize = 0;
    for (matches) |match| {
        if (match.scope == scope and match.arg_index == arg_index) count += 1;
    }
    return count;
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
