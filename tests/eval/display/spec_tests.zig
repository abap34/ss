const std = @import("std");
const compiler = @import("compiler");
const allocation_testing = @import("allocation_testing");
const core = compiler.core;
const Type = compiler.language.Type;
const testing = std.testing;

fn documentFromSource(text: []const u8) !core.DocumentState {
    return documentWithAllocator(testing.allocator, text);
}

fn documentWithAllocator(allocator: std.mem.Allocator, text: []const u8) !core.DocumentState {
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
    var context = compiler.analysis.infer.Context.init(state.allocator);
    defer context.deinit();
    const sema = compiler.semantic_env.SemanticEnv.init(state, state.declaration_index, &state.functions);
    const target = try compiler.analysis.infer.prepareDisplay(state.allocator, state, &sema, input, state.sourceOrigin(0, .{ .start = 0, .end = 1 }), &context);
    return target.function;
}

fn register(state: *core.DocumentState, page: core.NodeId, ty: Type, field_name: []const u8, field: core.Value) !core.NodeId {
    var value = core.Value{ .record = .init(try ty.clone(state.allocator)) };
    defer value.deinit(state.allocator);
    var cloned = try field.clone(state.allocator);
    value.record.fields.append(state.allocator, .{ .name = field_name, .value = cloned }) catch |err| {
        cloned.deinit(state.allocator);
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
    const child = try evaluation.expandDisplay(first, generator);
    try testing.expect(state.getNode(child).?.placement.?.display == .pending);
    try testing.expect(state.childrenOf(child) == null);
    const leaf = try evaluation.expandDisplay(child, callback);
    const result = state.getNode(leaf).?.placement.?.value;
    try testing.expectEqual(@as(f32, 42), result.record.field("value").?.number);
    try testing.expectEqualSlices(core.NodeId, &.{first}, state.childrenOf(page).?);
    try testing.expectEqualSlices(core.NodeId, &.{child}, state.childrenOf(first).?);
    try testing.expectEqualSlices(core.NodeId, &.{leaf}, state.childrenOf(child).?);
    try testing.expectEqual(page, state.getNode(leaf).?.placement.?.page_id);
    try testing.expectEqual(child, state.getNode(leaf).?.placement.?.parent_id);
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

const expansion_source =
    \\type Input { value: Number }
    \\type Output { value: Number page: Page }
    \\fn display(self: Placed<Input>) -> Output
    \\  return Output { value = self.value.value page = self.page }
    \\end
;

test "display expansion: each placement publishes its own child exactly once" {
    var state = try documentFromSource(expansion_source);
    defer state.deinit();
    try compiler.analysis.analyzeDocumentState(testing.allocator, &state);
    const input = Type.recordType("Input").inModule(0);
    const target = try prepare(&state, input);
    var graph = (try compiler.analysis.analyzeDocumentStateWithMode(testing.allocator, &state, .evaluation)).?;
    defer graph.deinit();
    const first_page = try state.addPage("First");
    const second_page = try state.addPage("Second");
    const first = try register(&state, first_page, input, "value", .{ .number = 12 });
    const second = try register(&state, second_page, input, "value", .{ .number = 12 });
    var evaluation = try compiler.evaluation.EvalContext.init(testing.allocator, &state, &graph, .{ .io = testing.io });
    defer evaluation.deinit();
    const second_child = try evaluation.expandDisplay(second, target);
    const first_child = try evaluation.expandDisplay(first, target);
    const count = state.nodeCount();
    try testing.expect(first_child != second_child);
    for ([_]struct { parent: core.NodeId, child: core.NodeId, page: core.NodeId }{
        .{ .parent = first, .child = first_child, .page = first_page },
        .{ .parent = second, .child = second_child, .page = second_page },
    }) |case| {
        try testing.expectEqual(case.child, try evaluation.expandDisplay(case.parent, target));
        try testing.expectEqual(count, state.nodeCount());
        try testing.expectEqualSlices(core.NodeId, &.{case.child}, state.childrenOf(case.parent).?);
        try testing.expectEqualSlices(core.NodeId, &.{case.parent}, state.placementRootsOf(case.page));
        const placed = state.getNode(case.child).?.placement.?;
        try testing.expectEqual(case.parent, placed.parent_id);
        try testing.expectEqual(case.page, placed.page_id);
        try testing.expectEqual(case.page, placed.value.record.field("page").?.page);
        try testing.expectEqualStrings("Output", placed.value.record.ty.class_name.?);
        try testing.expect(placed.display == .pending);
    }
    var other_target = target;
    other_target.module_id += 1;
    try testing.expectError(error.DisplayTargetMismatch, evaluation.expandDisplay(first, other_target));
    try testing.expectEqual(count, state.nodeCount());
}

const CancellationCounter = struct {
    checks: usize = 0,
    cancel_after: usize,

    fn canceled(context: *const anyopaque) bool {
        const self: *CancellationCounter = @ptrCast(@alignCast(@constCast(context)));
        self.checks += 1;
        return self.checks >= self.cancel_after;
    }
};

test "display expansion: cancellation leaves the parent pending and publishes no child" {
    var state = try documentFromSource(expansion_source);
    defer state.deinit();
    try compiler.analysis.analyzeDocumentState(testing.allocator, &state);
    const input = Type.recordType("Input").inModule(0);
    const target = try prepare(&state, input);
    var graph = (try compiler.analysis.analyzeDocumentStateWithMode(testing.allocator, &state, .evaluation)).?;
    defer graph.deinit();
    const page = try state.addPage("Page");
    const parent = try register(&state, page, input, "value", .{ .number = 12 });
    var evaluation = try compiler.evaluation.EvalContext.init(testing.allocator, &state, &graph, .{ .io = testing.io });
    defer evaluation.deinit();
    const count = state.nodeCount();
    const next_id = state.graph.next_id;
    for (1..128) |cancel_after| {
        var counter = CancellationCounter{ .cancel_after = cancel_after };
        evaluation.cancellation = .{ .context = &counter, .is_canceled = CancellationCounter.canceled };
        if (evaluation.expandDisplay(parent, target)) |child| {
            try testing.expectEqual(next_id, child);
            try testing.expectEqual(count + 1, state.nodeCount());
            try testing.expect(cancel_after > 2);
            return;
        } else |err| {
            try testing.expectEqual(error.Canceled, err);
            try testing.expectEqual(count, state.nodeCount());
            try testing.expectEqual(next_id, state.graph.next_id);
            try testing.expect(state.getNode(parent).?.placement.?.display == .pending);
            try testing.expect(state.childrenOf(parent) == null);
        }
    }
    return error.CancellationDidNotFinish;
}

test "display expansion: allocation failures preserve a retryable parent and no partial child" {
    // Arm failures only after analysis and registration so every run exercises
    // the expansion boundary, including the document's managed hash maps.
    for (0..256) |failure_offset| {
        var failing = testing.FailingAllocator.init(testing.allocator, .{ .resize_fail_index = 0 });
        const allocator = failing.allocator();
        var state = try documentWithAllocator(allocator, expansion_source);
        defer state.deinit();
        try compiler.analysis.analyzeDocumentState(allocator, &state);
        const input = Type.recordType("Input").inModule(0);
        const target = try prepare(&state, input);
        var graph = (try compiler.analysis.analyzeDocumentStateWithMode(allocator, &state, .evaluation)).?;
        defer graph.deinit();
        const page = try state.addPage("Page");
        const parent = try register(&state, page, input, "value", .{ .number = 12 });
        var evaluation = try compiler.evaluation.EvalContext.init(allocator, &state, &graph, .{ .io = testing.io });
        defer evaluation.deinit();
        const count = state.nodeCount();
        const next_id = state.graph.next_id;
        failing.fail_index = failing.alloc_index + failure_offset;
        if (evaluation.expandDisplay(parent, target)) |child| {
            try testing.expect(!failing.has_induced_failure);
            try testing.expectEqual(next_id, child);
            try testing.expect(failure_offset > 0);
            return;
        } else |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            try testing.expectEqual(count, state.nodeCount());
            try testing.expectEqual(next_id, state.graph.next_id);
            try testing.expect(state.getNode(parent).?.placement.?.display == .pending);
            try testing.expect(state.childrenOf(parent) == null);
            try testing.expectEqualSlices(core.NodeId, &.{parent}, state.placementRootsOf(page));
            failing.fail_index = std.math.maxInt(usize);
            const child = try evaluation.expandDisplay(parent, target);
            try testing.expectEqual(next_id, child);
            try testing.expectEqual(count + 1, state.nodeCount());
            try testing.expectEqualSlices(core.NodeId, &.{child}, state.childrenOf(parent).?);
        }
    }
    return error.AllocationFailuresDidNotFinish;
}

fn documentWithModules(text: []const u8) !core.DocumentState {
    const allocator = testing.allocator;
    var source = try allocator.dupe(u8, text);
    defer allocator.free(source);
    var syntax = try compiler.syntax.parseWithSourceName(allocator, source, "native-display-spec.ss");
    defer syntax.deinit(allocator);
    var index = try compiler.analysis.loadModuleIndex(allocator, testing.io, ".", syntax, .{});
    defer index.deinit();
    return compiler.analysis.buildDocumentState(allocator, "native-display-spec.ss", ".", &source, &syntax, &index);
}

fn prepareTarget(state: *core.DocumentState, input: Type) !core.native_display.Target {
    var context = compiler.analysis.infer.Context.init(state.allocator);
    defer context.deinit();
    const sema = compiler.semantic_env.SemanticEnv.init(state, state.declaration_index, &state.functions);
    return compiler.analysis.infer.prepareDisplay(state.allocator, state, &sema, input, state.sourceOrigin(0, .{ .start = 0, .end = 1 }), &context);
}

test "native text display: a user display reaches Markdown preparation through immutable Text input" {
    var state = try documentWithModules(
        \\import std:text/content as native
        \\import std:text/types as styles
        \\import std:text/style as block
        \\type Message { content: String }
        \\fn display(self: Placed<Message>) -> native::Text
        \\  return native::Text {
        \\    content = self.value.content
        \\    style = block::TextBlockStyle { text = styles::TextStyle { size = 31 parse = styles::TextParseMode.block } }
        \\  }
        \\end
    );
    defer state.deinit();
    try compiler.analysis.analyzeDocumentState(testing.allocator, &state);
    const input = Type.recordType("Message").inModule(0);
    const target = try prepareTarget(&state, input);
    var graph = (try compiler.analysis.analyzeDocumentStateWithMode(testing.allocator, &state, .evaluation)).?;
    defer graph.deinit();
    const page = try state.addPage("Page");
    const parent = try register(&state, page, input, "content", .{ .string = "# Overview\n\n**Typed** text" });
    var evaluation = try compiler.evaluation.EvalContext.init(testing.allocator, &state, &graph, .{ .io = testing.io });
    defer evaluation.deinit();
    try testing.expectError(error.InvalidNativeDisplay, evaluation.expandDisplayTarget(parent, .{ .native = .text }));
    try testing.expect(state.getNode(parent).?.placement.?.display == .pending);
    try testing.expectError(error.UnexpandedDisplay, core.prepared.prepare(testing.allocator, &state));
    const child = (try evaluation.expandDisplayTarget(parent, target))[0];
    const native = try prepareTarget(&state, state.getNode(child).?.placement.?.value.record.ty);
    try testing.expectEqual(core.native_display.Kind.text, native.native);
    const count = state.nodeCount();
    try testing.expectEqual(@as(usize, 0), (try evaluation.expandDisplayTarget(child, native)).len);
    try testing.expectEqual(@as(usize, 0), (try evaluation.expandDisplayTarget(child, native)).len);
    try testing.expectEqual(count, state.nodeCount());
    try testing.expect(state.childrenOf(child) == null);
    const node = state.getNode(child).?;
    try testing.expect(node.role == null);
    try testing.expectEqual(@as(usize, 0), node.fields.items.len);
    try testing.expectEqual(core.ObjectKind.text, node.object_kind.?);
    try testing.expectEqualStrings("# Overview\n\n**Typed** text", core.nodeDisplayContent(node));
    const render = core.render_policy.resolve(&state, node);
    try testing.expectEqual(@as(f32, 31), render.text.?.font_size);
    var prepared = try core.prepared.prepareObjectWithRender(testing.allocator, &state, node, render);
    defer prepared.deinit(testing.allocator);
    try testing.expectEqual(core.markdown.ParseMode.block, prepared.parse_mode);
    try testing.expect(prepared.markdown_doc.?.blocks.items.len >= 2);
    try testing.expectEqualStrings("# Overview\n\n**Typed** text", prepared.content);
    try testing.expectEqual(core.ObjectKind.overlay, state.getNode(parent).?.object_kind.?);
    try testing.expectEqual(core.render_policy.RenderKind.chrome_only, core.render_policy.resolveKind(&state, state.getNode(parent).?));
    var pages = try core.prepared.prepare(testing.allocator, &state);
    defer pages.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), pages.pages.len);
    try testing.expectEqual(@as(usize, 2), pages.pages[0].objects.len);
    try testing.expectError(error.DisplayTargetMismatch, evaluation.expandDisplayTarget(child, target));
}

