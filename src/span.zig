const std = @import("std");

/// A span into a source file.
/// `start` is inclusive, `end` is exclusive. `file_id` is 1-based;
/// 0 is reserved as the "no file" sentinel (`Span.NONE`).
pub const Span = struct {
    start: u32 = 0,
    end: u32 = 0,
    file_id: u32 = 0,

    pub const NONE: Span = .{};

    pub fn len(self: Span) u32 {
        return if (self.end >= self.start) self.end - self.start else 0;
    }

    pub fn isNone(self: Span) bool {
        return self.file_id == 0;
    }

    pub fn make(start: u32, end: u32, file_id: u32) Span {
        return .{ .start = start, .end = end, .file_id = file_id };
    }
};
