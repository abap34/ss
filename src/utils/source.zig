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

// The text is borrowed from the source generation; only line starts are owned.
pub const LineIndex = struct {
    text: []const u8,
    starts: []usize,

    pub const empty: LineIndex = .{ .text = "", .starts = &.{} };

    pub fn init(allocator: std.mem.Allocator, text: []const u8) !LineIndex {
        const starts = try allocator.alloc(usize, lineCount(text));
        starts[0] = 0;
        var next: usize = 1;
        for (text, 0..) |byte, index| {
            if (byte == '\n') {
                starts[next] = index + 1;
                next += 1;
            }
        }
        return .{ .text = text, .starts = starts };
    }

    pub fn clone(self: LineIndex, allocator: std.mem.Allocator, text: []const u8) !LineIndex {
        std.debug.assert(self.text.len == text.len);
        return .{ .text = text, .starts = try allocator.dupe(usize, self.starts) };
    }

    pub fn deinit(self: LineIndex, allocator: std.mem.Allocator) void {
        allocator.free(self.starts);
    }

    pub fn lineAt(self: LineIndex, byte_offset: usize) Line {
        const number = self.lineNumber(byte_offset);
        return self.lineByNumber(number + 1).?;
    }

    pub fn lineByNumber(self: LineIndex, number: usize) ?Line {
        if (number == 0 or number > @max(self.starts.len, 1)) return null;
        const index = number - 1;
        const start = if (self.starts.len == 0) 0 else self.starts[index];
        const raw_end = if (number < self.starts.len) self.starts[number] - 1 else self.text.len;
        const end = if (raw_end > start and self.text[raw_end - 1] == '\r') raw_end - 1 else raw_end;
        return .{ .number = number, .span = .{ .start = start, .end = end }, .raw_end = raw_end };
    }

    pub fn locationAt(self: LineIndex, byte_offset: usize) Location {
        const line = self.lineAt(byte_offset);
        const prefix = self.text[line.span.start..@min(byte_offset, self.text.len)];
        return .{
            .line = line.number,
            .column = (std.unicode.utf8CountCodepoints(prefix) catch prefix.len) + 1,
        };
    }

    pub fn utf16PositionAt(self: LineIndex, byte_offset: usize) Utf16Position {
        const line = self.lineAt(byte_offset);
        return .{
            .line = line.number - 1,
            .character = utf16Units(self.text[line.span.start..@min(byte_offset, self.text.len)]),
        };
    }

    pub fn offsetForUtf16Position(self: LineIndex, target_line: usize, target_character: usize) usize {
        if (target_line >= @max(self.starts.len, 1)) return self.text.len;
        const line = self.lineByNumber(target_line + 1).?;
        return offsetInLine(self.text, line.span.start, line.raw_end, target_character);
    }

    fn lineNumber(self: LineIndex, byte_offset: usize) usize {
        const limit = @min(byte_offset, self.text.len);
        var low: usize = 0;
        var high = self.starts.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (self.starts[middle] <= limit) low = middle + 1 else high = middle;
        }
        return low -| 1;
    }
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

pub fn lineSpanAt(source: []const u8, byte_index: usize) ByteSpan {
    const limit = @min(byte_index, source.len);
    const start = if (std.mem.lastIndexOfScalar(u8, source[0..limit], '\n')) |newline| newline + 1 else 0;
    const raw_end = std.mem.indexOfScalarPos(u8, source, limit, '\n') orelse source.len;
    const end = if (raw_end > start and source[raw_end - 1] == '\r') raw_end - 1 else raw_end;
    return .{ .start = start, .end = end };
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
    const line_end = std.mem.indexOfScalarPos(u8, source, line_start, '\n') orelse source.len;
    return offsetInLine(source, line_start, line_end, target_character);
}

fn offsetInLine(source: []const u8, line_start: usize, line_end: usize, target_character: usize) usize {
    var character: usize = 0;
    var index = line_start;
    while (index < line_end) {
        if (character >= target_character) return index;
        const unit = utf8Unit(source[0..line_end], index);
        if (unit.width > target_character - character) return index;
        character += unit.width;
        index = unit.end;
    }
    return index;
}

pub fn utf16Units(bytes: []const u8) usize {
    var units: usize = 0;
    var index: usize = 0;
    while (index < bytes.len) {
        const unit = utf8Unit(bytes, index);
        units += unit.width;
        index = unit.end;
    }
    return units;
}

const Utf8Unit = struct { end: usize, width: usize };

fn utf8Unit(bytes: []const u8, index: usize) Utf8Unit {
    const fallback = Utf8Unit{ .end = index + 1, .width = 1 };
    const length = std.unicode.utf8ByteSequenceLength(bytes[index]) catch return fallback;
    if (length > bytes.len - index) return fallback;
    const end = index + length;
    const codepoint = std.unicode.utf8Decode(bytes[index..end]) catch return fallback;
    return .{ .end = end, .width = if (codepoint > 0xffff) 2 else 1 };
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
    const line = lineSpanAt(source, pos);
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
