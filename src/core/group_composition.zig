const std = @import("std");
const model = @import("model");

/// Collect adjacency and optional equal cuts before update normalization.
/// Layout consumes only the constraints surviving update normalization.
pub fn collect(state: anytype, node: *const model.Node, constraints: *std.ArrayList(model.Constraint)) !void {
    const config = settings(node);
    try collectAlignment(state, node, config, constraints);
    if (config.mode == .overlay) return;
    try collectAdjacency(state, node, config, constraints);
    if (!config.mode.equal()) return;
    const horizontal = config.mode.isHorizontal();
    const gap = config.gap;
    if (!std.math.isFinite(gap) or gap < 0) return error.InvalidGroupSplit;
    var children = std.ArrayList(model.NodeId).empty;
    defer children.deinit(state.allocator);
    for (state.childrenOf(node.id) orelse &.{}) |child_id| {
        const child = state.getNode(child_id) orelse continue;
        if (child.discarded or child.kind != .object) continue;
        try children.append(state.allocator, child_id);
    }
    if (children.items.len < 2) return error.InvalidGroupSplit;
    const template = model.Constraint{
        .target_node = children.items[0],
        .target_anchor = .left,
        .source = .{ .node = .{ .node_id = node.id, .anchor = .left } },
        .offset = 0,
        .group_split = true,
        .origin = node.origin,
    };
    const count: f32 = @floatFromInt(children.items.len);
    for (children.items, 0..) |child_id, index| {
        const start = @as(f32, @floatFromInt(index)) / count;
        const end = @as(f32, @floatFromInt(index + 1)) / count;
        try appendCut(state.allocator, constraints, template, child_id, horizontal, true, start, gap * start);
        try appendCut(state.allocator, constraints, template, child_id, horizontal, false, end, gap * (end - 1));
    }
    for (children.items) |child_id| {
        const child = state.getNode(child_id).?;
        if (model.isGroupNode(child)) {
            // A nested group receives the complete cell on the other axis.
            if (horizontal) {
                try append(state.allocator, constraints, template, child_id, .bottom, .bottom, 0, false);
                try append(state.allocator, constraints, template, child_id, .top, .top, 0, false);
            } else {
                try append(state.allocator, constraints, template, child_id, .left, .left, 0, false);
                try append(state.allocator, constraints, template, child_id, .right, .right, 0, false);
            }
        } else if (horizontal) {
            // Resolved to top or center_y by the effective page policy.
            try append(state.allocator, constraints, template, child_id, .top, .top, 0, true);
        } else {
            try append(state.allocator, constraints, template, child_id, .left, .left, 0, true);
        }
    }
}

fn collectAdjacency(state: anytype, node: *const model.Node, config: Settings, constraints: *std.ArrayList(model.Constraint)) !void {
    // Equal cuts already determine each cell's position and extent. Adding a
    // sibling relation would keep the previous cell pinned after its cuts are
    // replaced by a caller's position update.
    if (config.mode.equal()) return;
    const horizontal = config.mode.isHorizontal();
    const gap = config.gap;
    if (!std.math.isFinite(gap)) return error.InvalidGroupSplit;
    const template = model.Constraint{
        .target_node = node.id,
        .target_anchor = if (horizontal) .left else .top,
        .source = .{ .node = .{ .node_id = node.id, .anchor = if (horizontal) .right else .bottom } },
        .offset = if (horizontal) gap else -gap,
        .origin = node.origin,
    };
    var previous: ?model.NodeId = null;
    var count: usize = 0;
    for (state.childrenOf(node.id) orelse &.{}) |id| {
        const child = state.getNode(id) orelse continue;
        if (child.discarded or child.kind != .object) continue;
        count += 1;
        if (!horizontal) {
            // Use the containing column when its width and position are fixed.
            // Otherwise the directed sibling candidate below supplies alignment.
            var alignment = template;
            alignment.target_node = id;
            alignment.target_anchor = .left;
            alignment.source = .{ .node = .{ .node_id = node.id, .anchor = .left } };
            alignment.offset = 0;
            alignment.default_alignment = true;
            try constraints.append(state.allocator, alignment);
        }
        if (previous) |source_id| {
            var constraint = template;
            constraint.target_node = id;
            constraint.source.node.node_id = source_id;
            try constraints.append(state.allocator, constraint);
            if (!horizontal) {
                constraint.target_anchor = .left;
                constraint.source.node.anchor = .left;
                constraint.offset = 0;
                constraint.default_alignment = true;
                try constraints.append(state.allocator, constraint);
            }
        }
        previous = id;
    }
    if (count < 2) return error.InvalidGroupSplit;
}

fn appendCut(allocator: std.mem.Allocator, constraints: *std.ArrayList(model.Constraint), template: model.Constraint, target: model.NodeId, horizontal: bool, start: bool, fraction: f32, offset: f32) !void {
    var cut = template;
    cut.target_node = target;
    cut.target_anchor = if (horizontal) (if (start) .left else .right) else (if (start) .top else .bottom);
    cut.source.node.anchor = if (horizontal) .left else .top;
    cut.source_extent_factor = if (horizontal) fraction else -fraction;
    // Keep endpoint and midpoint cuts in the ordinary anchor representation.
    if (fraction == 0 or fraction == 0.5 or fraction == 1) {
        cut.source_extent_factor = 0;
        cut.source.node.anchor = if (horizontal)
            (if (fraction == 0) .left else if (fraction == 1) .right else .center_x)
        else
            (if (fraction == 0) .top else if (fraction == 1) .bottom else .center_y);
    }
    cut.offset = if (horizontal) offset else -offset;
    try constraints.append(allocator, cut);
}

fn append(allocator: std.mem.Allocator, constraints: *std.ArrayList(model.Constraint), template: model.Constraint, target: model.NodeId, target_anchor: model.Anchor, source_anchor: model.Anchor, offset: f32, alignment: bool) !void {
    var constraint = template;
    constraint.target_node = target;
    constraint.target_anchor = target_anchor;
    constraint.source.node.anchor = source_anchor;
    constraint.offset = offset;
    constraint.default_alignment = alignment;
    try constraints.append(allocator, constraint);
}

pub const Settings = struct {
    mode: model.GroupComposition = .overlay,
    gap: f32 = 32,
    align_y: bool = false,
};

pub fn settings(node: *const model.Node) Settings {
    const placement = node.placement orelse return .{};
    if (placement.value != .group) return .{};
    const value = placement.value.group;
    return .{ .mode = value.composition, .gap = value.gap, .align_y = value.composition.isHorizontal() };
}

fn collectAlignment(state: anytype, node: *const model.Node, config: Settings, constraints: *std.ArrayList(model.Constraint)) !void {
    if (!config.align_y) return;
    const template = model.Constraint{
        .target_node = node.id,
        .target_anchor = .top,
        .source = .{ .node = .{ .node_id = node.id, .anchor = .top } },
        .offset = 0,
        .origin = node.origin,
        .default_alignment = true,
    };
    var previous: ?model.NodeId = null;
    for (state.childrenOf(node.id) orelse &.{}) |child_id| {
        const child = state.getNode(child_id) orelse continue;
        if (child.kind != .object or child.discarded) continue;
        if (previous) |source_id| {
            var constraint = template;
            constraint.target_node = child_id;
            constraint.source.node.node_id = source_id;
            try constraints.append(state.allocator, constraint);
        }
        previous = child_id;
    }
}
