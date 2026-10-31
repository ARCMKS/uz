const std = @import("std");

pub const Type = union(enum) {
    primitive: PrimType,
    named: []const u8,
};

pub const PrimType = enum { i8, i16, i32, i64, u8, u16, u32, u64, f32, f64, bool_, string, void };

pub const Param = struct {
    name: []const u8,
    is_mut: bool = false,
    type_ann: ?Type = null,
};

pub const FnDecl = struct {
    name: []const u8,
    params: []Param,
    ret_type: ?Type,
    body: *Block,
};

pub const VariantDecl = struct {
    name: []const u8,
    payload_types: []Type, // empty for unit variants
};

pub const TypeDecl = struct {
    name: []const u8,
    variants: []VariantDecl,
};

pub const Decl = union(enum) {
    fn_decl: FnDecl,
    type_decl: TypeDecl,
};

pub const Block = struct {
    stmts: []*Stmt,
};

pub const Stmt = union(enum) {
    let_stmt: struct {
        name: []const u8,
        is_mut: bool,
        type_ann: ?Type,
        init: *Expr,
    },
    return_stmt: struct { value: ?*Expr },
    if_stmt: struct {
        cond: *Expr,
        then_blk: *Block,
        else_blk: ?*Block,
    },
    while_stmt: struct { cond: *Expr, body: *Block },
    match_stmt: struct {
        scrutinee: *Expr,
        arms: []MatchArm,
    },
    assign_stmt: struct { target: *Expr, value: *Expr },
    expr_stmt: *Expr,
    block: *Block,
};

pub const MatchArm = struct {
    pattern: Pattern,
    body: *Stmt,
};

pub const Pattern = union(enum) {
    wildcard,
    bind: []const u8,
    int_lit: i64,
    str_lit: []const u8,
    bool_lit: bool,
    variant: struct {
        type_name: []const u8,
        variant_name: []const u8,
        subpatterns: []Pattern,
    },
};

pub const BinOp = enum { add, sub, mul, div, eq, ne, lt, le, gt, ge, and_, or_ };
pub const UnOp = enum { neg, not, deref, borrow };

pub const Expr = union(enum) {
    int_lit: i64,
    float_lit: f64,
    str_lit: []const u8,
    bool_lit: bool,
    ident: []const u8,
    binary: struct { op: BinOp, lhs: *Expr, rhs: *Expr },
    unary: struct { op: UnOp, operand: *Expr },
    call: struct { callee: []const u8, args: []*Expr },
    variant_ctor: struct { type_name: []const u8, variant_name: []const u8, args: []*Expr },
    try_expr: *Expr,
};

// Ast owns an arena; every nested allocation goes through it. Callers
// just call deinit() once.
pub const Ast = struct {
    arena: std.heap.ArenaAllocator,
    decls: std.ArrayList(Decl) = .empty,

    pub fn init(backing: std.mem.Allocator) Ast {
        return .{ .arena = std.heap.ArenaAllocator.init(backing) };
    }

    pub fn deinit(self: *Ast) void {
        self.arena.deinit();
    }

    pub fn allocator(self: *Ast) std.mem.Allocator {
        return self.arena.allocator();
    }

    pub fn addExpr(self: *Ast, e: Expr) !*Expr {
        const p = try self.allocator().create(Expr);
        p.* = e;
        return p;
    }

    pub fn addStmt(self: *Ast, s: Stmt) !*Stmt {
        const p = try self.allocator().create(Stmt);
        p.* = s;
        return p;
    }

    pub fn addBlock(self: *Ast, b: Block) !*Block {
        const p = try self.allocator().create(Block);
        p.* = b;
        return p;
    }
};