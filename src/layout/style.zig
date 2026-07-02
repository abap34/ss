const std = @import("std");
const model = @import("model");
const fields = @import("../core/fields.zig");

const Node = model.Node;
const TextStyle = model.TextStyle;

const DEFAULT_TEXT_STYLE = TextStyle{
    .font_size = 20,
    .line_height = 28,
    .spacing_after = 24,
    .default_x = 96,
    .default_right_inset = 96,
};

const DEFAULT_LINE_HEIGHT_FACTOR: f32 = 1.45;

pub const TextMetrics = struct {
    font_size: f32,
    line_height: f32,
};

pub fn styleForNode(ir: anytype, node: *const Node) TextStyle {
    return overrideTextStyleFromProperties(ir, node, DEFAULT_TEXT_STYLE);
}

pub fn shouldWrapNode(ir: anytype, node: *const Node) bool {
    if (positiveNodeFloatProperty(ir, node, "asset_width") != null) return false;
    if (fields.read(ir.allocator, ir, node, "layout", &.{"wrap"}, .text)) |wrap_mode| {
        if (std.mem.eql(u8, wrap_mode, "on")) return true;
        if (std.mem.eql(u8, wrap_mode, "off")) return false;
    }
    if (fields.read(ir.allocator, ir, node, "layout", &.{"right_inset"}, .number) != null) return true;
    return false;
}

pub fn parseNodeFloatProperty(ir: anytype, node: *const Node, key: []const u8) ?f32 {
    return fields.read(ir.allocator, ir, node, key, &.{}, .number);
}

fn overrideTextStyleFromProperties(ir: anytype, node: *const Node, base: TextStyle) TextStyle {
    var style = base;
    const text_metrics = textMetricsForNode(ir, node);
    const layout_font_size = positiveRecordFloatProperty(ir, node, "layout", "font_size");
    style.font_size = layout_font_size orelse text_metrics.font_size;

    const layout_line_height = positiveRecordFloatProperty(ir, node, "layout", "line_height");
    style.line_height = layout_line_height orelse text_metrics.line_height;
    if (nonNegativeRecordFloatProperty(ir, node, "layout", "spacing_after")) |value| style.spacing_after = value;
    if (recordFloatProperty(ir, node, "layout", "x")) |value| style.default_x = value;
    if (nonNegativeRecordFloatProperty(ir, node, "layout", "right_inset")) |value| style.default_right_inset = value;
    return style;
}

pub fn textMetricsForNode(ir: anytype, node: *const Node) TextMetrics {
    const font_size = positiveRecordFloatProperty(ir, node, "text", "size") orelse
        positiveRecordFloatProperty(ir, node, "layout", "font_size") orelse
        DEFAULT_TEXT_STYLE.font_size;

    const line_height = positiveRecordFloatProperty(ir, node, "text", "line_height") orelse defaultLineHeight(font_size);

    return .{
        .font_size = font_size,
        .line_height = line_height,
    };
}

fn positiveNodeFloatProperty(ir: anytype, node: *const Node, key: []const u8) ?f32 {
    const value = parseNodeFloatProperty(ir, node, key) orelse return null;
    return if (value > 0) value else null;
}

fn recordFloatProperty(ir: anytype, node: *const Node, record_key: []const u8, field_name: []const u8) ?f32 {
    return fields.read(ir.allocator, ir, node, record_key, &.{field_name}, .number);
}

fn positiveRecordFloatProperty(ir: anytype, node: *const Node, record_key: []const u8, field_name: []const u8) ?f32 {
    const value = recordFloatProperty(ir, node, record_key, field_name) orelse return null;
    return if (value > 0) value else null;
}

fn nonNegativeRecordFloatProperty(ir: anytype, node: *const Node, record_key: []const u8, field_name: []const u8) ?f32 {
    const value = recordFloatProperty(ir, node, record_key, field_name) orelse return null;
    return if (value >= 0) value else null;
}

fn defaultLineHeight(font_size: f32) f32 {
    return font_size * DEFAULT_LINE_HEIGHT_FACTOR;
}
