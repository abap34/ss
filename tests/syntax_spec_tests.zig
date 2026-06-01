const std = @import("std");
const syntax = @import("syntax");
const ast = @import("ast");
const Type = @import("language_type").Type;

const testing = std.testing;

const ParsedProgram = struct {
    arena: std.heap.ArenaAllocator,
    program: syntax.Program,

    fn deinit(self: *ParsedProgram) void {
        self.program.deinit(self.arena.allocator());
        self.arena.deinit();
    }
};

fn parse(source: []const u8) !ParsedProgram {
    return try parseWithSourceName(source, "unit-test.ss");
}

fn parseWithSourceName(source: []const u8, source_name: []const u8) !ParsedProgram {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    errdefer arena.deinit();
    const program = try syntax.parseWithSourceName(arena.allocator(), source, source_name);
    return .{ .arena = arena, .program = program };
}

fn expectParseError(expected: anyerror, source: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var program = syntax.parseWithSourceName(arena.allocator(), source, "unit-test.ss") catch |err| {
        try testing.expectEqual(expected, err);
        const diagnostic = syntax.lastParseDiagnostic() orelse return error.MissingParseDiagnostic;
        try testing.expectEqual(expected, diagnostic.err);
        return;
    };
    defer program.deinit(arena.allocator());
    return error.ExpectedParseError;
}

fn expectCall(expr: ast.Expr, name: []const u8, arity: usize) !ast.CallExpr {
    switch (expr) {
        .call => |call| {
            try testing.expectEqualStrings(name, call.name);
            try testing.expectEqual(arity, call.args.items.len);
            return call;
        },
        else => return error.ExpectedCallExpr,
    }
}

fn expectNumber(expr: ast.Expr, expected: f32) !void {
    switch (expr) {
        .number => |actual| try testing.expectApproxEqAbs(expected, actual, 0.0001),
        else => return error.ExpectedNumberExpr,
    }
}

fn expectString(expr: ast.Expr, expected: []const u8) !void {
    switch (expr) {
        .string => |actual| try testing.expectEqualStrings(expected, actual),
        else => return error.ExpectedStringExpr,
    }
}

test "syntax spec: imports and pages preserve source order" {
    var parsed = try parse(
        \\// Leading trivia is not part of the AST.
        \\import core
        \\
        \\page Intro
        \\  title Hello
        \\end
        \\
        \\import "themes/default"; // comments may follow terminators
        \\
        \\page "Two Words"
        \\  title("Done");
        \\end
        \\
    );
    defer parsed.deinit();
    const program = &parsed.program;

    try testing.expectEqual(@as(usize, 2), program.imports.items.len);
    try testing.expectEqualStrings("core", program.imports.items[0].spec);
    try testing.expectEqualStrings("themes/default", program.imports.items[1].spec);
    try testing.expectEqual(@as(usize, 2), program.pages.items.len);
    try testing.expectEqualStrings("Intro", program.pages.items[0].name);
    try testing.expectEqualStrings("Two Words", program.pages.items[1].name);

    try testing.expectEqual(@as(usize, 4), program.top_level_items.items.len);
    try testing.expectEqual(@as(usize, 0), program.top_level_items.items[0].import);
    try testing.expectEqual(@as(usize, 0), program.top_level_items.items[1].page);
    try testing.expectEqual(@as(usize, 1), program.top_level_items.items[2].import);
    try testing.expectEqual(@as(usize, 1), program.top_level_items.items[3].page);
}

test "syntax spec: page name underscore generates an internal reserved name" {
    var first = try parseWithSourceName(
        \\page _
        \\  title First
        \\end
        \\
    , "first.ss");
    defer first.deinit();

    var second = try parseWithSourceName(
        \\page _
        \\  title Second
        \\end
        \\
    , "second.ss");
    defer second.deinit();

    try testing.expect(std.mem.startsWith(u8, first.program.pages.items[0].name, "#gen_"));
    try testing.expect(std.mem.startsWith(u8, second.program.pages.items[0].name, "#gen_"));
    try testing.expect(!std.mem.eql(u8, first.program.pages.items[0].name, second.program.pages.items[0].name));
}

test "syntax spec: explicit reserved page names are rejected" {
    try expectParseError(error.ReservedPageNamePrefix,
        \\page #generated
        \\  title Bad
        \\end
        \\
    );
}

