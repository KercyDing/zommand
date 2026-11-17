const std = @import("std");
const output = @import("output.zig");
const schema = @import("schema.zig");
const style = @import("style.zig");
const util = @import("util.zig");

/// Spaces between the label column and its help text.
const help_gap = 4;
/// Preferred maximum help line width.
const max_help_width = 80;

fn writeSpaces(writer: *std.Io.Writer, count: usize) std.Io.Writer.Error!void {
    var remaining = count;
    while (remaining > 0) : (remaining -= 1) try writer.writeByte(' ');
}

const LabelStyle = enum { literal, placeholder };

fn writeLabel(
    style_value: style.Style,
    label: []const u8,
    label_style: LabelStyle,
) std.Io.Writer.Error!void {
    switch (label_style) {
        .literal => style_value.literal(),
        .placeholder => style_value.placeholder(),
    }
    try style_value.terminal.writer.writeAll(label);
    style_value.reset();
}

fn writeHelpPrefix(
    style_value: style.Style,
    label: []const u8,
    label_style: LabelStyle,
    width: usize,
) std.Io.Writer.Error!void {
    const writer = style_value.terminal.writer;
    try writer.writeAll("  ");
    try writeLabel(style_value, label, label_style);
    const padding = if (label.len < width) width - label.len else 0;
    try writeSpaces(writer, padding + help_gap);
}

fn writeWrapped(
    writer: *std.Io.Writer,
    text: []const u8,
    width: usize,
    initial_column: usize,
    indent: usize,
) std.Io.Writer.Error!void {
    const limit = @max(width, indent + 20);

    var lines = std.mem.splitScalar(u8, text, '\n');
    var first_line = true;
    while (lines.next()) |line| {
        if (!first_line) {
            try writer.writeByte('\n');
            try writeSpaces(writer, indent);
        }

        var column: usize = if (first_line) initial_column else indent;
        var first_word = true;
        var words = std.mem.tokenizeAny(u8, line, " \t");
        while (words.next()) |word| {
            if (!first_word) {
                if (column + 1 + word.len > limit) {
                    try writer.writeByte('\n');
                    try writeSpaces(writer, indent);
                    column = indent;
                } else {
                    try writer.writeByte(' ');
                    column += 1;
                }
            }
            try writer.writeAll(word);
            column += word.len;
            first_word = false;
        }
        first_line = false;
    }
}

fn writeHelpRow(
    style_value: style.Style,
    label: []const u8,
    label_style: LabelStyle,
    help: []const u8,
    width: usize,
) std.Io.Writer.Error!void {
    const writer = style_value.terminal.writer;
    if (help.len == 0) {
        try writer.writeAll("  ");
        try writeLabel(style_value, label, label_style);
        try writer.writeByte('\n');
        return;
    }

    const prefix_width = 2 + width + help_gap;
    try writeHelpPrefix(style_value, label, label_style, width);
    try writeWrapped(writer, help, max_help_width, prefix_width, prefix_width);
    try writer.writeByte('\n');
}

/// Writes program or command help to `writer` without colors.
pub fn writeHelp(
    comptime cli: schema.Cli,
    comptime command: ?schema.Command,
    writer: *std.Io.Writer,
) std.Io.Writer.Error!void {
    var terminal: std.Io.Terminal = .{ .writer = writer, .mode = .no_color };
    try writeHelpTerminal(cli, command, &terminal);
}

/// Writes program or command help to `terminal`, colored if its mode supports
/// it.
pub fn writeHelpTerminal(
    comptime cli: schema.Cli,
    comptime command: ?schema.Command,
    terminal: *std.Io.Terminal,
) std.Io.Writer.Error!void {
    @setEvalBranchQuota(comptime util.evalBranchQuota(cli));
    const style_value: style.Style = .{ .terminal = terminal };
    if (command) |cmd| {
        try writeCommand(cli, style_value, cmd);
    } else {
        try writeProgram(cli, style_value);
    }
}

