const std = @import("std");
const ziggy = @import("ziggy");

const schema = @import("schema");

pub fn parse(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    source: [:0]const u8,
) !schema.Cli {
    var diagnostic: ziggy.Diagnostic = .{ .path = path };
    defer diagnostic.deinit(allocator);
    const options: ziggy.ParseOptions = .{ .diagnostic = &diagnostic };

    return ziggy.parseLeaky(
        schema.Cli,
        allocator,
        source,
        options,
    ) catch |err| {
        if (err == error.OutOfMemory) return err;

        var buffer: [4096]u8 = undefined;
        var stderr: std.Io.File.Writer = .init(.stderr(), io, &buffer);
        try stderr.interface.print("{f}\n", .{diagnostic.fmt(source)});
        try stderr.interface.flush();
        return error.InvalidSchema;
    };
}
