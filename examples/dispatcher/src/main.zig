const std = @import("std");
const cli = @import("cli");

const App = struct {
    out: *std.Io.Writer,

    pub const unhandled = .{"status"};

    pub fn handleGreet(self: *@This(), args: cli.Greet) !void {
        try self.out.print("hello, {s}!\n", .{args.name});
    }

    pub fn handleSum(self: *@This(), globals: cli.Globals, args: cli.Sum) !void {
        const a = try std.fmt.parseInt(i64, args.a, 10);
        const b = try std.fmt.parseInt(i64, args.b, 10);

        if (globals.verbose) {
            try self.out.print("{s} + {s} = {d}\n", .{ args.a, args.b, a + b });
        } else {
            try self.out.print("{d}\n", .{a + b});
        }
    }

    pub fn handleRepeat(self: *@This(), args: cli.Repeat) !void {
        const times = try std.fmt.parseInt(usize, args.times, 10);

        var index: usize = 0;
        while (index < times) : (index += 1) {
            try self.out.print("{s}\n", .{args.text});
        }
    }
};

pub fn main(init: std.process.Init) !void {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &stdout_buffer);

    const out = &stdout_writer.interface;
    defer out.flush() catch {};

    var app = App{ .out = out };
    try cli.run(init, &app);
}
