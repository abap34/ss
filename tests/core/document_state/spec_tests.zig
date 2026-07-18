const std = @import("std");
const ast = @import("ast");
const core = @import("core");

const testing = std.testing;

fn initEmptyDocumentState() !core.DocumentState {
    const allocator = testing.allocator;
    const asset_base_dir = try allocator.dupe(u8, ".");
    errdefer allocator.free(asset_base_dir);
    const project_path = try allocator.dupe(u8, "unit-test.ss");
    errdefer allocator.free(project_path);
    const project_source = try allocator.dupe(u8, "");
    errdefer allocator.free(project_source);
    return try core.DocumentState.init(allocator, asset_base_dir, project_path, project_source, ast.Module.init());
}

fn expectConstraint(
    state: *const core.DocumentState,
    target_node: core.NodeId,
    target_anchor: core.Anchor,
    role: core.ConstraintRole,
    from_update: bool,
) !void {
    for (state.constraints.items) |constraint| {
        if (constraint.target_node != target_node or constraint.target_anchor != target_anchor) continue;
        if (constraint.role != role or constraint.from_update != from_update) continue;
        return;
    }
    return error.TestExpectedConstraint;
}

test "core IR spec: pages are ordered document children with one-based page indexes" {
    var state = try initEmptyDocumentState();
    defer state.deinit();

    const first = try state.addPage("First");
    const second = try state.addPage("Second");

    try testing.expectEqual(@as(usize, 2), state.pageCount());
    try testing.expectEqual(first, state.page_order.items[0]);
    try testing.expectEqual(second, state.page_order.items[1]);
    try testing.expectEqual(@as(usize, 1), state.pageIndexOf(first));
    try testing.expectEqual(@as(usize, 2), state.pageIndexOf(second));

    const document_children = state.childrenOf(state.document_id).?;
    try testing.expectEqual(@as(usize, 2), document_children.len);
    try testing.expectEqual(first, document_children[0]);
    try testing.expectEqual(second, document_children[1]);
}

test "core IR spec: containment is idempotent for the same parent-child pair" {
    var state = try initEmptyDocumentState();
    defer state.deinit();

    const page = try state.addPage("Page");
    const object = try state.makeObject(page, "title", null, .text, .text, "Hello");
    try state.addContainment(page, object);
    try state.addContainment(page, object);

    const children = state.childrenOf(page).?;
    try testing.expectEqual(@as(usize, 1), children.len);
    try testing.expectEqual(object, children[0]);
}

test "core IR spec: page-local validation reports duplicate page ownership" {
    var state = try initEmptyDocumentState();
    defer state.deinit();

    const first = try state.addPage("First");
    const second = try state.addPage("Second");
    const object = try state.makeObject(first, "title", null, .text, .text, "Hello");
    try state.addContainment(second, object);

    try state.validatePageLocalLayout();

    try expectDiagnosticCode(&state, "PageOwnershipConflict:");
}

test "core IR spec: page-local validation reports cross-page constraints" {
    var state = try initEmptyDocumentState();
    defer state.deinit();

    const first = try state.addPage("First");
    const second = try state.addPage("Second");
    const target = try state.makeObject(first, "target", null, .text, .text, "Target");
    const source = try state.makeObject(second, "source", null, .text, .text, "Source");

    try state.addAnchorConstraint(target, .top, .{ .node = .{ .node_id = source, .anchor = .top } }, 0, "cross-page");
    try state.validatePageLocalLayout();

    try expectDiagnosticCode(&state, "CrossPageConstraint:");
}

test "core IR spec: page-local validation reports unowned layout objects" {
    var state = try initEmptyDocumentState();
    defer state.deinit();

    const page = try state.addPage("Page");
    const placed = try state.makeObject(page, "placed", null, .text, .text, "Placed");
    const helper = try state.createObjectWithOrigin("helper", null, .text, .text, "Helper", null);

    try state.addAnchorConstraint(placed, .top, .{ .node = .{ .node_id = helper, .anchor = .top } }, 0, "unowned");
    try state.validatePageLocalLayout();

    try expectDiagnosticCode(&state, "UnownedLayoutObject:");
}

