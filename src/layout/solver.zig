const std = @import("std");
const model = @import("model");
const diagnostics = @import("diagnostics.zig");
const metrics = @import("metrics.zig");
const style_defaults = @import("style.zig");

const NodeId = model.NodeId;
const Node = model.Node;
const Role = model.Role;
const Axis = model.Axis;
const AxisState = model.AxisState;
const Anchor = model.Anchor;
const Constraint = model.Constraint;
const ConstraintSource = model.ConstraintSource;
const Frame = model.Frame;
const PageLayout = model.PageLayout;
const TextStyle = model.TextStyle;
const roleEq = model.roleEq;
const GroupRole = model.GroupRole;

const VerticalFallbackPolicy = enum {
    top_flow,
    center_stack,
};

pub fn solveLayout(ir: anytype) !void {
    for (ir.nodes.items) |*node| {
        switch (node.kind) {
            .document => {},
            .page => {
                node.frame = .{
                    .x = 0,
                    .y = 0,
                    .width = PageLayout.width,
                    .height = PageLayout.height,
                    .x_set = true,
                    .y_set = true,
                };
            },
            .object, .derived => {
                node.frame.x = 0;
                node.frame.y = 0;
                node.frame.x_set = false;
                node.frame.y_set = false;
                node.frame.width = intrinsicWidth(ir, node);
                node.frame.height = intrinsicHeight(ir, node);
            },
        }
    }

    for (ir.page_order.items) |page_id| {
        try solvePageLayout(ir, page_id);
    }
}

pub fn styleForNode(ir: anytype, node: *const Node) TextStyle {
    return style_defaults.styleForNode(ir, node);
}

pub fn intrinsicWidth(ir: anytype, node: *const Node) f32 {
    return metrics.intrinsicWidth(ir, node);
}

pub fn intrinsicHeight(ir: anytype, node: *const Node) f32 {
    return metrics.intrinsicHeight(ir, node);
}

pub fn shouldWrapNode(ir: anytype, node: *const Node) bool {
    return metrics.shouldWrapNode(ir, node);
}

pub fn lineCount(text: []const u8) usize {
    return metrics.lineCount(text);
}

fn solvePageLayout(ir: anytype, page_id: NodeId) !void {
    const children = ir.contains.get(page_id) orelse return;
    const child_ids = children.items;

    const horizontal = try ir.allocator.alloc(AxisState, child_ids.len);
    defer ir.allocator.free(horizontal);
    const vertical = try ir.allocator.alloc(AxisState, child_ids.len);
    defer ir.allocator.free(vertical);

    for (child_ids, horizontal, vertical) |child_id, *h_state, *v_state| {
        const node = ir.getNode(child_id) orelse return error.UnknownNode;
        if (isGroupNode(node)) {
            h_state.* = .{};
            v_state.* = .{};
            continue;
        }
        const has_h_target = hasAxisTargetConstraint(ir, child_id, .horizontal);
        const has_v_target = hasAxisTargetConstraint(ir, child_id, .vertical);
        h_state.* = .{};
        v_state.* = .{};
        if (!has_h_target and node.frame.x_set) {
            h_state.size = node.frame.width;
            h_state.start = node.frame.x;
            h_state.end = node.frame.x + node.frame.width;
            h_state.center = node.frame.x + node.frame.width / 2;
        }
        if (!has_v_target and node.frame.y_set) {
            v_state.size = node.frame.height;
            v_state.start = node.frame.y;
            v_state.end = node.frame.y + node.frame.height;
            v_state.center = node.frame.y + node.frame.height / 2;
        }
    }

    try solvePageAxis(ir, page_id, child_ids, horizontal, .horizontal, &.{});

    var horizontal_fallback = try buildHorizontalFallbackConstraints(ir, page_id, child_ids, horizontal);
    defer horizontal_fallback.deinit(ir.allocator);
    try solvePageAxis(ir, page_id, child_ids, horizontal, .horizontal, horizontal_fallback.items);
    try finalizeHorizontalGroupStates(ir, page_id, child_ids, horizontal, horizontal_fallback.items);
    applySolvedHorizontalFrames(ir, child_ids, horizontal) catch return error.UnknownNode;
    try propagateTargetedGroupWidths(ir, child_ids, horizontal, &.{});

    try solvePageAxis(ir, page_id, child_ids, vertical, .vertical, &.{});
    var vertical_fallback = try buildVerticalFallbackConstraints(ir, page_id, child_ids, vertical);
    defer vertical_fallback.deinit(ir.allocator);
    try solvePageAxis(ir, page_id, child_ids, vertical, .vertical, vertical_fallback.items);

    for (child_ids, vertical) |child_id, v_state| {
        const node = ir.getNode(child_id) orelse return error.UnknownNode;
        node.frame.height = v_state.size orelse node.frame.height;
        node.frame.y_set = false;
        if (v_state.start) |y| {
            node.frame.y = y;
            node.frame.y_set = true;
        }
    }

    try diagnostics.collectPageDiagnostics(ir, page_id, child_ids);
}

fn applySolvedHorizontalFrames(ir: anytype, child_ids: []const NodeId, horizontal: []const AxisState) !void {
    for (child_ids, horizontal) |child_id, h_state| {
        const node = ir.getNode(child_id) orelse return error.UnknownNode;
        node.frame.width = h_state.size orelse node.frame.width;
        if (shouldWrapNode(ir, node)) {
            node.frame.height = intrinsicHeight(ir, node);
        }
        node.frame.x_set = false;
        if (h_state.start) |x| {
            node.frame.x = x;
            node.frame.x_set = true;
        }
    }
}

fn finalizeHorizontalGroupStates(ir: anytype, page_id: NodeId, child_ids: []const NodeId, states: []AxisState, extra_constraints: []const Constraint) !void {
    var pass: usize = 0;
    while (pass < 8) : (pass += 1) {
        var changed = false;
        changed = (try capDefaultWrappedHorizontalWidths(ir, child_ids, states)) or changed;
        changed = (try applyGroupTargetConstraints(ir, page_id, child_ids, states, .horizontal, extra_constraints)) or changed;
        changed = (try updateGroupAxisStates(ir, child_ids, states, .horizontal, extra_constraints)) or changed;
        if (!changed) break;
    }
}

fn capDefaultWrappedHorizontalWidths(ir: anytype, child_ids: []const NodeId, states: []AxisState) !bool {
    var changed = false;
    for (child_ids, states) |child_id, *state| {
        if (!state.size_is_default) continue;
        if (state.start == null or state.size == null) continue;
        if (state.end_source != null or state.size_source != null) continue;

        const node = ir.getNode(child_id) orelse return error.UnknownNode;
        if (isGroupNode(node)) continue;
        if (!shouldWrapNode(ir, node)) continue;

        const style = styleForNode(ir, node);
        const max_right = PageLayout.width - style.default_right_inset;
        const capped_width = @max(@as(f32, 1.0), max_right - state.start.?);
        if (capped_width >= state.size.? - 0.01) continue;

        state.size = capped_width;
        state.end = state.start.? + capped_width;
        state.center = state.start.? + capped_width / 2;
        state.end_source = null;
        state.center_source = null;
        changed = true;
    }
    return changed;
}

