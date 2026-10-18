const std = @import("std");
const compiler = @import("compiler");
const allocation_testing = @import("allocation_testing");
const core = compiler.core;
const Type = compiler.language.Type;
const testing = std.testing;

fn document(text: []const u8) !core.DocumentState {
    const allocator = testing.allocator;
    var source = try allocator.dupe(u8, text);
    defer allocator.free(source);
    var syntax = try compiler.syntax.parseWithSourceName(allocator, source, "typed-query-spec.ss");
    defer syntax.deinit(allocator);
    var index = try compiler.analysis.loadModuleIndex(allocator, testing.io, ".", syntax, .{});
    defer index.deinit();
    return compiler.analysis.buildDocumentState(allocator, "typed-query-spec.ss", ".", &source, &syntax, &index);
}

fn analyzeGraph(state: *core.DocumentState) !void {
    var graph = (try compiler.analysis.analyzeDocumentStateWithMode(testing.allocator, state, .evaluation)).?;
    defer graph.deinit();
}

fn checkedGraph(state: *core.DocumentState) !compiler.analysis.ExecutionGraph {
    const graph = compiler.analysis.analyzeDocumentStateWithMode(testing.allocator, state, .evaluation) catch |err| {
        for (state.diagnostics.entries.items) |entry| {
            std.debug.print("{s}\n", .{entry.code()});
            if (entry.data == .user_report) std.debug.print("{s}\n", .{entry.data.user_report.message});
        }
        return err;
    };
    return graph.?;
}

fn queryWithAllocator(allocator: std.mem.Allocator, state: *core.DocumentState, input: Type) !void {
    var selection = try state.selectTypedPlacements(allocator, .{ .document = state.graph.document_id }, input);
    defer selection.deinit(allocator);
    try testing.expectEqual(@as(usize, 2), selection.ids.items.len);
    std.mem.reverse(core.NodeId, selection.ids.items);
    try state.orderSelection(allocator, &selection);
    try testing.expectEqualStrings("First", state.getNode(selection.ids.items[0]).?.placement.?.value.record.field("title").?.string);
    var pages = core.Selection.init(.page, "reversed pages");
    defer pages.deinit(allocator);
    try pages.ids.appendSlice(allocator, state.graph.page_order.items);
    std.mem.reverse(core.NodeId, pages.ids.items);
    try state.orderSelection(allocator, &pages);
    try testing.expectEqualSlices(core.NodeId, state.graph.page_order.items, pages.ids.items);
}

test "typed queries: a preceding table of contents waits for generated headings and preserves construction order" {
    const source = try std.Io.Dir.cwd().readFileAlloc(testing.io, "tests/fixtures/typed-query/slide.ss", testing.allocator, .limited(64 * 1024));
    defer testing.allocator.free(source);
    var state = try document(source);
    defer state.deinit();
    var graph = try checkedGraph(&state);
    defer graph.deinit();
    try compiler.lowering.evaluateDocument(&state, &graph, .{ .io = testing.io });
    const toc = state.placementRootsOf(state.graph.page_order.items[0])[0];
    const text = state.getNode(state.childrenOf(toc).?[0]).?;
    try testing.expectEqualStrings("First, Second", core.nodeDisplayContent(text));
    const input = Type.recordType("Heading").inModule(0);
    try allocation_testing.checkAllAllocationFailures(testing.allocator, queryWithAllocator, .{ &state, input });
    const body_page = state.graph.page_order.items[1];
    var page_items = try state.selectTypedPlacements(testing.allocator, .{ .page = body_page }, input);
    defer page_items.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), page_items.ids.items.len);
    const wrapper = state.placementRootsOf(body_page)[0];
    var subtree = try state.selectTypedPlacements(testing.allocator, .{ .object = wrapper }, input);
    defer subtree.deinit(testing.allocator);
    try testing.expectEqualSlices(core.NodeId, page_items.ids.items[0..1], subtree.ids.items);
    var excluding_self = try state.selectTypedPlacements(testing.allocator, .{ .object = subtree.ids.items[0] }, input);
    defer excluding_self.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), excluding_self.ids.items.len);
    try allocation_testing.checkAllAllocationFailures(testing.allocator, childQueriesWithAllocator, .{ &state, wrapper });
    var other_module = try state.selectTypedPlacements(testing.allocator, .{ .document = state.graph.document_id }, Type.recordType("Heading").inModule(1));
    defer other_module.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), other_module.ids.items.len);
}

