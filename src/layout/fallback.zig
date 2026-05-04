const std = @import("std");
const model = @import("model");
const graph = @import("graph.zig");
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

pub fn buildHorizontalConstraints(ir: anytype, workspace: *const graph.AxisWorkspace) !std.ArrayList(Constraint) {
    var constraints = std.ArrayList(Constraint).empty;
    if (workspace.graph.len() == 0) return constraints;

    const allocator = ir.allocator;
    var components = try workspace.dependencyComponents(allocator, ir, .{});
    defer components.deinit();
    var roots = try components.rootIndexes(allocator);
    defer roots.deinit(allocator);

    for (roots.items) |root| {
        if (components.isPageDependent(root)) continue;
        const root_index = components.axisFallbackRootIndex(ir, root) orelse continue;
        const root_id = workspace.nodeAt(root_index);
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

pub fn buildVerticalConstraints(ir: anytype, workspace: *const graph.AxisWorkspace) !std.ArrayList(Constraint) {
    return switch (verticalFallbackPolicy(ir, workspace.graph.page_id)) {
        .top_flow => buildTopFlowVerticalFallbackConstraints(ir, workspace),
        .center_stack => buildCenterStackVerticalFallbackConstraints(ir, workspace),
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

fn buildTopFlowVerticalFallbackConstraints(ir: anytype, workspace: *const graph.AxisWorkspace) !std.ArrayList(Constraint) {
    var constraints = std.ArrayList(Constraint).empty;
    if (workspace.graph.len() == 0) return constraints;

    const allocator = ir.allocator;
    var components = try workspace.dependencyComponents(allocator, ir, .{ .include_containment = true, .skip_group_targets = true });
    defer components.deinit();

    const local_tops = try allocator.alloc(?f32, workspace.graph.len());
    defer allocator.free(local_tops);
    @memset(local_tops, null);

    var units = std.ArrayList(VerticalComponentUnit).empty;
    defer units.deinit(allocator);
    try collectVerticalComponentUnits(ir, workspace, &components, local_tops, .top_flow, &units);

    const seen = try allocator.alloc(bool, workspace.graph.len());
    defer allocator.free(seen);
    @memset(seen, false);

    var current_source: ConstraintSource = .{ .page = .top };
    var current_offset: f32 = PageLayout.flow_top - PageLayout.height;
    var current_top_value: f32 = PageLayout.flow_top;

    for (workspace.graph.child_ids, workspace.states, 0..) |child_id, state, index| {
        const node = ir.getNode(child_id) orelse return error.UnknownNode;
        if (groups.isGroupNode(node)) continue;
        if (roleEq(node.role, "page_number")) continue;

        const root = components.findConst(index);
        if (components.isPageDependent(root)) {
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
        try appendVerticalComponentPlacementConstraints(allocator, &constraints, workspace, &components, local_tops, root, current_source, current_offset, unit.local_top);

        current_source = .{ .node = .{ .node_id = workspace.nodeAt(unit.bottom_index), .anchor = .bottom } };
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

fn buildCenterStackVerticalFallbackConstraints(ir: anytype, workspace: *const graph.AxisWorkspace) !std.ArrayList(Constraint) {
    var constraints = std.ArrayList(Constraint).empty;
    if (workspace.graph.len() == 0) return constraints;

    const allocator = ir.allocator;
    var components = try workspace.dependencyComponents(allocator, ir, .{ .include_containment = true, .skip_group_targets = true });
    defer components.deinit();

    const local_tops = try allocator.alloc(?f32, workspace.graph.len());
    defer allocator.free(local_tops);
    @memset(local_tops, null);

    var units = std.ArrayList(VerticalComponentUnit).empty;
    defer units.deinit(allocator);
    try collectVerticalComponentUnits(ir, workspace, &components, local_tops, .center_stack, &units);
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
            workspace,
            &components,
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

fn collectVerticalComponentUnits(
    ir: anytype,
    workspace: *const graph.AxisWorkspace,
    components: *const graph.ComponentSet,
    local_tops: []?f32,
    policy: VerticalFallbackPolicy,
    units: *std.ArrayList(VerticalComponentUnit),
) !void {
    var seen = try ir.allocator.alloc(bool, workspace.graph.len());
    defer ir.allocator.free(seen);
    @memset(seen, false);

    for (workspace.graph.child_ids, 0..) |_, index| {
        const root = components.findConst(index);
        if (seen[root]) continue;
        seen[root] = true;
        if (components.isPageDependent(root)) continue;

        const unit = try computeVerticalComponentUnit(ir, workspace, components, root, local_tops, policy) orelse continue;
        try units.append(ir.allocator, unit);
    }
}

fn appendVerticalComponentPlacementConstraints(
    allocator: std.mem.Allocator,
    constraints: *std.ArrayList(Constraint),
    workspace: *const graph.AxisWorkspace,
    components: *const graph.ComponentSet,
    local_tops: []const ?f32,
    component_root: usize,
    source: ConstraintSource,
    base_offset: f32,
    local_top_base: f32,
) !void {
    for (workspace.graph.child_ids, 0..) |child_id, index| {
        if (!components.contains(component_root, index)) continue;
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

fn computeVerticalComponentUnit(
    ir: anytype,
    workspace: *const graph.AxisWorkspace,
    components: *const graph.ComponentSet,
    component_root: usize,
    local_tops: []?f32,
    policy: VerticalFallbackPolicy,
) !?VerticalComponentUnit {
    const root_index = components.fallbackRootIndex(ir, component_root) orelse return null;

    const temp = try ir.allocator.alloc(AxisState, workspace.states.len);
    defer ir.allocator.free(temp);
    @memcpy(temp, workspace.states);
    _ = solver.setAxisAnchor(&temp[root_index], .top, 0, null) catch return null;

    var local_fallback = try buildComponentLocalTopFlowConstraints(ir, workspace, components, component_root, root_index);
    defer local_fallback.deinit(ir.allocator);
    var temp_workspace = graph.AxisWorkspace.borrow(workspace, temp, local_fallback.items);
    try solver.runPageAxisPass(ir, &temp_workspace);
    if (policy == .center_stack) {
        try centerDirectChildGroupsInComponent(ir, &temp_workspace, components, component_root);
    }

    var local_bottom: ?f32 = null;
    var local_top: ?f32 = null;
    var bottom_index: ?usize = null;
    for (workspace.graph.child_ids, 0..) |child_id, index| {
        if (!components.contains(component_root, index)) continue;
        const node = ir.getNode(child_id) orelse return error.UnknownNode;
        if (roleEq(node.role, "page_number")) continue;
        if (groups.isGroupNode(node) and (temp[index].start == null or temp[index].end == null)) continue;
        const start = temp[index].start orelse return null;
        const end = temp[index].end orelse return null;
        if (index == root_index or !workspace.graph.hasTargetConstraint(ir, child_id, .vertical, &.{})) {
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
    const spacing_source = ir.getNode(workspace.nodeAt(spacing_source_index)) orelse return error.UnknownNode;
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
    workspace: *graph.AxisWorkspace,
    components: *const graph.ComponentSet,
    component_root: usize,
) !void {
    var pass: usize = 0;
    while (pass < 8) : (pass += 1) {
        var changed = false;
        changed = (try groups.updateAxisStates(ir, workspace)) or changed;

        for (workspace.graph.child_ids, 0..) |group_id, group_index| {
            if (!components.contains(component_root, group_index)) continue;
            const group_node = ir.getNode(group_id) orelse return error.UnknownNode;
            if (!groups.isGroupNode(group_node)) continue;
            const group_state = workspace.states[group_index];
            const group_center = group_state.center orelse continue;
            const children = ir.childrenOf(group_id) orelse continue;

            for (children) |child_id| {
                const child_index = workspace.indexOf(child_id) orelse continue;
                if (!components.contains(component_root, child_index)) continue;
                const child_node = ir.getNode(child_id) orelse return error.UnknownNode;
                if (!groups.isGroupNode(child_node)) continue;
                if (workspace.graph.hasTargetConstraint(ir, child_id, .vertical, &.{})) continue;
                const child_center = workspace.states[child_index].center orelse continue;
                const delta = group_center - child_center;
                changed = groups.shiftAxisState(&workspace.states[child_index], delta) or changed;
                changed = (try groups.translateSubtree(ir, workspace, child_id, delta)) or changed;
            }
        }

        if (!changed) break;
    }
}

fn buildComponentLocalTopFlowConstraints(
    ir: anytype,
    workspace: *const graph.AxisWorkspace,
    components: *const graph.ComponentSet,
    component_root: usize,
    root_index: usize,
) !std.ArrayList(Constraint) {
    var constraints = std.ArrayList(Constraint).empty;
    try appendLocalTopFlowForPageChildren(ir, workspace, components, component_root, root_index, &constraints);

    for (workspace.graph.child_ids, 0..) |group_id, group_index| {
        if (!components.contains(component_root, group_index)) continue;
        const group_node = ir.getNode(group_id) orelse return error.UnknownNode;
        if (!groups.isGroupNode(group_node)) continue;
        try appendLocalTopFlowForGroupChildren(ir, workspace, components, component_root, root_index, group_id, &constraints);
    }

    return constraints;
}

fn appendLocalTopFlowForPageChildren(
    ir: anytype,
    workspace: *const graph.AxisWorkspace,
    components: *const graph.ComponentSet,
    component_root: usize,
    root_index: usize,
    constraints: *std.ArrayList(Constraint),
) !void {
    try appendLocalTopFlowForChildren(ir, workspace, components, component_root, root_index, workspace.graph.child_ids, .page, constraints);
}

fn appendLocalTopFlowForGroupChildren(
    ir: anytype,
    workspace: *const graph.AxisWorkspace,
    components: *const graph.ComponentSet,
    component_root: usize,
    root_index: usize,
    group_id: NodeId,
    constraints: *std.ArrayList(Constraint),
) !void {
    const children = ir.childrenOf(group_id) orelse return;
    try appendLocalTopFlowForChildren(ir, workspace, components, component_root, root_index, children, .group, constraints);
}

const FlowScope = enum { page, group };

fn appendLocalTopFlowForChildren(
    ir: anytype,
    workspace: *const graph.AxisWorkspace,
    components: *const graph.ComponentSet,
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
        const index = flowChildIndex(ir, workspace, components, component_root, child_id, scope) orelse continue;

        unit.clearRetainingCapacity();
        try collectHorizontalFlowUnit(ir, workspace, components, component_root, children, scope, index, used, &unit);
        const placement_index = flowUnitPlacementIndex(ir, workspace, unit.items) orelse index;
        const spacing_index = flowUnitBottomIndex(ir, workspace, unit.items) orelse placement_index;
        const contains_root = flowUnitContains(unit.items, root_index);

        if (contains_root) {
            started = true;
        } else if (!started and scope == .page) {
            continue;
        }

        if (!contains_root) {
            try constraints.append(allocator, .{
                .target_node = workspace.nodeAt(placement_index),
                .target_anchor = .top,
                .source = current_source orelse .{ .node = .{ .node_id = workspace.nodeAt(root_index), .anchor = .top } },
                .offset = current_offset,
            });
        }

        try appendFlowUnitCenterConstraints(allocator, constraints, workspace, unit.items, if (contains_root) root_index else placement_index);

        const spacing_node = ir.getNode(workspace.nodeAt(spacing_index)) orelse return error.UnknownNode;
        current_source = .{ .node = .{ .node_id = workspace.nodeAt(spacing_index), .anchor = .bottom } };
        current_offset = -solver.styleForNode(ir, spacing_node).spacing_after;
    }
}

fn collectHorizontalFlowUnit(
    ir: anytype,
    workspace: *const graph.AxisWorkspace,
    components: *const graph.ComponentSet,
    component_root: usize,
    children: []const NodeId,
    scope: FlowScope,
    seed_index: usize,
    used: []bool,
    unit: *std.ArrayList(usize),
) !void {
    try unit.append(ir.allocator, seed_index);
    markChildUsed(workspace, children, seed_index, used);

    var changed = true;
    while (changed) {
        changed = false;
        for (children) |candidate_id| {
            const candidate_index = flowChildIndex(ir, workspace, components, component_root, candidate_id, scope) orelse continue;
            if (flowUnitContains(unit.items, candidate_index)) continue;
            if (!hasHorizontalRelationToUnit(ir, workspace, unit.items, candidate_index)) continue;
            try unit.append(ir.allocator, candidate_index);
            markChildUsed(workspace, children, candidate_index, used);
            changed = true;
        }
    }
}

fn appendFlowUnitCenterConstraints(
    allocator: std.mem.Allocator,
    constraints: *std.ArrayList(Constraint),
    workspace: *const graph.AxisWorkspace,
    unit: []const usize,
    center_index: usize,
) !void {
    if (unit.len < 2) return;
    for (unit) |index| {
        if (index == center_index) continue;
        try constraints.append(allocator, .{
            .target_node = workspace.nodeAt(index),
            .target_anchor = .center_y,
            .source = .{ .node = .{ .node_id = workspace.nodeAt(center_index), .anchor = .center_y } },
            .offset = 0,
        });
    }
}

fn flowChildIndex(
    ir: anytype,
    workspace: *const graph.AxisWorkspace,
    components: *const graph.ComponentSet,
    component_root: usize,
    child_id: NodeId,
    scope: FlowScope,
) ?usize {
    const index = workspace.indexOf(child_id) orelse return null;
    if (!components.contains(component_root, index)) return null;
    const node = ir.getNode(child_id) orelse return null;
    if (groups.isGroupNode(node) and scope != .group) return null;
    if (scope == .page and directParentGroupIndex(ir, workspace, components, component_root, child_id) != null) return null;
    const state = workspace.states[index];
    if (state.start != null or state.end != null or state.center != null) return null;
    if (workspace.graph.hasTargetConstraint(ir, child_id, .vertical, &.{})) return null;
    return index;
}

fn flowUnitPlacementIndex(ir: anytype, workspace: *const graph.AxisWorkspace, unit: []const usize) ?usize {
    return flowUnitMaxHeightIndex(ir, workspace, unit);
}

fn flowUnitBottomIndex(ir: anytype, workspace: *const graph.AxisWorkspace, unit: []const usize) ?usize {
    return flowUnitMaxHeightIndex(ir, workspace, unit);
}

fn flowUnitMaxHeightIndex(ir: anytype, workspace: *const graph.AxisWorkspace, unit: []const usize) ?usize {
    var best: ?usize = null;
    var best_height: f32 = -1;
    for (unit) |index| {
        const node = ir.getNode(workspace.nodeAt(index)) orelse continue;
        const height = workspace.states[index].size orelse node.frame.height;
        if (best == null or height > best_height) {
            best = index;
            best_height = height;
        }
    }
    return best;
}

fn hasHorizontalRelationToUnit(ir: anytype, workspace: *const graph.AxisWorkspace, unit: []const usize, candidate_index: usize) bool {
    for (unit) |member_index| {
        if (hasHorizontalRelation(ir, workspace.nodeAt(candidate_index), workspace.nodeAt(member_index))) return true;
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

fn markChildUsed(workspace: *const graph.AxisWorkspace, children: []const NodeId, index: usize, used: []bool) void {
    for (children, 0..) |child_id, child_pos| {
        if (child_id == workspace.nodeAt(index)) {
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

fn directParentGroupIndex(ir: anytype, workspace: *const graph.AxisWorkspace, components: *const graph.ComponentSet, component_root: usize, child_id: NodeId) ?usize {
    for (workspace.graph.child_ids, 0..) |candidate_id, index| {
        if (!components.contains(component_root, index)) continue;
        const candidate = ir.getNode(candidate_id) orelse continue;
        if (!groups.isGroupNode(candidate)) continue;
        const children = ir.childrenOf(candidate_id) orelse continue;
        for (children) |group_child_id| {
            if (group_child_id == child_id) return index;
        }
    }
    return null;
}
