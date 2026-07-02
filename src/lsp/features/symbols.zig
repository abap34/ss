const std = @import("std");

const analysis_snapshot = @import("../../analysis/snapshot.zig");
const query_symbols = @import("../../analysis/query/symbols.zig");
const protocol = @import("../protocol.zig");
const lsp_state = @import("../state.zig");

const LspRange = protocol.Range;

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
    if (!lsp_state.featureEnabledForSnapshot(snapshot, .document_symbols)) return try ctx.allocator.dupe(u8, "[]");
    const text = analysis_snapshot.sourceForPath(snapshot, doc_path) orelse return try ctx.allocator.dupe(u8, "[]");
    return json(ctx.allocator, text, analysis_snapshot.documentSymbols(snapshot, doc_path));
}

const DocumentSymbol = struct {
    name: []const u8,
    kind: usize,
    range: LspRange,
    selection_range: LspRange,
};

pub fn json(allocator: std.mem.Allocator, text: []const u8, symbols: []const query_symbols.Symbol) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    try out.append(allocator, '[');
    for (symbols, 0..) |symbol, index| {
        if (index != 0) try out.append(allocator, ',');
        try appendValue(allocator, &out, documentSymbol(text, symbol));
    }
    try out.append(allocator, ']');
    return out.toOwnedSlice(allocator);
}

fn documentSymbol(text: []const u8, symbol: query_symbols.Symbol) DocumentSymbol {
    return .{
        .name = symbol.name,
        .kind = symbolKind(symbol.kind),
        .range = protocol.rangeFromSpan(text, symbol.span),
        .selection_range = protocol.rangeFromSpan(text, symbol.selection_span),
    };
}

fn symbolKind(kind: query_symbols.Kind) usize {
    return switch (kind) {
        .function => 12,
        .constant => 13,
        .page => 5,
        .enum_type => 5,
        .record => 23,
        .object_class => 5,
    };
}

fn appendValue(allocator: std.mem.Allocator, out: *std.ArrayList(u8), symbol: DocumentSymbol) !void {
    try out.appendSlice(allocator, "{\"name\":");
    try protocol.appendJsonString(allocator, out, symbol.name);
    try out.appendSlice(allocator, ",\"kind\":");
    try protocol.appendInt(allocator, out, symbol.kind);
    try out.appendSlice(allocator, ",\"range\":");
    try protocol.appendRange(allocator, out, symbol.range);
    try out.appendSlice(allocator, ",\"selectionRange\":");
    try protocol.appendRange(allocator, out, symbol.selection_range);
    try out.append(allocator, '}');
}
