const std = @import("std");

/// Maximum accepted length for names and placeholders.
pub const max_name_len = 64;

/// Replaces `-` with `_` and validates the result as a Zig identifier.
pub fn toSnake(name: []const u8, buffer: []u8) ?[]const u8 {
    if (buffer.len < name.len) return null;

    for (name, 0..) |byte, index| {
        buffer[index] = if (byte == '-') '_' else byte;
    }

    const result = buffer[0..name.len];
    if (!std.zig.isValidId(result)) return null;
    return result;
}

/// Converts a snake_case identifier to PascalCase.
pub fn toPascal(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    var buffer: [max_name_len]u8 = undefined;
    const result = toPascalBuffer(name, &buffer) orelse return error.InvalidIdentifier;
    return allocator.dupe(u8, result);
}

/// Compile-time `toPascal`. Returns a string literal.
pub fn toPascalComptime(comptime name: []const u8) []const u8 {
    const result = pascalAt(name, 0, true);
    if (!std.zig.isValidId(result)) @compileError(std.fmt.comptimePrint(
        "cannot derive a valid type name from '{s}'",
        .{name},
    ));
    return result;
}

/// Returns a compile-time branch quota based on schema size.
///
/// `cli` must expose `args` and `commands` slices; each command must expose
/// an `args` slice.
pub fn evalBranchQuota(comptime cli: anytype) u32 {
    var count: u32 = @intCast(cli.args.len + cli.commands.len);
    for (cli.commands) |command| {
        count += @intCast(command.args.len);
    }
    const commands: u32 = @intCast(cli.commands.len);
    return 100_000 + count * 1_000 + commands * commands * 100;
}

fn toPascalBuffer(name: []const u8, buffer: []u8) ?[]const u8 {
    if (buffer.len < name.len) return null;

    var length: usize = 0;
    var capitalize = true;
    for (name) |byte| {
        if (byte == '_') {
            capitalize = true;
            continue;
        }
        buffer[length] = if (capitalize) std.ascii.toUpper(byte) else byte;
        length += 1;
        capitalize = false;
    }

    const result = buffer[0..length];
    if (!std.zig.isValidId(result)) return null;
    return result;
}

fn pascalAt(
    comptime name: []const u8,
    comptime index: usize,
    comptime capitalize: bool,
) []const u8 {
    if (index == name.len) return "";
    const byte = name[index];
    if (byte == '_') return pascalAt(name, index + 1, true);
    const output = if (capitalize) std.ascii.toUpper(byte) else byte;
    return std.fmt.comptimePrint("{c}{s}", .{ output, pascalAt(name, index + 1, false) });
}

test "toSnake replaces dashes" {
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("new_project", toSnake("new-project", &buffer).?);
    try std.testing.expect(toSnake("1bad", &buffer) == null);
}

test "toPascal matches comptime conversion" {
    const runtime = try toPascal(std.testing.allocator, "new_project");
    defer std.testing.allocator.free(runtime);

    try std.testing.expectEqualStrings("NewProject", runtime);
    try std.testing.expectEqualStrings("NewProject", comptime toPascalComptime("new_project"));
    try std.testing.expectError(
        error.InvalidIdentifier,
        toPascal(std.testing.allocator, "1bad"),
    );
}

test "evalBranchQuota scales with schema" {
    const FakeCommand = struct { args: []const u8 = &.{} };
    const fake = .{
        .args = [_]u8{},
        .commands = [_]FakeCommand{.{}},
    };
    try std.testing.expectEqual(@as(u32, 101_100), evalBranchQuota(fake));
}
