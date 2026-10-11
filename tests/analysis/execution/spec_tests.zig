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
