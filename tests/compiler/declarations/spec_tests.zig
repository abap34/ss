const std = @import("std");
const allocation_testing = @import("allocation_testing");
const compiler = @import("compiler");
const core = compiler.core;
const testing = std.testing;

const source =
    \\type Style {
    \\  amount: Number = 12
    \\}
    \\type Card {
    \\  style: Style = Style {}
    \\}
    \\page main
    \\  let card = Card {}
    \\end
;

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

fn styleDefault(state: *core.DocumentState) !core.Value {
    const descriptor = state.declaration_index.recordField(.{ .module_id = 0, .name = "Card" }, "style").?;
    return state.cachedFieldDefault(descriptor.default_property_value.?, descriptor.value_type);
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

    const descriptor = state.declaration_index.recordField(.{ .module_id = 0, .name = "Card" }, "style").?;
    try testing.expectEqualStrings("Card", descriptor.record_name);
    try testing.expectEqualStrings("Style", descriptor.value_type.class_name.?);
    const index_fields = state.declaration_index.record_fields.items.ptr;
    var previous_fields: ?[*]core.RecordFieldValue = null;
    for (0..1000) |_| {
        const value = try styleDefault(&state);
        try testing.expectEqual(@as(f32, 12), value.record.field("amount").?.number);
        if (previous_fields) |fields| try testing.expect(fields == value.record.fields.items.ptr);
        previous_fields = value.record.fields.items.ptr;
    }
    try testing.expect(index_fields == state.declaration_index.record_fields.items.ptr);
}

test "declaration index: failed rebuilding preserves the previous index and parsed defaults" {
    var state = try documentFromSource(source);
    defer state.deinit();
    const original = try styleDefault(&state);
    const index_fields = state.declaration_index.record_fields.items.ptr;
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    state.allocator = failing.allocator();
    const result = state.rebuildDeclarationIndex();
    state.allocator = testing.allocator;
    try testing.expectError(error.OutOfMemory, result);
    try testing.expect(index_fields == state.declaration_index.record_fields.items.ptr);
    const retained = try styleDefault(&state);
    try testing.expect(original.record.fields.items.ptr == retained.record.fields.items.ptr);
}

test "declaration index: refreshing declarations invalidates parsed field defaults" {
    var state = try documentFromSource(source);
    defer state.deinit();
    {
        const original = try styleDefault(&state);
        try testing.expectEqual(@as(f32, 12), original.record.field("amount").?.number);
    }
    const descriptor = state.declaration_index.recordField(.{ .module_id = 0, .name = "Card" }, "style").?;
    const text = descriptor.default_property_value.?;
    const offset = std.mem.indexOf(u8, text, "12").?;
    @memcpy(@constCast(text[offset .. offset + 2]), "34");
    try state.rebuildDeclarationIndex();
    const refreshed = try styleDefault(&state);
    try testing.expectEqual(@as(f32, 34), refreshed.record.field("amount").?.number);
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
    try allocation_testing.checkAllAllocationFailures(testing.allocator, initializeDocument, .{});
}

fn buildIndex(allocator: std.mem.Allocator, state: *const core.DocumentState) !void {
    var index = try core.declarations.build(allocator, state);
    defer index.deinit();
    try testing.expectEqualStrings("Card", index.recordField(.{ .module_id = 0, .name = "Card" }, "style").?.record_name);
}

test "declaration index: failed collection releases every partial container" {
    var state = try documentFromSource(source);
    defer state.deinit();
    try allocation_testing.checkAllAllocationFailures(testing.allocator, buildIndex, .{&state});
}

const display_source =
    \\type Label { text: String }
    \\type Caption { text: String }
    \\type RenderLabel { text: String }
    \\type RenderCaption { text: String }
    \\type Box<T> { value: T }
    \\fn display(self: Placed<Label>) -> RenderLabel = RenderLabel { text = self.value.text }
    \\fn display(self: Placed<Caption>) -> RenderCaption = RenderCaption { text = self.value.text }
    \\fn display<T>(self: Placed<Box<T>>) -> T = self.value.value
;

fn buildDisplayIndex(allocator: std.mem.Allocator, state: *const core.DocumentState) !void {
    var index = try core.declarations.build(allocator, state);
    defer index.deinit();
    const label = index.display(.{ .module_id = 0, .name = "Label" }).?;
    const caption = index.display(.{ .module_id = 0, .name = "Caption" }).?;
    try testing.expect(label.decl.span.start != caption.decl.span.start);
    try testing.expect(index.display(.{ .module_id = 1, .name = "Label" }) == null);
}

test "declaration index: display lookup uses the input declaration and retains independent function identities" {
    var state = try documentFromSource(display_source);
    defer state.deinit();
    try compiler.analysis.analyzeDocumentState(testing.allocator, &state);
    const sema = compiler.semantic_env.SemanticEnv.init(&state, state.declaration_index, &state.functions);
    const label = sema.displayForType(compiler.language.Type.recordType("Label").inModule(0)).?;
    const caption = sema.displayForType(compiler.language.Type.recordType("Caption").inModule(0)).?;
    try testing.expect(!label.key.eql(caption.key));
    try testing.expectEqualStrings("RenderLabel", label.decl.result_type.class_name.?);
    try testing.expectEqualStrings("RenderCaption", caption.decl.result_type.class_name.?);
    try testing.expect(sema.function("display") == null);
    try testing.expect(sema.displayForType(compiler.language.Type.recordType("Label").inModule(1)) == null);
    var box = try compiler.language.Type.recordType("Box").inModule(0).withArguments(testing.allocator, &.{compiler.language.Type.number});
    defer box.deinit(testing.allocator);
    const generic = sema.displayForType(box).?;
    try testing.expectEqual(@as(usize, 1), generic.decl.type_params.items.len);
    try testing.expect(!generic.key.eql(label.key));
    try allocation_testing.checkAllAllocationFailures(testing.allocator, buildDisplayIndex, .{&state});
}
