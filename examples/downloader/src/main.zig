const std = @import("std");
const http = @import("dusty");
const cli = @import("cli");

const Download = cli.Download;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = init.minimal.args;

    const result = try cli.parse(arena, args);

    switch (result) {
        .download => |download| try runDownload(init.io, init.gpa, download),
    }
}

fn runDownload(io: std.Io, allocator: std.mem.Allocator, download: Download) !void {
    const name = fileNameFromUrl(download.url);

    var dir = try std.Io.Dir.createDirPathOpen(std.Io.Dir.cwd(), io, download.path, .{});
    defer dir.close(io);

    var file = try dir.createFile(io, name, .{});
    defer file.close(io);

    var client = http.Client.init(allocator, io, .{});
    defer client.deinit();

    var response = try client.fetch(download.url, .{ .stream = true });
    defer response.deinit();

    const status = @backingInt(response.status());
    if (status < 200 or status >= 300) {
        std.log.err("unexpected HTTP status {d}", .{status});
        return error.UnexpectedHttpStatus;
    }

    var read_buffer: [16 * 1024]u8 = undefined;
    var body = try response.reader(&read_buffer);

    var write_buffer: [64 * 1024]u8 = undefined;
    var writer = file.writer(io, &write_buffer);

    while (true) {
        const written = body.interface.stream(&writer.interface, .unlimited) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (written == 0) break;
    }
    try writer.interface.flush();

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

test "fileNameFromUrl" {
    try std.testing.expectEqualStrings(
        "5.0.0.tar.gz",
        fileNameFromUrl("https://github.com/opencv/opencv/archive/refs/tags/5.0.0.tar.gz/"),
    );
    try std.testing.expectEqualStrings(
        "file.txt",
        fileNameFromUrl("https://example.com/file.txt?token=1#top"),
    );
}
