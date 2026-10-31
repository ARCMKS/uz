const std = @import("std");
const v = @import("value.zig");
const gc_mod = @import("gc.zig");
const cg = @import("codegen.zig");
const ir = @import("ir.zig");

pub const STACK_MAX = 4096;
pub const REGISTERS_MAX = 1024;

const CleanupEntry = struct {
    scope_depth: u32,
    callable: v.Value, // zero-arg callable, or a marker with body
};

pub const VM = struct {
    allocator: std.mem.Allocator,
    gc: gc_mod.Collector,
    strings: []const []const u8,

    stack: [STACK_MAX]v.Value = undefined,
    sp: usize = 0,
    registers: [REGISTERS_MAX]v.Value = undefined,

    pub fn init(allocator: std.mem.Allocator, strings: []const []const u8) VM {
        return .{
            .allocator = allocator,
            .gc = gc_mod.Collector.init(allocator),
            .strings = strings,
        };
    }

    pub fn deinit(self: *VM) void {
        self.gc.deinit();
    }

    pub fn run(self: *VM, code: []const u8) !v.Value {
        var ip: usize = 0;

        while (ip < code.len) {
            const op: cg.Op = @enumFromInt(code[ip]);
            ip += 1;
            switch (op) {
                .push_int => {
                    const n = std.mem.readInt(i64, code[ip..][0..8], .little);
                    ip += 8;
                    try self.push(.{ .integer = n });
                },
                .push_float => {
                    const bits = std.mem.readInt(u64, code[ip..][0..8], .little);
                    ip += 8;
                    try self.push(.{ .number = @bitCast(bits) });
                },
                .push_bool => {
                    const b = code[ip] != 0; ip += 1;
                    try self.push(.{ .boolean = b });
                },
                .push_nil => try self.push(.nil),
                .push_string => {
                    const idx = std.mem.readInt(u32, code[ip..][0..4], .little); ip += 4;
                    try self.safepoint();
                    const s = try self.gc.allocateString(self.strings[idx]);
                    try self.push(.{ .string = s });
                },
                .load_reg => {
                    const idx = std.mem.readInt(u32, code[ip..][0..4], .little); ip += 4;
                    if (idx >= REGISTERS_MAX) return error.RegisterOutOfBounds;
                    try self.push(self.registers[idx]);
                },
                .store_reg => {
                    const idx = std.mem.readInt(u32, code[ip..][0..4], .little); ip += 4;
                    if (idx >= REGISTERS_MAX) return error.RegisterOutOfBounds;
                    if (self.sp == 0) return error.StackUnderflow;
                    self.sp -= 1;
                    self.registers[idx] = self.stack[self.sp];
                },
                .pop => {
                    if (self.sp == 0) return error.StackUnderflow;
                    self.sp -= 1;
                },
                .dup => {
                    if (self.sp == 0) return error.StackUnderflow;
                    try self.push(self.stack[self.sp - 1]);
                },
                .binary => {
                    const subop: ir.OpBinary = @enumFromInt(code[ip]); ip += 1;
                    _ = code[ip]; ip += 1; // type hint
                    if (self.sp < 2) return error.StackUnderflow;
                    self.sp -= 1;
                    const rhs = self.stack[self.sp];
                    const lhs = self.stack[self.sp - 1];
                    self.stack[self.sp - 1] = try applyBinary(subop, lhs, rhs);
                },
                .make_error => {
                    const tag_raw = std.mem.readInt(u16, code[ip..][0..2], .little); ip += 2;
                    try self.safepoint();
                    const e = try self.gc.allocateError(@enumFromInt(tag_raw));
                    try self.push(.{ .error_ = e });
                },
                .is_error => {
                    if (self.sp == 0) return error.StackUnderflow;
                    const x = self.stack[self.sp - 1];
                    self.stack[self.sp - 1] = .{ .boolean = x.isError() };
                },
                .match_error => {
                    const tag_raw = std.mem.readInt(u16, code[ip..][0..2], .little); ip += 2;
                    const rel = std.mem.readInt(i32, code[ip..][0..4], .little); ip += 4;
                    if (self.sp == 0) return error.StackUnderflow;
                    const x = self.stack[self.sp - 1];
                    if (x == .error_ and @intFromEnum(x.error_.tag) == tag_raw) {
                        ip = @as(usize, @intCast(@as(i64, @intCast(ip)) + rel));
                    }
                },
                .try_unwrap => {
                    if (self.sp == 0) return error.StackUnderflow;
                    const x = self.stack[self.sp - 1];
                    if (x.isError()) return x; // propagate as value, not unwinding
                    // fall through: value already on top, will be stored by next store_reg
                },
                .jump => {
                    const rel = std.mem.readInt(i32, code[ip..][0..4], .little); ip += 4;
                    ip = @intCast(@as(i64, @intCast(ip)) + rel);
                },
                .jump_if_false => {
                    const rel = std.mem.readInt(i32, code[ip..][0..4], .little); ip += 4;
                    if (self.sp == 0) return error.StackUnderflow;
                    const x = self.stack[self.sp - 1];
                    self.sp -= 1;
                    const b = switch (x) {
                        .boolean => |bb| bb,
                        .nil => false,
                        .integer => |i| i != 0,
                        .number => |f| f != 0,
                        else => true,
                    };
                    if (!b) ip = @intCast(@as(i64, @intCast(ip)) + rel);
                },
                .return_val => {
                    if (self.sp == 0) return error.StackUnderflow;
                    return self.stack[self.sp - 1];
                },
            }
        }
        return error.FellOffEndOfProgram;
    }

    fn push(self: *VM, val: v.Value) !void {
        if (self.sp >= STACK_MAX) return error.StackOverflow;
        self.stack[self.sp] = val;
        self.sp += 1;
    }

    fn safepoint(self: *VM) !void {
        if (!self.gc.shouldCollect()) return;
        var roots = std.ArrayList(v.Value).empty;
        defer roots.deinit(self.allocator);
        try roots.appendSlice(self.allocator, self.stack[0..self.sp]);
        try roots.appendSlice(self.allocator, &self.registers);
        try self.gc.collect(roots.items);
    }
};