test "syntax spec: function signatures enforce result value tags and trailing defaults" {
    var parsed = try parse(
        \\@host fn external_width(value: Number) -> Number
        \\
        \\fn choose(flag: Bool, fallback: String = "no") -> String
        \\  if flag
        \\    return "yes"
        \\  else
        \\    return fallback
        \\  end
        \\end
        \\
    );
    defer parsed.deinit();
    const program = &parsed.program;

    try testing.expectEqual(@as(usize, 2), program.functions.items.len);
    try testing.expectEqual(ast.FunctionDecl.Kind.function, program.functions.items[0].kind);
    try testing.expectEqualStrings("external_width", program.functions.items[0].name);
    try testing.expectEqual(@as(usize, 1), program.functions.items[0].annotations.items.len);
    try testing.expectEqualStrings("host", program.functions.items[0].annotations.items[0].name);
    try testing.expectEqual(@as(usize, 0), program.functions.items[0].statements.items.len);

    const choose = program.functions.items[1];
    try testing.expectEqualStrings("choose", choose.name);
    try testing.expectEqual(@as(usize, 2), choose.params.items.len);
    try testing.expectEqual(Type.boolean.tag, choose.params.items[0].ty.tag);
    try testing.expectEqual(Type.string.tag, choose.params.items[1].ty.tag);
    try testing.expect(choose.params.items[1].default_value != null);
}

test "syntax spec: non-host functions must return on at least one complete path" {
    try expectParseError(error.ExpectedReturn,
        \\fn bad() -> Number
        \\  let x = 1
        \\end
        \\
    );
}

test "syntax spec: user functions require result annotations" {
    try expectParseError(error.ExpectedTypeAnnotation,
        \\fn bad()
        \\  return
        \\end
        \\
    );
}

test "syntax spec: void functions may omit explicit return values" {
    var parsed = try parse(
        \\fn noop() -> Void
        \\  let x = 1
        \\end
        \\
        \\fn stop() -> Void
        \\  return
        \\end
        \\
    );
    defer parsed.deinit();

    const noop = parsed.program.functions.items[0];
    try testing.expectEqual(Type.Tag.void, noop.result_type.tag);
    try testing.expectEqual(@as(usize, 1), noop.statements.items.len);

    const stop = parsed.program.functions.items[1];
    try testing.expectEqual(Type.Tag.void, stop.result_type.tag);
    try testing.expectEqual(@as(usize, 1), stop.statements.items.len);
    switch (stop.statements.items[0].kind) {
        .return_void => {},
        else => return error.ExpectedReturnVoid,
    }
}

test "syntax spec: function types and lambdas are source syntax" {
    var parsed = try parse(
        \\fn make_label(text_value: String) -> Page -> Object
        \\  return (page_value: Page) |-> new(page_value, text_value, "body", "text")
        \\end
        \\
        \\fn use(callback: (Page -> Object) -> Document, pair: (Page, Document) -> Object, thunk: () -> Number) -> Number
        \\  return thunk()
        \\end
        \\
    );
    defer parsed.deinit();

    const make_label = parsed.program.functions.items[0];
    try testing.expectEqual(Type.Tag.function, make_label.result_type.tag);
    try testing.expectEqual(@as(usize, 1), make_label.result_type.fn_params.len);
    try testing.expectEqual(Type.Tag.page, make_label.result_type.fn_params[0].tag);
    try testing.expect(make_label.result_type.fn_result != null);
    try testing.expectEqual(Type.Tag.object, make_label.result_type.fn_result.?.tag);
    switch (make_label.statements.items[0].kind.return_expr) {
        .lambda => |lambda| {
            try testing.expectEqual(@as(usize, 1), lambda.params.items.len);
            try testing.expectEqual(Type.Tag.page, lambda.params.items[0].ty.tag);
        },
        else => return error.ExpectedLambdaExpr,
    }

    const use = parsed.program.functions.items[1];
    try testing.expectEqual(Type.Tag.function, use.params.items[0].ty.tag);
    try testing.expectEqual(Type.Tag.function, use.params.items[0].ty.fn_params[0].tag);
    try testing.expectEqual(Type.Tag.function, use.params.items[1].ty.tag);
    try testing.expectEqual(@as(usize, 2), use.params.items[1].ty.fn_params.len);
    try testing.expectEqual(Type.Tag.function, use.params.items[2].ty.tag);
    try testing.expectEqual(@as(usize, 0), use.params.items[2].ty.fn_params.len);
}

test "syntax spec: untyped value tag is not accepted as a surface type" {
    try expectParseError(error.InvalidTypeAnnotation,
        \\fn bad(f: Function) -> Number
        \\  return 1
        \\end
        \\
    );
}

