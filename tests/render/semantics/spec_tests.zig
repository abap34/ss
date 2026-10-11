const LayoutFixture = @import("layout_testing").Fixture;
const std = @import("std");
const compiler = @import("compiler");
const core = compiler.core;
const render = @import("render");
const render_compile = @import("render_compile");
const testing = std.testing;

fn document(source: []const u8) !core.DocumentState {
    const allocator = testing.allocator;
    var text = try allocator.dupe(u8, source);
    defer allocator.free(text);
    var syntax = try compiler.syntax.parseWithSourceName(allocator, text, "semantics.ss");
    defer syntax.deinit(allocator);
    var modules = try compiler.analysis.loadModuleIndex(allocator, testing.io, ".", syntax, .{});
    defer modules.deinit();
    return compiler.analysis.buildDocumentState(allocator, "semantics.ss", ".", &text, &syntax, &modules);
}

fn evaluate(state: *core.DocumentState) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var graph = (try compiler.analysis.analyzeDocumentStateWithMode(arena.allocator(), state, .evaluation)).?;
    defer graph.deinit();
    try compiler.lowering.evaluateDocument(state, &graph, .{ .io = testing.io });
}

fn objectSemantic(ir: *const render.Ir, index: usize) *const render.SemanticNode {
    return ir.semantics.find(ir.pages[0].reading_order[index]).?;
}

test "standard constructors and custom roles resolve typed semantic attributes into IR" {
    var state = try document(
        \\import std:themes/default as *
        \\type CustomHeading = object {
        \\  base = Text
        \\  roles = ["custom-heading"]
        \\  semantics: SemanticStyle = SemanticStyle { role = SemanticRole.heading, heading_level = 3 }
        \\}
        \\type CustomCaption = object {
        \\  base = Text
        \\  roles = ["custom-caption"]
        \\  semantics: SemanticStyle = SemanticStyle { role = SemanticRole.caption }
        \\}
        \\page main
        \\  title!("Title")
        \\  subtitle!("Subtitle")
        \\  code_obj!("source")
        \\  fig_obj!("diagram")
        \\  txt_obj!("First\n\n## Second", "custom-heading")
        \\  txt_obj!("Custom caption", "custom-caption")
        \\  text!("## Markdown heading")
        \\end
    );
    defer state.deinit();
    try evaluate(&state);
    var state_layout = LayoutFixture.init(&state);
    defer state_layout.deinit();
    for (state.graph.nodes.items) |node| (try state_layout.frame(node.id)).* = .{ .width = 640, .height = 360 };
    var prepared = try core.prepared.prepare(testing.allocator, &state);
    defer prepared.deinit(testing.allocator);
    var ir = try render_compile.compile(testing.allocator, testing.io, &state, &prepared, try state_layout.document(), .{ .jobs = 1 });
    defer ir.deinit(testing.allocator);
    try ir.validate();
    const roles = [_]render.SemanticRole{ .heading, .heading, .code, .figure, .heading, .caption, .heading };
    try testing.expectEqual(roles.len, ir.pages[0].reading_order.len);
    for (roles, 0..) |role, index| try testing.expectEqual(role, objectSemantic(&ir, index).role);
    try testing.expectEqual(@as(?u8, 1), objectSemantic(&ir, 0).heading_level);
    try testing.expectEqual(@as(?u8, 2), objectSemantic(&ir, 1).heading_level);
    try testing.expectEqual(@as(?u8, 3), objectSemantic(&ir, 4).heading_level);
    try testing.expectEqual(@as(?u8, 2), objectSemantic(&ir, 6).heading_level);
    for (objectSemantic(&ir, 4).children) |child| try testing.expectEqual(render.SemanticRole.text, ir.semantics.find(child).?.role);
}

test "semantic-only edits update cached rendering without changing paint" {
    var state = try document(
        \\import std:themes/default as *
        \\page main
        \\  title!("Same paint")
        \\end
    );
    defer state.deinit();
    try evaluate(&state);
    var state_layout = LayoutFixture.init(&state);
    defer state_layout.deinit();
    for (state.graph.nodes.items) |node| (try state_layout.frame(node.id)).* = .{ .width = 640, .height = 360 };
    var prepared = try core.prepared.prepare(testing.allocator, &state);
    defer prepared.deinit(testing.allocator);
    var cache = render_compile.PageCache.init(testing.allocator, testing.io);
    defer cache.deinit();
    var first = try render_compile.compile(testing.allocator, testing.io, &state, &prepared, try state_layout.document(), .{ .jobs = 1, .page_cache = &cache });
    defer first.deinit(testing.allocator);
    prepared.pages[0].objects[0].semantics = .caption;
    var cached = try render_compile.compile(testing.allocator, testing.io, &state, &prepared, try state_layout.document(), .{ .jobs = 1, .page_cache = &cache });
    defer cached.deinit(testing.allocator);
    var fresh = try render_compile.compile(testing.allocator, testing.io, &state, &prepared, try state_layout.document(), .{ .jobs = 1 });
    defer fresh.deinit(testing.allocator);
    try testing.expectEqual(render.SemanticRole.caption, objectSemantic(&cached, 0).role);
    try testing.expectEqual(fresh.fingerprint(), cached.fingerprint());
    try testing.expectEqual(render.pageContentFingerprint(&first.pages[0]), render.pageContentFingerprint(&cached.pages[0]));
    try testing.expect(!std.mem.eql(u8, &first.fingerprint(), &cached.fingerprint()));
}

test "semantic attribute types are checked statically and invalid levels are diagnosed during preparation" {
    var wrong_type = try document(
        \\type Bad = object {
        \\  base = Text
        \\  roles = ["bad"]
        \\  semantics: SemanticStyle = SemanticStyle { heading_level = "three" }
        \\}
        \\page main
        \\  txt_obj!("Bad", "bad")
        \\end
    );
    defer wrong_type.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var type_failed = false;
    compiler.analysis.analyzeDocumentState(arena.allocator(), &wrong_type) catch {
        type_failed = true;
    };
    try testing.expect(type_failed);
    for ([_][]const u8{
        "role = SemanticRole.heading",
        "role = SemanticRole.heading, heading_level = 0",
        "role = SemanticRole.heading, heading_level = 7",
        "role = SemanticRole.heading, heading_level = 2.5",
        "role = SemanticRole.caption, heading_level = 2",
    }) |fields| {
        const source = try std.fmt.allocPrint(testing.allocator, "type Bad = object {{\n base = Text\n roles = [\"bad\"]\n semantics: SemanticStyle = SemanticStyle {{ {s} }}\n }}\npage main\n  txt_obj!(\"Bad\", \"bad\")\nend\n", .{fields});
        defer testing.allocator.free(source);
        var state = try document(source);
        defer state.deinit();
        try evaluate(&state);
        try testing.expectError(error.InvalidSemanticAttributes, core.prepared.prepare(testing.allocator, &state));
        const diagnostic = state.diagnostics.entries.items[state.diagnostics.entries.items.len - 1];
        try testing.expectEqualStrings("InvalidSemanticAttributes", diagnostic.code());
        try testing.expect(diagnostic.origin != null);
    }
}
