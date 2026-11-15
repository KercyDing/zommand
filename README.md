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
            .help = "Print hello world",
            .args = .{
                .{
                    .option = .{
                        .name = "name",
                        .help = "Name to greet",
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
const std = @import("std");
const cli = @import("cli");

pub fn main(init: std.process.Init) !void {
    const parsed = cli.parseOrExit(init);

    switch (parsed.command) {
        .print => |print| std.debug.print("hello, {s}!\n", .{print.name orelse "world"}),
    }
}
```

`parseOrExit` prints usage errors and exits with code 2; use `parseArgs` with
an explicit argv slice to handle errors yourself.

## Command line

- `--name value`, `--name=value`, `-n value`, `-nvalue`, `-n=value`, and
  clustered short flags such as `-ab` are accepted.
- `--` stops option parsing, so positionals may start with `-`. A dash-leading
  option value can use `--name=-x`.
- Flags cannot be repeated; non-`multiple` options cannot be repeated.
- `-h`/`--help` and `-V`/`--version` are reserved. Program-level `Cli.args` are
  accepted before or after the command and returned in `parsed.globals`.
- Usage errors go to stderr; `parseOrExit` exits with code 2.

## Naming

`name` is both the CLI token and the source for the Zig field and generated
type: `-` becomes `_`, and invalid names are schema errors. Zig keywords are
emitted as escaped identifiers, for example `@"type"`.

For arguments, `name` is the CLI name and field source, `short` is optional,
and `placeholder` only affects help:

```zig
.{ .name = "new-project" }
.{ .option = .{ .name = "dry-run", .short = "n", .placeholder = "mode" } }
```

See [`src/schema.zig`](src/schema.zig) for all fields.

## Examples

Complete projects live in [`examples`](examples):

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
