const std = @import("std");
const ast = @import("ast");
const utils = @import("utils");

const language_names = @import("../language/names.zig");
const source = utils.source;

pub const Position = struct {
    line: usize,
    character: usize,
};

pub const Range = struct {
    start: Position,
    end: Position,
};

pub const DocumentSymbol = struct {
    name: []u8,
    kind: usize,
    range: Range,
    selection_range: Range,
};

pub const FoldingRange = struct {
    start_line: usize,
    end_line: usize,
};

pub const SemanticToken = struct {
    line: usize,
    start: usize,
    length: usize,
    token_type: usize,
};

pub const DocumentColor = struct {
    range: Range,
    red: f64,
    green: f64,
    blue: f64,
};

pub fn deinitDocumentSymbols(allocator: std.mem.Allocator, symbols: []DocumentSymbol) void {
    for (symbols) |symbol| allocator.free(symbol.name);
    allocator.free(symbols);
}

pub fn documentSymbolsFromProgram(allocator: std.mem.Allocator, text: []const u8, program: ast.Program) ![]DocumentSymbol {
    var out = std.ArrayList(DocumentSymbol).empty;
    errdefer {
        for (out.items) |symbol| allocator.free(symbol.name);
        out.deinit(allocator);
    }

    for (program.functions.items) |decl| try appendSymbolFromSpan(allocator, &out, text, decl.name, 12, decl.span);
    for (program.constants.items) |decl| try appendSymbolFromSpan(allocator, &out, text, decl.name, 13, decl.span);
    for (program.pages.items) |decl| try appendSymbolFromSpan(allocator, &out, text, decl.name, 5, decl.span);
    for (program.types.items) |decl| try appendSymbolFromSpan(allocator, &out, text, decl.name, 5, decl.span);
    for (program.records.items) |decl| try appendSymbolFromSpan(allocator, &out, text, decl.name, 23, decl.span);
    for (program.objects.items) |decl| try appendSymbolFromSpan(allocator, &out, text, decl.name, 5, decl.span);

    return out.toOwnedSlice(allocator);
}

pub fn foldingRangesFromProgram(allocator: std.mem.Allocator, text: []const u8, program: ast.Program) ![]FoldingRange {
    var out = std.ArrayList(FoldingRange).empty;
    errdefer out.deinit(allocator);

    for (program.functions.items) |decl| try appendFoldingFromSpan(allocator, &out, text, decl.span);
    for (program.pages.items) |decl| try appendFoldingFromSpan(allocator, &out, text, decl.span);
    for (program.document_blocks.items) |decl| try appendFoldingFromSpan(allocator, &out, text, decl.span);
    for (program.records.items) |decl| try appendFoldingFromSpan(allocator, &out, text, decl.span);
    for (program.objects.items) |decl| try appendFoldingFromSpan(allocator, &out, text, decl.span);
    for (program.object_extensions.items) |decl| try appendFoldingFromSpan(allocator, &out, text, decl.span);

    return out.toOwnedSlice(allocator);
}

pub fn semanticTokens(allocator: std.mem.Allocator, text: []const u8) ![]SemanticToken {
    var tokens = std.ArrayList(SemanticToken).empty;
    errdefer tokens.deinit(allocator);

    var lines = source.lineIterator(text);
    while (lines.next()) |view| {
        try scanSemanticLine(allocator, &tokens, view.text(text), view.number - 1);
    }

    return tokens.toOwnedSlice(allocator);
}

pub fn documentColors(allocator: std.mem.Allocator, text: []const u8) ![]DocumentColor {
    var out = std.ArrayList(DocumentColor).empty;
    errdefer out.deinit(allocator);

    var index: usize = 0;
    while (std.mem.indexOfPos(u8, text, index, "c\"")) |start| {
        const end = source.skipDoubleQuotedString(text, start + 1, text.len);
        if (end <= text.len) if (parseColor(text[start..end])) |rgb| {
            try out.append(allocator, .{
                .range = rangeFromSpan(text, .{ .start = start, .end = end }),
                .red = rgb[0],
                .green = rgb[1],
                .blue = rgb[2],
            });
        };
        index = @max(end, start + 2);
    }

    return out.toOwnedSlice(allocator);
}

pub fn rangeFromSpan(text: []const u8, span: source.ByteSpan) Range {
    const start = source.utf16PositionAt(text, @min(span.start, text.len));
    const end = source.utf16PositionAt(text, @min(@max(span.end, span.start + 1), text.len));
    return .{
        .start = .{ .line = start.line, .character = start.character },
        .end = .{ .line = end.line, .character = end.character },
    };
}

fn appendSymbolFromSpan(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(DocumentSymbol),
    text: []const u8,
    name: []const u8,
    kind: usize,
    span: ast.Span,
) !void {
    try out.append(allocator, .{
        .name = try allocator.dupe(u8, name),
        .kind = kind,
        .range = rangeFromSpan(text, .{ .start = span.start, .end = span.end }),
        .selection_range = rangeFromSpan(text, nameSpan(text, span, name)),
    });
}

fn nameSpan(text: []const u8, span: ast.Span, name: []const u8) source.ByteSpan {
    const start = @min(span.start, text.len);
    const end = @min(@max(span.end, span.start), text.len);
    if (std.mem.indexOf(u8, text[start..end], name)) |offset| {
        return .{ .start = start + offset, .end = start + offset + name.len };
    }
    return .{ .start = start, .end = @min(start + name.len, text.len) };
}

fn appendFoldingFromSpan(allocator: std.mem.Allocator, out: *std.ArrayList(FoldingRange), text: []const u8, span: ast.Span) !void {
    const range = rangeFromSpan(text, .{ .start = span.start, .end = span.end });
    if (range.end.line <= range.start.line) return;
    try out.append(allocator, .{ .start_line = range.start.line, .end_line = range.end.line });
}

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
            const previous = previousNonSpace(line, start);
            if (semanticTokenType(word, previous_word, next, previous)) |kind| {
                try appendSemanticToken(allocator, tokens, line, line_index, start, index, kind);
            }
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
    const red = std.fmt.parseFloat(f64, std.mem.trim(u8, parts.next() orelse return null, " \t")) catch return null;
    const green = std.fmt.parseFloat(f64, std.mem.trim(u8, parts.next() orelse return null, " \t")) catch return null;
    const blue = std.fmt.parseFloat(f64, std.mem.trim(u8, parts.next() orelse return null, " \t")) catch return null;
    if (parts.next() != null) return null;
    return .{ red, green, blue };
}
