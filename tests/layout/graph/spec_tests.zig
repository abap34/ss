const LayoutFixture = @import("layout_testing").Fixture;
const std = @import("std");
const allocation_testing = @import("allocation_testing");
const ast = @import("ast");
const core = @import("core");
const model = @import("model");
const utils = @import("utils");

const graph = core.layout.graph;
const metrics = core.layout.metrics;
const solver = core.layout.solver;

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

fn finalizeDocumentState(layout: *LayoutFixture) !void {
    try layout.solve(null, .{}, true);
}
fn solveDocumentState(layout: *LayoutFixture) !void {
    try layout.solve(null, .{}, false);
}
fn solveDocumentStateWithOptions(layout: *LayoutFixture, trace_path: ?[]const u8, options: graph.SolveOptions) !void {
    try layout.solve(trace_path, options, false);
}

fn expectFloat(expected: f32, actual: f32) !void {
    try testing.expectApproxEqAbs(expected, actual, graph.ConstraintTolerance);
}

fn expectFrame(expected: model.Frame, actual: model.Frame) !void {
    try expectFloat(expected.x, actual.x);
    try expectFloat(expected.y, actual.y);
    try expectFloat(expected.width, actual.width);
    try expectFloat(expected.height, actual.height);
    try testing.expectEqual(expected.x_set, actual.x_set);
    try testing.expectEqual(expected.y_set, actual.y_set);
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
    var parts = std.ArrayList([]const u8).empty;
    defer parts.deinit(state.allocator);
    var iter = std.mem.splitScalar(u8, field_name, '.');
    while (iter.next()) |part| try parts.append(state.allocator, part);
    try setRecordPathValue(state, node_id, root_key, parts.items, value);
}

