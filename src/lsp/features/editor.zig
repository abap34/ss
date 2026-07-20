const std = @import("std");

const editor_snapshot = @import("../../editor/snapshot.zig");
const protocol = @import("../protocol.zig");
const lsp_state = @import("../state.zig");

pub const Context = struct {
    allocator: std.mem.Allocator,
    documents: *lsp_state.DocumentStore,
    provider: *lsp_state.AnalysisProvider,
    responses: *lsp_state.ResponseStore,
    diagnostics: *const lsp_state.ResponseStore,
    snapshot_cache: *editor_snapshot.Cache,
};

pub fn snapshotResult(ctx: *Context, params: ?protocol.JsonValue) ![]const u8 {
    var owned_snapshot: ?lsp_state.AnalysisSnapshot = null;
    defer if (owned_snapshot) |*snapshot| snapshot.deinit();

    const doc_path = try protocol.docPathFromParams(ctx.allocator, params);
    defer if (doc_path) |path| ctx.allocator.free(path);
    const snapshot = blk: {
        if (doc_path) |path| break :blk try ctx.provider.forDocument(path, &owned_snapshot);
        break :blk ctx.provider.current;
    } orelse return try editor_snapshot.emptyJson(ctx.allocator);

    if (snapshot.generation == ctx.documents.generation) {
        if (snapshot.layout_output) |*layout| {
            if (layout.editor) |*editor| {
                if (editor.model.display_fingerprint != null) {
                    try ctx.responses.store(ctx.allocator, snapshot, editor.json);
                }
                const base_snapshot_id = baseSnapshotId(params);
                const result = if (base_snapshot_id.len != 0 and displayMatches(ctx.snapshot_cache, &editor.model, base_snapshot_id))
                    try editor_snapshot.rebaseUnchangedDisplayJson(ctx.allocator, editor, base_snapshot_id)
                else
                    try ctx.allocator.dupe(u8, editor.json);
                errdefer ctx.allocator.free(result);
                return result;
            }
        }
    }
    if (try ctx.responses.cloneForEntry(ctx.allocator, snapshot.project.entry_path)) |cached| {
        defer ctx.allocator.free(cached);
        return try staleSnapshotWithErrors(ctx, snapshot.project.entry_path, cached);
    }
    const empty = try editor_snapshot.emptyJson(ctx.allocator);
    defer ctx.allocator.free(empty);
    return try staleSnapshotWithErrors(ctx, snapshot.project.entry_path, empty);
}

fn baseSnapshotId(params: ?protocol.JsonValue) []const u8 {
    const value = params orelse return "";
    const object = switch (value) {
        .object => |*item| item,
        else => return "",
    };
    return protocol.stringField(object, "baseSnapshotId") orelse "";
}

fn displayMatches(cache: *const editor_snapshot.Cache, model: *const editor_snapshot.Model, base_snapshot_id: []const u8) bool {
    const current = model.display_fingerprint orelse return false;
    const base = cache.displayForSnapshot(base_snapshot_id) orelse return false;
    return std.mem.eql(u8, &current, &base);
}

fn staleSnapshotWithErrors(ctx: *Context, entry_path: []const u8, source: []const u8) ![]u8 {
    const diagnostics = try ctx.diagnostics.cloneForEntry(ctx.allocator, entry_path) orelse
        return try staleSnapshot(ctx.allocator, source, "[]");
    defer ctx.allocator.free(diagnostics);
    return try staleSnapshot(ctx.allocator, source, diagnostics);
}

fn staleSnapshot(
    allocator: std.mem.Allocator,
    source: []const u8,
    diagnostics_json: []const u8,
) ![]u8 {
    const trimmed = std.mem.trim(u8, source, " \t\r\n");
    if (trimmed.len == 0 or trimmed[trimmed.len - 1] != '}') return try allocator.dupe(u8, source);
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, trimmed[0 .. trimmed.len - 1]);
    try out.appendSlice(allocator, ",\"stale\":true,\"build_diagnostics\":");
    try out.appendSlice(allocator, diagnostics_json);
    try out.appendSlice(allocator, "}\n");
    return try out.toOwnedSlice(allocator);
}
