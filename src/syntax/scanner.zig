const std = @import("std");
const utils = @import("utils");

const source = utils.source;

pub const TokenKind = enum {
    identifier,
    string,
    color_string,
    number,
    qualified_access,
};

pub const Token = struct {
    span: source.ByteSpan,
    line: usize,
    line_start: usize,
    line_end: usize,
    kind: TokenKind,
};

pub const SemanticKind = enum {
    keyword,
    function,
    variable,
    string,
    number,
    type,
    property,
    operator,
};

pub const SemanticToken = struct {
    token: Token,
    kind: SemanticKind,
};

pub const TokenIterator = struct {
    text: []const u8,
    lines: source.LineIterator,
    current_line: ?source.Line = null,
    cursor: usize = 0,

    pub fn next(self: *TokenIterator) ?Token {
        while (true) {
            const line_value = self.currentLine() orelse return null;
            if (self.cursor >= line_value.span.end) {
                self.current_line = null;
                continue;
            }

            const byte = self.text[self.cursor];
            if (source.lineCommentMarkerLength(self.text, self.cursor) != null) {
                self.current_line = null;
                continue;
            }
            if (source.isInlineSpace(byte)) {
                self.cursor += 1;
                continue;
            }
            if (source.startsWithAt(self.text, self.cursor, "::")) {
                return self.advance(line_value, self.cursor + 2, .qualified_access);
            }
            if (source.startsWithAt(self.text, self.cursor, "c\"")) {
                return self.advance(line_value, source.skipDoubleQuotedString(self.text, self.cursor + 1, line_value.span.end), .color_string);
            }
            if (byte == '"') {
                return self.advance(line_value, source.skipDoubleQuotedString(self.text, self.cursor, line_value.span.end), .string);
            }
            if (std.ascii.isDigit(byte)) {
                var end = self.cursor + 1;
                while (end < line_value.span.end and (std.ascii.isDigit(self.text[end]) or self.text[end] == '.')) end += 1;
                return self.advance(line_value, end, .number);
            }
            if (source.isIdentifierStart(byte)) {
                var end = self.cursor + 1;
                while (end < line_value.span.end and isCallableIdentifierContinue(self.text[end])) end += 1;
                return self.advance(line_value, end, .identifier);
            }

            self.cursor += std.unicode.utf8ByteSequenceLength(byte) catch 1;
        }
    }

    fn currentLine(self: *TokenIterator) ?source.Line {
        if (self.current_line == null) {
            self.current_line = self.lines.next() orelse return null;
            self.cursor = self.current_line.?.span.start;
        }
        return self.current_line.?;
    }

    fn advance(self: *TokenIterator, line_value: source.Line, end: usize, kind: TokenKind) Token {
        const start = self.cursor;
        self.cursor = @min(end, line_value.span.end);
        return .{
            .span = .{ .start = start, .end = self.cursor },
            .line = line_value.number - 1,
            .line_start = line_value.span.start,
            .line_end = line_value.span.end,
            .kind = kind,
        };
    }
};

pub fn tokens(text: []const u8) TokenIterator {
    return .{
        .text = text,
        .lines = source.lineIterator(text),
    };
}

pub fn isKeyword(text: []const u8) bool {
    for (keywords) |keyword| if (std.mem.eql(u8, text, keyword)) return true;
    return false;
}

pub fn keywordLabels() []const []const u8 {
    return &keywords;
}

pub fn semanticTokens(allocator: std.mem.Allocator, text: []const u8) ![]SemanticToken {
    var out = std.ArrayList(SemanticToken).empty;
    errdefer out.deinit(allocator);

    var iter = tokens(text);
    var previous_word: ?[]const u8 = null;
    while (iter.next()) |token| {
        const kind = switch (token.kind) {
            .qualified_access => blk: {
                previous_word = null;
                break :blk SemanticKind.operator;
            },
            .string, .color_string => blk: {
                previous_word = null;
                break :blk SemanticKind.string;
            },
            .number => blk: {
                previous_word = null;
                break :blk SemanticKind.number;
            },
            .identifier => blk: {
                const word = text[token.span.start..token.span.end];
                const next = nextNonSpaceByte(text, token.span.end, token.line_end);
                const previous = previousNonSpaceByte(text, token.span.start, token.line_start);
                const semantic_kind = semanticKindForIdentifier(word, previous_word, next, previous) orelse {
                    previous_word = word;
                    continue;
                };
                previous_word = word;
                break :blk semantic_kind;
            },
        };
        try out.append(allocator, .{ .token = token, .kind = kind });
    }

    return out.toOwnedSlice(allocator);
}

pub fn consumeKeywordNoTrivia(text: []const u8, pos: *usize, keyword: []const u8) bool {
    if (!source.startsWithAt(text, pos.*, keyword)) return false;
    const end = pos.* + keyword.len;
    if (end < text.len and source.isIdentifierContinue(text[end])) return false;
    pos.* = end;
    return true;
}

pub fn atStatementBoundary(text: []const u8, pos: usize) bool {
    var probe = pos;
    source.skipInlineSpaces(text, &probe);
    if (probe >= text.len) return true;
    return text[probe] == '\n';
}

pub fn scanIdentifier(text: []const u8, pos: *usize) bool {
    if (pos.* >= text.len or !source.isIdentifierStart(text[pos.*])) return false;
    pos.* += 1;
    while (pos.* < text.len and source.isIdentifierContinue(text[pos.*])) pos.* += 1;
    return true;
}

pub fn nextNonSpaceByte(text: []const u8, start: usize, end: usize) ?u8 {
    const index = source.skipInlineSpacesUntil(text, start, end);
    return if (index < @min(end, text.len)) text[index] else null;
}

pub fn previousNonSpaceByte(text: []const u8, start: usize, lower_bound: usize) ?u8 {
    var cursor = @min(start, text.len);
    const min = @min(lower_bound, cursor);
    while (cursor > min) {
        cursor -= 1;
        if (source.isInlineSpace(text[cursor])) continue;
        return text[cursor];
    }
    return null;
}

pub fn isCallableIdentifierContinue(byte: u8) bool {
    return source.isIdentifierContinue(byte) or byte == '!';
}

fn semanticKindForIdentifier(word: []const u8, previous_word: ?[]const u8, next: ?u8, previous: ?u8) ?SemanticKind {
    if (isKeyword(word)) return .keyword;
    if (std.ascii.isUpper(word[0])) return .type;
    if (previous == '.') return .property;
    if (previous_word) |prev| {
        if (std.mem.eql(u8, prev, "fn")) return .function;
        if (std.mem.eql(u8, prev, "let") or std.mem.eql(u8, prev, "const")) return .variable;
    }
    if (next == '(') return .function;
    return null;
}

const keywords = [_][]const u8{
    "import",
    "as",
    "with",
    "const",
    "document",
    "page",
    "fn",
    "let",
    "bind",
    "return",
    "end",
    "type",
    "record",
    "protocol",
    "extend",
    "base",
    "implements",
    "roles",
    "if",
    "then",
    "else",
    "for",
    "in",
    "property",
};
