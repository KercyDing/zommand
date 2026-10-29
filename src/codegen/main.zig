const std = @import("std");

const parse = @import("parse.zig");
const emit = @import("emit.zig");

const source_size_max = 1024 * 1024;

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);

    if (args.len != 3) {
        std.log.err("usage: {s} <input.ziggy> <output.zig>", .{args[0]});
        return error.InvalidArguments;
    }

    const source_bytes = try std.Io.Dir.cwd().readFileAlloc(
        init.io,
        args[1],
        allocator,
        .limited(source_size_max),
    );
    const source = try allocator.dupeSentinel(u8, source_bytes, 0);
    const cli = try parse.parse(allocator, init.io, args[1], source);

    var output: std.Io.Writer.Allocating = .init(allocator);
    try emit.emit(cli, &output.writer);

    try std.Io.Dir.cwd().writeFile(init.io, .{
        .sub_path = args[2],
        .data = output.writer.buffered(),
    });
}