fn solvePageAxis(ir: anytype, page_id: NodeId, child_ids: []const NodeId, states: []AxisState, axis: Axis, extra_constraints: []const Constraint) !void {
    try runPageAxisPass(ir, page_id, child_ids, states, axis, extra_constraints);

    for (child_ids, states) |child_id, *state| {
        if (state.size == null) {
            const node = ir.getNode(child_id) orelse return error.UnknownNode;
            state.size = switch (axis) {
                .horizontal => node.frame.width,
                .vertical => node.frame.height,
            };
            state.size_is_default = true;
        }
    }

    try runPageAxisPass(ir, page_id, child_ids, states, axis, extra_constraints);
}

fn hasAxisTargetConstraint(ir: anytype, node_id: NodeId, axis: Axis) bool {
    for (ir.constraints.items) |constraint| {
        if (constraint.target_node != node_id) continue;
        if (anchorAxis(constraint.target_anchor) != axis) continue;
        return true;
    }
    return false;
}

fn runPageAxisPass(ir: anytype, page_id: NodeId, child_ids: []const NodeId, states: []AxisState, axis: Axis, extra_constraints: []const Constraint) !void {
    var pass: usize = 0;
    while (pass < 32) : (pass += 1) {
        var changed = false;
        var local_pass: usize = 0;
        while (local_pass < 32) : (local_pass += 1) {
            var local_changed = false;

            for (states) |*state| {
                local_changed = (try reconcileAxisStateLocalized(ir, page_id, state)) or local_changed;
            }

            for (ir.constraints.items) |constraint| {
                if (constraintTargetsGroup(ir, constraint)) continue;
                if (constraintUsesGroupSource(ir, constraint)) continue;
                local_changed = (try applyAxisConstraint(ir, page_id, child_ids, states, axis, constraint, false)) or local_changed;
            }

            for (extra_constraints) |constraint| {
                if (constraintTargetsGroup(ir, constraint)) continue;
                if (constraintUsesGroupSource(ir, constraint)) continue;
                local_changed = (try applyAxisConstraint(ir, page_id, child_ids, states, axis, constraint, true)) or local_changed;
            }

            changed = local_changed or changed;
            if (!local_changed) break;
        }

        changed = (try updateGroupAxisStates(ir, child_ids, states, axis, extra_constraints)) or changed;
        changed = (try applyGroupTargetConstraints(ir, page_id, child_ids, states, axis, extra_constraints)) or changed;

        for (ir.constraints.items) |constraint| {
            if (!constraintUsesGroupSource(ir, constraint)) continue;
            changed = (try applyAxisConstraint(ir, page_id, child_ids, states, axis, constraint, false)) or changed;
        }

        for (extra_constraints) |constraint| {
            if (!constraintUsesGroupSource(ir, constraint)) continue;
            changed = (try applyAxisConstraint(ir, page_id, child_ids, states, axis, constraint, true)) or changed;
        }

        if (!changed) break;
    }
}

fn reconcileAxisStateLocalized(ir: anytype, page_id: NodeId, state: *AxisState) !bool {
    return reconcileAxisState(state) catch |err| switch (err) {
        error.ConstraintConflict, error.NegativeConstraintSize => blk: {
            const incoming = state.size_source orelse state.end_source orelse state.start_source orelse state.center_source;
            const existing = pickReconcileExistingSource(state, incoming);
            if (incoming) |c| {
                const kind: model.ConstraintFailureKind = if (err == error.ConstraintConflict) .conflict else .negative_size;
                ir.noteConstraintFailure(page_id, c, existing, kind);
            }
            break :blk false;
        },
    };
}

fn pickReconcileExistingSource(state: *const AxisState, incoming: ?Constraint) ?Constraint {
    const candidates = [_]?Constraint{ state.size_source, state.start_source, state.end_source, state.center_source };
    for (candidates) |candidate| {
        const c = candidate orelse continue;
        if (incoming) |inc| {
            if (constraintsSame(c, inc)) continue;
        }
        return c;
    }
    return null;
}

fn constraintsSame(a: Constraint, b: Constraint) bool {
    if (a.target_node != b.target_node) return false;
    if (a.target_anchor != b.target_anchor) return false;
    if (a.offset != b.offset) return false;
    return switch (a.source) {
        .page => |a_anchor| switch (b.source) {
            .page => |b_anchor| a_anchor == b_anchor,
            .node => false,
        },
        .node => |a_node| switch (b.source) {
            .page => false,
            .node => |b_node| a_node.node_id == b_node.node_id and a_node.anchor == b_node.anchor,
        },
    };
}

fn buildHorizontalFallbackConstraints(ir: anytype, page_id: NodeId, child_ids: []const NodeId, states: []const AxisState) !std.ArrayList(Constraint) {
    var constraints = std.ArrayList(Constraint).empty;
    if (child_ids.len == 0) return constraints;

    const allocator = ir.allocator;
    const parent = try allocator.alloc(usize, child_ids.len);
    defer allocator.free(parent);
    const page_dependent = try allocator.alloc(bool, child_ids.len);
    defer allocator.free(page_dependent);
    try initAxisComponents(ir, page_id, child_ids, states, .horizontal, parent, page_dependent);

    const seen = try allocator.alloc(bool, child_ids.len);
    defer allocator.free(seen);
    @memset(seen, false);

    for (child_ids, 0..) |_, index| {
        const root = componentFind(parent, index);
        if (seen[root]) continue;
        seen[root] = true;
        if (page_dependent[root]) continue;

        const root_index = componentAxisFallbackRootIndex(ir, child_ids, states, parent, root, .horizontal) orelse continue;
        const root_id = child_ids[root_index];
        const root_node = ir.getNode(root_id) orelse return error.UnknownNode;
        try constraints.append(ir.allocator, .{
            .target_node = root_id,
            .target_anchor = .left,
            .source = .{ .page = .left },
            .offset = styleForNode(ir, root_node).default_x,
        });
    }
    return constraints;
}

fn buildVerticalFallbackConstraints(ir: anytype, page_id: NodeId, child_ids: []const NodeId, states: []const AxisState) !std.ArrayList(Constraint) {
    return switch (verticalFallbackPolicy(ir, page_id)) {
        .top_flow => buildTopFlowVerticalFallbackConstraints(ir, page_id, child_ids, states),
        .center_stack => buildCenterStackVerticalFallbackConstraints(ir, page_id, child_ids, states),
    };
}

fn verticalFallbackPolicy(ir: anytype, page_id: NodeId) VerticalFallbackPolicy {
    const page = ir.getNode(page_id) orelse return .top_flow;
    const value = model.nodeProperty(page, "layout_v") orelse blk: {
        const document = ir.getNode(ir.document_id) orelse return .top_flow;
        break :blk model.nodeProperty(document, "layout_v") orelse return .top_flow;
    };
    if (std.mem.eql(u8, value, "center") or std.mem.eql(u8, value, "center_stack")) return .center_stack;
    return .top_flow;
}