test "typed queries: exact generic input types and selection algebra keep typed results" {
    var state = try document(
        \\import std:text/content as native
        \\type Label<T> { value: T }
        \\fn display<T>(self: Placed<Label<T>>) -> native::Text
        \\  return native::Text { content = "Label" }
        \\end
        \\fn/! label<T>(value: T) -> Label<T> = Label<T> { value = value }
        \\fn selection_union(left: Number, right: Number) -> Number = 99
        \\fn difference<T>(left: Selection<Placed<T>>, right: Selection<Placed<T>>) -> Selection<Placed<T>> = left - right
        \\page main
        \\  let sub = 7
        \\  let a = label!(1)
        \\  let b = label!("Second")
        \\  let numbers: Selection<Placed<Label<Number>>> = select<Label<Number>>(pagectx())
        \\  let words = select<Label<String>>(pagectx())
        \\  let mixed: Selection<Placement> = words | numbers
        \\  let remaining: Selection<Placed<Label<Number>>> = numbers - words
        \\  let common: Selection<Placed<Label<Number>>> = mixed & numbers
        \\  let first_item: Placement = first(mixed)
        \\  ~ first_item.left == page.left + 12
        \\  let empty = difference(numbers, numbers)
        \\  let unique = numbers | numbers
        \\  let result = str(selection_count(mixed)) ++ ":" ++ str(selection_count(remaining)) ++ ":" ++ str(selection_count(common)) ++ ":" ++ str(selection_count(empty)) ++ ":" ++ str(selection_count(unique)) ++ ":" ++ str(5 - 2) ++ ":" ++ str(selection_union(1, 2))
        \\  place_on!(pagectx(), native::Text { content = result })
        \\end
    );
    defer state.deinit();
    var graph = try checkedGraph(&state);
    defer graph.deinit();
    try compiler.lowering.evaluateDocument(&state, &graph, .{ .io = testing.io });
    var number_type = try Type.recordType("Label").inModule(0).withArguments(testing.allocator, &.{Type.number});
    defer number_type.deinit(testing.allocator);
    var string_type = try Type.recordType("Label").inModule(0).withArguments(testing.allocator, &.{Type.string});
    defer string_type.deinit(testing.allocator);
    const page = state.graph.page_order.items[0];
    const roots = state.placementRootsOf(page);
    for ([_]Type{ number_type, string_type }, roots[0..2]) |ty, root| {
        var selection = try state.selectTypedPlacements(testing.allocator, .{ .page = page }, ty);
        defer selection.deinit(testing.allocator);
        try testing.expectEqualSlices(core.NodeId, &.{root}, selection.ids.items);
    }
    try testing.expectEqualStrings("2:1:1:0:1:3:99", core.nodeDisplayContent(state.getNode(roots[2]).?));
    var pages = try core.prepared.prepare(testing.allocator, &state);
    defer pages.deinit(testing.allocator);
    var layout = try core.layout.solveDocument(&state, null, .{ .jobs = 1 });
    defer layout.deinit(testing.allocator);
    try testing.expectApproxEqAbs(@as(f32, 12), layout.nodeFrame(roots[0]).?.x, core.layout.graph.ConstraintTolerance);
}

test "typed queries: querying the collection produced by the same display is a dependency cycle" {
    var state = try document(
        \\import std:text/content as native
        \\type Summary {}
        \\fn display(self: Placed<Summary>) -> native::Text
        \\  let items = select<native::Text>(self.document)
        \\  return native::Text { content = str(selection_count(items)) }
        \\end
        \\page main
        \\  place_on!(pagectx(), Summary {})
        \\end
    );
    defer state.deinit();
    try testing.expectError(error.ExecutionDependencyCycle, analyzeGraph(&state));
    try testing.expect(state.diagnostics.entries.items.len != 0);
    try testing.expectEqual(@as(usize, 0), state.placementRootsOf(state.graph.page_order.items[0]).len);
}

