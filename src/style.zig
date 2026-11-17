//! Colors for terminal output. `std.Io.Terminal` picks ANSI escape codes, the
//! Windows console API, or no color, so every call is safe on any stream.

const std = @import("std");

pub const Style = struct {
    terminal: *std.Io.Terminal,

    /// Section titles (`Usage:`, `Commands:`, ...).
    pub fn header(self: Style) void {
        self.set(.cyan);
    }

    /// Program, command, flag, and option names.
    pub fn literal(self: Style) void {
        self.set(.bold);
    }

    /// Metavariables such as `<path>` and `[options]`.
    pub fn placeholder(self: Style) void {
        self.set(.yellow);
    }

    /// Secondary text such as "(default: .)"; gray rather than `dim`, which the
    /// Windows console maps to the same intensity as `bold`.
    pub fn hint(self: Style) void {
        self.set(.bright_black);
    }

    pub fn reset(self: Style) void {
        self.set(.reset);
    }

    fn set(self: Style, color: std.Io.Terminal.Color) void {
        self.terminal.setColor(color) catch {};
    }
};
