const std = @import("std");
const ast = @import("ast.zig");
const ir = @import("ir.zig");
const v = @import("value.zig");

pub const Lowerer = struct {
    allocator: std.mem.Allocator,
    ast: *const ast.Ast,
    module: *ir.Module,
    func: *ir.FunctionIR = undefined,
    var_map: std.StringHashMap(ir.Register),

    pub fn init(allocator: std.mem.Allocator, ast_: *const ast.Ast, module: *ir.Module) Lowerer {
        return .{
            .allocator = allocator,
            .ast = ast_,
            .module = module,
            .var_map = std.StringHashMap(ir.Register).init(allocator),
        };
    }

    pub fn deinit(self: *Lowerer) void {
        self.var_map.deinit();
    }

    pub fn lowerProgram(self: *Lowerer) !void {
        // Pass 1: reserve one FunctionIR per declaration so calls can resolve forward.
        for (self.ast.decls.items) |decl| switch (decl) {
            .fn_decl => |f| try self.module.functions.append(self.allocator, .{ .name = f.name }),
            .type_decl => {},
        };

        // Pass 2: lower bodies in place (no appends => stable pointers).
        var i: usize = 0;
        for (self.ast.decls.items) |decl| switch (decl) {
            .fn_decl => |*f| {
                try self.lowerFnBody(f, i);
                i += 1;
            },
            .type_decl => {},
        };
    }

    fn lowerFnBody(self: *Lowerer, f: *const ast.FnDecl, index: usize) !void {
        self.func = &self.module.functions.items[index];
        self.var_map.clearRetainingCapacity();

        var names = std.ArrayList([]const u8).empty;
        defer names.deinit(self.allocator);
        for (f.params) |p| {
            const r = self.func.allocReg();
            try self.var_map.put(p.name, r);
            try names.append(self.allocator, p.name);
        }
        self.func.params = try names.toOwnedSlice(self.allocator);

        try self.func.blocks.append(self.allocator, .{ .id = 0, .label = "entry" });

        for (f.body.stmts) |s| try self.lowerStmt(s);

        // Guaranteed terminator.
        try self.emit(.{ .op = .return_val, .src1 = .nil_const });
    }

    fn emit(self: *Lowerer, inst: ir.Instruction) !void {
        const block = &self.func.blocks.items[self.func.blocks.items.len - 1];
        try block.instructions.append(self.allocator, inst);
    }

    fn lowerStmt(self: *Lowerer, s: *ast.Stmt) anyerror!void {
        switch (s.*) {
            .let_stmt => |l| {
                const init = try self.lowerExpr(l.init);
                const slot = self.func.allocReg();
                try self.var_map.put(l.name, slot);
                try self.emit(.{ .op = .copy, .dest = slot, .src1 = init });
            },
            .return_stmt => |r| {
                const val = if (r.value) |e| try self.lowerExpr(e) else ir.Operand.nil_const;
                try self.emit(.{ .op = .return_val, .src1 = val });
            },
            .if_stmt => |i| try self.lowerIf(i),
            .while_stmt => |w| try self.lowerWhile(w),
            .match_stmt => |m| try self.lowerMatch(m),
            .assign_stmt => |a| {
                const name = switch (a.target.*) {
                    .ident => |n| n,
                    else => return error.InvalidAssignTarget,
                };
                const slot = self.var_map.get(name) orelse return error.UndefinedVariable;
                const val = try self.lowerExpr(a.value);
                try self.emit(.{ .op = .copy, .dest = slot, .src1 = val });
            },
            .expr_stmt => |e| {
                _ = try self.lowerExpr(e);
            },
            .block => |b| {
                for (b.stmts) |st| try self.lowerStmt(st);
            },
        }
    }

    fn lowerIf(self: *Lowerer, i: ast.Stmt.if_stmt) !void {
        const else_l = self.func.allocLabel();
        const end_l = self.func.allocLabel();
        const cond = try self.lowerExpr(i.cond);
        try self.emit(.{ .op = .jump_if_false, .src1 = cond, .label_target = else_l });
        for (i.then_blk.stmts) |st| try self.lowerStmt(st);
        if (i.else_blk) |eb| {
            try self.emit(.{ .op = .jump, .label_target = end_l });
            try self.emit(.{ .op = .label, .label_target = else_l });
            for (eb.stmts) |st| try self.lowerStmt(st);
            try self.emit(.{ .op = .label, .label_target = end_l });
        } else {
            try self.emit(.{ .op = .label, .label_target = else_l });
        }
    }

    fn lowerWhile(self: *Lowerer, w: ast.Stmt.while_stmt) !void {
        const top = self.func.allocLabel();
        const exit = self.func.allocLabel();
        try self.emit(.{ .op = .label, .label_target = top });
        const cond = try self.lowerExpr(w.cond);
        try self.emit(.{ .op = .jump_if_false, .src1 = cond, .label_target = exit });
        for (w.body.stmts) |st| try self.lowerStmt(st);
        try self.emit(.{ .op = .jump, .label_target = top });
        try self.emit(.{ .op = .label, .label_target = exit });
    }

    fn lowerMatch(self: *Lowerer, m: ast.Stmt.match_stmt) !void {
        const scrut = try self.lowerExpr(m.scrutinee);
        const end_l = self.func.allocLabel();

        const ErrArm = struct { label: ir.Label, body: *ast.Stmt };
        var err_arms = std.ArrayList(ErrArm).empty;
        defer err_arms.deinit(self.allocator);

        // 1. Emit error checks.
        for (m.arms) |arm| {
            const pat = switch (arm.pattern) {
                .variant => |x| x,
                else => continue,
            };
            if (!std.mem.eql(u8, pat.variant_name, "Err")) continue;
            const tag: v.ErrorTag = if (pat.subpatterns.len > 0) switch (pat.subpatterns[0]) {
                .str_lit => |s| v.ErrorTag.fromName(s),
                else => .generic,
            } else .generic;
            const l = self.func.allocLabel();
            try self.emit(.{ .op = .match_error, .src1 = scrut, .error_tag = tag, .label_target = l });
            try err_arms.append(self.allocator, .{ .label = l, .body = arm.body });
        }

        // 2. Ok / wildcard fallthrough.
        for (m.arms) |arm| {
            switch (arm.pattern) {
                .variant => |pat| {
                    if (std.mem.eql(u8, pat.variant_name, "Err")) continue;
                    // Ok(payload): payload is identity, so bind to the scrutinee register.
                    self.bindPayload(pat, scrut);
                    try self.lowerStmt(arm.body);
                    try self.emit(.{ .op = .jump, .label_target = end_l });
                },
                .wildcard => {
                    try self.lowerStmt(arm.body);
                    try self.emit(.{ .op = .jump, .label_target = end_l });
                },
                else => {},
            }
        }

        // 3. Error bodies.
        for (err_arms.items) |ea| {
            try self.emit(.{ .op = .label, .label_target = ea.label });
            try self.lowerStmt(ea.body);
            try self.emit(.{ .op = .jump, .label_target = end_l });
        }

        try self.emit(.{ .op = .label, .label_target = end_l });
    }

    fn bindPayload(self: *Lowerer, pat: ast.Pattern, scrut: ir.Operand) void {
        if (pat.subpatterns.len != 1) return;
        const bind_name = switch (pat.subpatterns[0]) {
            .bind => |n| n,
            else => return,
        };
        if (scrut == .register) {
            self.var_map.put(bind_name, scrut.register) catch {};
        }
    }

    fn lowerExpr(self: *Lowerer, e: *ast.Expr) anyerror!ir.Operand {
        switch (e.*) {
            .int_lit => |x| return .{ .int_const = x },
            .float_lit => |x| return .{ .float_const = x },
            .str_lit => |s| return .{ .string_const = s },
            .bool_lit => |b| return .{ .bool_const = b },
            .ident => |name| {
                if (self.var_map.get(name)) |r| return .{ .register = r };
                return error.UndefinedVariable;
            },
            .binary => |b| {
                const lhs = try self.lowerExpr(b.lhs);
                const rhs = try self.lowerExpr(b.rhs);
                const dest = self.func.allocReg();
                const op: ir.OpBinary = switch (b.op) {
                    .add => .add,
                    .sub => .sub,
                    .mul => .mul,
                    .div => .div,
                    .eq => .eq,
                    .ne => .ne,
                    .lt => .lt,
                    .le => .le,
                    .gt => .gt,
                    .ge => .ge,
                    .and_, .or_ => return error.UnsupportedOperator,
                };
                try self.emit(.{ .op = .binary, .dest = dest, .src1 = lhs, .src2 = rhs, .binop = op });
                return .{ .register = dest };
            },
            .unary => |u| switch (u.op) {
                .neg => {
                    const x = try self.lowerExpr(u.operand);
                    const dest = self.func.allocReg();
                    try self.emit(.{
                        .op = .binary,
                        .dest = dest,
                        .src1 = .{ .int_const = 0 },
                        .src2 = x,
                        .binop = .sub,
                    });
                    return .{ .register = dest };
                },
                .not => {
                    const x = try self.lowerExpr(u.operand);
                    const dest = self.func.allocReg();
                    try self.emit(.{
                        .op = .binary,
                        .dest = dest,
                        .src1 = x,
                        .src2 = .{ .bool_const = false },
                        .binop = .eq,
                    });
                    return .{ .register = dest };
                },
                .deref, .borrow => return error.UnsupportedOperator,
            },
            .call => |c| {
                const target = self.module.findFunction(c.callee) orelse return error.UndefinedFunction;
                for (c.args) |arg| {
                    const a = try self.lowerExpr(arg);
                    try self.emit(.{ .op = .push, .src1 = a });
                }
                const dest = self.func.allocReg();
                try self.emit(.{
                    .op = .call,
                    .dest = dest,
                    .call_target = target,
                    .argc = @intCast(c.args.len),
                });
                return .{ .register = dest };
            },
            .variant_ctor => |vc| {
                if (std.mem.eql(u8, vc.variant_name, "Err")) {
                    const tag: v.ErrorTag = if (vc.args.len > 0) switch (vc.args[0].*) {
                        .str_lit => |s| v.ErrorTag.fromName(s),
                        else => .generic,
                    } else .generic;
                    const dest = self.func.allocReg();
                    try self.emit(.{ .op = .make_error, .dest = dest, .error_tag = tag });
                    return .{ .register = dest };
                }
                // Ok(payload) is identity.
                if (vc.args.len == 1) return self.lowerExpr(vc.args[0]);
                return .nil_const;
            },
            .try_expr => |inner| {
                const x = try self.lowerExpr(inner);
                const dest = self.func.allocReg();
                try self.emit(.{ .op = .try_unwrap, .dest = dest, .src1 = x });
                return .{ .register = dest };
            },
        }
    }
};
