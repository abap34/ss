const LayoutFixture = @import("layout_testing").Fixture;
const std = @import("std");
const compiler = @import("compiler");
const core = compiler.core;
const render = @import("render");
const render_compile = @import("render_compile");
const testing = std.testing;
const test_cache_dir = ".test-tmp/render/semantics/cache";

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

test "prepared backgrounds use the same page theme fallback as display functions" {
    var state = try document(
        \\page inherited
        \\end
        \\page local
        \\  theme!(Theme {} with { page.background_fill = c"#00ff00" })
        \\end
        \\page absent
        \\  pagectx().theme = none
        \\end
        \\page explicit
        \\  pagectx().background_fill = c"#0000ff"
        \\end
        \\document
        \\  theme!(Theme {} with { page.background_fill = c"#ff0000" })
        \\end
    );
    defer state.deinit();
    try evaluate(&state);
    var pages = try core.prepared.prepare(testing.allocator, &state);
    defer pages.deinit(testing.allocator);
    const expected = [_][3]f32{ .{ 1, 0, 0 }, .{ 0, 1, 0 }, .{ 1, 0, 0 }, .{ 0, 0, 1 } };
    try testing.expectEqual(expected.len, pages.pages.len);
    for (pages.pages, expected) |page, rgb| {
        const color = page.background orelse return error.MissingBackground;
        try testing.expectEqual(rgb, [3]f32{ color.r, color.g, color.b });
    }
}

test "reusable native inputs read only the theme of their placement page" {
    var state = try document(
        \\const label: Heading = heading("Standalone", 2)
        \\const markup: Text = text("## Markdown")
        \\const symbol: Icon = icon("fa-solid:star")
        \\const shape: PathShape = rectangle(80, 20)
        \\fn examples!() -> Void
        \\  place!(label)
        \\  place!(markup)
        \\  place!(symbol)
        \\  place!(shape)
        \\  line!(70, 10)
        \\  let redrawn = line(60, 10, LineStyle { stroke = solid_stroke(c"#ff0000", 11) })
        \\  place!(redrawn with { style = VectorStyle { stroke = solid_stroke(c"#0000ff", 5) } })
        \\  pageno!()
        \\  heading!("Explicit", 2, default_text_style with { size = 12 })
        \\end
        \\page regular
        \\  examples!()
        \\end
        \\page special
        \\  examples!()
        \\  theme!(document_theme() with {
        \\    text.font.family = "DejaVu Serif"
        \\    text.align = Align.right
        \\    text.emoji_spacing = 0.5
        \\    text.color = c"#0000ff"
        \\    text.headings.h2.size = 40
        \\    image.scale = 2
        \\    path_shape.stroke.width = 7
        \\  })
        \\end
        \\document
        \\  theme!(Theme {} with {
        \\    text.font.family = "DejaVu Sans"
        \\    text.size = 20
        \\    text.line_height = 28
        \\    text.align = Align.center
        \\    text.emoji_spacing = 0.25
        \\    text.color = c"#ff0000"
        \\    text.headings.h2.font.weight = 650
        \\    text.headings.h2.size = 30
        \\    path_shape.fill = solid_fill(c"#ff0000")
        \\    path_shape.stroke.width = 3
        \\  })
        \\end
    );
    defer state.deinit();
    try evaluate(&state);
    var prepared = try core.prepared.prepare(testing.allocator, &state);
    defer prepared.deinit(testing.allocator);
    for (prepared.pages, 0..) |page, i| {
        const size: f32 = if (i == 0) 30 else 40;
        const family = if (i == 0) "DejaVu Sans" else "DejaVu Serif";
        var seen: usize = 0;
        for (page.objects) |obj| switch (obj.render.content) {
            .text => |paint| {
                if (std.mem.eql(u8, obj.content, "Explicit")) {
                    try testing.expectEqual(@as(f32, 12), paint.typography.font_size);
                    continue;
                }
                try testing.expectEqualStrings(family, paint.typography.font.family);
                const base = paint.typography;
                try testing.expectEqual(if (i == 0) core.render_paint.HorizontalAlign.center else .right, base.horizontal_align);
                try testing.expectEqual(@as(f32, if (i == 0) 0.25 else 0.5), base.emoji_spacing);
                try testing.expectEqual(@as(f32, if (i == 0) 1 else 0), base.color.r);
                try testing.expectEqual(@as(f32, if (i == 0) 0 else 1), base.color.b);
                if (std.mem.eql(u8, obj.content, "Standalone") or std.mem.eql(u8, obj.content, "## Markdown")) {
                    const effective = if (obj.content[0] == '#') paint.forMarkdownHeading(2) else paint;
                    try testing.expectEqual(size, effective.typography.font_size);
                    try testing.expectEqual(size * 1.4, effective.typography.line_height);
                    try testing.expectEqual(@as(u16, 650), effective.typography.font.weight);
                    try testing.expectEqualStrings(family, effective.typography.font.family);
                } else try testing.expectEqual(@as(f32, 13), paint.typography.font_size);
                seen += 1;
            },
            .vector_asset => |asset| {
                try testing.expectEqual(@as(f32, if (i == 0) 1 else 2), asset.scale);
                seen += 1;
            },
            .vector_path => |path| {
                if (path.natural_size.?.width == 60) {
                    try testing.expectEqual(@as(f32, 5), path.stroke.?.width);
                    try testing.expectEqual(@as(f32, 1), path.stroke.?.color.b);
                    try testing.expect(path.fill.base == .none);
                    continue;
                }
                try testing.expectEqual(@as(f32, if (i == 0) 3 else 7), path.stroke.?.width);
                if (path.natural_size.?.width == 80) {
                    try testing.expect(path.fill.base == .solid);
                } else try testing.expect(path.fill.base == .none);
                seen += 1;
            },
            else => {},
        };
        try testing.expectEqual(@as(usize, 6), seen);
    }
}

