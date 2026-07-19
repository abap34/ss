const std = @import("std");
const ast = @import("ast");
const core = @import("core");
const model = @import("model");

const graph = core.layout.graph;
const metrics = core.layout.metrics;
const solver = core.layout.solver;

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

fn finalizeDocumentState(state: *core.DocumentState) !void {
    var document = try state.finalizeDocument(null, .{});
    defer document.deinit(state.allocator);
}

fn solveDocumentState(state: *core.DocumentState) !void {
    try solveDocumentStateWithOptions(state, null, .{});
}

fn solveDocumentStateWithOptions(state: *core.DocumentState, trace_path: ?[]const u8, options: graph.SolveOptions) !void {
    var document = try solver.solveDocument(state, trace_path, options);
    defer document.deinit(state.allocator);
    try solver.applyDocument(state, &document);
}

fn expectFloat(expected: f32, actual: f32) !void {
    try testing.expectApproxEqAbs(expected, actual, 0.0001);
}

fn expectColor(expected_r: f32, expected_g: f32, expected_b: f32, actual: core.render_policy.Color) !void {
    try expectFloat(expected_r, actual.r);
    try expectFloat(expected_g, actual.g);
    try expectFloat(expected_b, actual.b);
}

fn setStringField(state: *core.DocumentState, node_id: model.NodeId, key: []const u8, value: []const u8) !void {
    try state.setNodeFieldValue(node_id, key, .{ .string = value });
}

fn setNumberField(state: *core.DocumentState, node_id: model.NodeId, key: []const u8, value: f32) !void {
    try state.setNodeFieldValue(node_id, key, .{ .number = value });
}

fn setEnumField(state: *core.DocumentState, node_id: model.NodeId, key: []const u8, enum_name: []const u8, case_name: []const u8) !void {
    try state.setNodeFieldValue(node_id, key, .{ .enum_case = .{
        .enum_name = enum_name,
        .case_name = case_name,
    } });
}

fn setRecordStringField(state: *core.DocumentState, node_id: model.NodeId, root_key: []const u8, field_name: []const u8, value: []const u8) !void {
    try setRecordFieldValue(state, node_id, root_key, field_name, .{ .string = value });
}

fn setRecordNumberField(state: *core.DocumentState, node_id: model.NodeId, root_key: []const u8, field_name: []const u8, value: f32) !void {
    try setRecordFieldValue(state, node_id, root_key, field_name, .{ .number = value });
}

fn setRecordEnumField(
    state: *core.DocumentState,
    node_id: model.NodeId,
    root_key: []const u8,
    field_name: []const u8,
    enum_name: []const u8,
    case_name: []const u8,
) !void {
    try setRecordFieldValue(state, node_id, root_key, field_name, .{ .enum_case = .{
        .enum_name = enum_name,
        .case_name = case_name,
    } });
}

fn setRecordFieldValue(state: *core.DocumentState, node_id: model.NodeId, root_key: []const u8, field_name: []const u8, value: core.Value) !void {
    try setRecordPathValue(state, node_id, root_key, &.{field_name}, value);
}

fn setRecordPathValue(state: *core.DocumentState, node_id: model.NodeId, root_key: []const u8, path: []const []const u8, value: core.Value) !void {
    const node = state.getNode(node_id) orelse return error.UnknownNode;
    for (node.fields.items) |*field| {
        if (!std.mem.eql(u8, field.key, root_key)) continue;
        if (field.value != .record) return error.ExpectedRecordField;
        try putRecordPathValue(state.allocator, &field.value.record, path, value);
        return;
    }

    var record = core.RecordValue.init(recordTypeName(root_key));
    defer record.deinit(state.allocator);
    try putRecordPathValue(state.allocator, &record, path, value);
    try state.setNodeFieldValue(node_id, root_key, .{ .record = record });
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
    if (std.mem.eql(u8, root_key, "math")) return "MathStyle";
    return root_key;
}

fn setLayoutPolicy(state: *core.DocumentState, node_id: model.NodeId, case_name: []const u8) !void {
    try setEnumField(state, node_id, "layout_v", "LayoutPolicy", case_name);
}

fn setLayoutCenterOffset(state: *core.DocumentState, node_id: model.NodeId, value: []const u8) !void {
    try setStringField(state, node_id, "layout_v_center_offset", value);
}

fn setRenderKind(state: *core.DocumentState, node_id: model.NodeId, case_name: []const u8) !void {
    try setEnumField(state, node_id, "render_kind", "RenderKind", case_name);
}

fn setMathAlign(state: *core.DocumentState, node_id: model.NodeId, case_name: []const u8) !void {
    try setEnumField(state, node_id, "math_align", "Align", case_name);
}

fn setLayoutWrap(state: *core.DocumentState, node_id: model.NodeId, case_name: []const u8) !void {
    try setRecordEnumField(state, node_id, "layout", "wrap", "WrapMode", case_name);
}

fn setLayoutFontSize(state: *core.DocumentState, node_id: model.NodeId, value: []const u8) !void {
    try setRecordStringField(state, node_id, "layout", "font_size", value);
}

fn setLayoutLineHeight(state: *core.DocumentState, node_id: model.NodeId, value: []const u8) !void {
    try setRecordStringField(state, node_id, "layout", "line_height", value);
}

fn setLayoutSpacingAfter(state: *core.DocumentState, node_id: model.NodeId, value: []const u8) !void {
    try setRecordStringField(state, node_id, "layout", "spacing_after", value);
}

fn setTextParse(state: *core.DocumentState, node_id: model.NodeId, case_name: []const u8) !void {
    try setRecordEnumField(state, node_id, "text", "parse", "TextParseMode", case_name);
}

fn setTextSize(state: *core.DocumentState, node_id: model.NodeId, value: []const u8) !void {
    try setRecordStringField(state, node_id, "text", "size", value);
}

fn setTextLineHeight(state: *core.DocumentState, node_id: model.NodeId, value: []const u8) !void {
    try setRecordStringField(state, node_id, "text", "line_height", value);
}

fn setTextInlineMathHeightFactor(state: *core.DocumentState, node_id: model.NodeId, value: []const u8) !void {
    try setRecordStringField(state, node_id, "text", "inline_math_height_factor", value);
}

fn setTextMarkdownBoldColor(state: *core.DocumentState, node_id: model.NodeId, value: []const u8) !void {
    try setRecordStringField(state, node_id, "text", "markdown_bold_color", value);
}

fn setTextMarkdownBoldWeight(state: *core.DocumentState, node_id: model.NodeId, value: []const u8) !void {
    try setRecordStringField(state, node_id, "text", "bold_weight", value);
}

fn setTextMarkdownItalicStyle(state: *core.DocumentState, node_id: model.NodeId, case_name: []const u8) !void {
    try setRecordEnumField(state, node_id, "text", "italic_style", "FontStyle", case_name);
}

fn setTextFontFamily(state: *core.DocumentState, node_id: model.NodeId, value: []const u8) !void {
    try setRecordPathValue(state, node_id, "text", &.{ "font", "family" }, .{ .string = value });
}

fn setTextFontWeight(state: *core.DocumentState, node_id: model.NodeId, value: []const u8) !void {
    try setRecordPathValue(state, node_id, "text", &.{ "font", "weight" }, .{ .string = value });
}

fn setTextFontStyle(state: *core.DocumentState, node_id: model.NodeId, case_name: []const u8) !void {
    try setRecordPathValue(state, node_id, "text", &.{ "font", "style" }, .{ .enum_case = .{ .enum_name = "FontStyle", .case_name = case_name } });
}

fn setTextFontStretch(state: *core.DocumentState, node_id: model.NodeId, case_name: []const u8) !void {
    try setRecordPathValue(state, node_id, "text", &.{ "font", "stretch" }, .{ .enum_case = .{ .enum_name = "FontStretch", .case_name = case_name } });
}

fn setTextCodeFontFamily(state: *core.DocumentState, node_id: model.NodeId, value: []const u8) !void {
    try setRecordPathValue(state, node_id, "text", &.{ "code_font", "family" }, .{ .string = value });
}

fn setTextCodeFontWeight(state: *core.DocumentState, node_id: model.NodeId, value: []const u8) !void {
    try setRecordPathValue(state, node_id, "text", &.{ "code_font", "weight" }, .{ .string = value });
}

fn setChromePadX(state: *core.DocumentState, node_id: model.NodeId, value: []const u8) !void {
    try setRecordStringField(state, node_id, "chrome", "pad_x", value);
}

fn setChromePadY(state: *core.DocumentState, node_id: model.NodeId, value: []const u8) !void {
    try setRecordStringField(state, node_id, "chrome", "pad_y", value);
}

fn setChromeLineWidth(state: *core.DocumentState, node_id: model.NodeId, value: []const u8) !void {
    try setRecordStringField(state, node_id, "chrome", "line_width", value);
}

fn setUnderlineWidth(state: *core.DocumentState, node_id: model.NodeId, value: []const u8) !void {
    try setRecordStringField(state, node_id, "underline", "width", value);
}

fn setRuleLineWidth(state: *core.DocumentState, node_id: model.NodeId, value: []const u8) !void {
    try setRecordStringField(state, node_id, "rule", "line_width", value);
}

