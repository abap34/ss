const std = @import("std");
const compiler = @import("compiler");
const query_types = compiler.analysis.query.types;
const resolve_query = compiler.analysis.query.resolve;
const snapshot_api = compiler.analysis.snapshot;
const type_resolution = compiler.language.type_resolution;

const testing = std.testing;

test "analysis completion: dot module and normal positions keep candidate kinds separate" {
    var case = try CompletionCase.init(
        \\import std:themes/default
        \\import std:themes/default as *
        \\
        \\page title
        \\  let t = default::h1("body")
        \\  t.text.size = 20
        \\end
        \\
    );
    defer case.deinit();

    {
        var result = try case.completeAfter("t.");
        defer result.deinit(case.allocator);
        try expectUnique(result);
        try expectHas(result, "text");
        try expectHas(result, "layout");
        try expectHas(result, "content");
        try expectMissing(result, "text_size");
        try expectMissing(result, "page");
        try expectMissing(result, "add");
        try expectMissing(result, "Align");
        try expectMissing(result, "String");
        try expectOnlyKind(result, .property);
    }

    {
        var result = try case.completeAfter("default::");
        defer result.deinit(case.allocator);
        try expectUnique(result);
        try expectHas(result, "h1");
        try expectHas(result, "h1!");
        try expectMissing(result, "page");
        try expectMissing(result, "add");
        try expectMissing(result, "text_size");
        try expectMissing(result, "String");
        try expectMissing(result, "Align");
    }

    {
        var result = try case.completeAfter("page title\n");
        defer result.deinit(case.allocator);
        try expectUnique(result);
        try expectHas(result, "page");
        try expectHas(result, "h1!");
        try expectHas(result, "String");
        try expectHas(result, "Object");
        try expectHas(result, "Selection");
        try expectHas(result, "Align");
        try expectHas(result, "Text");
        try expectMissing(result, "text_size");
    }
}

test "analysis completion: normal position follows import visibility" {
    var case = try CompletionCase.init(
        \\import std:themes/default as theme
        \\
        \\page title
        \\
        \\end
        \\
    );
    defer case.deinit();

    var result = try case.completeAfter("page title\n");
    defer result.deinit(case.allocator);
    try expectUnique(result);
    try expectHas(result, "page");
    try expectMissing(result, "h1");
    try expectMissing(result, "h1!");
    try expectMissing(result, "text_size");
}

test "analysis completion: visible function prefers imported module definitions over re-exported names" {
    var case = try CompletionCase.init(
        \\import std:themes/default as *
        \\
        \\page title
        \\  text!("body")
        \\end
        \\
    );
    defer case.deinit();

    const snapshot = try case.snapshotFor(case.source);
    const module = snapshot.moduleForPath(case.path) orelse return error.ExpectedModule;
    const item = resolve_query.valueBinding(null, snapshot, module.id, "text", null, .function) orelse return error.ExpectedFunction;

    try testing.expectEqualStrings("text", item.name);
    try testing.expectEqualStrings("text(text_value: String, theme: Theme = current_theme()) -> Object", item.signature);
}

