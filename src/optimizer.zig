const 

pub fn foldFunction(self: *ConstantFolder, func: *ir_mod.FunctionIR) !void {
    for (func.blocks.items) |*block| {
        try self.foldBasicBlock(block);
    }
}

fn foldBasicBlock(self: *ConstantFolder, block: *ir_mod.BasicBlock) !void {
    var known = std.AutoHashMap(ir_mod.Register, ir_mod.Operand).init(self.allocator);
    defer known.deinit();

    for (block.instructions.items) |*inst| {
        // Propagate known constants into operands.
        self.propagateOperand(&inst.src1, &known);
        self.propagateOperand(&inst.src2, &known);

        // Fold binary if both operands are constants.
        if (inst.op == .binary) {
            if (inst.src1 != null and inst.src2 != null) {
                if (tryFold(inst.binop, inst.src1.?, inst.src2.?)) |result| {
                    inst.op = .copy;
                    inst.src1 = result;
                    inst.src2 = null;
                }
            }
        }

        // Track dest = copy constant.
        if (inst.op == .copy and inst.dest != null and inst.src1 != null) {
            if (isConstant(inst.src1.?)) {
                try known.put(inst.dest.?, inst.src1.?);
            }
        }
    }
}

fn tryFold(op: ir_mod.OpBinary, a: ir_mod.Operand, b: ir_mod.Operand) ?ir_mod.Operand {
    // int + int
    if (a == .int_const and b == .int_const) {
        const x = a.int_const;
        const y = b.int_const;
        return switch (op) {
            .add => .{ .int_const = x + y },
            .sub => .{ .int_const = x - y },
            .mul => .{ .int_const = x * y },
            .div => if (y == 0) null else .{ .int_const = @divTrunc(x, y) },
            .eq => .{ .bool_const = x == y },
            .ne => .{ .bool_const = x != y },
            .lt => .{ .bool_const = x < y },
            .le => .{ .bool_const = x <= y },
            .gt => .{ .bool_const = x > y },
            .ge => .{ .bool_const = x >= y },
        };
    }
    // float + float
    if (a == .float_const and b == .float_const) {
        const x = a.float_const;
        const y = b.float_const;
        return switch (op) {
            .add => .{ .float_const = x + y },
            .sub => .{ .float_const = x - y },
            .mul => .{ .float_const = x * y },
            .div => if (y == 0.0) null else .{ .float_const = x / y },
            .eq => .{ .bool_const = x == y },
            .ne => .{ .bool_const = x != y },
            .lt => .{ .bool_const = x < y },
            .le => .{ .bool_const = x <= y },
            .gt => .{ .bool_const = x > y },
            .ge => .{ .bool_const = x >= y },
        };
    }
    return null;
}
