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
    pub const unhandled = .{"typo"};

    pub fn handleFoo(self: *@This()) void {
        _ = self;
    }
};

pub fn main() void {
    const init: std.process.Init = undefined;
    var app = App{};
    var parsed = Cli.Parsed{ .globals = .{}, .command = .{ .foo = .{} } };
    Cli.dispatch(init, &parsed, &app) catch {};
}
