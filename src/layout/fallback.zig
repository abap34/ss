const std = @import("std");
const model = @import("model");
const groups = @import("groups.zig");
const solver = @import("solver.zig");

const NodeId = model.NodeId;
const Axis = model.Axis;
const AxisState = model.AxisState;
const Constraint = model.Constraint;
const ConstraintSource = model.ConstraintSource;
const PageLayout = model.PageLayout;
const roleEq = model.roleEq;

const VerticalFallbackPolicy = enum {
    top_flow,
    center_stack,
};

pub fn buildHorizontalConstraints(ir: anytype, page_id: NodeId, child_ids: []const NodeId, states: []const AxisState) !std.ArrayList(Constraint) {
    var constraints = std.ArrayList(Constraint).empty;
    if (child_ids.len == 0) return constraints;

    const allocator = ir.allocator;
    const parent = try allocator.alloc(usize, child_ids.len);
    defer allocator.free(parent);
    const page_dependent = try allocator.alloc(bool, child_ids.len);
    defer allocator.free(page_dependent);
    try initAxisComponents(ir, page_id, child_ids, states, .horizontal, parent, page_dependent);

    const seen = try allocator.alloc(bool, child_ids.len);
    defer allocator.free(seen);
    @memset(seen, false);

    for (child_ids, 0..) |_, index| {
        const root = componentFind(parent, index);
        if (seen[root]) continue;
        seen[root] = true;
        if (page_dependent[root]) continue;

        const root_index = componentAxisFallbackRootIndex(ir, child_ids, states, parent, root, .horizontal) orelse continue;
        const root_id = child_ids[root_index];
        const root_node = ir.getNode(root_id) orelse return error.UnknownNode;
        try constraints.append(ir.allocator, .{
            .target_node = root_id,
            .target_anchor = .left,
            .source = .{ .page = .left },
            .offset = solver.styleForNode(ir, root_node).default_x,
        });
    }
    return constraints;
}

pub fn buildVerticalConstraints(ir: anytype, page_id: NodeId, child_ids: []const NodeId, states: []const AxisState) !std.ArrayList(Constraint) {
    return switch (verticalFallbackPolicy(ir, page_id)) {
        .top_flow => buildTopFlowVerticalFallbackConstraints(ir, page_id, child_ids, states),
        .center_stack => buildCenterStackVerticalFallbackConstraints(ir, page_id, child_ids, states),
    };
}

fn verticalFallbackPolicy(ir: anytype, page_id: NodeId) VerticalFallbackPolicy {
    const page = ir.getNode(page_id) orelse return .top_flow;
    const value = model.nodeProperty(page, "layout_v") orelse blk: {
        const document = ir.getNode(ir.document_id) orelse return .top_flow;
        break :blk model.nodeProperty(document, "layout_v") orelse return .top_flow;
    };
    if (std.mem.eql(u8, value, "center") or std.mem.eql(u8, value, "center_stack")) return .center_stack;
    return .top_flow;
}

fn buildTopFlowVerticalFallbackConstraints(ir: anytype, page_id: NodeId, child_ids: []const NodeId, states: []const AxisState) !std.ArrayList(Constraint) {
    var constraints = std.ArrayList(Constraint).empty;
    if (child_ids.len == 0) return constraints;

    const allocator = ir.allocator;
    const parent = try allocator.alloc(usize, child_ids.len);
    defer allocator.free(parent);
    const page_dependent = try allocator.alloc(bool, child_ids.len);
    defer allocator.free(page_dependent);
    try initAxisComponents(ir, page_id, child_ids, states, .vertical, parent, page_dependent);

    const local_tops = try allocator.alloc(?f32, child_ids.len);
    defer allocator.free(local_tops);
    @memset(local_tops, null);

    var units = std.ArrayList(VerticalComponentUnit).empty;
    defer units.deinit(allocator);
    try collectVerticalComponentUnits(ir, page_id, child_ids, states, parent, page_dependent, local_tops, .top_flow, &units);

    const seen = try allocator.alloc(bool, child_ids.len);
    defer allocator.free(seen);
    @memset(seen, false);

    var current_source: ConstraintSource = .{ .page = .top };
    var current_offset: f32 = PageLayout.flow_top - PageLayout.height;
    var current_top_value: f32 = PageLayout.flow_top;

    for (child_ids, states, 0..) |child_id, state, index| {
        const node = ir.getNode(child_id) orelse return error.UnknownNode;
        if (groups.isGroupNode(node)) continue;
        if (roleEq(node.role, "page_number")) continue;

        const root = componentFind(parent, index);
        if (page_dependent[root]) {
            const spacing = solver.styleForNode(ir, node).spacing_after;
            if (state.start) |bottom| {
                const next_top = bottom - spacing;
                if (next_top < current_top_value) {
                    current_source = .{ .node = .{ .node_id = child_id, .anchor = .bottom } };
                    current_offset = -spacing;
                    current_top_value = next_top;
                }
            }
            continue;
        }

        if (seen[root]) continue;
        seen[root] = true;

        const unit = findVerticalComponentUnit(units.items, root) orelse continue;
        try appendVerticalComponentPlacementConstraints(allocator, &constraints, child_ids, parent, local_tops, root, current_source, current_offset, unit.local_top);

        current_source = .{ .node = .{ .node_id = child_ids[unit.bottom_index], .anchor = .bottom } };
        current_offset = -unit.spacing_after;
        current_top_value = current_top_value - unit.height - unit.spacing_after;
    }

    return constraints;
}

