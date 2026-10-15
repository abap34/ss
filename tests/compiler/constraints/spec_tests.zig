const std = @import("std");
const compiler = @import("compiler");
const testing = std.testing;
const core = compiler.core;

fn evaluate(allocator: std.mem.Allocator, source: []const u8) !core.DocumentState {
    var text = try allocator.dupe(u8, source);
    defer allocator.free(text);
    var syntax = try compiler.syntax.parseWithSourceName(allocator, text, "constraints.ss");
    defer syntax.deinit(allocator);
    var modules = try compiler.analysis.loadModuleIndex(allocator, testing.io, ".", syntax, .{});
    defer modules.deinit();
    var state = try compiler.analysis.buildDocumentState(allocator, "constraints.ss", ".", &text, &syntax, &modules);
    errdefer state.deinit();
    var graph = (try compiler.analysis.analyzeDocumentStateWithMode(allocator, &state, .evaluation)).?;
    defer graph.deinit();
    try compiler.lowering.evaluateDocument(&state, &graph, .{ .io = testing.io });
    return state;
}

fn countExplicit(state: *const core.DocumentState) usize {
    var count: usize = 0;
    for (state.constraints.active.items) |rule| {
        if (!rule.default_alignment) count += 1;
    }
    return count;
}

fn hasDiagnostic(state: *const core.DocumentState, code: []const u8) bool {
    for (state.diagnostics.entries.items) |diagnostic| {
        if (std.mem.eql(u8, diagnostic.code(), code)) return true;
    }
    return false;
}

test "constraint values returned or used as statements do not register themselves" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var state = try evaluate(arena.allocator(),
        \\fn relation(a: Object, b: Object) -> Constraints
        \\  return equal(anchor(a, "left"), anchor(b, "right"), 24)
        \\end
        \\page main
        \\  let a = text!("A")
        \\  let b = text!("B")
        \\  relation(a, b)
        \\  let f = relation
        \\  f(a, b)
        \\  (f)(a, b)
        \\  let rules = constraints(relation(a, b))
        \\  (rules)
        \\end
    );
    defer state.deinit();
    try testing.expectEqual(@as(usize, 0), countExplicit(&state));
}

test "constraint registration is explicit and a bundle is reusable" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var state = try evaluate(arena.allocator(),
        \\fn relation(a: Object, b: Object) -> Constraints
        \\  return equal(anchor(a, "left"), anchor(b, "right"), 24)
        \\end
        \\page main
        \\  let a = text!("A")
        \\  let b = text!("B")
        \\  let rules = constraints(relation(a, b))
        \\  constrain!(rules)
        \\  constrain_on!(pagectx(), rules)
        \\  constrain!(constraints())
        \\end
    );
    defer state.deinit();
    try testing.expectEqual(@as(usize, 2), countExplicit(&state));
    for (state.constraints.active.items) |rule| {
        if (rule.default_alignment) continue;
        try testing.expectEqual(@as(f32, 24), rule.offset);
        try testing.expectEqual(state.graph.page_order.items[0], rule.page_id.?);
    }
}

test "constraint statements and explicit page registration have the same registration semantics" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var state = try evaluate(arena.allocator(),
        \\page main
        \\  let item = text!("Item")
        \\  ~ item.left == page.left + 40
        \\  constrain_on!(pagectx(), equal(anchor(item, "left"), page_anchor(pagectx(), "left"), 40))
        \\end
    );
    defer state.deinit();
    var previous: ?core.Constraint = null;
    for (state.constraints.active.items) |rule| {
        if (rule.default_alignment) continue;
        if (previous) |other| {
            try testing.expectEqual(other.target_node, rule.target_node);
            try testing.expectEqual(other.target_anchor, rule.target_anchor);
            try testing.expectEqual(other.source.page, rule.source.page);
            try testing.expectEqual(other.offset, rule.offset);
            try testing.expectEqual(other.scope_depth, rule.scope_depth);
            try testing.expectEqual(other.page_id, rule.page_id);
        }
        previous = rule;
    }
    try testing.expectEqual(@as(usize, 2), countExplicit(&state));
}

test "explicit registration from document context does not require a current page" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var state = try evaluate(arena.allocator(),
        \\document
        \\  let p = first(pages(docctx()))
        \\  let item = new("Item", "body", "text")
        \\  constrain_on!(p, equal(anchor(item, "left"), page_anchor(p, "left"), 40))
        \\  place_on!(p, item)
        \\end
        \\page main
        \\end
    );
    defer state.deinit();
    try testing.expectEqual(@as(usize, 1), countExplicit(&state));
    try testing.expect(!hasDiagnostic(&state, "UnownedLayoutObject"));
    try testing.expect(!hasDiagnostic(&state, "CrossPageConstraint"));
}

test "registration retains its page until object placement is known" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var state = try evaluate(arena.allocator(),
        \\document
        \\  let p = new_page(docctx(), "First")
        \\  let q = new_page(docctx(), "Second")
        \\  let item = new("Item", "body", "text")
        \\  constrain_on!(p, equal(anchor(item, "left"), page_anchor(p, "left"), 40))
        \\  place_on!(q, item)
        \\end
    );
    defer state.deinit();
    try testing.expect(hasDiagnostic(&state, "CrossPageConstraint"));
}

test "constraint construction has no layout write effect but registration does" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var text = try allocator.dupe(u8,
        \\page main
        \\  let item = text!("Item")
        \\  let rules = equal(anchor(item, "left"), page_anchor(pagectx(), "left"), 40)
        \\  constrain!(rules)
        \\end
    );
    defer allocator.free(text);
    var syntax = try compiler.syntax.parseWithSourceName(allocator, text, "effects.ss");
    defer syntax.deinit(allocator);
    var modules = try compiler.analysis.loadModuleIndex(allocator, testing.io, ".", syntax, .{});
    defer modules.deinit();
    var state = try compiler.analysis.buildDocumentState(allocator, "effects.ss", ".", &text, &syntax, &modules);
    defer state.deinit();
    var graph = (try compiler.analysis.analyzeDocumentStateWithMode(allocator, &state, .evaluation)).?;
    defer graph.deinit();
    try testing.expectEqual(@as(usize, 3), graph.units.items.len);
    try testing.expect(!graph.units.items[1].summary.writes_layout_input);
    try testing.expect(graph.units.items[2].summary.writes_layout_input);
    try testing.expect(!graph.units.items[2].summary.places_objects);
}
