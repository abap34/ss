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
pub const default_code_family = "Courier";
pub const default_weight: u16 = 400;
pub const default_bold_weight: u16 = 700;

pub fn textFacesForNode(ir: anytype, node: *const Node) TextFaces {
    const normal = faceFromRecord(
        ir.allocator,
        ir,
        node,
        "font",
        .{
            .family = default_family,
            .weight = default_weight,
            .style = .normal,
            .stretch = .normal,
        },
    );
    const markdown_bold_weight = fontWeightNumber(fields.read(ir.allocator, ir, node, "text", &.{"bold_weight"}, .number)) orelse default_bold_weight;
    const markdown_italic_style = parseStyle(fields.read(ir.allocator, ir, node, "text", &.{"italic_style"}, .text) orelse "") orelse .italic;
    return .{
        .normal = normal,
        .bold = .{
            .family = normal.family,
            .weight = @max(normal.weight, markdown_bold_weight),
            .style = normal.style,
            .stretch = normal.stretch,
        },
        .italic = .{
            .family = normal.family,
            .weight = normal.weight,
            .style = markdown_italic_style,
            .stretch = normal.stretch,
        },
        .code = faceFromRecord(
            ir.allocator,
            ir,
            node,
            "code_font",
            .{
                .family = default_code_family,
                .weight = default_weight,
                .style = .normal,
                .stretch = .normal,
            },
        ),
    };
}

pub fn textFacesForNodeWithEnv(allocator: std.mem.Allocator, node: *const Node, sema: anytype) TextFaces {
    const normal = faceFromRecordWithEnv(
        allocator,
        node,
        sema,
        "font",
        .{
            .family = default_family,
            .weight = default_weight,
            .style = .normal,
            .stretch = .normal,
        },
    );
    const markdown_bold_weight = fontWeightNumber(fields.readWithEnv(allocator, node, "text", &.{"bold_weight"}, sema, .number)) orelse default_bold_weight;
    const markdown_italic_style = parseStyle(fields.readWithEnv(allocator, node, "text", &.{"italic_style"}, sema, .text) orelse "") orelse .italic;
    return .{
        .normal = normal,
        .bold = .{
            .family = normal.family,
            .weight = @max(normal.weight, markdown_bold_weight),
            .style = normal.style,
            .stretch = normal.stretch,
        },
        .italic = .{
            .family = normal.family,
            .weight = normal.weight,
            .style = markdown_italic_style,
            .stretch = normal.stretch,
        },
        .code = faceFromRecordWithEnv(
            allocator,
            node,
            sema,
            "code_font",
            .{
                .family = default_code_family,
                .weight = default_weight,
                .style = .normal,
                .stretch = .normal,
            },
        ),
    };
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

fn faceFromRecord(
    allocator: std.mem.Allocator,
    ir: anytype,
    node: *const Node,
    font_field: []const u8,
    fallback: Face,
) Face {
    return .{
        .family = cleanFamily(fields.read(allocator, ir, node, "text", &.{ font_field, "family" }, .text) orelse fallback.family),
        .weight = fontWeightNumber(fields.read(allocator, ir, node, "text", &.{ font_field, "weight" }, .number)) orelse fallback.weight,
        .style = parseStyle(fields.read(allocator, ir, node, "text", &.{ font_field, "style" }, .text) orelse "") orelse fallback.style,
        .stretch = parseStretch(fields.read(allocator, ir, node, "text", &.{ font_field, "stretch" }, .text) orelse "") orelse fallback.stretch,
    };
}

fn faceFromRecordWithEnv(
    allocator: std.mem.Allocator,
    node: *const Node,
    sema: anytype,
    font_field: []const u8,
    fallback: Face,
) Face {
    return .{
        .family = cleanFamily(fields.readWithEnv(allocator, node, "text", &.{ font_field, "family" }, sema, .text) orelse fallback.family),
        .weight = fontWeightNumber(fields.readWithEnv(allocator, node, "text", &.{ font_field, "weight" }, sema, .number)) orelse fallback.weight,
        .style = parseStyle(fields.readWithEnv(allocator, node, "text", &.{ font_field, "style" }, sema, .text) orelse "") orelse fallback.style,
        .stretch = parseStretch(fields.readWithEnv(allocator, node, "text", &.{ font_field, "stretch" }, sema, .text) orelse "") orelse fallback.stretch,
    };
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
