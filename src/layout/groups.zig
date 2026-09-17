const model = @import("model");
const graph = @import("graph.zig");
const metrics = @import("metrics.zig");

const NodeId = model.NodeId;
const Node = model.Node;
const AxisState = model.AxisState;
const Anchor = model.Anchor;
const Constraint = model.Constraint;
const GroupRole = model.GroupRole;
const ConnectorRole = model.ConnectorRole;
const roleEq = model.roleEq;

pub fn constraintTargetsGroup(state: anytype, constraint: Constraint) bool {
    const target_node = state.getNode(constraint.target_node) orelse return false;
    return isGroupNode(target_node);
}

fn propagateWidthCapToSubtree(state: anytype, node_id: NodeId, max_right: f32, measurement_cache: ?*metrics.MeasurementCache) !void {
    const node = state.getNode(node_id) orelse return error.UnknownNode;
    if (node.frame.x_set and metrics.shouldWrapNode(state, node)) {
        const available = @max(@as(f32, 1.0), max_right - node.frame.x);
        if (available < node.frame.width - graph.ConstraintTolerance) {
            node.frame.width = available;
            node.frame.height = if (measurement_cache) |cache|
                try metrics.intrinsicHeightCached(state, node, cache)
            else
                metrics.intrinsicHeight(state, node);
        }
    }
    if (isGroupNode(node)) {
        const children = state.childrenOf(node_id) orelse return;
        for (children) |child_id| {
            try propagateWidthCapToSubtree(state, child_id, max_right, measurement_cache);
        }
    }
}

pub fn propagateTargetedWidths(state: anytype, workspace: *const graph.AxisWorkspace) !void {
    try propagateTargetedWidthsWithCache(state, workspace, null);
}

pub fn propagateTargetedWidthsCached(state: anytype, workspace: *const graph.AxisWorkspace, measurement_cache: *metrics.MeasurementCache) !void {
    try propagateTargetedWidthsWithCache(state, workspace, measurement_cache);
}

fn propagateTargetedWidthsWithCache(state: anytype, workspace: *const graph.AxisWorkspace, measurement_cache: ?*metrics.MeasurementCache) !void {
    for (workspace.graph.child_ids, workspace.states) |group_id, h_state| {
        const node = state.getNode(group_id) orelse return error.UnknownNode;
        if (!isGroupNode(node)) continue;
        if (!workspace.graph.hasTargetConstraint(state, group_id, .horizontal, workspace.soft_constraints)) continue;
        const group_left = h_state.start orelse continue;
        const group_width = h_state.size orelse continue;
        const group_right = group_left + group_width - metrics.chromePadX(state, node);
        const children = state.childrenOf(group_id) orelse continue;
        for (children) |child_id| {
            try propagateWidthCapToSubtree(state, child_id, group_right, measurement_cache);
        }
    }
}

fn computeTightGroupAxisState(state: anytype, workspace: *const graph.AxisWorkspace, node_id: NodeId) !AxisState {
    if (workspace.graph.splitFrame(node_id)) |frame| {
        const start = if (workspace.axis == .horizontal) frame.x else frame.y;
        const size = if (workspace.axis == .horizontal) frame.width else frame.height;
        return .{ .start = start, .end = start + size, .center = start + size / 2, .size = size };
    }
    return computeChildGroupAxisState(state, workspace, node_id);
}

fn computeChildGroupAxisState(state: anytype, workspace: *const graph.AxisWorkspace, node_id: NodeId) !AxisState {
    const group_children = state.childrenOf(node_id) orelse return .{};

    var start: ?f32 = null;
    var end: ?f32 = null;
    for (group_children) |child_id| {
        const child = state.getNode(child_id) orelse return error.UnknownNode;
        if (roleEq(child.role, ConnectorRole)) continue;
        const child_start, const child_end = try groupChildAxisBounds(state, workspace, child_id);
        if (child_start == null or child_end == null) return .{};
        if (start == null or child_start.? < start.?) start = child_start.?;
        if (end == null or child_end.? > end.?) end = child_end.?;
    }

    if (start == null or end == null) return .{};
    const pad = groupAxisPadding(state, workspace, node_id);
    const padded_start = start.? - pad;
    const padded_end = end.? + pad;
    const size = padded_end - padded_start;
    return .{
        .start = padded_start,
        .end = padded_end,
        .center = padded_start + size / 2,
        .size = size,
        .size_is_default = false,
    };
}

fn groupAxisPadding(state: anytype, workspace: *const graph.AxisWorkspace, node_id: NodeId) f32 {
    const node = state.getNode(node_id) orelse return 0;
    return switch (workspace.axis) {
        .horizontal => metrics.chromePadX(state, node),
        .vertical => metrics.chromePadY(state, node),
    };
}

