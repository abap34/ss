const std = @import("std");
const model = @import("model");

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
    _ = ir;
    return overrideTextStyleFromProperties(node, DEFAULT_TEXT_STYLE);
}

pub fn shouldWrapNode(ir: anytype, node: *const Node) bool {
    _ = ir;
    if (parseNodeFloatProperty(node, "asset_width") != null) return false;
    if (model.nodeProperty(node, "layout_right_inset") != null) return true;
    return false;
}

pub fn parseNodeFloatProperty(node: *const Node, key: []const u8) ?f32 {
    const value = model.nodeProperty(node, key) orelse return null;
    return std.fmt.parseFloat(f32, value) catch null;
}

fn overrideTextStyleFromProperties(node: *const Node, base: TextStyle) TextStyle {
    var style = base;
    if (parseNodeFloatProperty(node, "layout_font_size") orelse parseNodeFloatProperty(node, "text_size")) |value| style.font_size = value;
    if (parseNodeFloatProperty(node, "layout_line_height") orelse parseNodeFloatProperty(node, "text_line_height")) |value| style.line_height = value;
    if (parseNodeFloatProperty(node, "layout_spacing_after")) |value| style.spacing_after = value;
    if (parseNodeFloatProperty(node, "layout_x")) |value| style.default_x = value;
    if (parseNodeFloatProperty(node, "layout_right_inset")) |value| style.default_right_inset = value;
    return style;
}
