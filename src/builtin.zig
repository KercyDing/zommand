const std = @import("std");
const schema = @import("schema.zig");
const output = @import("output.zig");

/// Zig-style help column: two-space indent and a 16-character label field.
const help_width = 16;

fn writeHelpPrefix(writer: *std.Io.Writer, label: []const u8) std.Io.Writer.Error!void {
    try writer.writeAll("  ");
    try writer.writeAll(label);
    var padding = if (label.len < help_width) help_width - label.len else 0;
    while (padding > 0) : (padding -= 1) try writer.writeByte(' ');
    try writer.writeByte(' ');
}

fn writeHelpRow(
    writer: *std.Io.Writer,
    label: []const u8,
    help: []const u8,
) std.Io.Writer.Error!void {
    try writeHelpPrefix(writer, label);
    try writer.writeAll(help);
    try writer.writeByte('\n');
}

/// Writes program or command help to `writer`.
pub fn writeHelp(
    comptime cli: schema.Cli,
    comptime command: ?schema.Command,
    writer: *std.Io.Writer,
) std.Io.Writer.Error!void {
    if (command) |cmd| {
        try writeCommand(cli, writer, cmd);
    } else {
        try writeProgram(cli, writer);
    }
}

/// Prints program or command help to stdout and exits successfully.
pub fn showHelp(
    io: std.Io,
    comptime cli: schema.Cli,
    comptime command: ?schema.Command,
) noreturn {
    output.write(io, .stdout, writeHelp, .{ cli, command });
    std.process.exit(0);
}

/// Writes the configured program version to `writer`.
pub fn writeVersion(
    comptime cli: schema.Cli,
    writer: *std.Io.Writer,
) std.Io.Writer.Error!void {
    try writer.print("{f}\n", .{cli.version});
}

/// Prints the configured program version to stdout and exits successfully.
pub fn showVersion(io: std.Io, comptime cli: schema.Cli) noreturn {
    output.write(io, .stdout, writeVersion, .{cli});
    std.process.exit(0);
}

fn writeProgram(comptime cli: schema.Cli, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.print("{s} {f}\n", .{ cli.name, cli.version });
    if (cli.about.len != 0) {
        try writer.writeAll(cli.about);
        try writer.writeByte('\n');
    }
    if (cli.long_about) |long_about| {
        try writer.writeByte('\n');
        try writer.writeAll(long_about);
        try writer.writeByte('\n');
    }

    if (cli.about.len != 0 or cli.long_about != null) {
        try writer.writeByte('\n');
    }
    try writer.print("Usage: {s} <command> [options]\n", .{cli.name});

    try writer.writeAll("\nCommands:\n");
    inline for (cli.commands) |command| {
        try writeHelpRow(writer, command.name, command.about);
    }
    try writer.writeAll("\nOptions:\n");
    try writeHelpRow(writer, "-h, --help", "Print help");
    try writeHelpRow(writer, "-V, --version", "Print version");
}

fn writeCommand(
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
                    var label_buffer: [128]u8 = undefined;
                    const label = std.fmt.bufPrint(&label_buffer, "<{s}>", .{positional.id}) catch unreachable;
                    try writeHelpRow(writer, label, positional.help);
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
                    var label_buffer: [128]u8 = undefined;
                    const label = if (flag.short) |short|
                        std.fmt.bufPrint(&label_buffer, "-{s}, --{s}", .{ short, flag.id }) catch unreachable
                    else
                        std.fmt.bufPrint(&label_buffer, "--{s}", .{flag.id}) catch unreachable;
                    try writeHelpRow(writer, label, flag.help);
                },
                .option => |option| {
                    var label_buffer: [128]u8 = undefined;
                    const label = if (option.short) |short|
                        std.fmt.bufPrint(&label_buffer, "-{s}, --{s} <value>", .{ short, option.id }) catch unreachable
                    else
                        std.fmt.bufPrint(&label_buffer, "--{s} <value>", .{option.id}) catch unreachable;
                    try writeHelpPrefix(writer, label);
                    try writer.writeAll(option.help);
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
