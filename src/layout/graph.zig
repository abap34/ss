const std = @import("std");
const model = @import("model");

const NodeId = model.NodeId;
const Node = model.Node;
const Axis = model.Axis;
const AxisState = model.AxisState;
const Anchor = model.Anchor;
const Constraint = model.Constraint;
const ConstraintSource = model.ConstraintSource;
const Frame = model.Frame;
const GroupRole = model.GroupRole;
const roleEq = model.roleEq;

pub const ConstraintTolerance: f32 = 0.01;

pub const ConstraintClass = enum {
    self_size,
    self_anchor,
    normal,
    page_source,
    external_source,
    group_target,
    group_source,
    wrong_axis,
};

pub const ComponentPolicy = struct {
    include_containment: bool = false,
    group_targets: GroupTargetPolicy = .include,
};

pub const GroupTargetPolicy = enum {
    include,
    ignore,
    group_dependencies,
};

pub const SolveOptions = struct {
    record_diagnostics: bool = true,
};

pub const PageLayoutGraph = struct {
    allocator: std.mem.Allocator,
    page_id: NodeId,
    child_ids: []NodeId,
    index_by_node: std.AutoHashMap(NodeId, usize),
    has_horizontal_target_constraint: []bool,
    has_vertical_target_constraint: []bool,

    pub fn init(allocator: std.mem.Allocator, ir: anytype, page_id: NodeId) !PageLayoutGraph {
        var child_ids_list = std.ArrayList(NodeId).empty;
        errdefer child_ids_list.deinit(allocator);
        if (ir.contains.get(page_id)) |children| {
            try child_ids_list.appendSlice(allocator, children.items);
        }
        try appendImplicitConstraintGroups(allocator, ir, page_id, &child_ids_list);
        const child_ids = try child_ids_list.toOwnedSlice(allocator);
        errdefer allocator.free(child_ids);

        var index_by_node = std.AutoHashMap(NodeId, usize).init(allocator);
        errdefer index_by_node.deinit();
        try index_by_node.ensureTotalCapacity(@intCast(child_ids.len));
        for (child_ids, 0..) |node_id, index| {
            index_by_node.putAssumeCapacity(node_id, index);
        }
        const has_horizontal_target_constraint = try allocator.alloc(bool, child_ids.len);
        errdefer allocator.free(has_horizontal_target_constraint);
        const has_vertical_target_constraint = try allocator.alloc(bool, child_ids.len);
        errdefer allocator.free(has_vertical_target_constraint);
        @memset(has_horizontal_target_constraint, false);
        @memset(has_vertical_target_constraint, false);
        for (ir.constraints.items) |constraint| {
            const target_index = index_by_node.get(constraint.target_node) orelse continue;
            const axis = anchorAxis(constraint.target_anchor);
            switch (classifySelfConstraint(constraint, axis)) {
                .none, .size => {},
                .tautology, .conflict => continue,
            }
            switch (axis) {
                .horizontal => has_horizontal_target_constraint[target_index] = true,
                .vertical => has_vertical_target_constraint[target_index] = true,
            }
        }

        return .{
            .allocator = allocator,
            .page_id = page_id,
            .child_ids = child_ids,
            .index_by_node = index_by_node,
            .has_horizontal_target_constraint = has_horizontal_target_constraint,
            .has_vertical_target_constraint = has_vertical_target_constraint,
        };
    }

    pub fn deinit(self: *PageLayoutGraph) void {
        self.index_by_node.deinit();
        self.allocator.free(self.child_ids);
        self.allocator.free(self.has_horizontal_target_constraint);
        self.allocator.free(self.has_vertical_target_constraint);
    }

    pub fn len(self: *const PageLayoutGraph) usize {
        return self.child_ids.len;
    }

    pub fn indexOf(self: *const PageLayoutGraph, node_id: NodeId) ?usize {
        return self.index_by_node.get(node_id);
    }

    pub fn nodeAt(self: *const PageLayoutGraph, index: usize) NodeId {
        return self.child_ids[index];
    }

    pub fn childrenOf(self: *const PageLayoutGraph, ir: anytype, node_id: NodeId) []const NodeId {
        _ = self;
        return ir.childrenOf(node_id) orelse &.{};
    }

    pub fn parentGroupOf(self: *const PageLayoutGraph, ir: anytype, child_id: NodeId) ?NodeId {
        for (self.child_ids) |candidate_id| {
            const candidate = ir.getNode(candidate_id) orelse continue;
            if (!isGroupNode(candidate)) continue;
            const children = ir.childrenOf(candidate_id) orelse continue;
            for (children) |group_child_id| {
                if (group_child_id == child_id) return candidate_id;
            }
        }
        return null;
    }

    pub fn hasTargetConstraint(self: *const PageLayoutGraph, ir: anytype, node_id: NodeId, axis: Axis, extra_constraints: []const Constraint) bool {
        _ = ir;
        if (self.indexOf(node_id)) |index| {
            switch (axis) {
                .horizontal => if (self.has_horizontal_target_constraint[index]) return true,
                .vertical => if (self.has_vertical_target_constraint[index]) return true,
            }
        }
        for (extra_constraints) |constraint| {
            if (constraint.target_node != node_id) continue;
            if (anchorAxis(constraint.target_anchor) == axis) return true;
        }
        return false;
    }

    pub fn constraintsForAxis(self: *const PageLayoutGraph, allocator: std.mem.Allocator, ir: anytype, axis: Axis, extra_constraints: []const Constraint) !std.ArrayList(Constraint) {
        var result = std.ArrayList(Constraint).empty;
        try self.appendConstraintsForAxis(allocator, ir.constraints.items, axis, &result);
        try self.appendConstraintsForAxis(allocator, extra_constraints, axis, &result);
        return result;
    }

    pub fn targetConstraints(self: *const PageLayoutGraph, allocator: std.mem.Allocator, ir: anytype, node_id: NodeId, axis: Axis, extra_constraints: []const Constraint) !std.ArrayList(Constraint) {
        var result = std.ArrayList(Constraint).empty;
        try self.appendTargetConstraints(allocator, ir.constraints.items, node_id, axis, &result);
        try self.appendTargetConstraints(allocator, extra_constraints, node_id, axis, &result);
        return result;
    }

    pub fn sourceConstraints(self: *const PageLayoutGraph, allocator: std.mem.Allocator, ir: anytype, node_id: NodeId, axis: Axis, extra_constraints: []const Constraint) !std.ArrayList(Constraint) {
        var result = std.ArrayList(Constraint).empty;
        try self.appendSourceConstraints(allocator, ir.constraints.items, node_id, axis, &result);
        try self.appendSourceConstraints(allocator, extra_constraints, node_id, axis, &result);
        return result;
    }

    fn appendConstraintsForAxis(self: *const PageLayoutGraph, allocator: std.mem.Allocator, constraints: []const Constraint, axis: Axis, result: *std.ArrayList(Constraint)) !void {
        for (constraints) |constraint| {
            if (anchorAxis(constraint.target_anchor) != axis) continue;
            if (self.indexOf(constraint.target_node) == null) continue;
            try result.append(allocator, constraint);
        }
    }

    fn appendTargetConstraints(self: *const PageLayoutGraph, allocator: std.mem.Allocator, constraints: []const Constraint, node_id: NodeId, axis: Axis, result: *std.ArrayList(Constraint)) !void {
        _ = self;
        for (constraints) |constraint| {
            if (constraint.target_node != node_id) continue;
            if (anchorAxis(constraint.target_anchor) != axis) continue;
            try result.append(allocator, constraint);
        }
    }

    fn appendSourceConstraints(self: *const PageLayoutGraph, allocator: std.mem.Allocator, constraints: []const Constraint, node_id: NodeId, axis: Axis, result: *std.ArrayList(Constraint)) !void {
        _ = self;
        for (constraints) |constraint| {
            const source = switch (constraint.source) {
                .page => continue,
                .node => |source| source,
            };
            if (source.node_id != node_id) continue;
            if (anchorAxis(source.anchor) != axis) continue;
            try result.append(allocator, constraint);
        }
    }

    pub fn groupChildren(self: *const PageLayoutGraph, ir: anytype, group_id: NodeId) []const NodeId {
        return self.childrenOf(ir, group_id);
    }

    pub fn groupSubgraph(self: *const PageLayoutGraph, allocator: std.mem.Allocator, ir: anytype, group_id: NodeId) !NodeSubgraph {
        var subgraph = NodeSubgraph.init(allocator);
        errdefer subgraph.deinit();
        try self.collectGroupSubgraph(ir, group_id, &subgraph);
        return subgraph;
    }

    fn collectGroupSubgraph(self: *const PageLayoutGraph, ir: anytype, group_id: NodeId, subgraph: *NodeSubgraph) !void {
        const children = ir.childrenOf(group_id) orelse return;
        for (children) |child_id| {
            if (self.indexOf(child_id)) |index| try subgraph.add(index);
            const child = ir.getNode(child_id) orelse return error.UnknownNode;
            if (isGroupNode(child)) try self.collectGroupSubgraph(ir, child_id, subgraph);
        }
    }

    pub fn translateSubgraph(self: *const PageLayoutGraph, workspace: *AxisWorkspace, ir: anytype, group_id: NodeId, delta: f32) !bool {
        if (approxEq(delta, 0)) return false;
        var subgraph = try self.groupSubgraph(self.allocator, ir, group_id);
        defer subgraph.deinit();
        var changed = false;
        for (subgraph.indexes.items) |index| {
            changed = shiftAxisState(&workspace.states[index], delta) or changed;
        }
        return changed;
    }

    pub fn constraintClass(self: *const PageLayoutGraph, ir: anytype, constraint: Constraint, axis: Axis) ConstraintClass {
        if (anchorAxis(constraint.target_anchor) != axis) return .wrong_axis;
        const target_index = self.indexOf(constraint.target_node) orelse return .external_source;
        _ = target_index;
        const target_node = ir.getNode(constraint.target_node) orelse return .external_source;
        switch (classifySelfConstraint(constraint, axis)) {
            .none => {},
            .size => return .self_size,
            .tautology, .conflict => return .self_anchor,
        }
        if (isGroupNode(target_node)) return .group_target;
        return switch (constraint.source) {
            .page => .page_source,
            .node => |source| blk: {
                if (anchorAxis(source.anchor) != axis) break :blk .wrong_axis;
                const source_node = ir.getNode(source.node_id) orelse break :blk .external_source;
                if (isGroupNode(source_node)) break :blk .group_source;
                if (self.indexOf(source.node_id) == null) break :blk .external_source;
                break :blk .normal;
            },
        };
    }
};

