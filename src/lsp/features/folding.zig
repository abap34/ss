const std = @import("std");

const analysis_snapshot = @import("../../analysis/snapshot.zig");
const query_folding = @import("../../analysis/query/folding.zig");
const protocol = @import("../protocol.zig");
const lsp_state = @import("../state.zig");

pub const Context = struct {
    allocator: std.mem.Allocator,
    provider: *lsp_state.SnapshotProvider,
};

pub fn result(ctx: *Context, params: ?protocol.JsonValue) ![]const u8 {
    const doc_path = try protocol.docPathFromParams(ctx.allocator, params) orelse return try ctx.allocator.dupe(u8, "[]");
    defer ctx.allocator.free(doc_path);
    var owned_snapshot: ?lsp_state.Snapshot = null;
    defer if (owned_snapshot) |*snapshot| snapshot.deinit();
    const snapshot = try ctx.provider.forDocument(doc_path, &owned_snapshot) orelse return try ctx.allocator.dupe(u8, "[]");
    if (!lsp_state.featureEnabledForSnapshot(snapshot, .folding_ranges)) return try ctx.allocator.dupe(u8, "[]");
    const text = analysis_snapshot.sourceForPath(snapshot, doc_path) orelse return try ctx.allocator.dupe(u8, "[]");
    return json(ctx.allocator, text, analysis_snapshot.foldingRanges(snapshot, doc_path));
}

const FoldingRange = struct {
    start_line: usize,
    end_line: usize,
};

pub fn json(allocator: std.mem.Allocator, text: []const u8, ranges: []const query_folding.Range) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    try out.append(allocator, '[');
    var emitted: usize = 0;
    for (ranges) |range| {
        const folding = foldingRange(text, range) orelse continue;
        if (emitted != 0) try out.append(allocator, ',');
        emitted += 1;
        try appendValue(allocator, &out, folding);
    }
    try out.append(allocator, ']');
    return out.toOwnedSlice(allocator);
}

fn foldingRange(text: []const u8, range: query_folding.Range) ?FoldingRange {
    const lsp_range = protocol.rangeFromSpan(text, range.span);
    if (lsp_range.end_line <= lsp_range.start_line) return null;
    return .{
        .start_line = lsp_range.start_line,
        .end_line = lsp_range.end_line,
    };
}

fn appendValue(allocator: std.mem.Allocator, out: *std.ArrayList(u8), range: FoldingRange) !void {
    try out.appendSlice(allocator, "{\"startLine\":");
    try protocol.appendInt(allocator, out, range.start_line);
    try out.appendSlice(allocator, ",\"endLine\":");
    try protocol.appendInt(allocator, out, range.end_line);
    try out.append(allocator, '}');
}
