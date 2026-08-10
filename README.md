# Zis

A tiny tool for better control over your Zig projects.

## Prerequisites

- **[Mise](https://github.com/jdx/mise)** (pin the zig & zls version)
- [Only](https://github.com/KercyDing/only) (task runner if you like)

## Usage

```bash
zig build run -- fetch --save https://github.com/zigtools/zls/archive/refs/tags/0.16.0.tar.gz
# or:
# only br fetch --save https://github.com/zigtools/zls/archive/refs/tags/0.16.0.tar.gz
```

## A Few Thoughts

I heard about the project called [Ziggy](https://github.com/kristoff-it/ziggy), and it’s perfect for my Zis.

So I built [libcommand](libcommand/README.md), a library which could build CLI with a easy `.ziggy`.

This project is still in its very early stages, and I feel joy to build it.

## LICENSE

[MIT](LICENSE)