fn setRuleDash(state: *core.DocumentState, node_id: model.NodeId, value: []const u8) !void {
    try setRecordStringField(state, node_id, "rule", "dash", value);
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
    var state = try initEmptyDocumentState();
    defer state.deinit();

    const page = try state.addPage("Page");
    const a = try state.makeObject(page, "a", null, .text, .text, "A");
    const b = try state.makeObject(page, "b", null, .text, .text, "B");
    _ = try state.makeGroupWithOrigin(page, true, &.{ a, b }, "group");

    try state.addAnchorConstraint(a, .left, .{ .page = .left }, 10, "a-left");
    try state.addAnchorConstraint(a, .top, .{ .page = .top }, -10, "a-top");
    try state.addAnchorConstraint(b, .left, .{ .node = .{ .node_id = a, .anchor = .right } }, 20, "b-left");

    var page_graph = try graph.PageLayoutGraph.init(testing.allocator, &state, page);
    defer page_graph.deinit();

    try testing.expectEqual(@as(usize, 3), page_graph.len());
    try testing.expect(page_graph.indexOf(a) != null);
    try testing.expect(page_graph.indexOf(b) != null);
    try testing.expect(page_graph.hasTargetConstraint(&state, a, .horizontal, &.{}));
    try testing.expect(page_graph.hasTargetConstraint(&state, a, .vertical, &.{}));
    try testing.expect(!page_graph.hasTargetConstraint(&state, b, .vertical, &.{}));

    var horizontal = try page_graph.constraintsForAxis(testing.allocator, &state, .horizontal, &.{});
    defer horizontal.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), horizontal.items.len);

    var targets_a = try page_graph.targetConstraints(testing.allocator, &state, a, .horizontal, &.{});
    defer targets_a.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), targets_a.items.len);

    var sourced_by_a = try page_graph.sourceConstraints(testing.allocator, &state, a, .horizontal, &.{});
    defer sourced_by_a.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), sourced_by_a.items.len);
    try testing.expectEqual(b, sourced_by_a.items[0].target_node);
}

test "layout graph spec: implicit constraint objects stay page local" {
    var state = try initEmptyDocumentState();
    defer state.deinit();

    const first_page = try state.addPage("First");
    const second_page = try state.addPage("Second");
    const placed = try state.makeObject(first_page, "placed", null, .text, .text, "placed");
    const helper = try state.createObjectWithOrigin("helper", null, .text, .text, "helper", null);
    const foreign = try state.makeObject(second_page, "foreign", null, .text, .text, "foreign");
    try state.addAnchorConstraint(placed, .top, .{ .node = .{ .node_id = helper, .anchor = .top } }, 10, "helper-top");
    try state.addAnchorConstraint(placed, .left, .{ .node = .{ .node_id = foreign, .anchor = .left } }, 20, "foreign-left");

    var first_graph = try graph.PageLayoutGraph.init(testing.allocator, &state, first_page);
    defer first_graph.deinit();
    try testing.expect(first_graph.indexOf(placed) != null);
    try testing.expect(first_graph.indexOf(helper) == null);
    try testing.expect(first_graph.indexOf(foreign) == null);

    var second_graph = try graph.PageLayoutGraph.init(testing.allocator, &state, second_page);
    defer second_graph.deinit();
    try testing.expect(second_graph.indexOf(foreign) != null);
    try testing.expect(second_graph.indexOf(placed) == null);
}

test "layout graph spec: constraint classification names layout dependency roles" {
    var state = try initEmptyDocumentState();
    defer state.deinit();

    const page = try state.addPage("Page");
    const a = try state.makeObject(page, "a", null, .text, .text, "A");
    const b = try state.makeObject(page, "b", null, .text, .text, "B");
    const group_id = try state.makeGroupWithOrigin(page, true, &.{ a, b }, "group");

    var page_graph = try graph.PageLayoutGraph.init(testing.allocator, &state, page);
    defer page_graph.deinit();

    try testing.expectEqual(graph.ConstraintClass.page_source, page_graph.constraintClass(&state, .{
        .target_node = a,
        .target_anchor = .left,
        .source = .{ .page = .left },
        .offset = 10,
    }, .horizontal));

    try testing.expectEqual(graph.ConstraintClass.normal, page_graph.constraintClass(&state, .{
        .target_node = b,
        .target_anchor = .left,
        .source = .{ .node = .{ .node_id = a, .anchor = .right } },
        .offset = 20,
    }, .horizontal));

    try testing.expectEqual(graph.ConstraintClass.self_size, page_graph.constraintClass(&state, .{
        .target_node = a,
        .target_anchor = .right,
        .source = .{ .node = .{ .node_id = a, .anchor = .left } },
        .offset = 120,
    }, .horizontal));

    try testing.expectEqual(graph.ConstraintClass.self_anchor, page_graph.constraintClass(&state, .{
        .target_node = a,
        .target_anchor = .right,
        .source = .{ .node = .{ .node_id = a, .anchor = .right } },
        .offset = 120,
    }, .horizontal));

    try testing.expectEqual(graph.ConstraintClass.group_target, page_graph.constraintClass(&state, .{
        .target_node = group_id,
        .target_anchor = .left,
        .source = .{ .page = .left },
        .offset = 0,
    }, .horizontal));

    try testing.expectEqual(graph.ConstraintClass.group_source, page_graph.constraintClass(&state, .{
        .target_node = a,
        .target_anchor = .left,
        .source = .{ .node = .{ .node_id = group_id, .anchor = .right } },
        .offset = 0,
    }, .horizontal));

    try testing.expectEqual(graph.ConstraintClass.wrong_axis, page_graph.constraintClass(&state, .{
        .target_node = a,
        .target_anchor = .top,
        .source = .{ .page = .top },
        .offset = 0,
    }, .horizontal));

    try testing.expectEqual(graph.ConstraintClass.external_source, page_graph.constraintClass(&state, .{
        .target_node = 9999,
        .target_anchor = .left,
        .source = .{ .page = .left },
        .offset = 0,
    }, .horizontal));
}

test "layout graph spec: axis workspaces seed known frames only without target constraints" {
    var state = try initEmptyDocumentState();
    defer state.deinit();

    const page = try state.addPage("Page");
    const unconstrained = try state.makeObject(page, "free", null, .text, .text, "Free");
    const constrained = try state.makeObject(page, "fixed", null, .text, .text, "Fixed");

    state.getNode(unconstrained).?.frame = .{ .x = 10, .y = 20, .width = 30, .height = 40, .x_set = true, .y_set = true };
    state.getNode(constrained).?.frame = .{ .x = 100, .y = 200, .width = 50, .height = 60, .x_set = true, .y_set = true };
    try state.addAnchorConstraint(constrained, .left, .{ .page = .left }, 15, "fixed-left");

    var page_graph = try graph.PageLayoutGraph.init(testing.allocator, &state, page);
    defer page_graph.deinit();
    var workspace = try graph.AxisWorkspace.init(testing.allocator, &state, &page_graph, .horizontal);
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
    var self_conflict = try initEmptyDocumentState();
    defer self_conflict.deinit();

    const self_page = try self_conflict.addPage("Page");
    const object = try self_conflict.makeObject(self_page, "body", null, .text, .text, "A");
    try self_conflict.addAnchorConstraint(object, .top, .{ .node = .{ .node_id = object, .anchor = .top } }, 100, "self-top");
    try testing.expectError(error.ConstraintConflict, finalizeDocumentState(&self_conflict));

    var cycle = try initEmptyDocumentState();
    defer cycle.deinit();

    const cycle_page = try cycle.addPage("Page");
    const a = try cycle.makeObject(cycle_page, "a", null, .text, .text, "A");
    const b = try cycle.makeObject(cycle_page, "b", null, .text, .text, "B");
    try cycle.addAnchorConstraint(a, .top, .{ .node = .{ .node_id = b, .anchor = .top } }, 10, "a-top");
    try cycle.addAnchorConstraint(b, .top, .{ .node = .{ .node_id = a, .anchor = .top } }, 10, "b-top");
    try testing.expectError(error.ConstraintConflict, finalizeDocumentState(&cycle));
}

test "layout solver: consistent constraint cycles are fixed by fallback placement" {
    var state = try initEmptyDocumentState();
    defer state.deinit();

    const page = try state.addPage("Page");
    const a = try state.makeObject(page, "a", null, .text, .text, "A");
    const b = try state.makeObject(page, "b", null, .text, .text, "B");
    try state.addAnchorConstraint(a, .top, .{ .node = .{ .node_id = b, .anchor = .top } }, 0, "a-top");
    try state.addAnchorConstraint(b, .top, .{ .node = .{ .node_id = a, .anchor = .top } }, 0, "b-top");

    try finalizeDocumentState(&state);

    const a_node = state.getNode(a).?;
    const b_node = state.getNode(b).?;
    try testing.expect(a_node.frame.y_set);
    try testing.expect(b_node.frame.y_set);
    try expectFloat(graph.anchorValue(a_node.frame, .top), graph.anchorValue(b_node.frame, .top));
    try testing.expect(!state.hasConstraintFailures());
}

