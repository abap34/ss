const std = @import("std");
const allocation_testing = @import("allocation_testing");
const syntax = @import("syntax");
const ast = @import("ast");
const Type = @import("language_type").Type;

const testing = std.testing;

comptime {
    _ = @import("formatting/spec_tests.zig");
    _ = @import("grammar/spec_tests.zig");
    _ = @import("comparisons/spec_tests.zig");
    _ = @import("selections/spec_tests.zig");
}

const ParsedModule = struct {
    arena: std.heap.ArenaAllocator,
    module: syntax.Module,

    fn deinit(self: *ParsedModule) void {
        self.module.deinit(self.arena.allocator());
        self.arena.deinit();
    }
};

const ParsedRecoveringModule = struct {
    arena: std.heap.ArenaAllocator,
    result: syntax.ParseResult,

    fn deinit(self: *ParsedRecoveringModule) void {
        self.result.deinit(self.arena.allocator());
        self.arena.deinit();
    }
};

fn parse(source: []const u8) !ParsedModule {
    return try parseWithSourceName(source, "unit-test.ss");
}

fn parseWithSourceName(source: []const u8, source_name: []const u8) !ParsedModule {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    errdefer arena.deinit();
    const program = try syntax.parseWithSourceName(arena.allocator(), source, source_name);
    return .{ .arena = arena, .module = program };
}

fn parseRecovering(source: []const u8) !ParsedRecoveringModule {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    errdefer arena.deinit();
    const result = try syntax.parseRecoveringWithSourceName(arena.allocator(), source, "unit-test.ss");
    return .{ .arena = arena, .result = result };
}

fn parseAndDeinitSource(allocator: std.mem.Allocator, source: []const u8) !void {
    var program = try syntax.parseWithSourceName(allocator, source, "unit-test.ss");
    defer program.deinit(allocator);
}

fn parseRecoveringAndDeinitSource(allocator: std.mem.Allocator, source: []const u8) !void {
    var result = try syntax.parseRecoveringWithSourceName(allocator, source, "unit-test.ss");
    defer result.deinit(allocator);
}

fn cloneAndDeinitModule(allocator: std.mem.Allocator, module: *const ast.Module) !void {
    var cloned = try module.clone(allocator);
    defer cloned.deinit(allocator);
}

fn readFixture(path: []const u8) ![]u8 {
    const full_path = try std.fs.path.join(testing.allocator, &.{ "tests/fixtures/syntax", path });
    defer testing.allocator.free(full_path);
    return std.Io.Dir.cwd().readFileAlloc(testing.io, full_path, testing.allocator, .limited(64 * 1024));
}

fn expectParseErrorDiagnostic(expected: anyerror, source: []const u8) !syntax.ParseDiagnostic {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var failure: syntax.ParseFailure = .{};
    var program = syntax.parseWithSourceNameAndFailure(arena.allocator(), source, "unit-test.ss", &failure) catch |err| {
        try testing.expectEqual(expected, err);
        const diagnostic = failure.diagnostic orelse return error.MissingParseDiagnostic;
        try testing.expectEqual(expected, diagnostic.err);
        return diagnostic;
    };
    defer program.deinit(arena.allocator());
    return error.ExpectedParseError;
}

fn expectParseError(expected: anyerror, source: []const u8) !void {
    _ = try expectParseErrorDiagnostic(expected, source);
}

fn expectParseErrorWithoutLeaks(expected: anyerror, source: []const u8) !void {
    var failure: syntax.ParseFailure = .{};
    if (syntax.parseWithSourceNameAndFailure(testing.allocator, source, "unit-test.ss", &failure)) |result| {
        var program = result;
        defer program.deinit(testing.allocator);
        return error.ExpectedParseError;
    } else |err| {
        try testing.expectEqual(expected, err);
        const diagnostic = failure.diagnostic orelse return error.MissingParseDiagnostic;
        try testing.expectEqual(expected, diagnostic.err);
    }
}

fn expectParseErrorAt(expected: anyerror, source: []const u8, expected_start: usize) !void {
    const diagnostic = try expectParseErrorDiagnostic(expected, source);
    try testing.expectEqual(expected_start, diagnostic.span.start);
}

fn expectParseErrorSpan(expected: anyerror, source: []const u8, expected_start: usize, expected_end: usize) !void {
    const diagnostic = try expectParseErrorDiagnostic(expected, source);
    try testing.expectEqual(expected_start, diagnostic.span.start);
    try testing.expectEqual(expected_end, diagnostic.span.end);
}

test "syntax spec: parse diagnostics belong to their parse attempt" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var first_failure: syntax.ParseFailure = .{};
    try testing.expectError(
        error.ExpectedKeyword,
        syntax.parseWithSourceNameAndFailure(arena.allocator(), "@", "first.ss", &first_failure),
    );
    const first = first_failure.diagnostic orelse return error.MissingParseDiagnostic;
    try testing.expectEqual(error.ExpectedKeyword, first.err);
    try testing.expectEqual(ast.Span{ .start = 0, .end = 1 }, first.span);
    try testing.expectEqualStrings("keyword", first.expected.?);
    try testing.expectEqualStrings("@", first.found.?);

    var second_failure: syntax.ParseFailure = .{};
    try testing.expectError(
        error.ExpectedString,
        syntax.parseWithSourceNameAndFailure(arena.allocator(), "page", "second.ss", &second_failure),
    );
    const second = second_failure.diagnostic orelse return error.MissingParseDiagnostic;
    try testing.expectEqual(error.ExpectedString, second.err);
    try testing.expectEqual(ast.Span{ .start = 4, .end = 4 }, second.span);
    try testing.expectEqualStrings("string or page name", second.expected.?);
    try testing.expectEqualStrings("end of file", second.found.?);
    try testing.expectEqualStrings("@", first_failure.diagnostic.?.found.?);

    var program = try syntax.parseWithSourceNameAndFailure(
        arena.allocator(),
        "page Good\nend\n",
        "valid.ss",
        &first_failure,
    );
    defer program.deinit(arena.allocator());
    try testing.expect(first_failure.diagnostic == null);
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

