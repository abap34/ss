const std = @import("std");
const ast = @import("ast");
const language_names = @import("../language/names.zig");
const protocol = @import("protocol.zig");
const utils = @import("utils");

const source = utils.source;

pub fn documentSymbolsJson(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    try out.append(allocator, '[');
    var first = true;
    var lines = source.lineIterator(text);
    while (lines.next()) |view| {
        const line_index = view.number - 1;
        const line = view.text(text);
        const trimmed = trimLineStart(line);
        const kind: ?usize = if (std.mem.startsWith(u8, trimmed, "fn "))
            12
        else if (std.mem.startsWith(u8, trimmed, "const "))
            13
        else if (std.mem.startsWith(u8, trimmed, "page "))
            5
        else if (std.mem.startsWith(u8, trimmed, "type "))
            5
        else
            null;
        if (kind == null) continue;
        const name = symbolName(trimmed) orelse continue;
        if (!first) try out.append(allocator, ',');
        first = false;
        try appendSymbol(allocator, &out, name, kind.?, line_index, 0, line_index, line.len);
    }
    try out.append(allocator, ']');
    return out.toOwnedSlice(allocator);
}

pub fn documentSymbolsFromProgramJson(allocator: std.mem.Allocator, text: []const u8, program: ast.Program) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    try out.append(allocator, '[');
    var first = true;
    for (program.functions.items) |decl| {
        try appendSymbolFromSpan(allocator, &out, &first, text, decl.name, 12, decl.span);
    }
    for (program.constants.items) |decl| {
        try appendSymbolFromSpan(allocator, &out, &first, text, decl.name, 13, decl.span);
    }
    for (program.pages.items) |decl| {
        try appendSymbolFromSpan(allocator, &out, &first, text, decl.name, 5, decl.span);
    }
    for (program.types.items) |decl| {
        try appendSymbolFromSpan(allocator, &out, &first, text, decl.name, 5, decl.span);
    }
    for (program.records.items) |decl| {
        try appendSymbolFromSpan(allocator, &out, &first, text, decl.name, 23, decl.span);
    }
    for (program.objects.items) |decl| {
        try appendSymbolFromSpan(allocator, &out, &first, text, decl.name, 5, decl.span);
    }
    try out.append(allocator, ']');
    return out.toOwnedSlice(allocator);
}

pub fn foldingRangesJson(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    try out.append(allocator, '[');
    var first = true;
    var stack = std.ArrayList(usize).empty;
    defer stack.deinit(allocator);
    var block_start: ?usize = null;
    var lines = source.lineIterator(text);
    while (lines.next()) |view| {
        const line_index = view.number - 1;
        const line = view.text(text);
        const trimmed = trimLineStart(line);
        if (std.mem.startsWith(u8, trimmed, "page ") or std.mem.startsWith(u8, trimmed, "fn ")) {
            try stack.append(allocator, line_index);
        } else if (std.mem.eql(u8, std.mem.trim(u8, trimmed, " \t\r"), "end") and stack.items.len != 0) {
            const start = stack.pop().?;
            try appendFolding(allocator, &out, &first, start, line_index);
        }
        if (std.mem.endsWith(u8, std.mem.trim(u8, line, " \t\r"), "<<")) block_start = line_index;
        if (block_start) |start| if (std.mem.eql(u8, std.mem.trim(u8, line, " \t\r"), ">>") and line_index > start) {
            try appendFolding(allocator, &out, &first, start, line_index);
            block_start = null;
        };
    }
    try out.append(allocator, ']');
    return out.toOwnedSlice(allocator);
}

