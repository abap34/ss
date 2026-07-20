const std = @import("std");
const core = @import("core");

const editor_edit = @import("../../editor/edit.zig");
const shape_edit = editor_edit.shape;
const protocol = @import("../protocol.zig");
const lsp_state = @import("../state.zig");
const utils = @import("utils");

pub const Context = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    documents: *lsp_state.DocumentStore,
    active_editor_paths: *const std.StringHashMap(void),
    provider: *lsp_state.AnalysisProvider,
};

pub fn insertResult(ctx: *Context, params: ?protocol.JsonValue) ![]const u8 {
    const request = params orelse return try statusJson(ctx.allocator, "unsupported", "Missing shape insertion request.");
    if (request != .object) return try statusJson(ctx.allocator, "unsupported", "Invalid shape insertion request.");
    const request_object = &request.object;
    const doc_path = try protocol.docPathFromParams(ctx.allocator, params) orelse
        return try statusJson(ctx.allocator, "unsupported", "Missing source document.");
    defer ctx.allocator.free(doc_path);
    if (!ctx.active_editor_paths.contains(doc_path)) {
        return try statusJson(ctx.allocator, "unsupported", "The WYSIWYG editor is not active for this document.");
    }

    var owned_snapshot: ?lsp_state.AnalysisSnapshot = null;
    defer if (owned_snapshot) |*snapshot| snapshot.deinit();
    const snapshot = try ctx.provider.forDocument(doc_path, &owned_snapshot) orelse
        return try statusJson(ctx.allocator, "unsupported", "No compiler snapshot is available.");
    const layout = if (snapshot.layout_output) |*value| value else return try statusJson(ctx.allocator, "unsupported", "No solved layout is available.");
    const editor = if (layout.editor) |*value| value else return try statusJson(ctx.allocator, "unsupported", "The WYSIWYG editor is not active.");
    const requested_id = protocol.stringField(request_object, "snapshotId") orelse "";
    if (requested_id.len == 0 or !std.mem.eql(u8, editor.model.snapshot_id, requested_id) or snapshot.generation != ctx.documents.generation) {
        return try statusJson(ctx.allocator, "stale", "The document changed before the shape was inserted.");
    }

    const requested_page_id = protocol.intField(request_object, "pageId") orelse -1;
    if (requested_page_id < 0 or requested_page_id > std.math.maxInt(u32)) {
        return try statusJson(ctx.allocator, "unsupported", "Missing target page.");
    }
    const page_id: u32 = @intCast(requested_page_id);
    const target = editor.model.pageEditingTarget(page_id) orelse
        return try statusJson(ctx.allocator, "unsupported", "This page does not support shape insertion.");
    const page = pageForId(layout.report.pages, page_id) orelse
        return try statusJson(ctx.allocator, "stale", "The target page no longer exists.");

    const kind_text = protocol.stringField(request_object, "kind") orelse "";
    const kind = parseKind(kind_text) orelse
        return try statusJson(ctx.allocator, "unsupported", "Unknown shape kind.");
    const bounds_object = protocol.objectFieldObject(request_object, "bounds") orelse
        return try statusJson(ctx.allocator, "rejected", "Missing shape bounds.");
    const bounds = parseBounds(bounds_object) orelse
        return try statusJson(ctx.allocator, "rejected", "Invalid shape bounds.");
    if (!validBounds(bounds, page.width, page.height, kind)) {
        return try statusJson(ctx.allocator, "rejected", "Shape bounds must be finite, positive, and inside the page.");
    }
    const fill = parseFill(request_object) orelse
        return try statusJson(ctx.allocator, "rejected", "Invalid fill style.");
    const stroke = parseStroke(request_object) orelse
        return try statusJson(ctx.allocator, "rejected", "Invalid stroke style.");
    if (!fill.enabled and !stroke.enabled) {
        return try statusJson(ctx.allocator, "rejected", "A shape must have a fill or a stroke.");
    }

    var owned_source: ?[]u8 = null;
    defer if (owned_source) |source| ctx.allocator.free(source);
    const source = ctx.documents.sourceForPath(target.path) orelse blk: {
        owned_source = utils.fs.readFileAlloc(ctx.io, ctx.allocator, target.path) catch
            return try statusJson(ctx.allocator, "unsupported", "The target source document is unavailable.");
        const module = snapshot.moduleById(target.module_id) orelse
            return try statusJson(ctx.allocator, "stale", "The target source module changed.");
        if (!std.mem.eql(u8, owned_source.?, module.source)) {
            return try statusJson(ctx.allocator, "stale", "The target source document changed on disk.");
        }
        break :blk owned_source.?;
    };
    const binding = switch (kind) {
        .rectangle => target.rectangle_binding,
        .circle => target.circle_binding,
        .arrow => target.arrow_binding,
    };
    var result = (try shape_edit.insert(
        ctx.allocator,
        source,
        target.page,
        target.first_constraint_start,
        binding,
        kind,
        bounds,
        fill,
        stroke,
    )) orelse return try statusJson(ctx.allocator, "unsupported", "The page insertion point could not be located.");
    defer result.deinit(ctx.allocator);

    const uri = try protocol.uriFromPath(ctx.allocator, target.path);
    defer ctx.allocator.free(uri);
    return try insertionStatusJson(ctx.allocator, uri, source, result.edits, target.path, page_id, binding);
}

