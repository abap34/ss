const std = @import("std");
const model = @import("model");
const graph = @import("graph.zig");
const groups = @import("groups.zig");
const solver = @import("solver.zig");
const style_defaults = @import("style.zig");

const NodeId = model.NodeId;
const Axis = model.Axis;
const AxisState = model.AxisState;
const Constraint = model.Constraint;
const ConstraintSource = model.ConstraintSource;
const PageLayout = model.PageLayout;

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
        const placement_index = if (try computeHorizontalComponentUnit(ir, workspace, &components, root)) |unit|
            unit.placement_index
        else
            components.axisFallbackRootIndex(ir, root) orelse continue;
        const placement_id = workspace.nodeAt(placement_index);
        if (!hardFallbackSeedAllowed(workspace, &components, root, placement_id, .horizontal)) continue;
        const placement_node = ir.getNode(placement_id) orelse return error.UnknownNode;
        try constraints.append(ir.allocator, .{
            .target_node = placement_id,
            .target_anchor = .left,
            .source = .{ .page = .left },
            .offset = style_defaults.styleForNode(ir, placement_node).default_x,
        });
    }
    try appendAbsoluteFallbackConstraints(ir, workspace, &constraints);
    return constraints;
}

const HorizontalComponentUnit = struct {
    placement_index: usize,
};

fn computeHorizontalComponentUnit(
    ir: anytype,
    workspace: *const graph.AxisWorkspace,
    components: *const graph.ComponentSet,
    component_root: usize,
) !?HorizontalComponentUnit {
    const seed_index = components.axisFallbackRootIndex(ir, component_root) orelse return null;

    const temp = try ir.allocator.alloc(AxisState, workspace.states.len);
    defer ir.allocator.free(temp);
    @memcpy(temp, workspace.states);
    _ = graph.setAxisAnchor(&temp[seed_index], .left, 0, null) catch return null;

    var temp_workspace = graph.AxisWorkspace.borrow(workspace, temp, &.{});
    _ = try solver.runPageAxisPass(ir, &temp_workspace, .{ .record_diagnostics = false });

    var leftmost_index: ?usize = null;
    var leftmost_start: f32 = 0;
    for (workspace.graph.child_ids, 0..) |child_id, index| {
        if (!components.contains(component_root, index)) continue;
        const node = ir.getNode(child_id) orelse return error.UnknownNode;
        if (groups.isGroupNode(node)) continue;
        const start = temp[index].start orelse continue;
        if (leftmost_index == null or start < leftmost_start) {
            leftmost_index = index;
            leftmost_start = start;
        }
    }

    const placement_index = leftPredecessorGroupIndex(ir, workspace, components, component_root, leftmost_index orelse return null);
    return .{ .placement_index = placement_index };
}

