const std = @import("std");
const Span = @import("span.zig").Span;



pub const Token = struct {
    kind: Kind,
    span: Span,
    /// Borrowed slice of the source text (excluding quote delimiters
    /// for string literals). Preserved for parser compatibility.
    slice: []const u8 = "",
    int_val: i64 = 0,
    float_val: f64 = 0,

    pub const Kind = enum {
        // Literals
        int_lit, float_lit, string_lit, cstring_lit, ident,
        // Reserved words (§1.4)
        kw_fn, kw_let, kw_if, kw_else, kw_while, kw_for, kw_in,
        kw_return, kw_as, kw_true, kw_false,
        kw_ref, kw_rc, kw_mut, kw_const, kw_break, kw_continue,
        kw_type, kw_struct, kw_enum, kw_match, kw_using,
        kw_pub, kw_extern, kw_from,
        // Punctuation / operators (§1.8)
        lparen, rparen, lbrace, rbrace, lbracket, rbracket,
        semi, colon, comma, question,
        plus, minus, star, slash, amp, dot, bang,
        dot_dot, dot_dot_dot, arrow, fat_arrow,
        assign, eq_eq, bang_eq, lt, le, gt, ge,
        plus_eq, minus_eq, star_eq, slash_eq, and_and, or_or,
        // Special
        invalid, eof,
    };
};