pub fn styleResult(ctx: *Context, params: ?protocol.JsonValue) ![]const u8 {
    const request = params orelse return try statusJson(ctx.allocator, "unsupported", "Missing shape style request.");
    if (request != .object) return try statusJson(ctx.allocator, "unsupported", "Invalid shape style request.");
    const request_object = &request.object;
    const doc_path = try protocol.docPathFromParams(ctx.allocator, params) orelse
        return try statusJson(ctx.allocator, "unsupported", "Missing source document.");
    defer ctx.allocator.free(doc_path);
    if (!ctx.active_editor_paths.contains(doc_path)) {
        return try statusJson(ctx.allocator, "unsupported", "The WYSIWYG editor is not active for this document.");
    }

    var owned_snapshot: ?lsp_state.AnalysisSnapshot = null;
    defer if (owned_snapshot) |*snapshot| snapshot.deinit();
    const snapshot = try ctx.provider.forDocument(doc_path, &owned_snapshot) orelse
        return try statusJson(ctx.allocator, "unsupported", "No compiler snapshot is available.");
    const layout = if (snapshot.layout_output) |*value| value else return try statusJson(ctx.allocator, "unsupported", "No solved layout is available.");
    const editor = if (layout.editor) |*value| value else return try statusJson(ctx.allocator, "unsupported", "The WYSIWYG editor is not active.");
    const requested_id = protocol.stringField(request_object, "snapshotId") orelse "";
    if (requested_id.len == 0 or !std.mem.eql(u8, editor.model.snapshot_id, requested_id) or snapshot.generation != ctx.documents.generation) {
        return try statusJson(ctx.allocator, "stale", "The document changed before the shape style was edited.");
    }

    const requested_node_id = protocol.intField(request_object, "nodeId") orelse -1;
    if (requested_node_id < 0 or requested_node_id > std.math.maxInt(u32)) {
        return try statusJson(ctx.allocator, "unsupported", "Missing target shape.");
    }
    const target = editor.model.shapeEditingTarget(@intCast(requested_node_id)) orelse
        return try statusJson(ctx.allocator, "unsupported", "This shape does not have an editable standard style.");
    const requested_page_id = protocol.intField(request_object, "pageId") orelse -1;
    if (requested_page_id != target.page_id) {
        return try statusJson(ctx.allocator, "stale", "The selected shape no longer belongs to this page.");
    }
    const fill = parseFill(request_object) orelse
        return try statusJson(ctx.allocator, "rejected", "Invalid fill style.");
    const stroke = parseStroke(request_object) orelse
        return try statusJson(ctx.allocator, "rejected", "Invalid stroke style.");
    if (!fill.enabled and !stroke.enabled) {
        return try statusJson(ctx.allocator, "rejected", "A shape must have a fill or a stroke.");
    }

    var owned_source: ?[]u8 = null;
    defer if (owned_source) |source| ctx.allocator.free(source);
    const source = ctx.documents.sourceForPath(target.path) orelse blk: {
        owned_source = utils.fs.readFileAlloc(ctx.io, ctx.allocator, target.path) catch
            return try statusJson(ctx.allocator, "unsupported", "The target source document is unavailable.");
        const module = snapshot.moduleForPath(target.path) orelse
            return try statusJson(ctx.allocator, "stale", "The target source module changed.");
        if (!std.mem.eql(u8, owned_source.?, module.source)) {
            return try statusJson(ctx.allocator, "stale", "The target source document changed on disk.");
        }
        break :blk owned_source.?;
    };

    const fill_text = try shape_edit.fillExpression(ctx.allocator, fill);
    errdefer ctx.allocator.free(fill_text);
    const stroke_text = try shape_edit.strokeExpression(ctx.allocator, stroke);
    errdefer ctx.allocator.free(stroke_text);
    const edits = try ctx.allocator.alloc(editor_edit.TextEdit, 2);
    edits[0] = .{
        .start = target.fill_expression.start,
        .end = target.fill_expression.end,
        .text = fill_text,
    };
    edits[1] = .{
        .start = target.stroke_expression.start,
        .end = target.stroke_expression.end,
        .text = stroke_text,
    };
    var result = editor_edit.Result{ .edits = edits };
    defer result.deinit(ctx.allocator);
    const uri = try protocol.uriFromPath(ctx.allocator, target.path);
    defer ctx.allocator.free(uri);
    return try insertionStatusJson(ctx.allocator, uri, source, result.edits, target.path, target.page_id, target.binding);
}

