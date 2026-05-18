const std = @import("std");
const ast = @import("ast");
const core = @import("core");
const model = @import("model");

const graph = core.layout.graph;

const testing = std.testing;

fn initEmptyIr() !core.Ir {
    const allocator = testing.allocator;
    const asset_base_dir = try allocator.dupe(u8, ".");
    errdefer allocator.free(asset_base_dir);
    const project_path = try allocator.dupe(u8, "unit-test.ss");
    errdefer allocator.free(project_path);
    const project_source = try allocator.dupe(u8, "");
    errdefer allocator.free(project_source);
    return try core.Ir.init(allocator, asset_base_dir, project_path, project_source, ast.Program.init());
}

fn expectFloat(expected: f32, actual: f32) !void {
    try testing.expectApproxEqAbs(expected, actual, 0.0001);
}

test "layout graph spec: anchors map to axes and frame coordinates" {
    try testing.expectEqual(model.Axis.horizontal, graph.anchorAxis(.left));
    try testing.expectEqual(model.Axis.horizontal, graph.anchorAxis(.right));
    try testing.expectEqual(model.Axis.horizontal, graph.anchorAxis(.center_x));
    try testing.expectEqual(model.Axis.vertical, graph.anchorAxis(.top));
    try testing.expectEqual(model.Axis.vertical, graph.anchorAxis(.bottom));
    try testing.expectEqual(model.Axis.vertical, graph.anchorAxis(.center_y));

    const frame = model.Frame{ .x = 10, .y = 20, .width = 100, .height = 50, .x_set = true, .y_set = true };
    try expectFloat(10, graph.anchorValue(frame, .left));
    try expectFloat(110, graph.anchorValue(frame, .right));
    try expectFloat(60, graph.anchorValue(frame, .center_x));
    try expectFloat(20, graph.anchorValue(frame, .bottom));
    try expectFloat(70, graph.anchorValue(frame, .top));
    try expectFloat(45, graph.anchorValue(frame, .center_y));
}

test "layout graph spec: axis reconciliation derives missing anchors from any two independent facts" {
    var from_edges = model.AxisState{ .start = 10, .end = 70 };
    try testing.expect(try graph.reconcileAxisState(&from_edges));
    try expectFloat(60, from_edges.size.?);
    try expectFloat(40, from_edges.center.?);
    try testing.expect(!try graph.reconcileAxisState(&from_edges));

    var from_center = model.AxisState{ .center = 50, .size = 20 };
    try testing.expect(try graph.reconcileAxisState(&from_center));
    try expectFloat(40, from_center.start.?);
    try expectFloat(60, from_center.end.?);
}

test "layout graph spec: reconciliation reports conflicts and negative sizes" {
    var conflict = model.AxisState{ .start = 0, .end = 10, .size = 9 };
    try testing.expectError(error.ConstraintConflict, graph.reconcileAxisState(&conflict));

    var negative = model.AxisState{ .start = 20, .end = 10 };
    try testing.expectError(error.NegativeConstraintSize, graph.reconcileAxisState(&negative));
}

test "layout graph spec: self-referential anchor pairs define sizes when roles differ" {
    const width = model.Constraint{
        .target_node = 1,
        .target_anchor = .right,
        .source = .{ .node = .{ .node_id = 1, .anchor = .left } },
        .offset = 120,
    };
    try expectFloat(120, graph.selfReferentialSize(width, .horizontal).?);

    const centered = model.Constraint{
        .target_node = 1,
        .target_anchor = .center_x,
        .source = .{ .node = .{ .node_id = 1, .anchor = .left } },
        .offset = 35,
    };
    try expectFloat(70, graph.selfReferentialSize(centered, .horizontal).?);

    const same_role = model.Constraint{
        .target_node = 1,
        .target_anchor = .right,
        .source = .{ .node = .{ .node_id = 1, .anchor = .right } },
        .offset = 120,
    };
    try testing.expect(graph.selfReferentialSize(same_role, .horizontal) == null);

    const wrong_axis = model.Constraint{
        .target_node = 1,
        .target_anchor = .right,
        .source = .{ .node = .{ .node_id = 1, .anchor = .top } },
        .offset = 120,
    };
    try testing.expect(graph.selfReferentialSize(wrong_axis, .horizontal) == null);
}

test "layout graph spec: shifting an axis moves anchors without changing size" {
    var state = model.AxisState{ .start = 10, .end = 30, .center = 20, .size = 20 };
    try testing.expect(graph.shiftAxisState(&state, 5));
    try expectFloat(15, state.start.?);
    try expectFloat(35, state.end.?);
    try expectFloat(25, state.center.?);
    try expectFloat(20, state.size.?);
    try testing.expect(!graph.shiftAxisState(&state, graph.ConstraintTolerance / 2));
}

