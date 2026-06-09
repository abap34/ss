const std = @import("std");
const ast = @import("ast");
const core = @import("core");
const model = @import("model");

const graph = core.layout.graph;
const metrics = core.layout.metrics;
const solver = core.layout.solver;

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

fn expectSelfConstraintSize(expected: f32, actual: graph.SelfConstraint) !void {
    switch (actual) {
        .size => |size| try expectFloat(expected, size),
        else => return error.ExpectedSelfConstraintSize,
    }
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
    try expectSelfConstraintSize(120, graph.classifySelfConstraint(width, .horizontal));

    const centered = model.Constraint{
        .target_node = 1,
        .target_anchor = .center_x,
        .source = .{ .node = .{ .node_id = 1, .anchor = .left } },
        .offset = 35,
    };
    try expectSelfConstraintSize(70, graph.classifySelfConstraint(centered, .horizontal));

    const same_role = model.Constraint{
        .target_node = 1,
        .target_anchor = .right,
        .source = .{ .node = .{ .node_id = 1, .anchor = .right } },
        .offset = 120,
    };
    switch (graph.classifySelfConstraint(same_role, .horizontal)) {
        .conflict => {},
        else => return error.ExpectedSelfConstraintConflict,
    }

    const tautology = model.Constraint{
        .target_node = 1,
        .target_anchor = .right,
        .source = .{ .node = .{ .node_id = 1, .anchor = .right } },
        .offset = 0,
    };
    switch (graph.classifySelfConstraint(tautology, .horizontal)) {
        .tautology => {},
        else => return error.ExpectedSelfConstraintTautology,
    }

    const wrong_axis = model.Constraint{
        .target_node = 1,
        .target_anchor = .right,
        .source = .{ .node = .{ .node_id = 1, .anchor = .top } },
        .offset = 120,
    };
    switch (graph.classifySelfConstraint(wrong_axis, .horizontal)) {
        .none => {},
        else => return error.ExpectedSelfConstraintNone,
    }
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

test "layout graph spec: sourced anchor updates preserve default size" {
    const constraint = model.Constraint{
        .target_node = 2,
        .target_anchor = .left,
        .source = .{ .node = .{ .node_id = 1, .anchor = .right } },
        .offset = 20,
    };

    var state = model.AxisState{
        .start = 220,
        .end = 260,
        .center = 240,
        .size = 40,
        .start_source = constraint,
        .size_is_default = true,
    };

    try testing.expect(try graph.setAxisAnchor(&state, .left, 120, constraint));
    try expectFloat(120, state.start.?);
    try expectFloat(40, state.size.?);
    try testing.expect(state.end == null);
    try testing.expect(state.center == null);

    try testing.expect(try graph.reconcileAxisState(&state));
    try expectFloat(160, state.end.?);
    try expectFloat(140, state.center.?);

    const explicit_size = model.Constraint{
        .target_node = 2,
        .target_anchor = .right,
        .source = .{ .node = .{ .node_id = 2, .anchor = .left } },
        .offset = 40,
    };
    var explicit = model.AxisState{
        .start = 220,
        .end = 260,
        .center = 240,
        .size = 40,
        .start_source = constraint,
        .size_source = explicit_size,
    };

    try testing.expect(try graph.setAxisAnchor(&explicit, .left, 120, constraint));
    try expectFloat(120, explicit.start.?);
    try expectFloat(40, explicit.size.?);
    try testing.expect(explicit.end == null);
    try testing.expect(explicit.center == null);

    try testing.expect(try graph.reconcileAxisState(&explicit));
    try expectFloat(160, explicit.end.?);
    try expectFloat(140, explicit.center.?);
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

    try testing.expectEqual(graph.ConstraintClass.self_anchor, page_graph.constraintClass(&ir, .{
        .target_node = a,
        .target_anchor = .right,
        .source = .{ .node = .{ .node_id = a, .anchor = .right } },
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

test "layout solver: final validation rejects unsatisfied hard constraints" {
    var self_conflict = try initEmptyIr();
    defer self_conflict.deinit();

    const self_page = try self_conflict.addPage("Page");
    const object = try self_conflict.makeObject(self_page, "body", null, .text, .text, "A");
    try self_conflict.addAnchorConstraint(object, .top, .{ .node = .{ .node_id = object, .anchor = .top } }, 100, "self-top");
    try testing.expectError(error.ConstraintConflict, self_conflict.finalize());

    var cycle = try initEmptyIr();
    defer cycle.deinit();

    const cycle_page = try cycle.addPage("Page");
    const a = try cycle.makeObject(cycle_page, "a", null, .text, .text, "A");
    const b = try cycle.makeObject(cycle_page, "b", null, .text, .text, "B");
    try cycle.addAnchorConstraint(a, .top, .{ .node = .{ .node_id = b, .anchor = .top } }, 10, "a-top");
    try cycle.addAnchorConstraint(b, .top, .{ .node = .{ .node_id = a, .anchor = .top } }, 10, "b-top");
    try testing.expectError(error.ConstraintConflict, cycle.finalize());
}

test "layout solver: tautological self-anchor constraints do not block fallback placement" {
    var ir = try initEmptyIr();
    defer ir.deinit();

    const page = try ir.addPage("Page");
    const object = try ir.makeObject(page, "body", null, .text, .text, "A");
    try ir.addAnchorConstraint(object, .top, .{ .node = .{ .node_id = object, .anchor = .top } }, 0, "self-top");

    try ir.finalize();

    const node = ir.getNode(object).?;
    try testing.expect(node.frame.x_set);
    try testing.expect(node.frame.y_set);
    try testing.expect(!ir.hasConstraintFailures());
}

test "layout solver: explicit anchor conflicts and negative sizes are rejected" {
    var conflict = try initEmptyIr();
    defer conflict.deinit();

    const conflict_page = try conflict.addPage("Page");
    const conflict_object = try conflict.makeObject(conflict_page, "body", null, .text, .text, "A");
    try conflict.addAnchorConstraint(conflict_object, .left, .{ .page = .left }, 100, "left-a");
    try conflict.addAnchorConstraint(conflict_object, .left, .{ .page = .left }, 120, "left-b");
    try testing.expectError(error.ConstraintConflict, conflict.finalize());

    var negative = try initEmptyIr();
    defer negative.deinit();

    const negative_page = try negative.addPage("Page");
    const negative_object = try negative.makeObject(negative_page, "body", null, .text, .text, "A");
    try negative.addAnchorConstraint(negative_object, .left, .{ .node = .{ .node_id = negative_object, .anchor = .right } }, 10, "negative-width");
    try testing.expectError(error.NegativeConstraintSize, negative.finalize());
}

test "layout solver: group width propagation must preserve child hard widths" {
    var ir = try initEmptyIr();
    defer ir.deinit();

    const page = try ir.addPage("Page");
    const child = try ir.makeObject(page, "body", null, .text, .text, "this text can be wrapped");
    try ir.setNodeProperty(child, "wrap", "on");
    const group = try ir.makeGroupWithOrigin(page, true, &.{child}, "group");

    try ir.addAnchorConstraint(child, .left, .{ .page = .left }, 100, "child-left");
    try ir.addAnchorConstraint(child, .right, .{ .node = .{ .node_id = child, .anchor = .left } }, 700, "child-width");
    try ir.addAnchorConstraint(group, .right, .{ .node = .{ .node_id = group, .anchor = .left } }, 600, "group-width");

    try testing.expectError(error.ConstraintConflict, ir.finalize());
}

test "layout solver: wrapped width cap propagates through dependent anchors" {
    var ir = try initEmptyIr();
    defer ir.deinit();

    const page = try ir.addPage("Page");
    const wrapped = try ir.makeObject(
        page,
        "wrapped",
        null,
        .text,
        .text,
        "this is intentionally long enough to produce a wide intrinsic text box",
    );
    const follower = try ir.makeObject(page, "follower", null, .text, .text, "B");
    try ir.setNodeProperty(wrapped, "wrap", "on");

    try ir.addAnchorConstraint(wrapped, .left, .{ .page = .left }, 1100, "wrapped-left");
    try ir.addAnchorConstraint(follower, .left, .{ .node = .{ .node_id = wrapped, .anchor = .right } }, 20, "follower-left");

    try solver.solveLayout(&ir);

    const wrapped_node = ir.getNode(wrapped).?;
    const follower_node = ir.getNode(follower).?;
    const style = core.layout.styleForNode(&ir, wrapped_node);
    const expected_width = model.PageLayout.width - style.default_right_inset - 1100;
    try expectFloat(expected_width, wrapped_node.frame.width);
    try expectFloat(wrapped_node.frame.x + wrapped_node.frame.width + 20, follower_node.frame.x);
}

test "layout solver: vertical axis observes width-dependent wrapped height" {
    var ir = try initEmptyIr();
    defer ir.deinit();

    const page = try ir.addPage("Page");
    const wrapped = try ir.makeObject(
        page,
        "wrapped",
        null,
        .text,
        .text,
        "this sentence should wrap into multiple lines once the horizontal solver caps its width",
    );
    try ir.setNodeProperty(wrapped, "wrap", "on");
    try ir.addAnchorConstraint(wrapped, .left, .{ .page = .left }, 1100, "wrapped-left");
    try ir.addAnchorConstraint(wrapped, .bottom, .{ .page = .bottom }, 40, "wrapped-bottom");

    try solver.solveLayout(&ir);

    const wrapped_node = ir.getNode(wrapped).?;
    const expected_height = metrics.intrinsicHeight(&ir, wrapped_node);
    try testing.expect(expected_height > 28);
    try expectFloat(expected_height, wrapped_node.frame.height);
}

test "layout metrics: chrome padding is part of visual bounds and yields a content frame" {
    var ir = try initEmptyIr();
    defer ir.deinit();

    const page = try ir.addPage("Page");
    const plain = try ir.makeObject(page, "plain", null, .text, .text, "Hello");
    const padded = try ir.makeObject(page, "padded", null, .text, .text, "Hello");
    try ir.setNodeProperty(padded, "chrome_pad_x", "12");
    try ir.setNodeProperty(padded, "chrome_pad_y", "8");

    const plain_node = ir.getNode(plain).?;
    const padded_node = ir.getNode(padded).?;
    try expectFloat(metrics.intrinsicWidth(&ir, plain_node) + 24, metrics.intrinsicWidth(&ir, padded_node));
    try expectFloat(metrics.intrinsicHeight(&ir, plain_node) + 16, metrics.intrinsicHeight(&ir, padded_node));

    ir.getNode(padded).?.frame = .{ .x = 10, .y = 20, .width = 100, .height = 50, .x_set = true, .y_set = true };
    const content = core.layout.contentFrame(&ir, ir.getNode(padded).?);
    try expectFloat(22, content.x);
    try expectFloat(28, content.y);
    try expectFloat(76, content.width);
    try expectFloat(34, content.height);
}

test "layout solver: group chrome padding expands tight group bounds" {
    var ir = try initEmptyIr();
    defer ir.deinit();

    const page = try ir.addPage("Page");
    const child = try ir.makeObject(page, "child", null, .text, .text, "Hello");
    const group = try ir.makeGroupWithOrigin(page, true, &.{child}, "group");
    try ir.setNodeProperty(group, "chrome_pad_x", "12");
    try ir.setNodeProperty(group, "chrome_pad_y", "8");

    try ir.addAnchorConstraint(child, .left, .{ .page = .left }, 100, "child-left");
    try ir.addAnchorConstraint(child, .right, .{ .node = .{ .node_id = child, .anchor = .left } }, 200, "child-width");
    try ir.addAnchorConstraint(child, .bottom, .{ .page = .bottom }, 100, "child-bottom");
    try ir.addAnchorConstraint(child, .top, .{ .node = .{ .node_id = child, .anchor = .bottom } }, 40, "child-height");

    try solver.solveLayout(&ir);

    const group_node = ir.getNode(group).?;
    try expectFloat(88, group_node.frame.x);
    try expectFloat(92, group_node.frame.y);
    try expectFloat(224, group_node.frame.width);
    try expectFloat(56, group_node.frame.height);
}

test "layout solver: target group width leaves room for chrome padding" {
    var ir = try initEmptyIr();
    defer ir.deinit();

    const page = try ir.addPage("Page");
    const child = try ir.makeObject(
        page,
        "child",
        null,
        .text,
        .text,
        "this sentence is intentionally long enough to wrap when the group width is constrained",
    );
    try ir.setNodeProperty(child, "wrap", "on");
    const group = try ir.makeGroupWithOrigin(page, true, &.{child}, "group");
    try ir.setNodeProperty(group, "chrome_pad_x", "10");

    try ir.addAnchorConstraint(group, .left, .{ .page = .left }, 100, "group-left");
    try ir.addAnchorConstraint(group, .right, .{ .node = .{ .node_id = group, .anchor = .left } }, 220, "group-width");

    try solver.solveLayout(&ir);

    const group_node = ir.getNode(group).?;
    const child_node = ir.getNode(child).?;
    try expectFloat(100, group_node.frame.x);
    try expectFloat(220, group_node.frame.width);
    try expectFloat(110, child_node.frame.x);
    try expectFloat(200, child_node.frame.width);
}

test "layout diagnostics: fixed-height object reports content overflow" {
    var ir = try initEmptyIr();
    defer ir.deinit();

    const page = try ir.addPage("Page");
    const object = try ir.makeObject(page, "short-box", null, .text, .text, "line one\nline two");
    try ir.addAnchorConstraint(object, .left, .{ .page = .left }, 20, "left");
    try ir.addAnchorConstraint(object, .right, .{ .node = .{ .node_id = object, .anchor = .left } }, 200, "width");
    try ir.addAnchorConstraint(object, .bottom, .{ .page = .bottom }, 20, "bottom");
    try ir.addAnchorConstraint(object, .top, .{ .node = .{ .node_id = object, .anchor = .bottom } }, 20, "height");

    try solver.solveLayout(&ir);

    const node = ir.getNode(object).?;
    try expectFloat(20, node.frame.height);
    const required_height = metrics.intrinsicHeight(&ir, node);
    try testing.expect(required_height > node.frame.height);

    var found = false;
    for (ir.diagnostics.items) |diagnostic| {
        if (diagnostic.node_id != object) continue;
        switch (diagnostic.data) {
            .content_overflow => |data| {
                found = true;
                try testing.expectEqual(core.DiagnosticSeverity.warning, diagnostic.severity);
                try expectFloat(required_height, data.required_height);
                try expectFloat(node.frame.height, data.frame_height);
                try expectFloat(required_height - node.frame.height, data.overflow_height);
            },
            else => {},
        }
    }
    try testing.expect(found);
}

test "layout diagnostics: one-pixel text reports content overflow" {
    var ir = try initEmptyIr();
    defer ir.deinit();

    const page = try ir.addPage("Page");
    const object = try ir.makeObject(page, "toc-marker", null, .text, .text, "hidden section title");
    try ir.setNodeProperty(object, "layout_font_size", "1");
    try ir.setNodeProperty(object, "layout_line_height", "1");
    try ir.setNodeProperty(object, "text_size", "1");
    try ir.setNodeProperty(object, "text_line_height", "1");
    try ir.setNodeProperty(object, "wrap", "on");
    try ir.addAnchorConstraint(object, .left, .{ .page = .left }, 20, "left");
    try ir.addAnchorConstraint(object, .right, .{ .node = .{ .node_id = object, .anchor = .left } }, 1, "width");
    try ir.addAnchorConstraint(object, .bottom, .{ .page = .bottom }, 20, "bottom");
    try ir.addAnchorConstraint(object, .top, .{ .node = .{ .node_id = object, .anchor = .bottom } }, 1, "height");

    try solver.solveLayout(&ir);

    var found = false;
    for (ir.diagnostics.items) |diagnostic| {
        if (diagnostic.node_id == object and diagnostic.data == .content_overflow) found = true;
    }
    try testing.expect(found);
}

test "layout metrics use enlarged rendered text size" {
    var ir = try initEmptyIr();
    defer ir.deinit();

    const page = try ir.addPage("Page");
    const object = try ir.makeObject(page, "body", null, .text, .text, "one\ntwo");
    try ir.setNodeProperty(object, "layout_font_size", "20");
    try ir.setNodeProperty(object, "layout_line_height", "28");
    try ir.setNodeProperty(object, "text_size", "30");
    try ir.setNodeProperty(object, "text_line_height", "45");

    const node = ir.getNode(object).?;
    try expectFloat(90, metrics.intrinsicHeight(&ir, node));
}

test "render policy: invalid numeric properties fall back before rendering" {
    var ir = try initEmptyIr();
    defer ir.deinit();

    const page = try ir.addPage("Page");
    const object = try ir.makeObject(page, "bad-numbers", null, .text, .text, "Hello");
    try ir.setNodeProperty(object, "text_size", "-1");
    try ir.setNodeProperty(object, "text_line_height", "nan");
    try ir.setNodeProperty(object, "text_inline_math_height_factor", "0");
    try ir.setNodeProperty(object, "chrome_pad_x", "-10");
    try ir.setNodeProperty(object, "chrome_pad_y", "inf");
    try ir.setNodeProperty(object, "chrome_line_width", "-2");
    try ir.setNodeProperty(object, "underline_width", "-1");
    try ir.setNodeProperty(object, "rule_line_width", "-1");
    try ir.setNodeProperty(object, "rule_dash", "inf, 4");

    const resolved = core.render_policy.resolve(&ir, ir.getNode(object).?);
    const text = resolved.text.?;
    try expectFloat(20, text.font_size);
    try expectFloat(28, text.line_height);
    try expectFloat(1, text.inline_math_height_factor);
    try expectFloat(0, resolved.chrome.pad_x);
    try expectFloat(0, resolved.chrome.pad_y);
    try expectFloat(0, resolved.chrome.line_width);
    try expectFloat(0, resolved.underline.width);
    try expectFloat(0, resolved.rule.line_width);
    try testing.expect(resolved.rule.dash == null);
}

test "render policy: math alignment applies to markdown and vector math" {
    var ir = try initEmptyIr();
    defer ir.deinit();

    const page = try ir.addPage("Page");
    const text_object = try ir.makeObject(page, "body", null, .text, .text, "$$x^2$$");
    try ir.setNodeProperty(text_object, "math_align", "left");

    var resolved_text = core.render_policy.resolve(&ir, ir.getNode(text_object).?);
    try testing.expectEqual(core.render_policy.HorizontalAlign.left, resolved_text.text.?.math_align);

    try ir.setNodeProperty(text_object, "math_align", "sideways");
    resolved_text = core.render_policy.resolve(&ir, ir.getNode(text_object).?);
    try testing.expectEqual(core.render_policy.HorizontalAlign.center, resolved_text.text.?.math_align);

    try ir.setNodeProperty(ir.document_id, "math_align", "right");
    const document_text_object = try ir.makeObject(page, "body", null, .text, .text, "$$a^2$$");
    const resolved_document_text = core.render_policy.resolve(&ir, ir.getNode(document_text_object).?);
    try testing.expectEqual(core.render_policy.HorizontalAlign.right, resolved_document_text.text.?.math_align);

    try ir.setNodeProperty(page, "math_align", "left");
    const page_text_object = try ir.makeObject(page, "body", null, .text, .text, "$$b^2$$");
    const resolved_page_text = core.render_policy.resolve(&ir, ir.getNode(page_text_object).?);
    try testing.expectEqual(core.render_policy.HorizontalAlign.left, resolved_page_text.text.?.math_align);

    const math_object = try ir.makeObject(page, "math_tex", null, .text, .text, "\\int_0^1 x^2 \\, dx");
    try ir.setNodeProperty(math_object, "render_kind", "vector_math");
    try ir.setNodeProperty(math_object, "math_align", "right");

    const resolved_math = core.render_policy.resolve(&ir, ir.getNode(math_object).?);
    try testing.expectEqual(core.render_policy.HorizontalAlign.right, resolved_math.math.?.horizontal_align);
}
