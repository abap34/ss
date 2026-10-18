const std = @import("std");
const allocation_testing = @import("allocation_testing");
const ast = @import("ast");
const core = @import("core");
const utils = @import("utils");

const testing = std.testing;

fn initEmptyDocumentState() !core.DocumentState {
    return initEmptyDocumentStateWithAllocator(testing.allocator);
}

fn initEmptyDocumentStateWithAllocator(allocator: std.mem.Allocator) !core.DocumentState {
    const asset_base_dir = try allocator.dupe(u8, ".");
    errdefer allocator.free(asset_base_dir);
    const project_path = try allocator.dupe(u8, "unit-test.ss");
    errdefer allocator.free(project_path);
    const project_source = try allocator.dupe(u8, "");
    errdefer allocator.free(project_source);
    return try core.DocumentState.init(allocator, asset_base_dir, project_path, project_source, ast.Module.init());
}

test "document state spec: initialization preserves ownership on allocation failure" {
    try allocation_testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(allocator: std.mem.Allocator) !void {
            var state = try initEmptyDocumentStateWithAllocator(allocator);
            defer state.deinit();
        }
    }.run, .{});
}

fn appendSparseSourceModule(state: *core.DocumentState, id: core.SourceModuleId) !void {
    const spec = try testing.allocator.dupe(u8, "sparse-module");
    errdefer testing.allocator.free(spec);
    const source = try testing.allocator.dupe(u8, "");
    errdefer testing.allocator.free(source);
    const line_index = try utils.source.LineIndex.init(testing.allocator, source);
    errdefer line_index.deinit(testing.allocator);
    try state.modules.entries.append(testing.allocator, .{
        .id = id,
        .kind = .library,
        .spec = spec,
        .path = null,
        .source = source,
        .line_index = line_index,
        .syntax = ast.Module.init(),
        .implicit_import_ids = .empty,
        .resolved_import_ids = .empty,
    });
}

fn expectConstraint(
    state: *const core.DocumentState,
    target_node: core.NodeId,
    target_anchor: core.Anchor,
    role: core.ConstraintRole,
    from_update: bool,
) !void {
    for (state.constraints.active.items) |constraint| {
        if (constraint.target_node != target_node or constraint.target_anchor != target_anchor) continue;
        if (constraint.role != role or constraint.from_update != from_update) continue;
        return;
    }
    return error.TestExpectedConstraint;
}

test "document state spec: module lookup supports indexed and sparse identifiers" {
    var state = try initEmptyDocumentState();
    defer state.deinit();

    try testing.expectEqual(state.modules.project_id, state.moduleById(state.modules.project_id).?.id);

    const sparse_id: core.SourceModuleId = 7;
    try appendSparseSourceModule(&state, sparse_id);

    try testing.expectEqual(sparse_id, state.moduleById(sparse_id).?.id);
    try testing.expectEqual(sparse_id, state.moduleByIdMutable(sparse_id).?.id);
    try testing.expectEqual(@as(?*const core.SourceModule, null), state.moduleById(1));
    try testing.expectEqual(@as(?*core.SourceModule, null), state.moduleByIdMutable(1));
}

test "document state spec: constraint failure recording preserves allocation failures" {
    var state = try initEmptyDocumentState();
    defer state.deinit();

    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });

    const constraint = core.Constraint{
        .target_node = state.graph.document_id,
        .target_anchor = .left,
        .source = .{ .page = .left },
        .offset = 0,
    };
    try testing.expectError(
        error.OutOfMemory,
        state.diagnostics.noteConstraintFailureDetailed(failing.allocator(), state.graph.document_id, constraint, null, .conflict, .anchor_value_conflict, null, null, null),
    );
    try testing.expect(!state.diagnostics.hasConstraintFailures());
}

test "document state spec: pages are ordered document children with one-based page indexes" {
    var state = try initEmptyDocumentState();
    defer state.deinit();

    const first = try state.addPage("First");
    const second = try state.addPage("Second");

    try testing.expectEqual(@as(usize, 2), state.pageCount());
    try testing.expectEqual(first, state.graph.page_order.items[0]);
    try testing.expectEqual(second, state.graph.page_order.items[1]);
    try testing.expectEqual(@as(usize, 1), state.pageIndexOf(first));
    try testing.expectEqual(@as(usize, 2), state.pageIndexOf(second));

    const document_children = state.childrenOf(state.graph.document_id).?;
    try testing.expectEqual(@as(usize, 2), document_children.len);
    try testing.expectEqual(first, document_children[0]);
    try testing.expectEqual(second, document_children[1]);
}

fn placementInput(allocator: std.mem.Allocator) !core.Value {
    const ty = try ast.Type.recordType("Labeled").inModule(7).withArguments(allocator, &.{ast.Type.number});
    var record = core.RecordValue.init(ty);
    errdefer record.deinit(allocator);
    try record.fields.append(allocator, .{ .name = "label", .value = .{ .string = "Count" } });
    try record.fields.append(allocator, .{ .name = "value", .value = .{ .number = 3 } });
    return .{ .record = record };
}

test "document state spec: repeated input registration creates independent placements before display" {
    var state = try initEmptyDocumentState();
    defer state.deinit();
    const first_page = try state.addPage("First");
    const second_page = try state.addPage("Second");
    const ids = blk: {
        var input = try placementInput(testing.allocator);
        defer input.deinit(testing.allocator);
        break :blk [_]core.NodeId{
            try state.registerPlacement(first_page, input, null),
            try state.registerPlacement(first_page, input, null),
            try state.registerPlacement(second_page, input, null),
        };
    };

    try testing.expect(ids[0] != ids[1] and ids[1] != ids[2]);
    try testing.expectEqualSlices(core.NodeId, ids[0..2], state.placementRootsOf(first_page));
    try testing.expectEqualSlices(core.NodeId, ids[2..], state.placementRootsOf(second_page));
    for (ids, [_]core.NodeId{ first_page, first_page, second_page }) |id, page_id| {
        const node = state.getNode(id).?;
        const input = node.placement.?.value.record;
        try testing.expectEqual(@as(?u32, 7), input.ty.nominal_module_id);
        try testing.expectEqualStrings("Labeled", input.ty.class_name.?);
        try testing.expectEqual(ast.Type.Kind.number, input.ty.arguments[0].kind);
        try testing.expectEqualStrings("Count", input.field("label").?.string);
        try testing.expectEqual(@as(f32, 3), input.field("value").?.number);
        try testing.expectEqual(page_id, node.placement.?.parent_id);
        try testing.expectEqual(page_id, state.parentPageOf(id).?);
        try testing.expectEqual(page_id, state.layoutPageOf(id).?);
        try testing.expect(node.payload_kind == null and node.object_kind == null);
        try testing.expect(node.content == null);
    }
}

test "document state spec: placement children have one direct parent and inherit page ownership" {
    var state = try initEmptyDocumentState();
    defer state.deinit();
    const page = try state.addPage("Page");
    var input = try placementInput(testing.allocator);
    defer input.deinit(testing.allocator);
    const parent = try state.registerPlacement(page, input, null);
    const first = try state.registerPlacement(parent, input, null);
    const second = try state.registerPlacement(parent, input, null);
    const grandchild = try state.registerPlacement(first, input, null);

    try testing.expectEqualSlices(core.NodeId, &.{parent}, state.childrenOf(page).?);
    try testing.expectEqualSlices(core.NodeId, &.{parent}, state.placementRootsOf(page));
    try testing.expectEqualSlices(core.NodeId, &.{ first, second }, state.childrenOf(parent).?);
    try testing.expectEqualSlices(core.NodeId, &.{grandchild}, state.childrenOf(first).?);
    for ([_]core.NodeId{ parent, first, second, grandchild }) |id| {
        try testing.expectEqual(page, state.parentPageOf(id).?);
        try testing.expectEqual(page, state.layoutPageOf(id).?);
    }
    try testing.expectEqual(first, state.getNode(grandchild).?.placement.?.parent_id);
    try state.validatePageLocalLayout();
    try testing.expectEqual(@as(usize, 0), state.diagnostics.entries.items.len);

    try state.addContainment(parent, first);
    try testing.expectEqualSlices(core.NodeId, &.{ first, second }, state.childrenOf(parent).?);
    try testing.expectError(error.DuplicateObjectParent, state.addContainment(second, first));
    try testing.expectError(error.DuplicateObjectParent, state.addContainment(page, first));
    try testing.expectError(error.DuplicatePlacement, state.placeObjectOnPage(page, parent));
}

test "document state spec: registration order does not reorder authored placement roots or display children" {
    var state = try initEmptyDocumentState();
    defer state.deinit();
    const page = try state.addPage("Page");
    var input = try placementInput(testing.allocator);
    defer input.deinit(testing.allocator);
    state.graph.composition_cursor = .{ .source_order = 30 };
    const last = try state.registerPlacement(page, input, null);
    state.graph.composition_cursor = .{ .source_order = 10 };
    const first = try state.registerPlacement(page, input, null);
    const next = try state.registerPlacement(page, input, null);
    try testing.expectEqualSlices(core.NodeId, &.{ first, next, last }, state.placementRootsOf(page));
    try testing.expectEqualSlices(core.NodeId, &.{ first, next, last }, state.childrenOf(page).?);

    state.graph.composition_cursor = .{ .source_order = 90 };
    const first_child = try state.registerPlacement(first, input, null);
    state.graph.composition_cursor = .{ .source_order = 5 };
    const next_child = try state.registerPlacement(first, input, null);
    try testing.expectEqualSlices(core.NodeId, &.{ first_child, next_child }, state.childrenOf(first).?);
    try testing.expectEqual(@as(usize, 0), state.graph.composition_cursor.?.sequence);
}

