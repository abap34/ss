const std = @import("std");
const ast = @import("ast");
const model = @import("model");
const utils = @import("utils");
const graph = @import("graph.zig");

const json = utils.json;

const Anchor = model.Anchor;
const Constraint = model.Constraint;
const ConstraintSource = model.ConstraintSource;
const Node = model.Node;
const NodeId = model.NodeId;
const NodeIndex = std.AutoHashMap(NodeId, usize);

pub const RelationKind = enum {
    explicit,
    fallback,
};

pub const Location = struct {
    path: []u8,
    start: usize,
    end: usize,
};

pub const ConstraintSyntax = struct {
    action: ast.ConstraintDecl.Action,
    target: utils.source.ByteSpan,
    source: ?utils.source.ByteSpan,
    offset: ?utils.source.ByteSpan,
};

pub const Page = struct {
    id: NodeId,
    width: f32,
    height: f32,
};

pub const Object = struct {
    id: NodeId,
    page_id: NodeId,
    x: f32,
    y: f32,
    width: f32,
    height: f32,
};

pub const Relation = struct {
    kind: RelationKind,
    constraint_index: ?usize,
    target_node: NodeId,
    target_anchor: Anchor,
    source: ConstraintSource,
    offset: f32,
    axis: model.Axis,
    role: model.ConstraintRole,
    scope_depth: u32,
    from_update: bool,
    origin: ?[]u8,
    location: ?Location,
    syntax: ?ConstraintSyntax,
};

pub const Report = struct {
    allocator: std.mem.Allocator,
    pages: []Page,
    objects: []Object,
    relations: []Relation,
    failure_count: usize,
    page_index_by_id: NodeIndex,
    object_index_by_id: NodeIndex,

    pub fn init(allocator: std.mem.Allocator, state: anytype) !Report {
        var pages = std.ArrayList(Page).empty;
        errdefer pages.deinit(allocator);
        for (state.page_order.items) |page_id| {
            const page = state.getNode(page_id) orelse continue;
            try pages.append(allocator, .{
                .id = page.id,
                .width = page.frame.width,
                .height = page.frame.height,
            });
        }

        var objects = std.ArrayList(Object).empty;
        errdefer objects.deinit(allocator);
        for (state.nodes.items) |node| {
            if (node.kind != .object) continue;
            const page_id = state.parentPageOf(node.id) orelse continue;
            try objects.append(allocator, .{
                .id = node.id,
                .page_id = page_id,
                .x = node.frame.x,
                .y = node.frame.y,
                .width = node.frame.width,
                .height = node.frame.height,
            });
        }

        var relations = std.ArrayList(Relation).empty;
        errdefer relations.deinit(allocator);
        errdefer deinitRelationItems(allocator, relations.items);
        for (state.constraints.items, 0..) |constraint, constraint_index| {
            try appendRelationModel(allocator, &relations, state, .explicit, constraint_index, constraint);
        }
        for (state.fallback_constraints.items) |constraint| {
            try appendRelationModel(allocator, &relations, state, .fallback, null, constraint);
        }

        const owned_pages = try pages.toOwnedSlice(allocator);
        errdefer allocator.free(owned_pages);
        const owned_objects = try objects.toOwnedSlice(allocator);
        errdefer allocator.free(owned_objects);
        const owned_relations = try relations.toOwnedSlice(allocator);
        errdefer {
            deinitRelationItems(allocator, owned_relations);
            allocator.free(owned_relations);
        }

        var page_index_by_id = NodeIndex.init(allocator);
        errdefer page_index_by_id.deinit();
        try page_index_by_id.ensureTotalCapacity(@intCast(owned_pages.len));
        for (owned_pages, 0..) |page, index| {
            const entry = page_index_by_id.getOrPutAssumeCapacity(page.id);
            if (!entry.found_existing) entry.value_ptr.* = index;
        }

        var object_index_by_id = NodeIndex.init(allocator);
        errdefer object_index_by_id.deinit();
        try object_index_by_id.ensureTotalCapacity(@intCast(owned_objects.len));
        for (owned_objects, 0..) |object, index| {
            const entry = object_index_by_id.getOrPutAssumeCapacity(object.id);
            if (!entry.found_existing) entry.value_ptr.* = index;
        }

        return .{
            .allocator = allocator,
            .pages = owned_pages,
            .objects = owned_objects,
            .relations = owned_relations,
            .failure_count = state.constraint_failures.items.len,
            .page_index_by_id = page_index_by_id,
            .object_index_by_id = object_index_by_id,
        };
    }

    pub fn deinit(self: *Report) void {
        self.page_index_by_id.deinit();
        self.object_index_by_id.deinit();
        self.allocator.free(self.pages);
        self.allocator.free(self.objects);
        deinitRelationItems(self.allocator, self.relations);
        self.allocator.free(self.relations);
        self.* = .{
            .allocator = self.allocator,
            .pages = &.{},
            .objects = &.{},
            .relations = &.{},
            .failure_count = 0,
            .page_index_by_id = NodeIndex.init(self.allocator),
            .object_index_by_id = NodeIndex.init(self.allocator),
        };
    }

    pub fn objectById(self: *const Report, node_id: NodeId) ?Object {
        const index = self.object_index_by_id.get(node_id) orelse return null;
        return self.objects[index];
    }

    pub fn pageById(self: *const Report, page_id: NodeId) ?Page {
        const index = self.page_index_by_id.get(page_id) orelse return null;
        return self.pages[index];
    }
};

