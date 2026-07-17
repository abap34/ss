const std = @import("std");

const editor_snapshot = @import("../../editor/snapshot.zig");
const protocol = @import("../protocol.zig");
const lsp_state = @import("../state.zig");

pub const Context = struct {
    allocator: std.mem.Allocator,
    documents: *lsp_state.DocumentStore,
    provider: *lsp_state.AnalysisProvider,
    responses: *lsp_state.ResponseStore,
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
            if (layout.editor_json) |editor_json| {
                const result = try ctx.allocator.dupe(u8, editor_json);
                errdefer ctx.allocator.free(result);
                try ctx.responses.store(ctx.allocator, snapshot, result);
                return result;
            }
        }
    }
    if (try ctx.responses.cloneForEntry(ctx.allocator, snapshot.project.entry_path)) |cached| {
        defer ctx.allocator.free(cached);
        return try staleSnapshot(ctx.allocator, cached);
    }
    return try editor_snapshot.emptyJson(ctx.allocator);
}

fn staleSnapshot(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, source, " \t\r\n");
    if (trimmed.len == 0 or trimmed[trimmed.len - 1] != '}') return try allocator.dupe(u8, source);
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, trimmed[0 .. trimmed.len - 1]);
    try out.appendSlice(allocator, ",\"stale\":true}\n");
    return try out.toOwnedSlice(allocator);
}
