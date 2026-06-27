const std = @import("std");

pub const Tokenizer = struct {
    text: []const u8,
    index: usize = 0,

    pub fn init(text: []const u8) Tokenizer {
        return .{ .text = text };
    }

    pub fn next(self: *Tokenizer) ?[]const u8 {
        if (self.index >= self.text.len) return null;
        const start = self.index;
        const first_codepoint = utf8CodepointAt(self.text, self.index);
        const first_len = first_codepoint.len;
        const first_end = @min(self.text.len, self.index + first_len);
        const first = self.text[start..first_end];
        self.index = first_end;

        if (isWhitespace(first)) {
            while (self.index < self.text.len) {
                const len = utf8ByteSequenceLength(self.text[self.index]);
                const end = @min(self.text.len, self.index + len);
                if (!isWhitespace(self.text[self.index..end])) break;
                self.index = end;
            }
            return self.text[start..self.index];
        }

        if (isEmojiStart(first_codepoint.value)) {
            self.index = consumeEmojiSequence(self.text, self.index, first_codepoint.value);
            return self.text[start..self.index];
        }

        if (isAsciiWordByte(first[0])) {
            while (self.index < self.text.len and isAsciiWordByte(self.text[self.index])) self.index += 1;
            return self.text[start..self.index];
        }

        return first;
    }
};

const Utf8Codepoint = struct {
    value: u21,
    len: usize,
};

fn utf8CodepointAt(text: []const u8, index: usize) Utf8Codepoint {
    if (index >= text.len) return .{ .value = 0, .len = 0 };
    const len = @min(utf8ByteSequenceLength(text[index]), text.len - index);
    const value = std.unicode.utf8Decode(text[index .. index + len]) catch text[index];
    return .{ .value = value, .len = len };
}

pub fn utf8ByteSequenceLength(first: u8) usize {
    if (first < 0x80) return 1;
    if ((first & 0xe0) == 0xc0) return 2;
    if ((first & 0xf0) == 0xe0) return 3;
    if ((first & 0xf8) == 0xf0) return 4;
    return 1;
}

fn consumeEmojiSequence(text: []const u8, index: usize, first: u21) usize {
    var cursor = index;
    if (isRegionalIndicator(first)) {
        const next = utf8CodepointAt(text, cursor);
        if (isRegionalIndicator(next.value)) cursor += next.len;
        return cursor;
    }

    while (cursor < text.len) {
        const next = utf8CodepointAt(text, cursor);
        if (next.len == 0) break;
        if (isEmojiModifier(next.value) or next.value == 0xfe0f) {
            cursor += next.len;
            continue;
        }
        if (next.value == 0x200d) {
            const joiner_start = cursor;
            cursor += next.len;
            const joined = utf8CodepointAt(text, cursor);
            if (joined.len == 0 or !isEmojiStart(joined.value)) return joiner_start;
            cursor += joined.len;
            continue;
        }
        break;
    }
    return cursor;
}

fn isEmojiStart(value: u21) bool {
    return (value >= 0x1f000 and value <= 0x1faff) or
        (value >= 0x2600 and value <= 0x27bf) or
        isRegionalIndicator(value);
}

fn isEmojiModifier(value: u21) bool {
    return (value >= 0x1f3fb and value <= 0x1f3ff) or value == 0xfe0e or value == 0xfe0f;
}

fn isRegionalIndicator(value: u21) bool {
    return value >= 0x1f1e6 and value <= 0x1f1ff;
}

fn isAsciiWordByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '.' or byte == '/' or byte == ':' or byte == '+' or byte == '-';
}

pub fn isWhitespace(text: []const u8) bool {
    for (text) |byte| {
        if (byte != ' ' and byte != '\t' and byte != '\r' and byte != '\n') return false;
    }
    return text.len > 0;
}

pub fn isEmojiToken(text: []const u8) bool {
    if (text.len == 0) return false;
    const first = utf8CodepointAt(text, 0);
    return first.len > 0 and isEmojiStart(first.value);
}