fn setRecordPathValue(state: *core.DocumentState, node_id: model.NodeId, root_key: []const u8, path: []const []const u8, value: core.Value) !void {
    const node = state.getNode(node_id) orelse return error.UnknownNode;
    for (node.fields.items) |*field| {
        if (!std.mem.eql(u8, field.key, root_key)) continue;
        if (field.value != .record) return error.ExpectedRecordField;
        try putRecordPathValue(state.allocator, &field.value.record, path, value);
        return;
    }

    var record = core.RecordValue.init(ast.Type.recordType(recordTypeName(root_key)));
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

    var nested = core.RecordValue.init(ast.Type.recordType(recordTypeName(path[0])));
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
    if (std.mem.eql(u8, root_key, "latex")) return "LatexStyle";
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

fn setTextMathScale(state: *core.DocumentState, node_id: model.NodeId, value: []const u8) !void {
    try setRecordStringField(state, node_id, "text", "math.scale", value);
}

fn setTextMarkdownBoldColor(state: *core.DocumentState, node_id: model.NodeId, value: []const u8) !void {
    try setRecordStringField(state, node_id, "text", "markdown.bold_color", value);
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
    var state_layout = LayoutFixture.init(&state);
    defer state_layout.deinit();

    const page = try state.addPage("Page");
    const a = try state.makeObject(page, "a", null, .text, .text, "A");
    const b = try state.makeObject(page, "b", null, .text, .text, "B");
    _ = try state.makeGroupWithOrigin(page, true, &.{ a, b }, .{ .label = "group" });

    try state.constraints.addAnchor(state.allocator, a, .left, .{ .page = .left }, 10, .{ .label = "a-left" });
    try state.constraints.addAnchor(state.allocator, a, .top, .{ .page = .top }, -10, .{ .label = "a-top" });
    try state.constraints.addAnchor(state.allocator, b, .left, .{ .node = .{ .node_id = a, .anchor = .right } }, 20, .{ .label = "b-left" });

    var page_graph = try initPageGraph(&state, page);
    defer page_graph.deinit();

    try testing.expectEqual(@as(usize, 3), page_graph.len());
    try testing.expect(page_graph.indexOf(a) != null);
    try testing.expect(page_graph.indexOf(b) != null);
    try testing.expect(page_graph.hasTargetConstraint(try state_layout.work(), a, .horizontal, &.{}));
    try testing.expect(page_graph.hasTargetConstraint(try state_layout.work(), a, .vertical, &.{}));
    try testing.expect(!page_graph.hasTargetConstraint(try state_layout.work(), b, .vertical, &.{}));

    try testing.expectEqual(@as(usize, 2), page_graph.constraintsOnAxis(.horizontal).len);
    try testing.expectEqualSlices(usize, &.{ 0, 1 }, page_graph.targetConstraintIndexes(a));
    try testing.expectEqualSlices(usize, &.{2}, page_graph.targetConstraintIndexes(b));
    try testing.expectEqual(a, page_graph.constraintTargetingAnchor(b, .left).?.source.node.node_id);
    try testing.expect(page_graph.constraintTargetingAnchor(b, .top) == null);
}

test "layout graph spec: implicit constraint objects stay page local" {
    var state = try initEmptyDocumentState();
    defer state.deinit();
    var state_layout = LayoutFixture.init(&state);
    defer state_layout.deinit();

    const first_page = try state.addPage("First");
    const second_page = try state.addPage("Second");
    const placed = try state.makeObject(first_page, "placed", null, .text, .text, "placed");
    const helper = try state.createObjectWithOrigin("helper", null, .text, .text, "helper", null);
    const foreign = try state.makeObject(second_page, "foreign", null, .text, .text, "foreign");
    try state.constraints.addAnchor(state.allocator, placed, .top, .{ .node = .{ .node_id = helper, .anchor = .top } }, 10, .{ .label = "helper-top" });
    try state.constraints.addAnchor(state.allocator, placed, .left, .{ .node = .{ .node_id = foreign, .anchor = .left } }, 20, .{ .label = "foreign-left" });

    var first_graph = try initPageGraph(&state, first_page);
    defer first_graph.deinit();
    try testing.expect(first_graph.indexOf(placed) != null);
    try testing.expect(first_graph.indexOf(helper) == null);
    try testing.expect(first_graph.indexOf(foreign) == null);

    var second_graph = try initPageGraph(&state, second_page);
    defer second_graph.deinit();
    try testing.expect(second_graph.indexOf(foreign) != null);
    try testing.expect(second_graph.indexOf(placed) == null);
}

test "layout graph spec: constraint classification names layout dependency roles" {
    var state = try initEmptyDocumentState();
    defer state.deinit();
    var state_layout = LayoutFixture.init(&state);
    defer state_layout.deinit();

    const page = try state.addPage("Page");
    const a = try state.makeObject(page, "a", null, .text, .text, "A");
    const b = try state.makeObject(page, "b", null, .text, .text, "B");
    const group_id = try state.makeGroupWithOrigin(page, true, &.{ a, b }, .{ .label = "group" });

    var page_graph = try initPageGraph(&state, page);
    defer page_graph.deinit();

    try testing.expectEqual(graph.ConstraintClass.page_source, page_graph.constraintClass(try state_layout.work(), .{
        .target_node = a,
        .target_anchor = .left,
        .source = .{ .page = .left },
        .offset = 10,
    }, .horizontal));

    try testing.expectEqual(graph.ConstraintClass.normal, page_graph.constraintClass(try state_layout.work(), .{
        .target_node = b,
        .target_anchor = .left,
        .source = .{ .node = .{ .node_id = a, .anchor = .right } },
        .offset = 20,
    }, .horizontal));

    try testing.expectEqual(graph.ConstraintClass.self_size, page_graph.constraintClass(try state_layout.work(), .{
        .target_node = a,
        .target_anchor = .right,
        .source = .{ .node = .{ .node_id = a, .anchor = .left } },
        .offset = 120,
    }, .horizontal));

    try testing.expectEqual(graph.ConstraintClass.self_anchor, page_graph.constraintClass(try state_layout.work(), .{
        .target_node = a,
        .target_anchor = .right,
        .source = .{ .node = .{ .node_id = a, .anchor = .right } },
        .offset = 120,
    }, .horizontal));

    try testing.expectEqual(graph.ConstraintClass.group_target, page_graph.constraintClass(try state_layout.work(), .{
        .target_node = group_id,
        .target_anchor = .left,
        .source = .{ .page = .left },
        .offset = 0,
    }, .horizontal));

    try testing.expectEqual(graph.ConstraintClass.group_source, page_graph.constraintClass(try state_layout.work(), .{
        .target_node = a,
        .target_anchor = .left,
        .source = .{ .node = .{ .node_id = group_id, .anchor = .right } },
        .offset = 0,
    }, .horizontal));

    try testing.expectEqual(graph.ConstraintClass.wrong_axis, page_graph.constraintClass(try state_layout.work(), .{
        .target_node = a,
        .target_anchor = .top,
        .source = .{ .page = .top },
        .offset = 0,
    }, .horizontal));

    try testing.expectEqual(graph.ConstraintClass.external_source, page_graph.constraintClass(try state_layout.work(), .{
        .target_node = 9999,
        .target_anchor = .left,
        .source = .{ .page = .left },
        .offset = 0,
    }, .horizontal));
}

test "layout graph spec: axis workspaces seed known frames only without target constraints" {
    var state = try initEmptyDocumentState();
    defer state.deinit();
    var state_layout = LayoutFixture.init(&state);
    defer state_layout.deinit();

    const page = try state.addPage("Page");
    const unconstrained = try state.makeObject(page, "free", null, .text, .text, "Free");
    const constrained = try state.makeObject(page, "fixed", null, .text, .text, "Fixed");

    (try state_layout.frame(unconstrained)).* = .{ .x = 10, .y = 20, .width = 30, .height = 40, .x_set = true, .y_set = true };
    (try state_layout.frame(constrained)).* = .{ .x = 100, .y = 200, .width = 50, .height = 60, .x_set = true, .y_set = true };
    try state.constraints.addAnchor(state.allocator, constrained, .left, .{ .page = .left }, 15, .{ .label = "fixed-left" });

    var page_graph = try initPageGraph(&state, page);
    defer page_graph.deinit();
    var workspace = try graph.AxisWorkspace.init(testing.allocator, try state_layout.work(), &page_graph, .horizontal);
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

test "axis propagation completes long dependency chains in either constraint order" {
    const count = 1100;
    for ([_]bool{ false, true }) |reversed| {
        var state = try initEmptyDocumentState();
        defer state.deinit();
        var state_layout = LayoutFixture.init(&state);
        defer state_layout.deinit();
        const page = try state.addPage("Long chain");
        var nodes: [count]model.NodeId = undefined;
        for (&nodes) |*node| node.* = try state.makeObject(page, "cell", null, .text, .text, "x");
        for (1..count) |position| {
            const index = if (reversed) count - position else position;
            try state.constraints.addAnchor(state.allocator, nodes[index], .left, .{ .node = .{ .node_id = nodes[index - 1], .anchor = .right } }, 1, .{ .label = "chain" });
        }
        try state.constraints.addAnchor(state.allocator, nodes[0], .left, .{ .page = .left }, 0, .{ .label = "start" });
        var page_graph = try initPageGraph(&state, page);
        defer page_graph.deinit();
        var workspace = try graph.AxisWorkspace.init(testing.allocator, try state_layout.work(), &page_graph, .horizontal);
        defer workspace.deinit();
        for (workspace.states) |*axis_state| axis_state.size = 10;
        _ = try solver.runPageAxisPass(try state_layout.work(), &workspace, .{});
        for (nodes, 0..) |node, index| {
            const placed = workspace.stateOfConst(node).?;
            try testing.expect(placed.start != null and placed.end != null);
            try expectFloat(@as(f32, @floatFromInt(index * 11)), placed.start.?);
            try expectFloat(@as(f32, @floatFromInt(index * 11 + 10)), placed.end.?);
        }
        try testing.expectEqual(@as(usize, 0), (try state_layout.work()).diagnostics.constraint_failures.items.len);
        var cancellation = LayoutCancellationCounter{ .cancel_after = 20 };
        try testing.expectError(error.Canceled, solver.runPageAxisPass(try state_layout.work(), &workspace, .{
            .cancellation = .{ .context = &cancellation, .is_canceled = cancelLayoutAfterCheck },
        }));
    }
}

test "axis propagation resolves deep groups in either node order" {
    var state = try initEmptyDocumentState();
    defer state.deinit();
    var state_layout = LayoutFixture.init(&state);
    defer state_layout.deinit();
    const page = try state.addPage("Deep groups");
    const leaf = try state.makeObject(page, "leaf", null, .text, .text, "x");
    var outer = leaf;
    for (0..128) |_| outer = try state.makeGroupWithOrigin(page, true, &.{outer}, .{ .label = "group" });
    try state.constraints.addAnchor(state.allocator, outer, .left, .{ .page = .left }, 100, .{ .label = "outer-left" });
    var inputs = try core.layout.partition.Document.init(testing.allocator, &state);
    defer inputs.deinit(testing.allocator);
    for (0..2) |_| {
        var page_graph = try graph.PageLayoutGraph.init(testing.allocator, try state_layout.work(), inputs.pages[0]);
        defer page_graph.deinit();
        var workspace = try graph.AxisWorkspace.init(testing.allocator, try state_layout.work(), &page_graph, .horizontal);
        defer workspace.deinit();
        workspace.stateOf(leaf).?.* = .{ .start = 10, .size = 20 };
        _ = try solver.runPageAxisPass(try state_layout.work(), &workspace, .{});
        for (workspace.states) |placed| {
            try testing.expect(placed.start != null and placed.end != null);
            try expectFloat(100, placed.start.?);
            try expectFloat(120, placed.end.?);
        }
        try testing.expect(!(try solver.runPageAxisPass(try state_layout.work(), &workspace, .{})));
        std.mem.reverse(model.NodeId, inputs.pages[0].node_ids);
    }
    try testing.expectEqual(@as(usize, 0), (try state_layout.work()).diagnostics.constraint_failures.items.len);
}

test "layout exhaustion survives isolated jobs and cannot be applied" {
    for ([_]usize{ 1, 2 }) |jobs| {
        for ([_]bool{ false, true }) |record_diagnostics| {
            var state = try initEmptyDocumentState();
            defer state.deinit();
            var state_layout = LayoutFixture.init(&state);
            defer state_layout.deinit();
            for (0..2) |_| {
                const page = try state.addPage("Unconverged group");
                const child = try state.makeObject(page, "child", null, .text, .text, "x");
                const group = try state.makeGroupWithOrigin(page, true, &.{child}, .{ .label = "group" });
                try state.constraints.addAnchor(state.allocator, child, .left, .{ .page = .left }, 0, .{ .label = "child-left" });
                try state.constraints.addAnchor(state.allocator, child, .right, .{ .node = .{ .node_id = child, .anchor = .left } }, 10, .{ .label = "child-width" });
                try state.constraints.addAnchor(state.allocator, group, .left, .{ .node = .{ .node_id = child, .anchor = .right } }, 10, .{ .label = "group-after-child" });
            }
            const options = graph.SolveOptions{ .jobs = jobs, .record_diagnostics = record_diagnostics };
            var result = try solver.solveDocument(&state, null, options);
            defer result.deinit(testing.allocator);
            for (result.pages) |*page| {
                try testing.expect(!page.converged);
                try testing.expectError(error.LayoutDidNotConverge, page.validate());
                try testing.expectEqual(@as(usize, 0), page.constraint_failures.len);
                try testing.expectEqual(@as(usize, if (record_diagnostics) 1 else 0), page.diagnostics.len);
                if (record_diagnostics) {
                    const diagnostic = page.diagnostics[0];
                    try testing.expectEqual(page.page_id, diagnostic.page_id.?);
                    try testing.expectEqual(model.DiagnosticSeverity.@"error", diagnostic.severity);
                    try testing.expectEqual(model.LayoutConvergenceStage.group_constraints, diagnostic.data.layout_nonconvergence.stage);
                    try testing.expectEqual(diagnostic.data.layout_nonconvergence.limit, diagnostic.data.layout_nonconvergence.iterations);
                    try testing.expectEqualStrings("group-after-child", diagnostic.origin.?.label.?);
                    try testing.expect(diagnostic.data.layout_nonconvergence.constraint != null);
                    const message = try utils.err.formatContextDiagnostic(testing.allocator, diagnostic);
                    defer testing.allocator.free(message);
                    try testing.expect(std.mem.indexOf(u8, message, "LayoutDidNotConverge: horizontal axis stopped during group_constraints") != null);
                }
            }
            try testing.expectError(error.LayoutDidNotConverge, result.validate());
            var detailed = try solver.finalizeDocument(&state, null, options);
            defer detailed.deinit(testing.allocator);
            try testing.expectError(error.LayoutDidNotConverge, detailed.validate());
            try testing.expectEqual(@as(usize, 0), state.diagnostics.entries.items.len);
        }
    }
}

test "layout solver: final validation rejects unsatisfied hard constraints" {
    var self_conflict = try initEmptyDocumentState();
    defer self_conflict.deinit();
    var self_conflict_layout = LayoutFixture.init(&self_conflict);
    defer self_conflict_layout.deinit();

    const self_page = try self_conflict.addPage("Page");
    const object = try self_conflict.makeObject(self_page, "body", null, .text, .text, "A");
    try self_conflict.constraints.addAnchor(self_conflict.allocator, object, .top, .{ .node = .{ .node_id = object, .anchor = .top } }, 100, .{ .label = "self-top" });
    try testing.expectError(error.ConstraintConflict, finalizeDocumentState(&self_conflict_layout));

    var cycle = try initEmptyDocumentState();
    defer cycle.deinit();
    var cycle_layout = LayoutFixture.init(&cycle);
    defer cycle_layout.deinit();

    const cycle_page = try cycle.addPage("Page");
    const a = try cycle.makeObject(cycle_page, "a", null, .text, .text, "A");
    const b = try cycle.makeObject(cycle_page, "b", null, .text, .text, "B");
    try cycle.constraints.addAnchor(cycle.allocator, a, .top, .{ .node = .{ .node_id = b, .anchor = .top } }, 10, .{ .label = "a-top" });
    try cycle.constraints.addAnchor(cycle.allocator, b, .top, .{ .node = .{ .node_id = a, .anchor = .top } }, 10, .{ .label = "b-top" });
    try testing.expectError(error.ConstraintConflict, finalizeDocumentState(&cycle_layout));
}

test "layout solver: consistent constraint cycles are fixed by fallback placement" {
    var state = try initEmptyDocumentState();
    defer state.deinit();
    var state_layout = LayoutFixture.init(&state);
    defer state_layout.deinit();

    const page = try state.addPage("Page");
    const a = try state.makeObject(page, "a", null, .text, .text, "A");
    const b = try state.makeObject(page, "b", null, .text, .text, "B");
    try state.constraints.addAnchor(state.allocator, a, .top, .{ .node = .{ .node_id = b, .anchor = .top } }, 0, .{ .label = "a-top" });
    try state.constraints.addAnchor(state.allocator, b, .top, .{ .node = .{ .node_id = a, .anchor = .top } }, 0, .{ .label = "b-top" });

    try finalizeDocumentState(&state_layout);

    try testing.expect((try state_layout.frame(a)).*.y_set);
    try testing.expect((try state_layout.frame(b)).*.y_set);
    try expectFloat(graph.anchorValue((try state_layout.frame(a)).*, .top), graph.anchorValue((try state_layout.frame(b)).*, .top));
    try testing.expect(!(state_layout.result.failureCount() != 0));
}

test "layout solver: tautological self-anchor constraints do not block fallback placement" {
    var state = try initEmptyDocumentState();
    defer state.deinit();
    var state_layout = LayoutFixture.init(&state);
    defer state_layout.deinit();

    const page = try state.addPage("Page");
    const object = try state.makeObject(page, "body", null, .text, .text, "A");
    try state.constraints.addAnchor(state.allocator, object, .top, .{ .node = .{ .node_id = object, .anchor = .top } }, 0, .{ .label = "self-top" });

    try finalizeDocumentState(&state_layout);

    try testing.expect((try state_layout.frame(object)).*.x_set);
    try testing.expect((try state_layout.frame(object)).*.y_set);
    try testing.expect(!(state_layout.result.failureCount() != 0));
}

test "layout solver: vertical fallback tries alternate roots in incomplete components" {
    var state = try initEmptyDocumentState();
    defer state.deinit();
    var state_layout = LayoutFixture.init(&state);
    defer state_layout.deinit();

    const page = try state.addPage("Page");
    const panel = try state.makeObject(page, "panel", null, .text, .text, "");
    const body = try state.makeObject(page, "body", null, .text, .text, "content");
    try state.constraints.addAnchor(state.allocator, panel, .left, .{ .page = .left }, 52, .{ .label = "panel-left" });
    try state.constraints.addAnchor(state.allocator, panel, .right, .{ .page = .right }, -52, .{ .label = "panel-right" });
    try state.constraints.addAnchor(state.allocator, body, .left, .{ .page = .left }, 72, .{ .label = "body-left" });
    try state.constraints.addAnchor(state.allocator, body, .right, .{ .page = .right }, -72, .{ .label = "body-right" });
    try state.constraints.addAnchor(state.allocator, panel, .top, .{ .node = .{ .node_id = body, .anchor = .top } }, 16, .{ .label = "panel-top" });
    try state.constraints.addAnchor(state.allocator, panel, .bottom, .{ .node = .{ .node_id = body, .anchor = .bottom } }, -16, .{ .label = "panel-bottom" });

    try finalizeDocumentState(&state_layout);

    try testing.expect((try state_layout.frame(panel)).*.y_set);
    try testing.expect((try state_layout.frame(body)).*.y_set);
    try expectFloat(graph.anchorValue((try state_layout.frame(body)).*, .top) + 16, graph.anchorValue((try state_layout.frame(panel)).*, .top));
    try expectFloat(graph.anchorValue((try state_layout.frame(body)).*, .bottom) - 16, graph.anchorValue((try state_layout.frame(panel)).*, .bottom));
    try testing.expect(!(state_layout.result.failureCount() != 0));
}

test "layout solver: constraint-referenced objects participate in fallback placement" {
    var state = try initEmptyDocumentState();
    defer state.deinit();
    var state_layout = LayoutFixture.init(&state);
    defer state_layout.deinit();

    const page = try state.addPage("Page");
    const placed = try state.makeObject(page, "placed", null, .text, .text, "placed");
    const referenced = try state.makeObject(page, "referenced", null, .text, .text, "referenced");
    try state.constraints.addAnchor(state.allocator, placed, .top, .{ .node = .{ .node_id = referenced, .anchor = .top } }, 10, .{ .label = "placed-top" });

    try finalizeDocumentState(&state_layout);

    try testing.expect((try state_layout.frame(placed)).*.y_set);
    try testing.expect((try state_layout.frame(referenced)).*.y_set);
    try expectFloat(graph.anchorValue((try state_layout.frame(referenced)).*, .top) + 10, graph.anchorValue((try state_layout.frame(placed)).*, .top));
    try testing.expect(!(state_layout.result.failureCount() != 0));
}

test "layout solver: size-only constraints still receive fallback placement" {
    var state = try initEmptyDocumentState();
    defer state.deinit();
    var state_layout = LayoutFixture.init(&state);
    defer state_layout.deinit();

    const page = try state.addPage("Page");
    const object = try state.makeObject(page, "body", null, .text, .text, "content");
    try state.constraints.addAnchor(state.allocator, object, .right, .{ .node = .{ .node_id = object, .anchor = .left } }, 240, .{ .label = "object-width" });
    try state.constraints.addAnchor(state.allocator, object, .top, .{ .node = .{ .node_id = object, .anchor = .bottom } }, 96, .{ .label = "object-height" });

    try finalizeDocumentState(&state_layout);

    try testing.expect((try state_layout.frame(object)).*.x_set);
    try testing.expect((try state_layout.frame(object)).*.y_set);
    try expectFloat(240, (try state_layout.frame(object)).*.width);
    try expectFloat(96, (try state_layout.frame(object)).*.height);
    try testing.expect(!(state_layout.result.failureCount() != 0));
}

test "layout solver: page-dependent group children receive local vertical fallback" {
    var state = try initEmptyDocumentState();
    defer state.deinit();
    var state_layout = LayoutFixture.init(&state);
    defer state_layout.deinit();

    const page = try state.addPage("Page");
    const ruler = try state.makeObject(page, "rule", null, .text, .text, "");
    const title = try state.makeObject(page, "title", null, .text, .text, "Title");
    const body = try state.makeObject(page, "body", null, .text, .text, "Body");
    _ = try state.makeGroupWithOrigin(page, true, &.{ ruler, title }, .{ .label = "head" });
    try setLayoutLineHeight(&state, ruler, "4");
    try setLayoutSpacingAfter(&state, ruler, "12");
    try state.constraints.addAnchor(state.allocator, ruler, .top, .{ .page = .top }, -200, .{ .label = "rule-top" });

    try finalizeDocumentState(&state_layout);

    try testing.expect((try state_layout.frame(ruler)).*.y_set);
    try testing.expect((try state_layout.frame(title)).*.y_set);
    try testing.expect((try state_layout.frame(body)).*.y_set);
    try expectFloat(graph.anchorValue((try state_layout.frame(ruler)).*, .bottom) - 12, graph.anchorValue((try state_layout.frame(title)).*, .top));
    try expectFloat(core.layout.Defaults.flow_top, graph.anchorValue((try state_layout.frame(body)).*, .top));
    try testing.expect(!(state_layout.result.failureCount() != 0));
}

test "layout solver: fallback does not conflict with a nested group target" {
    for ([_]bool{ false, true }) |place_outer| {
        var state = try initEmptyDocumentState();
        defer state.deinit();
        var state_layout = LayoutFixture.init(&state);
        defer state_layout.deinit();
        const page = try state.addPage("Nested group");
        const a = try state.createObjectWithOrigin("a", null, .text, .text, "A", null);
        const b = try state.createObjectWithOrigin("b", null, .text, .text, "B", null);
        const c = try state.createObjectWithOrigin("c", null, .text, .text, "C", null);
        const inner = try state.createGroupWithOrigin(&.{ b, c }, null);
        const outer = try state.createGroupWithOrigin(&.{ a, inner }, null);
        if (place_outer) {
            try state.placeObjectOnPage(page, outer);
        } else {
            for ([_]model.NodeId{ a, b, c }) |node_id| try state.placeObjectOnPage(page, node_id);
        }
        for ([_]model.NodeId{ a, b, c }, [_]f32{ 120, 180, 90 }, [_]f32{ 80, 60, 50 }) |node_id, width, height| {
            try state.constraints.addAnchor(state.allocator, node_id, .right, .{ .node = .{ .node_id = node_id, .anchor = .left } }, width, null);
            try state.constraints.addAnchor(state.allocator, node_id, .top, .{ .node = .{ .node_id = node_id, .anchor = .bottom } }, height, null);
        }
        try state.constraints.addAnchor(state.allocator, a, .left, .{ .page = .left }, 80, null);
        try state.constraints.addAnchor(state.allocator, a, .top, .{ .page = .top }, -80, null);
        try state.constraints.addAnchor(state.allocator, c, .left, .{ .node = .{ .node_id = b, .anchor = .left } }, 0, null);
        try state.constraints.addAnchor(state.allocator, c, .top, .{ .node = .{ .node_id = b, .anchor = .bottom } }, -32, null);
        try state.constraints.addAnchor(state.allocator, inner, .left, .{ .node = .{ .node_id = a, .anchor = .right } }, 32, null);
        try state.constraints.addAnchor(state.allocator, inner, .top, .{ .node = .{ .node_id = a, .anchor = .top } }, 0, null);

        try solveDocumentState(&state_layout);

        try testing.expect(!(state_layout.result.failureCount() != 0));
        const a_frame = (try state_layout.frame(a)).*;
        const b_frame = (try state_layout.frame(b)).*;
        const c_frame = (try state_layout.frame(c)).*;
        try expectFloat(80, a_frame.x);
        try expectFloat(core.layout.Defaults.height - 80, graph.anchorValue(a_frame, .top));
        try expectFloat(a_frame.x + a_frame.width + 32, b_frame.x);
        try expectFloat(graph.anchorValue(a_frame, .top), graph.anchorValue(b_frame, .top));
        try expectFloat(b_frame.x, c_frame.x);
        try expectFloat(b_frame.y - 32, graph.anchorValue(c_frame, .top));
        try expectFloat(142, (try state_layout.frame(inner)).*.height);
    }
}

test "layout graph: affine cuts wait for and use the source axis extent" {
    var state = try initEmptyDocumentState();
    defer state.deinit();
    var state_layout = LayoutFixture.init(&state);
    defer state_layout.deinit();
    const page = try state.addPage("Affine cuts");
    const child = try state.makeObject(page, "body", null, .text, .text, "A");
    const group = try state.makeGroupWithOrigin(page, true, &.{child}, null);
    var page_graph = try initPageGraph(&state, page);
    defer page_graph.deinit();
    var workspace = try graph.AxisWorkspace.init(testing.allocator, try state_layout.work(), &page_graph, .horizontal);
    defer workspace.deinit();
    const cut = model.Constraint{
        .target_node = child,
        .target_anchor = .right,
        .source = .{ .node = .{ .node_id = group, .anchor = .left } },
        .source_extent_factor = 1.0 / 3.0,
        .offset = -20,
        .group_split = true,
    };
    workspace.stateOf(group).?.* = .{ .start = 100 };
    try testing.expect((try graph.constraintAffineSourceValue(try state_layout.work(), &workspace, cut)) == null);
    workspace.stateOf(group).?.size = 900;
    try expectFloat(400, (try graph.constraintAffineSourceValue(try state_layout.work(), &workspace, cut)).?);
    workspace.stateOf(group).?.size = 1200;
    try expectFloat(500, (try graph.constraintAffineSourceValue(try state_layout.work(), &workspace, cut)).?);
}

test "layout groups: soft positions preserve hard anchors and tight sizes" {
    for ([_]model.Anchor{ .top, .bottom, .center_y }) |hard_anchor| {
        var state = try initEmptyDocumentState();
        defer state.deinit();
        var state_layout = LayoutFixture.init(&state);
        defer state_layout.deinit();
        const page = try state.addPage("Group fallback");
        const child = try state.makeObject(page, "body", null, .text, .text, "A");
        const group = try state.makeGroupWithOrigin(page, true, &.{child}, null);
        try state.constraints.addAnchor(state.allocator, group, hard_anchor, .{ .page = .bottom }, 400, null);
        var page_graph = try initPageGraph(&state, page);
        defer page_graph.deinit();
        var workspace = try graph.AxisWorkspace.init(testing.allocator, try state_layout.work(), &page_graph, .vertical);
        defer workspace.deinit();
        workspace.stateOf(child).?.* = .{ .start = 0, .end = 80, .center = 40, .size = 80 };
        workspace.soft_constraints = &.{.{
            .target_node = group,
            .target_anchor = .top,
            .source = .{ .page = .bottom },
            .offset = 300,
        }};

        _ = try core.layout.groups.applyTargetConstraints(try state_layout.work(), &workspace, .{});

        try testing.expect(!(state_layout.result.failureCount() != 0));
        const group_state = workspace.stateOfConst(group).?.*;
        try expectFloat(400, graph.axisAnchorValue(group_state, hard_anchor).?);
        try expectFloat(80, group_state.size.?);
        try expectFloat(group_state.start.?, workspace.stateOfConst(child).?.start.?);
        try expectFloat(group_state.end.?, workspace.stateOfConst(child).?.end.?);
    }
}

test "layout solver: a page-positioned object does not affect page flow" {
    var baseline = try initEmptyDocumentState();
    defer baseline.deinit();
    var baseline_layout = LayoutFixture.init(&baseline);
    defer baseline_layout.deinit();

    const baseline_page = try baseline.addPage("Page");
    const baseline_title = try baseline.createObjectWithOrigin("title", null, .text, .text, "Title", null);
    const baseline_rule = try baseline.createObjectWithOrigin("rule", null, .text, .text, "", null);
    const baseline_head = try baseline.createGroupWithOrigin(&.{ baseline_title, baseline_rule }, .{ .label = "head" });
    const baseline_body = try baseline.createObjectWithOrigin("body", null, .text, .text, "Body", null);
    try baseline.placeObjectOnPage(baseline_page, baseline_head);
    try baseline.placeObjectOnPage(baseline_page, baseline_body);
    try setLayoutLineHeight(&baseline, baseline_title, "44");
    try setLayoutLineHeight(&baseline, baseline_rule, "2");
    try setLayoutSpacingAfter(&baseline, baseline_rule, "48");
    try setLayoutLineHeight(&baseline, baseline_body, "70");
    try baseline.constraints.addAnchor(baseline.allocator, baseline_title, .top, .{ .page = .top }, -56, .{ .label = "title-top" });
    try baseline.constraints.addAnchor(baseline.allocator, baseline_rule, .top, .{ .node = .{ .node_id = baseline_title, .anchor = .bottom } }, -14, .{ .label = "rule-below-title" });
    try solveDocumentState(&baseline_layout);

    var decorated = try initEmptyDocumentState();
    defer decorated.deinit();
    var decorated_layout = LayoutFixture.init(&decorated);
    defer decorated_layout.deinit();

    const decorated_page = try decorated.addPage("Page");
    const page_number = try decorated.createObjectWithOrigin("pageno", null, .text, .text, "1", null);
    try decorated.placeObjectOnPage(decorated_page, page_number);
    try setLayoutLineHeight(&decorated, page_number, "16");
    try setLayoutSpacingAfter(&decorated, page_number, "0");
    try decorated.constraints.addAnchor(decorated.allocator, page_number, .bottom, .{ .page = .bottom }, 20, .{ .label = "pageno-bottom" });

    const decorated_title = try decorated.createObjectWithOrigin("title", null, .text, .text, "Title", null);
    const decorated_rule = try decorated.createObjectWithOrigin("rule", null, .text, .text, "", null);
    const decorated_head = try decorated.createGroupWithOrigin(&.{ decorated_title, decorated_rule }, .{ .label = "head" });
    const decorated_body = try decorated.createObjectWithOrigin("body", null, .text, .text, "Body", null);
    try decorated.placeObjectOnPage(decorated_page, decorated_head);
    try decorated.placeObjectOnPage(decorated_page, decorated_body);
    try setLayoutLineHeight(&decorated, decorated_title, "44");
    try setLayoutLineHeight(&decorated, decorated_rule, "2");
    try setLayoutSpacingAfter(&decorated, decorated_rule, "48");
    try setLayoutLineHeight(&decorated, decorated_body, "70");
    try decorated.constraints.addAnchor(decorated.allocator, decorated_title, .top, .{ .page = .top }, -56, .{ .label = "title-top" });
    try decorated.constraints.addAnchor(decorated.allocator, decorated_rule, .top, .{ .node = .{ .node_id = decorated_title, .anchor = .bottom } }, -14, .{ .label = "rule-below-title" });
    try solveDocumentState(&decorated_layout);

    try testing.expectEqualSlices(model.NodeId, &.{ page_number, decorated_head, decorated_body }, decorated.placementRootsOf(decorated_page));
    try expectFrame((try baseline_layout.frame(baseline_title)).*, (try decorated_layout.frame(decorated_title)).*);
    try expectFrame((try baseline_layout.frame(baseline_rule)).*, (try decorated_layout.frame(decorated_rule)).*);
    try expectFrame((try baseline_layout.frame(baseline_body)).*, (try decorated_layout.frame(decorated_body)).*);
    try expectFloat(20, graph.anchorValue((try decorated_layout.frame(page_number)).*, .bottom));
    try testing.expect(!(decorated_layout.result.failureCount() != 0));
}

test "layout solver: page-positioned components leave unrelated vertical flow unchanged" {
    for ([_][]const u8{ "top_flow", "center" }) |policy| {
        for ([_]bool{ false, true }) |anchor_group| {
            for ([_]bool{ false, true }) |place_fixed_first| {
                var state = try initEmptyDocumentState();
                defer state.deinit();
                var state_layout = LayoutFixture.init(&state);
                defer state_layout.deinit();
                const page = try state.addPage("Page anchors");
                try setLayoutPolicy(&state, page, policy);

                const heading = try state.createObjectWithOrigin("heading", null, .text, .text, "Heading", null);
                const note = try state.createObjectWithOrigin("note", null, .text, .text, "Note", null);
                const fixed = try state.createGroupWithOrigin(&.{ heading, note }, null);
                const first = try state.createObjectWithOrigin("body", null, .text, .text, "First", null);
                const second = try state.createObjectWithOrigin("body", null, .text, .text, "Second", null);
                if (place_fixed_first) try state.placeObjectOnPage(page, fixed);
                try state.placeObjectOnPage(page, first);
                try state.placeObjectOnPage(page, second);
                if (!place_fixed_first) try state.placeObjectOnPage(page, fixed);

                try setLayoutLineHeight(&state, heading, "40");
                try setLayoutLineHeight(&state, note, "30");
                try setLayoutSpacingAfter(&state, note, "120");
                try setLayoutLineHeight(&state, first, "80");
                try setLayoutSpacingAfter(&state, first, "24");
                try setLayoutLineHeight(&state, second, "60");
                try setLayoutSpacingAfter(&state, second, "0");
                try state.constraints.addAnchor(state.allocator, if (anchor_group) fixed else heading, .top, .{ .page = .bottom }, 400, null);
                try state.constraints.addAnchor(state.allocator, note, .top, .{ .node = .{ .node_id = heading, .anchor = .bottom } }, -16, null);
                // Horizontal page anchors leave vertical flow available.
                try state.constraints.addAnchor(state.allocator, first, .left, .{ .page = .left }, 180, null);
                try state.constraints.addAnchor(state.allocator, second, .right, .{ .page = .right }, -180, null);

                try solveDocumentState(&state_layout);

                try testing.expect(!(state_layout.result.failureCount() != 0));
                const first_frame = (try state_layout.frame(first)).*;
                const second_frame = (try state_layout.frame(second)).*;
                const expected_top = if (std.mem.eql(u8, policy, "center"))
                    (core.layout.Defaults.height + 80 + 24 + 60) / 2
                else
                    core.layout.Defaults.flow_top;
                try expectFloat(expected_top, graph.anchorValue(first_frame, .top));
                try expectFloat(expected_top - 80 - 24, graph.anchorValue(second_frame, .top));
                try expectFloat(180, graph.anchorValue(first_frame, .left));
                try expectFloat(core.layout.Defaults.width - 180, graph.anchorValue(second_frame, .right));
                try expectFloat(400, graph.anchorValue((try state_layout.frame(heading)).*, .top));
                try expectFloat(344, graph.anchorValue((try state_layout.frame(note)).*, .top));
            }
        }
    }
}

test "layout solver: page-dependent group children before fixed anchors receive fallback" {
    var state = try initEmptyDocumentState();
    defer state.deinit();
    var state_layout = LayoutFixture.init(&state);
    defer state_layout.deinit();

    const page = try state.addPage("Page");
    const title = try state.makeObject(page, "title", null, .text, .text, "Title");
    const ruler = try state.makeObject(page, "rule", null, .text, .text, "");
    _ = try state.makeGroupWithOrigin(page, true, &.{ title, ruler }, .{ .label = "head" });
    try setLayoutSpacingAfter(&state, title, "12");
    try setLayoutLineHeight(&state, ruler, "4");
    try state.constraints.addAnchor(state.allocator, ruler, .top, .{ .page = .top }, -200, .{ .label = "rule-top" });

    try finalizeDocumentState(&state_layout);

    try testing.expect((try state_layout.frame(title)).*.y_set);
    try testing.expect((try state_layout.frame(ruler)).*.y_set);
    try expectFloat(graph.anchorValue((try state_layout.frame(ruler)).*, .top) + 12, graph.anchorValue((try state_layout.frame(title)).*, .bottom));
    try testing.expect(!(state_layout.result.failureCount() != 0));
}

test "layout solver: page-dependent vertical cycles receive fallback placement" {
    var state = try initEmptyDocumentState();
    defer state.deinit();
    var state_layout = LayoutFixture.init(&state);
    defer state_layout.deinit();

    const page = try state.addPage("Page");
    const ruler = try state.makeObject(page, "rule", null, .text, .text, "");
    const first = try state.makeObject(page, "first", null, .text, .text, "A");
    const second = try state.makeObject(page, "second", null, .text, .text, "B");
    _ = try state.makeGroupWithOrigin(page, true, &.{ ruler, first, second }, .{ .label = "head" });
    try setLayoutLineHeight(&state, ruler, "4");
    try setLayoutSpacingAfter(&state, ruler, "12");
    try state.constraints.addAnchor(state.allocator, ruler, .top, .{ .page = .top }, -200, .{ .label = "rule-top" });
    try state.constraints.addAnchor(state.allocator, first, .top, .{ .node = .{ .node_id = second, .anchor = .top } }, 0, .{ .label = "first-cycle" });
    try state.constraints.addAnchor(state.allocator, second, .top, .{ .node = .{ .node_id = first, .anchor = .top } }, 0, .{ .label = "second-cycle" });

    try finalizeDocumentState(&state_layout);

    try testing.expect((try state_layout.frame(first)).*.y_set);
    try testing.expect((try state_layout.frame(second)).*.y_set);
    try expectFloat(graph.anchorValue((try state_layout.frame(ruler)).*, .bottom) - 12, graph.anchorValue((try state_layout.frame(first)).*, .top));
    try expectFloat(graph.anchorValue((try state_layout.frame(first)).*, .top), graph.anchorValue((try state_layout.frame(second)).*, .top));
    try testing.expect(!(state_layout.result.failureCount() != 0));
}

test "layout solver: page-dependent horizontal cycles receive fallback placement" {
    var state = try initEmptyDocumentState();
    defer state.deinit();
    var state_layout = LayoutFixture.init(&state);
    defer state_layout.deinit();

    const page = try state.addPage("Page");
    const ruler = try state.makeObject(page, "rule", null, .text, .text, "");
    const first = try state.makeObject(page, "first", null, .text, .text, "A");
    const second = try state.makeObject(page, "second", null, .text, .text, "B");
    _ = try state.makeGroupWithOrigin(page, true, &.{ ruler, first, second }, .{ .label = "head" });
    try setLayoutLineHeight(&state, ruler, "4");
    try state.constraints.addAnchor(state.allocator, ruler, .left, .{ .page = .left }, 100, .{ .label = "rule-left" });
    try state.constraints.addAnchor(state.allocator, first, .left, .{ .node = .{ .node_id = second, .anchor = .left } }, 0, .{ .label = "first-cycle" });
    try state.constraints.addAnchor(state.allocator, second, .left, .{ .node = .{ .node_id = first, .anchor = .left } }, 0, .{ .label = "second-cycle" });

    try finalizeDocumentState(&state_layout);

    try testing.expect((try state_layout.frame(first)).*.x_set);
    try testing.expect((try state_layout.frame(second)).*.x_set);
    try expectFloat((try state_layout.frame(first)).*.x, (try state_layout.frame(second)).*.x);
    try testing.expect(!(state_layout.result.failureCount() != 0));
}

test "layout solver: centered page-dependent group children receive local vertical fallback" {
    var state = try initEmptyDocumentState();
    defer state.deinit();
    var state_layout = LayoutFixture.init(&state);
    defer state_layout.deinit();

    try setLayoutPolicy(&state, state.graph.document_id, "center");

    const page = try state.addPage("Page");
    const ruler = try state.makeObject(page, "rule", null, .text, .text, "");
    const title = try state.makeObject(page, "title", null, .text, .text, "Title");
    const body = try state.makeObject(page, "body", null, .text, .text, "Body");
    _ = try state.makeGroupWithOrigin(page, true, &.{ ruler, title }, .{ .label = "head" });
    try setLayoutLineHeight(&state, ruler, "4");
    try setLayoutSpacingAfter(&state, ruler, "12");
    try setLayoutLineHeight(&state, body, "500");
    try state.constraints.addAnchor(state.allocator, ruler, .top, .{ .page = .top }, -200, .{ .label = "rule-top" });

    try finalizeDocumentState(&state_layout);

    try testing.expect((try state_layout.frame(ruler)).*.y_set);
    try testing.expect((try state_layout.frame(title)).*.y_set);
    try testing.expect((try state_layout.frame(body)).*.y_set);
    try expectFloat(graph.anchorValue((try state_layout.frame(ruler)).*, .bottom) - 12, graph.anchorValue((try state_layout.frame(title)).*, .top));
    try expectFloat(core.layout.Defaults.height / 2, graph.anchorValue((try state_layout.frame(body)).*, .center_y));
    try testing.expect(!(state_layout.result.failureCount() != 0));
}

test "layout solver: horizontal alignment alone does not imply vertical row alignment" {
    var stacked = try initEmptyDocumentState();
    defer stacked.deinit();
    var stacked_layout = LayoutFixture.init(&stacked);
    defer stacked_layout.deinit();

    const stacked_page = try stacked.addPage("Page");
    const first = try stacked.makeObject(stacked_page, "first", null, .text, .text, "A");
    const second = try stacked.makeObject(stacked_page, "second", null, .text, .text, "B");
    _ = try stacked.makeGroupWithOrigin(stacked_page, true, &.{ first, second }, .{ .label = "group" });
    try stacked.constraints.addAnchor(stacked.allocator, second, .left, .{ .node = .{ .node_id = first, .anchor = .left } }, 0, .{ .label = "same-left" });

    try solveDocumentState(&stacked_layout);

    const first_node = stacked.getNode(first).?;
    const first_spacing = core.layout.styleForNode(&stacked, first_node).spacing_after;
    try expectFloat((try stacked_layout.frame(first)).*.y - first_spacing, (try stacked_layout.frame(second)).*.y + (try stacked_layout.frame(second)).*.height);

    var row = try initEmptyDocumentState();
    defer row.deinit();
    var row_layout = LayoutFixture.init(&row);
    defer row_layout.deinit();

    const row_page = try row.addPage("Page");
    const left = try row.makeObject(row_page, "left", null, .text, .text, "A");
    const right = try row.makeObject(row_page, "right", null, .text, .text, "B");
    try row.constraints.addAnchor(row.allocator, right, .left, .{ .node = .{ .node_id = left, .anchor = .right } }, 30, .{ .label = "right-of-left" });
    try row.constraints.addAnchor(row.allocator, right, .center_y, .{ .node = .{ .node_id = left, .anchor = .center_y } }, 0, .{ .label = "same-center-y" });

    try solveDocumentState(&row_layout);

    try expectFloat((try row_layout.frame(left)).*.y + (try row_layout.frame(left)).*.height / 2, (try row_layout.frame(right)).*.y + (try row_layout.frame(right)).*.height / 2);
}

fn addDefaultAlignment(state: *core.DocumentState, target: model.NodeId, source: model.NodeId) !void {
    try state.constraints.addAnchor(state.allocator, target, .top, .{ .node = .{ .node_id = source, .anchor = .top } }, 0, null);
    state.constraints.active.items[state.constraints.active.items.len - 1].default_alignment = true;
}

fn addFixedSize(state: *core.DocumentState, node_id: model.NodeId, width: f32, height: f32) !void {
    try state.constraints.addAnchor(state.allocator, node_id, .right, .{ .node = .{ .node_id = node_id, .anchor = .left } }, width, null);
    try state.constraints.addAnchor(state.allocator, node_id, .top, .{ .node = .{ .node_id = node_id, .anchor = .bottom } }, height, null);
}

test "layout solver: row defaults follow effective page policy independently of declaration order" {
    const cases = [_]struct { document: []const u8, page: ?[]const u8, anchor: model.Anchor }{
        .{ .document = "top", .page = null, .anchor = .top },
        .{ .document = "top_flow", .page = null, .anchor = .top },
        .{ .document = "center", .page = null, .anchor = .center_y },
        .{ .document = "center_stack", .page = null, .anchor = .center_y },
        .{ .document = "center", .page = "top", .anchor = .top },
        .{ .document = "top", .page = "center", .anchor = .center_y },
    };
    for (cases) |case| {
        for ([_]bool{ false, true }) |reverse| {
            var state = try initEmptyDocumentState();
            defer state.deinit();
            var state_layout = LayoutFixture.init(&state);
            defer state_layout.deinit();
            const page = try state.addPage("Row policy");
            try setLayoutPolicy(&state, state.graph.document_id, case.document);
            if (case.page) |policy| try setLayoutPolicy(&state, page, policy);
            const first = try state.makeObject(page, "first", null, .text, .text, "A");
            const second = try state.makeObject(page, "second", null, .text, .text, "B");
            const a = if (reverse) second else first;
            const b = if (reverse) first else second;
            try addFixedSize(&state, a, 120, 80);
            try addFixedSize(&state, b, 180, 160);
            try state.constraints.addAnchor(state.allocator, b, .left, .{ .node = .{ .node_id = a, .anchor = .right } }, 32, null);
            try addDefaultAlignment(&state, b, a);

            try solveDocumentState(&state_layout);

            try testing.expect(!(state_layout.result.failureCount() != 0));
            const a_frame = (try state_layout.frame(a)).*;
            const b_frame = (try state_layout.frame(b)).*;
            try testing.expect(a_frame.y_set and b_frame.y_set);
            try expectFloat(80, a_frame.height);
            try expectFloat(160, b_frame.height);
            try expectFloat(graph.anchorValue(a_frame, case.anchor), graph.anchorValue(b_frame, case.anchor));
        }
    }
}

test "layout solver: explicit target anchors override row defaults without reverse alignment" {
    for ([_]model.Anchor{ .top, .bottom, .center_y }) |anchor| {
        var state = try initEmptyDocumentState();
        defer state.deinit();
        var state_layout = LayoutFixture.init(&state);
        defer state_layout.deinit();
        const page = try state.addPage("Explicit target");
        const a = try state.makeObject(page, "a", null, .text, .text, "A");
        const b = try state.makeObject(page, "b", null, .text, .text, "B");
        try addFixedSize(&state, a, 120, 80);
        try addFixedSize(&state, b, 180, 160);
        try state.constraints.addAnchor(state.allocator, b, .left, .{ .node = .{ .node_id = a, .anchor = .right } }, 32, null);
        try addDefaultAlignment(&state, b, a);
        try state.constraints.addAnchor(state.allocator, b, anchor, .{ .page = .bottom }, 300, null);

        try solveDocumentState(&state_layout);

        try testing.expect(!(state_layout.result.failureCount() != 0));
        const a_frame = (try state_layout.frame(a)).*;
        const b_frame = (try state_layout.frame(b)).*;
        try expectFloat(300, graph.anchorValue(b_frame, anchor));
        try expectFloat(core.layout.Defaults.flow_top, graph.anchorValue(a_frame, .top));
    }
}

test "layout solver: row defaults align nested column bounds with fixed or flowing sources" {
    for ([_][]const u8{ "top", "center" }) |policy| {
        for ([_]bool{ false, true }) |place_outer| {
            for ([_]bool{ false, true }) |anchor_source| {
                var state = try initEmptyDocumentState();
                defer state.deinit();
                var state_layout = LayoutFixture.init(&state);
                defer state_layout.deinit();
                const page = try state.addPage("Nested default alignment");
                try setLayoutPolicy(&state, state.graph.document_id, policy);
                const a = try state.createObjectWithOrigin("a", null, .text, .text, "A", null);
                const b = try state.createObjectWithOrigin("b", null, .text, .text, "B", null);
                const c = try state.createObjectWithOrigin("c", null, .text, .text, "C", null);
                const inner = try state.createGroupWithOrigin(&.{ b, c }, null);
                const outer = try state.createGroupWithOrigin(&.{ a, inner }, null);
                if (place_outer) {
                    try state.placeObjectOnPage(page, outer);
                } else {
                    for ([_]model.NodeId{ b, c, a }) |node_id| try state.placeObjectOnPage(page, node_id);
                }
                try addFixedSize(&state, a, 120, 80);
                try addFixedSize(&state, b, 180, 60);
                try addFixedSize(&state, c, 90, 50);
                if (anchor_source) try state.constraints.addAnchor(state.allocator, a, .top, .{ .page = .top }, -80, null);
                try state.constraints.addAnchor(state.allocator, c, .left, .{ .node = .{ .node_id = b, .anchor = .left } }, 0, null);
                try state.constraints.addAnchor(state.allocator, c, .top, .{ .node = .{ .node_id = b, .anchor = .bottom } }, -32, null);
                try state.constraints.addAnchor(state.allocator, inner, .left, .{ .node = .{ .node_id = a, .anchor = .right } }, 32, null);
                try addDefaultAlignment(&state, inner, a);

                try solveDocumentState(&state_layout);

                try testing.expect(!(state_layout.result.failureCount() != 0));
                const a_frame = (try state_layout.frame(a)).*;
                const b_frame = (try state_layout.frame(b)).*;
                const c_frame = (try state_layout.frame(c)).*;
                const inner_frame = (try state_layout.frame(inner)).*;
                const anchor: model.Anchor = if (std.mem.eql(u8, policy, "center")) .center_y else .top;
                try testing.expect(a_frame.y_set and b_frame.y_set and c_frame.y_set);
                try expectFloat(graph.anchorValue(a_frame, anchor), graph.anchorValue(inner_frame, anchor));
                if (!anchor_source and anchor == .center_y) try expectFloat(core.layout.Defaults.height / 2, graph.anchorValue(inner_frame, .center_y));
                try expectFloat(142, inner_frame.height);
                try expectFloat(60, b_frame.height);
                try expectFloat(50, c_frame.height);
                try expectFloat(b_frame.y - 32, graph.anchorValue(c_frame, .top));
            }
        }
    }
}

test "layout solver: row defaults do not translate explicitly positioned group descendants" {
    var state = try initEmptyDocumentState();
    defer state.deinit();
    var state_layout = LayoutFixture.init(&state);
    defer state_layout.deinit();
    const page = try state.addPage("Positioned column");
    const a = try state.makeObject(page, "a", null, .text, .text, "A");
    const b = try state.makeObject(page, "b", null, .text, .text, "B");
    const c = try state.makeObject(page, "c", null, .text, .text, "C");
    const column = try state.createGroupWithOrigin(&.{ b, c }, null);
    try addFixedSize(&state, a, 120, 80);
    try addFixedSize(&state, b, 180, 60);
    try addFixedSize(&state, c, 90, 50);
    try state.constraints.addAnchor(state.allocator, b, .top, .{ .page = .bottom }, 300, null);
    try state.constraints.addAnchor(state.allocator, c, .top, .{ .node = .{ .node_id = b, .anchor = .bottom } }, -32, null);
    try state.constraints.addAnchor(state.allocator, column, .left, .{ .node = .{ .node_id = a, .anchor = .right } }, 32, null);
    try addDefaultAlignment(&state, column, a);

    try solveDocumentState(&state_layout);

    try testing.expect(!(state_layout.result.failureCount() != 0));
    try expectFloat(300, graph.anchorValue((try state_layout.frame(b)).*, .top));
    try expectFloat(158, (try state_layout.frame(c)).*.y);
    try expectFloat(core.layout.Defaults.flow_top, graph.anchorValue((try state_layout.frame(a)).*, .top));
}

test "layout graph: row defaults choose the first eligible target candidate and reject dependency cycles" {
    var state = try initEmptyDocumentState();
    defer state.deinit();
    var state_layout = LayoutFixture.init(&state);
    defer state_layout.deinit();
    const page = try state.addPage("Default selection");
    const a = try state.makeObject(page, "a", null, .text, .text, "A");
    const b = try state.makeObject(page, "b", null, .text, .text, "B");
    const c = try state.makeObject(page, "c", null, .text, .text, "C");
    const d = try state.makeObject(page, "d", null, .text, .text, "D");
    try addDefaultAlignment(&state, b, a);
    try addDefaultAlignment(&state, b, c);
    try addDefaultAlignment(&state, a, b);
    try addDefaultAlignment(&state, c, c);
    try addDefaultAlignment(&state, c, a);
    try state.constraints.addAnchor(state.allocator, d, .top, .{ .node = .{ .node_id = c, .anchor = .bottom } }, -32, null);
    try addDefaultAlignment(&state, c, d);
    var page_graph = try initPageGraph(&state, page);
    defer page_graph.deinit();
    try testing.expectEqual(@as(usize, 1), page_graph.constraints.len);
    try testing.expectEqual(@as(usize, 6), page_graph.default_alignment_constraints.len);
    try testing.expectEqual(@as(usize, 0), page_graph.targetConstraintIndexes(b).len);
    try testing.expect(!page_graph.hasTargetConstraint(try state_layout.work(), b, .vertical, &.{}));
    var workspace = try graph.AxisWorkspace.init(testing.allocator, try state_layout.work(), &page_graph, .vertical);
    defer workspace.deinit();
    var defaults = try core.layout.fallback.buildDefaultAlignmentConstraints(try state_layout.work(), &workspace);
    defer defaults.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), defaults.items.len);
    try testing.expectEqual(b, defaults.items[0].target_node);
    try testing.expectEqual(a, defaults.items[0].source.node.node_id);
    try testing.expectEqual(c, defaults.items[1].target_node);
    try testing.expectEqual(a, defaults.items[1].source.node.node_id);
}

