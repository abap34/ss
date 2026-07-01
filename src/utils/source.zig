const std = @import("std");

pub const ByteSpan = struct {
    start: usize,
    end: usize,
};

pub const Location = struct {
    line: usize,
    column: usize,
};

pub const Utf16Position = struct {
    line: usize,
    character: usize,
};

pub const Line = struct {
    number: usize,
    span: ByteSpan,
    raw_end: usize,

    pub fn text(self: Line, source: []const u8) []const u8 {
        return source[self.span.start..self.span.end];
    }
};

pub const LineIterator = struct {
    source: []const u8,
    next_start: usize = 0,
    next_number: usize = 1,

    pub fn next(self: *LineIterator) ?Line {
        if (self.next_start > self.source.len) return null;
        const line_start = self.next_start;
        const raw_line_end = std.mem.indexOfScalarPos(u8, self.source, line_start, '\n') orelse self.source.len;
        const line_end = if (raw_line_end > line_start and self.source[raw_line_end - 1] == '\r') raw_line_end - 1 else raw_line_end;
        self.next_start = if (raw_line_end == self.source.len) self.source.len + 1 else raw_line_end + 1;
        const number = self.next_number;
        self.next_number += 1;
        return .{
            .number = number,
            .span = .{ .start = line_start, .end = line_end },
            .raw_end = raw_line_end,
        };
    }
};

pub const SpanView = struct {
    span: ByteSpan,
    trimmed: ByteSpan,

    pub fn isEmpty(self: SpanView) bool {
        return self.trimmed.start >= self.trimmed.end;
    }

    pub fn text(self: SpanView, source: []const u8) []const u8 {
        return source[self.trimmed.start..self.trimmed.end];
    }
};

pub const CodeByte = struct {
    pos: usize,
    byte: u8,
};

pub const CodeByteIterator = struct {
    source: []const u8,
    index: usize,
    end: usize,

    pub fn next(self: *CodeByteIterator) ?CodeByte {
        while (self.index < self.end) {
            const pos = self.index;
            const byte = self.source[pos];
            if (byte == '"') {
                self.index = skipDoubleQuotedString(self.source, pos, self.end);
                continue;
            }
            self.index += 1;
            return .{ .pos = pos, .byte = byte };
        }
        return null;
    }
};

pub fn lineIterator(source: []const u8) LineIterator {
    return .{ .source = source };
}

pub fn startsWithAt(source: []const u8, pos: usize, needle: []const u8) bool {
    if (pos > source.len) return false;
    return std.mem.startsWith(u8, source[pos..], needle);
}

pub fn lineAt(source: []const u8, byte_index: usize) Line {
    const limit = @min(byte_index, source.len);
    var line_number: usize = 1;
    var line_start: usize = 0;
    var index: usize = 0;
    while (index < limit) : (index += 1) {
        if (source[index] == '\n') {
            line_number += 1;
            line_start = index + 1;
        }
    }
    const raw_end = std.mem.indexOfScalarPos(u8, source, line_start, '\n') orelse source.len;
    const trimmed_end = if (raw_end > line_start and source[raw_end - 1] == '\r') raw_end - 1 else raw_end;
    return .{
        .number = line_number,
        .span = .{ .start = line_start, .end = trimmed_end },
        .raw_end = raw_end,
    };
}

pub fn lineByNumber(source: []const u8, number: usize) ?Line {
    var lines = lineIterator(source);
    while (lines.next()) |line| {
        if (line.number == number) return line;
    }
    return null;
}

pub fn lineCount(source: []const u8) usize {
    if (source.len == 0) return 1;
    var count: usize = 1;
    for (source) |ch| {
        if (ch == '\n') count += 1;
    }
    return count;
}

pub fn locationAt(source: []const u8, byte_index: usize) Location {
    var line: usize = 1;
    var line_start: usize = 0;
    const limit = @min(byte_index, source.len);
    var index: usize = 0;
    while (index < limit) : (index += 1) {
        if (source[index] == '\n') {
            line += 1;
            line_start = index + 1;
        }
    }
    const prefix = source[line_start..limit];
    const column = (std.unicode.utf8CountCodepoints(prefix) catch prefix.len) + 1;
    return .{ .line = line, .column = column };
}

pub fn utf16PositionAt(source: []const u8, byte_offset: usize) Utf16Position {
    const limit = @min(byte_offset, source.len);
    var line: usize = 0;
    var line_start: usize = 0;
    var index: usize = 0;
    while (index < limit) : (index += 1) {
        if (source[index] == '\n') {
            line += 1;
            line_start = index + 1;
        }
    }
    return .{
        .line = line,
        .character = utf16Units(source[line_start..limit]),
    };
}

pub fn offsetForUtf16Position(source: []const u8, target_line: usize, target_character: usize) usize {
    var line: usize = 0;
    var line_start: usize = 0;
    var index: usize = 0;
    while (index < source.len and line < target_line) : (index += 1) {
        if (source[index] == '\n') {
            line += 1;
            line_start = index + 1;
        }
    }
    if (line < target_line) return source.len;

    var character: usize = 0;
    index = line_start;
    while (index < source.len and source[index] != '\n') {
        if (character >= target_character) return index;
        const len = std.unicode.utf8ByteSequenceLength(source[index]) catch 1;
        const end = @min(index + len, source.len);
        const cp = std.unicode.utf8Decode(source[index..end]) catch source[index];
        const width: usize = if (cp >= 0x10000) 2 else 1;
        if (character + width > target_character) return index;
        character += width;
        index = end;
    }
    return index;
}