test "layout solver: tautological self-anchor constraints do not block fallback placement" {
    var state = try initEmptyDocumentState();
    defer state.deinit();

    const page = try state.addPage("Page");
    const object = try state.makeObject(page, "body", null, .text, .text, "A");
    try state.addAnchorConstraint(object, .top, .{ .node = .{ .node_id = object, .anchor = .top } }, 0, "self-top");

    try finalizeDocumentState(&state);

    const node = state.getNode(object).?;
    try testing.expect(node.frame.x_set);
    try testing.expect(node.frame.y_set);
    try testing.expect(!state.hasConstraintFailures());
}

test "layout solver: vertical fallback tries alternate roots in incomplete components" {
    var state = try initEmptyDocumentState();
    defer state.deinit();

    const page = try state.addPage("Page");
    const panel = try state.makeObject(page, "panel", null, .text, .text, "");
    const body = try state.makeObject(page, "body", null, .text, .text, "content");
    try state.addAnchorConstraint(panel, .left, .{ .page = .left }, 52, "panel-left");
    try state.addAnchorConstraint(panel, .right, .{ .page = .right }, -52, "panel-right");
    try state.addAnchorConstraint(body, .left, .{ .page = .left }, 72, "body-left");
    try state.addAnchorConstraint(body, .right, .{ .page = .right }, -72, "body-right");
    try state.addAnchorConstraint(panel, .top, .{ .node = .{ .node_id = body, .anchor = .top } }, 16, "panel-top");
    try state.addAnchorConstraint(panel, .bottom, .{ .node = .{ .node_id = body, .anchor = .bottom } }, -16, "panel-bottom");

    try finalizeDocumentState(&state);

    const panel_node = state.getNode(panel).?;
    const body_node = state.getNode(body).?;
    try testing.expect(panel_node.frame.y_set);
    try testing.expect(body_node.frame.y_set);
    try expectFloat(graph.anchorValue(body_node.frame, .top) + 16, graph.anchorValue(panel_node.frame, .top));
    try expectFloat(graph.anchorValue(body_node.frame, .bottom) - 16, graph.anchorValue(panel_node.frame, .bottom));
    try testing.expect(!state.hasConstraintFailures());
}

test "layout solver: constraint-referenced objects participate in fallback placement" {
    var state = try initEmptyDocumentState();
    defer state.deinit();

    const page = try state.addPage("Page");
    const placed = try state.makeObject(page, "placed", null, .text, .text, "placed");
    const referenced = try state.makeObject(page, "referenced", null, .text, .text, "referenced");
    try state.addAnchorConstraint(placed, .top, .{ .node = .{ .node_id = referenced, .anchor = .top } }, 10, "placed-top");

    try finalizeDocumentState(&state);

    const placed_node = state.getNode(placed).?;
    const referenced_node = state.getNode(referenced).?;
    try testing.expect(placed_node.frame.y_set);
    try testing.expect(referenced_node.frame.y_set);
    try expectFloat(graph.anchorValue(referenced_node.frame, .top) + 10, graph.anchorValue(placed_node.frame, .top));
    try testing.expect(!state.hasConstraintFailures());
}

test "layout solver: size-only constraints still receive fallback placement" {
    var state = try initEmptyDocumentState();
    defer state.deinit();

    const page = try state.addPage("Page");
    const object = try state.makeObject(page, "body", null, .text, .text, "content");
    try state.addAnchorConstraint(object, .right, .{ .node = .{ .node_id = object, .anchor = .left } }, 240, "object-width");
    try state.addAnchorConstraint(object, .top, .{ .node = .{ .node_id = object, .anchor = .bottom } }, 96, "object-height");

    try finalizeDocumentState(&state);

    const node = state.getNode(object).?;
    try testing.expect(node.frame.x_set);
    try testing.expect(node.frame.y_set);
    try expectFloat(240, node.frame.width);
    try expectFloat(96, node.frame.height);
    try testing.expect(!state.hasConstraintFailures());
}

test "layout solver: page-dependent group children receive local vertical fallback" {
    var state = try initEmptyDocumentState();
    defer state.deinit();

    const page = try state.addPage("Page");
    const ruler = try state.makeObject(page, "rule", null, .text, .text, "");
    const title = try state.makeObject(page, "title", null, .text, .text, "Title");
    const body = try state.makeObject(page, "body", null, .text, .text, "Body");
    _ = try state.makeGroupWithOrigin(page, true, &.{ ruler, title }, "head");
    try setLayoutLineHeight(&state, ruler, "4");
    try setLayoutSpacingAfter(&state, ruler, "12");
    try state.addAnchorConstraint(ruler, .top, .{ .page = .top }, -200, "rule-top");

    try finalizeDocumentState(&state);

    const ruler_node = state.getNode(ruler).?;
    const title_node = state.getNode(title).?;
    const body_node = state.getNode(body).?;
    try testing.expect(ruler_node.frame.y_set);
    try testing.expect(title_node.frame.y_set);
    try testing.expect(body_node.frame.y_set);
    try expectFloat(graph.anchorValue(ruler_node.frame, .bottom) - 12, graph.anchorValue(title_node.frame, .top));
    try expectFloat(graph.anchorValue(title_node.frame, .bottom) - core.layout.styleForNode(&state, title_node).spacing_after, graph.anchorValue(body_node.frame, .top));
    try testing.expect(!state.hasConstraintFailures());
}

test "layout solver: page-dependent group children before fixed anchors receive fallback" {
    var state = try initEmptyDocumentState();
    defer state.deinit();

    const page = try state.addPage("Page");
    const title = try state.makeObject(page, "title", null, .text, .text, "Title");
    const ruler = try state.makeObject(page, "rule", null, .text, .text, "");
    _ = try state.makeGroupWithOrigin(page, true, &.{ title, ruler }, "head");
    try setLayoutSpacingAfter(&state, title, "12");
    try setLayoutLineHeight(&state, ruler, "4");
    try state.addAnchorConstraint(ruler, .top, .{ .page = .top }, -200, "rule-top");

    try finalizeDocumentState(&state);

    const title_node = state.getNode(title).?;
    const ruler_node = state.getNode(ruler).?;
    try testing.expect(title_node.frame.y_set);
    try testing.expect(ruler_node.frame.y_set);
    try expectFloat(graph.anchorValue(ruler_node.frame, .top) + 12, graph.anchorValue(title_node.frame, .bottom));
    try testing.expect(!state.hasConstraintFailures());
}

test "layout solver: page-dependent vertical cycles receive fallback placement" {
    var state = try initEmptyDocumentState();
    defer state.deinit();

    const page = try state.addPage("Page");
    const ruler = try state.makeObject(page, "rule", null, .text, .text, "");
    const first = try state.makeObject(page, "first", null, .text, .text, "A");
    const second = try state.makeObject(page, "second", null, .text, .text, "B");
    _ = try state.makeGroupWithOrigin(page, true, &.{ ruler, first, second }, "head");
    try setLayoutLineHeight(&state, ruler, "4");
    try setLayoutSpacingAfter(&state, ruler, "12");
    try state.addAnchorConstraint(ruler, .top, .{ .page = .top }, -200, "rule-top");
    try state.addAnchorConstraint(first, .top, .{ .node = .{ .node_id = second, .anchor = .top } }, 0, "first-cycle");
    try state.addAnchorConstraint(second, .top, .{ .node = .{ .node_id = first, .anchor = .top } }, 0, "second-cycle");

    try finalizeDocumentState(&state);

    const ruler_node = state.getNode(ruler).?;
    const first_node = state.getNode(first).?;
    const second_node = state.getNode(second).?;
    try testing.expect(first_node.frame.y_set);
    try testing.expect(second_node.frame.y_set);
    try expectFloat(graph.anchorValue(ruler_node.frame, .bottom) - 12, graph.anchorValue(first_node.frame, .top));
    try expectFloat(graph.anchorValue(first_node.frame, .top), graph.anchorValue(second_node.frame, .top));
    try testing.expect(!state.hasConstraintFailures());
}

test "layout solver: page-dependent horizontal cycles receive fallback placement" {
    var state = try initEmptyDocumentState();
    defer state.deinit();

    const page = try state.addPage("Page");
    const ruler = try state.makeObject(page, "rule", null, .text, .text, "");
    const first = try state.makeObject(page, "first", null, .text, .text, "A");
    const second = try state.makeObject(page, "second", null, .text, .text, "B");
    _ = try state.makeGroupWithOrigin(page, true, &.{ ruler, first, second }, "head");
    try setLayoutLineHeight(&state, ruler, "4");
    try state.addAnchorConstraint(ruler, .left, .{ .page = .left }, 100, "rule-left");
    try state.addAnchorConstraint(first, .left, .{ .node = .{ .node_id = second, .anchor = .left } }, 0, "first-cycle");
    try state.addAnchorConstraint(second, .left, .{ .node = .{ .node_id = first, .anchor = .left } }, 0, "second-cycle");

    try finalizeDocumentState(&state);

    const first_node = state.getNode(first).?;
    const second_node = state.getNode(second).?;
    try testing.expect(first_node.frame.x_set);
    try testing.expect(second_node.frame.x_set);
    try expectFloat(first_node.frame.x, second_node.frame.x);
    try testing.expect(!state.hasConstraintFailures());
}