test "typed queries: shared display helpers retain each input subtree without depending on their own output" {
    var state = try document(
        \\import std:text/content as native
        \\type Label { title: String }
        \\type Reader { target: Placement }
        \\fn/! label(title: String) -> Label = Label { title = title }
        \\fn display(self: Placed<Label>) -> native::Text
        \\  return native::Text { content = self.value.title }
        \\end
        \\fn texts(scope: Placement) -> Selection<Placed<native::Text>> = select<native::Text>(scope)
        \\fn display(self: Placed<Reader>) -> native::Text
        \\  let selected = texts(self.value.target)
        \\  return native::Text { content = join(selected, ",", (t: Placed<native::Text>) |-> t.value.content) }
        \\end
        \\page main
        \\  let first_target = label!("First")
        \\  let second_target = label!("Second")
        \\  place_on!(pagectx(), Reader { target = first_target })
        \\  place_on!(pagectx(), Reader { target = second_target })
        \\end
    );
    defer state.deinit();
    var graph = try checkedGraph(&state);
    defer graph.deinit();
    try compiler.lowering.evaluateDocument(&state, &graph, .{ .io = testing.io });
    const roots = state.placementRootsOf(state.graph.page_order.items[0]);
    try testing.expectEqual(@as(usize, 4), roots.len);
    for (roots[2..], [_][]const u8{ "First", "Second" }) |root, expected| {
        const reader_text = state.getNode(state.childrenOf(root).?[0]).?;
        try testing.expectEqualStrings(expected, core.nodeDisplayContent(reader_text));
    }
}

test "typed queries: iterating a completed collection cannot add matching placements" {
    var state = try document(
        \\import std:text/content as native
        \\type Label { title: String }
        \\fn display(self: Placed<Label>) -> native::Text
        \\  return native::Text { content = self.value.title }
        \\end
        \\fn/! label(title: String) -> Label = Label { title = title }
        \\page main
        \\  label!("Initial")
        \\  foreach(select<Label>(pagectx()), (item: Placed<Label>) |-> label!(item.value.title))
        \\end
    );
    defer state.deinit();
    try testing.expectError(error.InvalidSelectionMutation, analyzeGraph(&state));
}

test "typed queries: invalid types scopes and arities fail before evaluation" {
    for ([_]struct { expression: []const u8, code: []const u8 }{
        .{ .expression = "select<Number>(document)", .code = "InvalidSelectionType" },
        .{ .expression = "select<Heading>(Heading { title = \"Input\" })", .code = "InvalidSelectionScope" },
        .{ .expression = "select<Heading>(document, \"children\")", .code = "InvalidArity" },
        .{ .expression = "select<Heading, Heading>(document)", .code = "InvalidTypeArity" },
        .{ .expression = "select(document)", .code = "MissingTypeArguments" },
    }) |case| {
        const source = try std.fmt.allocPrint(testing.allocator, "type Heading {{ title: String }}\npage main\n  let document = docctx()\n  let items = {s}\nend\n", .{case.expression});
        defer testing.allocator.free(source);
        var state = try document(source);
        defer state.deinit();
        if (analyzeGraph(&state)) |_| return error.ExpectedInvalidQuery else |_| {}
        var found = false;
        for (state.diagnostics.entries.items) |entry| {
            if (std.mem.eql(u8, entry.code(), case.code)) found = true;
        }
        if (!found) std.debug.print("Expected diagnostic {s} for {s}\n", .{ case.code, case.expression });
        try testing.expect(found);
    }
}

test "typed queries: selection operators reject scalar operands before evaluation" {
    for ([_][]const u8{ "3 | 4", "3 & 4", "select<Heading>(docctx()) | 4", "select<Heading>(docctx()) - 4", "4 - select<Heading>(docctx())" }) |expression| {
        const source = try std.fmt.allocPrint(testing.allocator, "type Heading {{ title: String }}\npage Main\nlet result = {s}\nend\n", .{expression});
        defer testing.allocator.free(source);
        var state = try document(source);
        defer state.deinit();
        if (analyzeGraph(&state)) |_| return error.ExpectedInvalidOperator else |_| {}
        var found = false;
        for (state.diagnostics.entries.items) |entry| {
            if (std.mem.eql(u8, entry.code(), "TypeMismatch")) found = true;
        }
        try testing.expect(found);
        for (state.graph.page_order.items) |page| try testing.expectEqual(@as(usize, 0), state.placementRootsOf(page).len);
    }
}

