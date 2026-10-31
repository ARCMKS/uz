const std = @import("std");

pub const ObjType = enum(u8) {
    string,
    error_obj,
    // P2: array, closure
};

pub const ErrorTag = enum(u16) {
    generic = 0,
    division_by_zero,
    file_not_found,
    permission_denied,
    invalid_argument,
    type_mismatch,
    pattern_mismatch,

    pub fn name(self: ErrorTag) []const u8 {
        return switch (self) {
            .generic => "generic",
            .division_by_zero => "division_by_zero",
            .file_not_found => "file_not_found",
            .permission_denied => "permission_denied",
            .invalid_argument => "invalid_argument",
            .type_mismatch => "type_mismatch",
            .pattern_mismatch => "pattern_mismatch",
        };
    }

    /// Manual table: avoids the 0.17 struct-of-arrays reflection surface.
    pub fn fromName(name_str: []const u8) ErrorTag {
        const table = .{
            .{ "generic", ErrorTag.generic },
            .{ "division_by_zero", ErrorTag.division_by_zero },
            .{ "file_not_found", ErrorTag.file_not_found },
            .{ "permission_denied", ErrorTag.permission_denied },
            .{ "invalid_argument", ErrorTag.invalid_argument },
            .{ "type_mismatch", ErrorTag.type_mismatch },
            .{ "pattern_mismatch", ErrorTag.pattern_mismatch },
        };
        inline for (table) |entry| {
            if (std.mem.eql(u8, name_str, entry[0])) return entry[1];
        }
        return .generic;
    }
};

pub const RefField = struct {
    offset: u32,
    kind: enum(u8) { value, array } = .value,
};

pub const TraceVisitor = struct {
    ctx: *anyopaque,
    markFn: *const fn (ctx: *anyopaque, obj: *Obj) void,

    pub fn mark(self: *TraceVisitor, obj: *Obj) void {
        self.markFn(self.ctx, obj);
    }
};

pub const TraceFn = *const fn (obj: *Obj, visitor: *TraceVisitor) void;

pub const ObjDescriptor = struct {
    name: [:0]const u8,
    obj_type: ObjType,
    fixed_size: u32,
    ref_fields: []const RefField = &.{},
    trace: ?TraceFn = null,
    min_size: u32 = 0,
};

/// Stable, pointer-aligned header. Payload structs embed this as their first field.
pub const Obj = extern struct {
    obj_type: ObjType,
    gc_flags: u8,
    _pad: [2]u8 = .{ 0, 0 },
    size: u32,
    next: ?*Obj,
    descriptor: *const ObjDescriptor,

    pub const GC_MARK: u8 = 1 << 0;
    pub const GC_IMMORTAL: u8 = 1 << 1;

    pub fn isMarked(self: *const Obj) bool {
        return (self.gc_flags & GC_MARK) != 0;
    }
    pub fn mark(self: *Obj) void {
        self.gc_flags |= GC_MARK;
    }
    pub fn clearMark(self: *Obj) void {
        self.gc_flags &= ~GC_MARK;
    }
    pub fn isImmortal(self: *const Obj) bool {
        return (self.gc_flags & GC_IMMORTAL) != 0;
    }
};

comptime {
    std.debug.assert(@sizeOf(Obj) % @alignOf(*anyopaque) == 0);
    std.debug.assert(@offsetOf(Obj, "descriptor") < @sizeOf(Obj));
}

pub const ObjString = struct {
    obj: Obj,
    bytes: []const u8,
    hash: u32,
};

pub const ObjError = struct {
    obj: Obj,
    tag: ErrorTag,
};

pub const string_descriptor: ObjDescriptor = .{
    .name = "string",
    .obj_type = .string,
    .fixed_size = @sizeOf(ObjString),
};

pub const error_descriptor: ObjDescriptor = .{
    .name = "error",
    .obj_type = .error_obj,
    .fixed_size = @sizeOf(ObjError),
};

pub fn asString(obj: *Obj) ?*ObjString {
    if (obj.obj_type != .string) return null;
    return @fieldParentPtr("obj", obj);
}

pub fn asError(obj: *Obj) ?*ObjError {
    if (obj.obj_type != .error_obj) return null;
    return @fieldParentPtr("obj", obj);
}

/// The single value representation. Every heap value is `*Obj`;
/// `descriptor.obj_type` is the discriminator.
pub const Value = union(enum) {
    nil,
    boolean: bool,
    integer: i64,
    number: f64,
    obj: *Obj,

    pub fn isObj(self: Value) bool {
        return self == .obj;
    }
    pub fn isError(self: Value) bool {
        return switch (self) {
            .obj => |o| o.obj_type == .error_obj,
            else => false,
        };
    }
    pub fn asString(self: Value) ?*ObjString {
        return switch (self) {
            .obj => |o| asString(o),
            else => null,
        };
    }
    pub fn asError(self: Value) ?*ObjError {
        return switch (self) {
            .obj => |o| asError(o),
            else => null,
        };
    }
    pub fn fmtType(self: Value) []const u8 {
        return switch (self) {
            .nil => "nil",
            .boolean => "bool",
            .integer => "int",
            .number => "float",
            .obj => |o| o.descriptor.name,
        };
    }
};