test "analysis completion: visible variables and definitions use shared scope resolution" {
    var case = try CompletionCase.init(
        \\document
        \\  let x = "document"
        \\  let doc_probe = x
        \\end
        \\
        \\page title
        \\  let x = 1
        \\  let page_probe = x
        \\end
        \\
        \\fn make() -> Bool
        \\  let x = true
        \\  let fn_probe = x
        \\  return x
        \\end
        \\
    );
    defer case.deinit();

    {
        const snapshot = try case.snapshotFor(case.source);
        const module = snapshot.moduleForPath(case.path) orelse return error.ExpectedModule;
        const offset = offsetAfter(case.source, "doc_probe = x");
        const variable = resolve_query.visibleVariableBinding(null, snapshot, module.id, offset, "x") orelse return error.ExpectedVariable;
        try testing.expectEqualStrings("x", variable.name);
        try testing.expectEqualStrings("String", variable.type_label);
        const definition = resolve_query.visibleVariable(null, snapshot, module.id, offset, "x") orelse return error.ExpectedDefinition;
        try testing.expectEqual(compiler.core.DefinitionKind.variable, definition.kind);
        try testing.expectEqual(module.id, definition.module_id);
    }

    {
        const snapshot = try case.snapshotFor(case.source);
        const module = snapshot.moduleForPath(case.path) orelse return error.ExpectedModule;
        const offset = offsetAfter(case.source, "page_probe = x");
        const variable = resolve_query.visibleVariableBinding(null, snapshot, module.id, offset, "x") orelse return error.ExpectedVariable;
        try testing.expectEqualStrings("Number", variable.type_label);
        const definition = resolve_query.visibleVariable(null, snapshot, module.id, offset, "x") orelse return error.ExpectedDefinition;
        try testing.expectEqual(compiler.core.DefinitionKind.variable, definition.kind);
        try testing.expectEqual(module.id, definition.module_id);
    }

    {
        const snapshot = try case.snapshotFor(case.source);
        const module = snapshot.moduleForPath(case.path) orelse return error.ExpectedModule;
        const offset = offsetAfter(case.source, "fn_probe = x");
        const variable = resolve_query.visibleVariableBinding(null, snapshot, module.id, offset, "x") orelse return error.ExpectedVariable;
        try testing.expectEqualStrings("Bool", variable.type_label);
        const definition = resolve_query.visibleVariable(null, snapshot, module.id, offset, "x") orelse return error.ExpectedDefinition;
        try testing.expectEqual(compiler.core.DefinitionKind.variable, definition.kind);
        try testing.expectEqual(module.id, definition.module_id);
    }
}

test "analysis completion: normal positions include builtin and source type names" {
    var case = try CompletionCase.init(
        \\import std:themes/default as *
        \\
        \\page title
        \\end
        \\
    );
    defer case.deinit();

    const request_source =
        \\import std:themes/default as *
        \\
        \\type SourceOnly = alpha | beta
        \\type SourceCard = object {
        \\}
        \\
        \\fn keep(value: ) -> SourceOnly
        \\  return value
        \\end
        \\
    ;

    var result = try case.completeSourceAfter(request_source, "value: ");
    defer result.deinit(case.allocator);
    try expectUnique(result);
    for (type_resolution.builtinTypes()) |builtin| try expectHas(result, builtin.name);
    try testing.expect(type_resolution.isBuiltinTypeName("Selection"));
    try expectHas(result, "SourceOnly");
    try expectHas(result, "SourceCard");
    try expectMissing(result, "text_size");
}

test "analysis completion: enum type dot completes cases" {
    var case = try CompletionCase.init(
        \\import std:themes/default as *
        \\import std:core/classes as classes
        \\
        \\page title
        \\  let style = TextStyle { math_align = Align.center }
        \\  let qualified = TextStyle { math_align = classes::Align.left }
        \\end
        \\
    );
    defer case.deinit();

    const request_source =
        \\import std:themes/default as *
        \\import std:core/classes as classes
        \\
        \\page title
        \\  Align.
        \\  classes::Align.
        \\end
        \\
    ;

    inline for (.{ "Align.", "classes::Align." }) |needle| {
        var result = try case.completeSourceAfter(request_source, needle);
        defer result.deinit(case.allocator);
        try expectUnique(result);
        try expectHas(result, "left");
        try expectHas(result, "center");
        try expectHas(result, "right");
        try expectKind(result, "left", .enum_case);
        try expectKind(result, "center", .enum_case);
        try expectKind(result, "right", .enum_case);
        try expectMissing(result, "page");
        try expectMissing(result, "String");
        try expectMissing(result, "text_size");
    }
}

test "analysis completion: source recovery sees preceding same-scope bindings" {
    var case = try CompletionCase.init(
        \\import std:themes/default as *
        \\
        \\page title
        \\  let t = h2! "before"
        \\  let alias = t
        \\  let later = h2! "after"
        \\  alias.text.size = 1
        \\  later.text.size = 1
        \\end
        \\
    );
    defer case.deinit();

    const request_source =
        \\import std:themes/default as *
        \\
        \\page title
        \\  let t = h2! "before"
        \\  let alias = t
        \\  alias.
        \\  let later = h2! "after"
        \\  later.
        \\end
        \\
    ;

    {
        var result = try case.completeSourceAfter(request_source, "alias.");
        defer result.deinit(case.allocator);
        try expectUnique(result);
        try expectHas(result, "text");
        try expectHas(result, "layout");
        try expectMissing(result, "text_size");
        try expectMissing(result, "page");
    }

    {
        var result = try case.completeSourceAfter(request_source, "later.");
        defer result.deinit(case.allocator);
        try expectUnique(result);
        try expectHas(result, "text");
        try expectHas(result, "layout");
        try expectMissing(result, "text_size");
        try expectMissing(result, "page");
    }
}

