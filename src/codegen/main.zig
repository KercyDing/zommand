const std = @import("std");

const emit = @import("emit.zig");
const schema = @import("../schema.zig");

const source_size_max = 1024 * 1024;

/// Raw schema where each `args` field is kept as a ZON node so that it can be
/// normalized after parsing. Both `.{ .flag = ... }` and `.{ .{ .flag = ... } }`
/// are accepted.
const RawCli = struct {
    name: []const u8,
    version: []const u8 = "0.0.1",
    help: ?[]const u8 = null,
    args: ?std.zig.Zoir.Node.Index = null,
    commands: ?std.zig.Zoir.Node.Index = null,
};

const RawCommand = struct {
    name: []const u8,
    help: []const u8,
    args: ?std.zig.Zoir.Node.Index = null,
};

const NormalizeError = error{ OutOfMemory, ParseZon };

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
    const cli = parseSchema(allocator, source, &diagnostics) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ParseZon => {
            diagnostics.log(args[1]);
            return error.InvalidSchema;
        },
    };

    var output: std.Io.Writer.Allocating = .init(allocator);
    emit.emit(allocator, cli, &output.writer) catch |err| switch (err) {
        error.InvalidSchema => std.process.exit(1),
        else => return err,
    };

    try std.Io.Dir.cwd().writeFile(init.io, .{
        .sub_path = args[2],
        .data = output.writer.buffered(),
    });
}

/// Parses and normalizes a ZON schema. The result lives in `allocator`.
pub fn parseSchema(
    allocator: std.mem.Allocator,
    source: [:0]const u8,
    diagnostics: *std.zon.parse.Diagnostics,
) NormalizeError!schema.Cli {
    var ast = try std.zig.Ast.parse(std.heap.page_allocator, source, .{ .mode = .zon });
    defer ast.deinit(std.heap.page_allocator);

    var zoir = try std.zig.ZonGen.generate(std.heap.page_allocator, ast, .{ .parse_str_lits = false });
    defer zoir.deinit(std.heap.page_allocator);

    return normalizeSchema(allocator, &ast, &zoir, diagnostics);
}

fn normalizeSchema(
    allocator: std.mem.Allocator,
    ast: *const std.zig.Ast,
    zoir: *const std.zig.Zoir,
    diagnostics: *std.zon.parse.Diagnostics,
) NormalizeError!schema.Cli {
    const raw = try std.zon.parse.fromZoir(RawCli, .{
        .arena = allocator,
        .ast = ast,
        .zoir = zoir,
        .diagnostics = diagnostics,
    });

    return .{
        .name = raw.name,
        .version = raw.version,
        .help = raw.help,
        .args = try normalizeArgs(allocator, ast, zoir, diagnostics, raw.args),
        .commands = try normalizeCommands(allocator, ast, zoir, diagnostics, raw.commands),
    };
}

/// Accepts `.commands = .{ .name = ... }` as shorthand for a single command and
/// `.commands = .{ .{ .name = ... }, ... }` as a list.
fn normalizeCommands(
    allocator: std.mem.Allocator,
    ast: *const std.zig.Ast,
    zoir: *const std.zig.Zoir,
    diagnostics: *std.zon.parse.Diagnostics,
    node: ?std.zig.Zoir.Node.Index,
) NormalizeError![]const schema.Command {
    const raw_commands = try normalizeList(RawCommand, allocator, ast, zoir, diagnostics, node);
    const commands = try allocator.alloc(schema.Command, raw_commands.len);
    for (raw_commands, commands) |raw_command, *command| {
        command.* = try normalizeCommand(allocator, ast, zoir, diagnostics, raw_command);
    }
    return commands;
}

fn normalizeCommand(
    allocator: std.mem.Allocator,
    ast: *const std.zig.Ast,
    zoir: *const std.zig.Zoir,
    diagnostics: *std.zon.parse.Diagnostics,
    raw: RawCommand,
) NormalizeError!schema.Command {
    return .{
        .name = raw.name,
        .help = raw.help,
        .args = try normalizeArgs(allocator, ast, zoir, diagnostics, raw.args),
    };
}

/// Accepts `.args = .{ .flag = ... }` as shorthand for a single argument and
/// `.args = .{ .{ .flag = ... }, ... }` as a list.
fn normalizeArgs(
    allocator: std.mem.Allocator,
    ast: *const std.zig.Ast,
    zoir: *const std.zig.Zoir,
    diagnostics: *std.zon.parse.Diagnostics,
    node: ?std.zig.Zoir.Node.Index,
) NormalizeError![]const schema.Arg {
    return normalizeList(schema.Arg, allocator, ast, zoir, diagnostics, node);
}

/// ZON lists accept a single item as a struct literal, or an array literal.
/// `.{}` is an empty list. For unions, a struct literal with multiple fields is
/// treated as a list missing its array wrapper so the error stays actionable.
fn normalizeList(
    comptime T: type,
    allocator: std.mem.Allocator,
    ast: *const std.zig.Ast,
    zoir: *const std.zig.Zoir,
    diagnostics: *std.zon.parse.Diagnostics,
    node: ?std.zig.Zoir.Node.Index,
) NormalizeError![]const T {
    const index = node orelse return &.{};

    switch (index.get(zoir)) {
        .empty_literal => return &.{},
        .struct_literal => |fields| {
            switch (@typeInfo(T)) {
                .@"union" => if (fields.names.len != 1) {
                    return parseList(T, allocator, ast, zoir, diagnostics, index);
                },
                else => {},
            }

            const items = try allocator.alloc(T, 1);
            items[0] = try std.zon.parse.fromZoir(T, .{
                .arena = allocator,
                .ast = ast,
                .zoir = zoir,
                .node = index,
                .diagnostics = diagnostics,
            });
            return items;
        },
        else => return parseList(T, allocator, ast, zoir, diagnostics, index),
    }
}

fn parseList(
    comptime T: type,
    allocator: std.mem.Allocator,
    ast: *const std.zig.Ast,
    zoir: *const std.zig.Zoir,
    diagnostics: *std.zon.parse.Diagnostics,
    node: std.zig.Zoir.Node.Index,
) NormalizeError![]const T {
    return std.zon.parse.fromZoir([]const T, .{
        .arena = allocator,
        .ast = ast,
        .zoir = zoir,
        .node = node,
        .diagnostics = diagnostics,
    });
}