test "layout solver: positioned nested groups preserve internal default alignment" {
    for ([_][]const u8{ "top", "center" }) |policy| {
        var state = try initEmptyDocumentState();
        defer state.deinit();
        var state_layout = LayoutFixture.init(&state);
        defer state_layout.deinit();
        const page = try state.addPage("Nested positioned group");
        try setLayoutPolicy(&state, page, policy);
        const a_leaf = try state.createObjectWithOrigin("a", null, .text, .text, "A", null);
        const b_leaf = try state.createObjectWithOrigin("b", null, .text, .text, "B", null);
        const c_leaf = try state.createObjectWithOrigin("c", null, .text, .text, "C", null);
        try addFixedSize(&state, a_leaf, 120, 80);
        try addFixedSize(&state, b_leaf, 180, 60);
        try addFixedSize(&state, c_leaf, 90, 50);
        const a = try state.createGroupWithOrigin(&.{a_leaf}, null);
        const b = try state.createGroupWithOrigin(&.{b_leaf}, null);
        const c = try state.createGroupWithOrigin(&.{c_leaf}, null);
        const inner = try state.createGroupWithOrigin(&.{ a, b }, null);
        const outer = try state.createGroupWithOrigin(&.{ inner, c }, null);
        try state.placeObjectOnPage(page, outer);
        try state.constraints.addAnchor(state.allocator, outer, .left, .{ .page = .left }, 80, null);
        try state.constraints.addAnchor(state.allocator, outer, .top, .{ .page = .top }, -80, null);
        try state.constraints.addAnchor(state.allocator, b, .left, .{ .node = .{ .node_id = a, .anchor = .right } }, 32, null);
        try state.constraints.addAnchor(state.allocator, c, .left, .{ .node = .{ .node_id = inner, .anchor = .right } }, 32, null);
        try addDefaultAlignment(&state, b, a);
        try addDefaultAlignment(&state, c, inner);

        try finalizeDocumentState(&state_layout);

        const anchor: model.Anchor = if (std.mem.eql(u8, policy, "center")) .center_y else .top;
        const a_frame = (try state_layout.frame(a)).*;
        for ([_]model.NodeId{ b, c }) |id| {
            try expectFloat(graph.anchorValue(a_frame, anchor), graph.anchorValue((try state_layout.frame(id)).*, anchor));
        }
        try expectFloat(80, (try state_layout.frame(inner)).*.height);
        try expectFloat(80, (try state_layout.frame(outer)).*.height);
    }
}