test "analysis completion: fn paired function and const result annotations drive property targets" {
    var case = try CompletionCase.init(
        \\import std:themes/default as *
        \\
        \\fn make_plain() -> Object
        \\  return h2!("plain")
        \\end
        \\
        \\fn/! make_paired(content: String) -> Object
        \\  return h2!(content)
        \\end
        \\
        \\const make_const: Object = h2!("const")
        \\
        \\page title
        \\  let a = make_plain()
        \\  a.text.size = 1
        \\  let b = make_paired! "paired"
        \\  b.text.size = 1
        \\  let c = make_const
        \\  c.text.size = 1
        \\end
        \\
    );
    defer case.deinit();

    const request_source =
        \\import std:themes/default as *
        \\
        \\fn make_plain() -> Object
        \\  return h2!("plain")
        \\end
        \\
        \\fn/! make_paired(content: String) -> Object
        \\  return h2!(content)
        \\end
        \\
        \\const make_const: Object = h2!("const")
        \\
        \\page title
        \\  let a = make_plain()
        \\  a.
        \\  let b = make_paired! "paired"
        \\  b.
        \\  let c = make_const
        \\  c.
        \\end
        \\
    ;

    inline for (.{ "a.", "b.", "c." }) |needle| {
        var result = try case.completeSourceAfter(request_source, needle);
        defer result.deinit(case.allocator);
        try expectUnique(result);
        try expectHas(result, "text");
        try expectHas(result, "layout");
        try expectMissing(result, "text_size");
        try expectMissing(result, "page");
    }
}

test "analysis completion: record update paths complete record fields" {
    var case = try CompletionCase.init(
        \\import std:themes/default as *
        \\
        \\page title
        \\  let local = current_theme() with {
        \\    body.text.size = 20
        \\  }
        \\  text!("body", local)
        \\end
        \\
    );
    defer case.deinit();

    const request_source =
        \\import std:themes/default as *
        \\
        \\page title
        \\  let local = current_theme() with {
        \\
        \\    bod
        \\    body.
        \\    body.text.
        \\    body.text.size =
        \\  }
        \\  text!("body", local)
        \\end
        \\
    ;

    {
        var result = try case.completeSourceAfter(request_source, "with {\n");
        defer result.deinit(case.allocator);
        try expectUnique(result);
        try expectHas(result, "body");
        try expectHas(result, "h1");
        try expectHas(result, "callout");
        try expectMissing(result, "size");
        try expectMissing(result, "page");
        try expectMissing(result, "String");
    }

    {
        var result = try case.completeSourceAfter(request_source, "body.");
        defer result.deinit(case.allocator);
        try expectUnique(result);
        try expectHas(result, "text");
        try expectHas(result, "layout");
        try expectMissing(result, "size");
        try expectMissing(result, "page");
    }

    {
        var result = try case.completeSourceAfter(request_source, "body.text.");
        defer result.deinit(case.allocator);
        try expectUnique(result);
        try expectHas(result, "size");
        try expectHas(result, "color");
        try expectMissing(result, "text");
        try expectMissing(result, "page");
    }

    {
        var result = try case.completeSourceAfter(request_source, "bod");
        defer result.deinit(case.allocator);
        try expectUnique(result);
        try expectHas(result, "body");
        try expectHas(result, "h1");
        try expectHas(result, "callout");
        try expectMissing(result, "size");
        try expectMissing(result, "page");
        try expectMissing(result, "String");
    }

    {
        const unindented_source =
            \\import std:themes/default as *
            \\
            \\page title
            \\  let local = current_theme() with  {
            \\bod
            \\  }
            \\  text!("body", local)
            \\end
            \\
        ;
        var result = try case.completeSourceAfter(unindented_source, "bod");
        defer result.deinit(case.allocator);
        try expectUnique(result);
        try expectHas(result, "body");
        try expectHas(result, "h1");
        try expectHas(result, "callout");
        try expectMissing(result, "size");
        try expectMissing(result, "page");
        try expectMissing(result, "String");
    }

    {
        var result = try case.completeSourceAfter(request_source, "body.text.size =");
        defer result.deinit(case.allocator);
        try expectUnique(result);
        try expectMissing(result, "callout");
        try expectHas(result, "page");
    }
}

