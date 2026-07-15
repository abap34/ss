const std = @import("std");
const ast = @import("ast");
const core = @import("core");
const model = @import("model");

const graph = core.layout.graph;
const metrics = core.layout.metrics;
const solver = core.layout.solver;

const testing = std.testing;

fn initEmptyContext() !core.Context {
    const allocator = testing.allocator;
    const asset_base_dir = try allocator.dupe(u8, ".");
    errdefer allocator.free(asset_base_dir);
    const project_path = try allocator.dupe(u8, "unit-test.ss");
    errdefer allocator.free(project_path);
    const project_source = try allocator.dupe(u8, "");
    errdefer allocator.free(project_source);
    return try core.Context.init(allocator, asset_base_dir, project_path, project_source, ast.Module.init());
}

fn expectFloat(expected: f32, actual: f32) !void {
    try testing.expectApproxEqAbs(expected, actual, 0.0001);
}

fn expectColor(expected_r: f32, expected_g: f32, expected_b: f32, actual: core.render_policy.Color) !void {
    try expectFloat(expected_r, actual.r);
    try expectFloat(expected_g, actual.g);
    try expectFloat(expected_b, actual.b);
}

fn setStringField(ir: *core.Context, node_id: model.NodeId, key: []const u8, value: []const u8) !void {
    try ir.setNodeFieldValue(node_id, key, .{ .string = value });
}

fn setNumberField(ir: *core.Context, node_id: model.NodeId, key: []const u8, value: f32) !void {
    try ir.setNodeFieldValue(node_id, key, .{ .number = value });
}

fn setEnumField(ir: *core.Context, node_id: model.NodeId, key: []const u8, enum_name: []const u8, case_name: []const u8) !void {
    try ir.setNodeFieldValue(node_id, key, .{ .enum_case = .{
        .enum_name = enum_name,
        .case_name = case_name,
    } });
}

fn setRecordStringField(ir: *core.Context, node_id: model.NodeId, root_key: []const u8, field_name: []const u8, value: []const u8) !void {
    try setRecordFieldValue(ir, node_id, root_key, field_name, .{ .string = value });
}

fn setRecordNumberField(ir: *core.Context, node_id: model.NodeId, root_key: []const u8, field_name: []const u8, value: f32) !void {
    try setRecordFieldValue(ir, node_id, root_key, field_name, .{ .number = value });
}

fn setRecordEnumField(
    ir: *core.Context,
    node_id: model.NodeId,
    root_key: []const u8,
    field_name: []const u8,
    enum_name: []const u8,
    case_name: []const u8,
) !void {
    try setRecordFieldValue(ir, node_id, root_key, field_name, .{ .enum_case = .{
        .enum_name = enum_name,
        .case_name = case_name,
    } });
}

fn setRecordFieldValue(ir: *core.Context, node_id: model.NodeId, root_key: []const u8, field_name: []const u8, value: core.Value) !void {
    try setRecordPathValue(ir, node_id, root_key, &.{field_name}, value);
}

fn setRecordPathValue(ir: *core.Context, node_id: model.NodeId, root_key: []const u8, path: []const []const u8, value: core.Value) !void {
    const node = ir.getNode(node_id) orelse return error.UnknownNode;
    for (node.fields.items) |*field| {
        if (!std.mem.eql(u8, field.key, root_key)) continue;
        if (field.value != .record) return error.ExpectedRecordField;
        try putRecordPathValue(ir.allocator, &field.value.record, path, value);
        return;
    }

    var record = core.RecordValue.init(recordTypeName(root_key));
    defer record.deinit(ir.allocator);
    try putRecordPathValue(ir.allocator, &record, path, value);
    try ir.setNodeFieldValue(node_id, root_key, .{ .record = record });
}

fn putRecordPathValue(allocator: std.mem.Allocator, record: *core.RecordValue, path: []const []const u8, value: core.Value) !void {
    if (path.len == 0) return error.ExpectedRecordField;
    if (path.len == 1) return putRecordFieldValue(allocator, record, path[0], value);

    for (record.fields.items) |*field| {
        if (!std.mem.eql(u8, field.name, path[0])) continue;
        if (field.value != .record) return error.ExpectedRecordField;
        return putRecordPathValue(allocator, &field.value.record, path[1..], value);
    }

    var nested = core.RecordValue.init(recordTypeName(path[0]));
    errdefer nested.deinit(allocator);
    try putRecordPathValue(allocator, &nested, path[1..], value);
    try record.fields.append(allocator, .{
        .name = path[0],
        .value = .{ .record = nested },
        .explicit = true,
    });
}

fn putRecordFieldValue(allocator: std.mem.Allocator, record: *core.RecordValue, field_name: []const u8, value: core.Value) !void {
    for (record.fields.items) |*field| {
        if (!std.mem.eql(u8, field.name, field_name)) continue;
        field.value.deinit(allocator);
        field.value = try value.clone(allocator);
        field.explicit = true;
        return;
    }
    try record.fields.append(allocator, .{
        .name = field_name,
        .value = try value.clone(allocator),
        .explicit = true,
    });
}

fn recordTypeName(root_key: []const u8) []const u8 {
    if (std.mem.eql(u8, root_key, "layout")) return "LayoutStyle";
    if (std.mem.eql(u8, root_key, "text")) return "TextStyle";
    if (std.mem.eql(u8, root_key, "chrome")) return "ChromeStyle";
    if (std.mem.eql(u8, root_key, "rule")) return "RuleStyle";
    if (std.mem.eql(u8, root_key, "shape")) return "ShapeStyle";
    if (std.mem.eql(u8, root_key, "math")) return "MathStyle";
    return root_key;
}

fn setLayoutPolicy(ir: *core.Context, node_id: model.NodeId, case_name: []const u8) !void {
    try setEnumField(ir, node_id, "layout_v", "LayoutPolicy", case_name);
}

fn setLayoutCenterOffset(ir: *core.Context, node_id: model.NodeId, value: []const u8) !void {
    try setStringField(ir, node_id, "layout_v_center_offset", value);
}

fn setRenderKind(ir: *core.Context, node_id: model.NodeId, case_name: []const u8) !void {
    try setEnumField(ir, node_id, "render_kind", "RenderKind", case_name);
}

fn setMathAlign(ir: *core.Context, node_id: model.NodeId, case_name: []const u8) !void {
    try setEnumField(ir, node_id, "math_align", "Align", case_name);
}

fn setLayoutWrap(ir: *core.Context, node_id: model.NodeId, case_name: []const u8) !void {
    try setRecordEnumField(ir, node_id, "layout", "wrap", "WrapMode", case_name);
}

fn setLayoutFontSize(ir: *core.Context, node_id: model.NodeId, value: []const u8) !void {
    try setRecordStringField(ir, node_id, "layout", "font_size", value);
}

fn setLayoutLineHeight(ir: *core.Context, node_id: model.NodeId, value: []const u8) !void {
    try setRecordStringField(ir, node_id, "layout", "line_height", value);
}

fn setLayoutSpacingAfter(ir: *core.Context, node_id: model.NodeId, value: []const u8) !void {
    try setRecordStringField(ir, node_id, "layout", "spacing_after", value);
}

fn setTextParse(ir: *core.Context, node_id: model.NodeId, case_name: []const u8) !void {
    try setRecordEnumField(ir, node_id, "text", "parse", "TextParseMode", case_name);
}

fn setTextSize(ir: *core.Context, node_id: model.NodeId, value: []const u8) !void {
    try setRecordStringField(ir, node_id, "text", "size", value);
}

fn setTextLineHeight(ir: *core.Context, node_id: model.NodeId, value: []const u8) !void {
    try setRecordStringField(ir, node_id, "text", "line_height", value);
}

fn setTextInlineMathHeightFactor(ir: *core.Context, node_id: model.NodeId, value: []const u8) !void {
    try setRecordStringField(ir, node_id, "text", "inline_math_height_factor", value);
}

fn setTextMarkdownBoldColor(ir: *core.Context, node_id: model.NodeId, value: []const u8) !void {
    try setRecordStringField(ir, node_id, "text", "markdown_bold_color", value);
}

