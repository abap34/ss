const std = @import("std");
const model = @import("model");
const utils = @import("utils");
const graph = @import("graph.zig");

const json = utils.json;

const Anchor = model.Anchor;
const Constraint = model.Constraint;
const ConstraintSource = model.ConstraintSource;
const Node = model.Node;
const NodeId = model.NodeId;

pub fn toJson(allocator: std.mem.Allocator, state: anytype) ![]u8 {
    var buffer = std.ArrayList(u8).empty;
    errdefer buffer.deinit(allocator);

    var root = try json.Object.beginBuffer(allocator, &buffer);
    try root.intField("schema", 1);
    try root.stringField("kind", "ss-layout-conflicts");
    try root.stringField("entry_path", state.projectPath());

    var pages = try root.arrayField("pages");
    for (state.page_order.items, 0..) |page_id, index| {
        const page = state.getNode(page_id) orelse continue;
        var item = try pages.objectItem();
        try item.intField("id", page.id);
        try item.intField("index", index + 1);
        try item.stringField("name", page.name);
        try item.floatField("width", page.frame.width, "{d:.4}");
        try item.floatField("height", page.frame.height, "{d:.4}");
        try item.optionalStringField("origin", page.origin);
        try appendOriginObject(&item, "location", state, page.origin);
        try item.end();
    }
    try pages.end();

    var objects = try root.arrayField("objects");
    for (state.nodes.items) |*node| {
        if (node.kind != .object) continue;
        const page_id = state.parentPageOf(node.id) orelse continue;
        var item = try objects.objectItem();
        try item.intField("id", node.id);
        try item.intField("page_id", page_id);
        try item.stringField("name", node.name);
        try item.optionalStringField("role", node.role);
        try item.optionalEnumTagField("object_kind", node.object_kind);
        try item.floatField("x", node.frame.x, "{d:.4}");
        try item.floatField("y", node.frame.y, "{d:.4}");
        try item.floatField("width", node.frame.width, "{d:.4}");
        try item.floatField("height", node.frame.height, "{d:.4}");
        try item.boolField("x_set", node.frame.x_set);
        try item.boolField("y_set", node.frame.y_set);
        try item.boolField("group", graph.isGroupNode(node));
        try item.optionalStringField("origin", node.origin);
        try appendOriginObject(&item, "location", state, node.origin);
        try item.end();
    }
    try objects.end();

    var anchors = try root.arrayField("anchors");
    for (state.page_order.items) |page_id| {
        const page = state.getNode(page_id) orelse continue;
        try appendAnchorSet(&anchors, page, page_id, page_id);
        if (state.childrenOf(page_id)) |children| {
            for (children) |child_id| try appendNodeAnchors(&anchors, state, page_id, child_id);
        }
    }
    try anchors.end();

    var relations = try root.arrayField("relations");
    for (state.constraints.items, 0..) |constraint, index| {
        try appendRelation(&relations, state, index, "explicit", constraint);
    }
    for (state.fallback_constraints.items, 0..) |constraint, index| {
        try appendRelation(&relations, state, state.constraints.items.len + index, "fallback", constraint);
    }
    try relations.end();

    var failures = try root.arrayField("failures");
    for (state.constraint_failures.items, 0..) |failure, index| {
        var item = try failures.objectItem();
        try item.intField("index", index);
        try item.stringField("code", failureCode(failure.kind));
        try item.enumTagField("reason", failure.reason);
        try item.intField("page_id", failure.page_id);
        try item.optionalEnumTagField("axis", failure.axis);
        try item.optionalFloatField("actual", failure.actual, "{d:.4}");
        try item.optionalFloatField("expected", failure.expected, "{d:.4}");
        try item.optionalIntField("constraint_index", constraintIndex(state, failure.constraint));
        try item.optionalIntField("existing_constraint_index", if (failure.existing_constraint) |c| constraintIndex(state, c) else null);
        try appendConstraintObject(&item, "constraint", state, failure.constraint);
        if (failure.existing_constraint) |constraint| {
            try appendConstraintObject(&item, "existing_constraint", state, constraint);
        } else {
            try item.nullField("existing_constraint");
        }
        if (failure.propagation) |propagation| {
            try appendPropagationObject(&item, "propagation", propagation);
        } else {
            try item.nullField("propagation");
        }
        try item.end();
    }
    try failures.end();

    try root.end();
    try json.appendNewline(&buffer, allocator);
    return buffer.toOwnedSlice(allocator);
}