test "analysis completion: chevron blocks and comments do not create fake bindings or scopes" {
    var case = try CompletionCase.init(
        \\import std:themes/default as *
        \\
        \\page title
        \\  # let fake_comment = h2! "comment"
        \\  let t = h2! <<
        \\let fake_block = h2! "block"
        \\end
        \\>>
        \\  t.text.size = 1
        \\end
        \\
    );
    defer case.deinit();

    const request_source =
        \\import std:themes/default as *
        \\
        \\page title
        \\  # let fake_comment = h2! "comment"
        \\  let t = h2! <<
        \\let fake_block = h2! "block"
        \\end
        \\>>
        \\  t.
        \\end
        \\
    ;

    {
        var result = try case.completeSourceAfter(request_source, "t.");
        defer result.deinit(case.allocator);
        try expectUnique(result);
        try expectHas(result, "text");
        try expectHas(result, "layout");
        try expectMissing(result, "text_size");
        try expectMissing(result, "page");
    }

    {
        var result = try case.completeSourceAfter(request_source, "page title\n");
        defer result.deinit(case.allocator);
        try expectUnique(result);
        try expectMissing(result, "fake_comment");
        try expectMissing(result, "fake_block");
        try expectMissing(result, "text_size");
    }
}

test "analysis queries: module identity survives nested fields and label changes" {
    try checkNominalQueries("import \"a\" as a\nimport \"b\" as b\n");
    try checkNominalQueries("import \"b\" as b\nimport \"a\" as a\n");
}

fn checkNominalQueries(imports: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = ".ss-cache/query-nominal-fixture";
    const path = root ++ "/main.ss";
    const source = try std.mem.concat(allocator, u8, &.{
        imports,
        \\page main
        \\  let first = a::make()
        \\  let second = b::make()
        \\  let ar = a::record_value()
        \\  let br = b::record_value()
        \\  let ax = first.object_a
        \\  let bx = second.object_b
        \\  let av = ar.value.only_a
        \\  let bv = br.value.only_b
        \\  let am = a::Mode.alpha
        \\  let bm = b::Mode.beta
        \\end
    });
    var sources = snapshot_api.SourceSet.init(allocator, testing.io);
    defer sources.deinit();
    try sources.put(path, source);
    try sources.put(root ++ "/a.ss",
        \\record Style { only_a: Number = 1 }
        \\record Box { value: Style = Style {} }
        \\type Base = object { object_a: Number = 1 }
        \\type Card = object { base = Base
        \\  roles = ["query-a"] }
        \\type Mode = alpha
        \\fn make() -> Card
        \\  return new("", "query-a", "text")
        \\end
        \\fn record_value() -> Box
        \\  return Box {}
        \\end
    );
    try sources.put(root ++ "/b.ss",
        \\record Style { only_b: String = "b" }
        \\record Box { value: Style = Style {} }
        \\type Base = object { object_b: String = "b" }
        \\type Card = object { base = Base
        \\  roles = ["query-b"] }
        \\type Mode = beta
        \\fn make() -> Card
        \\  return new("", "query-b", "text")
        \\end
        \\fn record_value() -> Box
        \\  return Box {}
        \\end
    );
    var snapshot = try snapshot_api.build(allocator, &sources, path, root, .{});
    defer snapshot.deinit();
    try testing.expect(!snapshot.diagnostics.hasErrors());
    for (snapshot.value_bindings) |*binding| @memset(binding.type_label, '!');
    for (snapshot.variable_bindings) |*binding| @memset(binding.type_label, '!');
    for (snapshot.record_fields) |*field| @memset(field.type_label, '!');
    const queries = .{
        .{ "first.", "object_a", "object_b" },
        .{ "second.", "object_b", "object_a" },
        .{ "ar.value.", "only_a", "only_b" },
        .{ "br.value.", "only_b", "only_a" },
        .{ "a::Mode.", "alpha", "beta" },
        .{ "b::Mode.", "beta", "alpha" },
    };
    inline for (queries) |query| {
        var result = try snapshot_api.completeAt(allocator, &snapshot, .{ .path = path, .source = source, .offset = offsetAfter(source, query[0]) }, .{ .budget_ms = 100 });
        defer result.deinit(allocator);
        try expectHas(result, query[1]);
        try expectMissing(result, query[2]);
    }
    inline for (.{ .{ "ar.value.only_a", "a.ss" }, .{ "br.value.only_b", "b.ss" }, .{ "first.object_a", "a.ss" }, .{ "second.object_b", "b.ss" } }) |query| {
        const targets = try snapshot_api.definitionAt(allocator, &snapshot, .{ .path = path, .source = source, .offset = offsetAfter(source, query[0]) - 1 }, .{ .budget_ms = 100 });
        defer allocator.free(targets);
        try testing.expectEqual(@as(usize, 1), targets.len);
        try testing.expect(std.mem.endsWith(u8, targets[0].path orelse "", query[1]));
    }
}