fn setTextMarkdownBoldWeight(ir: *core.Context, node_id: model.NodeId, value: []const u8) !void {
    try setRecordStringField(ir, node_id, "text", "bold_weight", value);
}

fn setTextMarkdownItalicStyle(ir: *core.Context, node_id: model.NodeId, case_name: []const u8) !void {
    try setRecordEnumField(ir, node_id, "text", "italic_style", "FontStyle", case_name);
}

fn setTextFontFamily(ir: *core.Context, node_id: model.NodeId, value: []const u8) !void {
    try setRecordPathValue(ir, node_id, "text", &.{ "font", "family" }, .{ .string = value });
}

fn setTextFontWeight(ir: *core.Context, node_id: model.NodeId, value: []const u8) !void {
    try setRecordPathValue(ir, node_id, "text", &.{ "font", "weight" }, .{ .string = value });
}

fn setTextFontStyle(ir: *core.Context, node_id: model.NodeId, case_name: []const u8) !void {
    try setRecordPathValue(ir, node_id, "text", &.{ "font", "style" }, .{ .enum_case = .{ .enum_name = "FontStyle", .case_name = case_name } });
}

fn setTextFontStretch(ir: *core.Context, node_id: model.NodeId, case_name: []const u8) !void {
    try setRecordPathValue(ir, node_id, "text", &.{ "font", "stretch" }, .{ .enum_case = .{ .enum_name = "FontStretch", .case_name = case_name } });
}

fn setTextCodeFontFamily(ir: *core.Context, node_id: model.NodeId, value: []const u8) !void {
    try setRecordPathValue(ir, node_id, "text", &.{ "code_font", "family" }, .{ .string = value });
}

fn setTextCodeFontWeight(ir: *core.Context, node_id: model.NodeId, value: []const u8) !void {
    try setRecordPathValue(ir, node_id, "text", &.{ "code_font", "weight" }, .{ .string = value });
}

fn setChromePadX(ir: *core.Context, node_id: model.NodeId, value: []const u8) !void {
    try setRecordStringField(ir, node_id, "chrome", "pad_x", value);
}

fn setChromePadY(ir: *core.Context, node_id: model.NodeId, value: []const u8) !void {
    try setRecordStringField(ir, node_id, "chrome", "pad_y", value);
}

fn setChromeLineWidth(ir: *core.Context, node_id: model.NodeId, value: []const u8) !void {
    try setRecordStringField(ir, node_id, "chrome", "line_width", value);
}

fn setUnderlineWidth(ir: *core.Context, node_id: model.NodeId, value: []const u8) !void {
    try setRecordStringField(ir, node_id, "underline", "width", value);
}

fn setRuleLineWidth(ir: *core.Context, node_id: model.NodeId, value: []const u8) !void {
    try setRecordStringField(ir, node_id, "rule", "line_width", value);
}

