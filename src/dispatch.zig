const std = @import("std");
const util = @import("util.zig");

/// Fallback quota for callers that do not provide one.
const default_eval_branch_quota = 100_000;

/// Calls the `handle<Command>` method on `app` for `parsed.command`.
///
/// Parameters are supplied by type, in any order:
/// - `*App` or `*const App`
/// - `std.process.Init`
/// - program-level globals
/// - the command payload
/// - an `App` field whose type matches exactly
///
/// Commands without a `pub` handler are skipped at compile time.
pub fn dispatch(init: std.process.Init, parsed: anytype, app: anytype) !void {
    return dispatchWithQuota(default_eval_branch_quota, init, parsed, app);
}

/// Like `dispatch`, with an explicit compile-time branch quota.
pub fn dispatchWithQuota(
    comptime quota: u32,
    init: std.process.Init,
    parsed: anytype,
    app: anytype,
) !void {
    @setEvalBranchQuota(quota);

    const Parsed = comptime requireParsed(std.meta.Child(@TypeOf(parsed)));
    const App = comptime requireApp(@TypeOf(app));
    const Globals = @FieldType(Parsed, "globals");

    const globals: Globals = parsed.globals;
    switch (parsed.command) {
        inline else => |payload, tag| {
            const name = comptime handlerName(@tagName(tag));
            if (!@hasDecl(App, name)) return;

            const handler = @field(App, name);
            validateHandler(handler, name);

            const info = @typeInfo(@TypeOf(handler)).@"fn";
            var args: std.meta.ArgsTuple(@TypeOf(handler)) = undefined;
            inline for (info.param_types, 0..) |maybe_type, index| {
                const T = maybe_type orelse @compileError(std.fmt.comptimePrint(
                    "handler '{s}' must not have generic parameters",
                    .{name},
                ));
                args[index] = resolve(T, App, app, payload, globals, init, name, index);
            }

            const result = @call(.auto, handler, args);
            if (info.return_type.? == void) return;
            return try result;
        },
    }
}

fn requireParsed(comptime Parsed: type) type {
    switch (@typeInfo(Parsed)) {
        .@"struct" => {},
        else => @compileError("parsed must be a struct"),
    }
    if (!@hasField(Parsed, "globals")) @compileError("parsed is missing field 'globals'");
    if (!@hasField(Parsed, "command")) @compileError("parsed is missing field 'command'");

    const Command = @FieldType(Parsed, "command");
    switch (@typeInfo(Command)) {
        .@"union" => |info| {
            if (info.tag_type == null) @compileError("parsed.command must be a union(enum)");
        },
        else => @compileError("parsed.command must be a union(enum)"),
    }
    return Parsed;
}

fn requireApp(comptime AppPtr: type) type {
    const pointer = switch (@typeInfo(AppPtr)) {
        .pointer => |info| info,
        else => @compileError("app must be a pointer to a struct"),
    };
    if (pointer.attrs.@"const") @compileError("app must be a mutable pointer");
    switch (@typeInfo(pointer.child)) {
        .@"struct" => {},
        else => @compileError("app must point to a struct"),
    }
    return pointer.child;
}

fn validateHandler(comptime handler: anytype, comptime name: []const u8) void {
    const info = switch (@typeInfo(@TypeOf(handler))) {
        .@"fn" => |value| value,
        else => @compileError(std.fmt.comptimePrint(
            "App.{s} must be a function",
            .{name},
        )),
    };
    if (info.attrs.varargs) @compileError(std.fmt.comptimePrint(
        "handler '{s}' must not be variadic",
        .{name},
    ));

    const Return = info.return_type orelse @compileError(std.fmt.comptimePrint(
        "handler '{s}' must not have a generic return type",
        .{name},
    ));
    switch (@typeInfo(Return)) {
        .void => {},
        .error_union => |error_union| {
            if (error_union.payload != void) @compileError(std.fmt.comptimePrint(
                "handler '{s}' must return 'void' or '!void'",
                .{name},
            ));
        },
        else => @compileError(std.fmt.comptimePrint(
            "handler '{s}' must return 'void' or '!void'",
            .{name},
        )),
    }
}

fn resolve(
    comptime T: type,
    comptime App: type,
    app: *App,
    payload: anytype,
    globals: anytype,
    init: std.process.Init,
    comptime handler: []const u8,
    comptime index: usize,
) T {
    if (T == *App) return app;
    if (T == *const App) return app;
    if (T == std.process.Init) return init;
    if (T == @TypeOf(globals)) return globals;
    if (T == @TypeOf(payload)) return payload;
    if (comptime appFieldFor(T, App)) |name| return @field(app, name);

    @compileError(std.fmt.comptimePrint(
        "handler '{s}' parameter {d} of type '{s}' cannot be supplied by dispatch",
        .{ handler, index, @typeName(T) },
    ));
}

