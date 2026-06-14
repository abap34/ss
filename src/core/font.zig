const std = @import("std");
const model = @import("model");
const class_fields = @import("class_fields.zig");

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
    const normal = faceFromProperties(
        ir,
        node,
        "text_font_family",
        "text_font_weight",
        "text_font_style",
        "text_font_stretch",
        .{
            .family = default_family,
            .weight = default_weight,
            .style = .normal,
            .stretch = .normal,
        },
    );
    const markdown_bold_weight = fontWeightProperty(ir, node, "text_markdown_bold_weight") orelse default_bold_weight;
    const markdown_italic_style = fontStyleProperty(ir, node, "text_markdown_italic_style") orelse .italic;
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
        .code = faceFromProperties(
            ir,
            node,
            "text_code_font_family",
            "text_code_font_weight",
            "text_code_font_style",
            "text_code_font_stretch",
            .{
                .family = default_code_family,
                .weight = default_weight,
                .style = .normal,
                .stretch = .normal,
            },
        ),
    };
}

pub fn textFacesForNodeWithEnv(node: *const Node, sema: anytype) TextFaces {
    const normal = faceFromPropertiesWithEnv(
        node,
        sema,
        "text_font_family",
        "text_font_weight",
        "text_font_style",
        "text_font_stretch",
        .{
            .family = default_family,
            .weight = default_weight,
            .style = .normal,
            .stretch = .normal,
        },
    );
    const markdown_bold_weight = fontWeightPropertyWithEnv(node, sema, "text_markdown_bold_weight") orelse default_bold_weight;
    const markdown_italic_style = fontStylePropertyWithEnv(node, sema, "text_markdown_italic_style") orelse .italic;
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
        .code = faceFromPropertiesWithEnv(
            node,
            sema,
            "text_code_font_family",
            "text_code_font_weight",
            "text_code_font_style",
            "text_code_font_stretch",
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
    return switch (style) {
        .normal => "normal",
        .oblique => "oblique",
        .italic => "italic",
    };
}

pub fn stretchName(stretch: Stretch) []const u8 {
    return switch (stretch) {
        .ultra_condensed => "ultra_condensed",
        .extra_condensed => "extra_condensed",
        .condensed => "condensed",
        .semi_condensed => "semi_condensed",
        .normal => "normal",
        .semi_expanded => "semi_expanded",
        .expanded => "expanded",
        .extra_expanded => "extra_expanded",
        .ultra_expanded => "ultra_expanded",
    };
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

fn faceFromProperties(
    ir: anytype,
    node: *const Node,
    family_key: []const u8,
    weight_key: []const u8,
    style_key: []const u8,
    stretch_key: []const u8,
    fallback: Face,
) Face {
    return .{
        .family = cleanFamily(class_fields.property(ir, node, family_key) orelse fallback.family),
        .weight = fontWeightProperty(ir, node, weight_key) orelse fallback.weight,
        .style = fontStyleProperty(ir, node, style_key) orelse fallback.style,
        .stretch = fontStretchProperty(ir, node, stretch_key) orelse fallback.stretch,
    };
}

fn faceFromPropertiesWithEnv(
    node: *const Node,
    sema: anytype,
    family_key: []const u8,
    weight_key: []const u8,
    style_key: []const u8,
    stretch_key: []const u8,
    fallback: Face,
) Face {
    return .{
        .family = cleanFamily(class_fields.propertyWithEnv(node, family_key, sema) orelse fallback.family),
        .weight = fontWeightPropertyWithEnv(node, sema, weight_key) orelse fallback.weight,
        .style = fontStylePropertyWithEnv(node, sema, style_key) orelse fallback.style,
        .stretch = fontStretchPropertyWithEnv(node, sema, stretch_key) orelse fallback.stretch,
    };
}

fn cleanFamily(value: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    return if (trimmed.len == 0) "sans-serif" else trimmed;
}

fn fontWeightProperty(ir: anytype, node: *const Node, key: []const u8) ?u16 {
    const raw = class_fields.property(ir, node, key) orelse return null;
    return parseWeight(raw);
}

fn fontWeightPropertyWithEnv(node: *const Node, sema: anytype, key: []const u8) ?u16 {
    const raw = class_fields.propertyWithEnv(node, key, sema) orelse return null;
    return parseWeight(raw);
}

fn parseWeight(raw: []const u8) ?u16 {
    const parsed = std.fmt.parseFloat(f32, raw) catch return null;
    if (!std.math.isFinite(parsed)) return null;
    const rounded = @round(parsed);
    if (rounded < 1 or rounded > 1000) return null;
    return @intFromFloat(rounded);
}

fn fontStyleProperty(ir: anytype, node: *const Node, key: []const u8) ?Style {
    const raw = class_fields.property(ir, node, key) orelse return null;
    return parseStyle(raw);
}

fn fontStylePropertyWithEnv(node: *const Node, sema: anytype, key: []const u8) ?Style {
    const raw = class_fields.propertyWithEnv(node, key, sema) orelse return null;
    return parseStyle(raw);
}

fn parseStyle(raw: []const u8) ?Style {
    if (std.mem.eql(u8, raw, "normal")) return .normal;
    if (std.mem.eql(u8, raw, "oblique")) return .oblique;
    if (std.mem.eql(u8, raw, "italic")) return .italic;
    return null;
}

fn fontStretchProperty(ir: anytype, node: *const Node, key: []const u8) ?Stretch {
    const raw = class_fields.property(ir, node, key) orelse return null;
    return parseStretch(raw);
}

fn fontStretchPropertyWithEnv(node: *const Node, sema: anytype, key: []const u8) ?Stretch {
    const raw = class_fields.propertyWithEnv(node, key, sema) orelse return null;
    return parseStretch(raw);
}

fn parseStretch(raw: []const u8) ?Stretch {
    if (std.mem.eql(u8, raw, "ultra_condensed")) return .ultra_condensed;
    if (std.mem.eql(u8, raw, "extra_condensed")) return .extra_condensed;
    if (std.mem.eql(u8, raw, "condensed")) return .condensed;
    if (std.mem.eql(u8, raw, "semi_condensed")) return .semi_condensed;
    if (std.mem.eql(u8, raw, "normal")) return .normal;
    if (std.mem.eql(u8, raw, "semi_expanded")) return .semi_expanded;
    if (std.mem.eql(u8, raw, "expanded")) return .expanded;
    if (std.mem.eql(u8, raw, "extra_expanded")) return .extra_expanded;
    if (std.mem.eql(u8, raw, "ultra_expanded")) return .ultra_expanded;
    return null;
}