fn setRuleDash(ir: *core.Context, node_id: model.NodeId, value: []const u8) !void {
    try setRecordStringField(ir, node_id, "rule", "dash", value);
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
    try testing.expectError(error.NegativeFrameSize, graph.reconcileAxisState(&negative));
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

test "layout graph spec: hard anchors move default-sized states" {
    const constraint = model.Constraint{
        .target_node = 2,
        .target_anchor = .center_y,
        .source = .{ .node = .{ .node_id = 1, .anchor = .center_y } },
        .offset = 0,
    };

    var state = model.AxisState{
        .start = 10,
        .end = 50,
        .center = 30,
        .size = 40,
        .size_is_default = true,
    };

    try testing.expect(try graph.moveDefaultSizedAnchor(&state, .center_y, 80, constraint));
    try expectFloat(80, state.center.?);
    try expectFloat(40, state.size.?);
    try testing.expect(state.start == null);
    try testing.expect(state.end == null);

    try testing.expect(try graph.reconcileAxisState(&state));
    try expectFloat(60, state.start.?);
    try expectFloat(100, state.end.?);
}

test "layout graph spec: page graph indexes direct page children and filters axis constraints" {
    var ir = try initEmptyContext();
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

test "layout graph spec: implicit constraint objects stay page local" {
    var ir = try initEmptyContext();
    defer ir.deinit();

    const first_page = try ir.addPage("First");
    const second_page = try ir.addPage("Second");
    const placed = try ir.makeObject(first_page, "placed", null, .text, .text, "placed");
    const helper = try ir.createObjectWithOrigin("helper", null, .text, .text, "helper", null);
    const foreign = try ir.makeObject(second_page, "foreign", null, .text, .text, "foreign");
    try ir.addAnchorConstraint(placed, .top, .{ .node = .{ .node_id = helper, .anchor = .top } }, 10, "helper-top");
    try ir.addAnchorConstraint(placed, .left, .{ .node = .{ .node_id = foreign, .anchor = .left } }, 20, "foreign-left");

    var first_graph = try graph.PageLayoutGraph.init(testing.allocator, &ir, first_page);
    defer first_graph.deinit();
    try testing.expect(first_graph.indexOf(placed) != null);
    try testing.expect(first_graph.indexOf(helper) == null);
    try testing.expect(first_graph.indexOf(foreign) == null);

    var second_graph = try graph.PageLayoutGraph.init(testing.allocator, &ir, second_page);
    defer second_graph.deinit();
    try testing.expect(second_graph.indexOf(foreign) != null);
    try testing.expect(second_graph.indexOf(placed) == null);
}

test "layout graph spec: constraint classification names layout dependency roles" {
    var ir = try initEmptyContext();
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
    var ir = try initEmptyContext();
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
    var self_conflict = try initEmptyContext();
    defer self_conflict.deinit();

    const self_page = try self_conflict.addPage("Page");
    const object = try self_conflict.makeObject(self_page, "body", null, .text, .text, "A");
    try self_conflict.addAnchorConstraint(object, .top, .{ .node = .{ .node_id = object, .anchor = .top } }, 100, "self-top");
    try testing.expectError(error.ConstraintConflict, self_conflict.finalize());

    var cycle = try initEmptyContext();
    defer cycle.deinit();

    const cycle_page = try cycle.addPage("Page");
    const a = try cycle.makeObject(cycle_page, "a", null, .text, .text, "A");
    const b = try cycle.makeObject(cycle_page, "b", null, .text, .text, "B");
    try cycle.addAnchorConstraint(a, .top, .{ .node = .{ .node_id = b, .anchor = .top } }, 10, "a-top");
    try cycle.addAnchorConstraint(b, .top, .{ .node = .{ .node_id = a, .anchor = .top } }, 10, "b-top");
    try testing.expectError(error.ConstraintConflict, cycle.finalize());
}

test "layout solver: consistent constraint cycles are fixed by fallback placement" {
    var ir = try initEmptyContext();
    defer ir.deinit();

    const page = try ir.addPage("Page");
    const a = try ir.makeObject(page, "a", null, .text, .text, "A");
    const b = try ir.makeObject(page, "b", null, .text, .text, "B");
    try ir.addAnchorConstraint(a, .top, .{ .node = .{ .node_id = b, .anchor = .top } }, 0, "a-top");
    try ir.addAnchorConstraint(b, .top, .{ .node = .{ .node_id = a, .anchor = .top } }, 0, "b-top");

    try ir.finalize();

    const a_node = ir.getNode(a).?;
    const b_node = ir.getNode(b).?;
    try testing.expect(a_node.frame.y_set);
    try testing.expect(b_node.frame.y_set);
    try expectFloat(graph.anchorValue(a_node.frame, .top), graph.anchorValue(b_node.frame, .top));
    try testing.expect(!ir.hasConstraintFailures());
}

test "layout solver: tautological self-anchor constraints do not block fallback placement" {
    var ir = try initEmptyContext();
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

test "layout solver: vertical fallback tries alternate roots in incomplete components" {
    var ir = try initEmptyContext();
    defer ir.deinit();

    const page = try ir.addPage("Page");
    const panel = try ir.makeObject(page, "panel", null, .text, .text, "");
    const body = try ir.makeObject(page, "body", null, .text, .text, "content");
    try ir.addAnchorConstraint(panel, .left, .{ .page = .left }, 52, "panel-left");
    try ir.addAnchorConstraint(panel, .right, .{ .page = .right }, -52, "panel-right");
    try ir.addAnchorConstraint(body, .left, .{ .page = .left }, 72, "body-left");
    try ir.addAnchorConstraint(body, .right, .{ .page = .right }, -72, "body-right");
    try ir.addAnchorConstraint(panel, .top, .{ .node = .{ .node_id = body, .anchor = .top } }, 16, "panel-top");
    try ir.addAnchorConstraint(panel, .bottom, .{ .node = .{ .node_id = body, .anchor = .bottom } }, -16, "panel-bottom");

    try ir.finalize();

    const panel_node = ir.getNode(panel).?;
    const body_node = ir.getNode(body).?;
    try testing.expect(panel_node.frame.y_set);
    try testing.expect(body_node.frame.y_set);
    try expectFloat(graph.anchorValue(body_node.frame, .top) + 16, graph.anchorValue(panel_node.frame, .top));
    try expectFloat(graph.anchorValue(body_node.frame, .bottom) - 16, graph.anchorValue(panel_node.frame, .bottom));
    try testing.expect(!ir.hasConstraintFailures());
}

test "layout solver: constraint-referenced objects participate in fallback placement" {
    var ir = try initEmptyContext();
    defer ir.deinit();

    const page = try ir.addPage("Page");
    const placed = try ir.makeObject(page, "placed", null, .text, .text, "placed");
    const referenced = try ir.makeObject(page, "referenced", null, .text, .text, "referenced");
    try ir.addAnchorConstraint(placed, .top, .{ .node = .{ .node_id = referenced, .anchor = .top } }, 10, "placed-top");

    try ir.finalize();

    const placed_node = ir.getNode(placed).?;
    const referenced_node = ir.getNode(referenced).?;
    try testing.expect(placed_node.frame.y_set);
    try testing.expect(referenced_node.frame.y_set);
    try expectFloat(graph.anchorValue(referenced_node.frame, .top) + 10, graph.anchorValue(placed_node.frame, .top));
    try testing.expect(!ir.hasConstraintFailures());
}

test "layout solver: size-only constraints still receive fallback placement" {
    var ir = try initEmptyContext();
    defer ir.deinit();

    const page = try ir.addPage("Page");
    const object = try ir.makeObject(page, "body", null, .text, .text, "content");
    try ir.addAnchorConstraint(object, .right, .{ .node = .{ .node_id = object, .anchor = .left } }, 240, "object-width");
    try ir.addAnchorConstraint(object, .top, .{ .node = .{ .node_id = object, .anchor = .bottom } }, 96, "object-height");

    try ir.finalize();

    const node = ir.getNode(object).?;
    try testing.expect(node.frame.x_set);
    try testing.expect(node.frame.y_set);
    try expectFloat(240, node.frame.width);
    try expectFloat(96, node.frame.height);
    try testing.expect(!ir.hasConstraintFailures());
}

test "layout solver: page-dependent group children receive local vertical fallback" {
    var ir = try initEmptyContext();
    defer ir.deinit();

    const page = try ir.addPage("Page");
    const ruler = try ir.makeObject(page, "rule", null, .text, .text, "");
    const title = try ir.makeObject(page, "title", null, .text, .text, "Title");
    const body = try ir.makeObject(page, "body", null, .text, .text, "Body");
    _ = try ir.makeGroupWithOrigin(page, true, &.{ ruler, title }, "head");
    try setLayoutLineHeight(&ir, ruler, "4");
    try setLayoutSpacingAfter(&ir, ruler, "12");
    try ir.addAnchorConstraint(ruler, .top, .{ .page = .top }, -200, "rule-top");

    try ir.finalize();

    const ruler_node = ir.getNode(ruler).?;
    const title_node = ir.getNode(title).?;
    const body_node = ir.getNode(body).?;
    try testing.expect(ruler_node.frame.y_set);
    try testing.expect(title_node.frame.y_set);
    try testing.expect(body_node.frame.y_set);
    try expectFloat(graph.anchorValue(ruler_node.frame, .bottom) - 12, graph.anchorValue(title_node.frame, .top));
    try expectFloat(graph.anchorValue(title_node.frame, .bottom) - core.layout.styleForNode(&ir, title_node).spacing_after, graph.anchorValue(body_node.frame, .top));
    try testing.expect(!ir.hasConstraintFailures());
}

test "layout solver: page-dependent group children before fixed anchors receive fallback" {
    var ir = try initEmptyContext();
    defer ir.deinit();

    const page = try ir.addPage("Page");
    const title = try ir.makeObject(page, "title", null, .text, .text, "Title");
    const ruler = try ir.makeObject(page, "rule", null, .text, .text, "");
    _ = try ir.makeGroupWithOrigin(page, true, &.{ title, ruler }, "head");
    try setLayoutSpacingAfter(&ir, title, "12");
    try setLayoutLineHeight(&ir, ruler, "4");
    try ir.addAnchorConstraint(ruler, .top, .{ .page = .top }, -200, "rule-top");

    try ir.finalize();

    const title_node = ir.getNode(title).?;
    const ruler_node = ir.getNode(ruler).?;
    try testing.expect(title_node.frame.y_set);
    try testing.expect(ruler_node.frame.y_set);
    try expectFloat(graph.anchorValue(ruler_node.frame, .top) + 12, graph.anchorValue(title_node.frame, .bottom));
    try testing.expect(!ir.hasConstraintFailures());
}

test "layout solver: page-dependent vertical cycles receive fallback placement" {
    var ir = try initEmptyContext();
    defer ir.deinit();

    const page = try ir.addPage("Page");
    const ruler = try ir.makeObject(page, "rule", null, .text, .text, "");
    const first = try ir.makeObject(page, "first", null, .text, .text, "A");
    const second = try ir.makeObject(page, "second", null, .text, .text, "B");
    _ = try ir.makeGroupWithOrigin(page, true, &.{ ruler, first, second }, "head");
    try setLayoutLineHeight(&ir, ruler, "4");
    try setLayoutSpacingAfter(&ir, ruler, "12");
    try ir.addAnchorConstraint(ruler, .top, .{ .page = .top }, -200, "rule-top");
    try ir.addAnchorConstraint(first, .top, .{ .node = .{ .node_id = second, .anchor = .top } }, 0, "first-cycle");
    try ir.addAnchorConstraint(second, .top, .{ .node = .{ .node_id = first, .anchor = .top } }, 0, "second-cycle");

    try ir.finalize();

    const ruler_node = ir.getNode(ruler).?;
    const first_node = ir.getNode(first).?;
    const second_node = ir.getNode(second).?;
    try testing.expect(first_node.frame.y_set);
    try testing.expect(second_node.frame.y_set);
    try expectFloat(graph.anchorValue(ruler_node.frame, .bottom) - 12, graph.anchorValue(first_node.frame, .top));
    try expectFloat(graph.anchorValue(first_node.frame, .top), graph.anchorValue(second_node.frame, .top));
    try testing.expect(!ir.hasConstraintFailures());
}

test "layout solver: page-dependent horizontal cycles receive fallback placement" {
    var ir = try initEmptyContext();
    defer ir.deinit();

    const page = try ir.addPage("Page");
    const ruler = try ir.makeObject(page, "rule", null, .text, .text, "");
    const first = try ir.makeObject(page, "first", null, .text, .text, "A");
    const second = try ir.makeObject(page, "second", null, .text, .text, "B");
    _ = try ir.makeGroupWithOrigin(page, true, &.{ ruler, first, second }, "head");
    try setLayoutLineHeight(&ir, ruler, "4");
    try ir.addAnchorConstraint(ruler, .left, .{ .page = .left }, 100, "rule-left");
    try ir.addAnchorConstraint(first, .left, .{ .node = .{ .node_id = second, .anchor = .left } }, 0, "first-cycle");
    try ir.addAnchorConstraint(second, .left, .{ .node = .{ .node_id = first, .anchor = .left } }, 0, "second-cycle");

    try ir.finalize();

    const first_node = ir.getNode(first).?;
    const second_node = ir.getNode(second).?;
    try testing.expect(first_node.frame.x_set);
    try testing.expect(second_node.frame.x_set);
    try expectFloat(first_node.frame.x, second_node.frame.x);
    try testing.expect(!ir.hasConstraintFailures());
}

test "layout solver: centered page-dependent group children receive local vertical fallback" {
    var ir = try initEmptyContext();
    defer ir.deinit();

    try setLayoutPolicy(&ir, ir.document_id, "center");

    const page = try ir.addPage("Page");
    const ruler = try ir.makeObject(page, "rule", null, .text, .text, "");
    const title = try ir.makeObject(page, "title", null, .text, .text, "Title");
    const body = try ir.makeObject(page, "body", null, .text, .text, "Body");
    _ = try ir.makeGroupWithOrigin(page, true, &.{ ruler, title }, "head");
    try setLayoutLineHeight(&ir, ruler, "4");
    try setLayoutSpacingAfter(&ir, ruler, "12");
    try setLayoutLineHeight(&ir, body, "500");
    try ir.addAnchorConstraint(ruler, .top, .{ .page = .top }, -200, "rule-top");

    try ir.finalize();

    const ruler_node = ir.getNode(ruler).?;
    const title_node = ir.getNode(title).?;
    const body_node = ir.getNode(body).?;
    try testing.expect(ruler_node.frame.y_set);
    try testing.expect(title_node.frame.y_set);
    try testing.expect(body_node.frame.y_set);
    try expectFloat(graph.anchorValue(ruler_node.frame, .bottom) - 12, graph.anchorValue(title_node.frame, .top));
    try expectFloat(graph.anchorValue(title_node.frame, .bottom) - core.layout.styleForNode(&ir, title_node).spacing_after, graph.anchorValue(body_node.frame, .top));
    try testing.expect(!ir.hasConstraintFailures());
}

test "layout solver: horizontal alignment alone does not imply vertical row alignment" {
    var stacked = try initEmptyContext();
    defer stacked.deinit();

    const stacked_page = try stacked.addPage("Page");
    const first = try stacked.makeObject(stacked_page, "first", null, .text, .text, "A");
    const second = try stacked.makeObject(stacked_page, "second", null, .text, .text, "B");
    _ = try stacked.makeGroupWithOrigin(stacked_page, true, &.{ first, second }, "group");
    try stacked.addAnchorConstraint(second, .left, .{ .node = .{ .node_id = first, .anchor = .left } }, 0, "same-left");

    try solver.solveLayout(&stacked);

    const first_node = stacked.getNode(first).?;
    const second_node = stacked.getNode(second).?;
    const first_spacing = core.layout.styleForNode(&stacked, first_node).spacing_after;
    try expectFloat(first_node.frame.y - first_spacing, second_node.frame.y + second_node.frame.height);

    var row = try initEmptyContext();
    defer row.deinit();

    const row_page = try row.addPage("Page");
    const left = try row.makeObject(row_page, "left", null, .text, .text, "A");
    const right = try row.makeObject(row_page, "right", null, .text, .text, "B");
    try row.addAnchorConstraint(right, .left, .{ .node = .{ .node_id = left, .anchor = .right } }, 30, "right-of-left");
    try row.addAnchorConstraint(right, .center_y, .{ .node = .{ .node_id = left, .anchor = .center_y } }, 0, "same-center-y");

    try solver.solveLayout(&row);

    const left_node = row.getNode(left).?;
    const right_node = row.getNode(right).?;
    try expectFloat(left_node.frame.y + left_node.frame.height / 2, right_node.frame.y + right_node.frame.height / 2);
}

test "layout solver: horizontal fallback seeds unconstrained peer anchors" {
    var ir = try initEmptyContext();
    defer ir.deinit();

    const page = try ir.addPage("Page");
    const title = try ir.makeObject(page, "title", null, .text, .text, "Title");
    const byline = try ir.makeObject(page, "byline", null, .text, .text, "Byline");
    try ir.addAnchorConstraint(title, .left, .{ .node = .{ .node_id = byline, .anchor = .left } }, 0, "same-left");

    try ir.finalize();

    const title_node = ir.getNode(title).?;
    const byline_node = ir.getNode(byline).?;
    try expectFloat(title_node.frame.x, byline_node.frame.x);
}

test "layout solver: same-target peer equalities form one fallback unit" {
    var ir = try initEmptyContext();
    defer ir.deinit();

    const page = try ir.addPage("Page");
    const a = try ir.makeObject(page, "a", null, .text, .text, "A");
    const b = try ir.makeObject(page, "b", null, .text, .text, "B");
    const c = try ir.makeObject(page, "c", null, .text, .text, "C");
    try ir.addAnchorConstraint(a, .top, .{ .node = .{ .node_id = b, .anchor = .top } }, 0, "a-is-b");
    try ir.addAnchorConstraint(a, .top, .{ .node = .{ .node_id = c, .anchor = .top } }, 0, "a-is-c");

    try ir.finalize();

    const a_node = ir.getNode(a).?;
    const b_node = ir.getNode(b).?;
    const c_node = ir.getNode(c).?;
    try expectFloat(graph.anchorValue(a_node.frame, .top), graph.anchorValue(b_node.frame, .top));
    try expectFloat(graph.anchorValue(a_node.frame, .top), graph.anchorValue(c_node.frame, .top));
    try testing.expect(!ir.hasConstraintFailures());
}

test "layout solver: chained peer equalities form one fallback unit" {
    var ir = try initEmptyContext();
    defer ir.deinit();

    const page = try ir.addPage("Page");
    const a = try ir.makeObject(page, "a", null, .text, .text, "A");
    const b = try ir.makeObject(page, "b", null, .text, .text, "B");
    const c = try ir.makeObject(page, "c", null, .text, .text, "C");
    try ir.addAnchorConstraint(a, .top, .{ .node = .{ .node_id = b, .anchor = .top } }, 0, "a-is-b");
    try ir.addAnchorConstraint(b, .top, .{ .node = .{ .node_id = c, .anchor = .top } }, 0, "b-is-c");

    try ir.finalize();

    const a_node = ir.getNode(a).?;
    const b_node = ir.getNode(b).?;
    const c_node = ir.getNode(c).?;
    try expectFloat(graph.anchorValue(a_node.frame, .top), graph.anchorValue(b_node.frame, .top));
    try expectFloat(graph.anchorValue(a_node.frame, .top), graph.anchorValue(c_node.frame, .top));
    try testing.expect(!ir.hasConstraintFailures());
}

test "layout solver: hard peer equality conflicts are independent of direction and chaining" {
    var forward = try initEmptyContext();
    defer forward.deinit();

    const forward_page = try forward.addPage("Page");
    const forward_a = try forward.makeObject(forward_page, "a", null, .text, .text, "A");
    const forward_b = try forward.makeObject(forward_page, "b", null, .text, .text, "B");
    try forward.addAnchorConstraint(forward_a, .top, .{ .page = .top }, -100, "a-top");
    try forward.addAnchorConstraint(forward_b, .top, .{ .page = .top }, -200, "b-top");
    try forward.addAnchorConstraint(forward_a, .top, .{ .node = .{ .node_id = forward_b, .anchor = .top } }, 0, "a-is-b");
    try testing.expectError(error.ConstraintConflict, forward.finalize());

    var reverse = try initEmptyContext();
    defer reverse.deinit();

    const reverse_page = try reverse.addPage("Page");
    const reverse_a = try reverse.makeObject(reverse_page, "a", null, .text, .text, "A");
    const reverse_b = try reverse.makeObject(reverse_page, "b", null, .text, .text, "B");
    try reverse.addAnchorConstraint(reverse_a, .top, .{ .page = .top }, -100, "a-top");
    try reverse.addAnchorConstraint(reverse_b, .top, .{ .page = .top }, -200, "b-top");
    try reverse.addAnchorConstraint(reverse_b, .top, .{ .node = .{ .node_id = reverse_a, .anchor = .top } }, 0, "b-is-a");
    try testing.expectError(error.ConstraintConflict, reverse.finalize());

    var chain = try initEmptyContext();
    defer chain.deinit();

    const chain_page = try chain.addPage("Page");
    const chain_a = try chain.makeObject(chain_page, "a", null, .text, .text, "A");
    const chain_b = try chain.makeObject(chain_page, "b", null, .text, .text, "B");
    const chain_c = try chain.makeObject(chain_page, "c", null, .text, .text, "C");
    try chain.addAnchorConstraint(chain_a, .top, .{ .page = .top }, -100, "a-top");
    try chain.addAnchorConstraint(chain_c, .top, .{ .page = .top }, -200, "c-top");
    try chain.addAnchorConstraint(chain_a, .top, .{ .node = .{ .node_id = chain_b, .anchor = .top } }, 0, "a-is-b");
    try chain.addAnchorConstraint(chain_b, .top, .{ .node = .{ .node_id = chain_c, .anchor = .top } }, 0, "b-is-c");
    try testing.expectError(error.ConstraintConflict, chain.finalize());
}

test "layout solver: horizontal fallback does not seed inconsistent hard cycles" {
    var ir = try initEmptyContext();
    defer ir.deinit();

    const page = try ir.addPage("Page");
    const a = try ir.makeObject(page, "a", null, .text, .text, "aa");
    const b = try ir.makeObject(page, "b", null, .text, .text, "bb");
    try ir.addAnchorConstraint(a, .left, .{ .node = .{ .node_id = b, .anchor = .left } }, 100, "a-left");
    try ir.addAnchorConstraint(b, .left, .{ .node = .{ .node_id = a, .anchor = .left } }, 200, "b-left");

    try testing.expectError(error.ConstraintConflict, ir.finalize());
}

test "layout solver: constrained group source forms one fallback unit" {
    var ir = try initEmptyContext();
    defer ir.deinit();

    try setLayoutPolicy(&ir, ir.document_id, "center");

    const page = try ir.addPage("Page");
    const left_title = try ir.makeObject(page, "left-title", null, .text, .text, "Left");
    const left_body = try ir.makeObject(page, "left-body", null, .text, .text, "Body");
    const right = try ir.makeObject(page, "right", null, .text, .text, "Right");
    const left_group = try ir.makeGroupWithOrigin(ir.document_id, false, &.{ left_title, left_body }, "left-group");

    try ir.addAnchorConstraint(right, .left, .{ .node = .{ .node_id = left_group, .anchor = .right } }, 30, "right-of-group");
    try ir.addAnchorConstraint(right, .center_y, .{ .node = .{ .node_id = left_group, .anchor = .center_y } }, 0, "align-group-center");

    try ir.finalize();

    const group_node = ir.getNode(left_group).?;
    const left_title_node = ir.getNode(left_title).?;
    const left_body_node = ir.getNode(left_body).?;
    const right_node = ir.getNode(right).?;
    try testing.expect(group_node.frame.x_set);
    try testing.expect(group_node.frame.y_set);
    try expectFloat(group_node.frame.x + group_node.frame.width + 30, right_node.frame.x);
    try expectFloat(group_node.frame.y + group_node.frame.height / 2, right_node.frame.y + right_node.frame.height / 2);

    const title_spacing = core.layout.styleForNode(&ir, left_title_node).spacing_after;
    try expectFloat(left_title_node.frame.y - title_spacing, left_body_node.frame.y + left_body_node.frame.height);
}

test "layout solver: centered vflow treats vertically aligned groups as one row" {
    var ir = try initEmptyContext();
    defer ir.deinit();

    try setLayoutPolicy(&ir, ir.document_id, "center");

    const page = try ir.addPage("Page");
    const left_title = try ir.makeObject(page, "left-title", null, .text, .text, "Left");
    const left_body = try ir.makeObject(page, "left-body", null, .text, .text, "Body");
    const right_title = try ir.makeObject(page, "right-title", null, .text, .text, "Right");
    const right_body = try ir.makeObject(page, "right-body", null, .text, .text, "Body");
    const left_group = try ir.makeGroupWithOrigin(ir.document_id, false, &.{ left_title, left_body }, "left-group");
    const right_group = try ir.makeGroupWithOrigin(ir.document_id, false, &.{ right_title, right_body }, "right-group");

    try setLayoutLineHeight(&ir, left_title, "40");
    try setLayoutLineHeight(&ir, left_body, "200");
    try setLayoutLineHeight(&ir, right_title, "40");
    try setLayoutLineHeight(&ir, right_body, "200");
    try setLayoutSpacingAfter(&ir, left_title, "20");
    try setLayoutSpacingAfter(&ir, right_title, "20");
    try setLayoutSpacingAfter(&ir, left_body, "0");
    try setLayoutSpacingAfter(&ir, right_body, "0");

    try ir.addAnchorConstraint(right_group, .left, .{ .node = .{ .node_id = left_group, .anchor = .right } }, 30, "right-of-left-group");
    try ir.addAnchorConstraint(right_group, .center_y, .{ .node = .{ .node_id = left_group, .anchor = .center_y } }, 0, "align-group-centers");

    try ir.finalize();

    const left_group_node = ir.getNode(left_group).?;
    const right_group_node = ir.getNode(right_group).?;
    const left_center = left_group_node.frame.y + left_group_node.frame.height / 2;
    const right_center = right_group_node.frame.y + right_group_node.frame.height / 2;
    try expectFloat(left_center, right_center);

    const row_top = @max(left_group_node.frame.y + left_group_node.frame.height, right_group_node.frame.y + right_group_node.frame.height);
    const row_bottom = @min(left_group_node.frame.y, right_group_node.frame.y);
    try expectFloat(model.PageLayout.height / 2, (row_top + row_bottom) / 2);
}

test "layout solver: centered vflow clamps below fixed top components only when needed" {
    var ir = try initEmptyContext();
    defer ir.deinit();

    try setLayoutPolicy(&ir, ir.document_id, "center");

    const page = try ir.addPage("Page");
    const header = try ir.makeObject(page, "title", null, .text, .text, "Title");
    const body = try ir.makeObject(page, "body", null, .text, .text, "Body");

    try setLayoutLineHeight(&ir, header, "44");
    try setLayoutSpacingAfter(&ir, header, "40");
    try setLayoutLineHeight(&ir, body, "580");
    try ir.addAnchorConstraint(header, .top, .{ .page = .top }, -56, "header-top");

    try solver.solveLayout(&ir);

    const header_node = ir.getNode(header).?;
    const body_node = ir.getNode(body).?;
    const header_bottom = header_node.frame.y;
    const body_top = body_node.frame.y + body_node.frame.height;
    const header_spacing = core.layout.styleForNode(&ir, header_node).spacing_after;
    try expectFloat(header_bottom - header_spacing, body_top);
}

test "layout solver: document centered vflow is not shadowed by page default policy" {
    var ir = try initEmptyContext();
    defer ir.deinit();

    try setLayoutPolicy(&ir, ir.document_id, "center");
    try setLayoutCenterOffset(&ir, ir.document_id, "40");

    const page = try ir.addPage("Page");
    const pageno = try ir.makeObject(page, "pageno", null, .text, .text, "1");
    const title = try ir.makeObject(page, "title", null, .text, .text, "Title");
    const subtitle = try ir.makeObject(page, "subtitle", null, .text, .text, "Subtitle");

    try setLayoutLineHeight(&ir, pageno, "16");
    try setLayoutSpacingAfter(&ir, pageno, "0");
    try setLayoutLineHeight(&ir, title, "94");
    try setLayoutSpacingAfter(&ir, title, "42");
    try setLayoutLineHeight(&ir, subtitle, "37");
    try setLayoutSpacingAfter(&ir, subtitle, "0");
    try ir.addAnchorConstraint(pageno, .bottom, .{ .page = .bottom }, 20, "pageno-bottom");

    try solver.solveLayout(&ir);

    const pageno_node = ir.getNode(pageno).?;
    const title_node = ir.getNode(title).?;
    const subtitle_node = ir.getNode(subtitle).?;
    const stack_top = graph.anchorValue(title_node.frame, .top);
    const stack_bottom = graph.anchorValue(subtitle_node.frame, .bottom);
    try expectFloat(model.PageLayout.height / 2 - 40, (stack_top + stack_bottom) / 2);
    try testing.expect(graph.anchorValue(title_node.frame, .bottom) > graph.anchorValue(pageno_node.frame, .top));
}

test "layout solver: centered vflow preserves page center for side-by-side rows" {
    var ir = try initEmptyContext();
    defer ir.deinit();

    try setLayoutPolicy(&ir, ir.document_id, "center");

    const page = try ir.addPage("Page");
    const title = try ir.makeObject(page, "title", null, .text, .text, "Title");
    const rule = try ir.makeObject(page, "rule", null, .text, .text, "");
    const body = try ir.makeObject(page, "body", null, .text, .text, "Body");
    const pipe_child = try ir.makeObject(page, "pipe", null, .text, .text, "Pipe");
    const pipe = try ir.makeGroupWithOrigin(page, true, &.{pipe_child}, "pipe-group");

    try setLayoutLineHeight(&ir, title, "44");
    try setLayoutLineHeight(&ir, rule, "4");
    try setLayoutSpacingAfter(&ir, rule, "48");
    try setLayoutLineHeight(&ir, body, "360");
    try setLayoutLineHeight(&ir, pipe_child, "360");
    try ir.addAnchorConstraint(title, .top, .{ .page = .top }, -56, "title-top");
    try ir.addAnchorConstraint(rule, .top, .{ .node = .{ .node_id = title, .anchor = .bottom } }, -14, "rule-below-title");
    try ir.addAnchorConstraint(pipe, .right, .{ .page = .right }, -100, "pipe-right");
    try ir.addAnchorConstraint(pipe, .top, .{ .node = .{ .node_id = body, .anchor = .top } }, 0, "align-row-top");

    try solver.solveLayout(&ir);

    const body_node = ir.getNode(body).?;
    const pipe_node = ir.getNode(pipe).?;
    const body_center = body_node.frame.y + body_node.frame.height / 2;
    const pipe_center = pipe_node.frame.y + pipe_node.frame.height / 2;
    try expectFloat(body_center, pipe_center);
    try expectFloat(model.PageLayout.height / 2, body_center);
}

test "layout solver: explicit anchor conflicts and negative frame sizes are rejected" {
    var conflict = try initEmptyContext();
    defer conflict.deinit();

    const conflict_page = try conflict.addPage("Page");
    const conflict_object = try conflict.makeObject(conflict_page, "body", null, .text, .text, "A");
    try conflict.addAnchorConstraint(conflict_object, .left, .{ .page = .left }, 100, "left-a");
    try conflict.addAnchorConstraint(conflict_object, .left, .{ .page = .left }, 120, "left-b");
    try testing.expectError(error.ConstraintConflict, conflict.finalize());

    var negative = try initEmptyContext();
    defer negative.deinit();

    const negative_page = try negative.addPage("Page");
    const negative_object = try negative.makeObject(negative_page, "body", null, .text, .text, "A");
    try negative.addAnchorConstraint(negative_object, .left, .{ .node = .{ .node_id = negative_object, .anchor = .right } }, 10, "negative-width");
    try testing.expectError(error.NegativeFrameSize, negative.finalize());
}

test "layout solver: group width propagation must preserve child hard widths" {
    var ir = try initEmptyContext();
    defer ir.deinit();

    const page = try ir.addPage("Page");
    const child = try ir.makeObject(page, "body", null, .text, .text, "this text can be wrapped");
    try setLayoutWrap(&ir, child, "on");
    const group = try ir.makeGroupWithOrigin(page, true, &.{child}, "group");

    try ir.addAnchorConstraint(child, .left, .{ .page = .left }, 100, "child-left");
    try ir.addAnchorConstraint(child, .right, .{ .node = .{ .node_id = child, .anchor = .left } }, 700, "child-width");
    try ir.addAnchorConstraint(group, .right, .{ .node = .{ .node_id = group, .anchor = .left } }, 600, "group-width");

    try testing.expectError(error.ConstraintConflict, ir.finalize());
}

test "layout solver: wrapped width cap propagates through dependent anchors" {
    var ir = try initEmptyContext();
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
    try setLayoutWrap(&ir, wrapped, "on");

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
    var ir = try initEmptyContext();
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
    try setLayoutWrap(&ir, wrapped, "on");
    try ir.addAnchorConstraint(wrapped, .left, .{ .page = .left }, 1100, "wrapped-left");
    try ir.addAnchorConstraint(wrapped, .bottom, .{ .page = .bottom }, 40, "wrapped-bottom");

    try solver.solveLayout(&ir);

    const wrapped_node = ir.getNode(wrapped).?;
    const expected_height = metrics.intrinsicHeight(&ir, wrapped_node);
    try testing.expect(expected_height > 28);
    try expectFloat(expected_height, wrapped_node.frame.height);
}

const FakeMeasurementContext = struct {
    target: model.NodeId,
    natural_calls: usize = 0,
    constrained_calls: usize = 0,
    last_constrained_width: f32 = 0,
};

fn fakeLayoutMeasurement(
    context: *anyopaque,
    context_ptr: *anyopaque,
    node: *const model.Node,
    width: f32,
    mode: model.LayoutMeasurementMode,
) anyerror!?model.LayoutMeasurement {
    _ = context_ptr;
    const ctx: *FakeMeasurementContext = @ptrCast(@alignCast(context));
    if (node.id != ctx.target) return null;
    return switch (mode) {
        .natural => blk: {
            ctx.natural_calls += 1;
            break :blk .{ .width = 321, .height = 1 };
        },
        .width_constrained => blk: {
            ctx.constrained_calls += 1;
            ctx.last_constrained_width = width;
            break :blk .{ .width = width, .height = 87 };
        },
    };
}

const FakeAllMeasurementContext = struct {
    calls: usize = 0,
};

fn fakeAllLayoutMeasurement(
    context: *anyopaque,
    context_ptr: *anyopaque,
    node: *const model.Node,
    width: f32,
    mode: model.LayoutMeasurementMode,
) anyerror!?model.LayoutMeasurement {
    _ = context_ptr;
    _ = node;
    _ = width;
    _ = mode;
    const ctx: *FakeAllMeasurementContext = @ptrCast(@alignCast(context));
    ctx.calls += 1;
    return .{ .width = 1000, .height = 700 };
}

test "layout solver uses render measurement provider for intrinsic object size" {
    var ir = try initEmptyContext();
    defer ir.deinit();

    const page = try ir.addPage("Page");
    const object = try ir.makeObject(page, "body", null, .text, .text, "provider measured text");
    var measurement = FakeMeasurementContext{ .target = object };

    try solver.solveLayoutWithTracePathAndOptions(&ir, null, .{
        .measurement_provider = .{
            .context = &measurement,
            .measure = fakeLayoutMeasurement,
        },
    });

    const node = ir.getNode(object).?;
    try expectFloat(321, node.frame.width);
    try expectFloat(87, node.frame.height);
    try expectFloat(321, measurement.last_constrained_width);
    try testing.expect(measurement.natural_calls > 0);
    try testing.expect(measurement.constrained_calls > 0);
}

const LayoutProgressCounter = struct {
    started_total: usize = 0,
    completed: usize = 0,
    completed_total: usize = 0,
};

fn recordLayoutPageStarted(context: *anyopaque, completed: usize, total: usize) void {
    const counter: *LayoutProgressCounter = @ptrCast(@alignCast(context));
    counter.completed = completed;
    counter.started_total = total;
}

fn recordLayoutPageCompleted(context: *anyopaque, completed: usize, total: usize) void {
    const counter: *LayoutProgressCounter = @ptrCast(@alignCast(context));
    counter.completed = completed;
    counter.completed_total = total;
}

test "layout solver runs page jobs with configured job count" {
    var ir = try initEmptyContext();
    defer ir.deinit();

    const first_page = try ir.addPage("First");
    const first = try ir.makeObject(first_page, "first", null, .text, .text, "First");
    try ir.addAnchorConstraint(first, .left, .{ .page = .left }, 40, "first-left");
    try ir.addAnchorConstraint(first, .top, .{ .page = .top }, -80, "first-top");

    const second_page = try ir.addPage("Second");
    const second = try ir.makeObject(second_page, "second", null, .text, .text, "Second");
    try ir.addAnchorConstraint(second, .left, .{ .page = .left }, 80, "second-left");
    try ir.addAnchorConstraint(second, .top, .{ .page = .top }, -120, "second-top");

    var counter = LayoutProgressCounter{};
    var results = try solver.solveLayoutResultsWithTracePathAndOptions(&ir, null, .{
        .jobs = 2,
        .progress = .{
            .context = &counter,
            .pageStarted = recordLayoutPageStarted,
            .pageCompleted = recordLayoutPageCompleted,
        },
    });
    defer results.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), results.pages.len);
    try testing.expectEqual(@as(usize, 2), counter.started_total);
    try testing.expectEqual(@as(usize, 2), counter.completed);
    try testing.expectEqual(@as(usize, 2), counter.completed_total);
    try testing.expect(results.frameOf(first_page, first) != null);
    try testing.expect(results.frameOf(second_page, second) != null);
}

test "layout metrics keep asset intrinsic size ahead of render measurement provider" {
    var ir = try initEmptyContext();
    defer ir.deinit();

    const page = try ir.addPage("Page");
    const pdf = try ir.makeObject(page, "pdf", null, .asset, .pdf_ref, "chart.pdf");
    try setNumberField(&ir, pdf, "asset_width", 220);
    try setNumberField(&ir, pdf, "asset_height", 70);
    const image = try ir.makeObject(page, "image", null, .asset, .image_ref, "chart.png");
    try setNumberField(&ir, image, "asset_width", 180);
    try setNumberField(&ir, image, "asset_height", 90);

    var measurement = FakeAllMeasurementContext{};
    try solver.solveLayoutWithTracePathAndOptions(&ir, null, .{
        .measurement_provider = .{
            .context = &measurement,
            .measure = fakeAllLayoutMeasurement,
        },
    });

    const pdf_node = ir.getNode(pdf).?;
    try expectFloat(220, pdf_node.frame.width);
    try expectFloat(70, pdf_node.frame.height);
    const image_node = ir.getNode(image).?;
    try expectFloat(180, image_node.frame.width);
    try expectFloat(90, image_node.frame.height);
    try testing.expectEqual(@as(usize, 0), measurement.calls);
}

test "layout metrics use measured font width for wrapped text height" {
    var ir = try initEmptyContext();
    defer ir.deinit();

    const page = try ir.addPage("Page");
    const object = try ir.makeObject(page, "body", null, .text, .text, "0123456789012345678901234567");
    try setLayoutWrap(&ir, object, "on");
    try setTextFontFamily(&ir, object, "Helvetica");
    try setTextSize(&ir, object, "30");

    const node = ir.getNode(object).?;
    node.frame.width = 480;

    try expectFloat(43.5, metrics.intrinsicHeight(&ir, node));
}

test "layout metrics use render atom widths for CJK emoji markdown text" {
    var ir = try initEmptyContext();
    defer ir.deinit();

    const page = try ir.addPage("Page");
    const object = try ir.makeObject(page, "body", null, .text, .text, "✅ 最初のエラー報告までの時間が短縮できる");
    try setLayoutWrap(&ir, object, "on");
    try setTextParse(&ir, object, "block");
    try setTextFontFamily(&ir, object, "Helvetica");
    try setTextFontWeight(&ir, object, "700");
    try setTextSize(&ir, object, "30");
    try setTextLineHeight(&ir, object, "31");

    const node = ir.getNode(object).?;
    const measured_width = metrics.intrinsicWidth(&ir, node);
    try testing.expect(measured_width > 1);
    node.frame.width = measured_width - 1;

    try expectFloat(62, metrics.intrinsicHeight(&ir, node));
}

test "layout solver keeps CJK emoji markdown text on one line when measured atom width fits" {
    var ir = try initEmptyContext();
    defer ir.deinit();

    const page = try ir.addPage("Page");
    const object = try ir.makeObject(page, "body", null, .text, .text, "✅ 最初のエラー報告までの時間が短縮できる");
    try setLayoutWrap(&ir, object, "on");
    try setTextParse(&ir, object, "block");
    try setTextFontFamily(&ir, object, "Helvetica");
    try setTextFontWeight(&ir, object, "700");
    try setTextSize(&ir, object, "30");
    try setTextLineHeight(&ir, object, "31");

    const expected_width = metrics.intrinsicWidth(&ir, ir.getNode(object).?);
    try testing.expect(expected_width > 1);

    try solver.solveLayout(&ir);

    const node = ir.getNode(object).?;
    try expectFloat(expected_width, node.frame.width);
    try expectFloat(31, node.frame.height);
}

test "layout metrics: chrome padding is part of visual bounds and yields a content frame" {
    var ir = try initEmptyContext();
    defer ir.deinit();

    const page = try ir.addPage("Page");
    const plain = try ir.makeObject(page, "plain", null, .text, .text, "Hello");
    const padded = try ir.makeObject(page, "padded", null, .text, .text, "Hello");
    try setChromePadX(&ir, padded, "12");
    try setChromePadY(&ir, padded, "8");

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

test "layout metrics: unwrapped text width includes visual glyph bounds" {
    var ir = try initEmptyContext();
    defer ir.deinit();

    const page = try ir.addPage("Page");
    const object = try ir.makeObject(page, "body", null, .text, .text, "コンポーネントの集合と絶対位置");
    try setTextSize(&ir, object, "24");
    try setChromePadX(&ir, object, "20");

    const node = ir.getNode(object).?;
    const style = core.layout.style.textMetricsForNode(&ir, node);
    const font = core.font.textFacesForNode(&ir, node).normal;
    var atom_width: f32 = 0;
    var utf8 = try std.unicode.Utf8View.init(node.content.?);
    var iterator = utf8.iterator();
    while (iterator.nextCodepointSlice()) |slice| {
        atom_width += try core.render_text_measure.advanceWidth(testing.allocator, slice, font, style.font_size);
    }

    try testing.expect(metrics.intrinsicWidth(&ir, node) >= atom_width + 40);
}

test "layout solver: group chrome padding expands tight group bounds" {
    var ir = try initEmptyContext();
    defer ir.deinit();

    const page = try ir.addPage("Page");
    const child = try ir.makeObject(page, "child", null, .text, .text, "Hello");
    const group = try ir.makeGroupWithOrigin(page, true, &.{child}, "group");
    try setChromePadX(&ir, group, "12");
    try setChromePadY(&ir, group, "8");

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
    var ir = try initEmptyContext();
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
    try setLayoutWrap(&ir, child, "on");
    const group = try ir.makeGroupWithOrigin(page, true, &.{child}, "group");
    try setChromePadX(&ir, group, "10");

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

test "layout diagnostics: fixed-height object reports frame too small" {
    var ir = try initEmptyContext();
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
                try expectFloat(metrics.intrinsicWidth(&ir, node), data.required_width);
                try expectFloat(node.frame.width, data.frame_width);
                try expectFloat(0, data.overflow_width);
                try expectFloat(required_height, data.required_height);
                try expectFloat(node.frame.height, data.frame_height);
                try expectFloat(required_height - node.frame.height, data.overflow_height);
            },
            else => {},
        }
    }
    try testing.expect(found);
}