const VerticalComponentUnit = struct {
    component_root: usize,
    root_index: usize,
    bottom_index: usize,
    local_top: f32,
    height: f32,
    spacing_after: f32,
};

fn buildCenterStackVerticalFallbackConstraints(ir: anytype, page_id: NodeId, child_ids: []const NodeId, states: []const AxisState) !std.ArrayList(Constraint) {
    var constraints = std.ArrayList(Constraint).empty;
    if (child_ids.len == 0) return constraints;

    const allocator = ir.allocator;
    const parent = try allocator.alloc(usize, child_ids.len);
    defer allocator.free(parent);
    const page_dependent = try allocator.alloc(bool, child_ids.len);
    defer allocator.free(page_dependent);
    try initAxisComponents(ir, page_id, child_ids, states, .vertical, parent, page_dependent);

    const local_tops = try allocator.alloc(?f32, child_ids.len);
    defer allocator.free(local_tops);
    @memset(local_tops, null);

    var units = std.ArrayList(VerticalComponentUnit).empty;
    defer units.deinit(allocator);
    try collectVerticalComponentUnits(ir, page_id, child_ids, states, parent, page_dependent, local_tops, .center_stack, &units);
    if (units.items.len == 0) return constraints;

    var total_height: f32 = 0;
    for (units.items, 0..) |unit, index| {
        total_height += unit.height;
        if (index != units.items.len - 1) total_height += unit.spacing_after;
    }

    var current_top = PageLayout.height / 2 + total_height / 2;
    for (units.items) |unit| {
        try appendVerticalComponentPlacementConstraints(
            allocator,
            &constraints,
            child_ids,
            parent,
            local_tops,
            unit.component_root,
            .{ .page = .bottom },
            current_top - unit.local_top,
            0,
        );
        current_top -= unit.height + unit.spacing_after;
    }

    return constraints;
}

fn initAxisComponents(
    ir: anytype,
    page_id: NodeId,
    child_ids: []const NodeId,
    states: []const AxisState,
    axis: Axis,
    parent: []usize,
    page_dependent: []bool,
) !void {
    for (parent, page_dependent, 0..) |*p, *dependent, index| {
        p.* = index;
        dependent.* = false;
    }
    if (axis == .vertical) {
        try unionContainmentComponents(ir, child_ids, parent, page_dependent);
    }
    try unionAxisConstraintComponents(ir, page_id, child_ids, states, axis, parent, page_dependent);
}

fn collectVerticalComponentUnits(
    ir: anytype,
    page_id: NodeId,
    child_ids: []const NodeId,
    states: []const AxisState,
    parent: []usize,
    page_dependent: []const bool,
    local_tops: []?f32,
    policy: VerticalFallbackPolicy,
    units: *std.ArrayList(VerticalComponentUnit),
) !void {
    var seen = try ir.allocator.alloc(bool, child_ids.len);
    defer ir.allocator.free(seen);
    @memset(seen, false);

    for (child_ids, 0..) |_, index| {
        const root = componentFind(parent, index);
        if (seen[root]) continue;
        seen[root] = true;
        if (page_dependent[root]) continue;

        const unit = try computeVerticalComponentUnit(ir, page_id, child_ids, states, parent, root, local_tops, policy) orelse continue;
        try units.append(ir.allocator, unit);
    }
}

