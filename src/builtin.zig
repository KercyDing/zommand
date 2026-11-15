const std = @import("std");
const schema = @import("schema.zig");
const output = @import("output.zig");

/// Minimum help column: two-space indent and a 16-character label field.
const min_help_width = 16;

fn writeHelpPrefix(writer: *std.Io.Writer, label: []const u8, width: usize) std.Io.Writer.Error!void {
    try writer.writeAll("  ");
    try writer.writeAll(label);
    const padding = if (label.len < width) width - label.len else 0;
    var remaining = padding;
    while (remaining > 0) : (remaining -= 1) try writer.writeByte(' ');
    try writer.writeByte(' ');
}

fn writeHelpRow(
    writer: *std.Io.Writer,
    label: []const u8,
    help: []const u8,
    width: usize,
) std.Io.Writer.Error!void {
    if (help.len == 0) {
        try writer.writeAll("  ");
        try writer.writeAll(label);
        try writer.writeByte('\n');
        return;
    }

    try writeHelpPrefix(writer, label, width);
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
    try writer.print("{s}\n", .{cli.version});
}

/// Prints the configured program version to stdout and exits successfully.
pub fn showVersion(io: std.Io, comptime cli: schema.Cli) noreturn {
    output.write(io, .stdout, writeVersion, .{cli});
    std.process.exit(0);
}

fn writeProgram(comptime cli: schema.Cli, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    if (cli.help) |help| {
        if (help.len != 0) {
            try writer.writeAll(help);
            try writer.writeByte('\n');
            try writer.writeByte('\n');
        }
    }

    try writer.print("Usage: {s} [options] <command> [args]\n", .{cli.name});

    try writer.writeAll("\nCommands:\n\n");
    const command_width = @max(min_help_width, commandWidth(cli.commands));
    inline for (cli.commands) |command| {
        try writeHelpRow(writer, command.name, firstLine(command.help orelse ""), command_width);
    }

    try writer.writeAll("\nOptions:\n\n");
    const option_width = @max(min_help_width, namedWidth(cli.args, true));
    try writeNamedRows(cli.args, writer, option_width);
    try writeHelpRow(writer, "-h, --help", "Print help", option_width);
    try writeHelpRow(writer, "-V, --version", "Print version", option_width);
}

fn writeCommand(
    comptime cli: schema.Cli,
    writer: *std.Io.Writer,
    comptime command: schema.Command,
) std.Io.Writer.Error!void {
    if (command.help) |help| {
        if (help.len != 0) {
            try writer.writeAll(help);
            try writer.writeByte('\n');
            try writer.writeByte('\n');
        }
    }

    try writer.print("Usage: {s} {s}", .{ cli.name, command.name });
    inline for (command.args) |arg| {
        switch (arg) {
            .positional => |positional| {
                try writer.writeAll(if (positional.required) " <" else " [<");
                try writer.writeAll(schema.argPlaceholder(arg));
                try writer.writeAll(if (positional.required) ">" else ">]");
                if (positional.multiple) try writer.writeAll("...");
            },
            .flag, .option => {},
        }
    }
    try writer.writeAll(" [options]\n");

    if (commandHasPositionals(command)) {
        try writer.writeAll("\nArguments:\n\n");
        const argument_width = @max(min_help_width, positionalWidth(command.args));
        inline for (command.args) |arg| {
            switch (arg) {
                .positional => |positional| {
                    var label_buffer: [256]u8 = undefined;
                    const label = positionalLabel(arg, &label_buffer);
                    try writeHelpRow(writer, label, positional.help orelse "", argument_width);
                },
                else => {},
            }
        }
    }

    try writer.writeAll("\nOptions:\n\n");
    const option_width = @max(min_help_width, namedWidth(command.args, true));
    try writeNamedRows(command.args, writer, option_width);
    try writeHelpRow(writer, "-h, --help", "Print help", option_width);
}

