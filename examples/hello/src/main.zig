const std = @import("std");
const cli = @import("cli");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();

    switch (try cli.parse(allocator, init.minimal.args)) {
        .print => |print| std.debug.print("hello, {s}!\n", .{print.name}),
    }
}
