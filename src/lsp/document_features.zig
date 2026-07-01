const std = @import("std");
const ast = @import("ast");

const analysis_document = @import("../analysis/document_features.zig");
const protocol = @import("protocol.zig");

pub fn documentSymbolsFromProgramJson(allocator: std.mem.Allocator, text: []const u8, program: ast.Program) ![]const u8 {
    const symbols = try analysis_document.documentSymbolsFromProgram(allocator, text, program);
    defer analysis_document.deinitDocumentSymbols(allocator, symbols);

    var out = std.ArrayList(u8).empty;
    try out.append(allocator, '[');
    for (symbols, 0..) |symbol, index| {
        if (index != 0) try out.append(allocator, ',');
        try appendSymbolValue(allocator, &out, symbol);
    }
    try out.append(allocator, ']');
    return out.toOwnedSlice(allocator);
}

pub fn foldingRangesFromProgramJson(allocator: std.mem.Allocator, text: []const u8, program: ast.Program) ![]const u8 {
    const ranges = try analysis_document.foldingRangesFromProgram(allocator, text, program);
    defer allocator.free(ranges);

    var out = std.ArrayList(u8).empty;
    try out.append(allocator, '[');
    for (ranges, 0..) |range, index| {
        if (index != 0) try out.append(allocator, ',');
        try appendFoldingValue(allocator, &out, range);
    }
    try out.append(allocator, ']');
    return out.toOwnedSlice(allocator);
}

pub fn semanticTokensJson(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    const tokens = try analysis_document.semanticTokens(allocator, text);
    defer allocator.free(tokens);

    var out = std.ArrayList(u8).empty;
    try out.appendSlice(allocator, "{\"data\":[");
    var previous_line: usize = 0;
    var previous_start: usize = 0;
    for (tokens, 0..) |token, index| {
        if (index != 0) try out.append(allocator, ',');
        const delta_line = token.line - previous_line;
        const delta_start = if (delta_line == 0) token.start - previous_start else token.start;
        try protocol.appendInt(allocator, &out, delta_line);
        try out.append(allocator, ',');
        try protocol.appendInt(allocator, &out, delta_start);
        try out.append(allocator, ',');
        try protocol.appendInt(allocator, &out, token.length);
        try out.append(allocator, ',');
        try protocol.appendInt(allocator, &out, token.token_type);
        try out.appendSlice(allocator, ",0");
        previous_line = token.line;
        previous_start = token.start;
    }
    try out.appendSlice(allocator, "]}");
    return out.toOwnedSlice(allocator);
}

pub fn documentColorsJson(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    const colors = try analysis_document.documentColors(allocator, text);
    defer allocator.free(colors);

    var out = std.ArrayList(u8).empty;
    try out.append(allocator, '[');
    for (colors, 0..) |color, index| {
        if (index != 0) try out.append(allocator, ',');
        try out.appendSlice(allocator, "{\"range\":");
        try appendAnalysisRange(allocator, &out, color.range);
        try out.appendSlice(allocator, ",\"color\":{\"red\":");
        try protocol.appendFloat(allocator, &out, color.red);
        try out.appendSlice(allocator, ",\"green\":");
        try protocol.appendFloat(allocator, &out, color.green);
        try out.appendSlice(allocator, ",\"blue\":");
        try protocol.appendFloat(allocator, &out, color.blue);
        try out.appendSlice(allocator, ",\"alpha\":1}}");
    }
    try out.append(allocator, ']');
    return out.toOwnedSlice(allocator);
}

pub fn colorPresentationsJson(allocator: std.mem.Allocator, red: f64, green: f64, blue: f64) ![]const u8 {
    const label = try std.fmt.allocPrint(allocator, "c\"#{x:0>2}{x:0>2}{x:0>2}\"", .{ toByte(red), toByte(green), toByte(blue) });
    defer allocator.free(label);
    var out = std.ArrayList(u8).empty;
    try out.appendSlice(allocator, "[{\"label\":");
    try protocol.appendJsonString(allocator, &out, label);
    try out.appendSlice(allocator, "}]");
    return out.toOwnedSlice(allocator);
}

fn appendSymbolValue(allocator: std.mem.Allocator, out: *std.ArrayList(u8), symbol: analysis_document.DocumentSymbol) !void {
    try out.appendSlice(allocator, "{\"name\":");
    try protocol.appendJsonString(allocator, out, symbol.name);
    try out.appendSlice(allocator, ",\"kind\":");
    try protocol.appendInt(allocator, out, symbol.kind);
    try out.appendSlice(allocator, ",\"range\":");
    try appendAnalysisRange(allocator, out, symbol.range);
    try out.appendSlice(allocator, ",\"selectionRange\":");
    try appendAnalysisRange(allocator, out, symbol.selection_range);
    try out.append(allocator, '}');
}

fn appendFoldingValue(allocator: std.mem.Allocator, out: *std.ArrayList(u8), range: analysis_document.FoldingRange) !void {
    try out.appendSlice(allocator, "{\"startLine\":");
    try protocol.appendInt(allocator, out, range.start_line);
    try out.appendSlice(allocator, ",\"endLine\":");
    try protocol.appendInt(allocator, out, range.end_line);
    try out.append(allocator, '}');
}

fn appendAnalysisRange(allocator: std.mem.Allocator, out: *std.ArrayList(u8), range: analysis_document.Range) !void {
    try out.appendSlice(allocator, "{\"start\":{\"line\":");
    try protocol.appendInt(allocator, out, range.start.line);
    try out.appendSlice(allocator, ",\"character\":");
    try protocol.appendInt(allocator, out, range.start.character);
    try out.appendSlice(allocator, "},\"end\":{\"line\":");
    try protocol.appendInt(allocator, out, range.end.line);
    try out.appendSlice(allocator, ",\"character\":");
    try protocol.appendInt(allocator, out, range.end.character);
    try out.appendSlice(allocator, "}}");
}

fn toByte(value: f64) u8 {
    return @intFromFloat(@max(0, @min(255, std.math.round(value * 255.0))));
}
