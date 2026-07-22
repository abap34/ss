const std = @import("std");
const core = @import("core");

const editor_edit = @import("../../editor/edit.zig");
const shape_edit = editor_edit.shape;
const edit_relations = @import("edit/relations.zig");
const edit_response = @import("edit/response.zig");
const protocol = @import("../protocol.zig");
const lsp_state = @import("../state.zig");
const utils = @import("utils");

const statusJson = edit_response.statusJson;
const insertionStatusJson = edit_response.workspaceEditJson;

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
    const stroke = parseStroke(request_object) orelse
        return try statusJson(ctx.allocator, "rejected", "Invalid stroke style.");
    const shape: shape_edit.Shape = switch (kind) {
        .line => blk: {
            if (!stroke.enabled) {
                return try statusJson(ctx.allocator, "rejected", "A line must have a visible stroke.");
            }
            const start = parsePoint(request_object, "start") orelse
                return try statusJson(ctx.allocator, "rejected", "Invalid line start point.");
            const end = parsePoint(request_object, "end") orelse
                return try statusJson(ctx.allocator, "rejected", "Invalid line end point.");
            const geometry = shape_edit.normalizeLine(start, end, page.width, page.height) orelse
                return try statusJson(ctx.allocator, "rejected", "Line endpoints must be distinct and inside the page.");
            break :blk .{ .line = .{
                .bounds = geometry.bounds,
                .start = geometry.start,
                .end = geometry.end,
                .stroke = stroke,
            } };
        },
        .rectangle, .circle, .arrow, .speech_bubble => blk: {
            const bounds_object = protocol.objectFieldObject(request_object, "bounds") orelse
                return try statusJson(ctx.allocator, "rejected", "Missing shape bounds.");
            const bounds = parseBounds(bounds_object) orelse
                return try statusJson(ctx.allocator, "rejected", "Invalid shape bounds.");
            if (!validBounds(bounds, page.width, page.height, kind)) {
                return try statusJson(ctx.allocator, "rejected", "Shape bounds must be finite, positive, and inside the page.");
            }
            const fill = parseFill(request_object) orelse
                return try statusJson(ctx.allocator, "rejected", "Invalid fill style.");
            if (!fill.enabled and !stroke.enabled) {
                return try statusJson(ctx.allocator, "rejected", "A shape must have a fill or a stroke.");
            }
            const closed = shape_edit.ClosedShape{ .bounds = bounds, .fill = fill, .stroke = stroke };
            break :blk switch (kind) {
                .rectangle => .{ .rectangle = closed },
                .circle => .{ .circle = closed },
                .arrow => .{ .arrow = closed },
                .speech_bubble => .{ .speech_bubble = closed },
                .line => unreachable,
            };
        },
    };

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
        .speech_bubble => target.speech_bubble_binding,
        .line => target.line_binding,
    };
    var result = (try shape_edit.insert(
        ctx.allocator,
        source,
        target.page,
        target.first_constraint_start,
        binding,
        shape,
    )) orelse return try statusJson(ctx.allocator, "unsupported", "The page insertion point could not be located.");
    defer result.deinit(ctx.allocator);

    const uri = try protocol.uriFromPath(ctx.allocator, target.path);
    defer ctx.allocator.free(uri);
    return try insertionStatusJson(ctx.allocator, uri, source, result.edits, target.path, page_id, binding);
}

const LineGeometryRequest = struct {
    snapshot_id: []const u8,
    page_id: core.NodeId,
    node_id: core.NodeId,
    start: shape_edit.Point,
    end: shape_edit.Point,
};

