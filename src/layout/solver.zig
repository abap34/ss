const model = @import("model");
const diagnostics = @import("diagnostics.zig");
const fallback = @import("fallback.zig");
const graph = @import("graph.zig");
const groups = @import("groups.zig");
const metrics = @import("metrics.zig");
const style_defaults = @import("style.zig");

const NodeId = model.NodeId;
const AxisState = model.AxisState;
const Constraint = model.Constraint;
const PageLayout = model.PageLayout;
const ConstraintTolerance = graph.ConstraintTolerance;

pub const SolveOptions = graph.SolveOptions;

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
            .object => {
                node.frame.x = 0;
                node.frame.y = 0;
                node.frame.x_set = false;
                node.frame.y_set = false;
                node.frame.width = metrics.intrinsicWidth(ir, node);
                node.frame.height = metrics.intrinsicHeight(ir, node);
            },
        }
    }

    for (ir.page_order.items) |page_id| {
        try solvePageLayout(ir, page_id);
    }
}

fn solvePageLayout(ir: anytype, page_id: NodeId) !void {
    var page_graph = try graph.PageLayoutGraph.init(ir.allocator, ir, page_id);
    defer page_graph.deinit();
    if (page_graph.len() == 0) return;

    var horizontal = try graph.AxisWorkspace.init(ir.allocator, ir, &page_graph, .horizontal);
    defer horizontal.deinit();

    try solvePageAxis(ir, &horizontal);

    var horizontal_fallback = try fallback.buildHorizontalConstraints(ir, &horizontal);
    defer horizontal_fallback.deinit(ir.allocator);
    horizontal.soft_constraints = horizontal_fallback.items;
    try solvePageAxis(ir, &horizontal);
    try settleHorizontalAxis(ir, &horizontal);
    applySolvedHorizontalFrames(ir, &horizontal) catch return error.UnknownNode;
    try groups.propagateTargetedWidths(ir, &horizontal);

    var vertical = try graph.AxisWorkspace.init(ir.allocator, ir, &page_graph, .vertical);
    defer vertical.deinit();

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
        if (metrics.shouldWrapNode(ir, node)) {
            node.frame.height = metrics.intrinsicHeight(ir, node);
        }
        node.frame.x_set = false;
        if (h_state.start) |x| {
            node.frame.x = x;
            node.frame.x_set = true;
        }
    }
}