test "core IR spec: position updates replace deeper constraints across anchors on the same axis" {
    var state = try initEmptyDocumentState();
    defer state.deinit();

    const page = try state.addPage("Page");
    const object = try state.makeObject(page, "item", null, .text, .text, "Item");
    try state.addAnchorConstraintAtScope(object, .center_x, .{ .page = .center_x }, 0, "component-center", 1);
    try state.addAnchorConstraintAtScope(object, .right, .{ .node = .{ .node_id = object, .anchor = .left } }, 240, "component-width", 1);
    try state.addConstraintUpdate(object, .left, .position, 0, .{ .page = .left }, 80, "page-left");

    try core.constraint_updates.resolve(&state);

    try testing.expectEqual(@as(usize, 2), state.constraints.items.len);
    try testing.expectEqual(@as(usize, 1), state.overridden_constraints.items.len);
    try testing.expectEqual(core.Anchor.center_x, state.overridden_constraints.items[0].target_anchor);
    try testing.expectEqual(core.ConstraintRole.size, state.constraints.items[0].role);
    try testing.expectEqual(core.Anchor.left, state.constraints.items[1].target_anchor);
    try testing.expect(state.constraints.items[1].from_update);
}

test "core IR spec: group position updates replace external placement of descendants" {
    var state = try initEmptyDocumentState();
    defer state.deinit();

    const page = try state.addPage("Page");
    const title = try state.makeObject(page, "title", null, .text, .text, "Title");
    const rule = try state.makeObject(page, "rule", null, .text, .text, "");
    const inner = try state.makeGroupWithOrigin(page, true, &.{ title, rule }, "inner-group");
    const root = try state.makeGroupWithOrigin(page, true, &.{inner}, "root-group");

    try state.addAnchorConstraintAtScope(title, .left, .{ .page = .left }, 72, "component-left", 1);
    try state.addAnchorConstraintAtScope(title, .top, .{ .page = .top }, -100, "component-top", 1);
    try state.addAnchorConstraintAtScope(title, .right, .{ .node = .{ .node_id = title, .anchor = .left } }, 240, "component-width", 1);
    try state.addAnchorConstraintAtScope(rule, .left, .{ .node = .{ .node_id = title, .anchor = .left } }, 0, "component-align", 1);
    try state.addAnchorConstraintAtScope(rule, .top, .{ .node = .{ .node_id = title, .anchor = .bottom } }, -30, "component-rule", 1);
    try state.addConstraintUpdate(root, .left, .position, 0, .{ .page = .left }, 180, "caller-left");
    try state.addConstraintUpdate(root, .top, .position, 0, .{ .page = .top }, -140, "caller-top");

    try core.constraint_updates.resolve(&state);

    try testing.expectEqual(@as(usize, 5), state.constraints.items.len);
    try testing.expectEqual(@as(usize, 2), state.overridden_constraints.items.len);
    try testing.expectEqualStrings("component-left", state.overridden_constraints.items[0].origin.?);
    try testing.expectEqualStrings("component-top", state.overridden_constraints.items[1].origin.?);
    try expectConstraint(&state, title, .right, .size, false);
    try expectConstraint(&state, rule, .left, .position, false);
    try expectConstraint(&state, rule, .top, .position, false);
    try expectConstraint(&state, root, .left, .position, true);
    try expectConstraint(&state, root, .top, .position, true);
}

