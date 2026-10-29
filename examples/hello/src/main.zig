const std = @import("std");
const cli = @import("cli");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = init.minimal.args;

    switch (try cli.parse(arena, args)) {
        .print => |print| std.debug.print("hello, {s}!\n", .{print.name}),
    }
}