test "layout solver: positioned ancestors preserve internal defaults but exclude external alignment" {
    for ([_]bool{ false, true }) |source_inside| {
        var state = try initEmptyDocumentState();
        defer state.deinit();
        var state_layout = LayoutFixture.init(&state);
        defer state_layout.deinit();
        const page = try state.addPage("Positioned ancestor");
        const a = try state.makeObject(page, "a", null, .text, .text, "A");
        const b = try state.makeObject(page, "b", null, .text, .text, "B");
        const group = try state.makeGroupWithOrigin(page, true, if (source_inside) &.{ a, b } else &.{b}, null);
        try addFixedSize(&state, a, 120, 80);
        try addFixedSize(&state, b, 180, 160);
        try state.constraints.addAnchor(state.allocator, group, .top, .{ .page = .bottom }, 500, null);
        try state.constraints.addAnchor(state.allocator, b, .left, .{ .node = .{ .node_id = a, .anchor = .right } }, 32, null);
        try addDefaultAlignment(&state, b, a);

        try solveDocumentState(&state_layout);

        try testing.expect(!(state_layout.result.failureCount() != 0));
        try expectFloat(500, graph.anchorValue((try state_layout.frame(b)).*, .top));
        if (source_inside) try expectFloat(500, graph.anchorValue((try state_layout.frame(a)).*, .top));
    }
}

test "layout graph: row defaults reject a cycle through an explicit vertical relation" {
    var state = try initEmptyDocumentState();
    defer state.deinit();
    var state_layout = LayoutFixture.init(&state);
    defer state_layout.deinit();
    const page = try state.addPage("Hard dependency cycle");
    const a = try state.makeObject(page, "a", null, .text, .text, "A");
    const b = try state.makeObject(page, "b", null, .text, .text, "B");
    try state.constraints.addAnchor(state.allocator, a, .top, .{ .node = .{ .node_id = b, .anchor = .bottom } }, -32, null);
    try addDefaultAlignment(&state, b, a);
    var page_graph = try initPageGraph(&state, page);
    defer page_graph.deinit();
    var workspace = try graph.AxisWorkspace.init(testing.allocator, try state_layout.work(), &page_graph, .vertical);
    defer workspace.deinit();
    var defaults = try core.layout.fallback.buildDefaultAlignmentConstraints(try state_layout.work(), &workspace);
    defer defaults.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), defaults.items.len);

    try solveDocumentState(&state_layout);
    try testing.expect(!(state_layout.result.failureCount() != 0));
    try expectFloat((try state_layout.frame(b)).*.y - 32, graph.anchorValue((try state_layout.frame(a)).*, .top));
}

test "layout graph: row defaults reject cycles through ancestor group translation" {
    var state = try initEmptyDocumentState();
    defer state.deinit();
    var state_layout = LayoutFixture.init(&state);
    defer state_layout.deinit();
    const page = try state.addPage("Group translation cycle");
    const a = try state.makeObject(page, "a", null, .text, .text, "A");
    const b = try state.makeObject(page, "b", null, .text, .text, "B");
    const c = try state.makeObject(page, "c", null, .text, .text, "C");
    const group = try state.makeGroupWithOrigin(page, true, &.{ b, c }, null);
    try addFixedSize(&state, a, 120, 80);
    try addFixedSize(&state, b, 180, 60);
    try addFixedSize(&state, c, 90, 50);
    try state.constraints.addAnchor(state.allocator, c, .top, .{ .node = .{ .node_id = b, .anchor = .bottom } }, -32, null);
    try addDefaultAlignment(&state, group, a);
    try addDefaultAlignment(&state, a, c);
    var page_graph = try initPageGraph(&state, page);
    defer page_graph.deinit();
    var workspace = try graph.AxisWorkspace.init(testing.allocator, try state_layout.work(), &page_graph, .vertical);
    defer workspace.deinit();
    var defaults = try core.layout.fallback.buildDefaultAlignmentConstraints(try state_layout.work(), &workspace);
    defer defaults.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), defaults.items.len);
    try testing.expectEqual(group, defaults.items[0].target_node);

    try solveDocumentState(&state_layout);
    try testing.expect(!(state_layout.result.failureCount() != 0));
    try expectFloat(graph.anchorValue((try state_layout.frame(a)).*, .top), graph.anchorValue((try state_layout.frame(group)).*, .top));
}

test "layout solver: horizontal fallback seeds unconstrained peer anchors" {
    var state = try initEmptyDocumentState();
    defer state.deinit();
    var state_layout = LayoutFixture.init(&state);
    defer state_layout.deinit();

    const page = try state.addPage("Page");
    const title = try state.makeObject(page, "title", null, .text, .text, "Title");
    const byline = try state.makeObject(page, "byline", null, .text, .text, "Byline");
    try state.constraints.addAnchor(state.allocator, title, .left, .{ .node = .{ .node_id = byline, .anchor = .left } }, 0, .{ .label = "same-left" });

    try finalizeDocumentState(&state_layout);

    try expectFloat((try state_layout.frame(title)).*.x, (try state_layout.frame(byline)).*.x);
}

test "layout solver: horizontal policy measures the complete row through display wrappers" {
    for ([_][]const u8{ "left", "center", "right" }) |policy| {
        for (0..3) |depth| {
            var state = try initEmptyDocumentState();
            defer state.deinit();
            var state_layout = LayoutFixture.init(&state);
            defer state_layout.deinit();
            const page = try state.addPage("Wrapped row");
            try setEnumField(&state, page, "layout_h", "LayoutPolicy", policy);
            var a = try state.createObjectWithOrigin("a", null, .text, .text, "A", null);
            var b = try state.createObjectWithOrigin("b", null, .text, .text, "B", null);
            try addFixedSize(&state, a, 120, 80);
            try addFixedSize(&state, b, 240, 60);
            for (0..depth) |_| {
                a = try state.createGroupWithOrigin(&.{a}, null);
                b = try state.createGroupWithOrigin(&.{b}, null);
            }
            const row = try state.createGroupWithOrigin(&.{ a, b }, null);
            try state.placeObjectOnPage(page, row);
            try state.constraints.addAnchor(state.allocator, b, .left, .{ .node = .{ .node_id = a, .anchor = .right } }, 32, null);
            try addDefaultAlignment(&state, b, a);

            try finalizeDocumentState(&state_layout);

            const frame = (try state_layout.frame(row)).*;
            try expectFloat(392, frame.width);
            const expected: f32 = if (std.mem.eql(u8, policy, "center")) 640 - frame.width / 2 else if (std.mem.eql(u8, policy, "right")) 1184 - frame.width else 96;
            try expectFloat(expected, frame.x);
            try expectFloat(frame.x, (try state_layout.frame(a)).*.x);
            try expectFloat(frame.x + 152, (try state_layout.frame(b)).*.x);
        }
    }
}

test "layout solver: same-target peer equalities form one fallback unit" {
    var state = try initEmptyDocumentState();
    defer state.deinit();
    var state_layout = LayoutFixture.init(&state);
    defer state_layout.deinit();

    const page = try state.addPage("Page");
    const a = try state.makeObject(page, "a", null, .text, .text, "A");
    const b = try state.makeObject(page, "b", null, .text, .text, "B");
    const c = try state.makeObject(page, "c", null, .text, .text, "C");
    try state.constraints.addAnchor(state.allocator, a, .top, .{ .node = .{ .node_id = b, .anchor = .top } }, 0, .{ .label = "a-is-b" });
    try state.constraints.addAnchor(state.allocator, a, .top, .{ .node = .{ .node_id = c, .anchor = .top } }, 0, .{ .label = "a-is-c" });

    try finalizeDocumentState(&state_layout);

    try expectFloat(graph.anchorValue((try state_layout.frame(a)).*, .top), graph.anchorValue((try state_layout.frame(b)).*, .top));
    try expectFloat(graph.anchorValue((try state_layout.frame(a)).*, .top), graph.anchorValue((try state_layout.frame(c)).*, .top));
    try testing.expect(!(state_layout.result.failureCount() != 0));
}

test "layout solver: chained peer equalities form one fallback unit" {
    var state = try initEmptyDocumentState();
    defer state.deinit();
    var state_layout = LayoutFixture.init(&state);
    defer state_layout.deinit();

    const page = try state.addPage("Page");
    const a = try state.makeObject(page, "a", null, .text, .text, "A");
    const b = try state.makeObject(page, "b", null, .text, .text, "B");
    const c = try state.makeObject(page, "c", null, .text, .text, "C");
    try state.constraints.addAnchor(state.allocator, a, .top, .{ .node = .{ .node_id = b, .anchor = .top } }, 0, .{ .label = "a-is-b" });
    try state.constraints.addAnchor(state.allocator, b, .top, .{ .node = .{ .node_id = c, .anchor = .top } }, 0, .{ .label = "b-is-c" });

    try finalizeDocumentState(&state_layout);

    try expectFloat(graph.anchorValue((try state_layout.frame(a)).*, .top), graph.anchorValue((try state_layout.frame(b)).*, .top));
    try expectFloat(graph.anchorValue((try state_layout.frame(a)).*, .top), graph.anchorValue((try state_layout.frame(c)).*, .top));
    try testing.expect(!(state_layout.result.failureCount() != 0));
}

