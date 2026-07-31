const std = @import("std");
const model = @import("model");
const diagnostics = @import("diagnostics.zig");
const document = @import("document.zig");
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
const Defaults = @import("document.zig").Defaults;
const ConstraintTolerance = graph.ConstraintTolerance;

pub const SolveOptions = graph.SolveOptions;

pub fn solveDocument(state: anytype, trace_path: ?[]const u8, options: SolveOptions) !document.Document {
    try graph.checkCancellation(options);
    layout_trace.beginSolve(state.allocator, trace_path);
    defer layout_trace.endSolve(state.allocator);

    for (state.page_order.items) |page_id| {
        try graph.checkCancellation(options);
        const page = state.getNode(page_id) orelse return error.UnknownNode;
        page.frame = .{
            .x = 0,
            .y = 0,
            .width = Defaults.width,
            .height = Defaults.height,
            .x_set = true,
            .y_set = true,
        };
    }

    const page_count = state.page_order.items.len;
    if (page_count > 0) {
        if (options.progress) |progress| progress.pageStarted(progress.context, 0, page_count);
    }

    const page_jobs = try state.allocator.alloc(PageJob, page_count);
    defer state.allocator.free(page_jobs);
    for (state.page_order.items, 0..) |page_id, page_index| {
        try graph.checkCancellation(options);
        page_jobs[page_index] = .{
            .page_id = page_id,
            .page_index = page_index,
        };
    }

    var page_results = std.ArrayList(document.Page).empty;
    errdefer {
        for (page_results.items) |*result| result.deinit(state.allocator);
        page_results.deinit(state.allocator);
    }
    try runPageJobs(state, page_jobs, options, trace_path == null and !options.record_propagation, &page_results);
    try graph.checkCancellation(options);
    return .{ .pages = try page_results.toOwnedSlice(state.allocator) };
}

const PageJob = struct {
    page_id: NodeId,
    page_index: usize,

    fn run(self: PageJob, state: anytype, options: SolveOptions) !document.Page {
        try graph.checkCancellation(options);
        var measurement_cache = metrics.MeasurementCache.initWithRenderProvider(state.allocator, options.measurement_provider);
        defer measurement_cache.deinit();
        var result = try solvePageLayout(state, self.page_id, self.page_index, &measurement_cache, options);
        errdefer result.deinit(state.allocator);
        try graph.checkCancellation(options);
        return result;
    }

    fn runIsolated(self: PageJob, state: anytype, allocator: std.mem.Allocator, options: SolveOptions) !document.Page {
        try graph.checkCancellation(options);
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        var local_context = state.*;
        local_context.allocator = arena.allocator();
        local_context.diagnostics = .empty;
        local_context.constraint_failures = .empty;
        local_context.last_constraint_failure = null;
        defer {
            for (local_context.diagnostics.items) |*diagnostic| diagnostic.deinit(local_context.allocator);
            local_context.diagnostics.deinit(local_context.allocator);
            for (local_context.constraint_failures.items) |*failure| failure.deinit(local_context.allocator);
            local_context.constraint_failures.deinit(local_context.allocator);
        }
        var local_options = options;
        local_options.progress = null;
        var measurement_cache = metrics.MeasurementCache.initWithRenderProvider(local_context.allocator, local_options.measurement_provider);
        defer measurement_cache.deinit();
        var result = try solvePageLayout(&local_context, self.page_id, self.page_index, &measurement_cache, local_options);
        defer result.deinit(local_context.allocator);
        try graph.checkCancellation(options);
        return try clonePage(allocator, &result);
    }
};

const PageLayoutJobOutput = struct {
    result: ?document.Page = null,
    err: ?anyerror = null,
};

fn PageWork(comptime ContextPtr: type) type {
    return struct {
        state: ContextPtr,
        jobs: []const PageJob,
        options: SolveOptions,
        outputs: []PageLayoutJobOutput,
        next_job: std.atomic.Value(usize) = .init(0),
        completed: usize = 0,
        failed: std.atomic.Value(bool) = .init(false),
        progress_lock: std.atomic.Value(bool) = .init(false),
    };
}

fn runPageJobs(state: anytype, jobs: []const PageJob, options: SolveOptions, parallel_allowed: bool, out: *std.ArrayList(document.Page)) !void {
    const worker_count = layoutWorkerCount(jobs.len, options, parallel_allowed);
    if (worker_count <= 1) return try runPageJobsSequential(state, jobs, options, out);
    return try runPageJobsParallel(state, jobs, options, worker_count, out);
}

fn runPageJobsSequential(state: anytype, jobs: []const PageJob, options: SolveOptions, out: *std.ArrayList(document.Page)) !void {
    for (jobs, 0..) |job, completed_index| {
        try graph.checkCancellation(options);
        var result = try job.run(state, options);
        var result_transferred = false;
        errdefer if (!result_transferred) result.deinit(state.allocator);
        try out.append(state.allocator, result);
        result_transferred = true;
        if (options.progress) |progress| progress.pageCompleted(progress.context, completed_index + 1, jobs.len);
    }
}

fn runPageJobsParallel(state: anytype, jobs: []const PageJob, options: SolveOptions, worker_count: usize, out: *std.ArrayList(document.Page)) !void {
    try graph.checkCancellation(options);
    const ContextPtr = @TypeOf(state);
    const outputs = try state.allocator.alloc(PageLayoutJobOutput, jobs.len);
    defer state.allocator.free(outputs);
    for (outputs) |*output| output.* = .{};
    defer {
        for (outputs) |*output| {
            if (output.result) |*result| result.deinit(std.heap.smp_allocator);
        }
    }

    var work = PageWork(ContextPtr){
        .state = state,
        .jobs = jobs,
        .options = options,
        .outputs = outputs,
    };

    var threads = try state.allocator.alloc(std.Thread, worker_count);
    defer state.allocator.free(threads);

    var started: usize = 0;
    var joined = false;
    errdefer {
        if (!joined) {
            work.failed.store(true, .seq_cst);
            for (threads[0..started]) |thread| thread.join();
        }
    }

    while (started < worker_count) : (started += 1) {
        threads[started] = try std.Thread.spawn(.{}, layoutJobWorker, .{ ContextPtr, &work });
    }

    for (threads[0..started]) |thread| thread.join();
    joined = true;

    try graph.checkCancellation(options);

    if (work.failed.load(.seq_cst)) {
        for (outputs) |output| {
            if (output.err) |err| return err;
        }
        return error.LayoutJobFailed;
    }

    for (outputs) |*output| {
        try graph.checkCancellation(options);
        const result = if (output.result) |*value| value else return error.LayoutJobFailed;
        var cloned = try clonePage(state.allocator, result);
        var cloned_transferred = false;
        errdefer if (!cloned_transferred) cloned.deinit(state.allocator);
        try mergePageLayoutIssues(state, &cloned);
        try out.append(state.allocator, cloned);
        cloned_transferred = true;
    }
}

fn layoutJobWorker(comptime ContextPtr: type, work: *PageWork(ContextPtr)) void {
    while (!work.failed.load(.monotonic)) {
        const index = work.next_job.fetchAdd(1, .monotonic);
        if (index >= work.jobs.len) break;
        graph.checkCancellation(work.options) catch |err| {
            work.outputs[index].err = err;
            work.failed.store(true, .seq_cst);
            break;
        };
        const result = work.jobs[index].runIsolated(work.state, std.heap.smp_allocator, work.options) catch |err| {
            work.outputs[index].err = err;
            work.failed.store(true, .seq_cst);
            break;
        };
        work.outputs[index].result = result;
        notifyLayoutProgress(ContextPtr, work);
    }
}

fn notifyLayoutProgress(comptime ContextPtr: type, work: *PageWork(ContextPtr)) void {
    const progress = work.options.progress orelse return;
    lockProgress(&work.progress_lock);
    defer unlockProgress(&work.progress_lock);
    work.completed += 1;
    progress.pageCompleted(progress.context, work.completed, work.jobs.len);
}

fn lockProgress(lock: *std.atomic.Value(bool)) void {
    while (lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
        std.atomic.spinLoopHint();
    }
}

fn unlockProgress(lock: *std.atomic.Value(bool)) void {
    lock.store(false, .release);
}

fn layoutWorkerCount(job_count: usize, options: SolveOptions, parallel_allowed: bool) usize {
    const automatic_job_cap = 8;
    if (!parallel_allowed or job_count <= 1) return 1;
    const requested = options.jobs orelse @min(std.Thread.getCpuCount() catch 1, automatic_job_cap);
    if (requested <= 1) return 1;
    return @min(requested, job_count);
}