fn childQueriesWithAllocator(allocator: std.mem.Allocator, state: *core.DocumentState, root: core.NodeId) !void {
    var direct = try state.select(allocator, .{ .object = root }, core.Query.children());
    defer direct.deinit(allocator);
    try testing.expectEqual(@as(usize, 1), direct.selection.ids.items.len);
    var all = try state.select(allocator, .{ .object = root }, core.Query.descendants());
    defer all.deinit(allocator);
    try testing.expectEqual(@as(usize, 2), all.selection.ids.items.len);
    try testing.expectEqual(direct.selection.ids.items[0], all.selection.ids.items[0]);
    try testing.expectEqual(state.childrenOf(direct.selection.ids.items[0]).?[0], all.selection.ids.items[1]);
    var singleton = try state.select(allocator, .{ .object = root }, core.Query.selfPlacement());
    defer singleton.deinit(allocator);
    try testing.expectEqualSlices(core.NodeId, &.{root}, singleton.selection.ids.items);
    var leaf = try state.select(allocator, .{ .object = all.selection.ids.items[1] }, core.Query.children());
    defer leaf.deinit(allocator);
    try testing.expectEqual(@as(usize, 0), leaf.selection.ids.items.len);
}

test "typed queries: previous pages are optional and page filtering keeps construction order" {
    var state = try document(
        \\import std:text/content as native
        \\import std:query as query
        \\type PageLabel {}
        \\fn display(self: Placed<PageLabel>) -> native::Text
        \\  let previous: Page? = query::previous_page(self.page)
        \\  let body: Selection<Page> = query::filter(pages(self.document), (p: Page) |-> page_index(p) > 1)
        \\  let labels = join(body, ",", (p: Page) |-> str(page_index(p)))
        \\  return native::Text { content = str(page_index(previous ?? self.page)) ++ ":" ++ labels }
        \\end
        \\page cover
        \\  place_on!(pagectx(), PageLabel {})
        \\end
        \\page first
        \\  place_on!(pagectx(), PageLabel {})
        \\end
        \\page second
        \\  place_on!(pagectx(), PageLabel {})
        \\end
    );
    defer state.deinit();
    var graph = try checkedGraph(&state);
    defer graph.deinit();
    try compiler.lowering.evaluateDocument(&state, &graph, .{ .io = testing.io });
    for (state.graph.page_order.items, [_][]const u8{ "1:2,3", "1:2,3", "2:2,3" }, 0..) |page, expected, index| {
        var previous = try state.select(testing.allocator, .{ .page = page }, core.Query.previousPage());
        defer previous.deinit(testing.allocator);
        if (index == 0) try testing.expect(previous == .none) else try testing.expectEqual(state.graph.page_order.items[index - 1], previous.page);
        const root = state.placementRootsOf(page)[0];
        try testing.expectEqualStrings(expected, core.nodeDisplayContent(state.getNode(state.childrenOf(root).?[0]).?));
    }
}

test "typed queries: filtering evaluates each predicate once and leaves the input selection unchanged" {
    var state = try document(
        \\import std:text/content as native
        \\type Heading { title: String level: Number }
        \\fn/! heading(title: String, level: Number) -> Heading = Heading { title = title level = level }
        \\fn display(self: Placed<Heading>) -> native::Text = native::Text { content = self.value.title }
        \\fn visit!(item: Placed<Heading>) -> Bool
        \\  place_on!(pagectx(), native::Text { content = "Visit " ++ item.value.title })
        \\  return item.value.level == 1
        \\end
        \\page main
        \\  heading!("First", 1)
        \\  heading!("Second", 2)
        \\  heading!("Third", 1)
        \\  let input = select<Heading>(pagectx())
        \\  let selected: Selection<Placed<Heading>> = filter(input, (h: Placed<Heading>) |-> visit!(h))
        \\  let empty = filter(input, (h: Placed<Heading>) |-> false)
        \\  let still_empty = filter(empty, (h: Placed<Heading>) |-> visit!(h))
        \\  let titles = join(selected, ",", (h: Placed<Heading>) |-> h.value.title)
        \\  let result = titles ++ ":" ++ str(selection_count(input)) ++ ":" ++ str(selection_count(still_empty))
        \\  place_on!(pagectx(), native::Text { content = result })
        \\end
    );
    defer state.deinit();
    var graph = try checkedGraph(&state);
    defer graph.deinit();
    try compiler.lowering.evaluateDocument(&state, &graph, .{ .io = testing.io });
    const roots = state.placementRootsOf(state.graph.page_order.items[0]);
    try testing.expectEqual(@as(usize, 7), roots.len);
    for (roots[3..], [_][]const u8{ "Visit First", "Visit Second", "Visit Third", "First,Third:3:0" }) |root, expected| {
        try testing.expectEqualStrings(expected, core.nodeDisplayContent(state.getNode(root).?));
    }
}