fn buildTopFlowVerticalFallbackConstraints(ir: anytype, page_id: NodeId, child_ids: []const NodeId, states: []const AxisState) !std.ArrayList(Constraint) {
    var constraints = std.ArrayList(Constraint).empty;
    if (child_ids.len == 0) return constraints;

    const allocator = ir.allocator;
    const parent = try allocator.alloc(usize, child_ids.len);
    defer allocator.free(parent);
    const page_dependent = try allocator.alloc(bool, child_ids.len);
    defer allocator.free(page_dependent);
    try initAxisComponents(ir, page_id, child_ids, states, .vertical, parent, page_dependent);

    const local_tops = try allocator.alloc(?f32, child_ids.len);
    defer allocator.free(local_tops);
    @memset(local_tops, null);

    var units = std.ArrayList(VerticalComponentUnit).empty;
    defer units.deinit(allocator);
    try collectVerticalComponentUnits(ir, page_id, child_ids, states, parent, page_dependent, local_tops, .top_flow, &units);

    const seen = try allocator.alloc(bool, child_ids.len);
    defer allocator.free(seen);
    @memset(seen, false);

    var current_source: ConstraintSource = .{ .page = .top };
    var current_offset: f32 = PageLayout.flow_top - PageLayout.height;
    var current_top_value: f32 = PageLayout.flow_top;

    for (child_ids, states, 0..) |child_id, state, index| {
        const node = ir.getNode(child_id) orelse return error.UnknownNode;
        if (isGroupNode(node)) continue;
        if (roleEq(node.role, "page_number")) continue;

        const root = componentFind(parent, index);
        if (page_dependent[root]) {
            const spacing = styleForNode(ir, node).spacing_after;
            if (state.start) |bottom| {
                const next_top = bottom - spacing;
                if (next_top < current_top_value) {
                    current_source = .{ .node = .{ .node_id = child_id, .anchor = .bottom } };
                    current_offset = -spacing;
                    current_top_value = next_top;
                }
            }
            continue;
        }

        if (seen[root]) continue;
        seen[root] = true;

        const unit = findVerticalComponentUnit(units.items, root) orelse continue;
        try appendVerticalComponentPlacementConstraints(allocator, &constraints, child_ids, parent, local_tops, root, current_source, current_offset, unit.local_top);

        current_source = .{ .node = .{ .node_id = child_ids[unit.bottom_index], .anchor = .bottom } };
        current_offset = -unit.spacing_after;
        current_top_value = current_top_value - unit.height - unit.spacing_after;
    }

    return constraints;
}

const VerticalComponentUnit = struct {
    component_root: usize,
    root_index: usize,
    bottom_index: usize,
    local_top: f32,
    height: f32,
    spacing_after: f32,
};

fn buildCenterStackVerticalFallbackConstraints(ir: anytype, page_id: NodeId, child_ids: []const NodeId, states: []const AxisState) !std.ArrayList(Constraint) {
    var constraints = std.ArrayList(Constraint).empty;
    if (child_ids.len == 0) return constraints;

    const allocator = ir.allocator;
    const parent = try allocator.alloc(usize, child_ids.len);
    defer allocator.free(parent);
    const page_dependent = try allocator.alloc(bool, child_ids.len);
    defer allocator.free(page_dependent);
    try initAxisComponents(ir, page_id, child_ids, states, .vertical, parent, page_dependent);

    const local_tops = try allocator.alloc(?f32, child_ids.len);
    defer allocator.free(local_tops);
    @memset(local_tops, null);

    var units = std.ArrayList(VerticalComponentUnit).empty;
    defer units.deinit(allocator);
    try collectVerticalComponentUnits(ir, page_id, child_ids, states, parent, page_dependent, local_tops, .center_stack, &units);
    if (units.items.len == 0) return constraints;

    var total_height: f32 = 0;
    for (units.items, 0..) |unit, index| {
        total_height += unit.height;
        if (index != units.items.len - 1) total_height += unit.spacing_after;
    }

    var current_top = PageLayout.height / 2 + total_height / 2;
    for (units.items) |unit| {
        try appendVerticalComponentPlacementConstraints(
            allocator,
            &constraints,
            child_ids,
            parent,
            local_tops,
            unit.component_root,
            .{ .page = .bottom },
            current_top - unit.local_top,
            0,
        );
        current_top -= unit.height + unit.spacing_after;
    }

    return constraints;
}

fn initAxisComponents(
    ir: anytype,
    page_id: NodeId,
    child_ids: []const NodeId,
    states: []const AxisState,
    axis: Axis,
    parent: []usize,
    page_dependent: []bool,
) !void {
    for (parent, page_dependent, 0..) |*p, *dependent, index| {
        p.* = index;
        dependent.* = false;
    }
    if (axis == .vertical) {
        try unionContainmentComponents(ir, child_ids, parent, page_dependent);
    }
    try unionAxisConstraintComponents(ir, page_id, child_ids, states, axis, parent, page_dependent);
}

fn collectVerticalComponentUnits(
    ir: anytype,
    page_id: NodeId,
    child_ids: []const NodeId,
    states: []const AxisState,
    parent: []usize,
    page_dependent: []const bool,
    local_tops: []?f32,
    policy: VerticalFallbackPolicy,
    units: *std.ArrayList(VerticalComponentUnit),
) !void {
    var seen = try ir.allocator.alloc(bool, child_ids.len);
    defer ir.allocator.free(seen);
    @memset(seen, false);

    for (child_ids, 0..) |_, index| {
        const root = componentFind(parent, index);
        if (seen[root]) continue;
        seen[root] = true;
        if (page_dependent[root]) continue;

        const unit = try computeVerticalComponentUnit(ir, page_id, child_ids, states, parent, root, local_tops, policy) orelse continue;
        try units.append(ir.allocator, unit);
    }
}

fn appendVerticalComponentPlacementConstraints(
    allocator: std.mem.Allocator,
    constraints: *std.ArrayList(Constraint),
    child_ids: []const NodeId,
    parent: []usize,
    local_tops: []const ?f32,
    component_root: usize,
    source: ConstraintSource,
    base_offset: f32,
    local_top_base: f32,
) !void {
    for (child_ids, 0..) |child_id, index| {
        if (componentFind(parent, index) != component_root) continue;
        const local_top = local_tops[index] orelse continue;
        try constraints.append(allocator, .{
            .target_node = child_id,
            .target_anchor = .top,
            .source = source,
            .offset = base_offset - local_top_base + local_top,
        });
    }
}

fn findVerticalComponentUnit(units: []const VerticalComponentUnit, component_root: usize) ?VerticalComponentUnit {
    for (units) |unit| {
        if (unit.component_root == component_root) return unit;
    }
    return null;
}

fn unionContainmentComponents(ir: anytype, child_ids: []const NodeId, parent: []usize, page_dependent: []bool) !void {
    for (child_ids, 0..) |node_id, index| {
        const node = ir.getNode(node_id) orelse return error.UnknownNode;
        if (!isGroupNode(node)) continue;
        const children = ir.childrenOf(node_id) orelse continue;
        for (children) |child_id| {
            const child_index = indexOfNode(child_ids, child_id) orelse continue;
            componentUnion(parent, page_dependent, index, child_index);
        }
    }
}

fn unionAxisConstraintComponents(
    ir: anytype,
    page_id: NodeId,
    child_ids: []const NodeId,
    states: []const AxisState,
    axis: Axis,
    parent: []usize,
    page_dependent: []bool,
) !void {
    for (child_ids, states, 0..) |child_id, state, index| {
        const node = ir.getNode(child_id) orelse return error.UnknownNode;
        if (roleEq(node.role, "page_number") or state.start != null or state.end != null or state.center != null) {
            page_dependent[componentFind(parent, index)] = true;
        }
    }

    for (ir.constraints.items) |constraint| {
        if (anchorAxis(constraint.target_anchor) != axis) continue;
        if (selfReferentialSize(constraint, axis) != null) continue;
        if (axis == .vertical and constraintTargetsGroup(ir, constraint)) continue;
        const target_page = ir.parentPageOf(constraint.target_node) orelse continue;
        if (target_page != page_id) continue;
        const target_index = indexOfNode(child_ids, constraint.target_node) orelse continue;

        switch (constraint.source) {
            .page => page_dependent[componentFind(parent, target_index)] = true,
            .node => |source| {
                if (anchorAxis(source.anchor) != axis) continue;
                const source_index = indexOfNode(child_ids, source.node_id) orelse {
                    page_dependent[componentFind(parent, target_index)] = true;
                    continue;
                };
                componentUnion(parent, page_dependent, target_index, source_index);
            },
        }
    }
}