fn settleHorizontalAxis(ir: anytype, workspace: *graph.AxisWorkspace) !void {
    var pass: usize = 0;
    while (pass < 8) : (pass += 1) {
        try finalizeHorizontalGroupStates(ir, workspace);
        try runPageAxisPass(ir, workspace);
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
        if (!metrics.shouldWrapNode(ir, node)) continue;

        const style = style_defaults.styleForNode(ir, node);
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

pub fn runPageAxisPass(ir: anytype, workspace: *graph.AxisWorkspace) !void {
    return runPageAxisPassWithOptions(ir, workspace, .{});
}

pub fn runPageAxisPassWithOptions(ir: anytype, workspace: *graph.AxisWorkspace, options: SolveOptions) !void {
    var pass: usize = 0;
    while (pass < 32) : (pass += 1) {
        var changed = false;
        var local_pass: usize = 0;
        while (local_pass < 32) : (local_pass += 1) {
            var local_changed = false;

            for (workspace.states) |*state| {
                local_changed = (try reconcileAxisStateLocalized(ir, workspace.graph.page_id, state, options)) or local_changed;
            }

            for (ir.constraints.items) |constraint| {
                if (groups.constraintTargetsGroup(ir, constraint)) continue;
                if (groups.constraintUsesGroupSource(ir, constraint)) continue;
                local_changed = (try applyAxisConstraint(ir, workspace, constraint, false, options)) or local_changed;
            }

            for (workspace.soft_constraints) |constraint| {
                if (groups.constraintTargetsGroup(ir, constraint)) continue;
                if (groups.constraintUsesGroupSource(ir, constraint)) continue;
                local_changed = (try applyAxisConstraint(ir, workspace, constraint, true, options)) or local_changed;
            }

            changed = local_changed or changed;
            if (!local_changed) break;
        }

        changed = (try groups.updateAxisStates(ir, workspace)) or changed;
        changed = (try groups.applyTargetConstraintsWithOptions(ir, workspace, options)) or changed;

        for (ir.constraints.items) |constraint| {
            if (!groups.constraintUsesGroupSource(ir, constraint)) continue;
            changed = (try applyAxisConstraint(ir, workspace, constraint, false, options)) or changed;
        }

        for (workspace.soft_constraints) |constraint| {
            if (!groups.constraintUsesGroupSource(ir, constraint)) continue;
            changed = (try applyAxisConstraint(ir, workspace, constraint, true, options)) or changed;
        }

        if (!changed) break;
    }
}

fn reconcileAxisStateLocalized(ir: anytype, page_id: NodeId, state: *AxisState, options: SolveOptions) !bool {
    return graph.reconcileAxisState(state) catch |err| switch (err) {
        error.ConstraintConflict, error.NegativeConstraintSize => blk: {
            const incoming = state.size_source orelse state.end_source orelse state.start_source orelse state.center_source;
            const existing = pickReconcileExistingSource(state, incoming);
            if (options.record_diagnostics) {
                if (incoming) |c| {
                    const kind: model.ConstraintFailureKind = if (err == error.ConstraintConflict) .conflict else .negative_size;
                    ir.noteConstraintFailure(page_id, c, existing, kind);
                }
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

fn applyAxisConstraint(ir: anytype, workspace: *graph.AxisWorkspace, constraint: Constraint, is_soft: bool, options: SolveOptions) !bool {
    if (graph.anchorAxis(constraint.target_anchor) != workspace.axis) return false;

    const target_index = workspace.indexOf(constraint.target_node) orelse return false;
    const target_node = ir.getNode(constraint.target_node) orelse return error.UnknownNode;
    if (groups.isGroupNode(target_node)) return false;

    if (graph.selfReferentialSize(constraint, workspace.axis)) |size| {
        if (size < -ConstraintTolerance) {
            if (is_soft) return false;
            if (options.record_diagnostics) {
                ir.noteConstraintFailure(workspace.graph.page_id, constraint, workspace.states[target_index].size_source, .negative_size);
            }
            return false;
        }
        if (is_soft and workspace.states[target_index].size != null) return false;
        return graph.setAxisSize(&workspace.states[target_index], size, constraint) catch |err| {
            if (is_soft) return false;
            if (options.record_diagnostics) {
                const kind: model.ConstraintFailureKind = if (err == error.ConstraintConflict) .conflict else .negative_size;
                ir.noteConstraintFailure(workspace.graph.page_id, constraint, workspace.states[target_index].size_source, kind);
            }
            return false;
        };
    }

    if (is_soft and graph.axisAnchorValue(workspace.states[target_index], constraint.target_anchor) != null) {
        return false;
    }

    const source_value = try graph.constraintSourceValue(ir, workspace, constraint.source);
    if (source_value == null) {
        return try applyReverseAxisConstraint(ir, workspace, constraint, is_soft, target_index, options);
    }

    return graph.setAxisAnchor(&workspace.states[target_index], constraint.target_anchor, source_value.? + constraint.offset, constraint) catch |err| {
        if (is_soft) return false;
        if (options.record_diagnostics) {
            const kind: model.ConstraintFailureKind = if (err == error.ConstraintConflict) .conflict else .negative_size;
            ir.noteConstraintFailure(workspace.graph.page_id, constraint, graph.axisAnchorSource(workspace.states[target_index], constraint.target_anchor), kind);
        }
        return false;
    };
}

fn applyReverseAxisConstraint(
    ir: anytype,
    workspace: *graph.AxisWorkspace,
    constraint: Constraint,
    is_soft: bool,
    target_index: usize,
    options: SolveOptions,
) !bool {
    if (is_soft) return false;

    const node_source = switch (constraint.source) {
        .page => return false,
        .node => |source| source,
    };
    if (graph.anchorAxis(node_source.anchor) != workspace.axis) return error.ConstraintAxisMismatch;

    const source_node = ir.getNode(node_source.node_id) orelse return error.UnknownNode;
    if (groups.isGroupNode(source_node)) return false;

    const source_index = workspace.indexOf(node_source.node_id) orelse return false;
    if (graph.axisAnchorValue(workspace.states[source_index], node_source.anchor) != null) return false;

    const target_state = workspace.states[target_index];
    if (target_state.size_is_default and graph.axisAnchorSource(target_state, constraint.target_anchor) == null) return false;

    const target_value = graph.axisAnchorValue(target_state, constraint.target_anchor) orelse return false;
    return graph.setAxisAnchor(&workspace.states[source_index], node_source.anchor, target_value - constraint.offset, constraint) catch |err| {
        if (options.record_diagnostics) {
            const kind: model.ConstraintFailureKind = if (err == error.ConstraintConflict) .conflict else .negative_size;
            ir.noteConstraintFailure(workspace.graph.page_id, constraint, graph.axisAnchorSource(workspace.states[source_index], node_source.anchor), kind);
        }
        return false;
    };
}
