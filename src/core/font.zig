const std = @import("std");
const model = @import("model");
const fields = @import("fields.zig");

const Node = model.Node;

pub const Style = enum {
    normal,
    oblique,
    italic,
};

pub const Stretch = enum {
    ultra_condensed,
    extra_condensed,
    condensed,
    semi_condensed,
    normal,
    semi_expanded,
    expanded,
    extra_expanded,
    ultra_expanded,
};

pub const Face = struct {
    family: []const u8,
    weight: u16,
    style: Style,
    stretch: Stretch,
};

pub const TextFaces = struct {
    normal: Face,
    bold: Face,
    italic: Face,
    code: Face,
};

pub const default_family = "Helvetica";
pub const default_code_family = "monospace";
pub const default_weight: u16 = 400;
pub const default_bold_weight: u16 = 700;

pub fn bodyFont(node: *const Node) Face {
    return faceAt(node, "font", &.{}, .{ .family = default_family, .weight = default_weight, .style = .normal, .stretch = .normal });
}

pub fn codeFont(node: *const Node) Face {
    return faceAt(node, "code", &.{"font"}, .{ .family = default_code_family, .weight = default_weight, .style = .normal, .stretch = .normal });
}

pub fn headingFont(node: *const Node, level: []const u8, base: Face) Face {
    return faceAt(node, "headings", &.{ level, "font" }, base);
}

pub fn boldWeight(state: anytype, node: *const Node) u16 {
    return fontWeightNumber(fields.read(state.allocator, state, node, "markdown", &.{ "bold", "weight" }, .number)) orelse default_bold_weight;
}

pub fn italicStyle(state: anytype, node: *const Node) Style {
    return parseStyle(fields.read(state.allocator, state, node, "markdown", &.{ "italic", "style" }, .text) orelse "") orelse .italic;
}

pub fn styleName(style: Style) []const u8 {
    return @tagName(style);
}

pub fn stretchName(stretch: Stretch) []const u8 {
    return @tagName(stretch);
}

pub fn styleCode(style: Style) c_int {
    return switch (style) {
        .normal => 0,
        .oblique => 1,
        .italic => 2,
    };
}

pub fn stretchCode(stretch: Stretch) c_int {
    return switch (stretch) {
        .ultra_condensed => 0,
        .extra_condensed => 1,
        .condensed => 2,
        .semi_condensed => 3,
        .normal => 4,
        .semi_expanded => 5,
        .expanded => 6,
        .extra_expanded => 7,
        .ultra_expanded => 8,
    };
}

fn faceAt(node: *const Node, key: []const u8, path: []const []const u8, fallback: Face) Face {
    const root = model.nodeField(node, key) orelse return fallback;
    const value = fields.pathValue(root, path) orelse return fallback;
    if (value != .record) return fallback;
    const record = value.record;
    return .{
        .family = cleanFamily(readField(record, "family", .text) orelse fallback.family),
        .weight = fontWeightNumber(readField(record, "weight", .number)) orelse fallback.weight,
        .style = parseStyle(readField(record, "style", .text) orelse "") orelse fallback.style,
        .stretch = parseStretch(readField(record, "stretch", .text) orelse "") orelse fallback.stretch,
    };
}

fn readField(record: model.RecordValue, key: []const u8, comptime as: fields.ReadAs) ?fields.ReadResult(as) {
    return fields.readValue(record.field(key) orelse return null, as);
}

fn cleanFamily(value: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    return if (trimmed.len == 0) "sans-serif" else trimmed;
}

fn fontWeightNumber(maybe_number: ?f32) ?u16 {
    const parsed = maybe_number orelse return null;
    if (!std.math.isFinite(parsed)) return null;
    const rounded = @round(parsed);
    if (rounded < 1 or rounded > 1000) return null;
    return @intFromFloat(rounded);
}

fn parseStyle(raw: []const u8) ?Style {
    return std.meta.stringToEnum(Style, raw);
}

fn parseStretch(raw: []const u8) ?Stretch {
    return std.meta.stringToEnum(Stretch, raw);
}