fn clonePage(allocator: std.mem.Allocator, result: *const document.Page) !document.Page {
    const object_frames = try allocator.dupe(document.ObjectFrame, result.object_frames);
    var object_frames_transferred = false;
    errdefer if (!object_frames_transferred) allocator.free(object_frames);
    const fallback_constraints = try allocator.dupe(Constraint, result.fallback_constraints);
    var fallback_constraints_transferred = false;
    errdefer if (!fallback_constraints_transferred) allocator.free(fallback_constraints);

    const diagnostics_slice = try allocator.alloc(model.Diagnostic, result.diagnostics.len);
    var diagnostics_transferred = false;
    var copied_diagnostics: usize = 0;
    errdefer {
        if (!diagnostics_transferred) {
            for (diagnostics_slice[0..copied_diagnostics]) |*diagnostic| diagnostic.deinit(allocator);
            allocator.free(diagnostics_slice);
        }
    }
    for (result.diagnostics, 0..) |diagnostic, index| {
        diagnostics_slice[index] = try diagnostic.clone(allocator);
        copied_diagnostics += 1;
    }

    const failure_slice = try allocator.alloc(model.ConstraintFailure, result.constraint_failures.len);
    var failures_transferred = false;
    var copied_failures: usize = 0;
    errdefer {
        if (!failures_transferred) {
            for (failure_slice[0..copied_failures]) |*failure| failure.deinit(allocator);
            allocator.free(failure_slice);
        }
    }
    for (result.constraint_failures, 0..) |failure, index| {
        failure_slice[index] = try failure.clone(allocator);
        copied_failures += 1;
    }

    const asset_keys = try allocator.dupe(u64, result.asset_keys);
    var asset_keys_transferred = false;
    errdefer if (!asset_keys_transferred) allocator.free(asset_keys);
    const measurement_keys = try allocator.dupe(u64, result.measurement_keys);
    var measurement_keys_transferred = false;
    errdefer if (!measurement_keys_transferred) allocator.free(measurement_keys);

    object_frames_transferred = true;
    fallback_constraints_transferred = true;
    diagnostics_transferred = true;
    failures_transferred = true;
    asset_keys_transferred = true;
    measurement_keys_transferred = true;
    return .{
        .page_id = result.page_id,
        .index = result.index,
        .object_frames = object_frames,
        .fallback_constraints = fallback_constraints,
        .diagnostics = diagnostics_slice,
        .constraint_failures = failure_slice,
        .asset_keys = asset_keys,
        .measurement_keys = measurement_keys,
    };
}

fn mergePageLayoutIssues(state: anytype, result: *const document.Page) !void {
    for (result.diagnostics) |diagnostic| {
        var cloned = try diagnostic.clone(state.allocator);
        errdefer cloned.deinit(state.allocator);
        try state.addDiagnostic(cloned);
    }
    for (result.constraint_failures) |failure| {
        var cloned = try failure.clone(state.allocator);
        var cloned_transferred = false;
        errdefer if (!cloned_transferred) cloned.deinit(state.allocator);
        try state.constraint_failures.append(state.allocator, cloned);
        cloned_transferred = true;
        state.last_constraint_failure = state.constraint_failures.items[state.constraint_failures.items.len - 1];
    }
}

pub fn applyDocument(state: anytype, results: *const document.Document) !void {
    state.fallback_constraints.clearRetainingCapacity();
    for (results.pages) |page| {
        try state.fallback_constraints.appendSlice(state.allocator, page.fallback_constraints);
        for (page.object_frames) |entry| {
            const node = state.getNode(entry.node_id) orelse return error.UnknownNode;
            node.frame = entry.frame;
        }
    }
}

fn solvePageLayout(state: anytype, page_id: NodeId, page_index: usize, measurement_cache: *metrics.MeasurementCache, options: SolveOptions) !document.Page {
    try graph.checkCancellation(options);
    const diagnostic_start = state.diagnostics.items.len;
    const constraint_failure_start = state.constraint_failures.items.len;
    const measurement_key_start = measurement_cache.usedKeyCount();
    var page_graph = try graph.PageLayoutGraph.init(state.allocator, state, page_id);
    defer page_graph.deinit();
    try graph.checkCancellation(options);
    if (page_graph.len() == 0) return try collectPage(state, page_id, page_index, &.{}, &.{}, &.{}, diagnostic_start, constraint_failure_start, measurement_cache, measurement_key_start, options);
    try initializePageObjectMeasurements(state, &page_graph, measurement_cache, options);
    try graph.checkCancellation(options);

    var horizontal = try graph.AxisWorkspace.init(state.allocator, state, &page_graph, .horizontal);
    defer horizontal.deinit();
    var horizontal_propagation: ?graph.PropagationTracker = null;
    defer if (horizontal_propagation) |*tracker| tracker.deinit();
    if (options.record_propagation) {
        horizontal_propagation = try graph.PropagationTracker.init(state.allocator, page_graph.len());
        if (horizontal_propagation) |*tracker| horizontal.propagation = tracker;
    }

    try solvePageAxis(state, &horizontal, options);
    try graph.checkCancellation(options);

    var horizontal_fallback = try fallback.buildHorizontalConstraints(state, &horizontal);
    defer horizontal_fallback.deinit(state.allocator);
    layout_trace.recordDefaultConstraints(state.allocator, &horizontal, horizontal_fallback.items);
    horizontal.soft_constraints = horizontal_fallback.items;
    try solvePageAxis(state, &horizontal, options);
    try settleHorizontalAxis(state, &horizontal, options);
    applySolvedHorizontalFrames(state, &horizontal, measurement_cache, options) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => return error.UnknownNode,
    };
    try graph.checkCancellation(options);
    try groups.propagateTargetedWidthsCached(state, &horizontal, measurement_cache);
    try graph.checkCancellation(options);

    var vertical = try graph.AxisWorkspace.init(state.allocator, state, &page_graph, .vertical);
    defer vertical.deinit();
    var vertical_propagation: ?graph.PropagationTracker = null;
    defer if (vertical_propagation) |*tracker| tracker.deinit();
    if (options.record_propagation) {
        vertical_propagation = try graph.PropagationTracker.init(state.allocator, page_graph.len());
        if (vertical_propagation) |*tracker| vertical.propagation = tracker;
    }

    try solvePageAxis(state, &vertical, options);
    try graph.checkCancellation(options);
    var vertical_fallback = try fallback.buildVerticalConstraints(state, &vertical);
    defer vertical_fallback.deinit(state.allocator);
    layout_trace.recordDefaultConstraints(state.allocator, &vertical, vertical_fallback.items);
    vertical.soft_constraints = vertical_fallback.items;
    try solvePageAxis(state, &vertical, options);

    for (page_graph.child_ids, vertical.states) |child_id, v_state| {
        try graph.checkCancellation(options);
        const node = state.getNode(child_id) orelse return error.UnknownNode;
        node.frame.height = v_state.size orelse node.frame.height;
        node.frame.y_set = false;
        if (v_state.start) |y| {
            node.frame.y = y;
            node.frame.y_set = true;
        }
    }

    try validatePageConstraints(state, page_id, &page_graph, options);
    try graph.checkCancellation(options);
    try diagnostics.collectPageDiagnosticsCached(state, page_id, page_graph.child_ids, measurement_cache);
    try graph.checkCancellation(options);
    return try collectPage(
        state,
        page_id,
        page_index,
        page_graph.child_ids,
        horizontal_fallback.items,
        vertical_fallback.items,
        diagnostic_start,
        constraint_failure_start,
        measurement_cache,
        measurement_key_start,
        options,
    );
}

