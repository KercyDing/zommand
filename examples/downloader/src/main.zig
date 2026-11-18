const std = @import("std");
const cli = @import("cli");

const Download = cli.Download;

pub fn main(init: std.process.Init) !void {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &stdout_buffer);

    const out = &stdout_writer.interface;
    defer out.flush() catch {};

    const arena = init.arena.allocator();
    const parsed = cli.parseOrExit(init);

    switch (parsed.command) {
        .download => |download| try runDownload(init, arena, out, parsed.globals.verbose, download),
    }
}

fn runDownload(
    init: std.process.Init,
    arena: std.mem.Allocator,
    out: *std.Io.Writer,
    verbose: bool,
    download: Download,
) !void {
    const io = init.io;

    const uri = std.Uri.parse(download.url) catch |err| {
        std.log.err("invalid URL '{s}': {t}", .{ download.url, err });
        return err;
    };

    if (!std.mem.eql(u8, uri.scheme, "http") and !std.mem.eql(u8, uri.scheme, "https")) {
        std.log.err("unsupported URL scheme: {s}", .{uri.scheme});
        return error.UnsupportedScheme;
    }

    if (uri.host == null) {
        std.log.err("URL is missing a host: {s}", .{download.url});
        return error.MissingHost;
    }

    const file_name = fileName(uri);

    if (verbose) {
        try out.print("Fetching from: {s}\n", .{download.url});
    }

    var dir = try std.Io.Dir.createDirPathOpen(std.Io.Dir.cwd(), io, download.path, .{});
    defer dir.close(io);

    var file = try dir.createFile(io, file_name, .{});
    defer file.close(io);
    errdefer dir.deleteFile(io, file_name) catch {};

    var client: std.http.Client = .{
        .allocator = init.gpa,
        .io = io,
    };
    defer client.deinit();
    try client.initDefaultProxies(arena, init.environ_map);

    var file_buffer: [64 * 1024]u8 = undefined;
    var file_writer = file.writer(io, &file_buffer);
    const file_out = &file_writer.interface;

    const result = try client.fetch(.{
        .location = .{ .url = download.url },
        .response_writer = file_out,
    });

    try file_out.flush();

    const status = result.status;
    if (status.class() != .success) {
        std.log.err("Unexpected HTTP status: {}\n", .{@backingInt(status)});
        return error.UnexpectedHttpStatus;
    }

    if (verbose) {
        try out.print("HTTP {}\n", .{@backingInt(status)});
    }

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try dir.realPathFile(io, file_name, &path_buf);
    try out.print("Downloaded to {s}\n", .{path_buf[0..path_len]});
}

/// Returns the last path segment of `uri`, falling back to "download".
fn fileName(uri: std.Uri) []const u8 {
    const path = switch (uri.path) {
        .percent_encoded => |path| path,
        .raw => |raw| raw,
    };
    const name = std.Io.Dir.path.basename(path);
    return if (name.len == 0) "download" else name;
}
