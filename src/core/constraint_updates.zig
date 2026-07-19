const std = @import("std");
const model = @import("model");
const document_state = @import("document_state.zig");

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

const GroupPositionMask = struct {
    update_index: usize,
    nodes: std.AutoHashMap(model.NodeId, void),

    fn deinit(self: *GroupPositionMask) void {
        self.nodes.deinit();
    }
};

pub fn resolve(state: *document_state.DocumentState) !void {
    state.overridden_constraints.clearRetainingCapacity();
    for (state.constraint_updates.items) |*update| update.active = false;
    if (state.constraint_updates.items.len == 0) return;

    var winners = WinnerMap.init(state.allocator);
    defer winners.deinit();
    try winners.ensureTotalCapacity(@intCast(state.constraint_updates.items.len));
    for (state.constraint_updates.items, 0..) |update, index| {
        const result = winners.getOrPutAssumeCapacity(Slot.init(update.target_node, update.target_anchor, update.role));
        if (!result.found_existing or update.scope_depth <= state.constraint_updates.items[result.value_ptr.*].scope_depth) {
            result.value_ptr.* = index;
        }
    }
    for (state.constraint_updates.items, 0..) |*update, index| {
        update.active = winners.get(Slot.init(update.target_node, update.target_anchor, update.role)) == index;
    }

    var group_masks = std.ArrayList(GroupPositionMask).empty;
    defer {
        for (group_masks.items) |*mask| mask.deinit();
        group_masks.deinit(state.allocator);
    }
    for (state.constraint_updates.items, 0..) |update, index| {
        if (!update.active or update.role != .position) continue;
        const node = state.getNode(update.target_node) orelse continue;
        if (!model.roleEq(node.role, model.GroupRole)) continue;

        var nodes = std.AutoHashMap(model.NodeId, void).init(state.allocator);
        errdefer nodes.deinit();
        try collectSubtree(state, update.target_node, &nodes);
        try group_masks.append(state.allocator, .{
            .update_index = index,
            .nodes = nodes,
        });
    }
    try resolveOverlappingUpdates(state.constraint_updates.items, group_masks.items, state.allocator);

    var active_constraints = std.ArrayList(model.Constraint).empty;
    errdefer active_constraints.deinit(state.allocator);
    for (state.constraints.items) |constraint| {
        if (isMaskedByWinner(state.constraint_updates.items, &winners, group_masks.items, constraint)) {
            try state.overridden_constraints.append(state.allocator, constraint);
        } else {
            try active_constraints.append(state.allocator, constraint);
        }
    }
    for (state.constraint_updates.items) |update| {
        const replacement = update.replacement orelse continue;
        if (update.active) {
            try active_constraints.append(state.allocator, replacement);
        } else {
            try state.overridden_constraints.append(state.allocator, replacement);
        }
    }
    state.constraints.deinit(state.allocator);
    state.constraints = active_constraints;
}

fn isMaskedByWinner(
    updates: []const model.ConstraintUpdate,
    winners: *const WinnerMap,
    group_masks: []const GroupPositionMask,
    constraint: model.Constraint,
) bool {
    const slot = Slot.init(constraint.target_node, constraint.target_anchor, constraint.role);
    if (winners.get(slot)) |winner_index| {
        if (updates[winner_index].active and updates[winner_index].scope_depth <= constraint.scope_depth) return true;
    }
    if (constraint.role != .position) return false;

    for (group_masks) |mask| {
        const update = updates[mask.update_index];
        if (!update.active) continue;
        if (model.anchorAxis(update.target_anchor) != model.anchorAxis(constraint.target_anchor)) continue;
        if (!mask.nodes.contains(constraint.target_node)) continue;
        if (update.scope_depth > constraint.scope_depth) continue;
        switch (constraint.source) {
            .page => return true,
            .node => |source| if (!mask.nodes.contains(source.node_id)) return true,
        }
    }
    return false;
}

fn resolveOverlappingUpdates(
    updates: []model.ConstraintUpdate,
    group_masks: []const GroupPositionMask,
    allocator: std.mem.Allocator,
) !void {
    const suppressed = try allocator.alloc(bool, updates.len);
    defer allocator.free(suppressed);
    @memset(suppressed, false);

    for (updates, 0..) |update, index| {
        if (!update.active or update.role != .position) continue;
        for (updates, 0..) |candidate, candidate_index| {
            if (index == candidate_index or !candidate.active or candidate.role != .position) continue;
            if (model.anchorAxis(update.target_anchor) != model.anchorAxis(candidate.target_anchor)) continue;
            if (!updatesOverlap(group_masks, index, update.target_node, candidate_index, candidate.target_node)) continue;
            if (hasGreaterAuthority(candidate, candidate_index, update, index)) {
                suppressed[index] = true;
                break;
            }
        }
    }
    for (updates, suppressed) |*update, is_suppressed| {
        if (is_suppressed) update.active = false;
    }
}

fn updatesOverlap(
    group_masks: []const GroupPositionMask,
    left_index: usize,
    left_target: model.NodeId,
    right_index: usize,
    right_target: model.NodeId,
) bool {
    if (left_target == right_target) return true;
    for (group_masks) |mask| {
        if (mask.update_index == left_index and mask.nodes.contains(right_target)) return true;
        if (mask.update_index == right_index and mask.nodes.contains(left_target)) return true;
    }
    return false;
}

fn hasGreaterAuthority(
    candidate: model.ConstraintUpdate,
    candidate_index: usize,
    update: model.ConstraintUpdate,
    update_index: usize,
) bool {
    if (candidate.scope_depth != update.scope_depth) return candidate.scope_depth < update.scope_depth;
    return candidate_index > update_index;
}

fn collectSubtree(
    state: *document_state.DocumentState,
    node_id: model.NodeId,
    nodes: *std.AutoHashMap(model.NodeId, void),
) !void {
    if (nodes.contains(node_id)) return;
    try nodes.put(node_id, {});
    const children = state.childrenOf(node_id) orelse return;
    for (children) |child_id| try collectSubtree(state, child_id, nodes);
}