pub fn lineGeometryResult(ctx: *Context, params: ?protocol.JsonValue) ![]const u8 {
    const request = params orelse return try statusJson(ctx.allocator, "rejected", "Missing line geometry request.");
    if (request != .object) return try statusJson(ctx.allocator, "rejected", "Invalid line geometry request.");
    const request_object = &request.object;
    const parsed = parseLineGeometryRequest(request_object) orelse
        return try statusJson(ctx.allocator, "rejected", "Invalid line geometry request.");
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
    const layout = if (snapshot.layout_output) |*value| value else return try statusJson(ctx.allocator, "stale", "The document changed before the line was edited.");
    const editor = if (layout.editor) |*value| value else return try statusJson(ctx.allocator, "stale", "The document changed before the line was edited.");
    if (parsed.snapshot_id.len == 0 or
        !std.mem.eql(u8, editor.model.snapshot_id, parsed.snapshot_id) or
        snapshot.generation != ctx.documents.generation)
    {
        return try statusJson(ctx.allocator, "stale", "The document changed before the line was edited.");
    }

    const target = editor.model.shapeEditingTarget(parsed.node_id) orelse
        return try statusJson(ctx.allocator, "unsupported", "This object is not an editable canonical line.");
    if (parsed.page_id != target.page_id) {
        return try statusJson(ctx.allocator, "stale", "The selected line no longer belongs to this page.");
    }
    if (target.kind != .line) {
        return try statusJson(ctx.allocator, "rejected", "The selected object is not a line.");
    }
    const expressions = target.line_source orelse
        return try statusJson(ctx.allocator, "unsupported", "This line does not have editable canonical geometry.");
    const editing = editor.model.editingTarget(parsed.node_id) orelse
        return try statusJson(ctx.allocator, "unsupported", "This line has no editable binding in the page.");
    if (editing.page_id != target.page_id or
        !std.mem.eql(u8, editing.path, target.path) or
        !std.mem.eql(u8, editing.binding, target.binding))
    {
        return try statusJson(ctx.allocator, "stale", "The selected line source changed.");
    }
    const page = pageForId(layout.report.pages, parsed.page_id) orelse
        return try statusJson(ctx.allocator, "stale", "The target page no longer exists.");
    const geometry = shape_edit.normalizeLine(parsed.start, parsed.end, page.width, page.height) orelse
        return try statusJson(ctx.allocator, "rejected", "Line endpoints must be distinct and inside the page.");

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

    var geometry_edits = try shape_edit.lineGeometryEdits(ctx.allocator, .{
        .width = expressions.width_expression,
        .height = expressions.height_expression,
        .start_x = expressions.start_x_expression,
        .start_y = expressions.start_y_expression,
        .end_x = expressions.end_x_expression,
        .end_y = expressions.end_y_expression,
    }, geometry);
    defer geometry_edits.deinit(ctx.allocator);
    const updates = try edit_relations.existingUpdates(
        ctx.allocator,
        &layout.report,
        parsed.node_id,
        target.path,
        editing.page,
    );
    defer ctx.allocator.free(updates);
    var position_edits = (try editor_edit.absolutePosition(
        ctx.allocator,
        source,
        editing.page,
        target.binding,
        geometry.bounds.x,
        geometry.bounds.y,
        updates,
        null,
    )) orelse return try statusJson(ctx.allocator, "unsupported", "The page insertion point could not be located.");
    defer position_edits.deinit(ctx.allocator);
    var result = try combineEditResults(ctx.allocator, geometry_edits.edits, position_edits.edits);
    defer result.deinit(ctx.allocator);

    const uri = try protocol.uriFromPath(ctx.allocator, target.path);
    defer ctx.allocator.free(uri);
    return try insertionStatusJson(
        ctx.allocator,
        uri,
        source,
        result.edits,
        target.path,
        target.page_id,
        target.binding,
    );
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
    const stroke = parseStroke(request_object) orelse
        return try statusJson(ctx.allocator, "rejected", "Invalid stroke style.");
    const fill: ?shape_edit.Fill = if (target.kind == .line)
        null
    else
        parseFill(request_object) orelse
            return try statusJson(ctx.allocator, "rejected", "Invalid fill style.");
    if (target.kind == .line) {
        if (!stroke.enabled) {
            return try statusJson(ctx.allocator, "rejected", "A line must have a visible stroke.");
        }
    } else if (!fill.?.enabled and !stroke.enabled) {
        return try statusJson(ctx.allocator, "rejected", "A shape must have a fill or a stroke.");
    }
    const fill_span = if (fill != null)
        target.fill_expression orelse
            return try statusJson(ctx.allocator, "unsupported", "This shape fill is not editable.")
    else
        null;

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

    const fill_text: ?[]u8 = if (fill) |value| try shape_edit.fillExpression(ctx.allocator, value) else null;
    var fill_text_transferred = false;
    errdefer if (!fill_text_transferred) if (fill_text) |text| ctx.allocator.free(text);
    const stroke_text = try shape_edit.strokeExpression(ctx.allocator, stroke);
    var stroke_text_transferred = false;
    errdefer if (!stroke_text_transferred) ctx.allocator.free(stroke_text);
    const edits = try ctx.allocator.alloc(editor_edit.TextEdit, if (fill_text == null) 1 else 2);
    var edit_index: usize = 0;
    if (fill_text) |text| {
        edits[edit_index] = .{
            .start = fill_span.?.start,
            .end = fill_span.?.end,
            .text = text,
        };
        edit_index += 1;
    }
    edits[edit_index] = .{
        .start = target.stroke_expression.start,
        .end = target.stroke_expression.end,
        .text = stroke_text,
    };
    var result = editor_edit.Result{ .edits = edits };
    fill_text_transferred = true;
    stroke_text_transferred = true;
    defer result.deinit(ctx.allocator);
    const uri = try protocol.uriFromPath(ctx.allocator, target.path);
    defer ctx.allocator.free(uri);
    return try insertionStatusJson(ctx.allocator, uri, source, result.edits, target.path, target.page_id, target.binding);
}

