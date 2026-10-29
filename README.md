# Zommand

A Zig library to build CLIs from an easy `.zon` schema.

## How Does It Work

`command-codegen` parses a `.zon` schema at build time and generates a Zig
module containing explicit command types and the parser:

```zig
// Generated from cli.zon.
pub const Fetch = struct {
    url: []const u8,
    save: bool,
};

pub const Result = union(enum) {
    fetch: Fetch,
};

const Parser = command.Generate(schema, Result);

pub fn parse(
    allocator: std.mem.Allocator,
    args: []const [:0]const u8,
) ParseError!Result {
    return Parser.parse(allocator, args);
}
```

The generated file stays in the build cache; nothing is written into the source
tree. Types are explicit Zig declarations rather than comptime-constructed
`@Struct`/`@Union`, so editors can resolve them as long as their Zig build
integration works.

The schema uses Zig tagged unions written directly in ZON:

```zig
.args = .{
    .{ .positional = .{ .id = "url", .required = true } },
    .{ .flag = .{ .id = "save", .short = "s" } },
    .{ .option = .{ .id = "template", .default = "global" } },
},
```

`Generate` validates at comptime that the generated `Result` type matches the
schema exactly, including field names and field types. The schema supports
positionals, boolean flags, and options, with short names, defaults, required
values, repeated values, and inheritance by subcommands. See
[`src/schema.zig`](src/schema.zig) for the full schema and the
[examples](examples) for complete usages.

## Consuming the library

Generate the schema module in `build.zig`, then import it from the executable:

```zig
const zommand = b.dependency("zommand", .{
    .target = target,
    .optimize = optimize,
});

const generate = b.addRunArtifact(zommand.artifact("command-codegen"));
generate.addFileArg(b.path("src/cli.zon"));
const cli = b.createModule(.{
    .root_source_file = generate.addOutputFileArg("cli.zig"),
    .imports = &.{
        .{ .name = "command", .module = zommand.module("command") },
    },
});

const exe_mod = b.createModule(.{
    .root_source_file = b.path("src/main.zig"),
    .target = target,
    .optimize = optimize,
    .imports = &.{
        .{ .name = "cli", .module = cli },
    },
});
```

```zig
// src/main.zig
const cli = @import("cli");
const Fetch = cli.Fetch;

const result = try cli.parse(allocator, args);

switch (result) {
    .fetch => |f| try runFetch(io, allocator, environ, f),
}
```

## Examples

Each example is a complete project that depends on zommand through a path
dependency:

- [`examples/pack-fetch`](examples/pack-fetch) fetches a package archive and
  prints its hash or a dependency declaration.
- [`examples/scaffold`](examples/scaffold) creates a Zig project from a
  template, the former `zis init` command.
- [`examples/hello`](examples/hello) is the smallest usage, with one command
  and an option.

```bash
cd examples/hello
zig build
./zig-out/bin/hello print
./zig-out/bin/hello print --name xxx

cd examples/pack-fetch
zig build
./zig-out/bin/pack-fetch fetch --save https://github.com/zigtools/zls/archive/refs/tags/0.16.0.tar.gz

cd examples/scaffold
zig build
./zig-out/bin/scaffold init my-project
```

## Development

```bash
zig build test                                  # library tests
(cd examples/pack-fetch && zig build test)      # pack-fetch tests
(cd examples/scaffold && zig build test)        # scaffold tests
```

## LICENSE

[MIT](LICENSE)