pub fn foldingRangesFromProgramJson(allocator: std.mem.Allocator, text: []const u8, program: ast.Program) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    try out.append(allocator, '[');
    var first = true;
    for (program.functions.items) |decl| try appendFoldingFromSpan(allocator, &out, &first, text, decl.span);
    for (program.pages.items) |decl| try appendFoldingFromSpan(allocator, &out, &first, text, decl.span);
    for (program.document_blocks.items) |decl| try appendFoldingFromSpan(allocator, &out, &first, text, decl.span);
    for (program.records.items) |decl| try appendFoldingFromSpan(allocator, &out, &first, text, decl.span);
    for (program.objects.items) |decl| try appendFoldingFromSpan(allocator, &out, &first, text, decl.span);
    for (program.object_extensions.items) |decl| try appendFoldingFromSpan(allocator, &out, &first, text, decl.span);
    try out.append(allocator, ']');
    return out.toOwnedSlice(allocator);
}

pub fn semanticTokensJson(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var tokens = std.ArrayList(SemanticToken).empty;
    defer tokens.deinit(allocator);
    var lines = source.lineIterator(text);
    while (lines.next()) |view| {
        const line_index = view.number - 1;
        const line = view.text(text);
        try scanSemanticLine(allocator, &tokens, line, line_index);
    }

    var out = std.ArrayList(u8).empty;
    try out.appendSlice(allocator, "{\"data\":[");
    var previous_line: usize = 0;
    var previous_start: usize = 0;
    for (tokens.items, 0..) |token, i| {
        if (i != 0) try out.append(allocator, ',');
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
    var out = std.ArrayList(u8).empty;
    try out.append(allocator, '[');
    var first = true;
    var index: usize = 0;
    while (std.mem.indexOfPos(u8, text, index, "c\"")) |start| {
        const end = source.skipDoubleQuotedString(text, start + 1, text.len);
        if (end <= text.len) if (parseColor(text[start..end])) |rgb| {
            if (!first) try out.append(allocator, ',');
            first = false;
            const range = protocol.rangeFromSpan(text, .{ .start = start, .end = end });
            try out.appendSlice(allocator, "{\"range\":");
            try protocol.appendRange(allocator, &out, range);
            try out.appendSlice(allocator, ",\"color\":{\"red\":");
            try protocol.appendFloat(allocator, &out, rgb[0]);
            try out.appendSlice(allocator, ",\"green\":");
            try protocol.appendFloat(allocator, &out, rgb[1]);
            try out.appendSlice(allocator, ",\"blue\":");
            try protocol.appendFloat(allocator, &out, rgb[2]);
            try out.appendSlice(allocator, ",\"alpha\":1}}");
        };
        index = @max(end, start + 2);
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

fn trimLineStart(line: []const u8) []const u8 {
    const start = source.skipInlineSpacesUntil(line, 0, line.len);
    return line[start..];
}

fn symbolName(line: []const u8) ?[]const u8 {
    var it = std.mem.tokenizeAny(u8, line, " \t(:=");
    _ = it.next() orelse return null;
    return it.next();
}

fn appendSymbol(allocator: std.mem.Allocator, out: *std.ArrayList(u8), name: []const u8, kind: usize, sl: usize, sc: usize, el: usize, ec: usize) !void {
    try out.appendSlice(allocator, "{\"name\":");
    try protocol.appendJsonString(allocator, out, name);
    try out.appendSlice(allocator, ",\"kind\":");
    try protocol.appendInt(allocator, out, kind);
    try out.appendSlice(allocator, ",\"range\":{\"start\":{\"line\":");
    try protocol.appendInt(allocator, out, sl);
    try out.appendSlice(allocator, ",\"character\":");
    try protocol.appendInt(allocator, out, sc);
    try out.appendSlice(allocator, "},\"end\":{\"line\":");
    try protocol.appendInt(allocator, out, el);
    try out.appendSlice(allocator, ",\"character\":");
    try protocol.appendInt(allocator, out, ec);
    try out.appendSlice(allocator, "}},\"selectionRange\":{\"start\":{\"line\":");
    try protocol.appendInt(allocator, out, sl);
    try out.appendSlice(allocator, ",\"character\":");
    try protocol.appendInt(allocator, out, sc);
    try out.appendSlice(allocator, "},\"end\":{\"line\":");
    try protocol.appendInt(allocator, out, el);
    try out.appendSlice(allocator, ",\"character\":");
    try protocol.appendInt(allocator, out, ec);
    try out.appendSlice(allocator, "}}}");
}

fn appendSymbolFromSpan(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    first: *bool,
    text: []const u8,
    name: []const u8,
    kind: usize,
    span: ast.Span,
) !void {
    const range = protocol.rangeFromSpan(text, .{ .start = span.start, .end = span.end });
    const selection = protocol.rangeFromSpan(text, nameSpan(text, span, name));
    if (!first.*) try out.append(allocator, ',');
    first.* = false;
    try out.appendSlice(allocator, "{\"name\":");
    try protocol.appendJsonString(allocator, out, name);
    try out.appendSlice(allocator, ",\"kind\":");
    try protocol.appendInt(allocator, out, kind);
    try out.appendSlice(allocator, ",\"range\":");
    try protocol.appendRange(allocator, out, range);
    try out.appendSlice(allocator, ",\"selectionRange\":");
    try protocol.appendRange(allocator, out, selection);
    try out.append(allocator, '}');
}

fn nameSpan(text: []const u8, span: ast.Span, name: []const u8) source.ByteSpan {
    const start = @min(span.start, text.len);
    const end = @min(@max(span.end, span.start), text.len);
    if (std.mem.indexOf(u8, text[start..end], name)) |offset| {
        return .{ .start = start + offset, .end = start + offset + name.len };
    }
    return .{ .start = start, .end = @min(start + name.len, text.len) };
}

fn appendFolding(allocator: std.mem.Allocator, out: *std.ArrayList(u8), first: *bool, start: usize, end: usize) !void {
    if (end <= start) return;
    if (!first.*) try out.append(allocator, ',');
    first.* = false;
    try out.appendSlice(allocator, "{\"startLine\":");
    try protocol.appendInt(allocator, out, start);
    try out.appendSlice(allocator, ",\"endLine\":");
    try protocol.appendInt(allocator, out, end);
    try out.append(allocator, '}');
}

fn appendFoldingFromSpan(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    first: *bool,
    text: []const u8,
    span: ast.Span,
) !void {
    const range = protocol.rangeFromSpan(text, .{ .start = span.start, .end = span.end });
    try appendFolding(allocator, out, first, range.start_line, range.end_line);
}

const SemanticToken = struct {
    line: usize,
    start: usize,
    length: usize,
    token_type: usize,
};

fn scanSemanticLine(allocator: std.mem.Allocator, tokens: *std.ArrayList(SemanticToken), line: []const u8, line_index: usize) !void {
    var index: usize = 0;
    var previous_word: ?[]const u8 = null;
    while (index < line.len) {
        const byte = line[index];
        if (byte == ';' and index + 1 < line.len and line[index + 1] == ';') break;
        if (byte == '/' and index + 1 < line.len and line[index + 1] == '/') break;
        if (byte == '#') break;
        if (source.isInlineSpace(byte)) {
            index += 1;
            continue;
        }
        if (byte == ':' and index + 1 < line.len and line[index + 1] == ':') {
            try appendSemanticToken(allocator, tokens, line, line_index, index, index + 2, 7);
            previous_word = null;
            index += 2;
            continue;
        }
        if ((byte == 'c' and index + 1 < line.len and line[index + 1] == '"') or byte == '"') {
            const start = index;
            const quote_start = if (byte == 'c') index + 1 else index;
            index = source.skipDoubleQuotedString(line, quote_start, line.len);
            try appendSemanticToken(allocator, tokens, line, line_index, start, @min(index, line.len), 3);
            previous_word = null;
            continue;
        }
        if (std.ascii.isDigit(byte)) {
            const start = index;
            index += 1;
            while (index < line.len and (std.ascii.isDigit(line[index]) or line[index] == '.')) index += 1;
            try appendSemanticToken(allocator, tokens, line, line_index, start, index, 4);
            previous_word = null;
            continue;
        }
        if (source.isIdentifierStart(byte)) {
            const start = index;
            index += 1;
            while (index < line.len and language_names.isCallableNameChar(line[index])) index += 1;
            const word = line[start..index];
            const next = nextNonSpace(line, index);
            const prev = previousNonSpace(line, start);
            const token_type = semanticTokenType(word, previous_word, next, prev);
            if (token_type) |kind| try appendSemanticToken(allocator, tokens, line, line_index, start, index, kind);
            previous_word = word;
            continue;
        }
        previous_word = null;
        index += std.unicode.utf8ByteSequenceLength(byte) catch 1;
    }
}

fn appendSemanticToken(
    allocator: std.mem.Allocator,
    tokens: *std.ArrayList(SemanticToken),
    line: []const u8,
    line_index: usize,
    start: usize,
    end: usize,
    token_type: usize,
) !void {
    try tokens.append(allocator, .{
        .line = line_index,
        .start = source.utf16Units(line[0..start]),
        .length = @max(1, source.utf16Units(line[start..end])),
        .token_type = token_type,
    });
}

fn semanticTokenType(word: []const u8, previous_word: ?[]const u8, next: ?u8, previous: ?u8) ?usize {
    if (language_names.isKeyword(word)) return 0;
    if (isBuiltinType(word) or std.ascii.isUpper(word[0])) return 5;
    if (previous == '.') return 6;
    if (previous_word) |prev| {
        if (std.mem.eql(u8, prev, "fn")) return 1;
        if (std.mem.eql(u8, prev, "let") or std.mem.eql(u8, prev, "const")) return 2;
    }
    if (next == '(') return 1;
    return null;
}

fn isBuiltinType(word: []const u8) bool {
    const types = [_][]const u8{ "document", "page", "object", "selection", "anchor", "string", "number", "bool", "boolean", "constraints", "void", "Void" };
    for (types) |name| if (std.mem.eql(u8, word, name)) return true;
    return false;
}

fn nextNonSpace(line: []const u8, start: usize) ?u8 {
    const index = source.skipInlineSpacesUntil(line, start, line.len);
    return if (index < line.len) line[index] else null;
}

fn previousNonSpace(line: []const u8, start: usize) ?u8 {
    const span = source.trimInlineSpaceSpan(line, .{ .start = 0, .end = start });
    return if (span.end > 0) line[span.end - 1] else null;
}

fn parseColor(literal: []const u8) ?[3]f64 {
    if (literal.len < 3 or literal[0] != 'c' or literal[1] != '"' or literal[literal.len - 1] != '"') return null;
    const inner = literal[2 .. literal.len - 1];
    if (inner.len == 7 and inner[0] == '#') {
        return .{
            @as(f64, @floatFromInt(std.fmt.parseUnsigned(u8, inner[1..3], 16) catch return null)) / 255.0,
            @as(f64, @floatFromInt(std.fmt.parseUnsigned(u8, inner[3..5], 16) catch return null)) / 255.0,
            @as(f64, @floatFromInt(std.fmt.parseUnsigned(u8, inner[5..7], 16) catch return null)) / 255.0,
        };
    }
    var parts = std.mem.splitScalar(u8, inner, ',');
    const r = std.fmt.parseFloat(f64, std.mem.trim(u8, parts.next() orelse return null, " \t")) catch return null;
    const g = std.fmt.parseFloat(f64, std.mem.trim(u8, parts.next() orelse return null, " \t")) catch return null;
    const b = std.fmt.parseFloat(f64, std.mem.trim(u8, parts.next() orelse return null, " \t")) catch return null;
    if (parts.next() != null) return null;
    return .{ r, g, b };
}

fn toByte(value: f64) u8 {
    return @intFromFloat(@max(0, @min(255, std.math.round(value * 255.0))));
}