test "document state spec: registration rejects invalid parents without allocating a placement" {
    var state = try initEmptyDocumentState();
    defer state.deinit();
    const page = try state.addPage("Page");
    const legacy = try state.makeObject(page, "legacy", .text, .text, "Legacy");
    const count = state.nodeCount();
    var input = try placementInput(testing.allocator);
    defer input.deinit(testing.allocator);
    try testing.expectError(error.UnknownNode, state.registerPlacement(999, input, null));
    try testing.expectError(error.InvalidPlacementParent, state.registerPlacement(state.graph.document_id, input, null));
    try testing.expectError(error.InvalidPlacementParent, state.registerPlacement(legacy, input, null));
    try testing.expectError(error.InvalidValueTag, state.registerPlacement(page, .void, null));
    try testing.expectEqual(count, state.nodeCount());
}

fn exercisePlacementRegistration(allocator: std.mem.Allocator) !void {
    var state = try initEmptyDocumentStateWithAllocator(allocator);
    defer state.deinit();
    const page = try state.addPage("Page");
    var input = try placementInput(allocator);
    defer input.deinit(allocator);
    var parent = page;
    for (0..4) |index| {
        state.graph.composition_cursor = .{ .source_order = index };
        const count = state.nodeCount();
        const next_id = state.graph.next_id;
        const ownership_count = state.graph.direct_page_ownership.items.len;
        const children_count = if (state.childrenOf(parent)) |children| children.len else 0;
        const roots_count = state.placementRootsOf(page).len;
        const id = state.registerPlacement(parent, input, .{ .path = "input.ss", .label = "item" }) catch |err| {
            try testing.expectEqual(count, state.nodeCount());
            try testing.expectEqual(next_id, state.graph.next_id);
            try testing.expectEqual(ownership_count, state.graph.direct_page_ownership.items.len);
            try testing.expectEqual(children_count, if (state.childrenOf(parent)) |children| children.len else @as(usize, 0));
            try testing.expectEqual(roots_count, state.placementRootsOf(page).len);
            try testing.expectEqual(@as(usize, 0), state.graph.composition_cursor.?.sequence);
            return err;
        };
        try testing.expectEqualStrings("input.ss", state.getNode(id).?.origin.?.path.?);
        if (index == 1) parent = id;
    }
}

test "document state spec: placement registration preserves ownership and graph on allocation failure" {
    try allocation_testing.checkAllAllocationFailures(testing.allocator, exercisePlacementRegistration, .{});
}

test "document state spec: containment is idempotent for the same parent-child pair" {
    var state = try initEmptyDocumentState();
    defer state.deinit();

    const page = try state.addPage("Page");
    const object = try state.makeObject(page, "title", .text, .text, "Hello");
    try state.addContainment(page, object);
    try state.addContainment(page, object);

    const children = state.childrenOf(page).?;
    try testing.expectEqual(@as(usize, 1), children.len);
    try testing.expectEqual(object, children[0]);
    try testing.expectEqual(page, state.parentPageOf(object).?);
    try testing.expectEqual(page, state.layoutPageOf(object).?);
}

test "document state spec: page-local validation reports duplicate page ownership" {
    var state = try initEmptyDocumentState();
    defer state.deinit();

    const first = try state.addPage("First");
    const second = try state.addPage("Second");
    const object = try state.makeObject(first, "title", .text, .text, "Hello");
    try state.addContainment(second, object);

    try state.validatePageLocalLayout();

    try testing.expectEqual(first, state.parentPageOf(object).?);
    try testing.expectEqual(@as(?core.NodeId, null), state.layoutPageOf(object));
    try expectDiagnosticCode(&state, "PageOwnershipConflict:");
}

test "document state spec: indirect group containment does not assign a page until placement" {
    var state = try initEmptyDocumentState();
    defer state.deinit();

    const page = try state.addPage("Page");
    const child = try state.createObjectWithOrigin("child", .text, .text, "Child", null);
    const group = try state.createGroupWithOrigin(&.{child}, null);

    try testing.expectEqual(@as(?core.NodeId, null), state.parentPageOf(child));
    try testing.expectEqual(@as(?core.NodeId, null), state.layoutPageOf(child));

    try state.placeObjectOnPage(page, group);

    try testing.expectEqual(page, state.parentPageOf(group).?);
    try testing.expectEqual(page, state.layoutPageOf(group).?);
    try testing.expectEqual(page, state.parentPageOf(child).?);
    try testing.expectEqual(page, state.layoutPageOf(child).?);
}

test "document state spec: only groups inherit layout ownership from children" {
    var state = try initEmptyDocumentState();
    defer state.deinit();

    const page = try state.addPage("Page");
    const child = try state.makeObject(page, "child", .text, .text, "Child");
    const shape = try state.createObjectWithOrigin("shape", .overlay, .text, "", null);
    try state.addContainment(shape, child);
    const group = try state.createGroupWithOrigin(&.{child}, null);

    try testing.expectEqual(@as(?core.NodeId, null), state.layoutPageOf(shape));
    try testing.expectEqual(page, state.layoutPageOf(group).?);
}

test "document state spec: a group of placed objects infers layout ownership without placement" {
    var state = try initEmptyDocumentState();
    defer state.deinit();

    const page = try state.addPage("Page");
    const first = try state.createObjectWithOrigin("first", .text, .text, "First", null);
    const second = try state.createObjectWithOrigin("second", .text, .text, "Second", null);
    try state.placeObjectOnPage(page, first);
    try state.placeObjectOnPage(page, second);
    const group = try state.createGroupWithOrigin(&.{ first, second }, null);

    try testing.expectEqual(@as(usize, 0), state.constraints.active.items.len);
    try testing.expectEqual(page, state.layoutPageOf(group).?);
    try testing.expectEqual(@as(?core.NodeId, null), state.parentPageOf(group));
    try testing.expect(!state.getNode(group).?.attached);
    try testing.expectEqualSlices(core.NodeId, &.{ first, second }, state.placementRootsOf(page));
    try testing.expectEqualSlices(core.NodeId, &.{ first, second }, state.childrenOf(page).?);
    try testing.expectEqualSlices(core.NodeId, &.{ first, second }, state.childrenOf(group).?);

    try state.validatePageLocalLayout();
    try testing.expectEqual(@as(usize, 0), state.diagnostics.entries.items.len);
}

test "document state spec: nested groups can share placed children without changing ownership" {
    var state = try initEmptyDocumentState();
    defer state.deinit();

    const page = try state.addPage("Page");
    const first = try state.makeObject(page, "first", .text, .text, "First");
    const shared = try state.makeObject(page, "shared", .text, .text, "Shared");
    const last = try state.makeObject(page, "last", .text, .text, "Last");
    const left = try state.createGroupWithOrigin(&.{ first, shared }, null);
    const right = try state.createGroupWithOrigin(&.{ shared, last }, null);
    const outer = try state.createGroupWithOrigin(&.{ left, right }, null);

    for ([_]core.NodeId{ left, right, outer }) |group| {
        try testing.expectEqual(page, state.layoutPageOf(group).?);
        try testing.expectEqual(@as(?core.NodeId, null), state.parentPageOf(group));
        try testing.expect(!state.getNode(group).?.attached);
    }
    try testing.expectEqual(page, state.parentPageOf(shared).?);
    try testing.expectEqual(page, state.layoutPageOf(shared).?);
    try testing.expectEqualSlices(core.NodeId, &.{ first, shared }, state.childrenOf(left).?);
    try testing.expectEqualSlices(core.NodeId, &.{ shared, last }, state.childrenOf(right).?);
    try state.validatePageLocalLayout();
    try testing.expectEqual(@as(usize, 0), state.diagnostics.entries.items.len);
}

test "document state spec: group inference requires every live child to have a page" {
    var state = try initEmptyDocumentState();
    defer state.deinit();

    const page = try state.addPage("Page");
    const placed = try state.makeObject(page, "placed", .text, .text, "Placed");
    const unplaced = try state.createObjectWithOrigin("unplaced", .text, .text, "Unplaced", null);
    const partial = try state.createGroupWithOrigin(&.{ placed, unplaced }, null);
    const outer = try state.createGroupWithOrigin(&.{ placed, partial }, null);
    const empty = try state.createGroupWithOrigin(&.{}, null);

    for ([_]core.NodeId{ partial, outer, empty }) |group| {
        try testing.expectEqual(@as(?core.NodeId, null), state.layoutPageOf(group));
        try testing.expectEqual(@as(?core.NodeId, null), state.parentPageOf(group));
        try testing.expect(!state.getNode(group).?.attached);
    }
    try state.validatePageLocalLayout();
    try expectNoDiagnosticCode(&state, "UnplacedObject");

    try state.placeObjectOnPage(page, unplaced);
    try testing.expectEqual(page, state.layoutPageOf(partial).?);
    try testing.expectEqual(page, state.layoutPageOf(outer).?);
    try testing.expect(!state.getNode(partial).?.attached);
    try testing.expect(!state.getNode(outer).?.attached);
}

test "document state spec: discarded children do not prevent group page inference" {
    var state = try initEmptyDocumentState();
    defer state.deinit();

    const page = try state.addPage("Page");
    const placed = try state.makeObject(page, "placed", .text, .text, "Placed");
    const unused = try state.createObjectWithOrigin("unused", .text, .text, "Unused", null);
    const group = try state.createGroupWithOrigin(&.{ placed, unused }, null);
    try state.discardObjectSubtree(unused);
    try testing.expectEqual(page, state.layoutPageOf(group).?);
    try testing.expect(!state.getNode(group).?.attached);
    try state.validatePageLocalLayout();
    try testing.expectEqual(@as(usize, 0), state.diagnostics.entries.items.len);
}

test "document state spec: ambiguous nested groups cannot inherit a sibling page" {
    var state = try initEmptyDocumentState();
    defer state.deinit();

    const first_page = try state.addPage("First");
    const second_page = try state.addPage("Second");
    const first = try state.makeObject(first_page, "first", .text, .text, "First");
    const second = try state.makeObject(second_page, "second", .text, .text, "Second");
    const mixed = try state.createGroupWithOrigin(&.{ first, second }, null);
    const before = try state.createGroupWithOrigin(&.{ first, mixed }, null);
    const after = try state.createGroupWithOrigin(&.{ mixed, first }, null);

    for ([_]core.NodeId{ mixed, before, after }) |group| {
        try testing.expectEqual(@as(?core.NodeId, null), state.layoutPageOf(group));
    }

    const duplicate = try state.makeObject(first_page, "duplicate", .text, .text, "Duplicate");
    try state.addContainment(second_page, duplicate);
    const ambiguous = try state.createGroupWithOrigin(&.{ first, duplicate }, null);
    try testing.expectEqual(@as(?core.NodeId, null), state.layoutPageOf(ambiguous));
    try state.validatePageLocalLayout();
    try expectNoDiagnosticCode(&state, "UnplacedObject");
    try expectDiagnosticCode(&state, "PageOwnershipConflict");
}