const CompletionCase = struct {
    arena: *std.heap.ArenaAllocator,
    allocator: std.mem.Allocator,
    path: []const u8,
    source: []const u8,
    snapshot: ?snapshot_api.AnalysisSnapshot = null,

    fn init(source: []const u8) !CompletionCase {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();

        const arena = try testing.allocator.create(std.heap.ArenaAllocator);
        errdefer testing.allocator.destroy(arena);
        arena.* = std.heap.ArenaAllocator.init(testing.allocator);
        errdefer arena.deinit();
        const allocator = arena.allocator();

        const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
        try std.Io.Dir.cwd().createDirPath(testing.io, root);
        const path = try std.fs.path.join(allocator, &.{ root, "case.ss" });
        const owned_source = try allocator.dupe(u8, source);
        return .{
            .arena = arena,
            .allocator = allocator,
            .path = path,
            .source = owned_source,
        };
    }

    fn deinit(self: *CompletionCase) void {
        if (self.snapshot) |*snapshot| snapshot.deinit();
        self.arena.deinit();
        testing.allocator.destroy(self.arena);
    }

    fn completeAfter(self: *CompletionCase, needle: []const u8) !query_types.CompletionResult {
        return self.completeSourceAfter(self.source, needle);
    }

    fn completeSourceAfter(self: *CompletionCase, source: []const u8, needle: []const u8) !query_types.CompletionResult {
        const offset = offsetAfter(source, needle);
        const snapshot = try self.snapshotFor(source);
        return snapshot_api.completeAt(self.allocator, snapshot, .{
            .path = self.path,
            .source = source,
            .offset = offset,
            .source_version = snapshot.generation,
        }, .{ .budget_ms = 10 });
    }

    fn snapshotFor(self: *CompletionCase, source: []const u8) !*snapshot_api.AnalysisSnapshot {
        if (self.snapshot) |*snapshot| snapshot.deinit();
        self.snapshot = try buildAnalysis(self.allocator, self.path, source);
        return if (self.snapshot) |*snapshot| snapshot else unreachable;
    }
};

fn buildAnalysis(allocator: std.mem.Allocator, path: []const u8, source: []const u8) !snapshot_api.AnalysisSnapshot {
    const asset_base_dir = std.fs.path.dirname(path) orelse ".";
    var sources = snapshot_api.SourceSet.init(allocator, testing.io);
    defer sources.deinit();
    try sources.put(path, source);
    return snapshot_api.build(allocator, &sources, path, asset_base_dir, .{});
}

fn offsetAfter(source: []const u8, needle: []const u8) usize {
    const start = std.mem.indexOf(u8, source, needle) orelse @panic("needle not found");
    return start + needle.len;
}

fn expectHas(result: query_types.CompletionResult, label: []const u8) !void {
    for (result.items) |item| {
        if (std.mem.eql(u8, item.label, label)) return;
    }
    return error.ExpectedCompletionMissing;
}

fn expectKind(result: query_types.CompletionResult, label: []const u8, kind: query_types.CompletionKind) !void {
    for (result.items) |item| {
        if (!std.mem.eql(u8, item.label, label)) continue;
        try testing.expectEqual(kind, item.kind);
        return;
    }
    return error.ExpectedCompletionMissing;
}