pub const Lexer = struct {
    src: []const u8,
    file_id: u32,
    current: usize = 0,

    pub fn init(src: []const u8, file_id: u32) Lexer {
        return .{ .src = src, .file_id = file_id };
    }

    pub fn tokenize(self: *Lexer, allocator: std.mem.Allocator) !std.ArrayList(Token) {
        var tokens: std.ArrayList(Token) = .empty;
        errdefer tokens.deinit(allocator);

        while (true) {
            self.skipWhitespaceAndComments();
            if (self.current >= self.src.len) break;
            try tokens.append(allocator, self.nextToken());
        }
        try tokens.append(allocator, .{
            .kind = .eof,
            .span = Span.make(
                @intCast(self.src.len),
                @intCast(self.src.len),
                self.file_id,
            ),
        });
        return tokens;
    }

    fn nextToken(self: *Lexer) Token {
        const start = self.current;
        const c = self.src[self.current];

        // c-string must be checked before the identifier path.
        if (c == 'c' and self.current + 1 < self.src.len
            and self.src[self.current + 1] == '"')
        {
            return self.scanString(start, true);
        }
        if (isDigit(c)) return self.scanNumber(start);
        if (isAlpha(c) or c == '_') return self.scanIdentOrKeyword(start);
        if (c == '"') return self.scanString(start, false);

        self.current += 1;
        const one = Span.make(@intCast(start), @intCast(self.current), self.file_id);

        switch (c) {
            '(' => return .{ .kind = .lparen, .span = one, .slice = self.slice(start) },
            ')' => return .{ .kind = .rparen, .span = one, .slice = self.slice(start) },
            '{' => return .{ .kind = .lbrace, .span = one, .slice = self.slice(start) },
            '}' => return .{ .kind = .rbrace, .span = one, .slice = self.slice(start) },
            '[' => return .{ .kind = .lbracket, .span = one, .slice = self.slice(start) },
            ']' => return .{ .kind = .rbracket, .span = one, .slice = self.slice(start) },
            ';' => return .{ .kind = .semi, .span = one, .slice = self.slice(start) },
            ':' => return .{ .kind = .colon, .span = one, .slice = self.slice(start) },
            ',' => return .{ .kind = .comma, .span = one, .slice = self.slice(start) },
            '?' => return .{ .kind = .question, .span = one, .slice = self.slice(start) },

            '+' => {
                if (self.match('=')) return self.mk(.plus_eq, start);
                return self.mk(.plus, start);
            },
            '-' => {
                if (self.match('>')) return self.mk(.arrow, start);
                if (self.match('=')) return self.mk(.minus_eq, start);
                return self.mk(.minus, start);
            },
            '*' => {
                if (self.match('=')) return self.mk(.star_eq, start);
                return self.mk(.star, start);
            },
            '/' => {
                if (self.match('=')) return self.mk(.slash_eq, start);
                return self.mk(.slash, start);
            },
            '&' => {
                if (self.match('&')) return self.mk(.and_and, start);
                return self.mk(.amp, start);
            },
            '|' => {
                if (self.match('|')) return self.mk(.or_or, start);
                return self.mk(.invalid, start);
            },
            '!' => {
                if (self.match('=')) return self.mk(.bang_eq, start);
                return self.mk(.bang, start);
            },
            '=' => {
                if (self.match('>')) return self.mk(.fat_arrow, start);
                if (self.match('=')) return self.mk(.eq_eq, start);
                return self.mk(.assign, start);
            },
            '<' => {
                if (self.match('=')) return self.mk(.le, start);
                return self.mk(.lt, start);
            },
            '>' => {
                if (self.match('=')) return self.mk(.ge, start);
                return self.mk(.gt, start);
            },
            '.' => {
                if (self.match('.')) {
                    if (self.match('.')) return self.mk(.dot_dot_dot, start);
                    return self.mk(.dot_dot, start);
                }
                return self.mk(.dot, start);
            },
            else => return self.mk(.invalid, start),
        }
    }

    fn mk(self: *Lexer, kind: Token.Kind, start: usize) Token {
        return .{
            .kind = kind,
            .span = Span.make(@intCast(start), @intCast(self.current), self.file_id),
            .slice = self.src[start..self.current],
        };
    }

    fn slice(self: *Lexer, start: usize) []const u8 {
        return self.src[start..self.current];
    }

    fn scanNumber(self: *Lexer, start: usize) Token {
        // 0x / 0X / 0b / 0B
        if (self.src[self.current] == '0' and self.current + 1 < self.src.len) {
            const next = self.src[self.current + 1];
            if (next == 'x' or next == 'X') {
                self.current += 2;
                while (self.current < self.src.len and isHexDigit(self.src[self.current]))
                    self.current += 1;
                const text = self.src[start + 2 .. self.current];
                return .{
                    .kind = .int_lit,
                    .span = Span.make(@intCast(start), @intCast(self.current), self.file_id),
                    .slice = self.src[start..self.current],
                    .int_val = std.fmt.parseInt(i64, text, 16) catch 0,
                };
            }
            if (next == 'b' or next == 'B') {
                self.current += 2;
                while (self.current < self.src.len
                    and (self.src[self.current] == '0' or self.src[self.current] == '1'))
                    self.current += 1;
                const text = self.src[start + 2 .. self.current];
                return .{
                    .kind = .int_lit,
                    .span = Span.make(@intCast(start), @intCast(self.current), self.file_id),
                    .slice = self.src[start..self.current],
                    .int_val = std.fmt.parseInt(i64, text, 2) catch 0,
                };
            }
        }

        // Decimal or float
        var is_float = false;
        while (self.current < self.src.len) {
            const c = self.src[self.current];
            if (isDigit(c)) {
                self.current += 1;
            } else if (c == '.' and self.current + 1 < self.src.len
                and isDigit(self.src[self.current + 1]))
            {
                if (is_float) break;
                is_float = true;
                self.current += 1;
            } else break;
        }
        const text = self.src[start..self.current];
        const span = Span.make(@intCast(start), @intCast(self.current), self.file_id);
        if (is_float) {
            return .{
                .kind = .float_lit,
                .span = span,
                .slice = text,
                .float_val = std.fmt.parseFloat(f64, text) catch 0,
            };
        }
        return .{
            .kind = .int_lit,
            .span = span,
            .slice = text,
            .int_val = std.fmt.parseInt(i64, text, 10) catch 0,
        };
    }

    fn scanIdentOrKeyword(self: *Lexer, start: usize) Token {
        while (self.current < self.src.len and isAlnum(self.src[self.current]))
            self.current += 1;
        const text = self.src[start..self.current];
        const kind = keywordKind(text) orelse .ident;
        return .{
            .kind = kind,
            .span = Span.make(@intCast(start), @intCast(self.current), self.file_id),
            .slice = text,
        };
    }

    fn scanString(self: *Lexer, start: usize, is_c: bool) Token {
        if (is_c) self.current += 1; // skip 'c'
        self.current += 1;           // skip opening '"'
        // Per reference §1.7: the lexer does NOT honor `\"` for the
        // closing-quote scan. Scan to '"' or '\n', whichever first.
        while (self.current < self.src.len
            and self.src[self.current] != '"'
            and self.src[self.current] != '\n') : (self.current += 1)
        {}
        if (self.current < self.src.len and self.src[self.current] == '"')
            self.current += 1;

        // Inner content, without the quote delimiters.
        const inner_start = if (is_c) start + 2 else start + 1;
        const inner_end = if (self.current > inner_start
            and self.src[self.current - 1] == '"')
            self.current - 1
        else
            self.current;

        return .{
            .kind = if (is_c) .cstring_lit else .string_lit,
            .span = Span.make(@intCast(start), @intCast(self.current), self.file_id),
            .slice = self.src[inner_start..inner_end],
        };
    }

    fn match(self: *Lexer, c: u8) bool {
        if (self.current < self.src.len and self.src[self.current] == c) {
            self.current += 1;
            return true;
        }
        return false;
    }

    fn skipWhitespaceAndComments(self: *Lexer) void {
        while (self.current < self.src.len) {
            switch (self.src[self.current]) {
                ' ', '\t', '\r', '\n' => self.current += 1,
                '/' => {
                    if (self.current + 1 < self.src.len
                        and self.src[self.current + 1] == '/')
                    {
                        while (self.current < self.src.len
                            and self.src[self.current] != '\n')
                            self.current += 1;
                    } else break;
                },
                else => break,
            }
        }
    }
};

