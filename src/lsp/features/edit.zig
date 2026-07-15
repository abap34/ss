const std = @import("std");

const editor_edit = @import("../../editor/edit.zig");
const protocol = @import("../protocol.zig");
const lsp_state = @import("../state.zig");
const utils = @import("utils");

pub const Context = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    documents: *lsp_state.DocumentStore,
    active_editor_paths: *const std.StringHashMap(void),
    provider: *lsp_state.SnapshotProvider,
    validation_context: *anyopaque,
    validate: *const fn (context: *anyopaque, path: []const u8, source: []const u8, node_id: u32, x: f64, y: f64, width: f64, height: f64) anyerror!bool,
};

pub fn result(ctx: *Context, params: ?protocol.JsonValue) ![]const u8 {
    const request = params orelse return try statusJson(ctx.allocator, "unsupported", "Missing edit request.");
    if (request != .object) return try statusJson(ctx.allocator, "unsupported", "Invalid edit request.");
    const request_object = &request.object;
    const doc_path = try protocol.docPathFromParams(ctx.allocator, params) orelse
        return try statusJson(ctx.allocator, "unsupported", "Missing source document.");
    defer ctx.allocator.free(doc_path);
    if (!ctx.active_editor_paths.contains(doc_path)) {
        return try statusJson(ctx.allocator, "unsupported", "The WYSIWYG editor is not active for this document.");
    }

    var owned_snapshot: ?lsp_state.Snapshot = null;
    defer if (owned_snapshot) |*snapshot| snapshot.deinit();
    const snapshot = try ctx.provider.forDocument(doc_path, &owned_snapshot) orelse
        return try statusJson(ctx.allocator, "unsupported", "No compiler snapshot is available.");
    const layout = if (snapshot.layout) |*value| value else return try statusJson(ctx.allocator, "unsupported", "No solved layout is available.");
    const editor_json = layout.editor_snapshot_json orelse
        return try statusJson(ctx.allocator, "unsupported", "The WYSIWYG editor is not active.");

    var parsed = try utils.json.parseValue(ctx.allocator, editor_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return try statusJson(ctx.allocator, "unsupported", "Invalid compiler snapshot.");
    const root = &parsed.value.object;
    const expected_id = protocol.stringField(root, "snapshot_id") orelse "";
    const requested_id = protocol.stringField(request_object, "snapshotId") orelse "";
    if (requested_id.len == 0 or !std.mem.eql(u8, expected_id, requested_id) or snapshot.generation != ctx.documents.generation) {
        return try statusJson(ctx.allocator, "stale", "The document changed before the edit was applied.");
    }

    const node_id: u32 = @intCast(@max(0, protocol.intField(request_object, "nodeId") orelse 0));
    const editing = findEditingTarget(root, node_id) orelse
        return try statusJson(ctx.allocator, "unsupported", "This object has no editable binding in the page.");
    const requested_page_id = protocol.intField(request_object, "pageId") orelse -1;
    const target_page_id = protocol.intField(editing, "page_id") orelse -1;
    if (requested_page_id != target_page_id) {
        return try statusJson(ctx.allocator, "stale", "The selected object no longer belongs to this page.");
    }
    const path = protocol.stringField(editing, "path") orelse doc_path;
    const binding = protocol.stringField(editing, "binding") orelse
        return try statusJson(ctx.allocator, "unsupported", "The object has no source binding.");
    const binding_required = protocol.boolField(editing, "binding_required") orelse false;
    const page_span = editor_edit.ByteSpan{
        .start = protocol.usizeField(editing, "page_start") orelse 0,
        .end = protocol.usizeField(editing, "page_end") orelse 0,
    };
    var owned_source: ?[]u8 = null;
    defer if (owned_source) |source| ctx.allocator.free(source);
    const source = ctx.documents.sourceForPath(path) orelse blk: {
        owned_source = utils.fs.readFileAlloc(ctx.io, ctx.allocator, path) catch
            return try statusJson(ctx.allocator, "unsupported", "The source document is unavailable.");
        break :blk owned_source.?;
    };

    const from_bounds = protocol.objectFieldObject(request_object, "fromBounds") orelse
        return try statusJson(ctx.allocator, "unsupported", "Missing initial bounds.");
    const to_bounds = protocol.objectFieldObject(request_object, "toBounds") orelse
        return try statusJson(ctx.allocator, "unsupported", "Missing target bounds.");
    const from_x = protocol.numberField(from_bounds, "x") orelse
        return try statusJson(ctx.allocator, "unsupported", "Invalid initial bounds.");
    const from_y = protocol.numberField(from_bounds, "y") orelse
        return try statusJson(ctx.allocator, "unsupported", "Invalid initial bounds.");
    _ = protocol.numberField(from_bounds, "width") orelse
        return try statusJson(ctx.allocator, "unsupported", "Invalid initial bounds.");
    _ = protocol.numberField(from_bounds, "height") orelse
        return try statusJson(ctx.allocator, "unsupported", "Invalid initial bounds.");
    const to_x = protocol.numberField(to_bounds, "x") orelse
        return try statusJson(ctx.allocator, "unsupported", "Invalid target bounds.");
    const to_y = protocol.numberField(to_bounds, "y") orelse
        return try statusJson(ctx.allocator, "unsupported", "Invalid target bounds.");
    const to_width = protocol.numberField(to_bounds, "width") orelse
        return try statusJson(ctx.allocator, "unsupported", "Invalid target bounds.");
    const to_height = protocol.numberField(to_bounds, "height") orelse
        return try statusJson(ctx.allocator, "unsupported", "Invalid target bounds.");
    const mode = protocol.stringField(request_object, "mode") orelse "absolute";
    if (!std.mem.eql(u8, mode, "absolute") and !std.mem.eql(u8, mode, "relative")) {
        return try statusJson(ctx.allocator, "unsupported", "Unknown layout edit mode.");
    }

    var edit_result = if (std.mem.eql(u8, mode, "relative")) blk: {
        if (binding_required) {
            return try statusJson(ctx.allocator, "unsupported", "Set an absolute position before keeping this object's relations.");
        }
        const updates = try relationUpdates(ctx.allocator, root, source, path, node_id, binding, to_x - from_x, to_y - from_y);
        defer ctx.allocator.free(updates);
        if (!hasBothAxes(root, node_id, path, page_span)) {
            return try statusJson(ctx.allocator, "unsupported", "Keeping relations requires explicit horizontal and vertical constraints in this page.");
        }
        break :blk try editor_edit.preserveRelations(ctx.allocator, source, updates);
    } else blk: {
        const spans = try editableConstraintSpans(ctx.allocator, root, node_id, path, page_span);
        defer ctx.allocator.free(spans);
        const introduction: ?editor_edit.BindingIntroduction = if (binding_required) .{ .statement = .{
            .start = protocol.usizeField(editing, "statement_start") orelse
                return try statusJson(ctx.allocator, "unsupported", "The component statement has no source location."),
            .end = protocol.usizeField(editing, "statement_end") orelse
                return try statusJson(ctx.allocator, "unsupported", "The component statement has no source location."),
        } } else null;
        break :blk (try editor_edit.absolutePosition(
            ctx.allocator,
            source,
            page_span,
            binding,
            to_x,
            to_y,
            spans,
            introduction,
        )) orelse
            return try statusJson(ctx.allocator, "unsupported", "The page insertion point could not be located.");
    };
    defer edit_result.deinit(ctx.allocator);

    const edited_source = try editor_edit.applyEdits(ctx.allocator, source, edit_result.edits);
    defer ctx.allocator.free(edited_source);
    if (!try ctx.validate(ctx.validation_context, path, edited_source, node_id, to_x, to_y, to_width, to_height)) {
        return try statusJson(ctx.allocator, "rejected", "The proposed source edit did not reproduce the requested position.");
    }

    const uri = try protocol.uriFromPath(ctx.allocator, path);
    defer ctx.allocator.free(uri);
    return try editStatusJson(ctx.allocator, uri, source, edit_result.edits);
}

fn findEditingTarget(root: *const protocol.JsonObject, node_id: u32) ?*const protocol.JsonObject {
    const items = protocol.arrayFieldObject(root, "editing") orelse return null;
    for (items.items) |*item| {
        if (item.* != .object) continue;
        if ((protocol.intField(&item.object, "node_id") orelse -1) == node_id) return &item.object;
    }
    return null;
}

fn editableConstraintSpans(
    allocator: std.mem.Allocator,
    root: *const protocol.JsonObject,
    node_id: u32,
    path: []const u8,
    page_span: editor_edit.ByteSpan,
) ![]editor_edit.ByteSpan {
    var spans = std.ArrayList(editor_edit.ByteSpan).empty;
    errdefer spans.deinit(allocator);
    const relations = layoutRelations(root) orelse return try spans.toOwnedSlice(allocator);
    for (relations.items) |*relation_value| {
        if (relation_value.* != .object) continue;
        const relation = &relation_value.object;
        if (!relationTargetsNode(relation, node_id)) continue;
        if (!relationHasRole(relation, "position")) continue;
        const location = protocol.objectFieldObject(relation, "location") orelse continue;
        const relation_path = protocol.stringField(location, "path") orelse continue;
        const start = protocol.usizeField(location, "start") orelse continue;
        const end = protocol.usizeField(location, "end") orelse continue;
        if (!std.mem.eql(u8, relation_path, path) or start < page_span.start or end > page_span.end) continue;
        try spans.append(allocator, .{ .start = start, .end = end });
    }
    return try spans.toOwnedSlice(allocator);
}

fn relationUpdates(
    allocator: std.mem.Allocator,
    root: *const protocol.JsonObject,
    source: []const u8,
    path: []const u8,
    node_id: u32,
    binding: []const u8,
    dx: f64,
    dy: f64,
) ![]editor_edit.RelationUpdate {
    var updates = std.ArrayList(editor_edit.RelationUpdate).empty;
    errdefer updates.deinit(allocator);
    const relations = layoutRelations(root) orelse return try updates.toOwnedSlice(allocator);
    for (relations.items) |*relation_value| {
        if (relation_value.* != .object) continue;
        const relation = &relation_value.object;
        if (!relationTargetsNode(relation, node_id)) continue;
        if (!relationHasRole(relation, "position")) continue;
        const location = protocol.objectFieldObject(relation, "location") orelse continue;
        const relation_path = protocol.stringField(location, "path") orelse continue;
        if (!std.mem.eql(u8, relation_path, path)) continue;
        const start = protocol.usizeField(location, "start") orelse continue;
        const end = protocol.usizeField(location, "end") orelse continue;
        if (start >= source.len or end > source.len or end <= start) continue;
        const parsed = editor_edit.parseRelation(source[start..end]) orelse continue;
        if (!std.mem.eql(u8, parsed.target, binding)) continue;
        const axis = protocol.stringField(relation, "axis") orelse continue;
        const offset = protocol.numberField(relation, "offset") orelse 0;
        try updates.append(allocator, .{
            .span = .{ .start = start, .end = end },
            .target = parsed.target,
            .target_anchor = parsed.target_anchor,
            .source = parsed.source,
            .source_anchor = parsed.source_anchor,
            .offset = offset + if (std.mem.eql(u8, axis, "horizontal")) dx else -dy,
        });
    }
    return try updates.toOwnedSlice(allocator);
}

fn hasBothAxes(root: *const protocol.JsonObject, node_id: u32, path: []const u8, page_span: editor_edit.ByteSpan) bool {
    var horizontal = false;
    var vertical = false;
    const relations = layoutRelations(root) orelse return false;
    for (relations.items) |*relation_value| {
        if (relation_value.* != .object) continue;
        const relation = &relation_value.object;
        if (!relationTargetsNode(relation, node_id)) continue;
        if (!relationHasRole(relation, "position")) continue;
        const location = protocol.objectFieldObject(relation, "location") orelse continue;
        const relation_path = protocol.stringField(location, "path") orelse continue;
        const start = protocol.usizeField(location, "start") orelse continue;
        const end = protocol.usizeField(location, "end") orelse continue;
        if (!std.mem.eql(u8, relation_path, path) or start < page_span.start or end > page_span.end) continue;
        const axis = protocol.stringField(relation, "axis") orelse continue;
        horizontal = horizontal or std.mem.eql(u8, axis, "horizontal");
        vertical = vertical or std.mem.eql(u8, axis, "vertical");
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

fn statusJson(
    allocator: std.mem.Allocator,
    status: []const u8,
    message: ?[]const u8,
) ![]u8 {
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

fn editStatusJson(
    allocator: std.mem.Allocator,
    uri: []const u8,
    source: []const u8,
    edits: []const editor_edit.TextEdit,
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
    try out.appendSlice(allocator, "]}}}");
    return try out.toOwnedSlice(allocator);
}

fn appendEditRange(allocator: std.mem.Allocator, out: *std.ArrayList(u8), source: []const u8, edit: editor_edit.TextEdit) !void {
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
