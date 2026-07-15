const std = @import("std");
const ast = @import("ast");
const core = @import("core");
const render = @import("render");
const render_html = @import("../render/html.zig");
const utils = @import("utils");

const json = utils.json;
const assets = @import("assets.zig");
const binding_names = @import("names.zig");

pub fn toJson(
    allocator: std.mem.Allocator,
    io: std.Io,
    state: *core.DocumentState,
    render_ir: *const render.Ir,
    generation: u64,
) ![]u8 {
    try render_ir.validate();
    var fragment = try render_html.prepareFragment(allocator, render_ir);
    defer fragment.deinit(allocator);
    var published_assets = try assets.publish(allocator, io, &fragment, ".ss-cache/render");
    defer published_assets.deinit(allocator);
    const layout_json = try core.layout.conflicts.toJson(allocator, state);
    defer allocator.free(layout_json);
    const display_json = try displayJson(allocator, &fragment, &published_assets);
    defer allocator.free(display_json);
    const outline_json = try outlineJson(allocator, state);
    defer allocator.free(outline_json);
    const editing_json = try editingJson(allocator, state);
    defer allocator.free(editing_json);
    const source_paths_json = try sourcePathsJson(allocator, state);
    defer allocator.free(source_paths_json);

    var hasher = std.hash.Wyhash.init(generation);
    hasher.update(state.projectPath());
    hasher.update(state.projectSource());
    hasher.update(layout_json);
    hasher.update(display_json);
    hasher.update(outline_json);
    hasher.update(editing_json);
    hasher.update(source_paths_json);
    const snapshot_id = try std.fmt.allocPrint(allocator, "{d}-{x}", .{
        generation,
        hasher.final(),
    });
    defer allocator.free(snapshot_id);

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"schema\":1,\"kind\":\"ss-editor-snapshot\",\"snapshot_id\":");
    try json.appendString(allocator, &out, snapshot_id);
    try out.appendSlice(allocator, ",\"generation\":");
    try json.appendInt(allocator, &out, generation);
    try out.appendSlice(allocator, ",\"entry_path\":");
    try json.appendString(allocator, &out, state.projectPath());
    try out.appendSlice(allocator, ",\"source_paths\":");
    try out.appendSlice(allocator, source_paths_json);
    try out.appendSlice(allocator, ",\"coordinate_space\":{\"unit\":\"pt\",\"origin\":\"page-top-left\",\"x_axis\":\"right\",\"y_axis\":\"down\"},\"layout\":");
    try out.appendSlice(allocator, std.mem.trim(u8, layout_json, "\r\n"));
    try out.appendSlice(allocator, ",\"display\":");
    try out.appendSlice(allocator, display_json);
    try out.appendSlice(allocator, ",\"outline\":");
    try out.appendSlice(allocator, outline_json);
    try out.appendSlice(allocator, ",\"editing\":");
    try out.appendSlice(allocator, editing_json);
    try out.appendSlice(allocator, "}\n");
    return try out.toOwnedSlice(allocator);
}

fn sourcePathsJson(allocator: std.mem.Allocator, state: *const core.DocumentState) ![]u8 {
    var buffer = std.ArrayList(u8).empty;
    errdefer buffer.deinit(allocator);
    var paths = try json.Array.beginBuffer(allocator, &buffer);
    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();
    try paths.stringItem(state.projectPath());
    try seen.put(state.projectPath(), {});
    for (state.modules.items) |module| {
        const path = module.path orelse continue;
        if (seen.contains(path)) continue;
        try paths.stringItem(path);
        try seen.put(path, {});
    }
    try paths.end();
    return try buffer.toOwnedSlice(allocator);
}

fn displayJson(allocator: std.mem.Allocator, fragment: *const render_html.Fragment, published_assets: *const assets.Set) ![]u8 {
    var buffer = std.ArrayList(u8).empty;
    errdefer buffer.deinit(allocator);
    var root = try json.Object.beginBuffer(allocator, &buffer);
    try root.intField("schema", 2);
    try root.stringField("html", fragment.html);
    try root.stringField("css", fragment.css);
    try root.boolField("has_pdf", fragment.assets.has_pdf);
    var asset_values = try root.arrayField("assets");
    for (published_assets.assets) |asset| {
        var value = try asset_values.objectItem();
        try value.stringField("kind", @tagName(asset.kind));
        const hex = std.fmt.bytesToHex(asset.resource_id, .lower);
        try value.stringField("resource_id", &hex);
        try value.stringField("relative_path", asset.relative_path);
        try value.stringField("path", asset.path);
        try value.end();
    }
    try asset_values.end();
    try root.end();
    return try buffer.toOwnedSlice(allocator);
}

