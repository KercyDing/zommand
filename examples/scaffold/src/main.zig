const std = @import("std");
const builtin = @import("builtin");
const cli = @import("cli");

const Init = cli.Init;

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);

    const result = try cli.parse(allocator, args);

    switch (result) {
        .init => |i| try runInit(init.io, allocator, init.environ_map, i),
    }
}

const bootstrap_name = "template";
const name_placeholder = "{{name}}";
const fingerprint_placeholder = "{{fingerprint}}";

const Replacement = struct {
    needle: []const u8,
    replacement: []const u8,
};

/// The init command entry.
pub fn runInit(
    io: std.Io,
    allocator: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
    init: Init,
) !void {
    try validateTemplateName(init.template);

    const project_name = try normalizeName(
        allocator,
        std.fs.path.basename(init.name),
    );
    defer allocator.free(project_name);

    const data_dir = try dataDirPath(allocator, environ);
    defer allocator.free(data_dir);

    const templates_path = try std.fs.path.join(
        allocator,
        &.{ data_dir, "templates", init.template },
    );
    defer allocator.free(templates_path);

    var templates_dir = try openTemplatesDir(
        io,
        allocator,
        environ,
        templates_path,
    );
    defer templates_dir.close(io);

    const target_path: []const u8 = init.name;
    var target_dir = try createEmptyDirPathOpen(
        std.Io.Dir.cwd(),
        io,
        target_path,
    );
    defer target_dir.close(io);

    const fingerprint = try generateFingerprint(io, allocator, project_name);
    defer allocator.free(fingerprint);

    const repls = [_]Replacement{
        .{ .needle = name_placeholder, .replacement = project_name },
        .{ .needle = fingerprint_placeholder, .replacement = fingerprint },
    };
    try copyDir(io, allocator, templates_dir, target_dir, &repls);

    std.debug.print("Initialized project in {s}\n", .{target_path});
}