test "layout diagnostics: one-pixel text reports frame too small" {
    var ir = try initEmptyContext();
    defer ir.deinit();

    const page = try ir.addPage("Page");
    const object = try ir.makeObject(page, "toc-marker", null, .text, .text, "hidden section title");
    try setLayoutFontSize(&ir, object, "1");
    try setLayoutLineHeight(&ir, object, "1");
    try setTextSize(&ir, object, "1");
    try setTextLineHeight(&ir, object, "1");
    try setLayoutWrap(&ir, object, "on");
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
    var ir = try initEmptyContext();
    defer ir.deinit();

    const page = try ir.addPage("Page");
    const object = try ir.makeObject(page, "body", null, .text, .text, "one\ntwo");
    try setLayoutFontSize(&ir, object, "20");
    try setTextSize(&ir, object, "30");
    try setTextLineHeight(&ir, object, "45");

    const node = ir.getNode(object).?;
    try expectFloat(90, metrics.intrinsicHeight(&ir, node));
}

test "layout metrics derive line height from explicit text size" {
    var ir = try initEmptyContext();
    defer ir.deinit();

    const page = try ir.addPage("Page");
    const object = try ir.makeObject(page, "body", null, .text, .text, "one\ntwo");
    try setTextSize(&ir, object, "30");

    const node = ir.getNode(object).?;
    try expectFloat(87, metrics.intrinsicHeight(&ir, node));

    const resolved = core.render_policy.resolve(&ir, node);
    try expectFloat(30, resolved.text.?.font_size);
    try expectFloat(43.5, resolved.text.?.line_height);
}