fn isDigit(c: u8) bool { return c >= '0' and c <= '9'; }
fn isHexDigit(c: u8) bool {
    return isDigit(c) or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}
fn isAlpha(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}
fn isAlnum(c: u8) bool { return isAlpha(c) or isDigit(c) or c == '_'; }

fn keywordKind(s: []const u8) ?Token.Kind {
    const eql = std.mem.eql;
    if (eql(u8, s, "fn")) return .kw_fn;
    if (eql(u8, s, "let")) return .kw_let;
    if (eql(u8, s, "if")) return .kw_if;
    if (eql(u8, s, "else")) return .kw_else;
    if (eql(u8, s, "while")) return .kw_while;
    if (eql(u8, s, "for")) return .kw_for;
    if (eql(u8, s, "in")) return .kw_in;
    if (eql(u8, s, "return")) return .kw_return;
    if (eql(u8, s, "as")) return .kw_as;
    if (eql(u8, s, "true")) return .kw_true;
    if (eql(u8, s, "false")) return .kw_false;
    if (eql(u8, s, "ref")) return .kw_ref;
    if (eql(u8, s, "rc")) return .kw_rc;
    if (eql(u8, s, "mut")) return .kw_mut;
    if (eql(u8, s, "const")) return .kw_const;
    if (eql(u8, s, "break")) return .kw_break;
    if (eql(u8, s, "continue")) return .kw_continue;
    if (eql(u8, s, "type")) return .kw_type;
    if (eql(u8, s, "struct")) return .kw_struct;
    if (eql(u8, s, "enum")) return .kw_enum;
    if (eql(u8, s, "match")) return .kw_match;
    if (eql(u8, s, "using")) return .kw_using;
    if (eql(u8, s, "pub")) return .kw_pub;
    if (eql(u8, s, "extern")) return .kw_extern;
    if (eql(u8, s, "from")) return .kw_from;
    return null;
}