pub fn utf16Units(bytes: []const u8) usize {
    var units: usize = 0;
    var index: usize = 0;
    while (index < bytes.len) {
        const len = std.unicode.utf8ByteSequenceLength(bytes[index]) catch 1;
        const end = @min(index + len, bytes.len);
        const cp = std.unicode.utf8Decode(bytes[index..end]) catch bytes[index];
        units += if (cp > 0xFFFF) @as(usize, 2) else 1;
        index = end;
    }
    return units;
}

pub fn spanView(source: []const u8, span: ByteSpan) SpanView {
    return .{
        .span = span,
        .trimmed = trimInlineSpaceSpan(source, span),
    };
}

pub fn trimInlineSpaceSpan(source: []const u8, span: ByteSpan) ByteSpan {
    var first = @min(span.start, source.len);
    const end = @min(span.end, source.len);
    while (first < end and isInlineSpace(source[first])) first += 1;
    var last = end;
    while (last > first and isInlineSpace(source[last - 1])) last -= 1;
    return .{ .start = first, .end = last };
}

pub fn trimWhitespaceSpan(source: []const u8, span: ByteSpan) ByteSpan {
    var first = @min(span.start, source.len);
    const end = @min(span.end, source.len);
    while (first < end and std.ascii.isWhitespace(source[first])) first += 1;
    var last = end;
    while (last > first and std.ascii.isWhitespace(source[last - 1])) last -= 1;
    return .{ .start = first, .end = last };
}

pub fn skipInlineSpacesUntil(source: []const u8, start: usize, end: usize) usize {
    var index = start;
    const limit = @min(end, source.len);
    while (index < limit and isInlineSpace(source[index])) index += 1;
    return index;
}

pub fn skipInlineSpaces(source: []const u8, pos: *usize) void {
    pos.* = skipInlineSpacesUntil(source, pos.*, source.len);
}

pub fn skipWhitespaceUntil(source: []const u8, start: usize, end: usize) usize {
    var index = start;
    const limit = @min(end, source.len);
    while (index < limit and std.ascii.isWhitespace(source[index])) index += 1;
    return index;
}

pub fn codeBytes(source: []const u8, start: usize, end: usize) CodeByteIterator {
    return .{
        .source = source,
        .index = @min(start, source.len),
        .end = @min(end, source.len),
    };
}

pub fn wordSpanAt(source: []const u8, offset: usize, comptime isWordByte: fn (u8) bool) ?ByteSpan {
    const pos = @min(offset, source.len);
    const line = lineAt(source, pos).span;
    var start = pos;
    while (start > line.start and isWordByte(source[start - 1])) start -= 1;
    var end = pos;
    while (end < line.end and isWordByte(source[end])) end += 1;
    if (end <= start) return null;
    return .{ .start = start, .end = end };
}

pub fn isIdentifierStart(ch: u8) bool {
    return std.ascii.isAlphabetic(ch) or ch == '_';
}

pub fn isIdentifierContinue(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_';
}

pub fn isInlineSpace(ch: u8) bool {
    return ch == ' ' or ch == '\t' or ch == '\r';
}

pub fn lineCommentMarkerLength(source: []const u8, pos: usize) ?usize {
    if (pos >= source.len) return null;
    if (source[pos] == '#') return 1;
    if (pos + 1 >= source.len) return null;
    if (source[pos] == '/' and source[pos + 1] == '/') return 2;
    if (source[pos] == ';' and source[pos + 1] == ';') return 2;
    return null;
}

pub fn stripLineComment(line: []const u8) []const u8 {
    var bytes = codeBytes(line, 0, line.len);
    while (bytes.next()) |item| {
        if (lineCommentMarkerLength(line, item.pos) != null) return line[0..item.pos];
    }
    return line;
}

pub fn skipLineComment(source: []const u8, pos: *usize) void {
    while (pos.* < source.len and source[pos.*] != '\n') pos.* += 1;
}

pub fn skipTriviaFrom(source: []const u8, pos: *usize) void {
    while (pos.* < source.len) {
        const after_whitespace = skipWhitespaceUntil(source, pos.*, source.len);
        if (after_whitespace != pos.*) {
            pos.* = after_whitespace;
            continue;
        }
        if (lineCommentMarkerLength(source, pos.*)) |marker_len| {
            pos.* += marker_len;
            skipLineComment(source, pos);
            continue;
        }
        return;
    }
}

pub fn skipDoubleQuotedString(source: []const u8, start: usize, limit: usize) usize {
    return skipQuotedString(source, start, limit, '"');
}

pub fn skipQuotedString(source: []const u8, start: usize, limit: usize, quote: u8) usize {
    var index = @min(start + 1, source.len);
    const end = @min(limit, source.len);
    while (index < end) : (index += 1) {
        if (source[index] == '\\') {
            index += 1;
            continue;
        }
        if (source[index] == quote) return index + 1;
    }
    return end;
}
