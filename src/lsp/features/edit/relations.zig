const std = @import("std");

const source_relation = @import("../../../editor/relation.zig");
const protocol = @import("../../protocol.zig");

pub fn existingUpdateSpans(
    allocator: std.mem.Allocator,
    root: *const protocol.JsonObject,
    node_id: u32,
    path: []const u8,
    page_span: source_relation.ByteSpan,
) ![]source_relation.ByteSpan {
    var spans = std.ArrayList(source_relation.ByteSpan).empty;
    errdefer spans.deinit(allocator);
    const relations = layoutRelations(root) orelse return try spans.toOwnedSlice(allocator);
    for (relations.items) |*relation_value| {
        if (relation_value.* != .object) continue;
        const relation = &relation_value.object;
        if (!relationTargetsNode(relation, node_id)) continue;
        if (!relationHasRole(relation, "position")) continue;
        if (!(protocol.boolField(relation, "from_update") orelse false)) continue;
        const location = protocol.objectFieldObject(relation, "location") orelse continue;
        const relation_path = protocol.stringField(location, "path") orelse continue;
        const start = protocol.usizeField(location, "start") orelse continue;
        const end = protocol.usizeField(location, "end") orelse continue;
        if (!std.mem.eql(u8, relation_path, path) or start < page_span.start or end > page_span.end) continue;
        try spans.append(allocator, .{ .start = start, .end = end });
    }
    return try spans.toOwnedSlice(allocator);
}

pub fn editingTarget(root: *const protocol.JsonObject, node_id: u32) ?*const protocol.JsonObject {
    const items = protocol.arrayFieldObject(root, "editing") orelse return null;
    for (items.items) |*item| {
        if (item.* != .object) continue;
        if ((protocol.intField(&item.object, "node_id") orelse -1) == node_id) return &item.object;
    }
    return null;
}

const RelationCandidate = struct {
    source_span: ?source_relation.ByteSpan,
    target_anchor: []const u8,
    source: []const u8,
    source_anchor: []const u8,
    evaluated_offset: f64,
};

pub fn collect(
    allocator: std.mem.Allocator,
    root: *const protocol.JsonObject,
    source: []const u8,
    path: []const u8,
    node_id: u32,
    binding: []const u8,
    page_span: source_relation.ByteSpan,
    dx: f64,
    dy: f64,
) ![]source_relation.Adjustment {
    var adjustments = std.ArrayList(source_relation.Adjustment).empty;
    errdefer adjustments.deinit(allocator);
    try appendAxisAdjustments(allocator, &adjustments, root, source, path, node_id, binding, page_span, "horizontal", dx);
    try appendAxisAdjustments(allocator, &adjustments, root, source, path, node_id, binding, page_span, "vertical", -dy);
    return try adjustments.toOwnedSlice(allocator);
}