fn computeVerticalComponentUnit(
    ir: anytype,
    page_id: NodeId,
    child_ids: []const NodeId,
    states: []const AxisState,
    parent: []usize,
    component_root: usize,
    local_tops: []?f32,
    policy: VerticalFallbackPolicy,
) !?VerticalComponentUnit {
    const root_index = componentFallbackRootIndex(ir, child_ids, parent, component_root) orelse return null;

    const temp = try ir.allocator.alloc(AxisState, states.len);
    defer ir.allocator.free(temp);
    @memcpy(temp, states);
    _ = setAxisAnchor(&temp[root_index], .top, 0, null) catch return null;

    var local_fallback = try buildComponentLocalTopFlowConstraints(ir, child_ids, states, parent, component_root, root_index);
    defer local_fallback.deinit(ir.allocator);
    try runPageAxisPass(ir, page_id, child_ids, temp, .vertical, local_fallback.items);
    if (policy == .center_stack) {
        try centerDirectChildGroupsInComponent(ir, child_ids, temp, parent, component_root);
    }

    var local_bottom: ?f32 = null;
    var local_top: ?f32 = null;
    var bottom_index: ?usize = null;
    for (child_ids, 0..) |child_id, index| {
        if (componentFind(parent, index) != component_root) continue;
        const node = ir.getNode(child_id) orelse return error.UnknownNode;
        if (roleEq(node.role, "page_number")) continue;
        if (isGroupNode(node) and (temp[index].start == null or temp[index].end == null)) continue;
        const start = temp[index].start orelse return null;
        const end = temp[index].end orelse return null;
        if (index == root_index or !hasAxisTargetConstraint(ir, child_id, .vertical)) {
            local_tops[index] = end;
        }
        if (local_bottom == null or start < local_bottom.?) {
            local_bottom = start;
            bottom_index = index;
        }
        if (local_top == null or end > local_top.?) local_top = end;
    }
    if (local_bottom == null or local_top == null) return null;

    const spacing_source_index = bottom_index orelse root_index;
    const spacing_source = ir.getNode(child_ids[spacing_source_index]) orelse return error.UnknownNode;
    return .{
        .component_root = component_root,
        .root_index = root_index,
        .bottom_index = spacing_source_index,
        .local_top = local_top.?,
        .height = local_top.? - local_bottom.?,
        .spacing_after = styleForNode(ir, spacing_source).spacing_after,
    };
}

fn centerDirectChildGroupsInComponent(
    ir: anytype,
    child_ids: []const NodeId,
    states: []AxisState,
    parent: []usize,
    component_root: usize,
) !void {
    var pass: usize = 0;
    while (pass < 8) : (pass += 1) {
        var changed = false;
        changed = (try updateGroupAxisStates(ir, child_ids, states, .vertical, &.{})) or changed;

        for (child_ids, 0..) |group_id, group_index| {
            if (componentFind(parent, group_index) != component_root) continue;
            const group_node = ir.getNode(group_id) orelse return error.UnknownNode;
            if (!isGroupNode(group_node)) continue;
            const group_state = states[group_index];
            const group_center = group_state.center orelse continue;
            const children = ir.childrenOf(group_id) orelse continue;

            for (children) |child_id| {
                const child_index = indexOfNode(child_ids, child_id) orelse continue;
                if (componentFind(parent, child_index) != component_root) continue;
                const child_node = ir.getNode(child_id) orelse return error.UnknownNode;
                if (!isGroupNode(child_node)) continue;
                if (groupHasTargetConstraint(ir, child_id, .vertical, &.{})) continue;
                const child_center = states[child_index].center orelse continue;
                const delta = group_center - child_center;
                changed = shiftAxisState(&states[child_index], delta) or changed;
                changed = (try translateGroupSubtree(ir, child_ids, states, child_id, delta)) or changed;
            }
        }

        if (!changed) break;
    }
}

fn buildComponentLocalTopFlowConstraints(
    ir: anytype,
    child_ids: []const NodeId,
    states: []const AxisState,
    parent: []usize,
    component_root: usize,
    root_index: usize,
) !std.ArrayList(Constraint) {
    var constraints = std.ArrayList(Constraint).empty;
    try appendLocalTopFlowForPageChildren(ir, child_ids, states, parent, component_root, root_index, &constraints);

    for (child_ids, 0..) |group_id, group_index| {
        if (componentFind(parent, group_index) != component_root) continue;
        const group_node = ir.getNode(group_id) orelse return error.UnknownNode;
        if (!isGroupNode(group_node)) continue;
        try appendLocalTopFlowForGroupChildren(ir, child_ids, states, parent, component_root, root_index, group_id, &constraints);
    }

    return constraints;
}

fn appendLocalTopFlowForPageChildren(
    ir: anytype,
    child_ids: []const NodeId,
    states: []const AxisState,
    parent: []usize,
    component_root: usize,
    root_index: usize,
    constraints: *std.ArrayList(Constraint),
) !void {
    try appendLocalTopFlowForChildren(ir, child_ids, states, parent, component_root, root_index, child_ids, .page, constraints);
}

fn appendLocalTopFlowForGroupChildren(
    ir: anytype,
    child_ids: []const NodeId,
    states: []const AxisState,
    parent: []usize,
    component_root: usize,
    root_index: usize,
    group_id: NodeId,
    constraints: *std.ArrayList(Constraint),
) !void {
    const children = ir.childrenOf(group_id) orelse return;
    try appendLocalTopFlowForChildren(ir, child_ids, states, parent, component_root, root_index, children, .group, constraints);
}

const FlowScope = enum { page, group };

fn appendLocalTopFlowForChildren(
    ir: anytype,
    child_ids: []const NodeId,
    states: []const AxisState,
    parent: []usize,
    component_root: usize,
    root_index: usize,
    children: []const NodeId,
    scope: FlowScope,
    constraints: *std.ArrayList(Constraint),
) !void {
    const allocator = ir.allocator;
    const used = try allocator.alloc(bool, children.len);
    defer allocator.free(used);
    @memset(used, false);

    var unit = std.ArrayList(usize).empty;
    defer unit.deinit(allocator);

    var current_source: ?ConstraintSource = null;
    var current_offset: f32 = 0;
    var started = false;

    for (children, 0..) |child_id, child_pos| {
        if (used[child_pos]) continue;
        const index = flowChildIndex(ir, child_ids, states, parent, component_root, child_id, scope) orelse continue;

        unit.clearRetainingCapacity();
        try collectHorizontalFlowUnit(ir, child_ids, states, parent, component_root, children, scope, index, used, &unit);
        const placement_index = flowUnitPlacementIndex(ir, child_ids, states, unit.items) orelse index;
        const spacing_index = flowUnitBottomIndex(ir, child_ids, states, unit.items) orelse placement_index;
        const contains_root = flowUnitContains(unit.items, root_index);

        if (contains_root) {
            started = true;
        } else if (!started and scope == .page) {
            continue;
        }

        if (!contains_root) {
            try constraints.append(allocator, .{
                .target_node = child_ids[placement_index],
                .target_anchor = .top,
                .source = current_source orelse .{ .node = .{ .node_id = child_ids[root_index], .anchor = .top } },
                .offset = current_offset,
            });
        }

        try appendFlowUnitCenterConstraints(allocator, constraints, child_ids, unit.items, if (contains_root) root_index else placement_index);

        const spacing_node = ir.getNode(child_ids[spacing_index]) orelse return error.UnknownNode;
        current_source = .{ .node = .{ .node_id = child_ids[spacing_index], .anchor = .bottom } };
        current_offset = -styleForNode(ir, spacing_node).spacing_after;
    }
}

