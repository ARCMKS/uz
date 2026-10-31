const std = @import("std");
const lexer = @import("lexer.zig");
const ast = @import("ast.zig");

/// Explicit parser error set. Declaring this on `parseStmt` breaks the
/// mutual-inference cycle between `parseBlock ↔ parseStmt` and
/// `parseStmt ↔ parseMatch`.
const ParseError = error{
    UnexpectedEof,
    UnexpectedToken,
    ExpectedSemicolon,
    UnexpectedPattern,
    UnexpectedCallTarget,
    UnexpectedFieldAccess,
    OutOfMemory,
};

const BP = struct { left: u8, right: u8 };

pub const Parser = struct {
    tokens: []const lexer.Token,
    cursor: usize = 0,
    out: *ast.Ast,

    pub fn init(out: *ast.Ast, tokens: []const lexer.Token) Parser {
        return .{ .tokens = tokens, .out = out };
    }

    pub fn parseProgram(self: *Parser) !void {
        while (self.peekKind() != .eof) {
            const d = try self.parseDecl();
            try self.out.decls.append(self.out.allocator(), d);
        }
    }

    fn parseDecl(self: *Parser) !ast.Decl {
        return switch (self.peekKind()) {
            .kw_fn => .{ .fn_decl = try self.parseFnDecl() },
            .kw_type => .{ .type_decl = try self.parseTypeDecl() },
            else => error.ExpectedDeclaration,
        };
    }

    fn parseFnDecl(self: *Parser) !ast.FnDecl {
        _ = try self.expect(.kw_fn);
        const name = (try self.expect(.ident)).slice;

        _ = try self.expect(.lparen);
        var params = std.ArrayList(ast.Param).empty;
        if (self.peekKind() != .rparen) {
            while (true) {
                const p = try self.parseParam();
                try params.append(self.out.allocator(), p);
                if (self.peekKind() != .comma) break;
                _ = self.advance();
            }
        }
        _ = try self.expect(.rparen);

        var ret_type: ?ast.Type = null;
        if (self.peekKind() == .colon) {
            _ = self.advance();
            ret_type = try self.parseType();
        }

        const body = try self.parseBlock();
        return .{
            .name = name,
            .params = try params.toOwnedSlice(self.out.allocator()),
            .ret_type = ret_type,
            .body = body,
        };
    }

    fn parseParam(self: *Parser) !ast.Param {
        var is_mut = false;
        if (self.peekKind() == .kw_mut) {
            _ = self.advance();
            is_mut = true;
        }
        const name = (try self.expect(.ident)).slice;
        var type_ann: ?ast.Type = null;
        if (self.peekKind() == .colon) {
            _ = self.advance();
            type_ann = try self.parseType();
        }
        return .{ .name = name, .is_mut = is_mut, .type_ann = type_ann };
    }

    fn parseTypeDecl(self: *Parser) !ast.TypeDecl {
        _ = try self.expect(.kw_type);
        const name = (try self.expect(.ident)).slice;
        _ = try self.expect(.assign);
        _ = try self.expect(.kw_enum);
        _ = try self.expect(.lbrace);

        var variants = std.ArrayList(ast.VariantDecl).empty;
        while (self.peekKind() != .rbrace and self.peekKind() != .eof) {
            const vname = (try self.expect(.ident)).slice;
            var payload = std.ArrayList(ast.Type).empty;
            if (self.peekKind() == .lparen) {
                _ = self.advance();
                while (true) {
                    try payload.append(self.out.allocator(), try self.parseType());
                    if (self.peekKind() != .comma) break;
                    _ = self.advance();
                }
                _ = try self.expect(.rparen);
            }
            try variants.append(self.out.allocator(), .{
                .name = vname,
                .payload_types = try payload.toOwnedSlice(self.out.allocator()),
            });
            if (self.peekKind() == .comma) _ = self.advance();
        }
        _ = try self.expect(.rbrace);
        return .{ .name = name, .variants = try variants.toOwnedSlice(self.out.allocator()) };
    }

    /// Fix 2: explicit switch on primitive names instead of the
    /// `@typeInfo(...).@"enum".fields` reflection API, which changed in 0.17.
    fn parseType(self: *Parser) !ast.Type {
        const tok = self.advance() orelse return error.UnexpectedEof;
        if (tok.kind != .ident) return error.UnexpectedToken;
        const name = tok.slice;

        const eql = std.mem.eql;
        if (eql(u8, name, "i8"))     return .{ .primitive = .i8 };
        if (eql(u8, name, "i16"))    return .{ .primitive = .i16 };
        if (eql(u8, name, "i32"))    return .{ .primitive = .i32 };
        if (eql(u8, name, "i64"))    return .{ .primitive = .i64 };
        if (eql(u8, name, "u8"))     return .{ .primitive = .u8 };
        if (eql(u8, name, "u16"))    return .{ .primitive = .u16 };
        if (eql(u8, name, "u32"))    return .{ .primitive = .u32 };
        if (eql(u8, name, "u64"))    return .{ .primitive = .u64 };
        if (eql(u8, name, "f32"))    return .{ .primitive = .f32 };
        if (eql(u8, name, "f64"))    return .{ .primitive = .f64 };
        if (eql(u8, name, "bool"))   return .{ .primitive = .bool_ };
        if (eql(u8, name, "string")) return .{ .primitive = .string };
        if (eql(u8, name, "void"))   return .{ .primitive = .void };
        return .{ .named = name };
    }

    fn parseBlock(self: *Parser) !*ast.Block {
        _ = try self.expect(.lbrace);
        var stmts = std.ArrayList(*ast.Stmt).empty;
        while (self.peekKind() != .rbrace and self.peekKind() != .eof) {
            try stmts.append(self.out.allocator(), try self.parseStmt());
        }
        _ = try self.expect(.rbrace);
        return try self.out.addBlock(.{ .stmts = try stmts.toOwnedSlice(self.out.allocator()) });
    }

    /// Fix 3: explicit error set on the hub of the recursive call graph.
    fn parseStmt(self: *Parser) ParseError!*ast.Stmt {
        return switch (self.peekKind()) {
            .kw_let => self.parseLet(),
            .kw_return => self.parseReturn(),
            .kw_if => self.parseIf(),
            .kw_while => self.parseWhile(),
            .kw_match => self.parseMatch(),
            .lbrace => blk: {
                const b = try self.parseBlock();
                break :blk try self.out.addStmt(.{ .block = b });
            },
            else => self.parseExprOrAssign(),
        };
    }

    fn parseLet(self: *Parser) !*ast.Stmt {
        _ = try self.expect(.kw_let);
        var is_mut = false;
        if (self.peekKind() == .kw_mut) {
            _ = self.advance();
            is_mut = true;
        }
        const name = (try self.expect(.ident)).slice;
        var type_ann: ?ast.Type = null;
        if (self.peekKind() == .colon) {
            _ = self.advance();
            type_ann = try self.parseType();
        }
        _ = try self.expect(.assign);
        const init_expr = try self.parseExpr(0); // Fix 1: was `init`
        try self.endStatement();
        return try self.out.addStmt(.{ .let_stmt = .{
            .name = name, .is_mut = is_mut, .type_ann = type_ann, .init = init_expr,
        } });
    }

    fn parseReturn(self: *Parser) !*ast.Stmt {
        _ = try self.expect(.kw_return);
        var value: ?*ast.Expr = null;
        if (!isTerminator(self.peekKind())) value = try self.parseExpr(0);
        try self.endStatement();
        return try self.out.addStmt(.{ .return_stmt = .{ .value = value } });
    }

    fn parseIf(self: *Parser) !*ast.Stmt {
        _ = try self.expect(.kw_if);
        _ = try self.expect(.lparen);
        const cond = try self.parseExpr(0);
        _ = try self.expect(.rparen);
        const then_blk = try self.parseBlock();
        var else_blk: ?*ast.Block = null;
        if (self.peekKind() == .kw_else) {
            _ = self.advance();
            else_blk = try self.parseBlock();
        }
        return try self.out.addStmt(.{ .if_stmt = .{
            .cond = cond, .then_blk = then_blk, .else_blk = else_blk,
        } });
    }

    fn parseWhile(self: *Parser) !*ast.Stmt {
        _ = try self.expect(.kw_while);
        _ = try self.expect(.lparen);
        const cond = try self.parseExpr(0);
        _ = try self.expect(.rparen);
        const body = try self.parseBlock();
        return try self.out.addStmt(.{ .while_stmt = .{ .cond = cond, .body = body } });
    }

    fn parseMatch(self: *Parser) !*ast.Stmt {
        _ = try self.expect(.kw_match);
        const scrutinee = try self.parseExpr(0);
        _ = try self.expect(.lbrace);

        var arms = std.ArrayList(ast.MatchArm).empty;
        while (self.peekKind() != .rbrace and self.peekKind() != .eof) {
            const pat = try self.parsePattern();
            _ = try self.expect(.fat_arrow);
            const body = try self.parseStmt();
            try arms.append(self.out.allocator(), .{ .pattern = pat, .body = body });
            if (self.peekKind() == .comma or self.peekKind() == .semi) _ = self.advance();
        }
        _ = try self.expect(.rbrace);
        return try self.out.addStmt(.{ .match_stmt = .{
            .scrutinee = scrutinee,
            .arms = try arms.toOwnedSlice(self.out.allocator()),
        } });
    }

    fn parsePattern(self: *Parser) !ast.Pattern {
        const tok = self.advance() orelse return error.UnexpectedEof;
        switch (tok.kind) {
            .ident => {
                if (std.mem.eql(u8, tok.slice, "_")) return .wildcard;
                if (self.peekKind() == .dot) {
                    _ = self.advance();
                    const vname = (try self.expect(.ident)).slice;
                    var subs = std.ArrayList(ast.Pattern).empty;
                    if (self.peekKind() == .lparen) {
                        _ = self.advance();
                        while (self.peekKind() != .rparen) {
                            try subs.append(self.out.allocator(), try self.parsePattern());
                            if (self.peekKind() != .comma) break;
                            _ = self.advance();
                        }
                        _ = try self.expect(.rparen);
                    }
                    return .{ .variant = .{
                        .type_name = tok.slice,
                        .variant_name = vname,
                        .subpatterns = try subs.toOwnedSlice(self.out.allocator()),
                    } };
                }
                return .{ .bind = tok.slice };
            },
            .int_lit => return .{ .int_lit = tok.int_val },
            .string_lit => return .{ .str_lit = tok.slice },
            .kw_true => return .{ .bool_lit = true },
            .kw_false => return .{ .bool_lit = false },
            else => return error.UnexpectedPattern,
        }
    }

    fn parseExprOrAssign(self: *Parser) !*ast.Stmt {
        const left = try self.parseExpr(0);
        if (self.peekKind() == .assign) {
            _ = self.advance();
            const value = try self.parseExpr(0);
            try self.endStatement();
            return try self.out.addStmt(.{ .assign_stmt = .{ .target = left, .value = value } });
        }
        try self.endStatement();
        return try self.out.addStmt(.{ .expr_stmt = left });
    }

    fn parseExpr(self: *Parser, min_bp: u8) !*ast.Expr {
        const tok = self.advance() orelse return error.UnexpectedEof;
        var left: *ast.Expr = switch (tok.kind) {
            .int_lit => try self.out.addExpr(.{ .int_lit = tok.int_val }),
            .float_lit => try self.out.addExpr(.{ .float_lit = tok.float_val }),
            .string_lit => try self.out.addExpr(.{ .str_lit = tok.slice }),
            .kw_true => try self.out.addExpr(.{ .bool_lit = true }),
            .kw_false => try self.out.addExpr(.{ .bool_lit = false }),
            .ident => try self.out.addExpr(.{ .ident = tok.slice }),
            .lparen => blk: {
                const inner = try self.parseExpr(0);
                _ = try self.expect(.rparen);
                break :blk inner;
            },
            .minus => blk: {
                const operand = try self.parseExpr(15);
                break :blk try self.out.addExpr(.{ .unary = .{ .op = .neg, .operand = operand } });
            },
            .bang => blk: {
                const operand = try self.parseExpr(15);
                break :blk try self.out.addExpr(.{ .unary = .{ .op = .not, .operand = operand } });
            },
            else => return error.UnexpectedToken,
        };

        while (true) {
            const next = self.peekKind();
            const bp = infixBp(next) orelse break;
            if (bp.left < min_bp) break;
            _ = self.advance();

            if (next == .lparen) {
                // Call: left must be a bare identifier.
                const callee = switch (left.*) {
                    .ident => |name| name,
                    else => return error.UnexpectedCallTarget,
                };
                var args = std.ArrayList(*ast.Expr).empty;
                if (self.peekKind() != .rparen) {
                    while (true) {
                        try args.append(self.out.allocator(), try self.parseExpr(0));
                        if (self.peekKind() != .comma) break;
                        _ = self.advance();
                    }
                }
                _ = try self.expect(.rparen);
                left = try self.out.addExpr(.{ .call = .{
                    .callee = callee,
                    .args = try args.toOwnedSlice(self.out.allocator()),
                } });
                continue;
            }

            if (next == .dot) {
                // Type.Variant or Type.Variant(args)
                const type_name = switch (left.*) {
                    .ident => |name| name,
                    else => return error.UnexpectedFieldAccess,
                };
                const vname = (try self.expect(.ident)).slice;
                var args = std.ArrayList(*ast.Expr).empty;
                if (self.peekKind() == .lparen) {
                    _ = self.advance();
                    while (self.peekKind() != .rparen) {
                        try args.append(self.out.allocator(), try self.parseExpr(0));
                        if (self.peekKind() != .comma) break;
                        _ = self.advance();
                    }
                    _ = try self.expect(.rparen);
                }
                left = try self.out.addExpr(.{ .variant_ctor = .{
                    .type_name = type_name,
                    .variant_name = vname,
                    .args = try args.toOwnedSlice(self.out.allocator()),
                } });
                continue;
            }

            if (next == .question) {
                left = try self.out.addExpr(.{ .try_expr = left });
                continue;
            }

            const rhs = try self.parseExpr(bp.right);
            const op: ast.BinOp = switch (next) {
                .or_or => .or_, .and_and => .and_,
                .eq_eq => .eq, .bang_eq => .ne,
                .lt => .lt, .le => .le, .gt => .gt, .ge => .ge,
                .plus => .add, .minus => .sub,
                .star => .mul, .slash => .div,
                else => unreachable,
            };
            left = try self.out.addExpr(.{ .binary = .{ .op = op, .lhs = left, .rhs = rhs } });
        }
        return left;
    }

    fn infixBp(k: lexer.Token.Kind) ?BP {
        return switch (k) {
            .or_or => .{ .left = 1, .right = 2 },
            .and_and => .{ .left = 3, .right = 4 },
            .eq_eq, .bang_eq => .{ .left = 5, .right = 6 },
            .lt, .le, .gt, .ge => .{ .left = 7, .right = 8 },
            .plus, .minus => .{ .left = 9, .right = 10 },
            .star, .slash => .{ .left = 11, .right = 12 },
            .lparen => .{ .left = 13, .right = 14 },
            .dot => .{ .left = 15, .right = 16 },
            .question => .{ .left = 17, .right = 18 },
            else => null,
        };
    }

    fn isTerminator(k: lexer.Token.Kind) bool {
        return k == .semi or k == .rbrace or k == .eof;
    }

    fn endStatement(self: *Parser) !void {
        switch (self.peekKind()) {
            .semi => _ = self.advance(),
            .rbrace, .eof => {},
            else => return error.ExpectedSemicolon,
        }
    }

    fn peekKind(self: *Parser) lexer.Token.Kind {
        if (self.cursor >= self.tokens.len) return .eof;
        return self.tokens[self.cursor].kind;
    }

    fn advance(self: *Parser) ?lexer.Token {
        if (self.cursor >= self.tokens.len) return null;
        const t = self.tokens[self.cursor];
        self.cursor += 1;
        return t;
    }

    fn expect(self: *Parser, k: lexer.Token.Kind) !lexer.Token {
        const t = self.advance() orelse return error.UnexpectedEof;
        if (t.kind != k) return error.UnexpectedToken;
        return t;
    }
};