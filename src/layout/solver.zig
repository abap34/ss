const std = @import("std");
const model = @import("model");
const diagnostics = @import("diagnostics.zig");
const fallback = @import("fallback.zig");
const graph = @import("graph.zig");
const groups = @import("groups.zig");
const metrics = @import("metrics.zig");
const style_defaults = @import("style.zig");

const NodeId = model.NodeId;
const Node = model.Node;
const Axis = model.Axis;
const AxisState = model.AxisState;
const Anchor = model.Anchor;
const Constraint = model.Constraint;
const ConstraintSource = model.ConstraintSource;
const Frame = model.Frame;
const PageLayout = model.PageLayout;
const TextStyle = model.TextStyle;
const ConstraintTolerance = graph.ConstraintTolerance;

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
    var page_graph = try graph.PageLayoutGraph.init(ir.allocator, ir, page_id);
    defer page_graph.deinit();
    if (page_graph.len() == 0) return;

    var horizontal = try graph.AxisWorkspace.init(ir.allocator, ir, &page_graph, .horizontal);
    defer horizontal.deinit();
    var vertical = try graph.AxisWorkspace.init(ir.allocator, ir, &page_graph, .vertical);
    defer vertical.deinit();

    try solvePageAxis(ir, &horizontal);

    var horizontal_fallback = try fallback.buildHorizontalConstraints(ir, &horizontal);
    defer horizontal_fallback.deinit(ir.allocator);
    horizontal.soft_constraints = horizontal_fallback.items;
    try solvePageAxis(ir, &horizontal);
    try finalizeHorizontalGroupStates(ir, &horizontal);
    applySolvedHorizontalFrames(ir, &horizontal) catch return error.UnknownNode;
    try groups.propagateTargetedWidths(ir, &horizontal);

    try solvePageAxis(ir, &vertical);
    var vertical_fallback = try fallback.buildVerticalConstraints(ir, &vertical);
    defer vertical_fallback.deinit(ir.allocator);
    vertical.soft_constraints = vertical_fallback.items;
    try solvePageAxis(ir, &vertical);

    for (page_graph.child_ids, vertical.states) |child_id, v_state| {
        const node = ir.getNode(child_id) orelse return error.UnknownNode;
        node.frame.height = v_state.size orelse node.frame.height;
        node.frame.y_set = false;
        if (v_state.start) |y| {
            node.frame.y = y;
            node.frame.y_set = true;
        }
    }

    try diagnostics.collectPageDiagnostics(ir, page_id, page_graph.child_ids);
}