test "typed queries: filtering preserves subtree facts for predicates and returned selections" {
    var state = try document(
        \\import std:text/content as native
        \\type Label { title: String }
        \\type Reader { target: Placement }
        \\fn/! label(title: String) -> Label = Label { title = title }
        \\fn display(self: Placed<Label>) -> native::Text = native::Text { content = self.value.title }
        \\fn display(self: Placed<Reader>) -> native::Text
        \\  let chosen: Selection<Placement> = filter(selection(self.value.target), (p: Placement) |-> selection_count(children(p)) > 0)
        \\  let leaves = select<native::Text>(first(chosen))
        \\  return native::Text { content = join(leaves, ",", (t: Placed<native::Text>) |-> t.value.content) }
        \\end
        \\page main
        \\  let first_target = label!("First")
        \\  let second_target = label!("Second")
        \\  place_on!(pagectx(), Reader { target = first_target })
        \\  place_on!(pagectx(), Reader { target = second_target })
        \\end
    );
    defer state.deinit();
    var graph = try checkedGraph(&state);
    defer graph.deinit();
    try compiler.lowering.evaluateDocument(&state, &graph, .{ .io = testing.io });
    const roots = state.placementRootsOf(state.graph.page_order.items[0]);
    for (roots[2..], [_][]const u8{ "First", "Second" }) |root, expected| {
        try testing.expectEqualStrings(expected, core.nodeDisplayContent(state.getNode(state.childrenOf(root).?[0]).?));
    }
}

test "typed queries: predicates cannot grow their selected collection or mutate from displays" {
    const definitions =
        \\import std:text/content as native
        \\type Heading { title: String }
        \\type Summary {}
        \\fn/! heading(title: String) -> Heading = Heading { title = title }
        \\fn display(self: Placed<Heading>) -> native::Text = native::Text { content = self.value.title }
        \\fn mutate!(item: Placed<Heading>) -> Bool
        \\  heading!(item.value.title)
        \\  return true
        \\end
        \\
    ;
    for ([_]bool{ false, true }) |in_display| {
        const body = if (in_display)
            \\fn display(self: Placed<Summary>) -> native::Text
            \\  let items = filter(select<Heading>(self.document), (h: Placed<Heading>) |-> mutate!(h))
            \\  return native::Text { content = str(selection_count(items)) }
            \\end
            \\page main
            \\  heading!("Initial")
            \\  place_on!(pagectx(), Summary {})
            \\end
        else
            \\page main
            \\  heading!("Initial")
            \\  let items = filter(select<Heading>(pagectx()), (h: Placed<Heading>) |-> mutate!(h))
            \\end
        ;
        const source = try std.mem.concat(testing.allocator, u8, &.{ definitions, body });
        defer testing.allocator.free(source);
        var state = try document(source);
        defer state.deinit();
        try testing.expectError(if (in_display) error.ImpureDisplayFunction else error.InvalidSelectionMutation, analyzeGraph(&state));
        for (state.graph.page_order.items) |page| try testing.expectEqual(@as(usize, 0), state.placementRootsOf(page).len);
    }
}

