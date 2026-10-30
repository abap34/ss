const std = @import("std");
const compiler = @import("compiler");
const allocation_testing = @import("allocation_testing");
const core = compiler.core;
const testing = std.testing;

fn document(text: []const u8) !core.DocumentState {
    var source = try testing.allocator.dupe(u8, text);
    defer testing.allocator.free(source);
    var syntax = try compiler.syntax.parseWithSourceName(testing.allocator, source, "staging-spec.ss");
    defer syntax.deinit(testing.allocator);
    var index = try compiler.analysis.loadModuleIndex(testing.allocator, testing.io, ".", syntax, .{});
    defer index.deinit();
    return compiler.analysis.buildDocumentState(testing.allocator, "staging-spec.ss", ".", &source, &syntax, &index);
}

fn evaluate(state: *core.DocumentState) !void {
    var graph = (compiler.analysis.analyzeDocumentStateWithMode(testing.allocator, state, .evaluation) catch |err| {
        for (state.diagnostics.entries.items) |entry| {
            std.debug.print("{s}\n", .{entry.code()});
            if (entry.data == .user_report) std.debug.print("{s}\n", .{entry.data.user_report.message});
        }
        return err;
    }).?;
    defer graph.deinit();
    try compiler.lowering.evaluateDocument(state, &graph, .{ .io = testing.io });
}

fn parseAllocation(allocator: std.mem.Allocator) !void {
    var syntax = try compiler.syntax.parseWithSourceName(allocator,
        \\page Demo
        \\  stages s { first second }
        \\  show s >= s.second
        \\    text!(str(s + s.first))
        \\  end
        \\  let invalid = s()
        \\end
    , "staging-spec.ss");
    defer syntax.deinit(allocator);
    var cloned = try syntax.clone(allocator);
    defer cloned.deinit(allocator);
}

test "staging: page expansion and cloning release allocations on failure" {
    try allocation_testing.checkAllAllocationFailures(testing.allocator, parseAllocation, .{});
}

test "staging: stage variables shadow callable names until rebound" {
    var syntax = try compiler.syntax.parseWithSourceName(testing.allocator,
        \\fn s() -> Number = 99
        \\page Demo
        \\  stages s { first second }
        \\  let invalid = s()
        \\  let s = (value: Number) |-> value
        \\  let valid = s(42)
        \\end
    , "staging-spec.ss");
    defer syntax.deinit(testing.allocator);
    for (syntax.pages.items, 0..) |page, index| {
        const invalid = page.statements.items[0].kind.let_binding.expr;
        try testing.expect(invalid == .apply);
        try testing.expectEqual(@as(f32, @floatFromInt(index)), invalid.apply.callee.number);
        const valid = page.statements.items[2].kind.let_binding.expr;
        try testing.expectEqualStrings("s", valid.call.callee.name);
    }
}

test "staging: arbitrary expressions and lambda shadowing preserve lexical bindings" {
    var state = try document(
        \\fn advance(value: Number) -> Number = value + 1
        \\page Intro
        \\  text! "Before"
        \\end
        \\page Demo
        \\  stages s { first second third }
        \\  let identity = (s: Number) |-> s
        \\  text!(str(identity(42)))
        \\  text!(str(advance(s)))
        \\  show advance(s) >= advance(s.second)
        \\    text! "Reveal"
        \\  end
        \\end
        \\page End
        \\  text! "After"
        \\end
    );
    defer state.deinit();
    try evaluate(&state);
    try testing.expectEqual(@as(usize, 5), state.graph.page_order.items.len);
    for (state.graph.page_order.items[1..4], 0..) |page, index| {
        const roots = state.placementRootsOf(page);
        try testing.expectEqual(@as(usize, 3), roots.len);
        try testing.expectEqualStrings("42", core.nodeDisplayContent(state.getNode(roots[0]).?));
        try testing.expectEqual(index >= 1, state.isDrawn(roots[2]));
    }
}

test "staging: a predicate can query its body and late display descendants" {
    var state = try document(
        \\type Badge { title: String }
        \\fn display(self: Placed<Badge>) -> Group<Text, Text>
        \\  return text(self.value.title) // text("Detail")
        \\end
        \\page Demo
        \\  show selection_count(select<Text>(pagectx())) == 2
        \\    place!(Badge { title = "Title" })
        \\  end
        \\end
    );
    defer state.deinit();
    try evaluate(&state);
    const roots = state.placementRootsOf(state.graph.page_order.items[0]);
    try testing.expectEqual(@as(usize, 1), roots.len);
    try testing.expect(state.isDrawn(roots[0]));
}

