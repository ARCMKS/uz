const std = @import("std");
const v = @import("value.zig");
const ir = @import("ir.zig");

pub fn truthy(val: v.Value) bool {
    return switch (val) {
        .nil => false,
        .boolean => |b| b,
        .integer => |i| i != 0,
        .number => |n| n != 0,
        .obj => true,
    };
}

pub fn eql(a: v.Value, b: v.Value) bool {
    return switch (a) {
        .nil => b == .nil,
        .boolean => |x| b == .boolean and b.boolean == x,
        .integer => |x| switch (b) {
            .integer => |y| x == y,
            .number => |y| @as(f64, @floatFromInt(x)) == y,
            else => false,
        },
        .number => |x| switch (b) {
            .number => |y| x == y,
            .integer => |y| x == @as(f64, @floatFromInt(y)),
            else => false,
        },
        .obj => |x| switch (b) {
            .obj => |y| eqlObj(x, y),
            else => false,
        },
    };
}

fn eqlObj(a: *v.Obj, b: *v.Obj) bool {
    if (a.obj_type != b.obj_type) return false;
    return switch (a.obj_type) {
        .string => std.mem.eql(u8, v.asString(a).?.bytes, v.asString(b).?.bytes),
        .error_obj => v.asError(a).?.tag == v.asError(b).?.tag,
    };
}

pub fn applyBinary(op: ir.OpBinary, a: v.Value, b: v.Value) !v.Value {
    if (a == .integer and b == .integer) {
        const x = a.integer;
        const y = b.integer;
        return switch (op) {
            .add => .{ .integer = x +% y },
            .sub => .{ .integer = x -% y },
            .mul => .{ .integer = x *% y },
            .div => if (y == 0) error.DivisionByZero else .{ .integer = @divTrunc(x, y) },
            .eq => .{ .boolean = x == y },
            .ne => .{ .boolean = x != y },
            .lt => .{ .boolean = x < y },
            .le => .{ .boolean = x <= y },
            .gt => .{ .boolean = x > y },
            .ge => .{ .boolean = x >= y },
        };
    }

    const fx: f64 = switch (a) {
        .integer => |i| @floatFromInt(i),
        .number => |n| n,
        else => return error.TypeError,
    };
    const fy: f64 = switch (b) {
        .integer => |i| @floatFromInt(i),
        .number => |n| n,
        else => return error.TypeError,
    };
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