test "typed queries: filtering rejects invalid predicate types before evaluation" {
    for ([_][]const u8{ "filter", "selection_filter" }) |operation| {
        for ([_][]const u8{ "(p: Page) |-> 1", "() |-> true", "(n: Number) |-> true", "nothing" }) |predicate| {
            const source = try std.fmt.allocPrint(testing.allocator,
                \\fn nothing(page_value: Page) -> Void
                \\end
                \\page main
                \\  let selected = {s}(pages(docctx()), {s})
                \\end
            , .{ operation, predicate });
            defer testing.allocator.free(source);
            var state = try document(source);
            defer state.deinit();
            if (analyzeGraph(&state)) |_| return error.ExpectedInvalidPredicate else |_| {}
            try testing.expect(state.diagnostics.entries.items.len != 0);
        }
    }
}

test "typed queries: predicate failure releases its temporary selection" {
    var state = try document(
        \\type Missing {}
        \\fn fail(page_value: Page) -> Bool
        \\  if page_index(page_value) > 1
        \\    let item = first(select<Missing>(page_value))
        \\  end
        \\  return true
        \\end
        \\page main
        \\  filter(pages(docctx()), fail)
        \\end
        \\page later
        \\end
    );
    defer state.deinit();
    var graph = try checkedGraph(&state);
    defer graph.deinit();
    try testing.expectError(error.EmptySelection, compiler.lowering.evaluateDocument(&state, &graph, .{ .io = testing.io }));
}

test "typed queries: child helpers wait for displays and preserve each captured subtree" {
    var state = try document(
        \\import std:text/content as native
        \\type Heading { title: String }
        \\type Wrapped { content: Heading }
        \\type Reader { target: Placement }
        \\fn/! wrapped(title: String) -> Wrapped = Wrapped { content = Heading { title = title } }
        \\fn display(self: Placed<Heading>) -> native::Text = native::Text { content = self.value.title }
        \\fn display(self: Placed<Wrapped>) -> Heading = self.value.content
        \\fn child_count(target: Placement) -> Number = selection_count(children(target))
        \\fn display(self: Placed<Reader>) -> native::Text
        \\  let same: Placed<Reader> = first(selection(self))
        \\  let target = same.value.target
        \\  let read = () |-> child_count(target)
        \\  let direct: Selection<Placement> = children(target)
        \\  let all: Selection<Placement> = descendants(target)
        \\  let result = str(read()) ++ ":" ++ str(selection_count(all)) ++ ":" ++ str(selection_count(selection(self)))
        \\  return native::Text { content = result }
        \\end
        \\page main
        \\  let first_target = wrapped!("First")
        \\  let second_target = place_on!(pagectx(), native::Text { content = "Second" })
        \\  place_on!(pagectx(), Reader { target = first_target })
        \\  place_on!(pagectx(), Reader { target = second_target })
        \\  let child = first(children(first_target))
        \\  let leaf = first(descendants(child))
        \\  ~ leaf.left == page.left + 24
        \\end
    );
    defer state.deinit();
    var graph = try checkedGraph(&state);
    defer graph.deinit();
    try compiler.lowering.evaluateDocument(&state, &graph, .{ .io = testing.io });
    const roots = state.placementRootsOf(state.graph.page_order.items[0]);
    try testing.expectEqual(@as(usize, 4), roots.len);
    for (roots[2..], [_][]const u8{ "1:2:1", "0:0:1" }) |root, expected| {
        try testing.expectEqualStrings(expected, core.nodeDisplayContent(state.getNode(state.childrenOf(root).?[0]).?));
    }
    var pages = try core.prepared.prepare(testing.allocator, &state);
    defer pages.deinit(testing.allocator);
    var layout = try core.layout.solveDocument(&state, null, .{ .jobs = 1 });
    defer layout.deinit(testing.allocator);
    const leaf = state.childrenOf(state.childrenOf(roots[0]).?[0]).?[0];
    try testing.expectApproxEqAbs(@as(f32, 24), layout.nodeFrame(leaf).?.x, core.layout.graph.ConstraintTolerance);
}

