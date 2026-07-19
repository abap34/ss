const std = @import("std");
const core = @import("core");

const editor_edit = @import("../../../editor/edit.zig");
const editor_snapshot = @import("../../../editor/snapshot.zig");
const source_relation = @import("../../../editor/relation.zig");

const LayoutReport = core.layout.conflicts.Report;
const Relation = core.layout.conflicts.Relation;

pub fn existingUpdates(
    allocator: std.mem.Allocator,
    report: *const LayoutReport,
    node_id: core.NodeId,
    path: []const u8,
    page_span: source_relation.ByteSpan,
) ![]editor_edit.ExistingUpdate {
    var updates = std.ArrayList(editor_edit.ExistingUpdate).empty;
    errdefer updates.deinit(allocator);
    for (report.relations) |relation| {
        if (relation.kind != .explicit or relation.target_node != node_id) continue;
        if (relation.role != .position or !relation.from_update) continue;
        const source_edit = localSourceEdit(relation, path, page_span) orelse continue;
        const syntax = relation.syntax orelse continue;
        if (syntax.action != .update) continue;
        try updates.append(allocator, .{
            .source = source_edit,
            .horizontal = relation.axis == .horizontal,
        });
    }
    return try updates.toOwnedSlice(allocator);
}

const RelationCandidate = struct {
    source_edit: ?source_relation.Source,
    target_anchor: []const u8,
    source: []const u8,
    source_anchor: []const u8,
    evaluated_offset: f64,
};

pub fn collect(
    allocator: std.mem.Allocator,
    report: *const LayoutReport,
    editor: *const editor_snapshot.Model,
    path: []const u8,
    node_id: core.NodeId,
    binding: []const u8,
    page_span: source_relation.ByteSpan,
    dx: f64,
    dy: f64,
) ![]source_relation.Adjustment {
    var adjustments = std.ArrayList(source_relation.Adjustment).empty;
    errdefer adjustments.deinit(allocator);
    try appendAxisAdjustments(allocator, &adjustments, report, editor, path, node_id, binding, page_span, .horizontal, dx);
    try appendAxisAdjustments(allocator, &adjustments, report, editor, path, node_id, binding, page_span, .vertical, -dy);
    return try adjustments.toOwnedSlice(allocator);
}

fn appendAxisAdjustments(
    allocator: std.mem.Allocator,
    adjustments: *std.ArrayList(source_relation.Adjustment),
    report: *const LayoutReport,
    editor: *const editor_snapshot.Model,
    path: []const u8,
    node_id: core.NodeId,
    binding: []const u8,
    page_span: source_relation.ByteSpan,
    axis: core.Axis,
    delta: f64,
) !void {
    var candidates = std.ArrayList(RelationCandidate).empty;
    defer candidates.deinit(allocator);
    var relation_count: usize = 0;
    var local_count: usize = 0;
    for (report.relations) |relation| {
        if (relation.kind != .explicit or relation.target_node != node_id) continue;
        if (relation.role != .position or relation.axis != axis) continue;
        relation_count += 1;
        const candidate = relationCandidate(editor, path, page_span, relation) orelse continue;
        if (candidate.source_edit != null) local_count += 1;
        try candidates.append(allocator, candidate);
    }

    if (relation_count == 0 or candidates.items.len == 0) return;
    if (local_count == relation_count) {
        for (candidates.items) |candidate| try adjustments.append(allocator, .{
            .action = .{ .replace = candidate.source_edit.? },
            .target = binding,
            .target_anchor = candidate.target_anchor,
            .source = candidate.source,
            .source_anchor = candidate.source_anchor,
            .evaluated_offset = candidate.evaluated_offset,
            .delta = delta,
        });
        return;
    }

    const candidate = firstRemoteCandidate(candidates.items) orelse candidates.items[0];
    try adjustments.append(allocator, .{
        .action = .{ .append_update = candidate.source_edit },
        .target = binding,
        .target_anchor = candidate.target_anchor,
        .source = candidate.source,
        .source_anchor = candidate.source_anchor,
        .evaluated_offset = candidate.evaluated_offset,
        .delta = delta,
    });
}

fn relationCandidate(
    editor: *const editor_snapshot.Model,
    path: []const u8,
    page_span: source_relation.ByteSpan,
    relation: Relation,
) ?RelationCandidate {
    return .{
        .source_edit = localSourceEdit(relation, path, page_span),
        .target_anchor = @tagName(relation.target_anchor),
        .source = relationSourceBinding(editor, relation.source) orelse return null,
        .source_anchor = switch (relation.source) {
            .page => |anchor| @tagName(anchor),
            .node => |source| @tagName(source.anchor),
        },
        .evaluated_offset = relation.offset,
    };
}

fn localSourceEdit(relation: Relation, path: []const u8, page_span: source_relation.ByteSpan) ?source_relation.Source {
    const location = relation.location orelse return null;
    if (!std.mem.eql(u8, location.path, path)) return null;
    if (location.start < page_span.start or location.end > page_span.end) return null;
    const syntax = relation.syntax orelse return null;
    const source_span = syntax.source orelse return null;
    return .{
        .target = syntax.target,
        .source = source_span,
        .offset = syntax.offset,
    };
}

fn relationSourceBinding(editor: *const editor_snapshot.Model, source: core.ConstraintSource) ?[]const u8 {
    return switch (source) {
        .page => "page",
        .node => |node_source| editor.bindingForNode(node_source.node_id),
    };
}

fn firstRemoteCandidate(candidates: []const RelationCandidate) ?RelationCandidate {
    for (candidates) |candidate| if (candidate.source_edit == null) return candidate;
    return null;
}

pub fn haveBothAxes(adjustments: []const source_relation.Adjustment) bool {
    var horizontal = false;
    var vertical = false;
    for (adjustments) |adjustment| {
        const is_horizontal = source_relation.isHorizontal(adjustment.target_anchor) orelse continue;
        if (is_horizontal) horizontal = true else vertical = true;
    }
    return horizontal and vertical;
}