fn appendImplicitConstraintGroups(allocator: std.mem.Allocator, ir: anytype, page_id: NodeId, child_ids: *std.ArrayList(NodeId)) !void {
    var changed = true;
    while (changed) {
        changed = false;
        for (ir.nodes.items) |node| {
            if (!isGroupNode(&node)) continue;
            if (containsNodeId(child_ids.items, node.id)) continue;
            if (!groupHasPageDescendant(ir, page_id, node.id)) continue;
            if (!groupIsReferencedByConstraint(ir, node.id)) continue;
            try child_ids.append(allocator, node.id);
            changed = true;
        }
    }
}

fn groupIsReferencedByConstraint(ir: anytype, group_id: NodeId) bool {
    for (ir.constraints.items) |constraint| {
        if (constraint.target_node == group_id) return true;
        switch (constraint.source) {
            .page => {},
            .node => |source| if (source.node_id == group_id) return true,
        }
    }
    return false;
}

fn groupHasPageDescendant(ir: anytype, page_id: NodeId, group_id: NodeId) bool {
    const children = ir.childrenOf(group_id) orelse return false;
    for (children) |child_id| {
        if (ir.parentPageOf(child_id) == page_id) return true;
        const child = ir.getNode(child_id) orelse continue;
        if (isGroupNode(child) and groupHasPageDescendant(ir, page_id, child_id)) return true;
    }
    return false;
}