fn parseKind(text: []const u8) ?shape_edit.Kind {
    if (std.mem.eql(u8, text, "rectangle")) return .rectangle;
    if (std.mem.eql(u8, text, "circle")) return .circle;
    if (std.mem.eql(u8, text, "arrow")) return .arrow;
    return null;
}

fn parseBounds(object: *const protocol.JsonObject) ?shape_edit.Bounds {
    return .{
        .x = protocol.numberField(object, "x") orelse return null,
        .y = protocol.numberField(object, "y") orelse return null,
        .width = protocol.numberField(object, "width") orelse return null,
        .height = protocol.numberField(object, "height") orelse return null,
    };
}

fn parseFill(request: *const protocol.JsonObject) ?shape_edit.Fill {
    const object = protocol.objectFieldObject(request, "fill") orelse return null;
    const enabled = protocol.boolField(object, "enabled") orelse return null;
    const color = protocol.stringField(object, "color") orelse return null;
    const opacity = protocol.numberField(object, "opacity") orelse return null;
    if (!validColor(color) or !std.math.isFinite(opacity) or opacity < 0 or opacity > 1) return null;
    return .{ .enabled = enabled, .color = color, .opacity = opacity };
}

fn parseStroke(request: *const protocol.JsonObject) ?shape_edit.Stroke {
    const object = protocol.objectFieldObject(request, "stroke") orelse return null;
    const enabled = protocol.boolField(object, "enabled") orelse return null;
    const color = protocol.stringField(object, "color") orelse return null;
    const width = protocol.numberField(object, "width") orelse return null;
    const style_text = protocol.stringField(object, "style") orelse return null;
    const style: shape_edit.StrokeStyle = if (std.mem.eql(u8, style_text, "solid"))
        .solid
    else if (std.mem.eql(u8, style_text, "dashed"))
        .dashed
    else if (std.mem.eql(u8, style_text, "dotted"))
        .dotted
    else if (std.mem.eql(u8, style_text, "dash_dot"))
        .dash_dot
    else
        return null;
    if (!validColor(color) or !std.math.isFinite(width) or width <= 0) return null;
    return .{ .enabled = enabled, .color = color, .width = width, .style = style };
}

