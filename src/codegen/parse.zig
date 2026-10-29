const std = @import("std");
const ziggy = @import("ziggy");

const schema = @import("schema");

pub fn parse(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    source: [:0]const u8,
) !schema.Cli {
    var meta: ziggy.Deserializer.Meta = undefined;
    const options: ziggy.Deserializer.Options = .{};

    return ziggy.deserializeLeaky(
        schema.Cli,
        allocator,
        source,
        &meta,
        options,
    ) catch |err| {
        if (err == error.OutOfMemory) return err;

        var buffer: [4096]u8 = undefined;
        var stderr: std.Io.File.Writer = .init(.stderr(), io, &buffer);
        try meta.reportErrors(allocator, options, path, source, err, &stderr.interface);
        try stderr.interface.flush();
        return error.InvalidSchema;
    };
}
