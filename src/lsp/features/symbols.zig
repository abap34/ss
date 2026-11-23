const std = @import("std");
const LineIndex = @import("utils").source.LineIndex;
const json = @import("utils").json;

const analysis_snapshot = @import("../../analysis/snapshot.zig");
const syntax = @import("../../syntax.zig");
const source_pages = @import("../source_pages.zig");
const query_symbols = @import("../../analysis/query/symbols.zig");
const protocol = @import("../protocol.zig");
const lsp_state = @import("../state.zig");

const LspRange = protocol.Range;

pub const Context = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    provider: *lsp_state.AnalysisProvider,
    documents: *lsp_state.DocumentStore,
};

pub fn result(ctx: *Context, params: ?protocol.JsonValue) ![]const u8 {
    ctx.provider.beginQuery(1000);
    const doc_path = try protocol.docPathFromParams(ctx.allocator, params) orelse return try ctx.allocator.dupe(u8, "[]");
    defer ctx.allocator.free(doc_path);
    const snapshot = try ctx.provider.forDocument(doc_path) orelse return try ctx.allocator.dupe(u8, "[]");
    if (!lsp_state.featureEnabledForAnalysis(snapshot, .document_symbols)) return try ctx.allocator.dupe(u8, "[]");
    const module = snapshot.moduleForPath(doc_path) orelse return try ctx.allocator.dupe(u8, "[]");
    return jsonWithIndex(ctx.allocator, module.line_index, analysis_snapshot.documentSymbols(snapshot, doc_path));
}

pub fn codeLenses(ctx: *Context, params: ?protocol.JsonValue) ![]const u8 {
    var doc = try lsp_state.documentTextFromParams(ctx.io, ctx.allocator, ctx.documents, params) orelse return try ctx.allocator.dupe(u8, "[]");
    defer doc.deinit(ctx.allocator);
    const uri = try protocol.uriFromPath(ctx.allocator, doc.path);
    defer ctx.allocator.free(uri);

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(ctx.allocator);
    var lenses = try json.Array.beginBuffer(ctx.allocator, &out);
    const starts = doc.page_starts orelse try source_pages.collect(ctx.allocator, doc.source, "", &.{});
    defer if (doc.page_starts == null) ctx.allocator.free(starts);
    for (starts) |offset| {
        var lens = try lenses.objectItem();
        const source_range = protocol.rangeFromIndex(doc.line_index, .{ .start = offset, .end = offset + 4 });
        var range = try lens.objectField("range");
        var start = try range.objectField("start");
        try start.intField("line", source_range.start_line);
        try start.intField("character", source_range.start_character);
        try start.end();
        var end = try range.objectField("end");
        try end.intField("line", source_range.end_line);
        try end.intField("character", source_range.end_character);
        try end.end();
        try range.end();
        var command = try lens.objectField("command");
        try command.stringField("title", "Jump to slide");
        try command.stringField("command", "ss.editor.revealPage");
        var arguments = try command.arrayField("arguments");
        var target = try arguments.objectItem();
        try target.stringField("uri", uri);
        try target.intField("start", offset);
        try target.optionalIntField("version", ctx.documents.versionForPath(doc.path));
        try target.end();
        try arguments.end();
        try command.end();
        try lens.end();
    }
    try lenses.end();
    return try out.toOwnedSlice(ctx.allocator);
}

/// Physical page boundaries come from the compiler's surface AST, before
/// includes and stages expand. Null pages mean syntax is still being edited;
/// clients should retain their existing decorations until a complete parse.
pub fn pageRanges(ctx: *Context, params: ?protocol.JsonValue) ![]const u8 {
    var doc = try lsp_state.documentTextFromParams(ctx.io, ctx.allocator, ctx.documents, params) orelse return try ctx.allocator.dupe(u8, "null");
    defer doc.deinit(ctx.allocator);
    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();
    const parsed: ?syntax.Surface.Module = syntax.parseSurface(arena.allocator(), doc.source) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => null,
    };
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(ctx.allocator);
    var result_object = try json.Object.beginBuffer(ctx.allocator, &out);
    try result_object.optionalIntField("version", ctx.documents.versionForPath(doc.path));
    if (parsed) |module| {
        var pages = try result_object.arrayField("pages");
        for (module.pages.items) |page| {
            const range = protocol.rangeFromIndex(doc.line_index, .{ .start = page.span.start, .end = page.span.end - 1 });
            var item = try pages.objectItem();
            try item.intField("startLine", range.start_line);
            try item.intField("endLine", range.end_line);
            try item.end();
        }
        try pages.end();
    } else {
        try result_object.nullField("pages");
    }
    try result_object.end();
    return out.toOwnedSlice(ctx.allocator);
}

const DocumentSymbol = struct {
    name: []const u8,
    kind: usize,
    range: LspRange,
    selection_range: LspRange,
};

fn jsonWithIndex(allocator: std.mem.Allocator, text: LineIndex, symbols: []const query_symbols.Symbol) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    try out.append(allocator, '[');
    for (symbols, 0..) |symbol, index| {
        if (index != 0) try out.append(allocator, ',');
        try appendValue(allocator, &out, documentSymbol(text, symbol));
    }
    try out.append(allocator, ']');
    return out.toOwnedSlice(allocator);
}

fn documentSymbol(text: LineIndex, symbol: query_symbols.Symbol) DocumentSymbol {
    return .{
        .name = symbol.name,
        .kind = symbolKind(symbol.kind),
        .range = protocol.rangeFromIndex(text, symbol.span),
        .selection_range = protocol.rangeFromIndex(text, symbol.selection_span),
    };
}

fn symbolKind(kind: query_symbols.Kind) usize {
    return switch (kind) {
        .function => 12,
        .constant => 13,
        .page => 5,
        .enum_type => 5,
        .record => 23,
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
