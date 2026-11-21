const std = @import("std");
const compiler = @import("compiler");
const testing = std.testing;

const root = "/include-spec/main.ss";
const clock_context: u8 = 0;

fn frozenNow(_: *const anyopaque) i128 {
    return 0;
}

fn parse(overlay: *const compiler.module_loader.SourceOverlay, text: []const u8) !compiler.syntax.Module {
    var includes = compiler.module_loader.IncludeLoader{ .io = testing.io, .overlay = overlay };
    return compiler.syntax.parseWithOptions(testing.allocator, text, root, .{ .include_resolver = includes.resolver() });
}

test "include shares declarations and expands stages and show in source order" {
    var overlay = compiler.module_loader.SourceOverlay.init(testing.allocator);
    defer overlay.deinit();
    try overlay.put("/include-spec/parts/body.ss",
        \\include "../helpers.ss"
        \\page Body
        \\  stages s { first second }
        \\  show s == s.second
        \\    text!(message())
        \\  end
        \\end
    );
    try overlay.put("/include-spec/helpers.ss", "fn message() -> String = title\n");
    var source = try testing.allocator.dupe(u8,
        \\const title: String = "Shared"
        \\page Before
        \\end
        \\include "parts/body.ss"
        \\page After
        \\  text!(message())
        \\end
    );
    defer testing.allocator.free(source);
    var syntax = try parse(&overlay, source);
    defer syntax.deinit(testing.allocator);
    const expanded = try compiler.syntax.printExpandedAlloc(testing.allocator, syntax);
    defer testing.allocator.free(expanded);
    const before = std.mem.indexOf(u8, expanded, "page \"Before\"").?;
    const body = std.mem.indexOf(u8, expanded, "page \"Body / first\"").?;
    const after = std.mem.indexOf(u8, expanded, "page \"After\"").?;
    try testing.expect(before < body and body < after);
    var index = try compiler.analysis.loadModuleIndex(testing.allocator, testing.io, "/include-spec", syntax, .{ .overlay = &overlay });
    defer index.deinit();
    var state = try compiler.analysis.buildDocumentState(testing.allocator, root, "/include-spec", &source, &syntax, &index);
    defer state.deinit();
    var graph = (try compiler.analysis.analyzeDocumentStateWithMode(testing.allocator, &state, .evaluation)).?;
    defer graph.deinit();
    try compiler.lowering.evaluateDocument(&state, &graph, .{ .io = testing.io });
    try testing.expectEqual(@as(usize, 4), state.graph.page_order.items.len);
    const pages = state.graph.page_order.items;
    const first = state.placementRootsOf(pages[1])[0];
    const second = state.placementRootsOf(pages[2])[0];
    try testing.expect(!state.isDrawn(first));
    try testing.expect(state.isDrawn(second));
    try testing.expectEqualStrings("Shared", compiler.core.nodeDisplayContent(state.getNode(second).?));
}

test "include rejects cycles and repeated physical files" {
    var overlay = compiler.module_loader.SourceOverlay.init(testing.allocator);
    defer overlay.deinit();
    try overlay.put("/include-spec/one.ss", "include \"main.ss\"\n");
    try overlay.put(root, "include \"one.ss\"\n");
    try testing.expectError(error.IncludeCycle, parse(&overlay, "include \"one.ss\"\n"));
    try overlay.put("/include-spec/one.ss", "page One\nend\n");
    try testing.expectError(error.DuplicateInclude, parse(&overlay, "include \"one.ss\"\ninclude \"./one.ss\"\n"));
}

test "include expands integer stages and retains physical declaration spans" {
    var overlay = compiler.module_loader.SourceOverlay.init(testing.allocator);
    defer overlay.deinit();
    const child_source = "page Range\nstages i { 1:2 }\nlet value = i\nend\npage List\nstages i { 7 1 }\nlet value = i\nend\n";
    try overlay.put("/include-spec/integers.ss", child_source);
    var module = try parse(&overlay, "include \"integers.ss\"\n");
    defer module.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 4), module.pages.items.len);
    for (module.pages.items, [_]f32{ 1, 2, 7, 1 }) |page, value| {
        try testing.expectEqual(value, page.statements.items[0].kind.let_binding.expr.number);
        const file = module.source_files.items[0];
        try testing.expectEqualStrings("/include-spec/integers.ss", file.path);
        const span = page.stages.?.span;
        try testing.expect(std.mem.startsWith(u8, child_source[span.start - file.offset .. span.end - file.offset], "stages i"));
    }
}

