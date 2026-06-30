const std = @import("std");
const model = @import("model");
const diagnostics = @import("diagnostics.zig");
const fallback = @import("fallback.zig");
const graph = @import("graph.zig");
const groups = @import("groups.zig");
const metrics = @import("metrics.zig");
const style_defaults = @import("style.zig");
const layout_trace = @import("trace.zig");
const utils = @import("utils");

const NodeId = model.NodeId;
const AxisState = model.AxisState;
const Constraint = model.Constraint;
const PageLayout = model.PageLayout;
const ConstraintTolerance = graph.ConstraintTolerance;

pub const SolveOptions = graph.SolveOptions;

pub fn solveLayout(ir: anytype) !void {
    try solveLayoutWithTracePath(ir, null);
}

pub fn solveLayoutWithTracePath(ir: anytype, trace_path: ?[]const u8) !void {
    try solveLayoutWithTracePathAndOptions(ir, trace_path, .{});
}

pub fn solveLayoutWithTracePathAndOptions(ir: anytype, trace_path: ?[]const u8, options: SolveOptions) !void {
    layout_trace.beginSolve(ir.allocator, trace_path);
    defer layout_trace.endSolve(ir.allocator);

    var measurement_cache = metrics.MeasurementCache.initWithRenderProvider(ir.allocator, options.measurement_provider);
    defer measurement_cache.deinit();

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
                node.frame.width = try metrics.intrinsicWidthCached(ir, node, &measurement_cache);
                node.frame.height = try metrics.intrinsicHeightCached(ir, node, &measurement_cache);
            },
        }
    }

    for (ir.page_order.items) |page_id| {
        try solvePageLayout(ir, page_id, &measurement_cache, options);
    }
}

fn solvePageLayout(ir: anytype, page_id: NodeId, measurement_cache: *metrics.MeasurementCache, options: SolveOptions) !void {
    var page_graph = try graph.PageLayoutGraph.init(ir.allocator, ir, page_id);
    defer page_graph.deinit();
    if (page_graph.len() == 0) return;

    var horizontal = try graph.AxisWorkspace.init(ir.allocator, ir, &page_graph, .horizontal);
    defer horizontal.deinit();
    var horizontal_propagation: ?graph.PropagationTracker = null;
    defer if (horizontal_propagation) |*tracker| tracker.deinit();
    if (options.record_propagation) {
        horizontal_propagation = try graph.PropagationTracker.init(ir.allocator, page_graph.len());
        if (horizontal_propagation) |*tracker| horizontal.propagation = tracker;
    }

    try solvePageAxis(ir, &horizontal, options);

    var horizontal_fallback = try fallback.buildHorizontalConstraints(ir, &horizontal);
    defer horizontal_fallback.deinit(ir.allocator);
    layout_trace.recordDefaultConstraints(ir.allocator, &horizontal, horizontal_fallback.items);
    horizontal.soft_constraints = horizontal_fallback.items;
    try solvePageAxis(ir, &horizontal, options);
    try settleHorizontalAxis(ir, &horizontal, options);
    applySolvedHorizontalFrames(ir, &horizontal, measurement_cache) catch return error.UnknownNode;
    try groups.propagateTargetedWidthsCached(ir, &horizontal, measurement_cache);

    var vertical = try graph.AxisWorkspace.init(ir.allocator, ir, &page_graph, .vertical);
    defer vertical.deinit();
    var vertical_propagation: ?graph.PropagationTracker = null;
    defer if (vertical_propagation) |*tracker| tracker.deinit();
    if (options.record_propagation) {
        vertical_propagation = try graph.PropagationTracker.init(ir.allocator, page_graph.len());
        if (vertical_propagation) |*tracker| vertical.propagation = tracker;
    }

    try solvePageAxis(ir, &vertical, options);
    var vertical_fallback = try fallback.buildVerticalConstraints(ir, &vertical);
    defer vertical_fallback.deinit(ir.allocator);
    layout_trace.recordDefaultConstraints(ir.allocator, &vertical, vertical_fallback.items);
    vertical.soft_constraints = vertical_fallback.items;
    try solvePageAxis(ir, &vertical, options);

    for (page_graph.child_ids, vertical.states) |child_id, v_state| {
        const node = ir.getNode(child_id) orelse return error.UnknownNode;
        node.frame.height = v_state.size orelse node.frame.height;
        node.frame.y_set = false;
        if (v_state.start) |y| {
            node.frame.y = y;
            node.frame.y_set = true;
        }
    }

    try validatePageConstraints(ir, page_id, &page_graph, options);
    try diagnostics.collectPageDiagnosticsCached(ir, page_id, page_graph.child_ids, measurement_cache);
}

fn applySolvedHorizontalFrames(ir: anytype, workspace: *const graph.AxisWorkspace, measurement_cache: *metrics.MeasurementCache) !void {
    for (workspace.graph.child_ids, workspace.states) |child_id, h_state| {
        const node = ir.getNode(child_id) orelse return error.UnknownNode;
        const old_width = node.frame.width;
        const solved_width = h_state.size orelse old_width;
        node.frame.width = solved_width;
        if (metrics.shouldWrapNode(ir, node) and @abs(solved_width - old_width) > ConstraintTolerance) {
            node.frame.height = try metrics.intrinsicHeightCached(ir, node, measurement_cache);
        }
        node.frame.x_set = false;
        if (h_state.start) |x| {
            node.frame.x = x;
            node.frame.x_set = true;
        }
    }
}

fn settleHorizontalAxis(ir: anytype, workspace: *graph.AxisWorkspace, options: SolveOptions) !void {
    var pass: usize = 0;
    while (pass < 8) : (pass += 1) {
        var changed = try finalizeHorizontalGroupStates(ir, workspace, options);
        changed = (try runPageAxisPass(ir, workspace, options)) or changed;
        if (!changed) break;
    }
}

