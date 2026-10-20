const std = @import("std");
const builtin = @import("builtin");
const curl = @import("curl");

const Cli = @import("zis_schema").Cli;
const Fetch = @FieldType(Cli.Result, "fetch");

const ArchiveFormat = enum {
    tar,
    tar_gz,
    tar_xz,
    tar_zst,
    zip,

    fn checkFormat(path: []const u8) ?ArchiveFormat {
        if (std.ascii.endsWithIgnoreCase(path, ".tar")) {
            return .tar;
        }
        if (std.ascii.endsWithIgnoreCase(path, ".tar.gz") or std.ascii.endsWithIgnoreCase(path, ".tgz")) {
            return .tar_gz;
        }
        if (std.ascii.endsWithIgnoreCase(path, ".tar.xz") or std.ascii.endsWithIgnoreCase(path, ".txz")) {
            return .tar_xz;
        }
        if (std.ascii.endsWithIgnoreCase(path, ".tar.zst") or std.ascii.endsWithIgnoreCase(path, ".tzst")) {
            return .tar_zst;
        }
        if (std.ascii.endsWithIgnoreCase(path, ".zip") or std.ascii.endsWithIgnoreCase(path, ".jar")) {
            return .zip;
        }

        return null;
    }
};

const TempTaskDir = struct {
    dir: std.Io.Dir,
    name: [32]u8,

    fn create(
        io: std.Io,
        parent: std.Io.Dir,
    ) !TempTaskDir {
        while (true) {
            var random_id: u128 = undefined;
            io.random(std.mem.asBytes(&random_id));

            const name = std.fmt.hex(random_id);

            parent.createDir(
                io,
                &name,
                .default_dir,
            ) catch |err| switch (err) {
                error.PathAlreadyExists => continue,
                else => return err,
            };

            const dir = parent.openDir(io, &name, .{}) catch |err| {
                parent.deleteDir(io, &name) catch {};
                return err;
            };

            return .{
                .dir = dir,
                .name = name,
            };
        }
    }

    fn cleanup(
        self: *TempTaskDir,
        io: std.Io,
        parent: std.Io.Dir,
    ) void {
        self.dir.close(io);
        parent.deleteTree(io, &self.name) catch {};
        self.* = undefined;
    }
};