fn appendAxisAdjustments(
    allocator: std.mem.Allocator,
    adjustments: *std.ArrayList(source_relation.Adjustment),
    root: *const protocol.JsonObject,
    source: []const u8,
    path: []const u8,
    node_id: u32,
    binding: []const u8,
    page_span: source_relation.ByteSpan,
    axis: []const u8,
    delta: f64,
) !void {
    var candidates = std.ArrayList(RelationCandidate).empty;
    defer candidates.deinit(allocator);
    var relation_count: usize = 0;
    var local_count: usize = 0;
    const relations = layoutRelations(root) orelse return;
    for (relations.items) |*relation_value| {
        if (relation_value.* != .object) continue;
        const relation = &relation_value.object;
        if (!relationTargetsNode(relation, node_id)) continue;
        if (!relationHasRole(relation, "position")) continue;
        if (!std.mem.eql(u8, protocol.stringField(relation, "kind") orelse "", "explicit")) continue;
        if (!std.mem.eql(u8, protocol.stringField(relation, "axis") orelse "", axis)) continue;
        relation_count += 1;
        const candidate = relationCandidate(root, source, path, binding, page_span, relation) orelse continue;
        if (candidate.source_span != null) local_count += 1;
        try candidates.append(allocator, candidate);
    }

    if (relation_count == 0 or candidates.items.len == 0) return;
    if (local_count == relation_count) {
        for (candidates.items) |candidate| try adjustments.append(allocator, .{
            .action = .{ .replace = candidate.source_span.? },
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
        .action = .{ .append_update = candidate.source_span },
        .target = binding,
        .target_anchor = candidate.target_anchor,
        .source = candidate.source,
        .source_anchor = candidate.source_anchor,
        .evaluated_offset = candidate.evaluated_offset,
        .delta = delta,
    });
}

fn relationCandidate(
    root: *const protocol.JsonObject,
    source_text: []const u8,
    path: []const u8,
    binding: []const u8,
    page_span: source_relation.ByteSpan,
    relation: *const protocol.JsonObject,
) ?RelationCandidate {
    const target = protocol.objectFieldObject(relation, "target") orelse return null;
    const target_anchor = protocol.stringField(target, "anchor") orelse return null;
    const evaluated_offset = protocol.numberField(relation, "offset") orelse 0;
    if (protocol.objectFieldObject(relation, "location")) |location| {
        const relation_path = protocol.stringField(location, "path") orelse "";
        const start = protocol.usizeField(location, "start") orelse source_text.len;
        const end = protocol.usizeField(location, "end") orelse 0;
        if (std.mem.eql(u8, relation_path, path) and start >= page_span.start and end <= page_span.end and start < end and end <= source_text.len) {
            const parsed = source_relation.parse(source_text[start..end]);
            if (parsed) |value| {
                if (source_relation.sameObjectPath(value.target, binding) and std.mem.eql(u8, value.target_anchor, target_anchor)) return .{
                    .source_span = .{ .start = start, .end = end },
                    .target_anchor = value.target_anchor,
                    .source = value.source,
                    .source_anchor = value.source_anchor,
                    .evaluated_offset = evaluated_offset,
                };
            }
        }
    }

    const relation_source = protocol.objectFieldObject(relation, "source") orelse return null;
    const source_name = relationSourceBinding(root, relation_source) orelse return null;
    return .{
        .source_span = null,
        .target_anchor = target_anchor,
        .source = source_name,
        .source_anchor = protocol.stringField(relation_source, "anchor") orelse return null,
        .evaluated_offset = evaluated_offset,
    };
}

fn relationSourceBinding(root: *const protocol.JsonObject, source: *const protocol.JsonObject) ?[]const u8 {
    const source_type = protocol.stringField(source, "type") orelse return null;
    if (std.mem.eql(u8, source_type, "page")) return "page";
    if (!std.mem.eql(u8, source_type, "node")) return null;
    const node_id: u32 = @intCast(@max(0, protocol.intField(source, "node_id") orelse 0));
    const editing = editingTarget(root, node_id) orelse return null;
    if (protocol.boolField(editing, "binding_required") orelse false) return null;
    return protocol.stringField(editing, "binding");
}

fn firstRemoteCandidate(candidates: []const RelationCandidate) ?RelationCandidate {
    for (candidates) |candidate| if (candidate.source_span == null) return candidate;
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

fn layoutRelations(root: *const protocol.JsonObject) ?*const protocol.JsonArray {
    const layout = protocol.objectFieldObject(root, "layout") orelse return null;
    return protocol.arrayFieldObject(layout, "relations");
}

fn relationTargetsNode(relation: *const protocol.JsonObject, node_id: u32) bool {
    const target = protocol.objectFieldObject(relation, "target") orelse return false;
    return (protocol.intField(target, "node_id") orelse -1) == node_id;
}

fn relationHasRole(relation: *const protocol.JsonObject, expected: []const u8) bool {
    const role = protocol.stringField(relation, "role") orelse return false;
    return std.mem.eql(u8, role, expected);
}