test "syntax spec: bare user type names parse as object class annotations" {
    var parsed = try parse(
        \\fn keep(value: Text) -> Text
        \\  return value
        \\end
        \\
    );
    defer parsed.deinit();

    const keep = parsed.program.functions.items[0];
    try testing.expectEqual(Type.Tag.object, keep.params.items[0].ty.tag);
    try testing.expectEqualStrings("Text", keep.params.items[0].ty.class_name.?);
    try testing.expectEqual(Type.Tag.object, keep.result_type.tag);
    try testing.expectEqualStrings("Text", keep.result_type.class_name.?);
}

test "syntax spec: lambda expressions can be used as callees" {
    var parsed = try parse(
        \\page Lambda
        \\  let value = ((x: Number) |-> x + 1)(2)
        \\end
        \\
    );
    defer parsed.deinit();

    const expr = parsed.program.pages.items[0].statements.items[0].kind.let_binding.expr;
    switch (expr) {
        .apply => |apply| {
            try testing.expectEqual(@as(usize, 1), apply.args.items.len);
            switch (apply.callee.*) {
                .lambda => |lambda| {
                    try testing.expectEqual(@as(usize, 1), lambda.params.items.len);
                    try testing.expectEqual(Type.Tag.number, lambda.params.items[0].ty.tag);
                },
                else => return error.ExpectedLambdaExpr,
            }
        },
        else => return error.ExpectedApplyExpr,
    }
}

test "syntax spec: lambda body may start on a later line" {
    var parsed = try parse(
        \\page Lambda
        \\  let value = foreach(
        \\    pages(docctx()),
        \\    (page_value: Page)
        \\      |->
        \\        new(
        \\          page_value,
        \\          str(page_index(page_value)),
        \\          "body",
        \\          "text"
        \\        )
        \\  )
        \\end
        \\
    );
    defer parsed.deinit();

    const expr = parsed.program.pages.items[0].statements.items[0].kind.let_binding.expr;
    switch (expr.call.args.items[1]) {
        .lambda => |lambda| {
            try testing.expectEqual(@as(usize, 1), lambda.params.items.len);
            try testing.expectEqual(Type.Tag.page, lambda.params.items[0].ty.tag);
            switch (lambda.body.*) {
                .call => |call| try testing.expectEqualStrings("new", call.name),
                else => return error.ExpectedCallExpr,
            }
        },
        else => return error.ExpectedLambdaExpr,
    }
}

test "syntax spec: required parameters cannot follow defaulted parameters" {
    try expectParseError(error.RequiredParameterAfterDefault,
        \\fn bad(a: Number = 1, b: Number) -> Number
        \\  return a
        \\end
        \\
    );
}

test "syntax spec: expression parsing lowers operators to named primitive calls" {
    var parsed = try parse(
        \\page Expr
        \\  let value = 1 + 2 * -3
        \\  let text = "a" ++ "b" ++ "c"
        \\end
        \\
    );
    defer parsed.deinit();
    const program = &parsed.program;

    const numeric = program.pages.items[0].statements.items[0].kind.let_binding.expr;
    const add = try expectCall(numeric, "add", 2);
    try expectNumber(add.args.items[0], 1);
    const mul = try expectCall(add.args.items[1], "mul", 2);
    try expectNumber(mul.args.items[0], 2);
    const neg = try expectCall(mul.args.items[1], "neg", 1);
    try expectNumber(neg.args.items[0], 3);

    const text = program.pages.items[0].statements.items[1].kind.let_binding.expr;
    const outer_concat = try expectCall(text, "concat", 2);
    const inner_concat = try expectCall(outer_concat.args.items[0], "concat", 2);
    try expectString(inner_concat.args.items[0], "a");
    try expectString(inner_concat.args.items[1], "b");
    try expectString(outer_concat.args.items[1], "c");
}

test "syntax spec: call sugar is explicit about text-bearing and zero-argument calls" {
    var parsed = try parse(
        \\page Text
        \\  title Plain text with spaces
        \\  code <<
        \\first
        \\second
        \\>>
        \\  quote """
        \\hello
        \\"""
        \\end
        \\
    );
    defer parsed.deinit();
    const program = &parsed.program;

    const statements = program.pages.items[0].statements.items;
    const title = try expectCall(statements[0].kind.expr_stmt, "title", 1);
    try expectString(title.args.items[0], "Plain text with spaces");
    const code = try expectCall(statements[1].kind.expr_stmt, "code", 1);
    try expectString(code.args.items[0], "first\nsecond");
    const quote = try expectCall(statements[2].kind.expr_stmt, "quote", 1);
    try expectString(quote.args.items[0], "hello");

    try expectParseError(error.ZeroArgCallRequiresParens,
        \\page Bad
        \\  title
        \\end
        \\
    );
}

