const std = @import("std");
const compiler = @import("compiler");
const core = compiler.core;
const json = @import("utils").json;
const testing = std.testing;

fn evaluate(text: []const u8) !core.DocumentState {
    const allocator = testing.allocator;
    var source = try allocator.dupe(u8, text);
    defer allocator.free(source);
    var syntax = try compiler.syntax.parseWithSourceName(allocator, source, "dump-spec.ss");
    defer syntax.deinit(allocator);
    var index = try compiler.analysis.loadModuleIndex(allocator, testing.io, ".", syntax, .{});
    defer index.deinit();
    var state = try compiler.analysis.buildDocumentState(allocator, "dump-spec.ss", ".", &source, &syntax, &index);
    errdefer state.deinit();
    errdefer for (state.diagnostics.entries.items) |diagnostic| {
        std.debug.print("{s}", .{diagnostic.code()});
        if (diagnostic.data == .user_report) std.debug.print(": {s}", .{diagnostic.data.user_report.message});
        std.debug.print("\n", .{});
    };
    var graph = (try compiler.analysis.analyzeDocumentStateWithMode(allocator, &state, .evaluation)).?;
    defer graph.deinit();
    try compiler.lowering.evaluateDocument(&state, &graph, .{ .io = testing.io });
    return state;
}

fn field(value: json.Value, key: []const u8) !json.Value {
    if (value != .object) return error.ExpectedObject;
    return value.object.get(key) orelse error.MissingField;
}

fn inputField(input: json.Value, name: []const u8) !json.Value {
    for ((try field(input, "fields")).array.items) |entry| {
        if (std.mem.eql(u8, (try field(entry, "name")).string, name)) return field(entry, "value");
    }
    return error.MissingInputField;
}

fn nodeById(root: json.Value, id: core.NodeId) !json.Value {
    for ((try field(root, "nodes")).array.items) |node| {
        if ((try field(node, "id")).integer == id) return node;
    }
    return error.MissingNode;
}

test "dump preserves generic inputs and distinguishes repeated placements from display children" {
    var state = try evaluate(
        \\import std:text/content as native
        \\type Heading { title: String }
        \\type Wrapped<T> { content: T label: String? = none enabled: Bool = true }
        \\fn display(self: Placed<Heading>) -> native::Text
        \\  return native::Text { content = self.value.title }
        \\end
        \\fn display<T>(self: Placed<Wrapped<T>>) -> T = self.value.content
        \\const shared: Wrapped<Heading> = Wrapped<Heading> { content = Heading { title = "**First**" } }
        \\page first
        \\  let a = place!(shared)
        \\  let b = place!(shared)
        \\  let empty = place!(native::Text { content = "" })
        \\end
        \\page second
        \\  let c = place!(shared)
        \\end
    );
    defer state.deinit();
    var layouts = try core.layout.solveDocument(&state, null, .{ .jobs = 1 });
    defer layouts.deinit(testing.allocator);
    const text = try compiler.dump.toOwnedString(testing.allocator, &state, &layouts);
    defer testing.allocator.free(text);
    var parsed = try json.parseValue(testing.allocator, text, .{});
    defer parsed.deinit();
    const first_page = state.graph.page_order.items[0];
    const second_page = state.graph.page_order.items[1];
    const roots = state.placementRootsOf(first_page);
    try testing.expectEqual(@as(usize, 3), roots.len);
    try testing.expect(roots[0] != roots[1]);
    const repeated = state.placementRootsOf(second_page)[0];
    for ([_]core.NodeId{ roots[0], roots[1], repeated }) |id| {
        const page = if (id == repeated) second_page else first_page;
        const parent = try field(try nodeById(parsed.value, id), "placement");
        try testing.expectEqual(page, (try field(parent, "page")).integer);
        try testing.expectEqual(page, (try field(parent, "parent")).integer);
        try testing.expectEqual(state.graph.document_id, (try field(parent, "document")).integer);
        const input = try field(parent, "input");
        const ty = try field(input, "type");
        try testing.expectEqualStrings("Wrapped", (try field(ty, "name")).string);
        try testing.expectEqual(@as(i64, 0), (try field(ty, "module")).integer);
        const argument = (try field(ty, "arguments")).array.items[0];
        try testing.expectEqualStrings("Heading", (try field(argument, "name")).string);
        try testing.expectEqualStrings("none", (try field(try inputField(input, "label"), "kind")).string);
        try testing.expect((try field(try inputField(input, "enabled"), "value")).bool);
        const content = try inputField(input, "content");
        try testing.expectEqualStrings("**First**", (try field(try inputField(content, "title"), "value")).string);
        const display = try field(parent, "display");
        try testing.expectEqualStrings("expanded", (try field(display, "state")).string);
        try testing.expect((try field(try field(display, "target"), "instance")) == .integer);
        const children = (try field(parent, "children")).array.items;
        try testing.expectEqual(@as(usize, 1), children.len);
        const child = try field(try nodeById(parsed.value, @intCast(children[0].integer)), "placement");
        try testing.expectEqual(id, (try field(child, "parent")).integer);
        const leaf_id: core.NodeId = @intCast((try field(child, "children")).array.items[0].integer);
        const leaf = try nodeById(parsed.value, leaf_id);
        try testing.expectEqualStrings("**First**", (try field(leaf, "content")).string);
        const leaf_placement = try field(leaf, "placement");
        try testing.expectEqual(page, (try field(leaf_placement, "page")).integer);
        try testing.expectEqualStrings("native", (try field(try field(leaf_placement, "display"), "state")).string);
        try testing.expectEqual(@as(usize, 0), (try field(leaf_placement, "children")).array.items.len);
    }
    const empty = try nodeById(parsed.value, roots[2]);
    try testing.expectEqualStrings("", (try field(empty, "content")).string);
    try testing.expect((try field(empty, "blocks")) == .array);
    const first_order = try field(try field(try nodeById(parsed.value, roots[0]), "placement"), "order");
    const next_order = try field(try field(try nodeById(parsed.value, roots[1]), "placement"), "order");
    try testing.expect((try field(first_order, "source_order")).integer < (try field(next_order, "source_order")).integer);
}

