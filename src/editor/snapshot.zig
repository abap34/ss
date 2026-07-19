const std = @import("std");
const ast = @import("ast");
const core = @import("core");
const render = @import("render");
const render_html = @import("../render/html.zig");
const utils = @import("utils");

const json = utils.json;
const assets = @import("assets.zig");
const binding_names = @import("names.zig");

pub const EditingTarget = struct {
    node_id: core.NodeId,
    page_id: core.NodeId,
    page_index: usize,
    page_name: []u8,
    binding: []u8,
    binding_required: bool,
    statement: utils.source.ByteSpan,
    path: []u8,
    page: utils.source.ByteSpan,
};

pub const Model = struct {
    allocator: std.mem.Allocator,
    snapshot_id: []u8,
    editing: []EditingTarget,

    pub fn deinit(self: *Model) void {
        self.allocator.free(self.snapshot_id);
        deinitEditingTargets(self.allocator, self.editing);
        self.allocator.free(self.editing);
        self.* = .{ .allocator = self.allocator, .snapshot_id = &.{}, .editing = &.{} };
    }

    pub fn editingTarget(self: *const Model, node_id: core.NodeId) ?*const EditingTarget {
        for (self.editing) |*target| if (target.node_id == node_id) return target;
        return null;
    }

    pub fn bindingForNode(self: *const Model, node_id: core.NodeId) ?[]const u8 {
        const target = self.editingTarget(node_id) orelse return null;
        if (target.binding_required) return null;
        return target.binding;
    }
};

pub const Output = struct {
    json: []u8,
    model: Model,

    pub fn deinit(self: *Output) void {
        self.model.allocator.free(self.json);
        self.model.deinit();
        self.json = &.{};
    }
};

pub fn emptyJson(allocator: std.mem.Allocator) ![]u8 {
    return try allocator.dupe(u8,
        \\{"schema":1,"kind":"ss-editor-snapshot","snapshot_id":"","generation":0,"entry_path":"","source_paths":[],"coordinate_space":{"unit":"pt","origin":"page-top-left","x_axis":"right","y_axis":"down"},"layout":{"schema":1,"kind":"ss-layout-conflicts","entry_path":"","pages":[],"objects":[],"anchors":[],"relations":[],"failures":[]},"display":{"schema":2,"html":"","css":"","has_pdf":false,"assets":[]},"outline":[],"editing":[]}
        \\
    );
}

pub fn build(
    allocator: std.mem.Allocator,
    io: std.Io,
    state: *core.DocumentState,
    render_ir: *const render.Ir,
    generation: u64,
) !Output {
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
    const editing = try collectEditingTargets(allocator, state);
    errdefer {
        deinitEditingTargets(allocator, editing);
        allocator.free(editing);
    }
    const editing_json = try editingJson(allocator, editing);
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
    errdefer allocator.free(snapshot_id);

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
    return .{
        .json = try out.toOwnedSlice(allocator),
        .model = .{
            .allocator = allocator,
            .snapshot_id = snapshot_id,
            .editing = editing,
        },
    };
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
        const digest = std.fmt.bytesToHex(asset.digest, .lower);
        const digest_text = try std.fmt.allocPrint(allocator, "sha256:{s}", .{digest});
        defer allocator.free(digest_text);
        try value.stringField("digest", digest_text);
        try value.stringField("media_type", asset.media_type);
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

fn editingJson(allocator: std.mem.Allocator, editing: []const EditingTarget) ![]u8 {
    var buffer = std.ArrayList(u8).empty;
    errdefer buffer.deinit(allocator);
    var items = try json.Array.beginBuffer(allocator, &buffer);
    for (editing) |target| {
        var item = try items.objectItem();
        try item.intField("node_id", target.node_id);
        try item.intField("page_id", target.page_id);
        try item.intField("page_index", target.page_index);
        try item.stringField("page_name", target.page_name);
        try item.stringField("binding", target.binding);
        try item.boolField("binding_required", target.binding_required);
        try item.intField("statement_start", target.statement.start);
        try item.intField("statement_end", target.statement.end);
        try item.stringField("path", target.path);
        try item.intField("page_start", target.page.start);
        try item.intField("page_end", target.page.end);
        try item.end();
    }
    try items.end();
    return try buffer.toOwnedSlice(allocator);
}

fn collectEditingTargets(allocator: std.mem.Allocator, state: *core.DocumentState) ![]EditingTarget {
    var targets = std.ArrayList(EditingTarget).empty;
    errdefer {
        deinitEditingTargets(allocator, targets.items);
        targets.deinit(allocator);
    }
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
            try appendEditingTarget(allocator, &targets, .{
                .node_id = node.id,
                .page_id = object_source.page_id,
                .page_index = page_index,
                .page_name = page_decl.name,
                .binding = binding,
                .binding_required = binding_required,
                .statement = .{ .start = statement.span.start, .end = statement.span.end },
                .path = state.projectPath(),
                .page = .{ .start = page_decl.span.start, .end = page_decl.span.end },
            });
        }
    }
    return try targets.toOwnedSlice(allocator);
}

const EditingTargetView = struct {
    node_id: core.NodeId,
    page_id: core.NodeId,
    page_index: usize,
    page_name: []const u8,
    binding: []const u8,
    binding_required: bool,
    statement: utils.source.ByteSpan,
    path: []const u8,
    page: utils.source.ByteSpan,
};

fn appendEditingTarget(allocator: std.mem.Allocator, targets: *std.ArrayList(EditingTarget), view: EditingTargetView) !void {
    const page_name = try allocator.dupe(u8, view.page_name);
    errdefer allocator.free(page_name);
    const binding = try allocator.dupe(u8, view.binding);
    errdefer allocator.free(binding);
    const path = try allocator.dupe(u8, view.path);
    errdefer allocator.free(path);
    try targets.append(allocator, .{
        .node_id = view.node_id,
        .page_id = view.page_id,
        .page_index = view.page_index,
        .page_name = page_name,
        .binding = binding,
        .binding_required = view.binding_required,
        .statement = view.statement,
        .path = path,
        .page = view.page,
    });
}

fn deinitEditingTargets(allocator: std.mem.Allocator, targets: []const EditingTarget) void {
    for (targets) |target| {
        allocator.free(target.page_name);
        allocator.free(target.binding);
        allocator.free(target.path);
    }
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