fn expectIdent(expr: ast.Expr, name: []const u8) !void {
    switch (expr) {
        .ident => |ident| try testing.expectEqualStrings(name, ident.name),
        else => return error.ExpectedIdentifierExpr,
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

test "syntax spec: line comment helpers recognize only double semicolons" {
    const source = @import("utils").source;
    try testing.expectEqual(@as(?usize, 2), source.lineCommentMarkerLength(";; comment", 0));
    try testing.expectEqual(@as(?usize, null), source.lineCommentMarkerLength("# code", 0));
    try testing.expectEqual(@as(?usize, null), source.lineCommentMarkerLength(";", 0));
    try testing.expectEqual(@as(?usize, null), source.lineCommentMarkerLength("// code", 0));
    try testing.expectEqualStrings("a // b ", source.stripLineComment("a // b ;; comment"));
    try testing.expectEqualStrings("a # code", source.stripLineComment("a # code"));
    try testing.expectEqualStrings("a # code ", source.stripLineComment("a # code ;; comment"));
    try testing.expectEqualStrings("\"https://example.com/a//b;;#\" ", source.stripLineComment("\"https://example.com/a//b;;#\" ;; comment"));
    const text = " ;; first\n ;; second\n # code";
    var pos: usize = 0;
    source.skipTriviaFrom(text, &pos);
    try testing.expectEqualStrings("# code", text[pos..]);
}

test "syntax spec: hash characters remain in paths names and text" {
    var parsed = try parse(
        \\import ./parts#one as *
        \\page Part#one
        \\text("# Heading")
        \\text <<
        \\# Heading
        \\>>
        \\end
    );
    defer parsed.deinit();
    try testing.expectEqualStrings("./parts#one", parsed.module.imports.items[0].spec);
    try testing.expectEqualStrings("Part#one", parsed.module.pages.items[0].name);
    for (parsed.module.pages.items[0].statements.items) |statement| {
        const call = try expectCall(statement.kind.expr_stmt, "text", 1);
        try testing.expectEqualStrings("# Heading", call.args.items[0].string.text);
    }
}

test "syntax spec: double slashes remain text and single slash remains division" {
    var parsed = try parse(
        \\page Example
        \\  text("https://example.com/a//b")
        \\  text line // body
        \\  text """
        \\// multiline body
        \\"""
        \\  let quotient = 8 / 2
        \\end
    );
    defer parsed.deinit();
    const statements = parsed.module.pages.items[0].statements.items;
    try testing.expectEqual(@as(usize, 4), statements.len);
    const expected = [_][]const u8{ "https://example.com/a//b", "line // body", "// multiline body" };
    for (expected, 0..) |text, index| {
        const call = try expectCall(statements[index].kind.expr_stmt, "text", 1);
        try expectString(call.args.items[0], text);
    }
}

test "syntax spec: imports and pages preserve source order" {
    const source_text =
        \\;; Leading trivia is not part of the AST.
        \\import core
        \\import "themes/default"; ;; comments may follow terminators
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
    const program = &parsed.module;

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

    try testing.expectEqual(@as(usize, 5), parsed.module.imports.items.len);
    try expectImportMode(parsed.module.imports.items[0], "default", true);
    try expectImportMode(parsed.module.imports.items[1], "base", false);
    try expectImportMode(parsed.module.imports.items[2], null, true);
    try expectImportMode(parsed.module.imports.items[3], null, true);
    try expectImportMode(parsed.module.imports.items[4], "seminar_theme", false);
    try expectSpanText(source_text, parsed.module.imports.items[0].spec_span, "std:themes/default");
    try expectSpanText(source_text, parsed.module.imports.items[1].spec_span, "std:themes/default");
    try expectSpanText(source_text, parsed.module.imports.items[1].alias_span.?, "base");
    try testing.expect(parsed.module.imports.items[0].alias_span == null);
    try testing.expect(parsed.module.imports.items[2].alias_span == null);
    try testing.expect(parsed.module.imports.items[3].alias_span == null);
    try expectSpanText(source_text, parsed.module.imports.items[4].alias_span.?, "seminar_theme");
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

    const stmt = parsed.module.pages.items[0].statements.items[0];
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
        \\enum Mode { light dark }
        \\type Widget {
        \\  title: String
        \\}
        \\type Theme {
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

    try expectSpanText(source_text, parsed.module.types.items[0].name_span.?, "Mode");
    try expectSpanText(source_text, parsed.module.records.items[0].name_span.?, "Widget");
    try expectSpanText(source_text, parsed.module.records.items[0].fields.items[0].name_span.?, "title");
    try expectSpanText(source_text, parsed.module.records.items[1].name_span.?, "Theme");
    try expectSpanText(source_text, parsed.module.records.items[1].fields.items[0].name_span.?, "accent");
    try expectSpanText(source_text, parsed.module.constants.items[0].name_span.?, "accent");
    try expectSpanText(source_text, parsed.module.functions.items[0].name_span.?, "helper");
    try expectSpanText(source_text, parsed.module.pages.items[0].name_span.?, "First");
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

    const binding = parsed.module.pages.items[0].statements.items[0].kind.let_binding;
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

    try testing.expect(std.mem.startsWith(u8, first.module.pages.items[0].name, "#gen_"));
    try testing.expect(std.mem.startsWith(u8, second.module.pages.items[0].name, "#gen_"));
    try testing.expect(!std.mem.eql(u8, first.module.pages.items[0].name, second.module.pages.items[0].name));
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
    const program = &parsed.module;

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
        \\fn remember(action: (Document, String, Number) -> Void) -> Void =
        \\  action(
        \\    docctx(),
        \\    "layout_h_center_offset",
        \\    42,
        \\  )
        \\
        \\fn/! badge(text_value: String) -> Text = text(text_value)
        \\
    );
    defer parsed.deinit();

    try testing.expectEqual(@as(usize, 4), parsed.module.functions.items.len);

    const square = parsed.module.functions.items[0];
    try testing.expectEqualStrings("square", square.name);
    try testing.expectEqual(@as(usize, 1), square.statements.items.len);
    _ = try expectCall(square.statements.items[0].kind.return_expr, "mul", 2);

    const remember = parsed.module.functions.items[1];
    try testing.expectEqualStrings("remember", remember.name);
    try testing.expectEqual(@as(usize, 1), remember.statements.items.len);
    _ = try expectCall(remember.statements.items[0].kind.expr_stmt, "action", 3);

    const badge = parsed.module.functions.items[2];
    try testing.expectEqualStrings("badge", badge.name);
    try testing.expectEqual(@as(usize, 1), badge.statements.items.len);
    _ = try expectCall(badge.statements.items[0].kind.return_expr, "text", 1);

    const placing = parsed.module.functions.items[3];
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

    try testing.expectEqual(@as(usize, 0), parsed.module.functions.items.len);
    try testing.expectEqual(@as(usize, 1), parsed.module.constants.items.len);
    const accent = parsed.module.constants.items[0];
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

    const noop = parsed.module.functions.items[0];
    try testing.expectEqual(Type.Kind.void, noop.result_type.kind);
    try testing.expectEqual(@as(usize, 1), noop.statements.items.len);

    const stop = parsed.module.functions.items[1];
    try testing.expectEqual(Type.Kind.void, stop.result_type.kind);
    try testing.expectEqual(@as(usize, 1), stop.statements.items.len);
    switch (stop.statements.items[0].kind) {
        .return_void => {},
        else => return error.ExpectedReturnVoid,
    }
}

test "syntax spec: function types and lambdas are source syntax" {
    var parsed = try parse(
        \\fn make_label(text_value: String) -> Page -> Placement
        \\  return (page_value: Page) |-> place_on!(page_value, text(text_value))
        \\end
        \\
        \\fn use(callback: (Page -> Placement) -> Document, pair: (Page, Document) -> Placement, thunk: () -> Number) -> Number
        \\  return thunk()
        \\end
        \\
    );
    defer parsed.deinit();

    const make_label = parsed.module.functions.items[0];
    try testing.expectEqual(Type.Kind.function, make_label.result_type.kind);
    try testing.expectEqual(@as(usize, 1), make_label.result_type.fn_params.len);
    try testing.expectEqual(Type.Kind.page, make_label.result_type.fn_params[0].kind);
    try testing.expect(make_label.result_type.fn_result != null);
    try testing.expectEqual(Type.Kind.placement, make_label.result_type.fn_result.?.kind);
    switch (make_label.statements.items[0].kind.return_expr) {
        .lambda => |lambda| {
            try testing.expectEqual(@as(usize, 1), lambda.params.items.len);
            try testing.expectEqual(Type.Kind.page, lambda.params.items[0].ty.kind);
        },
        else => return error.ExpectedLambdaExpr,
    }

    const use = parsed.module.functions.items[1];
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

    try testing.expectEqualStrings("mark!", parsed.module.functions.items[0].name);
    const call = try expectCall(parsed.module.pages.items[0].statements.items[0].kind.expr_stmt, "mark!", 0);
    try testing.expectEqualStrings("mark!", call.callee.name);
    _ = try expectCall(parsed.module.pages.items[0].statements.items[1].kind.expr_stmt, "text!", 1);
    _ = try expectCall(parsed.module.pages.items[0].statements.items[2].kind.expr_stmt, "code!", 1);

    try expectParseError(error.ExpectedChar,
        \\type Bad! {
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
}

test "syntax spec: bang-marked functions are ordinary references" {
    var parsed = try parse(
        \\page References
        \\  let local = mark!
        \\  let imported = actions::mark!
        \\  apply(mark!)
        \\end
    );
    defer parsed.deinit();

    const statements = parsed.module.pages.items[0].statements.items;
    try testing.expectEqualStrings("mark!", statements[0].kind.let_binding.expr.ident.name);
    try testing.expectEqualStrings("actions::mark!", statements[1].kind.let_binding.expr.ident.name);
    const apply = try expectCall(statements[2].kind.expr_stmt, "apply", 1);
    try testing.expectEqualStrings("mark!", apply.args.items[0].ident.name);
}

test "syntax spec: qualified callables parse in normal and text block calls" {
    var parsed = try parse(
        \\import std:text as body
        \\
        \\page Calls
        \\  body::text("body")
        \\  body::text! <<
        \\block body
        \\>>
        \\end
        \\
    );
    defer parsed.deinit();

    const normal_call = try expectCall(parsed.module.pages.items[0].statements.items[0].kind.expr_stmt, "text", 1);
    try testing.expect(normal_call.callee.isQualified());
    try testing.expectEqualStrings("body", normal_call.callee.qualifier.?);

    const block_call = try expectCall(parsed.module.pages.items[0].statements.items[1].kind.expr_stmt, "text!", 1);
    try testing.expect(block_call.callee.isQualified());
    try testing.expectEqualStrings("body", block_call.callee.qualifier.?);
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
        \\fn/! note(text_value: String, tone: String = "soft") -> Text
        \\  return text(text_value)
        \\end
        \\
    );
    defer parsed.deinit();

    try testing.expectEqual(@as(usize, 2), parsed.module.functions.items.len);
    const note = parsed.module.functions.items[0];
    try testing.expectEqualStrings("note", note.name);
    try testing.expectEqual(@as(usize, 2), note.params.items.len);
    try testing.expectEqualStrings("tone", note.params.items[1].name);
    try expectString(note.params.items[1].default_value.?.*, "soft");

    const placing = parsed.module.functions.items[1];
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
        \\fn/! note!() -> Text
        \\  return text("")
        \\end
        \\
    ;
    const bang_offset = (std.mem.indexOf(u8, bad_source, "note!") orelse return error.ExpectedIdentifier) + "note".len;
    try expectParseErrorAt(error.PairedFunctionNameCannotEndWithBang, bad_source, bang_offset);
}

test "syntax spec: user type annotations retain unresolved names until name resolution" {
    var parsed = try parse(
        \\fn keep(value: Text) -> Text
        \\  return value
        \\end
        \\
    );
    defer parsed.deinit();

    const keep = parsed.module.functions.items[0];
    try testing.expectEqual(Type.Kind.unresolved, keep.params.items[0].ty.kind);
    try testing.expectEqualStrings("Text", keep.params.items[0].ty.class_name.?);
    try testing.expectEqual(Type.Kind.unresolved, keep.result_type.kind);
    try testing.expectEqualStrings("Text", keep.result_type.class_name.?);
}

test "syntax spec: enum declarations and optional types parse" {
    var parsed = try parse(
        \\enum Align { left center right }
        \\
        \\fn keep(value: Color?, missing: None) -> Color?
        \\  return value
        \\end
        \\
    );
    defer parsed.deinit();

    try testing.expectEqual(@as(usize, 1), parsed.module.types.items.len);
    try testing.expectEqualStrings("Align", parsed.module.types.items[0].name);
    try testing.expectEqual(@as(usize, 3), parsed.module.types.items[0].cases.items.len);
    try testing.expectEqualStrings("left", parsed.module.types.items[0].cases.items[0].name);
    try testing.expectEqualStrings("center", parsed.module.types.items[0].cases.items[1].name);
    try testing.expectEqualStrings("right", parsed.module.types.items[0].cases.items[2].name);
    try expectSpanText(
        \\enum Align { left center right }
        \\
        \\fn keep(value: Color?, missing: None) -> Color?
        \\  return value
        \\end
        \\
    , parsed.module.types.items[0].cases.items[1].name_span.?, "center");

    const keep = parsed.module.functions.items[0];
    try testing.expectEqual(Type.Kind.optional, keep.params.items[0].ty.kind);
    try testing.expectEqual(Type.Kind.color, keep.params.items[0].ty.optional_child.?.kind);
    try testing.expectEqual(Type.Kind.none, keep.params.items[1].ty.kind);
    try testing.expectEqual(Type.Kind.optional, keep.result_type.kind);
    try testing.expectEqual(Type.Kind.color, keep.result_type.optional_child.?.kind);
}

test "syntax spec: enum braces preserve multiline cases and source spans" {
    const text =
        \\enum Mode {
        \\  alpha ;; first case
        \\  beta
        \\}
        \\enum EmptyName { none }
    ;
    var parsed = try parse(text);
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 2), parsed.module.types.items.len);
    const mode = parsed.module.types.items[0];
    try testing.expectEqual(@as(usize, 2), mode.cases.items.len);
    try expectSpanText(text, mode.cases.items[1].name_span.?, "beta");
    try expectSpanText(text, mode.name_span.?, "Mode");
    try testing.expectEqualStrings("none", parsed.module.types.items[1].cases.items[0].name);
    try allocation_testing.checkAllAllocationFailures(testing.allocator, parseAndDeinitSource, .{text});
}

test "syntax spec: enum declarations require nonempty braces" {
    try expectParseErrorWithoutLeaks(error.ExpectedTypeAnnotation, "enum Mode {}\n");
    try expectParseErrorWithoutLeaks(error.ExpectedChar, "enum Mode { alpha\n");
    try expectParseErrorWithoutLeaks(error.ExpectedChar, "enum Mode = alpha\n");
    try expectParseErrorWithoutLeaks(error.ExpectedIdentifier, "enum Mode { alpha | beta }\n");
    try expectParseErrorWithoutLeaks(error.ReservedIdentifier, "const enum = 1\n");
}

test "syntax spec: failed constant and type declarations release parsed ownership" {
    try expectParseErrorWithoutLeaks(
        error.ExpectedChar,
        "const value: (Page -> Placement)?\n",
    );
    try expectParseErrorWithoutLeaks(error.ExpectedChar, "type Mode\n");
    try expectParseErrorWithoutLeaks(error.ExpectedIdentifier,
        \\type Mode { value: }
        \\
    );
}

test "syntax spec: constant and enum parsing survive every allocation failure" {
    try allocation_testing.checkAllAllocationFailures(
        testing.allocator,
        parseAndDeinitSource,
        .{"const value: Selection<Text> = source\n"},
    );
    try allocation_testing.checkAllAllocationFailures(
        testing.allocator,
        parseAndDeinitSource,
        .{"enum Mode { alpha beta }\n"},
    );
}

test "syntax spec: imports survive every allocation failure" {
    try allocation_testing.checkAllAllocationFailures(
        testing.allocator,
        parseAndDeinitSource,
        .{"import \"dep\"\n"},
    );
}

test "syntax spec: failed pages release parsed ownership" {
    try expectParseErrorWithoutLeaks(error.ExpectedEnd,
        \\page Broken
        \\  let item = "owned"
        \\
    );
}

test "syntax spec: document and page parsing survive every allocation failure" {
    try allocation_testing.checkAllAllocationFailures(
        testing.allocator,
        parseAndDeinitSource,
        .{
            \\document
            \\  let value = 1
            \\end
            \\
        },
    );
    try allocation_testing.checkAllAllocationFailures(
        testing.allocator,
        parseAndDeinitSource,
        .{
            \\page _
            \\  let item = "owned"
            \\end
            \\
        },
    );
    try allocation_testing.checkAllAllocationFailures(
        testing.allocator,
        parseAndDeinitSource,
        .{
            \\page Nested
            \\  if predicate
            \\    let then_value = "then"
            \\  else
            \\    let else_value = "else"
            \\  end
            \\end
            \\
        },
    );
}

test "syntax spec: recovering blocks propagate every allocation failure" {
    try allocation_testing.checkAllAllocationFailures(
        testing.allocator,
        parseRecoveringAndDeinitSource,
        .{
            \\page Recover
            \\  bind x = 1
            \\end
            \\
        },
    );
    try allocation_testing.checkAllAllocationFailures(
        testing.allocator,
        parseRecoveringAndDeinitSource,
        .{
            \\page Recover
            \\  if true
            \\    bind x = 1
            \\  end
            \\end
            \\
        },
    );
}

test "syntax spec: failed type declarations release parsed ownership" {
    try expectParseErrorWithoutLeaks(error.ExpectedChar, "type Theme\n");
    try expectParseErrorWithoutLeaks(error.ExpectedTypeAnnotation,
        \\type Theme {
        \\  label
        \\}
        \\
    );
    try expectParseErrorWithoutLeaks(error.ExpectedChar,
        \\type Card {
        \\  label: String = "caption"
        \\
    );
}

test "syntax spec: type declarations survive every allocation failure" {
    try allocation_testing.checkAllAllocationFailures(
        testing.allocator,
        parseAndDeinitSource,
        .{
            \\type Card {
            \\  handler: Selection<(Page -> Placement)?> = build
            \\}
            \\
        },
    );
    try allocation_testing.checkAllAllocationFailures(
        testing.allocator,
        parseAndDeinitSource,
        .{
            \\type Theme {
            \\  handler: Selection<(Page -> Placement)?> = build
            \\}
            \\
        },
    );
}

test "syntax spec: optional types compose with functions and selections" {
    var parsed = try parse(
        \\fn keep(callback: (Page -> Placement)?, maker: Page -> Placement?, items: Selection<Text>?) -> Void
        \\end
        \\
    );
    defer parsed.deinit();

    const keep = parsed.module.functions.items[0];
    const callback = keep.params.items[0].ty;
    try testing.expectEqual(Type.Kind.optional, callback.kind);
    try testing.expectEqual(Type.Kind.function, callback.optional_child.?.kind);
    try testing.expectEqual(Type.Kind.page, callback.optional_child.?.fn_params[0].kind);
    try testing.expectEqual(Type.Kind.placement, callback.optional_child.?.fn_result.?.kind);

    const maker = keep.params.items[1].ty;
    try testing.expectEqual(Type.Kind.function, maker.kind);
    try testing.expectEqual(Type.Kind.optional, maker.fn_result.?.kind);
    try testing.expectEqual(Type.Kind.placement, maker.fn_result.?.optional_child.?.kind);

    const items = keep.params.items[2].ty;
    try testing.expectEqual(Type.Kind.optional, items.kind);
    try testing.expectEqual(Type.Kind.selection, items.optional_child.?.kind);
    try testing.expectEqual(Type.Kind.unresolved, items.optional_child.?.selectionItem().kind);
    try testing.expectEqualStrings("Text", items.optional_child.?.selectionItem().class_name.?);
}

test "syntax spec: failed function declarations release parsed ownership" {
    try expectParseErrorWithoutLeaks(
        error.ExpectedChar,
        "fn bad(items: Selection<(Page -> Placement)?) -> Void\nend\n",
    );
    try expectParseErrorWithoutLeaks(error.RequiredParameterAfterDefault,
        \\fn bad(a: Number = 1, b: Number) -> Number
        \\  return a
        \\end
        \\
    );
    try expectParseErrorWithoutLeaks(error.ExpectedReturn,
        \\fn bad() -> Number
        \\  let x = 1
        \\end
        \\
    );
}

test "syntax spec: expression parsing survives every allocation failure" {
    const source =
        \\import std:text as classes
        \\enum Align { left center }
        \\type Card {
        \\  label: String = "caption"
        \\}
        \\type Theme {
        \\  body: String = "body"
        \\}
        \\const default_tone: String = "soft"
        \\fn choose(callback: (Page -> Placement)?, tone: String = "soft") -> Placement
        \\  let applied = ((value: String) |-> classes::text(value))(tone)
        \\  let updated = Theme { body = tone } with {
        \\    body.text.size = -(1 + 2)
        \\  }
        \\  if docctx().background_fill?
        \\    return callback(pagectx()).body ?? updated
        \\  else
        \\    return applied
        \\  end
        \\end
        \\document
        \\  let title = "deck"
        \\end
        \\page Expressions
        \\  let card = Card { label = default_tone }
        \\  docctx().layout_h_center_offset = 42
        \\  ~ card.left == page.left - 10
        \\  text "caption"
        \\end
        \\
    ;
    try allocation_testing.checkAllAllocationFailures(
        testing.allocator,
        parseAndDeinitSource,
        .{source},
    );
}

test "syntax spec: failed parenthesized expressions release parsed ownership" {
    try expectParseErrorWithoutLeaks(error.ExpectedChar,
        \\page Broken
        \\  let value = (text("x")
        \\end
        \\
    );
}

test "syntax spec: module cloning survives every allocation failure" {
    const source =
        \\type Card {
        \\  label: String = "caption"
        \\}
        \\fn choose(tone: String = "soft") -> Placement
        \\  let applied = ((value: String) |-> text(value))(tone)
        \\  let updated = Card { label = tone } with { label = applied }
        \\  return docctx().background_fill? ?? updated
        \\end
        \\page Expressions
        \\  let value = choose("loud")
        \\end
        \\
    ;
    var parsed = try parse(source);
    defer parsed.deinit();
    try allocation_testing.checkAllAllocationFailures(
        testing.allocator,
        cloneAndDeinitModule,
        .{&parsed.module},
    );
}

test "syntax spec: paired functions survive every allocation failure" {
    try allocation_testing.checkAllAllocationFailures(
        testing.allocator,
        parseAndDeinitSource,
        .{
            \\fn/! note(text_value: String, tone: String = "soft") -> Text
            \\  return text(text_value)
            \\end
            \\
        },
    );
}

test "syntax spec: qualified type names parse in annotations and type parameters" {
    const source =
        \\import std:text as classes
        \\
        \\fn keep(value: classes::TextStyle, items: Selection<classes::Text>) -> Placed<classes::Text>
        \\  return value
        \\end
        \\
    ;
    var parsed = try parse(source);
    defer parsed.deinit();

    const keep = parsed.module.functions.items[0];
    try testing.expectEqual(Type.Kind.unresolved, keep.params.items[0].ty.kind);
    try testing.expectEqualStrings("classes::TextStyle", keep.params.items[0].ty.class_name.?);
    try testing.expectEqualStrings("classes::TextStyle", source[keep.params.items[0].ty.class_name_span.?.start..keep.params.items[0].ty.class_name_span.?.end]);
    try testing.expectEqual(Type.Kind.selection, keep.params.items[1].ty.kind);
    try testing.expectEqualStrings("classes::Text", keep.params.items[1].ty.selectionItem().class_name.?);
    try testing.expectEqualStrings("classes::Text", source[keep.params.items[1].ty.selectionItem().class_name_span.?.start..keep.params.items[1].ty.selectionItem().class_name_span.?.end]);
    try testing.expectEqual(Type.Kind.placed, keep.result_type.kind);
    try testing.expectEqualStrings("classes::Text", keep.result_type.placedInput().?.class_name.?);
    try testing.expectEqualStrings("classes::Text", source[keep.result_type.placedInput().?.class_name_span.?.start..keep.result_type.placedInput().?.class_name_span.?.end]);
}

test "syntax spec: qualified record literals and enum targets parse" {
    var parsed = try parse(
        \\import std:text as classes
        \\
        \\page Values
        \\  let style = classes::TextStyle { size = 32 }
        \\  let align = classes::Align.left
        \\end
        \\
    );
    defer parsed.deinit();

    const statements = parsed.module.pages.items[0].statements.items;
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

    const statements = parsed.module.pages.items[0].statements.items;
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

test "syntax spec: type field defaults are parsed as expressions" {
    var parsed = try parse(
        \\enum Align { left center right }
        \\type Card {
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

    const card = parsed.module.records.items[0];
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
        \\  let fill = docctx().background_fill ?? c"0,0,0"
        \\  let has_fill = docctx().background_fill?
        \\  let color = text("x").text_markdown_code_fill ?? c"0,0,0"
        \\end
        \\
    );
    defer parsed.deinit();

    const statements = parsed.module.pages.items[0].statements.items;
    switch (statements[0].kind.let_binding.expr) {
        .coalesce => |coalesce| {
            const fill = try expectMember(coalesce.target.*, "background_fill");
            _ = try expectCall(fill.target.*, "docctx", 0);
            try expectColor(coalesce.fallback.*, "0,0,0");
        },
        else => return error.ExpectedCoalesceExpr,
    }
    switch (statements[1].kind.let_binding.expr) {
        .optional_check => |optional_check| {
            const fill = try expectMember(optional_check.target.*, "background_fill");
            _ = try expectCall(fill.target.*, "docctx", 0);
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

test "syntax spec: optional members preserve chains and cloning" {
    var parsed = try parse("page main\nlet width = style.marker?.nested?.width ?? 0\nend\n");
    defer parsed.deinit();
    var copy = try parsed.module.clone(testing.allocator);
    defer copy.deinit(testing.allocator);
    const expression = copy.pages.items[0].statements.items[0].kind.let_binding.expr.coalesce.target.*;
    const width = try expectMember(expression, "width");
    try testing.expect(width.optional);
    const nested = try expectMember(width.target.*, "nested");
    try testing.expect(nested.optional);
    const marker = try expectMember(nested.target.*, "marker");
    try testing.expect(!marker.optional);
}

test "syntax spec: incomplete optional members preserve a member name hole" {
    var parsed = try parseRecovering("page main\nlet width = style.marker?.\nlet ok = 1\nend\n");
    defer parsed.deinit();
    const member = parsed.result.module.pages.items[0].statements.items[0].kind.let_binding.expr.member;
    try testing.expect(member.optional);
    const hole = member.name_hole.?;
    try testing.expectEqual(syntax.HoleKind.member_name, parsed.result.holes.holes[hole].kind);
    try testing.expectEqualStrings("ok", parsed.result.module.pages.items[0].statements.items[1].kind.let_binding.name);
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

    const expr = parsed.module.pages.items[0].statements.items[0].kind.let_binding.expr;
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

    const expr = parsed.module.pages.items[0].statements.items[0].kind.let_binding.expr;
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
        \\          text(
        \\            str(page_index(page_value))
        \\          )
        \\        )
        \\  )
        \\end
        \\
    );
    defer parsed.deinit();

    const expr = parsed.module.pages.items[0].statements.items[0].kind.let_binding.expr;
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
    const program = &parsed.module;

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

fn expectComposition(expr: ast.Expr, mode: ast.GroupComposition) !ast.CallExpr {
    const result = try expectCall(expr, "group", 2);
    try testing.expectEqual(mode, result.callee.composition.?);
    try testing.expect(result.callee.is_operator);
    try testing.expect(result.callee.qualifier == null);
    try testing.expectEqual(@as(usize, 2), result.arg_spans.items.len);
    return result;
}

test "syntax spec: composition preserves its operation and associates left" {
    var parsed = try parse(
        \\page Composition
        \\  let horizontal = a || b || c
        \\  let vertical = a // b // c
        \\  let compact = a||b
        \\end
    );
    defer parsed.deinit();
    const statements = parsed.module.pages.items[0].statements.items;
    for ([_]ast.GroupComposition{ .horizontal, .vertical }, 0..) |name, index| {
        const outer = try expectComposition(statements[index].kind.let_binding.expr, name);
        const inner = try expectComposition(outer.args.items[0], name);
        try expectIdent(inner.args.items[0], "a");
        try expectIdent(inner.args.items[1], "b");
        try expectIdent(outer.args.items[1], "c");
    }
    _ = try expectComposition(statements[2].kind.let_binding.expr, .horizontal);
}

test "syntax spec: parentheses preserve mixed and same direction compositions" {
    var parsed = try parse(
        \\page Composition
        \\  let nested = a || (b // c)
        \\  let divided = (a || b) // (c || d)
        \\  let right_nested = a || (b || c)
        \\end
    );
    defer parsed.deinit();
    const statements = parsed.module.pages.items[0].statements.items;
    const nested = try expectComposition(statements[0].kind.let_binding.expr, .horizontal);
    try expectIdent(nested.args.items[0], "a");
    _ = try expectComposition(nested.args.items[1], .vertical);
    const divided = try expectComposition(statements[1].kind.let_binding.expr, .vertical);
    _ = try expectComposition(divided.args.items[0], .horizontal);
    _ = try expectComposition(divided.args.items[1], .horizontal);
    const right_nested = try expectComposition(statements[2].kind.let_binding.expr, .horizontal);
    try expectIdent(right_nested.args.items[0], "a");
    _ = try expectComposition(right_nested.args.items[1], .horizontal);
}

test "syntax spec: composition binds less tightly than existing expression operators" {
    var parsed = try parse(
        \\page Composition
        \\  let arithmetic = 1 + 2 * -3 // 8 / 2
        \\  let concatenated = "a" ++ "b" || "c"
        \\  let fallback = optional ?? a || b ?? c
        \\  let checked = a? || !b
        \\end
    );
    defer parsed.deinit();
    const statements = parsed.module.pages.items[0].statements.items;
    const arithmetic = try expectComposition(statements[0].kind.let_binding.expr, .vertical);
    const add = try expectCall(arithmetic.args.items[0], "add", 2);
    _ = try expectCall(add.args.items[1], "mul", 2);
    const div = try expectCall(arithmetic.args.items[1], "div", 2);
    try expectNumber(div.args.items[0], 8);
    try expectNumber(div.args.items[1], 2);
    const concatenated = try expectComposition(statements[1].kind.let_binding.expr, .horizontal);
    _ = try expectCall(concatenated.args.items[0], "concat", 2);
    const fallback = try expectComposition(statements[2].kind.let_binding.expr, .horizontal);
    try expectIdent(fallback.args.items[0].coalesce.target.*, "optional");
    try expectIdent(fallback.args.items[0].coalesce.fallback.*, "a");
    try expectIdent(fallback.args.items[1].coalesce.target.*, "b");
    try expectIdent(fallback.args.items[1].coalesce.fallback.*, "c");
    const checked = try expectComposition(statements[3].kind.let_binding.expr, .horizontal);
    try expectIdent(checked.args.items[0].optional_check.target.*, "a");
    _ = try expectCall(checked.args.items[1], "not", 1);
}

test "syntax spec: composition expression statements coexist with call and line text sugar" {
    var parsed = try parse(
        \\page Composition
        \\  a || b
        \\  (a || b) // c
        \\  text("x") || image("y")
        \\  text "x" || image "y"
        \\  parts.left || parts.right
        \\  place!(a || (b // c))
        \\  text foo || bar // baz
        \\  text - bullet
        \\  text "literal"
        \\  1 || 2
        \\end
    );
    defer parsed.deinit();
    const statements = parsed.module.pages.items[0].statements.items;
    try testing.expectEqual(@as(usize, 10), statements.len);
    _ = try expectComposition(statements[0].kind.expr_stmt, .horizontal);
    _ = try expectComposition(statements[1].kind.expr_stmt, .vertical);
    for (statements[2..4]) |statement| {
        const composition = try expectComposition(statement.kind.expr_stmt, .horizontal);
        const text_call = try expectCall(composition.args.items[0], "text", 1);
        const image_call = try expectCall(composition.args.items[1], "image", 1);
        try expectString(text_call.args.items[0], "x");
        try expectString(image_call.args.items[0], "y");
    }
    const members = try expectComposition(statements[4].kind.expr_stmt, .horizontal);
    _ = try expectMember(members.args.items[0], "left");
    _ = try expectMember(members.args.items[1], "right");
    const placing = try expectCall(statements[5].kind.expr_stmt, "place!", 1);
    _ = try expectComposition(placing.args.items[0], .horizontal);
    for ([_][]const u8{ "foo || bar // baz", "- bullet", "literal" }, 6..) |expected, index| {
        const text_call = try expectCall(statements[index].kind.expr_stmt, "text", 1);
        try expectString(text_call.args.items[0], expected);
    }
    _ = try expectComposition(statements[9].kind.expr_stmt, .horizontal);
}

test "syntax spec: composition continues before and after the operator across trivia" {
    var parsed = try parse(
        \\page Composition
        \\  let nested = a || ;; next operand
        \\    ;; explanation
        \\    (
        \\      b //
        \\      c
        \\    )
        \\  let next = d
        \\end
    );
    defer parsed.deinit();
    const statements = parsed.module.pages.items[0].statements.items;
    try testing.expectEqual(@as(usize, 2), statements.len);
    const nested = try expectComposition(statements[0].kind.let_binding.expr, .horizontal);
    _ = try expectComposition(nested.args.items[1], .vertical);
    try expectIdent(statements[1].kind.let_binding.expr, "d");

    try parseAndDeinitSource(testing.allocator, "page Valid\n  let value = a\n    || b\nend\n");
    try parseAndDeinitSource(testing.allocator, "page Valid\n  let value = (a\n    || b)\nend\n");
}

test "syntax spec: composition preserves punctuation in line text arguments" {
    const source_text =
        \\page LineText
        \\  text! ...
        \\  text! ? question
        \\  text! with explanation
        \\  text! // raw vertical marks
        \\  text! || raw horizontal marks
        \\  text! ?? question
        \\  text! { explanation
        \\  theme::text! ...
        \\  text ...
        \\  text ? question
        \\  text with explanation
        \\  text { explanation
        \\  text . dot
        \\  a ?? b || c
        \\  parts.left || b
        \\  (parts . left) || b
        \\  a? || b
        \\  text! "A" || text!("B")
        \\end
    ;
    var parsed = try parse(source_text);
    defer parsed.deinit();
    const statements = parsed.module.pages.items[0].statements.items;
    try testing.expectEqual(@as(usize, 18), statements.len);
    const expected_text = [_][]const u8{
        "...",              "? question",    "with explanation", "// raw vertical marks", "|| raw horizontal marks",
        "?? question",      "{ explanation", "...",              "...",                   "? question",
        "with explanation", "{ explanation", ". dot",
    };
    for (expected_text, 0..) |expected, index| {
        const call = try expectCall(statements[index].kind.expr_stmt, if (index < 8) "text!" else "text", 1);
        try expectString(call.args.items[0], expected);
    }
    const fallback = try expectComposition(statements[13].kind.expr_stmt, .horizontal);
    try expectIdent(fallback.args.items[0].coalesce.target.*, "a");
    try expectIdent(fallback.args.items[0].coalesce.fallback.*, "b");
    for (statements[14..16]) |statement| {
        const composition = try expectComposition(statement.kind.expr_stmt, .horizontal);
        _ = try expectMember(composition.args.items[0], "left");
    }
    const checked = try expectComposition(statements[16].kind.expr_stmt, .horizontal);
    try expectIdent(checked.args.items[0].optional_check.target.*, "a");
    const placed = try expectComposition(statements[17].kind.expr_stmt, .horizontal);
    for (placed.args.items) |operand| _ = try expectCall(operand, "text!", 1);
    try allocation_testing.checkAllAllocationFailures(testing.allocator, parseAndDeinitSource, .{source_text});
}

test "syntax spec: mixed composition diagnostics point to the second direction" {
    for ([_][]const u8{
        "page Bad\n  a || b // c\nend\n",
        "page Bad\n  a // b || c\nend\n",
        "page Bad\n  let value = a || b ?? c // d\nend\n",
        "page Bad\n  let value = a || b || c // d\nend\n",
    }) |source_text| {
        const first_horizontal = std.mem.indexOf(u8, source_text, "||").?;
        const first_vertical = std.mem.indexOf(u8, source_text, "//").?;
        const second_direction = @max(first_horizontal, first_vertical);
        try expectParseErrorSpan(error.MixedCompositionDirections, source_text, second_direction, second_direction + 2);
        try expectParseErrorWithoutLeaks(error.MixedCompositionDirections, source_text);
    }
}

test "syntax spec: missing composition operands report expression errors without leaks" {
    for ([_][]const u8{
        "page Bad\n  a ||\nend\n",
        "page Bad\n  let value = a //;\nend\n",
        "page Bad\n  let value = place!(a ||)\nend\n",
        "page Bad\n  let value = f(a //, b)\nend\n",
        "page Bad\n  let value = a ||",
    }) |source_text| try expectParseErrorWithoutLeaks(error.ExpectedExpression, source_text);
}

test "syntax spec: composition preserves operator and operand source spans" {
    const source_text = "page Span\n  let layout = a || (b // c) || d\nend\n";
    var parsed = try parse(source_text);
    defer parsed.deinit();
    const outer = try expectComposition(parsed.module.pages.items[0].statements.items[0].kind.let_binding.expr, .horizontal);
    try expectSpanText(source_text, outer.callee.name_span.?, "||");
    try expectSpanText(source_text, outer.callee.span.?, "||");
    try expectSpanText(source_text, outer.arg_spans.items[0], "a || (b // c)");
    try expectSpanText(source_text, outer.arg_spans.items[1], "d");
    const horizontal = try expectComposition(outer.args.items[0], .horizontal);
    try expectSpanText(source_text, horizontal.arg_spans.items[0], "a");
    try expectSpanText(source_text, horizontal.arg_spans.items[1], "(b // c)");
    const vertical = try expectComposition(horizontal.args.items[1], .vertical);
    try expectSpanText(source_text, vertical.callee.name_span.?, "//");
    try expectSpanText(source_text, vertical.arg_spans.items[0], "b");
    try expectSpanText(source_text, vertical.arg_spans.items[1], "c");
}

test "syntax spec: raw strings preserve composition markers" {
    var parsed = try parse(
        \\page Text
        \\  text "a || b // c"
        \\  text """
        \\a || b // c
        \\"""
        \\  text <<
        \\a || b // c
        \\>>
        \\end
    );
    defer parsed.deinit();
    const statements = parsed.module.pages.items[0].statements.items;
    try testing.expectEqual(@as(usize, 3), statements.len);
    for (statements) |statement| {
        const call = try expectCall(statement.kind.expr_stmt, "text", 1);
        try expectString(call.args.items[0], "a || b // c");
    }
}

test "syntax spec: recovering composition retains missing operands and following bindings" {
    var parsed = try parseRecovering(
        \\page Recover
        \\  a ||
        \\  let ok = 1
        \\  let incomplete = place!(b //)
        \\  let after = 2
        \\end
    );
    defer parsed.deinit();
    const statements = parsed.result.module.pages.items[0].statements.items;
    try testing.expectEqual(@as(usize, 4), statements.len);
    const horizontal = try expectComposition(statements[0].kind.expr_stmt, .horizontal);
    try testing.expect(horizontal.args.items[1] == .hole);
    try testing.expectEqualStrings("ok", statements[1].kind.let_binding.name);
    const placing = try expectCall(statements[2].kind.let_binding.expr, "place!", 1);
    const vertical = try expectComposition(placing.args.items[0], .vertical);
    try testing.expect(vertical.args.items[1] == .hole);
    try testing.expectEqualStrings("after", statements[3].kind.let_binding.name);
    try testing.expectEqual(@as(usize, 2), parsed.result.holes.holes.len);
    for (parsed.result.holes.diagnostics) |diagnostic| try testing.expectEqual(error.ExpectedExpression, diagnostic.err);
}

test "syntax spec: recovering mixed compositions preserves subsequent statements" {
    var parsed = try parseRecovering("page Recover\n  a || b // c\n  let ok = 1\nend\n");
    defer parsed.deinit();
    const statements = parsed.result.module.pages.items[0].statements.items;
    try testing.expectEqual(@as(usize, 2), statements.len);
    try testing.expect(statements[0].kind == .hole);
    try testing.expectEqualStrings("ok", statements[1].kind.let_binding.name);
    try testing.expectEqual(error.MixedCompositionDirections, parsed.result.holes.diagnostics[0].err);
    try allocation_testing.checkAllAllocationFailures(testing.allocator, parseRecoveringAndDeinitSource, .{"page Recover\ntext(\"A\")\n|| text(\"B\")\n//\ntext <<\nC\n>>\nlet ok = 1\nend\n"});
}

test "syntax spec: missing composition operands preserve conditional and constraint statements" {
    const source_text =
        \\page Recover
        \\  a ||
        \\  if true
        \\    let inside = 1
        \\  end
        \\  b //
        \\  ~ a.left == page.left + 80
        \\  c ||
        \\  ~!~ a.top == page.top - 80
        \\  let after = 2
        \\end
        \\page Next
        \\end
    ;
    var parsed = try parseRecovering(source_text);
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 2), parsed.result.module.pages.items.len);
    const statements = parsed.result.module.pages.items[0].statements.items;
    try testing.expectEqual(@as(usize, 7), statements.len);
    for ([_]usize{ 0, 2, 4 }, [_]ast.GroupComposition{ .horizontal, .vertical, .horizontal }) |index, name| {
        const composition = try expectComposition(statements[index].kind.expr_stmt, name);
        try testing.expect(composition.args.items[1] == .hole);
    }
    const conditional = statements[1].kind.if_stmt;
    try testing.expectEqual(@as(usize, 1), conditional.then_statements.items.len);
    try testing.expectEqualStrings("inside", conditional.then_statements.items[0].kind.let_binding.name);
    try testing.expect(statements[3].kind == .constrain);
    try testing.expect(statements[5].kind == .constrain);
    try testing.expectEqualStrings("after", statements[6].kind.let_binding.name);
    try testing.expectEqual(@as(usize, 3), parsed.result.holes.holes.len);
    for (parsed.result.holes.diagnostics) |diagnostic| try testing.expectEqual(error.ExpectedExpression, diagnostic.err);
    try allocation_testing.checkAllAllocationFailures(testing.allocator, parseRecoveringAndDeinitSource, .{source_text});
    for ([_][]const u8{
        "page Bad\n a ||\n if true\n end\nend\n",
        "page Bad\n a ||\n ~ a.left == page.left\nend\n",
        "page Bad\n a ||\n return\nend\n",
    }) |invalid| try expectParseErrorWithoutLeaks(error.ExpectedExpression, invalid);
}

test "syntax spec: unsupported statement names remain composition operands" {
    var parsed = try parse("page Names\n a ||\n for\n b //\n in\n c ||\n property\n d //\n then\nend\n");
    defer parsed.deinit();
    const statements = parsed.module.pages.items[0].statements.items;
    try testing.expectEqual(@as(usize, 4), statements.len);
    for (statements, [_][]const u8{ "for", "in", "property", "then" }, [_]ast.GroupComposition{ .horizontal, .vertical, .horizontal, .vertical }) |statement, name, mode| {
        const composition = try expectComposition(statement.kind.expr_stmt, mode);
        try expectIdent(composition.args.items[1], name);
    }
}

test "syntax spec: composition parsing and cloning survive every allocation failure" {
    const source_text = "page Composition\n  a || (b // c) || text(\"d\")\nend\n";
    try allocation_testing.checkAllAllocationFailures(testing.allocator, parseAndDeinitSource, .{source_text});
    var parsed = try parse(source_text);
    defer parsed.deinit();
    try allocation_testing.checkAllAllocationFailures(testing.allocator, cloneAndDeinitModule, .{&parsed.module});
    try allocation_testing.checkAllAllocationFailures(testing.allocator, parseRecoveringAndDeinitSource, .{"page Recover\n  a ||\n  let ok = 1\nend\n"});
}

test "syntax spec: equal composition chains preserve grouping and spans" {
    const source_text =
        \\page Equal
        \\  let flat = a|=|b|=|c
        \\  let grouped = (a |=| b) |=| c
        \\  let vertical = a/=/b/=/c
        \\  let mixed = a |=| (b // c)
        \\  let division = a / 2 /=/ b / 3
        \\end
    ;
    var parsed = try parse(source_text);
    defer parsed.deinit();
    const statements = parsed.module.pages.items[0].statements.items;
    for ([_]usize{ 0, 2 }, [_]ast.GroupComposition{ .equal_horizontal, .equal_vertical }) |index, mode| {
        const split = try expectCall(statements[index].kind.let_binding.expr, "group", 3);
        try testing.expectEqual(mode, split.callee.composition.?);
        try testing.expect(split.callee.is_operator);
        try expectSpanText(source_text, split.callee.span.?, if (index == 0) "|=|" else "/=/");
        for (split.args.items, [_][]const u8{ "a", "b", "c" }) |operand, name| try expectIdent(operand, name);
        try expectSpanText(source_text, split.arg_spans.items[2], "c");
    }
    const grouped = try expectComposition(statements[1].kind.let_binding.expr, .equal_horizontal);
    _ = try expectComposition(grouped.args.items[0], .equal_horizontal);
    const mixed = try expectComposition(statements[3].kind.let_binding.expr, .equal_horizontal);
    _ = try expectComposition(mixed.args.items[1], .vertical);
    const division = try expectComposition(statements[4].kind.let_binding.expr, .equal_vertical);
    for (division.args.items) |operand| _ = try expectCall(operand, "div", 2);
    try allocation_testing.checkAllAllocationFailures(testing.allocator, parseAndDeinitSource, .{source_text});
    try allocation_testing.checkAllAllocationFailures(testing.allocator, cloneAndDeinitModule, .{&parsed.module});
}

test "syntax spec: equal compositions diagnose mixed operators and recover missing operands" {
    const operators = [_][]const u8{ "||", "//", "|=|", "/=/" };
    for (operators) |left| {
        for (operators) |right| {
            if (std.mem.eql(u8, left, right)) continue;
            const source_text = try std.fmt.allocPrint(testing.allocator, "page Bad\n let g = a {s} b {s} c\nend\n", .{ left, right });
            defer testing.allocator.free(source_text);
            const position = std.mem.lastIndexOf(u8, source_text, right).?;
            try expectParseErrorSpan(error.MixedCompositionDirections, source_text, position, position + right.len);
            try expectParseErrorWithoutLeaks(error.MixedCompositionDirections, source_text);
        }
    }
    const incomplete = "page Recover\n a |=| b |=|\n let ok = 1\n c /=/\nend\n";
    var parsed = try parseRecovering(incomplete);
    defer parsed.deinit();
    const statements = parsed.result.module.pages.items[0].statements.items;
    try testing.expectEqual(@as(usize, 3), statements.len);
    const horizontal = try expectCall(statements[0].kind.expr_stmt, "group", 3);
    try testing.expectEqual(ast.GroupComposition.equal_horizontal, horizontal.callee.composition.?);
    try testing.expect(horizontal.args.items[2] == .hole);
    try testing.expectEqualStrings("ok", statements[1].kind.let_binding.name);
    try allocation_testing.checkAllAllocationFailures(testing.allocator, parseRecoveringAndDeinitSource, .{incomplete});
}

test "syntax spec: equal operators continue after trivia and remain literal in text" {
    var parsed = try parse(
        \\page Text
        \\  a |=| ;; continue
        \\    b
        \\  c /=/
        \\    d
        \\  text! |=| raw
        \\  text! /=/ raw
        \\  text "a |=| b /=/ c"
        \\end
    );
    defer parsed.deinit();
    const statements = parsed.module.pages.items[0].statements.items;
    _ = try expectComposition(statements[0].kind.expr_stmt, .equal_horizontal);
    _ = try expectComposition(statements[1].kind.expr_stmt, .equal_vertical);
    for ([_][]const u8{ "|=| raw", "/=/ raw", "a |=| b /=/ c" }, 2..) |value, index| {
        const call = try expectCall(statements[index].kind.expr_stmt, if (index < 4) "text!" else "text", 1);
        try expectString(call.args.items[0], value);
    }
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
    const statements = parsed.module.pages.items[0].statements.items;

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
    const program = &parsed.module;

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

test "syntax spec: chevron blocks close at the first line-leading delimiter" {
    const source =
        \\page Text
        \\  code <<
        \\first
        \\  inline >> remains content
        \\  > single chevron remains content
        \\second
        \\  >> ;; terminator comment
        \\end
        \\
    ;
    var parsed = try parse(source);
    defer parsed.deinit();

    const call = try expectCall(parsed.module.pages.items[0].statements.items[0].kind.expr_stmt, "code", 1);
    switch (call.args.items[0]) {
        .string => |literal| {
            try testing.expectEqualStrings("first\n  inline >> remains content\n  > single chevron remains content\nsecond", literal.text);
            const span = literal.source_span orelse return error.ExpectedStringSourceSpan;
            try testing.expectEqualStrings(literal.text, source[span.start..span.end]);
        },
        else => return error.ExpectedStringExpr,
    }
}

test "syntax spec: chevron suffixes belong to the enclosing expression" {
    const operators = [_][]const u8{ "||", "//", "|=|", "/=/" };
    for (operators, [_]ast.GroupComposition{ .horizontal, .vertical, .equal_horizontal, .equal_vertical }) |operator, name| {
        for ([_][]const u8{ "", " ", "\t" }) |spacing| {
            const text = try std.fmt.allocPrint(testing.allocator, "page Blocks\nlet g = text << ;; header\nA\n\t>>{s}{s} ;; continuation\ntext <<\nB\n>>\nend\n", .{ spacing, operator });
            defer testing.allocator.free(text);
            var parsed = try parse(text);
            defer parsed.deinit();
            const expression = parsed.module.pages.items[0].statements.items[0].kind.let_binding.expr;
            const pair = try expectComposition(expression, name);
            const left = try expectCall(pair.args.items[0], "text", 1);
            const right = try expectCall(pair.args.items[1], "text", 1);
            try expectString(left.args.items[0], "A");
            try expectString(right.args.items[0], "B");
        }
    }
    const nested = "page Blocks\nlet g = (text <<\nA\n>>) || text(<< ;; header\nB\n>>)\nend\n";
    var parsed = try parse(nested);
    defer parsed.deinit();
    _ = try expectComposition(parsed.module.pages.items[0].statements.items[0].kind.let_binding.expr, .horizontal);
    try allocation_testing.checkAllAllocationFailures(testing.allocator, parseAndDeinitSource, .{nested});
    try allocation_testing.checkAllAllocationFailures(testing.allocator, parseRecoveringAndDeinitSource, .{nested});
    var crlf = try parse("page Blocks\r\nlet s = << ;; header\r\nA\r\n\t>> ++ \"B\"\r\nend\r\n");
    defer crlf.deinit();
    _ = try expectCall(crlf.module.pages.items[0].statements.items[0].kind.let_binding.expr, "concat", 2);
}

test "syntax spec: block and quoted strings accept the same composition continuations" {
    for ([_][]const u8{ "text(\"A\")", "text <<\nA\n>>" }) |left| {
        for ([_][]const u8{ "\n", "\n\n", "\n;; comment\n", "\r\n;; comment\r\n", "\r\n\t" }) |separator| {
            for ([_][]const u8{ "||", "//", "|=|", "/=/" }) |operator| {
                const text = try std.fmt.allocPrint(testing.allocator, "page Blocks\nlet g = {s}{s}{s} text(\"B\")\nend\n", .{ left, separator, operator });
                defer testing.allocator.free(text);
                var parsed = try parse(text);
                defer parsed.deinit();
                try testing.expectEqual(@as(usize, 1), parsed.module.pages.items[0].statements.items.len);
                var recovered = try parseRecovering(text);
                defer recovered.deinit();
                try testing.expectEqual(@as(usize, 0), recovered.result.holes.diagnostics.len);
            }
        }
    }
}

test "syntax spec: block diagnostics point to the opener without cascading end errors" {
    for ([_][]const u8{
        "const message: String = <<\nmissing\n",
        "fn label() -> String\nreturn <<\nmissing\n",
        "page Blocks\nlet s = <<\nmissing\nend\n",
        "page Blocks\ntext(<<\nmissing\nend\n",
        "page Blocks\nif true\ntext(<<\nmissing\nend\nend\n",
    }) |text| {
        const opening = std.mem.indexOf(u8, text, "<<").?;
        try expectParseErrorSpan(error.UnterminatedBlockString, text, opening, opening + 2);
        var recovered = try parseRecovering(text);
        defer recovered.deinit();
        try testing.expectEqual(@as(usize, 1), recovered.result.holes.diagnostics.len);
        const diagnostic = recovered.result.holes.diagnostics[0];
        try testing.expectEqual(error.UnterminatedBlockString, diagnostic.err);
        try testing.expectEqual(ast.Span{ .start = opening, .end = opening + 2 }, diagnostic.span);
        try allocation_testing.checkAllAllocationFailures(testing.allocator, parseRecoveringAndDeinitSource, .{text});
    }
    const punctuation = "page Blocks\nlet g = (text <<\nA\n>> || text(\"B\")\nend\n";
    const diagnostic = try expectParseErrorDiagnostic(error.ExpectedChar, punctuation);
    try testing.expectEqualStrings("')'", diagnostic.expected.?);
    try testing.expectEqualStrings("end", diagnostic.found.?);
    var recovered = try parseRecovering(punctuation);
    defer recovered.deinit();
    try testing.expectEqualStrings("')'", recovered.result.holes.diagnostics[0].expected.?);
    const unclosed_call = "page Blocks\ntext(<<\nA\n>>\nend\n";
    var call_recovered = try parseRecovering(unclosed_call);
    defer call_recovered.deinit();
    try testing.expectEqual(@as(usize, 1), call_recovered.result.holes.diagnostics.len);
    try testing.expectEqualStrings("')'", call_recovered.result.holes.diagnostics[0].expected.?);
    try testing.expectEqualStrings("end", call_recovered.result.holes.diagnostics[0].found.?);
    try allocation_testing.checkAllAllocationFailures(testing.allocator, parseRecoveringAndDeinitSource, .{unclosed_call});
    const header = try expectParseErrorDiagnostic(error.ExpectedLineBreak, "page Blocks\ntext << unexpected\nend\n");
    try testing.expectEqualStrings("unexpected", header.found.?);
}

test "syntax spec: mixed composition diagnostics name both actual operators" {
    const operators = [_][]const u8{ "||", "//", "|=|", "/=/" };
    for (operators) |left| {
        for (operators) |right| {
            if (std.mem.eql(u8, left, right)) continue;
            const text = try std.fmt.allocPrint(testing.allocator, "page Mixed\na {s} b {s} c\nend\n", .{ left, right });
            defer testing.allocator.free(text);
            const expected = try std.fmt.allocPrint(testing.allocator, "mixed '{s}' and '{s}'", .{ left, right });
            defer testing.allocator.free(expected);
            const diagnostic = try expectParseErrorDiagnostic(error.MixedCompositionDirections, text);
            try testing.expect(std.mem.startsWith(u8, diagnostic.detail.?, expected));
            var recovered = try parseRecovering(text);
            defer recovered.deinit();
            try testing.expectEqualStrings(diagnostic.detail.?, recovered.result.holes.diagnostics[0].detail.?);
        }
    }
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

    const call = try expectCall(parsed.module.pages.items[0].statements.items[0].kind.let_binding.expr, "themed", 2);
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
    const program = &parsed.module;

    const statements = program.pages.items[0].statements.items;
    try testing.expectEqualStrings("local", statements[0].kind.let_binding.name);

    const width = statements[1].kind.constrain;
    try testing.expectEqual(.node, width.target.kind);
    try testing.expectEqualStrings("box", width.target.node_name.?);
    try testing.expectEqual(.right, width.target.anchor);
    try testing.expectEqual(.left, width.source.?.anchor);
    try expectNumber(width.offset.?, 100);

    const left = statements[2].kind.constrain;
    try testing.expectEqual(.left, left.target.anchor);
    try testing.expectEqual(.page, left.source.?.kind);
    try testing.expectEqual(.left, left.source.?.anchor);
    try expectNumber(left.offset.?, 10);

    const right = statements[3].kind.constrain;
    try testing.expectEqual(.right, right.target.anchor);
    try testing.expectEqual(.page, right.source.?.kind);
    const neg = try expectCall(right.offset.?, "neg", 1);
    try expectNumber(neg.args.items[0], 20);

    const property = statements[4].kind.property_set;
    try expectIdent(property.target, "box");
    try expectPath(property.path.items, &.{"left"});
    try expectString(property.value, "red");

    var equality = try parse(
        \\page Equality
        \\  box.left == other.left + 10
        \\end
        \\
    );
    defer equality.deinit();
    try testing.expectEqualStrings("num_eq", equality.module.pages.items[0].statements.items[0].kind.expr_stmt.call.callee.name);
}

test "syntax spec: constraints accept record member anchor paths" {
    var parsed = try parse(
        \\page Layout
        \\  ~ caption.top == parts.root.bottom - 16
        \\end
        \\
    );
    defer parsed.deinit();

    const constraint = parsed.module.pages.items[0].statements.items[0].kind.constrain;
    try testing.expectEqual(.node, constraint.target.kind);
    try testing.expectEqualStrings("caption", constraint.target.node_name.?);
    try testing.expectEqualStrings("caption", constraint.target.node_path.?);
    try testing.expectEqual(.top, constraint.target.anchor);
    try testing.expectEqual(.node, constraint.source.?.kind);
    try testing.expectEqualStrings("parts", constraint.source.?.node_name.?);
    try testing.expectEqualStrings("parts.root", constraint.source.?.node_path.?);
    try testing.expectEqual(.bottom, constraint.source.?.anchor);
}

test "syntax spec: constraint syntax spans follow multiline source" {
    const source = try readFixture("constraints/multiline.ss");
    defer testing.allocator.free(source);
    var parsed = try parse(source);
    defer parsed.deinit();

    const constraint = parsed.module.pages.items[0].statements.items[0].kind.constrain;
    const source_spans = constraint.syntax.?;
    try testing.expectEqualStrings("caption . top", source[source_spans.target.start..source_spans.target.end]);
    try testing.expectEqualStrings("parts . root . bottom", source[source_spans.source.?.start..source_spans.source.?.end]);
    try testing.expectEqualStrings("- (gap + 16)", source[source_spans.offset.?.start..source_spans.offset.?.end]);
}

test "syntax spec: constraint updates accept optional replacement relations" {
    var parsed = try parse(
        \\page Layout
        \\  ~!~ box.left
        \\  ~!~box.top==page.top-24
        \\  ~!~ box.width == 320
        \\  ~!~ box.height
        \\end
        \\
    );
    defer parsed.deinit();

    const statements = parsed.module.pages.items[0].statements.items;
    const discard = statements[0].kind.constrain;
    try testing.expectEqual(.update, discard.action);
    try testing.expectEqual(.anchor, discard.target_kind);
    try testing.expectEqual(.left, discard.target.anchor);
    try testing.expect(discard.source == null);
    try testing.expect(discard.offset == null);

    const replace = statements[1].kind.constrain;
    try testing.expectEqual(.update, replace.action);
    try testing.expectEqual(.top, replace.target.anchor);
    try testing.expectEqual(.page, replace.source.?.kind);
    try testing.expectEqual(.top, replace.source.?.anchor);
    const neg = try expectCall(replace.offset.?, "neg", 1);
    try expectNumber(neg.args.items[0], 24);

    const width = statements[2].kind.constrain;
    try testing.expectEqual(.update, width.action);
    try testing.expectEqual(.dimension, width.target_kind);
    try testing.expectEqual(.right, width.target.anchor);
    try testing.expectEqual(.left, width.source.?.anchor);
    try expectNumber(width.offset.?, 320);

    const height = statements[3].kind.constrain;
    try testing.expectEqual(.update, height.action);
    try testing.expectEqual(.dimension, height.target_kind);
    try testing.expectEqual(.top, height.target.anchor);
    try testing.expect(height.source == null);
}

test "syntax spec: member expressions stay in the AST" {
    var parsed = try parse(
        \\page Members
        \\  let target = pagectx()
        \\  target.layout_h_center_offset = target.layout_h_center_offset + 1
        \\  docctx().layout_h_center_offset = 42
        \\  let color = target.background_fill ?? c"#000000"
        \\  let has_color = target.background_fill?
        \\end
        \\
    );
    defer parsed.deinit();

    const statements = parsed.module.pages.items[0].statements.items;
    const offset_set = statements[1].kind.property_set;
    try expectIdent(offset_set.target, "target");
    try expectPath(offset_set.path.items, &.{"layout_h_center_offset"});
    const add = try expectCall(offset_set.value, "add", 2);
    _ = try expectMember(add.args.items[0], "layout_h_center_offset");
    try expectNumber(add.args.items[1], 1);

    const doc_prop = statements[2].kind.property_set;
    _ = try expectCall(doc_prop.target, "docctx", 0);
    try expectPath(doc_prop.path.items, &.{"layout_h_center_offset"});
    try expectNumber(doc_prop.value, 42);

    switch (statements[3].kind.let_binding.expr) {
        .coalesce => |coalesce| {
            _ = try expectMember(coalesce.target.*, "background_fill");
            try expectColor(coalesce.fallback.*, "0,0,0");
        },
        else => return error.ExpectedCoalesceExpr,
    }

    switch (statements[4].kind.let_binding.expr) {
        .optional_check => |optional_check| _ = try expectMember(optional_check.target.*, "background_fill"),
        else => return error.ExpectedOptionalCheckExpr,
    }
}

test "syntax spec: chained member assignment targets the enclosing expression" {
    var parsed = try parse(
        \\type PageRef { page: Page }
        \\page Members
        \\  let target = PageRef { page = pagectx() }
        \\  target.page.background_fill = c"#ff0000"
        \\  target.page.layout_h_center_offset = target.page.layout_h_center_offset + 1
        \\end
        \\
    );
    defer parsed.deinit();

    const statements = parsed.module.pages.items[0].statements.items;
    const color_set = statements[1].kind.property_set;
    try expectIdent(color_set.target, "target");
    try expectPath(color_set.path.items, &.{ "page", "background_fill" });
    try expectColor(color_set.value, "1,0,0");

    const offset_set = statements[2].kind.property_set;
    try expectIdent(offset_set.target, "target");
    try expectPath(offset_set.path.items, &.{ "page", "layout_h_center_offset" });
    const add = try expectCall(offset_set.value, "add", 2);
    const read_offset = try expectMember(add.args.items[0], "layout_h_center_offset");
    _ = try expectMember(read_offset.target.*, "page");
    try expectNumber(add.args.items[1], 1);
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

    const statements = parsed.module.pages.items[0].statements.items;
    const layout = statements[0].kind.property_set;
    try expectIdent(layout.target, "box");
    try expectPath(layout.path.items, &.{ "layout", "x" });
    try expectNumber(layout.value, 102);

    const font = statements[1].kind.property_set;
    try expectIdent(font.target, "box");
    try expectPath(font.path.items, &.{ "text", "font", "family" });
    try expectString(font.value, "Avenir");
}

test "syntax spec: place is an ordinary identifier" {
    var parsed = try parse(
        \\page Placement
        \\  let place = 1
        \\  let local = place + 1
        \\end
        \\
    );
    defer parsed.deinit();

    const statements = parsed.module.pages.items[0].statements.items;
    try testing.expectEqualStrings("place", statements[0].kind.let_binding.name);
    const add = try expectCall(statements[1].kind.let_binding.expr, "add", 2);
    switch (add.args.items[0]) {
        .ident => |ident| try testing.expectEqualStrings("place", ident.name),
        else => return error.ExpectedIdentifier,
    }
    try expectNumber(add.args.items[1], 1);
}

test "syntax spec: bare assignment must say let and page dimensions are not targets" {
    try expectParseError(error.AssignmentRequiresLet,
        \\page Bad
        \\  local = 1
        \\end
        \\
    );

    const diagnostic = try expectParseErrorDiagnostic(error.PageCannotBeConstraintTarget,
        \\page Bad
        \\  ~ page.width == 100
        \\end
        \\
    );
    try testing.expectEqualStrings("an object anchor as the constraint target", diagnostic.expected.?);
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

    const statements = parsed.result.module.pages.items[0].statements.items;
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

    const statements = parsed.result.module.pages.items[0].statements.items;
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
    try testing.expectEqual(@as(usize, 1), parsed.result.module.pages.items.len);
    try testing.expectEqualStrings("Recover", parsed.result.module.pages.items[0].name);
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
    const call = parsed.result.module.pages.items[0].statements.items[0].kind.expr_stmt.call;
    try testing.expectEqualStrings("theme", call.callee.qualifier.?);
    try testing.expectEqual(@as(ast.HoleId, 0), call.callee.name_hole.?);
}

test "syntax spec: recovering parse keeps type expression holes" {
    var parsed = try parseRecovering(
        \\fn typed(x:) -> = x
        \\page Recover
        \\  let item: = 1
        \\end
        \\type Broken {
        \\  field:
        \\}
        \\type Widget {
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

    const func = parsed.result.module.functions.items[0];
    try testing.expectEqual(Type.Kind.hole, func.params.items[0].ty.kind);
    try testing.expectEqual(@as(ast.HoleId, 0), func.params.items[0].ty.hole_id.?);
    try testing.expectEqual(Type.Kind.hole, func.result_type.kind);
    try testing.expectEqual(@as(ast.HoleId, 1), func.result_type.hole_id.?);

    const binding = parsed.result.module.pages.items[0].statements.items[0].kind.let_binding;
    try testing.expectEqual(Type.Kind.hole, binding.type_annotation.?.kind);
    try testing.expectEqual(@as(ast.HoleId, 2), binding.type_annotation.?.hole_id.?);

    const record_field = parsed.result.module.records.items[0].fields.items[0];
    try testing.expectEqual(Type.Kind.hole, record_field.value_type.kind);
    try testing.expectEqual(@as(ast.HoleId, 3), record_field.value_type.hole_id.?);

    const second_field = parsed.result.module.records.items[1].fields.items[0];
    try testing.expectEqual(Type.Kind.hole, second_field.value_type.kind);
    try testing.expectEqual(@as(ast.HoleId, 4), second_field.value_type.hole_id.?);
}

test "syntax spec: selected imports retain names and spans through cloning" {
    const source_text =
        \\import "dep" as {
        \\  Item, make, make!, ;; placement is selected explicitly
        \\}
    ;
    var program = try syntax.parseWithSourceName(testing.allocator, source_text, "selected.ss");
    defer program.deinit(testing.allocator);
    const mode = program.imports.items[0].mode;
    try expectImportMode(program.imports.items[0], null, false);
    try testing.expectEqual(@as(usize, 3), mode.selected.len);
    for (mode.selected, [_][]const u8{ "Item", "make", "make!" }) |item, expected| {
        try testing.expectEqualStrings(expected, item.name);
        try expectSpanText(source_text, item.span, expected);
    }
    try allocation_testing.checkAllAllocationFailures(testing.allocator, cloneAndDeinitModule, .{&program});
    var cloned = try program.clone(testing.allocator);
    defer cloned.deinit(testing.allocator);
    const cloned_names = cloned.imports.items[0].mode.selected;
    try testing.expect(mode.selected.ptr != cloned_names.ptr);
    for (mode.selected, cloned_names) |original, copy| {
        try testing.expect(original.name.ptr != copy.name.ptr);
        try testing.expectEqualStrings(original.name, copy.name);
    }
    try allocation_testing.checkAllAllocationFailures(testing.allocator, parseAndDeinitSource, .{source_text});
    try allocation_testing.checkAllAllocationFailures(testing.allocator, parseRecoveringAndDeinitSource, .{source_text});
}

test "syntax spec: malformed selected imports release ownership" {
    try expectParseErrorWithoutLeaks(error.ExpectedIdentifier, "import dep as {}\n");
    try expectParseErrorWithoutLeaks(error.ExpectedComma, "import dep as { first second }\n");
    try expectParseErrorWithoutLeaks(error.ExpectedComma, "import dep as { first\n");
    try expectParseErrorWithoutLeaks(error.DuplicateImportedName, "import dep as { first, first }\n");
    try expectParseErrorWithoutLeaks(error.ExpectedComma, "import dep as { alias::first }\n");
    try expectParseErrorWithoutLeaks(error.ExpectedIdentifier, "import dep as { first,, second }\n");
}

test "recovering parser advances past stray expression delimiters" {
    const Budget = struct {
        checks: usize = 0,
        fn canceled(context: *const anyopaque) bool {
            const self: *@This() = @ptrCast(@alignCast(@constCast(context)));
            self.checks += 1;
            return self.checks > 1000;
        }
    };
    const sources = [_][]const u8{
        "page sample\nlet t = Theme {\nbody.text.size = 10\n}\ntext! \"After\"\nend\n",
        "page sample\n)\n,\n}\ntext! \"After\"\nend\n",
        "page sample\nif true\n)\n,\n}\nelse\ntext! \"After\"\nend\nend\n",
    };
    for (sources) |source_text| {
        var budget: Budget = .{};
        var result = try syntax.parseRecoveringWithOptions(testing.allocator, source_text, "unit-test.ss", .{
            .cancellation = .{ .context = &budget, .is_canceled = Budget.canceled },
        });
        defer result.deinit(testing.allocator);
        try testing.expect(result.holes.diagnostics.len > 0);
        try testing.expectEqual(@as(usize, 1), result.module.pages.items.len);
        const statements = result.module.pages.items[0].statements.items;
        const last = statements[statements.len - 1];
        const after = if (last.kind == .if_stmt)
            last.kind.if_stmt.else_statements.items[0]
        else
            last;
        const call = try expectCall(after.kind.expr_stmt, "text!", 1);
        try expectString(call.args.items[0], "After");
    }
}

test "syntax spec: ordinary type declarations preserve field defaults and spans" {
    const source_text =
        \\type Padding {
        \\  horizontal: Number = 16
        \\  vertical: Number = 12
        \\}
        \\type Card {
        \\  title: String
        \\  padding: Padding = Padding {}
        \\}
        \\type Empty {}
    ;
    var parsed = try parse(source_text);
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 3), parsed.module.records.items.len);
    const card = parsed.module.records.items[1];
    try expectSpanText(source_text, card.name_span.?, "Card");
    try expectSpanText(source_text, card.fields.items[0].name_span.?, "title");
    try testing.expect(card.fields.items[0].default_value == null);
    try testing.expect(card.fields.items[1].default_value != null);
    try testing.expectEqual(@as(usize, 0), parsed.module.records.items[2].fields.items.len);
    try allocation_testing.checkAllAllocationFailures(testing.allocator, parseAndDeinitSource, .{source_text});
    try allocation_testing.checkAllAllocationFailures(testing.allocator, cloneAndDeinitModule, .{&parsed.module});
    try expectParseErrorWithoutLeaks(error.ExpectedTypeAnnotation, "type Card { title }\n");
}

test "syntax spec: former object declaration keywords are ordinary field names" {
    const source_text = "type Card { object: String base: Number roles: String }\n";
    var parsed = try parse(source_text);
    defer parsed.deinit();
    const fields = parsed.module.records.items[0].fields.items;
    try testing.expectEqual(@as(usize, 3), fields.len);
    for (fields, [_][]const u8{ "object", "base", "roles" }) |field, name| try testing.expectEqualStrings(name, field.name);
}

test "syntax spec: constraint value registration releases parsed ownership" {
    try allocation_testing.checkAllAllocationFailures(testing.allocator, parseAndDeinitSource, .{
        "page main\n  let rule = a.left + 4 == b.right + 28\n  ~ rule\n  pagectx() ~ rule\nend\n",
    });
    try expectParseErrorWithoutLeaks(error.ExpectedExpression, "page main\n  target ~\nend\n");
}

test "syntax spec: nested selection arguments retain function and optional children" {
    const source_text =
        \\fn keep(items: Selection<Selection<(Page -> Placement)?>>) -> Void
        \\end
        \\fn unary(items: Selection<Page> -> Selection<Placement>) -> Void
        \\end
        \\fn multiple(items: (Selection<Page>, Selection<Placement>) -> Selection<Page>) -> Void
        \\end
    ;
    var parsed = try parse(source_text);
    defer parsed.deinit();
    const outer = parsed.module.functions.items[0].params.items[0].ty;
    const inner = outer.selectionItem();
    try testing.expectEqual(Type.Kind.selection, inner.kind);
    const optional = inner.selectionItem();
    try testing.expectEqual(Type.Kind.optional, optional.kind);
    const callback = optional.optional_child.?;
    try testing.expectEqual(Type.Kind.function, callback.kind);
    try testing.expectEqual(Type.Kind.page, callback.fn_params[0].kind);
    try testing.expectEqual(Type.Kind.placement, callback.fn_result.?.kind);
    try allocation_testing.checkAllAllocationFailures(testing.allocator, parseAndDeinitSource, .{source_text});
    try allocation_testing.checkAllAllocationFailures(testing.allocator, cloneAndDeinitModule, .{&parsed.module});
}

test "syntax spec: generic declarations and applications preserve type arguments" {
    const source_text =
        \\type Box<T> {
        \\  value: T
        \\}
        \\fn identity<T>(value: T) -> T = value
        \\fn/! wrap<T>(value: T) -> Box<T> = Box<T> { value = value }
        \\page main
        \\  let value: Box<Selection<Page>> = Box<Selection<Page>> { value = pages(document) }
        \\  let x = identity<Number>(3)
        \\  let y = lib::identity<Box<Selection<Page>>>(value)
        \\  wrap! <Box<Selection<Page>>> (value)
        \\end
    ;
    var parsed = try parse(source_text);
    defer parsed.deinit();
    const box = parsed.module.records.items[0];
    try testing.expectEqualStrings("T", box.type_params.items[0].name);
    try testing.expectEqualStrings("T", source_text[box.type_params.items[0].span.start..box.type_params.items[0].span.end]);
    const identity = parsed.module.functions.items[0];
    try testing.expectEqualStrings("T", identity.type_params.items[0].name);
    const paired = parsed.module.functions.items[2];
    try testing.expectEqualStrings("wrap!", paired.name);
    try testing.expectEqualStrings("T", paired.type_params.items[0].name);
    try testing.expectEqual(Type.Kind.placed, paired.result_type.kind);
    const input_type = paired.result_type.placedInput().?;
    try testing.expectEqualStrings("Box", input_type.class_name.?);
    try testing.expectEqualStrings("T", input_type.arguments[0].class_name.?);
    const forwarded = paired.statements.items[0].kind.return_expr.call.args.items[1].call;
    try testing.expectEqualStrings("T", forwarded.type_args.items[0].class_name.?);
    const statements = parsed.module.pages.items[0].statements.items;
    const constructed = statements[0].kind.let_binding.expr.record;
    try testing.expectEqualStrings("Box", constructed.type_name);
    try testing.expectEqual(Type.Kind.page, constructed.type_args.items[0].selectionItem().kind);
    const explicit = statements[1].kind.let_binding.expr.call;
    try testing.expectEqual(Type.Kind.number, explicit.type_args.items[0].kind);
    const qualified = statements[2].kind.let_binding.expr.call;
    try testing.expectEqualStrings("lib", qualified.callee.qualifier.?);
    try testing.expectEqualStrings("Box", qualified.type_args.items[0].class_name.?);
    try testing.expectEqual(Type.Kind.page, qualified.type_args.items[0].arguments[0].selectionItem().kind);
    const placed = statements[3].kind.expr_stmt.call;
    try testing.expectEqualStrings("wrap!", placed.callee.name);
    try testing.expectEqual(@as(usize, 1), placed.type_args.items.len);
    try allocation_testing.checkAllAllocationFailures(testing.allocator, parseAndDeinitSource, .{source_text});
    try allocation_testing.checkAllAllocationFailures(testing.allocator, cloneAndDeinitModule, .{&parsed.module});
}

test "syntax spec: generic calls are distinguished from comparison expressions" {
    var parsed = try parse(
        \\page main
        \\  let a = f<Number>(3)
        \\  let b = f < Number > (3)
        \\  let c = x < y
        \\  let d = (x < y) > z
        \\end
    );
    defer parsed.deinit();
    const statements = parsed.module.pages.items[0].statements.items;
    for (statements[0..2]) |statement| {
        const call = statement.kind.let_binding.expr.call;
        try testing.expectEqualStrings("f", call.callee.name);
        try testing.expectEqual(Type.Kind.number, call.type_args.items[0].kind);
    }
    for (statements[2..]) |statement| {
        try testing.expectEqual(@as(usize, 0), statement.kind.let_binding.expr.call.type_args.items.len);
    }
}

test "syntax spec: type parameters reject duplicate and empty declarations" {
    try expectParseErrorWithoutLeaks(error.DuplicateTypeParameter, "type Box<T, T> { value: T }\n");
    try expectParseErrorWithoutLeaks(error.DuplicateTypeParameter, "fn keep<T, T>(x: T) -> T = x\n");
    try expectParseErrorWithoutLeaks(error.ExpectedIdentifier, "type Box<> { value: Number }\n");
    try expectParseErrorWithoutLeaks(error.ExpectedTypeAnnotation, "fn keep(x: Box<>) -> Number = 0\n");
}

test "syntax spec: incomplete generic input preserves subsequent declarations" {
    const sources = [_][]const u8{
        "type Broken<T,> { value: T }\ntype Kept { value: Number }\n",
        "fn broken<T,>(value: T) -> T = value\nfn kept() -> Number = 1\n",
        "page main\n  let missing = call<Number,>(1)\n  let kept = 2\nend\n",
    };
    for (sources) |text| {
        try allocation_testing.checkAllAllocationFailures(testing.allocator, parseRecoveringAndDeinitSource, .{text});
    }
    var recovered = try syntax.parseRecoveringWithSourceName(testing.allocator, sources[0], "generics.ss");
    defer recovered.deinit(testing.allocator);
    try testing.expectEqualStrings("Kept", recovered.module.records.items[0].name);
}

test "syntax spec: parenthesized qualified expressions are distinct from typed lambdas" {
    const source =
        \\page Qualified
        \\  let value = (library::Item { value = 1 })
        \\  let call = (library::make(1))
        \\  let reference = (library::Kind.value)
        \\  let group = (library::Item { value = 1 } // other)
        \\  let function = (value: library::Item) |-> value
        \\end
    ;
    var parsed = try parse(source);
    defer parsed.deinit();
    const statements = parsed.module.pages.items[0].statements.items;
    try testing.expectEqualStrings("library::Item", statements[0].kind.let_binding.expr.record.type_name);
    const call = statements[1].kind.let_binding.expr.call;
    try testing.expectEqualStrings("library", call.callee.qualifier.?);
    try testing.expectEqualStrings("make", call.callee.name);
    const reference = statements[2].kind.let_binding.expr.member.target.ident;
    try testing.expectEqualStrings("library::Kind", reference.name);
    const group = try expectComposition(statements[3].kind.let_binding.expr, .vertical);
    try testing.expectEqualStrings("library::Item", group.args.items[0].record.type_name);
    const lambda = statements[4].kind.let_binding.expr.lambda;
    try testing.expectEqualStrings("library::Item", lambda.params.items[0].ty.class_name.?);
    try allocation_testing.checkAllAllocationFailures(testing.allocator, parseAndDeinitSource, .{source});
}

test "syntax spec: qualified values parse standalone with members and updates" {
    const source =
        \\const style: Style = library:: defaults
        \\page main
        \\  let copied = library::defaults with { size = 24 }
        \\  let size = library::defaults.size
        \\  let fallback = library::optional ?? library::defaults
        \\  let reference = (library::format)
        \\end
    ;
    var parsed = try parse(source);
    defer parsed.deinit();
    const ident = parsed.module.constants.items[0].value.ident;
    try testing.expectEqualStrings("library::defaults", ident.name);
    const reference = ident.reference();
    try expectSpanText(source, reference.qualifier_span.?, "library");
    try expectSpanText(source, reference.name_span.?, "defaults");
    try expectSpanText(source, reference.span.?, "library:: defaults");
    const statements = parsed.module.pages.items[0].statements.items;
    try testing.expectEqualStrings("library::defaults", statements[0].kind.let_binding.expr.record_update.target.ident.name);
    try testing.expectEqualStrings("library::defaults", statements[1].kind.let_binding.expr.member.target.ident.name);
    try testing.expectEqualStrings("library::optional", statements[2].kind.let_binding.expr.coalesce.target.ident.name);
    try testing.expectEqualStrings("library::format", statements[3].kind.let_binding.expr.ident.name);
    try allocation_testing.checkAllAllocationFailures(testing.allocator, parseAndDeinitSource, .{source});
}

test "syntax spec: extend and implements are ordinary identifiers" {
    var parsed = try parse(
        \\type Card { implements: String = "contract" }
        \\fn extend(value: Number) -> Number = value
        \\page main
        \\  let implements = extend(1)
        \\end
    );
    defer parsed.deinit();
    try testing.expectEqualStrings("extend", parsed.module.functions.items[0].name);
    try testing.expectEqualStrings("implements", parsed.module.records.items[0].fields.items[0].name);
}