test "dump preserves callback and document references without evaluating them again" {
    var state = try evaluate(
        \\import std:text/content as native
        \\type Caption { title: String }
        \\type Reference<T> {
        \\  target: Placed<T>
        \\  candidates: Selection<Placed<T>>
        \\  page: Page
        \\  document: Document
        \\  format: () -> String
        \\}
        \\fn display(self: Placed<Caption>) -> native::Text
        \\  return native::Text { content = self.value.title }
        \\end
        \\fn display<T>(self: Placed<Reference<T>>) -> native::Text
        \\  return native::Text { content = self.value.format() }
        \\end
        \\page first
        \\  let target = place!(Caption { title = "Target" })
        \\  let reference = place!(Reference<Caption> {
        \\    target = target
        \\    candidates = selection(target)
        \\    page = pagectx()
        \\    document = docctx()
        \\    format = () |-> target.value.title
        \\  })
        \\end
    );
    defer state.deinit();
    const layouts = core.layout.Document{};
    const text = try compiler.dump.toOwnedString(testing.allocator, &state, &layouts);
    defer testing.allocator.free(text);
    var parsed = try json.parseValue(testing.allocator, text, .{});
    defer parsed.deinit();
    const page = state.graph.page_order.items[0];
    const roots = state.placementRootsOf(page);
    const placement = try field(try nodeById(parsed.value, roots[1]), "placement");
    const input = try field(placement, "input");
    try testing.expectEqual(roots[0], (try field(try inputField(input, "target"), "id")).integer);
    try testing.expectEqual(page, (try field(try inputField(input, "page"), "id")).integer);
    try testing.expectEqual(state.graph.document_id, (try field(try inputField(input, "document"), "id")).integer);
    const ids = (try field(try inputField(input, "candidates"), "ids")).array.items;
    try testing.expectEqual(@as(usize, 1), ids.len);
    try testing.expectEqual(roots[0], ids[0].integer);
    const function = try inputField(input, "format");
    try testing.expectEqualStrings("function", (try field(function, "kind")).string);
    try testing.expect((try field(function, "closure")) == .integer);
}