test "staging: nested predicates capture function parameters and hide descendants" {
    var state = try document(
        \\fn notes!(enabled: Bool) -> Void
        \\  show enabled
        \\    text! "Outer"
        \\    show true
        \\      text! "Inner"
        \\    end
        \\  end
        \\end
        \\page Demo
        \\  notes!(false)
        \\  notes!(true)
        \\end
    );
    defer state.deinit();
    try evaluate(&state);
    const roots = state.placementRootsOf(state.graph.page_order.items[0]);
    try testing.expectEqual(@as(usize, 4), roots.len);
    for (roots, 0..) |id, index| try testing.expectEqual(index >= 2, state.isDrawn(id));
}

test "staging: false predicates retain query membership and layout constraints" {
    var state = try document(
        \\page Demo
        \\  show false
        \\    let hidden = text! "Hidden"
        \\    ~ hidden.width == 220
        \\    ~ hidden.left == page.left + 30
        \\  end
        \\end
    );
    defer state.deinit();
    try evaluate(&state);
    const roots = state.placementRootsOf(state.graph.page_order.items[0]);
    try testing.expectEqual(@as(usize, 1), roots.len);
    try testing.expect(!state.isDrawn(roots[0]));
    const input_type = state.getNode(roots[0]).?.placement.?.value.record.ty;
    var selection = try state.selectTypedPlacements(testing.allocator, .{ .page = state.graph.page_order.items[0] }, input_type);
    defer selection.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), selection.ids.items.len);
    var layouts = try compiler.lowering.solveDocument(&state, null, .{});
    defer layouts.deinit(testing.allocator);
    try layouts.validate();
    const frame = layouts.nodeFrame(roots[0]).?;
    try testing.expectApproxEqAbs(@as(f32, 220), frame.width, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 30), frame.x, 0.01);
}

test "staging: invalid declarations and unknown stage names point to source" {
    const cases = [_]struct { source: []const u8, expected: anyerror, token: []const u8 }{
        .{ .source = "page Demo\nstages s {}\nend\n", .expected = error.EmptyStages, .token = "stages" },
        .{ .source = "page Demo\nstages s { one one }\nend\n", .expected = error.DuplicateStageName, .token = "one" },
        .{ .source = "page Demo\nstages s { one }\nshow s == s.missing\nend\nend\n", .expected = error.UnknownStage, .token = "missing" },
        .{ .source = "page Demo\ntext! \"First\"\nstages s { one }\nend\n", .expected = error.InvalidStagesLocation, .token = "stages" },
    };
    for (cases) |case| {
        var failure = compiler.syntax.ParseFailure{};
        try testing.expectError(case.expected, compiler.syntax.parseWithSourceNameAndFailure(testing.allocator, case.source, "staging-spec.ss", &failure));
        const span = failure.diagnostic.?.span;
        try testing.expect(std.mem.startsWith(u8, case.source[span.start..], case.token));
    }
}

test "staging: conditions require Bool and reject document mutations" {
    const cases = [_]struct { source: []const u8, code: []const u8 }{
        .{ .source = "page Demo\nshow 1\ntext! \"Body\"\nend\nend\n", .code = "DrawingConditionTypeMismatch" },
        .{ .source = "fn create!() -> Bool\ntext! \"Unexpected\"\nreturn true\nend\npage Demo\nshow create!()\ntext! \"Body\"\nend\nend\n", .code = "DrawingConditionHasEffects" },
        .{ .source = "page Demo\nshow false\ntext!(unknown)\nend\nend\n", .code = "UnknownIdentifier" },
        .{ .source = "fn invalid() -> Number\nshow true\nend\nreturn 1\nend\npage Demo\ntext!(str(invalid()))\nend\n", .code = "PlacementEffect" },
    };
    for (cases) |case| {
        var state = try document(case.source);
        defer state.deinit();
        if (compiler.analysis.analyzeDocumentStateWithMode(testing.allocator, &state, .evaluation)) |maybe_graph| {
            var graph = maybe_graph orelse return error.ExpectedDiagnostic;
            graph.deinit();
            return error.ExpectedDiagnostic;
        } else |_| {}
        var found = false;
        for (state.diagnostics.entries.items) |entry| if (std.mem.eql(u8, entry.code(), case.code)) {
            found = true;
        };
        if (!found) for (state.diagnostics.entries.items) |entry| std.debug.print("Expected {s}, got {s}\n", .{ case.code, entry.code() });
        try testing.expect(found);
    }
}

