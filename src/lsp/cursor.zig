const std = @import("std");
const core = @import("core");
const utils = @import("utils");
const language_names = @import("../language/names.zig");

const source = utils.source;

pub const PositionRequest = struct {
    doc_path: []u8,
    source: []const u8,
    offset: usize,
    line: usize,
    character: usize,

    pub fn deinit(self: *PositionRequest, allocator: std.mem.Allocator) void {
        allocator.free(self.doc_path);
    }
};

pub const TargetRequest = struct {
    target: []u8,
    doc_path: []u8,
    source: []const u8,
    offset: usize,

    pub fn deinit(self: *TargetRequest, allocator: std.mem.Allocator) void {
        allocator.free(self.target);
        allocator.free(self.doc_path);
    }
};

pub fn offsetForPosition(text: []const u8, line: usize, character: usize) usize {
    return source.offsetForUtf16Position(text, line, character);
}

pub fn wordAt(allocator: std.mem.Allocator, text: []const u8, target_line: usize, character: usize) !?[]u8 {
    const pos = offsetForPosition(text, target_line, character);
    const span = source.wordSpanAt(text, pos, language_names.isCallableNameChar) orelse return null;
    return try allocator.dupe(u8, text[span.start..span.end]);
}

pub fn targetAtPosition(allocator: std.mem.Allocator, text: []const u8, line: usize, character: usize) !?[]u8 {
    const offset = offsetForPosition(text, line, character);
    return try wordAt(allocator, text, line, character) orelse if (importSpecAtOffset(text, offset)) |spec|
        try allocator.dupe(u8, spec)
    else
        null;
}

pub fn qualifiedAliasBeforeOffset(text: []const u8, offset: usize) ?[]const u8 {
    var cursor = @min(offset, text.len);
    while (cursor > 0 and language_names.isCallableNameChar(text[cursor - 1])) cursor -= 1;
    if (cursor < 2 or !std.mem.eql(u8, text[cursor - 2 .. cursor], "::")) return null;
    var alias_start = cursor - 2;
    while (alias_start > 0 and source.isIdentifierContinue(text[alias_start - 1])) alias_start -= 1;
    if (alias_start == cursor - 2) return null;
    return text[alias_start .. cursor - 2];
}

pub fn targetFollowedByDoubleColon(request: *const TargetRequest) bool {
    const bounds = source.wordSpanAt(request.source, request.offset, language_names.isCallableNameChar) orelse return false;
    return bounds.end + 2 <= request.source.len and std.mem.eql(u8, request.source[bounds.end .. bounds.end + 2], "::");
}

pub fn isImportAliasTarget(request: *const TargetRequest) bool {
    const bounds = source.wordSpanAt(request.source, request.offset, language_names.isCallableNameChar) orelse return false;
    const line_span = source.lineAt(request.source, bounds.start).span;
    const line = request.source[line_span.start..line_span.end];
    const trimmed = std.mem.trim(u8, line, " \t");
    if (!std.mem.startsWith(u8, trimmed, "import ")) return false;
    const as_index = std.mem.lastIndexOf(u8, line, " as ") orelse return false;
    return bounds.start >= line_span.start + as_index + " as ".len;
}

pub fn importSpecAtOffset(text: []const u8, offset: usize) ?[]const u8 {
    const pos = @min(offset, text.len);
    const line_span = source.lineAt(text, pos).span;
    const line_start = line_span.start;
    const line_end = line_span.end;

    var cursor = source.skipInlineSpacesUntil(text, line_start, line_end);
    if (cursor + "import".len > line_end or !std.mem.eql(u8, text[cursor .. cursor + "import".len], "import")) return null;
    cursor += "import".len;
    if (cursor >= line_end or !source.isInlineSpace(text[cursor])) return null;
    cursor = source.skipInlineSpacesUntil(text, cursor, line_end);
    if (cursor >= line_end) return null;

    const spec_start = cursor;
    const inner_start: usize = if (text[cursor] == '"') blk: {
        cursor += 1;
        break :blk cursor;
    } else spec_start;
    while (cursor < line_end) : (cursor += 1) {
        if (text[spec_start] == '"') {
            if (text[cursor] == '"') break;
        } else if (source.isInlineSpace(text[cursor])) {
            break;
        }
    }
    const inner_end = cursor;
    const spec_end = if (cursor < line_end and text[spec_start] == '"') cursor + 1 else cursor;
    if (pos < spec_start or pos > spec_end) return null;
    if (inner_end <= inner_start) return null;
    return text[inner_start..inner_end];
}

pub fn definitionKindForRequest(request: *const TargetRequest) core.DefinitionKind {
    if (std.mem.endsWith(u8, request.target, "!")) return .function;
    const bounds = source.wordSpanAt(request.source, request.offset, language_names.isCallableNameChar) orelse return .constant;
    const line = source.lineAt(request.source, bounds.end).span;
    const cursor = source.skipInlineSpacesUntil(request.source, bounds.end, line.end);
    if (cursor < line.end and request.source[cursor] == '(') return .function;
    return .constant;
}