fn validBounds(bounds: shape_edit.Bounds, page_width: f64, page_height: f64, kind: shape_edit.Kind) bool {
    const tolerance = 0.01;
    if (!std.math.isFinite(bounds.x) or !std.math.isFinite(bounds.y) or
        !std.math.isFinite(bounds.width) or !std.math.isFinite(bounds.height)) return false;
    if (bounds.x < 0 or bounds.y < 0 or bounds.width <= 0 or bounds.height <= 0) return false;
    if (bounds.x + bounds.width > page_width + tolerance or bounds.y + bounds.height > page_height + tolerance) return false;
    if (kind == .circle and @abs(bounds.width - bounds.height) > tolerance) return false;
    return true;
}

fn validColor(value: []const u8) bool {
    if (value.len != 7 or value[0] != '#') return false;
    for (value[1..]) |byte| if (!std.ascii.isHex(byte)) return false;
    return true;
}

fn pageForId(pages: []const core.layout.conflicts.Page, page_id: u32) ?core.layout.conflicts.Page {
    for (pages) |page| if (page.id == page_id) return page;
    return null;
}

fn statusJson(allocator: std.mem.Allocator, status: []const u8, message: ?[]const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"schema\":1,\"status\":");
    try protocol.appendJsonString(allocator, &out, status);
    if (message) |text| {
        try out.appendSlice(allocator, ",\"message\":");
        try protocol.appendJsonString(allocator, &out, text);
    }
    try out.append(allocator, '}');
    return try out.toOwnedSlice(allocator);
}

fn insertionStatusJson(
    allocator: std.mem.Allocator,
    uri: []const u8,
    source: []const u8,
    edits: anytype,
    path: []const u8,
    page_id: u32,
    binding: []const u8,
) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"schema\":1,\"status\":\"ok\",\"workspaceEdit\":{\"changes\":{");
    try protocol.appendJsonString(allocator, &out, uri);
    try out.appendSlice(allocator, ":[");
    for (edits, 0..) |edit, index| {
        if (index != 0) try out.append(allocator, ',');
        try out.appendSlice(allocator, "{\"range\":");
        try appendEditRange(allocator, &out, source, edit);
        try out.appendSlice(allocator, ",\"newText\":");
        try protocol.appendJsonString(allocator, &out, edit.text);
        try out.append(allocator, '}');
    }
    try out.appendSlice(allocator, "]}},\"selection\":{\"path\":");
    try protocol.appendJsonString(allocator, &out, path);
    try out.appendSlice(allocator, ",\"pageId\":");
    try protocol.appendInt(allocator, &out, page_id);
    try out.appendSlice(allocator, ",\"binding\":");
    try protocol.appendJsonString(allocator, &out, binding);
    try out.appendSlice(allocator, "}}");
    return try out.toOwnedSlice(allocator);
}

fn appendEditRange(allocator: std.mem.Allocator, out: *std.ArrayList(u8), source: []const u8, edit: anytype) !void {
    const start = utils.source.utf16PositionAt(source, edit.start);
    const end = utils.source.utf16PositionAt(source, edit.end);
    try out.appendSlice(allocator, "{\"start\":{\"line\":");
    try protocol.appendInt(allocator, out, start.line);
    try out.appendSlice(allocator, ",\"character\":");
    try protocol.appendInt(allocator, out, start.character);
    try out.appendSlice(allocator, "},\"end\":{\"line\":");
    try protocol.appendInt(allocator, out, end.line);
    try out.appendSlice(allocator, ",\"character\":");
    try protocol.appendInt(allocator, out, end.character);
    try out.appendSlice(allocator, "}}");
}