test "core IR spec: overlapping group and descendant updates use scope and source order" {
    var later_descendant = try initEmptyDocumentState();
    defer later_descendant.deinit();

    const first_page = try later_descendant.addPage("Page");
    const first_child = try later_descendant.makeObject(first_page, "child", null, .text, .text, "Child");
    const first_group = try later_descendant.makeGroupWithOrigin(first_page, true, &.{first_child}, "group");
    try later_descendant.addConstraintUpdate(first_group, .left, .position, 0, .{ .page = .left }, 100, "group-first");
    try later_descendant.addConstraintUpdate(first_child, .left, .position, 0, .{ .page = .left }, 160, "child-last");

    try core.constraint_updates.resolve(&later_descendant);

    try testing.expect(!later_descendant.constraint_updates.items[0].active);
    try testing.expect(later_descendant.constraint_updates.items[1].active);
    try testing.expectEqual(@as(usize, 1), later_descendant.constraints.items.len);
    try testing.expectEqual(first_child, later_descendant.constraints.items[0].target_node);
    try testing.expectEqual(@as(usize, 1), later_descendant.overridden_constraints.items.len);

    var shallower_group = try initEmptyDocumentState();
    defer shallower_group.deinit();

    const second_page = try shallower_group.addPage("Page");
    const second_child = try shallower_group.makeObject(second_page, "child", null, .text, .text, "Child");
    const second_group = try shallower_group.makeGroupWithOrigin(second_page, true, &.{second_child}, "group");
    try shallower_group.addConstraintUpdate(second_group, .left, .position, 0, .{ .page = .left }, 100, "caller-group");
    try shallower_group.addConstraintUpdate(second_child, .left, .position, 1, .{ .page = .left }, 160, "component-child");

    try core.constraint_updates.resolve(&shallower_group);

    try testing.expect(shallower_group.constraint_updates.items[0].active);
    try testing.expect(!shallower_group.constraint_updates.items[1].active);
    try testing.expectEqual(@as(usize, 1), shallower_group.constraints.items.len);
    try testing.expectEqual(second_group, shallower_group.constraints.items[0].target_node);
    try testing.expectEqual(@as(usize, 1), shallower_group.overridden_constraints.items.len);
}

test "core IR spec: size updates preserve position constraints" {
    var state = try initEmptyDocumentState();
    defer state.deinit();

    const page = try state.addPage("Page");
    const object = try state.makeObject(page, "item", null, .text, .text, "Item");
    try state.addAnchorConstraintAtScope(object, .center_x, .{ .page = .center_x }, 0, "component-center", 1);
    try state.addAnchorConstraintAtScope(object, .right, .{ .node = .{ .node_id = object, .anchor = .left } }, 240, "component-width", 1);
    try state.addConstraintUpdate(
        object,
        .right,
        .size,
        0,
        .{ .node = .{ .node_id = object, .anchor = .left } },
        320,
        "page-width",
    );

    try core.constraint_updates.resolve(&state);

    try testing.expectEqual(@as(usize, 2), state.constraints.items.len);
    try testing.expectEqual(core.ConstraintRole.position, state.constraints.items[0].role);
    try testing.expectEqual(core.ConstraintRole.size, state.constraints.items[1].role);
    try testing.expectEqual(@as(f32, 320), state.constraints.items[1].offset);
    try testing.expect(state.constraints.items[1].from_update);
    try testing.expectEqual(@as(usize, 1), state.overridden_constraints.items.len);
    try testing.expectEqual(@as(f32, 240), state.overridden_constraints.items[0].offset);
}

test "core IR spec: pure updates suppress inherited constraints without adding a replacement" {
    var state = try initEmptyDocumentState();
    defer state.deinit();

    const page = try state.addPage("Page");
    const object = try state.makeObject(page, "item", null, .text, .text, "Item");
    try state.addAnchorConstraintAtScope(object, .top, .{ .page = .top }, -40, "component-top", 1);
    try state.addConstraintUpdate(object, .top, .position, 0, null, 0, "page-top");

    try core.constraint_updates.resolve(&state);

    try testing.expectEqual(@as(usize, 0), state.constraints.items.len);
    try testing.expectEqual(@as(usize, 1), state.overridden_constraints.items.len);
    try testing.expect(state.constraint_updates.items[0].active);
}

test "core IR spec: suppressed cross-page constraints are not diagnosed" {
    var state = try initEmptyDocumentState();
    defer state.deinit();

    const first = try state.addPage("First");
    const second = try state.addPage("Second");
    const target = try state.makeObject(first, "target", null, .text, .text, "Target");
    const source = try state.makeObject(second, "source", null, .text, .text, "Source");
    try state.addAnchorConstraintAtScope(target, .left, .{ .node = .{ .node_id = source, .anchor = .left } }, 0, "component-left", 1);
    try state.addConstraintUpdate(target, .left, .position, 0, null, 0, "page-left");

    try core.constraint_updates.resolve(&state);
    try state.validatePageLocalLayout();

    for (state.diagnostics.items) |diagnostic| {
        switch (diagnostic.data) {
            .user_report => |data| try testing.expect(!std.mem.startsWith(u8, data.message, "CrossPageConstraint:")),
            else => {},
        }
    }
}

