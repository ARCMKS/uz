const std = @import("std");
const ir = @import("ir.zig");

pub const Op = enum(u8) {
    push_int = 0,
    push_float,
    push_bool,
    push_nil,
    push_string, // u32 pool_idx
    load_reg, // u32
    store_reg, // u32
    pop,
    dup,
    binary, // u8 subop, u8 type_hint
    make_error, // u16 tag_id
    is_error,
    match_error, // u16 tag_id, i32 rel_offset
    try_unwrap, // u32 skip_on_ok_offset? — actually: if error return; else fall through
    jump, // i32 rel_offset
    jump_if_false, // i32 rel_offset
    return_val,
};

pub const Codegen = struct {
    allocator: std.mem.Allocator,
    code: std.ArrayList(u8) = .empty,
    strings: std.ArrayList([]const u8) = .empty,
    // label → byte offset once resolved
    label_positions: std.AutoHashMap(u32, usize),
    // pending jump patches: (pos_of_i32_operand, label_id)
    patches: std.ArrayList(struct { pos: usize, label: u32 }) = .empty,

    pub fn init(allocator: std.mem.Allocator) Codegen {
        return .{
            .allocator = allocator,
            .label_positions = std.AutoHashMap(u32, usize).init(allocator),
        };
    }

    pub fn deinit(self: *Codegen) void {
        self.code.deinit(self.allocator);
        self.strings.deinit(self.allocator);
        self.patches.deinit(self.allocator);
        self.label_positions.deinit();
    }

    pub fn emitFunction(self: *Codegen, func: *const ir.FunctionIR) ![]u8 {
        for (func.blocks.items) |block| {
            for (block.instructions.items) |inst| {
                try self.emitInstruction(inst);
            }
        }
        try self.resolveLabels();
        return self.code.toOwnedSlice(self.allocator);
    }

    pub fn stringPool(self: *Codegen) []const []const u8 {
        return self.strings.items;
    }

    fn emitInstruction(self: *Codegen, inst: ir.Instruction) !void {
        switch (inst.op) {
            .copy => {
                if (inst.src1) |s| try self.emitOperandLoad(s);
                if (inst.dest) |d| {
                    try self.emitByte(@backingInt(Op.store_reg));
                    try self.emitU32(@backingInt(d));
                }
            },
            .binary => {
                if (inst.src1) |s| try self.emitOperandLoad(s);
                if (inst.src2) |s| try self.emitOperandLoad(s);
                try self.emitByte(@backingInt(Op.binary));
                try self.emitByte(@backingInt(inst.binop));
                try self.emitByte(@backingInt(inferTypeHint(inst)));
                if (inst.dest) |d| {
                    try self.emitByte(@backingInt(Op.store_reg));
                    try self.emitU32(@backingInt(d));
                }
            },
            .make_error => {
                try self.emitByte(@backingInt(Op.make_error));
                try self.emitU16(tagId(inst.error_tag));
                if (inst.dest) |d| {
                    try self.emitByte(@backingInt(Op.store_reg));
                    try self.emitU32(@backingInt(d));
                }
            },
            .is_error => {
                if (inst.src1) |s| try self.emitOperandLoad(s);
                try self.emitByte(@backingInt(Op.is_error));
                if (inst.dest) |d| {
                    try self.emitByte(@backingInt(Op.store_reg));
                    try self.emitU32(@backingInt(d));
                }
            },
            .match_error => {
                if (inst.src1) |s| try self.emitOperandLoad(s);
                try self.emitByte(@backingInt(Op.match_error));
                try self.emitU16(tagId(inst.error_tag));
                try self.patchLabel(@backingInt(inst.label_target.?));
            },
            .enter_scope => try self.emitByte(@backingInt(Op.enter_scope)),
            .exit_scope => try self.emitByte(@backingInt(Op.exit_scope)),
            .defer_push => {
                if (inst.src1) |s| try self.emitOperandLoad(s);
                try self.emitByte(@backingInt(Op.defer_push));
            },
            .bind_ok => {
                if (inst.src1) |s| try self.emitOperandLoad(s);
                try self.emitByte(@backingInt(Op.bind_ok));
                if (inst.dest) |d| {
                    try self.emitByte(@backingInt(Op.store_reg));
                    try self.emitU32(@backingInt(d));
                }
            },
            .bind_err => {
                if (inst.src1) |s| try self.emitOperandLoad(s);
                try self.emitByte(@backingInt(Op.bind_err));
                if (inst.dest) |d| {
                    try self.emitByte(@backingInt(Op.store_reg));
                    try self.emitU32(@backingInt(d));
                }
            },
            .try_unwrap => {
                if (inst.src1) |s| try self.emitOperandLoad(s);
                try self.emitByte(@backingInt(Op.try_unwrap));
                if (inst.dest) |d| {
                    try self.emitByte(@backingInt(Op.store_reg));
                    try self.emitU32(@backingInt(d));
                }
            },
            .jump => {
                try self.emitByte(@backingInt(Op.jump));
                try self.patchLabel(@backingInt(inst.label_target.?));
            },
            .jump_if_false => {
                if (inst.src1) |s| try self.emitOperandLoad(s);
                try self.emitByte(@backingInt(Op.jump_if_false));
                try self.patchLabel(@backingInt(inst.label_target.?));
            },
            .label => {
                const id = @backingInt(inst.label_target.?);
                try self.label_positions.put(id, self.code.items.len);
            },
            .return_val => {
                if (inst.src1) |s| try self.emitOperandLoad(s);
                try self.emitByte(@backingInt(Op.return_val));
            },
        }
    }

    fn emitOperandLoad(self: *Codegen, op: ir.Operand) !void {
        switch (op) {
            .int_const => |v| {
                try self.emitByte(@backingInt(Op.push_int));
                try self.emitI64(v);
            },
            .float_const => |v| {
                try self.emitByte(@backingInt(Op.push_float));
                try self.emitF64(v);
            },
            .bool_const => |v| {
                try self.emitByte(@backingInt(Op.push_bool));
                try self.emitByte(if (v) 1 else 0);
            },
            .nil_const => {
                try self.emitByte(@backingInt(Op.push_nil));
            },
            .string_const => |s| {
                try self.emitByte(@backingInt(Op.push_string));
                const idx: u32 = @intCast(self.strings.items.len);
                try self.strings.append(self.allocator, s);
                try self.emitU32(idx);
            },
            .error_const => |tag| {
                try self.emitByte(@backingInt(Op.make_error));
                try self.emitU16(tagId(tag));
            },
            .register => |r| {
                try self.emitByte(@backingInt(Op.load_reg));
                try self.emitU32(@backingInt(r));
            },
        }
    }

    fn inferTypeHint(self: *Codegen, inst: ir.Instruction) ir.TypeHint {
        _ = self;
        return switch (inst.binop) {
            .add, .sub, .mul, .div => .int, // will be refined at runtime
            .eq, .ne, .lt, .le, .gt, .ge => .bool,
        };
    }

    fn tagId(name: []const u8) u16 {
        return @backingInt(@import("value.zig").ErrorTag.from_name(name));
    }

    fn patchLabel(self: *Codegen, label_id: u32) !void {
        const pos = self.code.items.len;
        try self.emitI32(0); // placeholder
        try self.patches.append(self.allocator, .{ .pos = pos, .label = label_id });
    }

    fn resolveLabels(self: *Codegen) !void {
        for (self.patches.items) |p| {
            const target = self.label_positions.get(p.label) orelse return error.UndefinedLabel;
            const rel: i32 = @as(i32, @intCast(target)) - @as(i32, @intCast(p.pos + 4));
            std.mem.writeInt(i32, self.code.items[p.pos..][0..4], rel, .little);
        }
    }

    fn emitByte(self: *Codegen, b: u8) !void {
        try self.code.append(self.allocator, b);
    }
    fn emitU16(self: *Codegen, v: u16) !void {
        var buf: [2]u8 = undefined;
        std.mem.writeInt(u16, &buf, v, .little);
        try self.code.appendSlice(self.allocator, &buf);
    }
    fn emitU32(self: *Codegen, v: u32) !void {
        var buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &buf, v, .little);
        try self.code.appendSlice(self.allocator, &buf);
    }
    fn emitI32(self: *Codegen, v: i32) !void {
        var buf: [4]u8 = undefined;
        std.mem.writeInt(i32, &buf, v, .little);
        try self.code.appendSlice(self.allocator, &buf);
    }
    fn emitI64(self: *Codegen, v: i64) !void {
        var buf: [8]u8 = undefined;
        std.mem.writeInt(i64, &buf, v, .little);
        try self.code.appendSlice(self.allocator, &buf);
    }
    fn emitF64(self: *Codegen, v: f64) !void {
        var buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &buf, @bitCast(v), .little);
        try self.code.appendSlice(self.allocator, &buf);
    }
};
