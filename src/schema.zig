pub const Cli = struct {
    /// Program name, for example: "zommand".
    name: []const u8,

    /// Program version, for example: "0.0.1".
    version: ?[]const u8 = null,

    /// Short one-line description.
    about: []const u8 = "",

    /// Optional detailed description.
    long_about: ?[]const u8 = null,

    /// Top-level arguments, for example:
    ///
    /// zommand --verbose
    args: []const Arg = &.{},

    /// Available subcommands.
    commands: []const Command = &.{},
};

pub const Command = struct {
    /// Command name, for example: "fetch".
    name: []const u8,

    /// Short one-line description.
    about: []const u8 = "",

    /// Optional detailed description.
    long_about: ?[]const u8 = null,

    /// Arguments owned by this command.
    args: []const Arg = &.{},

    // TODO: subcommands for subcommands.
    // commands: []const Command = &.{},
};

pub const Arg = union(enum) {
    /// Positional argument:
    ///
    /// zommand fetch <url>
    positional: Positional,

    /// Boolean flag:
    ///
    /// --force
    /// -f
    flag: Flag,

    /// Option that accepts a value:
    ///
    /// --path DIR
    /// -p DIR
    option: Option,
};

pub const Positional = struct {
    /// Internal identifier.
    ///
    /// It is also used as the default value name in help output.
    id: []const u8,

    /// Help message shown for this argument.
    help: []const u8 = "",

    /// Whether this argument must be provided.
    required: bool = false,

    /// Whether this argument may accept multiple values.
    ///
    /// Example:
    ///
    /// zommand add <file1> <file2>...
    multiple: bool = false,
};

pub const Flag = struct {
    /// Internal identifier.
    ///
    /// It is also used as the default long option name.
    ///
    /// Example:
    ///
    /// id = "force" -> --force
    id: []const u8,

    /// Optional short option name.
    ///
    /// Ziggy represents it as a string:
    ///
    /// .short = "f"
    short: ?[]const u8 = null,

    /// Help message shown for this flag.
    help: []const u8 = "",

    /// Whether this flag is inherited by subcommands.
    global: bool = false,

    /// Whether this flag may appear multiple times.
    ///
    /// This can be used for count-style flags such as:
    ///
    /// -v
    /// -vv
    /// -vvv
    multiple: bool = false,
};

pub const Option = struct {
    /// Internal identifier.
    ///
    /// It is also used as the default long option name.
    ///
    /// Example:
    ///
    /// id = "path" -> --path
    id: []const u8,

    /// Optional short option name.
    short: ?[]const u8 = null,

    /// Help message shown for this option.
    help: []const u8 = "",

    /// Whether this option must be provided.
    required: bool = false,

    /// Whether this option may appear multiple times.
    ///
    /// Example:
    ///
    /// --include src --include tests
    multiple: bool = false,

    /// Optional default value used when the option is absent.
    default: ?[]const u8 = null,

    /// Whether this option is inherited by subcommands.
    global: bool = false,
};
