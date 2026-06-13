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

const DEFAULT_LINE_HEIGHT_FACTOR: f32 = 1.6;

pub const TextMetrics = struct {
    font_size: f32,
    line_height: f32,
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
    const text_metrics = textMetricsForNode(ir, node);
    const explicit_text_size = explicitPositiveNodeFloatProperty(node, "text_size");
    const explicit_layout_font_size = explicitPositiveNodeFloatProperty(node, "layout_font_size");
    const default_layout_font_size = defaultPositiveNodeFloatProperty(ir, node, "layout_font_size");
    style.font_size = explicit_layout_font_size orelse explicit_text_size orelse default_layout_font_size orelse text_metrics.font_size;

    const text_line_height = explicitPositiveNodeFloatProperty(node, "text_line_height");
    const explicit_layout_line_height = explicitPositiveNodeFloatProperty(node, "layout_line_height");
    const default_layout_line_height = defaultPositiveNodeFloatProperty(ir, node, "layout_line_height");
    style.line_height = explicit_layout_line_height orelse text_line_height orelse default_layout_line_height orelse text_metrics.line_height;
    if (nonNegativeNodeFloatProperty(ir, node, "layout_spacing_after")) |value| style.spacing_after = value;
    if (parseNodeFloatProperty(ir, node, "layout_x")) |value| style.default_x = value;
    if (nonNegativeNodeFloatProperty(ir, node, "layout_right_inset")) |value| style.default_right_inset = value;
    return style;
}

pub fn textMetricsForNode(ir: anytype, node: *const Node) TextMetrics {
    const explicit_text_size = explicitPositiveNodeFloatProperty(node, "text_size");
    const default_text_size = defaultPositiveNodeFloatProperty(ir, node, "text_size");
    const layout_font_size = explicitPositiveNodeFloatProperty(node, "layout_font_size") orelse defaultPositiveNodeFloatProperty(ir, node, "layout_font_size");
    const font_size = explicit_text_size orelse default_text_size orelse layout_font_size orelse DEFAULT_TEXT_STYLE.font_size;

    const line_height = explicitPositiveNodeFloatProperty(node, "text_line_height") orelse blk: {
        const default_text_line_height = defaultPositiveNodeFloatProperty(ir, node, "text_line_height");
        break :blk default_text_line_height orelse defaultLineHeight(font_size);
    };

    return .{
        .font_size = font_size,
        .line_height = line_height,
    };
}

fn positiveNodeFloatProperty(ir: anytype, node: *const Node, key: []const u8) ?f32 {
    const value = parseNodeFloatProperty(ir, node, key) orelse return null;
    return if (value > 0) value else null;
}

fn nonNegativeNodeFloatProperty(ir: anytype, node: *const Node, key: []const u8) ?f32 {
    const value = parseNodeFloatProperty(ir, node, key) orelse return null;
    return if (value >= 0) value else null;
}

fn explicitPositiveNodeFloatProperty(node: *const Node, key: []const u8) ?f32 {
    const value = parseFloatValue(model.nodeProperty(node, key) orelse return null) orelse return null;
    return if (value > 0) value else null;
}

fn defaultPositiveNodeFloatProperty(ir: anytype, node: *const Node, key: []const u8) ?f32 {
    const value = parseFloatValue(class_fields.defaultProperty(ir, node, key) orelse return null) orelse return null;
    return if (value > 0) value else null;
}

fn parseFloatValue(value: []const u8) ?f32 {
    const parsed = std.fmt.parseFloat(f32, value) catch return null;
    return if (std.math.isFinite(parsed)) parsed else null;
}

fn defaultLineHeight(font_size: f32) f32 {
    return font_size * DEFAULT_LINE_HEIGHT_FACTOR;
}
