const model = @import("model");
const graph = @import("graph.zig");
const solver = @import("solver.zig");

const NodeId = model.NodeId;
const Node = model.Node;
const Axis = model.Axis;
const AxisState = model.AxisState;
const Anchor = model.Anchor;
const Constraint = model.Constraint;
const Frame = model.Frame;
const GroupRole = model.GroupRole;
const roleEq = model.roleEq;

pub fn constraintTargetsGroup(ir: anytype, constraint: Constraint) bool {
    const target_node = ir.getNode(constraint.target_node) orelse return false;
    return isGroupNode(target_node);
}

pub fn hasTargetConstraint(ir: anytype, group_id: NodeId, axis: Axis, extra_constraints: []const Constraint) bool {
    for (ir.constraints.items) |constraint| {
        if (constraint.target_node != group_id) continue;
        if (solver.anchorAxis(constraint.target_anchor) != axis) continue;
        return true;
    }
    for (extra_constraints) |constraint| {
        if (constraint.target_node != group_id) continue;
        if (solver.anchorAxis(constraint.target_anchor) != axis) continue;
        return true;
    }
    return false;
}

fn propagateWidthCapToSubtree(ir: anytype, node_id: NodeId, max_right: f32) !void {
    const node = ir.getNode(node_id) orelse return error.UnknownNode;
    if (node.frame.x_set and solver.shouldWrapNode(ir, node)) {
        const available = @max(@as(f32, 1.0), max_right - node.frame.x);
        if (available < node.frame.width - graph.ConstraintTolerance) {
            node.frame.width = available;
            node.frame.height = solver.intrinsicHeight(ir, node);
        }
    }
    if (isGroupNode(node)) {
        const children = ir.childrenOf(node_id) orelse return;
        for (children) |child_id| {
            try propagateWidthCapToSubtree(ir, child_id, max_right);
        }
    }
}

pub fn propagateTargetedWidths(ir: anytype, workspace: *const graph.AxisWorkspace) !void {
    for (workspace.graph.child_ids, workspace.states) |group_id, h_state| {
        const node = ir.getNode(group_id) orelse return error.UnknownNode;
        if (!isGroupNode(node)) continue;
        if (!workspace.graph.hasTargetConstraint(ir, group_id, .horizontal, workspace.soft_constraints)) continue;
        const group_left = h_state.start orelse continue;
        const group_width = h_state.size orelse continue;
        const group_right = group_left + group_width;
        const children = ir.childrenOf(group_id) orelse continue;
        for (children) |child_id| {
            try propagateWidthCapToSubtree(ir, child_id, group_right);
        }
    }
}