test "syntax spec: assignment syntax separates bindings, properties, and constraints" {
    var parsed = try parse(
        \\page Layout
        \\  let local = 42
        \\  ~ box.width == 100
        \\  ~ box.left == page.left + 10
        \\  ~ box.right == page.right - 20
        \\  box.left = "red"
        \\end
        \\
    );
    defer parsed.deinit();
    const program = &parsed.program;

    const statements = program.pages.items[0].statements.items;
    try testing.expectEqualStrings("local", statements[0].kind.let_binding.name);

    const width = statements[1].kind.constrain;
    try testing.expectEqual(.node, width.target.kind);
    try testing.expectEqualStrings("box", width.target.node_name.?);
    try testing.expectEqual(.right, width.target.anchor);
    try testing.expectEqual(.left, width.source.anchor);
    try expectNumber(width.offset.?, 100);

    const left = statements[2].kind.constrain;
    try testing.expectEqual(.left, left.target.anchor);
    try testing.expectEqual(.page, left.source.kind);
    try testing.expectEqual(.left, left.source.anchor);
    try expectNumber(left.offset.?, 10);

    const right = statements[3].kind.constrain;
    try testing.expectEqual(.right, right.target.anchor);
    try testing.expectEqual(.page, right.source.kind);
    const neg = try expectCall(right.offset.?, "neg", 1);
    try expectNumber(neg.args.items[0], 20);

    const property = try expectCall(statements[4].kind.expr_stmt, "set_prop", 3);
    switch (property.args.items[0]) {
        .ident => |name| try testing.expectEqualStrings("box", name),
        else => return error.ExpectedIdentifier,
    }
    try expectString(property.args.items[1], "left");
    try expectString(property.args.items[2], "red");

    try expectParseError(error.ExpectedConstraintMarker,
        \\page Bad
        \\  box.left == page.left + 10
        \\end
        \\
    );
}

test "syntax spec: member sugar lowers to primitive calls" {
    var parsed = try parse(
        \\page Members
        \\  let target = text("hello")
        \\  target.content = target.content ++ "!"
        \\  docctx().footer_text = "footer"
        \\  let color = target.text_color ?? "black"
        \\  let has_color = target.text_color?
        \\end
        \\
    );
    defer parsed.deinit();

    const statements = parsed.program.pages.items[0].statements.items;
    const content_set = try expectCall(statements[1].kind.expr_stmt, "set_content", 2);
    switch (content_set.args.items[0]) {
        .ident => |name| try testing.expectEqualStrings("target", name),
        else => return error.ExpectedIdentifier,
    }
    const concat = try expectCall(content_set.args.items[1], "concat", 2);
    _ = try expectCall(concat.args.items[0], "content", 1);
    try expectString(concat.args.items[1], "!");

    const doc_prop = try expectCall(statements[2].kind.expr_stmt, "set_prop", 3);
    _ = try expectCall(doc_prop.args.items[0], "docctx", 0);
    try expectString(doc_prop.args.items[1], "footer_text");
    try expectString(doc_prop.args.items[2], "footer");

    const prop = try expectCall(statements[3].kind.let_binding.expr, "prop", 3);
    try expectString(prop.args.items[1], "text_color");
    try expectString(prop.args.items[2], "black");

    const has_prop = try expectCall(statements[4].kind.let_binding.expr, "has_prop", 2);
    try expectString(has_prop.args.items[1], "text_color");
}

test "syntax spec: place is an ordinary identifier and bind is removed" {
    var parsed = try parse(
        \\page Placement
        \\  let place = 1
        \\  let local = place + 1
        \\end
        \\
    );
    defer parsed.deinit();

    const statements = parsed.program.pages.items[0].statements.items;
    try testing.expectEqualStrings("place", statements[0].kind.let_binding.name);
    const add = try expectCall(statements[1].kind.let_binding.expr, "add", 2);
    switch (add.args.items[0]) {
        .ident => |name| try testing.expectEqualStrings("place", name),
        else => return error.ExpectedIdentifier,
    }
    try expectNumber(add.args.items[1], 1);

    try expectParseError(error.BindRemoved,
        \\page Bad
        \\  bind local = text("bad")
        \\end
        \\
    );
}

test "syntax spec: bare assignment must say let and page dimensions are not targets" {
    try expectParseError(error.AssignmentRequiresLet,
        \\page Bad
        \\  local = 1
        \\end
        \\
    );

    try expectParseError(error.PageCannotBeConstraintTarget,
        \\page Bad
        \\  ~ page.width == 100
        \\end
        \\
    );
}

test "syntax spec: grammar keywords are rejected as identifiers" {
    try expectParseError(error.ReservedIdentifier,
        \\fn bad(let: Number) -> Number
        \\  return let
        \\end
        \\
    );
}
