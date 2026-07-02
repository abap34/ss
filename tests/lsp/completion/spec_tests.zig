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
    const item = resolve_query.valueBinding(snapshot, module.id, "text", null, .function) orelse return error.ExpectedFunction;

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
        const variable = resolve_query.visibleVariableBinding(snapshot, module.id, offset, "x") orelse return error.ExpectedVariable;
        try testing.expectEqualStrings("x", variable.name);
        try testing.expectEqualStrings("String", variable.type_label);
        const definition = resolve_query.visibleVariable(snapshot, module.id, offset, "x") orelse return error.ExpectedDefinition;
        try testing.expectEqual(compiler.core.DefinitionKind.variable, definition.kind);
        try testing.expectEqual(module.id, definition.module_id);
    }

    {
        const snapshot = try case.snapshotFor(case.source);
        const module = snapshot.moduleForPath(case.path) orelse return error.ExpectedModule;
        const offset = offsetAfter(case.source, "page_probe = x");
        const variable = resolve_query.visibleVariableBinding(snapshot, module.id, offset, "x") orelse return error.ExpectedVariable;
        try testing.expectEqualStrings("Number", variable.type_label);
        const definition = resolve_query.visibleVariable(snapshot, module.id, offset, "x") orelse return error.ExpectedDefinition;
        try testing.expectEqual(compiler.core.DefinitionKind.variable, definition.kind);
        try testing.expectEqual(module.id, definition.module_id);
    }

    {
        const snapshot = try case.snapshotFor(case.source);
        const module = snapshot.moduleForPath(case.path) orelse return error.ExpectedModule;
        const offset = offsetAfter(case.source, "fn_probe = x");
        const variable = resolve_query.visibleVariableBinding(snapshot, module.id, offset, "x") orelse return error.ExpectedVariable;
        try testing.expectEqualStrings("Bool", variable.type_label);
        const definition = resolve_query.visibleVariable(snapshot, module.id, offset, "x") orelse return error.ExpectedDefinition;
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
        self.snapshot = try buildSnapshot(self.allocator, self.path, source);
        return if (self.snapshot) |*snapshot| snapshot else unreachable;
    }
};

fn buildSnapshot(allocator: std.mem.Allocator, path: []const u8, source: []const u8) !snapshot_api.AnalysisSnapshot {
    const asset_base_dir = std.fs.path.dirname(path) orelse ".";
    var sources = snapshot_api.SourceSet.init(allocator, testing.io);
    defer sources.deinit();
    try sources.put(path, source);
    return snapshot_api.buildSnapshot(allocator, &sources, path, asset_base_dir, .{});
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