test "layout metrics honor explicit text and layout line heights" {
    var ir = try initEmptyContext();
    defer ir.deinit();

    const page = try ir.addPage("Page");
    const text_only = try ir.makeObject(page, "text-only", null, .text, .text, "one\ntwo");
    try setTextSize(&ir, text_only, "30");
    try setTextLineHeight(&ir, text_only, "45");
    try expectFloat(90, metrics.intrinsicHeight(&ir, ir.getNode(text_only).?));

    const layout_override = try ir.makeObject(page, "layout-override", null, .text, .text, "one\ntwo");
    try setTextSize(&ir, layout_override, "30");
    try setTextLineHeight(&ir, layout_override, "45");
    try setLayoutLineHeight(&ir, layout_override, "50");
    try expectFloat(100, metrics.intrinsicHeight(&ir, ir.getNode(layout_override).?));

    const resolved = core.render_policy.resolve(&ir, ir.getNode(layout_override).?);
    try expectFloat(45, resolved.text.?.line_height);
}

test "layout metrics treat zero line heights as automatic" {
    var ir = try initEmptyContext();
    defer ir.deinit();

    const page = try ir.addPage("Page");
    const object = try ir.makeObject(page, "body", null, .text, .text, "one\ntwo");
    try setTextSize(&ir, object, "30");
    try setTextLineHeight(&ir, object, "0");
    try setLayoutLineHeight(&ir, object, "0");

    const node = ir.getNode(object).?;
    try expectFloat(87, metrics.intrinsicHeight(&ir, node));

    const resolved = core.render_policy.resolve(&ir, node);
    try expectFloat(43.5, resolved.text.?.line_height);
}