fn finalizeHorizontalGroupStates(ir: anytype, workspace: *graph.AxisWorkspace, options: SolveOptions) !bool {
    var any_changed = false;
    var pass: usize = 0;
    while (pass < 8) : (pass += 1) {
        var changed = false;
        changed = (try capDefaultWrappedHorizontalWidths(ir, workspace)) or changed;
        changed = (try groups.applyTargetConstraints(ir, workspace, options)) or changed;
        changed = (try groups.updateAxisStates(ir, workspace)) or changed;
        any_changed = changed or any_changed;
        if (!changed) break;
    }
    return any_changed;
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

fn solvePageAxis(ir: anytype, workspace: *graph.AxisWorkspace, options: SolveOptions) !void {
    _ = try runPageAxisPass(ir, workspace, options);

    for (workspace.graph.child_ids, workspace.states, 0..) |child_id, *state, index| {
        if (state.size == null) {
            const node = ir.getNode(child_id) orelse return error.UnknownNode;
            state.size = switch (workspace.axis) {
                .horizontal => node.frame.width,
                .vertical => node.frame.height,
            };
            state.size_is_default = true;
            try recordDefaultSizePropagation(ir, workspace, index, state.size.?);
        }
    }

    _ = try runPageAxisPass(ir, workspace, options);
}

pub fn runPageAxisPass(ir: anytype, workspace: *graph.AxisWorkspace, options: SolveOptions) !bool {
    const trace_enabled = layout_trace.shouldTraceAxisPass(workspace);
    const run_id = if (trace_enabled) layout_trace.nextRunId() else 0;
    if (trace_enabled) layout_trace.axisPassBegin(ir.allocator, ir, workspace, run_id);

    var pass: usize = 0;
    var iteration_count: usize = 0;
    var converged = false;
    var any_changed = false;
    while (pass < 32) : (pass += 1) {
        iteration_count = pass + 1;
        var changed = false;
        var local_pass: usize = 0;
        var local_iterations: usize = 0;
        while (local_pass < 32) : (local_pass += 1) {
            local_iterations += 1;
            var local_changed = false;

            for (workspace.states, 0..) |*state, index| {
                local_changed = (try reconcileAxisStateLocalized(ir, workspace, index, state, options)) or local_changed;
            }

            for (workspace.hard_constraints) |constraint| {
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

        const group_bounds_changed = try groups.updateAxisStates(ir, workspace);
        changed = group_bounds_changed or changed;
        const group_targets_changed = try groups.applyTargetConstraints(ir, workspace, options);
        changed = group_targets_changed or changed;

        var group_sources_changed = false;
        for (workspace.hard_constraints) |constraint| {
            if (!groups.constraintUsesGroupSource(ir, constraint)) continue;
            const applied = try applyAxisConstraint(ir, workspace, constraint, false, options);
            group_sources_changed = applied or group_sources_changed;
            changed = applied or changed;
        }

        var soft_group_sources_changed = false;
        for (workspace.soft_constraints) |constraint| {
            if (!groups.constraintUsesGroupSource(ir, constraint)) continue;
            const applied = try applyAxisConstraint(ir, workspace, constraint, true, options);
            soft_group_sources_changed = applied or soft_group_sources_changed;
            changed = applied or changed;
        }

        if (trace_enabled) {
            layout_trace.axisPassIteration(
                ir.allocator,
                ir,
                run_id,
                workspace,
                pass,
                local_iterations,
                changed,
                group_bounds_changed,
                group_targets_changed,
                group_sources_changed,
                soft_group_sources_changed,
            );
        }

        any_changed = changed or any_changed;
        if (!changed) {
            converged = true;
            break;
        }
    }

    if (trace_enabled) layout_trace.axisPassEnd(ir.allocator, ir, run_id, workspace, iteration_count, converged);
    return any_changed;
}

fn reconcileAxisStateLocalized(ir: anytype, workspace: *graph.AxisWorkspace, index: usize, state: *AxisState, options: SolveOptions) !bool {
    const changed = graph.reconcileAxisState(state) catch |err| switch (err) {
        error.ConstraintConflict, error.NegativeFrameSize => blk: {
            const incoming = state.size_source orelse state.end_source orelse state.start_source orelse state.center_source;
            const existing = pickReconcileExistingSource(state, incoming);
            if (options.record_diagnostics) {
                if (incoming) |c| {
                    const kind: model.ConstraintFailureKind = if (err == error.ConstraintConflict) .conflict else .negative_frame_size;
                    const propagation = try reconciliationFailurePropagation(ir, workspace, index, state, err);
                    ir.noteConstraintFailureDetailedWithPropagation(
                        workspace.graph.page_id,
                        c,
                        existing,
                        kind,
                        if (err == error.ConstraintConflict) .anchor_value_conflict else .negative_frame_size,
                        workspace.axis,
                        null,
                        null,
                        propagation,
                    );
                }
            }
            break :blk false;
        },
    };
    if (changed) try recordReconciledPropagation(ir, workspace, index);
    return changed;
}

fn reconcileAppliedAxisState(ir: anytype, workspace: *graph.AxisWorkspace, index: usize) !void {
    const changed = graph.reconcileAxisState(&workspace.states[index]) catch return;
    if (changed) try recordReconciledPropagation(ir, workspace, index);
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

    switch (graph.classifySelfConstraint(constraint, workspace.axis)) {
        .none => {},
        .tautology => return false,
        .conflict => {
            if (!is_soft and options.record_diagnostics) {
                ir.noteConstraintFailureDetailed(
                    workspace.graph.page_id,
                    constraint,
                    graph.axisAnchorSource(workspace.states[target_index], constraint.target_anchor),
                    .conflict,
                    .anchor_value_conflict,
                    workspace.axis,
                    graph.axisAnchorValue(workspace.states[target_index], constraint.target_anchor),
                    null,
                );
            }
            return false;
        },
        .size => |size| {
            if (size < -ConstraintTolerance) {
                if (is_soft) return false;
                if (options.record_diagnostics) {
                    const propagation = try negativeSizePropagation(ir, workspace, target_index, constraint, size);
                    ir.noteConstraintFailureDetailedWithPropagation(
                        workspace.graph.page_id,
                        constraint,
                        workspace.states[target_index].size_source,
                        .negative_frame_size,
                        .negative_frame_size,
                        workspace.axis,
                        size,
                        0,
                        propagation,
                    );
                }
                return false;
            }
            if (is_soft and workspace.states[target_index].size != null) return false;
            const applied = graph.setAxisSize(&workspace.states[target_index], size, constraint) catch |err| {
                if (is_soft) return false;
                if (options.record_diagnostics) {
                    if (err == error.ConstraintConflict) {
                        const propagation = try sizeConflictPropagation(ir, workspace, target_index, constraint, workspace.states[target_index].size, size);
                        ir.noteConstraintFailureDetailedWithPropagation(
                            workspace.graph.page_id,
                            constraint,
                            workspace.states[target_index].size_source,
                            .conflict,
                            .overconstrained_frame,
                            workspace.axis,
                            workspace.states[target_index].size,
                            size,
                            propagation,
                        );
                    } else {
                        const propagation = try negativeSizePropagation(ir, workspace, target_index, constraint, size);
                        ir.noteConstraintFailureDetailedWithPropagation(
                            workspace.graph.page_id,
                            constraint,
                            workspace.states[target_index].size_source,
                            .negative_frame_size,
                            .negative_frame_size,
                            workspace.axis,
                            size,
                            0,
                            propagation,
                        );
                    }
                }
                return false;
            };
            if (applied or shouldRecordSizeConstraintPropagation(workspace, target_index)) {
                try recordSizeConstraintPropagation(ir, workspace, target_index, constraint, size);
            }
            if (applied) {
                layout_trace.recordConstraintPropagation(ir.allocator, workspace, constraint, is_soft, false);
            }
            return applied;
        },
    }

    if (is_soft and graph.axisAnchorValue(workspace.states[target_index], constraint.target_anchor) != null) {
        return false;
    }

    const source_value = try graph.constraintSourceValue(ir, workspace, constraint.source);
    if (source_value == null) {
        return try applyReverseAxisConstraint(ir, workspace, constraint, is_soft, target_index, options);
    }

    const target_value = source_value.? + constraint.offset;
    if (!is_soft and canMoveDefaultSizedAnchor(ir, workspace, target_index)) {
        if (try graph.moveDefaultSizedAnchor(&workspace.states[target_index], constraint.target_anchor, target_value, constraint)) {
            try reconcileAppliedAxisState(ir, workspace, target_index);
            try recordAnchorConstraintPropagation(ir, workspace, target_index, constraint, target_value);
            layout_trace.recordConstraintPropagation(ir.allocator, workspace, constraint, is_soft, false);
            return true;
        }
    }

    if (!is_soft and shouldReplaceDefaultGeometry(ir, workspace, target_index, constraint.target_anchor)) {
        if (graph.replaceAxisAnchor(&workspace.states[target_index], constraint.target_anchor, target_value, constraint)) {
            try reconcileAppliedAxisState(ir, workspace, target_index);
            try recordAnchorConstraintPropagation(ir, workspace, target_index, constraint, target_value);
            layout_trace.recordConstraintPropagation(ir.allocator, workspace, constraint, is_soft, false);
            return true;
        }
    }

    const applied = graph.setAxisAnchor(&workspace.states[target_index], constraint.target_anchor, target_value, constraint) catch |err| {
        if (!is_soft and err == error.ConstraintConflict and canMoveDefaultSizedAnchor(ir, workspace, target_index)) {
            if (try graph.moveDefaultSizedAnchor(&workspace.states[target_index], constraint.target_anchor, target_value, constraint)) {
                try reconcileAppliedAxisState(ir, workspace, target_index);
                try recordAnchorConstraintPropagation(ir, workspace, target_index, constraint, target_value);
                layout_trace.recordConstraintPropagation(ir.allocator, workspace, constraint, is_soft, false);
                return true;
            }
        }
        if (!is_soft and err == error.ConstraintConflict and canReplaceDuplicateDefaultAnchor(ir, workspace, target_index, constraint.target_anchor)) {
            if (try graph.moveDefaultSizedAnchor(&workspace.states[target_index], constraint.target_anchor, target_value, constraint)) {
                try reconcileAppliedAxisState(ir, workspace, target_index);
                try recordAnchorConstraintPropagation(ir, workspace, target_index, constraint, target_value);
                layout_trace.recordConstraintPropagation(ir.allocator, workspace, constraint, is_soft, false);
                return true;
            }
        }
        if (!is_soft and err == error.ConstraintConflict) {
            const existing = graph.axisAnchorSource(workspace.states[target_index], constraint.target_anchor);
            if (existing != null and constraintInSlice(workspace.soft_constraints, existing.?) and graph.replaceAxisAnchor(&workspace.states[target_index], constraint.target_anchor, target_value, constraint)) {
                try reconcileAppliedAxisState(ir, workspace, target_index);
                try recordAnchorConstraintPropagation(ir, workspace, target_index, constraint, target_value);
                layout_trace.recordConstraintPropagation(ir.allocator, workspace, constraint, is_soft, false);
                return true;
            }
        }
        if (is_soft) return false;
        if (options.record_diagnostics) {
            if (err == error.ConstraintConflict) {
                const propagation = try anchorConflictPropagation(ir, workspace, target_index, constraint, target_value);
                ir.noteConstraintFailureDetailedWithPropagation(
                    workspace.graph.page_id,
                    constraint,
                    graph.axisAnchorSource(workspace.states[target_index], constraint.target_anchor),
                    .conflict,
                    .anchor_value_conflict,
                    workspace.axis,
                    graph.axisAnchorValue(workspace.states[target_index], constraint.target_anchor),
                    target_value,
                    propagation,
                );
            } else {
                const propagation = try negativeAnchorPropagation(ir, workspace, target_index);
                ir.noteConstraintFailureDetailedWithPropagation(
                    workspace.graph.page_id,
                    constraint,
                    graph.axisAnchorSource(workspace.states[target_index], constraint.target_anchor),
                    .negative_frame_size,
                    .negative_frame_size,
                    workspace.axis,
                    null,
                    null,
                    propagation,
                );
            }
        }
        return false;
    };
    if (applied) {
        try recordAnchorConstraintPropagation(ir, workspace, target_index, constraint, target_value);
        layout_trace.recordConstraintPropagation(ir.allocator, workspace, constraint, is_soft, false);
    }
    return applied;
}

fn canMoveDefaultSizedAnchor(ir: anytype, workspace: *const graph.AxisWorkspace, target_index: usize) bool {
    const state = workspace.states[target_index];
    if (!state.size_is_default or state.size == null) return false;
    _ = ir;
    if (workspace.graph.hardTargetAnchorCount(workspace.nodeAt(target_index), workspace.axis) > 1) return false;
    const sources = [_]?Constraint{ state.size_source, state.start_source, state.end_source, state.center_source };
    for (sources) |source| {
        const constraint = source orelse continue;
        if (!constraintInSlice(workspace.soft_constraints, constraint)) return false;
    }
    return true;
}

fn canReplaceDuplicateDefaultAnchor(ir: anytype, workspace: *const graph.AxisWorkspace, target_index: usize, target_anchor: model.Anchor) bool {
    const state = workspace.states[target_index];
    if (!state.size_is_default or state.size == null) return false;
    _ = ir;
    if (workspace.graph.hardTargetAnchorCount(workspace.nodeAt(target_index), workspace.axis) != 1) return false;
    const existing = graph.axisAnchorSource(state, target_anchor) orelse return false;
    return !constraintInSlice(workspace.soft_constraints, existing);
}

fn shouldReplaceDefaultGeometry(ir: anytype, workspace: *const graph.AxisWorkspace, target_index: usize, target_anchor: model.Anchor) bool {
    const state = workspace.states[target_index];
    if (!state.size_is_default) return false;
    _ = ir;
    if (workspace.graph.hardTargetAnchorCount(workspace.nodeAt(target_index), workspace.axis) <= 1) return false;

    const existing_source = graph.axisAnchorSource(state, target_anchor);
    if (existing_source) |source| return constraintInSlice(workspace.soft_constraints, source);
    return graph.axisAnchorValue(state, target_anchor) == null;
}

fn constraintInSlice(constraints: []const Constraint, needle: Constraint) bool {
    for (constraints) |constraint| {
        if (constraintsSame(constraint, needle)) return true;
    }
    return false;
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
    const target_anchor_source = graph.axisAnchorSource(target_state, constraint.target_anchor);
    if (target_anchor_source) |source| {
        if (constraintInSlice(workspace.soft_constraints, source) and workspace.graph.hardTargetAnchorCount(node_source.node_id, workspace.axis) > 0) return false;
    } else if (target_state.size_is_default) {
        return false;
    }

    const target_value = graph.axisAnchorValue(target_state, constraint.target_anchor) orelse return false;
    const applied = graph.setAxisAnchor(&workspace.states[source_index], node_source.anchor, target_value - constraint.offset, constraint) catch |err| {
        if (options.record_diagnostics) {
            const expected = target_value - constraint.offset;
            if (err == error.ConstraintConflict) {
                const propagation = try reverseAnchorConflictPropagation(ir, workspace, source_index, constraint, expected);
                ir.noteConstraintFailureDetailedWithPropagation(
                    workspace.graph.page_id,
                    constraint,
                    graph.axisAnchorSource(workspace.states[source_index], node_source.anchor),
                    .conflict,
                    .anchor_value_conflict,
                    workspace.axis,
                    graph.axisAnchorValue(workspace.states[source_index], node_source.anchor),
                    expected,
                    propagation,
                );
            } else {
                const propagation = try negativeAnchorPropagation(ir, workspace, source_index);
                ir.noteConstraintFailureDetailedWithPropagation(
                    workspace.graph.page_id,
                    constraint,
                    graph.axisAnchorSource(workspace.states[source_index], node_source.anchor),
                    .negative_frame_size,
                    .negative_frame_size,
                    workspace.axis,
                    null,
                    null,
                    propagation,
                );
            }
        }
        return false;
    };
    if (applied) {
        try recordReverseAnchorConstraintPropagation(ir, workspace, source_index, constraint, target_value - constraint.offset);
        layout_trace.recordConstraintPropagation(ir.allocator, workspace, constraint, is_soft, true);
    }
    return applied;
}

fn recordDefaultSizePropagation(ir: anytype, workspace: *graph.AxisWorkspace, index: usize, value: f32) !void {
    const tracker = workspace.propagation orelse return;
    var trace = graph.PropagationTrace{};
    errdefer trace.deinit(ir.allocator);
    const size_label = try nodeSlotLabel(ir.allocator, ir, workspace, index, .size);
    defer ir.allocator.free(size_label);
    try trace.appendOwnedLine(ir.allocator, try std.fmt.allocPrint(
        ir.allocator,
        "{s} = {d:.1}",
        .{ size_label, value },
    ));
    tracker.setTrace(index, .size, trace);
}

fn recordAnchorConstraintPropagation(ir: anytype, workspace: *graph.AxisWorkspace, target_index: usize, constraint: Constraint, value: f32) !void {
    const tracker = workspace.propagation orelse return;
    var trace = try sourceTraceForConstraint(ir, workspace, constraint);
    errdefer trace.deinit(ir.allocator);
    try appendConstraintLine(ir, &trace, constraint, value, false);
    tracker.setTrace(target_index, anchorSlot(constraint.target_anchor), trace);
}

fn recordReverseAnchorConstraintPropagation(ir: anytype, workspace: *graph.AxisWorkspace, source_index: usize, constraint: Constraint, value: f32) !void {
    const tracker = workspace.propagation orelse return;
    const target_value = graph.axisAnchorValue(workspace.states[workspace.indexOf(constraint.target_node) orelse return], constraint.target_anchor) orelse value + constraint.offset;
    var trace = try traceForNodeAnchorOrSeed(ir, workspace, constraint.target_node, constraint.target_anchor, target_value);
    errdefer trace.deinit(ir.allocator);
    try appendConstraintLine(ir, &trace, constraint, value, true);
    const node_source = switch (constraint.source) {
        .page => return,
        .node => |source| source,
    };
    tracker.setTrace(source_index, anchorSlot(node_source.anchor), trace);
}

fn shouldRecordSizeConstraintPropagation(workspace: *graph.AxisWorkspace, target_index: usize) bool {
    const tracker = workspace.propagation orelse return false;
    const trace = tracker.trace(target_index, .size) orelse return true;
    for (trace.line_sources.items) |source| {
        if (source != null) return false;
    }
    return true;
}

fn recordSizeConstraintPropagation(ir: anytype, workspace: *graph.AxisWorkspace, target_index: usize, constraint: Constraint, value: f32) !void {
    const tracker = workspace.propagation orelse return;
    var trace = graph.PropagationTrace{};
    errdefer trace.deinit(ir.allocator);
    try appendSizeLine(ir, workspace, &trace, target_index, constraint, value);
    tracker.setTrace(target_index, .size, trace);
    try recordReconciledPropagation(ir, workspace, target_index);
}

fn recordReconciledPropagation(ir: anytype, workspace: *graph.AxisWorkspace, index: usize) !void {
    if (workspace.propagation == null) return;
    try recordDerivedSlot(ir, workspace, index, .start);
    try recordDerivedSlot(ir, workspace, index, .end);
}

fn recordDerivedSlot(ir: anytype, workspace: *graph.AxisWorkspace, index: usize, slot: graph.PropagationSlot) !void {
    const tracker = workspace.propagation orelse return;
    const state = workspace.states[index];
    if (tracker.trace(index, slot) != null) return;
    if (slotConstraintSource(state, slot) != null) return;
    if (slot == .size and state.size_is_default) return;
    const after_value = slotValue(state, slot) orelse return;

    const pair = derivationPair(state, slot) orelse return;
    const first_trace = tracker.trace(index, pair.first) orelse return;
    const second_trace = tracker.trace(index, pair.second) orelse return;
    var trace = graph.PropagationTrace{};
    errdefer trace.deinit(ir.allocator);
    try trace.appendTrace(ir.allocator, first_trace);
    try trace.appendTrace(ir.allocator, second_trace);
    try appendDerivedLine(ir, workspace, &trace, index, slot, pair, after_value);
    tracker.setTrace(index, slot, trace);
}

fn slotConstraintSource(state: AxisState, slot: graph.PropagationSlot) ?Constraint {
    return switch (slot) {
        .start => state.start_source,
        .end => state.end_source,
        .center => state.center_source,
        .size => state.size_source,
    };
}

const DerivationPair = struct {
    first: graph.PropagationSlot,
    second: graph.PropagationSlot,
};

fn derivationPair(state: AxisState, slot: graph.PropagationSlot) ?DerivationPair {
    return switch (slot) {
        .size => if (state.start != null and state.end != null)
            .{ .first = .start, .second = .end }
        else if (state.start != null and state.center != null)
            .{ .first = .start, .second = .center }
        else if (state.end != null and state.center != null)
            .{ .first = .end, .second = .center }
        else
            null,
        .start => if (state.end != null and state.size != null)
            .{ .first = .end, .second = .size }
        else if (state.center != null and state.size != null)
            .{ .first = .center, .second = .size }
        else
            null,
        .end => if (state.start != null and state.size != null)
            .{ .first = .start, .second = .size }
        else if (state.center != null and state.size != null)
            .{ .first = .center, .second = .size }
        else
            null,
        .center => if (state.start != null and state.end != null)
            .{ .first = .start, .second = .end }
        else if (state.start != null and state.size != null)
            .{ .first = .start, .second = .size }
        else if (state.end != null and state.size != null)
            .{ .first = .end, .second = .size }
        else
            null,
    };
}

fn slotValue(state: AxisState, slot: graph.PropagationSlot) ?f32 {
    return switch (slot) {
        .start => state.start,
        .end => state.end,
        .center => state.center,
        .size => state.size,
    };
}

fn sourceTraceForConstraint(ir: anytype, workspace: *graph.AxisWorkspace, constraint: Constraint) !graph.PropagationTrace {
    return switch (constraint.source) {
        .page => |anchor| try pageAnchorTrace(ir, workspace, anchor),
        .node => |source| blk: {
            const source_value = (try graph.constraintSourceValue(ir, workspace, constraint.source)) orelse 0;
            break :blk try traceForNodeAnchorOrSeed(ir, workspace, source.node_id, source.anchor, source_value);
        },
    };
}

fn traceForNodeAnchorOrSeed(ir: anytype, workspace: *graph.AxisWorkspace, node_id: NodeId, anchor: model.Anchor, value: f32) !graph.PropagationTrace {
    if (workspace.propagation) |tracker| {
        if (workspace.indexOf(node_id)) |index| {
            if (tracker.trace(index, anchorSlot(anchor))) |existing| return try existing.clone(ir.allocator);
        }
    }
    var trace = graph.PropagationTrace{};
    errdefer trace.deinit(ir.allocator);
    const label = try nodeAnchorLabel(ir.allocator, ir, node_id, anchor);
    defer ir.allocator.free(label);
    try trace.appendOwnedLine(ir.allocator, try std.fmt.allocPrint(
        ir.allocator,
        "{s} = {d:.1}",
        .{ label, value },
    ));
    return trace;
}

fn pageAnchorTrace(ir: anytype, workspace: *graph.AxisWorkspace, anchor: model.Anchor) !graph.PropagationTrace {
    var trace = graph.PropagationTrace{};
    errdefer trace.deinit(ir.allocator);
    const page = ir.getNode(workspace.graph.page_id) orelse return error.UnknownNode;
    try trace.appendOwnedLine(ir.allocator, try std.fmt.allocPrint(
        ir.allocator,
        "page.{s} = {d:.1}",
        .{ @tagName(anchor), graph.anchorValue(page.frame, anchor) },
    ));
    return trace;
}

fn appendConstraintLine(ir: anytype, trace: *graph.PropagationTrace, constraint: Constraint, value: f32, reverse: bool) !void {
    const prefix = if (trace.lines.items.len == 0) "" else "→ ";
    const target_label = if (reverse)
        try reverseTargetLabel(ir.allocator, ir, constraint)
    else
        try nodeAnchorLabel(ir.allocator, ir, constraint.target_node, constraint.target_anchor);
    defer ir.allocator.free(target_label);
    const source_label = if (reverse)
        try nodeAnchorLabel(ir.allocator, ir, constraint.target_node, constraint.target_anchor)
    else
        try constraintSourceLabel(ir.allocator, ir, constraint.source);
    defer ir.allocator.free(source_label);
    const offset = if (reverse) -constraint.offset else constraint.offset;
    const source_text = try constraintOriginLabel(ir.allocator, ir, constraint);
    const line = std.fmt.allocPrint(
        ir.allocator,
        "{s}{s} = {s} {s} {d:.1} = {d:.1}",
        .{ prefix, target_label, source_label, if (offset < 0) "-" else "+", @abs(offset), value },
    ) catch |err| {
        ir.allocator.free(source_text);
        return err;
    };
    try trace.appendOwnedLineWithSource(ir.allocator, line, source_text);
}

fn appendSizeLine(ir: anytype, workspace: *graph.AxisWorkspace, trace: *graph.PropagationTrace, target_index: usize, constraint: Constraint, value: f32) !void {
    const prefix = if (trace.lines.items.len == 0) "" else "→ ";
    const size_label = try nodeSlotLabel(ir.allocator, ir, workspace, target_index, .size);
    defer ir.allocator.free(size_label);
    if (constraint.source == .node) {
        const source = constraint.source.node;
        if (source.node_id == constraint.target_node and graph.anchorAxis(source.anchor) == workspace.axis) {
            const target_label = try nodeAnchorLabel(ir.allocator, ir, constraint.target_node, constraint.target_anchor);
            defer ir.allocator.free(target_label);
            const source_label = try nodeAnchorLabel(ir.allocator, ir, source.node_id, source.anchor);
            defer ir.allocator.free(source_label);
            const start_label = try nodeSlotLabel(ir.allocator, ir, workspace, target_index, .start);
            defer ir.allocator.free(start_label);
            const end_label = try nodeSlotLabel(ir.allocator, ir, workspace, target_index, .end);
            defer ir.allocator.free(end_label);
            const source_text = try constraintOriginLabel(ir.allocator, ir, constraint);
            const constraint_line = std.fmt.allocPrint(
                ir.allocator,
                "{s}{s} = {s} {s} {d:.1}",
                .{ prefix, target_label, source_label, if (constraint.offset < 0) "-" else "+", @abs(constraint.offset) },
            ) catch |err| {
                ir.allocator.free(source_text);
                return err;
            };
            try trace.appendOwnedLineWithSource(ir.allocator, constraint_line, source_text);
            try trace.appendOwnedLine(ir.allocator, try std.fmt.allocPrint(
                ir.allocator,
                "→ {s} = {s} - {s} = {d:.1}",
                .{ size_label, end_label, start_label, value },
            ));
            return;
        }
    }
    const source_text = try constraintOriginLabel(ir.allocator, ir, constraint);
    const line = std.fmt.allocPrint(
        ir.allocator,
        "{s}{s} = {d:.1}",
        .{ prefix, size_label, value },
    ) catch |err| {
        ir.allocator.free(source_text);
        return err;
    };
    try trace.appendOwnedLineWithSource(ir.allocator, line, source_text);
}

fn appendDerivedLine(ir: anytype, workspace: *graph.AxisWorkspace, trace: *graph.PropagationTrace, index: usize, slot: graph.PropagationSlot, pair: DerivationPair, value: f32) !void {
    const target_label = try nodeSlotLabel(ir.allocator, ir, workspace, index, slot);
    defer ir.allocator.free(target_label);
    const first_label = try nodeSlotLabel(ir.allocator, ir, workspace, index, pair.first);
    defer ir.allocator.free(first_label);
    const second_label = try nodeSlotLabel(ir.allocator, ir, workspace, index, pair.second);
    defer ir.allocator.free(second_label);
    try trace.appendOwnedLine(ir.allocator, try std.fmt.allocPrint(
        ir.allocator,
        "→ {s} = {s}, {s} = {d:.1}",
        .{ target_label, first_label, second_label, value },
    ));
}

fn constraintOriginLabel(allocator: std.mem.Allocator, ir: anytype, constraint: Constraint) ![]const u8 {
    const origin_text = constraint.origin orelse return allocator.dupe(u8, "fallback");
    const located = utils.err.parseLocatedOrigin(origin_text) orelse return allocator.dupe(u8, "unknown");
    var path = ir.projectPath();
    var source = ir.projectSource();
    if (located.path) |origin_path| {
        if (ir.moduleByPathOrSpec(origin_path)) |module| {
            path = module.path orelse module.spec;
            source = module.source;
        } else {
            path = origin_path;
        }
    } else {
        const module = ir.projectModule();
        path = module.path orelse module.spec;
        source = module.source;
    }
    const loc = utils.err.computeLineColumn(source, located.span.start);
    return std.fmt.allocPrint(allocator, "{s}:{d}", .{ path, loc.line });
}

fn anchorSlot(anchor: model.Anchor) graph.PropagationSlot {
    return switch (anchor) {
        .left, .bottom => .start,
        .right, .top => .end,
        .center_x, .center_y => .center,
    };
}

fn nodeSlotLabel(allocator: std.mem.Allocator, ir: anytype, workspace: *const graph.AxisWorkspace, index: usize, slot: graph.PropagationSlot) ![]const u8 {
    const node_id = workspace.nodeAt(index);
    const suffix = switch (slot) {
        .start => if (workspace.axis == .horizontal) "left" else "bottom",
        .end => if (workspace.axis == .horizontal) "right" else "top",
        .center => if (workspace.axis == .horizontal) "center_x" else "center_y",
        .size => if (workspace.axis == .horizontal) "width" else "height",
    };
    return std.fmt.allocPrint(allocator, "{s}.{s}", .{ nodeLabel(ir, node_id), suffix });
}

fn nodeAnchorLabel(allocator: std.mem.Allocator, ir: anytype, node_id: NodeId, anchor: model.Anchor) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}.{s}", .{ nodeLabel(ir, node_id), @tagName(anchor) });
}

fn reverseTargetLabel(allocator: std.mem.Allocator, ir: anytype, constraint: Constraint) ![]const u8 {
    return switch (constraint.source) {
        .page => std.fmt.allocPrint(allocator, "page.unknown", .{}),
        .node => |source| nodeAnchorLabel(allocator, ir, source.node_id, source.anchor),
    };
}

fn constraintSourceLabel(allocator: std.mem.Allocator, ir: anytype, source: model.ConstraintSource) ![]const u8 {
    return switch (source) {
        .page => |anchor| std.fmt.allocPrint(allocator, "page.{s}", .{@tagName(anchor)}),
        .node => |node_source| nodeAnchorLabel(allocator, ir, node_source.node_id, node_source.anchor),
    };
}

fn nodeLabel(ir: anytype, node_id: NodeId) []const u8 {
    const node = ir.getNode(node_id) orelse return "unknown";
    return node.role orelse node.name;
}

fn anchorConflictPropagation(ir: anytype, workspace: *graph.AxisWorkspace, target_index: usize, constraint: Constraint, incoming_value: f32) !?model.ConstraintPropagation {
    if (workspace.propagation == null) return null;
    const current_value = graph.axisAnchorValue(workspace.states[target_index], constraint.target_anchor) orelse return null;
    var current = try traceForNodeAnchorOrSeed(ir, workspace, constraint.target_node, constraint.target_anchor, current_value);
    defer current.deinit(ir.allocator);
    var incoming = try sourceTraceForConstraint(ir, workspace, constraint);
    defer incoming.deinit(ir.allocator);
    try appendConstraintLine(ir, &incoming, constraint, incoming_value, false);
    const target_label = try nodeAnchorLabel(ir.allocator, ir, constraint.target_node, constraint.target_anchor);
    defer ir.allocator.free(target_label);
    return try twoPathPropagation(
        ir.allocator,
        target_label,
        "current value",
        &current,
        "incoming value",
        &incoming,
        try std.fmt.allocPrint(
            ir.allocator,
            "{s} is already fixed at {d:.1}, but this propagation requires {d:.1}.",
            .{ target_label, current_value, incoming_value },
        ),
        null,
    );
}

fn reverseAnchorConflictPropagation(ir: anytype, workspace: *graph.AxisWorkspace, source_index: usize, constraint: Constraint, incoming_value: f32) !?model.ConstraintPropagation {
    if (workspace.propagation == null) return null;
    const node_source = switch (constraint.source) {
        .page => return null,
        .node => |source| source,
    };
    const current_value = graph.axisAnchorValue(workspace.states[source_index], node_source.anchor) orelse return null;
    var current = try traceForNodeAnchorOrSeed(ir, workspace, node_source.node_id, node_source.anchor, current_value);
    defer current.deinit(ir.allocator);
    const target_value = graph.axisAnchorValue(workspace.states[workspace.indexOf(constraint.target_node) orelse return null], constraint.target_anchor) orelse return null;
    var incoming = try traceForNodeAnchorOrSeed(ir, workspace, constraint.target_node, constraint.target_anchor, target_value);
    defer incoming.deinit(ir.allocator);
    try appendConstraintLine(ir, &incoming, constraint, incoming_value, true);
    const target_label = try nodeAnchorLabel(ir.allocator, ir, node_source.node_id, node_source.anchor);
    defer ir.allocator.free(target_label);
    return try twoPathPropagation(
        ir.allocator,
        target_label,
        "current value",
        &current,
        "incoming value",
        &incoming,
        try std.fmt.allocPrint(
            ir.allocator,
            "{s} is already fixed at {d:.1}, but this propagation requires {d:.1}.",
            .{ target_label, current_value, incoming_value },
        ),
        null,
    );
}

fn sizeConflictPropagation(ir: anytype, workspace: *graph.AxisWorkspace, target_index: usize, constraint: Constraint, current_value: ?f32, incoming_value: f32) !?model.ConstraintPropagation {
    if (workspace.propagation == null) return null;
    const current_size = current_value orelse return null;
    var current = try traceForSlotOrSeed(ir, workspace, target_index, .size, current_size);
    defer current.deinit(ir.allocator);
    var incoming = graph.PropagationTrace{};
    defer incoming.deinit(ir.allocator);
    try appendSizeLine(ir, workspace, &incoming, target_index, constraint, incoming_value);
    const target_label = try nodeSlotLabel(ir.allocator, ir, workspace, target_index, .size);
    defer ir.allocator.free(target_label);
    return try twoPathPropagation(
        ir.allocator,
        target_label,
        "current value",
        &current,
        "incoming value",
        &incoming,
        try std.fmt.allocPrint(
            ir.allocator,
            "{s} is already fixed at {d:.1}, but this propagation requires {d:.1}.",
            .{ target_label, current_size, incoming_value },
        ),
        null,
    );
}

fn negativeSizePropagation(ir: anytype, workspace: *graph.AxisWorkspace, target_index: usize, constraint: Constraint, size: f32) !?model.ConstraintPropagation {
    if (workspace.propagation == null) return null;
    var trace = graph.PropagationTrace{};
    defer trace.deinit(ir.allocator);
    if (workspace.propagation.?.trace(target_index, .size)) |existing| {
        trace = try existing.clone(ir.allocator);
    } else {
        try appendSizeLine(ir, workspace, &trace, target_index, constraint, size);
    }
    const target_label = try nodeSlotLabel(ir.allocator, ir, workspace, target_index, .size);
    defer ir.allocator.free(target_label);
    return try onePathPropagation(
        ir.allocator,
        target_label,
        if (workspace.axis == .horizontal) "width" else "height",
        &trace,
        try std.fmt.allocPrint(ir.allocator, "{s} = {d:.1}", .{ target_label, size }),
    );
}

fn negativeAnchorPropagation(ir: anytype, workspace: *graph.AxisWorkspace, target_index: usize) !?model.ConstraintPropagation {
    if (workspace.propagation == null) return null;
    const start_value = workspace.states[target_index].start;
    const end_value = workspace.states[target_index].end;
    if (start_value == null or end_value == null) return null;
    return try frameEdgePropagation(ir, workspace, target_index, start_value.?, end_value.?);
}

fn reconciliationFailurePropagation(ir: anytype, workspace: *graph.AxisWorkspace, index: usize, state: *const AxisState, err: anyerror) !?model.ConstraintPropagation {
    if (workspace.propagation == null) return null;
    if (err == error.NegativeFrameSize and state.start != null and state.end != null) {
        return try frameEdgePropagation(ir, workspace, index, state.start.?, state.end.?);
    }
    return null;
}

fn frameEdgePropagation(ir: anytype, workspace: *graph.AxisWorkspace, index: usize, start_value: f32, end_value: f32) !?model.ConstraintPropagation {
    var start_trace = try traceForSlotOrSeed(ir, workspace, index, .start, start_value);
    defer start_trace.deinit(ir.allocator);
    var end_trace = try traceForSlotOrSeed(ir, workspace, index, .end, end_value);
    defer end_trace.deinit(ir.allocator);
    const size_label = try nodeSlotLabel(ir.allocator, ir, workspace, index, .size);
    defer ir.allocator.free(size_label);
    const start_label = try nodeSlotLabel(ir.allocator, ir, workspace, index, .start);
    defer ir.allocator.free(start_label);
    const end_label = try nodeSlotLabel(ir.allocator, ir, workspace, index, .end);
    defer ir.allocator.free(end_label);
    return try twoPathPropagation(
        ir.allocator,
        size_label,
        if (workspace.axis == .horizontal) "left" else "bottom",
        &start_trace,
        if (workspace.axis == .horizontal) "right" else "top",
        &end_trace,
        try std.fmt.allocPrint(
            ir.allocator,
            "{s} = {s} - {s} = {d:.1} - {d:.1} = {d:.1}",
            .{ size_label, end_label, start_label, end_value, start_value, end_value - start_value },
        ),
        null,
    );
}

fn traceForSlotOrSeed(ir: anytype, workspace: *graph.AxisWorkspace, index: usize, slot: graph.PropagationSlot, value: f32) !graph.PropagationTrace {
    if (workspace.propagation) |tracker| {
        if (tracker.trace(index, slot)) |existing| return try existing.clone(ir.allocator);
    }
    var trace = graph.PropagationTrace{};
    errdefer trace.deinit(ir.allocator);
    const label = try nodeSlotLabel(ir.allocator, ir, workspace, index, slot);
    defer ir.allocator.free(label);
    try trace.appendOwnedLine(ir.allocator, try std.fmt.allocPrint(ir.allocator, "{s} = {d:.1}", .{ label, value }));
    return trace;
}

fn onePathPropagation(
    allocator: std.mem.Allocator,
    target: []const u8,
    title: []const u8,
    trace: *const graph.PropagationTrace,
    result_line: []const u8,
) !?model.ConstraintPropagation {
    errdefer allocator.free(result_line);
    var paths = try allocator.alloc(model.PropagationPath, 1);
    errdefer allocator.free(paths);
    paths[0] = try modelPathFromTrace(allocator, title, trace);
    errdefer paths[0].deinit(allocator);

    var result = try allocator.alloc([]const u8, 1);
    errdefer allocator.free(result);
    result[0] = result_line;

    return .{
        .target = try allocator.dupe(u8, target),
        .paths = paths,
        .result = result,
    };
}

fn twoPathPropagation(
    allocator: std.mem.Allocator,
    target: []const u8,
    first_title: []const u8,
    first_trace: *const graph.PropagationTrace,
    second_title: []const u8,
    second_trace: *const graph.PropagationTrace,
    first_result_line: []const u8,
    second_result_line: ?[]const u8,
) !?model.ConstraintPropagation {
    errdefer allocator.free(first_result_line);
    if (second_result_line) |line| {
        errdefer allocator.free(line);
    }
    var paths = try allocator.alloc(model.PropagationPath, 2);
    errdefer allocator.free(paths);
    paths[0] = try modelPathFromTrace(allocator, first_title, first_trace);
    errdefer paths[0].deinit(allocator);
    paths[1] = try modelPathFromTrace(allocator, second_title, second_trace);
    errdefer paths[1].deinit(allocator);

    const result_len: usize = if (second_result_line == null) 1 else 2;
    var result = try allocator.alloc([]const u8, result_len);
    errdefer allocator.free(result);
    result[0] = first_result_line;
    if (second_result_line) |line| result[1] = line;

    return .{
        .target = try allocator.dupe(u8, target),
        .paths = paths,
        .result = result,
    };
}

fn modelPathFromTrace(allocator: std.mem.Allocator, title: []const u8, trace: *const graph.PropagationTrace) !model.PropagationPath {
    const lines = try allocator.alloc([]const u8, trace.lines.items.len);
    const line_sources = allocator.alloc(?[]const u8, trace.lines.items.len) catch |err| {
        allocator.free(lines);
        return err;
    };
    var copied: usize = 0;
    errdefer {
        for (lines[0..copied], line_sources[0..copied]) |line, source| {
            allocator.free(line);
            if (source) |text| allocator.free(text);
        }
        allocator.free(lines);
        allocator.free(line_sources);
    }
    for (trace.lines.items, 0..) |line, index| {
        const copied_line = try allocator.dupe(u8, line);
        const source = if (index < trace.line_sources.items.len) trace.line_sources.items[index] else null;
        const copied_source = if (source) |text| allocator.dupe(u8, text) catch |err| {
            allocator.free(copied_line);
            return err;
        } else null;
        lines[index] = copied_line;
        line_sources[index] = copied_source;
        copied += 1;
    }
    return .{
        .title = try allocator.dupe(u8, title),
        .lines = lines,
        .line_sources = line_sources,
    };
}

fn validatePageConstraints(ir: anytype, page_id: NodeId, page_graph: *const graph.PageLayoutGraph, options: SolveOptions) !void {
    for (page_graph.constraints) |constraint| {
        if (page_graph.indexOf(constraint.target_node) == null) continue;
        if (constraintAlreadyFailed(ir, constraint)) continue;

        const target_value = switch (try finalNodeAnchorValue(ir, constraint.target_node, constraint.target_anchor)) {
            .known => |value| value,
            .unknown => {
                const propagation = if (options.record_propagation) try constraintCyclePropagation(ir, page_graph, constraint) else null;
                ir.noteConstraintFailureDetailedWithPropagation(page_id, constraint, null, .conflict, .constraint_cycle, graph.anchorAxis(constraint.target_anchor), null, null, propagation);
                continue;
            },
        };

        const source_value = switch (try finalConstraintSourceValue(ir, page_id, constraint.source)) {
            .known => |value| value,
            .unknown => {
                const propagation = if (options.record_propagation) try constraintCyclePropagation(ir, page_graph, constraint) else null;
                ir.noteConstraintFailureDetailedWithPropagation(page_id, constraint, null, .conflict, .constraint_cycle, graph.anchorAxis(constraint.target_anchor), target_value, null, propagation);
                continue;
            },
        };

        const expected = source_value + constraint.offset;
        if (@abs(target_value - expected) > ConstraintTolerance) {
            const related = validationRelatedConstraint(page_graph, constraint);
            const propagation = if (options.record_propagation) try validationConflictPropagation(ir, page_id, page_graph, constraint, related, target_value, expected) else null;
            ir.noteConstraintFailureDetailedWithPropagation(page_id, constraint, related, .conflict, .anchor_value_conflict, graph.anchorAxis(constraint.target_anchor), target_value, expected, propagation);
        }
    }
}

const ConstraintEndpoint = struct {
    node_id: NodeId,
    anchor: model.Anchor,
};

fn constraintCyclePropagation(ir: anytype, page_graph: *const graph.PageLayoutGraph, start_constraint: Constraint) !?model.ConstraintPropagation {
    const axis = graph.anchorAxis(start_constraint.target_anchor);
    const start_endpoint: ConstraintEndpoint = .{ .node_id = start_constraint.target_node, .anchor = start_constraint.target_anchor };
    var current = start_constraint;
    var accumulated_offset: f32 = 0;
    var trace = graph.PropagationTrace{};
    defer trace.deinit(ir.allocator);

    var steps: usize = 0;
    while (steps <= page_graph.constraints.len) : (steps += 1) {
        if (graph.anchorAxis(current.target_anchor) != axis) return null;
        accumulated_offset += current.offset;
        try appendCycleConstraintLine(ir, &trace, current, accumulated_offset);

        const source_endpoint = constraintSourceEndpoint(current.source) orelse return null;
        if (graph.anchorAxis(source_endpoint.anchor) != axis) return null;
        if (constraintEndpointSame(source_endpoint, start_endpoint)) {
            const target_label = try nodeAnchorLabel(ir.allocator, ir, start_endpoint.node_id, start_endpoint.anchor);
            defer ir.allocator.free(target_label);
            return try onePathPropagation(
                ir.allocator,
                target_label,
                "cycle",
                &trace,
                try std.fmt.allocPrint(
                    ir.allocator,
                    "{s} depends on itself; accumulated offset = {d:.1}",
                    .{ target_label, accumulated_offset },
                ),
            );
        }

        current = findConstraintTargetingEndpoint(page_graph, source_endpoint, axis) orelse return null;
    }
    return null;
}

fn validationConflictPropagation(
    ir: anytype,
    page_id: NodeId,
    page_graph: *const graph.PageLayoutGraph,
    constraint: Constraint,
    related_constraint: ?Constraint,
    target_value: f32,
    expected: f32,
) !?model.ConstraintPropagation {
    var current = if (related_constraint) |related|
        try finalConstraintTrace(ir, page_id, page_graph, related, target_value, 0)
    else
        graph.PropagationTrace{};
    defer current.deinit(ir.allocator);
    const target_label = try nodeAnchorLabel(ir.allocator, ir, constraint.target_node, constraint.target_anchor);
    defer ir.allocator.free(target_label);
    if (current.lines.items.len == 0) {
        try current.appendOwnedLine(ir.allocator, try std.fmt.allocPrint(
            ir.allocator,
            "{s} = {d:.1}",
            .{ target_label, target_value },
        ));
    }

    var incoming = try finalConstraintTrace(ir, page_id, page_graph, constraint, expected, 0);
    defer incoming.deinit(ir.allocator);

    return try twoPathPropagation(
        ir.allocator,
        target_label,
        "current value",
        &current,
        "incoming value",
        &incoming,
        try std.fmt.allocPrint(
            ir.allocator,
            "{s} is already fixed at {d:.1}, but this propagation requires {d:.1}.",
            .{ target_label, target_value, expected },
        ),
        null,
    );
}

fn finalConstraintTrace(ir: anytype, page_id: NodeId, page_graph: *const graph.PageLayoutGraph, constraint: Constraint, value: f32, depth: usize) anyerror!graph.PropagationTrace {
    if (depth > page_graph.constraints.len) return finalNodeAnchorTrace(ir, constraint.target_node, constraint.target_anchor, value);
    const source_value = switch (try finalConstraintSourceValue(ir, page_id, constraint.source)) {
        .known => |known| known,
        .unknown => value - constraint.offset,
    };
    var trace = try finalConstraintSourceTrace(ir, page_id, page_graph, constraint.source, source_value, depth + 1);
    errdefer trace.deinit(ir.allocator);
    try appendConstraintLine(ir, &trace, constraint, value, false);
    return trace;
}

fn finalConstraintSourceTrace(ir: anytype, page_id: NodeId, page_graph: *const graph.PageLayoutGraph, source: model.ConstraintSource, value: f32, depth: usize) anyerror!graph.PropagationTrace {
    return switch (source) {
        .page => |anchor| try finalPageAnchorTrace(ir, page_id, anchor, value),
        .node => |node_source| blk: {
            if (findConstraintTargetingEndpoint(page_graph, .{ .node_id = node_source.node_id, .anchor = node_source.anchor }, graph.anchorAxis(node_source.anchor))) |source_constraint| {
                break :blk try finalConstraintTrace(ir, page_id, page_graph, source_constraint, value, depth);
            }
            break :blk try finalNodeAnchorTrace(ir, node_source.node_id, node_source.anchor, value);
        },
    };
}

fn finalPageAnchorTrace(ir: anytype, page_id: NodeId, anchor: model.Anchor, value: f32) !graph.PropagationTrace {
    _ = page_id;
    var trace = graph.PropagationTrace{};
    errdefer trace.deinit(ir.allocator);
    try trace.appendOwnedLine(ir.allocator, try std.fmt.allocPrint(
        ir.allocator,
        "page.{s} = {d:.1}",
        .{ @tagName(anchor), value },
    ));
    return trace;
}

fn finalNodeAnchorTrace(ir: anytype, node_id: NodeId, anchor: model.Anchor, value: f32) !graph.PropagationTrace {
    var trace = graph.PropagationTrace{};
    errdefer trace.deinit(ir.allocator);
    const label = try nodeAnchorLabel(ir.allocator, ir, node_id, anchor);
    defer ir.allocator.free(label);
    try trace.appendOwnedLine(ir.allocator, try std.fmt.allocPrint(ir.allocator, "{s} = {d:.1}", .{ label, value }));
    return trace;
}

fn appendCycleConstraintLine(ir: anytype, trace: *graph.PropagationTrace, constraint: Constraint, accumulated_offset: f32) !void {
    const prefix = if (trace.lines.items.len == 0) "" else "→ ";
    const target_label = try nodeAnchorLabel(ir.allocator, ir, constraint.target_node, constraint.target_anchor);
    defer ir.allocator.free(target_label);
    const source_label = try constraintSourceLabel(ir.allocator, ir, constraint.source);
    defer ir.allocator.free(source_label);
    const source_text = try constraintOriginLabel(ir.allocator, ir, constraint);
    const line = std.fmt.allocPrint(
        ir.allocator,
        "{s}{s} = {s} {s} {d:.1}; accumulated offset = {d:.1}",
        .{ prefix, target_label, source_label, if (constraint.offset < 0) "-" else "+", @abs(constraint.offset), accumulated_offset },
    ) catch |err| {
        ir.allocator.free(source_text);
        return err;
    };
    try trace.appendOwnedLineWithSource(ir.allocator, line, source_text);
}

fn constraintSourceEndpoint(source: model.ConstraintSource) ?ConstraintEndpoint {
    return switch (source) {
        .page => null,
        .node => |node_source| .{ .node_id = node_source.node_id, .anchor = node_source.anchor },
    };
}

fn findConstraintTargetingEndpoint(page_graph: *const graph.PageLayoutGraph, endpoint: ConstraintEndpoint, axis: model.Axis) ?Constraint {
    for (page_graph.constraints) |constraint| {
        if (graph.anchorAxis(constraint.target_anchor) != axis) continue;
        if (constraint.target_node == endpoint.node_id and constraint.target_anchor == endpoint.anchor) return constraint;
    }
    return null;
}

fn constraintEndpointSame(a: ConstraintEndpoint, b: ConstraintEndpoint) bool {
    return a.node_id == b.node_id and a.anchor == b.anchor;
}

fn constraintAlreadyFailed(ir: anytype, constraint: Constraint) bool {
    for (ir.constraint_failures.items) |failure| {
        if (constraintsSame(failure.constraint, constraint)) return true;
    }
    return false;
}

fn validationRelatedConstraint(page_graph: *const graph.PageLayoutGraph, failure: Constraint) ?Constraint {
    for (page_graph.constraints) |candidate| {
        if (candidate.target_node != failure.target_node) continue;
        if (candidate.target_anchor != failure.target_anchor) continue;
        if (constraintsSame(candidate, failure)) continue;
        return candidate;
    }
    return null;
}

const FinalAnchorValue = union(enum) {
    known: f32,
    unknown: void,
};

fn finalConstraintSourceValue(ir: anytype, page_id: NodeId, source: model.ConstraintSource) !FinalAnchorValue {
    return switch (source) {
        .page => |anchor| blk: {
            const page = ir.getNode(page_id) orelse return error.UnknownNode;
            if (!graph.anchorKnown(page.frame, anchor)) break :blk .{ .unknown = {} };
            break :blk .{ .known = graph.anchorValue(page.frame, anchor) };
        },
        .node => |node_source| try finalNodeAnchorValue(ir, node_source.node_id, node_source.anchor),
    };
}

fn finalNodeAnchorValue(ir: anytype, node_id: NodeId, anchor: model.Anchor) !FinalAnchorValue {
    const node = ir.getNode(node_id) orelse return error.UnknownNode;
    if (!graph.anchorKnown(node.frame, anchor)) return .{ .unknown = {} };
    return .{ .known = graph.anchorValue(node.frame, anchor) };
}
