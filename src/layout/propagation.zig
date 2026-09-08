const std = @import("std");
const model = @import("model");
const graph = @import("graph.zig");
const groups = @import("groups.zig");

/// Ordinary constraints are reconsidered only when one of their endpoints changes.
pub const Queue = struct {
    allocator: std.mem.Allocator,
    constraints: graph.NodeAdjacency,
    pending: []usize,
    queued: []bool,
    head: usize = 0,
    count: usize = 0,

    pub fn init(allocator: std.mem.Allocator, state: anytype, workspace: *const graph.AxisWorkspace) !Queue {
        const node_count = workspace.states.len;
        const pending = try allocator.alloc(usize, node_count);
        errdefer allocator.free(pending);
        const queued = try allocator.alloc(bool, node_count);
        errdefer allocator.free(queued);
        @memset(queued, false);
        var edges = std.ArrayList(graph.NodeAdjacency.Edge).empty;
        defer edges.deinit(allocator);
        const constraint_count = workspace.hard_constraints.len + workspace.soft_constraints.len;
        try edges.ensureTotalCapacity(allocator, constraint_count * 2);
        for (0..constraint_count) |index| {
            const entry = constraintAt(workspace, index);
            if (groups.constraintTargetsGroup(state, entry.constraint) or groups.constraintUsesGroupSource(state, entry.constraint)) continue;
            const target = workspace.indexOf(entry.constraint.target_node) orelse continue;
            edges.appendAssumeCapacity(.{ .node = target, .value = index });
            if (entry.constraint.source == .node) {
                if (workspace.indexOf(entry.constraint.source.node.node_id)) |source| {
                    if (source != target) edges.appendAssumeCapacity(.{ .node = source, .value = index });
                }
            }
        }
        return .{
            .allocator = allocator,
            .constraints = try graph.NodeAdjacency.init(allocator, node_count, edges.items),
            .pending = pending,
            .queued = queued,
        };
    }

    pub fn deinit(self: *Queue) void {
        self.constraints.deinit(self.allocator);
        self.allocator.free(self.pending);
        self.allocator.free(self.queued);
    }

    pub fn seed(self: *Queue) void {
        for (0..self.pending.len) |index| self.push(index);
    }

    pub fn push(self: *Queue, index: usize) void {
        if (self.queued[index]) return;
        self.pending[(self.head + self.count) % self.pending.len] = index;
        self.count += 1;
        self.queued[index] = true;
    }

    pub fn pop(self: *Queue) ?usize {
        if (self.count == 0) return null;
        const index = self.pending[self.head];
        self.head = (self.head + 1) % self.pending.len;
        self.count -= 1;
        self.queued[index] = false;
        return index;
    }

    pub fn notify(self: *Queue, workspace: *const graph.AxisWorkspace, constraint: model.Constraint) void {
        if (workspace.indexOf(constraint.target_node)) |index| self.push(index);
        if (constraint.source == .node) {
            if (workspace.indexOf(constraint.source.node.node_id)) |index| self.push(index);
        }
    }

    pub fn constraintAt(workspace: *const graph.AxisWorkspace, index: usize) struct { constraint: model.Constraint, soft: bool } {
        return if (index < workspace.hard_constraints.len)
            .{ .constraint = workspace.hard_constraints[index], .soft = false }
        else
            .{ .constraint = workspace.soft_constraints[index - workspace.hard_constraints.len], .soft = true };
    }
};

pub fn groupIterationLimit(node_count: usize) usize {
    return @max(node_count + 1, 32);
}

pub fn nonConvergenceError(state: anytype, workspace: *const graph.AxisWorkspace, options: graph.SolveOptions, stage: model.LayoutConvergenceStage, iterations: usize, limit: usize, pending: ?model.Constraint) anyerror {
    if (options.record_diagnostics) {
        const origin = if (pending) |constraint| constraint.origin else null;
        var diagnostic = model.Diagnostic{
            .phase = .layout,
            .severity = .@"error",
            .page_id = workspace.graph.page_id,
            .node_id = if (pending) |constraint| constraint.target_node else null,
            .origin = if (origin) |value| value.clone(state.allocator) catch |err| return err else null,
            .data = .{ .layout_nonconvergence = .{
                .axis = workspace.axis,
                .stage = stage,
                .iterations = iterations,
                .limit = limit,
                .constraint = if (pending) |constraint| blk: {
                    var copy = constraint;
                    copy.origin = null;
                    break :blk copy;
                } else null,
            } },
        };
        state.addDiagnostic(diagnostic) catch |err| {
            diagnostic.deinit(state.allocator);
            return err;
        };
    }
    return error.LayoutDidNotConverge;
}