fn collectPage(
    state: anytype,
    page_id: NodeId,
    page_index: usize,
    child_ids: []const NodeId,
    horizontal_fallback: []const Constraint,
    vertical_fallback: []const Constraint,
    diagnostic_start: usize,
    constraint_failure_start: usize,
    measurement_cache: *const metrics.MeasurementCache,
    measurement_key_start: usize,
    options: SolveOptions,
) !document.Page {
    try graph.checkCancellation(options);
    var frames = std.ArrayList(document.ObjectFrame).empty;
    var fallback_constraints = std.ArrayList(Constraint).empty;
    var diagnostics_out = std.ArrayList(model.Diagnostic).empty;
    var failures_out = std.ArrayList(model.ConstraintFailure).empty;
    var measurement_keys = std.ArrayList(u64).empty;
    errdefer {
        frames.deinit(state.allocator);
        fallback_constraints.deinit(state.allocator);
        for (diagnostics_out.items) |*diagnostic| diagnostic.deinit(state.allocator);
        diagnostics_out.deinit(state.allocator);
        for (failures_out.items) |*failure| failure.deinit(state.allocator);
        failures_out.deinit(state.allocator);
        measurement_keys.deinit(state.allocator);
    }
    try fallback_constraints.appendSlice(state.allocator, horizontal_fallback);
    try fallback_constraints.appendSlice(state.allocator, vertical_fallback);
    for (child_ids) |child_id| {
        try graph.checkCancellation(options);
        const node = state.getNode(child_id) orelse return error.UnknownNode;
        if (node.kind != .object) continue;
        try frames.append(state.allocator, .{
            .node_id = child_id,
            .frame = node.frame,
        });
    }
    for (state.diagnostics.items[diagnostic_start..]) |diagnostic| {
        try graph.checkCancellation(options);
        if (diagnostic.page_id != null and diagnostic.page_id.? != page_id) continue;
        var cloned = try diagnostic.clone(state.allocator);
        var cloned_transferred = false;
        errdefer if (!cloned_transferred) cloned.deinit(state.allocator);
        try diagnostics_out.append(state.allocator, cloned);
        cloned_transferred = true;
    }
    for (state.constraint_failures.items[constraint_failure_start..]) |failure| {
        try graph.checkCancellation(options);
        if (failure.page_id != page_id) continue;
        var cloned = try failure.clone(state.allocator);
        var cloned_transferred = false;
        errdefer if (!cloned_transferred) cloned.deinit(state.allocator);
        try failures_out.append(state.allocator, cloned);
        cloned_transferred = true;
    }
    try graph.checkCancellation(options);
    try measurement_cache.appendUsedKeysSince(state.allocator, measurement_key_start, &measurement_keys);
    const frame_slice = try frames.toOwnedSlice(state.allocator);
    var frame_slice_transferred = false;
    errdefer if (!frame_slice_transferred) state.allocator.free(frame_slice);
    const fallback_slice = try fallback_constraints.toOwnedSlice(state.allocator);
    var fallback_slice_transferred = false;
    errdefer if (!fallback_slice_transferred) state.allocator.free(fallback_slice);
    const diagnostic_slice = try diagnostics_out.toOwnedSlice(state.allocator);
    var diagnostic_slice_transferred = false;
    errdefer {
        if (!diagnostic_slice_transferred) {
            for (diagnostic_slice) |*diagnostic| diagnostic.deinit(state.allocator);
            state.allocator.free(diagnostic_slice);
        }
    }
    const failure_slice = try failures_out.toOwnedSlice(state.allocator);
    var failure_slice_transferred = false;
    errdefer {
        if (!failure_slice_transferred) {
            for (failure_slice) |*failure| failure.deinit(state.allocator);
            state.allocator.free(failure_slice);
        }
    }
    const measurement_key_slice = try measurement_keys.toOwnedSlice(state.allocator);
    var measurement_key_slice_transferred = false;
    errdefer if (!measurement_key_slice_transferred) state.allocator.free(measurement_key_slice);
    frame_slice_transferred = true;
    fallback_slice_transferred = true;
    diagnostic_slice_transferred = true;
    failure_slice_transferred = true;
    measurement_key_slice_transferred = true;
    return .{
        .page_id = page_id,
        .index = page_index,
        .object_frames = frame_slice,
        .fallback_constraints = fallback_slice,
        .diagnostics = diagnostic_slice,
        .constraint_failures = failure_slice,
        .measurement_keys = measurement_key_slice,
    };
}

fn initializePageObjectMeasurements(state: anytype, page_graph: *const graph.PageLayoutGraph, measurement_cache: *metrics.MeasurementCache, options: SolveOptions) !void {
    for (page_graph.child_ids) |node_id| {
        try graph.checkCancellation(options);
        const node = state.getNode(node_id) orelse return error.UnknownNode;
        if (node.kind != .object) continue;
        node.frame.x = 0;
        node.frame.y = 0;
        node.frame.x_set = false;
        node.frame.y_set = false;
        node.frame.width = try metrics.intrinsicWidthCached(state, node, measurement_cache);
        node.frame.height = try metrics.intrinsicHeightCached(state, node, measurement_cache);
    }
}

fn applySolvedHorizontalFrames(state: anytype, workspace: *const graph.AxisWorkspace, measurement_cache: *metrics.MeasurementCache, options: SolveOptions) !void {
    for (workspace.graph.child_ids, workspace.states) |child_id, h_state| {
        try graph.checkCancellation(options);
        const node = state.getNode(child_id) orelse return error.UnknownNode;
        const old_width = node.frame.width;
        const solved_width = h_state.size orelse old_width;
        node.frame.width = solved_width;
        if (metrics.shouldWrapNode(state, node) and @abs(solved_width - old_width) > ConstraintTolerance) {
            node.frame.height = try metrics.intrinsicHeightCached(state, node, measurement_cache);
        }
        node.frame.x_set = false;
        if (h_state.start) |x| {
            node.frame.x = x;
            node.frame.x_set = true;
        }
    }
}

fn settleHorizontalAxis(state: anytype, workspace: *graph.AxisWorkspace, options: SolveOptions) !void {
    var pass: usize = 0;
    while (pass < 8) : (pass += 1) {
        try graph.checkCancellation(options);
        var changed = try finalizeHorizontalGroupStates(state, workspace, options);
        changed = (try runPageAxisPass(state, workspace, options)) or changed;
        if (!changed) break;
    }
}

fn finalizeHorizontalGroupStates(state: anytype, workspace: *graph.AxisWorkspace, options: SolveOptions) !bool {
    var any_changed = false;
    var pass: usize = 0;
    while (pass < 8) : (pass += 1) {
        try graph.checkCancellation(options);
        var changed = false;
        changed = (try capDefaultWrappedHorizontalWidths(state, workspace, options)) or changed;
        changed = (try groups.applyTargetConstraints(state, workspace, options)) or changed;
        changed = (try groups.updateAxisStates(state, workspace)) or changed;
        any_changed = changed or any_changed;
        if (!changed) break;
    }
    return any_changed;
}

fn capDefaultWrappedHorizontalWidths(state: anytype, workspace: *graph.AxisWorkspace, options: SolveOptions) !bool {
    var changed = false;
    for (workspace.graph.child_ids, workspace.states) |child_id, *axis_state| {
        try graph.checkCancellation(options);
        if (!axis_state.size_is_default) continue;
        if (axis_state.start == null or axis_state.size == null) continue;
        if (axis_state.end_source != null or axis_state.size_source != null) continue;

        const node = state.getNode(child_id) orelse return error.UnknownNode;
        if (groups.isGroupNode(node)) continue;
        if (!metrics.shouldWrapNode(state, node)) continue;

        const style = style_defaults.styleForNode(state, node);
        const max_right = Defaults.width - style.default_right_inset;
        const capped_width = @max(@as(f32, 1.0), max_right - axis_state.start.?);
        if (capped_width >= axis_state.size.? - ConstraintTolerance) continue;

        axis_state.size = capped_width;
        axis_state.end = axis_state.start.? + capped_width;
        axis_state.center = axis_state.start.? + capped_width / 2;
        axis_state.end_source = null;
        axis_state.center_source = null;
        changed = true;
    }
    return changed;
}

fn solvePageAxis(state: anytype, workspace: *graph.AxisWorkspace, options: SolveOptions) !void {
    try graph.checkCancellation(options);
    _ = try runPageAxisPass(state, workspace, options);

    for (workspace.graph.child_ids, workspace.states, 0..) |child_id, *axis_state, index| {
        try graph.checkCancellation(options);
        if (axis_state.size == null) {
            const node = state.getNode(child_id) orelse return error.UnknownNode;
            axis_state.size = switch (workspace.axis) {
                .horizontal => node.frame.width,
                .vertical => node.frame.height,
            };
            axis_state.size_is_default = true;
            try recordDefaultSizePropagation(state, workspace, index, axis_state.size.?);
        }
    }

    try graph.checkCancellation(options);
    _ = try runPageAxisPass(state, workspace, options);
}