fn appendVerticalComponentPlacementConstraints(
    allocator: std.mem.Allocator,
    constraints: *std.ArrayList(Constraint),
    child_ids: []const NodeId,
    parent: []usize,
    local_tops: []const ?f32,
    component_root: usize,
    source: ConstraintSource,
    base_offset: f32,
    local_top_base: f32,
) !void {
    for (child_ids, 0..) |child_id, index| {
        if (componentFind(parent, index) != component_root) continue;
        const local_top = local_tops[index] orelse continue;
        try constraints.append(allocator, .{
            .target_node = child_id,
            .target_anchor = .top,
            .source = source,
            .offset = base_offset - local_top_base + local_top,
        });
    }
}

fn findVerticalComponentUnit(units: []const VerticalComponentUnit, component_root: usize) ?VerticalComponentUnit {
    for (units) |unit| {
        if (unit.component_root == component_root) return unit;
    }
    return null;
}

fn unionContainmentComponents(ir: anytype, child_ids: []const NodeId, parent: []usize, page_dependent: []bool) !void {
    for (child_ids, 0..) |node_id, index| {
        const node = ir.getNode(node_id) orelse return error.UnknownNode;
        if (!groups.isGroupNode(node)) continue;
        const children = ir.childrenOf(node_id) orelse continue;
        for (children) |child_id| {
            const child_index = solver.indexOfNode(child_ids, child_id) orelse continue;
            componentUnion(parent, page_dependent, index, child_index);
        }
    }
}

fn unionAxisConstraintComponents(
    ir: anytype,
    page_id: NodeId,
    child_ids: []const NodeId,
    states: []const AxisState,
    axis: Axis,
    parent: []usize,
    page_dependent: []bool,
) !void {
    for (child_ids, states, 0..) |child_id, state, index| {
        const node = ir.getNode(child_id) orelse return error.UnknownNode;
        if (roleEq(node.role, "page_number") or state.start != null or state.end != null or state.center != null) {
            page_dependent[componentFind(parent, index)] = true;
        }
    }

    for (ir.constraints.items) |constraint| {
        if (solver.anchorAxis(constraint.target_anchor) != axis) continue;
        if (solver.selfReferentialSize(constraint, axis) != null) continue;
        if (axis == .vertical and groups.constraintTargetsGroup(ir, constraint)) continue;
        const target_page = ir.parentPageOf(constraint.target_node) orelse continue;
        if (target_page != page_id) continue;
        const target_index = solver.indexOfNode(child_ids, constraint.target_node) orelse continue;

        switch (constraint.source) {
            .page => page_dependent[componentFind(parent, target_index)] = true,
            .node => |source| {
                if (solver.anchorAxis(source.anchor) != axis) continue;
                const source_index = solver.indexOfNode(child_ids, source.node_id) orelse {
                    page_dependent[componentFind(parent, target_index)] = true;
                    continue;
                };
                componentUnion(parent, page_dependent, target_index, source_index);
            },
        }
    }
}

fn computeVerticalComponentUnit(
    ir: anytype,
    page_id: NodeId,
    child_ids: []const NodeId,
    states: []const AxisState,
    parent: []usize,
    component_root: usize,
    local_tops: []?f32,
    policy: VerticalFallbackPolicy,
) !?VerticalComponentUnit {
    const root_index = componentFallbackRootIndex(ir, child_ids, parent, component_root) orelse return null;

    const temp = try ir.allocator.alloc(AxisState, states.len);
    defer ir.allocator.free(temp);
    @memcpy(temp, states);
    _ = solver.setAxisAnchor(&temp[root_index], .top, 0, null) catch return null;

    var local_fallback = try buildComponentLocalTopFlowConstraints(ir, child_ids, states, parent, component_root, root_index);
    defer local_fallback.deinit(ir.allocator);
    try solver.runPageAxisPass(ir, page_id, child_ids, temp, .vertical, local_fallback.items);
    if (policy == .center_stack) {
        try centerDirectChildGroupsInComponent(ir, child_ids, temp, parent, component_root);
    }

    var local_bottom: ?f32 = null;
    var local_top: ?f32 = null;
    var bottom_index: ?usize = null;
    for (child_ids, 0..) |child_id, index| {
        if (componentFind(parent, index) != component_root) continue;
        const node = ir.getNode(child_id) orelse return error.UnknownNode;
        if (roleEq(node.role, "page_number")) continue;
        if (groups.isGroupNode(node) and (temp[index].start == null or temp[index].end == null)) continue;
        const start = temp[index].start orelse return null;
        const end = temp[index].end orelse return null;
        if (index == root_index or !solver.hasAxisTargetConstraint(ir, child_id, .vertical)) {
            local_tops[index] = end;
        }
        if (local_bottom == null or start < local_bottom.?) {
            local_bottom = start;
            bottom_index = index;
        }
        if (local_top == null or end > local_top.?) local_top = end;
    }
    if (local_bottom == null or local_top == null) return null;

    const spacing_source_index = bottom_index orelse root_index;
    const spacing_source = ir.getNode(child_ids[spacing_source_index]) orelse return error.UnknownNode;
    return .{
        .component_root = component_root,
        .root_index = root_index,
        .bottom_index = spacing_source_index,
        .local_top = local_top.?,
        .height = local_top.? - local_bottom.?,
        .spacing_after = solver.styleForNode(ir, spacing_source).spacing_after,
    };
}