test "render policy: invalid numeric properties fall back before rendering" {
    var ir = try initEmptyContext();
    defer ir.deinit();

    const page = try ir.addPage("Page");
    const object = try ir.makeObject(page, "bad-numbers", null, .text, .text, "Hello");
    try setTextSize(&ir, object, "-1");
    try setTextLineHeight(&ir, object, "nan");
    try setTextInlineMathHeightFactor(&ir, object, "0");
    try setChromePadX(&ir, object, "-10");
    try setChromePadY(&ir, object, "inf");
    try setChromeLineWidth(&ir, object, "-2");
    try setUnderlineWidth(&ir, object, "-1");
    try setRuleLineWidth(&ir, object, "-1");
    try setRuleDash(&ir, object, "inf, 4");

    const resolved = core.render_policy.resolve(&ir, ir.getNode(object).?);
    const text = resolved.text.?;
    try expectFloat(20, text.font_size);
    try expectFloat(29, text.line_height);
    try expectFloat(1, text.inline_math_height_factor);
    try expectFloat(0, resolved.chrome.pad_x);
    try expectFloat(0, resolved.chrome.pad_y);
    try expectFloat(0, resolved.chrome.line_width);
    try expectFloat(0, resolved.underline.width);
    try expectFloat(0, resolved.rule.line_width);
    try testing.expect(resolved.rule.dash == null);
}