fn expectMissing(result: query_types.CompletionResult, label: []const u8) !void {
    for (result.items) |item| {
        if (std.mem.eql(u8, item.label, label)) return error.UnexpectedCompletionPresent;
    }
}

fn expectUnique(result: query_types.CompletionResult) !void {
    var seen = std.StringHashMap(void).init(testing.allocator);
    defer seen.deinit();
    for (result.items) |item| {
        if (seen.contains(item.label)) return error.DuplicateCompletionLabel;
        try seen.put(item.label, {});
    }
}

fn expectOnlyKind(result: query_types.CompletionResult, kind: query_types.CompletionKind) !void {
    for (result.items) |item| try testing.expectEqual(kind, item.kind);
}

test "analysis queries: recovery syntax is borrowed for repeated requests" {
    var case = try CompletionCase.init(
        \\page title
        \\  let t = text("body")
        \\  t.
        \\end
        \\
    );
    defer case.deinit();
    const snapshot = try case.snapshotFor(case.source);
    const tree = snapshot.syntaxForSource(case.path, case.source) orelse return error.TestUnexpectedResult;
    const req = query_types.SourceRequest{ .path = case.path, .source = case.source, .offset = offsetAfter(case.source, "  t") };
    for (0..32) |_| {
        var limited = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 1 });
        var context = try compiler.analysis.query.context.Context.initFromSnapshot(limited.allocator(), snapshot, req, null);
        defer context.deinit(limited.allocator());
        try testing.expectEqual(tree, context.module().?);
        try testing.expect(context.parsed.owned == null);
        try testing.expectEqualStrings("t", context.target);
    }
    var completion = try snapshot_api.completeAt(testing.allocator, snapshot, .{
        .path = case.path,
        .source = case.source,
        .offset = offsetAfter(case.source, "t."),
    }, .{ .budget_ms = 1000 });
    defer completion.deinit(testing.allocator);
    try expectHas(completion, "text");
    try expectHas(completion, "content");
}

test "analysis queries: failed imports keep the entry recovery tree" {
    var case = try CompletionCase.init(
        \\import ./absent as missing
        \\page title
        \\  missing::unfinished()
        \\end
        \\
    );
    defer case.deinit();
    const snapshot = try case.snapshotFor(case.source);
    try testing.expect(snapshot.diagnostics.hasErrors());
    const tree = snapshot.syntaxForSource(case.path, case.source) orelse return error.TestUnexpectedResult;
    var context = try compiler.analysis.query.context.Context.initFromSnapshot(testing.allocator, snapshot, .{
        .path = case.path,
        .source = case.source,
        .offset = offsetAfter(case.source, "missing::un"),
    }, null);
    defer context.deinit(testing.allocator);
    try testing.expectEqual(tree, context.module().?);
    try testing.expectEqualStrings("missing", context.qualifiedCallableAlias().?);
}

const retained_source =
    \\fn accept(value: first::Card?, callback: (second::Card) -> first::Card) -> first::Card = callback(value?)
    \\page title
    \\  let broken: third::Card =
    \\end
    \\
;

fn ownQuerySyntax(allocator: std.mem.Allocator) !void {
    var storage = snapshot_api.SyntaxStorage.init(allocator);
    defer storage.deinit();
    {
        const source = try testing.allocator.dupe(u8, retained_source);
        defer testing.allocator.free(source);
        var parsed = try compiler.syntax.parseRecoveringWithSourceName(testing.allocator, source, "owned.ss");
        defer parsed.deinit(testing.allocator);
        try storage.capture("owned.ss", source, parsed.module);
    }
    const tree = storage.forSource("owned.ss", retained_source) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 1), tree.functions.items.len);
    const function = tree.functions.items[0];
    try testing.expectEqualStrings("first::Card", function.result_type.class_name.?);
    try testing.expectEqualStrings("first::Card", function.params.items[0].ty.optional_child.?.class_name.?);
    try testing.expectEqualStrings("second::Card", function.params.items[1].ty.fn_params[0].class_name.?);
    try testing.expectEqualStrings("first::Card", function.params.items[1].ty.fn_result.?.class_name.?);
    try testing.expect(storage.forSource("owned.ss", "page changed\nend\n") == null);
    try storage.replace("owned.ss", "page changed\nend\n", null);
    try testing.expect(storage.forSource("owned.ss", retained_source) == null);
    try testing.expect(storage.forSource("owned.ss", "page changed\nend\n") != null);
}

