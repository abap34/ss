const std = @import("std");
const compiler = @import("compiler");
const core = compiler.core;
const testing = std.testing;

const implementation =
    \\const suffix: String = "original"
    \\record Item { value: String = "original" }
    \\type Choice = first | second
    \\type Card = object { roles = ["exported-card"] }
    \\fn default_item() -> Item
    \\  return Item { value = suffix }
    \\end
    \\fn/! make(item: Item = default_item()) -> Object
    \\  return new(item.value, "exported-card", "text")
    \\end
    \\fn hidden() -> Number
    \\  return 99
    \\end
;
const facade = "import a as { make, make!, Item, Choice, Card, suffix }\n";

const Options = struct {
    diagnostic: ?[]const u8 = null,
    verify: ?*const fn (*core.DocumentState) anyerror!void = null,
};

fn exercise(source: []const u8, first: []const u8, second: []const u8, options: Options) !void {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const path = try std.fs.path.join(allocator, &.{ root, "main.ss" });
    var overlay = compiler.module_loader.SourceOverlay.init(allocator);
    defer overlay.deinit();
    try overlay.put(try std.fs.path.join(allocator, &.{ root, "a.ss" }), first);
    try overlay.put(try std.fs.path.join(allocator, &.{ root, "b.ss" }), second);
    var source_buf = try allocator.dupe(u8, source);
    var syntax = try compiler.syntax.parseWithSourceName(allocator, source_buf, path);
    var modules = try compiler.analysis.loadModuleIndex(allocator, testing.io, root, syntax, .{ .overlay = &overlay });
    defer modules.deinit();
    var state = try compiler.analysis.buildDocumentStateWithOptions(allocator, path, root, &source_buf, &syntax, &modules, .{});
    defer state.deinit();
    errdefer for (state.diagnostics.items) |diagnostic| {
        if (diagnostic.data == .user_report) std.debug.print("{s}: {s}\n", .{ diagnostic.origin orelse "", diagnostic.data.user_report.message });
    };
    if (options.diagnostic) |expected| {
        try testing.expectError(error.DiagnosticsFailed, compiler.analysis.analyzeDocumentState(allocator, &state));
        for (state.diagnostics.items) |diagnostic| {
            if (diagnostic.data == .user_report and std.mem.startsWith(u8, diagnostic.data.user_report.message, expected)) return;
        }
        return error.ExpectedDiagnostic;
    }
    var graph = (try compiler.analysis.analyzeDocumentStateWithMode(allocator, &state, .evaluation)).?;
    defer graph.deinit();
    try compiler.lowering.evaluateDocument(&state, &graph, .{ .io = testing.io });
    if (options.verify) |verify| try verify(&state);
}

fn verifyOriginalDeclarations(state: *core.DocumentState) !void {
    const sema = compiler.semantic_env.SemanticEnv.init(state, state.declaration_index, &state.functions);
    const direct = sema.resolvedFunction(.{ .qualifier = "a", .name = "make" }) orelse return error.MissingFunction;
    const reexported = sema.resolvedFunction(.{ .qualifier = "b", .name = "make" }) orelse return error.MissingFunction;
    const selected = sema.resolvedFunction(.bare("make")) orelse return error.MissingFunction;
    try testing.expectEqual(direct.module_id, reexported.module_id);
    try testing.expectEqual(direct.module_id, selected.module_id);
    try testing.expect(direct.decl.params.items.ptr == reexported.decl.params.items.ptr);
    try testing.expect(direct.decl.statements.items.ptr == selected.decl.statements.items.ptr);
    const placed = sema.resolvedFunction(.bare("make!")) orelse return error.MissingFunction;
    try testing.expectEqual(direct.module_id, placed.module_id);
    const original_type = sema.resolveTypeNameInContext(0, "a::Item") orelse return error.MissingType;
    const exported_type = sema.resolveTypeNameInContext(0, "b::Item") orelse return error.MissingType;
    try testing.expectEqual(original_type.nominal_module_id, exported_type.nominal_module_id);
    for (state.nodes.items) |*node| {
        if (node.kind != .object) continue;
        try testing.expectEqualStrings("original", core.nodeDisplayContent(node));
    }
}

test "selected imports preserve declarations, default environments and placement pairs" {
    try exercise(
        \\import a as a
        \\import b as b
        \\import b as { make, make!, Item, Choice, Card, suffix }
        \\const suffix: String = "caller"
        \\fn default_item() -> String
        \\  return "caller"
        \\end
        \\page main
        \\  let item: a::Item = Item {}
        \\  let choice: a::Choice = Choice.first
        \\  let card: Card = new("original", "exported-card", "text")
        \\  make!()
        \\  b::make!()
        \\  a::make!()
        \\end
    , implementation, facade, .{ .verify = verifyOriginalDeclarations });
}

test "selected imports reject missing names even without a use" {
    try exercise("import b as { hidden }\n", implementation, facade, .{ .diagnostic = "UnknownImportedName:" });
    try exercise("import a as { missing }\n", implementation, "", .{ .diagnostic = "UnknownImportedName:" });
}

test "selected imports do not turn open imports or the implicit prelude into exports" {
    try exercise("import b as { make }\n", implementation, "import a as *\n", .{ .diagnostic = "UnknownImportedName:" });
    try exercise("import b as { text }\n", implementation, "", .{ .diagnostic = "UnknownImportedName:" });
}

test "selected imports expose only the selected placement variant" {
    try exercise(
        \\import b as b
        \\page main
        \\  b::make!()
        \\end
    , implementation, "import a as { make }\n", .{ .diagnostic = "UnknownFunction:" });
}

test "selected bindings precede open imports and local declarations precede both" {
    const first = "const value: String = \"selected\"\n";
    const second = "const value: Number = 12\n";
    inline for (.{ "import a as { value }\nimport b as *\n", "import b as *\nimport a as { value }\n" }) |imports| {
        try exercise(imports ++ "page main\n  let s: String = value\nend\n", first, second, .{});
        try exercise(imports ++ "const value: Bool = true\npage main\n  let b: Bool = value\nend\n", first, second, .{});
    }
}

test "prelude exports use the canonical parameters without forwarding functions" {
    try exercise(
        \\import std:core/prelude as prelude
        \\page main
        \\  prelude::pageno_obj!(decorate)
        \\end
        \\fn decorate(item: Object) -> Object
        \\  return body_obj("custom")
        \\end
    , "", "", .{ .verify = struct {
        fn verify(state: *core.DocumentState) !void {
            const prelude = state.moduleByPathOrSpec("std:core/prelude") orelse return error.MissingPrelude;
            try testing.expectEqual(@as(usize, 0), prelude.syntax.functions.items.len);
            const sema = compiler.semantic_env.SemanticEnv.init(state, state.declaration_index, &state.functions);
            const function = sema.resolvedFunction(.{ .qualifier = "prelude", .name = "pageno_obj!" }) orelse return error.MissingFunction;
            const generated = state.moduleByPathOrSpec("std:core/generated") orelse return error.MissingModule;
            try testing.expectEqual(generated.id, function.module_id);
            try testing.expectEqual(@as(usize, 1), function.decl.params.items.len);
            var found_custom = false;
            for (state.nodes.items) |*node| {
                if (std.mem.eql(u8, core.nodeDisplayContent(node), "custom")) found_custom = true;
            }
            try testing.expect(found_custom);
        }
    }.verify });
}