test "typed queries: reading one's own children during display rejects a dependency cycle" {
    for ([_][]const u8{ "children", "descendants" }) |query| {
        const source = try std.fmt.allocPrint(testing.allocator,
            \\import std:text/content as native
            \\type Reader {{}}
            \\fn display(self: Placed<Reader>) -> native::Text
            \\  return native::Text {{ content = str(selection_count({s}(self))) }}
            \\end
            \\page main
            \\  place_on!(pagectx(), Reader {{}})
            \\end
        , .{query});
        defer testing.allocator.free(source);
        var state = try document(source);
        defer state.deinit();
        try testing.expectError(error.ExecutionDependencyCycle, analyzeGraph(&state));
        try testing.expectEqual(@as(usize, 0), state.placementRootsOf(state.graph.page_order.items[0]).len);
    }
}

test "typed queries: child and singleton queries require a placement reference" {
    for ([_][]const u8{ "children", "descendants", "selection" }) |query| {
        for ([_][]const u8{ "7", "Heading { title = \"Value\" }", "pagectx()", "text!(\"Legacy\")" }) |input| {
            const source = try std.fmt.allocPrint(testing.allocator,
                \\type Heading {{ title: String }}
                \\page main
                \\  let result = {s}({s})
                \\end
            , .{ query, input });
            defer testing.allocator.free(source);
            var state = try document(source);
            defer state.deinit();
            if (analyzeGraph(&state)) |_| return error.ExpectedInvalidQuery else |_| {}
            try testing.expect(state.diagnostics.entries.items.len != 0);
            for (state.graph.page_order.items) |page| try testing.expectEqual(@as(usize, 0), state.placementRootsOf(page).len);
        }
    }
}

test "typed queries: a child display can count direct siblings but not unfinished descendants" {
    for ([_][]const u8{ "children", "descendants" }) |query| {
        const source = try std.fmt.allocPrint(testing.allocator,
            \\import std:text/content as native
            \\type Parent {{}}
            \\type Child {{ parent: Placement }}
            \\fn display(self: Placed<Parent>) -> Child = Child {{ parent = self }}
            \\fn display(self: Placed<Child>) -> native::Text
            \\  let peers = {s}(self.value.parent)
            \\  return native::Text {{ content = str(selection_count(peers)) }}
            \\end
            \\page main
            \\  place_on!(pagectx(), Parent {{}})
            \\end
        , .{query});
        defer testing.allocator.free(source);
        var state = try document(source);
        defer state.deinit();
        if (std.mem.eql(u8, query, "descendants")) {
            try testing.expectError(error.ExecutionDependencyCycle, analyzeGraph(&state));
            continue;
        }
        var graph = try checkedGraph(&state);
        defer graph.deinit();
        try compiler.lowering.evaluateDocument(&state, &graph, .{ .io = testing.io });
        const parent = state.placementRootsOf(state.graph.page_order.items[0])[0];
        const child = state.childrenOf(parent).?[0];
        try testing.expectEqualStrings("1", core.nodeDisplayContent(state.getNode(state.childrenOf(child).?[0]).?));
    }
}

test "typed queries: shared typed subtree helpers preserve the receiver path and exclude it from results" {
    var state = try document(
        \\import std:text/content as native
        \\type Parent {}
        \\type Child { parent: Placement }
        \\fn display(self: Placed<Parent>) -> Child = Child { parent = self }
        \\fn count_children(target: Placement) -> Number = selection_count(select<Child>(target))
        \\fn display(self: Placed<Child>) -> native::Text
        \\  let peers = count_children(self.value.parent)
        \\  let nested = count_children(self)
        \\  return native::Text { content = str(peers) ++ ":" ++ str(nested) }
        \\end
        \\page main
        \\  place_on!(pagectx(), Parent {})
        \\end
    );
    defer state.deinit();
    var graph = try checkedGraph(&state);
    defer graph.deinit();
    var ancestor_reads: usize = 0;
    var nested_reads: usize = 0;
    const input = Type.recordType("Child").inModule(0);
    for (graph.units.items) |unit| {
        if (unit.kind != .display or unit.kind.display.step != 1) continue;
        for (unit.summary.selection_reads.items) |read| {
            if (read != .objects or read.objects.input_type == null or !Type.eql(input, read.objects.input_type.?)) continue;
            const scope = read.objects.placement;
            try testing.expect(scope.call != null);
            try testing.expect(scope.depth.max == null);
            if (scope.path.len == 0) {
                ancestor_reads += 1;
                try testing.expectEqual(@as(usize, 1), scope.depth.min);
            } else {
                nested_reads += 1;
                try testing.expectEqualSlices(usize, &.{0}, scope.path);
                try testing.expectEqual(@as(usize, 2), scope.depth.min);
            }
        }
    }
    try testing.expectEqual(@as(usize, 1), ancestor_reads);
    try testing.expectEqual(@as(usize, 1), nested_reads);
    try compiler.lowering.evaluateDocument(&state, &graph, .{ .io = testing.io });
    const parent = state.placementRootsOf(state.graph.page_order.items[0])[0];
    const child = state.childrenOf(parent).?[0];
    const text = state.childrenOf(child).?[0];
    try testing.expectEqualStrings("1:0", core.nodeDisplayContent(state.getNode(text).?));
}