pub const AxisWorkspace = struct {
    allocator: std.mem.Allocator,
    graph: *const PageLayoutGraph,
    axis: Axis,
    states: []AxisState,
    soft_constraints: []const Constraint = &.{},
    owns_states: bool = true,

    pub fn init(allocator: std.mem.Allocator, ir: anytype, page_graph: *const PageLayoutGraph, axis: Axis) !AxisWorkspace {
        const states = try allocator.alloc(AxisState, page_graph.len());
        errdefer allocator.free(states);

        for (page_graph.child_ids, states) |child_id, *state| {
            const node = ir.getNode(child_id) orelse return error.UnknownNode;
            state.* = .{};
            if (isGroupNode(node)) continue;
            if (page_graph.hasTargetConstraint(ir, child_id, axis, &.{})) continue;
            switch (axis) {
                .horizontal => if (node.frame.x_set) {
                    state.size = node.frame.width;
                    state.start = node.frame.x;
                    state.end = node.frame.x + node.frame.width;
                    state.center = node.frame.x + node.frame.width / 2;
                },
                .vertical => if (node.frame.y_set) {
                    state.size = node.frame.height;
                    state.start = node.frame.y;
                    state.end = node.frame.y + node.frame.height;
                    state.center = node.frame.y + node.frame.height / 2;
                },
            }
        }

        return .{
            .allocator = allocator,
            .graph = page_graph,
            .axis = axis,
            .states = states,
        };
    }

    pub fn borrow(parent: *const AxisWorkspace, states: []AxisState, soft_constraints: []const Constraint) AxisWorkspace {
        return .{
            .allocator = parent.allocator,
            .graph = parent.graph,
            .axis = parent.axis,
            .states = states,
            .soft_constraints = soft_constraints,
            .owns_states = false,
        };
    }

    pub fn deinit(self: *AxisWorkspace) void {
        if (self.owns_states) self.allocator.free(self.states);
    }

    pub fn indexOf(self: *const AxisWorkspace, node_id: NodeId) ?usize {
        return self.graph.indexOf(node_id);
    }

    pub fn nodeAt(self: *const AxisWorkspace, index: usize) NodeId {
        return self.graph.nodeAt(index);
    }

    pub fn stateOf(self: *AxisWorkspace, node_id: NodeId) ?*AxisState {
        const index = self.indexOf(node_id) orelse return null;
        return &self.states[index];
    }

    pub fn stateOfConst(self: *const AxisWorkspace, node_id: NodeId) ?*const AxisState {
        const index = self.indexOf(node_id) orelse return null;
        return &self.states[index];
    }

    pub fn dependencyComponents(self: *const AxisWorkspace, allocator: std.mem.Allocator, ir: anytype, policy: ComponentPolicy) !ComponentSet {
        return try ComponentSet.init(allocator, ir, self, policy);
    }
};