fn centerDirectChildGroupsInComponent(
    ir: anytype,
    child_ids: []const NodeId,
    states: []AxisState,
    parent: []usize,
    component_root: usize,
) !void {
    var pass: usize = 0;
    while (pass < 8) : (pass += 1) {
        var changed = false;
        changed = (try groups.updateAxisStates(ir, child_ids, states, .vertical, &.{})) or changed;

        for (child_ids, 0..) |group_id, group_index| {
            if (componentFind(parent, group_index) != component_root) continue;
            const group_node = ir.getNode(group_id) orelse return error.UnknownNode;
            if (!groups.isGroupNode(group_node)) continue;
            const group_state = states[group_index];
            const group_center = group_state.center orelse continue;
            const children = ir.childrenOf(group_id) orelse continue;

            for (children) |child_id| {
                const child_index = solver.indexOfNode(child_ids, child_id) orelse continue;
                if (componentFind(parent, child_index) != component_root) continue;
                const child_node = ir.getNode(child_id) orelse return error.UnknownNode;
                if (!groups.isGroupNode(child_node)) continue;
                if (groups.hasTargetConstraint(ir, child_id, .vertical, &.{})) continue;
                const child_center = states[child_index].center orelse continue;
                const delta = group_center - child_center;
                changed = groups.shiftAxisState(&states[child_index], delta) or changed;
                changed = (try groups.translateSubtree(ir, child_ids, states, child_id, delta)) or changed;
            }
        }

        if (!changed) break;
    }
}

fn buildComponentLocalTopFlowConstraints(
    ir: anytype,
    child_ids: []const NodeId,
    states: []const AxisState,
    parent: []usize,
    component_root: usize,
    root_index: usize,
) !std.ArrayList(Constraint) {
    var constraints = std.ArrayList(Constraint).empty;
    try appendLocalTopFlowForPageChildren(ir, child_ids, states, parent, component_root, root_index, &constraints);

    for (child_ids, 0..) |group_id, group_index| {
        if (componentFind(parent, group_index) != component_root) continue;
        const group_node = ir.getNode(group_id) orelse return error.UnknownNode;
        if (!groups.isGroupNode(group_node)) continue;
        try appendLocalTopFlowForGroupChildren(ir, child_ids, states, parent, component_root, root_index, group_id, &constraints);
    }

    return constraints;
}

fn appendLocalTopFlowForPageChildren(
    ir: anytype,
    child_ids: []const NodeId,
    states: []const AxisState,
    parent: []usize,
    component_root: usize,
    root_index: usize,
    constraints: *std.ArrayList(Constraint),
) !void {
    try appendLocalTopFlowForChildren(ir, child_ids, states, parent, component_root, root_index, child_ids, .page, constraints);
}

fn appendLocalTopFlowForGroupChildren(
    ir: anytype,
    child_ids: []const NodeId,
    states: []const AxisState,
    parent: []usize,
    component_root: usize,
    root_index: usize,
    group_id: NodeId,
    constraints: *std.ArrayList(Constraint),
) !void {
    const children = ir.childrenOf(group_id) orelse return;
    try appendLocalTopFlowForChildren(ir, child_ids, states, parent, component_root, root_index, children, .group, constraints);
}

const FlowScope = enum { page, group };

