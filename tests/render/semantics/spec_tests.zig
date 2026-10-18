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

test "typed headings and user displays preserve semantic attributes without role classes" {
    var state = try document(
        \\type Caption { content: String }
        \\fn display(self: Placed<Caption>) -> Text
        \\  return text(self.value.content) with {
        \\    semantics = TextSemantics { role = SemanticRole.caption }
        \\  }
        \\end
        \\page main
        \\  heading!("Title")
        \\  heading!("Subtitle", 2)
        \\  code!("source")
        \\  place!(text("diagram") with { semantics = TextSemantics { role = SemanticRole.figure } })
        \\  heading!("First\n\n## Second", 3)
        \\  place!(Caption { content = "Custom caption" })
        \\  text!("## Markdown heading")
        \\end
    );
    defer state.deinit();
    try evaluate(&state);
    for (state.graph.nodes.items) |node| {
        if (node.kind != .object) continue;
        try testing.expect(node.placement != null);
        try testing.expect(node.role == null);
        try testing.expectEqual(@as(usize, 0), node.fields.items.len);
    }
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

test "text semantic updates are immutable and preserved through typed groups" {
    var state = try document(
        \\page main
        \\  let caption = text("Same content") with { semantics = TextSemantics { role = SemanticRole.caption } }
        \\  let title = caption with { semantics = TextSemantics { role = SemanticRole.heading heading_level = 4 } }
        \\  place!(group(caption, group(title, caption)))
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
    try testing.expectEqual(@as(usize, 3), ir.pages[0].reading_order.len);
    try testing.expectEqual(render.SemanticRole.caption, objectSemantic(&ir, 0).role);
    try testing.expectEqual(render.SemanticRole.heading, objectSemantic(&ir, 1).role);
    try testing.expectEqual(@as(?u8, 4), objectSemantic(&ir, 1).heading_level);
    try testing.expectEqual(render.SemanticRole.caption, objectSemantic(&ir, 2).role);
}

test "semantic meaning comes from display values rather than user type names" {
    var state = try document(
        \\import std:document as doc
        \\type Heading { content: String }
        \\fn display(self: Placed<Heading>) -> Text = text(self.value.content)
        \\page main
        \\  doc::heading!("Standard", 2)
        \\  place!(Heading { content = "Custom" })
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
    try testing.expectEqual(@as(usize, 2), ir.pages[0].reading_order.len);
    try testing.expectEqual(render.SemanticRole.heading, objectSemantic(&ir, 0).role);
    try testing.expectEqual(@as(?u8, 2), objectSemantic(&ir, 0).heading_level);
    try testing.expectEqual(render.SemanticRole.paragraph, objectSemantic(&ir, 1).role);
}

test "semantic-only edits update cached rendering without changing paint" {
    var state = try document(
        \\import std:themes/default as *
        \\page main
        \\  place!(text("Same paint") with { semantics = TextSemantics { role = SemanticRole.heading heading_level = 1 } })
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
        \\page main
        \\  place!(text("Bad") with { semantics = TextSemantics { heading_level = "three" } })
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
        const source = try std.fmt.allocPrint(testing.allocator, "page main\n  place!(text(\"Bad\") with {{ semantics = TextSemantics {{ {s} }} }})\nend\n", .{fields});
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

test "standard heading levels are validated through their display output" {
    for ([_][]const u8{ "0", "7", "1.5" }) |level| {
        const source = try std.fmt.allocPrint(testing.allocator, "page main\n  heading!(\"Invalid level\", {s})\nend\n", .{level});
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