test "document state spec: cyclic group containment cannot infer page ownership" {
    var state = try initEmptyDocumentState();
    defer state.deinit();

    const page = try state.addPage("Page");
    const child = try state.makeObject(page, "child", .text, .text, "Child");
    const first = try state.createGroupWithOrigin(&.{child}, null);
    const second = try state.createGroupWithOrigin(&.{first}, null);
    try state.addContainment(first, second);

    try testing.expectEqual(@as(?core.NodeId, null), state.layoutPageOf(first));
    try testing.expectEqual(@as(?core.NodeId, null), state.layoutPageOf(second));
    try testing.expectEqual(page, state.layoutPageOf(child).?);
}

test "document state spec: page placement records roots without flattening groups or duplicating objects" {
    var state = try initEmptyDocumentState();
    defer state.deinit();

    const page = try state.addPage("Page");
    const first_child = try state.createObjectWithOrigin("first", .text, .text, "First", null);
    const second_child = try state.createObjectWithOrigin("second", .text, .text, "Second", null);
    const group = try state.createGroupWithOrigin(&.{ first_child, second_child }, null);
    const label = try state.createObjectWithOrigin("label", .text, .text, "Label", null);

    try state.placeObjectOnPage(page, group);
    try state.placeObjectOnPage(page, label);
    try testing.expectError(error.DuplicatePlacement, state.placeObjectOnPage(page, label));
    try state.markReturnedObjectOrigins(label, state.nodeCount(), .{ .label = "label-return" });

    const placement_roots = state.placementRootsOf(page);
    try testing.expectEqualSlices(core.NodeId, &.{ group, label }, placement_roots);

    const page_objects = state.childrenOf(page).?;
    try testing.expectEqualSlices(core.NodeId, &.{ group, first_child, second_child, label }, page_objects);
}

test "document state spec: page-local validation reports cross-page constraints" {
    var state = try initEmptyDocumentState();
    defer state.deinit();

    const first = try state.addPage("First");
    const second = try state.addPage("Second");
    const target = try state.makeObject(first, "target", .text, .text, "Target");
    const source = try state.makeObject(second, "source", .text, .text, "Source");

    try state.constraints.addAnchor(state.allocator, target, .top, .{ .node = .{ .node_id = source, .anchor = .top } }, 0, .{ .label = "cross-page" });
    try state.validatePageLocalLayout();

    try expectDiagnosticCode(&state, "CrossPageConstraint:");
}

test "document state spec: page-local validation reports unowned layout objects" {
    var state = try initEmptyDocumentState();
    defer state.deinit();

    const page = try state.addPage("Page");
    const placed = try state.makeObject(page, "placed", .text, .text, "Placed");
    const helper = try state.createObjectWithOrigin("helper", .text, .text, "Helper", null);

    try state.constraints.addAnchor(state.allocator, placed, .top, .{ .node = .{ .node_id = helper, .anchor = .top } }, 0, .{ .label = "unowned" });
    try state.validatePageLocalLayout();

    try expectDiagnosticCode(&state, "UnownedLayoutObject:");
}

test "document state spec: position updates replace deeper constraints across anchors on the same axis" {
    var state = try initEmptyDocumentState();
    defer state.deinit();

    const page = try state.addPage("Page");
    const object = try state.makeObject(page, "item", .text, .text, "Item");
    try state.constraints.addAnchorAtScope(state.allocator, object, .center_x, .{ .page = .center_x }, 0, .{ .label = "component-center" }, 1);
    try state.constraints.addAnchorAtScope(state.allocator, object, .right, .{ .node = .{ .node_id = object, .anchor = .left } }, 240, .{ .label = "component-width" }, 1);
    try state.constraints.addUpdate(state.allocator, object, .left, .position, 0, .{ .page = .left }, 80, .{ .label = "page-left" });

    try core.constraint_updates.resolve(&state);

    try testing.expectEqual(@as(usize, 2), state.constraints.active.items.len);
    try testing.expectEqual(@as(usize, 1), state.constraints.overridden.items.len);
    try testing.expectEqual(core.Anchor.center_x, state.constraints.overridden.items[0].target_anchor);
    try testing.expectEqual(core.ConstraintRole.size, state.constraints.active.items[0].role);
    try testing.expectEqual(core.Anchor.left, state.constraints.active.items[1].target_anchor);
    try testing.expect(state.constraints.active.items[1].from_update);
}

test "document state spec: group position updates replace external placement of descendants" {
    var state = try initEmptyDocumentState();
    defer state.deinit();

    const page = try state.addPage("Page");
    const title = try state.makeObject(page, "title", .text, .text, "Title");
    const rule = try state.makeObject(page, "rule", .text, .text, "");
    const inner = try state.makeGroupWithOrigin(page, true, &.{ title, rule }, .{ .label = "inner-group" });
    const root = try state.makeGroupWithOrigin(page, true, &.{inner}, .{ .label = "root-group" });

    try state.constraints.addAnchorAtScope(state.allocator, title, .left, .{ .page = .left }, 72, .{ .label = "component-left" }, 1);
    try state.constraints.addAnchorAtScope(state.allocator, title, .top, .{ .page = .top }, -100, .{ .label = "component-top" }, 1);
    try state.constraints.addAnchorAtScope(state.allocator, title, .right, .{ .node = .{ .node_id = title, .anchor = .left } }, 240, .{ .label = "component-width" }, 1);
    try state.constraints.addAnchorAtScope(state.allocator, rule, .left, .{ .node = .{ .node_id = title, .anchor = .left } }, 0, .{ .label = "component-align" }, 1);
    try state.constraints.addAnchorAtScope(state.allocator, rule, .top, .{ .node = .{ .node_id = title, .anchor = .bottom } }, -30, .{ .label = "component-rule" }, 1);
    try state.constraints.addUpdate(state.allocator, root, .left, .position, 0, .{ .page = .left }, 180, .{ .label = "caller-left" });
    try state.constraints.addUpdate(state.allocator, root, .top, .position, 0, .{ .page = .top }, -140, .{ .label = "caller-top" });

    try core.constraint_updates.resolve(&state);

    try testing.expectEqual(@as(usize, 5), state.constraints.active.items.len);
    try testing.expectEqual(@as(usize, 2), state.constraints.overridden.items.len);
    try testing.expectEqualStrings("component-left", state.constraints.overridden.items[0].origin.?.label.?);
    try testing.expectEqualStrings("component-top", state.constraints.overridden.items[1].origin.?.label.?);
    try expectConstraint(&state, title, .right, .size, false);
    try expectConstraint(&state, rule, .left, .position, false);
    try expectConstraint(&state, rule, .top, .position, false);
    try expectConstraint(&state, root, .left, .position, true);
    try expectConstraint(&state, root, .top, .position, true);
}

test "document state spec: overlapping group and descendant updates use scope and source order" {
    var later_descendant = try initEmptyDocumentState();
    defer later_descendant.deinit();

    const first_page = try later_descendant.addPage("Page");
    const first_child = try later_descendant.makeObject(first_page, "child", .text, .text, "Child");
    const first_group = try later_descendant.makeGroupWithOrigin(first_page, true, &.{first_child}, .{ .label = "group" });
    try later_descendant.constraints.addUpdate(later_descendant.allocator, first_group, .left, .position, 0, .{ .page = .left }, 100, .{ .label = "group-first" });
    try later_descendant.constraints.addUpdate(later_descendant.allocator, first_child, .left, .position, 0, .{ .page = .left }, 160, .{ .label = "child-last" });

    try core.constraint_updates.resolve(&later_descendant);

    try testing.expect(!later_descendant.constraints.updates.items[0].active);
    try testing.expect(later_descendant.constraints.updates.items[1].active);
    try testing.expectEqual(@as(usize, 1), later_descendant.constraints.active.items.len);
    try testing.expectEqual(first_child, later_descendant.constraints.active.items[0].target_node);
    try testing.expectEqual(@as(usize, 1), later_descendant.constraints.overridden.items.len);

    var shallower_group = try initEmptyDocumentState();
    defer shallower_group.deinit();

    const second_page = try shallower_group.addPage("Page");
    const second_child = try shallower_group.makeObject(second_page, "child", .text, .text, "Child");
    const second_group = try shallower_group.makeGroupWithOrigin(second_page, true, &.{second_child}, .{ .label = "group" });
    try shallower_group.constraints.addUpdate(shallower_group.allocator, second_group, .left, .position, 0, .{ .page = .left }, 100, .{ .label = "caller-group" });
    try shallower_group.constraints.addUpdate(shallower_group.allocator, second_child, .left, .position, 1, .{ .page = .left }, 160, .{ .label = "component-child" });

    try core.constraint_updates.resolve(&shallower_group);

    try testing.expect(shallower_group.constraints.updates.items[0].active);
    try testing.expect(!shallower_group.constraints.updates.items[1].active);
    try testing.expectEqual(@as(usize, 1), shallower_group.constraints.active.items.len);
    try testing.expectEqual(second_group, shallower_group.constraints.active.items[0].target_node);
    try testing.expectEqual(@as(usize, 1), shallower_group.constraints.overridden.items.len);
}

