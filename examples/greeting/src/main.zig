const std = @import("std");
const cli = @import("cli");

pub fn main(init: std.process.Init) !void {
    const parsed = cli.parseOrExit(init);

    switch (parsed.command) {
        .print => |print| std.debug.print("hello, {s}!\n", .{print.name orelse "world"}),
    }
}
