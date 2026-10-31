const std = @import("std");
const lexer_mod = @import("lexer.zig");
const smap_mod = @import("source_map.zig");
const diag_mod = @import("diagnostics.zig");
const parser_mod = @import("parser.zig");
const ast_mod = @import("ast.zig");
const ir_mod = @import("ir.zig");
const lower_mod = @import("lower.zig");

const source =
    \\fn main(): i64 {
    \\    let x = (3 + 4) * 2;
    \\    if (x == 14) {
    \\        return x;
    \\    } else {
    \\        return 0;
    \\    }
    \\}
    \\
    \\type IntResult = enum { Ok(i64), Err(string) }
    \\
    \\fn half(n: i64): IntResult {
    \\    if (n < 0) {
    \\        return IntResult.Err("negative");
    \\    }
    \\    return IntResult.Ok(n / 2);
    \\}
    \\
    \\fn run(): i64 {
    \\    let r = half(20);
    \\    match r {
    \\        IntResult.Ok(v) => { return v; },
    \\        IntResult.Err(_) => { return -1; }
    \\    }
    \\}
;

pub fn main(init: std.process.Init) !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // file source-map handling
    var smap = try smap_mod.SourceMap.init(allocator);
    defer smap.deinit();
    const file_id = try smap.add("demo.manu", source);
    std.debug.print("Registered demo.manu as file_id={d}\n", .{file_id});

    var diag = diag_mod.DiagnosticBag.init(allocator);
    defer diag.deinit();

    // Lexer
    var lex = lexer_mod.Lexer.init(source, file_id);
    var tokens = try lex.tokenize(allocator);
    defer tokens.deinit(allocator);
    std.debug.print("Lexed {d} tokens\n", .{tokens.items.len});

    // Report any invalid tokens as diagnostics with source excerpts.
    for (tokens.items) |tok| {
        if (tok.kind == .invalid) {
            var buf: [64]u8 = undefined;
            const n = smap.spanText(tok.span, &buf);
            try diag.report(.err, tok.span, "invalid token '{s}'", .{buf[0..n]});
        }
    }

    // parser
    var ast = ast_mod.Ast.init(allocator);
    defer ast.deinit();
    var p = parser_mod.Parser.init(&ast, tokens.items);
    p.parseProgram() catch |err| {
        const eof_span = tokens.items[tokens.items.len - 1].span;
        try diag.report(.err, eof_span, "parse error: {s}", .{@errorName(err)});
    };
    std.debug.print("Parsed {d} declarations\n", .{ast.decls.items.len});

    if (diag.hasErrors()) {
        var stderr_buffer: [4096]u8 = undefined;
        var stderr_writer = std.Io.File.stderr().writerStreaming(
            init.io,
            &stderr_buffer,
        );
    
        const stderr = &stderr_writer.interface;
    
        stderr.print("--- diagnostics ---\n", .{}) catch {};
        diag.flush(&smap, stderr, true);
    
        stderr.flush() catch {};
        std.process.exit(1);
    }

    var fn_ir = ir_mod.FunctionIR{};
    defer fn_ir.deinit(allocator);
    {
        var low = try lower_mod.Lowerer.init(allocator, &ast, &fn_ir);
        defer low.deinit();
        try low.lowerProgram(ast.root);
        // Append return
        const block = &fn_ir.blocks.items[0];
        try block.instructions.append(allocator, .{ .op = .return_val, .src1 = .nil_const });
    }
}

test { std.testing.refAllDecls(@This()); }