fn appFieldFor(comptime T: type, comptime App: type) ?[]const u8 {
    const info = @typeInfo(App).@"struct";
    comptime var found: ?[]const u8 = null;
    inline for (info.field_names, info.field_types) |name, FieldType| {
        if (FieldType == T) {
            if (found != null) @compileError(std.fmt.comptimePrint(
                "App has multiple fields of type '{s}'; take 'self' and use the field explicitly",
                .{@typeName(T)},
            ));
            found = name;
        }
    }
    return found;
}

fn handlerName(comptime command_id: []const u8) []const u8 {
    return std.fmt.comptimePrint("handle{s}", .{util.toPascalComptime(command_id)});
}

test "dispatch injects arguments by type" {
    const Globals = struct { verbose: bool };
    const Image = struct { path: []const u8, detect: bool };
    const List = struct {};
    const Result = union(enum) { image: Image, list: List };
    const Parsed = struct { globals: Globals, command: Result };

    const App = struct {
        out: *std.Io.Writer,
        calls: usize = 0,
        last: []const u8 = "",

        pub fn handleImage(
            self: *@This(),
            args: Image,
            globals: Globals,
            init: std.process.Init,
            out: *std.Io.Writer,
        ) !void {
            _ = init;
            self.calls += 1;
            self.last = args.path;
            try out.print("{s}:{d}\n", .{ args.path, @intFromBool(globals.verbose) });
        }

        pub fn handleList(self: *@This(), out: *std.Io.Writer) void {
            self.calls += 1;
            self.last = "list";
            out.writeAll("list\n") catch {};
        }
    };

    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    var app = App{ .out = &writer };
    const init: std.process.Init = undefined;

    var parsed = Parsed{
        .globals = .{ .verbose = true },
        .command = .{ .image = .{ .path = "x.png", .detect = true } },
    };
    try dispatch(init, &parsed, &app);
    try std.testing.expectEqual(@as(usize, 1), app.calls);
    try std.testing.expectEqualStrings("x.png", app.last);
    try std.testing.expectEqualStrings("x.png:1\n", writer.buffered());

    parsed.command = .{ .list = .{} };
    try dispatch(init, &parsed, &app);
    try std.testing.expectEqual(@as(usize, 2), app.calls);
    try std.testing.expectEqualStrings("list", app.last);
    try std.testing.expectEqualStrings("x.png:1\nlist\n", writer.buffered());
}

test "dispatch skips commands without a handler" {
    const Globals = struct {};
    const Seen = struct {};
    const Missing = struct {};
    const Result = union(enum) { seen: Seen, missing: Missing };
    const Parsed = struct { globals: Globals, command: Result };

    const App = struct {
        calls: usize = 0,

        pub fn handleSeen(self: *@This()) void {
            self.calls += 1;
        }
    };

    var app = App{};
    const init: std.process.Init = undefined;
    var parsed = Parsed{
        .globals = .{},
        .command = .{ .seen = .{} },
    };

    try dispatch(init, &parsed, &app);
    try std.testing.expectEqual(@as(usize, 1), app.calls);

    parsed.command = .{ .missing = .{} };
    try dispatch(init, &parsed, &app);
    try std.testing.expectEqual(@as(usize, 1), app.calls);
}

test "dispatch propagates handler errors" {
    const Globals = struct {};
    const Fail = struct {};
    const Result = union(enum) { fail: Fail };
    const Parsed = struct { globals: Globals, command: Result };

    const App = struct {
        pub fn handleFail(self: *@This()) error{Boom}!void {
            _ = self;
            return error.Boom;
        }
    };

    var app = App{};
    const init: std.process.Init = undefined;
    var parsed = Parsed{
        .globals = .{},
        .command = .{ .fail = .{} },
    };

    try std.testing.expectError(error.Boom, dispatch(init, &parsed, &app));
}

test "dispatch accepts const app receivers" {
    const Globals = struct {};
    const Show = struct {};
    const Result = union(enum) { show: Show };
    const Parsed = struct { globals: Globals, command: Result };

    const App = struct {
        called: *bool,

        pub fn handleShow(self: *const @This()) void {
            self.called.* = true;
        }
    };

    var called = false;
    var app = App{ .called = &called };
    const init: std.process.Init = undefined;
    var parsed = Parsed{
        .globals = .{},
        .command = .{ .show = .{} },
    };

    try dispatch(init, &parsed, &app);
    try std.testing.expect(called);
}

test "handler names follow command ids" {
    try std.testing.expectEqualStrings("handleImage", comptime handlerName("image"));
    try std.testing.expectEqualStrings("handleNewProject", comptime handlerName("new_project"));
}
