const std = @import("std");

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
    args: []const Arg = &.{},

    /// Available subcommands.
    commands: []const Command = &.{},
};

pub const Command = struct {
    /// Command name shown on the command line, for example: "new-project".
    /// `-` is converted to `_` for the generated Zig field and type name.
    name: []const u8,
    /// Help text shown in the command list and command help.
    help: ?[]const u8 = null,
    /// Arguments owned by this command.
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
    help: ?[]const u8 = null,
    required: bool = false,
    multiple: bool = false,
};

pub const Flag = struct {
    /// Command-line name, also used as the result field name.
    name: []const u8,
    short: ?[]const u8 = null,
    help: ?[]const u8 = null,
    multiple: bool = false,
};

pub const Option = struct {
    /// Command-line name, also used as the result field name.
    name: []const u8,
    short: ?[]const u8 = null,
    /// Placeholder shown in help. Defaults to "value".
    placeholder: ?[]const u8 = null,
    help: ?[]const u8 = null,
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

/// Converts `name` to a Zig identifier by replacing `-` with `_`.
/// Returns null when the result is not a valid identifier.
pub fn deriveId(name: []const u8, buffer: []u8) ?[]const u8 {
    if (buffer.len < name.len) return null;

    for (name, 0..) |byte, index| {
        buffer[index] = if (byte == '-') '_' else byte;
    }

    const result = buffer[0..name.len];
    if (!std.zig.isValidId(result)) return null;
    return result;
}

fn derivedId(comptime name: []const u8) []const u8 {
    comptime var buffer: [name.len]u8 = undefined;
    const result = deriveId(name, &buffer) orelse {
        @compileError(std.fmt.comptimePrint(
            "name '{s}' is invalid: it must convert to a Zig identifier",
            .{name},
        ));
    };
    return std.fmt.comptimePrint("{s}", .{result});
}
