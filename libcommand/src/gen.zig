const std = @import("std");
const schema = @import("schema.zig");

const ARG_COUNT_MAX = 64;

pub const ParseError = error{
    OutOfMemory,
    CommandNotFound,
    ArgumentNotFound,
    MissingRequiredArgument,
    MissingOptionValue,
    TooManyArguments,
};

pub fn Generate(comptime cli: *const schema.Cli) type {
    const ResultType = makeResultType(cli.*);

    return struct {
        pub const Result = ResultType;

        pub fn programName() []const u8 {
            return cli.name;
        }

        pub fn parse(
            allocator: std.mem.Allocator,
            args: []const [:0]const u8,
        ) ParseError!Result {
            if (args.len <= 1) return ParseError.CommandNotFound;

            inline for (cli.commands) |command| {
                if (std.mem.eql(u8, args[1], command.name)) {
                    const value = try parseCommand(command, allocator, args[2..]);
                    return @unionInit(Result, command.name, value);
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

fn makeResultType(comptime cli: schema.Cli) type {
    const field_count = cli.commands.len;

    if (field_count == 0) {
        @compileError("CLI must contain at least one command!");
    }

    var field_names: [field_count][]const u8 = undefined;
    var field_types: [field_count]type = undefined;
    var field_values: [field_count]u32 = undefined;
    var field_attrs: [field_count]std.builtin.Type.Union.FieldAttributes = @splat(.{});

    for (cli.commands, 0..) |cmd, i| {
        field_names[i] = cmd.name;
        field_types[i] = makeCommandType(cmd);
        field_values[i] = @intCast(i);
    }

    const CommandTag = @Enum(
        u32,
        .exhaustive,
        &field_names,
        &field_values,
    );

    return @Union(
        .auto,
        CommandTag,
        &field_names,
        &field_types,
        &field_attrs,
    );
}

fn makeCommandType(comptime command: schema.Command) type {
    validateCommand(command);

    const field_count = command.args.len;

    var field_names: [field_count][]const u8 = undefined;
    var field_types: [field_count]type = undefined;
    var field_attrs: [field_count]std.builtin.Type.Struct.FieldAttributes = @splat(.{});

    for (command.args, 0..) |arg, i| {
        field_names[i] = switch (arg) {
            .positional => |pos| pos.id,
            .flag => |flag| flag.id,
            .option => |option| option.id,
        };

        field_types[i] = switch (arg) {
            .positional => |pos| if (pos.multiple)
                []const []const u8
            else if (pos.required)
                []const u8
            else
                ?[]const u8,

            .flag => |flag| if (flag.multiple)
                usize
            else
                bool,

            .option => |option| if (option.multiple)
                []const []const u8
            else if (option.required or option.default != null)
                []const u8
            else
                ?[]const u8,
        };
    }

    return @Struct(
        .auto,
        null,
        &field_names,
        &field_types,
        &field_attrs,
    );
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
    allocator: std.mem.Allocator,
    args: []const [:0]const u8,
) ParseError!makeCommandType(command) {
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

    const Command = makeCommandType(command);
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
    result: *makeCommandType(command),
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
            const values = @field(result, id);
            if (values.len > 0) allocator.free(values);
        }
    }
}

test "makeCommandType : success : positional and flag" {
    const command: schema.Command = .{
        .name = "fetch",
        .args = &.{
            .{ .positional = .{
                .id = "url",
                .required = true,
            } },
            .{ .flag = .{
                .id = "force",
            } },
        },
    };

    const Fetch = makeCommandType(command);

    try std.testing.expect(
        @FieldType(Fetch, "url") == []const u8,
    );
    try std.testing.expect(
        @FieldType(Fetch, "force") == bool,
    );

    const value: Fetch = .{
        .url = "https://example.com",
        .force = true,
    };

    try std.testing.expectEqualStrings(
        "https://example.com",
        value.url,
    );
    try std.testing.expect(value.force);
}

test "Generate : success : preserve schema and generate result type" {
    const Cli = Generate(&.{
        .name = "zis",
        .commands = &.{.{
            .name = "fetch",
            .args = &.{
                .{ .positional = .{ .id = "url", .required = true } },
                .{ .flag = .{ .id = "force", .short = "f" } },
            },
        }},
    });

    try std.testing.expectEqualStrings(
        "zis",
        Cli.programName(),
    );

    const Fetch = @FieldType(Cli.Result, "fetch");

    try std.testing.expect(
        @FieldType(Fetch, "url") == []const u8,
    );

    try std.testing.expect(
        @FieldType(Fetch, "force") == bool,
    );
}
