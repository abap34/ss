const std = @import("std");
const model = @import("model");
const core_context = @import("context.zig");

const Slot = struct {
    target_node: model.NodeId,
    axis: model.Axis,
    role: model.ConstraintRole,

    fn init(target_node: model.NodeId, target_anchor: model.Anchor, role: model.ConstraintRole) Slot {
        return .{
            .target_node = target_node,
            .axis = model.anchorAxis(target_anchor),
            .role = role,
        };
    }
};

const WinnerMap = std.AutoHashMap(Slot, usize);

pub fn resolve(context: *core_context.Context) !void {
    context.overridden_constraints.clearRetainingCapacity();
    for (context.constraint_updates.items) |*update| update.active = false;
    if (context.constraint_updates.items.len == 0) return;

    var winners = WinnerMap.init(context.allocator);
    defer winners.deinit();
    try winners.ensureTotalCapacity(@intCast(context.constraint_updates.items.len));
    for (context.constraint_updates.items, 0..) |update, index| {
        const result = winners.getOrPutAssumeCapacity(Slot.init(update.target_node, update.target_anchor, update.role));
        if (!result.found_existing or update.scope_depth <= context.constraint_updates.items[result.value_ptr.*].scope_depth) {
            result.value_ptr.* = index;
        }
    }
    for (context.constraint_updates.items, 0..) |*update, index| {
        update.active = winners.get(Slot.init(update.target_node, update.target_anchor, update.role)) == index;
    }

    var active_constraints = std.ArrayList(model.Constraint).empty;
    errdefer active_constraints.deinit(context.allocator);
    for (context.constraints.items) |constraint| {
        if (isMaskedByWinner(context.constraint_updates.items, &winners, constraint)) {
            try context.overridden_constraints.append(context.allocator, constraint);
        } else {
            try active_constraints.append(context.allocator, constraint);
        }
    }
    for (context.constraint_updates.items) |update| {
        const replacement = update.replacement orelse continue;
        if (update.active) {
            try active_constraints.append(context.allocator, replacement);
        } else {
            try context.overridden_constraints.append(context.allocator, replacement);
        }
    }
    context.constraints.deinit(context.allocator);
    context.constraints = active_constraints;
}

fn isMaskedByWinner(
    updates: []const model.ConstraintUpdate,
    winners: *const WinnerMap,
    constraint: model.Constraint,
) bool {
    const slot = Slot.init(constraint.target_node, constraint.target_anchor, constraint.role);
    const winner_index = winners.get(slot) orelse return false;
    return updates[winner_index].scope_depth <= constraint.scope_depth;
}