/// The fetch command entry.
pub fn runFetch(
    io: std.Io,
    allocator: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
    fetch: Fetch,
) !void {
    const url: [:0]u8 = try allocator.dupeSentinel(u8, fetch.url, 0);
    defer allocator.free(url);

    const download_name = fileNameFromUrl(url);
    const archive_format = ArchiveFormat.checkFormat(download_name) orelse {
        std.log.err("Unsupported format: {s}", .{download_name});
        return error.UnsupportedArchiveFormat;
    };

    _ = archive_format;

    const part_name = try std.fmt.allocPrint(allocator, "{s}.part", .{download_name});
    defer allocator.free(part_name);

    var ca_bundle = try curl.allocCABundle(allocator, io);
    defer ca_bundle.deinit(allocator);

    var temp_root = try openSystemTempDir(io, environ);
    defer temp_root.close(io);

    var download_path = try std.Io.Dir.createDirPathOpen(temp_root, io, "zis", .{});
    defer download_path.close(io);

    var task = try TempTaskDir.create(io, download_path);
    defer task.cleanup(io, download_path);

    const task_dir = task.dir;

    if (fetch.save) {
        const init_result = try std.process.run(allocator, io, .{
            .argv = &.{ "zig", "init" },
            .cwd = .{ .dir = task_dir },
            .stdout_limit = .limited(4096),
            .stderr_limit = .limited(64 * 1024),
        });
        defer allocator.free(init_result.stdout);
        defer allocator.free(init_result.stderr);

        if (!termSucceeded(init_result.term)) {
            if (init_result.stderr.len != 0) {
                std.debug.print("{s}", .{init_result.stderr});
            }
            return error.ZigInitFailed;
        }
    }

    const archive_path = try std.fmt.allocPrint(
        allocator,
        "./{s}",
        .{download_name},
    );
    defer allocator.free(archive_path);

    var committed = false;
    defer {
        if (!committed) {
            task_dir.deleteFile(io, part_name) catch {};
        }
    }

    var easy = try curl.Easy.init(.{
        .ca_bundle = ca_bundle,
    });
    defer easy.deinit();

    try easy.setFollowLocation(true);

    std.debug.print("Fetching...\n", .{});

    const response = blk: {
        var file = try task_dir.createFile(io, part_name, .{});
        defer file.close(io);

        var writer_buffer: [64 * 1024]u8 = undefined;
        var file_writer = file.writer(io, &writer_buffer);

        const response = try easy.fetch(url, .{
            .writer = &file_writer.interface,
        });

        try file_writer.interface.flush();

        break :blk response;
    };

    if (response.status_code < 200 or response.status_code >= 300) {
        return error.UnexpectedHttpStatus;
    }

    try task_dir.rename(part_name, task_dir, download_name, io);
    committed = true;

    // Let Zig to take it over.
    const argv: []const []const u8 = if (fetch.save)
        &.{ "zig", "fetch", "--save", archive_path }
    else
        &.{ "zig", "fetch", archive_path };

    const result = try std.process.run(allocator, io, .{
        .argv = argv,
        .cwd = .{ .dir = task_dir },
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(64 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (!termSucceeded(result.term)) {
        if (result.stderr.len != 0) {
            std.debug.print("{s}", .{result.stderr});
        }
        return error.ZigFetchFailed;
    }

    if (!fetch.save) {
        const hash = std.mem.trim(u8, result.stdout, " \t\r\n");
        std.debug.print("{s}\n", .{hash});
        return;
    }

    // save == true
    var zon_file = try task_dir.openFile(io, "build.zig.zon", .{});
    defer zon_file.close(io);

    const zon_stat = try zon_file.stat(io);

    const zon_size = std.math.cast(usize, zon_stat.size) orelse
        return error.GeneratedManifestTooLarge;

    if (zon_size > 64 * 1024) {
        return error.GeneratedManifestTooLarge;
    }

    const zon_source = try allocator.allocSentinel(u8, zon_size, 0);
    defer allocator.free(zon_source);

    var zon_reader = zon_file.reader(io, &.{});
    try zon_reader.interface.readSliceAll(zon_source);

    var dependency = try dependencyFromZon(
        allocator,
        zon_source,
    );
    defer dependency.deinit(allocator);

    std.debug.print(
        \\.{s} = .{{
        \\    .url = "{f}",
        \\    .hash = "{s}",
        \\}},
        \\
    , .{
        dependency.name,
        std.zig.fmtString(fetch.url),
        dependency.hash,
    });
}

/// Open the temporary directory of the system.
fn openSystemTempDir(io: std.Io, environ: *const std.process.Environ.Map) !std.Io.Dir {
    const temp_path = switch (builtin.os.tag) {
        .windows => environ.get("TMP") orelse environ.get("TEMP") orelse return error.TempDirUnavailble,
        .wasi, .freestanding => return error.TempDirUnavailble,
        else => environ.get("TMPDIR") orelse "/tmp",
    };

    if (!std.fs.path.isAbsolute(temp_path)) {
        return error.InvalidTempDir;
    }

    return std.Io.Dir.openDirAbsolute(io, temp_path, .{}) catch return error.OpenTempDirFailed;
}

const Dependency = struct {
    name: []u8,
    hash: []u8,

    fn deinit(self: *Dependency, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.hash);
        self.* = undefined;
    }
};

fn dependencyFromZon(
    allocator: std.mem.Allocator,
    source: [:0]const u8,
) !Dependency {
    var ast = try std.zig.Ast.parse(
        allocator,
        source,
        .{ .mode = .zon },
    );
    defer ast.deinit(allocator);

    if (ast.errors.len != 0) {
        return error.InvalidGeneratedManifest;
    }

    const root_node = ast.nodeData(.root).node;

    var root_buffer: [2]std.zig.Ast.Node.Index = undefined;
    const root = ast.fullStructInit(
        &root_buffer,
        root_node,
    ) orelse return error.InvalidGeneratedManifest;

    for (root.ast.fields) |field_node| {
        const field_name_token = ast.firstToken(field_node) - 2;
        const field_name = ast.tokenSlice(field_name_token);

        if (!std.mem.eql(u8, field_name, "dependencies")) {
            continue;
        }

        var dependencies_buffer: [2]std.zig.Ast.Node.Index = undefined;
        const dependencies = ast.fullStructInit(
            &dependencies_buffer,
            field_node,
        ) orelse return error.InvalidGeneratedManifest;

        if (dependencies.ast.fields.len != 1) {
            return error.UnexpectedDependencyCount;
        }

        const dependency_node = dependencies.ast.fields[0];

        const name_token = ast.firstToken(dependency_node) - 2;
        const name = ast.tokenSlice(name_token);

        var dependency_buffer: [2]std.zig.Ast.Node.Index = undefined;
        const dependency_init = ast.fullStructInit(
            &dependency_buffer,
            dependency_node,
        ) orelse return error.InvalidGeneratedManifest;

        var hash: ?[]const u8 = null;

        for (dependency_init.ast.fields) |member_node| {
            const member_name_token = ast.firstToken(member_node) - 2;
            const member_name = ast.tokenSlice(member_name_token);

            if (!std.mem.eql(u8, member_name, "hash")) {
                continue;
            }

            if (ast.nodeTag(member_node) != .string_literal) {
                return error.InvalidGeneratedManifest;
            }

            const hash_literal = ast.tokenSlice(
                ast.nodeMainToken(member_node),
            );

            if (hash_literal.len < 2 or
                hash_literal[0] != '"' or
                hash_literal[hash_literal.len - 1] != '"')
            {
                return error.InvalidGeneratedManifest;
            }

            hash = hash_literal[1 .. hash_literal.len - 1];
            break;
        }

        const hash_value = hash orelse
            return error.DependencyHashNotFound;

        const owned_name = try allocator.dupe(u8, name);
        errdefer allocator.free(owned_name);

        const owned_hash = try allocator.dupe(u8, hash_value);
        errdefer allocator.free(owned_hash);

        return .{
            .name = owned_name,
            .hash = owned_hash,
        };
    }

    return error.DependencyNotFound;
}

fn termSucceeded(term: std.process.Child.Term) bool {
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

/// Get file name from the given URL.
inline fn fileNameFromUrl(url: []const u8) []const u8 {
    var end = url.len;

    if (std.mem.findScalar(u8, url, '?')) |index| {
        end = @min(end, index);
    }

    if (std.mem.findScalar(u8, url, '#')) |index| {
        end = @min(end, index);
    }

    while (end > 0 and url[end - 1] == '/') {
        end -= 1;
    }

    if (end == 0) return "download";

    const clean_url = url[0..end];

    const slash_index = std.mem.findScalarLast(u8, clean_url, '/') orelse return clean_url;

    const name = clean_url[slash_index + 1 ..];

    return if (name.len == 0) "download" else name;
}

test "fileNameFromUrl : success" {
    const url: []const u8 = "https://github.com/opencv/opencv/archive/refs/tags/5.0.0.tar.gz/";
    const expected: []const u8 = "5.0.0.tar.gz";

    try std.testing.expectEqualStrings(expected, fileNameFromUrl(url));
}