test "render policy: font face properties resolve structurally" {
    var ir = try initEmptyContext();
    defer ir.deinit();

    const page = try ir.addPage("Page");
    const object = try ir.makeObject(page, "font", null, .text, .text, "Hello");
    try setTextFontFamily(&ir, object, "Avenir Next");
    try setTextFontWeight(&ir, object, "650");
    try setTextFontStyle(&ir, object, "oblique");
    try setTextFontStretch(&ir, object, "condensed");
    try setTextMarkdownBoldWeight(&ir, object, "720");
    try setTextMarkdownItalicStyle(&ir, object, "italic");
    try setTextCodeFontFamily(&ir, object, "Menlo");
    try setTextCodeFontWeight(&ir, object, "500");

    const resolved = core.render_policy.resolve(&ir, ir.getNode(object).?);
    const text = resolved.text.?;
    try testing.expectEqualStrings("Avenir Next", text.font.family);
    try testing.expectEqual(@as(u16, 650), text.font.weight);
    try testing.expectEqual(core.font.Style.oblique, text.font.style);
    try testing.expectEqual(core.font.Stretch.condensed, text.font.stretch);
    try testing.expectEqual(@as(u16, 720), text.bold_font.weight);
    try testing.expectEqual(core.font.Style.italic, text.italic_font.style);
    try testing.expectEqualStrings("Menlo", text.code_font.family);
    try testing.expectEqual(@as(u16, 500), text.code_font.weight);
}