fn appendRelation(relations: *json.Array, state: anytype, index: usize, kind: []const u8, constraint: Constraint) !void {
    var item = try relations.objectItem();
    try item.intField("index", index);
    try item.stringField("kind", kind);
    try item.enumTagField("axis", graph.anchorAxis(constraint.target_anchor));
    try item.enumTagField("role", constraint.role);
    try item.boolField("from_update", constraint.from_update);
    try item.optionalStringField("origin", constraint.origin);
    try appendOriginObject(&item, "location", state, constraint.origin);
    try item.floatField("offset", constraint.offset, "{d:.4}");
    try appendConstraintExpression(&item, "expression", state, constraint);
    var target = try item.objectField("target");
    try appendNodeEndpoint(&target, state, constraint.target_node, constraint.target_anchor);
    try target.end();
    var source = try item.objectField("source");
    try appendSourceEndpoint(&source, state, constraint.source);
    try source.end();
    try item.end();
}

fn appendNodeAnchors(anchors: *json.Array, state: anytype, page_id: NodeId, node_id: NodeId) !void {
    const node = state.getNode(node_id) orelse return;
    try appendAnchorSet(anchors, node, page_id, node_id);
    if (!graph.isGroupNode(node)) return;
    if (state.childrenOf(node_id)) |children| {
        for (children) |child_id| try appendNodeAnchors(anchors, state, page_id, child_id);
    }
}

fn appendAnchorSet(anchors: *json.Array, node: *const Node, page_id: NodeId, node_id: NodeId) !void {
    const all_anchors = [_]Anchor{ .left, .right, .center_x, .bottom, .top, .center_y };
    for (all_anchors) |anchor| {
        if (!graph.anchorKnown(node.frame, anchor)) continue;
        var item = try anchors.objectItem();
        try item.intField("page_id", page_id);
        try item.intField("node_id", node_id);
        try item.stringField("anchor", @tagName(anchor));
        try item.floatField("value", graph.anchorValue(node.frame, anchor), "{d:.4}");
        try item.end();
    }
}

fn appendConstraintObject(object: *json.Object, field_name: []const u8, state: anytype, constraint: Constraint) !void {
    var child = try object.objectField(field_name);
    try child.optionalIntField("index", constraintIndex(state, constraint));
    try child.optionalStringField("origin", constraint.origin);
    try appendOriginObject(&child, "location", state, constraint.origin);
    try child.enumTagField("axis", graph.anchorAxis(constraint.target_anchor));
    try child.enumTagField("role", constraint.role);
    try child.boolField("from_update", constraint.from_update);
    try child.floatField("offset", constraint.offset, "{d:.4}");
    try appendConstraintExpression(&child, "expression", state, constraint);
    var target = try child.objectField("target");
    try appendNodeEndpoint(&target, state, constraint.target_node, constraint.target_anchor);
    try target.end();
    var source = try child.objectField("source");
    try appendSourceEndpoint(&source, state, constraint.source);
    try source.end();
    try child.end();
}

fn appendPropagationObject(object: *json.Object, field_name: []const u8, propagation: model.ConstraintPropagation) !void {
    var child = try object.objectField(field_name);
    try child.optionalStringField("target", propagation.target);
    var paths = try child.arrayField("paths");
    for (propagation.paths) |path| {
        var path_object = try paths.objectItem();
        try path_object.stringField("title", path.title);
        var lines = try path_object.arrayField("lines");
        for (path.lines) |line| try lines.stringItem(line);
        try lines.end();
        var sources = try path_object.arrayField("sources");
        for (path.lines, 0..) |_, index| {
            const source = if (index < path.line_sources.len) path.line_sources[index] else null;
            if (source) |text| {
                try sources.stringItem(text);
            } else {
                try sources.nullItem();
            }
        }
        try sources.end();
        try path_object.end();
    }
    try paths.end();
    var result = try child.arrayField("result");
    for (propagation.result) |line| try result.stringItem(line);
    try result.end();
    try child.end();
}