fn parseKind(text: []const u8) ?shape_edit.Kind {
    if (std.mem.eql(u8, text, "rectangle")) return .rectangle;
    if (std.mem.eql(u8, text, "circle")) return .circle;
    if (std.mem.eql(u8, text, "arrow")) return .arrow;
    if (std.mem.eql(u8, text, "speech_bubble")) return .speech_bubble;
    if (std.mem.eql(u8, text, "line")) return .line;
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

fn parsePoint(request: *const protocol.JsonObject, name: []const u8) ?shape_edit.Point {
    const object = protocol.objectFieldObject(request, name) orelse return null;
    return .{
        .x = protocol.numberField(object, "x") orelse return null,
        .y = protocol.numberField(object, "y") orelse return null,
    };
}

fn parseLineGeometryRequest(request: *const protocol.JsonObject) ?LineGeometryRequest {
    const page_id = protocol.intField(request, "pageId") orelse return null;
    const node_id = protocol.intField(request, "nodeId") orelse return null;
    if (page_id < 0 or page_id > std.math.maxInt(core.NodeId) or
        node_id < 0 or node_id > std.math.maxInt(core.NodeId)) return null;
    return .{
        .snapshot_id = protocol.stringField(request, "snapshotId") orelse return null,
        .page_id = @intCast(page_id),
        .node_id = @intCast(node_id),
        .start = parsePoint(request, "start") orelse return null,
        .end = parsePoint(request, "end") orelse return null,
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

fn combineEditResults(
    allocator: std.mem.Allocator,
    first: []const editor_edit.TextEdit,
    second: []const editor_edit.TextEdit,
) !editor_edit.Result {
    const edits = try allocator.alloc(editor_edit.TextEdit, first.len + second.len);
    var initialized: usize = 0;
    errdefer {
        for (edits[0..initialized]) |*edit| edit.deinit(allocator);
        allocator.free(edits);
    }
    const groups = [_][]const editor_edit.TextEdit{ first, second };
    for (groups) |items| {
        for (items) |edit| {
            edits[initialized] = .{
                .start = edit.start,
                .end = edit.end,
                .text = try allocator.dupe(u8, edit.text),
            };
            initialized += 1;
        }
    }
    return .{ .edits = edits };
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