test "document state spec: size updates preserve position constraints" {
    var state = try initEmptyDocumentState();
    defer state.deinit();

    const page = try state.addPage("Page");
    const object = try state.makeObject(page, "item", .text, .text, "Item");
    try state.constraints.addAnchorAtScope(state.allocator, object, .center_x, .{ .page = .center_x }, 0, .{ .label = "component-center" }, 1);
    try state.constraints.addAnchorAtScope(state.allocator, object, .right, .{ .node = .{ .node_id = object, .anchor = .left } }, 240, .{ .label = "component-width" }, 1);
    try state.constraints.addUpdate(
        state.allocator,
        object,
        .right,
        .size,
        0,
        .{ .node = .{ .node_id = object, .anchor = .left } },
        320,
        .{ .label = "page-width" },
    );

    try core.constraint_updates.resolve(&state);

    try testing.expectEqual(@as(usize, 2), state.constraints.active.items.len);
    try testing.expectEqual(core.ConstraintRole.position, state.constraints.active.items[0].role);
    try testing.expectEqual(core.ConstraintRole.size, state.constraints.active.items[1].role);
    try testing.expectEqual(@as(f32, 320), state.constraints.active.items[1].offset);
    try testing.expect(state.constraints.active.items[1].from_update);
    try testing.expectEqual(@as(usize, 1), state.constraints.overridden.items.len);
    try testing.expectEqual(@as(f32, 240), state.constraints.overridden.items[0].offset);
}

test "document state spec: pure updates suppress inherited constraints without adding a replacement" {
    var state = try initEmptyDocumentState();
    defer state.deinit();

    const page = try state.addPage("Page");
    const object = try state.makeObject(page, "item", .text, .text, "Item");
    try state.constraints.addAnchorAtScope(state.allocator, object, .top, .{ .page = .top }, -40, .{ .label = "component-top" }, 1);
    try state.constraints.addUpdate(state.allocator, object, .top, .position, 0, null, 0, .{ .label = "page-top" });

    try core.constraint_updates.resolve(&state);

    try testing.expectEqual(@as(usize, 0), state.constraints.active.items.len);
    try testing.expectEqual(@as(usize, 1), state.constraints.overridden.items.len);
    try testing.expect(state.constraints.updates.items[0].active);
}

test "document state spec: suppressed cross-page constraints are not diagnosed" {
    var state = try initEmptyDocumentState();
    defer state.deinit();

    const first = try state.addPage("First");
    const second = try state.addPage("Second");
    const target = try state.makeObject(first, "target", .text, .text, "Target");
    const source = try state.makeObject(second, "source", .text, .text, "Source");
    try state.constraints.addAnchorAtScope(state.allocator, target, .left, .{ .node = .{ .node_id = source, .anchor = .left } }, 0, .{ .label = "component-left" }, 1);
    try state.constraints.addUpdate(state.allocator, target, .left, .position, 0, null, 0, .{ .label = "page-left" });

    try core.constraint_updates.resolve(&state);
    try state.validatePageLocalLayout();

    for (state.diagnostics.entries.items) |diagnostic| {
        switch (diagnostic.data) {
            .user_report => |data| try testing.expect(!std.mem.eql(u8, data.code, "CrossPageConstraint")),
            else => {},
        }
    }
}

test "document state spec: caller updates have authority over deeper updates" {
    var state = try initEmptyDocumentState();
    defer state.deinit();

    const page = try state.addPage("Page");
    const object = try state.makeObject(page, "item", .text, .text, "Item");
    try state.constraints.addUpdate(state.allocator, object, .left, .position, 2, .{ .page = .left }, 20, .{ .label = "nested-left" });
    try state.constraints.addUpdate(state.allocator, object, .right, .position, 0, .{ .page = .right }, -60, .{ .label = "page-right" });
    try state.constraints.addUpdate(state.allocator, object, .center_x, .position, 1, .{ .page = .center_x }, 10, .{ .label = "component-center" });

    try core.constraint_updates.resolve(&state);

    try testing.expect(!state.constraints.updates.items[0].active);
    try testing.expect(state.constraints.updates.items[1].active);
    try testing.expect(!state.constraints.updates.items[2].active);
    try testing.expectEqual(@as(usize, 1), state.constraints.active.items.len);
    try testing.expectEqual(core.Anchor.right, state.constraints.active.items[0].target_anchor);
    try testing.expectEqual(@as(f32, -60), state.constraints.active.items[0].offset);
    try testing.expectEqual(@as(usize, 2), state.constraints.overridden.items.len);
}

test "document state spec: later updates replace earlier updates in the same scope" {
    var state = try initEmptyDocumentState();
    defer state.deinit();

    const page = try state.addPage("Page");
    const object = try state.makeObject(page, "item", .text, .text, "Item");
    try state.constraints.addAnchorAtScope(state.allocator, object, .center_x, .{ .page = .center_x }, 0, .{ .label = "component-center" }, 1);
    try state.constraints.addUpdate(state.allocator, object, .left, .position, 0, null, 0, .{ .label = "first" });
    try state.constraints.addUpdate(state.allocator, object, .right, .position, 0, .{ .page = .right }, -40, .{ .label = "second" });

    try core.constraint_updates.resolve(&state);

    try testing.expect(!state.constraints.updates.items[0].active);
    try testing.expect(state.constraints.updates.items[1].active);
    try testing.expectEqual(@as(usize, 1), state.constraints.active.items.len);
    try testing.expectEqual(core.Anchor.right, state.constraints.active.items[0].target_anchor);
    try testing.expectEqual(@as(f32, -40), state.constraints.active.items[0].offset);
    try testing.expectEqual(@as(usize, 1), state.constraints.overridden.items.len);
}

test "document state spec: later pure updates suppress earlier replacements" {
    var state = try initEmptyDocumentState();
    defer state.deinit();

    const page = try state.addPage("Page");
    const object = try state.makeObject(page, "item", .text, .text, "Item");
    try state.constraints.addAnchorAtScope(state.allocator, object, .center_x, .{ .page = .center_x }, 0, .{ .label = "component-center" }, 1);
    try state.constraints.addUpdate(state.allocator, object, .left, .position, 0, .{ .page = .left }, 40, .{ .label = "first" });
    try state.constraints.addUpdate(state.allocator, object, .right, .position, 0, null, 0, .{ .label = "second" });

    try core.constraint_updates.resolve(&state);

    try testing.expect(!state.constraints.updates.items[0].active);
    try testing.expect(state.constraints.updates.items[1].active);
    try testing.expectEqual(@as(usize, 0), state.constraints.active.items.len);
    try testing.expectEqual(@as(usize, 2), state.constraints.overridden.items.len);
    try testing.expect(state.constraints.overridden.items[1].from_update);
}

test "document state spec: prepared pages collect inline math asset dependencies" {
    var state = try initEmptyDocumentState();
    defer state.deinit();

    const page = try state.addPage("Page");
    _ = try state.makeObject(page, "body", .text, .text, "value $x+y$");

    var pages = try core.prepared.prepare(testing.allocator, &state);
    defer pages.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), pages.pages.len);
    try testing.expectEqual(@as(usize, 1), pages.pages[0].objects.len);
    const object = pages.pages[0].objects[0];
    try testing.expectEqual(@as(usize, 1), object.asset_deps.len);
    try testing.expectEqual(core.prepared.AssetDependency.Kind.inline_math, object.asset_deps[0].kind);
    try testing.expectEqualStrings("x+y", object.asset_deps[0].source);
}

test "document state spec: prepared pages preserve explicit LaTeX body dependencies" {
    var state = try initEmptyDocumentState();
    defer state.deinit();

    const page = try state.addPage("Page");
    const latex_object = try state.makeObject(page, "latex", .asset, .latex, "\\begin{center}$x+y$\\end{center}");
    try state.setNodeFieldValue(latex_object, "render_kind", .{ .enum_case = .{
        .enum_name = "RenderKind",
        .case_name = "latex",
    } });

    var pages = try core.prepared.prepare(testing.allocator, &state);
    defer pages.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), pages.pages.len);
    try testing.expectEqual(@as(usize, 1), pages.pages[0].objects.len);
    const object = pages.pages[0].objects[0];
    try testing.expectEqual(@as(usize, 1), object.asset_deps.len);
    try testing.expectEqual(core.prepared.AssetDependency.Kind.latex_body, object.asset_deps[0].kind);
    try testing.expectEqualStrings("\\begin{center}$x+y$\\end{center}", object.asset_deps[0].source);
}

test "document state spec: layout results collect solved page frames" {
    var state = try initEmptyDocumentState();
    defer state.deinit();

    const page = try state.addPage("Page");
    const object = try state.makeObject(page, "body", .text, .text, "Hello");
    try state.constraints.addAnchor(state.allocator, object, .left, .{ .page = .left }, 40, .{ .label = "body-left" });
    try state.constraints.addAnchor(state.allocator, object, .top, .{ .page = .top }, -80, .{ .label = "body-top" });

    var results = try core.layout.solveDocument(&state, null, .{});
    defer results.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), results.pages.len);
    try testing.expectEqual(page, results.pages[0].page_id);
    const result_frame = results.frameOf(page, object) orelse return error.MissingLayoutFrame;
    try testing.expect(result_frame.x_set);
    try testing.expect(result_frame.y_set);
    try testing.expectEqual(@as(f32, 40), result_frame.x);
    try testing.expectEqual(@as(f32, 640), result_frame.y + result_frame.height);
    try testing.expectEqual(@as(usize, 0), state.diagnostics.entries.items.len);
}

test "document state spec: layout results own page diagnostics" {
    var state = try initEmptyDocumentState();
    defer state.deinit();

    const page = try state.addPage("Page");
    const object = try state.makeObject(page, "body", .text, .text, "Hello");
    try state.constraints.addAnchor(state.allocator, object, .left, .{ .page = .left }, -40, .{ .label = "body-left" });
    try state.constraints.addAnchor(state.allocator, object, .top, .{ .page = .top }, -80, .{ .label = "body-top" });

    var results = try core.layout.solveDocument(&state, null, .{});
    defer results.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), results.pages.len);
    try testing.expect(results.pages[0].diagnostics.len > 0);
    try testing.expectEqual(@as(usize, 0), state.diagnostics.entries.items.len);
    try testing.expectEqual(core.DiagnosticPhase.layout, results.pages[0].diagnostics[0].phase);
}

