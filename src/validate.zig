const std = @import("std");

const schema = @import("schema.zig");
const util = @import("util.zig");

const Arg = schema.Arg;
const Cli = schema.Cli;

/// Returns true for valid command and argument names.
pub fn isValidName(name: []const u8) bool {
    if (name.len == 0 or name.len > util.max_name_len or name[0] == '-') return false;
    for (name) |byte| {
        if (byte == '=' or std.ascii.isWhitespace(byte)) return false;
    }
    return true;
}

/// Returns true for valid help placeholders.
pub fn isValidDisplayName(name: []const u8) bool {
    if (name.len == 0 or name.len > util.max_name_len) return false;
    for (name) |byte| {
        if (std.ascii.isWhitespace(byte)) return false;
    }
    return true;
}

/// Returns true for valid short argument names.
pub fn isValidShort(short: []const u8) bool {
    if (short.len != 1) return false;
    return short[0] != '-' and short[0] != '=' and short[0] != 'h' and short[0] != 'V';
}

/// Schema validation failure. Shared by code generation and `Generate`.
pub const Issue = union(enum) {
    invalid_version: []const u8,
    invalid_program_name: []const u8,
    missing_commands,
    invalid_command_name: []const u8,
    invalid_identifier: struct { name: []const u8, owner: []const u8 },
    missing_command_help: []const u8,
    missing_argument_help: struct { name: []const u8, owner: []const u8 },
    program_positional,
    multiple_positional,
    required_after_optional,
    invalid_placeholder: struct { name: []const u8, owner: []const u8 },
    reserved_argument_name: struct { name: []const u8, owner: []const u8 },
    invalid_short: struct { short: []const u8, owner: []const u8 },
    required_default: struct { name: []const u8, owner: []const u8 },
    multiple_default: struct { name: []const u8, owner: []const u8 },
    duplicate_command_name: []const u8,
    duplicate_command_id: struct { previous: []const u8, current: []const u8, id: []const u8 },
    duplicate_command_case: struct { previous: []const u8, current: []const u8 },
    duplicate_argument_id: struct {
        previous: []const u8,
        current: []const u8,
        id: []const u8,
        owner: []const u8,
    },
    duplicate_argument_name: struct { name: []const u8, owner: []const u8 },
    duplicate_short: struct { short: []const u8, owner: []const u8 },
    program_name_conflict: struct { name: []const u8, command: []const u8 },
    program_short_conflict: struct { short: []const u8, command: []const u8 },
};

/// Validates schema rules shared by code generation and `Generate`.
pub fn check(cli: Cli) ?Issue {
    _ = std.SemanticVersion.parse(cli.version) catch {
        return .{ .invalid_version = cli.version };
    };
    if (!isValidName(cli.name)) return .{ .invalid_program_name = cli.name };
    if (cli.commands.len == 0) return .missing_commands;

    if (checkArgs(cli.args, "program", true)) |issue| return issue;

    for (cli.commands, 0..) |command, index| {
        if (!isValidName(command.name)) {
            return .{ .invalid_command_name = command.name };
        }

        var command_buffer: [util.max_name_len]u8 = undefined;
        const command_id = util.toSnake(command.name, &command_buffer) orelse {
            return .{ .invalid_identifier = .{ .name = command.name, .owner = "program" } };
        };

        if (command.help.len == 0) {
            return .{ .missing_command_help = command.name };
        }
        if (checkArgs(command.args, command.name, false)) |issue| return issue;

        for (cli.commands[0..index]) |previous| {
            if (std.mem.eql(u8, command.name, previous.name)) {
                return .{ .duplicate_command_name = command.name };
            }

            var previous_buffer: [util.max_name_len]u8 = undefined;
            const previous_id = util.toSnake(previous.name, &previous_buffer) orelse {
                return .{ .invalid_identifier = .{ .name = previous.name, .owner = "program" } };
            };
            if (std.mem.eql(u8, command_id, previous_id)) {
                return .{ .duplicate_command_id = .{
                    .previous = previous.name,
                    .current = command.name,
                    .id = command_id,
                } };
            }
            if (std.ascii.eqlIgnoreCase(command_id, previous_id)) {
                return .{ .duplicate_command_case = .{
                    .previous = previous.name,
                    .current = command.name,
                } };
            }
        }
    }

    for (cli.args) |global_arg| {
        for (cli.commands) |command| {
            for (command.args) |command_arg| {
                if (!schema.isNamed(global_arg) or !schema.isNamed(command_arg)) continue;

                if (std.mem.eql(u8, schema.argName(global_arg), schema.argName(command_arg))) {
                    return .{ .program_name_conflict = .{
                        .name = schema.argName(global_arg),
                        .command = command.name,
                    } };
                }

                if (schema.argShort(global_arg)) |global_short| {
                    if (schema.argShort(command_arg)) |command_short| {
                        if (std.mem.eql(u8, global_short, command_short)) {
                            return .{ .program_short_conflict = .{
                                .short = global_short,
                                .command = command.name,
                            } };
                        }
                    }
                }
            }
        }
    }

    return null;
}