test "layout solver: centered page-dependent group children receive local vertical fallback" {
    var state = try initEmptyDocumentState();
    defer state.deinit();

    try setLayoutPolicy(&state, state.document_id, "center");

    const page = try state.addPage("Page");
    const ruler = try state.makeObject(page, "rule", null, .text, .text, "");
    const title = try state.makeObject(page, "title", null, .text, .text, "Title");
    const body = try state.makeObject(page, "body", null, .text, .text, "Body");
    _ = try state.makeGroupWithOrigin(page, true, &.{ ruler, title }, "head");
    try setLayoutLineHeight(&state, ruler, "4");
    try setLayoutSpacingAfter(&state, ruler, "12");
    try setLayoutLineHeight(&state, body, "500");
    try state.addAnchorConstraint(ruler, .top, .{ .page = .top }, -200, "rule-top");

    try finalizeDocumentState(&state);

    const ruler_node = state.getNode(ruler).?;
    const title_node = state.getNode(title).?;
    const body_node = state.getNode(body).?;
    try testing.expect(ruler_node.frame.y_set);
    try testing.expect(title_node.frame.y_set);
    try testing.expect(body_node.frame.y_set);
    try expectFloat(graph.anchorValue(ruler_node.frame, .bottom) - 12, graph.anchorValue(title_node.frame, .top));
    try expectFloat(graph.anchorValue(title_node.frame, .bottom) - core.layout.styleForNode(&state, title_node).spacing_after, graph.anchorValue(body_node.frame, .top));
    try testing.expect(!state.hasConstraintFailures());
}

test "layout solver: horizontal alignment alone does not imply vertical row alignment" {
    var stacked = try initEmptyDocumentState();
    defer stacked.deinit();

    const stacked_page = try stacked.addPage("Page");
    const first = try stacked.makeObject(stacked_page, "first", null, .text, .text, "A");
    const second = try stacked.makeObject(stacked_page, "second", null, .text, .text, "B");
    _ = try stacked.makeGroupWithOrigin(stacked_page, true, &.{ first, second }, "group");
    try stacked.addAnchorConstraint(second, .left, .{ .node = .{ .node_id = first, .anchor = .left } }, 0, "same-left");

    try solveDocumentState(&stacked);

    const first_node = stacked.getNode(first).?;
    const second_node = stacked.getNode(second).?;
    const first_spacing = core.layout.styleForNode(&stacked, first_node).spacing_after;
    try expectFloat(first_node.frame.y - first_spacing, second_node.frame.y + second_node.frame.height);

    var row = try initEmptyDocumentState();
    defer row.deinit();

    const row_page = try row.addPage("Page");
    const left = try row.makeObject(row_page, "left", null, .text, .text, "A");
    const right = try row.makeObject(row_page, "right", null, .text, .text, "B");
    try row.addAnchorConstraint(right, .left, .{ .node = .{ .node_id = left, .anchor = .right } }, 30, "right-of-left");
    try row.addAnchorConstraint(right, .center_y, .{ .node = .{ .node_id = left, .anchor = .center_y } }, 0, "same-center-y");

    try solveDocumentState(&row);

    const left_node = row.getNode(left).?;
    const right_node = row.getNode(right).?;
    try expectFloat(left_node.frame.y + left_node.frame.height / 2, right_node.frame.y + right_node.frame.height / 2);
}

test "layout solver: horizontal fallback seeds unconstrained peer anchors" {
    var state = try initEmptyDocumentState();
    defer state.deinit();

    const page = try state.addPage("Page");
    const title = try state.makeObject(page, "title", null, .text, .text, "Title");
    const byline = try state.makeObject(page, "byline", null, .text, .text, "Byline");
    try state.addAnchorConstraint(title, .left, .{ .node = .{ .node_id = byline, .anchor = .left } }, 0, "same-left");

    try finalizeDocumentState(&state);

    const title_node = state.getNode(title).?;
    const byline_node = state.getNode(byline).?;
    try expectFloat(title_node.frame.x, byline_node.frame.x);
}

test "layout solver: same-target peer equalities form one fallback unit" {
    var state = try initEmptyDocumentState();
    defer state.deinit();

    const page = try state.addPage("Page");
    const a = try state.makeObject(page, "a", null, .text, .text, "A");
    const b = try state.makeObject(page, "b", null, .text, .text, "B");
    const c = try state.makeObject(page, "c", null, .text, .text, "C");
    try state.addAnchorConstraint(a, .top, .{ .node = .{ .node_id = b, .anchor = .top } }, 0, "a-is-b");
    try state.addAnchorConstraint(a, .top, .{ .node = .{ .node_id = c, .anchor = .top } }, 0, "a-is-c");

    try finalizeDocumentState(&state);

    const a_node = state.getNode(a).?;
    const b_node = state.getNode(b).?;
    const c_node = state.getNode(c).?;
    try expectFloat(graph.anchorValue(a_node.frame, .top), graph.anchorValue(b_node.frame, .top));
    try expectFloat(graph.anchorValue(a_node.frame, .top), graph.anchorValue(c_node.frame, .top));
    try testing.expect(!state.hasConstraintFailures());
}

test "layout solver: chained peer equalities form one fallback unit" {
    var state = try initEmptyDocumentState();
    defer state.deinit();

    const page = try state.addPage("Page");
    const a = try state.makeObject(page, "a", null, .text, .text, "A");
    const b = try state.makeObject(page, "b", null, .text, .text, "B");
    const c = try state.makeObject(page, "c", null, .text, .text, "C");
    try state.addAnchorConstraint(a, .top, .{ .node = .{ .node_id = b, .anchor = .top } }, 0, "a-is-b");
    try state.addAnchorConstraint(b, .top, .{ .node = .{ .node_id = c, .anchor = .top } }, 0, "b-is-c");

    try finalizeDocumentState(&state);

    const a_node = state.getNode(a).?;
    const b_node = state.getNode(b).?;
    const c_node = state.getNode(c).?;
    try expectFloat(graph.anchorValue(a_node.frame, .top), graph.anchorValue(b_node.frame, .top));
    try expectFloat(graph.anchorValue(a_node.frame, .top), graph.anchorValue(c_node.frame, .top));
    try testing.expect(!state.hasConstraintFailures());
}

test "layout solver: hard peer equality conflicts are independent of direction and chaining" {
    var forward = try initEmptyDocumentState();
    defer forward.deinit();

    const forward_page = try forward.addPage("Page");
    const forward_a = try forward.makeObject(forward_page, "a", null, .text, .text, "A");
    const forward_b = try forward.makeObject(forward_page, "b", null, .text, .text, "B");
    try forward.addAnchorConstraint(forward_a, .top, .{ .page = .top }, -100, "a-top");
    try forward.addAnchorConstraint(forward_b, .top, .{ .page = .top }, -200, "b-top");
    try forward.addAnchorConstraint(forward_a, .top, .{ .node = .{ .node_id = forward_b, .anchor = .top } }, 0, "a-is-b");
    try testing.expectError(error.ConstraintConflict, finalizeDocumentState(&forward));

    var reverse = try initEmptyDocumentState();
    defer reverse.deinit();

    const reverse_page = try reverse.addPage("Page");
    const reverse_a = try reverse.makeObject(reverse_page, "a", null, .text, .text, "A");
    const reverse_b = try reverse.makeObject(reverse_page, "b", null, .text, .text, "B");
    try reverse.addAnchorConstraint(reverse_a, .top, .{ .page = .top }, -100, "a-top");
    try reverse.addAnchorConstraint(reverse_b, .top, .{ .page = .top }, -200, "b-top");
    try reverse.addAnchorConstraint(reverse_b, .top, .{ .node = .{ .node_id = reverse_a, .anchor = .top } }, 0, "b-is-a");
    try testing.expectError(error.ConstraintConflict, finalizeDocumentState(&reverse));

    var chain = try initEmptyDocumentState();
    defer chain.deinit();

    const chain_page = try chain.addPage("Page");
    const chain_a = try chain.makeObject(chain_page, "a", null, .text, .text, "A");
    const chain_b = try chain.makeObject(chain_page, "b", null, .text, .text, "B");
    const chain_c = try chain.makeObject(chain_page, "c", null, .text, .text, "C");
    try chain.addAnchorConstraint(chain_a, .top, .{ .page = .top }, -100, "a-top");
    try chain.addAnchorConstraint(chain_c, .top, .{ .page = .top }, -200, "c-top");
    try chain.addAnchorConstraint(chain_a, .top, .{ .node = .{ .node_id = chain_b, .anchor = .top } }, 0, "a-is-b");
    try chain.addAnchorConstraint(chain_b, .top, .{ .node = .{ .node_id = chain_c, .anchor = .top } }, 0, "b-is-c");
    try testing.expectError(error.ConstraintConflict, finalizeDocumentState(&chain));
}

