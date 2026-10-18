const std = @import("std");
const core = @import("core");
const ast = @import("ast");
const Type = ast.Type;
const contracts = @import("compiler").evaluation_contracts;
const eval_value = @import("compiler").evaluation_values;
const testing = std.testing;

test "runtime contracts: nominal values retain all applied type arguments" {
    const allocator = testing.allocator;
    var number_box = try Type.recordType("Box").inModule(1).withArguments(allocator, &.{Type.number});
    defer number_box.deinit(allocator);
    var string_box = try Type.recordType("Box").inModule(1).withArguments(allocator, &.{Type.string});
    defer string_box.deinit(allocator);
    var nested = try Type.recordType("Box").inModule(1).withArguments(allocator, &.{number_box});
    defer nested.deinit(allocator);
    var other_nested = try Type.recordType("Box").inModule(1).withArguments(allocator, &.{string_box});
    defer other_nested.deinit(allocator);
    var optional = try Type.optional(allocator, nested);
    defer optional.deinit(allocator);
    var other_optional = try Type.optional(allocator, other_nested);
    defer other_optional.deinit(allocator);
    var value = core.Value{ .record = .init(try nested.clone(allocator)) };
    defer value.deinit(allocator);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const state_allocator = arena.allocator();
    var state = try core.DocumentState.init(
        state_allocator,
        try state_allocator.dupe(u8, "."),
        try state_allocator.dupe(u8, "contracts.ss"),
        try state_allocator.dupe(u8, ""),
        ast.Module.init(),
    );
    defer state.deinit();
    try testing.expect(contracts.valueConformsToType(&state, value, nested));
    try testing.expect(contracts.valueConformsToType(&state, value, optional));
    try testing.expect(!contracts.valueConformsToType(&state, value, other_nested));
    try testing.expect(!contracts.valueConformsToType(&state, value, other_optional));
    try testing.expect(!contracts.valueConformsToType(&state, value, number_box));
    try testing.expect(!contracts.valueConformsToType(&state, value, Type.recordType("Box").inModule(1)));
    try testing.expect(!contracts.valueConformsToType(&state, value, nested.inModule(2)));
}

test "runtime contracts: placement references validate the complete registered input type" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const storage = arena.allocator();
    var state = try core.DocumentState.init(storage, try storage.dupe(u8, "."), try storage.dupe(u8, "placements.ss"), try storage.dupe(u8, ""), ast.Module.init());
    defer state.deinit();
    const page = try state.addPage("Page");
    var input_type = try Type.recordType("Box").inModule(1).withArguments(allocator, &.{Type.number});
    defer input_type.deinit(allocator);
    var expected = try Type.placedOf(allocator, input_type);
    defer expected.deinit(allocator);
    var different = try Type.placedOf(allocator, input_type.inModule(2));
    defer different.deinit(allocator);
    var value = core.Value{ .record = .init(try input_type.clone(allocator)) };
    defer value.deinit(allocator);
    const placed = core.Value{ .object = try state.registerPlacement(page, value, null) };
    var read = try eval_value.placementMember(&state, placed.object, "value");
    defer read.deinit(storage);
    try testing.expect(Type.eql(input_type, read.record.ty));
    try read.record.fields.append(storage, .{ .name = "new", .value = .{ .number = 4 } });
    try testing.expectEqual(@as(usize, 0), state.getNode(placed.object).?.placement.?.value.record.fields.items.len);
    const owner = try eval_value.placementMember(&state, placed.object, "page");
    try testing.expectEqual(page, owner.page);
    const document = try eval_value.placementMember(&state, placed.object, "document");
    try testing.expectEqual(state.graph.document_id, document.document);
    const anchor = try eval_value.placementMember(&state, placed.object, "right");
    try testing.expectEqual(placed.object, anchor.anchor.node.node_id);
    try testing.expectEqual(core.Anchor.right, anchor.anchor.node.anchor);
    try testing.expectError(error.UnknownField, eval_value.placementMember(&state, placed.object, "content"));
    const legacy = core.Value{ .object = try state.makeObject(page, "old", .text, .text, "Text") };
    try testing.expect(contracts.valueConformsToType(&state, placed, expected));
    try testing.expect(contracts.valueConformsToType(&state, placed, Type.placement));
    try testing.expect(!contracts.valueConformsToType(&state, placed, different));
    try testing.expect(!contracts.valueConformsToType(&state, value, expected));
    try testing.expect(!contracts.valueConformsToType(&state, legacy, expected));
    try testing.expect(!contracts.valueConformsToType(&state, legacy, Type.placement));
    try testing.expect(!contracts.valueConformsToType(&state, .{ .object = 999 }, Type.placement));
    var selected = core.Value{ .selection = .init(.object, "placements") };
    defer selected.deinit(allocator);
    try selected.selection.ids.append(allocator, placed.object);
    var selection_type = try Type.selectionOf(allocator, expected);
    defer selection_type.deinit(allocator);
    try testing.expect(contracts.valueConformsToType(&state, selected, selection_type));
    try testing.expect(contracts.valueConformsToType(&state, selected, Type.selection(.placement)));
    try selected.selection.ids.append(allocator, legacy.object);
    try testing.expect(!contracts.valueConformsToType(&state, selected, selection_type));
    try testing.expect(!contracts.valueConformsToType(&state, selected, Type.selection(.placement)));
}

test "runtime contracts: unresolved names reject values even inside optional and generic types" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const storage = arena.allocator();
    var state = try core.DocumentState.init(storage, try storage.dupe(u8, "."), try storage.dupe(u8, "unresolved.ss"), try storage.dupe(u8, ""), ast.Module.init());
    defer state.deinit();
    const name = Type.unresolvedNameAt("Missing", .{ .start = 0, .end = 7 });
    var optional = try Type.optional(allocator, name);
    defer optional.deinit(allocator);
    var generic = try Type.recordType("Box").inModule(0).withArguments(allocator, &.{name});
    defer generic.deinit(allocator);
    var value = core.Value{ .record = .init(try generic.clone(allocator)) };
    defer value.deinit(allocator);
    try testing.expect(!contracts.valueConformsToType(&state, .{ .string = "value" }, name));
    try testing.expect(!contracts.valueConformsToType(&state, .none, optional));
    try testing.expect(!contracts.valueConformsToType(&state, value, generic));
}