pub const ComponentSet = struct {
    allocator: std.mem.Allocator,
    workspace: *const AxisWorkspace,
    parent: []usize,
    page_dependent: []bool,

    pub fn init(allocator: std.mem.Allocator, ir: anytype, workspace: *const AxisWorkspace, policy: ComponentPolicy) !ComponentSet {
        const len = workspace.graph.len();
        const parent = try allocator.alloc(usize, len);
        errdefer allocator.free(parent);
        const page_dependent = try allocator.alloc(bool, len);
        errdefer allocator.free(page_dependent);

        var set = ComponentSet{
            .allocator = allocator,
            .workspace = workspace,
            .parent = parent,
            .page_dependent = page_dependent,
        };
        for (set.parent, set.page_dependent, 0..) |*p, *dependent, index| {
            p.* = index;
            dependent.* = false;
        }

        if (policy.include_containment) try set.unionContainment(ir);
        try set.markKnownAnchors(ir);
        try set.unionConstraintSlice(ir, ir.constraints.items, policy);
        try set.unionConstraintSlice(ir, workspace.soft_constraints, policy);
        return set;
    }

    pub fn deinit(self: *ComponentSet) void {
        self.allocator.free(self.parent);
        self.allocator.free(self.page_dependent);
    }

    pub fn find(self: *ComponentSet, index: usize) usize {
        var current = index;
        while (self.parent[current] != current) {
            current = self.parent[current];
        }
        return current;
    }

    pub fn findConst(self: *const ComponentSet, index: usize) usize {
        var current = index;
        while (self.parent[current] != current) {
            current = self.parent[current];
        }
        return current;
    }

    pub fn contains(self: *const ComponentSet, component_root: usize, index: usize) bool {
        return self.findConst(index) == component_root;
    }

    pub fn isPageDependent(self: *const ComponentSet, component_root: usize) bool {
        return self.page_dependent[self.findConst(component_root)];
    }

    pub fn markPageDependent(self: *ComponentSet, index: usize) void {
        self.page_dependent[self.find(index)] = true;
    }

    pub fn merge(self: *ComponentSet, a: usize, b: usize) void {
        const a_root = self.find(a);
        const b_root = self.find(b);
        if (a_root == b_root) return;
        self.parent[b_root] = a_root;
        self.page_dependent[a_root] = self.page_dependent[a_root] or self.page_dependent[b_root];
    }

    pub fn rootIndexes(self: *const ComponentSet, allocator: std.mem.Allocator) !std.ArrayList(usize) {
        var result = std.ArrayList(usize).empty;
        for (self.parent, 0..) |_, index| {
            const root = self.findConst(index);
            if (containsIndex(result.items, root)) continue;
            try result.append(allocator, root);
        }
        return result;
    }

    pub fn fallbackRootIndex(self: *const ComponentSet, ir: anytype, component_root: usize) ?usize {
        for (self.workspace.graph.child_ids, 0..) |child_id, index| {
            if (!self.contains(component_root, index)) continue;
            const node = ir.getNode(child_id) orelse continue;
            if (isGroupNode(node)) continue;
            return index;
        }
        return null;
    }

    pub fn axisFallbackRootIndex(self: *const ComponentSet, ir: anytype, component_root: usize) ?usize {
        var fallback: ?usize = null;
        for (self.workspace.graph.child_ids, self.workspace.states, 0..) |child_id, state, index| {
            if (!self.contains(component_root, index)) continue;
            const node = ir.getNode(child_id) orelse continue;
            if (isGroupNode(node)) continue;
            if (fallback == null) fallback = index;
            if (state.start == null and !self.workspace.graph.hasTargetConstraint(ir, child_id, self.workspace.axis, self.workspace.soft_constraints)) return index;
        }
        return fallback;
    }

    fn unionContainment(self: *ComponentSet, ir: anytype) !void {
        for (self.workspace.graph.child_ids, 0..) |node_id, index| {
            const node = ir.getNode(node_id) orelse return error.UnknownNode;
            if (!isGroupNode(node)) continue;
            const children = ir.childrenOf(node_id) orelse continue;
            for (children) |child_id| {
                const child_index = self.workspace.indexOf(child_id) orelse continue;
                self.merge(index, child_index);
            }
        }
    }

    fn markKnownAnchors(self: *ComponentSet, ir: anytype) !void {
        _ = ir;
        for (self.workspace.states, 0..) |state, index| {
            if (state.start != null or state.end != null or state.center != null) {
                self.markPageDependent(index);
            }
        }
    }

    fn unionConstraintSlice(self: *ComponentSet, ir: anytype, constraints: []const Constraint, policy: ComponentPolicy) !void {
        for (constraints) |constraint| {
            const class = self.workspace.graph.constraintClass(ir, constraint, self.workspace.axis);
            switch (class) {
                .wrong_axis, .self_size, .self_anchor => continue,
                .external_source => {
                    if (self.workspace.indexOf(constraint.target_node)) |target_index| {
                        self.markPageDependent(target_index);
                    }
                    continue;
                },
                .group_target => switch (policy.group_targets) {
                    .include => {},
                    .ignore => continue,
                    .group_dependencies => {
                        try self.mergeGroupTargetDependency(ir, constraint);
                        continue;
                    },
                },
                .normal, .page_source, .group_source => {},
            }
            if (self.workspace.indexOf(constraint.target_node)) |target_index| {
                switch (constraint.source) {
                    .page => self.markPageDependent(target_index),
                    .node => |source| {
                        const source_index = self.workspace.indexOf(source.node_id) orelse {
                            self.markPageDependent(target_index);
                            continue;
                        };
                        self.merge(target_index, source_index);
                    },
                }
            }
        }
    }

    fn mergeGroupTargetDependency(self: *ComponentSet, ir: anytype, constraint: Constraint) !void {
        const target_index = self.workspace.indexOf(constraint.target_node) orelse return;
        const target_node = ir.getNode(constraint.target_node) orelse return error.UnknownNode;
        if (!isGroupNode(target_node)) return;

        const source = switch (constraint.source) {
            .page => return,
            .node => |node_source| node_source,
        };
        if (anchorAxis(source.anchor) != self.workspace.axis) return;

        const source_index = self.workspace.indexOf(source.node_id) orelse return;
        const source_node = ir.getNode(source.node_id) orelse return error.UnknownNode;
        if (!isGroupNode(source_node)) return;

        self.merge(target_index, source_index);
    }
};

