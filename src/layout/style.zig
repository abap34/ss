const model = @import("model");
const fields = @import("../core/fields.zig");
const render_policy = @import("../core/render_policy.zig");

const Node = model.Node;
const TextStyle = model.TextStyle;

const DEFAULT_TEXT_STYLE = TextStyle{
    .font_size = 20,
    .line_height = 28,
    .spacing_after = 24,
    .default_x = 96,
    .default_right_inset = 96,
};

pub const TextMetrics = struct {
    font_size: f32,
    line_height: f32,
};

pub fn styleForNode(state: anytype, node: *const Node) TextStyle {
    return overrideTextStyleFromProperties(state, node, DEFAULT_TEXT_STYLE);
}

pub fn shouldWrapNode(state: anytype, node: *const Node) bool {
    return render_policy.shouldWrapText(state, node);
}

pub fn parseNodeFloatProperty(state: anytype, node: *const Node, key: []const u8) ?f32 {
    return fields.read(state.allocator, state, node, key, &.{}, .number);
}

fn overrideTextStyleFromProperties(state: anytype, node: *const Node, base: TextStyle) TextStyle {
    var style = base;
    const text_metrics = textMetricsForNode(state, node);
    style.font_size = text_metrics.font_size;
    style.line_height = text_metrics.line_height;
    if (nonNegativeRecordFloatProperty(state, node, "layout", "spacing_after")) |value| style.spacing_after = value;
    if (recordFloatProperty(state, node, "layout", "x")) |value| style.default_x = value;
    if (nonNegativeRecordFloatProperty(state, node, "layout", "right_inset")) |value| style.default_right_inset = value;
    return style;
}

pub fn textMetricsForNode(state: anytype, node: *const Node) TextMetrics {
    const resolved = render_policy.resolveTextMetrics(state, node);
    return .{
        .font_size = resolved.font_size,
        .line_height = resolved.line_height,
    };
}

fn recordFloatProperty(state: anytype, node: *const Node, record_key: []const u8, field_name: []const u8) ?f32 {
    return fields.read(state.allocator, state, node, record_key, &.{field_name}, .number);
}

fn nonNegativeRecordFloatProperty(state: anytype, node: *const Node, record_key: []const u8, field_name: []const u8) ?f32 {
    const value = recordFloatProperty(state, node, record_key, field_name) orelse return null;
    return if (value >= 0) value else null;
}
