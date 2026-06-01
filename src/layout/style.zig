const std = @import("std");
const model = @import("model");
const class_fields = @import("../core/class_fields.zig");

const Node = model.Node;
const TextStyle = model.TextStyle;

const DEFAULT_TEXT_STYLE = TextStyle{
    .font_size = 20,
    .line_height = 28,
    .spacing_after = 24,
    .default_x = 96,
    .default_right_inset = 96,
};

pub fn styleForNode(ir: anytype, node: *const Node) TextStyle {
    return overrideTextStyleFromProperties(ir, node, DEFAULT_TEXT_STYLE);
}

pub fn shouldWrapNode(ir: anytype, node: *const Node) bool {
    if (positiveNodeFloatProperty(ir, node, "asset_width") != null) return false;
    if (class_fields.property(ir, node, "wrap")) |wrap_mode| {
        if (std.mem.eql(u8, wrap_mode, "on")) return true;
        if (std.mem.eql(u8, wrap_mode, "off")) return false;
    }
    if (class_fields.property(ir, node, "layout_right_inset") != null) return true;
    return false;
}

pub fn parseNodeFloatProperty(ir: anytype, node: *const Node, key: []const u8) ?f32 {
    const value = class_fields.property(ir, node, key) orelse return null;
    const parsed = std.fmt.parseFloat(f32, value) catch return null;
    return if (std.math.isFinite(parsed)) parsed else null;
}

fn overrideTextStyleFromProperties(ir: anytype, node: *const Node, base: TextStyle) TextStyle {
    var style = base;
    const text_size = positiveNodeFloatProperty(ir, node, "text_size");
    const layout_font_size = positiveNodeFloatProperty(ir, node, "layout_font_size");
    if (layout_font_size orelse text_size) |value| style.font_size = value;
    if (text_size) |value| style.font_size = @max(style.font_size, value);

    const text_line_height = positiveNodeFloatProperty(ir, node, "text_line_height");
    const layout_line_height = positiveNodeFloatProperty(ir, node, "layout_line_height");
    if (layout_line_height orelse text_line_height) |value| style.line_height = value;
    if (text_line_height) |value| style.line_height = @max(style.line_height, value);
    if (nonNegativeNodeFloatProperty(ir, node, "layout_spacing_after")) |value| style.spacing_after = value;
    if (parseNodeFloatProperty(ir, node, "layout_x")) |value| style.default_x = value;
    if (nonNegativeNodeFloatProperty(ir, node, "layout_right_inset")) |value| style.default_right_inset = value;
    return style;
}

fn positiveNodeFloatProperty(ir: anytype, node: *const Node, key: []const u8) ?f32 {
    const value = parseNodeFloatProperty(ir, node, key) orelse return null;
    return if (value > 0) value else null;
}

fn nonNegativeNodeFloatProperty(ir: anytype, node: *const Node, key: []const u8) ?f32 {
    const value = parseNodeFloatProperty(ir, node, key) orelse return null;
    return if (value >= 0) value else null;
}
