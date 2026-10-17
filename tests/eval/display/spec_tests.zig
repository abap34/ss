const std = @import("std");
const compiler = @import("compiler");
const allocation_testing = @import("allocation_testing");
const core = compiler.core;
const Type = compiler.language.Type;
const testing = std.testing;

fn documentFromSource(text: []const u8) !core.DocumentState {
    const allocator = testing.allocator;
    var owned_source = try allocator.dupe(u8, text);
    defer allocator.free(owned_source);
    var syntax = try compiler.syntax.parseWithSourceName(allocator, owned_source, "display-spec.ss");
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
    return compiler.analysis.buildDocumentState(allocator, "display-spec.ss", ".", &owned_source, &syntax, &index);
}

fn prepare(state: *core.DocumentState, input: Type) !core.FunctionKey {
    var context = compiler.analysis.infer.Context.init(testing.allocator);
    defer context.deinit();
    const sema = compiler.semantic_env.SemanticEnv.init(state, state.declaration_index, &state.functions);
    const target = try compiler.analysis.infer.prepareDisplay(testing.allocator, state, &sema, input, state.sourceOrigin(0, .{ .start = 0, .end = 1 }), &context);
    return target.key;
}

fn register(state: *core.DocumentState, page: core.NodeId, ty: Type, field_name: []const u8, field: core.Value) !core.NodeId {
    var value = core.Value{ .record = .init(try ty.clone(testing.allocator)) };
    defer value.deinit(testing.allocator);
    var cloned = try field.clone(testing.allocator);
    value.record.fields.append(testing.allocator, .{ .name = field_name, .value = cloned }) catch |err| {
        cloned.deinit(testing.allocator);
        return err;
    };
    return state.registerPlacement(page, value, null);
}

fn initializeEvaluation(allocator: std.mem.Allocator, state: *core.DocumentState, graph: *const compiler.analysis.ExecutionGraph) !void {
    var evaluation = try compiler.evaluation.EvalContext.init(allocator, state, graph, .{ .io = testing.io });
    defer evaluation.deinit();
}

test "display evaluation: concrete generic results retain input type and placement ownership" {
    var state = try documentFromSource(
        \\type Input<T> { value: T }
        \\type Output<T> { value: T page: Page document: Document }
        \\fn display<T>(self: Placed<Input<T>>) -> Output<T>
        \\  return Output<T> { value = self.value.value page = self.page document = self.document }
        \\end
    );
    defer state.deinit();
    try compiler.analysis.analyzeDocumentState(testing.allocator, &state);
    var number_type = try Type.recordType("Input").inModule(0).withArguments(testing.allocator, &.{Type.number});
    defer number_type.deinit(testing.allocator);
    var string_type = try Type.recordType("Input").inModule(0).withArguments(testing.allocator, &.{Type.string});
    defer string_type.deinit(testing.allocator);
    const number_target = try prepare(&state, number_type);
    const string_target = try prepare(&state, string_type);
    try testing.expect(!number_target.eql(string_target));
    const instance_count = state.instantiations.entries.items.len;
    try testing.expect(number_target.eql(try prepare(&state, number_type)));
    try testing.expectEqual(instance_count, state.instantiations.entries.items.len);
    var graph = (try compiler.analysis.analyzeDocumentStateWithMode(testing.allocator, &state, .evaluation)).?;
    defer graph.deinit();
    try allocation_testing.checkAllAllocationFailures(testing.allocator, initializeEvaluation, .{ &state, &graph });
    const first_page = try state.addPage("First");
    const second_page = try state.addPage("Second");
    const first = try register(&state, first_page, number_type, "value", .{ .number = 12 });
    const repeated = try register(&state, second_page, number_type, "value", .{ .number = 12 });
    const second = try register(&state, second_page, string_type, "value", .{ .string = "Second" });
    var evaluation = try compiler.evaluation.EvalContext.init(testing.allocator, &state, &graph, .{ .io = testing.io });
    defer evaluation.deinit();
    try testing.expectError(error.InvalidValueTag, evaluation.displayValue(first, string_target));
    for ([_]struct { id: core.NodeId, page: core.NodeId }{ .{ .id = first, .page = first_page }, .{ .id = repeated, .page = second_page } }) |case| {
        var result = try evaluation.displayValue(case.id, number_target);
        defer result.deinit(testing.allocator);
        try testing.expectEqualStrings("Output", result.record.ty.class_name.?);
        try testing.expect(Type.eql(Type.number, result.record.ty.arguments[0]));
        try testing.expectEqual(@as(f32, 12), result.record.field("value").?.number);
        try testing.expectEqual(case.page, result.record.field("page").?.page);
        try testing.expectEqual(state.graph.document_id, result.record.field("document").?.document);
    }
    var text = try evaluation.displayValue(second, string_target);
    defer text.deinit(testing.allocator);
    try testing.expect(Type.eql(Type.string, text.record.ty.arguments[0]));
    try testing.expectEqualStrings("Second", text.record.field("value").?.string);
    try testing.expectEqual(@as(usize, 1), state.getNode(first).?.placement.?.value.record.fields.items.len);
}