test "document state spec: identical validation user reports are deduplicated" {
    var state = try initEmptyDocumentState();
    defer state.deinit();

    try addValidationUserReport(&state, .{ .path = "theme.ss", .span = .{ .start = 10, .end = 20 } }, "UnknownField: missing field");
    try addValidationUserReport(&state, .{ .path = "theme.ss", .span = .{ .start = 10, .end = 20 } }, "UnknownField: missing field");
    try addValidationUserReport(&state, .{ .path = "theme.ss", .span = .{ .start = 30, .end = 40 } }, "UnknownField: missing field");
    try addValidationUserReport(&state, .{ .path = "theme.ss", .span = .{ .start = 10, .end = 20 } }, "UnknownField: different field");

    try testing.expectEqual(@as(usize, 4), state.diagnostics.entries.items.len);
    state.diagnostics.deduplicateValidationUserReports(state.allocator);
    try testing.expectEqual(@as(usize, 3), state.diagnostics.entries.items.len);
    try testing.expect(state.diagnostics.entries.items[0].origin.?.eql(core.SourceOrigin.at("theme.ss", .{ .start = 10, .end = 20 })));
    try testing.expect(state.diagnostics.entries.items[1].origin.?.eql(core.SourceOrigin.at("theme.ss", .{ .start = 30, .end = 40 })));
    try testing.expect(state.diagnostics.entries.items[2].origin.?.eql(core.SourceOrigin.at("theme.ss", .{ .start = 10, .end = 20 })));
    try testing.expectEqualStrings("UnknownField: missing field", state.diagnostics.entries.items[0].data.user_report.message);
    try testing.expectEqualStrings("UnknownField: missing field", state.diagnostics.entries.items[1].data.user_report.message);
    try testing.expectEqualStrings("UnknownField: different field", state.diagnostics.entries.items[2].data.user_report.message);
}

test "document state spec: node fields reject duplicate keys" {
    var state = try initEmptyDocumentState();
    defer state.deinit();

    const page = try state.addPage("Page");
    const object = try state.makeObject(page, "shape", .overlay, .text, "");

    try state.setNodeFieldValue(object, "fill", .{ .string = "red" });
    try state.setNodeFieldValue(object, "stroke", .{ .string = "black" });
    try testing.expectError(error.DuplicatePropertyDefinition, state.setNodeFieldValue(object, "fill", .{ .string = "blue" }));

    const node = state.getNode(object).?;
    try testing.expectEqual(@as(usize, 2), node.fields.items.len);
    try testing.expectEqualStrings("red", state.getNodeField(object, "fill").?.string);
    try testing.expectEqualStrings("black", state.getNodeField(object, "stroke").?.string);
}

test "document state spec: node field writes retain their scope and origin" {
    var state = try initEmptyDocumentState();
    defer state.deinit();
    const group = try state.createGroupWithOrigin(&.{}, null);
    const origin = core.SourceOrigin.at("group.ss", .{ .start = 12, .end = 14 });
    try state.setNodeFieldValueWithOrigin(group, "align_children_y", .{ .boolean = true }, 3, origin);
    const field = state.getNode(group).?.fields.items[0];
    try testing.expectEqual(@as(u32, 3), field.scope_depth);
    try testing.expect(field.origin.?.eql(origin));
    try testing.expectError(error.DuplicatePropertyDefinition, state.setNodeFieldValueWithOrigin(group, "align_children_y", .{ .boolean = false }, 0, null));
    try testing.expect(state.getNode(group).?.fields.items[0].origin.?.eql(origin));
    try testing.expectError(error.DuplicatePropertyDefinition, state.setNodeFieldValue(group, "align_children_y", .none));
    try testing.expectEqual(@as(u32, 3), state.getNode(group).?.fields.items[0].scope_depth);
    try testing.expect(state.getNode(group).?.fields.items[0].origin.?.eql(origin));
}

test "document state spec: default group alignments connect consecutive children without placing the group" {
    var state = try initEmptyDocumentState();
    defer state.deinit();
    const page = try state.addPage("Page");
    const a = try state.makeObject(page, "a", .text, .text, "A");
    const b = try state.makeObject(page, "b", .text, .text, "B");
    const c = try state.makeObject(page, "c", .text, .text, "C");
    const group = try state.createGroupWithOrigin(&.{ a, b, c }, null);
    const origin = core.SourceOrigin.at("group.ss", .{ .start = 12, .end = 14 });
    try state.setNodeFieldValueWithOrigin(group, "align_children_y", .{ .boolean = true }, 2, origin);
    const page_child_count = state.childrenOf(page).?.len;
    const node_count = state.nodeCount();
    try state.collectDefaultAlignments();
    try state.collectDefaultAlignments();
    try testing.expectEqual(@as(usize, 2), state.constraints.active.items.len);
    for (state.constraints.active.items, [_]core.NodeId{ a, b }, [_]core.NodeId{ b, c }) |constraint, source, target| {
        try testing.expect(constraint.default_alignment);
        try testing.expectEqual(target, constraint.target_node);
        try testing.expectEqual(source, constraint.source.node.node_id);
        try testing.expectEqual(core.Anchor.top, constraint.target_anchor);
        try testing.expectEqual(core.Anchor.top, constraint.source.node.anchor);
        try testing.expectEqual(@as(f32, 0), constraint.offset);
        try testing.expectEqual(core.ConstraintRole.position, constraint.role);
        try testing.expectEqual(@as(u32, 2), constraint.scope_depth);
        try testing.expect(constraint.origin.?.eql(origin));
        try testing.expect(!constraint.from_update);
    }
    try testing.expect(!state.getNode(group).?.attached);
    try testing.expectEqual(page_child_count, state.childrenOf(page).?.len);
    try testing.expectEqual(node_count, state.nodeCount());
}

test "document state spec: default alignments skip discarded children and inactive groups" {
    var state = try initEmptyDocumentState();
    defer state.deinit();
    const page = try state.addPage("Page");
    const a = try state.makeObject(page, "a", .text, .text, "A");
    const ignored = try state.createObjectWithOrigin("ignored", .text, .text, "", null);
    try state.discardObjectSubtree(ignored);
    const b = try state.makeObject(page, "b", .text, .text, "B");
    const active = try state.createGroupWithOrigin(&.{ a, ignored, b }, null);
    try state.setNodeFieldValue(active, "align_children_y", .{ .boolean = true });
    const disabled = try state.createGroupWithOrigin(&.{ a, b }, null);
    try state.setNodeFieldValue(disabled, "align_children_y", .{ .boolean = false });
    _ = try state.createGroupWithOrigin(&.{ a, b }, null);
    const empty = try state.createGroupWithOrigin(&.{}, null);
    try state.setNodeFieldValue(empty, "align_children_y", .{ .boolean = true });
    const single = try state.createGroupWithOrigin(&.{a}, null);
    try state.setNodeFieldValue(single, "align_children_y", .{ .boolean = true });
    const discarded = try state.createGroupWithOrigin(&.{ignored}, null);
    try state.setNodeFieldValue(discarded, "align_children_y", .{ .boolean = true });
    try state.discardObjectSubtree(discarded);
    try state.setNodeFieldValue(a, "align_children_y", .{ .boolean = true });
    try state.collectDefaultAlignments();
    try testing.expectEqual(@as(usize, 1), state.constraints.active.items.len);
    try testing.expectEqual(a, state.constraints.active.items[0].source.node.node_id);
    try testing.expectEqual(b, state.constraints.active.items[0].target_node);
}

test "document state spec: an empty child group remains an ordinary alignment endpoint" {
    var state = try initEmptyDocumentState();
    defer state.deinit();
    const page = try state.addPage("Page");
    const a = try state.makeObject(page, "a", .text, .text, "A");
    const empty = try state.createGroupWithOrigin(&.{}, null);
    const b = try state.makeObject(page, "b", .text, .text, "B");
    const group = try state.createGroupWithOrigin(&.{ a, empty, b }, null);
    try state.setNodeFieldValue(group, "align_children_y", .{ .boolean = true });
    try state.collectDefaultAlignments();
    try testing.expectEqual(@as(usize, 2), state.constraints.active.items.len);
    try testing.expectEqual(empty, state.constraints.active.items[0].target_node);
    try testing.expectEqual(empty, state.constraints.active.items[1].source.node.node_id);
}

test "document state spec: updates mask default alignments without recreating candidates" {
    var state = try initEmptyDocumentState();
    defer state.deinit();
    const page = try state.addPage("Page");
    const a = try state.makeObject(page, "a", .text, .text, "A");
    const b = try state.makeObject(page, "b", .text, .text, "B");
    const group = try state.createGroupWithOrigin(&.{ a, b }, null);
    try state.setNodeFieldValueWithOrigin(group, "align_children_y", .{ .boolean = true }, 2, .{ .label = "group-default" });
    try state.constraints.addAnchorAtScope(state.allocator, b, .left, .{ .node = .{ .node_id = a, .anchor = .right } }, 32, null, 2);
    try state.constraints.addUpdate(state.allocator, b, .center_y, .position, 0, .{ .page = .center_y }, 10, .{ .label = "caller-update" });
    try state.collectDefaultAlignments();
    try core.constraint_updates.resolve(&state);
    try state.collectDefaultAlignments();
    try testing.expectEqual(@as(usize, 2), state.constraints.active.items.len);
    for (state.constraints.active.items) |constraint| try testing.expect(!constraint.default_alignment);
    try testing.expectEqual(@as(usize, 1), state.constraints.overridden.items.len);
    const overridden = state.constraints.overridden.items[0];
    try testing.expect(overridden.default_alignment);
    try testing.expectEqual(@as(u32, 2), overridden.scope_depth);
    try testing.expectEqualStrings("group-default", overridden.origin.?.label.?);
    try expectConstraint(&state, b, .left, .position, false);
    try expectConstraint(&state, b, .center_y, .position, true);
}