/// Prints program or command help to stdout and exits successfully.
pub fn showHelp(
    io: std.Io,
    environ: *const std.process.Environ.Map,
    comptime cli: schema.Cli,
    comptime command: ?schema.Command,
) noreturn {
    output.writeTerminal(io, .stdout, environ, writeHelpTerminal, .{ cli, command });
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

fn writeProgram(comptime cli: schema.Cli, style_value: style.Style) std.Io.Writer.Error!void {
    const writer = style_value.terminal.writer;
    if (cli.help) |help| {
        if (help.len != 0) {
            try writeWrapped(writer, help, max_help_width, 0, 0);
            try writer.writeByte('\n');
            try writer.writeByte('\n');
        }
    }

    style_value.header();
    try writer.writeAll("Usage: ");
    style_value.reset();
    style_value.literal();
    try writer.writeAll(cli.name);
    style_value.reset();
    style_value.placeholder();
    try writer.writeAll(" [options] <command> [args]\n");
    style_value.reset();

    const help_width = @max(commandWidth(cli.commands), namedWidth(cli.args, true));

    style_value.header();
    try writer.writeAll("\nCommands:\n\n");
    style_value.reset();
    inline for (cli.commands) |command| {
        try writeHelpRow(style_value, command.name, .literal, firstLine(command.help), help_width);
    }

    style_value.header();
    try writer.writeAll("\nOptions:\n\n");
    style_value.reset();
    try writeNamedRows(cli.args, style_value, help_width);
    try writeHelpRow(style_value, "-h, --help", .literal, "Print help", help_width);
    try writeHelpRow(style_value, "-V, --version", .literal, "Print version", help_width);
}

fn writeCommand(
    comptime cli: schema.Cli,
    style_value: style.Style,
    comptime command: schema.Command,
) std.Io.Writer.Error!void {
    const writer = style_value.terminal.writer;
    if (command.help.len != 0) {
        try writeWrapped(writer, command.help, max_help_width, 0, 0);
        try writer.writeByte('\n');
        try writer.writeByte('\n');
    }

    style_value.header();
    try writer.writeAll("Usage: ");
    style_value.reset();
    style_value.literal();
    try writer.writeAll(cli.name);
    style_value.reset();
    try writer.writeByte(' ');
    style_value.literal();
    try writer.writeAll(command.name);
    style_value.reset();
    inline for (command.args) |arg| {
        switch (arg) {
            .positional => |positional| {
                style_value.placeholder();
                try writer.writeAll(if (positional.required) " <" else " [<");
                try writer.writeAll(schema.argPlaceholder(arg));
                try writer.writeAll(if (positional.required) ">" else ">]");
                if (positional.multiple) try writer.writeAll("...");
                style_value.reset();
            },
            .flag, .option => {},
        }
    }
    style_value.placeholder();
    try writer.writeAll(" [options]\n");
    style_value.reset();

    const help_width = @max(
        positionalWidth(command.args),
        @max(namedWidth(command.args, false), "-h, --help".len),
    );

    if (commandHasPositionals(command)) {
        style_value.header();
        try writer.writeAll("\nArguments:\n\n");
        style_value.reset();
        inline for (command.args) |arg| {
            switch (arg) {
                .positional => |positional| {
                    var label_buffer: [256]u8 = undefined;
                    const label = positionalLabel(arg, &label_buffer);
                    try writeHelpRow(style_value, label, .placeholder, positional.help, help_width);
                },
                else => {},
            }
        }
    }

    style_value.header();
    try writer.writeAll("\nOptions:\n\n");
    style_value.reset();
    try writeNamedRows(command.args, style_value, help_width);
    try writeHelpRow(style_value, "-h, --help", .literal, "Print help", help_width);
}

fn writeNamedRows(
    comptime args: []const schema.Arg,
    style_value: style.Style,
    width: usize,
) std.Io.Writer.Error!void {
    const writer = style_value.terminal.writer;
    inline for (args) |arg| {
        switch (arg) {
            .positional => {},
            .flag => |flag| {
                var label_buffer: [256]u8 = undefined;
                const label = namedLabel(arg, &label_buffer);
                try writeHelpRow(style_value, label, .literal, flag.help, width);
            },
            .option => |option| {
                var label_buffer: [256]u8 = undefined;
                const label = namedLabel(arg, &label_buffer);
                const help = option.help;

                var extra_buffer: [256]u8 = undefined;
                var extra_len: usize = 0;
                if (option.required and option.default == null) {
                    const annotation = " (required)";
                    @memcpy(extra_buffer[extra_len..][0..annotation.len], annotation);
                    extra_len += annotation.len;
                } else if (option.default) |default| {
                    const annotation = std.fmt.bufPrint(
                        extra_buffer[extra_len..],
                        " (default: {s})",
                        .{default},
                    ) catch "";
                    extra_len += annotation.len;
                }
                const extra = extra_buffer[0..extra_len];

                if (help.len == 0 and extra.len == 0) {
                    try writer.writeAll("  ");
                    try writeLabel(style_value, label, .literal);
                    try writer.writeByte('\n');
                } else {
                    const prefix_width = 2 + width + help_gap;
                    try writeHelpPrefix(style_value, label, .literal, width);
                    try writeWrapped(writer, help, max_help_width, prefix_width, prefix_width);
                    if (extra.len != 0) {
                        style_value.hint();
                        try writer.writeAll(extra);
                        style_value.reset();
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
            ) catch unreachable
        else
            std.fmt.bufPrint(buffer, "--{s}", .{schema.argName(arg)}) catch unreachable,
        .option => |option| {
            const placeholder = schema.argPlaceholder(arg);
            const suffix: []const u8 = if (option.multiple) ">..." else ">";
            if (option.short) |short| {
                return std.fmt.bufPrint(
                    buffer,
                    "-{s}, --{s} <{s}{s}",
                    .{ short, schema.argName(arg), placeholder, suffix },
                ) catch unreachable;
            }
            return std.fmt.bufPrint(
                buffer,
                "--{s} <{s}{s}",
                .{ schema.argName(arg), placeholder, suffix },
            ) catch unreachable;
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
            ) catch unreachable
        else
            std.fmt.bufPrint(
                buffer,
                "<{s}>",
                .{schema.argPlaceholder(arg)},
            ) catch unreachable,
        .flag, .option => unreachable,
    };
}