test "native image display: immutable inputs retain asset styles and independent placements" {
    var state = try documentWithModules(
        \\import std:assets as assets
        \\type Picture { image: assets::Image }
        \\fn display(self: Placed<Picture>) -> assets::Image = self.value.image
        \\const picture: assets::Image = assets::Image {
        \\  path = "tests/fixtures/layout/practical/diagram.svg"
        \\  style = assets::AssetBlockStyle {} with { asset.scale = 0.5 chrome.pad_x = 8 chrome.pad_y = 6 }
        \\}
        \\page first
        \\  let first = place!(picture)
        \\  let second = place!(picture with { style.asset.scale = 0.25 })
        \\end
        \\page second
        \\  let wrapped = place!(Picture { image = picture })
        \\end
    );
    defer state.deinit();
    var graph = (try compiler.analysis.analyzeDocumentStateWithMode(testing.allocator, &state, .evaluation)).?;
    defer graph.deinit();
    try compiler.lowering.evaluateDocument(&state, &graph, .{ .io = testing.io });
    try testing.expectEqual(@as(usize, 0), state.diagnostics.entries.items.len);
    const first_page = state.graph.page_order.items[0];
    const second_page = state.graph.page_order.items[1];
    const roots = state.placementRootsOf(first_page);
    try testing.expectEqual(@as(usize, 2), roots.len);
    const parent = state.placementRootsOf(second_page)[0];
    const child = state.childrenOf(parent).?[0];
    for ([_]core.NodeId{ roots[0], roots[1], child }, [_]f32{ 0.5, 0.25, 0.5 }) |id, scale| {
        const node = state.getNode(id).?;
        try testing.expectEqual(core.native_display.Kind.image, node.placement.?.display.native);
        try testing.expectEqual(if (id == child) second_page else first_page, node.placement.?.page_id);
        try testing.expectEqual(core.ObjectKind.asset, node.object_kind.?);
        try testing.expectEqual(core.PayloadKind.image_ref, node.payload_kind.?);
        try testing.expect(node.role == null);
        try testing.expect(node.content == null);
        try testing.expectEqual(@as(usize, 0), node.fields.items.len);
        const paint = core.render_policy.resolve(&state, node);
        try testing.expectEqual(core.render_policy.RenderKind.raster_asset, paint.kind);
        try testing.expectEqual(scale, paint.asset.?.scale);
        try testing.expectEqual(@as(f32, 8), paint.chrome.pad_x);
        try testing.expectEqual(@as(f32, 6), paint.chrome.pad_y);
        var prepared = try core.prepared.prepareObject(testing.allocator, &state, node);
        defer prepared.deinit(testing.allocator);
        try testing.expectEqualStrings("tests/fixtures/layout/practical/diagram.svg", prepared.content);
        try testing.expectEqual(@as(usize, 1), prepared.asset_deps.len);
        try testing.expectEqualStrings(prepared.content, prepared.asset_deps[0].source);
        try testing.expect(prepared.markdown_doc == null);
        try testing.expect(prepared.text_layout == null);
    }
    try testing.expectEqual(parent, state.getNode(child).?.placement.?.parent_id);
    var selected = try state.selectTypedPlacements(testing.allocator, .{ .document = state.graph.document_id }, state.getNode(child).?.placement.?.value.record.ty);
    defer selected.deinit(testing.allocator);
    try testing.expectEqualSlices(core.NodeId, &.{ roots[0], roots[1], child }, selected.ids.items);
}

