const std = @import("std");
const core = @import("core");

const editor_edit = @import("../../editor/edit.zig");
const icon_catalog = @import("../../editor/icons.zig");
const edit_response = @import("edit/response.zig");
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

pub fn catalogResult(allocator: std.mem.Allocator, params: ?protocol.JsonValue) ![]const u8 {
    const request = params orelse return try icon_catalog.catalogJson(allocator, "", .all);
    if (request != .object) return try icon_catalog.catalogJson(allocator, "", .all);
    const query = protocol.stringField(&request.object, "query") orelse "";
    const style_text = protocol.stringField(&request.object, "style") orelse "all";
    const filter = icon_catalog.parseFilter(style_text) orelse .all;
    return icon_catalog.catalogJson(allocator, query, filter) catch |err| switch (err) {
        error.QueryTooLong => edit_response.statusJson(allocator, "rejected", "The icon query is too long."),
        else => return err,
    };
}

pub fn insertResult(ctx: *Context, params: ?protocol.JsonValue) ![]const u8 {
    const request = params orelse return try edit_response.statusJson(ctx.allocator, "unsupported", "Missing icon insertion request.");
    if (request != .object) return try edit_response.statusJson(ctx.allocator, "unsupported", "Invalid icon insertion request.");
    const request_object = &request.object;
    const doc_path = try protocol.docPathFromParams(ctx.allocator, params) orelse
        return try edit_response.statusJson(ctx.allocator, "unsupported", "Missing source document.");
    defer ctx.allocator.free(doc_path);
    if (!ctx.active_editor_paths.contains(doc_path)) {
        return try edit_response.statusJson(ctx.allocator, "unsupported", "The WYSIWYG editor is not active for this document.");
    }

    var owned_snapshot: ?lsp_state.AnalysisSnapshot = null;
    defer if (owned_snapshot) |*snapshot| snapshot.deinit();
    const snapshot = try ctx.provider.forDocument(doc_path, &owned_snapshot) orelse
        return try edit_response.statusJson(ctx.allocator, "unsupported", "No compiler snapshot is available.");
    const layout = if (snapshot.layout_output) |*value| value else
        return try edit_response.statusJson(ctx.allocator, "unsupported", "No solved layout is available.");
    const editor = if (layout.editor) |*value| value else
        return try edit_response.statusJson(ctx.allocator, "unsupported", "The WYSIWYG editor is not active.");
    const requested_id = protocol.stringField(request_object, "snapshotId") orelse "";
    if (requested_id.len == 0 or
        !std.mem.eql(u8, editor.model.snapshot_id, requested_id) or
        snapshot.generation != ctx.documents.generation)
    {
        return try edit_response.statusJson(ctx.allocator, "stale", "The document changed before the icon was inserted.");
    }

    const requested_page_id = protocol.intField(request_object, "pageId") orelse -1;
    if (requested_page_id < 0 or requested_page_id > std.math.maxInt(core.NodeId)) {
        return try edit_response.statusJson(ctx.allocator, "unsupported", "Missing target page.");
    }
    const page_id: core.NodeId = @intCast(requested_page_id);
    const target = editor.model.pageEditingTarget(page_id) orelse
        return try edit_response.statusJson(ctx.allocator, "unsupported", "This page does not support icon insertion.");
    const page = pageForId(layout.report.pages, page_id) orelse
        return try edit_response.statusJson(ctx.allocator, "stale", "The target page no longer exists.");

    const requested_source = protocol.stringField(request_object, "source") orelse
        return try edit_response.statusJson(ctx.allocator, "rejected", "Missing icon identifier.");
    const spec = core.fontawesome.parseSource(requested_source) orelse
        return try edit_response.statusJson(ctx.allocator, "rejected", "Invalid icon identifier.");
    if (!core.fontawesome.contains(spec)) {
        return try edit_response.statusJson(ctx.allocator, "rejected", "The icon is not present in the bundled collection.");
    }
    const canonical_source = try core.fontawesome.canonicalSource(ctx.allocator, spec);
    defer ctx.allocator.free(canonical_source);
    const bounds_object = protocol.objectFieldObject(request_object, "bounds") orelse
        return try edit_response.statusJson(ctx.allocator, "rejected", "Missing icon bounds.");
    const bounds = parseBounds(bounds_object) orelse
        return try edit_response.statusJson(ctx.allocator, "rejected", "Invalid icon bounds.");
    if (!validBounds(bounds, page.width, page.height)) {
        return try edit_response.statusJson(ctx.allocator, "rejected", "Icon bounds must be finite, positive, and inside the page.");
    }
    const color = protocol.stringField(request_object, "color") orelse
        return try edit_response.statusJson(ctx.allocator, "rejected", "Missing icon color.");
    if (!validColor(color)) {
        return try edit_response.statusJson(ctx.allocator, "rejected", "Invalid icon color.");
    }

    var owned_source: ?[]u8 = null;
    defer if (owned_source) |source| ctx.allocator.free(source);
    const source = ctx.documents.sourceForPath(target.path) orelse blk: {
        owned_source = utils.fs.readFileAlloc(ctx.io, ctx.allocator, target.path) catch
            return try edit_response.statusJson(ctx.allocator, "unsupported", "The target source document is unavailable.");
        const module = snapshot.moduleById(target.module_id) orelse
            return try edit_response.statusJson(ctx.allocator, "stale", "The target source module changed.");
        if (!std.mem.eql(u8, owned_source.?, module.source)) {
            return try edit_response.statusJson(ctx.allocator, "stale", "The target source document changed on disk.");
        }
        break :blk owned_source.?;
    };
    var result = (try editor_edit.icon.insert(
        ctx.allocator,
        source,
        target.page,
        target.first_constraint_start,
        target.icon_binding,
        canonical_source,
        bounds,
        color,
    )) orelse return try edit_response.statusJson(ctx.allocator, "unsupported", "The page insertion point could not be located.");
    defer result.deinit(ctx.allocator);

    const uri = try protocol.uriFromPath(ctx.allocator, target.path);
    defer ctx.allocator.free(uri);
    return edit_response.workspaceEditJson(
        ctx.allocator,
        uri,
        source,
        result.edits,
        target.path,
        page_id,
        target.icon_binding,
    );
}

fn parseBounds(object: *const protocol.JsonObject) ?editor_edit.icon.Bounds {
    return .{
        .x = protocol.numberField(object, "x") orelse return null,
        .y = protocol.numberField(object, "y") orelse return null,
        .width = protocol.numberField(object, "width") orelse return null,
        .height = protocol.numberField(object, "height") orelse return null,
    };
}

fn validBounds(bounds: editor_edit.icon.Bounds, page_width: f64, page_height: f64) bool {
    const tolerance = 0.01;
    if (!std.math.isFinite(bounds.x) or !std.math.isFinite(bounds.y) or
        !std.math.isFinite(bounds.width) or !std.math.isFinite(bounds.height)) return false;
    if (bounds.x < 0 or bounds.y < 0 or bounds.width <= 0 or bounds.height <= 0) return false;
    return bounds.x + bounds.width <= page_width + tolerance and
        bounds.y + bounds.height <= page_height + tolerance;
}

fn validColor(value: []const u8) bool {
    if (value.len != 7 or value[0] != '#') return false;
    for (value[1..]) |byte| if (!std.ascii.isHex(byte)) return false;
    return true;
}

fn pageForId(pages: []const core.layout.conflicts.Page, page_id: core.NodeId) ?core.layout.conflicts.Page {
    for (pages) |page| if (page.id == page_id) return page;
    return null;
}