test "layout solver: hard peer equality conflicts are independent of direction and chaining" {
    var forward = try initEmptyDocumentState();
    defer forward.deinit();
    var forward_layout = LayoutFixture.init(&forward);
    defer forward_layout.deinit();

    const forward_page = try forward.addPage("Page");
    const forward_a = try forward.makeObject(forward_page, "a", null, .text, .text, "A");
    const forward_b = try forward.makeObject(forward_page, "b", null, .text, .text, "B");
    try forward.constraints.addAnchor(forward.allocator, forward_a, .top, .{ .page = .top }, -100, .{ .label = "a-top" });
    try forward.constraints.addAnchor(forward.allocator, forward_b, .top, .{ .page = .top }, -200, .{ .label = "b-top" });
    try forward.constraints.addAnchor(forward.allocator, forward_a, .top, .{ .node = .{ .node_id = forward_b, .anchor = .top } }, 0, .{ .label = "a-is-b" });
    try testing.expectError(error.ConstraintConflict, finalizeDocumentState(&forward_layout));

    var reverse = try initEmptyDocumentState();
    defer reverse.deinit();
    var reverse_layout = LayoutFixture.init(&reverse);
    defer reverse_layout.deinit();

    const reverse_page = try reverse.addPage("Page");
    const reverse_a = try reverse.makeObject(reverse_page, "a", null, .text, .text, "A");
    const reverse_b = try reverse.makeObject(reverse_page, "b", null, .text, .text, "B");
    try reverse.constraints.addAnchor(reverse.allocator, reverse_a, .top, .{ .page = .top }, -100, .{ .label = "a-top" });
    try reverse.constraints.addAnchor(reverse.allocator, reverse_b, .top, .{ .page = .top }, -200, .{ .label = "b-top" });
    try reverse.constraints.addAnchor(reverse.allocator, reverse_b, .top, .{ .node = .{ .node_id = reverse_a, .anchor = .top } }, 0, .{ .label = "b-is-a" });
    try testing.expectError(error.ConstraintConflict, finalizeDocumentState(&reverse_layout));

    var chain = try initEmptyDocumentState();
    defer chain.deinit();
    var chain_layout = LayoutFixture.init(&chain);
    defer chain_layout.deinit();

    const chain_page = try chain.addPage("Page");
    const chain_a = try chain.makeObject(chain_page, "a", null, .text, .text, "A");
    const chain_b = try chain.makeObject(chain_page, "b", null, .text, .text, "B");
    const chain_c = try chain.makeObject(chain_page, "c", null, .text, .text, "C");
    try chain.constraints.addAnchor(chain.allocator, chain_a, .top, .{ .page = .top }, -100, .{ .label = "a-top" });
    try chain.constraints.addAnchor(chain.allocator, chain_c, .top, .{ .page = .top }, -200, .{ .label = "c-top" });
    try chain.constraints.addAnchor(chain.allocator, chain_a, .top, .{ .node = .{ .node_id = chain_b, .anchor = .top } }, 0, .{ .label = "a-is-b" });
    try chain.constraints.addAnchor(chain.allocator, chain_b, .top, .{ .node = .{ .node_id = chain_c, .anchor = .top } }, 0, .{ .label = "b-is-c" });
    try testing.expectError(error.ConstraintConflict, finalizeDocumentState(&chain_layout));
}

test "layout solver: horizontal fallback does not seed inconsistent hard cycles" {
    var state = try initEmptyDocumentState();
    defer state.deinit();
    var state_layout = LayoutFixture.init(&state);
    defer state_layout.deinit();

    const page = try state.addPage("Page");
    const a = try state.makeObject(page, "a", null, .text, .text, "aa");
    const b = try state.makeObject(page, "b", null, .text, .text, "bb");
    try state.constraints.addAnchor(state.allocator, a, .left, .{ .node = .{ .node_id = b, .anchor = .left } }, 100, .{ .label = "a-left" });
    try state.constraints.addAnchor(state.allocator, b, .left, .{ .node = .{ .node_id = a, .anchor = .left } }, 200, .{ .label = "b-left" });

    try testing.expectError(error.ConstraintConflict, finalizeDocumentState(&state_layout));
}

test "layout solver: constrained group source forms one fallback unit" {
    var state = try initEmptyDocumentState();
    defer state.deinit();
    var state_layout = LayoutFixture.init(&state);
    defer state_layout.deinit();

    try setLayoutPolicy(&state, state.graph.document_id, "center");

    const page = try state.addPage("Page");
    const left_title = try state.makeObject(page, "left-title", null, .text, .text, "Left");
    const left_body = try state.makeObject(page, "left-body", null, .text, .text, "Body");
    const right = try state.makeObject(page, "right", null, .text, .text, "Right");
    const left_group = try state.makeGroupWithOrigin(state.graph.document_id, false, &.{ left_title, left_body }, .{ .label = "left-group" });

    try state.constraints.addAnchor(state.allocator, right, .left, .{ .node = .{ .node_id = left_group, .anchor = .right } }, 30, .{ .label = "right-of-group" });
    try state.constraints.addAnchor(state.allocator, right, .center_y, .{ .node = .{ .node_id = left_group, .anchor = .center_y } }, 0, .{ .label = "align-group-center" });

    try finalizeDocumentState(&state_layout);

    const left_title_node = state.getNode(left_title).?;
    try testing.expect((try state_layout.frame(left_group)).*.x_set);
    try testing.expect((try state_layout.frame(left_group)).*.y_set);
    try expectFloat((try state_layout.frame(left_group)).*.x + (try state_layout.frame(left_group)).*.width + 30, (try state_layout.frame(right)).*.x);
    try expectFloat((try state_layout.frame(left_group)).*.y + (try state_layout.frame(left_group)).*.height / 2, (try state_layout.frame(right)).*.y + (try state_layout.frame(right)).*.height / 2);

    const title_spacing = core.layout.styleForNode(&state, left_title_node).spacing_after;
    try expectFloat((try state_layout.frame(left_title)).*.y - title_spacing, (try state_layout.frame(left_body)).*.y + (try state_layout.frame(left_body)).*.height);
}

test "layout solver: centered vflow treats vertically aligned groups as one row" {
    var state = try initEmptyDocumentState();
    defer state.deinit();
    var state_layout = LayoutFixture.init(&state);
    defer state_layout.deinit();

    try setLayoutPolicy(&state, state.graph.document_id, "center");

    const page = try state.addPage("Page");
    const left_title = try state.makeObject(page, "left-title", null, .text, .text, "Left");
    const left_body = try state.makeObject(page, "left-body", null, .text, .text, "Body");
    const right_title = try state.makeObject(page, "right-title", null, .text, .text, "Right");
    const right_body = try state.makeObject(page, "right-body", null, .text, .text, "Body");
    const left_group = try state.makeGroupWithOrigin(state.graph.document_id, false, &.{ left_title, left_body }, .{ .label = "left-group" });
    const right_group = try state.makeGroupWithOrigin(state.graph.document_id, false, &.{ right_title, right_body }, .{ .label = "right-group" });

    try setLayoutLineHeight(&state, left_title, "40");
    try setLayoutLineHeight(&state, left_body, "200");
    try setLayoutLineHeight(&state, right_title, "40");
    try setLayoutLineHeight(&state, right_body, "200");
    try setLayoutSpacingAfter(&state, left_title, "20");
    try setLayoutSpacingAfter(&state, right_title, "20");
    try setLayoutSpacingAfter(&state, left_body, "0");
    try setLayoutSpacingAfter(&state, right_body, "0");

    try state.constraints.addAnchor(state.allocator, right_group, .left, .{ .node = .{ .node_id = left_group, .anchor = .right } }, 30, .{ .label = "right-of-left-group" });
    try state.constraints.addAnchor(state.allocator, right_group, .center_y, .{ .node = .{ .node_id = left_group, .anchor = .center_y } }, 0, .{ .label = "align-group-centers" });

    try finalizeDocumentState(&state_layout);

    const left_center = (try state_layout.frame(left_group)).*.y + (try state_layout.frame(left_group)).*.height / 2;
    const right_center = (try state_layout.frame(right_group)).*.y + (try state_layout.frame(right_group)).*.height / 2;
    try expectFloat(left_center, right_center);

    const row_top = @max((try state_layout.frame(left_group)).*.y + (try state_layout.frame(left_group)).*.height, (try state_layout.frame(right_group)).*.y + (try state_layout.frame(right_group)).*.height);
    const row_bottom = @min((try state_layout.frame(left_group)).*.y, (try state_layout.frame(right_group)).*.y);
    try expectFloat(core.layout.Defaults.height / 2, (row_top + row_bottom) / 2);
}

test "layout solver: centered vflow ignores the space occupied by fixed top components" {
    var state = try initEmptyDocumentState();
    defer state.deinit();
    var state_layout = LayoutFixture.init(&state);
    defer state_layout.deinit();

    try setLayoutPolicy(&state, state.graph.document_id, "center");

    const page = try state.addPage("Page");
    const header = try state.makeObject(page, "title", null, .text, .text, "Title");
    const body = try state.makeObject(page, "body", null, .text, .text, "Body");

    try setLayoutLineHeight(&state, header, "44");
    try setLayoutSpacingAfter(&state, header, "40");
    try setLayoutLineHeight(&state, body, "580");
    try state.constraints.addAnchor(state.allocator, header, .top, .{ .page = .top }, -56, .{ .label = "header-top" });

    try solveDocumentState(&state_layout);

    try expectFloat(core.layout.Defaults.height / 2, graph.anchorValue((try state_layout.frame(body)).*, .center_y));
    try expectFloat(core.layout.Defaults.height - 56, graph.anchorValue((try state_layout.frame(header)).*, .top));
    try testing.expect(!(state_layout.result.failureCount() != 0));
}

test "layout solver: document centered vflow is not shadowed by page default policy" {
    var state = try initEmptyDocumentState();
    defer state.deinit();
    var state_layout = LayoutFixture.init(&state);
    defer state_layout.deinit();

    try setLayoutPolicy(&state, state.graph.document_id, "center");
    try setLayoutCenterOffset(&state, state.graph.document_id, "40");

    const page = try state.addPage("Page");
    const pageno = try state.createObjectWithOrigin("pageno", null, .text, .text, "1", null);
    try state.placeObjectOnPage(page, pageno);
    const title = try state.makeObject(page, "title", null, .text, .text, "Title");
    const subtitle = try state.makeObject(page, "subtitle", null, .text, .text, "Subtitle");

    try setLayoutLineHeight(&state, pageno, "16");
    try setLayoutSpacingAfter(&state, pageno, "0");
    try setLayoutLineHeight(&state, title, "94");
    try setLayoutSpacingAfter(&state, title, "42");
    try setLayoutLineHeight(&state, subtitle, "37");
    try setLayoutSpacingAfter(&state, subtitle, "0");
    try state.constraints.addAnchor(state.allocator, pageno, .bottom, .{ .page = .bottom }, 20, .{ .label = "pageno-bottom" });

    try solveDocumentState(&state_layout);

    const stack_top = graph.anchorValue((try state_layout.frame(title)).*, .top);
    const stack_bottom = graph.anchorValue((try state_layout.frame(subtitle)).*, .bottom);
    try expectFloat(core.layout.Defaults.height / 2 - 40, (stack_top + stack_bottom) / 2);
    try testing.expect(graph.anchorValue((try state_layout.frame(title)).*, .bottom) > graph.anchorValue((try state_layout.frame(pageno)).*, .top));
}

test "layout solver: centered vflow preserves page center for side-by-side rows" {
    var state = try initEmptyDocumentState();
    defer state.deinit();
    var state_layout = LayoutFixture.init(&state);
    defer state_layout.deinit();

    try setLayoutPolicy(&state, state.graph.document_id, "center");

    const page = try state.addPage("Page");
    const title = try state.makeObject(page, "title", null, .text, .text, "Title");
    const rule = try state.makeObject(page, "rule", null, .text, .text, "");
    const body = try state.makeObject(page, "body", null, .text, .text, "Body");
    const pipe_child = try state.makeObject(page, "pipe", null, .text, .text, "Pipe");
    const pipe = try state.makeGroupWithOrigin(page, true, &.{pipe_child}, .{ .label = "pipe-group" });

    try setLayoutLineHeight(&state, title, "44");
    try setLayoutLineHeight(&state, rule, "4");
    try setLayoutSpacingAfter(&state, rule, "48");
    try setLayoutLineHeight(&state, body, "360");
    try setLayoutLineHeight(&state, pipe_child, "360");
    try state.constraints.addAnchor(state.allocator, title, .top, .{ .page = .top }, -56, .{ .label = "title-top" });
    try state.constraints.addAnchor(state.allocator, rule, .top, .{ .node = .{ .node_id = title, .anchor = .bottom } }, -14, .{ .label = "rule-below-title" });
    try state.constraints.addAnchor(state.allocator, pipe, .right, .{ .page = .right }, -100, .{ .label = "pipe-right" });
    try state.constraints.addAnchor(state.allocator, pipe, .top, .{ .node = .{ .node_id = body, .anchor = .top } }, 0, .{ .label = "align-row-top" });

    try solveDocumentState(&state_layout);

    const body_center = (try state_layout.frame(body)).*.y + (try state_layout.frame(body)).*.height / 2;
    const pipe_center = (try state_layout.frame(pipe)).*.y + (try state_layout.frame(pipe)).*.height / 2;
    try expectFloat(body_center, pipe_center);
    try expectFloat(core.layout.Defaults.height / 2, body_center);
}

test "layout solver: explicit anchor conflicts and negative frame sizes are rejected" {
    var conflict = try initEmptyDocumentState();
    defer conflict.deinit();
    var conflict_layout = LayoutFixture.init(&conflict);
    defer conflict_layout.deinit();

    const conflict_page = try conflict.addPage("Page");
    const conflict_object = try conflict.makeObject(conflict_page, "body", null, .text, .text, "A");
    try conflict.constraints.addAnchor(conflict.allocator, conflict_object, .left, .{ .page = .left }, 100, .{ .label = "left-a" });
    try conflict.constraints.addAnchor(conflict.allocator, conflict_object, .left, .{ .page = .left }, 120, .{ .label = "left-b" });
    try testing.expectError(error.ConstraintConflict, finalizeDocumentState(&conflict_layout));

    var negative = try initEmptyDocumentState();
    defer negative.deinit();
    var negative_layout = LayoutFixture.init(&negative);
    defer negative_layout.deinit();

    const negative_page = try negative.addPage("Page");
    const negative_object = try negative.makeObject(negative_page, "body", null, .text, .text, "A");
    try negative.constraints.addAnchor(negative.allocator, negative_object, .left, .{ .node = .{ .node_id = negative_object, .anchor = .right } }, 10, .{ .label = "negative-width" });
    try testing.expectError(error.NegativeFrameSize, finalizeDocumentState(&negative_layout));
}

test "layout solver: group width propagation must preserve child hard widths" {
    var state = try initEmptyDocumentState();
    defer state.deinit();
    var state_layout = LayoutFixture.init(&state);
    defer state_layout.deinit();

    const page = try state.addPage("Page");
    const child = try state.makeObject(page, "body", null, .text, .text, "this text can be wrapped");
    try setLayoutWrap(&state, child, "on");
    const group = try state.makeGroupWithOrigin(page, true, &.{child}, .{ .label = "group" });

    try state.constraints.addAnchor(state.allocator, child, .left, .{ .page = .left }, 100, .{ .label = "child-left" });
    try state.constraints.addAnchor(state.allocator, child, .right, .{ .node = .{ .node_id = child, .anchor = .left } }, 700, .{ .label = "child-width" });
    try state.constraints.addAnchor(state.allocator, group, .right, .{ .node = .{ .node_id = group, .anchor = .left } }, 600, .{ .label = "group-width" });

    try testing.expectError(error.ConstraintConflict, finalizeDocumentState(&state_layout));
}

test "layout solver: wrapped width cap propagates through dependent anchors" {
    var state = try initEmptyDocumentState();
    defer state.deinit();
    var state_layout = LayoutFixture.init(&state);
    defer state_layout.deinit();

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

    try state.constraints.addAnchor(state.allocator, wrapped, .left, .{ .page = .left }, 1100, .{ .label = "wrapped-left" });
    try state.constraints.addAnchor(state.allocator, follower, .left, .{ .node = .{ .node_id = wrapped, .anchor = .right } }, 20, .{ .label = "follower-left" });

    try solveDocumentState(&state_layout);

    const wrapped_node = state.getNode(wrapped).?;
    const style = core.layout.styleForNode(&state, wrapped_node);
    const expected_width = core.layout.Defaults.width - style.default_right_inset - 1100;
    try expectFloat(expected_width, (try state_layout.frame(wrapped)).*.width);
    try expectFloat((try state_layout.frame(wrapped)).*.x + (try state_layout.frame(wrapped)).*.width + 20, (try state_layout.frame(follower)).*.x);
}

test "layout solver: vertical axis observes width-dependent wrapped height" {
    var state = try initEmptyDocumentState();
    defer state.deinit();
    var state_layout = LayoutFixture.init(&state);
    defer state_layout.deinit();

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
    try state.constraints.addAnchor(state.allocator, wrapped, .left, .{ .page = .left }, 1100, .{ .label = "wrapped-left" });
    try state.constraints.addAnchor(state.allocator, wrapped, .bottom, .{ .page = .bottom }, 40, .{ .label = "wrapped-bottom" });

    try solveDocumentState(&state_layout);

    const wrapped_node = state.getNode(wrapped).?;
    const expected_height = metrics.intrinsicHeight(try state_layout.work(), wrapped_node, (try state_layout.frame(wrapped_node.id)).*);
    try testing.expect(expected_height > 28);
    try expectFloat(expected_height, (try state_layout.frame(wrapped)).*.height);
}