test "native asset display: local names and incomplete inputs cannot impersonate renderer types" {
    var state = try documentWithModules(
        \\import std:assets as assets
        \\type Image { path: String }
        \\type Pdf { path: String }
    );
    defer state.deinit();
    try compiler.analysis.analyzeDocumentState(testing.allocator, &state);
    for ([_]struct { name: []const u8, kind: core.native_display.Kind }{
        .{ .name = "Image", .kind = .image },
        .{ .name = "Pdf", .kind = .pdf },
    }) |case| {
        const local = Type.recordType(case.name).inModule(0);
        try testing.expect(core.native_display.kindForType(&state, local) == null);
        try testing.expectError(error.InvalidType, prepareTarget(&state, local));
        const native_module = state.moduleByPathOrSpec("std:assets/content").?;
        const native_type = Type.recordType(case.name).inModule(native_module.id);
        try testing.expectEqual(case.kind, (try prepareTarget(&state, native_type)).native);
        var value = core.Value{ .record = .init(native_type) };
        defer value.deinit(testing.allocator);
        try value.record.fields.append(testing.allocator, .{ .name = "path", .value = .{ .string = "Missing style" } });
        try testing.expectError(error.InvalidNativeDisplay, core.native_display.validateValue(&state, value, case.kind));
        try value.record.fields.append(testing.allocator, .{ .name = "style", .value = .{ .record = .init(Type.recordType("AssetBlockStyle").inModule(0)) } });
        try testing.expectError(error.InvalidNativeDisplay, core.native_display.validateValue(&state, value, case.kind));
    }
}

test "native image display: missing assets report their placement and page before rendering" {
    var state = try documentWithModules(
        \\import std:assets as assets
        \\page first
        \\  let missing = place!(assets::Image { path = "tests/fixtures/typed-display/absent-image.png" })
        \\end
    );
    defer state.deinit();
    var graph = (try compiler.analysis.analyzeDocumentStateWithMode(testing.allocator, &state, .evaluation)).?;
    defer graph.deinit();
    try compiler.lowering.evaluateDocument(&state, &graph, .{ .io = testing.io });
    const page = state.graph.page_order.items[0];
    const root = state.placementRootsOf(page)[0];
    try testing.expectEqual(@as(usize, 1), state.diagnostics.entries.items.len);
    const diagnostic = state.diagnostics.entries.items[0];
    try testing.expectEqualStrings("AssetNotFound", diagnostic.code());
    try testing.expectEqual(page, diagnostic.page_id.?);
    try testing.expectEqual(root, diagnostic.node_id.?);
    try testing.expect(diagnostic.origin != null);
    try testing.expectEqualStrings("tests/fixtures/typed-display/absent-image.png", diagnostic.data.asset_not_found.requested_path);
}