fn checkArgs(args: []const Arg, owner: []const u8, is_program: bool) ?Issue {
    var multiple_positional = false;
    var optional_positional = false;

    for (args, 0..) |arg, index| {
        const name = schema.argName(arg);
        if (!isValidName(name)) {
            return .{ .invalid_identifier = .{ .name = name, .owner = owner } };
        }

        var id_buffer: [util.max_name_len]u8 = undefined;
        const id = util.toSnake(name, &id_buffer) orelse {
            return .{ .invalid_identifier = .{ .name = name, .owner = owner } };
        };

        const help = switch (arg) {
            .positional => |value| value.help,
            .flag => |value| value.help,
            .option => |value| value.help,
        };
        if (help.len == 0) {
            return .{ .missing_argument_help = .{ .name = name, .owner = owner } };
        }

        switch (arg) {
            .positional => |value| {
                if (is_program) return .program_positional;
                if (multiple_positional) return .multiple_positional;
                if (value.required and optional_positional) return .required_after_optional;
                if (!value.required) optional_positional = true;
                multiple_positional = value.multiple;

                if (value.placeholder) |placeholder| {
                    if (!isValidDisplayName(placeholder)) {
                        return .{ .invalid_placeholder = .{
                            .name = placeholder,
                            .owner = owner,
                        } };
                    }
                }
            },
            .flag => |value| {
                if (std.mem.eql(u8, value.name, "help") or std.mem.eql(u8, value.name, "version")) {
                    return .{ .reserved_argument_name = .{ .name = value.name, .owner = owner } };
                }
                if (value.short) |short| {
                    if (!isValidShort(short)) {
                        return .{ .invalid_short = .{ .short = short, .owner = owner } };
                    }
                }
            },
            .option => |value| {
                if (std.mem.eql(u8, value.name, "help") or std.mem.eql(u8, value.name, "version")) {
                    return .{ .reserved_argument_name = .{ .name = value.name, .owner = owner } };
                }
                if (value.short) |short| {
                    if (!isValidShort(short)) {
                        return .{ .invalid_short = .{ .short = short, .owner = owner } };
                    }
                }
                if (value.required and value.default != null) {
                    return .{ .required_default = .{ .name = value.name, .owner = owner } };
                }
                if (value.multiple and value.default != null) {
                    return .{ .multiple_default = .{ .name = value.name, .owner = owner } };
                }
                if (value.placeholder) |placeholder| {
                    if (!isValidDisplayName(placeholder)) {
                        return .{ .invalid_placeholder = .{
                            .name = placeholder,
                            .owner = owner,
                        } };
                    }
                }
            },
        }

        for (args[0..index]) |previous| {
            var previous_buffer: [util.max_name_len]u8 = undefined;
            const previous_id = util.toSnake(schema.argName(previous), &previous_buffer) orelse {
                return .{ .invalid_identifier = .{
                    .name = schema.argName(previous),
                    .owner = owner,
                } };
            };
            if (std.mem.eql(u8, id, previous_id)) {
                return .{ .duplicate_argument_id = .{
                    .previous = schema.argName(previous),
                    .current = name,
                    .id = id,
                    .owner = owner,
                } };
            }

            if (schema.isNamed(arg) and schema.isNamed(previous)) {
                if (std.mem.eql(u8, name, schema.argName(previous))) {
                    return .{ .duplicate_argument_name = .{ .name = name, .owner = owner } };
                }
                if (schema.argShort(arg)) |short| {
                    if (schema.argShort(previous)) |previous_short| {
                        if (std.mem.eql(u8, short, previous_short)) {
                            return .{ .duplicate_short = .{ .short = short, .owner = owner } };
                        }
                    }
                }
            }
        }
    }

    return null;
}

test "rejects commands differing only by case" {
    const cli: Cli = .{
        .name = "p",
        .commands = &.{
            .{ .name = "image", .help = "Image" },
            .{ .name = "Image", .help = "Image" },
        },
    };

    const issue = check(cli) orelse return error.ExpectedIssue;
    try std.testing.expect(switch (issue) {
        .duplicate_command_case => true,
        else => false,
    });
}