test "core IR spec: caller updates have authority over deeper updates" {
    var state = try initEmptyDocumentState();
    defer state.deinit();

    const page = try state.addPage("Page");
    const object = try state.makeObject(page, "item", null, .text, .text, "Item");
    try state.addConstraintUpdate(object, .left, .position, 2, .{ .page = .left }, 20, "nested-left");
    try state.addConstraintUpdate(object, .right, .position, 0, .{ .page = .right }, -60, "page-right");
    try state.addConstraintUpdate(object, .center_x, .position, 1, .{ .page = .center_x }, 10, "component-center");

    try core.constraint_updates.resolve(&state);

    try testing.expect(!state.constraint_updates.items[0].active);
    try testing.expect(state.constraint_updates.items[1].active);
    try testing.expect(!state.constraint_updates.items[2].active);
    try testing.expectEqual(@as(usize, 1), state.constraints.items.len);
    try testing.expectEqual(core.Anchor.right, state.constraints.items[0].target_anchor);
    try testing.expectEqual(@as(f32, -60), state.constraints.items[0].offset);
    try testing.expectEqual(@as(usize, 2), state.overridden_constraints.items.len);
}

test "core IR spec: later updates replace earlier updates in the same scope" {
    var state = try initEmptyDocumentState();
    defer state.deinit();

    const page = try state.addPage("Page");
    const object = try state.makeObject(page, "item", null, .text, .text, "Item");
    try state.addAnchorConstraintAtScope(object, .center_x, .{ .page = .center_x }, 0, "component-center", 1);
    try state.addConstraintUpdate(object, .left, .position, 0, null, 0, "first");
    try state.addConstraintUpdate(object, .right, .position, 0, .{ .page = .right }, -40, "second");

    try core.constraint_updates.resolve(&state);

    try testing.expect(!state.constraint_updates.items[0].active);
    try testing.expect(state.constraint_updates.items[1].active);
    try testing.expectEqual(@as(usize, 1), state.constraints.items.len);
    try testing.expectEqual(core.Anchor.right, state.constraints.items[0].target_anchor);
    try testing.expectEqual(@as(f32, -40), state.constraints.items[0].offset);
    try testing.expectEqual(@as(usize, 1), state.overridden_constraints.items.len);
}

test "core IR spec: later pure updates suppress earlier replacements" {
    var state = try initEmptyDocumentState();
    defer state.deinit();

    const page = try state.addPage("Page");
    const object = try state.makeObject(page, "item", null, .text, .text, "Item");
    try state.addAnchorConstraintAtScope(object, .center_x, .{ .page = .center_x }, 0, "component-center", 1);
    try state.addConstraintUpdate(object, .left, .position, 0, .{ .page = .left }, 40, "first");
    try state.addConstraintUpdate(object, .right, .position, 0, null, 0, "second");

    try core.constraint_updates.resolve(&state);

    try testing.expect(!state.constraint_updates.items[0].active);
    try testing.expect(state.constraint_updates.items[1].active);
    try testing.expectEqual(@as(usize, 0), state.constraints.items.len);
    try testing.expectEqual(@as(usize, 2), state.overridden_constraints.items.len);
    try testing.expect(state.overridden_constraints.items[1].from_update);
}

test "core IR spec: page unit collects inline math asset dependencies" {
    var state = try initEmptyDocumentState();
    defer state.deinit();

    const page = try state.addPage("Page");
    _ = try state.makeObject(page, "body", null, .text, .text, "value $x+y$");

    var pages = try core.prepared.prepare(testing.allocator, &state);
    defer pages.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), pages.pages.len);
    try testing.expectEqual(@as(usize, 1), pages.pages[0].objects.len);
    const object = pages.pages[0].objects[0];
    try testing.expectEqual(@as(usize, 1), object.asset_deps.len);
    try testing.expectEqual(core.prepared.AssetDependency.Kind.inline_math, object.asset_deps[0].kind);
    try testing.expectEqualStrings("x+y", object.asset_deps[0].source);
    try testing.expectEqual(@as(usize, 1), object.asset_keys.len);
    try testing.expectEqual(@as(usize, 1), pages.pages[0].asset_keys.len);
    try testing.expectEqual(object.asset_keys[0], pages.pages[0].asset_keys[0]);
    try testing.expectEqual(core.prepared.assetDependencyKey(object.asset_deps[0], object.tex_preamble), object.asset_keys[0]);
}