fn appendLocalTopFlowForChildren(
    ir: anytype,
    child_ids: []const NodeId,
    states: []const AxisState,
    parent: []usize,
    component_root: usize,
    root_index: usize,
    children: []const NodeId,
    scope: FlowScope,
    constraints: *std.ArrayList(Constraint),
) !void {
    const allocator = ir.allocator;
    const used = try allocator.alloc(bool, children.len);
    defer allocator.free(used);
    @memset(used, false);

    var unit = std.ArrayList(usize).empty;
    defer unit.deinit(allocator);

    var current_source: ?ConstraintSource = null;
    var current_offset: f32 = 0;
    var started = false;

    for (children, 0..) |child_id, child_pos| {
        if (used[child_pos]) continue;
        const index = flowChildIndex(ir, child_ids, states, parent, component_root, child_id, scope) orelse continue;

        unit.clearRetainingCapacity();
        try collectHorizontalFlowUnit(ir, child_ids, states, parent, component_root, children, scope, index, used, &unit);
        const placement_index = flowUnitPlacementIndex(ir, child_ids, states, unit.items) orelse index;
        const spacing_index = flowUnitBottomIndex(ir, child_ids, states, unit.items) orelse placement_index;
        const contains_root = flowUnitContains(unit.items, root_index);

        if (contains_root) {
            started = true;
        } else if (!started and scope == .page) {
            continue;
        }

        if (!contains_root) {
            try constraints.append(allocator, .{
                .target_node = child_ids[placement_index],
                .target_anchor = .top,
                .source = current_source orelse .{ .node = .{ .node_id = child_ids[root_index], .anchor = .top } },
                .offset = current_offset,
            });
        }

        try appendFlowUnitCenterConstraints(allocator, constraints, child_ids, unit.items, if (contains_root) root_index else placement_index);

        const spacing_node = ir.getNode(child_ids[spacing_index]) orelse return error.UnknownNode;
        current_source = .{ .node = .{ .node_id = child_ids[spacing_index], .anchor = .bottom } };
        current_offset = -solver.styleForNode(ir, spacing_node).spacing_after;
    }
}

fn collectHorizontalFlowUnit(
    ir: anytype,
    child_ids: []const NodeId,
    states: []const AxisState,
    parent: []usize,
    component_root: usize,
    children: []const NodeId,
    scope: FlowScope,
    seed_index: usize,
    used: []bool,
    unit: *std.ArrayList(usize),
) !void {
    try unit.append(ir.allocator, seed_index);
    markChildUsed(child_ids, children, seed_index, used);

    var changed = true;
    while (changed) {
        changed = false;
        for (children) |candidate_id| {
            const candidate_index = flowChildIndex(ir, child_ids, states, parent, component_root, candidate_id, scope) orelse continue;
            if (flowUnitContains(unit.items, candidate_index)) continue;
            if (!hasHorizontalRelationToUnit(ir, child_ids, unit.items, candidate_index)) continue;
            try unit.append(ir.allocator, candidate_index);
            markChildUsed(child_ids, children, candidate_index, used);
            changed = true;
        }
    }
}

fn appendFlowUnitCenterConstraints(
    allocator: std.mem.Allocator,
    constraints: *std.ArrayList(Constraint),
    child_ids: []const NodeId,
    unit: []const usize,
    center_index: usize,
) !void {
    if (unit.len < 2) return;
    for (unit) |index| {
        if (index == center_index) continue;
        try constraints.append(allocator, .{
            .target_node = child_ids[index],
            .target_anchor = .center_y,
            .source = .{ .node = .{ .node_id = child_ids[center_index], .anchor = .center_y } },
            .offset = 0,
        });
    }
}

fn flowChildIndex(
    ir: anytype,
    child_ids: []const NodeId,
    states: []const AxisState,
    parent: []usize,
    component_root: usize,
    child_id: NodeId,
    scope: FlowScope,
) ?usize {
    const index = solver.indexOfNode(child_ids, child_id) orelse return null;
    if (componentFind(parent, index) != component_root) return null;
    const node = ir.getNode(child_id) orelse return null;
    if (groups.isGroupNode(node) and scope != .group) return null;
    if (scope == .page and directParentGroupIndex(ir, child_ids, parent, component_root, child_id) != null) return null;
    const state = states[index];
    if (state.start != null or state.end != null or state.center != null) return null;
    if (solver.hasAxisTargetConstraint(ir, child_id, .vertical)) return null;
    return index;
}

