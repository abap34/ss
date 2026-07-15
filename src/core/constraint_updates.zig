const std = @import("std");
const model = @import("model");

pub fn resolve(ir: anytype) !void {
    ir.overridden_constraints.clearRetainingCapacity();
    for (ir.constraint_updates.items) |*update| update.active = false;
    if (ir.constraint_updates.items.len == 0) return;

    var winners = std.ArrayList(usize).empty;
    defer winners.deinit(ir.allocator);
    for (ir.constraint_updates.items, 0..) |update, index| {
        if (hasStrongerUpdate(ir.constraint_updates.items, update)) continue;
        for (winners.items) |winner_index| {
            const winner = ir.constraint_updates.items[winner_index];
            if (!updatesShareSlot(update, winner) or winner.scope_depth != update.scope_depth) continue;
            try addDuplicateDiagnostic(ir, update);
            return error.DuplicateConstraintUpdate;
        }
        try winners.append(ir.allocator, index);
        ir.constraint_updates.items[index].active = true;
    }

    var active_constraints = std.ArrayList(model.Constraint).empty;
    errdefer active_constraints.deinit(ir.allocator);
    for (ir.constraints.items) |constraint| {
        if (isMaskedByWinner(ir.constraint_updates.items, winners.items, constraint)) {
            try ir.overridden_constraints.append(ir.allocator, constraint);
        } else {
            try active_constraints.append(ir.allocator, constraint);
        }
    }
    for (ir.constraint_updates.items) |update| {
        const replacement = update.replacement orelse continue;
        if (update.active) {
            try active_constraints.append(ir.allocator, replacement);
        } else {
            try ir.overridden_constraints.append(ir.allocator, replacement);
        }
    }
    ir.constraints.deinit(ir.allocator);
    ir.constraints = active_constraints;
}

fn hasStrongerUpdate(updates: []const model.ConstraintUpdate, update: model.ConstraintUpdate) bool {
    for (updates) |candidate| {
        if (updatesShareSlot(update, candidate) and candidate.scope_depth < update.scope_depth) return true;
    }
    return false;
}

fn isMaskedByWinner(
    updates: []const model.ConstraintUpdate,
    winners: []const usize,
    constraint: model.Constraint,
) bool {
    for (winners) |winner_index| {
        if (updateMasks(updates[winner_index], constraint)) return true;
    }
    return false;
}

fn addDuplicateDiagnostic(ir: anytype, update: model.ConstraintUpdate) !void {
    const node = ir.getNode(update.target_node);
    const label = if (node) |value| value.role orelse value.name else "unknown";
    const message = try std.fmt.allocPrint(
        ir.allocator,
        "DuplicateConstraintUpdate: '{s}.{s}' is updated more than once in the same evaluation scope",
        .{ label, @tagName(update.target_anchor) },
    );
    try ir.addValidationDiagnostic(.@"error", null, update.target_node, update.origin, .{
        .user_report = .{ .message = message },
    });
}

fn updatesShareSlot(left: model.ConstraintUpdate, right: model.ConstraintUpdate) bool {
    return left.target_node == right.target_node and
        model.anchorsShareAxis(left.target_anchor, right.target_anchor) and
        left.role == right.role;
}

fn updateMasks(update: model.ConstraintUpdate, constraint: model.Constraint) bool {
    return update.target_node == constraint.target_node and
        model.anchorsShareAxis(update.target_anchor, constraint.target_anchor) and
        update.role == constraint.role and
        update.scope_depth <= constraint.scope_depth;
}