test "core IR spec: prepared page asset keys attach to layout results" {
    var state = try initEmptyDocumentState();
    defer state.deinit();

    const page = try state.addPage("Page");
    const object = try state.makeObject(page, "body", null, .text, .text, "value $x+y$");
    try state.addAnchorConstraint(object, .left, .{ .page = .left }, 40, "body-left");
    try state.addAnchorConstraint(object, .top, .{ .page = .top }, -80, "body-top");

    var pages = try core.prepared.prepare(testing.allocator, &state);
    defer pages.deinit(testing.allocator);
    var results = try core.layout.solveDocument(&state, null, .{});
    defer results.deinit(testing.allocator);
    try core.prepared.attachAssetKeys(testing.allocator, &results, &pages);

    try testing.expectEqual(@as(usize, 1), results.pages.len);
    try testing.expectEqual(@as(usize, 1), results.pages[0].asset_keys.len);
    try testing.expectEqual(pages.pages[0].asset_keys[0], results.pages[0].asset_keys[0]);
}

test "core IR spec: layout results collect solved page frames" {
    var state = try initEmptyDocumentState();
    defer state.deinit();

    const page = try state.addPage("Page");
    const object = try state.makeObject(page, "body", null, .text, .text, "Hello");
    try state.addAnchorConstraint(object, .left, .{ .page = .left }, 40, "body-left");
    try state.addAnchorConstraint(object, .top, .{ .page = .top }, -80, "body-top");

    var results = try core.layout.solveDocument(&state, null, .{});
    defer results.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), results.pages.len);
    try testing.expectEqual(page, results.pages[0].page_id);
    const result_frame = results.frameOf(page, object) orelse return error.MissingLayoutFrame;
    const node_frame = state.getNode(object).?.frame;
    try testing.expect(result_frame.x_set);
    try testing.expect(result_frame.y_set);
    try testing.expectEqual(node_frame, result_frame);
    try testing.expect(results.pages[0].measurement_keys.len > 0);
}

test "core IR spec: layout results own page diagnostics" {
    var state = try initEmptyDocumentState();
    defer state.deinit();

    const page = try state.addPage("Page");
    const object = try state.makeObject(page, "body", null, .text, .text, "Hello");
    try state.addAnchorConstraint(object, .left, .{ .page = .left }, -40, "body-left");
    try state.addAnchorConstraint(object, .top, .{ .page = .top }, -80, "body-top");

    var results = try core.layout.solveDocument(&state, null, .{});
    defer results.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), results.pages.len);
    try testing.expect(results.pages[0].diagnostics.len > 0);
    try testing.expect(state.diagnostics.items.len > 0);
    try testing.expectEqual(core.DiagnosticPhase.layout, results.pages[0].diagnostics[0].phase);
}

test "core IR spec: node fields reject duplicate keys" {
    var state = try initEmptyDocumentState();
    defer state.deinit();

    const page = try state.addPage("Page");
    const object = try state.makeObject(page, "shape", null, .overlay, .text, "");

    try state.setNodeFieldValue(object, "fill", .{ .string = "red" });
    try state.setNodeFieldValue(object, "stroke", .{ .string = "black" });
    try testing.expectError(error.DuplicatePropertyDefinition, state.setNodeFieldValue(object, "fill", .{ .string = "blue" }));

    const node = state.getNode(object).?;
    try testing.expectEqual(@as(usize, 2), node.fields.items.len);
    try testing.expectEqualStrings("red", state.getNodeField(object, "fill").?.string);
    try testing.expectEqualStrings("black", state.getNodeField(object, "stroke").?.string);
}

fn expectDiagnosticCode(state: *core.DocumentState, code: []const u8) !void {
    for (state.diagnostics.items) |diagnostic| {
        switch (diagnostic.data) {
            .user_report => |data| {
                if (std.mem.startsWith(u8, data.message, code)) return;
            },
            else => {},
        }
    }
    return error.ExpectedDiagnosticMissing;
}