test "include snapshots map cross-file definitions and semantic errors to physical sources" {
    const api = compiler.analysis.snapshot;
    const child_path = "/include-spec/child.ss";
    const main_source = "const title: String = \"Shared\"\ninclude \"child.ss\"\npage Main\n  let result = label()\nend\n";
    const child_source = "fn label() -> String = title\npage Child\n  let local: Number = 42\n  let result = local\nend\n";
    var sources = api.SourceSet.init(testing.allocator, testing.io);
    defer sources.deinit();
    try sources.put(root, main_source);
    try sources.put(child_path, child_source);
    var snapshot = try api.build(testing.allocator, &sources, root, "/include-spec", .{});
    defer snapshot.deinit();
    try testing.expect(!snapshot.diagnostics.hasErrors());
    try testing.expect(snapshot.coversPath(child_path));
    try testing.expectEqualStrings(main_source, api.sourceForPath(&snapshot, root).?);
    try testing.expectEqualStrings(child_source, api.sourceForPath(&snapshot, child_path).?);
    const requests = .{
        .{ root, main_source, "label()", child_path, @as(usize, 0) },
        .{ child_path, child_source, "title", root, @as(usize, 0) },
        .{ child_path, child_source, "= local", child_path, @as(usize, 2) },
    };
    inline for (requests) |item| {
        const offset = std.mem.lastIndexOf(u8, item[1], item[2]).? + item[2].len - 2;
        for ([_]u32{ 1000, 0 }) |budget_ms| {
            const targets = try api.definitionAt(testing.allocator, &snapshot, .{ .path = item[0], .source = item[1], .offset = offset }, .{
                .budget_ms = budget_ms,
                .clock = .{ .context = &clock_context, .now_ns = frozenNow },
            });
            defer testing.allocator.free(targets);
            try testing.expectEqual(@as(usize, 1), targets.len);
            try testing.expectEqualStrings(item[3], targets[0].path.?);
            try testing.expectEqual(item[4], targets[0].line);
        }
    }
    try sources.put(child_path, "fn label() -> String = missing\n");
    var invalid = try api.build(testing.allocator, &sources, root, "/include-spec", .{});
    defer invalid.deinit();
    try testing.expect(invalid.diagnostics.hasErrors());
    var found = false;
    for (invalid.diagnostics.items.items) |diagnostic| {
        if (!std.mem.eql(u8, diagnostic.code, "UnknownIdentifier")) continue;
        try testing.expectEqualStrings(child_path, diagnostic.path);
        try testing.expectEqual(@as(usize, 23), diagnostic.span.?.start);
        found = true;
    }
    try testing.expect(found);
}

test "include snapshots resolve forward document and staged page bindings across physical sources" {
    const api = compiler.analysis.snapshot;
    const child_path = "/include-spec/child.ss";
    const main_source =
        \\document
        \\  let result = suffix
        \\  let prefix = "Root"
        \\end
        \\include "child.ss"
    ;
    const child_source =
        \\document
        \\  let suffix = prefix ++ " child"
        \\end
        \\page Child
        \\  stages i { 1:2 }
        \\  let copy = title
        \\  let title = text!("Included")
        \\end
    ;
    var sources = api.SourceSet.init(testing.allocator, testing.io);
    defer sources.deinit();
    try sources.put(root, main_source);
    try sources.put(child_path, child_source);
    var snapshot = try api.build(testing.allocator, &sources, root, "/include-spec", .{});
    defer snapshot.deinit();
    try testing.expect(!snapshot.diagnostics.hasErrors());
    const requests = .{
        .{ root, main_source, "= suffix", child_path, @as(usize, 1) },
        .{ child_path, child_source, "= prefix", root, @as(usize, 2) },
        .{ child_path, child_source, "= title", child_path, @as(usize, 6) },
    };
    inline for (requests) |item| {
        const offset = std.mem.indexOf(u8, item[1], item[2]).? + item[2].len - 2;
        const targets = try api.definitionAt(testing.allocator, &snapshot, .{ .path = item[0], .source = item[1], .offset = offset }, .{
            .budget_ms = 1000,
            .clock = .{ .context = &clock_context, .now_ns = frozenNow },
        });
        defer testing.allocator.free(targets);
        try testing.expectEqual(@as(usize, 1), targets.len);
        try testing.expectEqualStrings(item[3], targets[0].path.?);
        try testing.expectEqual(item[4], targets[0].line);
    }
}

