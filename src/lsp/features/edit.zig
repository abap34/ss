const std = @import("std");

const editor_edit = @import("../../editor/edit.zig");
const edit_relations = @import("edit/relations.zig");
const protocol = @import("../protocol.zig");
const lsp_state = @import("../state.zig");
const utils = @import("utils");

pub const Context = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    documents: *lsp_state.DocumentStore,
    active_editor_paths: *const std.StringHashMap(void),
    provider: *lsp_state.AnalysisProvider,
    generated_context: *anyopaque,
    on_generated: *const fn (context: *anyopaque, path: []const u8, source: []const u8) anyerror!void,
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

    var owned_snapshot: ?lsp_state.AnalysisSnapshot = null;
    defer if (owned_snapshot) |*snapshot| snapshot.deinit();
    const snapshot = try ctx.provider.forDocument(doc_path, &owned_snapshot) orelse
        return try statusJson(ctx.allocator, "unsupported", "No compiler snapshot is available.");
    const requested_id = protocol.stringField(request_object, "snapshotId") orelse "";
    const layout = if (snapshot.layout_output) |*value| value else return try statusJson(
        ctx.allocator,
        if (requested_id.len == 0) "unsupported" else "stale",
        if (requested_id.len == 0) "No solved layout is available." else "The document changed before the edit was applied.",
    );
    const editor = if (layout.editor) |*value| value else return try statusJson(
        ctx.allocator,
        if (requested_id.len == 0) "unsupported" else "stale",
        if (requested_id.len == 0) "The WYSIWYG editor is not active." else "The document changed before the edit was applied.",
    );

    if (requested_id.len == 0 or !std.mem.eql(u8, editor.model.snapshot_id, requested_id) or snapshot.generation != ctx.documents.generation) {
        return try statusJson(ctx.allocator, "stale", "The document changed before the edit was applied.");
    }

    const node_id: u32 = @intCast(@max(0, protocol.intField(request_object, "nodeId") orelse 0));
    const editing = editor.model.editingTarget(node_id) orelse
        return try statusJson(ctx.allocator, "unsupported", "This object has no editable binding in the page.");
    const requested_page_id = protocol.intField(request_object, "pageId") orelse -1;
    if (requested_page_id != editing.page_id) {
        return try statusJson(ctx.allocator, "stale", "The selected object no longer belongs to this page.");
    }
    const path = editing.path;
    const binding = editing.binding;
    const binding_required = editing.binding_required;
    const page_span = editing.page;
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
    _ = protocol.numberField(to_bounds, "width") orelse
        return try statusJson(ctx.allocator, "unsupported", "Invalid target bounds.");
    _ = protocol.numberField(to_bounds, "height") orelse
        return try statusJson(ctx.allocator, "unsupported", "Invalid target bounds.");
    const mode = protocol.stringField(request_object, "mode") orelse "absolute";
    if (!std.mem.eql(u8, mode, "absolute") and !std.mem.eql(u8, mode, "relative")) {
        return try statusJson(ctx.allocator, "unsupported", "Unknown layout edit mode.");
    }

    var edit_result = if (std.mem.eql(u8, mode, "relative")) blk: {
        if (binding_required) {
            return try statusJson(ctx.allocator, "unsupported", "Set an absolute position before keeping this object's relations.");
        }
        const adjustments = try edit_relations.collect(ctx.allocator, &layout.report, &editor.model, path, node_id, binding, page_span, to_x - from_x, to_y - from_y);
        defer ctx.allocator.free(adjustments);
        if (!edit_relations.haveBothAxes(adjustments)) {
            return try statusJson(ctx.allocator, "unsupported", "Keeping relations requires expressible horizontal and vertical position relations.");
        }
        break :blk (try editor_edit.relativePosition(ctx.allocator, source, page_span, adjustments)) orelse
            return try statusJson(ctx.allocator, "unsupported", "The page insertion point could not be located.");
    } else blk: {
        const updates = try edit_relations.existingUpdates(ctx.allocator, &layout.report, node_id, path, page_span);
        defer ctx.allocator.free(updates);
        const introduction: ?editor_edit.BindingIntroduction = if (binding_required) .{ .statement = editing.statement } else null;
        break :blk (try editor_edit.absolutePosition(
            ctx.allocator,
            source,
            page_span,
            binding,
            to_x,
            to_y,
            updates,
            introduction,
        )) orelse
            return try statusJson(ctx.allocator, "unsupported", "The page insertion point could not be located.");
    };
    defer edit_result.deinit(ctx.allocator);

    // Applying the generated edit triggers the authoritative analysis and
    // layout pass. Running it here as a preflight would evaluate the document
    // twice for every pointer gesture.
    const edited_source = try editor_edit.applyEdits(ctx.allocator, source, edit_result.edits);
    defer ctx.allocator.free(edited_source);
    try ctx.on_generated(ctx.generated_context, path, edited_source);
    const uri = try protocol.uriFromPath(ctx.allocator, path);
    defer ctx.allocator.free(uri);
    return try editStatusJson(ctx.allocator, uri, source, edit_result.edits);
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
