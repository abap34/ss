const std = @import("std");
const compiler = @import("compiler");
const core = compiler.core;
const testing = std.testing;

const source =
    \\record Style {
    \\  amount: Number = 12
    \\}
    \\type Base = object {
    \\  style: Style = Style {}
    \\}
    \\type Card = object {
    \\  base = Base
    \\  roles = ["card"]
    \\}
    \\page main
    \\  let card = new("", "card", "text")
    \\end
;
const card = core.Node{ .id = 0, .kind = .object, .name = "card", .role = "card" };

fn documentFromSource(text: []const u8) !core.DocumentState {
    const allocator = testing.allocator;
    var owned_source = try allocator.dupe(u8, text);
    defer allocator.free(owned_source);
    var syntax = try compiler.syntax.parseWithSourceName(allocator, owned_source, "declarations-spec.ss");
    defer syntax.deinit(allocator);
    var index = compiler.analysis.ModuleIndex{
        .module_graph = .{
            .allocator = allocator,
            .modules = .empty,
            .module_order = .empty,
            .project_implicit_import_ids = .empty,
            .project_import_ids = .empty,
        },
        .constants = core.ConstMap.init(allocator),
        .functions = core.FunctionMap.init(allocator),
    };
    defer index.deinit();
    return compiler.analysis.buildDocumentState(allocator, "declarations-spec.ss", ".", &owned_source, &syntax, &index);
}

fn evaluatedDocument() !struct { state: core.DocumentState, graph: compiler.analysis.ExecutionGraph } {
    var state = try documentFromSource(source);
    errdefer state.deinit();
    var graph = (try compiler.analysis.analyzeDocumentStateWithMode(testing.allocator, &state, .evaluation)).?;
    errdefer graph.deinit();
    try compiler.lowering.evaluateDocument(&state, &graph, .{ .io = testing.io });
    return .{ .state = state, .graph = graph };
}

test "declaration index: document moves and graph disposal preserve shared declarations" {
    var evaluated = try evaluatedDocument();
    var state = evaluated.state;
    evaluated.state = undefined;
    defer state.deinit();
    try testing.expect(evaluated.graph.declarations == state.declaration_index);
    evaluated.graph.deinit();

    const sema = compiler.semantic_env.SemanticEnv.init(&state, null, &state.functions);
    const descriptor = sema.field(.{ .module_id = 0, .name = "Card" }, "style").?;
    try testing.expectEqualStrings("Base", descriptor.class_name);
    const index_fields = state.declaration_index.fields.items.ptr;
    var previous_fields: ?[*]core.RecordFieldValue = null;
    for (0..1000) |_| {
        var slot = (try core.fields.get(testing.allocator, &state, &card, "style")).?;
        defer slot.deinit(testing.allocator);
        try testing.expect(!slot.owned);
        try testing.expectEqual(@as(f32, 12), slot.value.record.field("amount").?.number);
        if (previous_fields) |fields| try testing.expect(fields == slot.value.record.fields.items.ptr);
        previous_fields = slot.value.record.fields.items.ptr;
    }
    try testing.expect(index_fields == state.declaration_index.fields.items.ptr);
}

test "declaration index: failed rebuilding preserves the previous index and parsed defaults" {
    var state = try documentFromSource(source);
    defer state.deinit();
    var original = (try core.fields.get(testing.allocator, &state, &card, "style")).?;
    defer original.deinit(testing.allocator);
    const index_fields = state.declaration_index.fields.items.ptr;
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    state.allocator = failing.allocator();
    const result = state.rebuildDeclarationIndex();
    state.allocator = testing.allocator;
    try testing.expectError(error.OutOfMemory, result);
    try testing.expect(index_fields == state.declaration_index.fields.items.ptr);
    var retained = (try core.fields.get(testing.allocator, &state, &card, "style")).?;
    defer retained.deinit(testing.allocator);
    try testing.expect(original.value.record.fields.items.ptr == retained.value.record.fields.items.ptr);
}

test "declaration index: refreshing declarations invalidates parsed field defaults" {
    var state = try documentFromSource(source);
    defer state.deinit();
    {
        var original = (try core.fields.get(testing.allocator, &state, &card, "style")).?;
        defer original.deinit(testing.allocator);
        try testing.expectEqual(@as(f32, 12), original.value.record.field("amount").?.number);
    }
    const descriptor = state.declaration_index.field(.{ .module_id = 0, .name = "Card" }, "style").?;
    const text = descriptor.default_property_value.?;
    const offset = std.mem.indexOf(u8, text, "12").?;
    @memcpy(@constCast(text[offset .. offset + 2]), "34");
    try state.rebuildDeclarationIndex();
    var refreshed = (try core.fields.get(testing.allocator, &state, &card, "style")).?;
    defer refreshed.deinit(testing.allocator);
    try testing.expectEqual(@as(f32, 34), refreshed.value.record.field("amount").?.number);
}

fn initializeDocument(allocator: std.mem.Allocator) !void {
    const assets = try allocator.dupe(u8, ".");
    errdefer allocator.free(assets);
    const path = try allocator.dupe(u8, "declarations-spec.ss");
    errdefer allocator.free(path);
    const text = try allocator.dupe(u8, "");
    errdefer allocator.free(text);
    var state = try core.DocumentState.init(allocator, assets, path, text, compiler.syntax.Module.init());
    state.deinit();
}

test "declaration index: document initialization releases partially allocated owners" {
    try testing.checkAllAllocationFailures(testing.allocator, initializeDocument, .{});
}

test "declaration index: repeated extensions have the same precedence in analysis and runtime" {
    var state = try documentFromSource(
        \\type Card = object {
        \\  roles = ["card"]
        \\  amount: Number = 1
        \\}
        \\extend Card {
        \\  amount: Number = 2
        \\}
        \\extend Card {
        \\  amount: Number = 3
        \\}
    );
    defer state.deinit();
    try compiler.analysis.analyzeDocumentState(testing.allocator, &state);
    const sema = compiler.semantic_env.SemanticEnv.init(&state, null, &state.functions);
    try testing.expectEqualStrings("3", sema.field(.{ .module_id = 0, .name = "Card" }, "amount").?.default_property_value.?);
    var slot = (try core.fields.get(testing.allocator, &state, &card, "amount")).?;
    defer slot.deinit(testing.allocator);
    try testing.expectEqual(@as(f32, 3), slot.value.number);
}

fn buildIndex(allocator: std.mem.Allocator, state: *const core.DocumentState) !void {
    var index = try core.declarations.build(allocator, state);
    defer index.deinit();
    try testing.expectEqualStrings("Base", index.field(.{ .module_id = 0, .name = "Card" }, "style").?.class_name);
}

test "declaration index: failed collection releases every partial container" {
    var state = try documentFromSource(source);
    defer state.deinit();
    try testing.checkAllAllocationFailures(testing.allocator, buildIndex, .{&state});
}
