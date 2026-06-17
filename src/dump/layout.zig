const std = @import("std");
const core = @import("core");

const json = @import("utils").json;
const layout = core.layout;

pub fn writePageOrderField(root: *json.Object, page_order: []const core.NodeId) !void {
    var array = try root.arrayField("page_order");
    for (page_order) |page_id| try array.intItem(page_id);
    try array.end();
}

pub fn writeContainsField(root: *json.Object, contains_map: *std.AutoHashMap(core.NodeId, std.ArrayList(core.NodeId))) !void {
    var contains = try root.arrayField("contains");
    var contains_iterator = contains_map.iterator();
    while (contains_iterator.next()) |entry| {
        var item = try contains.objectItem();
        try item.intField("parent", entry.key_ptr.*);
        var children = try item.arrayField("children");
        for (entry.value_ptr.items) |child_id| try children.intItem(child_id);
        try children.end();
        try item.end();
    }
    try contains.end();
}

pub fn writeConstraintsField(root: *json.Object, constraints: []const core.Constraint) !void {
    var array = try root.arrayField("constraints");
    for (constraints) |constraint| {
        var item = try array.objectItem();
        try writeConstraintFields(&item, constraint, "target_node", "source_node", "node");
        try item.end();
    }
    try array.end();
}

pub fn writeLayoutRelationsField(allocator: std.mem.Allocator, root: *json.Object, ir: *core.Ir) !void {
    var array = try root.arrayField("layout_relations");
    for (ir.constraints.items) |constraint| {
        const page_id = ir.parentPageOf(constraint.target_node) orelse continue;
        var item = try array.objectItem();
        try item.stringField("kind", "explicit");
        try item.intField("page_id", page_id);
        try item.enumTagField("axis", layout.anchorAxis(constraint.target_anchor));
        try writeConstraintFields(&item, constraint, "target_node", "source_node", "node");
        try item.end();
    }

    for (ir.page_order.items) |page_id| {
        try writeFallbackRelationsForPage(allocator, &array, ir, page_id);
    }
    try array.end();
}

fn writeFallbackRelationsForPage(allocator: std.mem.Allocator, array: *json.Array, ir: *core.Ir, page_id: core.NodeId) !void {
    var page_graph = try layout.graph.PageLayoutGraph.init(allocator, ir, page_id);
    defer page_graph.deinit();
    if (page_graph.len() == 0) return;

    var horizontal = try emptyAxisWorkspace(allocator, &page_graph, .horizontal);
    defer horizontal.deinit();
    try solveAxisForFallbackDump(ir, &horizontal);
    var horizontal_fallback = try layout.fallback.buildHorizontalConstraints(ir, &horizontal);
    defer horizontal_fallback.deinit(allocator);
    try writeFallbackRelationItems(array, page_id, .horizontal, horizontal_fallback.items);

    var vertical = try emptyAxisWorkspace(allocator, &page_graph, .vertical);
    defer vertical.deinit();
    try solveAxisForFallbackDump(ir, &vertical);
    var vertical_fallback = try layout.fallback.buildVerticalConstraints(ir, &vertical);
    defer vertical_fallback.deinit(allocator);
    try writeFallbackRelationItems(array, page_id, .vertical, vertical_fallback.items);
}

fn emptyAxisWorkspace(allocator: std.mem.Allocator, page_graph: *const layout.graph.PageLayoutGraph, axis: core.Axis) !layout.graph.AxisWorkspace {
    const states = try allocator.alloc(core.AxisState, page_graph.len());
    errdefer allocator.free(states);
    for (states) |*state| state.* = .{};
    return .{
        .allocator = allocator,
        .graph = page_graph,
        .axis = axis,
        .states = states,
    };
}

fn solveAxisForFallbackDump(ir: *core.Ir, workspace: *layout.graph.AxisWorkspace) !void {
    try layout.solver.runPageAxisPassWithOptions(ir, workspace, .{ .record_diagnostics = false });
    for (workspace.graph.child_ids, workspace.states) |child_id, *state| {
        if (state.size != null) continue;
        const node = ir.getNode(child_id) orelse return error.UnknownNode;
        state.size = switch (workspace.axis) {
            .horizontal => node.frame.width,
            .vertical => node.frame.height,
        };
        state.size_is_default = true;
    }
    try layout.solver.runPageAxisPassWithOptions(ir, workspace, .{ .record_diagnostics = false });
}

fn writeFallbackRelationItems(array: *json.Array, page_id: core.NodeId, axis: core.Axis, constraints: []const core.Constraint) !void {
    for (constraints) |constraint| {
        var item = try array.objectItem();
        try item.stringField("kind", "fallback");
        try item.intField("page_id", page_id);
        try item.enumTagField("axis", axis);
        try writeConstraintFields(&item, constraint, "target_node", "source_node", "node");
        try item.end();
    }
}

fn writeConstraintFields(
    item: *json.Object,
    constraint: core.Constraint,
    target_key: []const u8,
    source_key: []const u8,
    node_source_kind: []const u8,
) !void {
    try item.intField(target_key, constraint.target_node);
    try item.enumTagField("target_anchor", constraint.target_anchor);
    switch (constraint.source) {
        .page => |anchor| {
            try item.stringField("source_kind", "page");
            try item.enumTagField("source_anchor", anchor);
            try item.nullField(source_key);
        },
        .node => |source| {
            try item.stringField("source_kind", node_source_kind);
            try item.enumTagField("source_anchor", source.anchor);
            try item.intField(source_key, source.node_id);
        },
    }
    try item.floatField("offset", constraint.offset, "{d:.1}");
    try item.optionalStringField("origin", constraint.origin);
}