fn writeNamedRows(
    comptime args: []const schema.Arg,
    writer: *std.Io.Writer,
    width: usize,
) std.Io.Writer.Error!void {
    inline for (args) |arg| {
        switch (arg) {
            .positional => {},
            .flag => |flag| {
                var label_buffer: [256]u8 = undefined;
                const label = namedLabel(arg, &label_buffer);
                try writeHelpRow(writer, label, flag.help orelse "", width);
            },
            .option => |option| {
                var label_buffer: [256]u8 = undefined;
                const label = namedLabel(arg, &label_buffer);
                const help = option.help orelse "";
                const has_annotation =
                    (option.required and option.default == null) or
                    option.default != null;

                if (help.len == 0 and !has_annotation) {
                    try writer.writeAll("  ");
                    try writer.writeAll(label);
                    try writer.writeByte('\n');
                } else {
                    try writeHelpPrefix(writer, label, width);
                    try writer.writeAll(help);
                    if (option.required and option.default == null) {
                        try writer.writeAll(" (required)");
                    }
                    if (option.default) |default| {
                        try writer.print(" (default: {s})", .{default});
                    }
                    try writer.writeByte('\n');
                }
            },
        }
    }
}

fn firstLine(text: []const u8) []const u8 {
    return if (std.mem.findScalar(u8, text, '\n')) |index| text[0..index] else text;
}

fn commandHasPositionals(comptime command: schema.Command) bool {
    inline for (command.args) |arg| {
        switch (arg) {
            .positional => return true,
            .flag, .option => {},
        }
    }
    return false;
}

fn namedWidth(comptime args: []const schema.Arg, comptime include_reserved: bool) usize {
    var width: usize = 0;
    inline for (args) |arg| {
        switch (arg) {
            .positional => {},
            .flag, .option => width = @max(width, namedLabelLen(arg)),
        }
    }
    if (include_reserved) {
        width = @max(width, "-h, --help".len);
        width = @max(width, "-V, --version".len);
    }
    return width;
}

fn positionalWidth(comptime args: []const schema.Arg) usize {
    var width: usize = 0;
    inline for (args) |arg| {
        switch (arg) {
            .positional => |positional| {
                width = @max(width, 2 + schema.argPlaceholder(arg).len + @as(usize, if (positional.multiple) 3 else 0));
            },
            .flag, .option => {},
        }
    }
    return width;
}

fn commandWidth(comptime commands: []const schema.Command) usize {
    var width: usize = 0;
    inline for (commands) |command| width = @max(width, command.name.len);
    return width;
}

fn namedLabel(comptime arg: schema.Arg, buffer: []u8) []const u8 {
    return switch (arg) {
        .positional => unreachable,
        .flag => |flag| if (flag.short) |short|
            std.fmt.bufPrint(
                buffer,
                "-{s}, --{s}",
                .{ short, schema.argName(arg) },
            ) catch "argument"
        else
            std.fmt.bufPrint(buffer, "--{s}", .{schema.argName(arg)}) catch "argument",
        .option => |option| {
            const placeholder = schema.argPlaceholder(arg);
            const suffix: []const u8 = if (option.multiple) ">..." else ">";
            if (option.short) |short| {
                return std.fmt.bufPrint(
                    buffer,
                    "-{s}, --{s} <{s}{s}",
                    .{ short, schema.argName(arg), placeholder, suffix },
                ) catch "argument";
            }
            return std.fmt.bufPrint(
                buffer,
                "--{s} <{s}{s}",
                .{ schema.argName(arg), placeholder, suffix },
            ) catch "argument";
        },
    };
}

fn namedLabelLen(comptime arg: schema.Arg) usize {
    return switch (arg) {
        .positional => unreachable,
        .flag => |flag| (if (flag.short != null) 6 else 2) + schema.argName(arg).len,
        .option => |option| (if (option.short != null) 6 else 2) +
            schema.argName(arg).len +
            3 +
            schema.argPlaceholder(arg).len +
            (if (option.multiple) 3 else 0),
    };
}

fn positionalLabel(comptime arg: schema.Arg, buffer: []u8) []const u8 {
    return switch (arg) {
        .positional => |positional| if (positional.multiple)
            std.fmt.bufPrint(
                buffer,
                "<{s}>...",
                .{schema.argPlaceholder(arg)},
            ) catch "argument"
        else
            std.fmt.bufPrint(
                buffer,
                "<{s}>",
                .{schema.argPlaceholder(arg)},
            ) catch "argument",
        .flag, .option => unreachable,
    };
}