test "layout solver: horizontal fallback does not seed inconsistent hard cycles" {
    var state = try initEmptyDocumentState();
    defer state.deinit();

    const page = try state.addPage("Page");
    const a = try state.makeObject(page, "a", null, .text, .text, "aa");
    const b = try state.makeObject(page, "b", null, .text, .text, "bb");
    try state.addAnchorConstraint(a, .left, .{ .node = .{ .node_id = b, .anchor = .left } }, 100, "a-left");
    try state.addAnchorConstraint(b, .left, .{ .node = .{ .node_id = a, .anchor = .left } }, 200, "b-left");

    try testing.expectError(error.ConstraintConflict, finalizeDocumentState(&state));
}

test "layout solver: constrained group source forms one fallback unit" {
    var state = try initEmptyDocumentState();
    defer state.deinit();

    try setLayoutPolicy(&state, state.document_id, "center");

    const page = try state.addPage("Page");
    const left_title = try state.makeObject(page, "left-title", null, .text, .text, "Left");
    const left_body = try state.makeObject(page, "left-body", null, .text, .text, "Body");
    const right = try state.makeObject(page, "right", null, .text, .text, "Right");
    const left_group = try state.makeGroupWithOrigin(state.document_id, false, &.{ left_title, left_body }, "left-group");

    try state.addAnchorConstraint(right, .left, .{ .node = .{ .node_id = left_group, .anchor = .right } }, 30, "right-of-group");
    try state.addAnchorConstraint(right, .center_y, .{ .node = .{ .node_id = left_group, .anchor = .center_y } }, 0, "align-group-center");

    try finalizeDocumentState(&state);

    const group_node = state.getNode(left_group).?;
    const left_title_node = state.getNode(left_title).?;
    const left_body_node = state.getNode(left_body).?;
    const right_node = state.getNode(right).?;
    try testing.expect(group_node.frame.x_set);
    try testing.expect(group_node.frame.y_set);
    try expectFloat(group_node.frame.x + group_node.frame.width + 30, right_node.frame.x);
    try expectFloat(group_node.frame.y + group_node.frame.height / 2, right_node.frame.y + right_node.frame.height / 2);

    const title_spacing = core.layout.styleForNode(&state, left_title_node).spacing_after;
    try expectFloat(left_title_node.frame.y - title_spacing, left_body_node.frame.y + left_body_node.frame.height);
}

test "layout solver: centered vflow treats vertically aligned groups as one row" {
    var state = try initEmptyDocumentState();
    defer state.deinit();

    try setLayoutPolicy(&state, state.document_id, "center");

    const page = try state.addPage("Page");
    const left_title = try state.makeObject(page, "left-title", null, .text, .text, "Left");
    const left_body = try state.makeObject(page, "left-body", null, .text, .text, "Body");
    const right_title = try state.makeObject(page, "right-title", null, .text, .text, "Right");
    const right_body = try state.makeObject(page, "right-body", null, .text, .text, "Body");
    const left_group = try state.makeGroupWithOrigin(state.document_id, false, &.{ left_title, left_body }, "left-group");
    const right_group = try state.makeGroupWithOrigin(state.document_id, false, &.{ right_title, right_body }, "right-group");

    try setLayoutLineHeight(&state, left_title, "40");
    try setLayoutLineHeight(&state, left_body, "200");
    try setLayoutLineHeight(&state, right_title, "40");
    try setLayoutLineHeight(&state, right_body, "200");
    try setLayoutSpacingAfter(&state, left_title, "20");
    try setLayoutSpacingAfter(&state, right_title, "20");
    try setLayoutSpacingAfter(&state, left_body, "0");
    try setLayoutSpacingAfter(&state, right_body, "0");

    try state.addAnchorConstraint(right_group, .left, .{ .node = .{ .node_id = left_group, .anchor = .right } }, 30, "right-of-left-group");
    try state.addAnchorConstraint(right_group, .center_y, .{ .node = .{ .node_id = left_group, .anchor = .center_y } }, 0, "align-group-centers");

    try finalizeDocumentState(&state);

    const left_group_node = state.getNode(left_group).?;
    const right_group_node = state.getNode(right_group).?;
    const left_center = left_group_node.frame.y + left_group_node.frame.height / 2;
    const right_center = right_group_node.frame.y + right_group_node.frame.height / 2;
    try expectFloat(left_center, right_center);

    const row_top = @max(left_group_node.frame.y + left_group_node.frame.height, right_group_node.frame.y + right_group_node.frame.height);
    const row_bottom = @min(left_group_node.frame.y, right_group_node.frame.y);
    try expectFloat(core.layout.Defaults.height / 2, (row_top + row_bottom) / 2);
}

test "layout solver: centered vflow clamps below fixed top components only when needed" {
    var state = try initEmptyDocumentState();
    defer state.deinit();

    try setLayoutPolicy(&state, state.document_id, "center");

    const page = try state.addPage("Page");
    const header = try state.makeObject(page, "title", null, .text, .text, "Title");
    const body = try state.makeObject(page, "body", null, .text, .text, "Body");

    try setLayoutLineHeight(&state, header, "44");
    try setLayoutSpacingAfter(&state, header, "40");
    try setLayoutLineHeight(&state, body, "580");
    try state.addAnchorConstraint(header, .top, .{ .page = .top }, -56, "header-top");

    try solveDocumentState(&state);

    const header_node = state.getNode(header).?;
    const body_node = state.getNode(body).?;
    const header_bottom = header_node.frame.y;
    const body_top = body_node.frame.y + body_node.frame.height;
    const header_spacing = core.layout.styleForNode(&state, header_node).spacing_after;
    try expectFloat(header_bottom - header_spacing, body_top);
}

test "layout solver: document centered vflow is not shadowed by page default policy" {
    var state = try initEmptyDocumentState();
    defer state.deinit();

    try setLayoutPolicy(&state, state.document_id, "center");
    try setLayoutCenterOffset(&state, state.document_id, "40");

    const page = try state.addPage("Page");
    const pageno = try state.makeObject(page, "pageno", null, .text, .text, "1");
    const title = try state.makeObject(page, "title", null, .text, .text, "Title");
    const subtitle = try state.makeObject(page, "subtitle", null, .text, .text, "Subtitle");

    try setLayoutLineHeight(&state, pageno, "16");
    try setLayoutSpacingAfter(&state, pageno, "0");
    try setLayoutLineHeight(&state, title, "94");
    try setLayoutSpacingAfter(&state, title, "42");
    try setLayoutLineHeight(&state, subtitle, "37");
    try setLayoutSpacingAfter(&state, subtitle, "0");
    try state.addAnchorConstraint(pageno, .bottom, .{ .page = .bottom }, 20, "pageno-bottom");

    try solveDocumentState(&state);

    const pageno_node = state.getNode(pageno).?;
    const title_node = state.getNode(title).?;
    const subtitle_node = state.getNode(subtitle).?;
    const stack_top = graph.anchorValue(title_node.frame, .top);
    const stack_bottom = graph.anchorValue(subtitle_node.frame, .bottom);
    try expectFloat(core.layout.Defaults.height / 2 - 40, (stack_top + stack_bottom) / 2);
    try testing.expect(graph.anchorValue(title_node.frame, .bottom) > graph.anchorValue(pageno_node.frame, .top));
}

test "layout solver: centered vflow preserves page center for side-by-side rows" {
    var state = try initEmptyDocumentState();
    defer state.deinit();

    try setLayoutPolicy(&state, state.document_id, "center");

    const page = try state.addPage("Page");
    const title = try state.makeObject(page, "title", null, .text, .text, "Title");
    const rule = try state.makeObject(page, "rule", null, .text, .text, "");
    const body = try state.makeObject(page, "body", null, .text, .text, "Body");
    const pipe_child = try state.makeObject(page, "pipe", null, .text, .text, "Pipe");
    const pipe = try state.makeGroupWithOrigin(page, true, &.{pipe_child}, "pipe-group");

    try setLayoutLineHeight(&state, title, "44");
    try setLayoutLineHeight(&state, rule, "4");
    try setLayoutSpacingAfter(&state, rule, "48");
    try setLayoutLineHeight(&state, body, "360");
    try setLayoutLineHeight(&state, pipe_child, "360");
    try state.addAnchorConstraint(title, .top, .{ .page = .top }, -56, "title-top");
    try state.addAnchorConstraint(rule, .top, .{ .node = .{ .node_id = title, .anchor = .bottom } }, -14, "rule-below-title");
    try state.addAnchorConstraint(pipe, .right, .{ .page = .right }, -100, "pipe-right");
    try state.addAnchorConstraint(pipe, .top, .{ .node = .{ .node_id = body, .anchor = .top } }, 0, "align-row-top");

    try solveDocumentState(&state);

    const body_node = state.getNode(body).?;
    const pipe_node = state.getNode(pipe).?;
    const body_center = body_node.frame.y + body_node.frame.height / 2;
    const pipe_center = pipe_node.frame.y + pipe_node.frame.height / 2;
    try expectFloat(body_center, pipe_center);
    try expectFloat(core.layout.Defaults.height / 2, body_center);
}

