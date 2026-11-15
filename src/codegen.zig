const std = @import("std");

const codegen = @import("codegen/main.zig");

pub fn main(init: std.process.Init) !void {
    return codegen.main(init);
}
