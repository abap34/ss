const std = @import("std");
const model = @import("model");

const Node = model.Node;
const Role = model.Role;
const PageLayout = model.PageLayout;
const TextStyle = model.TextStyle;

const StyleEntry = struct {
    role: []const u8,
    style: ?[]const u8 = null,
    spec: TextStyle,
};

const DEFAULT_TEXT_STYLE = TextStyle{
    .font_size = 20,
    .line_height = 28,
    .spacing_after = 24,
    .default_x = 96,
    .default_right_inset = 96,
};

const STYLE_ENTRIES = [_]StyleEntry{
    .{ .role = "title", .spec = .{ .font_size = 34, .line_height = 40, .spacing_after = 54, .default_x = 72, .default_right_inset = 72 } },
    .{ .role = "subtitle", .spec = .{ .font_size = 18, .line_height = 24, .spacing_after = 34, .default_x = 96, .default_right_inset = 96 } },
    .{ .role = "byline", .spec = .{ .font_size = 20, .line_height = 26, .spacing_after = 18, .default_x = 72, .default_right_inset = 72 } },
    .{ .role = "body", .spec = .{ .font_size = 20, .line_height = 28, .spacing_after = 28, .default_x = 96, .default_right_inset = 96 } },
    .{ .role = "math", .spec = .{ .font_size = 18, .line_height = 24, .spacing_after = 28, .default_x = 102, .default_right_inset = 102 } },
    .{ .role = "figure", .spec = .{ .font_size = 16, .line_height = 20, .spacing_after = 28, .default_x = 102, .default_right_inset = 102 } },
    .{ .role = "code", .spec = .{ .font_size = 15, .line_height = 20, .spacing_after = 28, .default_x = 102, .default_right_inset = 102 } },
    .{ .role = "toc", .spec = .{ .font_size = 18, .line_height = 24, .spacing_after = 24, .default_x = 96, .default_right_inset = 96 } },
    .{ .role = "page_number", .spec = .{ .font_size = 13, .line_height = 16, .spacing_after = 0, .default_x = PageLayout.flow_margin_x, .default_right_inset = PageLayout.page_number_right_inset } },
    .{ .role = "highlight", .spec = .{ .font_size = 14, .line_height = 18, .spacing_after = 20, .default_x = 120, .default_right_inset = 120 } },
    .{ .role = "heading1", .spec = .{ .font_size = 20, .line_height = 28, .spacing_after = 24, .default_x = 96, .default_right_inset = 96 } },
    .{ .role = "toc_entry", .spec = .{ .font_size = 20, .line_height = 28, .spacing_after = 24, .default_x = 96, .default_right_inset = 96 } },
    .{ .role = "note", .spec = .{ .font_size = 20, .line_height = 28, .spacing_after = 24, .default_x = 96, .default_right_inset = 96 } },
    .{ .role = "rule", .spec = .{ .font_size = 4, .line_height = 4, .spacing_after = 0, .default_x = 72, .default_right_inset = 72 } },
    .{ .role = "label", .spec = .{ .font_size = 14, .line_height = 18, .spacing_after = 0, .default_x = 72, .default_right_inset = 72 } },
    .{ .role = "panel", .spec = .{ .font_size = 4, .line_height = 4, .spacing_after = 0, .default_x = 72, .default_right_inset = 72 } },
};

const WRAP_ROLES = [_][]const u8{
    "title",
    "subtitle",
    "byline",
    "body",
    "toc",
    "heading1",
    "toc_entry",
    "note",
    "highlight",
};

pub fn styleForNode(ir: anytype, node: *const Node) TextStyle {
    _ = ir;
    const role = node.role orelse "body";
    const base = lookupTextStyle(role, null) orelse DEFAULT_TEXT_STYLE;
    return overrideTextStyleFromProperties(node, base);
}

pub fn shouldWrapNode(ir: anytype, node: *const Node) bool {
    _ = ir;
    const role = node.role orelse return false;
    if (parseNodeFloatProperty(node, "asset_width") != null) return false;
    if (model.nodeProperty(node, "layout_right_inset") != null) return true;
    return containsRole(&WRAP_ROLES, role);
}

pub fn parseNodeFloatProperty(node: *const Node, key: []const u8) ?f32 {
    const value = model.nodeProperty(node, key) orelse return null;
    return std.fmt.parseFloat(f32, value) catch null;
}

fn lookupTextStyle(role: []const u8, style_name: ?[]const u8) ?TextStyle {
    for (STYLE_ENTRIES) |entry| {
        if (!std.mem.eql(u8, entry.role, role)) continue;
        if (style_name == null and entry.style == null) return entry.spec;
        if (style_name != null and entry.style != null and std.mem.eql(u8, entry.style.?, style_name.?)) return entry.spec;
    }
    return null;
}

fn containsRole(entries: []const []const u8, role: []const u8) bool {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry, role)) return true;
    }
    return false;
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