const FakeMeasurementContext = struct {
    target: model.NodeId,
    natural_calls: usize = 0,
    constrained_calls: usize = 0,
    last_constrained_width: f32 = 0,
};

const InkMeasurement = struct {
    ink: model.LayoutBounds,

    fn measure(context: *anyopaque, _: *core.layout.Workspace, _: *const model.Node, width: f32, _: model.LayoutMeasurementMode) !?model.LayoutMeasurement {
        const self: *InkMeasurement = @ptrCast(@alignCast(context));
        return .{ .width = 10, .height = 36, .ink_bounds = self.ink, .first_baseline = 26, .measured_width = width };
    }
};

test "layout diagnostics preserve the direction of ink outside the page" {
    const cases = [_]struct { left: f32, ink: model.LayoutBounds, overflow_left: f32 = 0, overflow_right: f32 = 0, overflow_top: f32 = 0 }{
        .{ .left = 0, .ink = .{ .x = -5, .y = 5, .width = 13, .height = 24 }, .overflow_left = 5 },
        .{ .left = 1270, .ink = .{ .x = -2, .y = 5, .width = 15, .height = 24 }, .overflow_right = 3 },
        .{ .left = 60, .ink = .{ .x = 0, .y = -0.5, .width = 10, .height = 24 }, .overflow_top = 0.5 },
    };
    for (cases) |case| {
        var state = try initEmptyDocumentState();
        defer state.deinit();
        var state_layout = LayoutFixture.init(&state);
        defer state_layout.deinit();
        const page = try state.addPage("Ink overflow");
        const object = try state.makeObject(page, "text", null, .text, .text, "j");
        try state.constraints.addAnchor(state.allocator, object, .left, .{ .page = .left }, case.left, .{ .label = "left" });
        try state.constraints.addAnchor(state.allocator, object, .top, .{ .page = .top }, 0, .{ .label = "top" });
        var measurement = InkMeasurement{ .ink = case.ink };
        try solveDocumentStateWithOptions(&state_layout, null, .{ .measurement_provider = .{ .context = &measurement, .measure = InkMeasurement.measure } });
        const retained = state_layout.result.measurementOf(object).?;
        try testing.expectEqualDeep(case.ink, retained.ink_bounds.?);
        try testing.expectEqual(@as(f32, 26), retained.first_baseline.?);
        var found = false;
        for (state_layout.result.pages[0].diagnostics) |diagnostic| {
            if (diagnostic.node_id != object or diagnostic.data != .page_overflow) continue;
            const data = diagnostic.data.page_overflow;
            try expectFloat(case.overflow_left, data.overflow_left);
            try expectFloat(case.overflow_right, data.overflow_right);
            try expectFloat(case.overflow_top, data.overflow_top);
            try expectFloat(0, data.overflow_bottom);
            found = true;
        }
        try testing.expect(found);
    }
}