fn collectHorizontalFlowUnit(
    ir: anytype,
    child_ids: []const NodeId,
    states: []const AxisState,
    parent: []usize,
    component_root: usize,
    children: []const NodeId,
    scope: FlowScope,
    seed_index: usize,
    used: []bool,
    unit: *std.ArrayList(usize),
) !void {
    try unit.append(ir.allocator, seed_index);
    markChildUsed(child_ids, children, seed_index, used);

    var changed = true;
    while (changed) {
        changed = false;
        for (children) |candidate_id| {
            const candidate_index = flowChildIndex(ir, child_ids, states, parent, component_root, candidate_id, scope) orelse continue;
            if (flowUnitContains(unit.items, candidate_index)) continue;
            if (!hasHorizontalRelationToUnit(ir, child_ids, unit.items, candidate_index)) continue;
            try unit.append(ir.allocator, candidate_index);
            markChildUsed(child_ids, children, candidate_index, used);
            changed = true;
        }
    }
}

fn appendFlowUnitCenterConstraints(
    allocator: std.mem.Allocator,
    constraints: *std.ArrayList(Constraint),
    child_ids: []const NodeId,
    unit: []const usize,
    center_index: usize,
) !void {
    if (unit.len < 2) return;
    for (unit) |index| {
        if (index == center_index) continue;
        try constraints.append(allocator, .{
            .target_node = child_ids[index],
            .target_anchor = .center_y,
            .source = .{ .node = .{ .node_id = child_ids[center_index], .anchor = .center_y } },
            .offset = 0,
        });
    }
}

fn flowChildIndex(
    ir: anytype,
    child_ids: []const NodeId,
    states: []const AxisState,
    parent: []usize,
    component_root: usize,
    child_id: NodeId,
    scope: FlowScope,
) ?usize {
    const index = indexOfNode(child_ids, child_id) orelse return null;
    if (componentFind(parent, index) != component_root) return null;
    const node = ir.getNode(child_id) orelse return null;
    if (isGroupNode(node) and scope != .group) return null;
    if (scope == .page and directParentGroupIndex(ir, child_ids, parent, component_root, child_id) != null) return null;
    const state = states[index];
    if (state.start != null or state.end != null or state.center != null) return null;
    if (hasAxisTargetConstraint(ir, child_id, .vertical)) return null;
    return index;
}

fn flowUnitPlacementIndex(ir: anytype, child_ids: []const NodeId, states: []const AxisState, unit: []const usize) ?usize {
    return flowUnitMaxHeightIndex(ir, child_ids, states, unit);
}

fn flowUnitBottomIndex(ir: anytype, child_ids: []const NodeId, states: []const AxisState, unit: []const usize) ?usize {
    return flowUnitMaxHeightIndex(ir, child_ids, states, unit);
}

fn flowUnitMaxHeightIndex(ir: anytype, child_ids: []const NodeId, states: []const AxisState, unit: []const usize) ?usize {
    var best: ?usize = null;
    var best_height: f32 = -1;
    for (unit) |index| {
        const node = ir.getNode(child_ids[index]) orelse continue;
        const height = states[index].size orelse node.frame.height;
        if (best == null or height > best_height) {
            best = index;
            best_height = height;
        }
    }
    return best;
}

fn hasHorizontalRelationToUnit(ir: anytype, child_ids: []const NodeId, unit: []const usize, candidate_index: usize) bool {
    for (unit) |member_index| {
        if (hasHorizontalRelation(ir, child_ids[candidate_index], child_ids[member_index])) return true;
    }
    return false;
}

fn hasHorizontalRelation(ir: anytype, a: NodeId, b: NodeId) bool {
    for (ir.constraints.items) |constraint| {
        if (anchorAxis(constraint.target_anchor) != .horizontal) continue;
        const source = switch (constraint.source) {
            .page => continue,
            .node => |source| source,
        };
        if (anchorAxis(source.anchor) != .horizontal) continue;
        if (constraint.target_node == a and source.node_id == b) return true;
        if (constraint.target_node == b and source.node_id == a) return true;
    }
    return false;
}

fn markChildUsed(child_ids: []const NodeId, children: []const NodeId, index: usize, used: []bool) void {
    for (children, 0..) |child_id, child_pos| {
        if (child_id == child_ids[index]) {
            used[child_pos] = true;
            return;
        }
    }
}

fn flowUnitContains(unit: []const usize, index: usize) bool {
    for (unit) |member| {
        if (member == index) return true;
    }
    return false;
}

fn directParentGroupIndex(ir: anytype, child_ids: []const NodeId, parent: []usize, component_root: usize, child_id: NodeId) ?usize {
    for (child_ids, 0..) |candidate_id, index| {
        if (componentFind(parent, index) != component_root) continue;
        const candidate = ir.getNode(candidate_id) orelse continue;
        if (!isGroupNode(candidate)) continue;
        const children = ir.childrenOf(candidate_id) orelse continue;
        for (children) |group_child_id| {
            if (group_child_id == child_id) return index;
        }
    }
    return null;
}

fn componentFallbackRootIndex(ir: anytype, child_ids: []const NodeId, parent: []usize, component_root: usize) ?usize {
    for (child_ids, 0..) |child_id, index| {
        if (componentFind(parent, index) != component_root) continue;
        const node = ir.getNode(child_id) orelse continue;
        if (isGroupNode(node)) continue;
        if (roleEq(node.role, "page_number")) continue;
        return index;
    }
    return null;
}

fn componentAxisFallbackRootIndex(
    ir: anytype,
    child_ids: []const NodeId,
    states: []const AxisState,
    parent: []usize,
    component_root: usize,
    axis: Axis,
) ?usize {
    var fallback: ?usize = null;
    for (child_ids, states, 0..) |child_id, state, index| {
        if (componentFind(parent, index) != component_root) continue;
        const node = ir.getNode(child_id) orelse continue;
        if (isGroupNode(node)) continue;
        if (roleEq(node.role, "page_number")) continue;
        if (fallback == null) fallback = index;
        if (state.start == null and !hasAxisTargetConstraint(ir, child_id, axis)) return index;
    }
    return fallback;
}

fn componentFind(parent: []usize, index: usize) usize {
    var current = index;
    while (parent[current] != current) {
        current = parent[current];
    }
    return current;
}

fn componentUnion(parent: []usize, page_dependent: []bool, a: usize, b: usize) void {
    const a_root = componentFind(parent, a);
    const b_root = componentFind(parent, b);
    if (a_root == b_root) return;
    parent[b_root] = a_root;
    page_dependent[a_root] = page_dependent[a_root] or page_dependent[b_root];
}