test "native text display: nominal identity and complete input are required" {
    var state = try documentWithModules(
        \\import std:text/content as native
        \\type Text { content: String }
    );
    defer state.deinit();
    try compiler.analysis.analyzeDocumentState(testing.allocator, &state);
    const local = Type.recordType("Text").inModule(0);
    try testing.expect(core.native_display.kindForType(&state, local) == null);
    try testing.expectError(error.InvalidType, prepareTarget(&state, local));
    const native_module = state.moduleByPathOrSpec("std:text/content").?;
    const native_type = Type.recordType("Text").inModule(native_module.id);
    try testing.expectEqual(core.native_display.Kind.text, (try prepareTarget(&state, native_type)).native);
    var value = core.Value{ .record = .init(native_type) };
    defer value.deinit(testing.allocator);
    try value.record.fields.append(testing.allocator, .{ .name = "content", .value = .{ .string = "Missing style" } });
    try testing.expectError(error.InvalidNativeDisplay, core.native_display.validateValue(&state, value, .text));
    try value.record.fields.append(testing.allocator, .{ .name = "style", .value = .{ .record = .init(Type.recordType("TextBlockStyle").inModule(0)) } });
    try testing.expectError(error.InvalidNativeDisplay, core.native_display.validateValue(&state, value, .text));
}

test "native text display: public Text preserves complete block styles without mutable properties" {
    var state = try documentWithModules(
        \\import std:text as text_api
        \\import std:layout/types as layout
        \\fn/! styled(content: String, style: text_api::TextBlockStyle) -> text_api::Text
        \\  return text_api::Text { content = content style = style }
        \\end
        \\page main
        \\  let original = text_api::TextBlockStyle {
        \\    text = text_api::TextStyle { size = 23 parse = text_api::TextParseMode.block }
        \\    layout = layout::LayoutStyle { x = 64 right_inset = 80 spacing_after = 19 wrap = layout::WrapMode.off }
        \\    underline = text_api::UnderlineStyle { color = c"#ff0000" width = 3 offset = -4 }
        \\    headings = text_api::MarkdownHeadingStyles {
        \\      h1 = text_api::MarkdownHeadingStyle { text = text_api::TextStyle { size = 37 line_height = 43 } }
        \\    }
        \\  }
        \\  let changed = original with { text.size = 29 layout.wrap = layout::WrapMode.on headings.h2 = text_api::MarkdownHeadingStyle { text = text_api::TextStyle { size = 31 } } }
        \\  let first: Placed<text_api::Text> = styled!("# First", original)
        \\  let second: Placed<text_api::Text> = styled!("## Second", changed)
        \\end
    );
    defer state.deinit();
    var graph = (try compiler.analysis.analyzeDocumentStateWithMode(testing.allocator, &state, .evaluation)).?;
    defer graph.deinit();
    try compiler.lowering.evaluateDocument(&state, &graph, .{ .io = testing.io });
    const roots = state.placementRootsOf(state.graph.page_order.items[0]);
    try testing.expectEqual(@as(usize, 2), roots.len);
    for (roots, [_]f32{ 23, 29 }, 0..) |root, font_size, index| {
        const node = state.getNode(root).?;
        try testing.expect(node.role == null);
        try testing.expectEqual(@as(usize, 0), node.fields.items.len);
        const paint = core.render_policy.resolve(&state, node);
        try testing.expectEqual(font_size, paint.text.?.font_size);
        try testing.expectEqual(index == 1, paint.text.?.wrap);
        try testing.expectEqual(@as(f32, 37), paint.text.?.markdown_headings[0].?.font_size);
        try testing.expectEqual(@as(f32, 43), paint.text.?.markdown_headings[0].?.line_height);
        if (index == 0) try testing.expect(paint.text.?.markdown_headings[1] == null) else try testing.expectEqual(@as(f32, 31), paint.text.?.markdown_headings[1].?.font_size);
        try testing.expectEqual(@as(f32, 3), paint.underline.width);
        try testing.expectEqual(@as(f32, -4), paint.underline.offset);
        try testing.expectEqual(@as(f32, 1), paint.underline.color.?.r);
        const layout = core.nodeField(node, "layout").?.record;
        try testing.expectEqual(@as(f32, 64), layout.field("x").?.number);
        try testing.expectEqual(@as(f32, 80), layout.field("right_inset").?.number);
        try testing.expectEqual(@as(f32, 19), layout.field("spacing_after").?.number);
        var prepared = try core.prepared.prepareObjectWithRender(testing.allocator, &state, node, paint);
        defer prepared.deinit(testing.allocator);
        try testing.expectEqual(core.markdown.ParseMode.block, prepared.parse_mode);
        try testing.expectEqual(@as(usize, 1), prepared.markdown_doc.?.blocks.items.len);
    }
}

test "native text display: an immutable theme block can be used directly and updated independently" {
    var state = try documentWithModules(
        \\import std:themes/academic as academic
        \\import std:text as { Text }
        \\fn/! styled(content: String, style: TextBlockStyle) -> Text = Text { content = content style = style }
        \\page main
        \\  let theme = academic::default_theme()
        \\  styled!("Original", theme.h1)
        \\  styled!("Changed", theme.h1 with { text.size = 44 })
        \\  styled!("Reused", theme.h1)
        \\end
    );
    defer state.deinit();
    var graph = (try compiler.analysis.analyzeDocumentStateWithMode(testing.allocator, &state, .evaluation)).?;
    defer graph.deinit();
    try compiler.lowering.evaluateDocument(&state, &graph, .{ .io = testing.io });
    const roots = state.placementRootsOf(state.graph.page_order.items[0]);
    try testing.expectEqual(@as(usize, 3), roots.len);
    for (roots, [_]f32{ 32, 44, 32 }) |root, size| {
        const node = state.getNode(root).?;
        const paint = core.render_policy.resolve(&state, node);
        try testing.expectEqual(size, paint.text.?.font_size);
        try testing.expectEqual(@as(f32, 36), paint.text.?.line_height);
        try testing.expectEqual(@as(f32, 48), core.nodeField(node, "layout").?.record.field("spacing_after").?.number);
        try testing.expect(node.role == null);
        try testing.expectEqual(@as(usize, 0), node.fields.items.len);
    }
}