pub const NodeSubgraph = struct {
    allocator: std.mem.Allocator,
    indexes: std.ArrayList(usize),

    pub fn init(allocator: std.mem.Allocator) NodeSubgraph {
        return .{ .allocator = allocator, .indexes = .empty };
    }

    pub fn deinit(self: *NodeSubgraph) void {
        self.indexes.deinit(self.allocator);
    }

    pub fn add(self: *NodeSubgraph, index: usize) !void {
        if (containsIndex(self.indexes.items, index)) return;
        try self.indexes.append(self.allocator, index);
    }
};

pub fn isGroupNode(node: *const Node) bool {
    return roleEq(node.role, GroupRole);
}

pub fn anchorAxis(anchor: Anchor) Axis {
    return switch (anchor) {
        .left, .right, .center_x => .horizontal,
        .top, .bottom, .center_y => .vertical,
    };
}

pub const SelfConstraint = union(enum) {
    none: void,
    tautology: void,
    conflict: void,
    size: f32,
};

pub fn classifySelfConstraint(constraint: Constraint, axis: Axis) SelfConstraint {
    const node_source = switch (constraint.source) {
        .node => |ns| ns,
        .page => return .{ .none = {} },
    };
    if (node_source.node_id != constraint.target_node) return .{ .none = {} };
    if (anchorAxis(node_source.anchor) != axis) return .{ .none = {} };
    if (anchorAxis(constraint.target_anchor) != axis) return .{ .none = {} };
    if (node_source.anchor == constraint.target_anchor) {
        return if (approxEq(constraint.offset, 0))
            .{ .tautology = {} }
        else
            .{ .conflict = {} };
    }
    if (sizeFromAnchorPair(constraint.target_anchor, node_source.anchor, constraint.offset)) |size| {
        return .{ .size = size };
    }
    return .{ .none = {} };
}

