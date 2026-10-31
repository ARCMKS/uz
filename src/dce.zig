//! src/dce.zig
//!
//! Dead Code Elimination (DCE) Pass.
//! Scans Control-Flow Graph (CFG) basic blocks to count register references and removes
//! unused, side-effect-free instructions until reaching a fixed-point state.

const std = @import("std");
const ir_mod = @import("ir.zig");

/// Optimization pass runner performing fixed-point dead code elimination.
pub const DeadCodeEliminator = struct {
    allocator: std.mem.Allocator,

    /// Initializes a new dead code elimination pass runner.
    pub fn init(allocator: std.mem.Allocator) DeadCodeEliminator {
        return .{ .allocator = allocator };
    }

    /// Iteratively eliminates dead instructions across all blocks until no further changes occur.
    pub fn eliminateFunction(self: *DeadCodeEliminator, func: *ir_mod.FunctionIR) !void {
        var changed = true;
        while (changed) {
            changed = try self.runPass(func);
        }
    }

    /// Single sweep across basic blocks to recalculate use-counts and trim dead instructions.
    fn runPass(self: *DeadCodeEliminator, func: *ir_mod.FunctionIR) !bool {
        // 1. Calculate usage counts for all virtual registers in the function
        var use_counts = std.AutoHashMap(ir_mod.Register, u32).init(self.allocator);
        defer use_counts.deinit();

        for (func.blocks.items) |block| {
            for (block.instructions.items) |inst| {
                self.countOperandUse(&use_counts, inst.src1);
                self.countOperandUse(&use_counts, inst.src2);
            }
        }

        var changed = false;

        // 2. Filter out instructions whose destination register has 0 usages
        for (func.blocks.items) |*block| {
            var write_idx: usize = 0;
            for (block.instructions.items) |inst| {
                if (isDead(inst, &use_counts)) {
                    changed = true;
                    continue; // Omit instruction from retained list
                }
                block.instructions.items[write_idx] = inst;
                write_idx += 1;
            }
            block.instructions.items.len = write_idx;
        }

        return changed;
    }

    /// Increments the reference count of a virtual register operand.
    fn countOperandUse(
        self: *DeadCodeEliminator,
        counts: *std.AutoHashMap(ir_mod.Register, u32),
        operand: ?ir_mod.Operand,
    ) void {
        _ = self;
        if (operand) |op| {
            if (op == .register) {
                const gop = counts.getOrPut(op.register) catch return;
                if (gop.found_existing) {
                    gop.value_ptr.* += 1;
                } else {
                    gop.value_ptr.* = 1;
                }
            }
        }
    }

    /// Determines if an instruction is dead (has a destination, zero uses, and no side effects).
    fn isDead(inst: ir_mod.Instruction, use_counts: *const std.AutoHashMap(ir_mod.Register, u32)) bool {
        // Instructions without destination registers (e.g., control flow) cannot be pruned by DCE
        const dest = inst.dest orelse return false;

        // Preserve instructions with observable side effects
        if (hasSideEffects(inst.op)) return false;

        // Instruction is dead if its destination register is never referenced downstream
        const uses = use_counts.get(dest) orelse 0;
        return uses == 0;
    }

    /// Indicates whether an IR opcode produces external or execution-critical side effects.
    fn hasSideEffects(op: ir_mod.Instruction.Opcode) bool {
        return switch (op) {
            .return_val, .jump, .jump_if_false, .label,
            .match_error, .try_unwrap, .make_error,
            .enter_scope, .exit_scope, .defer_push => true,
            .binary, .copy, .is_error, .bind_ok, .bind_err => false,
        };
    }
};