fn fakeLayoutMeasurement(
    context: *anyopaque,
    state_ptr: *core.layout.Workspace,
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

const FailingMeasurementContext = struct {
    target: model.NodeId,
    constrained_calls: usize = 0,
};

fn failRepeatedConstrainedMeasurement(
    context: *anyopaque,
    state_ptr: *core.layout.Workspace,
    node: *const model.Node,
    width: f32,
    mode: model.LayoutMeasurementMode,
) anyerror!?model.LayoutMeasurement {
    _ = state_ptr;
    const ctx: *FailingMeasurementContext = @ptrCast(@alignCast(context));
    if (node.id != ctx.target) return null;
    return switch (mode) {
        .natural => .{ .width = 321, .height = 1 },
        .width_constrained => blk: {
            ctx.constrained_calls += 1;
            if (ctx.constrained_calls > 1) return error.TestMeasurementFailed;
            break :blk .{ .width = width, .height = 87 };
        },
    };
}

const FakeAllMeasurementContext = struct {
    calls: usize = 0,
};

fn fakeAllLayoutMeasurement(
    context: *anyopaque,
    state_ptr: *core.layout.Workspace,
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

const NestedTraceMeasurementContext = struct {
    inner_state: *core.DocumentState,
    inner_trace_path: []const u8,
    solved: bool = false,
};

fn solveNestedTraceDuringMeasurement(
    context: *anyopaque,
    state_ptr: *core.layout.Workspace,
    node: *const model.Node,
    width: f32,
    mode: model.LayoutMeasurementMode,
) anyerror!?model.LayoutMeasurement {
    _ = state_ptr;
    _ = node;
    _ = width;
    _ = mode;
    const ctx: *NestedTraceMeasurementContext = @ptrCast(@alignCast(context));
    if (!ctx.solved) {
        ctx.solved = true;
        var inner_document = try solver.solveDocument(ctx.inner_state, ctx.inner_trace_path, .{});
        defer inner_document.deinit(ctx.inner_state.allocator);
    }
    return .{ .width = 240, .height = 80 };
}

fn expectTraceContainsOnly(path: []const u8, expected_name: []const u8, unexpected_name: []const u8) !void {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(testing.io, path, testing.allocator, .limited(1024 * 1024));
    defer testing.allocator.free(bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, bytes, .{});
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |object| object,
        else => return error.ExpectedTraceObject,
    };
    const events = root.get("events") orelse return error.ExpectedTraceEvents;
    try testing.expect(events.array.items.len > 0);
    try testing.expect(std.mem.indexOf(u8, bytes, expected_name) != null);
    try testing.expect(std.mem.indexOf(u8, bytes, unexpected_name) == null);
}

test "nested layout traces keep independent sessions" {
    var outer_state = try initEmptyDocumentState();
    defer outer_state.deinit();
    var outer_state_layout = LayoutFixture.init(&outer_state);
    defer outer_state_layout.deinit();
    const outer_page = try outer_state.addPage("Outer");
    _ = try outer_state.makeObject(outer_page, "outer-only", null, .text, .text, "outer");

    var inner_state = try initEmptyDocumentState();
    defer inner_state.deinit();
    var inner_state_layout = LayoutFixture.init(&inner_state);
    defer inner_state_layout.deinit();
    const inner_page = try inner_state.addPage("Inner");
    _ = try inner_state.makeObject(inner_page, "inner-only", null, .text, .text, "inner");

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    defer testing.allocator.free(root);
    const outer_trace_path = try std.fs.path.join(testing.allocator, &.{ root, "outer.json" });
    defer testing.allocator.free(outer_trace_path);
    const inner_trace_path = try std.fs.path.join(testing.allocator, &.{ root, "inner.json" });
    defer testing.allocator.free(inner_trace_path);

    var measurement = NestedTraceMeasurementContext{
        .inner_state = &inner_state,
        .inner_trace_path = inner_trace_path,
    };
    var outer_document = try solver.solveDocument(&outer_state, outer_trace_path, .{
        .measurement_provider = .{
            .context = &measurement,
            .measure = solveNestedTraceDuringMeasurement,
        },
    });
    defer outer_document.deinit(outer_state.allocator);

    try testing.expect(measurement.solved);
    try expectTraceContainsOnly(outer_trace_path, "outer-only", "inner-only");
    try expectTraceContainsOnly(inner_trace_path, "inner-only", "outer-only");
}

test "layout solver uses render measurement provider for intrinsic object size" {
    var state = try initEmptyDocumentState();
    defer state.deinit();
    var state_layout = LayoutFixture.init(&state);
    defer state_layout.deinit();

    const page = try state.addPage("Page");
    const object = try state.makeObject(page, "body", null, .text, .text, "provider measured text");
    var measurement = FakeMeasurementContext{ .target = object };

    try solveDocumentStateWithOptions(&state_layout, null, .{
        .measurement_provider = .{
            .context = &measurement,
            .measure = fakeLayoutMeasurement,
        },
    });

    try expectFloat(321, (try state_layout.frame(object)).*.width);
    try expectFloat(87, (try state_layout.frame(object)).*.height);
    try expectFloat(321, measurement.last_constrained_width);
    try testing.expect(measurement.natural_calls > 0);
    try testing.expect(measurement.constrained_calls > 0);
}

test "layout solver preserves render measurement errors after horizontal solving" {
    var state = try initEmptyDocumentState();
    defer state.deinit();
    var state_layout = LayoutFixture.init(&state);
    defer state_layout.deinit();

    const page = try state.addPage("Page");
    const object = try state.makeObject(page, "body", null, .text, .text, "provider measured text");
    try setLayoutWrap(&state, object, "on");
    var measurement = FailingMeasurementContext{ .target = object };

    try testing.expectError(error.TestMeasurementFailed, solver.solveDocument(&state, null, .{
        .measurement_provider = .{
            .context = &measurement,
            .measure = failRepeatedConstrainedMeasurement,
        },
    }));
    try testing.expectEqual(@as(usize, 2), measurement.constrained_calls);
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
    var state_layout = LayoutFixture.init(&state);
    defer state_layout.deinit();

    const first_page = try state.addPage("First");
    const first = try state.makeObject(first_page, "first", null, .text, .text, "First");
    try state.constraints.addAnchor(state.allocator, first, .left, .{ .page = .left }, 40, .{ .label = "first-left" });
    try state.constraints.addAnchor(state.allocator, first, .top, .{ .page = .top }, -80, .{ .label = "first-top" });

    const second_page = try state.addPage("Second");
    const second = try state.makeObject(second_page, "second", null, .text, .text, "Second");
    try state.constraints.addAnchor(state.allocator, second, .left, .{ .page = .left }, 80, .{ .label = "second-left" });
    try state.constraints.addAnchor(state.allocator, second, .top, .{ .page = .top }, -120, .{ .label = "second-top" });

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

const LayoutCancellationCounter = struct {
    checks: std.atomic.Value(usize) = .init(0),
    cancel_after: usize,
};

fn cancelLayoutAfterCheck(context: *const anyopaque) bool {
    const counter: *LayoutCancellationCounter = @ptrCast(@alignCast(@constCast(context)));
    return counter.checks.fetchAdd(1, .seq_cst) + 1 >= counter.cancel_after;
}

test "layout solver cooperatively cancels parallel page jobs" {
    var state = try initEmptyDocumentState();
    defer state.deinit();
    var state_layout = LayoutFixture.init(&state);
    defer state_layout.deinit();

    const first_page = try state.addPage("First");
    const first = try state.makeObject(first_page, "first", null, .text, .text, "First");
    try state.constraints.addAnchor(state.allocator, first, .left, .{ .page = .left }, 40, .{ .label = "first-left" });
    try state.constraints.addAnchor(state.allocator, first, .top, .{ .page = .top }, -80, .{ .label = "first-top" });

    const second_page = try state.addPage("Second");
    const second = try state.makeObject(second_page, "second", null, .text, .text, "Second");
    try state.constraints.addAnchor(state.allocator, second, .left, .{ .page = .left }, 80, .{ .label = "second-left" });
    try state.constraints.addAnchor(state.allocator, second, .top, .{ .page = .top }, -120, .{ .label = "second-top" });

    var counter = LayoutCancellationCounter{ .cancel_after = 30 };
    try testing.expectError(error.Canceled, solver.solveDocument(&state, null, .{
        .jobs = 2,
        .cancellation = .{
            .context = &counter,
            .is_canceled = cancelLayoutAfterCheck,
        },
    }));
    try testing.expect(counter.checks.load(.seq_cst) >= counter.cancel_after);
}

test "layout metrics prefer render measurement provider for asset size" {
    var state = try initEmptyDocumentState();
    defer state.deinit();
    var state_layout = LayoutFixture.init(&state);
    defer state_layout.deinit();

    const page = try state.addPage("Page");
    const pdf = try state.makeObject(page, "pdf", null, .asset, .pdf_ref, "chart.pdf");
    try setNumberField(&state, pdf, "asset_width", 220);
    try setNumberField(&state, pdf, "asset_height", 70);
    const image = try state.makeObject(page, "image", null, .asset, .image_ref, "chart.png");

    var measurement = FakeAllMeasurementContext{};
    try solveDocumentStateWithOptions(&state_layout, null, .{
        .measurement_provider = .{
            .context = &measurement,
            .measure = fakeAllLayoutMeasurement,
        },
    });

    try expectFloat(1000, (try state_layout.frame(pdf)).*.width);
    try expectFloat(700, (try state_layout.frame(pdf)).*.height);
    try expectFloat(1000, (try state_layout.frame(image)).*.width);
    try expectFloat(700, (try state_layout.frame(image)).*.height);
    try testing.expect(measurement.calls > 0);
}

test "asset payloads ignore text wrap requests" {
    var state = try initEmptyDocumentState();
    defer state.deinit();
    var state_layout = LayoutFixture.init(&state);
    defer state_layout.deinit();

    const page = try state.addPage("Page");
    const image = try state.makeObject(page, "image", null, .asset, .image_ref, "chart.png");
    try setLayoutWrap(&state, image, "on");

    try testing.expect(!metrics.shouldWrapNode(try state_layout.work(), state.getNode(image).?));
}

test "layout metrics use measured font width for wrapped text height" {
    var state = try initEmptyDocumentState();
    defer state.deinit();
    var state_layout = LayoutFixture.init(&state);
    defer state_layout.deinit();

    const page = try state.addPage("Page");
    const object = try state.makeObject(page, "body", null, .text, .text, "0123456789012345678901234567");
    try setLayoutWrap(&state, object, "on");
    try setTextFontFamily(&state, object, "Helvetica");
    try setTextSize(&state, object, "30");

    const node = state.getNode(object).?;
    (try state_layout.frame(object)).*.width = 480;

    try expectFloat(43.5, metrics.intrinsicHeight(try state_layout.work(), node, (try state_layout.frame(node.id)).*));
}

test "layout metrics use render atom widths for CJK emoji markdown text" {
    var state = try initEmptyDocumentState();
    defer state.deinit();
    var state_layout = LayoutFixture.init(&state);
    defer state_layout.deinit();

    const page = try state.addPage("Page");
    const object = try state.makeObject(page, "body", null, .text, .text, "✅ 最初のエラー報告までの時間が短縮できる");
    try setLayoutWrap(&state, object, "on");
    try setTextParse(&state, object, "block");
    try setTextFontFamily(&state, object, "Helvetica");
    try setTextFontWeight(&state, object, "700");
    try setTextSize(&state, object, "30");
    try setTextLineHeight(&state, object, "31");

    const node = state.getNode(object).?;
    const measured_width = metrics.intrinsicWidth(try state_layout.work(), node);
    try testing.expect(measured_width > 1);
    (try state_layout.frame(object)).*.width = measured_width - 1;

    try expectFloat(62, metrics.intrinsicHeight(try state_layout.work(), node, (try state_layout.frame(node.id)).*));
}

test "layout solver keeps CJK emoji markdown text on one line when measured atom width fits" {
    var state = try initEmptyDocumentState();
    defer state.deinit();
    var state_layout = LayoutFixture.init(&state);
    defer state_layout.deinit();

    const page = try state.addPage("Page");
    const object = try state.makeObject(page, "body", null, .text, .text, "✅ 最初のエラー報告までの時間が短縮できる");
    try setLayoutWrap(&state, object, "on");
    try setTextParse(&state, object, "block");
    try setTextFontFamily(&state, object, "Helvetica");
    try setTextFontWeight(&state, object, "700");
    try setTextSize(&state, object, "30");
    try setTextLineHeight(&state, object, "31");

    const expected_width = metrics.intrinsicWidth(try state_layout.work(), state.getNode(object).?);
    try testing.expect(expected_width > 1);

    try solveDocumentState(&state_layout);

    try expectFloat(expected_width, (try state_layout.frame(object)).*.width);
    try expectFloat(31, (try state_layout.frame(object)).*.height);
}

test "layout metrics: chrome padding is part of visual bounds and yields a content frame" {
    var state = try initEmptyDocumentState();
    defer state.deinit();
    var state_layout = LayoutFixture.init(&state);
    defer state_layout.deinit();

    const page = try state.addPage("Page");
    const plain = try state.makeObject(page, "plain", null, .text, .text, "Hello");
    const padded = try state.makeObject(page, "padded", null, .text, .text, "Hello");
    try setChromePadX(&state, padded, "12");
    try setChromePadY(&state, padded, "8");

    const plain_node = state.getNode(plain).?;
    const padded_node = state.getNode(padded).?;
    try expectFloat(metrics.intrinsicWidth(try state_layout.work(), plain_node) + 24, metrics.intrinsicWidth(try state_layout.work(), padded_node));
    try expectFloat(metrics.intrinsicHeight(try state_layout.work(), plain_node, (try state_layout.frame(plain_node.id)).*) + 16, metrics.intrinsicHeight(try state_layout.work(), padded_node, (try state_layout.frame(padded_node.id)).*));

    (try state_layout.frame(padded)).* = .{ .x = 10, .y = 20, .width = 100, .height = 50, .x_set = true, .y_set = true };
    const content = core.layout.contentFrame(try state_layout.work(), state.getNode(padded).?, (try state_layout.frame(padded)).*);
    try expectFloat(22, content.x);
    try expectFloat(28, content.y);
    try expectFloat(76, content.width);
    try expectFloat(34, content.height);
}

test "layout metrics: unwrapped text width includes visual glyph bounds" {
    var state = try initEmptyDocumentState();
    defer state.deinit();
    var state_layout = LayoutFixture.init(&state);
    defer state_layout.deinit();

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

    try testing.expect(metrics.intrinsicWidth(try state_layout.work(), node) >= atom_width + 40);
}

test "layout solver: group chrome padding expands tight group bounds" {
    var state = try initEmptyDocumentState();
    defer state.deinit();
    var state_layout = LayoutFixture.init(&state);
    defer state_layout.deinit();

    const page = try state.addPage("Page");
    const child = try state.makeObject(page, "child", null, .text, .text, "Hello");
    const group = try state.makeGroupWithOrigin(page, true, &.{child}, .{ .label = "group" });
    try setChromePadX(&state, group, "12");
    try setChromePadY(&state, group, "8");

    try state.constraints.addAnchor(state.allocator, child, .left, .{ .page = .left }, 100, .{ .label = "child-left" });
    try state.constraints.addAnchor(state.allocator, child, .right, .{ .node = .{ .node_id = child, .anchor = .left } }, 200, .{ .label = "child-width" });
    try state.constraints.addAnchor(state.allocator, child, .bottom, .{ .page = .bottom }, 100, .{ .label = "child-bottom" });
    try state.constraints.addAnchor(state.allocator, child, .top, .{ .node = .{ .node_id = child, .anchor = .bottom } }, 40, .{ .label = "child-height" });

    try solveDocumentState(&state_layout);

    try expectFloat(88, (try state_layout.frame(group)).*.x);
    try expectFloat(92, (try state_layout.frame(group)).*.y);
    try expectFloat(224, (try state_layout.frame(group)).*.width);
    try expectFloat(56, (try state_layout.frame(group)).*.height);
}

test "layout solver: target group width leaves room for chrome padding" {
    var state = try initEmptyDocumentState();
    defer state.deinit();
    var state_layout = LayoutFixture.init(&state);
    defer state_layout.deinit();

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
    const group = try state.makeGroupWithOrigin(page, true, &.{child}, .{ .label = "group" });
    try setChromePadX(&state, group, "10");

    try state.constraints.addAnchor(state.allocator, group, .left, .{ .page = .left }, 100, .{ .label = "group-left" });
    try state.constraints.addAnchor(state.allocator, group, .right, .{ .node = .{ .node_id = group, .anchor = .left } }, 220, .{ .label = "group-width" });

    try solveDocumentState(&state_layout);

    try expectFloat(100, (try state_layout.frame(group)).*.x);
    try expectFloat(220, (try state_layout.frame(group)).*.width);
    try expectFloat(110, (try state_layout.frame(child)).*.x);
    try expectFloat(200, (try state_layout.frame(child)).*.width);
}

test "layout diagnostics: fixed-height object reports frame too small" {
    var state = try initEmptyDocumentState();
    defer state.deinit();
    var state_layout = LayoutFixture.init(&state);
    defer state_layout.deinit();

    const page = try state.addPage("Page");
    const object = try state.makeObject(page, "short-box", null, .text, .text, "line one\nline two");
    try state.constraints.addAnchor(state.allocator, object, .left, .{ .page = .left }, 20, .{ .label = "left" });
    try state.constraints.addAnchor(state.allocator, object, .right, .{ .node = .{ .node_id = object, .anchor = .left } }, 200, .{ .label = "width" });
    try state.constraints.addAnchor(state.allocator, object, .bottom, .{ .page = .bottom }, 20, .{ .label = "bottom" });
    try state.constraints.addAnchor(state.allocator, object, .top, .{ .node = .{ .node_id = object, .anchor = .bottom } }, 20, .{ .label = "height" });

    try solveDocumentState(&state_layout);

    const node = state.getNode(object).?;
    try expectFloat(20, (try state_layout.frame(object)).*.height);
    const required_height = metrics.intrinsicHeight(try state_layout.work(), node, (try state_layout.frame(node.id)).*);
    try testing.expect(required_height > (try state_layout.frame(object)).*.height);

    var found = false;
    for (state_layout.result.pages[0].diagnostics) |diagnostic| {
        if (diagnostic.node_id != object) continue;
        switch (diagnostic.data) {
            .content_overflow => |data| {
                found = true;
                try testing.expectEqual(core.DiagnosticSeverity.warning, diagnostic.severity);
                try expectFloat(metrics.intrinsicWidth(try state_layout.work(), node), data.required_width);
                try expectFloat((try state_layout.frame(object)).*.width, data.frame_width);
                try expectFloat(0, data.overflow_width);
                try expectFloat(required_height, data.required_height);
                try expectFloat((try state_layout.frame(object)).*.height, data.frame_height);
                try expectFloat(required_height - (try state_layout.frame(object)).*.height, data.overflow_height);
            },
            else => {},
        }
    }
    try testing.expect(found);
}

test "layout diagnostics: one-pixel text reports frame too small" {
    var state = try initEmptyDocumentState();
    defer state.deinit();
    var state_layout = LayoutFixture.init(&state);
    defer state_layout.deinit();

    const page = try state.addPage("Page");
    const object = try state.makeObject(page, "toc-marker", null, .text, .text, "hidden section title");
    try setLayoutFontSize(&state, object, "1");
    try setLayoutLineHeight(&state, object, "1");
    try setTextSize(&state, object, "1");
    try setTextLineHeight(&state, object, "1");
    try setLayoutWrap(&state, object, "on");
    try state.constraints.addAnchor(state.allocator, object, .left, .{ .page = .left }, 20, .{ .label = "left" });
    try state.constraints.addAnchor(state.allocator, object, .right, .{ .node = .{ .node_id = object, .anchor = .left } }, 1, .{ .label = "width" });
    try state.constraints.addAnchor(state.allocator, object, .bottom, .{ .page = .bottom }, 20, .{ .label = "bottom" });
    try state.constraints.addAnchor(state.allocator, object, .top, .{ .node = .{ .node_id = object, .anchor = .bottom } }, 1, .{ .label = "height" });

    try solveDocumentState(&state_layout);

    var found = false;
    for (state_layout.result.pages[0].diagnostics) |diagnostic| {
        if (diagnostic.node_id == object and diagnostic.data == .content_overflow) found = true;
    }
    try testing.expect(found);
}

test "layout font size resolves consistently for measurement and rendering" {
    var state = try initEmptyDocumentState();
    defer state.deinit();
    var state_layout = LayoutFixture.init(&state);
    defer state_layout.deinit();

    const page = try state.addPage("Page");
    const object = try state.makeObject(page, "body", null, .text, .text, "one\ntwo");
    try setLayoutFontSize(&state, object, "20");
    try setTextSize(&state, object, "30");
    try setTextLineHeight(&state, object, "45");

    const node = state.getNode(object).?;
    try expectFloat(90, metrics.intrinsicHeight(try state_layout.work(), node, (try state_layout.frame(node.id)).*));
    const resolved = core.render_policy.resolve(&state, node);
    try expectFloat(20, resolved.text.?.font_size);
    try expectFloat(45, resolved.text.?.line_height);
}

test "layout metrics derive line height from explicit text size" {
    var state = try initEmptyDocumentState();
    defer state.deinit();
    var state_layout = LayoutFixture.init(&state);
    defer state_layout.deinit();

    const page = try state.addPage("Page");
    const object = try state.makeObject(page, "body", null, .text, .text, "one\ntwo");
    try setTextSize(&state, object, "30");

    const node = state.getNode(object).?;
    try expectFloat(87, metrics.intrinsicHeight(try state_layout.work(), node, (try state_layout.frame(node.id)).*));

    const resolved = core.render_policy.resolve(&state, node);
    try expectFloat(30, resolved.text.?.font_size);
    try expectFloat(43.5, resolved.text.?.line_height);
}

test "layout metrics honor explicit text and layout line heights" {
    var state = try initEmptyDocumentState();
    defer state.deinit();
    var state_layout = LayoutFixture.init(&state);
    defer state_layout.deinit();

    const page = try state.addPage("Page");
    const text_only = try state.makeObject(page, "text-only", null, .text, .text, "one\ntwo");
    try setTextSize(&state, text_only, "30");
    try setTextLineHeight(&state, text_only, "45");
    try expectFloat(90, metrics.intrinsicHeight(try state_layout.work(), state.getNode(text_only).?, (try state_layout.frame(text_only)).*));

    const layout_override = try state.makeObject(page, "layout-override", null, .text, .text, "one\ntwo");
    try setTextSize(&state, layout_override, "30");
    try setTextLineHeight(&state, layout_override, "45");
    try setLayoutLineHeight(&state, layout_override, "50");
    try expectFloat(100, metrics.intrinsicHeight(try state_layout.work(), state.getNode(layout_override).?, (try state_layout.frame(layout_override)).*));

    const resolved = core.render_policy.resolve(&state, state.getNode(layout_override).?);
    try expectFloat(50, resolved.text.?.line_height);
}

test "layout metrics treat zero line heights as automatic" {
    var state = try initEmptyDocumentState();
    defer state.deinit();
    var state_layout = LayoutFixture.init(&state);
    defer state_layout.deinit();

    const page = try state.addPage("Page");
    const object = try state.makeObject(page, "body", null, .text, .text, "one\ntwo");
    try setTextSize(&state, object, "30");
    try setTextLineHeight(&state, object, "0");
    try setLayoutLineHeight(&state, object, "0");

    const node = state.getNode(object).?;
    try expectFloat(87, metrics.intrinsicHeight(try state_layout.work(), node, (try state_layout.frame(node.id)).*));

    const resolved = core.render_policy.resolve(&state, node);
    try expectFloat(43.5, resolved.text.?.line_height);
}

test "render policy: invalid numeric properties fall back before rendering" {
    var state = try initEmptyDocumentState();
    defer state.deinit();
    var state_layout = LayoutFixture.init(&state);
    defer state_layout.deinit();

    const page = try state.addPage("Page");
    const object = try state.makeObject(page, "bad-numbers", null, .text, .text, "Hello");
    try setTextSize(&state, object, "-1");
    try setTextLineHeight(&state, object, "nan");
    try setTextMathScale(&state, object, "0");
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
    try expectFloat(1, text.math_scale);
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
    var state_layout = LayoutFixture.init(&state);
    defer state_layout.deinit();

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
    var state_layout = LayoutFixture.init(&state);
    defer state_layout.deinit();

    const page = try state.addPage("Page");
    const object = try state.makeObject(page, "body", null, .text, .text, "**Hello**");

    var resolved = core.render_policy.resolve(&state, state.getNode(object).?);
    try testing.expect(resolved.text.?.markdown_bold_color == null);

    try setTextMarkdownBoldColor(&state, object, "0.2,0.4,0.6");
    resolved = core.render_policy.resolve(&state, state.getNode(object).?);
    try expectColor(0.2, 0.4, 0.6, resolved.text.?.markdown_bold_color.?);
}

test "render policy: markdown underline style resolves as text paint" {
    var state = try initEmptyDocumentState();
    defer state.deinit();
    var state_layout = LayoutFixture.init(&state);
    defer state_layout.deinit();

    const page = try state.addPage("Page");
    const object = try state.makeObject(page, "body", null, .text, .text, "_Hello_");
    try setRecordPathValue(&state, object, "text", &.{ "markdown", "underline", "color" }, .{ .string = "0.2,0.4,0.6" });
    try setRecordPathValue(&state, object, "text", &.{ "markdown", "underline", "opacity" }, .{ .number = 0.35 });
    try setRecordPathValue(&state, object, "text", &.{ "markdown", "underline", "width" }, .{ .number = 5 });
    try setRecordPathValue(&state, object, "text", &.{ "markdown", "underline", "offset" }, .{ .number = 3 });
    try setRecordPathValue(&state, object, "text", &.{ "markdown", "underline", "dash" }, .{ .string = "8,4" });

    const resolved = core.render_policy.resolve(&state, state.getNode(object).?);
    const underline = resolved.text.?.markdown_underline;
    try expectColor(0.2, 0.4, 0.6, underline.color.?);
    try expectFloat(0.35, underline.opacity);
    try expectFloat(5, underline.width.?);
    try expectFloat(3, underline.offset);
    try expectFloat(8, underline.dash.?.on);
    try expectFloat(4, underline.dash.?.off);
}

test "render policy: markdown quote style resolves as text paint" {
    var state = try initEmptyDocumentState();
    defer state.deinit();
    var state_layout = LayoutFixture.init(&state);
    defer state_layout.deinit();

    const page = try state.addPage("Page");
    const object = try state.makeObject(page, "body", null, .text, .text, "> Hello");
    try setRecordPathValue(&state, object, "text", &.{ "markdown", "quote", "color" }, .{ .string = "0.2,0.3,0.4" });
    try setRecordPathValue(&state, object, "text", &.{ "markdown", "quote", "inset" }, .{ .number = 12 });
    try setRecordPathValue(&state, object, "text", &.{ "markdown", "quote", "pad_x" }, .{ .number = 18 });
    try setRecordPathValue(&state, object, "text", &.{ "markdown", "quote", "pad_y" }, .{ .number = 9 });
    try setRecordPathValue(&state, object, "text", &.{ "markdown", "quote", "fill" }, .{ .string = "0.9,0.8,0.7" });
    try setRecordPathValue(&state, object, "text", &.{ "markdown", "quote", "radius" }, .{ .number = 7 });
    try setRecordPathValue(&state, object, "text", &.{ "markdown", "quote", "bar_color" }, .{ .string = "0.6,0.2,0.1" });
    try setRecordPathValue(&state, object, "text", &.{ "markdown", "quote", "bar_width" }, .{ .number = 4 });
    try setRecordPathValue(&state, object, "text", &.{ "markdown", "quote", "bar_dash" }, .{ .string = "8,3" });

    const quote = core.render_policy.resolve(&state, state.getNode(object).?).text.?.markdown_quote;
    try expectColor(0.2, 0.3, 0.4, quote.color.?);
    try expectFloat(12, quote.inset);
    try expectFloat(18, quote.pad_x);
    try expectFloat(9, quote.pad_y);
    try expectColor(0.9, 0.8, 0.7, quote.fill.?);
    try expectFloat(7, quote.radius);
    try expectColor(0.6, 0.2, 0.1, quote.bar_color.?);
    try expectFloat(4, quote.bar_width);
    try expectFloat(8, quote.bar_dash.?.on);
    try expectFloat(3, quote.bar_dash.?.off);
}

test "layout metrics include markdown quote padding" {
    var state = try initEmptyDocumentState();
    defer state.deinit();
    var state_layout = LayoutFixture.init(&state);
    defer state_layout.deinit();

    const page = try state.addPage("Page");
    const compact = try state.makeObject(page, "compact", null, .text, .text, "> Quoted paragraph");
    const padded = try state.makeObject(page, "padded", null, .text, .text, "> Quoted paragraph");
    for ([_]model.NodeId{ compact, padded }) |object| {
        try setLayoutWrap(&state, object, "on");
        try setTextParse(&state, object, "block");
        try setTextFontFamily(&state, object, "Helvetica");
        try setTextSize(&state, object, "20");
        try setTextLineHeight(&state, object, "29");
        try setRecordPathValue(&state, object, "text", &.{ "markdown", "quote", "inset" }, .{ .number = 0 });
        try setRecordPathValue(&state, object, "text", &.{ "markdown", "quote", "pad_x" }, .{ .number = 0 });
        (try state_layout.frame(object)).*.width = 1000;
    }
    try setRecordPathValue(&state, compact, "text", &.{ "markdown", "quote", "pad_y" }, .{ .number = 0 });
    try setRecordPathValue(&state, padded, "text", &.{ "markdown", "quote", "pad_y" }, .{ .number = 12 });

    const compact_height = metrics.intrinsicHeight(try state_layout.work(), state.getNode(compact).?, (try state_layout.frame(compact)).*);
    const padded_height = metrics.intrinsicHeight(try state_layout.work(), state.getNode(padded).?, (try state_layout.frame(padded)).*);
    try expectFloat(24, padded_height - compact_height);
}

test "layout metrics wrap Markdown cells using annotated column widths" {
    var state = try initEmptyDocumentState();
    defer state.deinit();
    var state_layout = LayoutFixture.init(&state);
    defer state_layout.deinit();

    const page = try state.addPage("Page");
    const narrow = try state.makeObject(page, "narrow", null, .text, .text, "| Name | Value |\n| ---{75pt} | ---{1fr} |\n| Several words wrap inside the first column | 123 |");
    const wide = try state.makeObject(page, "wide", null, .text, .text, "| Name | Value |\n| ---{300pt} | ---{1fr} |\n| Several words wrap inside the first column | 123 |");
    for ([_]model.NodeId{ narrow, wide }) |object| {
        try setLayoutWrap(&state, object, "on");
        try setTextParse(&state, object, "block");
        try setTextFontFamily(&state, object, "Helvetica");
        try setTextSize(&state, object, "20");
        try setTextLineHeight(&state, object, "24");
        (try state_layout.frame(object)).*.width = 600;
    }
    const narrow_height = metrics.intrinsicHeight(try state_layout.work(), state.getNode(narrow).?, (try state_layout.frame(narrow)).*);
    const wide_height = metrics.intrinsicHeight(try state_layout.work(), state.getNode(wide).?, (try state_layout.frame(wide)).*);
    try testing.expect(narrow_height > wide_height);
}

test "render policy: markdown headings resolve their own text paint" {
    var state = try initEmptyDocumentState();
    defer state.deinit();
    var state_layout = LayoutFixture.init(&state);
    defer state_layout.deinit();

    const page = try state.addPage("Page");
    const object = try state.makeObject(page, "body", null, .text, .text, "## Heading");
    try setRecordPathValue(&state, object, "markdown_headings", &.{ "h2", "text", "size" }, .{ .number = 35 });
    try setRecordPathValue(&state, object, "markdown_headings", &.{ "h2", "text", "line_height" }, .{ .number = 42 });
    try setRecordPathValue(&state, object, "markdown_headings", &.{ "h2", "text", "color" }, .{ .string = "0.1,0.6,0.2" });
    try setRecordPathValue(&state, object, "markdown_headings", &.{ "h2", "text", "font", "family" }, .{ .string = "Avenir Next" });
    try setRecordPathValue(&state, object, "markdown_headings", &.{ "h2", "text", "font", "weight" }, .{ .number = 650 });
    try setRecordPathValue(&state, object, "markdown_headings", &.{ "h2", "text", "math", "scale" }, .{ .number = 1.3 });
    try setRecordPathValue(&state, object, "markdown_headings", &.{ "h2", "text", "math", "inline_spacing" }, .{ .number = 0.2 });
    try setRecordPathValue(&state, object, "markdown_headings", &.{ "h2", "text", "math", "display_gap" }, .{ .number = 2.4 });
    try setRecordPathValue(&state, object, "markdown_headings", &.{ "h2", "text", "math", "display_fit" }, .{ .string = "shrink" });
    try setRecordPathValue(&state, object, "markdown_headings", &.{ "h2", "text", "math", "align" }, .{ .string = "left" });
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
    try expectFloat(1.3, selected.math_scale);
    try expectFloat(0.2, selected.inline_math_spacing);
    try expectFloat(2.4, selected.display_math_gap);
    try testing.expectEqual(core.render_policy.MathFit.shrink, selected.display_math_fit);
    try testing.expectEqual(core.render_policy.HorizontalAlign.left, selected.math_align);
    try expectFloat(0.25, selected.emoji_spacing);
}

test "layout metrics use the markdown block gap after a heading" {
    var state = try initEmptyDocumentState();
    defer state.deinit();
    var state_layout = LayoutFixture.init(&state);
    defer state_layout.deinit();

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
        (try state_layout.frame(object)).*.width = 1000;
    }
    try setRecordNumberField(&state, compact, "text", "markdown.block_gap", 8);
    try setRecordNumberField(&state, relaxed, "text", "markdown.block_gap", 20);

    const compact_height = metrics.intrinsicHeight(try state_layout.work(), state.getNode(compact).?, (try state_layout.frame(compact)).*);
    const relaxed_height = metrics.intrinsicHeight(try state_layout.work(), state.getNode(relaxed).?, (try state_layout.frame(relaxed)).*);
    try expectFloat(12, relaxed_height - compact_height);
}

test "render policy: math alignment is read from each content style" {
    var state = try initEmptyDocumentState();
    defer state.deinit();
    const page = try state.addPage("Page");
    const text_object = try state.makeObject(page, "body", null, .text, .text, "$$x^2$$");
    try setRecordPathValue(&state, text_object, "text", &.{ "math", "align" }, .{ .enum_case = .{ .enum_name = "Align", .case_name = "left" } });
    const resolved_text = core.render_policy.resolve(&state, state.getNode(text_object).?);
    try testing.expectEqual(core.render_policy.HorizontalAlign.left, resolved_text.text.?.math_align);

    const invalid_text_object = try state.makeObject(page, "body", null, .text, .text, "$$z^2$$");
    try setRecordPathValue(&state, invalid_text_object, "text", &.{ "math", "align" }, .{ .string = "sideways" });
    const resolved_invalid = core.render_policy.resolve(&state, state.getNode(invalid_text_object).?);
    try testing.expectEqual(core.render_policy.HorizontalAlign.center, resolved_invalid.text.?.math_align);

    const latex_object = try state.makeObject(page, "latex", null, .asset, .latex, "$x^2$");
    try setRenderKind(&state, latex_object, "latex");
    try setRecordPathValue(&state, latex_object, "latex", &.{"align"}, .{ .enum_case = .{ .enum_name = "Align", .case_name = "right" } });
    const resolved_latex = core.render_policy.resolve(&state, state.getNode(latex_object).?);
    try testing.expectEqual(core.render_policy.HorizontalAlign.right, resolved_latex.latex.?.horizontal_align);
}

fn initPageGraph(state: *core.DocumentState, page_id: model.NodeId) !graph.PageLayoutGraph {
    var inputs = try core.layout.partition.Document.init(testing.allocator, state);
    defer inputs.deinit(testing.allocator);
    var fixture = LayoutFixture.init(state);
    defer fixture.deinit();
    for (inputs.pages) |page| {
        if (page.page_id == page_id) return graph.PageLayoutGraph.init(testing.allocator, try fixture.work(), page);
    }
    return error.UnknownNode;
}

test "layout graph: adjacency preserves shared parents and component order across allocation failures" {
    var state = try initEmptyDocumentState();
    defer state.deinit();
    var state_layout = LayoutFixture.init(&state);
    defer state_layout.deinit();
    const page = try state.addPage("page");
    const a = try state.makeObject(page, "a", null, .text, .text, "a");
    const b = try state.makeObject(page, "b", null, .text, .text, "b");
    const c = try state.makeObject(page, "c", null, .text, .text, "c");
    const left = try state.makeGroupWithOrigin(page, true, &.{ a, b }, null);
    const right = try state.makeGroupWithOrigin(page, true, &.{ b, c }, null);
    const outer = try state.makeGroupWithOrigin(page, true, &.{ left, right }, null);
    try state.constraints.addAnchor(state.allocator, b, .left, .{ .node = .{ .node_id = a, .anchor = .right } }, 30, null);
    try state.constraints.addAnchor(state.allocator, b, .left, .{ .node = .{ .node_id = a, .anchor = .right } }, 40, null);
    try state.constraints.addAnchor(state.allocator, b, .top, .{ .node = .{ .node_id = a, .anchor = .top } }, 0, null);
    try addDefaultAlignment(&state, c, b);
    var inputs = try core.layout.partition.Document.init(testing.allocator, &state);
    defer inputs.deinit(testing.allocator);
    try inspectIndexedPageGraph(testing.allocator, &state, inputs.pages[0], b, outer);
    try allocation_testing.checkAllAllocationFailures(testing.allocator, inspectIndexedPageGraph, .{ &state, inputs.pages[0], b, outer });
}

fn inspectIndexedPageGraph(allocator: std.mem.Allocator, state: *core.DocumentState, inputs: core.layout.partition.Page, target: model.NodeId, outer: model.NodeId) !void {
    var area = try core.layout.Workspace.init(allocator, state, inputs);
    defer area.deinit();
    var page_graph = try graph.PageLayoutGraph.init(allocator, &area, inputs);
    defer page_graph.deinit();
    try testing.expectEqual(@as(usize, 1), page_graph.default_alignment_constraints.len);
    try testing.expectEqualSlices(usize, &.{ 0, 1, 2 }, page_graph.targetConstraintIndexes(target));
    try testing.expectEqualSlices(usize, &.{ 3, 4 }, page_graph.parentGroupIndexes(target));
    try testing.expectEqual(@as(f32, 30), page_graph.constraintTargetingAnchor(target, .left).?.offset);
    try testing.expectEqual(@as(usize, 0), page_graph.targetConstraintIndexes(9999).len);
    try testing.expectEqual(@as(usize, 0), page_graph.parentGroupIndexes(9999).len);
    var workspace = try graph.AxisWorkspace.init(allocator, &area, &page_graph, .horizontal);
    defer workspace.deinit();
    var components = try workspace.dependencyComponents(allocator, &area, .{});
    defer components.deinit();
    try testing.expectEqualSlices(usize, &.{ 1, 2, 3, 4, 5 }, components.rootIndexes());
    try testing.expectEqualSlices(usize, &.{ 0, 1 }, components.memberIndexes(1));
    try testing.expectEqual(@as(?usize, 0), components.fallbackRootIndex(&area, 1));
    var subgraph = try page_graph.groupSubgraph(allocator, &area, outer);
    defer subgraph.deinit();
    try testing.expectEqualSlices(usize, &.{ 3, 0, 1, 4, 2 }, subgraph.indexes.items);
}

test "layout graph: normalized split constraints need no preliminary frames" {
    var state = try initEmptyDocumentState();
    defer state.deinit();
    const page = try state.addPage("Split");
    const a = try state.makeObject(page, "a", null, .text, .text, "A");
    const b = try state.makeObject(page, "b", null, .text, .text, "B");
    const c = try state.makeObject(page, "c", null, .text, .text, "C");
    const inner = try state.makeGroupWithOrigin(page, true, &.{ b, c }, null);
    const outer = try state.makeGroupWithOrigin(page, true, &.{ a, inner }, null);
    try state.setNodeFieldValue(inner, "split_axis", .{ .string = "vertical" });
    try state.setNodeFieldValue(outer, "split_axis", .{ .string = "horizontal" });
    try state.collectDefaultAlignments();
    var inputs = try core.layout.partition.Document.init(testing.allocator, &state);
    defer inputs.deinit(testing.allocator);
    try inspectSplitGraph(testing.allocator, &state, inputs.pages[0], inner, outer);
    try allocation_testing.checkAllAllocationFailures(testing.allocator, inspectSplitGraph, .{ &state, inputs.pages[0], inner, outer });
}

fn inspectSplitGraph(allocator: std.mem.Allocator, state: *core.DocumentState, inputs: core.layout.partition.Page, inner: model.NodeId, outer: model.NodeId) !void {
    var area = try core.layout.Workspace.init(allocator, state, inputs);
    defer area.deinit();
    var split = try graph.PageLayoutGraph.init(allocator, &area, inputs);
    defer split.deinit();
    try testing.expect(split.hasSplitChildren(outer));
    try testing.expect(split.hasSplitChildren(inner));
    for (split.constraints) |constraint| try testing.expect(constraint.role != .size);
    try testing.expectEqual(@as(usize, 3), split.default_alignment_constraints.len);
    for (split.default_alignment_constraints) |constraint| {
        try testing.expect(constraint.group_split);
        const parent = constraint.source.node.node_id;
        try testing.expect(parent == inner or parent == outer);
        try testing.expectEqual(if (parent == inner) model.Anchor.left else model.Anchor.top, constraint.target_anchor);
    }
}

test "layout groups: required split height does not assign page coordinates" {
    for ([_][]const u8{ "horizontal", "vertical" }) |direction| {
        var state = try initEmptyDocumentState();
        defer state.deinit();
        var fixture = LayoutFixture.init(&state);
        defer fixture.deinit();
        const page = try state.addPage("Measured split");
        const a = try state.makeObject(page, "a", null, .text, .text, "A");
        const b = try state.makeObject(page, "b", null, .text, .text, "B");
        const group = try state.makeGroupWithOrigin(page, true, &.{ a, b }, null);
        try state.setNodeFieldValue(group, "split_axis", .{ .string = direction });
        try setRecordPathValue(&state, group, "chrome", &.{"pad_y"}, .{ .number = 5 });
        try state.collectDefaultAlignments();
        (try fixture.frame(a)).height = 40;
        (try fixture.frame(b)).height = 100;
        var page_graph = try initPageGraph(&state, page);
        defer page_graph.deinit();
        var vertical = try graph.AxisWorkspace.init(testing.allocator, try fixture.work(), &page_graph, .vertical);
        defer vertical.deinit();
        _ = try core.layout.groups.updateAxisStates(try fixture.work(), &vertical);
        const measured = vertical.stateOf(group).?.*;
        try expectFloat(if (std.mem.eql(u8, direction, "horizontal")) 110 else 242, measured.size.?);
        try testing.expect(measured.size_is_default);
        try testing.expect(measured.start == null and measured.end == null and measured.center == null);
    }
}

const WidthSensitiveMeasurement = struct {
    target: model.NodeId,
    last_width: f32 = 0,

    fn measure(context: *anyopaque, _: *core.layout.Workspace, node: *const model.Node, width: f32, mode: model.LayoutMeasurementMode) !?model.LayoutMeasurement {
        const self: *@This() = @ptrCast(@alignCast(context));
        if (node.id != self.target) return null;
        if (mode == .natural) return .{ .width = 48, .height = 36 };
        self.last_width = width;
        return .{ .width = width, .height = if (width < 48) @as(f32, 72) else 36 };
    }
};

fn expectHeightAtFinalWidth(width: f32, wrap: []const u8) !void {
    var state = try initEmptyDocumentState();
    defer state.deinit();
    var state_layout = LayoutFixture.init(&state);
    defer state_layout.deinit();
    const page = try state.addPage("Final width");
    const object = try state.makeObject(page, "body", null, .text, .text, "width-dependent content");
    const follower = try state.makeObject(page, "following", null, .text, .text, "following content");
    try setLayoutWrap(&state, object, wrap);
    try state.constraints.addAnchor(state.allocator, object, .left, .{ .page = .left }, 0, .{ .label = "body-left" });
    try state.constraints.addAnchor(state.allocator, object, .right, .{ .node = .{ .node_id = object, .anchor = .left } }, width, .{ .label = "body-width" });
    try state.constraints.addAnchor(state.allocator, object, .top, .{ .page = .top }, -100, .{ .label = "body-top" });
    try state.constraints.addAnchor(state.allocator, follower, .top, .{ .node = .{ .node_id = object, .anchor = .bottom } }, -10, .{ .label = "following-top" });
    var measurement = WidthSensitiveMeasurement{ .target = object };
    try solveDocumentStateWithOptions(&state_layout, null, .{ .measurement_provider = .{ .context = &measurement, .measure = WidthSensitiveMeasurement.measure } });
    const frame = (try state_layout.frame(object)).*;
    try testing.expectEqual(width, frame.width);
    try testing.expectEqual(width, measurement.last_width);
    try expectFloat(72, frame.height);
    const next = (try state_layout.frame(follower)).*;
    try expectFloat(core.layout.Defaults.height - 100 - 72 - 10, next.y + next.height);
}

test "layout solver: subpixel width changes invalidate height before vertical solving" {
    try expectHeightAtFinalWidth(47.995, "on");
}

test "layout solver: width-dependent height is independent of the outer wrap policy" {
    try expectHeightAtFinalWidth(24, "off");
}

fn finalizeWithAllocationFailures(allocator: std.mem.Allocator, conflict: bool) !void {
    var state = try initEmptyDocumentStateWithAllocator(allocator);
    defer state.deinit();
    const page = try state.addPage("Page");
    const object = try state.makeObject(page, "body", null, .text, .text, "");
    try state.constraints.addAnchor(state.allocator, object, .left, .{ .page = .left }, 100, null);
    if (conflict) try state.constraints.addAnchor(state.allocator, object, .left, .{ .page = .left }, 120, null);
    var result = try solver.finalizeDocument(&state, null, .{ .jobs = 1 });
    defer result.deinit(allocator);
    try testing.expectEqual(@as(usize, 1), result.pages.len);
    try testing.expectEqual(@as(usize, 0), state.diagnostics.entries.items.len);
    if (conflict) {
        try testing.expectError(error.ConstraintConflict, result.validate());
        try testing.expect(result.failureCount() > 0);
        try testing.expect(result.pages[0].constraint_failures[0].propagation != null);
    } else {
        try result.validate();
        try expectFloat(100, result.nodeFrame(object).?.x);
    }
}

test "layout solver: finalization releases results on every allocation failure" {
    try allocation_testing.checkAllAllocationFailures(testing.allocator, finalizeWithAllocationFailures, .{false});
    try allocation_testing.checkAllAllocationFailures(testing.allocator, finalizeWithAllocationFailures, .{true});
}

test "layout results preserve source and prior generations across sequential and parallel solves" {
    var state = try initEmptyDocumentState();
    defer state.deinit();
    var objects: [3]model.NodeId = undefined;
    for (&objects, 0..) |*object, index| {
        const page = try state.addPage("Page");
        object.* = try state.makeObject(page, "body", null, .text, .text, "Hello");
        try state.constraints.addAnchor(state.allocator, object.*, .left, .{ .page = .left }, if (index == 0) -40 else 60, .{ .label = "left" });
        if (index == 1) try state.constraints.addAnchor(state.allocator, object.*, .left, .{ .page = .left }, 80, .{ .label = "conflicting-left" });
    }
    const node_count = state.graph.nodes.items.len;
    var sequential = try solver.solveDocument(&state, null, .{ .jobs = 1 });
    defer sequential.deinit(testing.allocator);
    var parallel = try solver.solveDocument(&state, null, .{ .jobs = 3 });
    defer parallel.deinit(testing.allocator);
    try testing.expectEqualDeep(sequential.pages, parallel.pages);
    try testing.expectEqual(node_count, state.graph.nodes.items.len);
    try testing.expectEqual(@as(usize, 0), state.diagnostics.entries.items.len);
    try testing.expectEqual(@as(usize, 0), state.diagnostics.constraint_failures.items.len);
    try testing.expect(sequential.pages[0].diagnostics.len > 0);
    try testing.expectError(error.ConstraintConflict, sequential.pages[1].validate());
    try sequential.pages[2].validate();
    const old_frame = sequential.nodeFrame(objects[2]).?;
    state.constraints.active.items[3].offset = 90;
    var next = try solver.finalizeDocument(&state, null, .{ .jobs = 1 });
    defer next.deinit(testing.allocator);
    try testing.expectEqualDeep(old_frame, sequential.nodeFrame(objects[2]).?);
    try expectFloat(90, next.nodeFrame(objects[2]).?.x);
}