test "document state spec: default alignment collection is atomic on allocation failure" {
    for (0..2) |fail_index| {
        var state = try initEmptyDocumentState();
        defer state.deinit();
        const page = try state.addPage("Page");
        const a = try state.makeObject(page, "a", .text, .text, "A");
        const b = try state.makeObject(page, "b", .text, .text, "B");
        const group = try state.createGroupWithOrigin(&.{ a, b }, null);
        try state.setNodeFieldValue(group, "align_children_y", .{ .boolean = true });
        var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        const result = blk: {
            state.allocator = failing.allocator();
            defer state.allocator = testing.allocator;
            break :blk state.collectDefaultAlignments();
        };
        try testing.expectError(error.OutOfMemory, result);
        try testing.expectEqual(@as(usize, 0), state.constraints.active.items.len);
        try testing.expect(!state.constraints.default_alignments_collected);
        try state.collectDefaultAlignments();
        try testing.expectEqual(@as(usize, 1), state.constraints.active.items.len);
    }
}

test "document state spec: group split cuts carry source scope and survive only unmasked axes" {
    var state = try initEmptyDocumentState();
    defer state.deinit();
    const page = try state.addPage("Page");
    const a = try state.makeObject(page, "a", .text, .text, "A");
    const b = try state.makeObject(page, "b", .text, .text, "B");
    const group = try state.createGroupWithOrigin(&.{ a, b }, null);
    try state.setNodeFieldValueWithOrigin(group, "split_axis", .{ .string = "horizontal" }, 2, .{ .label = "split" });
    try state.setNodeFieldValue(group, "split_gap", .{ .number = 20 });
    try state.collectDefaultAlignments();
    try testing.expectEqual(@as(usize, 6), state.constraints.active.items.len);
    const cut = state.constraints.active.items[1];
    try testing.expectEqual(core.Anchor.right, cut.target_anchor);
    try testing.expectEqual(core.Anchor.center_x, cut.source.node.anchor);
    try testing.expectEqual(@as(f32, -10), cut.offset);
    for (state.constraints.active.items) |constraint| {
        try testing.expect(constraint.group_split);
        try testing.expectEqual(group, constraint.source.node.node_id);
        try testing.expectEqual(@as(u32, 2), constraint.scope_depth);
        try testing.expectEqualStrings("split", constraint.origin.?.label.?);
    }
    try state.constraints.addUpdate(state.allocator, b, .left, .position, 0, .{ .page = .left }, 200, null);
    try core.constraint_updates.resolve(&state);
    try state.collectDefaultAlignments();
    try testing.expectEqual(@as(usize, 2), state.constraints.overridden.items.len);
    for (state.constraints.overridden.items) |constraint| {
        try testing.expect(constraint.group_split);
        try testing.expectEqual(b, constraint.target_node);
    }
    for (state.constraints.active.items) |constraint| {
        if (constraint.target_node == b and constraint.group_split) try testing.expect(constraint.default_alignment);
    }
}

test "document state spec: n-ary cuts preserve fractional extents before update normalization" {
    var state = try initEmptyDocumentState();
    defer state.deinit();
    const page = try state.addPage("Page");
    const a = try state.makeObject(page, "a", .text, .text, "A");
    const b = try state.makeObject(page, "b", .text, .text, "B");
    const c = try state.makeObject(page, "c", .text, .text, "C");
    const group = try state.createGroupWithOrigin(&.{ a, b, c }, null);
    try state.setNodeFieldValueWithOrigin(group, "split_axis", .{ .string = "horizontal" }, 3, .{ .label = "ternary" });
    try state.setNodeFieldValue(group, "split_gap", .{ .number = 30 });
    try state.collectDefaultAlignments();
    try testing.expectEqual(@as(usize, 9), state.constraints.active.items.len);
    const cut = state.constraints.active.items[1];
    try testing.expectEqual(core.Anchor.right, cut.target_anchor);
    try testing.expectEqual(core.Anchor.left, cut.source.node.anchor);
    try testing.expectApproxEqAbs(@as(f32, 1.0 / 3.0), cut.source_extent_factor, 0.00001);
    try testing.expectApproxEqAbs(@as(f32, -20), cut.offset, 0.00001);
    try testing.expectEqual(@as(u32, 3), cut.scope_depth);
    try state.constraints.addUpdate(state.allocator, b, .left, .position, 0, .{ .page = .left }, 200, null);
    try core.constraint_updates.resolve(&state);
    try state.collectDefaultAlignments();
    try testing.expectEqual(@as(usize, 2), state.constraints.overridden.items.len);
    for (state.constraints.overridden.items) |constraint| {
        try testing.expect(constraint.source_extent_factor != 0);
        try testing.expectEqual(b, constraint.target_node);
    }
}

test "document state spec: group split collection is atomic on allocation failure" {
    for (0..2) |fail_index| {
        var state = try initEmptyDocumentState();
        defer state.deinit();
        const page = try state.addPage("Page");
        const a = try state.makeObject(page, "a", .text, .text, "A");
        const b = try state.makeObject(page, "b", .text, .text, "B");
        const group = try state.createGroupWithOrigin(&.{ a, b }, null);
        try state.setNodeFieldValue(group, "split_axis", .{ .string = "vertical" });
        var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        const result = blk: {
            state.allocator = failing.allocator();
            defer state.allocator = testing.allocator;
            break :blk state.collectDefaultAlignments();
        };
        try testing.expectError(error.OutOfMemory, result);
        try testing.expectEqual(@as(usize, 0), state.constraints.active.items.len);
        try testing.expect(!state.constraints.default_alignments_collected);
        try state.collectDefaultAlignments();
        try testing.expectEqual(@as(usize, 6), state.constraints.active.items.len);
    }
}

test "document state spec: invalid split settings report their group origin" {
    for ([_]f32{ -1, std.math.inf(f32), std.math.nan(f32) }) |gap| {
        var state = try initEmptyDocumentState();
        defer state.deinit();
        const a = try state.createObjectWithOrigin("a", .text, .text, "A", null);
        const b = try state.createObjectWithOrigin("b", .text, .text, "B", null);
        const group = try state.createGroupWithOrigin(&.{ a, b }, .{ .label = "split" });
        try state.setNodeFieldValue(group, "split_axis", .{ .string = "horizontal" });
        try state.setNodeFieldValue(group, "split_gap", .{ .number = gap });
        try testing.expectError(error.InvalidGroupSplit, state.collectDefaultAlignments());
        try testing.expectEqual(@as(usize, 0), state.constraints.active.items.len);
        try testing.expectEqualStrings("InvalidGroupSplit", state.diagnostics.entries.items[0].data.user_report.code);
        try testing.expectEqualStrings("split", state.diagnostics.entries.items[0].origin.?.label.?);
    }
}

test "document state spec: field writes release partial allocations before publication" {
    for (0..3) |fail_index| {
        var state = try initEmptyDocumentState();
        defer state.deinit();
        const group = try state.createGroupWithOrigin(&.{}, null);
        var value = core.ConstraintSet.init();
        defer value.deinit(testing.allocator);
        try value.items.append(testing.allocator, .{
            .target_node = group,
            .target_anchor = .top,
            .source = .{ .page = .top },
            .offset = 0,
        });
        var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        const result = blk: {
            state.allocator = failing.allocator();
            defer state.allocator = testing.allocator;
            break :blk state.setNodeFieldValueWithOrigin(group, "relations", .{ .constraints = value }, 2, .{ .label = "write" });
        };
        try testing.expectError(error.OutOfMemory, result);
        try testing.expectEqual(@as(usize, 0), state.getNode(group).?.fields.items.len);
        try state.setNodeFieldValue(group, "relations", .{ .constraints = value });
    }
}

fn addValidationUserReport(state: *core.DocumentState, origin: core.SourceOrigin, message: []const u8) !void {
    const owned_message = try testing.allocator.dupe(u8, message);
    try state.addValidationDiagnostic(.@"error", null, null, origin, .{
        .user_report = .{ .code = "UserReport", .message = owned_message },
    });
}

fn expectNoDiagnosticCode(state: *core.DocumentState, code: []const u8) !void {
    for (state.diagnostics.entries.items) |diagnostic| {
        if (diagnostic.data == .user_report) try testing.expect(!std.mem.eql(u8, diagnostic.data.user_report.code, code));
    }
}

fn expectDiagnosticCode(state: *core.DocumentState, code: []const u8) !void {
    for (state.diagnostics.entries.items) |diagnostic| {
        switch (diagnostic.data) {
            .user_report => |data| {
                if (std.mem.eql(u8, data.code, std.mem.trimEnd(u8, code, ":"))) return;
            },
            else => {},
        }
    }
    return error.ExpectedDiagnosticMissing;
}

test "document state spec: explicit field reads ignore shared settings defaults" {
    var state = try initDocumentStateWithLayoutSettingsDefaults();
    defer state.deinit();

    const page = try state.addPage("Page");
    const page_node = state.getNode(page).?;

    try testing.expectEqualStrings("top_flow", core.fields.read(state.allocator, &state, page_node, "layout_v", &.{}, .text).?);
    try testing.expect(core.fields.readExplicit(page_node, "layout_v", &.{}, .text) == null);

    const default_offset = core.fields.read(state.allocator, &state, page_node, "layout_v_center_offset", &.{}, .number).?;
    try testing.expectApproxEqAbs(@as(f32, 0), default_offset, 0.0001);
    try testing.expect(core.fields.readExplicit(page_node, "layout_v_center_offset", &.{}, .number) == null);

    try state.setNodeFieldValue(page, "layout_v", .{ .enum_case = .{ .enum_name = "LayoutPolicy", .case_name = "center" } });
    try state.setNodeFieldValue(page, "layout_v_center_offset", .{ .number = 40 });
    const explicit_page_node = state.getNode(page).?;

    try testing.expectEqualStrings("center", core.fields.readExplicit(explicit_page_node, "layout_v", &.{}, .text).?);
    const explicit_offset = core.fields.readExplicit(explicit_page_node, "layout_v_center_offset", &.{}, .number).?;
    try testing.expectApproxEqAbs(@as(f32, 40), explicit_offset, 0.0001);
}

