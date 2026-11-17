const dispatch = @import("dispatch.zig");
const gen = @import("gen.zig");
const schema = @import("schema.zig");
const style = @import("style.zig");
const util = @import("util.zig");
const validate = @import("validate.zig");

// =============== Types ===============
// Used by generated schema modules;
// applications call createCli from build.zig.
/// CLI schema used to describe a program and its commands.
pub const Cli = schema.Cli;
/// A command declared in a CLI schema.
pub const Command = schema.Command;
/// A positional argument, flag, or option in a CLI schema.
pub const Arg = schema.Arg;

/// Generates a typed parser for `cli` and `ResultType`.
pub const Generate = gen.Generate;
/// Errors returned when parsing process arguments fails.
pub const ParseError = gen.ParseError;

// =============== Tests ===============
test {
    const std = @import("std");

    std.testing.refAllDecls(dispatch);
    std.testing.refAllDecls(gen);
    std.testing.refAllDecls(schema);
    std.testing.refAllDecls(style);
    std.testing.refAllDecls(util);
    std.testing.refAllDecls(validate);
}
