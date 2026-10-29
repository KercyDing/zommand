const std = @import("std");

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