test "native text display: every bundled theme resolves the same text paint from a block value" {
    for ([_][]const u8{ "default", "academic", "pop" }) |name| {
        const source = try std.fmt.allocPrint(testing.allocator,
            \\import std:themes/{s} as theme_api
            \\import std:text as {{ Text }}
            \\import std:internal/style as styles
            \\fn/! styled(content: String, style: TextBlockStyle) -> Text = Text {{ content = content style = style }}
            \\page main
            \\  let theme = theme_api::default_theme()
            \\  text!("# Theme", theme)
            \\  styled!("# Theme", styles::markdown_text_style(theme))
            \\end
        , .{name});
        defer testing.allocator.free(source);
        var state = try documentWithModules(source);
        defer state.deinit();
        var graph = (try compiler.analysis.analyzeDocumentStateWithMode(testing.allocator, &state, .evaluation)).?;
        defer graph.deinit();
        try compiler.lowering.evaluateDocument(&state, &graph, .{ .io = testing.io });
        const roots = state.placementRootsOf(state.graph.page_order.items[0]);
        try testing.expectEqual(@as(usize, 2), roots.len);
        const previous = state.getNode(roots[0]).?;
        const typed = state.getNode(roots[1]).?;
        const previous_paint = core.render_policy.resolve(&state, previous);
        const typed_paint = core.render_policy.resolve(&state, typed);
        try testing.expectEqualDeep(previous_paint.text, typed_paint.text);
        try testing.expectEqualDeep(previous_paint.underline, typed_paint.underline);
        try testing.expectEqual(core.markdown.parseModeForNode(&state, previous), core.markdown.parseModeForNode(&state, typed));
        try testing.expect(typed.role == null);
        try testing.expectEqual(@as(usize, 0), typed.fields.items.len);
    }
}

fn preparePlan(state: *core.DocumentState, input: Type) !compiler.analysis.display.Plan {
    var context = compiler.analysis.infer.Context.init(state.allocator);
    defer context.deinit();
    const sema = compiler.semantic_env.SemanticEnv.init(state, state.declaration_index, &state.functions);
    return compiler.analysis.display.prepare(state.allocator, state, &sema, input, state.sourceOrigin(0, .{ .start = 0, .end = 1 }), &context);
}

fn preparePlanWithAllocator(allocator: std.mem.Allocator, state: *core.DocumentState, input: Type) !void {
    var context = compiler.analysis.infer.Context.init(allocator);
    defer context.deinit();
    const sema = compiler.semantic_env.SemanticEnv.init(state, state.declaration_index, &state.functions);
    var plan = try compiler.analysis.display.prepare(allocator, state, &sema, input, state.sourceOrigin(0, .{ .start = 0, .end = 1 }), &context);
    defer plan.deinit();
}

test "display plan: nested generic wrappers terminate at the native Text type" {
    var state = try documentWithModules(
        \\import std:text/content as native
        \\type Wrapper<T> { value: T }
        \\type Message { content: String }
        \\fn display<T>(self: Placed<Wrapper<T>>) -> T = self.value.value
        \\fn display(self: Placed<Message>) -> native::Text
        \\  return native::Text { content = self.value.content }
        \\end
    );
    defer state.deinit();
    try compiler.analysis.analyzeDocumentState(testing.allocator, &state);
    const message_type = Type.recordType("Message").inModule(0);
    const wrapper_type = Type.recordType("Wrapper").inModule(0);
    var inner = try wrapper_type.withArguments(testing.allocator, &.{message_type});
    defer inner.deinit(testing.allocator);
    var outer = try wrapper_type.withArguments(testing.allocator, &.{inner});
    defer outer.deinit(testing.allocator);
    var plan = try preparePlan(&state, outer);
    defer plan.deinit();
    try testing.expectEqual(@as(usize, 4), plan.steps.items.len);
    try allocation_testing.checkAllAllocationFailures(testing.allocator, preparePlanWithAllocator, .{ &state, outer });
    try testing.expect(Type.eql(outer, plan.steps.items[0].input));
    try testing.expect(Type.eql(inner, plan.steps.items[1].input));
    try testing.expect(Type.eql(message_type, plan.steps.items[2].input));
    try testing.expectEqual(core.native_display.Kind.text, plan.steps.items[3].target.native);
    try testing.expect(!plan.steps.items[0].target.function.eql(plan.steps.items[1].target.function));
    var graph = (try compiler.analysis.analyzeDocumentStateWithMode(testing.allocator, &state, .evaluation)).?;
    defer graph.deinit();
    const page = try state.addPage("Page");
    const message = try register(&state, page, message_type, "content", .{ .string = "**Nested** input" });
    const inner_placement = try register(&state, page, inner, "value", state.getNode(message).?.placement.?.value);
    const outer_placement = try register(&state, page, outer, "value", state.getNode(inner_placement).?.placement.?.value);
    var evaluation = try compiler.evaluation.EvalContext.init(testing.allocator, &state, &graph, .{ .io = testing.io });
    defer evaluation.deinit();
    var id = outer_placement;
    for (plan.steps.items, 0..) |step, index| {
        try testing.expect(Type.eql(step.input, state.getNode(id).?.placement.?.value.record.ty));
        try testing.expectEqual(index, step.depth);
        try testing.expectEqual(if (index == 0) null else @as(?usize, index - 1), step.parent);
        const children = try evaluation.expandDisplayTarget(id, step.target);
        try testing.expectEqual(step.children.items.len, children.len);
        if (children.len != 0) {
            try testing.expectEqualSlices(usize, &.{index + 1}, step.children.items);
            const child = children[0];
            try testing.expectEqual(id, state.getNode(child).?.placement.?.parent_id);
            try testing.expectEqual(page, state.getNode(child).?.placement.?.page_id);
            id = child;
        } else try testing.expectEqual(plan.steps.items.len - 1, index);
    }
    const node = state.getNode(id).?;
    try testing.expectEqualStrings("**Nested** input", core.nodeDisplayContent(node));
    try testing.expectEqual(core.markdown.ParseMode.block, core.markdown.parseModeForNode(&state, node));
}

