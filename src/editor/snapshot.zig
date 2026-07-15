const std = @import("std");
const ast = @import("ast");
const core = @import("core");
const render_scene = @import("render_scene");
const utils = @import("utils");

const json = utils.json;

pub fn toJson(
    allocator: std.mem.Allocator,
    ir: *core.Ir,
    scenes: *const render_scene.Document,
    generation: u64,
) ![]u8 {
    const layout_json = try core.layout.conflicts.toJson(allocator, ir);
    defer allocator.free(layout_json);
    const display_json = try displayJson(allocator, scenes);
    defer allocator.free(display_json);
    const outline_json = try outlineJson(allocator, ir);
    defer allocator.free(outline_json);
    const editing_json = try editingJson(allocator, ir);
    defer allocator.free(editing_json);
    const source_paths_json = try sourcePathsJson(allocator, ir);
    defer allocator.free(source_paths_json);

    var hasher = std.hash.Wyhash.init(generation);
    hasher.update(ir.projectPath());
    hasher.update(ir.projectSource());
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
    try json.appendString(allocator, &out, ir.projectPath());
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

fn sourcePathsJson(allocator: std.mem.Allocator, ir: *const core.Ir) ![]u8 {
    var buffer = std.ArrayList(u8).empty;
    errdefer buffer.deinit(allocator);
    var paths = try json.Array.beginBuffer(allocator, &buffer);
    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();
    try paths.stringItem(ir.projectPath());
    try seen.put(ir.projectPath(), {});
    for (ir.modules.items) |module| {
        const path = module.path orelse continue;
        if (seen.contains(path)) continue;
        try paths.stringItem(path);
        try seen.put(path, {});
    }
    try paths.end();
    return try buffer.toOwnedSlice(allocator);
}

fn displayJson(allocator: std.mem.Allocator, scenes: *const render_scene.Document) ![]u8 {
    var buffer = std.ArrayList(u8).empty;
    errdefer buffer.deinit(allocator);
    var root = try json.Object.beginBuffer(allocator, &buffer);
    try root.intField("schema", 1);
    var pages = try root.arrayField("pages");
    for (scenes.pages) |*page| {
        var page_object = try pages.objectItem();
        try page_object.intField("page_id", page.page_id);
        try page_object.intField("index", page.index + 1);
        try page_object.floatField("width", page.width, "{d:.4}");
        try page_object.floatField("height", page.height, "{d:.4}");
        var items = try page_object.arrayField("items");
        for (page.items.items) |item| try appendSceneItem(&items, item);
        try items.end();
        try page_object.end();
    }
    try pages.end();
    try root.end();
    return try buffer.toOwnedSlice(allocator);
}

fn appendSceneItem(items: *json.Array, item: render_scene.Item) !void {
    var object = try items.objectItem();
    try object.stringField("type", @tagName(item));
    try object.optionalIntField("node_id", item.nodeId());
    switch (item) {
        .fill_rect => |value| {
            try appendRect(&object, value.rect);
            try appendColor(&object, "color", value.color);
        },
        .stroke_line => |value| {
            try object.floatField("x1", value.start.x, "{d:.4}");
            try object.floatField("y1", value.start.y, "{d:.4}");
            try object.floatField("x2", value.end.x, "{d:.4}");
            try object.floatField("y2", value.end.y, "{d:.4}");
            try object.floatField("line_width", value.line_width, "{d:.4}");
            try object.floatField("dash_on", value.dash_on, "{d:.4}");
            try object.floatField("dash_off", value.dash_off, "{d:.4}");
            try appendColor(&object, "color", value.color);
        },
        .rounded_rect => |value| {
            try appendRect(&object, value.rect);
            try object.floatField("radius", value.radius, "{d:.4}");
            try object.floatField("line_width", value.line_width, "{d:.4}");
            try appendOptionalColor(&object, "fill", value.fill);
            try appendOptionalColor(&object, "stroke", value.stroke);
        },
        .text => |value| {
            try object.floatField("x", value.x, "{d:.4}");
            try object.floatField("baseline_y", value.baseline_y, "{d:.4}");
            try object.floatField("width", value.width, "{d:.4}");
            try object.stringField("text", value.text);
            try object.stringField("font_family", value.font_family);
            try object.intField("font_weight", value.font_weight);
            try object.enumTagField("font_style", value.font_style);
            try object.enumTagField("font_stretch", value.font_stretch);
            try object.floatField("font_size", value.font_size, "{d:.4}");
            try object.boolField("wrap", value.wrap);
            try object.boolField("preserve_color_glyphs", value.preserve_color_glyphs);
            try appendColor(&object, "color", value.color);
        },
        .raster => |value| {
            try appendRect(&object, value.rect);
            try object.stringField("path", value.path);
        },
        .svg => |value| {
            try appendRect(&object, value.rect);
            try object.stringField("path", value.path);
            try appendOptionalColor(&object, "tint", value.tint);
        },
        .pdf_page => |value| {
            try appendRect(&object, value.rect);
            try object.stringField("path", value.path);
            try object.intField("page_index", value.page_index);
            try object.enumTagField("box", value.box);
            try object.boolField("copy_annotations", value.copy_annotations);
        },
    }
    try object.end();
}

fn appendRect(object: *json.Object, rect: render_scene.Rect) !void {
    try object.floatField("x", rect.x, "{d:.4}");
    try object.floatField("y", rect.y, "{d:.4}");
    try object.floatField("width", rect.width, "{d:.4}");
    try object.floatField("height", rect.height, "{d:.4}");
}

fn appendColor(object: *json.Object, name: []const u8, color: core.render_policy.Color) !void {
    var value = try object.arrayField(name);
    try value.floatItem(color.r, "{d:.6}");
    try value.floatItem(color.g, "{d:.6}");
    try value.floatItem(color.b, "{d:.6}");
    try value.end();
}

fn appendOptionalColor(object: *json.Object, name: []const u8, color: ?core.render_policy.Color) !void {
    if (color) |value| return appendColor(object, name, value);
    try object.nullField(name);
}

fn outlineJson(allocator: std.mem.Allocator, ir: *core.Ir) ![]u8 {
    var buffer = std.ArrayList(u8).empty;
    errdefer buffer.deinit(allocator);
    var items = try json.Array.beginBuffer(allocator, &buffer);
    var seen = std.AutoHashMap(core.NodeId, void).init(allocator);
    defer seen.deinit();
    for (ir.page_order.items) |page_id| {
        const page = ir.getNode(page_id) orelse continue;
        var page_item = try items.objectItem();
        try page_item.intField("id", page.id);
        try page_item.nullField("parent_id");
        try page_item.intField("page_id", page.id);
        try page_item.stringField("kind", "page");
        try page_item.stringField("label", page.name);
        try page_item.end();
        try seen.put(page.id, {});
        if (ir.childrenOf(page_id)) |children| {
            for (children) |child_id| try appendOutlineNode(&items, ir, &seen, page_id, page_id, child_id);
        }
    }
    try items.end();
    return try buffer.toOwnedSlice(allocator);
}

fn appendOutlineNode(
    items: *json.Array,
    ir: *core.Ir,
    seen: *std.AutoHashMap(core.NodeId, void),
    page_id: core.NodeId,
    parent_id: core.NodeId,
    node_id: core.NodeId,
) !void {
    if (seen.contains(node_id)) return;
    const node = ir.getNode(node_id) orelse return;
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
    if (ir.childrenOf(node_id)) |children| {
        for (children) |child_id| try appendOutlineNode(items, ir, seen, page_id, node_id, child_id);
    }
}

fn editingJson(allocator: std.mem.Allocator, ir: *core.Ir) ![]u8 {
    var buffer = std.ArrayList(u8).empty;
    errdefer buffer.deinit(allocator);
    var items = try json.Array.beginBuffer(allocator, &buffer);
    var seen = std.AutoHashMap(core.NodeId, void).init(allocator);
    defer seen.deinit();
    const program = ir.projectProgram();
    for (ir.page_order.items, 0..) |page_id, page_offset| {
        if (page_offset >= program.pages.items.len) continue;
        const page_decl = program.pages.items[page_offset];
        if (ir.childrenOf(page_id)) |children| {
            for (children) |node_id| try appendEditingNode(&items, ir, &seen, page_id, page_offset + 1, page_decl, node_id);
        }
    }
    try items.end();
    return try buffer.toOwnedSlice(allocator);
}

fn appendEditingNode(
    items: *json.Array,
    ir: *core.Ir,
    seen: *std.AutoHashMap(core.NodeId, void),
    page_id: core.NodeId,
    page_index: usize,
    page_decl: anytype,
    node_id: core.NodeId,
) !void {
    if (seen.contains(node_id)) return;
    try seen.put(node_id, {});
    const node = ir.getNode(node_id) orelse return;
    if (editableBinding(ir, node, page_decl)) |binding| {
        var item = try items.objectItem();
        try item.intField("node_id", node.id);
        try item.intField("page_id", page_id);
        try item.intField("page_index", page_index);
        try item.stringField("page_name", page_decl.name);
        try item.stringField("binding", binding);
        try item.stringField("path", ir.projectPath());
        try item.intField("page_start", page_decl.span.start);
        try item.intField("page_end", page_decl.span.end);
        try item.end();
    }
    if (ir.childrenOf(node_id)) |children| {
        for (children) |child_id| try appendEditingNode(items, ir, seen, page_id, page_index, page_decl, child_id);
    }
}

fn editableBinding(ir: *core.Ir, node: *const core.Node, page: ast.PageDecl) ?[]const u8 {
    const origin_text = node.origin orelse return null;
    const located = utils.err.parseLocatedOrigin(origin_text) orelse return null;
    if (located.path) |path| {
        if (!std.mem.eql(u8, path, ir.projectPath())) return null;
    }
    if (located.span.start < page.span.start or located.span.end > page.span.end) return null;
    if (!constraintsEditableFromPage(ir, node.id, page.span)) return null;
    return bindingAtSpan(page.statements.items, located.span.start, located.span.end);
}

fn constraintsEditableFromPage(ir: *core.Ir, node_id: core.NodeId, page_span: anytype) bool {
    for (ir.constraints.items) |constraint| {
        if (constraint.target_node != node_id) continue;
        const origin = constraint.origin orelse return false;
        const located = utils.err.parseLocatedOrigin(origin) orelse return false;
        if (located.path) |path| {
            if (!std.mem.eql(u8, path, ir.projectPath())) return false;
        }
        if (located.span.start < page_span.start or located.span.end > page_span.end) return false;
    }
    return true;
}

fn bindingAtSpan(statements: []const ast.Statement, start: usize, end: usize) ?[]const u8 {
    for (statements) |statement| {
        if (statement.span.start == start and statement.span.end == end) {
            return switch (statement.kind) {
                .let_binding => |binding| binding.name,
                else => null,
            };
        }
        switch (statement.kind) {
            .if_stmt => |branch| {
                if (bindingAtSpan(branch.then_statements.items, start, end)) |binding| return binding;
                if (bindingAtSpan(branch.else_statements.items, start, end)) |binding| return binding;
            },
            else => {},
        }
    }
    return null;
}