fn runZigInit(io: std.Io, allocator: std.mem.Allocator, dir: std.Io.Dir) !void {
    const result = try std.process.run(allocator, io, .{
        .argv = &.{ "zig", "init" },
        .cwd = .{ .dir = dir },
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(64 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (!termSucceeded(result.term)) {
        if (result.stderr.len != 0) std.debug.print("{s}", .{result.stderr});
        return error.ZigInitFailed;
    }
}

/// Generates a package fingerprint for `name`.
fn generateFingerprint(io: std.Io, allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    var id: u32 = undefined;
    io.random(std.mem.asBytes(&id));
    if (id == 0) id = 1;
    if (id == 0xffffffff) id = 0xfffffffe;

    const checksum = std.hash.Crc32.hash(name);
    const value: u64 = @as(u64, id) | (@as(u64, checksum) << 32);
    return std.fmt.allocPrint(allocator, "0x{x:0>16}", .{value});
}

/// Finds the `0x...` fingerprint value in a generated `build.zig.zon`.
fn findFingerprintValue(source: []const u8) ?[]const u8 {
    const marker = ".fingerprint";
    const index = std.mem.indexOf(u8, source, marker) orelse return null;
    const rest = source[index..];

    const hex_marker = std.mem.indexOf(u8, rest, "0x") orelse return null;
    const start = index + hex_marker;
    var end = start + 2;
    while (end < source.len and std.ascii.isHex(source[end])) end += 1;
    return source[start..end];
}

/// Resolves the scaffold data directory.
fn dataDirPath(
    allocator: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
) ![]u8 {
    if (builtin.os.tag == .windows) {
        const local_app_data = environ.get("LOCALAPPDATA") orelse
            return error.LocalAppDataNotSet;
        if (!std.fs.path.isAbsolute(local_app_data)) {
            return error.InvalidLocalAppData;
        }
        return std.fs.path.join(allocator, &.{ local_app_data, "Programs", "Scaffold" });
    }

    if (environ.get("XDG_DATA_HOME")) |xdg| {
        if (xdg.len != 0 and std.fs.path.isAbsolute(xdg)) {
            return std.fs.path.join(allocator, &.{ xdg, "scaffold" });
        }
    }

    const home = environ.get("HOME") orelse return error.HomeNotSet;
    if (!std.fs.path.isAbsolute(home)) return error.InvalidHome;
    return std.fs.path.join(allocator, &.{ home, ".local", "share", "scaffold" });
}

/// Creates or opens `sub_path`, rejecting it if it already contains anything.
fn createEmptyDirPathOpen(
    parent: std.Io.Dir,
    io: std.Io,
    sub_path: []const u8,
) !std.Io.Dir {
    const status = try parent.createDirPathStatus(io, sub_path, .default_dir);
    var dir = try parent.openDir(io, sub_path, .{ .iterate = true });
    errdefer dir.close(io);

    if (status == .existed) {
        var it = dir.iterate();
        if (try it.next(io) != null) return error.TargetDirectoryNotEmpty;
    }

    return dir;
}

/// Opens the templates directory, bootstrapping it from `zig init` on first use.
fn openTemplatesDir(
    io: std.Io,
    allocator: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
    templates_path: []const u8,
) !std.Io.Dir {
    return std.Io.Dir.openDirAbsolute(io, templates_path, .{
        .iterate = true,
    }) catch |err| switch (err) {
        error.FileNotFound => {
            try bootstrapTemplates(io, allocator, environ, templates_path);
            return std.Io.Dir.openDirAbsolute(io, templates_path, .{
                .iterate = true,
            });
        },
        else => return err,
    };
}

/// Generates the template files for a template name.
fn bootstrapTemplates(
    io: std.Io,
    allocator: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
    templates_path: []const u8,
) !void {
    var temp_root = try openSystemTempDir(io, environ);
    defer temp_root.close(io);

    var task = try TempDir.create(io, temp_root);
    defer task.cleanup(io, temp_root);

    try task.dir.createDir(io, bootstrap_name, .default_dir);
    var project_dir = try task.dir.openDir(io, bootstrap_name, .{
        .iterate = true,
    });
    defer project_dir.close(io);

    try runZigInit(io, allocator, project_dir);

    const zon = try project_dir.readFileAlloc(
        io,
        "build.zig.zon",
        allocator,
        .unlimited,
    );
    defer allocator.free(zon);

    const old_fingerprint = findFingerprintValue(zon) orelse
        return error.FingerprintNotFound;

    var templates_dir = try std.Io.Dir.createDirPathOpen(
        std.Io.Dir.cwd(),
        io,
        templates_path,
        .{ .open_options = .{ .iterate = true } },
    );
    defer templates_dir.close(io);

    const repls = [_]Replacement{
        .{ .needle = bootstrap_name, .replacement = name_placeholder },
        .{ .needle = old_fingerprint, .replacement = fingerprint_placeholder },
    };
    try copyDir(io, allocator, project_dir, templates_dir, &repls);
}

/// Recursively copies `src` into `dst`, applying each replacement to every file.
fn copyDir(
    io: std.Io,
    allocator: std.mem.Allocator,
    src: std.Io.Dir,
    dst: std.Io.Dir,
    repls: []const Replacement,
) !void {
    var it = src.iterate();
    while (try it.next(io)) |entry| {
        switch (entry.kind) {
            .directory => {
                const source_stat = try src.statFile(io, entry.name, .{
                    .follow_symlinks = false,
                });
                try dst.createDir(io, entry.name, .default_dir);

                var sub_src = try src.openDir(io, entry.name, .{
                    .iterate = true,
                });
                defer sub_src.close(io);

                var sub_dst = try dst.openDir(io, entry.name, .{
                    .iterate = true,
                });
                defer sub_dst.close(io);

                try copyDir(io, allocator, sub_src, sub_dst, repls);
                // Zig 0.17 has no Windows implementation of directory permissions.
                if (builtin.os.tag != .windows) {
                    try sub_dst.setPermissions(io, source_stat.permissions);
                }
            },
            .file => {
                const source_stat = try src.statFile(io, entry.name, .{
                    .follow_symlinks = false,
                });
                const content = try src.readFileAlloc(
                    io,
                    entry.name,
                    allocator,
                    .unlimited,
                );
                defer allocator.free(content);

                const rendered = try applyReplacements(allocator, content, repls);
                defer allocator.free(rendered);

                try dst.writeFile(io, .{
                    .sub_path = entry.name,
                    .data = rendered,
                    .flags = .{
                        .exclusive = true,
                    },
                });
                // Zig 0.17 has no Windows implementation of directory permissions.
                if (builtin.os.tag != .windows) {
                    try dst.setFilePermissions(
                        io,
                        entry.name,
                        source_stat.permissions,
                        .{},
                    );
                }
            },
            .sym_link => {
                var link_buffer: [std.fs.max_path_bytes]u8 = undefined;
                const link_target = link_buffer[0..try src.readLink(
                    io,
                    entry.name,
                    &link_buffer,
                )];

                const is_directory = if (builtin.os.tag == .windows) blk: {
                    const target_stat = src.statFile(io, entry.name, .{}) catch |err| switch (err) {
                        error.FileNotFound => break :blk false,
                        else => return err,
                    };
                    break :blk target_stat.kind == .directory;
                } else false;

                try dst.symLink(io, link_target, entry.name, .{
                    .is_directory = is_directory,
                });
            },
            else => {},
        }
    }
}

fn applyReplacements(
    allocator: std.mem.Allocator,
    input: []const u8,
    repls: []const Replacement,
) ![]u8 {
    if (repls.len == 0) return allocator.dupe(u8, input);

    var current = try std.mem.replaceOwned(
        u8,
        allocator,
        input,
        repls[0].needle,
        repls[0].replacement,
    );
    errdefer allocator.free(current);

    for (repls[1..]) |r| {
        const next = try std.mem.replaceOwned(
            u8,
            allocator,
            current,
            r.needle,
            r.replacement,
        );
        allocator.free(current);
        current = next;
    }
    return current;
}

/// Normalizes a project name into a valid Zig identifier.
fn normalizeName(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);

    for (raw, 0..) |byte, i| switch (byte) {
        '0'...'9' => {
            if (i == 0) try list.append(allocator, '_');
            try list.append(allocator, byte);
        },
        '_', 'a'...'z', 'A'...'Z' => try list.append(allocator, byte),
        '-', '.', ' ' => try list.append(allocator, '_'),
        else => {},
    };

    if (!std.zig.isValidId(list.items)) {
        std.debug.print("error: '{s}' is not a valid project name\n", .{raw});
        std.process.exit(1);
    }

    return list.toOwnedSlice(allocator);
}

/// Rejects template names that would escape the templates directory.
fn validateTemplateName(name: []const u8) !void {
    if (name.len == 0 or
        std.mem.eql(u8, name, ".") or
        std.mem.eql(u8, name, "..") or
        std.mem.indexOfScalar(u8, name, '/') != null or
        std.mem.indexOfScalar(u8, name, '\\') != null)
    {
        return error.InvalidTemplateName;
    }
}

const TempDir = struct {
    dir: std.Io.Dir,
    name: [32]u8,

    fn create(io: std.Io, parent: std.Io.Dir) !TempDir {
        while (true) {
            var random_id: u128 = undefined;
            io.random(std.mem.asBytes(&random_id));

            const name = std.fmt.hex(random_id);

            parent.createDir(io, &name, .default_dir) catch |err| switch (err) {
                error.PathAlreadyExists => continue,
                else => return err,
            };

            const dir = parent.openDir(io, &name, .{}) catch |err| {
                parent.deleteDir(io, &name) catch {};
                return err;
            };

            return .{ .dir = dir, .name = name };
        }
    }

    fn cleanup(self: *TempDir, io: std.Io, parent: std.Io.Dir) void {
        self.dir.close(io);
        parent.deleteTree(io, &self.name) catch {};
        self.* = undefined;
    }
};

/// Opens the temporary directory of the system.
fn openSystemTempDir(io: std.Io, environ: *const std.process.Environ.Map) !std.Io.Dir {
    const temp_path = switch (builtin.os.tag) {
        .windows => environ.get("TMP") orelse environ.get("TEMP") orelse return error.TempDirUnavailble,
        .wasi, .freestanding => return error.TempDirUnavailble,
        else => environ.get("TMPDIR") orelse "/tmp",
    };

    if (!std.fs.path.isAbsolute(temp_path)) {
        return error.InvalidTempDir;
    }

    return std.Io.Dir.openDirAbsolute(io, temp_path, .{}) catch
        return error.OpenTempDirFailed;
}

fn termSucceeded(term: std.process.Child.Term) bool {
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

test "xdg fallback" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();
    try environ.put("XDG_DATA_HOME", "relative/data");
    try environ.put("HOME", "/home/example");

    const actual = try dataDirPath(allocator, &environ);
    defer allocator.free(actual);
    const expected = try std.fs.path.join(
        allocator,
        &.{ "/home/example", ".local", "share", "scaffold" },
    );
    defer allocator.free(expected);

    try std.testing.expectEqualStrings(expected, actual);
}

test "empty target" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDir(io, "empty", .default_dir);
    var empty = try createEmptyDirPathOpen(tmp.dir, io, "empty");
    empty.close(io);

    try tmp.dir.createDir(io, "non-empty", .default_dir);
    var non_empty = try tmp.dir.openDir(io, "non-empty", .{});
    try non_empty.writeFile(io, .{
        .sub_path = "keep.txt",
        .data = "keep me",
    });
    non_empty.close(io);

    try std.testing.expectError(
        error.TargetDirectoryNotEmpty,
        createEmptyDirPathOpen(tmp.dir, io, "non-empty"),
    );
}

test "copy metadata" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDir(io, "source", .default_dir);
    var source = try tmp.dir.openDir(io, "source", .{ .iterate = true });
    defer source.close(io);

    try source.writeFile(io, .{
        .sub_path = "run.sh",
        .data = "#!/bin/sh\necho {{name}}\n",
        .flags = .{ .permissions = .executable_file },
    });
    // `File.Permissions.setReadOnly` does not compile on Windows in Zig 0.17.
    if (builtin.os.tag != .windows) {
        try source.createDir(io, "readonly", .default_dir);
        var readonly = try source.openDir(io, "readonly", .{ .iterate = true });
        try readonly.writeFile(io, .{
            .sub_path = "nested.txt",
            .data = "nested",
        });
        const original_dir_permissions = (try readonly.stat(io)).permissions;
        const readonly_permissions = original_dir_permissions.setReadOnly(true);
        try readonly.setPermissions(io, readonly_permissions);
        readonly.close(io);
    }

    source.symLink(io, "run.sh", "run-link.sh", .{}) catch |err| switch (err) {
        error.AccessDenied, error.PermissionDenied => return error.SkipZigTest,
        else => return err,
    };

    try tmp.dir.createDir(io, "target", .default_dir);
    var target = try tmp.dir.openDir(io, "target", .{ .iterate = true });
    defer target.close(io);

    const repls = [_]Replacement{
        .{ .needle = name_placeholder, .replacement = "example" },
    };
    try copyDir(io, allocator, source, target, &repls);

    const rendered = try target.readFileAlloc(
        io,
        "run.sh",
        allocator,
        .unlimited,
    );
    defer allocator.free(rendered);
    try std.testing.expectEqualStrings("#!/bin/sh\necho example\n", rendered);

    if (builtin.os.tag != .windows) {
        const source_stat = try source.statFile(io, "run.sh", .{});
        const target_stat = try target.statFile(io, "run.sh", .{});
        try std.testing.expectEqual(source_stat.permissions, target_stat.permissions);
    }

    if (builtin.os.tag != .windows) {
        const source_dir_stat = try source.statFile(io, "readonly", .{});
        const target_dir_stat = try target.statFile(io, "readonly", .{});
        try std.testing.expectEqual(
            source_dir_stat.permissions,
            target_dir_stat.permissions,
        );
        try target.access(io, "readonly/nested.txt", .{});
    }

    var link_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const link_target = link_buffer[0..try target.readLink(
        io,
        "run-link.sh",
        &link_buffer,
    )];
    try std.testing.expectEqualStrings("run.sh", link_target);
}
