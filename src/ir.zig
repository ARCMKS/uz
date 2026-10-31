const std = @import("std");
const v = @import("value.zig");

pub const Register = enum(u32) { _ };
pub const Label = enum(u32) { _ };

pub const OpBinary = enum(u8) { add, sub, mul, div, eq, ne, lt, le, gt, ge };

pub const Operand = union(enum) {
    int_const: i64,
    float_const: f64,
    bool_const: bool,
    nil_const,
    string_const: []const u8,
    error_const: v.ErrorTag,
    register: Register,
};

pub const Instruction = struct {
    op: Opcode,
    dest: ?Register = null,
    src1: ?Operand = null,
    src2: ?Operand = null,
    binop: OpBinary = .add,
    label_target: ?Label = null,
    error_tag: v.ErrorTag = .generic,
    call_target: u32 = 0,
    argc: u8 = 0,

    pub const Opcode = enum(u8) {
        binary,
        copy,
        push, // materialize src1 onto the operand stack (for call args)
        make_error,
        is_error,
        match_error,
        try_unwrap,
        jump,
        jump_if_false,
        label,
        return_val,
        call,
        ret,
    };
};

pub const BasicBlock = struct {
    id: u32 = 0,
    label: []const u8 = "",
    instructions: std.ArrayList(Instruction) = .empty,
};

pub const FunctionIR = struct {
    name: []const u8,
    params: []const []const u8 = &.{},
    blocks: std.ArrayList(BasicBlock) = .empty,
    register_count: u32 = 0,
    label_count: u32 = 0,

    pub fn allocReg(self: *FunctionIR) Register {
        const r: Register = @fromBackingInt(@intCast(self.register_count));
        self.register_count += 1;
        return r;
    }

    pub fn allocLabel(self: *FunctionIR) Label {
        const l: Label = @fromBackingInt(@intCast(self.label_count));
        self.label_count += 1;
        return l;
    }

    pub fn deinit(self: *FunctionIR, allocator: std.mem.Allocator) void {
        for (self.blocks.items) |*b| b.instructions.deinit(allocator);
        self.blocks.deinit(allocator);
    }
};

pub const Module = struct {
    functions: std.ArrayList(FunctionIR) = .empty,

    pub fn deinit(self: *Module, allocator: std.mem.Allocator) void {
        for (self.functions.items) |*f| f.deinit(allocator);
        self.functions.deinit(allocator);
    }

    pub fn findFunction(self: *const Module, name: []const u8) ?u32 {
        for (self.functions.items, 0..) |f, i| {
            if (std.mem.eql(u8, f.name, name)) return @intCast(i);
        }
        return null;
    }
};
