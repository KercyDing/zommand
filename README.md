# Zommand

A Zig library to build CLIs from a `.zon` schema.

## Usage

Add the dependency:

```bash
zig fetch --save git+https://code.kercy666.com/Kercy/zommand#main
```

Declare the schema in ZON:

```zig
.{
    .name = "hello",
    .about = "Print hello world.",
    .commands = .{
        .{
            .name = "print",
            .about = "Print hello world",
            .args = .{
                .{
                    .option = .{
                        .id = "name",
                        .help = "Name to greet (default: world)",
                        .default = "world",
                    },
                },
            },
        },
    },
}
```

Generate a module from it in `build.zig`:

```zig
const zommand = @import("zommand");

const cli = zommand.createCli(b, .{
    .target = target,
    .optimize = optimize,
    .schema = b.path("cli.zon"),
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

The generated module has explicit command types and `parse`:

```zig
const cli = @import("cli");

const io = init.io;
const arena = init.arena.allocator();
const args = init.minimal.args;

const result = try cli.parse(io, arena, args);

switch (result) {
    .print => |print| std.debug.print("hello, {s}!\n", .{print.name}),
}
```

`--help` prints program or command help using the schema's `about`, `long_about`, and `help` fields.

See [`src/schema.zig`](src/schema.zig) for all fields.

## Examples

Complete projects live in [`examples`](examples):

- [`hello`](examples/hello): one command, one option
- [`downloader`](examples/downloader): stream a URL into a directory

```bash
only build-examples

./examples/hello/zig-out/bin/hello print --name xxx
./examples/downloader/zig-out/bin/downloader download https://ziglang.org/download/index.json --path ./.zig-cache/tmp
```

## Development

```bash
only build       # build zommand
only test        # run tests
only fmt         # format
only clean       # remove build artifacts
```

## LICENSE

[MIT](LICENSE)
