const std = @import("std");
const ast = @import("ast");
const core = @import("core");
const render = @import("render");
const render_html = @import("../render/html.zig");
const utils = @import("utils");

const json = utils.json;
const assets = @import("assets.zig");
const binding_names = @import("names.zig");

pub const Cache = struct {
    allocator: std.mem.Allocator,
    html: render_html.Cache,
    assets: assets.Cache,
    displays: std.AutoHashMap(render.Fingerprint, []u8),
    snapshot_displays: std.StringHashMap(render.Fingerprint),
    display_bytes: usize = 0,

    const max_displays = 4;
    const max_display_bytes = 64 * 1024 * 1024;
    const max_snapshot_displays = 16;

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Cache {
        return .{
            .allocator = allocator,
            .html = render_html.Cache.init(allocator),
            .assets = assets.Cache.init(allocator, io),
            .displays = std.AutoHashMap(render.Fingerprint, []u8).init(allocator),
            .snapshot_displays = std.StringHashMap(render.Fingerprint).init(allocator),
        };
    }

    pub fn deinit(self: *Cache) void {
        self.clearSnapshotDisplays();
        self.snapshot_displays.deinit();
        self.clearDisplays();
        self.displays.deinit();
        self.assets.deinit();
        self.html.deinit();
        self.* = undefined;
    }

    fn clearDisplays(self: *Cache) void {
        var values = self.displays.valueIterator();
        while (values.next()) |display| self.allocator.free(display.*);
        self.displays.clearRetainingCapacity();
        self.display_bytes = 0;
    }

    fn clearSnapshotDisplays(self: *Cache) void {
        var keys = self.snapshot_displays.keyIterator();
        while (keys.next()) |snapshot_id| self.allocator.free(snapshot_id.*);
        self.snapshot_displays.clearRetainingCapacity();
    }

    fn rememberDisplay(self: *Cache, snapshot_id: []const u8, fingerprint: render.Fingerprint) !void {
        if (self.snapshot_displays.getPtr(snapshot_id)) |stored| {
            stored.* = fingerprint;
            return;
        }
        if (self.snapshot_displays.count() >= max_snapshot_displays) self.clearSnapshotDisplays();
        const owned_snapshot_id = try self.allocator.dupe(u8, snapshot_id);
        errdefer self.allocator.free(owned_snapshot_id);
        try self.snapshot_displays.putNoClobber(owned_snapshot_id, fingerprint);
    }

    pub fn displayForSnapshot(self: *const Cache, snapshot_id: []const u8) ?render.Fingerprint {
        return self.snapshot_displays.get(snapshot_id);
    }
};

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

pub const PageEditingTarget = struct {
    page_id: core.NodeId,
    module_id: core.SourceModuleId,
    path: []u8,
    page: utils.source.ByteSpan,
    first_constraint_start: ?usize,
    rectangle_binding: []u8,
    circle_binding: []u8,
    arrow_binding: []u8,
    line_binding: []u8,
    icon_binding: []u8,
};

pub const ShapeKind = enum {
    rectangle,
    circle,
    arrow,
    line,
};

pub const ShapePoint = struct {
    x: f64,
    y: f64,
};

pub const ShapeFill = struct {
    enabled: bool,
    color: []u8,
    opacity: f64,
};

pub const ShapeStrokeStyle = enum {
    solid,
    dashed,
    dotted,
    dash_dot,
};

pub const ShapeStroke = struct {
    enabled: bool,
    color: []u8,
    width: f64,
    style: ShapeStrokeStyle,
};

pub const ShapeLineSource = struct {
    width_expression: utils.source.ByteSpan,
    height_expression: utils.source.ByteSpan,
    start_x_expression: utils.source.ByteSpan,
    start_y_expression: utils.source.ByteSpan,
    end_x_expression: utils.source.ByteSpan,
    end_y_expression: utils.source.ByteSpan,
};