test "layout solver: explicit anchor conflicts and negative frame sizes are rejected" {
    var conflict = try initEmptyDocumentState();
    defer conflict.deinit();

    const conflict_page = try conflict.addPage("Page");
    const conflict_object = try conflict.makeObject(conflict_page, "body", null, .text, .text, "A");
    try conflict.addAnchorConstraint(conflict_object, .left, .{ .page = .left }, 100, "left-a");
    try conflict.addAnchorConstraint(conflict_object, .left, .{ .page = .left }, 120, "left-b");
    try testing.expectError(error.ConstraintConflict, finalizeDocumentState(&conflict));

    var negative = try initEmptyDocumentState();
    defer negative.deinit();

    const negative_page = try negative.addPage("Page");
    const negative_object = try negative.makeObject(negative_page, "body", null, .text, .text, "A");
    try negative.addAnchorConstraint(negative_object, .left, .{ .node = .{ .node_id = negative_object, .anchor = .right } }, 10, "negative-width");
    try testing.expectError(error.NegativeFrameSize, finalizeDocumentState(&negative));
}

test "layout solver: group width propagation must preserve child hard widths" {
    var state = try initEmptyDocumentState();
    defer state.deinit();

    const page = try state.addPage("Page");
    const child = try state.makeObject(page, "body", null, .text, .text, "this text can be wrapped");
    try setLayoutWrap(&state, child, "on");
    const group = try state.makeGroupWithOrigin(page, true, &.{child}, "group");

    try state.addAnchorConstraint(child, .left, .{ .page = .left }, 100, "child-left");
    try state.addAnchorConstraint(child, .right, .{ .node = .{ .node_id = child, .anchor = .left } }, 700, "child-width");
    try state.addAnchorConstraint(group, .right, .{ .node = .{ .node_id = group, .anchor = .left } }, 600, "group-width");

    try testing.expectError(error.ConstraintConflict, finalizeDocumentState(&state));
}

test "layout solver: wrapped width cap propagates through dependent anchors" {
    var state = try initEmptyDocumentState();
    defer state.deinit();

    const page = try state.addPage("Page");
    const wrapped = try state.makeObject(
        page,
        "wrapped",
        null,
        .text,
        .text,
        "this is intentionally long enough to produce a wide intrinsic text box",
    );
    const follower = try state.makeObject(page, "follower", null, .text, .text, "B");
    try setLayoutWrap(&state, wrapped, "on");

    try state.addAnchorConstraint(wrapped, .left, .{ .page = .left }, 1100, "wrapped-left");
    try state.addAnchorConstraint(follower, .left, .{ .node = .{ .node_id = wrapped, .anchor = .right } }, 20, "follower-left");

    try solveDocumentState(&state);

    const wrapped_node = state.getNode(wrapped).?;
    const follower_node = state.getNode(follower).?;
    const style = core.layout.styleForNode(&state, wrapped_node);
    const expected_width = core.layout.Defaults.width - style.default_right_inset - 1100;
    try expectFloat(expected_width, wrapped_node.frame.width);
    try expectFloat(wrapped_node.frame.x + wrapped_node.frame.width + 20, follower_node.frame.x);
}

test "layout solver: vertical axis observes width-dependent wrapped height" {
    var state = try initEmptyDocumentState();
    defer state.deinit();

    const page = try state.addPage("Page");
    const wrapped = try state.makeObject(
        page,
        "wrapped",
        null,
        .text,
        .text,
        "this sentence should wrap into multiple lines once the horizontal solver caps its width",
    );
    try setLayoutWrap(&state, wrapped, "on");
    try state.addAnchorConstraint(wrapped, .left, .{ .page = .left }, 1100, "wrapped-left");
    try state.addAnchorConstraint(wrapped, .bottom, .{ .page = .bottom }, 40, "wrapped-bottom");

    try solveDocumentState(&state);

    const wrapped_node = state.getNode(wrapped).?;
    const expected_height = metrics.intrinsicHeight(&state, wrapped_node);
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
    state_ptr: *anyopaque,
    node: *const model.Node,
    width: f32,
    mode: model.LayoutMeasurementMode,
) anyerror!?model.LayoutMeasurement {
    _ = state_ptr;
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
    state_ptr: *anyopaque,
    node: *const model.Node,
    width: f32,
    mode: model.LayoutMeasurementMode,
) anyerror!?model.LayoutMeasurement {
    _ = state_ptr;
    _ = node;
    _ = width;
    _ = mode;
    const ctx: *FakeAllMeasurementContext = @ptrCast(@alignCast(context));
    ctx.calls += 1;
    return .{ .width = 1000, .height = 700 };
}