fn appendConstraintExpression(object: *json.Object, field_name: []const u8, state: anytype, constraint: Constraint) !void {
    const target = nodeLabel(state, constraint.target_node);
    const source = switch (constraint.source) {
        .page => "page",
        .node => |node_source| nodeLabel(state, node_source.node_id),
    };
    const source_anchor = switch (constraint.source) {
        .page => |anchor| @tagName(anchor),
        .node => |node_source| @tagName(node_source.anchor),
    };
    const text = try std.fmt.allocPrint(
        object.allocator,
        "{s}.{s} = {s}.{s} {s} {d:.1}",
        .{
            target,
            @tagName(constraint.target_anchor),
            source,
            source_anchor,
            if (constraint.offset < 0) "-" else "+",
            @abs(constraint.offset),
        },
    );
    defer object.allocator.free(text);
    try object.stringField(field_name, text);
}

fn appendNodeEndpoint(object: *json.Object, state: anytype, node_id: NodeId, anchor: Anchor) !void {
    const node = state.getNode(node_id);
    try object.stringField("type", "node");
    try object.intField("node_id", node_id);
    try object.stringField("name", if (node) |value| value.name else "unknown");
    try object.optionalStringField("role", if (node) |value| value.role else null);
    try object.stringField("label", nodeLabel(state, node_id));
    try object.stringField("anchor", @tagName(anchor));
}

fn appendSourceEndpoint(object: *json.Object, state: anytype, source: ConstraintSource) !void {
    switch (source) {
        .page => |anchor| {
            try object.stringField("type", "page");
            try object.stringField("name", "page");
            try object.stringField("label", "page");
            try object.stringField("anchor", @tagName(anchor));
        },
        .node => |node_source| try appendNodeEndpoint(object, state, node_source.node_id, node_source.anchor),
    }
}

fn appendOriginObject(object: *json.Object, field_name: []const u8, state: anytype, origin: ?[]const u8) !void {
    const origin_text = origin orelse {
        try object.nullField(field_name);
        return;
    };
    const located = utils.err.parseLocatedOrigin(origin_text) orelse {
        try object.nullField(field_name);
        return;
    };
    var path = state.projectPath();
    var source = state.projectSource();
    if (located.path) |origin_path| {
        if (state.moduleByPathOrSpec(origin_path)) |module| {
            path = module.path orelse module.spec;
            source = module.source;
        } else {
            path = origin_path;
        }
    } else {
        const module = state.projectModule();
        path = module.path orelse module.spec;
        source = module.source;
    }
    const loc = utils.source.locationAt(source, located.span.start);

    var child = try object.objectField(field_name);
    try child.stringField("path", path);
    try child.intField("line", loc.line);
    try child.intField("column", loc.column);
    try child.intField("start", located.span.start);
    try child.intField("end", located.span.end);
    try child.end();
}

fn nodeLabel(state: anytype, node_id: NodeId) []const u8 {
    const node = state.getNode(node_id) orelse return "unknown";
    return node.role orelse node.name;
}

fn constraintIndex(state: anytype, needle: Constraint) ?usize {
    for (state.constraints.items, 0..) |constraint, index| {
        if (constraintsSame(constraint, needle)) return index;
    }
    return null;
}

fn constraintsSame(a: Constraint, b: Constraint) bool {
    if (a.target_node != b.target_node) return false;
    if (a.target_anchor != b.target_anchor) return false;
    if (!graph.approxEq(a.offset, b.offset)) return false;
    const a_origin = a.origin orelse "";
    const b_origin = b.origin orelse "";
    if (!std.mem.eql(u8, a_origin, b_origin)) return false;
    return switch (a.source) {
        .page => |a_anchor| switch (b.source) {
            .page => |b_anchor| a_anchor == b_anchor,
            .node => false,
        },
        .node => |a_node| switch (b.source) {
            .page => false,
            .node => |b_node| a_node.node_id == b_node.node_id and a_node.anchor == b_node.anchor,
        },
    };
}

fn failureCode(kind: model.ConstraintFailureKind) []const u8 {
    return switch (kind) {
        .conflict => "ConstraintConflict",
        .negative_frame_size => "NegativeFrameSize",
    };
}