pub fn constraintSourceValue(ir: anytype, workspace: *const AxisWorkspace, source: ConstraintSource) !?f32 {
    return switch (source) {
        .page => |anchor| blk: {
            if (anchorAxis(anchor) != workspace.axis) return error.ConstraintAxisMismatch;
            const page = ir.getNode(workspace.graph.page_id) orelse return error.UnknownNode;
            break :blk anchorValue(page.frame, anchor);
        },
        .node => |node_source| blk: {
            if (anchorAxis(node_source.anchor) != workspace.axis) return error.ConstraintAxisMismatch;
            if (workspace.indexOf(node_source.node_id)) |index| {
                break :blk axisAnchorValue(workspace.states[index], node_source.anchor);
            }

            const source_node = ir.getNode(node_source.node_id) orelse return error.UnknownNode;
            if (!anchorKnown(source_node.frame, node_source.anchor)) break :blk null;
            break :blk anchorValue(source_node.frame, node_source.anchor);
        },
    };
}

pub fn axisAnchorValue(state: AxisState, anchor: Anchor) ?f32 {
    return switch (anchor) {
        .left, .bottom => state.start,
        .right, .top => state.end,
        .center_x, .center_y => state.center,
    };
}

pub fn axisAnchorSource(state: AxisState, anchor: Anchor) ?Constraint {
    return switch (anchor) {
        .left, .bottom => state.start_source,
        .right, .top => state.end_source,
        .center_x, .center_y => state.center_source,
    };
}

pub fn setAxisAnchor(state: *AxisState, anchor: Anchor, value: f32, source: ?Constraint) !bool {
    if (updateSourcedAxisAnchor(state, anchor, value, source)) |changed| return changed;
    if (try overrideDefaultDerivedAnchor(state, anchor, value, source)) return true;
    return switch (anchor) {
        .left, .bottom => try setOptionalFloat(&state.start, &state.start_source, value, source),
        .right, .top => try setOptionalFloat(&state.end, &state.end_source, value, source),
        .center_x, .center_y => try setOptionalFloat(&state.center, &state.center_source, value, source),
    };
}

fn updateSourcedAxisAnchor(state: *AxisState, anchor: Anchor, value: f32, source: ?Constraint) ?bool {
    if (source == null) return null;
    const source_value = source.?;
    const current = switch (anchor) {
        .left, .bottom => state.start,
        .right, .top => state.end,
        .center_x, .center_y => state.center,
    } orelse return null;
    if (approxEq(current, value)) return false;

    const current_source = switch (anchor) {
        .left, .bottom => state.start_source,
        .right, .top => state.end_source,
        .center_x, .center_y => state.center_source,
    } orelse return null;
    if (!constraintsEquivalent(current_source, source_value)) return null;

    switch (anchor) {
        .left, .bottom => {
            state.start = value;
            state.start_source = source;
        },
        .right, .top => {
            state.end = value;
            state.end_source = source;
        },
        .center_x, .center_y => {
            state.center = value;
            state.center_source = source;
        },
    }
    clearDerivedAnchorsAfterSourcedUpdate(state, anchor);
    return true;
}

fn clearDerivedAnchorsAfterSourcedUpdate(state: *AxisState, changed_anchor: Anchor) void {
    const preserve_size = state.size_is_default or state.size_source != null;
    if (!preserve_size) {
        if (state.size_source == null) state.size = null;
        if (state.center_source == null) state.center = null;
        return;
    }

    switch (changed_anchor) {
        .left, .bottom => {
            if (state.end_source == null) state.end = null;
            if (state.center_source == null) state.center = null;
        },
        .right, .top => {
            if (state.start_source == null) state.start = null;
            if (state.center_source == null) state.center = null;
        },
        .center_x, .center_y => {
            if (state.start_source == null) state.start = null;
            if (state.end_source == null) state.end = null;
        },
    }
}

