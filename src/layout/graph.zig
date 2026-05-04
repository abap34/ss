const std = @import("std");
const model = @import("model");

const NodeId = model.NodeId;
const Node = model.Node;
const Axis = model.Axis;
const AxisState = model.AxisState;
const Anchor = model.Anchor;
const Constraint = model.Constraint;
const ConstraintSource = model.ConstraintSource;
const GroupRole = model.GroupRole;
const roleEq = model.roleEq;

pub const ConstraintTolerance: f32 = 0.01;

pub const ConstraintClass = enum {
    self_size,
    normal,
    page_source,
    external_source,
    group_target,
    group_source,
    wrong_axis,
};

pub const ComponentPolicy = struct {
    include_containment: bool = false,
    skip_group_targets: bool = false,
};

pub const PageLayoutGraph = struct {
    allocator: std.mem.Allocator,
    page_id: NodeId,
    child_ids: []const NodeId,
    index_by_node: std.AutoHashMap(NodeId, usize),

    pub fn init(allocator: std.mem.Allocator, ir: anytype, page_id: NodeId) !PageLayoutGraph {
        const children = ir.contains.get(page_id) orelse return .{
            .allocator = allocator,
            .page_id = page_id,
            .child_ids = &.{},
            .index_by_node = std.AutoHashMap(NodeId, usize).init(allocator),
        };

        var index_by_node = std.AutoHashMap(NodeId, usize).init(allocator);
        errdefer index_by_node.deinit();
        try index_by_node.ensureTotalCapacity(@intCast(children.items.len));
        for (children.items, 0..) |node_id, index| {
            index_by_node.putAssumeCapacity(node_id, index);
        }

        return .{
            .allocator = allocator,
            .page_id = page_id,
            .child_ids = children.items,
            .index_by_node = index_by_node,
        };
    }

    pub fn deinit(self: *PageLayoutGraph) void {
        self.index_by_node.deinit();
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
        for (ir.constraints.items) |constraint| {
            if (constraint.target_node != node_id) continue;
            if (anchorAxis(constraint.target_anchor) == axis) return true;
        }
        for (extra_constraints) |constraint| {
            if (constraint.target_node != node_id) continue;
            if (anchorAxis(constraint.target_anchor) == axis) return true;
        }
        _ = self;
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
        if (selfReferentialSize(constraint, axis) != null) return .self_size;
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
            if (roleEq(node.role, "page_number")) continue;
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
            if (roleEq(node.role, "page_number")) continue;
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
        for (self.workspace.graph.child_ids, self.workspace.states, 0..) |child_id, state, index| {
            const node = ir.getNode(child_id) orelse return error.UnknownNode;
            if (roleEq(node.role, "page_number") or state.start != null or state.end != null or state.center != null) {
                self.markPageDependent(index);
            }
        }
    }

    fn unionConstraintSlice(self: *ComponentSet, ir: anytype, constraints: []const Constraint, policy: ComponentPolicy) !void {
        for (constraints) |constraint| {
            const class = self.workspace.graph.constraintClass(ir, constraint, self.workspace.axis);
            switch (class) {
                .wrong_axis, .self_size => continue,
                .external_source => {
                    if (self.workspace.indexOf(constraint.target_node)) |target_index| {
                        self.markPageDependent(target_index);
                    }
                    continue;
                },
                .group_target => if (policy.skip_group_targets) continue,
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

pub fn selfReferentialSize(constraint: Constraint, axis: Axis) ?f32 {
    const node_source = switch (constraint.source) {
        .node => |ns| ns,
        .page => return null,
    };
    if (node_source.node_id != constraint.target_node) return null;
    if (anchorAxis(node_source.anchor) != axis) return null;
    if (anchorAxis(constraint.target_anchor) != axis) return null;
    return sizeFromAnchorPair(constraint.target_anchor, node_source.anchor, constraint.offset);
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