fn initDocumentStateWithLayoutSettingsDefaults() !core.DocumentState {
    const allocator = testing.allocator;
    const asset_base_dir = try allocator.dupe(u8, ".");
    errdefer allocator.free(asset_base_dir);
    const project_path = try allocator.dupe(u8, "layout-settings.ss");
    errdefer allocator.free(project_path);
    const project_source = try allocator.dupe(u8, "");
    errdefer allocator.free(project_source);

    var program = ast.Module.init();
    errdefer program.deinit(allocator);

    try program.records.append(allocator, .{
        .name = try allocator.dupe(u8, "PageSettings"),
        .fields = .empty,
        .span = zeroSpan(),
    });
    try program.records.items[0].fields.append(allocator, .{
        .name = try allocator.dupe(u8, "layout_v"),
        .value_type = ast.Type.enumType("LayoutPolicy"),
        .default_property_value = try allocator.dupe(u8, "top_flow"),
        .span = zeroSpan(),
    });
    try program.records.items[0].fields.append(allocator, .{
        .name = try allocator.dupe(u8, "layout_v_center_offset"),
        .value_type = ast.Type.number,
        .default_property_value = try allocator.dupe(u8, "0"),
        .span = zeroSpan(),
    });

    var state = try core.DocumentState.init(allocator, asset_base_dir, project_path, project_source, program);
    program = ast.Module.init();
    errdefer state.deinit();
    try state.modules.order.append(allocator, state.modules.project_id);
    state.declaration_index.settings_module_id = state.modules.project_id;
    return state;
}

fn zeroSpan() ast.Span {
    return .{ .start = 0, .end = 0 };
}

test "diagnostic codes survive rewording cloning and duplicate detection" {
    var state = try initEmptyDocumentState();
    defer state.deinit();
    const cases = [_]struct { code: []const u8, message: []const u8 }{
        .{ .code = "ExampleCode", .message = "the same wording" },
        .{ .code = "OtherCode", .message = "the same wording" },
        .{ .code = "UserReport", .message = "ExampleCode: user-authored text" },
    };
    for (cases) |case| {
        try state.addValidationDiagnostic(.@"error", null, null, .{ .label = "origin" }, .{
            .user_report = .{ .code = case.code, .message = try testing.allocator.dupe(u8, case.message) },
        });
    }
    state.diagnostics.deduplicateValidationUserReports(state.allocator);
    try testing.expectEqual(cases.len, state.diagnostics.entries.items.len);
    for (state.diagnostics.entries.items, cases) |*diagnostic, case| {
        try testing.expectEqualStrings(case.code, diagnostic.code());
        var cloned = try diagnostic.clone(testing.allocator);
        defer cloned.deinit(testing.allocator);
        try testing.expectEqualStrings(case.code, cloned.code());
        const reworded = try testing.allocator.dupe(u8, "reworded: text");
        testing.allocator.free(diagnostic.data.user_report.message);
        diagnostic.data.user_report.message = reworded;
        try testing.expectEqualStrings(case.code, diagnostic.code());
    }
}

fn cloneSourceOrigins(allocator: std.mem.Allocator) !void {
    const origin: core.SourceOrigin = .{
        .path = "directory:bytes:12-34/slide.ss",
        .span = .{ .start = 7, .end = 13 },
        .label = "path:label:bytes:0-1",
    };
    const copied = try origin.clone(allocator);
    defer copied.deinit(allocator);
    try testing.expect(origin.eql(copied));
    try testing.expect(origin.path.?.ptr != copied.path.?.ptr);
    try testing.expect(origin.label.?.ptr != copied.label.?.ptr);
    try testing.expectEqual(origin.span.?, copied.location().?.span);
    try testing.expect(!origin.eql(.{ .label = origin.path, .span = origin.span }));

    const provenance = core.ContentProvenance{ .content_start = 4, .content_end = 10, .origin = origin };
    var shifted = try provenance.cloneWithOffset(allocator, 20);
    defer shifted.deinit(allocator);
    const resolved = core.ContentProvenance.originForSpan(&.{shifted}, 25, 29).?;
    try testing.expect(resolved.eql(origin.withSpan(.{ .start = 8, .end = 12 })));
    try testing.expectEqual(@as(?core.SourceOrigin, null), core.ContentProvenance.originForSpan(&.{shifted}, 23, 25));
    try testing.expectEqual(@as(?core.SourceOrigin, null), core.ContentProvenance.originForSpan(&.{shifted}, 29, 31));

    const borrowed = core.Diagnostic{
        .phase = .validation,
        .severity = .@"error",
        .origin = resolved,
        .data = .{ .user_report = .{ .code = "Example", .message = "body" } },
    };
    var diagnostic = try borrowed.clone(allocator);
    defer diagnostic.deinit(allocator);
    try testing.expect(diagnostic.origin.?.eql(resolved));

    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(allocator);
    var object = try utils.json.Object.beginBuffer(allocator, &buffer);
    try utils.err.writeOriginField(&object, "origin", diagnostic.origin);
    try object.end();
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, buffer.items, .{});
    defer parsed.deinit();
    const fields = parsed.value.object.get("origin").?.object;
    try testing.expectEqualStrings(origin.path.?, fields.get("path").?.string);
    try testing.expectEqualStrings(origin.label.?, fields.get("label").?.string);
    try testing.expectEqual(@as(i64, 8), fields.get("start").?.integer);
    try testing.expectEqual(@as(i64, 12), fields.get("end").?.integer);
}

test "structured origins preserve paths labels spans and independent ownership" {
    try allocation_testing.checkAllAllocationFailures(testing.allocator, cloneSourceOrigins, .{});
}

test "diagnostic constructors release message ownership when origin cloning fails" {
    for ([_]core.DiagnosticPhase{ .validation, .render, .layout }) |phase| {
        var state = try initEmptyDocumentState();
        defer state.deinit();
        const origin = core.SourceOrigin.at("origin.ss", .{ .start = 1, .end = 4 });
        state.getNode(state.graph.document_id).?.origin = origin;
        const data: core.Diagnostic.Data = .{
            .user_report = .{ .code = "Example", .message = try testing.allocator.dupe(u8, "owned before origin cloning") },
        };
        var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
        const original_allocator = state.allocator;
        state.allocator = failing.allocator();
        defer state.allocator = original_allocator;
        const result = switch (phase) {
            .validation => state.addValidationDiagnostic(.@"error", null, null, origin, data),
            .render => state.addRenderDiagnostic(.@"error", null, null, origin, data),
            .layout => state.addLayoutError(state.graph.document_id, state.graph.document_id, data),
        };
        try testing.expectError(error.OutOfMemory, result);
        try testing.expectEqual(@as(usize, 0), state.diagnostics.entries.items.len);
    }
}

fn exercisePropertyPathDefinitions(allocator: std.mem.Allocator) !void {
    var state = try initEmptyDocumentStateWithAllocator(allocator);
    defer state.deinit();
    const object = try state.createGroupWithOrigin(&.{}, null);
    var record = core.RecordValue.init(ast.Type.recordType("LayoutStyle"));
    defer record.deinit(allocator);
    try record.fields.append(allocator, .{ .name = "x", .value = .{ .number = 12 } });
    try state.defineNodeFieldPath(object, "layout", "layout.x", .{ .record = record }, 0, null);
    try record.fields.append(allocator, .{ .name = "right_inset", .value = .{ .number = 99 } });
    state.defineNodeFieldPath(object, "layout", "layout.right_inset", .{ .record = record }, 0, null) catch |err| {
        const original = state.getNodeField(object, "layout").?.record;
        try testing.expectEqual(@as(f32, 12), original.field("x").?.number);
        try testing.expect(original.field("right_inset") == null);
        try testing.expectEqual(@as(usize, 1), state.getNode(object).?.property_definitions.items.len);
        return err;
    };
    try testing.expectEqual(@as(f32, 99), state.getNodeField(object, "layout").?.record.field("right_inset").?.number);
    try testing.expectError(error.DuplicatePropertyDefinition, state.setNodeFieldValue(object, "layout", .{ .record = record }));
    try testing.expectError(error.DuplicatePropertyDefinition, state.defineNodeFieldPath(object, "layout", "layout.x", .{ .record = record }, 0, null));
}

test "document state spec: property path definitions are atomic on allocation failure" {
    try allocation_testing.checkAllAllocationFailures(testing.allocator, exercisePropertyPathDefinitions, .{});
}

test "document state spec: placement rejects a shared descendant before publishing membership" {
    var state = try initEmptyDocumentState();
    defer state.deinit();
    const page = try state.addPage("Page");
    const child = try state.createObjectWithOrigin("child", .text, .text, "Child", null);
    const left = try state.createGroupWithOrigin(&.{child}, null);
    const right = try state.createGroupWithOrigin(&.{child}, null);
    const outer = try state.createGroupWithOrigin(&.{ left, right }, null);
    try testing.expectError(error.DuplicateObjectParent, state.placeObjectOnPage(page, outer));
    try testing.expectEqual(@as(usize, 0), state.placementRootsOf(page).len);
    for ([_]core.NodeId{ child, left, right, outer }) |id| {
        try testing.expect(!state.getNode(id).?.attached);
        try testing.expectEqual(@as(?core.NodeId, null), state.parentPageOf(id));
    }
}

test "document state spec: composition order preserves page indices and explicit group children" {
    var state = try initEmptyDocumentState();
    defer state.deinit();
    state.graph.composition_cursor = .{ .source_order = 30 };
    const last_page = try state.addPage("Last");
    state.graph.composition_cursor = .{ .source_order = 10 };
    const first_page = try state.addPage("First");
    state.graph.composition_cursor = .{ .source_order = 20 };
    const middle_page = try state.addPage("Middle");
    try testing.expectEqualSlices(core.NodeId, &.{ first_page, middle_page, last_page }, state.graph.page_order.items);
    try testing.expectEqualSlices(core.NodeId, &.{ first_page, middle_page, last_page }, state.childrenOf(state.graph.document_id).?);
    for (state.graph.page_order.items, 1..) |id, index| try testing.expectEqual(index, state.getNode(id).?.page_index.?);

    const a = try state.createObjectWithOrigin("a", .text, .text, "A", null);
    const b = try state.createObjectWithOrigin("b", .text, .text, "B", null);
    const c = try state.createObjectWithOrigin("c", .text, .text, "C", null);
    state.graph.composition_cursor = .{ .source_order = 50 };
    try state.placeObjectOnPage(first_page, c);
    const group = try state.createGroupWithOrigin(&.{ b, a }, null);
    state.graph.composition_cursor = .{ .source_order = 40 };
    try state.placeObjectOnPage(first_page, group);
    try testing.expectEqualSlices(core.NodeId, &.{ group, c }, state.placementRootsOf(first_page));
    try testing.expectEqualSlices(core.NodeId, &.{ group, b, a, c }, state.childrenOf(first_page).?);
    try testing.expectEqualSlices(core.NodeId, &.{ b, a }, state.childrenOf(group).?);
}