fn applyBinary(op: ir.OpBinary, a: v.Value, b: v.Value) !v.Value {
    // Integer fast path
    if (a == .integer and b == .integer) {
        const x = a.integer; const y = b.integer;
        return switch (op) {
            .add => .{ .integer = x + y },
            .sub => .{ .integer = x - y },
            .mul => .{ .integer = x * y },
            .div => if (y == 0) error.DivisionByZero else .{ .integer = @divTrunc(x, y) },
            .eq => .{ .boolean = x == y },
            .ne => .{ .boolean = x != y },
            .lt => .{ .boolean = x < y },
            .le => .{ .boolean = x <= y },
            .gt => .{ .boolean = x > y },
            .ge => .{ .boolean = x >= y },
        };
    }
    // Float path
    const fx: f64 = switch (a) { .integer => |i| @floatFromInt(i), .number => |n| n, else => return error.TypeError };
    const fy: f64 = switch (b) { .integer => |i| @floatFromInt(i), .number => |n| n, else => return error.TypeError };
    return switch (op) {
        .add => .{ .number = fx + fy },
        .sub => .{ .number = fx - fy },
        .mul => .{ .number = fx * fy },
        .div => if (fy == 0) error.DivisionByZero else .{ .number = fx / fy },
        .eq => .{ .boolean = fx == fy },
        .ne => .{ .boolean = fx != fy },
        .lt => .{ .boolean = fx < fy },
        .le => .{ .boolean = fx <= fy },
        .gt => .{ .boolean = fx > fy },
        .ge => .{ .boolean = fx >= fy },
    };
}