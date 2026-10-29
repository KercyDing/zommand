const schema = @import("schema.zig");
const gen = @import("gen.zig");

// =============== Types ===============
// Used by generated schema modules;
// applications call createCli from build.zig.
pub const Cli = schema.Cli;
pub const Command = schema.Command;
pub const Arg = schema.Arg;

pub const Generate = gen.Generate;
pub const ParseError = gen.ParseError;

// =============== Tests ===============
test {
    _ = schema;
    _ = gen;
}