test "analysis queries: retained syntax owns all type spellings and partial allocations" {
    try ownQuerySyntax(testing.allocator);
    try testing.checkAllAllocationFailures(testing.allocator, ownQuerySyntax, .{});
}

const ParseCancellation = struct {
    checks: usize = 0,
    limit: usize,

    fn canceled(context: *const anyopaque) bool {
        const self: *ParseCancellation = @ptrCast(@alignCast(@constCast(context)));
        self.checks += 1;
        return self.checks >= self.limit;
    }
};

test "analysis queries: fallback parsing checks cancellation inside a document" {
    const source = "page title\n" ++ ("  let value = add(1, 2)\n" ** 100) ++ "end\n";
    var cancellation = ParseCancellation{ .limit = 20 };
    const budget = query_types.QueryBudget.start(.{
        .budget_ms = 1000,
        .cancellation = .{ .context = &cancellation, .is_canceled = ParseCancellation.canceled },
    });
    var context = try compiler.analysis.query.context.Context.initWithBudget(testing.allocator, .{
        .path = "cancel.ss",
        .source = source,
        .offset = offsetAfter(source, "val"),
    }, budget);
    defer context.deinit(testing.allocator);
    try testing.expect(context.module() == null);
    try testing.expectEqualStrings("value", context.target);
    try testing.expectEqual(@as(usize, 20), cancellation.checks);
}

test "analysis queries: replacing source invalidates syntax and keeps failed replacements atomic" {
    var case = try CompletionCase.init("page title\n  let value = 1\nend\n");
    defer case.deinit();
    const snapshot = try case.snapshotFor(case.source);
    const old_tree = snapshot.syntaxForSource(case.path, case.source).?;
    const changed = "page title\n  let value = 2\nend\n";
    var context = try compiler.analysis.query.context.Context.initFromSnapshot(testing.allocator, snapshot, .{
        .path = case.path,
        .source = changed,
        .offset = offsetAfter(changed, "val"),
    }, null);
    defer context.deinit(testing.allocator);
    try testing.expect(context.parsed.owned != null);
    try testing.expectEqual(old_tree, snapshot.syntaxForSource(case.path, case.source).?);
    var cancellation = ParseCancellation{ .limit = 1 };
    try testing.expectError(error.Canceled, snapshot.updateSyntax(case.path, changed, .{
        .context = &cancellation,
        .is_canceled = ParseCancellation.canceled,
    }));
    try testing.expectEqual(old_tree, snapshot.syntaxForSource(case.path, case.source).?);
    try snapshot.updateSyntax(case.path, changed, null);
    try testing.expect(snapshot.syntaxForSource(case.path, case.source) == null);
    const new_tree = snapshot.syntaxForSource(case.path, changed) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(f64, 2), new_tree.pages.items[0].statements.items[0].kind.let_binding.expr.number);
}

test "analysis queries: parser cancellation releases partial expressions and declarations" {
    const source =
        \\fn scale(value: Number, transform: (Number) -> Number) -> Number
        \\  if true
        \\    return transform(add(value, 1))
        \\  else
        \\    return 0
        \\  end
        \\end
        \\page title
        \\  let label = text("value")
        \\  label.text.size = 20
        \\end
        \\
    ;
    for (1..120) |limit| {
        var cancellation = ParseCancellation{ .limit = limit };
        var parsed = compiler.syntax.parseRecoveringWithOptions(testing.allocator, source, "cancel.ss", .{
            .cancellation = .{ .context = &cancellation, .is_canceled = ParseCancellation.canceled },
        }) catch |err| {
            try testing.expectEqual(error.Canceled, err);
            continue;
        };
        parsed.deinit(testing.allocator);
    }
}

