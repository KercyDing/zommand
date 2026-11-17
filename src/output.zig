const std = @import("std");
const style = @import("style.zig");

/// Destination stream used by output helpers.
pub const Stream = enum { stdout, stderr };

/// Writes formatted output through a buffered file writer and flushes it.
pub fn write(
    io: std.Io,
    comptime stream: Stream,
    write_fn: anytype,
    args: anytype,
) void {
    var buffer: [4096]u8 = undefined;
    var file_writer: std.Io.File.Writer = .init(file(stream), io, &buffer);
    @call(.auto, write_fn, args ++ .{&file_writer.interface}) catch {};
    file_writer.interface.flush() catch {};
}

/// Like `write`, but detects whether the stream supports colors (honoring
/// `NO_COLOR` and `CLICOLOR_FORCE`) and passes the resulting
/// `std.Io.Terminal` to `write_fn`.
pub fn writeTerminal(
    io: std.Io,
    comptime stream: Stream,
    environ: *const std.process.Environ.Map,
    write_fn: anytype,
    args: anytype,
) void {
    var buffer: [4096]u8 = undefined;
    const output_file = file(stream);
    var file_writer: std.Io.File.Writer = .init(output_file, io, &buffer);
    var terminal: std.Io.Terminal = .{
        .writer = &file_writer.interface,
        .mode = detect(io, output_file, environ),
    };
    @call(.auto, write_fn, args ++ .{&terminal}) catch {};
    file_writer.interface.flush() catch {};
}

fn detect(io: std.Io, output_file: std.Io.File, environ: *const std.process.Environ.Map) std.Io.Terminal.Mode {
    const no_color = if (environ.get("NO_COLOR")) |value| value.len != 0 else false;
    const force_color = if (environ.get("CLICOLOR_FORCE")) |value| value.len != 0 else false;
    return std.Io.Terminal.Mode.detect(io, output_file, no_color, force_color) catch .no_color;
}

/// Prints a secondary line (such as a "Try ... --help" hint) to stderr in the
/// hint color; ignores write errors.
pub fn printHint(
    io: std.Io,
    comptime format: []const u8,
    args: anytype,
) void {
    var buffer: [4096]u8 = undefined;
    const locked = io.lockStderr(&buffer, null) catch return;
    defer io.unlockStderr();
    var terminal = locked.terminal();
    const hint_style: style.Style = .{ .terminal = &terminal };
    hint_style.hint();
    terminal.writer.print(format, args) catch {};
    hint_style.reset();
    terminal.writer.flush() catch {};
}

/// Prints a usage error to stderr using the same "error: " formatting (and
/// terminal colors) as `std.log`; ignores write errors.
pub fn printError(
    io: std.Io,
    comptime format: []const u8,
    args: anytype,
) void {
    var buffer: [4096]u8 = undefined;
    const locked = io.lockStderr(&buffer, null) catch return;
    defer io.unlockStderr();
    const terminal = locked.terminal();
    std.log.defaultLogFileTerminal(.err, .default, format, args, terminal) catch {};
}

/// Prints formatted output through a buffered file writer and flushes it.
pub fn print(
    io: std.Io,
    comptime stream: Stream,
    comptime format: []const u8,
    args: anytype,
) void {
    var buffer: [4096]u8 = undefined;
    var file_writer: std.Io.File.Writer = .init(file(stream), io, &buffer);
    file_writer.interface.print(format, args) catch {};
    file_writer.interface.flush() catch {};
}

fn file(comptime stream: Stream) std.Io.File {
    return switch (stream) {
        .stdout => .stdout(),
        .stderr => .stderr(),
    };
}