test "core IR spec: explicit field reads ignore inherited class defaults" {
    var state = try initDocumentStateWithLayoutClassDefaults();
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

test "core IR spec: render environment entries are deduplicated by full triple" {
    var state = try initEmptyDocumentState();
    defer state.deinit();

    const page = try state.addPage("Page");
    const object = try state.makeObject(page, "text", null, .text, .text, "Hello");

    try state.extendRenderEnv(object, "set", "text_color", "red");
    try state.extendRenderEnv(object, "set", "text_color", "red");
    try state.extendRenderEnv(object, "set", "text_color", "blue");
    try state.extendRenderEnv(object, "push", "text_color", "red");

    const node = state.getNode(object).?;
    try testing.expectEqual(@as(usize, 3), node.render_env.items.len);
}

fn initDocumentStateWithLayoutClassDefaults() !core.DocumentState {
    const allocator = testing.allocator;
    const asset_base_dir = try allocator.dupe(u8, ".");
    errdefer allocator.free(asset_base_dir);
    const project_path = try allocator.dupe(u8, "layout-classes.ss");
    errdefer allocator.free(project_path);
    const project_source = try allocator.dupe(u8, "");
    errdefer allocator.free(project_source);

    var program = ast.Module.init();
    errdefer program.deinit(allocator);

    try program.objects.append(allocator, .{
        .name = try allocator.dupe(u8, "Doc"),
        .roles = .empty,
        .fields = .empty,
        .span = zeroSpan(),
    });
    try program.objects.items[0].fields.append(allocator, .{
        .name = try allocator.dupe(u8, "layout_v"),
        .value_type = ast.Type.enumType("LayoutPolicy"),
        .default_property_value = try allocator.dupe(u8, "top_flow"),
        .span = zeroSpan(),
    });
    try program.objects.items[0].fields.append(allocator, .{
        .name = try allocator.dupe(u8, "layout_v_center_offset"),
        .value_type = ast.Type.number,
        .default_property_value = try allocator.dupe(u8, "0"),
        .span = zeroSpan(),
    });

    try program.objects.append(allocator, .{
        .name = try allocator.dupe(u8, "PageContext"),
        .base = try allocator.dupe(u8, "Doc"),
        .roles = .empty,
        .fields = .empty,
        .span = zeroSpan(),
    });

    var state = try core.DocumentState.init(allocator, asset_base_dir, project_path, project_source, program);
    program = ast.Module.init();
    errdefer state.deinit();
    try state.module_order.append(allocator, state.project_module_id);
    return state;
}

fn zeroSpan() ast.Span {
    return .{ .start = 0, .end = 0 };
}

test "core IR spec: TeX preamble render environment resolves in document page object order" {
    var state = try initEmptyDocumentState();
    defer state.deinit();

    const page = try state.addPage("Page");
    const object = try state.makeObject(page, "math", null, .text, .math_tex, "x");

    try state.extendRenderEnv(state.document_id, core.render_env.OpAdd, core.render_env.KeyMathTexPreamble, "doc preamble");
    try state.extendRenderEnv(page, core.render_env.OpAdd, core.render_env.KeyMathTexPreambleFile, "page.tex");
    try state.extendRenderEnv(object, core.render_env.OpAdd, core.render_env.KeyMathTexPreamble, "object preamble");

    var env = try core.render_env.resolveForNode(testing.allocator, &state, state.getNode(object).?);
    defer env.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 3), env.tex_preamble.items.len);
    try testing.expectEqual(core.render_env.TexPreambleSource.text, env.tex_preamble.items[0].source);
    try testing.expectEqualStrings("doc preamble", env.tex_preamble.items[0].value);
    try testing.expectEqual(core.render_env.TexPreambleSource.file, env.tex_preamble.items[1].source);
    try testing.expectEqualStrings("page.tex", env.tex_preamble.items[1].value);
    try testing.expectEqual(core.render_env.TexPreambleSource.text, env.tex_preamble.items[2].source);
    try testing.expectEqualStrings("object preamble", env.tex_preamble.items[2].value);
}