test "display evaluation: captured functions survive between displays in one evaluation context" {
    var state = try documentFromSource(
        \\type Generator { value: Number }
        \\type Callback { call: () -> Number }
        \\type Output { value: Number }
        \\fn display(self: Placed<Generator>) -> Callback
        \\  let captured = self.value.value
        \\  return Callback { call = () |-> captured }
        \\end
        \\fn display(self: Placed<Callback>) -> Output
        \\  return Output { value = self.value.call() }
        \\end
    );
    defer state.deinit();
    try compiler.analysis.analyzeDocumentState(testing.allocator, &state);
    const generator_type = Type.recordType("Generator").inModule(0);
    const callback_type = Type.recordType("Callback").inModule(0);
    const generator = try prepare(&state, generator_type);
    const callback = try prepare(&state, callback_type);
    var graph = (try compiler.analysis.analyzeDocumentStateWithMode(testing.allocator, &state, .evaluation)).?;
    defer graph.deinit();
    const page = try state.addPage("First");
    const first = try register(&state, page, generator_type, "value", .{ .number = 42 });
    var evaluation = try compiler.evaluation.EvalContext.init(testing.allocator, &state, &graph, .{ .io = testing.io });
    defer evaluation.deinit();
    var generated = try evaluation.displayValue(first, generator);
    defer generated.deinit(testing.allocator);
    const child = try state.registerPlacement(first, generated, null);
    var result = try evaluation.displayValue(child, callback);
    defer result.deinit(testing.allocator);
    try testing.expectEqual(@as(f32, 42), result.record.field("value").?.number);
}

test "display analysis: concrete bodies are checked before evaluation" {
    var state = try documentFromSource(
        \\type Input<T> { value: T }
        \\type Output { value: Number }
        \\fn display<T>(self: Placed<Input<T>>) -> Output
        \\  return Output { value = self.value.value }
        \\end
    );
    defer state.deinit();
    try compiler.analysis.analyzeDocumentState(testing.allocator, &state);
    var valid = try Type.recordType("Input").inModule(0).withArguments(testing.allocator, &.{Type.number});
    defer valid.deinit(testing.allocator);
    _ = try prepare(&state, valid);
    var invalid = try Type.recordType("Input").inModule(0).withArguments(testing.allocator, &.{Type.string});
    defer invalid.deinit(testing.allocator);
    if (prepare(&state, invalid)) |_| return error.ExpectedInvalidDisplay else |err| {
        try testing.expect(err != error.OutOfMemory);
    }
    try testing.expectEqual(.failed, state.instantiations.entries.items[state.instantiations.entries.items.len - 1].status);
    try testing.expectError(error.AlreadyDiagnosed, prepare(&state, invalid));
}

test "display analysis: unresolved inputs missing displays and concrete scalar outputs are rejected" {
    var state = try documentFromSource(
        \\type Plain { value: Number }
        \\type Input<T> { value: T }
        \\fn display<T>(self: Placed<Input<T>>) -> T = self.value.value
    );
    defer state.deinit();
    try compiler.analysis.analyzeDocumentState(testing.allocator, &state);
    try testing.expectError(error.InvalidType, prepare(&state, Type.any));
    try testing.expectEqualStrings("UnresolvedDisplayType", state.diagnostics.entries.items[state.diagnostics.entries.items.len - 1].code());
    try testing.expectError(error.InvalidType, prepare(&state, Type.recordType("Plain").inModule(0)));
    try testing.expectEqualStrings("MissingDisplay", state.diagnostics.entries.items[state.diagnostics.entries.items.len - 1].code());
    var input = try Type.recordType("Input").inModule(0).withArguments(testing.allocator, &.{Type.number});
    defer input.deinit(testing.allocator);
    try testing.expectError(error.InvalidType, prepare(&state, input));
    try testing.expectEqualStrings("InvalidDisplayResult", state.diagnostics.entries.items[state.diagnostics.entries.items.len - 1].code());
}