fn overrideDefaultDerivedAnchor(state: *AxisState, anchor: Anchor, value: f32, source: ?Constraint) !bool {
    if (!state.size_is_default) return false;

    return switch (anchor) {
        .left, .bottom => blk: {
            if (state.start) |current| {
                if (approxEq(current, value)) break :blk false;
                if (state.start_source != null) break :blk false;
                if (state.end != null) {
                    state.start = value;
                    state.start_source = source;
                    state.size = null;
                    state.size_source = null;
                    state.size_is_default = false;
                    state.center = null;
                    state.center_source = null;
                    break :blk true;
                }
            }
            break :blk false;
        },
        .right, .top => blk: {
            if (state.end) |current| {
                if (approxEq(current, value)) break :blk false;
                if (state.end_source != null) break :blk false;
                if (state.start != null) {
                    state.end = value;
                    state.end_source = source;
                    state.size = null;
                    state.size_source = null;
                    state.size_is_default = false;
                    state.center = null;
                    state.center_source = null;
                    break :blk true;
                }
            }
            break :blk false;
        },
        .center_x, .center_y => false,
    };
}

pub fn moveDefaultSizedAnchor(state: *AxisState, anchor: Anchor, value: f32, source: ?Constraint) !bool {
    if (!state.size_is_default or state.size == null) return false;

    return switch (anchor) {
        .left, .bottom => blk: {
            if (state.start) |current| if (approxEq(current, value)) break :blk false;
            state.start = value;
            state.start_source = source;
            state.end = null;
            state.end_source = null;
            state.center = null;
            state.center_source = null;
            break :blk true;
        },
        .right, .top => blk: {
            if (state.end) |current| if (approxEq(current, value)) break :blk false;
            state.end = value;
            state.end_source = source;
            state.start = null;
            state.start_source = null;
            state.center = null;
            state.center_source = null;
            break :blk true;
        },
        .center_x, .center_y => blk: {
            if (state.center) |current| if (approxEq(current, value)) break :blk false;
            state.center = value;
            state.center_source = source;
            state.start = null;
            state.start_source = null;
            state.end = null;
            state.end_source = null;
            break :blk true;
        },
    };
}

pub fn replaceAxisAnchor(state: *AxisState, anchor: Anchor, value: f32, source: ?Constraint) bool {
    switch (anchor) {
        .left, .bottom => {
            if (state.start) |current| {
                if (approxEq(current, value) and constraintsEquivalentOptional(state.start_source, source)) return false;
            }
            state.start = value;
            state.start_source = source;
            state.end = null;
            state.end_source = null;
            state.size = null;
            state.size_source = null;
            state.size_is_default = false;
            state.center = null;
            state.center_source = null;
        },
        .right, .top => {
            if (state.end) |current| {
                if (approxEq(current, value) and constraintsEquivalentOptional(state.end_source, source)) return false;
            }
            state.end = value;
            state.end_source = source;
            state.start = null;
            state.start_source = null;
            state.size = null;
            state.size_source = null;
            state.size_is_default = false;
            state.center = null;
            state.center_source = null;
        },
        .center_x, .center_y => {
            if (state.center) |current| {
                if (approxEq(current, value) and constraintsEquivalentOptional(state.center_source, source)) return false;
            }
            state.center = value;
            state.center_source = source;
            state.start = null;
            state.start_source = null;
            state.end = null;
            state.end_source = null;
            state.size = null;
            state.size_source = null;
            state.size_is_default = false;
        },
    }
    return true;
}

pub fn reconcileAxisState(state: *AxisState) !bool {
    var changed = false;
    var progress = true;

    while (progress) {
        progress = false;

        if (state.start != null and state.end != null) {
            const size = state.end.? - state.start.?;
            try ensureNonNegativeSize(size);
            progress = (try setAxisSize(state, size, null)) or progress;
            progress = (try setOptionalFloat(&state.center, &state.center_source, state.start.? + size / 2, null)) or progress;
        }

        if (state.start != null and state.size != null) {
            progress = (try setOptionalFloat(&state.end, &state.end_source, state.start.? + state.size.?, null)) or progress;
            progress = (try setOptionalFloat(&state.center, &state.center_source, state.start.? + state.size.? / 2, null)) or progress;
        }

        if (state.end != null and state.size != null) {
            progress = (try setOptionalFloat(&state.start, &state.start_source, state.end.? - state.size.?, null)) or progress;
            progress = (try setOptionalFloat(&state.center, &state.center_source, state.start.? + state.size.? / 2, null)) or progress;
        }

        if (state.center != null and state.size != null) {
            progress = (try setOptionalFloat(&state.start, &state.start_source, state.center.? - state.size.? / 2, null)) or progress;
            progress = (try setOptionalFloat(&state.end, &state.end_source, state.center.? + state.size.? / 2, null)) or progress;
        }

        if (state.start != null and state.center != null) {
            const half = state.center.? - state.start.?;
            const size = half * 2;
            try ensureNonNegativeSize(size);
            progress = (try setAxisSize(state, size, null)) or progress;
            progress = (try setOptionalFloat(&state.end, &state.end_source, state.start.? + size, null)) or progress;
        }

        if (state.end != null and state.center != null) {
            const half = state.end.? - state.center.?;
            const size = half * 2;
            try ensureNonNegativeSize(size);
            progress = (try setAxisSize(state, size, null)) or progress;
            progress = (try setOptionalFloat(&state.start, &state.start_source, state.end.? - size, null)) or progress;
        }

        changed = progress or changed;
    }

    return changed;
}