fn applyAxisConstraint(ir: anytype, page_id: NodeId, child_ids: []const NodeId, states: []AxisState, axis: Axis, constraint: Constraint, is_soft: bool) !bool {
    if (anchorAxis(constraint.target_anchor) != axis) return false;

    const target_page = ir.parentPageOf(constraint.target_node) orelse return error.MissingParentPage;
    if (target_page != page_id) return false;

    const target_index = indexOfNode(child_ids, constraint.target_node) orelse return error.UnknownNode;
    const target_node = ir.getNode(constraint.target_node) orelse return error.UnknownNode;
    if (isGroupNode(target_node)) return false;

    if (selfReferentialSize(constraint, axis)) |size| {
        if (size < -0.01) {
            if (is_soft) return false;
            ir.noteConstraintFailure(page_id, constraint, states[target_index].size_source, .negative_size);
            return false;
        }
        if (is_soft and states[target_index].size != null) return false;
        return setAxisSize(&states[target_index], size, constraint) catch |err| {
            if (is_soft) return false;
            const kind: model.ConstraintFailureKind = if (err == error.ConstraintConflict) .conflict else .negative_size;
            ir.noteConstraintFailure(page_id, constraint, states[target_index].size_source, kind);
            return false;
        };
    }

    if (is_soft and axisAnchorValue(states[target_index], constraint.target_anchor) != null) {
        return false;
    }

    const source_value = try constraintSourceValue(ir, page_id, child_ids, states, axis, constraint.source);
    if (source_value == null) {
        return try applyReverseAxisConstraint(ir, page_id, child_ids, states, axis, constraint, is_soft, target_index);
    }

    return setAxisAnchor(&states[target_index], constraint.target_anchor, source_value.? + constraint.offset, constraint) catch |err| {
        if (is_soft) return false;
        const kind: model.ConstraintFailureKind = if (err == error.ConstraintConflict) .conflict else .negative_size;
        ir.noteConstraintFailure(page_id, constraint, axisAnchorSource(states[target_index], constraint.target_anchor), kind);
        return false;
    };
}

fn applyReverseAxisConstraint(
    ir: anytype,
    page_id: NodeId,
    child_ids: []const NodeId,
    states: []AxisState,
    axis: Axis,
    constraint: Constraint,
    is_soft: bool,
    target_index: usize,
) !bool {
    if (is_soft) return false;

    const node_source = switch (constraint.source) {
        .page => return false,
        .node => |source| source,
    };
    if (anchorAxis(node_source.anchor) != axis) return error.ConstraintAxisMismatch;

    const source_node = ir.getNode(node_source.node_id) orelse return error.UnknownNode;
    if (isGroupNode(source_node)) return false;

    const source_page = ir.parentPageOf(node_source.node_id) orelse return error.MissingParentPage;
    if (source_page != page_id) return false;

    const source_index = indexOfNode(child_ids, node_source.node_id) orelse return false;
    if (axisAnchorValue(states[source_index], node_source.anchor) != null) return false;

    const target_value = axisAnchorValue(states[target_index], constraint.target_anchor) orelse return false;
    return setAxisAnchor(&states[source_index], node_source.anchor, target_value - constraint.offset, constraint) catch |err| {
        const kind: model.ConstraintFailureKind = if (err == error.ConstraintConflict) .conflict else .negative_size;
        ir.noteConstraintFailure(page_id, constraint, axisAnchorSource(states[source_index], node_source.anchor), kind);
        return false;
    };
}

fn selfReferentialSize(constraint: Constraint, axis: Axis) ?f32 {
    const node_source = switch (constraint.source) {
        .node => |ns| ns,
        .page => return null,
    };
    if (node_source.node_id != constraint.target_node) return null;
    if (anchorAxis(node_source.anchor) != axis) return null;
    if (anchorAxis(constraint.target_anchor) != axis) return null;
    return sizeFromAnchorPair(constraint.target_anchor, node_source.anchor, constraint.offset);
}

const AnchorRole = enum { start, end, center };

fn anchorRole(a: Anchor) AnchorRole {
    return switch (a) {
        .left, .bottom => .start,
        .right, .top => .end,
        .center_x, .center_y => .center,
    };
}

fn sizeFromAnchorPair(target: Anchor, source: Anchor, offset: f32) ?f32 {
    return switch (anchorRole(target)) {
        .end => switch (anchorRole(source)) {
            .start => offset,
            .center => offset * 2,
            .end => null,
        },
        .start => switch (anchorRole(source)) {
            .end => -offset,
            .center => -offset * 2,
            .start => null,
        },
        .center => switch (anchorRole(source)) {
            .start => offset * 2,
            .end => -offset * 2,
            .center => null,
        },
    };
}

fn constraintTargetsGroup(ir: anytype, constraint: Constraint) bool {
    const target_node = ir.getNode(constraint.target_node) orelse return false;
    return isGroupNode(target_node);
}

fn groupHasTargetConstraint(ir: anytype, group_id: NodeId, axis: Axis, extra_constraints: []const Constraint) bool {
    for (ir.constraints.items) |constraint| {
        if (constraint.target_node != group_id) continue;
        if (anchorAxis(constraint.target_anchor) != axis) continue;
        return true;
    }
    for (extra_constraints) |constraint| {
        if (constraint.target_node != group_id) continue;
        if (anchorAxis(constraint.target_anchor) != axis) continue;
        return true;
    }
    return false;
}

fn propagateWidthCapToSubtree(ir: anytype, node_id: NodeId, max_right: f32) !void {
    const node = ir.getNode(node_id) orelse return error.UnknownNode;
    if (node.frame.x_set and shouldWrapNode(ir, node)) {
        const available = @max(@as(f32, 1.0), max_right - node.frame.x);
        if (available < node.frame.width - 0.01) {
            node.frame.width = available;
            node.frame.height = intrinsicHeight(ir, node);
        }
    }
    if (isGroupNode(node)) {
        const children = ir.childrenOf(node_id) orelse return;
        for (children) |child_id| {
            try propagateWidthCapToSubtree(ir, child_id, max_right);
        }
    }
}

fn propagateTargetedGroupWidths(ir: anytype, child_ids: []const NodeId, horizontal: []const AxisState, extra_constraints: []const Constraint) !void {
    for (child_ids, horizontal) |group_id, h_state| {
        const node = ir.getNode(group_id) orelse return error.UnknownNode;
        if (!isGroupNode(node)) continue;
        if (!groupHasTargetConstraint(ir, group_id, .horizontal, extra_constraints)) continue;
        const group_left = h_state.start orelse continue;
        const group_width = h_state.size orelse continue;
        const group_right = group_left + group_width;
        const children = ir.childrenOf(group_id) orelse continue;
        for (children) |child_id| {
            try propagateWidthCapToSubtree(ir, child_id, group_right);
        }
    }
}

fn computeTightGroupAxisState(ir: anytype, child_ids: []const NodeId, states: []const AxisState, node_id: NodeId, axis: Axis) !AxisState {
    const group_children = ir.childrenOf(node_id) orelse return .{};

    var start: ?f32 = null;
    var end: ?f32 = null;
    for (group_children) |child_id| {
        const child_start, const child_end = try groupChildAxisBounds(ir, child_ids, states, child_id, axis);
        if (child_start == null or child_end == null) return .{};
        if (start == null or child_start.? < start.?) start = child_start.?;
        if (end == null or child_end.? > end.?) end = child_end.?;
    }

    if (start == null or end == null) return .{};
    const size = end.? - start.?;
    return .{
        .start = start,
        .end = end,
        .center = start.? + size / 2,
        .size = size,
        .size_is_default = false,
    };
}