pub const ShapeEditingTarget = struct {
    node_id: core.NodeId,
    page_id: core.NodeId,
    binding: []u8,
    kind: ShapeKind,
    path: []u8,
    fill_expression: ?utils.source.ByteSpan,
    stroke_expression: utils.source.ByteSpan,
    fill: ?ShapeFill,
    start: ?ShapePoint,
    end: ?ShapePoint,
    line_source: ?ShapeLineSource,
    stroke: ShapeStroke,
};

pub const Model = struct {
    allocator: std.mem.Allocator,
    snapshot_id: []u8,
    display_base_snapshot_id: ?[]u8 = null,
    display_fingerprint: ?render.Fingerprint = null,
    display_json_start: usize = 0,
    display_json_end: usize = 0,
    editing: []EditingTarget,
    page_editing: []PageEditingTarget,
    shape_editing: []ShapeEditingTarget,

    pub fn deinit(self: *Model) void {
        self.allocator.free(self.snapshot_id);
        if (self.display_base_snapshot_id) |value| self.allocator.free(value);
        deinitEditingTargets(self.allocator, self.editing);
        self.allocator.free(self.editing);
        deinitPageEditingTargets(self.allocator, self.page_editing);
        self.allocator.free(self.page_editing);
        deinitShapeEditingTargets(self.allocator, self.shape_editing);
        self.allocator.free(self.shape_editing);
        self.* = .{ .allocator = self.allocator, .snapshot_id = &.{}, .editing = &.{}, .page_editing = &.{}, .shape_editing = &.{} };
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

    pub fn pageEditingTarget(self: *const Model, page_id: core.NodeId) ?*const PageEditingTarget {
        for (self.page_editing) |*target| if (target.page_id == page_id) return target;
        return null;
    }

    pub fn shapeEditingTarget(self: *const Model, node_id: core.NodeId) ?*const ShapeEditingTarget {
        for (self.shape_editing) |*target| if (target.node_id == node_id) return target;
        return null;
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

pub const Translation = struct {
    node_id: core.NodeId,
    x: f32,
    y: f32,
};

pub fn emptyJson(allocator: std.mem.Allocator) ![]u8 {
    return try allocator.dupe(u8,
        \\{"schema":1,"kind":"ss-editor-snapshot","snapshot_id":"","generation":0,"entry_path":"","source_paths":[],"coordinate_space":{"unit":"pt","origin":"page-top-left","x_axis":"right","y_axis":"down"},"layout":{"schema":1,"kind":"ss-layout-conflicts","entry_path":"","pages":[],"objects":[],"relations":[],"failures":[]},"display":{"schema":2,"html":"","css":"","has_pdf":false,"assets":[]},"outline":[],"editing":[],"page_editing":[],"shape_editing":[]}
        \\
    );
}

pub fn build(
    allocator: std.mem.Allocator,
    io: std.Io,
    state: *core.DocumentState,
    render_ir: *const render.Ir,
    generation: u64,
    layout_json: []const u8,
    cache: *Cache,
) !Output {
    const display_key = render_ir.displayFingerprint();
    var fragment = try render_html.prepareFragment(allocator, render_ir, display_key, &cache.html);
    defer fragment.deinit(allocator);
    var published_assets = try assets.publish(allocator, io, &fragment, ".ss-cache/render", &cache.assets);
    defer published_assets.deinit(allocator);
    var uncached_display: ?[]u8 = null;
    defer if (uncached_display) |value| allocator.free(value);
    const display_json = cache.displays.get(display_key) orelse blk: {
        const generated = try displayJson(allocator, &fragment, &published_assets);
        errdefer allocator.free(generated);
        if (generated.len > Cache.max_display_bytes) {
            uncached_display = generated;
            break :blk generated;
        }
        if (cache.displays.count() >= Cache.max_displays or
            cache.display_bytes > Cache.max_display_bytes - generated.len)
        {
            cache.clearDisplays();
        }
        try cache.displays.putNoClobber(display_key, generated);
        cache.display_bytes += generated.len;
        break :blk generated;
    };
    var output = try buildFromDisplayJson(allocator, state, generation, display_json, null, display_key, layout_json);
    errdefer output.deinit();
    try cache.rememberDisplay(output.model.snapshot_id, display_key);
    return output;
}

pub fn buildTranslationPatch(
    allocator: std.mem.Allocator,
    state: *core.DocumentState,
    generation: u64,
    base_snapshot_id: []const u8,
    translations: []const Translation,
    layout_json: []const u8,
) !Output {
    const display_json = try translationPatchJson(allocator, base_snapshot_id, translations);
    defer allocator.free(display_json);
    return try buildFromDisplayJson(allocator, state, generation, display_json, base_snapshot_id, null, layout_json);
}

pub fn rebaseUnchangedDisplayJson(
    allocator: std.mem.Allocator,
    output: *const Output,
    base_snapshot_id: []const u8,
) ![]u8 {
    const patch = try translationPatchJson(allocator, base_snapshot_id, &.{});
    defer allocator.free(patch);
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);
    try result.ensureTotalCapacity(allocator, output.json.len -
        (output.model.display_json_end - output.model.display_json_start) + patch.len);
    try result.appendSlice(allocator, output.json[0..output.model.display_json_start]);
    try result.appendSlice(allocator, patch);
    try result.appendSlice(allocator, output.json[output.model.display_json_end..]);
    return try result.toOwnedSlice(allocator);
}

fn buildFromDisplayJson(
    allocator: std.mem.Allocator,
    state: *core.DocumentState,
    generation: u64,
    display_json: []const u8,
    display_base_snapshot_id: ?[]const u8,
    display_fingerprint: ?render.Fingerprint,
    layout_json: []const u8,
) !Output {
    const outline_json = try outlineJson(allocator, state);
    defer allocator.free(outline_json);
    const editing = try collectEditingTargets(allocator, state);
    errdefer {
        deinitEditingTargets(allocator, editing);
        allocator.free(editing);
    }
    const page_editing = try collectPageEditingTargets(allocator, state);
    errdefer {
        deinitPageEditingTargets(allocator, page_editing);
        allocator.free(page_editing);
    }
    const shape_editing = try collectShapeEditingTargets(allocator, state, editing);
    errdefer {
        deinitShapeEditingTargets(allocator, shape_editing);
        allocator.free(shape_editing);
    }
    const editing_json = try editingJson(allocator, editing);
    defer allocator.free(editing_json);
    const page_editing_json = try pageEditingJson(allocator, page_editing);
    defer allocator.free(page_editing_json);
    const shape_editing_json = try shapeEditingJson(allocator, shape_editing);
    defer allocator.free(shape_editing_json);
    const source_paths_json = try sourcePathsJson(allocator, state);
    defer allocator.free(source_paths_json);

    var hasher = std.hash.Wyhash.init(generation);
    hasher.update(state.projectPath());
    hasher.update(state.projectSource());
    hasher.update(layout_json);
    hasher.update(display_json);
    hasher.update(outline_json);
    hasher.update(editing_json);
    hasher.update(page_editing_json);
    hasher.update(shape_editing_json);
    hasher.update(source_paths_json);
    const snapshot_id = try std.fmt.allocPrint(allocator, "{d}-{x}", .{
        generation,
        hasher.final(),
    });
    errdefer allocator.free(snapshot_id);
    const owned_display_base_snapshot_id = if (display_base_snapshot_id) |value| try allocator.dupe(u8, value) else null;
    errdefer if (owned_display_base_snapshot_id) |value| allocator.free(value);

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
    const display_json_start = out.items.len;
    try out.appendSlice(allocator, display_json);
    const display_json_end = out.items.len;
    try out.appendSlice(allocator, ",\"outline\":");
    try out.appendSlice(allocator, outline_json);
    try out.appendSlice(allocator, ",\"editing\":");
    try out.appendSlice(allocator, editing_json);
    try out.appendSlice(allocator, ",\"page_editing\":");
    try out.appendSlice(allocator, page_editing_json);
    try out.appendSlice(allocator, ",\"shape_editing\":");
    try out.appendSlice(allocator, shape_editing_json);
    try out.appendSlice(allocator, "}\n");
    return .{
        .json = try out.toOwnedSlice(allocator),
        .model = .{
            .allocator = allocator,
            .snapshot_id = snapshot_id,
            .display_base_snapshot_id = owned_display_base_snapshot_id,
            .display_fingerprint = display_fingerprint,
            .display_json_start = display_json_start,
            .display_json_end = display_json_end,
            .editing = editing,
            .page_editing = page_editing,
            .shape_editing = shape_editing,
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

fn translationPatchJson(allocator: std.mem.Allocator, base_snapshot_id: []const u8, translations: []const Translation) ![]u8 {
    var buffer = std.ArrayList(u8).empty;
    errdefer buffer.deinit(allocator);
    var root = try json.Object.beginBuffer(allocator, &buffer);
    try root.intField("schema", 3);
    try root.stringField("kind", "translation_patch");
    try root.stringField("base_snapshot_id", base_snapshot_id);
    var values = try root.arrayField("translations");
    for (translations) |translation| {
        var value = try values.objectItem();
        try value.intField("node_id", translation.node_id);
        try value.floatField("x", translation.x, "{d:.4}");
        try value.floatField("y", translation.y, "{d:.4}");
        try value.end();
    }
    try values.end();
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

fn pageEditingJson(allocator: std.mem.Allocator, targets: []const PageEditingTarget) ![]u8 {
    var buffer = std.ArrayList(u8).empty;
    errdefer buffer.deinit(allocator);
    var items = try json.Array.beginBuffer(allocator, &buffer);
    for (targets) |target| {
        var item = try items.objectItem();
        try item.intField("page_id", target.page_id);
        try item.boolField("insert_shapes", true);
        try item.boolField("insert_icons", true);
        try item.end();
    }
    try items.end();
    return try buffer.toOwnedSlice(allocator);
}

fn shapeEditingJson(allocator: std.mem.Allocator, targets: []const ShapeEditingTarget) ![]u8 {
    var buffer = std.ArrayList(u8).empty;
    errdefer buffer.deinit(allocator);
    var items = try json.Array.beginBuffer(allocator, &buffer);
    for (targets) |target| {
        var item = try items.objectItem();
        try item.intField("node_id", target.node_id);
        try item.intField("page_id", target.page_id);
        try item.stringField("binding", target.binding);
        try item.stringField("kind", @tagName(target.kind));
        if (target.fill) |fill_value| {
            var fill = try item.objectField("fill");
            try fill.boolField("enabled", fill_value.enabled);
            try fill.stringField("color", fill_value.color);
            try fill.floatField("opacity", fill_value.opacity, "{d:.4}");
            try fill.end();
        }
        if (target.start) |start_value| {
            var start = try item.objectField("start");
            try start.floatField("x", start_value.x, "{d:.6}");
            try start.floatField("y", start_value.y, "{d:.6}");
            try start.end();
        }
        if (target.end) |end_value| {
            var end = try item.objectField("end");
            try end.floatField("x", end_value.x, "{d:.6}");
            try end.floatField("y", end_value.y, "{d:.6}");
            try end.end();
        }
        var stroke = try item.objectField("stroke");
        try stroke.boolField("enabled", target.stroke.enabled);
        try stroke.stringField("color", target.stroke.color);
        try stroke.floatField("width", target.stroke.width, "{d:.4}");
        try stroke.stringField("style", @tagName(target.stroke.style));
        try stroke.end();
        try item.end();
    }
    try items.end();
    return try buffer.toOwnedSlice(allocator);
}

fn collectShapeEditingTargets(
    allocator: std.mem.Allocator,
    state: *const core.DocumentState,
    editing: []const EditingTarget,
) ![]ShapeEditingTarget {
    var targets = std.ArrayList(ShapeEditingTarget).empty;
    errdefer {
        deinitShapeEditingTargets(allocator, targets.items);
        targets.deinit(allocator);
    }
    for (editing) |editing_target| {
        if (editing_target.binding_required or std.mem.indexOfScalar(u8, editing_target.binding, '.') != null) continue;
        const module = moduleForPath(state, editing_target.path) orelse continue;
        const page = pageForSpan(module, editing_target.page) orelse continue;
        const binding_statement = statementForSpan(page, editing_target.statement) orelse continue;
        const constructor = shapeConstructor(binding_statement, editing_target.binding) orelse continue;
        var fill_expression: ?utils.source.ByteSpan = null;
        var fill: ?ShapeFill = null;
        var start: ?ShapePoint = null;
        var end: ?ShapePoint = null;
        var line_source: ?ShapeLineSource = null;
        if (constructor.kind == .line) {
            const start_x = shapeRecordField(module.source, constructor.style, constructor.style_span, "start_x") orelse continue;
            const start_y = shapeRecordField(module.source, constructor.style, constructor.style_span, "start_y") orelse continue;
            const end_x = shapeRecordField(module.source, constructor.style, constructor.style_span, "end_x") orelse continue;
            const end_y = shapeRecordField(module.source, constructor.style, constructor.style_span, "end_y") orelse continue;
            start = .{
                .x = shapeNumber(start_x.value) orelse continue,
                .y = shapeNumber(start_y.value) orelse continue,
            };
            end = .{
                .x = shapeNumber(end_x.value) orelse continue,
                .y = shapeNumber(end_y.value) orelse continue,
            };
            line_source = .{
                .width_expression = constructor.width_expression orelse continue,
                .height_expression = constructor.height_expression orelse continue,
                .start_x_expression = start_x.expression,
                .start_y_expression = start_y.expression,
                .end_x_expression = end_x.expression,
                .end_y_expression = end_y.expression,
            };
        } else {
            const fill_field = shapeRecordField(module.source, constructor.style, constructor.style_span, "fill") orelse continue;
            fill = (try shapeFill(allocator, fill_field.value)) orelse continue;
            fill_expression = fill_field.expression;
        }
        errdefer if (fill) |value| allocator.free(value.color);
        const stroke_field = shapeRecordField(module.source, constructor.style, constructor.style_span, "stroke") orelse {
            if (fill) |value| allocator.free(value.color);
            continue;
        };
        const stroke = (try shapeStroke(allocator, stroke_field.value)) orelse {
            if (fill) |value| allocator.free(value.color);
            continue;
        };
        errdefer allocator.free(stroke.color);
        const binding = try allocator.dupe(u8, editing_target.binding);
        errdefer allocator.free(binding);
        const path = try allocator.dupe(u8, editing_target.path);
        errdefer allocator.free(path);
        try targets.append(allocator, .{
            .node_id = editing_target.node_id,
            .page_id = editing_target.page_id,
            .binding = binding,
            .kind = constructor.kind,
            .path = path,
            .fill_expression = fill_expression,
            .stroke_expression = stroke_field.expression,
            .fill = fill,
            .start = start,
            .end = end,
            .line_source = line_source,
            .stroke = stroke,
        });
    }
    return try targets.toOwnedSlice(allocator);
}

const ShapeConstructor = struct {
    kind: ShapeKind,
    style: *const ast.RecordExpr,
    style_span: ast.Span,
    width_expression: ?utils.source.ByteSpan,
    height_expression: ?utils.source.ByteSpan,
};

const ShapeRecordField = struct {
    expression: utils.source.ByteSpan,
    value: ast.Expr,
};

fn shapeConstructor(statement: *const ast.Statement, binding: []const u8) ?ShapeConstructor {
    const let_binding = switch (statement.kind) {
        .let_binding => |*value| value,
        else => return null,
    };
    if (!std.mem.eql(u8, let_binding.name, binding)) return null;
    const call = switch (let_binding.expr) {
        .call => |*value| value,
        else => return null,
    };
    if (call.callee.qualifier != null) return null;
    const kind: ShapeKind = if (std.mem.eql(u8, call.callee.name, "rectangle!"))
        .rectangle
    else if (std.mem.eql(u8, call.callee.name, "circle!"))
        .circle
    else if (std.mem.eql(u8, call.callee.name, "arrow_shape!"))
        .arrow
    else if (std.mem.eql(u8, call.callee.name, "line!"))
        .line
    else
        return null;
    const style_index: usize = if (kind == .circle) 1 else 2;
    if (call.args.items.len != style_index + 1 or call.arg_spans.items.len <= style_index) return null;
    const style = switch (call.args.items[style_index]) {
        .record => |*value| value,
        else => return null,
    };
    const style_name = if (kind == .line) "LineStyle" else "VectorStyle";
    if (!std.mem.eql(u8, style.type_name, style_name)) return null;
    return .{
        .kind = kind,
        .style = style,
        .style_span = call.arg_spans.items[style_index],
        .width_expression = if (kind == .line) .{
            .start = call.arg_spans.items[0].start,
            .end = call.arg_spans.items[0].end,
        } else null,
        .height_expression = if (kind == .line) .{
            .start = call.arg_spans.items[1].start,
            .end = call.arg_spans.items[1].end,
        } else null,
    };
}

fn shapeNumber(expr: ast.Expr) ?f64 {
    const value = switch (expr) {
        .number => |number| number,
        else => return null,
    };
    return if (std.math.isFinite(value)) value else null;
}

fn shapeRecordField(
    source: []const u8,
    record: *const ast.RecordExpr,
    record_span: ast.Span,
    name: []const u8,
) ?ShapeRecordField {
    if (record_span.end > source.len) return null;
    for (record.fields.items, 0..) |*field, index| {
        if (!std.mem.eql(u8, field.name, name)) continue;
        const name_span = field.name_span orelse return null;
        const equals = std.mem.indexOfScalarPos(u8, source, name_span.end, '=') orelse return null;
        if (equals >= record_span.end) return null;
        var start = equals + 1;
        while (start < record_span.end and (source[start] == ' ' or source[start] == '\t' or source[start] == '\r' or source[start] == '\n')) start += 1;
        var end = if (index + 1 < record.fields.items.len)
            (record.fields.items[index + 1].name_span orelse return null).start
        else
            recordClosingBrace(source, record_span) orelse return null;
        while (end > start and (source[end - 1] == ' ' or source[end - 1] == '\t' or source[end - 1] == '\r' or source[end - 1] == '\n' or source[end - 1] == ',')) end -= 1;
        if (start >= end) return null;
        return .{ .expression = .{ .start = start, .end = end }, .value = field.value };
    }
    return null;
}

fn recordClosingBrace(source: []const u8, span: ast.Span) ?usize {
    var cursor = @min(span.end, source.len);
    while (cursor > span.start) {
        cursor -= 1;
        if (source[cursor] == '}') return cursor;
    }
    return null;
}

fn shapeFill(allocator: std.mem.Allocator, expr: ast.Expr) !?ShapeFill {
    const call = switch (expr) {
        .call => |value| value,
        else => return null,
    };
    if (call.callee.qualifier != null) return null;
    if (std.mem.eql(u8, call.callee.name, "no_fill")) {
        if (call.args.items.len != 0) return null;
        return .{ .enabled = false, .color = try allocator.dupe(u8, "#e8f1ff"), .opacity = 1 };
    }
    if (!std.mem.eql(u8, call.callee.name, "solid_fill") or call.args.items.len != 2) return null;
    const opacity = switch (call.args.items[1]) {
        .number => |value| value,
        else => return null,
    };
    if (!std.math.isFinite(opacity) or opacity < 0 or opacity > 1) return null;
    const color = switch (call.args.items[0]) {
        .color => |value| (try colorHex(allocator, value)) orelse return null,
        else => return null,
    };
    return .{ .enabled = true, .color = color, .opacity = opacity };
}

fn shapeStroke(allocator: std.mem.Allocator, expr: ast.Expr) !?ShapeStroke {
    const call = switch (expr) {
        .call => |value| value,
        else => return null,
    };
    if (call.callee.qualifier != null) return null;
    if (std.mem.eql(u8, call.callee.name, "no_stroke")) {
        if (call.args.items.len != 0) return null;
        return .{ .enabled = false, .color = try allocator.dupe(u8, "#2563eb"), .width = 1.6, .style = .solid };
    }
    const style: ShapeStrokeStyle = if (std.mem.eql(u8, call.callee.name, "solid_stroke"))
        .solid
    else if (std.mem.eql(u8, call.callee.name, "dashed_stroke"))
        .dashed
    else if (std.mem.eql(u8, call.callee.name, "dotted_stroke"))
        .dotted
    else if (std.mem.eql(u8, call.callee.name, "dash_dot_stroke"))
        .dash_dot
    else
        return null;
    if (call.args.items.len != 2) return null;
    const width = switch (call.args.items[1]) {
        .number => |value| value,
        else => return null,
    };
    if (!std.math.isFinite(width) or width <= 0) return null;
    const color = switch (call.args.items[0]) {
        .color => |value| (try colorHex(allocator, value)) orelse return null,
        else => return null,
    };
    return .{ .enabled = true, .color = color, .width = width, .style = style };
}

fn colorHex(allocator: std.mem.Allocator, text: []const u8) !?[]u8 {
    const rgb = utils.color.parse(text) orelse return null;
    const red: u8 = @intFromFloat(@round(std.math.clamp(rgb.r, 0, 1) * 255));
    const green: u8 = @intFromFloat(@round(std.math.clamp(rgb.g, 0, 1) * 255));
    const blue: u8 = @intFromFloat(@round(std.math.clamp(rgb.b, 0, 1) * 255));
    const digits = "0123456789abcdef";
    const result = try allocator.alloc(u8, 7);
    result[0] = '#';
    result[1] = digits[red >> 4];
    result[2] = digits[red & 0x0f];
    result[3] = digits[green >> 4];
    result[4] = digits[green & 0x0f];
    result[5] = digits[blue >> 4];
    result[6] = digits[blue & 0x0f];
    return result;
}

fn moduleForPath(state: *const core.DocumentState, path: []const u8) ?*const core.SourceModule {
    for (state.modules.items) |*module| {
        const module_path = module.path orelse continue;
        if (std.mem.eql(u8, module_path, path)) return module;
    }
    return null;
}

fn pageForSpan(module: *const core.SourceModule, span: utils.source.ByteSpan) ?*const ast.PageDecl {
    for (module.syntax.pages.items) |*page| {
        if (page.span.start == span.start and page.span.end == span.end) return page;
    }
    return null;
}

fn statementForSpan(page: *const ast.PageDecl, span: utils.source.ByteSpan) ?*const ast.Statement {
    for (page.statements.items) |*statement| {
        if (statement.span.start == span.start and statement.span.end == span.end) return statement;
    }
    return null;
}

fn collectPageEditingTargets(allocator: std.mem.Allocator, state: *const core.DocumentState) ![]PageEditingTarget {
    var targets = std.ArrayList(PageEditingTarget).empty;
    errdefer {
        deinitPageEditingTargets(allocator, targets.items);
        targets.deinit(allocator);
    }
    for (state.page_sources.items) |page_source| {
        const module = state.moduleById(page_source.module_id) orelse continue;
        if (module.path == null) continue;
        const page_decl = sourcePage(module, page_source) orelse continue;
        var names = try binding_names.Generator.initForModule(allocator, state, module.id, page_decl);
        defer names.deinit();
        try appendPageEditingTarget(allocator, &targets, .{
            .page_id = page_source.page_id,
            .module_id = page_source.module_id,
            .path = page_source.path,
            .page = .{ .start = page_source.span_start, .end = page_source.span_end },
            .first_constraint_start = firstConstraintStart(page_decl),
            .rectangle_binding = try names.forStatement(0, "rectangle"),
            .circle_binding = try names.forStatement(1, "circle"),
            .arrow_binding = try names.forStatement(2, "arrow_shape"),
            .line_binding = try names.forStatement(3, "line"),
            .icon_binding = try names.forStatement(4, "icon"),
        });
    }
    return try targets.toOwnedSlice(allocator);
}

fn collectEditingTargets(allocator: std.mem.Allocator, state: *core.DocumentState) ![]EditingTarget {
    var targets = std.ArrayList(EditingTarget).empty;
    errdefer {
        deinitEditingTargets(allocator, targets.items);
        targets.deinit(allocator);
    }
    var seen = std.AutoHashMap(core.NodeId, void).init(allocator);
    defer seen.deinit();
    for (state.page_sources.items) |page_source| {
        const module = state.moduleById(page_source.module_id) orelse continue;
        if (module.path == null) continue;
        const page_decl = sourcePage(module, page_source) orelse continue;
        var names = try binding_names.Generator.initForModule(allocator, state, module.id, page_decl);
        defer names.deinit();

        for (state.object_sources.items) |object_source| {
            if (object_source.module_id != module.id or object_source.page_id != page_source.page_id or seen.contains(object_source.node_id)) continue;
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
                .path = page_source.path,
                .page = .{ .start = page_decl.span.start, .end = page_decl.span.end },
            });
        }
    }
    return try targets.toOwnedSlice(allocator);
}

const PageEditingTargetView = struct {
    page_id: core.NodeId,
    module_id: core.SourceModuleId,
    path: []const u8,
    page: utils.source.ByteSpan,
    first_constraint_start: ?usize,
    rectangle_binding: []const u8,
    circle_binding: []const u8,
    arrow_binding: []const u8,
    line_binding: []const u8,
    icon_binding: []const u8,
};

fn appendPageEditingTarget(allocator: std.mem.Allocator, targets: *std.ArrayList(PageEditingTarget), view: PageEditingTargetView) !void {
    const path = try allocator.dupe(u8, view.path);
    errdefer allocator.free(path);
    const rectangle_binding = try allocator.dupe(u8, view.rectangle_binding);
    errdefer allocator.free(rectangle_binding);
    const circle_binding = try allocator.dupe(u8, view.circle_binding);
    errdefer allocator.free(circle_binding);
    const arrow_binding = try allocator.dupe(u8, view.arrow_binding);
    errdefer allocator.free(arrow_binding);
    const line_binding = try allocator.dupe(u8, view.line_binding);
    errdefer allocator.free(line_binding);
    const icon_binding = try allocator.dupe(u8, view.icon_binding);
    errdefer allocator.free(icon_binding);
    try targets.append(allocator, .{
        .page_id = view.page_id,
        .module_id = view.module_id,
        .path = path,
        .page = view.page,
        .first_constraint_start = view.first_constraint_start,
        .rectangle_binding = rectangle_binding,
        .circle_binding = circle_binding,
        .arrow_binding = arrow_binding,
        .line_binding = line_binding,
        .icon_binding = icon_binding,
    });
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

fn deinitPageEditingTargets(allocator: std.mem.Allocator, targets: []const PageEditingTarget) void {
    for (targets) |target| {
        allocator.free(target.path);
        allocator.free(target.rectangle_binding);
        allocator.free(target.circle_binding);
        allocator.free(target.arrow_binding);
        allocator.free(target.line_binding);
        allocator.free(target.icon_binding);
    }
}

fn deinitShapeEditingTargets(allocator: std.mem.Allocator, targets: []const ShapeEditingTarget) void {
    for (targets) |target| {
        allocator.free(target.binding);
        allocator.free(target.path);
        if (target.fill) |fill| allocator.free(fill.color);
        allocator.free(target.stroke.color);
    }
}

fn sourcePage(module: *const core.SourceModule, page_source: core.PageSource) ?*const ast.PageDecl {
    for (module.syntax.pages.items) |*page| {
        if (page.span.start == page_source.span_start and page.span.end == page_source.span_end) return page;
    }
    return null;
}

fn firstConstraintStart(page: *const ast.PageDecl) ?usize {
    for (page.statements.items) |statement| switch (statement.kind) {
        .constrain => return statement.span.start,
        else => {},
    };
    return null;
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
