# Zommand

A Zig library to build CLIs from a `.zon` schema.

## Usage

Add the dependency:

```bash
zig fetch --save git+https://github.com/KercyDing/zommand#main
```

Declare the schema in ZON:

```zig
.{
    .name = "greeting",
    .commands = .{
        .{
            .name = "print",
            .args = .{
                .{
                    .option = .{
                        .name = "name",
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

Parse in the application:

```zig
const cli = @import("cli");

const parsed = cli.parseOrExit(
    init.io,
    init.arena.allocator(),
    init.minimal.args,
);

switch (parsed.command) {
    .print => |print| std.debug.print("hello, {s}!\n", .{print.name orelse "world"}),
}
```

`-h` is an alias for `--help`; `-V` is an alias for `--version`. The
`help`/`version` argument ids and `h`/`V` short names are reserved.

See [`src/schema.zig`](src/schema.zig) for all fields.

## Examples

Complete projects live in [`examples`](examples):

- [`downloader`](examples/downloader): stream a URL into a directory
- [`greeting`](examples/greeting): minimal schema, one command, one option
- [`downloader`](examples/downloader): every optional field written out

```bash
only build-examples

./examples/greeting/zig-out/bin/greeting print --name xxx
./examples/downloader/zig-out/bin/downloader --verbose download https://ziglang.org/download/index.json --path ./.zig-cache/tmp
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