fn updateGroupAxisStates(ir: anytype, child_ids: []const NodeId, states: []AxisState, axis: Axis, extra_constraints: []const Constraint) !bool {
    var changed = false;
    for (child_ids, 0..) |node_id, index| {
        const node = ir.getNode(node_id) orelse return error.UnknownNode;
        if (!isGroupNode(node)) continue;
        if (groupHasTargetConstraint(ir, node_id, axis, extra_constraints)) continue;
        const tight = try computeTightGroupAxisState(ir, child_ids, states, node_id, axis);
        if (tight.start == null or tight.end == null) {
            changed = setGroupAxisState(&states[index], null, null) or changed;
            continue;
        }
        changed = setGroupAxisState(&states[index], tight.start.?, tight.end.?) or changed;
    }
    return changed;
}

fn applyGroupTargetConstraintSlice(
    ir: anytype,
    page_id: NodeId,
    child_ids: []const NodeId,
    states: []AxisState,
    axis: Axis,
    group_id: NodeId,
    base: AxisState,
    temp: *AxisState,
    used: *bool,
    last_constraint: *?Constraint,
    constraints: []const Constraint,
) !void {
    for (constraints) |constraint| {
        if (constraint.target_node != group_id) continue;
        if (anchorAxis(constraint.target_anchor) != axis) continue;
        used.* = true;
        last_constraint.* = constraint;

        if (selfReferentialSize(constraint, axis)) |size| {
            if (size < -0.01) {
                ir.noteConstraintFailure(page_id, constraint, temp.size_source, .negative_size);
                continue;
            }
            _ = setAxisSize(temp, size, constraint) catch |err| {
                const kind: model.ConstraintFailureKind = if (err == error.ConstraintConflict) .conflict else .negative_size;
                ir.noteConstraintFailure(page_id, constraint, temp.size_source, kind);
                continue;
            };
            continue;
        }

        const source_value = switch (constraint.source) {
            .page => try constraintSourceValue(ir, page_id, child_ids, states, axis, constraint.source),
            .node => |node_source| blk: {
                if (node_source.node_id == group_id) {
                    const current = axisAnchorValue(temp.*, node_source.anchor);
                    break :blk if (current != null) current else axisAnchorValue(base, node_source.anchor);
                }
                break :blk try constraintSourceValue(ir, page_id, child_ids, states, axis, constraint.source);
            },
        };
        if (source_value == null) continue;

        _ = setAxisAnchor(temp, constraint.target_anchor, source_value.? + constraint.offset, constraint) catch |err| {
            const kind: model.ConstraintFailureKind = if (err == error.ConstraintConflict) .conflict else .negative_size;
            ir.noteConstraintFailure(page_id, constraint, axisAnchorSource(temp.*, constraint.target_anchor), kind);
        };
    }
}

fn shiftAxisState(state: *AxisState, delta: f32) bool {
    if (approxEq(delta, 0)) return false;
    var changed = false;
    if (state.start) |value| {
        state.start = value + delta;
        changed = true;
    }
    if (state.end) |value| {
        state.end = value + delta;
        changed = true;
    }
    if (state.center) |value| {
        state.center = value + delta;
        changed = true;
    }
    return changed;
}

fn translateGroupSubtree(
    ir: anytype,
    child_ids: []const NodeId,
    states: []AxisState,
    group_id: NodeId,
    delta: f32,
) !bool {
    if (approxEq(delta, 0)) return false;
    var changed = false;
    const group_children = ir.childrenOf(group_id) orelse return false;
    for (group_children) |child_id| {
        if (indexOfNode(child_ids, child_id)) |child_index| {
            changed = shiftAxisState(&states[child_index], delta) or changed;
        }
        const child_node = ir.getNode(child_id) orelse return error.UnknownNode;
        if (isGroupNode(child_node)) {
            changed = (try translateGroupSubtree(ir, child_ids, states, child_id, delta)) or changed;
        }
    }
    return changed;
}

fn applyGroupTargetConstraints(
    ir: anytype,
    page_id: NodeId,
    child_ids: []const NodeId,
    states: []AxisState,
    axis: Axis,
    extra_constraints: []const Constraint,
) !bool {
    var changed = false;
    for (child_ids, 0..) |group_id, group_index| {
        const group_node = ir.getNode(group_id) orelse return error.UnknownNode;
        if (!isGroupNode(group_node)) continue;
        if (!groupHasTargetConstraint(ir, group_id, axis, extra_constraints)) continue;

        const base = try computeTightGroupAxisState(ir, child_ids, states, group_id, axis);
        if (base.start == null or base.end == null or base.center == null or base.size == null) continue;

        var temp = AxisState{};
        var used = false;
        var last_constraint: ?Constraint = null;
        try applyGroupTargetConstraintSlice(ir, page_id, child_ids, states, axis, group_id, base, &temp, &used, &last_constraint, ir.constraints.items);
        try applyGroupTargetConstraintSlice(ir, page_id, child_ids, states, axis, group_id, base, &temp, &used, &last_constraint, extra_constraints);
        if (!used) continue;

        if (temp.start == null and temp.end == null and temp.center == null and temp.size == null) {
            temp = base;
        } else {
            if (temp.size == null) {
                temp.size = base.size;
                temp.size_is_default = true;
            }
            if (temp.start == null and temp.end == null and temp.center == null) {
                temp.start = base.start;
            }
        }
        _ = reconcileAxisState(&temp) catch |err| {
            if (last_constraint) |constraint| {
                const kind: model.ConstraintFailureKind = if (err == error.ConstraintConflict) .conflict else .negative_size;
                ir.noteConstraintFailure(page_id, constraint, null, kind);
            }
            continue;
        };

        const delta = if (temp.start != null and base.start != null) temp.start.? - base.start.? else 0;
        changed = shiftAxisState(&states[group_index], delta) or changed;
        changed = (try translateGroupSubtree(ir, child_ids, states, group_id, delta)) or changed;
        states[group_index] = temp;
    }
    return changed;
}

fn constraintUsesGroupSource(ir: anytype, constraint: Constraint) bool {
    return switch (constraint.source) {
        .page => false,
        .node => |node_source| blk: {
            const source_node = ir.getNode(node_source.node_id) orelse break :blk false;
            break :blk isGroupNode(source_node);
        },
    };
}

fn setGroupAxisState(state: *AxisState, start: ?f32, end: ?f32) bool {
    const old = state.*;
    if (start == null or end == null) {
        state.* = .{};
        return !axisStatesEq(old, state.*);
    }

    const size = end.? - start.?;
    state.* = .{
        .start = start,
        .end = end,
        .center = start.? + size / 2,
        .size = size,
        .start_source = null,
        .end_source = null,
        .center_source = null,
        .size_source = null,
        .size_is_default = false,
    };
    return !axisStatesEq(old, state.*);
}

fn axisStatesEq(a: AxisState, b: AxisState) bool {
    return optionalFloatEq(a.start, b.start) and
        optionalFloatEq(a.end, b.end) and
        optionalFloatEq(a.center, b.center) and
        optionalFloatEq(a.size, b.size) and
        a.size_is_default == b.size_is_default;
}

fn optionalFloatEq(a: ?f32, b: ?f32) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return approxEq(a.?, b.?);
}

fn groupChildAxisBounds(ir: anytype, child_ids: []const NodeId, states: []const AxisState, child_id: NodeId, axis: Axis) !struct { ?f32, ?f32 } {
    if (indexOfNode(child_ids, child_id)) |index| {
        return .{
            axisAnchorValue(states[index], switch (axis) {
                .horizontal => .left,
                .vertical => .bottom,
            }),
            axisAnchorValue(states[index], switch (axis) {
                .horizontal => .right,
                .vertical => .top,
            }),
        };
    }

    const child = ir.getNode(child_id) orelse return error.UnknownNode;
    const start_anchor: Anchor = switch (axis) {
        .horizontal => .left,
        .vertical => .bottom,
    };
    const end_anchor: Anchor = switch (axis) {
        .horizontal => .right,
        .vertical => .top,
    };
    if (!anchorKnown(child.frame, start_anchor) or !anchorKnown(child.frame, end_anchor)) return .{ null, null };
    return .{ anchorValue(child.frame, start_anchor), anchorValue(child.frame, end_anchor) };
}