fn computeTightGroupAxisState(ir: anytype, workspace: *const graph.AxisWorkspace, node_id: NodeId) !AxisState {
    const group_children = ir.childrenOf(node_id) orelse return .{};

    var start: ?f32 = null;
    var end: ?f32 = null;
    for (group_children) |child_id| {
        const child_start, const child_end = try groupChildAxisBounds(ir, workspace, child_id);
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

pub fn updateAxisStates(ir: anytype, workspace: *graph.AxisWorkspace) !bool {
    var changed = false;
    for (workspace.graph.child_ids, 0..) |node_id, index| {
        const node = ir.getNode(node_id) orelse return error.UnknownNode;
        if (!isGroupNode(node)) continue;
        if (workspace.graph.hasTargetConstraint(ir, node_id, workspace.axis, workspace.soft_constraints)) continue;
        const tight = try computeTightGroupAxisState(ir, workspace, node_id);
        if (tight.start == null or tight.end == null) {
            changed = setGroupAxisState(&workspace.states[index], null, null) or changed;
            continue;
        }
        changed = setGroupAxisState(&workspace.states[index], tight.start.?, tight.end.?) or changed;
    }
    return changed;
}

fn applyGroupTargetConstraintSlice(
    ir: anytype,
    workspace: *const graph.AxisWorkspace,
    group_id: NodeId,
    base: AxisState,
    temp: *AxisState,
    used: *bool,
    last_constraint: *?Constraint,
    constraints: []const Constraint,
) !void {
    for (constraints) |constraint| {
        if (constraint.target_node != group_id) continue;
        if (solver.anchorAxis(constraint.target_anchor) != workspace.axis) continue;
        used.* = true;
        last_constraint.* = constraint;

        if (solver.selfReferentialSize(constraint, workspace.axis)) |size| {
            if (size < -graph.ConstraintTolerance) {
                ir.noteConstraintFailure(workspace.graph.page_id, constraint, temp.size_source, .negative_size);
                continue;
            }
            _ = solver.setAxisSize(temp, size, constraint) catch |err| {
                const kind: model.ConstraintFailureKind = if (err == error.ConstraintConflict) .conflict else .negative_size;
                ir.noteConstraintFailure(workspace.graph.page_id, constraint, temp.size_source, kind);
                continue;
            };
            continue;
        }

        const source_value = switch (constraint.source) {
            .page => try solver.constraintSourceValue(ir, workspace, constraint.source),
            .node => |node_source| blk: {
                if (node_source.node_id == group_id) {
                    const current = solver.axisAnchorValue(temp.*, node_source.anchor);
                    break :blk if (current != null) current else solver.axisAnchorValue(base, node_source.anchor);
                }
                break :blk try solver.constraintSourceValue(ir, workspace, constraint.source);
            },
        };
        if (source_value == null) continue;

        _ = solver.setAxisAnchor(temp, constraint.target_anchor, source_value.? + constraint.offset, constraint) catch |err| {
            const kind: model.ConstraintFailureKind = if (err == error.ConstraintConflict) .conflict else .negative_size;
            ir.noteConstraintFailure(workspace.graph.page_id, constraint, solver.axisAnchorSource(temp.*, constraint.target_anchor), kind);
        };
    }
}

pub fn shiftAxisState(state: *AxisState, delta: f32) bool {
    return graph.shiftAxisState(state, delta);
}

pub fn translateSubtree(
    ir: anytype,
    workspace: *graph.AxisWorkspace,
    group_id: NodeId,
    delta: f32,
) !bool {
    return try workspace.graph.translateSubgraph(workspace, ir, group_id, delta);
}

pub fn applyTargetConstraints(
    ir: anytype,
    workspace: *graph.AxisWorkspace,
) !bool {
    var changed = false;
    for (workspace.graph.child_ids, 0..) |group_id, group_index| {
        const group_node = ir.getNode(group_id) orelse return error.UnknownNode;
        if (!isGroupNode(group_node)) continue;
        if (!workspace.graph.hasTargetConstraint(ir, group_id, workspace.axis, workspace.soft_constraints)) continue;

        const base = try computeTightGroupAxisState(ir, workspace, group_id);
        if (base.start == null or base.end == null or base.center == null or base.size == null) continue;

        var temp = AxisState{};
        var used = false;
        var last_constraint: ?Constraint = null;
        try applyGroupTargetConstraintSlice(ir, workspace, group_id, base, &temp, &used, &last_constraint, ir.constraints.items);
        try applyGroupTargetConstraintSlice(ir, workspace, group_id, base, &temp, &used, &last_constraint, workspace.soft_constraints);
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
        _ = solver.reconcileAxisState(&temp) catch |err| {
            if (last_constraint) |constraint| {
                const kind: model.ConstraintFailureKind = if (err == error.ConstraintConflict) .conflict else .negative_size;
                ir.noteConstraintFailure(workspace.graph.page_id, constraint, null, kind);
            }
            continue;
        };

        const delta = if (temp.start != null and base.start != null) temp.start.? - base.start.? else 0;
        changed = shiftAxisState(&workspace.states[group_index], delta) or changed;
        changed = (try translateSubtree(ir, workspace, group_id, delta)) or changed;
        workspace.states[group_index] = temp;
    }
    return changed;
}

pub fn constraintUsesGroupSource(ir: anytype, constraint: Constraint) bool {
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
    return solver.approxEq(a.?, b.?);
}

fn groupChildAxisBounds(ir: anytype, workspace: *const graph.AxisWorkspace, child_id: NodeId) !struct { ?f32, ?f32 } {
    if (workspace.indexOf(child_id)) |index| {
        return .{
            solver.axisAnchorValue(workspace.states[index], switch (workspace.axis) {
                .horizontal => .left,
                .vertical => .bottom,
            }),
            solver.axisAnchorValue(workspace.states[index], switch (workspace.axis) {
                .horizontal => .right,
                .vertical => .top,
            }),
        };
    }

    const child = ir.getNode(child_id) orelse return error.UnknownNode;
    const start_anchor: Anchor = switch (workspace.axis) {
        .horizontal => .left,
        .vertical => .bottom,
    };
    const end_anchor: Anchor = switch (workspace.axis) {
        .horizontal => .right,
        .vertical => .top,
    };
    if (!solver.anchorKnown(child.frame, start_anchor) or !solver.anchorKnown(child.frame, end_anchor)) return .{ null, null };
    return .{ solver.anchorValue(child.frame, start_anchor), solver.anchorValue(child.frame, end_anchor) };
}

pub fn isGroupNode(node: *const Node) bool {
    return roleEq(node.role, GroupRole);
}