fn leftPredecessorGroupIndex(
    ir: anytype,
    workspace: *const graph.AxisWorkspace,
    components: *const graph.ComponentSet,
    component_root: usize,
    initial_index: usize,
) usize {
    var current = initial_index;
    var pass: usize = 0;
    while (pass < 8) : (pass += 1) {
        var changed = false;
        for (workspace.hard_constraints) |constraint| {
            if (graph.anchorAxis(constraint.target_anchor) != .horizontal) continue;
            if (constraint.target_anchor != .left) continue;
            const target_index = workspace.indexOf(constraint.target_node) orelse continue;
            if (target_index != current) continue;
            if (!components.contains(component_root, target_index)) continue;

            const source = switch (constraint.source) {
                .page => continue,
                .node => |node_source| node_source,
            };
            if (source.anchor != .right) continue;
            if (constraint.offset < -graph.ConstraintTolerance) continue;
            const source_index = workspace.indexOf(source.node_id) orelse continue;
            if (!components.contains(component_root, source_index)) continue;

            const source_node = ir.getNode(source.node_id) orelse continue;
            if (!groups.isGroupNode(source_node)) continue;
            current = source_index;
            changed = true;
            break;
        }
        if (!changed) break;
    }
    return current;
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
    var initial_components = try workspace.dependencyComponents(allocator, ir, verticalComponentPolicy());
    defer initial_components.deinit();

    try appendPageDependentLocalVerticalFallbackConstraints(ir, workspace, &initial_components, &constraints);
    var seeded = try seededWorkspaceWithSoftConstraints(ir, workspace, constraints.items);
    defer seeded.deinit();

    var components = try seeded.workspace.dependencyComponents(allocator, ir, verticalComponentPolicy());
    defer components.deinit();

    const local_tops = try allocator.alloc(?f32, seeded.workspace.graph.len());
    defer allocator.free(local_tops);
    @memset(local_tops, null);

    var units = std.ArrayList(VerticalComponentUnit).empty;
    defer units.deinit(allocator);
    try collectVerticalComponentUnits(ir, &seeded.workspace, &components, local_tops, .top_flow, &units);

    const seen = try allocator.alloc(bool, seeded.workspace.graph.len());
    defer allocator.free(seen);
    @memset(seen, false);

    var current_source: ConstraintSource = .{ .page = .top };
    var current_offset: f32 = PageLayout.flow_top - PageLayout.height;
    var current_top_value: f32 = PageLayout.flow_top;

    for (seeded.workspace.graph.child_ids, seeded.workspace.states, 0..) |child_id, state, index| {
        const node = ir.getNode(child_id) orelse return error.UnknownNode;
        if (groups.isGroupNode(node)) continue;

        const root = components.findConst(index);
        if (components.isPageDependent(root)) {
            const spacing = style_defaults.styleForNode(ir, node).spacing_after;
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
        try appendVerticalComponentPlacementConstraints(allocator, &constraints, &seeded.workspace, &components, local_tops, root, current_source, current_offset, unit.local_top);

        current_source = .{ .node = .{ .node_id = seeded.workspace.nodeAt(unit.bottom_index), .anchor = .bottom } };
        current_offset = -unit.spacing_after;
        current_top_value = current_top_value - unit.height - unit.spacing_after;
    }

    try appendAbsoluteFallbackConstraints(ir, &seeded.workspace, &constraints);
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
    var initial_components = try workspace.dependencyComponents(allocator, ir, verticalComponentPolicy());
    defer initial_components.deinit();

    try appendPageDependentLocalVerticalFallbackConstraints(ir, workspace, &initial_components, &constraints);
    var seeded = try seededWorkspaceWithSoftConstraints(ir, workspace, constraints.items);
    defer seeded.deinit();

    var components = try seeded.workspace.dependencyComponents(allocator, ir, verticalComponentPolicy());
    defer components.deinit();

    const local_tops = try allocator.alloc(?f32, seeded.workspace.graph.len());
    defer allocator.free(local_tops);
    @memset(local_tops, null);

    var units = std.ArrayList(VerticalComponentUnit).empty;
    defer units.deinit(allocator);
    try collectVerticalComponentUnits(ir, &seeded.workspace, &components, local_tops, .center_stack, &units);

    var total_height: f32 = 0;
    for (units.items, 0..) |unit, index| {
        total_height += unit.height;
        if (index != units.items.len - 1) total_height += unit.spacing_after;
    }

    const band = try centerStackAvailableBand(ir, &seeded.workspace, &components);
    var current_top = centerStackTopWithinBand(band, total_height, verticalCenterOffset(ir, workspace.graph.page_id));
    for (units.items) |unit| {
        try appendVerticalComponentPlacementConstraints(
            allocator,
            &constraints,
            &seeded.workspace,
            &components,
            local_tops,
            unit.component_root,
            .{ .page = .bottom },
            current_top - unit.local_top,
            0,
        );
        current_top -= unit.height + unit.spacing_after;
    }
    try appendAbsoluteFallbackConstraints(ir, &seeded.workspace, &constraints);

    return constraints;
}

const VerticalBand = struct {
    bottom: f32,
    top: f32,
};

const SeededAxisWorkspace = struct {
    allocator: std.mem.Allocator,
    states: []AxisState,
    workspace: graph.AxisWorkspace,

    fn deinit(self: *SeededAxisWorkspace) void {
        self.allocator.free(self.states);
    }
};

fn seededWorkspaceWithSoftConstraints(
    ir: anytype,
    workspace: *const graph.AxisWorkspace,
    constraints: []const Constraint,
) !SeededAxisWorkspace {
    const states = try ir.allocator.alloc(AxisState, workspace.states.len);
    errdefer ir.allocator.free(states);
    @memcpy(states, workspace.states);

    var seeded = graph.AxisWorkspace.borrow(workspace, states, constraints);
    _ = try solver.runPageAxisPass(ir, &seeded, .{ .record_diagnostics = false });
    return .{
        .allocator = ir.allocator,
        .states = states,
        .workspace = seeded,
    };
}

fn centerStackTopWithinBand(band: VerticalBand, total_height: f32, center_offset: f32) f32 {
    var top = PageLayout.height / 2 - center_offset + total_height / 2;
    if (band.top <= band.bottom) return top;

    const band_height = band.top - band.bottom;
    if (band_height < total_height) return band.top;

    if (top > band.top) top = band.top;
    if (top - total_height < band.bottom) top = band.bottom + total_height;
    return top;
}

fn centerStackAvailableBand(
    ir: anytype,
    workspace: *const graph.AxisWorkspace,
    components: *const graph.ComponentSet,
) !VerticalBand {
    var band = VerticalBand{ .bottom = 0, .top = PageLayout.height };
    var seen = try ir.allocator.alloc(bool, workspace.graph.len());
    defer ir.allocator.free(seen);
    @memset(seen, false);

    for (workspace.graph.child_ids, 0..) |_, index| {
        const root = components.findConst(index);
        if (seen[root]) continue;
        seen[root] = true;
        if (!components.isPageDependent(root)) continue;

        const bounds = try componentVerticalBounds(ir, workspace, components, root) orelse continue;
        const center = (bounds.bottom + bounds.top) / 2;
        if (center >= PageLayout.height / 2) {
            band.top = @min(band.top, bounds.bottom - bounds.spacing_after);
        } else {
            band.bottom = @max(band.bottom, bounds.top + bounds.spacing_after);
        }
    }

    if (band.top <= band.bottom) return .{ .bottom = 0, .top = PageLayout.height };
    return band;
}

const ComponentVerticalBounds = struct {
    bottom: f32,
    top: f32,
    spacing_after: f32,
};

fn componentVerticalBounds(
    ir: anytype,
    workspace: *const graph.AxisWorkspace,
    components: *const graph.ComponentSet,
    component_root: usize,
) !?ComponentVerticalBounds {
    var bottom: ?f32 = null;
    var top: ?f32 = null;
    var bottom_index: ?usize = null;

    for (workspace.graph.child_ids, workspace.states, 0..) |child_id, state, index| {
        if (!components.contains(component_root, index)) continue;
        const node = ir.getNode(child_id) orelse return error.UnknownNode;
        if (groups.isGroupNode(node)) continue;
        const node_bottom = state.start orelse continue;
        const node_top = state.end orelse continue;
        if (bottom == null or node_bottom < bottom.?) {
            bottom = node_bottom;
            bottom_index = index;
        }
        if (top == null or node_top > top.?) top = node_top;
    }

    const spacing_node = ir.getNode(workspace.nodeAt(bottom_index orelse return null)) orelse return error.UnknownNode;
    return .{
        .bottom = bottom orelse return null,
        .top = top orelse return null,
        .spacing_after = style_defaults.styleForNode(ir, spacing_node).spacing_after,
    };
}

fn verticalComponentPolicy() graph.ComponentPolicy {
    return .{
        .include_containment = true,
        .group_targets = .group_dependencies,
    };
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

fn appendPageDependentLocalVerticalFallbackConstraints(
    ir: anytype,
    workspace: *const graph.AxisWorkspace,
    components: *const graph.ComponentSet,
    constraints: *std.ArrayList(Constraint),
) !void {
    var seen = try ir.allocator.alloc(bool, workspace.graph.len());
    defer ir.allocator.free(seen);
    @memset(seen, false);

    for (workspace.graph.child_ids, 0..) |_, index| {
        const root = components.findConst(index);
        if (seen[root]) continue;
        seen[root] = true;
        if (!components.isPageDependent(root)) continue;

        try appendAnchoredLocalTopFlowForPageChildren(ir, workspace, components, root, constraints);
        for (workspace.graph.child_ids, 0..) |group_id, group_index| {
            if (!components.contains(root, group_index)) continue;
            const group_node = ir.getNode(group_id) orelse return error.UnknownNode;
            if (!groups.isGroupNode(group_node)) continue;
            try appendAnchoredLocalTopFlowForGroupChildren(ir, workspace, components, root, group_id, constraints);
        }
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

fn verticalCenterOffset(ir: anytype, page_id: NodeId) f32 {
    const page = ir.getNode(page_id) orelse return 0;
    if (style_defaults.parseNodeFloatProperty(ir, page, "layout_v_center_offset")) |value| return value;
    const document = ir.getNode(ir.document_id) orelse return 0;
    return style_defaults.parseNodeFloatProperty(ir, document, "layout_v_center_offset") orelse 0;
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

    if (try computeVerticalComponentUnitFromRoot(ir, workspace, components, component_root, local_tops, policy, root_index)) |unit| {
        return unit;
    }

    for (workspace.graph.child_ids, 0..) |child_id, candidate_index| {
        if (candidate_index == root_index) continue;
        if (!components.contains(component_root, candidate_index)) continue;
        const node = ir.getNode(child_id) orelse return error.UnknownNode;
        if (groups.isGroupNode(node)) continue;

        if (try computeVerticalComponentUnitFromRoot(ir, workspace, components, component_root, local_tops, policy, candidate_index)) |unit| {
            return unit;
        }
    }

    return null;
}

fn computeVerticalComponentUnitFromRoot(
    ir: anytype,
    workspace: *const graph.AxisWorkspace,
    components: *const graph.ComponentSet,
    component_root: usize,
    local_tops: []?f32,
    policy: VerticalFallbackPolicy,
    root_index: usize,
) !?VerticalComponentUnit {
    clearComponentLocalTops(components, component_root, local_tops);

    const temp = try ir.allocator.alloc(AxisState, workspace.states.len);
    defer ir.allocator.free(temp);
    @memcpy(temp, workspace.states);
    _ = graph.setAxisAnchor(&temp[root_index], .top, 0, null) catch return null;

    var local_fallback = try buildComponentLocalTopFlowConstraints(ir, workspace, components, component_root, root_index);
    defer local_fallback.deinit(ir.allocator);
    var temp_workspace = graph.AxisWorkspace.borrow(workspace, temp, local_fallback.items);
    _ = try solver.runPageAxisPass(ir, &temp_workspace, .{ .record_diagnostics = false });
    if (policy == .center_stack) {
        try centerDirectChildGroupsInComponent(ir, &temp_workspace, components, component_root);
    }

    var local_bottom: ?f32 = null;
    var local_top: ?f32 = null;
    var bottom_index: ?usize = null;
    for (workspace.graph.child_ids, 0..) |child_id, index| {
        if (!components.contains(component_root, index)) continue;
        const node = ir.getNode(child_id) orelse return error.UnknownNode;
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
        .spacing_after = style_defaults.styleForNode(ir, spacing_source).spacing_after,
    };
}

fn clearComponentLocalTops(components: *const graph.ComponentSet, component_root: usize, local_tops: []?f32) void {
    for (local_tops, 0..) |*local_top, index| {
        if (components.contains(component_root, index)) local_top.* = null;
    }
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

fn appendAnchoredLocalTopFlowForPageChildren(
    ir: anytype,
    workspace: *const graph.AxisWorkspace,
    components: *const graph.ComponentSet,
    component_root: usize,
    constraints: *std.ArrayList(Constraint),
) !void {
    try appendAnchoredLocalTopFlowForChildren(ir, workspace, components, component_root, workspace.graph.child_ids, .page, constraints);
}

fn appendAnchoredLocalTopFlowForGroupChildren(
    ir: anytype,
    workspace: *const graph.AxisWorkspace,
    components: *const graph.ComponentSet,
    component_root: usize,
    group_id: NodeId,
    constraints: *std.ArrayList(Constraint),
) !void {
    const children = ir.childrenOf(group_id) orelse return;
    try appendAnchoredLocalTopFlowForChildren(ir, workspace, components, component_root, children, .group, constraints);
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
    var current_source: ?ConstraintSource = null;
    var current_offset: f32 = 0;
    var started = false;

    for (children) |child_id| {
        const index = flowChildIndex(ir, workspace, components, component_root, child_id, scope) orelse continue;
        const contains_root = index == root_index;

        if (contains_root) {
            started = true;
        } else if (!started and scope == .page) {
            continue;
        }

        if (!contains_root) {
            try constraints.append(ir.allocator, .{
                .target_node = workspace.nodeAt(index),
                .target_anchor = .top,
                .source = current_source orelse .{ .node = .{ .node_id = workspace.nodeAt(root_index), .anchor = .top } },
                .offset = current_offset,
            });
        }

        const spacing_node = ir.getNode(workspace.nodeAt(index)) orelse return error.UnknownNode;
        current_source = .{ .node = .{ .node_id = workspace.nodeAt(index), .anchor = .bottom } };
        current_offset = -style_defaults.styleForNode(ir, spacing_node).spacing_after;
    }
}

fn appendAnchoredLocalTopFlowForChildren(
    ir: anytype,
    workspace: *const graph.AxisWorkspace,
    components: *const graph.ComponentSet,
    component_root: usize,
    children: []const NodeId,
    scope: FlowScope,
    constraints: *std.ArrayList(Constraint),
) !void {
    var pending_before_anchor = std.ArrayList(usize).empty;
    defer pending_before_anchor.deinit(ir.allocator);

    var current_source: ?ConstraintSource = null;
    var current_offset: f32 = 0;

    for (children) |child_id| {
        const index = localFlowChildIndex(ir, workspace, components, component_root, child_id, scope) orelse continue;
        const state = workspace.states[index];
        if (axisPositionKnown(state)) {
            try appendPendingBeforeKnownVerticalConstraints(ir, workspace, components, component_root, pending_before_anchor.items, index, constraints);
            pending_before_anchor.clearRetainingCapacity();
            if (state.start != null) {
                const spacing_node = ir.getNode(workspace.nodeAt(index)) orelse return error.UnknownNode;
                current_source = .{ .node = .{ .node_id = workspace.nodeAt(index), .anchor = .bottom } };
                current_offset = -style_defaults.styleForNode(ir, spacing_node).spacing_after;
            }
            continue;
        }

        if (current_source) |source| {
            const node_id = workspace.nodeAt(index);
            const has_fallback = hasFallbackTargetConstraint(constraints.items, node_id, .vertical);
            const can_seed = hardFallbackSeedAllowed(workspace, components, component_root, node_id, .vertical);
            if (!has_fallback and can_seed) {
                try constraints.append(ir.allocator, .{
                    .target_node = node_id,
                    .target_anchor = .top,
                    .source = source,
                    .offset = current_offset,
                });
            }
            if (!has_fallback and !can_seed) continue;
            const spacing_node = ir.getNode(node_id) orelse return error.UnknownNode;
            current_source = .{ .node = .{ .node_id = node_id, .anchor = .bottom } };
            current_offset = -style_defaults.styleForNode(ir, spacing_node).spacing_after;
        } else {
            try pending_before_anchor.append(ir.allocator, index);
        }
    }
}

fn appendPendingBeforeKnownVerticalConstraints(
    ir: anytype,
    workspace: *const graph.AxisWorkspace,
    components: *const graph.ComponentSet,
    component_root: usize,
    pending_indexes: []const usize,
    known_index: usize,
    constraints: *std.ArrayList(Constraint),
) !void {
    var source: ConstraintSource = .{ .node = .{ .node_id = workspace.nodeAt(known_index), .anchor = .top } };
    var cursor = pending_indexes.len;
    while (cursor > 0) {
        cursor -= 1;
        const index = pending_indexes[cursor];
        const node_id = workspace.nodeAt(index);
        const spacing_node = ir.getNode(node_id) orelse return error.UnknownNode;
        const has_fallback = hasFallbackTargetConstraint(constraints.items, node_id, .vertical);
        const can_seed = hardFallbackSeedAllowed(workspace, components, component_root, node_id, .vertical);
        if (!has_fallback and can_seed) {
            try constraints.append(ir.allocator, .{
                .target_node = node_id,
                .target_anchor = .bottom,
                .source = source,
                .offset = style_defaults.styleForNode(ir, spacing_node).spacing_after,
            });
        }
        if (!has_fallback and !can_seed) continue;
        source = .{ .node = .{ .node_id = node_id, .anchor = .top } };
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

fn localFlowChildIndex(
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
    return index;
}

fn appendAbsoluteFallbackConstraints(
    ir: anytype,
    workspace: *const graph.AxisWorkspace,
    constraints: *std.ArrayList(Constraint),
) !void {
    var seeded_workspace = graph.AxisWorkspace.borrow(workspace, workspace.states, constraints.items);
    var components = try seeded_workspace.dependencyComponents(ir.allocator, ir, .{});
    defer components.deinit();

    var seeded_hard_components = try ir.allocator.alloc(bool, workspace.graph.len());
    defer ir.allocator.free(seeded_hard_components);
    @memset(seeded_hard_components, false);

    for (workspace.graph.child_ids, workspace.states, 0..) |child_id, state, index| {
        if (axisPositionKnown(state)) continue;
        if (hasFallbackTargetConstraint(constraints.items, child_id, workspace.axis)) continue;
        const node = ir.getNode(child_id) orelse return error.UnknownNode;
        if (groups.isGroupNode(node)) continue;

        if (hasHardPositionTargetConstraint(workspace, child_id, workspace.axis)) {
            const root = components.findConst(index);
            if (!hardFallbackSeedAllowed(workspace, &components, root, child_id, workspace.axis)) continue;
            if (components.isPageDependent(root)) continue;
            if (componentHasAxisPositionSeed(workspace, &components, root, constraints.items)) continue;
            if (seeded_hard_components[root]) continue;
            seeded_hard_components[root] = true;
        }

        try constraints.append(ir.allocator, .{
            .target_node = child_id,
            .target_anchor = absoluteFallbackTargetAnchor(workspace.axis),
            .source = .{ .page = absoluteFallbackTargetAnchor(workspace.axis) },
            .offset = absoluteFallbackOffset(ir, node, workspace.axis),
        });
    }
}

fn componentHasAxisPositionSeed(
    workspace: *const graph.AxisWorkspace,
    components: *const graph.ComponentSet,
    component_root: usize,
    constraints: []const Constraint,
) bool {
    for (workspace.graph.child_ids, workspace.states, 0..) |child_id, state, index| {
        if (!components.contains(component_root, index)) continue;
        if (axisPositionKnown(state)) return true;
        if (hasFallbackTargetConstraint(constraints, child_id, workspace.axis)) return true;
    }
    return false;
}

fn absoluteFallbackTargetAnchor(axis: Axis) model.Anchor {
    return switch (axis) {
        .horizontal => .left,
        .vertical => .top,
    };
}

fn absoluteFallbackOffset(ir: anytype, node: *const model.Node, axis: Axis) f32 {
    return switch (axis) {
        .horizontal => style_defaults.styleForNode(ir, node).default_x,
        .vertical => PageLayout.flow_top - PageLayout.height,
    };
}

fn axisPositionKnown(state: AxisState) bool {
    return state.start != null or state.end != null or state.center != null;
}

fn hasFallbackTargetConstraint(constraints: []const Constraint, node_id: NodeId, axis: Axis) bool {
    for (constraints) |constraint| {
        if (constraint.target_node != node_id) continue;
        if (graph.anchorAxis(constraint.target_anchor) != axis) continue;
        return true;
    }
    return false;
}

fn hasHardPositionTargetConstraint(workspace: *const graph.AxisWorkspace, node_id: NodeId, axis: Axis) bool {
    for (workspace.hard_constraints) |constraint| {
        if (constraint.target_node != node_id) continue;
        if (graph.anchorAxis(constraint.target_anchor) != axis) continue;
        switch (graph.classifySelfConstraint(constraint, axis)) {
            .size, .tautology, .conflict => continue,
            .none => return true,
        }
    }
    return false;
}

fn hardFallbackSeedAllowed(
    workspace: *const graph.AxisWorkspace,
    components: *const graph.ComponentSet,
    component_root: usize,
    node_id: NodeId,
    axis: Axis,
) bool {
    if (!hasHardPositionTargetConstraint(workspace, node_id, axis)) return true;
    return !componentHasInconsistentHardPositionCycle(workspace, components, component_root, axis);
}

const ConstraintEndpoint = struct {
    node_id: NodeId,
    anchor: model.Anchor,
};

fn componentHasInconsistentHardPositionCycle(
    workspace: *const graph.AxisWorkspace,
    components: *const graph.ComponentSet,
    component_root: usize,
    axis: Axis,
) bool {
    for (workspace.hard_constraints) |constraint| {
        if (graph.anchorAxis(constraint.target_anchor) != axis) continue;
        const target_index = workspace.indexOf(constraint.target_node) orelse continue;
        if (!components.contains(component_root, target_index)) continue;
        const offset = hardConstraintCycleOffset(workspace, constraint, axis) orelse continue;
        if (@abs(offset) > graph.ConstraintTolerance) return true;
    }
    return false;
}

fn hardConstraintCycleOffset(workspace: *const graph.AxisWorkspace, start_constraint: Constraint, axis: Axis) ?f32 {
    const start_endpoint = ConstraintEndpoint{ .node_id = start_constraint.target_node, .anchor = start_constraint.target_anchor };
    var current = start_constraint;
    var accumulated_offset: f32 = 0;

    var steps: usize = 0;
    while (steps <= workspace.hard_constraints.len) : (steps += 1) {
        if (graph.anchorAxis(current.target_anchor) != axis) return null;
        accumulated_offset += current.offset;

        const source_endpoint = constraintSourceEndpoint(current.source) orelse return null;
        if (graph.anchorAxis(source_endpoint.anchor) != axis) return null;
        if (constraintEndpointSame(source_endpoint, start_endpoint)) return accumulated_offset;

        current = findHardConstraintTargetingEndpoint(workspace, source_endpoint, axis) orelse return null;
    }
    return null;
}

fn constraintSourceEndpoint(source: ConstraintSource) ?ConstraintEndpoint {
    return switch (source) {
        .page => null,
        .node => |node_source| .{ .node_id = node_source.node_id, .anchor = node_source.anchor },
    };
}

fn findHardConstraintTargetingEndpoint(workspace: *const graph.AxisWorkspace, endpoint: ConstraintEndpoint, axis: Axis) ?Constraint {
    for (workspace.hard_constraints) |constraint| {
        if (graph.anchorAxis(constraint.target_anchor) != axis) continue;
        if (constraint.target_node == endpoint.node_id and constraint.target_anchor == endpoint.anchor) return constraint;
    }
    return null;
}

fn constraintEndpointSame(a: ConstraintEndpoint, b: ConstraintEndpoint) bool {
    return a.node_id == b.node_id and a.anchor == b.anchor;
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
