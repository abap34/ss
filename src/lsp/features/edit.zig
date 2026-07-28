const std = @import("std");
const core = @import("core");

const editor_edit = @import("../../editor/edit.zig");
const edit_relations = @import("edit/relations.zig");
const edit_response = @import("edit/response.zig");
const edit_width = @import("edit/width.zig");
const protocol = @import("../protocol.zig");
const lsp_state = @import("../state.zig");
const utils = @import("utils");

pub const GeneratedEditMode = enum {
    absolute,
    relative,
    width,
};

pub const GeneratedConstraintReplacement = struct {
    index: usize,
    expected: core.Constraint,
    offset_span: utils.source.ByteSpan,
    literal_scale: f32,
    new_offset: f32,
};

pub const GeneratedEdit = struct {
    path: []const u8,
    base_source: []const u8,
    source: []const u8,
    base_generation: u64,
    base_snapshot_id: []const u8,
    node_id: core.NodeId,
    page_id: core.NodeId,
    mode: GeneratedEditMode,
    replacements: []const GeneratedConstraintReplacement,
};

pub const Context = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    documents: *lsp_state.DocumentStore,
    active_editor_paths: *const std.StringHashMap(void),
    provider: *lsp_state.AnalysisProvider,
    generated_context: *anyopaque,
    on_generated: *const fn (context: *anyopaque, edit: *const GeneratedEdit) anyerror!void,
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
        if (requested_id.len == 0) edit_response.build_diagnostics_message else "The document changed before the edit was applied.",
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
    const from_width = protocol.numberField(from_bounds, "width") orelse
        return try statusJson(ctx.allocator, "unsupported", "Invalid initial bounds.");
    const from_height = protocol.numberField(from_bounds, "height") orelse
        return try statusJson(ctx.allocator, "unsupported", "Invalid initial bounds.");
    const to_x = protocol.numberField(to_bounds, "x") orelse
        return try statusJson(ctx.allocator, "unsupported", "Invalid target bounds.");
    const to_y = protocol.numberField(to_bounds, "y") orelse
        return try statusJson(ctx.allocator, "unsupported", "Invalid target bounds.");
    const to_width = protocol.numberField(to_bounds, "width") orelse
        return try statusJson(ctx.allocator, "unsupported", "Invalid target bounds.");
    const to_height = protocol.numberField(to_bounds, "height") orelse
        return try statusJson(ctx.allocator, "unsupported", "Invalid target bounds.");
    if (!std.math.isFinite(from_x) or
        !std.math.isFinite(from_y) or
        !std.math.isFinite(from_width) or
        !std.math.isFinite(from_height) or
        !std.math.isFinite(to_x) or
        !std.math.isFinite(to_y) or
        !std.math.isFinite(to_width) or
        !std.math.isFinite(to_height))
    {
        return try statusJson(ctx.allocator, "unsupported", "Bounds must contain finite numbers.");
    }
    const mode = protocol.stringField(request_object, "mode") orelse "absolute";
    if (!std.mem.eql(u8, mode, "absolute") and
        !std.mem.eql(u8, mode, "relative") and
        !std.mem.eql(u8, mode, "width"))
    {
        return try statusJson(ctx.allocator, "unsupported", "Unknown layout edit mode.");
    }

    var edit_result = if (std.mem.eql(u8, mode, "width")) blk: {
        const page = layout.report.pageById(editing.page_id) orelse
            return try statusJson(ctx.allocator, "stale", "The target page no longer exists.");
        const object = layout.report.objectById(node_id) orelse
            return try statusJson(ctx.allocator, "stale", "The target component no longer exists.");
        if (object.page_id != page.id) {
            return try statusJson(ctx.allocator, "stale", "The target component no longer belongs to this page.");
        }
        if (!std.math.isFinite(to_width) or to_width < editing.minimum_width or
            object.x < 0 or @as(f64, object.x) + to_width > page.width)
        {
            return try statusJson(ctx.allocator, "rejected", edit_width.invalid_width_message);
        }
        const existing_update = try edit_width.existingUpdate(
            ctx.allocator,
            source,
            path,
            page_span,
            binding,
        );
        const introduction: ?editor_edit.BindingIntroduction = if (binding_required)
            .{ .statement = editing.statement }
        else
            null;
        break :blk (try editor_edit.componentWidth(
            ctx.allocator,
            source,
            page_span,
            binding,
            to_width,
            existing_update,
            introduction,
        )) orelse
            return try statusJson(ctx.allocator, "unsupported", "The page insertion point could not be located.");
    } else if (std.mem.eql(u8, mode, "relative")) blk: {
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
    const generated_mode: GeneratedEditMode = if (std.mem.eql(u8, mode, "absolute"))
        .absolute
    else if (std.mem.eql(u8, mode, "relative"))
        .relative
    else
        .width;
    const dimensions_unchanged =
        @abs(to_width - from_width) <= @as(f64, core.layout.graph.ConstraintTolerance) and
        @abs(to_height - from_height) <= @as(f64, core.layout.graph.ConstraintTolerance);
    const replacements = if (!binding_required and generated_mode != .width and dimensions_unchanged)
        try fastConstraintReplacements(
            ctx.allocator,
            &layout.report,
            source,
            path,
            page_span,
            node_id,
            edit_result.edits,
        )
    else
        try ctx.allocator.alloc(GeneratedConstraintReplacement, 0);
    defer ctx.allocator.free(replacements);
    const generated = GeneratedEdit{
        .path = path,
        .base_source = source,
        .source = edited_source,
        .base_generation = snapshot.generation,
        .base_snapshot_id = editor.model.snapshot_id,
        .node_id = node_id,
        .page_id = editing.page_id,
        .mode = generated_mode,
        .replacements = replacements,
    };
    try ctx.on_generated(ctx.generated_context, &generated);
    const uri = try protocol.uriFromPath(ctx.allocator, path);
    defer ctx.allocator.free(uri);
    return try editStatusJson(ctx.allocator, uri, source, edit_result.edits);
}