fn ensureNonNegativeSize(size: f32) !void {
    if (size < -ConstraintTolerance) return error.NegativeConstraintSize;
}

fn setOptionalFloat(slot: *?f32, source_slot: *?Constraint, value: f32, source: ?Constraint) !bool {
    if (slot.*) |current| {
        if (approxEq(current, value)) return false;
        return error.ConstraintConflict;
    }
    slot.* = value;
    source_slot.* = source;
    return true;
}

fn constraintsEquivalent(a: Constraint, b: Constraint) bool {
    if (a.target_node != b.target_node) return false;
    if (a.target_anchor != b.target_anchor) return false;
    if (!approxEq(a.offset, b.offset)) return false;
    return constraintSourcesEquivalent(a.source, b.source);
}

fn constraintsEquivalentOptional(a: ?Constraint, b: ?Constraint) bool {
    if (a == null or b == null) return a == null and b == null;
    return constraintsEquivalent(a.?, b.?);
}

fn constraintSourcesEquivalent(a: ConstraintSource, b: ConstraintSource) bool {
    return switch (a) {
        .page => |a_anchor| switch (b) {
            .page => |b_anchor| a_anchor == b_anchor,
            .node => false,
        },
        .node => |a_node| switch (b) {
            .page => false,
            .node => |b_node| a_node.node_id == b_node.node_id and a_node.anchor == b_node.anchor,
        },
    };
}

pub fn setAxisSize(state: *AxisState, value: f32, source: ?Constraint) !bool {
    if (state.size) |current| {
        if (approxEq(current, value)) {
            return false;
        }
        if (state.size_is_default) {
            state.size = value;
            state.size_source = source;
            state.size_is_default = false;
            return true;
        }
        return error.ConstraintConflict;
    }

    state.size = value;
    state.size_source = source;
    state.size_is_default = false;
    return true;
}

pub fn anchorKnown(frame: Frame, anchor: Anchor) bool {
    return switch (anchor) {
        .left, .right, .center_x => frame.x_set,
        .top, .bottom, .center_y => frame.y_set,
    };
}

pub fn anchorValue(frame: Frame, anchor: Anchor) f32 {
    return switch (anchor) {
        .left => frame.x,
        .right => frame.x + frame.width,
        .top => frame.y + frame.height,
        .bottom => frame.y,
        .center_x => frame.x + frame.width / 2,
        .center_y => frame.y + frame.height / 2,
    };
}

const AnchorRole = enum { start, end, center };

fn anchorRole(anchor: Anchor) AnchorRole {
    return switch (anchor) {
        .left, .bottom => .start,
        .right, .top => .end,
        .center_x, .center_y => .center,
    };
}

fn sizeFromAnchorPair(target: Anchor, source: Anchor, offset: f32) ?f32 {
    return switch (anchorRole(target)) {
        .end => switch (anchorRole(source)) {
            .start => offset,
            .center => offset * 2,
            .end => null,
        },
        .start => switch (anchorRole(source)) {
            .end => -offset,
            .center => -offset * 2,
            .start => null,
        },
        .center => switch (anchorRole(source)) {
            .start => offset * 2,
            .end => -offset * 2,
            .center => null,
        },
    };
}

pub fn shiftAxisState(state: *AxisState, delta: f32) bool {
    if (approxEq(delta, 0)) return false;
    var changed = false;
    if (state.start) |value| {
        state.start = value + delta;
        changed = true;
    }
    if (state.end) |value| {
        state.end = value + delta;
        changed = true;
    }
    if (state.center) |value| {
        state.center = value + delta;
        changed = true;
    }
    return changed;
}

pub fn approxEq(a: f32, b: f32) bool {
    const diff = if (a > b) a - b else b - a;
    return diff < ConstraintTolerance;
}

fn containsIndex(items: []const usize, index: usize) bool {
    for (items) |item| {
        if (item == index) return true;
    }
    return false;
}

fn containsNodeId(items: []const NodeId, node_id: NodeId) bool {
    for (items) |item| {
        if (item == node_id) return true;
    }
    return false;
}