test "include reference queries map page and binding targets to their physical declarations" {
    const api = compiler.analysis.snapshot;
    const child_path = "/include-spec/child.ss";
    const main_source =
        \\page Reader
        \\  let peer = &Target::item
        \\  let own = text!("Local")
        \\end
        \\include "child.ss"
    ;
    const child_source =
        \\page Target
        \\  let peer = &Reader::own
        \\  let item = text!("Included")
        \\end
        \\page Repeated
        \\  stages i { 1:2 }
        \\  let self_ref = &Repeated::item
        \\  let item = text!(str(i))
        \\end
    ;
    var sources = api.SourceSet.init(testing.allocator, testing.io);
    defer sources.deinit();
    try sources.put(root, main_source);
    try sources.put(child_path, child_source);
    var snapshot = try api.build(testing.allocator, &sources, root, "/include-spec", .{});
    defer snapshot.deinit();
    try testing.expect(!snapshot.diagnostics.hasErrors());
    const requests = .{
        .{ root, main_source, "&Target::item", 2, child_path, 0, "page Target" },
        .{ root, main_source, "&Target::item", 10, child_path, 2, "Ref<Placed<Text>>" },
        .{ child_path, child_source, "&Reader::own", 2, root, 0, "page Reader" },
        .{ child_path, child_source, "&Reader::own", 10, root, 2, "Ref<Placed<Text>>" },
        .{ child_path, child_source, "&Repeated::item", 2, child_path, 4, "page Repeated" },
        .{ child_path, child_source, "&Repeated::item", 12, child_path, 7, "Ref<Placed<Text>>" },
    };
    const options = compiler.analysis.query.types.QueryOptions{
        .budget_ms = 1000,
        .clock = .{ .context = &clock_context, .now_ns = frozenNow },
    };
    inline for (requests) |item| {
        const request = compiler.analysis.query.types.SourceRequest{
            .path = item[0],
            .source = item[1],
            .offset = std.mem.indexOf(u8, item[1], item[2]).? + item[3],
        };
        var hover = (try api.hoverAt(testing.allocator, &snapshot, request, options)) orelse return error.ExpectedHover;
        defer hover.deinit(testing.allocator);
        try testing.expect(std.mem.indexOf(u8, hover.markdown, item[6]) != null);
        const targets = try api.definitionAt(testing.allocator, &snapshot, request, options);
        defer testing.allocator.free(targets);
        try testing.expectEqual(@as(usize, 1), targets.len);
        try testing.expectEqualStrings(item[4], targets[0].path.?);
        try testing.expectEqual(@as(usize, item[5]), targets[0].line);
    }
}

test "include syntax owns included type names across cloning and allocation failures" {
    var overlay = compiler.module_loader.SourceOverlay.init(testing.allocator);
    defer overlay.deinit();
    try overlay.put("/include-spec/types.ss", "type Card { value: Label }\ntype Label { text: String }\n");
    try @import("allocation_testing").checkAllAllocationFailures(testing.allocator, cloneIncludedTypes, .{&overlay});
}

fn cloneIncludedTypes(allocator: std.mem.Allocator, overlay: *const compiler.module_loader.SourceOverlay) !void {
    var includes = compiler.module_loader.IncludeLoader{ .io = testing.io, .overlay = overlay };
    var parsed: ?compiler.syntax.Module = try compiler.syntax.parseWithOptions(allocator, "include \"types.ss\"\n", root, .{ .include_resolver = includes.resolver() });
    defer if (parsed) |*value| value.deinit(allocator);
    var copy = try parsed.?.clone(allocator);
    defer copy.deinit(allocator);
    parsed.?.deinit(allocator);
    parsed = null;
    try testing.expectEqualStrings("Label", copy.records.items[0].fields.items[0].value_type.class_name.?);
}
