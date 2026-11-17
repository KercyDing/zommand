const std = @import("std");
const command = @import("command");

const Globals = struct {};
const Payload = struct {};
const Result = union(enum) { foo: Payload };

const Cli = command.Generate(.{
    .name = "p",
    .commands = &.{.{ .name = "foo", .help = "Foo" }},
}, Globals, Result);

const App = struct {
    out: *std.Io.Writer,
    err: *std.Io.Writer,

    pub fn handleFoo(self: *@This(), out: *std.Io.Writer) void {
        _ = self;
        _ = out;
    }
};

pub fn main() void {
    const init: std.process.Init = undefined;
    var app = App{ .out = undefined, .err = undefined };
    var parsed = Cli.Parsed{ .globals = .{}, .command = .{ .foo = .{} } };
    Cli.dispatch(init, &parsed, &app) catch {};
}