test "staging: default arguments, local computations, and return use ordinary function semantics" {
    var state = try document(
        \\fn enough(value: Number, threshold: Number = 1) -> Bool
        \\  let next = value + 1
        \\  return next > threshold
        \\end
        \\fn details!(enabled: Bool = false) -> Number
        \\  show enabled
        \\    text! "Detail"
        \\    return 7
        \\  end
        \\end
        \\page Demo
        \\  stages s { first second }
        \\  show enough(s)
        \\    text! "Computed"
        \\  end
        \\  text!(str(details!()))
        \\end
    );
    defer state.deinit();
    try evaluate(&state);
    for (state.graph.page_order.items, 0..) |page, index| {
        const roots = state.placementRootsOf(page);
        try testing.expectEqual(@as(usize, 3), roots.len);
        try testing.expectEqual(index == 1, state.isDrawn(roots[0]));
        try testing.expect(!state.isDrawn(roots[1]));
        try testing.expect(state.isDrawn(roots[2]));
        try testing.expectEqualStrings("7", core.nodeDisplayContent(state.getNode(roots[2]).?));
    }
}

test "staging: a hidden adopted group suppresses existing children" {
    var state = try document(
        \\page Demo
        \\  let first = text! "First"
        \\  let second = text! "Second"
        \\  show false
        \\    group!(first, second)
        \\  end
        \\end
    );
    defer state.deinit();
    try evaluate(&state);
    const roots = state.placementRootsOf(state.graph.page_order.items[0]);
    try testing.expectEqual(@as(usize, 3), roots.len);
    for (roots) |id| try testing.expect(!state.isDrawn(id));
}

test "staging: hidden custom display children remain hidden after expansion" {
    var state = try document(
        \\type Badge { title: String }
        \\fn display(self: Placed<Badge>) -> Group<Text, Text>
        \\  return text(self.value.title) // text("Detail")
        \\end
        \\page Demo
        \\  show false
        \\    place!(Badge { title = "Title" })
        \\  end
        \\end
    );
    defer state.deinit();
    try evaluate(&state);
    var objects: usize = 0;
    for (state.graph.nodes.items) |node| {
        if (node.kind != .object) continue;
        objects += 1;
        try testing.expect(!state.isDrawn(node.id));
    }
    try testing.expectEqual(@as(usize, 4), objects);
}

fn evaluateAllocation(allocator: std.mem.Allocator) !void {
    var source = try allocator.dupe(u8,
        \\page Demo
        \\  stages s { first second }
        \\  let enabled = s == s.second
        \\  show enabled
        \\    show true
        \\      let local = 1
        \\    end
        \\  end
        \\end
    );
    defer allocator.free(source);
    var syntax = try compiler.syntax.parseWithSourceName(allocator, source, "staging-spec.ss");
    defer syntax.deinit(allocator);
    var index = compiler.analysis.ModuleIndex{
        .module_graph = .{ .allocator = allocator, .modules = .empty, .module_order = .empty, .project_implicit_import_ids = .empty, .project_import_ids = .empty },
        .constants = core.ConstMap.init(allocator),
        .functions = core.FunctionMap.init(allocator),
    };
    defer index.deinit();
    var state = try compiler.analysis.buildDocumentState(allocator, "staging-spec.ss", ".", &source, &syntax, &index);
    defer state.deinit();
    var graph = (try compiler.analysis.analyzeDocumentStateWithMode(allocator, &state, .evaluation)).?;
    defer graph.deinit();
    try compiler.lowering.evaluateDocument(&state, &graph, .{ .io = testing.io });
}

test "staging: deferred environments and graph summaries clean up after allocation failure" {
    try allocation_testing.checkAllAllocationFailures(testing.allocator, evaluateAllocation, .{});
}

test "staging: generated labels do not change source page name uniqueness" {
    var state = try document(
        \\page Demo
        \\  stages s { first second }
        \\  text! "Staged"
        \\end
        \\page "Demo / first"
        \\  text! "Ordinary"
        \\end
    );
    defer state.deinit();
    try evaluate(&state);
    try testing.expectEqual(@as(usize, 3), state.graph.page_order.items.len);
    var duplicate = try document(
        \\page Demo
        \\  stages s { first }
        \\end
        \\page Demo
        \\  stages t { second }
        \\end
    );
    defer duplicate.deinit();
    try testing.expectError(error.DuplicatePage, compiler.analysis.analyzeDocumentStateWithMode(testing.allocator, &duplicate, .evaluation));
}
