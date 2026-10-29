const std = @import("std");

/// Runtime CLI schema used by generated parsers.
pub const Cli = struct {
    /// Program name, for example: "zommand".
    name: []const u8,

    /// Program version.
    version: std.SemanticVersion,

    /// Short one-line description.
    about: []const u8 = "",

    /// Optional detailed description.
    long_about: ?[]const u8 = null,

    /// Top-level arguments.
    args: []const Arg = &.{},

    /// Available subcommands.
    commands: []const Command = &.{},
};

/// Schema read directly from a `.zon` file before version conversion.
pub const InputCli = struct {
    name: []const u8,
    version: []const u8,
    about: []const u8 = "",
    long_about: ?[]const u8 = null,
    args: []const Arg = &.{},
    commands: []const Command = &.{},
};

pub const Command = struct {
    /// Command name, for example: "fetch".
    name: []const u8,
    /// Short one-line description.
    about: []const u8 = "",
    /// Optional detailed description.
    long_about: ?[]const u8 = null,
    /// Arguments owned by this command.
    args: []const Arg = &.{},
};

pub const Arg = union(enum) {
    positional: Positional,
    flag: Flag,
    option: Option,
};

pub const Positional = struct {
    id: []const u8,
    help: []const u8 = "",
    required: bool = false,
    multiple: bool = false,
};

pub const Flag = struct {
    id: []const u8,
    short: ?[]const u8 = null,
    help: []const u8 = "",
    global: bool = false,
    multiple: bool = false,
};

pub const Option = struct {
    id: []const u8,
    short: ?[]const u8 = null,
    help: []const u8 = "",
    required: bool = false,
    multiple: bool = false,
    default: ?[]const u8 = null,
    global: bool = false,
};
