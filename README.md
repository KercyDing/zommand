# Zis

A tiny tool for better control over your Zig projects.

## Prerequisites

- **[Mise](https://github.com/jdx/mise)** (pin the zig & zls version)
- [Only](https://github.com/KercyDing/only) (task runner if you like)

## Usage

### Initialize a project

Create a Zig project from the default or a named template. The target directory must be empty.

```bash
zis init my-project
zis init my-project --template app
```

### Fetch a package

Fetch a Zig package and print its hash or dependency declaration.

```bash
zis fetch --save https://github.com/zigtools/zls/archive/refs/tags/0.16.0.tar.gz
```

## Customize templates

Zis creates missing templates from `zig init`. Edit a template here to customize future projects:

- Linux and macOS: `$XDG_DATA_HOME/zis/templates/<template>` or `$HOME/.local/share/zis/templates/<template>`
- Windows: `%LOCALAPPDATA%\Programs\Zis\templates\<template>`

The default template is `global`. Use `--template <name>` to choose another one.

## A Few Thoughts

I heard about the project called [Ziggy](https://github.com/kristoff-it/ziggy), and it’s perfect for my Zis.

So I built [libcommand](libcommand/README.md), a library which could build CLI with a easy `.ziggy`.

This project is steadily taking shape, and I still find joy in building it.

## LICENSE

[MIT](LICENSE)
