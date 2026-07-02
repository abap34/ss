const std = @import("std");

const analysis_snapshot = @import("../../analysis/snapshot.zig");
const lsp_state = @import("../state.zig");
const protocol = @import("../protocol.zig");
const query_budget = @import("../query_budget.zig");

pub const Context = struct {
    allocator: std.mem.Allocator,
    provider: *lsp_state.SnapshotProvider,
    documents: *lsp_state.DocumentStore,
};

pub fn result(ctx: *Context, params: ?protocol.JsonValue) ![]const u8 {
    var position = try lsp_state.requestPosition(ctx.allocator, ctx.documents, params) orelse return nullJson(ctx.allocator);
    defer position.deinit(ctx.allocator);
    var owned_snapshot: ?lsp_state.Snapshot = null;
    defer if (owned_snapshot) |*snapshot| snapshot.deinit();
    const snapshot = try ctx.provider.forDocument(position.doc_path, &owned_snapshot) orelse return nullJson(ctx.allocator);
    if (!lsp_state.featureEnabledForSnapshot(snapshot, .hover)) return nullJson(ctx.allocator);
    var hover = try analysis_snapshot.hoverAt(ctx.allocator, snapshot, .{
        .path = position.doc_path,
        .source = position.source,
        .offset = position.offset,
        .source_version = snapshot.generation,
    }, .{ .budget_ms = query_budget.hover_ms }) orelse return nullJson(ctx.allocator);
    defer hover.deinit(ctx.allocator);
    return json(ctx.allocator, hover);
}

pub fn nullJson(allocator: std.mem.Allocator) ![]const u8 {
    return allocator.dupe(u8, "null");
}

pub fn json(allocator: std.mem.Allocator, hover: analysis_snapshot.HoverInfo) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"contents\":{\"kind\":\"markdown\",\"value\":");
    try protocol.appendJsonString(allocator, &out, hover.markdown);
    try out.appendSlice(allocator, "}}");
    return out.toOwnedSlice(allocator);
}
