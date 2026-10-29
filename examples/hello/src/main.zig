const std = @import("std");
const cli = @import("cli");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = init.minimal.args;

    const result = try cli.parse(io, arena, args);

    switch (result) {
        .print => |print| std.debug.print("hello, {s}!\n", .{print.name}),
    }
}