test "layout solver uses render measurement provider for intrinsic object size" {
    var state = try initEmptyDocumentState();
    defer state.deinit();

    const page = try state.addPage("Page");
    const object = try state.makeObject(page, "body", null, .text, .text, "provider measured text");
    var measurement = FakeMeasurementContext{ .target = object };

    try solveDocumentStateWithOptions(&state, null, .{
        .measurement_provider = .{
            .context = &measurement,
            .measure = fakeLayoutMeasurement,
        },
    });

    const node = state.getNode(object).?;
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
    var state = try initEmptyDocumentState();
    defer state.deinit();

    const first_page = try state.addPage("First");
    const first = try state.makeObject(first_page, "first", null, .text, .text, "First");
    try state.addAnchorConstraint(first, .left, .{ .page = .left }, 40, "first-left");
    try state.addAnchorConstraint(first, .top, .{ .page = .top }, -80, "first-top");

    const second_page = try state.addPage("Second");
    const second = try state.makeObject(second_page, "second", null, .text, .text, "Second");
    try state.addAnchorConstraint(second, .left, .{ .page = .left }, 80, "second-left");
    try state.addAnchorConstraint(second, .top, .{ .page = .top }, -120, "second-top");

    var counter = LayoutProgressCounter{};
    var results = try solver.solveDocument(&state, null, .{
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
    var state = try initEmptyDocumentState();
    defer state.deinit();

    const page = try state.addPage("Page");
    const pdf = try state.makeObject(page, "pdf", null, .asset, .pdf_ref, "chart.pdf");
    try setNumberField(&state, pdf, "asset_width", 220);
    try setNumberField(&state, pdf, "asset_height", 70);
    const image = try state.makeObject(page, "image", null, .asset, .image_ref, "chart.png");
    try setNumberField(&state, image, "asset_width", 180);
    try setNumberField(&state, image, "asset_height", 90);

    var measurement = FakeAllMeasurementContext{};
    try solveDocumentStateWithOptions(&state, null, .{
        .measurement_provider = .{
            .context = &measurement,
            .measure = fakeAllLayoutMeasurement,
        },
    });

    const pdf_node = state.getNode(pdf).?;
    try expectFloat(220, pdf_node.frame.width);
    try expectFloat(70, pdf_node.frame.height);
    const image_node = state.getNode(image).?;
    try expectFloat(180, image_node.frame.width);
    try expectFloat(90, image_node.frame.height);
    try testing.expectEqual(@as(usize, 0), measurement.calls);
}

test "layout metrics use measured font width for wrapped text height" {
    var state = try initEmptyDocumentState();
    defer state.deinit();

    const page = try state.addPage("Page");
    const object = try state.makeObject(page, "body", null, .text, .text, "0123456789012345678901234567");
    try setLayoutWrap(&state, object, "on");
    try setTextFontFamily(&state, object, "Helvetica");
    try setTextSize(&state, object, "30");

    const node = state.getNode(object).?;
    node.frame.width = 480;

    try expectFloat(43.5, metrics.intrinsicHeight(&state, node));
}

test "layout metrics use render atom widths for CJK emoji markdown text" {
    var state = try initEmptyDocumentState();
    defer state.deinit();

    const page = try state.addPage("Page");
    const object = try state.makeObject(page, "body", null, .text, .text, "✅ 最初のエラー報告までの時間が短縮できる");
    try setLayoutWrap(&state, object, "on");
    try setTextParse(&state, object, "block");
    try setTextFontFamily(&state, object, "Helvetica");
    try setTextFontWeight(&state, object, "700");
    try setTextSize(&state, object, "30");
    try setTextLineHeight(&state, object, "31");

    const node = state.getNode(object).?;
    const measured_width = metrics.intrinsicWidth(&state, node);
    try testing.expect(measured_width > 1);
    node.frame.width = measured_width - 1;

    try expectFloat(62, metrics.intrinsicHeight(&state, node));
}

test "layout solver keeps CJK emoji markdown text on one line when measured atom width fits" {
    var state = try initEmptyDocumentState();
    defer state.deinit();

    const page = try state.addPage("Page");
    const object = try state.makeObject(page, "body", null, .text, .text, "✅ 最初のエラー報告までの時間が短縮できる");
    try setLayoutWrap(&state, object, "on");
    try setTextParse(&state, object, "block");
    try setTextFontFamily(&state, object, "Helvetica");
    try setTextFontWeight(&state, object, "700");
    try setTextSize(&state, object, "30");
    try setTextLineHeight(&state, object, "31");

    const expected_width = metrics.intrinsicWidth(&state, state.getNode(object).?);
    try testing.expect(expected_width > 1);

    try solveDocumentState(&state);

    const node = state.getNode(object).?;
    try expectFloat(expected_width, node.frame.width);
    try expectFloat(31, node.frame.height);
}

test "layout metrics: chrome padding is part of visual bounds and yields a content frame" {
    var state = try initEmptyDocumentState();
    defer state.deinit();

    const page = try state.addPage("Page");
    const plain = try state.makeObject(page, "plain", null, .text, .text, "Hello");
    const padded = try state.makeObject(page, "padded", null, .text, .text, "Hello");
    try setChromePadX(&state, padded, "12");
    try setChromePadY(&state, padded, "8");

    const plain_node = state.getNode(plain).?;
    const padded_node = state.getNode(padded).?;
    try expectFloat(metrics.intrinsicWidth(&state, plain_node) + 24, metrics.intrinsicWidth(&state, padded_node));
    try expectFloat(metrics.intrinsicHeight(&state, plain_node) + 16, metrics.intrinsicHeight(&state, padded_node));

    state.getNode(padded).?.frame = .{ .x = 10, .y = 20, .width = 100, .height = 50, .x_set = true, .y_set = true };
    const content = core.layout.contentFrame(&state, state.getNode(padded).?);
    try expectFloat(22, content.x);
    try expectFloat(28, content.y);
    try expectFloat(76, content.width);
    try expectFloat(34, content.height);
}

test "layout metrics: unwrapped text width includes visual glyph bounds" {
    var state = try initEmptyDocumentState();
    defer state.deinit();

    const page = try state.addPage("Page");
    const object = try state.makeObject(page, "body", null, .text, .text, "コンポーネントの集合と絶対位置");
    try setTextSize(&state, object, "24");
    try setChromePadX(&state, object, "20");

    const node = state.getNode(object).?;
    const style = core.layout.style.textMetricsForNode(&state, node);
    const font = core.font.textFacesForNode(&state, node).normal;
    var atom_width: f32 = 0;
    var utf8 = try std.unicode.Utf8View.init(node.content.?);
    var iterator = utf8.iterator();
    while (iterator.nextCodepointSlice()) |slice| {
        atom_width += try core.render_text_measure.advanceWidth(testing.allocator, slice, font, style.font_size);
    }

    try testing.expect(metrics.intrinsicWidth(&state, node) >= atom_width + 40);
}

test "layout solver: group chrome padding expands tight group bounds" {
    var state = try initEmptyDocumentState();
    defer state.deinit();

    const page = try state.addPage("Page");
    const child = try state.makeObject(page, "child", null, .text, .text, "Hello");
    const group = try state.makeGroupWithOrigin(page, true, &.{child}, "group");
    try setChromePadX(&state, group, "12");
    try setChromePadY(&state, group, "8");

    try state.addAnchorConstraint(child, .left, .{ .page = .left }, 100, "child-left");
    try state.addAnchorConstraint(child, .right, .{ .node = .{ .node_id = child, .anchor = .left } }, 200, "child-width");
    try state.addAnchorConstraint(child, .bottom, .{ .page = .bottom }, 100, "child-bottom");
    try state.addAnchorConstraint(child, .top, .{ .node = .{ .node_id = child, .anchor = .bottom } }, 40, "child-height");

    try solveDocumentState(&state);

    const group_node = state.getNode(group).?;
    try expectFloat(88, group_node.frame.x);
    try expectFloat(92, group_node.frame.y);
    try expectFloat(224, group_node.frame.width);
    try expectFloat(56, group_node.frame.height);
}

test "layout solver: target group width leaves room for chrome padding" {
    var state = try initEmptyDocumentState();
    defer state.deinit();

    const page = try state.addPage("Page");
    const child = try state.makeObject(
        page,
        "child",
        null,
        .text,
        .text,
        "this sentence is intentionally long enough to wrap when the group width is constrained",
    );
    try setLayoutWrap(&state, child, "on");
    const group = try state.makeGroupWithOrigin(page, true, &.{child}, "group");
    try setChromePadX(&state, group, "10");

    try state.addAnchorConstraint(group, .left, .{ .page = .left }, 100, "group-left");
    try state.addAnchorConstraint(group, .right, .{ .node = .{ .node_id = group, .anchor = .left } }, 220, "group-width");

    try solveDocumentState(&state);

    const group_node = state.getNode(group).?;
    const child_node = state.getNode(child).?;
    try expectFloat(100, group_node.frame.x);
    try expectFloat(220, group_node.frame.width);
    try expectFloat(110, child_node.frame.x);
    try expectFloat(200, child_node.frame.width);
}

test "layout diagnostics: fixed-height object reports frame too small" {
    var state = try initEmptyDocumentState();
    defer state.deinit();

    const page = try state.addPage("Page");
    const object = try state.makeObject(page, "short-box", null, .text, .text, "line one\nline two");
    try state.addAnchorConstraint(object, .left, .{ .page = .left }, 20, "left");
    try state.addAnchorConstraint(object, .right, .{ .node = .{ .node_id = object, .anchor = .left } }, 200, "width");
    try state.addAnchorConstraint(object, .bottom, .{ .page = .bottom }, 20, "bottom");
    try state.addAnchorConstraint(object, .top, .{ .node = .{ .node_id = object, .anchor = .bottom } }, 20, "height");

    try solveDocumentState(&state);

    const node = state.getNode(object).?;
    try expectFloat(20, node.frame.height);
    const required_height = metrics.intrinsicHeight(&state, node);
    try testing.expect(required_height > node.frame.height);

    var found = false;
    for (state.diagnostics.items) |diagnostic| {
        if (diagnostic.node_id != object) continue;
        switch (diagnostic.data) {
            .content_overflow => |data| {
                found = true;
                try testing.expectEqual(core.DiagnosticSeverity.warning, diagnostic.severity);
                try expectFloat(metrics.intrinsicWidth(&state, node), data.required_width);
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
    var state = try initEmptyDocumentState();
    defer state.deinit();

    const page = try state.addPage("Page");
    const object = try state.makeObject(page, "toc-marker", null, .text, .text, "hidden section title");
    try setLayoutFontSize(&state, object, "1");
    try setLayoutLineHeight(&state, object, "1");
    try setTextSize(&state, object, "1");
    try setTextLineHeight(&state, object, "1");
    try setLayoutWrap(&state, object, "on");
    try state.addAnchorConstraint(object, .left, .{ .page = .left }, 20, "left");
    try state.addAnchorConstraint(object, .right, .{ .node = .{ .node_id = object, .anchor = .left } }, 1, "width");
    try state.addAnchorConstraint(object, .bottom, .{ .page = .bottom }, 20, "bottom");
    try state.addAnchorConstraint(object, .top, .{ .node = .{ .node_id = object, .anchor = .bottom } }, 1, "height");

    try solveDocumentState(&state);

    var found = false;
    for (state.diagnostics.items) |diagnostic| {
        if (diagnostic.node_id == object and diagnostic.data == .content_overflow) found = true;
    }
    try testing.expect(found);
}

test "layout font size resolves consistently for measurement and rendering" {
    var state = try initEmptyDocumentState();
    defer state.deinit();

    const page = try state.addPage("Page");
    const object = try state.makeObject(page, "body", null, .text, .text, "one\ntwo");
    try setLayoutFontSize(&state, object, "20");
    try setTextSize(&state, object, "30");
    try setTextLineHeight(&state, object, "45");

    const node = state.getNode(object).?;
    try expectFloat(90, metrics.intrinsicHeight(&state, node));
    const resolved = core.render_policy.resolve(&state, node);
    try expectFloat(20, resolved.text.?.font_size);
    try expectFloat(45, resolved.text.?.line_height);
}

test "layout metrics derive line height from explicit text size" {
    var state = try initEmptyDocumentState();
    defer state.deinit();

    const page = try state.addPage("Page");
    const object = try state.makeObject(page, "body", null, .text, .text, "one\ntwo");
    try setTextSize(&state, object, "30");

    const node = state.getNode(object).?;
    try expectFloat(87, metrics.intrinsicHeight(&state, node));

    const resolved = core.render_policy.resolve(&state, node);
    try expectFloat(30, resolved.text.?.font_size);
    try expectFloat(43.5, resolved.text.?.line_height);
}

test "layout metrics honor explicit text and layout line heights" {
    var state = try initEmptyDocumentState();
    defer state.deinit();

    const page = try state.addPage("Page");
    const text_only = try state.makeObject(page, "text-only", null, .text, .text, "one\ntwo");
    try setTextSize(&state, text_only, "30");
    try setTextLineHeight(&state, text_only, "45");
    try expectFloat(90, metrics.intrinsicHeight(&state, state.getNode(text_only).?));

    const layout_override = try state.makeObject(page, "layout-override", null, .text, .text, "one\ntwo");
    try setTextSize(&state, layout_override, "30");
    try setTextLineHeight(&state, layout_override, "45");
    try setLayoutLineHeight(&state, layout_override, "50");
    try expectFloat(100, metrics.intrinsicHeight(&state, state.getNode(layout_override).?));

    const resolved = core.render_policy.resolve(&state, state.getNode(layout_override).?);
    try expectFloat(50, resolved.text.?.line_height);
}

test "layout metrics treat zero line heights as automatic" {
    var state = try initEmptyDocumentState();
    defer state.deinit();

    const page = try state.addPage("Page");
    const object = try state.makeObject(page, "body", null, .text, .text, "one\ntwo");
    try setTextSize(&state, object, "30");
    try setTextLineHeight(&state, object, "0");
    try setLayoutLineHeight(&state, object, "0");

    const node = state.getNode(object).?;
    try expectFloat(87, metrics.intrinsicHeight(&state, node));

    const resolved = core.render_policy.resolve(&state, node);
    try expectFloat(43.5, resolved.text.?.line_height);
}

test "render policy: invalid numeric properties fall back before rendering" {
    var state = try initEmptyDocumentState();
    defer state.deinit();

    const page = try state.addPage("Page");
    const object = try state.makeObject(page, "bad-numbers", null, .text, .text, "Hello");
    try setTextSize(&state, object, "-1");
    try setTextLineHeight(&state, object, "nan");
    try setTextInlineMathHeightFactor(&state, object, "0");
    try setChromePadX(&state, object, "-10");
    try setChromePadY(&state, object, "inf");
    try setChromeLineWidth(&state, object, "-2");
    try setUnderlineWidth(&state, object, "-1");
    try setRuleLineWidth(&state, object, "-1");
    try setRuleDash(&state, object, "inf, 4");

    const resolved = core.render_policy.resolve(&state, state.getNode(object).?);
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
    var state = try initEmptyDocumentState();
    defer state.deinit();

    const page = try state.addPage("Page");
    const object = try state.makeObject(page, "font", null, .text, .text, "Hello");
    try setTextFontFamily(&state, object, "Avenir Next");
    try setTextFontWeight(&state, object, "650");
    try setTextFontStyle(&state, object, "oblique");
    try setTextFontStretch(&state, object, "condensed");
    try setTextMarkdownBoldWeight(&state, object, "720");
    try setTextMarkdownItalicStyle(&state, object, "italic");
    try setTextCodeFontFamily(&state, object, "Menlo");
    try setTextCodeFontWeight(&state, object, "500");

    const resolved = core.render_policy.resolve(&state, state.getNode(object).?);
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
    var state = try initEmptyDocumentState();
    defer state.deinit();

    const page = try state.addPage("Page");
    const object = try state.makeObject(page, "body", null, .text, .text, "**Hello**");

    var resolved = core.render_policy.resolve(&state, state.getNode(object).?);
    try testing.expect(resolved.text.?.markdown_bold_color == null);

    try setTextMarkdownBoldColor(&state, object, "0.2,0.4,0.6");
    resolved = core.render_policy.resolve(&state, state.getNode(object).?);
    try expectColor(0.2, 0.4, 0.6, resolved.text.?.markdown_bold_color.?);
}

test "render policy: markdown headings resolve their own text paint" {
    var state = try initEmptyDocumentState();
    defer state.deinit();

    const page = try state.addPage("Page");
    const object = try state.makeObject(page, "body", null, .text, .text, "## Heading");
    try setRecordPathValue(&state, object, "markdown_headings", &.{ "h2", "text", "size" }, .{ .number = 35 });
    try setRecordPathValue(&state, object, "markdown_headings", &.{ "h2", "text", "line_height" }, .{ .number = 42 });
    try setRecordPathValue(&state, object, "markdown_headings", &.{ "h2", "text", "color" }, .{ .string = "0.1,0.6,0.2" });
    try setRecordPathValue(&state, object, "markdown_headings", &.{ "h2", "text", "font", "family" }, .{ .string = "Avenir Next" });
    try setRecordPathValue(&state, object, "markdown_headings", &.{ "h2", "text", "font", "weight" }, .{ .number = 650 });
    try setRecordPathValue(&state, object, "markdown_headings", &.{ "h2", "text", "inline_math_height_factor" }, .{ .number = 1.3 });
    try setRecordPathValue(&state, object, "markdown_headings", &.{ "h2", "text", "inline_math_spacing" }, .{ .number = 0.2 });
    try setRecordPathValue(&state, object, "markdown_headings", &.{ "h2", "text", "display_math_height_factor" }, .{ .number = 2.4 });
    try setRecordPathValue(&state, object, "markdown_headings", &.{ "h2", "text", "math_align" }, .{ .string = "left" });
    try setRecordPathValue(&state, object, "markdown_headings", &.{ "h2", "text", "emoji_spacing" }, .{ .number = 0.25 });

    const resolved = core.render_policy.resolve(&state, state.getNode(object).?);
    const heading = resolved.text.?.markdown_headings[1].?;
    try expectFloat(35, heading.font_size);
    try expectFloat(42, heading.line_height);
    try expectColor(0.1, 0.6, 0.2, heading.color);
    try testing.expectEqualStrings("Avenir Next", heading.font.family);
    try testing.expectEqual(@as(u16, 650), heading.font.weight);

    const selected = resolved.text.?.forMarkdownHeading(2);
    try expectFloat(35, selected.font_size);
    try expectFloat(42, selected.line_height);
    try expectColor(0.1, 0.6, 0.2, selected.color);
    try expectFloat(1.3, selected.inline_math_height_factor);
    try expectFloat(0.2, selected.inline_math_spacing);
    try expectFloat(2.4, selected.display_math_height_factor);
    try testing.expectEqual(core.render_policy.HorizontalAlign.left, selected.math_align);
    try expectFloat(0.25, selected.emoji_spacing);
}

test "layout metrics use the markdown block gap after a heading" {
    var state = try initEmptyDocumentState();
    defer state.deinit();

    const page = try state.addPage("Page");
    const compact = try state.makeObject(page, "compact", null, .text, .text, "## Heading\n\nBody");
    const relaxed = try state.makeObject(page, "relaxed", null, .text, .text, "## Heading\n\nBody");
    for ([_]model.NodeId{ compact, relaxed }) |object| {
        try setLayoutWrap(&state, object, "on");
        try setTextParse(&state, object, "block");
        try setTextFontFamily(&state, object, "Helvetica");
        try setTextSize(&state, object, "23");
        try setTextLineHeight(&state, object, "31");
        try setRecordPathValue(&state, object, "markdown_headings", &.{ "h2", "text", "font", "family" }, .{ .string = "Helvetica" });
        try setRecordPathValue(&state, object, "markdown_headings", &.{ "h2", "text", "size" }, .{ .number = 30 });
        try setRecordPathValue(&state, object, "markdown_headings", &.{ "h2", "text", "line_height" }, .{ .number = 37 });
        // Standalone heading layout spacing must not override spacing inside a Markdown document.
        try setRecordPathValue(&state, object, "markdown_headings", &.{ "h2", "spacing_after" }, .{ .number = 97 });
        state.getNode(object).?.frame.width = 1000;
    }
    try setRecordNumberField(&state, compact, "text", "markdown_block_gap", 8);
    try setRecordNumberField(&state, relaxed, "text", "markdown_block_gap", 20);

    const compact_height = metrics.intrinsicHeight(&state, state.getNode(compact).?);
    const relaxed_height = metrics.intrinsicHeight(&state, state.getNode(relaxed).?);
    try expectFloat(12, relaxed_height - compact_height);
}

test "render policy: math alignment applies to markdown and vector math" {
    var state = try initEmptyDocumentState();
    defer state.deinit();

    const page = try state.addPage("Page");
    const text_object = try state.makeObject(page, "body", null, .text, .text, "$$x^2$$");
    try setMathAlign(&state, text_object, "left");

    const resolved_text = core.render_policy.resolve(&state, state.getNode(text_object).?);
    try testing.expectEqual(core.render_policy.HorizontalAlign.left, resolved_text.text.?.math_align);

    const invalid_text_object = try state.makeObject(page, "body", null, .text, .text, "$$z^2$$");
    try setMathAlign(&state, invalid_text_object, "sideways");
    const resolved_invalid_text = core.render_policy.resolve(&state, state.getNode(invalid_text_object).?);
    try testing.expectEqual(core.render_policy.HorizontalAlign.center, resolved_invalid_text.text.?.math_align);

    try setMathAlign(&state, state.document_id, "right");
    const document_text_object = try state.makeObject(page, "body", null, .text, .text, "$$a^2$$");
    const resolved_document_text = core.render_policy.resolve(&state, state.getNode(document_text_object).?);
    try testing.expectEqual(core.render_policy.HorizontalAlign.right, resolved_document_text.text.?.math_align);

    try setMathAlign(&state, page, "left");
    const page_text_object = try state.makeObject(page, "body", null, .text, .text, "$$b^2$$");
    const resolved_page_text = core.render_policy.resolve(&state, state.getNode(page_text_object).?);
    try testing.expectEqual(core.render_policy.HorizontalAlign.left, resolved_page_text.text.?.math_align);

    const math_object = try state.makeObject(page, "math_tex", null, .text, .text, "\\int_0^1 x^2 \\, dx");
    try setRenderKind(&state, math_object, "vector_math");
    try setMathAlign(&state, math_object, "right");

    const resolved_math = core.render_policy.resolve(&state, state.getNode(math_object).?);
    try testing.expectEqual(core.render_policy.HorizontalAlign.right, resolved_math.math.?.horizontal_align);
}