fn fastConstraintReplacements(
    allocator: std.mem.Allocator,
    report: *const core.layout.conflicts.Report,
    source: []const u8,
    path: []const u8,
    page_span: utils.source.ByteSpan,
    node_id: core.NodeId,
    edits: []const editor_edit.TextEdit,
) ![]GeneratedConstraintReplacement {
    var replacements = std.ArrayList(GeneratedConstraintReplacement).empty;
    errdefer replacements.deinit(allocator);

    for (edits) |edit| {
        if (edit.end < edit.start or edit.end > source.len) return discardConstraintReplacements(allocator, &replacements);
        const previous_text = source[edit.start..edit.end];
        if (std.mem.eql(u8, previous_text, edit.text)) continue;
        if (edit.start == edit.end or edit.text.len != previous_text.len) {
            return discardConstraintReplacements(allocator, &replacements);
        }
        const parsed_previous = parseNumericOffset(previous_text) orelse
            return discardConstraintReplacements(allocator, &replacements);
        const parsed_replacement = parseNumericOffset(edit.text) orelse
            return discardConstraintReplacements(allocator, &replacements);
        if (!std.math.isFinite(parsed_previous) or
            !std.math.isFinite(parsed_replacement) or
            @abs(parsed_replacement) > std.math.floatMax(f32))
        {
            return discardConstraintReplacements(allocator, &replacements);
        }

        var matched: ?core.layout.conflicts.Relation = null;
        for (report.relations) |relation| {
            if (relation.kind != .explicit or
                relation.constraint_index == null or
                relation.target_node != node_id or
                relation.role != .position)
            {
                continue;
            }
            const location = relation.location orelse continue;
            if (!std.mem.eql(u8, location.path, path) or
                location.start < page_span.start or
                location.end > page_span.end)
            {
                continue;
            }
            const syntax = relation.syntax orelse continue;
            const offset_span = syntax.offset orelse continue;
            if (offset_span.start != edit.start or offset_span.end != edit.end) continue;
            if (matched != null) return discardConstraintReplacements(allocator, &replacements);
            matched = relation;
        }
        const relation = matched orelse return discardConstraintReplacements(allocator, &replacements);
        const constraint_index = relation.constraint_index.?;
        for (replacements.items) |replacement| {
            if (replacement.index == constraint_index) return discardConstraintReplacements(allocator, &replacements);
        }
        const literal_scale = numericLiteralScale(
            source,
            relation.syntax.?,
            .{ .start = edit.start, .end = edit.end },
            previous_text,
            parsed_previous,
            relation.offset,
        ) orelse return discardConstraintReplacements(allocator, &replacements);
        const semantic_offset = parsed_replacement * literal_scale;
        if (!std.math.isFinite(semantic_offset) or @abs(semantic_offset) > std.math.floatMax(f32)) {
            return discardConstraintReplacements(allocator, &replacements);
        }
        const new_offset: f32 = @floatCast(semantic_offset);
        if (!std.math.isFinite(new_offset)) return discardConstraintReplacements(allocator, &replacements);
        try replacements.append(allocator, .{
            .index = constraint_index,
            .expected = .{
                .target_node = relation.target_node,
                .target_anchor = relation.target_anchor,
                .source = relation.source,
                .offset = relation.offset,
                .origin = relation.origin,
                .role = relation.role,
                .scope_depth = relation.scope_depth,
                .from_update = relation.from_update,
            },
            .offset_span = .{ .start = edit.start, .end = edit.end },
            .literal_scale = @floatCast(literal_scale),
            .new_offset = new_offset,
        });
    }

    if (replacements.items.len == 0) {
        replacements.deinit(allocator);
        return try allocator.alloc(GeneratedConstraintReplacement, 0);
    }
    return try replacements.toOwnedSlice(allocator);
}