fn flowUnitPlacementIndex(ir: anytype, child_ids: []const NodeId, states: []const AxisState, unit: []const usize) ?usize {
    return flowUnitMaxHeightIndex(ir, child_ids, states, unit);
}

fn flowUnitBottomIndex(ir: anytype, child_ids: []const NodeId, states: []const AxisState, unit: []const usize) ?usize {
    return flowUnitMaxHeightIndex(ir, child_ids, states, unit);
}

fn flowUnitMaxHeightIndex(ir: anytype, child_ids: []const NodeId, states: []const AxisState, unit: []const usize) ?usize {
    var best: ?usize = null;
    var best_height: f32 = -1;
    for (unit) |index| {
        const node = ir.getNode(child_ids[index]) orelse continue;
        const height = states[index].size orelse node.frame.height;
        if (best == null or height > best_height) {
            best = index;
            best_height = height;
        }
    }
    return best;
}

fn hasHorizontalRelationToUnit(ir: anytype, child_ids: []const NodeId, unit: []const usize, candidate_index: usize) bool {
    for (unit) |member_index| {
        if (hasHorizontalRelation(ir, child_ids[candidate_index], child_ids[member_index])) return true;
    }
    return false;
}

fn hasHorizontalRelation(ir: anytype, a: NodeId, b: NodeId) bool {
    for (ir.constraints.items) |constraint| {
        if (solver.anchorAxis(constraint.target_anchor) != .horizontal) continue;
        const source = switch (constraint.source) {
            .page => continue,
            .node => |source| source,
        };
        if (solver.anchorAxis(source.anchor) != .horizontal) continue;
        if (constraint.target_node == a and source.node_id == b) return true;
        if (constraint.target_node == b and source.node_id == a) return true;
    }
    return false;
}

fn markChildUsed(child_ids: []const NodeId, children: []const NodeId, index: usize, used: []bool) void {
    for (children, 0..) |child_id, child_pos| {
        if (child_id == child_ids[index]) {
            used[child_pos] = true;
            return;
        }
    }
}

fn flowUnitContains(unit: []const usize, index: usize) bool {
    for (unit) |member| {
        if (member == index) return true;
    }
    return false;
}

fn directParentGroupIndex(ir: anytype, child_ids: []const NodeId, parent: []usize, component_root: usize, child_id: NodeId) ?usize {
    for (child_ids, 0..) |candidate_id, index| {
        if (componentFind(parent, index) != component_root) continue;
        const candidate = ir.getNode(candidate_id) orelse continue;
        if (!groups.isGroupNode(candidate)) continue;
        const children = ir.childrenOf(candidate_id) orelse continue;
        for (children) |group_child_id| {
            if (group_child_id == child_id) return index;
        }
    }
    return null;
}

fn componentFallbackRootIndex(ir: anytype, child_ids: []const NodeId, parent: []usize, component_root: usize) ?usize {
    for (child_ids, 0..) |child_id, index| {
        if (componentFind(parent, index) != component_root) continue;
        const node = ir.getNode(child_id) orelse continue;
        if (groups.isGroupNode(node)) continue;
        if (roleEq(node.role, "page_number")) continue;
        return index;
    }
    return null;
}

fn componentAxisFallbackRootIndex(
    ir: anytype,
    child_ids: []const NodeId,
    states: []const AxisState,
    parent: []usize,
    component_root: usize,
    axis: Axis,
) ?usize {
    var fallback: ?usize = null;
    for (child_ids, states, 0..) |child_id, state, index| {
        if (componentFind(parent, index) != component_root) continue;
        const node = ir.getNode(child_id) orelse continue;
        if (groups.isGroupNode(node)) continue;
        if (roleEq(node.role, "page_number")) continue;
        if (fallback == null) fallback = index;
        if (state.start == null and !solver.hasAxisTargetConstraint(ir, child_id, axis)) return index;
    }
    return fallback;
}

fn componentFind(parent: []usize, index: usize) usize {
    var current = index;
    while (parent[current] != current) {
        current = parent[current];
    }
    return current;
}

fn componentUnion(parent: []usize, page_dependent: []bool, a: usize, b: usize) void {
    const a_root = componentFind(parent, a);
    const b_root = componentFind(parent, b);
    if (a_root == b_root) return;
    parent[b_root] = a_root;
    page_dependent[a_root] = page_dependent[a_root] or page_dependent[b_root];
}
