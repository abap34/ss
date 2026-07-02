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

const ParsedRecoveringProgram = struct {
    arena: std.heap.ArenaAllocator,
    result: syntax.ParseResult,

    fn deinit(self: *ParsedRecoveringProgram) void {
        self.result.deinit(self.arena.allocator());
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

fn parseRecovering(source: []const u8) !ParsedRecoveringProgram {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    errdefer arena.deinit();
    const result = try syntax.parseRecoveringWithSourceName(arena.allocator(), source, "unit-test.ss");
    return .{ .arena = arena, .result = result };
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

fn expectParseErrorAt(expected: anyerror, source: []const u8, expected_start: usize) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var program = syntax.parseWithSourceName(arena.allocator(), source, "unit-test.ss") catch |err| {
        try testing.expectEqual(expected, err);
        const diagnostic = syntax.lastParseDiagnostic() orelse return error.MissingParseDiagnostic;
        try testing.expectEqual(expected, diagnostic.err);
        try testing.expectEqual(expected_start, diagnostic.span.start);
        return;
    };
    defer program.deinit(arena.allocator());
    return error.ExpectedParseError;
}

fn expectParseErrorSpan(expected: anyerror, source: []const u8, expected_start: usize, expected_end: usize) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var program = syntax.parseWithSourceName(arena.allocator(), source, "unit-test.ss") catch |err| {
        try testing.expectEqual(expected, err);
        const diagnostic = syntax.lastParseDiagnostic() orelse return error.MissingParseDiagnostic;
        try testing.expectEqual(expected, diagnostic.err);
        try testing.expectEqual(expected_start, diagnostic.span.start);
        try testing.expectEqual(expected_end, diagnostic.span.end);
        return;
    };
    defer program.deinit(arena.allocator());
    return error.ExpectedParseError;
}

fn expectCall(expr: ast.Expr, name: []const u8, arity: usize) !ast.CallExpr {
    switch (expr) {
        .call => |call| {
            try testing.expectEqualStrings(name, call.callee.name);
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
        .string => |actual| try testing.expectEqualStrings(expected, actual.text),
        else => return error.ExpectedStringExpr,
    }
}

fn expectBoolean(expr: ast.Expr, expected: bool) !void {
    switch (expr) {
        .boolean => |actual| try testing.expectEqual(expected, actual),
        else => return error.ExpectedBooleanExpr,
    }
}

fn expectColor(expr: ast.Expr, expected: []const u8) !void {
    switch (expr) {
        .color => |actual| try testing.expectEqualStrings(expected, actual),
        else => return error.ExpectedColorExpr,
    }
}

fn expectNone(expr: ast.Expr) !void {
    switch (expr) {
        .none => {},
        else => return error.ExpectedNoneExpr,
    }
}

fn expectMember(expr: ast.Expr, name: []const u8) !ast.MemberExpr {
    switch (expr) {
        .member => |member| {
            try testing.expectEqualStrings(name, member.name);
            return member;
        },
        else => return error.ExpectedMemberExpr,
    }
}

fn expectRecordUpdate(expr: ast.Expr, field_count: usize) !ast.RecordUpdateExpr {
    switch (expr) {
        .record_update => |update| {
            try testing.expectEqual(field_count, update.fields.items.len);
            return update;
        },
        else => return error.ExpectedRecordUpdateExpr,
    }
}

fn expectPath(path: []const ast.RecordPathSegment, expected: []const []const u8) !void {
    try testing.expectEqual(expected.len, path.len);
    for (expected, 0..) |segment, index| {
        try testing.expectEqualStrings(segment, path[index].name);
        try testing.expect(path[index].span.end > path[index].span.start);
    }
}

fn expectImportMode(import_decl: ast.ImportDecl, expected_alias: ?[]const u8, expected_unqualified: bool) !void {
    if (expected_alias) |alias| {
        try testing.expect(import_decl.mode.alias != null);
        try testing.expectEqualStrings(alias, import_decl.mode.alias.?);
    } else {
        try testing.expect(import_decl.mode.alias == null);
    }
    try testing.expectEqual(expected_unqualified, import_decl.mode.unqualified);
}

fn expectSpanText(source: []const u8, span: ast.Span, expected: []const u8) !void {
    try testing.expect(span.start <= span.end);
    try testing.expect(span.end <= source.len);
    try testing.expectEqualStrings(expected, source[span.start..span.end]);
}

test "syntax spec: imports and pages preserve source order" {
    const source_text =
        \\// Leading trivia is not part of the AST.
        \\import core
        \\import "themes/default"; // comments may follow terminators
        \\
        \\document
        \\  let deck_title = "Intro"
        \\end
        \\
        \\page Intro
        \\  title Hello
        \\end
        \\
        \\page "Two Words"
        \\  title("Done");
        \\end
        \\
    ;
    var parsed = try parse(source_text);
    defer parsed.deinit();
    const program = &parsed.program;

    try testing.expectEqual(@as(usize, 2), program.imports.items.len);
    try testing.expectEqualStrings("core", program.imports.items[0].spec);
    try testing.expectEqualStrings("themes/default", program.imports.items[1].spec);
    try expectSpanText(source_text, program.imports.items[0].spec_span, "core");
    try expectSpanText(source_text, program.imports.items[1].spec_span, "themes/default");
    try testing.expectEqual(@as(usize, 1), program.document_blocks.items.len);
    try testing.expectEqual(@as(usize, 1), program.document_statements.items.len);
    try testing.expectEqual(@as(usize, 0), program.document_blocks.items[0].statement_start);
    try testing.expectEqual(@as(usize, 1), program.document_blocks.items[0].statement_count);
    try testing.expectEqual(@as(usize, 2), program.pages.items.len);
    try testing.expectEqualStrings("Intro", program.pages.items[0].name);
    try testing.expectEqualStrings("Two Words", program.pages.items[1].name);

    try testing.expectEqual(@as(usize, 5), program.top_level_items.items.len);
    try testing.expectEqual(@as(usize, 0), program.top_level_items.items[0].import);
    try testing.expectEqual(@as(usize, 1), program.top_level_items.items[1].import);
    try testing.expectEqual(@as(usize, 0), program.top_level_items.items[2].document);
    try testing.expectEqual(@as(usize, 0), program.top_level_items.items[3].page);
    try testing.expectEqual(@as(usize, 1), program.top_level_items.items[4].page);
}

test "syntax spec: import modes are explicit in the AST" {
    const source_text =
        \\import std:themes/default
        \\import std:themes/default as base
        \\import std:themes/default as *
        \\import seminar-theme as *
        \\import seminar-theme as seminar_theme
        \\
        \\page ok
        \\end
        \\
    ;
    var parsed = try parse(source_text);
    defer parsed.deinit();

    try testing.expectEqual(@as(usize, 5), parsed.program.imports.items.len);
    try expectImportMode(parsed.program.imports.items[0], "default", true);
    try expectImportMode(parsed.program.imports.items[1], "base", false);
    try expectImportMode(parsed.program.imports.items[2], null, true);
    try expectImportMode(parsed.program.imports.items[3], null, true);
    try expectImportMode(parsed.program.imports.items[4], "seminar_theme", false);
    try expectSpanText(source_text, parsed.program.imports.items[0].spec_span, "std:themes/default");
    try expectSpanText(source_text, parsed.program.imports.items[1].spec_span, "std:themes/default");
    try expectSpanText(source_text, parsed.program.imports.items[1].alias_span.?, "base");
    try testing.expect(parsed.program.imports.items[0].alias_span == null);
    try testing.expect(parsed.program.imports.items[2].alias_span == null);
    try testing.expect(parsed.program.imports.items[3].alias_span == null);
    try expectSpanText(source_text, parsed.program.imports.items[4].alias_span.?, "seminar_theme");
}

test "syntax spec: qualified callable names preserve source spans" {
    const source_text =
        \\page ok
        \\  let value = theme::text("hi")
        \\end
        \\
    ;
    var parsed = try parse(source_text);
    defer parsed.deinit();

    const stmt = parsed.program.pages.items[0].statements.items[0];
    const expr = switch (stmt.kind) {
        .let_binding => |binding| binding.expr,
        else => return error.ExpectedLetBinding,
    };
    const call = try expectCall(expr, "text", 1);

    try testing.expect(call.callee.qualifier != null);
    try testing.expectEqualStrings("theme", call.callee.qualifier.?);
    try expectSpanText(source_text, call.callee.qualifier_span.?, "theme");
    try expectSpanText(source_text, call.callee.name_span.?, "text");
    try expectSpanText(source_text, call.callee.span.?, "theme::text");
}

test "syntax spec: declaration names preserve source spans" {
    const source_text =
        \\type Mode = light | dark
        \\type Widget = object {
        \\  title: String
        \\}
        \\record Theme {
        \\  accent: Color
        \\}
        \\const accent: Color = c"#336699"
        \\fn helper(value: String) -> Void = text(value)
        \\page First
        \\end
        \\
    ;
    var parsed = try parse(source_text);
    defer parsed.deinit();

    try expectSpanText(source_text, parsed.program.types.items[0].name_span.?, "Mode");
    try expectSpanText(source_text, parsed.program.objects.items[0].name_span.?, "Widget");
    try expectSpanText(source_text, parsed.program.objects.items[0].fields.items[0].name_span.?, "title");
    try expectSpanText(source_text, parsed.program.records.items[0].name_span.?, "Theme");
    try expectSpanText(source_text, parsed.program.records.items[0].fields.items[0].name_span.?, "accent");
    try expectSpanText(source_text, parsed.program.constants.items[0].name_span.?, "accent");
    try expectSpanText(source_text, parsed.program.functions.items[0].name_span.?, "helper");
    try expectSpanText(source_text, parsed.program.pages.items[0].name_span.?, "First");
}

test "syntax spec: let bindings keep optional type annotations" {
    const source_text =
        \\page ok
        \\  let count: Number = 1
        \\end
        \\
    ;
    var parsed = try parse(source_text);
    defer parsed.deinit();

    const binding = parsed.program.pages.items[0].statements.items[0].kind.let_binding;
    try testing.expectEqualStrings("count", binding.name);
    try expectSpanText(source_text, binding.name_span.?, "count");
    const annotation = binding.type_annotation orelse return error.ExpectedTypeAnnotation;
    try testing.expectEqual(Type.Kind.number, annotation.kind);
}

test "syntax spec: imports must precede other top-level items" {
    try expectParseError(error.ImportMustBeAtTop,
        \\page ok
        \\end
        \\
        \\import std:themes/default as *
        \\
    );
}

test "syntax spec: default import aliases must be identifiers" {
    try expectParseError(error.InvalidImportAlias,
        \\import seminar-theme
        \\
        \\page ok
        \\end
        \\
    );
}

test "syntax spec: import specs omit ss extension" {
    try expectParseError(error.InvalidImportSpec,
        \\import seminar-theme.ss as *
        \\
        \\page ok
        \\end
        \\
    );
}

test "syntax spec: as and with are reserved" {
    try expectParseError(error.ReservedIdentifier,
        \\fn as() -> Void
        \\  return
        \\end
        \\
    );

    try expectParseError(error.ReservedIdentifier,
        \\page ok
        \\  let as = 1
        \\end
        \\
    );

    try expectParseError(error.ReservedIdentifier,
        \\page ok
        \\  let with = 1
        \\end
        \\
    );
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

test "syntax spec: function signatures preserve types and trailing defaults" {
    var parsed = try parse(
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

    try testing.expectEqual(@as(usize, 1), program.functions.items.len);
    const choose = program.functions.items[0];
    try testing.expectEqualStrings("choose", choose.name);
    try testing.expectEqual(@as(usize, 2), choose.params.items.len);
    try testing.expectEqual(Type.boolean.kind, choose.params.items[0].ty.kind);
    try testing.expectEqual(Type.string.kind, choose.params.items[1].ty.kind);
    try testing.expect(choose.params.items[1].default_value != null);
}

test "syntax spec: functions can use expression bodies" {
    var parsed = try parse(
        \\fn square(x: Number) -> Number = x * x
        \\
        \\fn remember() -> Void =
        \\  set_prop(
        \\    docctx(),
        \\    "footer_text",
        \\    "remembered",
        \\  )
        \\
        \\fn/! badge(text_value: String) -> Object = text(text_value)
        \\
    );
    defer parsed.deinit();

    try testing.expectEqual(@as(usize, 4), parsed.program.functions.items.len);

    const square = parsed.program.functions.items[0];
    try testing.expectEqualStrings("square", square.name);
    try testing.expectEqual(@as(usize, 1), square.statements.items.len);
    _ = try expectCall(square.statements.items[0].kind.return_expr, "mul", 2);

    const remember = parsed.program.functions.items[1];
    try testing.expectEqualStrings("remember", remember.name);
    try testing.expectEqual(@as(usize, 1), remember.statements.items.len);
    _ = try expectCall(remember.statements.items[0].kind.expr_stmt, "set_prop", 3);

    const badge = parsed.program.functions.items[2];
    try testing.expectEqualStrings("badge", badge.name);
    try testing.expectEqual(@as(usize, 1), badge.statements.items.len);
    _ = try expectCall(badge.statements.items[0].kind.return_expr, "text", 1);

    const placing = parsed.program.functions.items[3];
    try testing.expectEqualStrings("badge!", placing.name);
    const place_on = try expectCall(placing.statements.items[0].kind.return_expr, "place_on!", 2);
    _ = try expectCall(place_on.args.items[0], "pagectx", 0);
    _ = try expectCall(place_on.args.items[1], "badge", 1);
}

test "syntax spec: expression-bodied functions require an expression" {
    try expectParseError(error.ExpectedIdentifier,
        \\fn bad() -> Number =
        \\
    );
}

test "syntax spec: constants are top-level value declarations" {
    var parsed = try parse(
        \\const accent: Color = c"#ff0000"
        \\
    );
    defer parsed.deinit();

    try testing.expectEqual(@as(usize, 0), parsed.program.functions.items.len);
    try testing.expectEqual(@as(usize, 1), parsed.program.constants.items.len);
    const accent = parsed.program.constants.items[0];
    try testing.expectEqualStrings("accent", accent.name);
    try testing.expectEqual(Type.Kind.color, accent.value_type.kind);
    try expectColor(accent.value, "1,0,0");
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
    try testing.expectEqual(Type.Kind.void, noop.result_type.kind);
    try testing.expectEqual(@as(usize, 1), noop.statements.items.len);

    const stop = parsed.program.functions.items[1];
    try testing.expectEqual(Type.Kind.void, stop.result_type.kind);
    try testing.expectEqual(@as(usize, 1), stop.statements.items.len);
    switch (stop.statements.items[0].kind) {
        .return_void => {},
        else => return error.ExpectedReturnVoid,
    }
}

test "syntax spec: function types and lambdas are source syntax" {
    var parsed = try parse(
        \\fn make_label(text_value: String) -> Page -> Object
        \\  return (page_value: Page) |-> place_on!(page_value, new(text_value, "body", "text"))
        \\end
        \\
        \\fn use(callback: (Page -> Object) -> Document, pair: (Page, Document) -> Object, thunk: () -> Number) -> Number
        \\  return thunk()
        \\end
        \\
    );
    defer parsed.deinit();

    const make_label = parsed.program.functions.items[0];
    try testing.expectEqual(Type.Kind.function, make_label.result_type.kind);
    try testing.expectEqual(@as(usize, 1), make_label.result_type.fn_params.len);
    try testing.expectEqual(Type.Kind.page, make_label.result_type.fn_params[0].kind);
    try testing.expect(make_label.result_type.fn_result != null);
    try testing.expectEqual(Type.Kind.object, make_label.result_type.fn_result.?.kind);
    switch (make_label.statements.items[0].kind.return_expr) {
        .lambda => |lambda| {
            try testing.expectEqual(@as(usize, 1), lambda.params.items.len);
            try testing.expectEqual(Type.Kind.page, lambda.params.items[0].ty.kind);
        },
        else => return error.ExpectedLambdaExpr,
    }

    const use = parsed.program.functions.items[1];
    try testing.expectEqual(Type.Kind.function, use.params.items[0].ty.kind);
    try testing.expectEqual(Type.Kind.function, use.params.items[0].ty.fn_params[0].kind);
    try testing.expectEqual(Type.Kind.function, use.params.items[1].ty.kind);
    try testing.expectEqual(@as(usize, 2), use.params.items[1].ty.fn_params.len);
    try testing.expectEqual(Type.Kind.function, use.params.items[2].ty.kind);
    try testing.expectEqual(@as(usize, 0), use.params.items[2].ty.fn_params.len);
}

test "syntax spec: bang suffix is limited to callable names" {
    var parsed = try parse(
        \\fn mark!() -> Void
        \\  return
        \\end
        \\
        \\page Calls
        \\  mark!()
        \\  text! "body"
        \\  code! <<
        \\plain block
        \\>>
        \\end
        \\
    );
    defer parsed.deinit();

    try testing.expectEqualStrings("mark!", parsed.program.functions.items[0].name);
    const call = try expectCall(parsed.program.pages.items[0].statements.items[0].kind.expr_stmt, "mark!", 0);
    try testing.expectEqualStrings("mark!", call.callee.name);
    _ = try expectCall(parsed.program.pages.items[0].statements.items[1].kind.expr_stmt, "text!", 1);
    _ = try expectCall(parsed.program.pages.items[0].statements.items[2].kind.expr_stmt, "code!", 1);

    try expectParseError(error.ExpectedChar,
        \\type Bad! = object {
        \\}
        \\
    );

    try expectParseError(error.ExpectedChar,
        \\page Bad
        \\  let value! = 1
        \\end
        \\
    );

    try expectParseError(error.ExpectedTypeAnnotation,
        \\const value!: Number = 1
        \\
    );

    try expectParseError(error.ExpectedTypeAnnotation,
        \\fn bad(value!: Number) -> Number
        \\  return 1
        \\end
        \\
    );

    try expectParseError(error.ExpectedChar,
        \\page Bad
        \\  let value = mark!
        \\end
        \\
    );
}

test "syntax spec: qualified callables parse in normal and text block calls" {
    var parsed = try parse(
        \\import std:themes/default
        \\
        \\page Calls
        \\  default::h2("body")
        \\  default::h2! <<
        \\block body
        \\>>
        \\end
        \\
    );
    defer parsed.deinit();

    const normal_call = try expectCall(parsed.program.pages.items[0].statements.items[0].kind.expr_stmt, "h2", 1);
    try testing.expect(normal_call.callee.isQualified());
    try testing.expectEqualStrings("default", normal_call.callee.qualifier.?);

    const block_call = try expectCall(parsed.program.pages.items[0].statements.items[1].kind.expr_stmt, "h2!", 1);
    try testing.expect(block_call.callee.isQualified());
    try testing.expectEqualStrings("default", block_call.callee.qualifier.?);
}

test "syntax spec: incomplete function type is not accepted as a surface type" {
    try expectParseError(error.InvalidTypeAnnotation,
        \\fn bad(f: Function) -> Number
        \\  return 1
        \\end
        \\
    );
}

test "syntax spec: paired placement functions expand to plain and placing definitions" {
    var parsed = try parse(
        \\fn/! note(text_value: String, tone: String = "soft") -> Object
        \\  return text(text_value)
        \\end
        \\
    );
    defer parsed.deinit();

    try testing.expectEqual(@as(usize, 2), parsed.program.functions.items.len);
    const note = parsed.program.functions.items[0];
    try testing.expectEqualStrings("note", note.name);
    try testing.expectEqual(@as(usize, 2), note.params.items.len);
    try testing.expectEqualStrings("tone", note.params.items[1].name);
    try expectString(note.params.items[1].default_value.?.*, "soft");

    const placing = parsed.program.functions.items[1];
    try testing.expectEqualStrings("note!", placing.name);
    try testing.expectEqual(@as(usize, 2), placing.params.items.len);
    try testing.expectEqualStrings("tone", placing.params.items[1].name);
    try expectString(placing.params.items[1].default_value.?.*, "soft");
    try testing.expectEqual(note.span.start, placing.span.start);
    try testing.expectEqual(note.span.end, placing.span.end);

    const return_expr = placing.statements.items[0].kind.return_expr;
    const place_call = try expectCall(return_expr, "place_on!", 2);
    _ = try expectCall(place_call.args.items[0], "pagectx", 0);
    const inner_call = try expectCall(place_call.args.items[1], "note", 2);
    switch (inner_call.args.items[0]) {
        .ident => |ident| try testing.expectEqualStrings("text_value", ident.name),
        else => return error.ExpectedIdentifier,
    }
    switch (inner_call.args.items[1]) {
        .ident => |ident| try testing.expectEqualStrings("tone", ident.name),
        else => return error.ExpectedIdentifier,
    }

    const bad_source =
        \\fn/! note!() -> Object
        \\  return new("", "body", "text")
        \\end
        \\
    ;
    const bang_offset = (std.mem.indexOf(u8, bad_source, "note!") orelse return error.ExpectedIdentifier) + "note".len;
    try expectParseErrorAt(error.PairedFunctionNameCannotEndWithBang, bad_source, bang_offset);
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
    try testing.expectEqual(Type.Kind.object, keep.params.items[0].ty.kind);
    try testing.expectEqualStrings("Text", keep.params.items[0].ty.class_name.?);
    try testing.expectEqual(Type.Kind.object, keep.result_type.kind);
    try testing.expectEqualStrings("Text", keep.result_type.class_name.?);
}

test "syntax spec: enum declarations and optional types parse" {
    var parsed = try parse(
        \\type Align = left | center | right
        \\
        \\fn keep(value: Color?, missing: None) -> Color?
        \\  return value
        \\end
        \\
    );
    defer parsed.deinit();

    try testing.expectEqual(@as(usize, 1), parsed.program.types.items.len);
    try testing.expectEqualStrings("Align", parsed.program.types.items[0].name);
    try testing.expectEqual(@as(usize, 3), parsed.program.types.items[0].cases.items.len);
    try testing.expectEqualStrings("left", parsed.program.types.items[0].cases.items[0].name);
    try testing.expectEqualStrings("center", parsed.program.types.items[0].cases.items[1].name);
    try testing.expectEqualStrings("right", parsed.program.types.items[0].cases.items[2].name);
    try expectSpanText(
        \\type Align = left | center | right
        \\
        \\fn keep(value: Color?, missing: None) -> Color?
        \\  return value
        \\end
        \\
    , parsed.program.types.items[0].cases.items[1].name_span.?, "center");

    const keep = parsed.program.functions.items[0];
    try testing.expectEqual(Type.Kind.optional, keep.params.items[0].ty.kind);
    try testing.expectEqual(Type.Kind.color, keep.params.items[0].ty.optional_child.?.kind);
    try testing.expectEqual(Type.Kind.none, keep.params.items[1].ty.kind);
    try testing.expectEqual(Type.Kind.optional, keep.result_type.kind);
    try testing.expectEqual(Type.Kind.color, keep.result_type.optional_child.?.kind);
}

test "syntax spec: incomplete enum declarations are rejected while parsing" {
    try expectParseError(error.ExpectedTypeAnnotation,
        \\type Mode = alpha |
        \\
        \\page bad
        \\end
        \\
    );
}

test "syntax spec: optional types compose with functions and selections" {
    var parsed = try parse(
        \\fn keep(callback: (Page -> Object)?, maker: Page -> Object?, items: Selection<Text>?) -> Void
        \\end
        \\
    );
    defer parsed.deinit();

    const keep = parsed.program.functions.items[0];
    const callback = keep.params.items[0].ty;
    try testing.expectEqual(Type.Kind.optional, callback.kind);
    try testing.expectEqual(Type.Kind.function, callback.optional_child.?.kind);
    try testing.expectEqual(Type.Kind.page, callback.optional_child.?.fn_params[0].kind);
    try testing.expectEqual(Type.Kind.object, callback.optional_child.?.fn_result.?.kind);

    const maker = keep.params.items[1].ty;
    try testing.expectEqual(Type.Kind.function, maker.kind);
    try testing.expectEqual(Type.Kind.optional, maker.fn_result.?.kind);
    try testing.expectEqual(Type.Kind.object, maker.fn_result.?.optional_child.?.kind);

    const items = keep.params.items[2].ty;
    try testing.expectEqual(Type.Kind.optional, items.kind);
    try testing.expectEqual(Type.Kind.selection, items.optional_child.?.kind);
    try testing.expectEqual(Type.Kind.object, items.optional_child.?.param);
    try testing.expectEqualStrings("Text", items.optional_child.?.param_class_name.?);
}

test "syntax spec: qualified type names parse in annotations and type parameters" {
    const source =
        \\import std:core/classes as classes
        \\
        \\fn keep(value: classes::TextStyle, items: Selection<classes::Text>) -> Object<classes::Text>
        \\  return value
        \\end
        \\
    ;
    var parsed = try parse(source);
    defer parsed.deinit();

    const keep = parsed.program.functions.items[0];
    try testing.expectEqual(Type.Kind.object, keep.params.items[0].ty.kind);
    try testing.expectEqualStrings("classes::TextStyle", keep.params.items[0].ty.class_name.?);
    try testing.expectEqualStrings("classes::TextStyle", source[keep.params.items[0].ty.class_name_span.?.start..keep.params.items[0].ty.class_name_span.?.end]);
    try testing.expectEqual(Type.Kind.selection, keep.params.items[1].ty.kind);
    try testing.expectEqualStrings("classes::Text", keep.params.items[1].ty.param_class_name.?);
    try testing.expectEqualStrings("classes::Text", source[keep.params.items[1].ty.param_class_name_span.?.start..keep.params.items[1].ty.param_class_name_span.?.end]);
    try testing.expectEqual(Type.Kind.object, keep.result_type.kind);
    try testing.expectEqualStrings("classes::Text", keep.result_type.class_name.?);
    try testing.expectEqualStrings("classes::Text", source[keep.result_type.class_name_span.?.start..keep.result_type.class_name_span.?.end]);
}

test "syntax spec: qualified record literals and enum targets parse" {
    var parsed = try parse(
        \\import std:core/classes as classes
        \\
        \\page Values
        \\  let style = classes::TextStyle { size = 32 }
        \\  let align = classes::Align.left
        \\end
        \\
    );
    defer parsed.deinit();

    const statements = parsed.program.pages.items[0].statements.items;
    switch (statements[0].kind.let_binding.expr) {
        .record => |record| {
            try testing.expectEqualStrings("classes::TextStyle", record.type_name);
            try testing.expectEqual(@as(usize, 1), record.fields.items.len);
        },
        else => return error.ExpectedRecordExpr,
    }

    const member = try expectMember(statements[1].kind.let_binding.expr, "left");
    switch (member.target.*) {
        .ident => |ident| try testing.expectEqualStrings("classes::Align", ident.name),
        else => return error.ExpectedIdentifier,
    }
}

test "syntax spec: enum values color literals and none stay explicit in the AST" {
    var parsed = try parse(
        \\page Values
        \\  let align = Align.left
        \\  let color = c"0.1,0.2,0.3"
        \\  let missing = none
        \\end
        \\
    );
    defer parsed.deinit();

    const statements = parsed.program.pages.items[0].statements.items;
    const member = try expectMember(statements[0].kind.let_binding.expr, "left");
    switch (member.target.*) {
        .ident => |ident| try testing.expectEqualStrings("Align", ident.name),
        else => return error.ExpectedIdentifier,
    }
    switch (statements[1].kind.let_binding.expr) {
        .color => |value| try testing.expectEqualStrings("0.1,0.2,0.3", value),
        else => return error.ExpectedColorExpr,
    }
    switch (statements[2].kind.let_binding.expr) {
        .none => {},
        else => return error.ExpectedNoneExpr,
    }
}

test "syntax spec: object field defaults are parsed as expressions" {
    var parsed = try parse(
        \\type Align = left | center | right
        \\type Card = object {
        \\  roles = ["card"]
        \\  size: Number = 1.02
        \\  offset: Number = -1.5
        \\  align: Align = Align.center
        \\  fill: Color = c"#334455"
        \\  maybe_fill: Color? = none
        \\  enabled: Bool = true
        \\  label: String = "caption"
        \\}
        \\
    );
    defer parsed.deinit();

    const card = parsed.program.objects.items[0];
    try testing.expectEqual(@as(usize, 7), card.fields.items.len);
    try expectNumber(card.fields.items[0].default_value.?.*, 1.02);
    try testing.expect(card.fields.items[0].default_property_value == null);

    const neg = try expectCall(card.fields.items[1].default_value.?.*, "neg", 1);
    try expectNumber(neg.args.items[0], 1.5);
    try testing.expect(card.fields.items[1].default_property_value == null);

    const enum_member = try expectMember(card.fields.items[2].default_value.?.*, "center");
    switch (enum_member.target.*) {
        .ident => |ident| try testing.expectEqualStrings("Align", ident.name),
        else => return error.ExpectedIdentifier,
    }
    try testing.expect(card.fields.items[2].default_property_value == null);

    try expectColor(card.fields.items[3].default_value.?.*, "0.2,0.26666668,0.33333334");
    try testing.expect(card.fields.items[3].default_property_value == null);
    try expectNone(card.fields.items[4].default_value.?.*);
    try testing.expect(card.fields.items[4].default_property_value == null);
    try expectBoolean(card.fields.items[5].default_value.?.*, true);
    try testing.expect(card.fields.items[5].default_property_value == null);
    try expectString(card.fields.items[6].default_value.?.*, "caption");
    try testing.expect(card.fields.items[6].default_property_value == null);
}

test "syntax spec: member optional and coalesce keep nested targets" {
    var parsed = try parse(
        \\page Members
        \\  let footer = docctx().footer_text ?? "missing"
        \\  let has_footer = docctx().footer_text?
        \\  let color = text("x").text_markdown_code_fill ?? c"0,0,0"
        \\end
        \\
    );
    defer parsed.deinit();

    const statements = parsed.program.pages.items[0].statements.items;
    switch (statements[0].kind.let_binding.expr) {
        .coalesce => |coalesce| {
            const footer = try expectMember(coalesce.target.*, "footer_text");
            _ = try expectCall(footer.target.*, "docctx", 0);
            try expectString(coalesce.fallback.*, "missing");
        },
        else => return error.ExpectedCoalesceExpr,
    }
    switch (statements[1].kind.let_binding.expr) {
        .optional_check => |optional_check| {
            const footer = try expectMember(optional_check.target.*, "footer_text");
            _ = try expectCall(footer.target.*, "docctx", 0);
        },
        else => return error.ExpectedOptionalCheckExpr,
    }
    switch (statements[2].kind.let_binding.expr) {
        .coalesce => |coalesce| {
            const fill = try expectMember(coalesce.target.*, "text_markdown_code_fill");
            _ = try expectCall(fill.target.*, "text", 1);
            switch (coalesce.fallback.*) {
                .color => |value| try testing.expectEqualStrings("0,0,0", value),
                else => return error.ExpectedColorExpr,
            }
        },
        else => return error.ExpectedCoalesceExpr,
    }
}

test "syntax spec: record update keeps target and nested field paths" {
    var parsed = try parse(
        \\page Update
        \\  let theme = default_theme() with {
        \\    body.text.size = 22,
        \\    h1.text.color = c"#123456"
        \\  }
        \\end
        \\
    );
    defer parsed.deinit();

    const expr = parsed.program.pages.items[0].statements.items[0].kind.let_binding.expr;
    const update = try expectRecordUpdate(expr, 2);
    _ = try expectCall(update.target.*, "default_theme", 0);
    try expectPath(update.fields.items[0].path.items, &.{ "body", "text", "size" });
    try expectNumber(update.fields.items[0].value, 22);
    try expectPath(update.fields.items[1].path.items, &.{ "h1", "text", "color" });
    try expectColor(update.fields.items[1].value, "0.07058824,0.20392157,0.3372549");
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
                    try testing.expectEqual(Type.Kind.number, lambda.params.items[0].ty.kind);
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
        \\        place_on!(
        \\          page_value,
        \\          new(
        \\            str(page_index(page_value)),
        \\            "body",
        \\            "text"
        \\          )
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
            try testing.expectEqual(Type.Kind.page, lambda.params.items[0].ty.kind);
            switch (lambda.body.*) {
                .call => |call| try testing.expectEqualStrings("place_on!", call.callee.name),
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
        \\  let flag = !false
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

    const flag = program.pages.items[0].statements.items[2].kind.let_binding.expr;
    const logical_not = try expectCall(flag, "not", 1);
    try expectBoolean(logical_not.args.items[0], false);
}

test "syntax spec: quoted strings keep backslashes literally" {
    var parsed = try parse(
        \\page Strings
        \\  let tex = "$F : L \to L$"
        \\  let marker = "\[1\]"
        \\  let literal = "a\nb"
        \\  let actual = "a
        \\b"
        \\end
        \\
    );
    defer parsed.deinit();
    const statements = parsed.program.pages.items[0].statements.items;

    try expectString(statements[0].kind.let_binding.expr, "$F : L \\to L$");
    try expectString(statements[1].kind.let_binding.expr, "\\[1\\]");
    try expectString(statements[2].kind.let_binding.expr, "a\\nb");
    try expectString(statements[3].kind.let_binding.expr, "a\nb");
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

    const bad_source =
        \\page Bad
        \\  title
        \\end
        \\
    ;
    const title_start = std.mem.indexOf(u8, bad_source, "title") orelse return error.MissingFixtureText;
    try expectParseErrorSpan(error.ZeroArgCallRequiresParens, bad_source, title_start, title_start + "title".len);
}

test "syntax spec: explicit call arguments preserve source spans" {
    const source =
        \\page Args
        \\  let out = themed(foo, "bar")
        \\end
        \\
    ;
    var parsed = try parse(source);
    defer parsed.deinit();

    const call = try expectCall(parsed.program.pages.items[0].statements.items[0].kind.let_binding.expr, "themed", 2);
    try testing.expectEqual(@as(usize, 2), call.arg_spans.items.len);
    try testing.expectEqualStrings("foo", source[call.arg_spans.items[0].start..call.arg_spans.items[0].end]);
    try testing.expectEqualStrings("\"bar\"", source[call.arg_spans.items[1].start..call.arg_spans.items[1].end]);
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

    const property = statements[4].kind.property_set;
    try testing.expectEqualStrings("box", property.object_name);
    try expectPath(property.path.items, &.{"left"});
    try expectString(property.value, "red");

    try expectParseError(error.ExpectedConstraintMarker,
        \\page Bad
        \\  box.left == page.left + 10
        \\end
        \\
    );
}

test "syntax spec: constraints accept record member anchor paths" {
    var parsed = try parse(
        \\page Layout
        \\  ~ caption.top == parts.root.bottom - 16
        \\end
        \\
    );
    defer parsed.deinit();

    const constraint = parsed.program.pages.items[0].statements.items[0].kind.constrain;
    try testing.expectEqual(.node, constraint.target.kind);
    try testing.expectEqualStrings("caption", constraint.target.node_name.?);
    try testing.expectEqualStrings("caption", constraint.target.node_path.?);
    try testing.expectEqual(.top, constraint.target.anchor);
    try testing.expectEqual(.node, constraint.source.kind);
    try testing.expectEqualStrings("parts", constraint.source.node_name.?);
    try testing.expectEqualStrings("parts.root", constraint.source.node_path.?);
    try testing.expectEqual(.bottom, constraint.source.anchor);
}

test "syntax spec: member expressions stay in the AST" {
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
    const content_set = statements[1].kind.property_set;
    try testing.expectEqualStrings("target", content_set.object_name);
    try expectPath(content_set.path.items, &.{"content"});
    const concat = try expectCall(content_set.value, "concat", 2);
    _ = try expectMember(concat.args.items[0], "content");
    try expectString(concat.args.items[1], "!");

    const doc_prop = try expectCall(statements[2].kind.expr_stmt, "set_prop", 3);
    _ = try expectCall(doc_prop.args.items[0], "docctx", 0);
    try expectString(doc_prop.args.items[1], "footer_text");
    try expectString(doc_prop.args.items[2], "footer");

    switch (statements[3].kind.let_binding.expr) {
        .coalesce => |coalesce| {
            _ = try expectMember(coalesce.target.*, "text_color");
            try expectString(coalesce.fallback.*, "black");
        },
        else => return error.ExpectedCoalesceExpr,
    }

    switch (statements[4].kind.let_binding.expr) {
        .optional_check => |optional_check| _ = try expectMember(optional_check.target.*, "text_color"),
        else => return error.ExpectedOptionalCheckExpr,
    }
}

test "syntax spec: chained member assignment targets the enclosing expression" {
    var parsed = try parse(
        \\page Members
        \\  let pipe = make_pipe()
        \\  pipe.middle.text_color = c"#ff0000"
        \\  pipe.middle.content = pipe.middle.content ++ "!"
        \\end
        \\
    );
    defer parsed.deinit();

    const statements = parsed.program.pages.items[0].statements.items;
    const color_set = statements[1].kind.property_set;
    try testing.expectEqualStrings("pipe", color_set.object_name);
    try expectPath(color_set.path.items, &.{ "middle", "text_color" });
    try expectColor(color_set.value, "1,0,0");

    const content_set = statements[2].kind.property_set;
    try testing.expectEqualStrings("pipe", content_set.object_name);
    try expectPath(content_set.path.items, &.{ "middle", "content" });
    const concat = try expectCall(content_set.value, "concat", 2);
    const read_content = try expectMember(concat.args.items[0], "content");
    _ = try expectMember(read_content.target.*, "middle");
    try expectString(concat.args.items[1], "!");
}

test "syntax spec: member assignments keep nested property paths" {
    var parsed = try parse(
        \\page Members
        \\  box.layout.x = 102
        \\  box.text.font.family = "Avenir"
        \\end
        \\
    );
    defer parsed.deinit();

    const statements = parsed.program.pages.items[0].statements.items;
    const layout = statements[0].kind.property_set;
    try testing.expectEqualStrings("box", layout.object_name);
    try expectPath(layout.path.items, &.{ "layout", "x" });
    try expectNumber(layout.value, 102);

    const font = statements[1].kind.property_set;
    try testing.expectEqualStrings("box", font.object_name);
    try expectPath(font.path.items, &.{ "text", "font", "family" });
    try expectString(font.value, "Avenir");
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
        .ident => |ident| try testing.expectEqualStrings("place", ident.name),
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

test "syntax spec: recovering parse keeps expression holes in the returned program" {
    var parsed = try parseRecovering(
        \\page Recover
        \\  let missing =
        \\  text!(, "leading")
        \\  text!("trailing",)
        \\end
        \\
    );
    defer parsed.deinit();

    try testing.expectEqual(@as(usize, 3), parsed.result.holes.holes.len);
    try testing.expectEqual(@as(usize, 3), parsed.result.holes.diagnostics.len);
    for (parsed.result.holes.diagnostics) |diagnostic| {
        try testing.expectEqual(error.ExpectedExpression, diagnostic.err);
        try testing.expect(diagnostic.caused_by != null);
        try testing.expectEqual(diagnostic.hole_id, diagnostic.caused_by.?);
    }

    const statements = parsed.result.program.pages.items[0].statements.items;
    switch (statements[0].kind.let_binding.expr) {
        .hole => |id| {
            try testing.expectEqual(@as(ast.HoleId, 0), id);
            try testing.expectEqual(syntax.HoleKind.expr, parsed.result.holes.holes[id].kind);
        },
        else => return error.ExpectedHoleExpr,
    }

    const leading_call = statements[1].kind.expr_stmt.call;
    switch (leading_call.args.items[0]) {
        .hole => |id| try testing.expectEqual(syntax.HoleKind.call_arg, parsed.result.holes.holes[id].kind),
        else => return error.ExpectedHoleExpr,
    }
    try expectString(leading_call.args.items[1], "leading");

    const trailing_call = statements[2].kind.expr_stmt.call;
    try expectString(trailing_call.args.items[0], "trailing");
    switch (trailing_call.args.items[1]) {
        .hole => |id| try testing.expectEqual(syntax.HoleKind.call_arg, parsed.result.holes.holes[id].kind),
        else => return error.ExpectedHoleExpr,
    }
}

test "syntax spec: recovering parse keeps statement holes and continues" {
    var parsed = try parseRecovering(
        \\page Recover
        \\  text!("body").
        \\  let ok = 1
        \\end
        \\
    );
    defer parsed.deinit();

    try testing.expectEqual(@as(usize, 1), parsed.result.holes.holes.len);
    try testing.expectEqual(syntax.HoleKind.member_name, parsed.result.holes.holes[0].kind);
    try testing.expectEqual(error.ExpectedMemberName, parsed.result.holes.diagnostics[0].err);

    const statements = parsed.result.program.pages.items[0].statements.items;
    switch (statements[0].kind) {
        .expr_stmt => |expr| switch (expr) {
            .member => |member| try testing.expectEqual(@as(ast.HoleId, 0), member.name_hole orelse return error.ExpectedMemberNameHole),
            else => return error.ExpectedMemberExpr,
        },
        else => return error.ExpectedExprStatement,
    }
    try testing.expectEqualStrings("ok", statements[1].kind.let_binding.name);
}

test "syntax spec: recovering parse reports import holes and parses following items" {
    var parsed = try parseRecovering(
        \\import "core/theme.ss"
        \\page Recover
        \\  let ok = 1
        \\end
        \\
    );
    defer parsed.deinit();

    try testing.expectEqual(@as(usize, 1), parsed.result.holes.holes.len);
    try testing.expectEqual(syntax.HoleKind.import_spec, parsed.result.holes.holes[0].kind);
    try testing.expectEqual(error.InvalidImportSpec, parsed.result.holes.diagnostics[0].err);
    try testing.expectEqual(@as(usize, 1), parsed.result.program.pages.items.len);
    try testing.expectEqualStrings("Recover", parsed.result.program.pages.items[0].name);
}

test "syntax spec: recovering parse keeps qualified callable name holes" {
    var parsed = try parseRecovering(
        \\page Recover
        \\  theme::("body")
        \\end
        \\
    );
    defer parsed.deinit();

    try testing.expectEqual(@as(usize, 1), parsed.result.holes.holes.len);
    try testing.expectEqual(syntax.HoleKind.name, parsed.result.holes.holes[0].kind);
    const call = parsed.result.program.pages.items[0].statements.items[0].kind.expr_stmt.call;
    try testing.expectEqualStrings("theme", call.callee.qualifier.?);
    try testing.expectEqual(@as(ast.HoleId, 0), call.callee.name_hole.?);
}

test "syntax spec: recovering parse keeps type expression holes" {
    var parsed = try parseRecovering(
        \\fn typed(x:) -> = x
        \\page Recover
        \\  let item: = 1
        \\end
        \\record Broken {
        \\  field:
        \\}
        \\type Widget = object {
        \\  prop:
        \\}
        \\
    );
    defer parsed.deinit();

    try testing.expectEqual(@as(usize, 5), parsed.result.holes.holes.len);
    for (parsed.result.holes.holes, 0..) |type_hole, index| {
        try testing.expectEqual(@as(ast.HoleId, @intCast(index)), type_hole.id);
        try testing.expectEqual(syntax.HoleKind.type_expr, type_hole.kind);
        try testing.expectEqual(syntax.ExpectedSyntax.type_expr, type_hole.expected);
        try testing.expectEqual(error.ExpectedTypeAnnotation, parsed.result.holes.diagnostics[index].err);
        try testing.expectEqual(type_hole.id, parsed.result.holes.diagnostics[index].caused_by.?);
    }

    const func = parsed.result.program.functions.items[0];
    try testing.expectEqual(Type.Kind.hole, func.params.items[0].ty.kind);
    try testing.expectEqual(@as(ast.HoleId, 0), func.params.items[0].ty.hole_id.?);
    try testing.expectEqual(Type.Kind.hole, func.result_type.kind);
    try testing.expectEqual(@as(ast.HoleId, 1), func.result_type.hole_id.?);

    const binding = parsed.result.program.pages.items[0].statements.items[0].kind.let_binding;
    try testing.expectEqual(Type.Kind.hole, binding.type_annotation.?.kind);
    try testing.expectEqual(@as(ast.HoleId, 2), binding.type_annotation.?.hole_id.?);

    const record_field = parsed.result.program.records.items[0].fields.items[0];
    try testing.expectEqual(Type.Kind.hole, record_field.value_type.kind);
    try testing.expectEqual(@as(ast.HoleId, 3), record_field.value_type.hole_id.?);

    const object_field = parsed.result.program.objects.items[0].fields.items[0];
    try testing.expectEqual(Type.Kind.hole, object_field.value_type.kind);
    try testing.expectEqual(@as(ast.HoleId, 4), object_field.value_type.hole_id.?);
}
