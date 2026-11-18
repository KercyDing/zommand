const std = @import("std");

const codegen = @import("codegen/main.zig");
const schema = @import("schema.zig");

pub fn main(init: std.process.Init) !void {
    return codegen.main(init);
}

test "args accepts single and list forms" {
    const source =
        \\.{
        \\    .name = "mixed",
        \\    .args = .{
        \\        .flag = .{ .name = "verbose", .help = "Verbose" },
        \\    },
        \\    .commands = .{
        \\        .{
        \\            .name = "one",
        \\            .help = "One",
        \\            .args = .{
        \\                .positional = .{ .name = "url", .help = "URL" },
        \\            },
        \\        },
        \\        .{
        \\            .name = "many",
        \\            .help = "Many",
        \\            .args = .{
        \\                .{ .positional = .{ .name = "name", .help = "Name" } },
        \\                .{ .flag = .{ .name = "force", .help = "Force" } },
        \\            },
        \\        },
        \\        .{
        \\            .name = "none",
        \\            .help = "None",
        \\        },
        \\    },
        \\}
    ;

    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var diagnostics: std.zon.parse.Diagnostics = undefined;
    const cli = try codegen.parseSchema(arena.allocator(), source, &diagnostics);

    try std.testing.expectEqual(1, cli.args.len);
    try std.testing.expect(cli.args[0] == .flag);

    try std.testing.expectEqual(3, cli.commands.len);
    try std.testing.expectEqual(1, cli.commands[0].args.len);
    try std.testing.expectEqualStrings("url", schema.argName(cli.commands[0].args[0]));
    try std.testing.expectEqual(2, cli.commands[1].args.len);
    try std.testing.expectEqual(0, cli.commands[2].args.len);
}

test "commands accepts single form" {
    const source =
        \\.{
        \\    .name = "single",
        \\    .commands = .{
        \\        .name = "run",
        \\        .help = "Run",
        \\        .args = .{
        \\            .flag = .{ .name = "force", .help = "Force" },
        \\        },
        \\    },
        \\}
    ;

    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var diagnostics: std.zon.parse.Diagnostics = undefined;
    const cli = try codegen.parseSchema(arena.allocator(), source, &diagnostics);

    try std.testing.expectEqual(1, cli.commands.len);
    try std.testing.expectEqualStrings("run", cli.commands[0].name);
    try std.testing.expectEqual(1, cli.commands[0].args.len);
    try std.testing.expect(cli.commands[0].args[0] == .flag);
}