fn emptyConstraintReplacements(allocator: std.mem.Allocator) ![]GeneratedConstraintReplacement {
    return try allocator.alloc(GeneratedConstraintReplacement, 0);
}

fn discardConstraintReplacements(
    allocator: std.mem.Allocator,
    replacements: *std.ArrayList(GeneratedConstraintReplacement),
) ![]GeneratedConstraintReplacement {
    replacements.deinit(allocator);
    replacements.* = .empty;
    return try emptyConstraintReplacements(allocator);
}

fn parseNumericOffset(text: []const u8) ?f64 {
    var remaining = std.mem.trim(u8, text, " \t\r\n");
    if (remaining.len == 0) return null;
    var sign: f64 = 1;
    if (remaining[0] == '+' or remaining[0] == '-') {
        if (remaining[0] == '-') sign = -1;
        remaining = std.mem.trim(u8, remaining[1..], " \t\r\n");
    }
    if (remaining.len == 0) return null;
    const value = std.fmt.parseFloat(f64, remaining) catch return null;
    return sign * value;
}

fn numericLiteralScale(
    source: []const u8,
    syntax: core.layout.conflicts.ConstraintSyntax,
    offset_span: utils.source.ByteSpan,
    previous_text: []const u8,
    parsed_previous: f64,
    evaluated_offset: f32,
) ?f64 {
    const tolerance = @as(f64, core.layout.graph.ConstraintTolerance);
    const evaluated = @as(f64, evaluated_offset);
    if (@abs(parsed_previous) <= tolerance and @abs(evaluated) <= tolerance) {
        const trimmed = std.mem.trim(u8, previous_text, " \t\r\n");
        if (trimmed.len != 0 and (trimmed[0] == '-' or trimmed[0] == '+')) return 1;
        const source_span = syntax.source orelse return 1;
        if (source_span.end > offset_span.start or offset_span.start > source.len) return null;
        const operator = std.mem.trim(u8, source[source_span.end..offset_span.start], " \t\r\n");
        if (operator.len == 0) return 1;
        return switch (operator[operator.len - 1]) {
            '-' => -1,
            '+' => 1,
            else => null,
        };
    }
    if (@abs(parsed_previous - evaluated) <= tolerance) return 1;
    if (@abs(-parsed_previous - evaluated) <= tolerance) return -1;
    return null;
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