test "a cached gradient follows the path contents and ignores allocation identity" {
    var state = try document(
        \\page example
        \\  rectangle!(100, 40, VectorStyle { fill = linear_gradient_fill(c"#ff0000", c"#0000ff") })
        \\end
    );
    defer state.deinit();
    try evaluate(&state);
    var layout = LayoutFixture.init(&state);
    defer layout.deinit();
    for (state.graph.nodes.items) |node| (try layout.frame(node.id)).* = .{ .width = 100, .height = 40 };
    var prepared = try core.prepared.prepare(testing.allocator, &state);
    defer prepared.deinit(testing.allocator);
    const path = &prepared.pages[0].objects[0].render.content.vector_path;
    const copy = try testing.allocator.dupe(core.PathCommand, path.path.commands);
    defer testing.allocator.free(copy);
    var cache = render_compile.PageCache.init(testing.allocator, testing.io);
    defer cache.deinit();
    const options = render_compile.Options{ .cache_dir = test_cache_dir, .jobs = 1, .page_cache = &cache };
    for (0..4) |iteration| {
        switch (iteration) {
            1 => path.path.commands = copy,
            2 => copy[0].move_to.x = 0.25,
            3 => path.fill.base.linear.colors[1] = .{ .r = 0, .g = 1, .b = 0 },
            else => {},
        }
        var ir = try render_compile.compile(testing.allocator, testing.io, &state, &prepared, try layout.document(), options);
        defer ir.deinit(testing.allocator);
        const drawn = for (ir.pages[0].items.items) |item| {
            if (item == .vector_path) break item.vector_path;
        } else return error.MissingVectorPath;
        try testing.expectEqual(@as(f64, if (iteration < 2) 0 else 25), drawn.commands[0].move_to.x);
        try testing.expectEqual(@as(f32, if (iteration == 3) 1 else 0), drawn.fill.base.linear.stops[1].color.g);
        try testing.expectEqual(@as(usize, @max(1, iteration)), cache.entries.count());
    }
}

test "standalone and fenced code emit the same selected rows and bottom rule" {
    var state = try document(
        \\page separate
        \\  code!("one
        \\two
        \\three", "plain", none, "2")
        \\end
        \\page fenced
        \\  text!(<<
        \\```plain {2}
        \\one
        \\two
        \\three
        \\```
        \\>>)
        \\end
        \\document
        \\  theme!(Theme {} with {
        \\    text.code.line_height = 25
        \\    text.code.line_highlight_fill = c"#00ff00"
        \\    text.code.chrome.bottom_rule.color = c"#ff0000"
        \\    text.code.chrome.bottom_rule.width = 3
        \\  })
        \\end
    );
    defer state.deinit();
    try evaluate(&state);
    var layout = LayoutFixture.init(&state);
    defer layout.deinit();
    for (state.graph.nodes.items) |node| (try layout.frame(node.id)).* = .{ .width = 480, .height = 240 };
    var prepared = try core.prepared.prepare(testing.allocator, &state);
    defer prepared.deinit(testing.allocator);
    var ir = try render_compile.compile(testing.allocator, testing.io, &state, &prepared, try layout.document(), .{ .cache_dir = test_cache_dir, .jobs = 1 });
    defer ir.deinit(testing.allocator);
    for (ir.pages) |page| {
        var rows: usize = 0;
        var rules: usize = 0;
        for (page.items.items) |item| switch (item) {
            .fill_rect => |rect| if (rect.color.g == 1 and rect.color.r == 0) {
                rows += 1;
                try testing.expectApproxEqAbs(@as(f64, 25), rect.rect.height, 0.01);
            },
            .stroke_line => |line| if (line.color.r == 1 and line.color.g == 0) {
                rules += 1;
                try testing.expectEqual(@as(f64, 3), line.line_width);
            },
            else => {},
        };
        try testing.expectEqual(@as(usize, 1), rows);
        try testing.expectEqual(@as(usize, 1), rules);
    }
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
        try testing.expectEqual(@as(usize, 0), node.fields.items.len);
    }
    var state_layout = LayoutFixture.init(&state);
    defer state_layout.deinit();
    for (state.graph.nodes.items) |node| (try state_layout.frame(node.id)).* = .{ .width = 640, .height = 360 };
    var prepared = try core.prepared.prepare(testing.allocator, &state);
    defer prepared.deinit(testing.allocator);
    var ir = try render_compile.compile(testing.allocator, testing.io, &state, &prepared, try state_layout.document(), .{ .cache_dir = test_cache_dir, .jobs = 1 });
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
    var ir = try render_compile.compile(testing.allocator, testing.io, &state, &prepared, try state_layout.document(), .{ .cache_dir = test_cache_dir, .jobs = 1 });
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
    var ir = try render_compile.compile(testing.allocator, testing.io, &state, &prepared, try state_layout.document(), .{ .cache_dir = test_cache_dir, .jobs = 1 });
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
    var first = try render_compile.compile(testing.allocator, testing.io, &state, &prepared, try state_layout.document(), .{ .cache_dir = test_cache_dir, .jobs = 1, .page_cache = &cache });
    defer first.deinit(testing.allocator);
    prepared.pages[0].objects[0].semantics = .caption;
    var cached = try render_compile.compile(testing.allocator, testing.io, &state, &prepared, try state_layout.document(), .{ .cache_dir = test_cache_dir, .jobs = 1, .page_cache = &cache });
    defer cached.deinit(testing.allocator);
    var fresh = try render_compile.compile(testing.allocator, testing.io, &state, &prepared, try state_layout.document(), .{ .cache_dir = test_cache_dir, .jobs = 1 });
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
