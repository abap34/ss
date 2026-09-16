const std = @import("std");
const model = @import("model");

const Allocator = model.Allocator;
const NodeId = model.NodeId;
const Axis = model.Axis;
const Constraint = model.Constraint;
const ConstraintSource = model.ConstraintSource;
const Diagnostic = model.Diagnostic;
const DiagnosticPhase = model.DiagnosticPhase;
const ConstraintFailure = model.ConstraintFailure;
const ConstraintFailureKind = model.ConstraintFailureKind;
const ConstraintFailureReason = model.ConstraintFailureReason;

pub const DocumentDiagnostics = struct {
    entries: std.ArrayList(Diagnostic) = .empty,
    constraint_failures: std.ArrayList(ConstraintFailure) = .empty,

    pub fn deinit(self: *DocumentDiagnostics, allocator: Allocator) void {
        self.clearDiagnostics(allocator);
        self.entries.deinit(allocator);
        self.clearConstraintFailures(allocator);
        self.constraint_failures.deinit(allocator);
    }

    pub fn noteConstraintFailureDetailed(
        self: *DocumentDiagnostics,
        allocator: Allocator,
        page_id: NodeId,
        constraint: Constraint,
        existing_constraint: ?Constraint,
        kind: ConstraintFailureKind,
        reason: ConstraintFailureReason,
        axis: ?Axis,
        actual: ?f32,
        expected: ?f32,
    ) !void {
        try self.noteConstraintFailureDetailedWithPropagation(
            allocator,
            page_id,
            constraint,
            existing_constraint,
            kind,
            reason,
            axis,
            actual,
            expected,
            null,
        );
    }

    pub fn noteConstraintFailureDetailedWithPropagation(
        self: *DocumentDiagnostics,
        allocator: Allocator,
        page_id: NodeId,
        constraint: Constraint,
        existing_constraint: ?Constraint,
        kind: ConstraintFailureKind,
        reason: ConstraintFailureReason,
        axis: ?Axis,
        actual: ?f32,
        expected: ?f32,
        propagation: ?model.ConstraintPropagation,
    ) !void {
        var failure: ConstraintFailure = .{
            .kind = kind,
            .reason = reason,
            .page_id = page_id,
            .axis = axis orelse model.anchorAxis(constraint.target_anchor),
            .constraint = constraint,
            .existing_constraint = existing_constraint,
            .actual = actual,
            .expected = expected,
            .propagation = propagation,
        };
        for (self.constraint_failures.items) |*existing| {
            if (constraintFailureSame(existing.*, failure) or constraintFailureSameTarget(existing.*, failure)) {
                if (constraintFailureDetailScore(failure) > constraintFailureDetailScore(existing.*)) {
                    existing.deinit(allocator);
                    existing.* = failure;
                } else {
                    failure.deinit(allocator);
                }
                return;
            }
        }
        self.constraint_failures.append(allocator, failure) catch |err| {
            failure.deinit(allocator);
            return err;
        };
    }

    pub fn hasConstraintFailures(self: *const DocumentDiagnostics) bool {
        return self.constraint_failures.items.len > 0;
    }

    pub fn clearConstraintFailures(self: *DocumentDiagnostics, allocator: Allocator) void {
        for (self.constraint_failures.items) |*failure| failure.deinit(allocator);
        self.constraint_failures.clearRetainingCapacity();
    }

    pub fn clearDiagnostics(self: *DocumentDiagnostics, allocator: Allocator) void {
        for (self.entries.items) |*diagnostic| diagnostic.deinit(allocator);
        self.entries.clearRetainingCapacity();
    }

    pub fn clearDiagnosticsForPhase(self: *DocumentDiagnostics, allocator: Allocator, phase: DiagnosticPhase) void {
        var write_index: usize = 0;
        for (self.entries.items) |*diagnostic| {
            if (diagnostic.phase == phase) {
                diagnostic.deinit(allocator);
                continue;
            }
            self.entries.items[write_index] = diagnostic.*;
            write_index += 1;
        }
        self.entries.items.len = write_index;
    }

    pub fn addDiagnostic(self: *DocumentDiagnostics, allocator: Allocator, diagnostic: Diagnostic) !void {
        try self.entries.append(allocator, diagnostic);
    }

    pub fn deduplicateValidationUserReports(self: *DocumentDiagnostics, allocator: Allocator) void {
        var write_index: usize = 0;
        for (self.entries.items) |*diagnostic| {
            var duplicate = false;
            for (self.entries.items[0..write_index]) |existing| {
                if (validationUserReportsMatch(existing, diagnostic.*)) {
                    duplicate = true;
                    break;
                }
            }
            if (duplicate) {
                diagnostic.deinit(allocator);
                continue;
            }
            self.entries.items[write_index] = diagnostic.*;
            write_index += 1;
        }
        self.entries.items.len = write_index;
    }
};

