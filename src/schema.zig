const std = @import("std");
const util = @import("util.zig");

/// Runtime CLI schema used by generated parsers.
pub const Cli = struct {
    /// Program name, for example: "zommand".
    name: []const u8,

    /// Program version. Defaults to "0.0.1".
    version: []const u8 = "0.0.1",

    /// Help text shown above the usage line. May contain newlines.
    help: ?[]const u8 = null,

    /// Program-level flags and options.
    ///
    /// They are accepted before and after the command. Positional arguments
    /// are not allowed here because the first bare token selects the command.
    /// Accepts a single argument or an array of arguments.
    args: []const Arg = &.{},

    /// Available subcommands. Accepts a single command or an array of commands.
    commands: []const Command = &.{},
};

pub const Command = struct {
    /// Command name shown on the command line, for example: "new-project".
    /// `-` is converted to `_` for the generated Zig field and type name.
    name: []const u8,
    /// Help text shown in the command list and command help.
    help: []const u8,
    /// Arguments owned by this command. Accepts a single argument or an array
    /// of arguments.
    args: []const Arg = &.{},
};

pub const Arg = union(enum) {
    positional: Positional,
    flag: Flag,
    option: Option,
};

pub const Positional = struct {
    /// Argument name, also used as the result field name.
    name: []const u8,
    /// Placeholder shown in help. Defaults to `name`.
    placeholder: ?[]const u8 = null,
    help: []const u8,
    required: bool = false,
    multiple: bool = false,
};

pub const Flag = struct {
    /// Command-line name, also used as the result field name.
    name: []const u8,
    short: ?[]const u8 = null,
    help: []const u8,
};

pub const Option = struct {
    /// Command-line name, also used as the result field name.
    name: []const u8,
    short: ?[]const u8 = null,
    /// Placeholder shown in help. Defaults to "value".
    placeholder: ?[]const u8 = null,
    help: []const u8,
    /// Whether the option must appear. Cannot be combined with `default`.
    required: bool = false,
    multiple: bool = false,
    /// Value used when the option is absent. Cannot be combined with `required`.
    default: ?[]const u8 = null,
};

/// Returns the command-line name for `arg`.
pub fn argName(arg: Arg) []const u8 {
    return switch (arg) {
        .positional => |value| value.name,
        .flag => |value| value.name,
        .option => |value| value.name,
    };
}

/// Returns true when `arg` is a flag or option.
pub fn isNamed(arg: Arg) bool {
    return switch (arg) {
        .positional => false,
        .flag, .option => true,
    };
}

/// Returns the short name for `arg`, if any.
pub fn argShort(arg: Arg) ?[]const u8 {
    return switch (arg) {
        .positional => null,
        .flag => |value| value.short,
        .option => |value| value.short,
    };
}

/// Returns the help placeholder for `arg`.
pub fn argPlaceholder(arg: Arg) []const u8 {
    return switch (arg) {
        .positional => |value| value.placeholder orelse value.name,
        .flag => |value| value.name,
        .option => |value| value.placeholder orelse "value",
    };
}

/// Returns the result field name for `arg`.
pub fn argId(comptime arg: Arg) []const u8 {
    return derivedId(argName(arg));
}

/// Returns the result field name for `command`.
pub fn commandId(comptime command: Command) []const u8 {
    return derivedId(command.name);
}

fn derivedId(comptime name: []const u8) []const u8 {
    comptime var buffer: [name.len]u8 = undefined;
    return util.toSnake(name, &buffer) orelse {
        @compileError(std.fmt.comptimePrint(
            "name '{s}' is invalid: it must convert to a Zig identifier",
            .{name},
        ));
    };
}
