const std = @import("std");
const core = @import("core");
const scene = @import("../scene.zig");
const measure = @import("measure.zig");

pub const Kind = enum {
    glyphs,
    resource,
};

pub const Atom = struct {
    kind: Kind,
    text: []const u8 = "",
    font: scene.FontFace,
    font_size: f32,
    color: scene.Color,
    width: f32,
    height: f32 = 0,
    resource_id: ?scene.ResourceId = null,
    is_space: bool = false,
    is_emoji: bool = false,
    strikethrough: bool = false,
    link_url: ?[]const u8 = null,
    tint: ?scene.Color = null,
};

pub const TextPaint = core.render_policy.TextPaint;

pub fn appendTextAtoms(
    allocator: std.mem.Allocator,
    atoms: *std.ArrayList(Atom),
    value: []const u8,
    font: scene.FontFace,
    color: scene.Color,
    font_size: f32,
    link_url: ?[]const u8,
    strikethrough: bool,
) !void {
    var tokenizer = Tokenizer.init(value);
    while (tokenizer.next()) |token| {
        const emoji = isEmojiToken(token);
        const measured_width = if (emoji)
            try measure.visualWidth(allocator, token, font, font_size)
        else
            try measure.width(allocator, token, font, font_size);
        const width = if (emoji) @max(measured_width, font_size * 1.05) else measured_width;
        try atoms.append(allocator, .{
            .kind = .glyphs,
            .text = token,
            .font = font,
            .font_size = font_size,
            .color = color,
            .width = width,
            .is_space = isWhitespace(token),
            .is_emoji = emoji,
            .strikethrough = strikethrough,
            .link_url = link_url,
        });
    }
}

pub fn appendResourceAtom(
    allocator: std.mem.Allocator,
    atoms: *std.ArrayList(Atom),
    resource_id: scene.ResourceId,
    width: f32,
    height: f32,
    font: scene.FontFace,
    font_size: f32,
    color: scene.Color,
) !void {
    try atoms.append(allocator, .{
        .kind = .resource,
        .font = font,
        .font_size = font_size,
        .color = color,
        .width = @max(width, 1),
        .height = @max(height, 1),
        .resource_id = resource_id,
        .tint = color,
    });
}

pub fn advance(atoms: []const Atom, index: usize, emoji_spacing: f32, inline_resource_spacing: f32) f32 {
    const atom = atoms[index];
    return switch (atom.kind) {
        .glyphs => atom.width + glyphSpacingAfter(atoms, index, emoji_spacing),
        .resource => atom.width + atom.font_size * inline_resource_spacing,
    };
}

fn glyphSpacingAfter(atoms: []const Atom, index: usize, emoji_spacing: f32) f32 {
    if (index + 1 >= atoms.len) return 0;
    if (!atoms[index].is_emoji or atoms[index + 1].is_space) return 0;
    return atoms[index].font_size * emoji_spacing;
}

const Tokenizer = struct {
    text: []const u8,
    index: usize = 0,

    fn init(text: []const u8) Tokenizer {
        return .{ .text = text };
    }

    fn next(self: *Tokenizer) ?[]const u8 {
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

fn utf8ByteSequenceLength(first: u8) usize {
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

fn isWhitespace(text: []const u8) bool {
    for (text) |byte| {
        if (byte != ' ' and byte != '\t' and byte != '\r' and byte != '\n') return false;
    }
    return text.len > 0;
}

fn isEmojiToken(text: []const u8) bool {
    if (text.len == 0) return false;
    const first = utf8CodepointAt(text, 0);
    return first.len > 0 and isEmojiStart(first.value);
}
