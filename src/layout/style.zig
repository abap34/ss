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

pub fn styleForNode(state: anytype, node: *const Node) TextStyle {
    return overrideTextStyleFromProperties(state, node, DEFAULT_TEXT_STYLE);
}

pub fn shouldWrapNode(state: anytype, node: *const Node) bool {
    if (positiveNodeFloatProperty(state, node, "asset_width") != null) return false;
    if (fields.read(state.allocator, state, node, "layout", &.{"wrap"}, .text)) |wrap_mode| {
        if (std.mem.eql(u8, wrap_mode, "on")) return true;
        if (std.mem.eql(u8, wrap_mode, "off")) return false;
    }
    if (fields.read(state.allocator, state, node, "layout", &.{"right_inset"}, .number) != null) return true;
    return false;
}

pub fn parseNodeFloatProperty(state: anytype, node: *const Node, key: []const u8) ?f32 {
    return fields.read(state.allocator, state, node, key, &.{}, .number);
}

fn overrideTextStyleFromProperties(state: anytype, node: *const Node, base: TextStyle) TextStyle {
    var style = base;
    const text_metrics = textMetricsForNode(state, node);
    const layout_font_size = positiveRecordFloatProperty(state, node, "layout", "font_size");
    style.font_size = layout_font_size orelse text_metrics.font_size;

    const layout_line_height = positiveRecordFloatProperty(state, node, "layout", "line_height");
    style.line_height = layout_line_height orelse text_metrics.line_height;
    if (nonNegativeRecordFloatProperty(state, node, "layout", "spacing_after")) |value| style.spacing_after = value;
    if (recordFloatProperty(state, node, "layout", "x")) |value| style.default_x = value;
    if (nonNegativeRecordFloatProperty(state, node, "layout", "right_inset")) |value| style.default_right_inset = value;
    return style;
}

pub fn textMetricsForNode(state: anytype, node: *const Node) TextMetrics {
    const font_size = positiveRecordFloatProperty(state, node, "text", "size") orelse
        positiveRecordFloatProperty(state, node, "layout", "font_size") orelse
        DEFAULT_TEXT_STYLE.font_size;

    const line_height = positiveRecordFloatProperty(state, node, "text", "line_height") orelse defaultLineHeight(font_size);

    return .{
        .font_size = font_size,
        .line_height = line_height,
    };
}

fn positiveNodeFloatProperty(state: anytype, node: *const Node, key: []const u8) ?f32 {
    const value = parseNodeFloatProperty(state, node, key) orelse return null;
    return if (value > 0) value else null;
}

fn recordFloatProperty(state: anytype, node: *const Node, record_key: []const u8, field_name: []const u8) ?f32 {
    return fields.read(state.allocator, state, node, record_key, &.{field_name}, .number);
}

fn positiveRecordFloatProperty(state: anytype, node: *const Node, record_key: []const u8, field_name: []const u8) ?f32 {
    const value = recordFloatProperty(state, node, record_key, field_name) orelse return null;
    return if (value > 0) value else null;
}

fn nonNegativeRecordFloatProperty(state: anytype, node: *const Node, record_key: []const u8, field_name: []const u8) ?f32 {
    const value = recordFloatProperty(state, node, record_key, field_name) orelse return null;
    return if (value >= 0) value else null;
}

fn defaultLineHeight(font_size: f32) f32 {
    return font_size * DEFAULT_LINE_HEIGHT_FACTOR;
}
