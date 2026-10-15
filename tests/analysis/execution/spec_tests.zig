const std = @import("std");
const compiler = @import("compiler");
const core = compiler.core;
const testing = std.testing;

fn document(source: []const u8) !core.DocumentState {
    const allocator = testing.allocator;
    var text = try allocator.dupe(u8, source);
    defer allocator.free(text);
    var syntax = try compiler.syntax.parseWithSourceName(allocator, text, "execution.ss");
    defer syntax.deinit(allocator);
    var modules = try compiler.analysis.loadModuleIndex(allocator, testing.io, ".", syntax, .{});
    defer modules.deinit();
    return compiler.analysis.buildDocumentState(allocator, "execution.ss", ".", &text, &syntax, &modules);
}

test "diagnostic analysis leaves pages untouched while evaluation registers ordered pages and origins" {
    var state = try document(
        \\page first
        \\  text!("First")
        \\end
        \\page second
        \\  text!("Second")
        \\end
    );
    defer state.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const node_count = state.graph.nodes.items.len;
    try testing.expect((try compiler.analysis.analyzeDocumentStateWithMode(arena.allocator(), &state, .diagnostics_only)) == null);
    try testing.expectEqual(node_count, state.graph.nodes.items.len);
    try testing.expectEqual(@as(usize, 0), state.graph.page_order.items.len);
    try testing.expectEqual(@as(usize, 0), state.source_map.pages.items.len);
    var graph = (try compiler.analysis.analyzeDocumentStateWithMode(arena.allocator(), &state, .evaluation)).?;
    defer graph.deinit();
    try testing.expectEqual(@as(usize, 2), state.graph.page_order.items.len);
    try testing.expectEqual(@as(usize, 2), state.source_map.pages.items.len);
    for ([_][]const u8{ "first", "second" }, 0..) |name, index| {
        const page_id = state.graph.page_order.items[index];
        try testing.expectEqualStrings(name, state.getNode(page_id).?.name);
        const origin = state.source_map.pages.items[index];
        try testing.expectEqual(page_id, origin.page_id);
        try testing.expectEqualStrings("execution.ss", origin.path);
        try testing.expect(origin.span_end > origin.span_start);
        const unit = graph.units.items[index];
        try testing.expectEqual(page_id, unit.kind.page_statement.page_id);
        try testing.expectEqual(index, unit.source_order);
    }
}

test "dependency cycle diagnostics retain source locations in both graph construction modes" {
    for ([_]compiler.analysis.AnalysisMode{ .diagnostics_only, .evaluation }) |mode| {
        var state = try document(
            \\page bad
            \\  let target = text("hello")
            \\  target.content = target.content ++ "!"
            \\end
        );
        defer state.deinit();
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        try testing.expectError(error.ExecutionDependencyCycle, compiler.analysis.analyzeDocumentStateWithMode(arena.allocator(), &state, mode));
        try testing.expectEqual(@as(usize, if (mode == .evaluation) 1 else 0), state.graph.page_order.items.len);
        const diagnostic = state.diagnostics.entries.items[state.diagnostics.entries.items.len - 1];
        try testing.expectEqualStrings("ExecutionDependencyCycle", diagnostic.code());
        const origin = diagnostic.origin.?.location().?;
        try testing.expectEqualStrings("execution.ss", origin.path.?);
        try testing.expect(origin.span.end > origin.span.start);
    }
}

// Keep freed allocations mapped but overwrite them, so stale string references
// fail deterministically rather than depending on allocator reuse.
const PoisonAllocator = struct {
    arena: std.heap.ArenaAllocator,

    fn allocator(self: *PoisonAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *PoisonAllocator = @ptrCast(@alignCast(ctx));
        return self.arena.allocator().rawAlloc(len, alignment, ret_addr);
    }

    fn resize(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) bool {
        return false;
    }

    fn remap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
        return null;
    }

    fn free(_: *anyopaque, memory: []u8, _: std.mem.Alignment, _: usize) void {
        @memset(memory, 0xa5);
    }
};

test "execution graph owns computed resource names after analyzers and cached summaries are destroyed" {
    var poison = PoisonAllocator{ .arena = std.heap.ArenaAllocator.init(testing.allocator) };
    defer poison.arena.deinit();
    // The testing allocator also checks that the graph's string storage is freed.
    for ([_]std.mem.Allocator{ poison.allocator(), testing.allocator }) |allocator| {
        var state = try document(
            \\fn read_size() -> Number = prop(docctx(), "font_" ++ "size")
            \\document
            \\  let first = read_size()
            \\end
            \\document
            \\  let second = read_size()
            \\end
            \\document
            \\  set_prop(docctx(), "font_" ++ "size", 24)
            \\end
            \\page main
            \\  let items = doc_objs(docctx(), "tag" ++ "ged")
            \\  let item = new("item", "tag" ++ "ged", "text")
            \\end
        );
        defer state.deinit();
        var declarations = try compiler.declarations.build(testing.allocator, &state);
        defer declarations.deinit();
        var graph = try compiler.analysis.ExecutionGraph.build(allocator, &state, &declarations, .{});
        defer graph.deinit();
        try testing.expectEqual(@as(usize, 5), graph.units.items.len);
        for (graph.units.items[0..2]) |unit| {
            var found = false;
            for (unit.summary.reads.items) |resource| {
                if (resource == .property and resource.property.owner == .document) {
                    if (resource.property.key.displayName()) |name| {
                        if (std.mem.eql(u8, name, "font_size")) found = true;
                    }
                }
            }
            try testing.expect(found);
        }
        var found_role = false;
        for (graph.units.items[3].summary.reads.items) |resource| {
            if (resource == .objects) {
                if (resource.objects) |role| {
                    if (std.mem.eql(u8, role, "tagged")) found_role = true;
                }
            }
        }
        try testing.expect(found_role);
        for ([_]compiler.analysis.DependencyEdge{ .{ .from = 2, .to = 0 }, .{ .from = 2, .to = 1 }, .{ .from = 4, .to = 3 } }) |expected| {
            var found = false;
            for (graph.edges.items) |edge| {
                if (edge.from == expected.from and edge.to == expected.to) found = true;
            }
            try testing.expect(found);
        }
    }
}
