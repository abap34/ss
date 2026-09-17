const std = @import("std");
const model = @import("model");
const fields = @import("fields.zig");

/// Collect adjacency and optional equal cuts before update normalization.
/// Natural measurement excludes only cuts; the final pass applies survivors.
pub fn collect(state: anytype, node: *const model.Node, constraints: *std.ArrayList(model.Constraint)) !void {
    try collectAdjacency(state, node, constraints);
    var axis_field = (try fields.get(state.allocator, state, node, "split_axis")) orelse return;
    defer axis_field.deinit(state.allocator);
    const axis_name = switch (axis_field.value) {
        .none => return,
        .enum_case => |value| value.case_name,
        .string => |value| value,
        else => return error.InvalidGroupSplit,
    };
    if (std.mem.eql(u8, axis_name, "none")) return;
    const horizontal = std.mem.eql(u8, axis_name, "horizontal");
    if (!horizontal and !std.mem.eql(u8, axis_name, "vertical")) return error.InvalidGroupSplit;
    const gap = try readNumber(state, node, "split_gap", &.{}, 32);
    const pad_x = try readNumber(state, node, "chrome", &.{"pad_x"}, 0);
    const pad_y = try readNumber(state, node, "chrome", &.{"pad_y"}, 0);
    if (!std.math.isFinite(gap) or gap < 0 or !std.math.isFinite(pad_x) or pad_x < 0 or !std.math.isFinite(pad_y) or pad_y < 0) return error.InvalidGroupSplit;
    var children = std.ArrayList(model.NodeId).empty;
    defer children.deinit(state.allocator);
    for (state.childrenOf(node.id) orelse &.{}) |child_id| {
        const child = state.getNode(child_id) orelse continue;
        if (child.discarded or child.kind != .object) continue;
        try children.append(state.allocator, child_id);
    }
    if (children.items.len < 2) return error.InvalidGroupSplit;
    var template = model.Constraint{
        .target_node = children.items[0],
        .target_anchor = .left,
        .source = .{ .node = .{ .node_id = node.id, .anchor = .left } },
        .offset = 0,
        .group_split = true,
        .origin = node.origin,
    };
    for (node.fields.items) |field| {
        if (!std.mem.eql(u8, field.key, "split_axis")) continue;
        template.scope_depth = field.scope_depth;
        template.origin = field.origin;
        break;
    }
    const count: f32 = @floatFromInt(children.items.len);
    const padding = if (horizontal) pad_x else pad_y;
    for (children.items, 0..) |child_id, index| {
        const start = @as(f32, @floatFromInt(index)) / count;
        const end = @as(f32, @floatFromInt(index + 1)) / count;
        try appendCut(state.allocator, constraints, template, child_id, horizontal, true, start, padding * (1 - 2 * start) + gap * start);
        try appendCut(state.allocator, constraints, template, child_id, horizontal, false, end, padding * (1 - 2 * end) + gap * (end - 1));
    }
    for (children.items) |child_id| {
        const child = state.getNode(child_id).?;
        if (model.roleEq(child.role, model.GroupRole)) {
            // A nested group receives the complete cell on the other axis.
            if (horizontal) {
                try append(state.allocator, constraints, template, child_id, .bottom, .bottom, pad_y, false);
                try append(state.allocator, constraints, template, child_id, .top, .top, -pad_y, false);
            } else {
                try append(state.allocator, constraints, template, child_id, .left, .left, pad_x, false);
                try append(state.allocator, constraints, template, child_id, .right, .right, -pad_x, false);
            }
        } else if (horizontal) {
            // Resolved to top or center_y by the effective page policy.
            try append(state.allocator, constraints, template, child_id, .top, .top, -pad_y, true);
        } else {
            try append(state.allocator, constraints, template, child_id, .left, .left, pad_x, true);
        }
    }
}

fn collectAdjacency(state: anytype, node: *const model.Node, constraints: *std.ArrayList(model.Constraint)) !void {
    var slot = (try fields.get(state.allocator, state, node, "join_axis")) orelse return;
    defer slot.deinit(state.allocator);
    const name = switch (slot.value) {
        .enum_case => |value| value.case_name,
        .string => |value| value,
        .none => return,
        else => return error.InvalidGroupSplit,
    };
    if (std.mem.eql(u8, name, "none")) return;
    const horizontal = std.mem.eql(u8, name, "horizontal");
    if (!horizontal and !std.mem.eql(u8, name, "vertical")) return error.InvalidGroupSplit;
    const gap = try readNumber(state, node, "split_gap", &.{}, 32);
    if (!std.math.isFinite(gap)) return error.InvalidGroupSplit;
    var template = model.Constraint{
        .target_node = node.id,
        .target_anchor = if (horizontal) .left else .top,
        .source = .{ .node = .{ .node_id = node.id, .anchor = if (horizontal) .right else .bottom } },
        .offset = if (horizontal) gap else -gap,
        .origin = node.origin,
    };
    for (node.fields.items) |field| {
        if (!std.mem.eql(u8, field.key, "join_axis")) continue;
        template.scope_depth = field.scope_depth;
        template.origin = field.origin;
        break;
    }
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
            alignment.offset = try readNumber(state, node, "chrome", &.{"pad_x"}, 0);
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

fn readNumber(state: anytype, node: *const model.Node, key: []const u8, path: []const []const u8, default: f32) !f32 {
    var slot = (try fields.get(state.allocator, state, node, key)) orelse return default;
    defer slot.deinit(state.allocator);
    const value = fields.pathValue(slot.value, path) orelse return default;
    return switch (value) {
        .number => |number| number,
        else => error.InvalidGroupSplit,
    };
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
