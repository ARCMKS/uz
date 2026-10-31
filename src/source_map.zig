const std = @import("std");
const Span = @import("span.zig").Span;

pub const SourceFile = struct {
    path: []const u8, // borrowed
    content: [:0]const u8, // owned, NUL-terminated for FFI convenience
    line_starts: []u32, // owned; line_starts[0] == 0
};

pub const Decoded = struct {
    line: u32,
    column: u32,
    line_start: u32,
    line_end: u32,
    file_path: []const u8,
    file_content: [:0]const u8,
};

pub const SourceMap = struct {
    allocator: std.mem.Allocator,
    files: std.ArrayListUnmanaged(SourceFile) = .empty,

    /// Install the sentinel at slot 0 so file_id 0 == Span.NONE.
    pub fn init(allocator: std.mem.Allocator) !SourceMap {
        var sm = SourceMap{ .allocator = allocator };
        try sm.files.append(allocator, .{
            .path = "<none>",
            .content = "",
            .line_starts = &.{},
        });
        return sm;
    }

    pub fn deinit(self: *SourceMap) void {
        for (self.files.items[1..]) |f| {
            self.allocator.free(f.content);
            self.allocator.free(f.line_starts);
        }
        self.files.deinit(self.allocator);
    }

    /// Copy `content` into the map and return its 1-based file_id.
    /// `path` is borrowed; the caller must keep it alive.
    pub fn add(self: *SourceMap, path: []const u8, content: []const u8) !u32 {
        const owned_content = try self.allocator.dupeSentinel(u8, content,0);
        errdefer self.allocator.free(owned_content);

        var lines: u32 = 1;
        for (content) |c| if (c == '\n') {
            lines += 1;
        };
        const line_starts = try self.allocator.alloc(u32, lines);
        errdefer self.allocator.free(line_starts);
        line_starts[0] = 0;
        var li: u32 = 1;
        for (content, 0..) |c, i| {
            if (c == '\n') {
                line_starts[li] = @intCast(i + 1);
                li += 1;
            }
        }

        const id: u32 = @intCast(self.files.items.len);
        try self.files.append(self.allocator, .{
            .path = path,
            .content = owned_content,
            .line_starts = line_starts,
        });
        return id;
    }

    pub fn get(self: *const SourceMap, file_id: u32) ?*const SourceFile {
        if (file_id == 0 or file_id >= self.files.items.len) return null;
        return &self.files.items[file_id];
    }

    /// The single place in the compiler that converts a byte offset
    /// into (line, column, excerpt). Mirrors source_map.c.
    pub fn decode(self: *const SourceMap, span: Span) ?Decoded {
        if (span.isNone()) return null;
        const f = self.get(span.file_id) orelse return null;
        if (f.line_starts.len == 0) return null;

        const file_len: u32 = @intCast(f.content.len);
        const off: u32 = if (span.start > file_len) file_len else span.start;

        var lo: u32 = 0;
        var hi: u32 = @intCast(f.line_starts.len);
        while (lo + 1 < hi) {
            const mid = (lo + hi) / 2;
            if (f.line_starts[mid] <= off) lo = mid else hi = mid;
        }

        const line_start = f.line_starts[lo];
        const line_end: u32 = if (lo + 1 < f.line_starts.len)
            f.line_starts[lo + 1] - 1
        else
            file_len;

        return .{
            .line = lo + 1,
            .column = off - line_start + 1,
            .line_start = line_start,
            .line_end = line_end,
            .file_path = f.path,
            .file_content = f.content,
        };
    }

    /// Copy the bytes of `span` into `out` as a NUL-terminated string.
    /// Returns the number of source bytes copied (excluding the NUL).
    pub fn spanText(self: *const SourceMap, span: Span, out: []u8) usize {
        if (out.len == 0) return 0;
        out[0] = 0;
        if (span.isNone()) return 0;
        const f = self.get(span.file_id) orelse return 0;
        const file_len: u32 = @intCast(f.content.len);
        var s = span.start;
        var e = span.end;
        if (s > file_len) s = file_len;
        if (e > file_len) e = file_len;
        if (e < s) e = s;
        var n: usize = @intCast(e - s);
        if (n >= out.len) n = out.len - 1;
        @memcpy(out[0..n], f.content[s..][0..n]);
        out[n] = 0;
        return n;
    }

    pub fn spanEquals(self: *const SourceMap, span: Span, str: []const u8) bool {
        if (span.len() != str.len) return false;
        const f = self.get(span.file_id) orelse return false;
        const file_len: u32 = @intCast(f.content.len);
        if (span.start + @as(u32, @intCast(str.len)) > file_len) return false;
        return std.mem.eql(u8, f.content[span.start..][0..str.len], str);
    }
};