fn applySolvedHorizontalFrames(ir: anytype, workspace: *const graph.AxisWorkspace) !void {
    for (workspace.graph.child_ids, workspace.states) |child_id, h_state| {
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

fn finalizeHorizontalGroupStates(ir: anytype, workspace: *graph.AxisWorkspace) !void {
    var pass: usize = 0;
    while (pass < 8) : (pass += 1) {
        var changed = false;
        changed = (try capDefaultWrappedHorizontalWidths(ir, workspace)) or changed;
        changed = (try groups.applyTargetConstraints(ir, workspace)) or changed;
        changed = (try groups.updateAxisStates(ir, workspace)) or changed;
        if (!changed) break;
    }
}

fn capDefaultWrappedHorizontalWidths(ir: anytype, workspace: *graph.AxisWorkspace) !bool {
    var changed = false;
    for (workspace.graph.child_ids, workspace.states) |child_id, *state| {
        if (!state.size_is_default) continue;
        if (state.start == null or state.size == null) continue;
        if (state.end_source != null or state.size_source != null) continue;

        const node = ir.getNode(child_id) orelse return error.UnknownNode;
        if (groups.isGroupNode(node)) continue;
        if (!shouldWrapNode(ir, node)) continue;

        const style = styleForNode(ir, node);
        const max_right = PageLayout.width - style.default_right_inset;
        const capped_width = @max(@as(f32, 1.0), max_right - state.start.?);
        if (capped_width >= state.size.? - ConstraintTolerance) continue;

        state.size = capped_width;
        state.end = state.start.? + capped_width;
        state.center = state.start.? + capped_width / 2;
        state.end_source = null;
        state.center_source = null;
        changed = true;
    }
    return changed;
}

fn solvePageAxis(ir: anytype, workspace: *graph.AxisWorkspace) !void {
    try runPageAxisPass(ir, workspace);

    for (workspace.graph.child_ids, workspace.states) |child_id, *state| {
        if (state.size == null) {
            const node = ir.getNode(child_id) orelse return error.UnknownNode;
            state.size = switch (workspace.axis) {
                .horizontal => node.frame.width,
                .vertical => node.frame.height,
            };
            state.size_is_default = true;
        }
    }

    try runPageAxisPass(ir, workspace);
}

pub fn hasAxisTargetConstraint(ir: anytype, node_id: NodeId, axis: Axis) bool {
    for (ir.constraints.items) |constraint| {
        if (constraint.target_node != node_id) continue;
        if (anchorAxis(constraint.target_anchor) != axis) continue;
        return true;
    }
    return false;
}

pub fn runPageAxisPass(ir: anytype, workspace: *graph.AxisWorkspace) !void {
    var pass: usize = 0;
    while (pass < 32) : (pass += 1) {
        var changed = false;
        var local_pass: usize = 0;
        while (local_pass < 32) : (local_pass += 1) {
            var local_changed = false;

            for (workspace.states) |*state| {
                local_changed = (try reconcileAxisStateLocalized(ir, workspace.graph.page_id, state)) or local_changed;
            }

            for (ir.constraints.items) |constraint| {
                if (groups.constraintTargetsGroup(ir, constraint)) continue;
                if (groups.constraintUsesGroupSource(ir, constraint)) continue;
                local_changed = (try applyAxisConstraint(ir, workspace, constraint, false)) or local_changed;
            }

            for (workspace.soft_constraints) |constraint| {
                if (groups.constraintTargetsGroup(ir, constraint)) continue;
                if (groups.constraintUsesGroupSource(ir, constraint)) continue;
                local_changed = (try applyAxisConstraint(ir, workspace, constraint, true)) or local_changed;
            }

            changed = local_changed or changed;
            if (!local_changed) break;
        }

        changed = (try groups.updateAxisStates(ir, workspace)) or changed;
        changed = (try groups.applyTargetConstraints(ir, workspace)) or changed;

        for (ir.constraints.items) |constraint| {
            if (!groups.constraintUsesGroupSource(ir, constraint)) continue;
            changed = (try applyAxisConstraint(ir, workspace, constraint, false)) or changed;
        }

        for (workspace.soft_constraints) |constraint| {
            if (!groups.constraintUsesGroupSource(ir, constraint)) continue;
            changed = (try applyAxisConstraint(ir, workspace, constraint, true)) or changed;
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

fn applyAxisConstraint(ir: anytype, workspace: *graph.AxisWorkspace, constraint: Constraint, is_soft: bool) !bool {
    if (anchorAxis(constraint.target_anchor) != workspace.axis) return false;

    const target_page = ir.parentPageOf(constraint.target_node) orelse return error.MissingParentPage;
    if (target_page != workspace.graph.page_id) return false;

    const target_index = workspace.indexOf(constraint.target_node) orelse return error.UnknownNode;
    const target_node = ir.getNode(constraint.target_node) orelse return error.UnknownNode;
    if (groups.isGroupNode(target_node)) return false;

    if (selfReferentialSize(constraint, workspace.axis)) |size| {
        if (size < -ConstraintTolerance) {
            if (is_soft) return false;
            ir.noteConstraintFailure(workspace.graph.page_id, constraint, workspace.states[target_index].size_source, .negative_size);
            return false;
        }
        if (is_soft and workspace.states[target_index].size != null) return false;
        return setAxisSize(&workspace.states[target_index], size, constraint) catch |err| {
            if (is_soft) return false;
            const kind: model.ConstraintFailureKind = if (err == error.ConstraintConflict) .conflict else .negative_size;
            ir.noteConstraintFailure(workspace.graph.page_id, constraint, workspace.states[target_index].size_source, kind);
            return false;
        };
    }

    if (is_soft and axisAnchorValue(workspace.states[target_index], constraint.target_anchor) != null) {
        return false;
    }

    const source_value = try constraintSourceValue(ir, workspace, constraint.source);
    if (source_value == null) {
        return try applyReverseAxisConstraint(ir, workspace, constraint, is_soft, target_index);
    }

    return setAxisAnchor(&workspace.states[target_index], constraint.target_anchor, source_value.? + constraint.offset, constraint) catch |err| {
        if (is_soft) return false;
        const kind: model.ConstraintFailureKind = if (err == error.ConstraintConflict) .conflict else .negative_size;
        ir.noteConstraintFailure(workspace.graph.page_id, constraint, axisAnchorSource(workspace.states[target_index], constraint.target_anchor), kind);
        return false;
    };
}

fn applyReverseAxisConstraint(
    ir: anytype,
    workspace: *graph.AxisWorkspace,
    constraint: Constraint,
    is_soft: bool,
    target_index: usize,
) !bool {
    if (is_soft) return false;

    const node_source = switch (constraint.source) {
        .page => return false,
        .node => |source| source,
    };
    if (anchorAxis(node_source.anchor) != workspace.axis) return error.ConstraintAxisMismatch;

    const source_node = ir.getNode(node_source.node_id) orelse return error.UnknownNode;
    if (groups.isGroupNode(source_node)) return false;

    const source_page = ir.parentPageOf(node_source.node_id) orelse return error.MissingParentPage;
    if (source_page != workspace.graph.page_id) return false;

    const source_index = workspace.indexOf(node_source.node_id) orelse return false;
    if (axisAnchorValue(workspace.states[source_index], node_source.anchor) != null) return false;

    const target_value = axisAnchorValue(workspace.states[target_index], constraint.target_anchor) orelse return false;
    return setAxisAnchor(&workspace.states[source_index], node_source.anchor, target_value - constraint.offset, constraint) catch |err| {
        const kind: model.ConstraintFailureKind = if (err == error.ConstraintConflict) .conflict else .negative_size;
        ir.noteConstraintFailure(workspace.graph.page_id, constraint, axisAnchorSource(workspace.states[source_index], node_source.anchor), kind);
        return false;
    };
}

pub fn selfReferentialSize(constraint: Constraint, axis: Axis) ?f32 {
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

pub fn constraintSourceValue(ir: anytype, workspace: *const graph.AxisWorkspace, source: ConstraintSource) !?f32 {
    return switch (source) {
        .page => |anchor| blk: {
            if (anchorAxis(anchor) != workspace.axis) return error.ConstraintAxisMismatch;
            const page = ir.getNode(workspace.graph.page_id) orelse return error.UnknownNode;
            break :blk anchorValue(page.frame, anchor);
        },
        .node => |node_source| blk: {
            if (anchorAxis(node_source.anchor) != workspace.axis) return error.ConstraintAxisMismatch;
            if (workspace.indexOf(node_source.node_id)) |index| {
                break :blk axisAnchorValue(workspace.states[index], node_source.anchor);
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

pub fn indexOfNode(ids: []const NodeId, target: NodeId) ?usize {
    for (ids, 0..) |id, index| {
        if (id == target) return index;
    }
    return null;
}

pub fn axisAnchorValue(state: AxisState, anchor: Anchor) ?f32 {
    return switch (anchor) {
        .left, .bottom => state.start,
        .right, .top => state.end,
        .center_x, .center_y => state.center,
    };
}

pub fn axisAnchorSource(state: AxisState, anchor: Anchor) ?Constraint {
    return switch (anchor) {
        .left, .bottom => state.start_source,
        .right, .top => state.end_source,
        .center_x, .center_y => state.center_source,
    };
}

pub fn setAxisAnchor(state: *AxisState, anchor: Anchor, value: f32, source: ?Constraint) !bool {
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

pub fn reconcileAxisState(state: *AxisState) !bool {
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
    if (size < -ConstraintTolerance) return error.NegativeConstraintSize;
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

pub fn setAxisSize(state: *AxisState, value: f32, source: ?Constraint) !bool {
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

pub fn anchorKnown(frame: Frame, anchor: Anchor) bool {
    return switch (anchor) {
        .left, .right, .center_x => frame.x_set,
        .top, .bottom, .center_y => frame.y_set,
    };
}

pub fn anchorValue(frame: Frame, anchor: Anchor) f32 {
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
    return graph.approxEq(a, b);
}