pub fn updateAxisStates(state: anytype, workspace: *graph.AxisWorkspace) !bool {
    var changed = false;
    for (workspace.graph.group_order) |index| {
        const node_id = workspace.nodeAt(index);
        if (workspace.graph.hasTargetConstraint(state, node_id, workspace.axis, workspace.soft_constraints)) continue;
        const tight = try computeTightGroupAxisState(state, workspace, node_id);
        if (tight.start == null or tight.end == null) {
            changed = setGroupAxisState(&workspace.states[index], null, null) or changed;
            continue;
        }
        changed = setGroupAxisState(&workspace.states[index], tight.start.?, tight.end.?) or changed;
    }
    return changed;
}

fn applyGroupTargetConstraintSlice(
    state: anytype,
    workspace: *const graph.AxisWorkspace,
    group_id: NodeId,
    base: AxisState,
    temp: *AxisState,
    used: *bool,
    last_constraint: *?Constraint,
    constraints: []const Constraint,
    is_soft: bool,
    options: graph.SolveOptions,
) !void {
    for (constraints) |constraint| {
        if (constraint.target_node != group_id) continue;
        if (graph.anchorAxis(constraint.target_anchor) != workspace.axis) continue;
        // A hard position and the tight child bounds determine the translated
        // group. Fallback must neither replace that position nor resize the
        // group by supplying a different anchor on the same axis.
        if (is_soft and (temp.start != null or temp.end != null or temp.center != null)) continue;
        if (is_soft and hasPositionedAncestor(workspace, group_id)) continue;
        used.* = true;
        last_constraint.* = constraint;

        switch (graph.classifySelfConstraint(constraint, workspace.axis)) {
            .none => {},
            .tautology => continue,
            .conflict => {
                if (!is_soft and options.record_diagnostics) {
                    try state.diagnostics.noteConstraintFailureDetailed(
                        state.allocator,
                        workspace.graph.page_id,
                        constraint,
                        graph.axisAnchorSource(temp.*, constraint.target_anchor),
                        .conflict,
                        .group_size_conflict,
                        workspace.axis,
                        graph.axisAnchorValue(temp.*, constraint.target_anchor),
                        null,
                    );
                }
                continue;
            },
            .size => |size| {
                if (size < -graph.ConstraintTolerance) {
                    if (!is_soft and options.record_diagnostics) {
                        try state.diagnostics.noteConstraintFailureDetailed(
                            state.allocator,
                            workspace.graph.page_id,
                            constraint,
                            temp.size_source,
                            .negative_frame_size,
                            .group_size_conflict,
                            workspace.axis,
                            size,
                            0,
                        );
                    }
                    continue;
                }
                _ = graph.setAxisSize(temp, size, constraint) catch |err| {
                    if (!is_soft and options.record_diagnostics) {
                        const kind: model.ConstraintFailureKind = if (err == error.ConstraintConflict) .conflict else .negative_frame_size;
                        try state.diagnostics.noteConstraintFailureDetailed(
                            state.allocator,
                            workspace.graph.page_id,
                            constraint,
                            temp.size_source,
                            kind,
                            .group_size_conflict,
                            workspace.axis,
                            temp.size,
                            size,
                        );
                    }
                    continue;
                };
                continue;
            },
        }

        const source_value = switch (constraint.source) {
            .page => try graph.constraintAffineSourceValue(state, workspace, constraint),
            .node => |node_source| blk: {
                if (node_source.node_id == group_id) {
                    const current = graph.axisAnchorValue(temp.*, node_source.anchor);
                    break :blk if (current != null) current else graph.axisAnchorValue(base, node_source.anchor);
                }
                break :blk try graph.constraintAffineSourceValue(state, workspace, constraint);
            },
        };
        if (source_value == null) continue;

        _ = graph.setAxisAnchor(temp, constraint.target_anchor, source_value.? + constraint.offset, constraint) catch |err| {
            if (!is_soft and options.record_diagnostics) {
                const kind: model.ConstraintFailureKind = if (err == error.ConstraintConflict) .conflict else .negative_frame_size;
                try state.diagnostics.noteConstraintFailureDetailed(
                    state.allocator,
                    workspace.graph.page_id,
                    constraint,
                    graph.axisAnchorSource(temp.*, constraint.target_anchor),
                    kind,
                    .group_size_conflict,
                    workspace.axis,
                    graph.axisAnchorValue(temp.*, constraint.target_anchor),
                    source_value.? + constraint.offset,
                );
            }
        };
    }
}

pub fn shiftAxisState(state: *AxisState, delta: f32) bool {
    return graph.shiftAxisState(state, delta);
}

pub fn translateSubtree(
    state: anytype,
    workspace: *graph.AxisWorkspace,
    group_id: NodeId,
    delta: f32,
) !bool {
    return try workspace.graph.translateSubgraph(workspace, state, group_id, delta);
}

pub const TargetUpdate = struct {
    changed: bool = false,
    constraint: ?Constraint = null,
};