fn exerciseFunctionInstanceStore(allocator: std.mem.Allocator) !void {
    var store = core.function_instances.Store.init(allocator);
    defer store.deinit();
    var optional = try ast.Type.optional(allocator, ast.Type.number);
    defer optional.deinit(allocator);
    const arguments = [_]ast.Type{optional};
    const key = core.function_instances.Key{ .definition = core.functionKey(7, "identity"), .arguments = &arguments };
    var declaration = ast.FunctionDecl{
        .name = try allocator.dupe(u8, "identity"),
        .span = .{ .start = 0, .end = 1 },
        .params = .empty,
        .result_type = ast.Type.number,
        .statements = .empty,
    };
    var owned = true;
    defer if (owned) declaration.deinit(allocator);
    const instance = try store.add(key, declaration);
    owned = false;
    try testing.expect(store.find(key).? == instance);
    try testing.expect(store.isChecking(key.definition));
    instance.status = .checked;
    try testing.expect(!store.isChecking(key.definition));
    const other_arguments = [_]ast.Type{ast.Type.string};
    try testing.expect(store.find(.{ .definition = key.definition, .arguments = &other_arguments }) == null);
    try testing.expect(store.find(.{ .definition = core.functionKey(8, "identity"), .arguments = &arguments }) == null);
    try store.call_targets.put(3, .{ .module_id = 7, .name = instance.declaration.name, .instance_id = instance.declaration.instance_id });
    try testing.expectEqual(@as(?u32, 0), store.call_targets.get(3).?.instance_id);
}

test "document state spec: concrete function instances own declarations and type arguments" {
    try allocation_testing.checkAllAllocationFailures(testing.allocator, exerciseFunctionInstanceStore, .{});
}

fn exerciseTypeInstanceStore(allocator: std.mem.Allocator) !void {
    var store = core.type_instances.Store.init(allocator);
    defer store.deinit();
    var nested = try ast.Type.optional(allocator, ast.Type.recordType("Item").inModule(4));
    defer nested.deinit(allocator);
    var ty = try ast.Type.recordType("Box").inModule(7).withArguments(allocator, &.{nested});
    defer ty.deinit(allocator);
    var declaration = ast.RecordDecl{
        .name = try allocator.dupe(u8, "Box"),
        .span = .{ .start = 10, .end = 20 },
        .fields = .empty,
    };
    var owned = true;
    defer if (owned) declaration.deinit(allocator);
    const instance = try store.add(ty, declaration);
    owned = false;
    try testing.expect(store.find(ty).? == instance);
    try testing.expect(store.isChecking(ty.nominalId().?));
    instance.status = .checked;
    try testing.expect(!store.isChecking(ty.nominalId().?));
    try testing.expect(store.find(ty.inModule(8)) == null);
    try testing.expect(store.find(ast.Type.recordType("Box").inModule(7)) == null);
    var other = try ast.Type.recordType("Box").inModule(7).withArguments(allocator, &.{ast.Type.number});
    defer other.deinit(allocator);
    try testing.expect(store.find(other) == null);
    try store.construction_targets.put(5, instance);
    try testing.expect(store.construction(.{ .analysis_id = 5, .type_name = "Box", .fields = .empty }).? == instance);
}

test "document state spec: concrete type instances own declarations and nested arguments" {
    try allocation_testing.checkAllAllocationFailures(testing.allocator, exerciseTypeInstanceStore, .{});
}

fn exercisePlacementChildren(allocator: std.mem.Allocator) !void {
    var state = try initEmptyDocumentStateWithAllocator(allocator);
    defer state.deinit();
    const page = try state.addPage("Page");
    var input = try placementInput(allocator);
    defer input.deinit(allocator);
    const parent = try state.registerPlacement(page, input, null);
    const count = state.nodeCount();
    const next = state.graph.next_id;
    const ownership = state.graph.direct_page_ownership.items.len;
    const children = state.registerPlacementChildren(parent, &.{ input, input, input }, .{ .path = "group.ss", .label = "children" }) catch |err| {
        try testing.expectEqual(count, state.nodeCount());
        try testing.expectEqual(next, state.graph.next_id);
        try testing.expectEqual(ownership, state.graph.direct_page_ownership.items.len);
        try testing.expectEqual(@as(usize, 0), if (state.childrenOf(parent)) |items| items.len else 0);
        return err;
    };
    try testing.expectEqual(@as(usize, 3), children.len);
    for (children, 0..) |id, offset| {
        try testing.expectEqual(next + offset, id);
        const node = state.getNode(id).?;
        try testing.expectEqual(parent, node.placement.?.parent_id);
        try testing.expectEqual(page, node.placement.?.page_id);
        try testing.expectEqualStrings("group.ss", node.origin.?.path.?);
    }
    try testing.expectError(error.InvalidPlacementParent, state.registerPlacementChildren(parent, &.{input}, null));
}

test "document state spec: display children publish atomically under allocation failure" {
    try allocation_testing.checkAllAllocationFailures(testing.allocator, exercisePlacementChildren, .{});
}

fn exerciseGroupClone(allocator: std.mem.Allocator) !void {
    var input = try placementInput(allocator);
    defer input.deinit(allocator);
    var group = core.Value{ .group = .{ .ty = try (ast.Type{ .kind = .group }).withArguments(allocator, &.{ input.record.ty, input.record.ty }) } };
    defer group.deinit(allocator);
    try group.group.children.ensureTotalCapacity(allocator, 2);
    group.group.children.appendAssumeCapacity(try input.clone(allocator));
    group.group.children.appendAssumeCapacity(try input.clone(allocator));
    var copy = try group.clone(allocator);
    defer copy.deinit(allocator);
    try testing.expect(ast.Type.eql(copy.group.ty, group.group.ty));
    try testing.expectEqual(@as(usize, 2), copy.group.children.items.len);
    try testing.expect(copy.group.children.items.ptr != group.group.children.items.ptr);
    try testing.expect(copy.group.children.items[0].record.fields.items.ptr != copy.group.children.items[1].record.fields.items.ptr);
}

test "document state spec: group values clone independently under allocation failure" {
    try allocation_testing.checkAllAllocationFailures(testing.allocator, exerciseGroupClone, .{});
}

fn exerciseGroupRegistration(allocator: std.mem.Allocator, display_child: bool) !void {
    var state = try initEmptyDocumentStateWithAllocator(allocator);
    defer state.deinit();
    const page = try state.addPage("Page");
    var input = try placementInput(allocator);
    defer input.deinit(allocator);
    var inner = core.Value{ .group = .{ .ty = try (ast.Type{ .kind = .group }).withArguments(allocator, &.{ input.record.ty, input.record.ty }) } };
    defer inner.deinit(allocator);
    try inner.group.children.ensureTotalCapacity(allocator, 2);
    inner.group.children.appendAssumeCapacity(try input.clone(allocator));
    inner.group.children.appendAssumeCapacity(try input.clone(allocator));
    var outer = core.Value{ .group = .{ .ty = try (ast.Type{ .kind = .group }).withArguments(allocator, &.{ input.record.ty, inner.group.ty }) } };
    defer outer.deinit(allocator);
    try outer.group.children.ensureTotalCapacity(allocator, 2);
    outer.group.children.appendAssumeCapacity(try input.clone(allocator));
    outer.group.children.appendAssumeCapacity(try inner.clone(allocator));
    const parent = if (display_child) try state.registerPlacement(page, input, null) else page;
    state.graph.composition_cursor = .{ .source_order = 17 };
    const count = state.nodeCount();
    const next = state.graph.next_id;
    const ownership = state.graph.direct_page_ownership.items.len;
    const containment = state.graph.contains.count();
    const roots = state.placementRootsOf(page).len;
    const registered: anyerror!core.NodeId = if (display_child) blk: {
        const children = state.registerPlacementChildren(parent, &.{outer}, null) catch |err| break :blk err;
        break :blk children[0];
    } else state.registerPlacement(page, outer, null);
    const id = registered catch |err| {
        try testing.expectEqual(count, state.nodeCount());
        try testing.expectEqual(next, state.graph.next_id);
        try testing.expectEqual(ownership, state.graph.direct_page_ownership.items.len);
        try testing.expectEqual(containment, state.graph.contains.count());
        try testing.expectEqual(roots, state.placementRootsOf(page).len);
        try testing.expectEqual(@as(usize, 0), state.graph.composition_cursor.?.sequence);
        return err;
    };
    try testing.expectEqual(next, id);
    try testing.expectEqual(count + 5, state.nodeCount());
    try testing.expectEqual(next + 5, state.graph.next_id);
    try testing.expectEqual(roots + @intFromBool(!display_child), state.placementRootsOf(page).len);
    try testing.expectEqual(@as(usize, @intFromBool(!display_child)), state.graph.composition_cursor.?.sequence);
    const children = state.childrenOf(id).?;
    try testing.expectEqual(@as(usize, 2), children.len);
    const nested = state.childrenOf(children[1]).?;
    try testing.expectEqual(@as(usize, 2), nested.len);
    for ([_]core.NodeId{ id, children[0], children[1], nested[0], nested[1] }) |node_id| {
        try testing.expectEqual(page, state.getNode(node_id).?.placement.?.page_id);
        try testing.expectEqual(page, state.parentPageOf(node_id).?);
    }
    for (nested) |node_id| try testing.expectEqual(children[1], state.getNode(node_id).?.placement.?.parent_id);
}

test "document state spec: group structure registers atomically without evaluating displays" {
    for ([_]bool{ false, true }) |display_child| {
        try allocation_testing.checkAllAllocationFailures(testing.allocator, exerciseGroupRegistration, .{display_child});
    }
}