test "typed queries: generated groups preserve dependency and document order" {
    var state = try document(
        \\import std:text/content as native
        \\type Heading { title: String }
        \\type Bundle {}
        \\type Toc {}
        \\fn display(self: Placed<Heading>) -> native::Text = native::Text { content = self.value.title }
        \\fn display(self: Placed<Bundle>) -> Group<Heading, Group<Heading, Heading>>
        \\  return group(Heading { title = "First" }, group(Heading { title = "Second" }, Heading { title = "Third" }))
        \\end
        \\fn display(self: Placed<Toc>) -> native::Text
        \\  return native::Text { content = join(select<Heading>(self.document), ", ", (h: Placed<Heading>) |-> h.value.title) }
        \\end
        \\page contents
        \\  place!(Toc {})
        \\end
        \\page body
        \\  let bundle = place!(Bundle {})
        \\  let groups = select<Group<Heading, Group<Heading, Heading>>>(bundle)
        \\  place!(native::Text { content = str(selection_count(groups)) })
        \\end
    );
    defer state.deinit();
    var graph = try checkedGraph(&state);
    defer graph.deinit();
    try compiler.lowering.evaluateDocument(&state, &graph, .{ .io = testing.io });
    const toc = state.placementRootsOf(state.graph.page_order.items[0])[0];
    try testing.expectEqualStrings("First, Second, Third", core.nodeDisplayContent(state.getNode(state.childrenOf(toc).?[0]).?));
    const roots = state.placementRootsOf(state.graph.page_order.items[1]);
    try testing.expectEqualStrings("1", core.nodeDisplayContent(state.getNode(roots[1]).?));
    const outer = state.childrenOf(roots[0]).?[0];
    const children = state.childrenOf(outer).?;
    try testing.expectEqual(@as(usize, 2), children.len);
    try testing.expectEqual(@as(usize, 2), state.childrenOf(children[1]).?.len);
}

test "typed queries: group child captures distinguish dependency summaries" {
    var state = try document(
        \\import std:text/content as native
        \\type Pair {}
        \\type Reader { read: () -> String }
        \\fn display(self: Placed<Pair>) -> Group<native::Text, native::Text>
        \\  return group(native::Text { content = "A" }, native::Text { content = "B" })
        \\end
        \\fn display(self: Placed<Reader>) -> native::Text = native::Text { content = self.value.read() }
        \\fn reader(target: Placement) -> Reader
        \\  return Reader { read = () |-> str(selection_count(select<native::Text>(target))) }
        \\end
        \\fn reuse(value: Group<Reader>) -> Group<Reader> = value
        \\page main
        \\  let leaf = place!(native::Text { content = "Leaf" })
        \\  let pair = place!(Pair {})
        \\  let empty = place!(reuse(group(reader(leaf))))
        \\  let full = place!(reuse(group(reader(pair))))
        \\end
    );
    defer state.deinit();
    var graph = try checkedGraph(&state);
    defer graph.deinit();
    try compiler.lowering.evaluateDocument(&state, &graph, .{ .io = testing.io });
    const roots = state.placementRootsOf(state.graph.page_order.items[0]);
    for (roots[2..], [_][]const u8{ "0", "2" }) |root, expected| {
        const reader = state.childrenOf(root).?[0];
        const text = state.getNode(state.childrenOf(reader).?[0]).?;
        try testing.expectEqualStrings(expected, core.nodeDisplayContent(text));
    }
}