pub fn applyTargetConstraints(
    state: anytype,
    workspace: *graph.AxisWorkspace,
    options: graph.SolveOptions,
) !TargetUpdate {
    var update = TargetUpdate{};
    var remaining = workspace.graph.group_order.len;
    while (remaining > 0) {
        remaining -= 1;
        const group_index = workspace.graph.group_order[remaining];
        const group_id = workspace.nodeAt(group_index);
        if (!workspace.graph.hasTargetConstraint(state, group_id, workspace.axis, workspace.soft_constraints)) continue;

        const base = try computeTightGroupAxisState(state, workspace, group_id);
        if (base.start == null or base.end == null or base.center == null or base.size == null) continue;

        var temp = AxisState{};
        var used = false;
        var last_constraint: ?Constraint = null;
        try applyGroupTargetConstraintSlice(state, workspace, group_id, base, &temp, &used, &last_constraint, workspace.hard_constraints, false, options);
        try applyGroupTargetConstraintSlice(state, workspace, group_id, base, &temp, &used, &last_constraint, workspace.soft_constraints, true, options);
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
        _ = graph.reconcileAxisState(&temp) catch |err| {
            if (options.record_diagnostics) {
                if (last_constraint) |constraint| {
                    const kind: model.ConstraintFailureKind = if (err == error.ConstraintConflict) .conflict else .negative_frame_size;
                    try state.diagnostics.noteConstraintFailureDetailed(
                        state.allocator,
                        workspace.graph.page_id,
                        constraint,
                        null,
                        kind,
                        .group_size_conflict,
                        workspace.axis,
                        temp.size,
                        base.size,
                    );
                }
            }
            continue;
        };

        const previous = workspace.states[group_index];
        const split_children = workspace.graph.hasSplitChildren(group_id);
        const child_bounds = if (!split_children and workspace.graph.splitFrame(group_id) != null)
            try computeChildGroupAxisState(state, workspace, group_id)
        else
            base;
        const delta = if (temp.start) |start| start - (child_bounds.start orelse start) else 0;
        // Split and frame-aligned children obtain their coordinates from parent
        // anchors. Subtree translation would apply their movement twice.
        const subtree_changed = if (split_children or hasChildrenAlignedToFrame(workspace, group_id)) false else try translateSubtree(state, workspace, group_id, delta);
        workspace.states[group_index] = temp;
        if (subtree_changed or !axisStatesEq(previous, temp)) {
            update.changed = true;
            update.constraint = last_constraint;
        }
    }
    return update;
}

fn hasChildrenAlignedToFrame(workspace: *const graph.AxisWorkspace, group_id: NodeId) bool {
    for (workspace.soft_constraints) |constraint| {
        if (!constraint.default_alignment or graph.anchorAxis(constraint.target_anchor) != workspace.axis) continue;
        switch (constraint.source) {
            .page => continue,
            .node => |source| if (source.node_id != group_id) continue,
        }
        for (workspace.graph.parentGroupIndexes(constraint.target_node)) |parent| {
            if (workspace.nodeAt(parent) == group_id) return true;
        }
    }
    return false;
}

fn hasPositionedAncestor(workspace: *const graph.AxisWorkspace, node_id: NodeId) bool {
    for (workspace.graph.parentGroupIndexes(node_id)) |index| {
        const parent_id = workspace.nodeAt(index);
        if (workspace.states[index].start != null) {
            for (workspace.graph.targetConstraintIndexes(parent_id)) |constraint_index| {
                const constraint = workspace.graph.constraints[constraint_index];
                if (graph.anchorAxis(constraint.target_anchor) != workspace.axis) continue;
                if (graph.classifySelfConstraint(constraint, workspace.axis) == .none) return true;
            }
        }
        if (hasPositionedAncestor(workspace, parent_id)) return true;
    }
    return false;
}

pub fn constraintUsesGroupSource(state: anytype, constraint: Constraint) bool {
    return switch (constraint.source) {
        .page => false,
        .node => |node_source| blk: {
            const source_node = state.getNode(node_source.node_id) orelse break :blk false;
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
    return graph.approxEq(a.?, b.?);
}

fn groupChildAxisBounds(state: anytype, workspace: *const graph.AxisWorkspace, child_id: NodeId) !struct { ?f32, ?f32 } {
    if (workspace.indexOf(child_id)) |index| {
        return .{
            graph.axisAnchorValue(workspace.states[index], switch (workspace.axis) {
                .horizontal => .left,
                .vertical => .bottom,
            }),
            graph.axisAnchorValue(workspace.states[index], switch (workspace.axis) {
                .horizontal => .right,
                .vertical => .top,
            }),
        };
    }

    const child = state.getNode(child_id) orelse return error.UnknownNode;
    const start_anchor: Anchor = switch (workspace.axis) {
        .horizontal => .left,
        .vertical => .bottom,
    };
    const end_anchor: Anchor = switch (workspace.axis) {
        .horizontal => .right,
        .vertical => .top,
    };
    if (!graph.anchorKnown(child.frame, start_anchor) or !graph.anchorKnown(child.frame, end_anchor)) return .{ null, null };
    return .{ graph.anchorValue(child.frame, start_anchor), graph.anchorValue(child.frame, end_anchor) };
}

pub fn isGroupNode(node: *const Node) bool {
    return roleEq(node.role, GroupRole);
}
