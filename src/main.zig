const std = @import("std");

const fetch_mod = @import("fetch.zig");
const init_mod = @import("init.zig");

const Cli = @import("zis_schema").Cli;

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);

    const result = try Cli.parse(allocator, args);

    switch (result) {
        .fetch => |f| try fetch_mod.runFetch(init.io, allocator, init.environ_map, f),
        .init => |i| try init_mod.runInit(init.io, allocator, init.environ_map, i),
    }
}