test "layout graph spec: page graph indexes direct page children and filters axis constraints" {
    var ir = try initEmptyIr();
    defer ir.deinit();

    const page = try ir.addPage("Page");
    const a = try ir.makeObject(page, "a", null, .text, .text, "A");
    const b = try ir.makeObject(page, "b", null, .text, .text, "B");
    _ = try ir.makeGroupWithOrigin(page, true, &.{ a, b }, "group");

    try ir.addAnchorConstraint(a, .left, .{ .page = .left }, 10, "a-left");
    try ir.addAnchorConstraint(a, .top, .{ .page = .top }, -10, "a-top");
    try ir.addAnchorConstraint(b, .left, .{ .node = .{ .node_id = a, .anchor = .right } }, 20, "b-left");

    var page_graph = try graph.PageLayoutGraph.init(testing.allocator, &ir, page);
    defer page_graph.deinit();

    try testing.expectEqual(@as(usize, 3), page_graph.len());
    try testing.expect(page_graph.indexOf(a) != null);
    try testing.expect(page_graph.indexOf(b) != null);
    try testing.expect(page_graph.hasTargetConstraint(&ir, a, .horizontal, &.{}));
    try testing.expect(page_graph.hasTargetConstraint(&ir, a, .vertical, &.{}));
    try testing.expect(!page_graph.hasTargetConstraint(&ir, b, .vertical, &.{}));

    var horizontal = try page_graph.constraintsForAxis(testing.allocator, &ir, .horizontal, &.{});
    defer horizontal.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), horizontal.items.len);

    var targets_a = try page_graph.targetConstraints(testing.allocator, &ir, a, .horizontal, &.{});
    defer targets_a.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), targets_a.items.len);

    var sourced_by_a = try page_graph.sourceConstraints(testing.allocator, &ir, a, .horizontal, &.{});
    defer sourced_by_a.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), sourced_by_a.items.len);
    try testing.expectEqual(b, sourced_by_a.items[0].target_node);
}

test "layout graph spec: constraint classification names layout dependency roles" {
    var ir = try initEmptyIr();
    defer ir.deinit();

    const page = try ir.addPage("Page");
    const a = try ir.makeObject(page, "a", null, .text, .text, "A");
    const b = try ir.makeObject(page, "b", null, .text, .text, "B");
    const group_id = try ir.makeGroupWithOrigin(page, true, &.{ a, b }, "group");

    var page_graph = try graph.PageLayoutGraph.init(testing.allocator, &ir, page);
    defer page_graph.deinit();

    try testing.expectEqual(graph.ConstraintClass.page_source, page_graph.constraintClass(&ir, .{
        .target_node = a,
        .target_anchor = .left,
        .source = .{ .page = .left },
        .offset = 10,
    }, .horizontal));

    try testing.expectEqual(graph.ConstraintClass.normal, page_graph.constraintClass(&ir, .{
        .target_node = b,
        .target_anchor = .left,
        .source = .{ .node = .{ .node_id = a, .anchor = .right } },
        .offset = 20,
    }, .horizontal));

    try testing.expectEqual(graph.ConstraintClass.self_size, page_graph.constraintClass(&ir, .{
        .target_node = a,
        .target_anchor = .right,
        .source = .{ .node = .{ .node_id = a, .anchor = .left } },
        .offset = 120,
    }, .horizontal));

    try testing.expectEqual(graph.ConstraintClass.group_target, page_graph.constraintClass(&ir, .{
        .target_node = group_id,
        .target_anchor = .left,
        .source = .{ .page = .left },
        .offset = 0,
    }, .horizontal));

    try testing.expectEqual(graph.ConstraintClass.group_source, page_graph.constraintClass(&ir, .{
        .target_node = a,
        .target_anchor = .left,
        .source = .{ .node = .{ .node_id = group_id, .anchor = .right } },
        .offset = 0,
    }, .horizontal));

    try testing.expectEqual(graph.ConstraintClass.wrong_axis, page_graph.constraintClass(&ir, .{
        .target_node = a,
        .target_anchor = .top,
        .source = .{ .page = .top },
        .offset = 0,
    }, .horizontal));

    try testing.expectEqual(graph.ConstraintClass.external_source, page_graph.constraintClass(&ir, .{
        .target_node = 9999,
        .target_anchor = .left,
        .source = .{ .page = .left },
        .offset = 0,
    }, .horizontal));
}

test "layout graph spec: axis workspaces seed known frames only without target constraints" {
    var ir = try initEmptyIr();
    defer ir.deinit();

    const page = try ir.addPage("Page");
    const unconstrained = try ir.makeObject(page, "free", null, .text, .text, "Free");
    const constrained = try ir.makeObject(page, "fixed", null, .text, .text, "Fixed");

    ir.getNode(unconstrained).?.frame = .{ .x = 10, .y = 20, .width = 30, .height = 40, .x_set = true, .y_set = true };
    ir.getNode(constrained).?.frame = .{ .x = 100, .y = 200, .width = 50, .height = 60, .x_set = true, .y_set = true };
    try ir.addAnchorConstraint(constrained, .left, .{ .page = .left }, 15, "fixed-left");

    var page_graph = try graph.PageLayoutGraph.init(testing.allocator, &ir, page);
    defer page_graph.deinit();
    var workspace = try graph.AxisWorkspace.init(testing.allocator, &ir, &page_graph, .horizontal);
    defer workspace.deinit();

    const free_state = workspace.stateOfConst(unconstrained).?;
    try expectFloat(10, free_state.start.?);
    try expectFloat(40, free_state.end.?);
    try expectFloat(25, free_state.center.?);
    try expectFloat(30, free_state.size.?);

    const fixed_state = workspace.stateOfConst(constrained).?;
    try testing.expect(fixed_state.start == null);
    try testing.expect(fixed_state.end == null);
    try testing.expect(fixed_state.center == null);
    try testing.expect(fixed_state.size == null);
}
