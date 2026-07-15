const std = @import("std");
const model = @import("model");

pub fn resolve(ir: anytype) !void {
    ir.overridden_constraints.clearRetainingCapacity();
    for (ir.constraint_updates.items) |*update| update.active = false;
    if (ir.constraint_updates.items.len == 0) return;

    var winners = std.ArrayList(usize).empty;
    defer winners.deinit(ir.allocator);
    for (ir.constraint_updates.items, 0..) |update, index| {
        if (winnerPosition(ir.constraint_updates.items, winners.items, update)) |position| {
            const winner = ir.constraint_updates.items[winners.items[position]];
            if (update.scope_depth <= winner.scope_depth) winners.items[position] = index;
        } else {
            try winners.append(ir.allocator, index);
        }
    }
    for (winners.items) |winner_index| ir.constraint_updates.items[winner_index].active = true;

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

fn winnerPosition(
    updates: []const model.ConstraintUpdate,
    winners: []const usize,
    update: model.ConstraintUpdate,
) ?usize {
    for (winners, 0..) |winner_index, position| {
        if (updatesShareSlot(update, updates[winner_index])) return position;
    }
    return null;
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