test "analysis queries: retained syntax traversal stops before reaching a distant target" {
    const source = ("fn repeated(value: Number) -> Number\n  return add(value, 1)\nend\n" ** 100) ++
        "page title\n  let target = 1\nend\n";
    var parsed = try compiler.syntax.parseRecoveringWithSourceName(testing.allocator, source, "traversal.ss");
    defer parsed.deinit(testing.allocator);
    const SyntaxView = struct {
        tree: *const compiler.syntax.Module,

        pub fn syntaxForSource(self: @This(), _: []const u8, _: []const u8) ?*const compiler.syntax.Module {
            return self.tree;
        }
    };
    var cancellation = ParseCancellation{ .limit = 40 };
    const budget = query_types.QueryBudget.start(.{
        .budget_ms = 1000,
        .cancellation = .{ .context = &cancellation, .is_canceled = ParseCancellation.canceled },
    });
    var context = try compiler.analysis.query.context.Context.initFromSnapshot(testing.allocator, SyntaxView{ .tree = &parsed.module }, .{
        .path = "traversal.ss",
        .source = source,
        .offset = offsetAfter(source, "tar"),
    }, budget);
    defer context.deinit(testing.allocator);
    try testing.expectEqual(&parsed.module, context.module().?);
    try testing.expect(context.parsed.owned == null);
    try testing.expect(context.target_kind == null);
    try testing.expectEqualStrings("target", context.target);
    try testing.expect(cancellation.checks >= cancellation.limit);
    try testing.expect(cancellation.checks <= cancellation.limit + 8);
}

test "analysis queries: canceled candidate collection releases partial results" {
    var case = try CompletionCase.init("page title\nend\n");
    defer case.deinit();
    const snapshot = try case.snapshotFor(case.source);
    const req = query_types.SourceRequest{ .path = case.path, .source = case.source, .offset = 0 };
    for ([_]usize{ 128, 512 }) |limit| {
        var cancellation = ParseCancellation{ .limit = limit };
        var allocations = testing.FailingAllocator.init(testing.allocator, .{});
        var result = try snapshot_api.completeAt(allocations.allocator(), snapshot, req, .{
            .budget_ms = 1000,
            .cancellation = .{ .context = &cancellation, .is_canceled = ParseCancellation.canceled },
        });
        defer result.deinit(allocations.allocator());
        try testing.expectEqual(@as(usize, 0), result.items.len);
        try testing.expect(allocations.alloc_index > 0);
        try testing.expect(cancellation.checks >= limit);
        try testing.expect(cancellation.checks <= limit + 8);
    }
}

test "analysis queries: fact lookup and import traversal honor cancellation" {
    var case = try CompletionCase.init("page title\nend\n");
    defer case.deinit();
    const snapshot = try case.snapshotFor(case.source);
    const module = snapshot.moduleForPath(case.path).?;
    var cancellation = ParseCancellation{ .limit = 40 };
    var budget = query_types.QueryBudget.start(.{
        .budget_ms = 1000,
        .cancellation = .{ .context = &cancellation, .is_canceled = ParseCancellation.canceled },
    });
    try testing.expect(resolve_query.valueBinding(budget, snapshot, module.id, "absent", null, .function) == null);
    try testing.expect(cancellation.checks >= cancellation.limit);
    try testing.expect(cancellation.checks <= cancellation.limit + 8);

    const ImportView = struct {
        value_bindings: []const snapshot_api.ValueBinding = &.{},
        imports: []const snapshot_api.ImportFact,
        visits: *usize,

        const Module = struct {
            imports: []const snapshot_api.ImportFact,
            implicit_import_ids: []const compiler.core.SourceModuleId = &.{},
        };

        pub fn moduleById(self: @This(), _: compiler.core.SourceModuleId) ?Module {
            self.visits.* += 1;
            return .{ .imports = self.imports };
        }
    };
    const imports = [_]snapshot_api.ImportFact{.{ .spec = &.{}, .spec_span = .{ .start = 0, .end = 0 }, .unqualified = true }} ** 512;
    var visits: usize = 0;
    cancellation.checks = 0;
    budget = query_types.QueryBudget.start(.{
        .budget_ms = 1000,
        .cancellation = .{ .context = &cancellation, .is_canceled = ParseCancellation.canceled },
    });
    try testing.expect(resolve_query.valueBinding(budget, ImportView{ .imports = &imports, .visits = &visits }, 0, "absent", null, .function) == null);
    try testing.expect(cancellation.checks >= cancellation.limit);
    try testing.expect(cancellation.checks <= cancellation.limit + 8);
    try testing.expect(visits < cancellation.limit);
}