test "render policy: markdown bold color is optional and resolves as text paint" {
    var ir = try initEmptyContext();
    defer ir.deinit();

    const page = try ir.addPage("Page");
    const object = try ir.makeObject(page, "body", null, .text, .text, "**Hello**");

    var resolved = core.render_policy.resolve(&ir, ir.getNode(object).?);
    try testing.expect(resolved.text.?.markdown_bold_color == null);

    try setTextMarkdownBoldColor(&ir, object, "0.2,0.4,0.6");
    resolved = core.render_policy.resolve(&ir, ir.getNode(object).?);
    try expectColor(0.2, 0.4, 0.6, resolved.text.?.markdown_bold_color.?);
}

test "render policy: math alignment applies to markdown and vector math" {
    var ir = try initEmptyContext();
    defer ir.deinit();

    const page = try ir.addPage("Page");
    const text_object = try ir.makeObject(page, "body", null, .text, .text, "$$x^2$$");
    try setMathAlign(&ir, text_object, "left");

    const resolved_text = core.render_policy.resolve(&ir, ir.getNode(text_object).?);
    try testing.expectEqual(core.render_policy.HorizontalAlign.left, resolved_text.text.?.math_align);

    const invalid_text_object = try ir.makeObject(page, "body", null, .text, .text, "$$z^2$$");
    try setMathAlign(&ir, invalid_text_object, "sideways");
    const resolved_invalid_text = core.render_policy.resolve(&ir, ir.getNode(invalid_text_object).?);
    try testing.expectEqual(core.render_policy.HorizontalAlign.center, resolved_invalid_text.text.?.math_align);

    try setMathAlign(&ir, ir.document_id, "right");
    const document_text_object = try ir.makeObject(page, "body", null, .text, .text, "$$a^2$$");
    const resolved_document_text = core.render_policy.resolve(&ir, ir.getNode(document_text_object).?);
    try testing.expectEqual(core.render_policy.HorizontalAlign.right, resolved_document_text.text.?.math_align);

    try setMathAlign(&ir, page, "left");
    const page_text_object = try ir.makeObject(page, "body", null, .text, .text, "$$b^2$$");
    const resolved_page_text = core.render_policy.resolve(&ir, ir.getNode(page_text_object).?);
    try testing.expectEqual(core.render_policy.HorizontalAlign.left, resolved_page_text.text.?.math_align);

    const math_object = try ir.makeObject(page, "math_tex", null, .text, .text, "\\int_0^1 x^2 \\, dx");
    try setRenderKind(&ir, math_object, "vector_math");
    try setMathAlign(&ir, math_object, "right");

    const resolved_math = core.render_policy.resolve(&ir, ir.getNode(math_object).?);
    try testing.expectEqual(core.render_policy.HorizontalAlign.right, resolved_math.math.?.horizontal_align);
}