fn validationUserReportsMatch(left: Diagnostic, right: Diagnostic) bool {
    if (left.phase != .validation or
        right.phase != .validation or
        left.severity != right.severity or
        left.page_id != right.page_id or
        left.node_id != right.node_id or
        left.origin == null or
        right.origin == null)
    {
        return false;
    }
    if (!left.origin.?.eql(right.origin.?)) return false;
    if (!std.mem.eql(u8, left.code(), right.code())) return false;
    const left_message = switch (left.data) {
        .user_report => |data| data.message,
        else => return false,
    };
    const right_message = switch (right.data) {
        .user_report => |data| data.message,
        else => return false,
    };
    return std.mem.eql(u8, left_message, right_message);
}

fn constraintFailureSame(a: ConstraintFailure, b: ConstraintFailure) bool {
    if (a.kind != b.kind) return false;
    if (a.page_id != b.page_id) return false;
    if (constraintFailureConstraintPairSame(a, b)) return true;
    return false;
}

fn constraintFailureSameTarget(a: ConstraintFailure, b: ConstraintFailure) bool {
    if (a.kind != b.kind) return false;
    if (a.reason != b.reason) return false;
    if (a.page_id != b.page_id) return false;
    if (a.axis != b.axis) return false;
    return a.constraint.target_node == b.constraint.target_node and a.constraint.target_anchor == b.constraint.target_anchor;
}

fn constraintFailureDetailScore(failure: ConstraintFailure) usize {
    var score: usize = 0;
    if (failure.propagation) |propagation| {
        score += 100;
        for (propagation.paths) |path| score += path.lines.len;
        score += propagation.result.len;
    }
    if (failure.actual != null) score += 10;
    if (failure.expected != null) score += 10;
    if (failure.existing_constraint != null) score += 1;
    return score;
}

fn constraintFailureConstraintPairSame(a: ConstraintFailure, b: ConstraintFailure) bool {
    if (!constraintEq(a.constraint, b.constraint)) {
        if (a.existing_constraint == null or b.existing_constraint == null) return false;
        return constraintEq(a.constraint, b.existing_constraint.?) and constraintEq(a.existing_constraint.?, b.constraint);
    }
    if ((a.existing_constraint == null) != (b.existing_constraint == null)) return false;
    if (a.existing_constraint) |existing_a| {
        if (!constraintEq(existing_a, b.existing_constraint.?)) return false;
    }
    return true;
}

fn constraintEq(a: Constraint, b: Constraint) bool {
    if (a.target_node != b.target_node) return false;
    if (a.target_anchor != b.target_anchor) return false;
    if (a.offset != b.offset) return false;
    if (a.source_extent_factor != b.source_extent_factor) return false;
    if (a.default_alignment != b.default_alignment) return false;
    if (a.group_split != b.group_split) return false;
    if (!constraintSourceEq(a.source, b.source)) return false;
    return model.SourceOrigin.optionalEql(a.origin, b.origin);
}

fn constraintSourceEq(a: ConstraintSource, b: ConstraintSource) bool {
    return switch (a) {
        .page => |a_anchor| switch (b) {
            .page => |b_anchor| a_anchor == b_anchor,
            .node => false,
        },
        .node => |a_node| switch (b) {
            .page => false,
            .node => |b_node| a_node.node_id == b_node.node_id and a_node.anchor == b_node.anchor,
        },
    };
}