test "display plan: exact cycles and growing type arguments are rejected before evaluation" {
    const cases = [_]struct { source: []const u8, name: []const u8, generic: bool }{
        .{ .source =
        \\type Loop {}
        \\fn display(self: Placed<Loop>) -> Loop = self.value
        , .name = "Loop", .generic = false },
        .{ .source =
        \\type First {}
        \\type Second {}
        \\fn display(self: Placed<First>) -> Second = Second {}
        \\fn display(self: Placed<Second>) -> First = First {}
        , .name = "First", .generic = false },
        .{ .source =
        \\type Growing<T> { value: T }
        \\fn display<T>(self: Placed<Growing<T>>) -> Growing<Growing<T>>
        \\  return Growing<Growing<T>> { value = self.value }
        \\end
        , .name = "Growing", .generic = true },
    };
    for (cases) |case| {
        var state = try documentFromSource(case.source);
        defer state.deinit();
        try compiler.analysis.analyzeDocumentState(testing.allocator, &state);
        var input = Type.recordType(case.name).inModule(0);
        if (case.generic) input = try input.withArguments(testing.allocator, &.{Type.number});
        defer input.deinit(testing.allocator);
        const count = state.nodeCount();
        try testing.expectError(error.NonTerminatingDisplay, preparePlan(&state, input));
        try testing.expectEqual(count, state.nodeCount());
        try testing.expectEqualStrings("NonTerminatingDisplay", state.diagnostics.entries.items[state.diagnostics.entries.items.len - 1].code());
        if (case.generic) try testing.expectEqual(@as(usize, 1), state.instantiations.entries.items.len);
    }
}

test "typed placement: source calls schedule distinct display units and preserve page ownership" {
    const source = try std.Io.Dir.cwd().readFileAlloc(testing.io, "tests/fixtures/typed-display/slide.ss", testing.allocator, .limited(64 * 1024));
    defer testing.allocator.free(source);
    var state = try documentWithModules(source);
    defer state.deinit();
    var graph = (try compiler.analysis.analyzeDocumentStateWithMode(testing.allocator, &state, .evaluation)).?;
    defer graph.deinit();
    var display_units: usize = 0;
    for (graph.units.items) |unit| if (unit.kind == .display) {
        display_units += 1;
    };
    try testing.expectEqual(@as(usize, 6), display_units);
    try allocation_testing.checkAllAllocationFailures(testing.allocator, initializeEvaluation, .{ &state, &graph });
    try compiler.lowering.evaluateDocument(&state, &graph, .{ .io = testing.io });
    var pages = try core.prepared.prepare(testing.allocator, &state);
    defer pages.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), pages.pages.len);
    const first_page = state.graph.page_order.items[0];
    const second_page = state.graph.page_order.items[1];
    const roots = state.placementRootsOf(first_page);
    try testing.expectEqual(@as(usize, 2), roots.len);
    try testing.expect(roots[0] != roots[1]);
    for (roots) |root| {
        const child = state.childrenOf(root).?[0];
        try testing.expectEqualStrings("**Typed** heading / page 1", core.nodeDisplayContent(state.getNode(child).?));
        try testing.expectEqual(first_page, state.getNode(child).?.placement.?.page_id);
    }
    const second = state.placementRootsOf(second_page)[0];
    const second_child = state.childrenOf(second).?[0];
    try testing.expectEqualStrings("Second / page 2", core.nodeDisplayContent(state.getNode(second_child).?));
    try testing.expectEqual(second_page, state.getNode(second_child).?.placement.?.page_id);
    var layout = try core.layout.solveDocument(&state, null, .{ .jobs = 1 });
    defer layout.deinit(testing.allocator);
    try layout.validate();
    const first_frame = layout.nodeFrame(roots[0]).?;
    const next_frame = layout.nodeFrame(roots[1]).?;
    try testing.expect(first_frame.width > 1);
    try testing.expectApproxEqAbs(@as(f32, 48), first_frame.x, core.layout.graph.ConstraintTolerance);
    try testing.expectApproxEqAbs(first_frame.x + first_frame.width + 24, next_frame.x, core.layout.graph.ConstraintTolerance);
    try testing.expectApproxEqAbs(first_frame.y + first_frame.height / 2, next_frame.y + next_frame.height / 2, core.layout.graph.ConstraintTolerance);
    for (roots) |root| {
        const parent_frame = layout.nodeFrame(root).?;
        const child_frame = layout.nodeFrame(state.childrenOf(root).?[0]).?;
        try testing.expectApproxEqAbs(parent_frame.x, child_frame.x, core.layout.graph.ConstraintTolerance);
        try testing.expectApproxEqAbs(parent_frame.y, child_frame.y, core.layout.graph.ConstraintTolerance);
        try testing.expectApproxEqAbs(parent_frame.width, child_frame.width, core.layout.graph.ConstraintTolerance);
        try testing.expectApproxEqAbs(parent_frame.height, child_frame.height, core.layout.graph.ConstraintTolerance);
    }
}

test "typed placement: display dependencies wait for page creation and retain callback captures" {
    var state = try documentWithModules(
        \\import std:text/content as native
        \\type Input { value: () -> String }
        \\type Callback { value: () -> String }
        \\fn display(self: Placed<Input>) -> Callback
        \\  let format = self.value.value
        \\  return Callback { value = () |-> format() }
        \\end
        \\fn display(self: Placed<Callback>) -> native::Text
        \\  return native::Text { content = self.value.value() }
        \\end
        \\document
        \\  let page = new_page(docctx(), "First")
        \\  let placed = place_on!(page, Input { value = () |-> str(page_count(docctx())) })
        \\  let second = new_page(docctx(), "Second")
        \\end
    );
    defer state.deinit();
    var graph = (try compiler.analysis.analyzeDocumentStateWithMode(testing.allocator, &state, .evaluation)).?;
    defer graph.deinit();
    var page_readers: usize = 0;
    for (graph.units.items) |unit| {
        for (unit.summary.reads.items) |read| {
            if (read != .pages) continue;
            try testing.expect(unit.kind == .display);
            try testing.expectEqual(@as(usize, 1), unit.kind.display.step);
            page_readers += 1;
        }
    }
    try testing.expectEqual(@as(usize, 1), page_readers);
    try compiler.lowering.evaluateDocument(&state, &graph, .{ .io = testing.io });
    try testing.expectEqual(@as(usize, 2), state.graph.page_order.items.len);
    const page = state.graph.page_order.items[0];
    const root = state.placementRootsOf(page)[0];
    const child = state.childrenOf(root).?[0];
    const text = state.childrenOf(child).?[0];
    try testing.expectEqualStrings("2", core.nodeDisplayContent(state.getNode(text).?));
    try testing.expectEqual(page, state.getNode(text).?.placement.?.page_id);
}