fn appendRelationModel(
    allocator: std.mem.Allocator,
    relations: *std.ArrayList(Relation),
    state: anytype,
    kind: RelationKind,
    constraint_index: ?usize,
    constraint: Constraint,
) !void {
    const relation = try initRelation(allocator, state, kind, constraint_index, constraint);
    errdefer deinitRelation(allocator, relation);
    try relations.append(allocator, relation);
}

fn initRelation(
    allocator: std.mem.Allocator,
    state: anytype,
    kind: RelationKind,
    constraint_index: ?usize,
    constraint: Constraint,
) !Relation {
    const origin = if (constraint.origin) |value| try allocator.dupe(u8, value) else null;
    errdefer if (origin) |value| allocator.free(value);
    const located = try cloneLocation(allocator, state, constraint.origin);
    errdefer if (located) |location| allocator.free(location.path);
    return .{
        .kind = kind,
        .constraint_index = constraint_index,
        .target_node = constraint.target_node,
        .target_anchor = constraint.target_anchor,
        .source = constraint.source,
        .offset = constraint.offset,
        .axis = graph.anchorAxis(constraint.target_anchor),
        .role = constraint.role,
        .scope_depth = constraint.scope_depth,
        .from_update = constraint.from_update,
        .origin = origin,
        .location = located,
        .syntax = constraintSourceSyntax(state, constraint.origin),
    };
}

fn deinitRelationItems(allocator: std.mem.Allocator, relations: []Relation) void {
    for (relations) |relation| deinitRelation(allocator, relation);
}

fn deinitRelation(allocator: std.mem.Allocator, relation: Relation) void {
    if (relation.origin) |origin| allocator.free(origin);
    if (relation.location) |location| allocator.free(location.path);
}

fn cloneLocation(allocator: std.mem.Allocator, state: anytype, origin: ?[]const u8) !?Location {
    const origin_text = origin orelse return null;
    const located = utils.err.parseLocatedOrigin(origin_text) orelse return null;
    const module = if (located.path) |origin_path| state.moduleByPathOrSpec(origin_path) else state.projectModule();
    const path = if (module) |value|
        value.path orelse value.spec
    else
        located.path orelse state.projectPath();
    return .{
        .path = try allocator.dupe(u8, path),
        .start = located.span.start,
        .end = located.span.end,
    };
}

fn constraintSourceSyntax(state: anytype, origin: ?[]const u8) ?ConstraintSyntax {
    const located = utils.err.parseLocatedOrigin(origin orelse return null) orelse return null;
    const module = if (located.path) |origin_path|
        state.moduleByPathOrSpec(origin_path) orelse return null
    else
        state.projectModule();
    const statement = findStatement(&module.syntax, .{
        .start = located.span.start,
        .end = located.span.end,
    }) orelse return null;
    const constraint = switch (statement.kind) {
        .constrain => |value| value,
        else => return null,
    };
    const syntax = constraint.syntax orelse return null;
    return .{
        .action = constraint.action,
        .target = .{ .start = syntax.target.start, .end = syntax.target.end },
        .source = if (syntax.source) |span| .{ .start = span.start, .end = span.end } else null,
        .offset = if (syntax.offset) |span| .{ .start = span.start, .end = span.end } else null,
    };
}

fn findStatement(module: *const ast.Module, span: ast.Span) ?*const ast.Statement {
    if (findStatementInList(module.document_statements.items, span)) |statement| return statement;
    for (module.functions.items) |*function| {
        if (findStatementInList(function.statements.items, span)) |statement| return statement;
    }
    for (module.pages.items) |*page| {
        if (findStatementInList(page.statements.items, span)) |statement| return statement;
    }
    return null;
}

fn findStatementInList(statements: []const ast.Statement, span: ast.Span) ?*const ast.Statement {
    for (statements) |*statement| {
        if (statement.span.start == span.start and statement.span.end == span.end) return statement;
        switch (statement.kind) {
            .if_stmt => |conditional| {
                if (findStatementInList(conditional.then_statements.items, span)) |nested| return nested;
                if (findStatementInList(conditional.else_statements.items, span)) |nested| return nested;
            },
            else => {},
        }
    }
    return null;
}

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
        try item.floatField("x", node.frame.x, "{d:.4}");
        try item.floatField("y", node.frame.y, "{d:.4}");
        try item.floatField("width", node.frame.width, "{d:.4}");
        try item.floatField("height", node.frame.height, "{d:.4}");
        try item.boolField("group", graph.isGroupNode(node));
        try appendOriginObject(&item, "location", state, node.origin);
        try item.end();
    }
    try objects.end();

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
    try object.stringField("type", "node");
    try object.intField("node_id", node_id);
    try object.stringField("label", nodeLabel(state, node_id));
    try object.stringField("anchor", @tagName(anchor));
}

fn appendSourceEndpoint(object: *json.Object, state: anytype, source: ConstraintSource) !void {
    switch (source) {
        .page => |anchor| {
            try object.stringField("type", "page");
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
