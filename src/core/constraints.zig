const std = @import("std");
const model = @import("model");

const Allocator = model.Allocator;
const NodeId = model.NodeId;
const Anchor = model.Anchor;
const Constraint = model.Constraint;
const ConstraintSet = model.ConstraintSet;
const ConstraintSource = model.ConstraintSource;
const ConstraintRole = model.ConstraintRole;

pub const DocumentConstraints = struct {
    active: std.ArrayList(Constraint) = .empty,
    fallback: std.ArrayList(Constraint) = .empty,
    updates: std.ArrayList(model.ConstraintUpdate) = .empty,
    overridden: std.ArrayList(Constraint) = .empty,
    default_alignments_collected: bool = false,

    pub fn deinit(self: *DocumentConstraints, allocator: Allocator) void {
        self.active.deinit(allocator);
        self.fallback.deinit(allocator);
        self.updates.deinit(allocator);
        self.overridden.deinit(allocator);
    }

    pub fn addAnchor(
        self: *DocumentConstraints,
        allocator: Allocator,
        target_node: NodeId,
        target_anchor: Anchor,
        source: ConstraintSource,
        offset: f32,
        origin: ?model.SourceOrigin,
    ) !void {
        try self.addAnchorAtScope(allocator, target_node, target_anchor, source, offset, origin, 0);
    }

    pub fn addAnchorAtScope(
        self: *DocumentConstraints,
        allocator: Allocator,
        target_node: NodeId,
        target_anchor: Anchor,
        source: ConstraintSource,
        offset: f32,
        origin: ?model.SourceOrigin,
        scope_depth: u32,
    ) !void {
        const constraint = Constraint{
            .target_node = target_node,
            .target_anchor = target_anchor,
            .source = source,
            .offset = offset,
            .origin = origin,
            .role = model.constraintRoleForRelation(target_node, target_anchor, source),
            .scope_depth = scope_depth,
        };
        try self.active.append(allocator, constraint);
    }

    pub fn addUpdate(
        self: *DocumentConstraints,
        allocator: Allocator,
        target_node: NodeId,
        target_anchor: Anchor,
        role: ConstraintRole,
        scope_depth: u32,
        replacement_source: ?ConstraintSource,
        replacement_offset: f32,
        origin: ?model.SourceOrigin,
    ) !void {
        try self.updates.append(allocator, .{
            .target_node = target_node,
            .target_anchor = target_anchor,
            .role = role,
            .scope_depth = scope_depth,
            .replacement = if (replacement_source) |source| .{
                .target_node = target_node,
                .target_anchor = target_anchor,
                .source = source,
                .offset = replacement_offset,
                .origin = origin,
                .role = role,
                .scope_depth = scope_depth,
                .from_update = true,
            } else null,
            .origin = origin,
        });
    }

    pub fn addSet(self: *DocumentConstraints, allocator: Allocator, constraints: ConstraintSet) !void {
        try self.active.appendSlice(allocator, constraints.items.items);
    }
};