test "typed placement: indirect display writes are rejected with the concrete input callback" {
    var state = try documentWithModules(
        \\import std:text/content as native
        \\type Input { value: () -> String }
        \\fn mutate() -> String
        \\  new_page(docctx(), "Unexpected")
        \\  return "bad"
        \\end
        \\fn display(self: Placed<Input>) -> native::Text
        \\  return native::Text { content = self.value.value() }
        \\end
        \\page first
        \\  place_on!(pagectx(), Input { value = mutate })
        \\end
    );
    defer state.deinit();
    try testing.expectError(error.ImpureDisplayFunction, compiler.analysis.analyzeDocumentState(testing.allocator, &state));
    try testing.expectEqual(@as(usize, 0), state.graph.page_order.items.len);
}

test "typed membership: full input types and page scopes distinguish generated collections" {
    const Resource = compiler.analysis.dependencies.Resource;
    var text = try Type.recordType("Box").inModule(0).withArguments(testing.allocator, &.{Type.string});
    defer text.deinit(testing.allocator);
    var number = try Type.recordType("Box").inModule(0).withArguments(testing.allocator, &.{Type.number});
    defer number.deinit(testing.allocator);
    const first = Resource{ .objects = .{ .input_type = text, .page_scope = .{ .page = 1 } } };
    const same = Resource{ .objects = .{ .input_type = text, .page_scope = .{ .page = 1 } } };
    const different_type = Resource{ .objects = .{ .input_type = number, .page_scope = .{ .page = 1 } } };
    const different_page = Resource{ .objects = .{ .input_type = text, .page_scope = .{ .page = 2 } } };
    const all_text = Resource{ .objects = .{ .input_type = text } };
    try testing.expect(first.eql(same));
    try testing.expect(first.intersects(same));
    try testing.expect(!first.eql(different_type));
    try testing.expect(!first.intersects(different_type));
    try testing.expect(!first.intersects(different_page));
    try testing.expect(all_text.intersects(first));
    try testing.expect(all_text.intersects(different_page));
    try testing.expect(!all_text.intersects(different_type));
}

fn buildDisplayGraph(allocator: std.mem.Allocator, state: *core.DocumentState) !void {
    var graph = try compiler.analysis.ExecutionGraph.build(allocator, state, state.declaration_index, .{ .page_id_mode = .synthetic });
    defer graph.deinit();
}

test "typed placement: authored root order survives dependency ordering and graph allocation failure" {
    var state = try documentWithModules(
        \\import std:text/content as native
        \\type Label { title: String }
        \\fn display(self: Placed<Label>) -> native::Text
        \\  return native::Text { content = self.value.title }
        \\end
        \\document
        \\  let page = new_page(docctx(), "First")
        \\  let first = place_on!(page, Label { title = str(page_count(docctx())) })
        \\  let later = place_on!(page, Label { title = "Later" })
        \\  let extra = new_page(docctx(), "Second")
        \\end
    );
    defer state.deinit();
    try compiler.analysis.analyzeDocumentState(testing.allocator, &state);
    try allocation_testing.checkAllAllocationFailures(testing.allocator, buildDisplayGraph, .{&state});
    var graph = (try compiler.analysis.analyzeDocumentStateWithMode(testing.allocator, &state, .evaluation)).?;
    defer graph.deinit();
    try compiler.lowering.evaluateDocument(&state, &graph, .{ .io = testing.io });
    const roots = state.placementRootsOf(state.graph.page_order.items[0]);
    try testing.expectEqual(@as(usize, 2), roots.len);
    try testing.expect(roots[0] > roots[1]);
    try testing.expectEqualStrings("2", core.nodeDisplayContent(state.getNode(state.childrenOf(roots[0]).?[0]).?));
    try testing.expectEqualStrings("Later", core.nodeDisplayContent(state.getNode(state.childrenOf(roots[1]).?[0]).?));
}

test "typed placement: generic displays run each concrete stage through the execution graph" {
    var state = try documentWithModules(
        \\import std:text/content as native
        \\type Wrapper<T> { value: T }
        \\fn display<T>(self: Placed<Wrapper<T>>) -> T = self.value.value
        \\page first
        \\  let text = native::Text { content = "Nested" }
        \\  let input = Wrapper<Wrapper<native::Text>> { value = Wrapper<native::Text> { value = text } }
        \\  place_on!(pagectx(), input)
        \\end
    );
    defer state.deinit();
    var graph = (try compiler.analysis.analyzeDocumentStateWithMode(testing.allocator, &state, .evaluation)).?;
    defer graph.deinit();
    try compiler.lowering.evaluateDocument(&state, &graph, .{ .io = testing.io });
    const root = state.placementRootsOf(state.graph.page_order.items[0])[0];
    const inner = state.childrenOf(root).?[0];
    const text = state.childrenOf(inner).?[0];
    try testing.expectEqualStrings("Nested", core.nodeDisplayContent(state.getNode(text).?));
    try testing.expectEqual(@as(usize, 1), state.getNode(root).?.placement.?.value.record.ty.arguments[0].arguments.len);
    try testing.expectEqual(core.native_display.Kind.text, state.getNode(text).?.placement.?.display.native);
}