fn outlineJson(allocator: std.mem.Allocator, state: *core.DocumentState) ![]u8 {
    var buffer = std.ArrayList(u8).empty;
    errdefer buffer.deinit(allocator);
    var items = try json.Array.beginBuffer(allocator, &buffer);
    var seen = std.AutoHashMap(core.NodeId, void).init(allocator);
    defer seen.deinit();
    for (state.page_order.items) |page_id| {
        const page = state.getNode(page_id) orelse continue;
        var page_item = try items.objectItem();
        try page_item.intField("id", page.id);
        try page_item.nullField("parent_id");
        try page_item.intField("page_id", page.id);
        try page_item.stringField("kind", "page");
        try page_item.stringField("label", page.name);
        try page_item.end();
        try seen.put(page.id, {});
        if (state.childrenOf(page_id)) |children| {
            for (children) |child_id| try appendOutlineNode(&items, state, &seen, page_id, page_id, child_id);
        }
    }
    try items.end();
    return try buffer.toOwnedSlice(allocator);
}

fn appendOutlineNode(
    items: *json.Array,
    state: *core.DocumentState,
    seen: *std.AutoHashMap(core.NodeId, void),
    page_id: core.NodeId,
    parent_id: core.NodeId,
    node_id: core.NodeId,
) !void {
    if (seen.contains(node_id)) return;
    const node = state.getNode(node_id) orelse return;
    if (node.kind != .object) return;
    try seen.put(node_id, {});
    var item = try items.objectItem();
    try item.intField("id", node.id);
    try item.intField("parent_id", parent_id);
    try item.intField("page_id", page_id);
    try item.stringField("kind", if (node.object_kind == .overlay) "group" else "object");
    try item.stringField("label", node.role orelse node.name);
    try item.optionalStringField("role", node.role);
    try item.end();
    if (state.childrenOf(node_id)) |children| {
        for (children) |child_id| try appendOutlineNode(items, state, seen, page_id, node_id, child_id);
    }
}

fn editingJson(allocator: std.mem.Allocator, state: *core.DocumentState) ![]u8 {
    var buffer = std.ArrayList(u8).empty;
    errdefer buffer.deinit(allocator);
    var items = try json.Array.beginBuffer(allocator, &buffer);
    var seen = std.AutoHashMap(core.NodeId, void).init(allocator);
    defer seen.deinit();
    const program = state.projectSyntax();
    for (program.pages.items) |*page_decl| {
        var names = try binding_names.Generator.init(allocator, state, page_decl);
        defer names.deinit();

        for (state.object_sources.items) |object_source| {
            if (object_source.module_id != state.project_module_id or seen.contains(object_source.node_id)) continue;
            if (state.parentPageOf(object_source.node_id) != object_source.page_id) continue;
            const statement = topLevelSourceStatement(page_decl, object_source) orelse continue;
            const page_index = pageOrderIndex(state.page_order.items, object_source.page_id) orelse continue;
            const node = state.getNode(object_source.node_id) orelse continue;
            if (node.kind != .object) continue;

            const binding_required = object_source.binding_base != null;
            const binding = if (object_source.binding_base) |base| blk: {
                const generated = try names.forStatement(statement.span.start, base);
                break :blk try std.fmt.allocPrint(allocator, "{s}{s}", .{ generated, object_source.path });
            } else try allocator.dupe(u8, object_source.path);
            defer allocator.free(binding);

            try seen.put(object_source.node_id, {});
            var item = try items.objectItem();
            try item.intField("node_id", node.id);
            try item.intField("page_id", object_source.page_id);
            try item.intField("page_index", page_index);
            try item.stringField("page_name", page_decl.name);
            try item.stringField("binding", binding);
            try item.boolField("binding_required", binding_required);
            try item.intField("statement_start", statement.span.start);
            try item.intField("statement_end", statement.span.end);
            try item.stringField("path", state.projectPath());
            try item.intField("page_start", page_decl.span.start);
            try item.intField("page_end", page_decl.span.end);
            try item.end();
        }
    }
    try items.end();
    return try buffer.toOwnedSlice(allocator);
}

fn topLevelSourceStatement(page: *const ast.PageDecl, object_source: core.ObjectSource) ?*const ast.Statement {
    for (page.statements.items) |*statement| {
        if (statement.span.start != object_source.span_start or statement.span.end != object_source.span_end) continue;
        if (object_source.binding_base != null) {
            if (statement.kind == .expr_stmt) return statement;
            return null;
        }
        const binding = switch (statement.kind) {
            .let_binding => |value| value,
            else => return null,
        };
        const base_end = std.mem.indexOfScalar(u8, object_source.path, '.') orelse object_source.path.len;
        if (std.mem.eql(u8, binding.name, object_source.path[0..base_end])) return statement;
        return null;
    }
    return null;
}

fn pageOrderIndex(page_order: []const core.NodeId, page_id: core.NodeId) ?usize {
    for (page_order, 0..) |candidate, index| {
        if (candidate == page_id) return index + 1;
    }
    return null;
}