fn constraintSourceValue(ir: anytype, page_id: NodeId, child_ids: []const NodeId, states: []const AxisState, axis: Axis, source: ConstraintSource) !?f32 {
    return switch (source) {
        .page => |anchor| blk: {
            if (anchorAxis(anchor) != axis) return error.ConstraintAxisMismatch;
            const page = ir.getNode(page_id) orelse return error.UnknownNode;
            break :blk anchorValue(page.frame, anchor);
        },
        .node => |node_source| blk: {
            if (anchorAxis(node_source.anchor) != axis) return error.ConstraintAxisMismatch;
            if (indexOfNode(child_ids, node_source.node_id)) |index| {
                break :blk axisAnchorValue(states[index], node_source.anchor);
            }

            const source_node = ir.getNode(node_source.node_id) orelse return error.UnknownNode;
            if (!anchorKnown(source_node.frame, node_source.anchor)) break :blk null;
            break :blk anchorValue(source_node.frame, node_source.anchor);
        },
    };
}

pub fn anchorAxis(anchor: Anchor) Axis {
    return switch (anchor) {
        .left, .right, .center_x => .horizontal,
        .top, .bottom, .center_y => .vertical,
    };
}

fn indexOfNode(ids: []const NodeId, target: NodeId) ?usize {
    for (ids, 0..) |id, index| {
        if (id == target) return index;
    }
    return null;
}

fn axisAnchorValue(state: AxisState, anchor: Anchor) ?f32 {
    return switch (anchor) {
        .left, .bottom => state.start,
        .right, .top => state.end,
        .center_x, .center_y => state.center,
    };
}

fn axisAnchorSource(state: AxisState, anchor: Anchor) ?Constraint {
    return switch (anchor) {
        .left, .bottom => state.start_source,
        .right, .top => state.end_source,
        .center_x, .center_y => state.center_source,
    };
}

fn setAxisAnchor(state: *AxisState, anchor: Anchor, value: f32, source: ?Constraint) !bool {
    if (try overrideDefaultDerivedAnchor(state, anchor, value, source)) return true;
    return switch (anchor) {
        .left, .bottom => try setOptionalFloat(&state.start, &state.start_source, value, source),
        .right, .top => try setOptionalFloat(&state.end, &state.end_source, value, source),
        .center_x, .center_y => try setOptionalFloat(&state.center, &state.center_source, value, source),
    };
}

fn overrideDefaultDerivedAnchor(state: *AxisState, anchor: Anchor, value: f32, source: ?Constraint) !bool {
    if (!state.size_is_default) return false;

    return switch (anchor) {
        .left, .bottom => blk: {
            if (state.start) |current| {
                if (approxEq(current, value)) break :blk false;
                if (state.end != null) {
                    state.start = value;
                    state.start_source = source;
                    state.size = null;
                    state.size_source = null;
                    state.size_is_default = false;
                    state.center = null;
                    state.center_source = null;
                    break :blk true;
                }
            }
            break :blk false;
        },
        .right, .top => blk: {
            if (state.end) |current| {
                if (approxEq(current, value)) break :blk false;
                if (state.start != null) {
                    state.end = value;
                    state.end_source = source;
                    state.size = null;
                    state.size_source = null;
                    state.size_is_default = false;
                    state.center = null;
                    state.center_source = null;
                    break :blk true;
                }
            }
            break :blk false;
        },
        .center_x, .center_y => false,
    };
}

fn reconcileAxisState(state: *AxisState) !bool {
    var changed = false;
    var progress = true;

    while (progress) {
        progress = false;

        if (state.start != null and state.end != null) {
            const size = state.end.? - state.start.?;
            try ensureNonNegativeSize(size);
            progress = (try setAxisSize(state, size, null)) or progress;
            progress = (try setOptionalFloat(&state.center, &state.center_source, state.start.? + size / 2, null)) or progress;
        }

        if (state.start != null and state.size != null) {
            progress = (try setOptionalFloat(&state.end, &state.end_source, state.start.? + state.size.?, null)) or progress;
            progress = (try setOptionalFloat(&state.center, &state.center_source, state.start.? + state.size.? / 2, null)) or progress;
        }

        if (state.end != null and state.size != null) {
            progress = (try setOptionalFloat(&state.start, &state.start_source, state.end.? - state.size.?, null)) or progress;
            progress = (try setOptionalFloat(&state.center, &state.center_source, state.start.? + state.size.? / 2, null)) or progress;
        }

        if (state.center != null and state.size != null) {
            progress = (try setOptionalFloat(&state.start, &state.start_source, state.center.? - state.size.? / 2, null)) or progress;
            progress = (try setOptionalFloat(&state.end, &state.end_source, state.center.? + state.size.? / 2, null)) or progress;
        }

        if (state.start != null and state.center != null) {
            const half = state.center.? - state.start.?;
            const size = half * 2;
            try ensureNonNegativeSize(size);
            progress = (try setAxisSize(state, size, null)) or progress;
            progress = (try setOptionalFloat(&state.end, &state.end_source, state.start.? + size, null)) or progress;
        }

        if (state.end != null and state.center != null) {
            const half = state.end.? - state.center.?;
            const size = half * 2;
            try ensureNonNegativeSize(size);
            progress = (try setAxisSize(state, size, null)) or progress;
            progress = (try setOptionalFloat(&state.start, &state.start_source, state.end.? - size, null)) or progress;
        }

        changed = progress or changed;
    }

    return changed;
}

fn ensureNonNegativeSize(size: f32) !void {
    if (size < -0.01) return error.NegativeConstraintSize;
}

fn setOptionalFloat(slot: *?f32, source_slot: *?Constraint, value: f32, source: ?Constraint) !bool {
    if (slot.*) |current| {
        if (approxEq(current, value)) return false;
        return error.ConstraintConflict;
    }
    slot.* = value;
    source_slot.* = source;
    return true;
}

fn setAxisSize(state: *AxisState, value: f32, source: ?Constraint) !bool {
    if (state.size) |current| {
        if (approxEq(current, value)) {
            return false;
        }
        if (state.size_is_default) {
            state.size = value;
            state.size_source = source;
            state.size_is_default = false;
            return true;
        }
        return error.ConstraintConflict;
    }

    state.size = value;
    state.size_source = source;
    state.size_is_default = false;
    return true;
}

fn anchorKnown(frame: Frame, anchor: Anchor) bool {
    return switch (anchor) {
        .left, .right, .center_x => frame.x_set,
        .top, .bottom, .center_y => frame.y_set,
    };
}

fn anchorValue(frame: Frame, anchor: Anchor) f32 {
    return switch (anchor) {
        .left => frame.x,
        .right => frame.x + frame.width,
        .top => frame.y + frame.height,
        .bottom => frame.y,
        .center_x => frame.x + frame.width / 2,
        .center_y => frame.y + frame.height / 2,
    };
}

pub fn approxEq(a: f32, b: f32) bool {
    const diff = if (a > b) a - b else b - a;
    return diff < 0.01;
}

fn isGroupNode(node: *const Node) bool {
    return roleEq(node.role, GroupRole);
}