test "paired placement: imported constructors preserve values defaults and concrete display plans" {
    var state = try documentWithModules(
        \\import ./tests/fixtures/typed-display/constructors as widgets
        \\fn default_prefix() -> String = "Caller: "
        \\fn invoke!(action: (String, String) -> Placed<widgets::Label>) -> Placed<widgets::Label>
        \\  return action("Indirect", "Callback: ")
        \\end
        \\page first
        \\  let value: widgets::Label = widgets::label("Value")
        \\  widgets::label("Discarded")
        \\  let first: Placed<widgets::Label> = widgets::label!(value.content)
        \\  let second = widgets::label!("Explicit", "Chosen: ")
        \\  let indirect = invoke!((content: String, prefix: String) |-> widgets::label!(content, prefix))
        \\  let nested = widgets::wrap(widgets::wrap(value))
        \\  let third = widgets::wrap!<widgets::Wrapper<widgets::Wrapper<widgets::Label>>>(nested)
        \\  let fourth = widgets::wrap!(nested)
        \\  let captured: String = fourth.value.content.content.content.content
        \\end
    );
    defer state.deinit();
    var graph = (try compiler.analysis.analyzeDocumentStateWithMode(testing.allocator, &state, .evaluation)).?;
    defer graph.deinit();
    try compiler.lowering.evaluateDocument(&state, &graph, .{ .io = testing.io });
    const page = state.graph.page_order.items[0];
    const roots = state.placementRootsOf(page);
    try testing.expectEqual(@as(usize, 5), roots.len);
    for ([_][]const u8{ "Module default: Value", "Chosen: Explicit", "Callback: Indirect", "Module default: Value", "Module default: Value" }, roots) |content, root| {
        var node = state.getNode(root).?;
        try testing.expectEqual(page, node.placement.?.page_id);
        while (state.childrenOf(node.id)) |children| {
            if (children.len == 0) break;
            try testing.expectEqual(@as(usize, 1), children.len);
            node = state.getNode(children[0]).?;
            try testing.expectEqual(page, node.placement.?.page_id);
        }
        try testing.expectEqualStrings(content, core.nodeDisplayContent(node));
        try testing.expectEqual(core.native_display.Kind.text, node.placement.?.display.native);
    }
    const first = state.getNode(roots[0]).?.placement.?;
    try testing.expectEqualStrings("Label", first.value.record.ty.class_name.?);
    try testing.expectEqualStrings("Module default: ", first.value.record.field("prefix").?.string);
    const third = state.getNode(roots[3]).?.placement.?;
    const fourth = state.getNode(roots[4]).?.placement.?;
    try testing.expect(Type.eql(third.value.record.ty, fourth.value.record.ty));
    try testing.expect(roots[3] != roots[4]);
    try testing.expect(state.childrenOf(roots[3]).?[0] != state.childrenOf(roots[4]).?[0]);
}

test "public placement: inferred explicit and forwarded type arguments preserve independent placements" {
    var state = try documentWithModules(
        \\import std:layout as layout
        \\import std:text as text_api
        \\type Label { title: String }
        \\fn display(self: Placed<Label>) -> text_api::Text
        \\  return text_api::Text { content = self.value.title ++ ":" ++ str(page_index(self.page)) }
        \\end
        \\fn forward!<T>(value: T) -> Placed<T>
        \\  return layout::place!<T>(value)
        \\end
        \\const shared: Label = Label { title = "Shared" }
        \\page first
        \\  let a: Placed<Label> = place!(shared)
        \\  let b: Placed<Label> = layout::place!<Label>(shared)
        \\  let alias = a
        \\  ~ b.left == alias.right + 24
        \\  let plain: Placed<text_api::Text> = place!(text_api::Text { content = "Native" })
        \\end
        \\page second
        \\  let c: Placed<Label> = forward!(shared)
        \\  let selection: Selection<Placed<Label>> = select<Label>(pagectx())
        \\  let title: String = first(selection).value.title
        \\end
    );
    defer state.deinit();
    var graph = (try compiler.analysis.analyzeDocumentStateWithMode(testing.allocator, &state, .evaluation)).?;
    defer graph.deinit();
    try compiler.lowering.evaluateDocument(&state, &graph, .{ .io = testing.io });
    const pages = state.graph.page_order.items;
    try testing.expectEqual(@as(usize, 2), pages.len);
    const first = state.placementRootsOf(pages[0]);
    const second = state.placementRootsOf(pages[1]);
    try testing.expectEqual(@as(usize, 3), first.len);
    try testing.expectEqual(@as(usize, 1), second.len);
    try testing.expect(first[0] != first[1]);
    try testing.expect(first[0] != second[0]);
    for (first[0..2]) |root| {
        const placement = state.getNode(root).?.placement.?;
        try testing.expectEqual(pages[0], placement.page_id);
        try testing.expectEqualStrings("Shared", placement.value.record.field("title").?.string);
        const child = state.childrenOf(root).?[0];
        try testing.expectEqualStrings("Shared:1", core.nodeDisplayContent(state.getNode(child).?));
    }
    try testing.expectEqualStrings("Native", core.nodeDisplayContent(state.getNode(first[2]).?));
    const child = state.childrenOf(second[0]).?[0];
    try testing.expectEqual(pages[1], state.getNode(second[0]).?.placement.?.page_id);
    try testing.expectEqualStrings("Shared:2", core.nodeDisplayContent(state.getNode(child).?));
    const relation = state.constraints.active.items[0];
    try testing.expectEqual(first[1], relation.target_node);
    try testing.expectEqual(first[0], relation.source.node.node_id);
}

test "public placement: non-displayable values and placed references fail before evaluation" {
    for ([_][]const u8{
        "place!(42)",
        "place!(Settings {})",
        "place!(place!(text_api::Text { content = \"Twice\" }))",
        "layout::place!<Number>(text_api::Text { content = \"Mismatch\" })",
        "place!(new(\"Legacy\", \"body\", \"text\"))",
        "place!(nothing())",
    }) |expression| {
        const source = try std.fmt.allocPrint(testing.allocator,
            \\import std:text as text_api
            \\import std:layout as layout
            \\type Settings {{}}
            \\fn nothing() -> Void
            \\end
            \\page main
            \\  {s}
            \\end
        , .{expression});
        defer testing.allocator.free(source);
        var state = try documentWithModules(source);
        defer state.deinit();
        if (compiler.analysis.analyzeDocumentStateWithMode(testing.allocator, &state, .evaluation)) |result| {
            var graph = result.?;
            graph.deinit();
            return error.ExpectedInvalidPlacement;
        } else |_| {}
        try testing.expect(state.diagnostics.entries.items.len != 0);
        for (state.graph.page_order.items) |page| try testing.expectEqual(@as(usize, 0), state.placementRootsOf(page).len);
    }
}
