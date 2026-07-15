const std = @import("std");
const model = @import("model");
const core_ir = @import("ir.zig");

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

pub fn resolve(ir: *core_ir.Ir) !void {
    ir.overridden_constraints.clearRetainingCapacity();
    for (ir.constraint_updates.items) |*update| update.active = false;
    if (ir.constraint_updates.items.len == 0) return;

    var winners = WinnerMap.init(ir.allocator);
    defer winners.deinit();
    try winners.ensureTotalCapacity(@intCast(ir.constraint_updates.items.len));
    for (ir.constraint_updates.items, 0..) |update, index| {
        const result = winners.getOrPutAssumeCapacity(Slot.init(update.target_node, update.target_anchor, update.role));
        if (!result.found_existing or update.scope_depth <= ir.constraint_updates.items[result.value_ptr.*].scope_depth) {
            result.value_ptr.* = index;
        }
    }
    for (ir.constraint_updates.items, 0..) |*update, index| {
        update.active = winners.get(Slot.init(update.target_node, update.target_anchor, update.role)) == index;
    }

    var active_constraints = std.ArrayList(model.Constraint).empty;
    errdefer active_constraints.deinit(ir.allocator);
    for (ir.constraints.items) |constraint| {
        if (isMaskedByWinner(ir.constraint_updates.items, &winners, constraint)) {
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

fn isMaskedByWinner(
    updates: []const model.ConstraintUpdate,
    winners: *const WinnerMap,
    constraint: model.Constraint,
) bool {
    const slot = Slot.init(constraint.target_node, constraint.target_anchor, constraint.role);
    const winner_index = winners.get(slot) orelse return false;
    return updates[winner_index].scope_depth <= constraint.scope_depth;
}
