const std = @import("std");

const schema = @import("schema");
const emit = @import("emit.zig");

const source_size_max = 1024 * 1024;

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);

    if (args.len != 3) {
        std.log.err("usage: {s} <schema.zon> <output.zig>", .{args[0]});
        return error.InvalidArguments;
    }

    const source_bytes = try std.Io.Dir.cwd().readFileAlloc(
        init.io,
        args[1],
        allocator,
        .limited(source_size_max),
    );
    const source = try allocator.dupeSentinel(u8, source_bytes, 0);

    var diagnostics: std.zon.parse.Diagnostics = undefined;
    const cli = std.zon.parse.fromSlice(schema.Cli, .{
        .gpa = std.heap.page_allocator,
        .arena = allocator,
        .source = source,
        .diagnostics = &diagnostics,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ParseZon => {
            diagnostics.log(args[1]);
            return error.InvalidSchema;
        },
    };

    var output: std.Io.Writer.Allocating = .init(allocator);
    try emit.emit(allocator, cli, &output.writer);

    try std.Io.Dir.cwd().writeFile(init.io, .{
        .sub_path = args[2],
        .data = output.writer.buffered(),
    });
}
