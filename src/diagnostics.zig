const std = @import("std");
const Span = @import("span.zig").Span;
const sm = @import("source_map.zig");

pub const Level = enum { note, warning, err };

pub const MAX_MESSAGE: usize = 256;

pub const Diagnostic = struct {
    level: Level,
    span: Span,
    message: [MAX_MESSAGE]u8,
    message_len: u32,

    pub fn text(self: *const Diagnostic) []const u8 {
        return self.message[0..self.message_len];
    }
};

pub const DiagnosticBag = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayListUnmanaged(Diagnostic) = .empty,
    error_count: u32 = 0,
    warning_count: u32 = 0,

    pub fn init(allocator: std.mem.Allocator) DiagnosticBag {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *DiagnosticBag) void {
        self.items.deinit(self.allocator);
    }

    pub fn clear(self: *DiagnosticBag) void {
        self.items.clearRetainingCapacity();
        self.error_count = 0;
        self.warning_count = 0;
    }

    /// Append a formatted diagnostic. Truncates at MAX_MESSAGE bytes
    /// (matching vsnprintf's silent truncation in the C reference).
    pub fn report(
        self: *DiagnosticBag,
        level: Level,
        span: Span,
        comptime fmt: []const u8,
        args: anytype,
    ) !void {
        var diag: Diagnostic = .{
            .level = level,
            .span = span,
            .message = std.mem.zeroes([MAX_MESSAGE]u8),
            .message_len = 0,
        };
        // fixedBufferStream.writeAll advances `pos` for every
        // successful byte before failing on a full buffer, so
        // fbs.pos is the exact truncation length on NoSpaceLeft.
        var writer: std.Io.Writer = .fixed(&diag.message);
        writer.print(fmt, args) catch {};
        diag.message_len = @intCast(writer.end);

        try self.items.append(self.allocator, diag);
        switch (level) {
            .err => self.error_count += 1,
            .warning => self.warning_count += 1,
            .note => {},
        }
    }

    pub fn hasErrors(self: *const DiagnosticBag) bool {
        return self.error_count > 0;
    }

    /// Render every diagnostic to `writer`. When `source_map` is
    /// non-null and the diagnostic has a valid span, print the
    /// source line and a caret underline. Mirrors diag_flush in C.
    pub fn flush(
        self: *const DiagnosticBag,
        source_map: ?*const sm.SourceMap,
        writer: anytype,
        color: bool,
    ) void {
        for (self.items.items) |*d| {
            const level_name: []const u8 = switch (d.level) {
                .note => "note",
                .warning => "warning",
                .err => "error",
            };
            const level_color: []const u8 = if (!color) "" else switch (d.level) {
                .note => "\x1b[36m",
                .warning => "\x1b[33m",
                .err => "\x1b[31m",
            };
            const reset: []const u8 = if (!color) "" else "\x1b[0m";

            writer.print("{s}{s}{s}: {s}\n", .{
                level_color, level_name, reset, d.text(),
            }) catch return;

            if (source_map == null or d.span.isNone()) continue;
            const dec = source_map.?.decode(d.span) orelse continue;

            writer.print("  {s}--> {s}:{d}:{d}{s}\n", .{
                reset, dec.file_path, dec.line, dec.column, reset,
            }) catch return;
            writer.print("   |\n", .{}) catch return;

            const line_slice = dec.file_content[dec.line_start..dec.line_end];
            writer.print("{d:>2} | {s}\n", .{ dec.line, line_slice }) catch return;

            writer.writeAll("   | ") catch return;
            var c: u32 = 1;
            while (c < dec.column) : (c += 1) {
                writer.writeByte(' ') catch return;
            }
            var len = d.span.len();
            if (len == 0) len = 1;
            const remaining = dec.line_end - (dec.line_start + dec.column - 1);
            if (len > remaining) len = remaining;
            if (len == 0) len = 1;
            const caret_color: []const u8 = if (!color) "" else "\x1b[33;1m";
            var i: u32 = 0;
            while (i < len) : (i += 1) {
                writer.print("{s}^{s}", .{ caret_color, reset }) catch return;
            }
            writer.writeByte('\n') catch return;
        }
    }
};
