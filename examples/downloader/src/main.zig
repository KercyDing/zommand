const std = @import("std");
const cli = @import("cli");

const Download = cli.Download;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = init.minimal.args;

    const result = try cli.parse(init.io, arena, args);

    switch (result) {
        .download => |download| try runDownload(init, arena, download),
    }
}

fn runDownload(init: std.process.Init, arena: std.mem.Allocator, download: Download) !void {
    const io = init.io;
    const name = fileNameFromUrl(download.url);

    var dir = try std.Io.Dir.createDirPathOpen(std.Io.Dir.cwd(), io, download.path, .{});
    defer dir.close(io);

    var file = try dir.createFile(io, name, .{});
    var keep = false;
    defer {
        file.close(io);
        if (!keep) dir.deleteFile(io, name) catch {};
    }

    var client: std.http.Client = .{
        .allocator = init.gpa,
        .io = io,
    };
    defer client.deinit();
    try client.initDefaultProxies(arena, init.environ_map);

    var write_buffer: [64 * 1024]u8 = undefined;
    var writer = file.writer(io, &write_buffer);

    const result = try client.fetch(.{
        .location = .{ .url = download.url },
        .response_writer = &writer.interface,
    });

    try writer.interface.flush();

    const status = @backingInt(result.status);
    if (status < 200 or status >= 300) {
        std.log.err("unexpected HTTP status {d}", .{status});
        return error.UnexpectedHttpStatus;
    }

    keep = true;
    std.debug.print("Downloaded {s}\n", .{name});
}

/// Returns the last path segment of `url`, falling back to "download".
fn fileNameFromUrl(url: []const u8) []const u8 {
    var end = url.len;

    if (std.mem.findScalar(u8, url, '?')) |index| end = @min(end, index);
    if (std.mem.findScalar(u8, url, '#')) |index| end = @min(end, index);

    while (end > 0 and url[end - 1] == '/') end -= 1;
    if (end == 0) return "download";

    const path = url[0..end];
    const slash = std.mem.findScalarLast(u8, path, '/') orelse return path;
    const name = path[slash + 1 ..];
    return if (name.len == 0) "download" else name;
}

test "file name from url" {
    try std.testing.expectEqualStrings(
        "5.0.0.tar.gz",
        fileNameFromUrl("https://github.com/opencv/opencv/archive/refs/tags/5.0.0.tar.gz/"),
    );
    try std.testing.expectEqualStrings(
        "file.txt",
        fileNameFromUrl("https://example.com/file.txt?token=1#top"),
    );
}