pub fn runPageAxisPass(state: anytype, workspace: *graph.AxisWorkspace, options: SolveOptions) !bool {
    const trace_enabled = layout_trace.shouldTraceAxisPass(workspace);
    const run_id = if (trace_enabled) layout_trace.nextRunId() else 0;
    if (trace_enabled) layout_trace.axisPassBegin(state.allocator, state, workspace, run_id);

    var pass: usize = 0;
    var iteration_count: usize = 0;
    var converged = false;
    var any_changed = false;
    while (pass < 32) : (pass += 1) {
        try graph.checkCancellation(options);
        iteration_count = pass + 1;
        var changed = false;
        var local_pass: usize = 0;
        var local_iterations: usize = 0;
        while (local_pass < 32) : (local_pass += 1) {
            try graph.checkCancellation(options);
            local_iterations += 1;
            var local_changed = false;

            for (workspace.states, 0..) |*axis_state, index| {
                try graph.checkCancellation(options);
                local_changed = (try reconcileAxisStateLocalized(state, workspace, index, axis_state, options)) or local_changed;
            }

            for (workspace.hard_constraints) |constraint| {
                try graph.checkCancellation(options);
                if (groups.constraintTargetsGroup(state, constraint)) continue;
                if (groups.constraintUsesGroupSource(state, constraint)) continue;
                local_changed = (try applyAxisConstraint(state, workspace, constraint, false, options)) or local_changed;
            }

            for (workspace.soft_constraints) |constraint| {
                try graph.checkCancellation(options);
                if (groups.constraintTargetsGroup(state, constraint)) continue;
                if (groups.constraintUsesGroupSource(state, constraint)) continue;
                local_changed = (try applyAxisConstraint(state, workspace, constraint, true, options)) or local_changed;
            }

            changed = local_changed or changed;
            if (!local_changed) break;
        }

        const group_bounds_changed = try groups.updateAxisStates(state, workspace);
        changed = group_bounds_changed or changed;
        const group_targets_changed = try groups.applyTargetConstraints(state, workspace, options);
        changed = group_targets_changed or changed;

        var group_sources_changed = false;
        for (workspace.hard_constraints) |constraint| {
            try graph.checkCancellation(options);
            if (!groups.constraintUsesGroupSource(state, constraint)) continue;
            const applied = try applyAxisConstraint(state, workspace, constraint, false, options);
            group_sources_changed = applied or group_sources_changed;
            changed = applied or changed;
        }

        var soft_group_sources_changed = false;
        for (workspace.soft_constraints) |constraint| {
            try graph.checkCancellation(options);
            if (!groups.constraintUsesGroupSource(state, constraint)) continue;
            const applied = try applyAxisConstraint(state, workspace, constraint, true, options);
            soft_group_sources_changed = applied or soft_group_sources_changed;
            changed = applied or changed;
        }

        if (trace_enabled) {
            layout_trace.axisPassIteration(
                state.allocator,
                state,
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

    if (trace_enabled) layout_trace.axisPassEnd(state.allocator, state, run_id, workspace, iteration_count, converged);
    return any_changed;
}

fn reconcileAxisStateLocalized(state: anytype, workspace: *graph.AxisWorkspace, index: usize, axis_state: *AxisState, options: SolveOptions) !bool {
    const changed = graph.reconcileAxisState(axis_state) catch |err| switch (err) {
        error.ConstraintConflict, error.NegativeFrameSize => blk: {
            const incoming = axis_state.size_source orelse axis_state.end_source orelse axis_state.start_source orelse axis_state.center_source;
            const existing = pickReconcileExistingSource(axis_state, incoming);
            if (options.record_diagnostics) {
                if (incoming) |c| {
                    const kind: model.ConstraintFailureKind = if (err == error.ConstraintConflict) .conflict else .negative_frame_size;
                    const propagation = try reconciliationFailurePropagation(state, workspace, index, axis_state, err);
                    state.noteConstraintFailureDetailedWithPropagation(
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
    if (changed) try recordReconciledPropagation(state, workspace, index);
    return changed;
}

fn reconcileAppliedAxisState(state: anytype, workspace: *graph.AxisWorkspace, index: usize) !void {
    const changed = graph.reconcileAxisState(&workspace.states[index]) catch return;
    if (changed) try recordReconciledPropagation(state, workspace, index);
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

fn applyAxisConstraint(state: anytype, workspace: *graph.AxisWorkspace, constraint: Constraint, is_soft: bool, options: SolveOptions) !bool {
    try graph.checkCancellation(options);
    if (graph.anchorAxis(constraint.target_anchor) != workspace.axis) return false;

    const target_index = workspace.indexOf(constraint.target_node) orelse return false;
    const target_node = state.getNode(constraint.target_node) orelse return error.UnknownNode;
    if (groups.isGroupNode(target_node)) return false;

    switch (graph.classifySelfConstraint(constraint, workspace.axis)) {
        .none => {},
        .tautology => return false,
        .conflict => {
            if (!is_soft and options.record_diagnostics) {
                state.noteConstraintFailureDetailed(
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
                    const propagation = try negativeSizePropagation(state, workspace, target_index, constraint, size);
                    state.noteConstraintFailureDetailedWithPropagation(
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
                        const propagation = try sizeConflictPropagation(state, workspace, target_index, constraint, workspace.states[target_index].size, size);
                        state.noteConstraintFailureDetailedWithPropagation(
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
                        const propagation = try negativeSizePropagation(state, workspace, target_index, constraint, size);
                        state.noteConstraintFailureDetailedWithPropagation(
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
                try recordSizeConstraintPropagation(state, workspace, target_index, constraint, size);
            }
            if (applied) {
                layout_trace.recordConstraintPropagation(state.allocator, workspace, constraint, is_soft, false);
            }
            return applied;
        },
    }

    if (is_soft and graph.axisAnchorValue(workspace.states[target_index], constraint.target_anchor) != null) {
        return false;
    }

    const source_value = try graph.constraintSourceValue(state, workspace, constraint.source);
    if (source_value == null) {
        return try applyReverseAxisConstraint(state, workspace, constraint, is_soft, target_index, options);
    }

    const target_value = source_value.? + constraint.offset;
    if (!is_soft and canMoveDefaultSizedAnchor(state, workspace, target_index)) {
        if (try graph.moveDefaultSizedAnchor(&workspace.states[target_index], constraint.target_anchor, target_value, constraint)) {
            try reconcileAppliedAxisState(state, workspace, target_index);
            try recordAnchorConstraintPropagation(state, workspace, target_index, constraint, target_value);
            layout_trace.recordConstraintPropagation(state.allocator, workspace, constraint, is_soft, false);
            return true;
        }
    }

    if (!is_soft and shouldReplaceDefaultGeometry(state, workspace, target_index, constraint.target_anchor)) {
        if (graph.replaceAxisAnchor(&workspace.states[target_index], constraint.target_anchor, target_value, constraint)) {
            try reconcileAppliedAxisState(state, workspace, target_index);
            try recordAnchorConstraintPropagation(state, workspace, target_index, constraint, target_value);
            layout_trace.recordConstraintPropagation(state.allocator, workspace, constraint, is_soft, false);
            return true;
        }
    }

    const applied = graph.setAxisAnchor(&workspace.states[target_index], constraint.target_anchor, target_value, constraint) catch |err| {
        if (!is_soft and err == error.ConstraintConflict and canMoveDefaultSizedAnchor(state, workspace, target_index)) {
            if (try graph.moveDefaultSizedAnchor(&workspace.states[target_index], constraint.target_anchor, target_value, constraint)) {
                try reconcileAppliedAxisState(state, workspace, target_index);
                try recordAnchorConstraintPropagation(state, workspace, target_index, constraint, target_value);
                layout_trace.recordConstraintPropagation(state.allocator, workspace, constraint, is_soft, false);
                return true;
            }
        }
        if (!is_soft and err == error.ConstraintConflict and canReplaceDuplicateDefaultAnchor(state, workspace, target_index, constraint.target_anchor)) {
            if (try graph.moveDefaultSizedAnchor(&workspace.states[target_index], constraint.target_anchor, target_value, constraint)) {
                try reconcileAppliedAxisState(state, workspace, target_index);
                try recordAnchorConstraintPropagation(state, workspace, target_index, constraint, target_value);
                layout_trace.recordConstraintPropagation(state.allocator, workspace, constraint, is_soft, false);
                return true;
            }
        }
        if (!is_soft and err == error.ConstraintConflict) {
            const existing = graph.axisAnchorSource(workspace.states[target_index], constraint.target_anchor);
            if (existing != null and constraintInSlice(workspace.soft_constraints, existing.?) and graph.replaceAxisAnchor(&workspace.states[target_index], constraint.target_anchor, target_value, constraint)) {
                try reconcileAppliedAxisState(state, workspace, target_index);
                try recordAnchorConstraintPropagation(state, workspace, target_index, constraint, target_value);
                layout_trace.recordConstraintPropagation(state.allocator, workspace, constraint, is_soft, false);
                return true;
            }
        }
        if (is_soft) return false;
        if (options.record_diagnostics) {
            if (err == error.ConstraintConflict) {
                const propagation = try anchorConflictPropagation(state, workspace, target_index, constraint, target_value);
                state.noteConstraintFailureDetailedWithPropagation(
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
                const propagation = try negativeAnchorPropagation(state, workspace, target_index);
                state.noteConstraintFailureDetailedWithPropagation(
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
        try recordAnchorConstraintPropagation(state, workspace, target_index, constraint, target_value);
        layout_trace.recordConstraintPropagation(state.allocator, workspace, constraint, is_soft, false);
    }
    return applied;
}

fn canMoveDefaultSizedAnchor(state: anytype, workspace: *const graph.AxisWorkspace, target_index: usize) bool {
    const axis_state = workspace.states[target_index];
    if (!axis_state.size_is_default or axis_state.size == null) return false;
    _ = state;
    if (workspace.graph.hardTargetAnchorCount(workspace.nodeAt(target_index), workspace.axis) > 1) return false;
    const sources = [_]?Constraint{ axis_state.size_source, axis_state.start_source, axis_state.end_source, axis_state.center_source };
    for (sources) |source| {
        const constraint = source orelse continue;
        if (!constraintInSlice(workspace.soft_constraints, constraint)) return false;
    }
    return true;
}

fn canReplaceDuplicateDefaultAnchor(state: anytype, workspace: *const graph.AxisWorkspace, target_index: usize, target_anchor: model.Anchor) bool {
    const axis_state = workspace.states[target_index];
    if (!axis_state.size_is_default or axis_state.size == null) return false;
    _ = state;
    if (workspace.graph.hardTargetAnchorCount(workspace.nodeAt(target_index), workspace.axis) != 1) return false;
    const existing = graph.axisAnchorSource(axis_state, target_anchor) orelse return false;
    return !constraintInSlice(workspace.soft_constraints, existing);
}

fn shouldReplaceDefaultGeometry(state: anytype, workspace: *const graph.AxisWorkspace, target_index: usize, target_anchor: model.Anchor) bool {
    const axis_state = workspace.states[target_index];
    if (!axis_state.size_is_default) return false;
    _ = state;
    if (workspace.graph.hardTargetAnchorCount(workspace.nodeAt(target_index), workspace.axis) <= 1) return false;

    const existing_source = graph.axisAnchorSource(axis_state, target_anchor);
    if (existing_source) |source| return constraintInSlice(workspace.soft_constraints, source);
    return graph.axisAnchorValue(axis_state, target_anchor) == null;
}

fn constraintInSlice(constraints: []const Constraint, needle: Constraint) bool {
    for (constraints) |constraint| {
        if (constraintsSame(constraint, needle)) return true;
    }
    return false;
}

fn applyReverseAxisConstraint(
    state: anytype,
    workspace: *graph.AxisWorkspace,
    constraint: Constraint,
    is_soft: bool,
    target_index: usize,
    options: SolveOptions,
) !bool {
    try graph.checkCancellation(options);
    if (is_soft) return false;

    const node_source = switch (constraint.source) {
        .page => return false,
        .node => |source| source,
    };
    if (graph.anchorAxis(node_source.anchor) != workspace.axis) return error.ConstraintAxisMismatch;

    const source_node = state.getNode(node_source.node_id) orelse return error.UnknownNode;
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
                const propagation = try reverseAnchorConflictPropagation(state, workspace, source_index, constraint, expected);
                state.noteConstraintFailureDetailedWithPropagation(
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
                const propagation = try negativeAnchorPropagation(state, workspace, source_index);
                state.noteConstraintFailureDetailedWithPropagation(
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
        try recordReverseAnchorConstraintPropagation(state, workspace, source_index, constraint, target_value - constraint.offset);
        layout_trace.recordConstraintPropagation(state.allocator, workspace, constraint, is_soft, true);
    }
    return applied;
}

fn recordDefaultSizePropagation(state: anytype, workspace: *graph.AxisWorkspace, index: usize, value: f32) !void {
    const tracker = workspace.propagation orelse return;
    var trace = graph.PropagationTrace{};
    errdefer trace.deinit(state.allocator);
    const size_label = try nodeSlotLabel(state.allocator, state, workspace, index, .size);
    defer state.allocator.free(size_label);
    try trace.appendOwnedLine(state.allocator, try std.fmt.allocPrint(
        state.allocator,
        "{s} = {d:.1}",
        .{ size_label, value },
    ));
    tracker.setTrace(index, .size, trace);
}

fn recordAnchorConstraintPropagation(state: anytype, workspace: *graph.AxisWorkspace, target_index: usize, constraint: Constraint, value: f32) !void {
    const tracker = workspace.propagation orelse return;
    var trace = try sourceTraceForConstraint(state, workspace, constraint);
    errdefer trace.deinit(state.allocator);
    try appendConstraintLine(state, &trace, constraint, value, false);
    tracker.setTrace(target_index, anchorSlot(constraint.target_anchor), trace);
}

fn recordReverseAnchorConstraintPropagation(state: anytype, workspace: *graph.AxisWorkspace, source_index: usize, constraint: Constraint, value: f32) !void {
    const tracker = workspace.propagation orelse return;
    const target_value = graph.axisAnchorValue(workspace.states[workspace.indexOf(constraint.target_node) orelse return], constraint.target_anchor) orelse value + constraint.offset;
    var trace = try traceForNodeAnchorOrSeed(state, workspace, constraint.target_node, constraint.target_anchor, target_value);
    errdefer trace.deinit(state.allocator);
    try appendConstraintLine(state, &trace, constraint, value, true);
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

fn recordSizeConstraintPropagation(state: anytype, workspace: *graph.AxisWorkspace, target_index: usize, constraint: Constraint, value: f32) !void {
    const tracker = workspace.propagation orelse return;
    var trace = graph.PropagationTrace{};
    errdefer trace.deinit(state.allocator);
    try appendSizeLine(state, workspace, &trace, target_index, constraint, value);
    tracker.setTrace(target_index, .size, trace);
    try recordReconciledPropagation(state, workspace, target_index);
}

fn recordReconciledPropagation(state: anytype, workspace: *graph.AxisWorkspace, index: usize) !void {
    if (workspace.propagation == null) return;
    try recordDerivedSlot(state, workspace, index, .start);
    try recordDerivedSlot(state, workspace, index, .end);
}

fn recordDerivedSlot(state: anytype, workspace: *graph.AxisWorkspace, index: usize, slot: graph.PropagationSlot) !void {
    const tracker = workspace.propagation orelse return;
    const axis_state = workspace.states[index];
    if (tracker.trace(index, slot) != null) return;
    if (slotConstraintSource(axis_state, slot) != null) return;
    if (slot == .size and axis_state.size_is_default) return;
    const after_value = slotValue(axis_state, slot) orelse return;

    const pair = derivationPair(axis_state, slot) orelse return;
    const first_trace = tracker.trace(index, pair.first) orelse return;
    const second_trace = tracker.trace(index, pair.second) orelse return;
    var trace = graph.PropagationTrace{};
    errdefer trace.deinit(state.allocator);
    try trace.appendTrace(state.allocator, first_trace);
    try trace.appendTrace(state.allocator, second_trace);
    try appendDerivedLine(state, workspace, &trace, index, slot, pair, after_value);
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

fn sourceTraceForConstraint(state: anytype, workspace: *graph.AxisWorkspace, constraint: Constraint) !graph.PropagationTrace {
    return switch (constraint.source) {
        .page => |anchor| try pageAnchorTrace(state, workspace, anchor),
        .node => |source| blk: {
            const source_value = (try graph.constraintSourceValue(state, workspace, constraint.source)) orelse 0;
            break :blk try traceForNodeAnchorOrSeed(state, workspace, source.node_id, source.anchor, source_value);
        },
    };
}

fn traceForNodeAnchorOrSeed(state: anytype, workspace: *graph.AxisWorkspace, node_id: NodeId, anchor: model.Anchor, value: f32) !graph.PropagationTrace {
    if (workspace.propagation) |tracker| {
        if (workspace.indexOf(node_id)) |index| {
            if (tracker.trace(index, anchorSlot(anchor))) |existing| return try existing.clone(state.allocator);
        }
    }
    var trace = graph.PropagationTrace{};
    errdefer trace.deinit(state.allocator);
    const label = try nodeAnchorLabel(state.allocator, state, node_id, anchor);
    defer state.allocator.free(label);
    try trace.appendOwnedLine(state.allocator, try std.fmt.allocPrint(
        state.allocator,
        "{s} = {d:.1}",
        .{ label, value },
    ));
    return trace;
}

fn pageAnchorTrace(state: anytype, workspace: *graph.AxisWorkspace, anchor: model.Anchor) !graph.PropagationTrace {
    var trace = graph.PropagationTrace{};
    errdefer trace.deinit(state.allocator);
    const page = state.getNode(workspace.graph.page_id) orelse return error.UnknownNode;
    try trace.appendOwnedLine(state.allocator, try std.fmt.allocPrint(
        state.allocator,
        "page.{s} = {d:.1}",
        .{ @tagName(anchor), graph.anchorValue(page.frame, anchor) },
    ));
    return trace;
}

fn appendConstraintLine(state: anytype, trace: *graph.PropagationTrace, constraint: Constraint, value: f32, reverse: bool) !void {
    const prefix = if (trace.lines.items.len == 0) "" else "→ ";
    const target_label = if (reverse)
        try reverseTargetLabel(state.allocator, state, constraint)
    else
        try nodeAnchorLabel(state.allocator, state, constraint.target_node, constraint.target_anchor);
    defer state.allocator.free(target_label);
    const source_label = if (reverse)
        try nodeAnchorLabel(state.allocator, state, constraint.target_node, constraint.target_anchor)
    else
        try constraintSourceLabel(state.allocator, state, constraint.source);
    defer state.allocator.free(source_label);
    const offset = if (reverse) -constraint.offset else constraint.offset;
    const source_text = try constraintOriginLabel(state.allocator, state, constraint);
    const line = std.fmt.allocPrint(
        state.allocator,
        "{s}{s} = {s} {s} {d:.1} = {d:.1}",
        .{ prefix, target_label, source_label, if (offset < 0) "-" else "+", @abs(offset), value },
    ) catch |err| {
        state.allocator.free(source_text);
        return err;
    };
    try trace.appendOwnedLineWithSource(state.allocator, line, source_text);
}

fn appendSizeLine(state: anytype, workspace: *graph.AxisWorkspace, trace: *graph.PropagationTrace, target_index: usize, constraint: Constraint, value: f32) !void {
    const prefix = if (trace.lines.items.len == 0) "" else "→ ";
    const size_label = try nodeSlotLabel(state.allocator, state, workspace, target_index, .size);
    defer state.allocator.free(size_label);
    if (constraint.source == .node) {
        const source = constraint.source.node;
        if (source.node_id == constraint.target_node and graph.anchorAxis(source.anchor) == workspace.axis) {
            const target_label = try nodeAnchorLabel(state.allocator, state, constraint.target_node, constraint.target_anchor);
            defer state.allocator.free(target_label);
            const source_label = try nodeAnchorLabel(state.allocator, state, source.node_id, source.anchor);
            defer state.allocator.free(source_label);
            const start_label = try nodeSlotLabel(state.allocator, state, workspace, target_index, .start);
            defer state.allocator.free(start_label);
            const end_label = try nodeSlotLabel(state.allocator, state, workspace, target_index, .end);
            defer state.allocator.free(end_label);
            const source_text = try constraintOriginLabel(state.allocator, state, constraint);
            const constraint_line = std.fmt.allocPrint(
                state.allocator,
                "{s}{s} = {s} {s} {d:.1}",
                .{ prefix, target_label, source_label, if (constraint.offset < 0) "-" else "+", @abs(constraint.offset) },
            ) catch |err| {
                state.allocator.free(source_text);
                return err;
            };
            try trace.appendOwnedLineWithSource(state.allocator, constraint_line, source_text);
            try trace.appendOwnedLine(state.allocator, try std.fmt.allocPrint(
                state.allocator,
                "→ {s} = {s} - {s} = {d:.1}",
                .{ size_label, end_label, start_label, value },
            ));
            return;
        }
    }
    const source_text = try constraintOriginLabel(state.allocator, state, constraint);
    const line = std.fmt.allocPrint(
        state.allocator,
        "{s}{s} = {d:.1}",
        .{ prefix, size_label, value },
    ) catch |err| {
        state.allocator.free(source_text);
        return err;
    };
    try trace.appendOwnedLineWithSource(state.allocator, line, source_text);
}

fn appendDerivedLine(state: anytype, workspace: *graph.AxisWorkspace, trace: *graph.PropagationTrace, index: usize, slot: graph.PropagationSlot, pair: DerivationPair, value: f32) !void {
    const target_label = try nodeSlotLabel(state.allocator, state, workspace, index, slot);
    defer state.allocator.free(target_label);
    const first_label = try nodeSlotLabel(state.allocator, state, workspace, index, pair.first);
    defer state.allocator.free(first_label);
    const second_label = try nodeSlotLabel(state.allocator, state, workspace, index, pair.second);
    defer state.allocator.free(second_label);
    try trace.appendOwnedLine(state.allocator, try std.fmt.allocPrint(
        state.allocator,
        "→ {s} = {s}, {s} = {d:.1}",
        .{ target_label, first_label, second_label, value },
    ));
}

fn constraintOriginLabel(allocator: std.mem.Allocator, state: anytype, constraint: Constraint) ![]const u8 {
    const origin_text = constraint.origin orelse return allocator.dupe(u8, "fallback");
    const located = utils.err.parseLocatedOrigin(origin_text) orelse return allocator.dupe(u8, "unknown");
    var path = state.projectPath();
    var source = state.projectSource();
    if (located.path) |origin_path| {
        if (state.moduleByPathOrSpec(origin_path)) |module| {
            path = module.path orelse module.spec;
            source = module.source;
        } else {
            path = origin_path;
        }
    } else {
        const module = state.projectModule();
        path = module.path orelse module.spec;
        source = module.source;
    }
    const loc = utils.source.locationAt(source, located.span.start);
    return std.fmt.allocPrint(allocator, "{s}:{d}", .{ path, loc.line });
}

fn anchorSlot(anchor: model.Anchor) graph.PropagationSlot {
    return switch (anchor) {
        .left, .bottom => .start,
        .right, .top => .end,
        .center_x, .center_y => .center,
    };
}

fn nodeSlotLabel(allocator: std.mem.Allocator, state: anytype, workspace: *const graph.AxisWorkspace, index: usize, slot: graph.PropagationSlot) ![]const u8 {
    const node_id = workspace.nodeAt(index);
    const suffix = switch (slot) {
        .start => if (workspace.axis == .horizontal) "left" else "bottom",
        .end => if (workspace.axis == .horizontal) "right" else "top",
        .center => if (workspace.axis == .horizontal) "center_x" else "center_y",
        .size => if (workspace.axis == .horizontal) "width" else "height",
    };
    return std.fmt.allocPrint(allocator, "{s}.{s}", .{ nodeLabel(state, node_id), suffix });
}

fn nodeAnchorLabel(allocator: std.mem.Allocator, state: anytype, node_id: NodeId, anchor: model.Anchor) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}.{s}", .{ nodeLabel(state, node_id), @tagName(anchor) });
}

fn reverseTargetLabel(allocator: std.mem.Allocator, state: anytype, constraint: Constraint) ![]const u8 {
    return switch (constraint.source) {
        .page => std.fmt.allocPrint(allocator, "page.unknown", .{}),
        .node => |source| nodeAnchorLabel(allocator, state, source.node_id, source.anchor),
    };
}

fn constraintSourceLabel(allocator: std.mem.Allocator, state: anytype, source: model.ConstraintSource) ![]const u8 {
    return switch (source) {
        .page => |anchor| std.fmt.allocPrint(allocator, "page.{s}", .{@tagName(anchor)}),
        .node => |node_source| nodeAnchorLabel(allocator, state, node_source.node_id, node_source.anchor),
    };
}

fn nodeLabel(state: anytype, node_id: NodeId) []const u8 {
    const node = state.getNode(node_id) orelse return "unknown";
    return node.role orelse node.name;
}

fn anchorConflictPropagation(state: anytype, workspace: *graph.AxisWorkspace, target_index: usize, constraint: Constraint, incoming_value: f32) !?model.ConstraintPropagation {
    if (workspace.propagation == null) return null;
    const current_value = graph.axisAnchorValue(workspace.states[target_index], constraint.target_anchor) orelse return null;
    var current = try traceForNodeAnchorOrSeed(state, workspace, constraint.target_node, constraint.target_anchor, current_value);
    defer current.deinit(state.allocator);
    var incoming = try sourceTraceForConstraint(state, workspace, constraint);
    defer incoming.deinit(state.allocator);
    try appendConstraintLine(state, &incoming, constraint, incoming_value, false);
    const target_label = try nodeAnchorLabel(state.allocator, state, constraint.target_node, constraint.target_anchor);
    defer state.allocator.free(target_label);
    return try twoPathPropagation(
        state.allocator,
        target_label,
        "current value",
        &current,
        "incoming value",
        &incoming,
        try std.fmt.allocPrint(
            state.allocator,
            "{s} is already fixed at {d:.1}, but this propagation requires {d:.1}.",
            .{ target_label, current_value, incoming_value },
        ),
        null,
    );
}

fn reverseAnchorConflictPropagation(state: anytype, workspace: *graph.AxisWorkspace, source_index: usize, constraint: Constraint, incoming_value: f32) !?model.ConstraintPropagation {
    if (workspace.propagation == null) return null;
    const node_source = switch (constraint.source) {
        .page => return null,
        .node => |source| source,
    };
    const current_value = graph.axisAnchorValue(workspace.states[source_index], node_source.anchor) orelse return null;
    var current = try traceForNodeAnchorOrSeed(state, workspace, node_source.node_id, node_source.anchor, current_value);
    defer current.deinit(state.allocator);
    const target_value = graph.axisAnchorValue(workspace.states[workspace.indexOf(constraint.target_node) orelse return null], constraint.target_anchor) orelse return null;
    var incoming = try traceForNodeAnchorOrSeed(state, workspace, constraint.target_node, constraint.target_anchor, target_value);
    defer incoming.deinit(state.allocator);
    try appendConstraintLine(state, &incoming, constraint, incoming_value, true);
    const target_label = try nodeAnchorLabel(state.allocator, state, node_source.node_id, node_source.anchor);
    defer state.allocator.free(target_label);
    return try twoPathPropagation(
        state.allocator,
        target_label,
        "current value",
        &current,
        "incoming value",
        &incoming,
        try std.fmt.allocPrint(
            state.allocator,
            "{s} is already fixed at {d:.1}, but this propagation requires {d:.1}.",
            .{ target_label, current_value, incoming_value },
        ),
        null,
    );
}

fn sizeConflictPropagation(state: anytype, workspace: *graph.AxisWorkspace, target_index: usize, constraint: Constraint, current_value: ?f32, incoming_value: f32) !?model.ConstraintPropagation {
    if (workspace.propagation == null) return null;
    const current_size = current_value orelse return null;
    var current = try traceForSlotOrSeed(state, workspace, target_index, .size, current_size);
    defer current.deinit(state.allocator);
    var incoming = graph.PropagationTrace{};
    defer incoming.deinit(state.allocator);
    try appendSizeLine(state, workspace, &incoming, target_index, constraint, incoming_value);
    const target_label = try nodeSlotLabel(state.allocator, state, workspace, target_index, .size);
    defer state.allocator.free(target_label);
    return try twoPathPropagation(
        state.allocator,
        target_label,
        "current value",
        &current,
        "incoming value",
        &incoming,
        try std.fmt.allocPrint(
            state.allocator,
            "{s} is already fixed at {d:.1}, but this propagation requires {d:.1}.",
            .{ target_label, current_size, incoming_value },
        ),
        null,
    );
}

fn negativeSizePropagation(state: anytype, workspace: *graph.AxisWorkspace, target_index: usize, constraint: Constraint, size: f32) !?model.ConstraintPropagation {
    if (workspace.propagation == null) return null;
    var trace = graph.PropagationTrace{};
    defer trace.deinit(state.allocator);
    if (workspace.propagation.?.trace(target_index, .size)) |existing| {
        trace = try existing.clone(state.allocator);
    } else {
        try appendSizeLine(state, workspace, &trace, target_index, constraint, size);
    }
    const target_label = try nodeSlotLabel(state.allocator, state, workspace, target_index, .size);
    defer state.allocator.free(target_label);
    return try onePathPropagation(
        state.allocator,
        target_label,
        if (workspace.axis == .horizontal) "width" else "height",
        &trace,
        try std.fmt.allocPrint(state.allocator, "{s} = {d:.1}", .{ target_label, size }),
    );
}

fn negativeAnchorPropagation(state: anytype, workspace: *graph.AxisWorkspace, target_index: usize) !?model.ConstraintPropagation {
    if (workspace.propagation == null) return null;
    const start_value = workspace.states[target_index].start;
    const end_value = workspace.states[target_index].end;
    if (start_value == null or end_value == null) return null;
    return try frameEdgePropagation(state, workspace, target_index, start_value.?, end_value.?);
}

fn reconciliationFailurePropagation(state: anytype, workspace: *graph.AxisWorkspace, index: usize, axis_state: *const AxisState, err: anyerror) !?model.ConstraintPropagation {
    if (workspace.propagation == null) return null;
    if (err == error.NegativeFrameSize and axis_state.start != null and axis_state.end != null) {
        return try frameEdgePropagation(state, workspace, index, axis_state.start.?, axis_state.end.?);
    }
    return null;
}

fn frameEdgePropagation(state: anytype, workspace: *graph.AxisWorkspace, index: usize, start_value: f32, end_value: f32) !?model.ConstraintPropagation {
    var start_trace = try traceForSlotOrSeed(state, workspace, index, .start, start_value);
    defer start_trace.deinit(state.allocator);
    var end_trace = try traceForSlotOrSeed(state, workspace, index, .end, end_value);
    defer end_trace.deinit(state.allocator);
    const size_label = try nodeSlotLabel(state.allocator, state, workspace, index, .size);
    defer state.allocator.free(size_label);
    const start_label = try nodeSlotLabel(state.allocator, state, workspace, index, .start);
    defer state.allocator.free(start_label);
    const end_label = try nodeSlotLabel(state.allocator, state, workspace, index, .end);
    defer state.allocator.free(end_label);
    return try twoPathPropagation(
        state.allocator,
        size_label,
        if (workspace.axis == .horizontal) "left" else "bottom",
        &start_trace,
        if (workspace.axis == .horizontal) "right" else "top",
        &end_trace,
        try std.fmt.allocPrint(
            state.allocator,
            "{s} = {s} - {s} = {d:.1} - {d:.1} = {d:.1}",
            .{ size_label, end_label, start_label, end_value, start_value, end_value - start_value },
        ),
        null,
    );
}

fn traceForSlotOrSeed(state: anytype, workspace: *graph.AxisWorkspace, index: usize, slot: graph.PropagationSlot, value: f32) !graph.PropagationTrace {
    if (workspace.propagation) |tracker| {
        if (tracker.trace(index, slot)) |existing| return try existing.clone(state.allocator);
    }
    var trace = graph.PropagationTrace{};
    errdefer trace.deinit(state.allocator);
    const label = try nodeSlotLabel(state.allocator, state, workspace, index, slot);
    defer state.allocator.free(label);
    try trace.appendOwnedLine(state.allocator, try std.fmt.allocPrint(state.allocator, "{s} = {d:.1}", .{ label, value }));
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

fn validatePageConstraints(state: anytype, page_id: NodeId, page_graph: *const graph.PageLayoutGraph, options: SolveOptions) !void {
    for (page_graph.constraints) |constraint| {
        try graph.checkCancellation(options);
        if (page_graph.indexOf(constraint.target_node) == null) continue;
        if (constraintAlreadyFailed(state, constraint)) continue;

        const target_value = switch (try finalNodeAnchorValue(state, constraint.target_node, constraint.target_anchor)) {
            .known => |value| value,
            .unknown => {
                const propagation = if (options.record_propagation) try constraintCyclePropagation(state, page_graph, constraint) else null;
                state.noteConstraintFailureDetailedWithPropagation(page_id, constraint, null, .conflict, .constraint_cycle, graph.anchorAxis(constraint.target_anchor), null, null, propagation);
                continue;
            },
        };

        const source_value = switch (try finalConstraintSourceValue(state, page_id, constraint.source)) {
            .known => |value| value,
            .unknown => {
                const propagation = if (options.record_propagation) try constraintCyclePropagation(state, page_graph, constraint) else null;
                state.noteConstraintFailureDetailedWithPropagation(page_id, constraint, null, .conflict, .constraint_cycle, graph.anchorAxis(constraint.target_anchor), target_value, null, propagation);
                continue;
            },
        };

        const expected = source_value + constraint.offset;
        if (@abs(target_value - expected) > ConstraintTolerance) {
            const related = validationRelatedConstraint(page_graph, constraint);
            const propagation = if (options.record_propagation) try validationConflictPropagation(state, page_id, page_graph, constraint, related, target_value, expected) else null;
            state.noteConstraintFailureDetailedWithPropagation(page_id, constraint, related, .conflict, .anchor_value_conflict, graph.anchorAxis(constraint.target_anchor), target_value, expected, propagation);
        }
    }
}

const ConstraintEndpoint = struct {
    node_id: NodeId,
    anchor: model.Anchor,
};

fn constraintCyclePropagation(state: anytype, page_graph: *const graph.PageLayoutGraph, start_constraint: Constraint) !?model.ConstraintPropagation {
    const axis = graph.anchorAxis(start_constraint.target_anchor);
    const start_endpoint: ConstraintEndpoint = .{ .node_id = start_constraint.target_node, .anchor = start_constraint.target_anchor };
    var current = start_constraint;
    var accumulated_offset: f32 = 0;
    var trace = graph.PropagationTrace{};
    defer trace.deinit(state.allocator);

    var steps: usize = 0;
    while (steps <= page_graph.constraints.len) : (steps += 1) {
        if (graph.anchorAxis(current.target_anchor) != axis) return null;
        accumulated_offset += current.offset;
        try appendCycleConstraintLine(state, &trace, current, accumulated_offset);

        const source_endpoint = constraintSourceEndpoint(current.source) orelse return null;
        if (graph.anchorAxis(source_endpoint.anchor) != axis) return null;
        if (constraintEndpointSame(source_endpoint, start_endpoint)) {
            const target_label = try nodeAnchorLabel(state.allocator, state, start_endpoint.node_id, start_endpoint.anchor);
            defer state.allocator.free(target_label);
            return try onePathPropagation(
                state.allocator,
                target_label,
                "cycle",
                &trace,
                try std.fmt.allocPrint(
                    state.allocator,
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
    state: anytype,
    page_id: NodeId,
    page_graph: *const graph.PageLayoutGraph,
    constraint: Constraint,
    related_constraint: ?Constraint,
    target_value: f32,
    expected: f32,
) !?model.ConstraintPropagation {
    var current = if (related_constraint) |related|
        try finalConstraintTrace(state, page_id, page_graph, related, target_value, 0)
    else
        graph.PropagationTrace{};
    defer current.deinit(state.allocator);
    const target_label = try nodeAnchorLabel(state.allocator, state, constraint.target_node, constraint.target_anchor);
    defer state.allocator.free(target_label);
    if (current.lines.items.len == 0) {
        try current.appendOwnedLine(state.allocator, try std.fmt.allocPrint(
            state.allocator,
            "{s} = {d:.1}",
            .{ target_label, target_value },
        ));
    }

    var incoming = try finalConstraintTrace(state, page_id, page_graph, constraint, expected, 0);
    defer incoming.deinit(state.allocator);

    return try twoPathPropagation(
        state.allocator,
        target_label,
        "current value",
        &current,
        "incoming value",
        &incoming,
        try std.fmt.allocPrint(
            state.allocator,
            "{s} is already fixed at {d:.1}, but this propagation requires {d:.1}.",
            .{ target_label, target_value, expected },
        ),
        null,
    );
}

fn finalConstraintTrace(state: anytype, page_id: NodeId, page_graph: *const graph.PageLayoutGraph, constraint: Constraint, value: f32, depth: usize) anyerror!graph.PropagationTrace {
    if (depth > page_graph.constraints.len) return finalNodeAnchorTrace(state, constraint.target_node, constraint.target_anchor, value);
    const source_value = switch (try finalConstraintSourceValue(state, page_id, constraint.source)) {
        .known => |known| known,
        .unknown => value - constraint.offset,
    };
    var trace = try finalConstraintSourceTrace(state, page_id, page_graph, constraint.source, source_value, depth + 1);
    errdefer trace.deinit(state.allocator);
    try appendConstraintLine(state, &trace, constraint, value, false);
    return trace;
}

fn finalConstraintSourceTrace(state: anytype, page_id: NodeId, page_graph: *const graph.PageLayoutGraph, source: model.ConstraintSource, value: f32, depth: usize) anyerror!graph.PropagationTrace {
    return switch (source) {
        .page => |anchor| try finalPageAnchorTrace(state, page_id, anchor, value),
        .node => |node_source| blk: {
            if (findConstraintTargetingEndpoint(page_graph, .{ .node_id = node_source.node_id, .anchor = node_source.anchor }, graph.anchorAxis(node_source.anchor))) |source_constraint| {
                break :blk try finalConstraintTrace(state, page_id, page_graph, source_constraint, value, depth);
            }
            break :blk try finalNodeAnchorTrace(state, node_source.node_id, node_source.anchor, value);
        },
    };
}

fn finalPageAnchorTrace(state: anytype, page_id: NodeId, anchor: model.Anchor, value: f32) !graph.PropagationTrace {
    _ = page_id;
    var trace = graph.PropagationTrace{};
    errdefer trace.deinit(state.allocator);
    try trace.appendOwnedLine(state.allocator, try std.fmt.allocPrint(
        state.allocator,
        "page.{s} = {d:.1}",
        .{ @tagName(anchor), value },
    ));
    return trace;
}

fn finalNodeAnchorTrace(state: anytype, node_id: NodeId, anchor: model.Anchor, value: f32) !graph.PropagationTrace {
    var trace = graph.PropagationTrace{};
    errdefer trace.deinit(state.allocator);
    const label = try nodeAnchorLabel(state.allocator, state, node_id, anchor);
    defer state.allocator.free(label);
    try trace.appendOwnedLine(state.allocator, try std.fmt.allocPrint(state.allocator, "{s} = {d:.1}", .{ label, value }));
    return trace;
}

fn appendCycleConstraintLine(state: anytype, trace: *graph.PropagationTrace, constraint: Constraint, accumulated_offset: f32) !void {
    const prefix = if (trace.lines.items.len == 0) "" else "→ ";
    const target_label = try nodeAnchorLabel(state.allocator, state, constraint.target_node, constraint.target_anchor);
    defer state.allocator.free(target_label);
    const source_label = try constraintSourceLabel(state.allocator, state, constraint.source);
    defer state.allocator.free(source_label);
    const source_text = try constraintOriginLabel(state.allocator, state, constraint);
    const line = std.fmt.allocPrint(
        state.allocator,
        "{s}{s} = {s} {s} {d:.1}; accumulated offset = {d:.1}",
        .{ prefix, target_label, source_label, if (constraint.offset < 0) "-" else "+", @abs(constraint.offset), accumulated_offset },
    ) catch |err| {
        state.allocator.free(source_text);
        return err;
    };
    try trace.appendOwnedLineWithSource(state.allocator, line, source_text);
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

fn constraintAlreadyFailed(state: anytype, constraint: Constraint) bool {
    for (state.constraint_failures.items) |failure| {
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

fn finalConstraintSourceValue(state: anytype, page_id: NodeId, source: model.ConstraintSource) !FinalAnchorValue {
    return switch (source) {
        .page => |anchor| blk: {
            const page = state.getNode(page_id) orelse return error.UnknownNode;
            if (!graph.anchorKnown(page.frame, anchor)) break :blk .{ .unknown = {} };
            break :blk .{ .known = graph.anchorValue(page.frame, anchor) };
        },
        .node => |node_source| try finalNodeAnchorValue(state, node_source.node_id, node_source.anchor),
    };
}

fn finalNodeAnchorValue(state: anytype, node_id: NodeId, anchor: model.Anchor) !FinalAnchorValue {
    const node = state.getNode(node_id) orelse return error.UnknownNode;
    if (!graph.anchorKnown(node.frame, anchor)) return .{ .unknown = {} };
    return .{ .known = graph.anchorValue(node.frame, anchor) };
}
