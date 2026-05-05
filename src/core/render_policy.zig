const std = @import("std");
const model = @import("model");
const class_fields = @import("class_fields.zig");
const layout = @import("layout.zig");

const Node = model.Node;

pub const Color = struct {
    r: f32,
    g: f32,
    b: f32,
};

pub const Dash = struct {
    on: f32,
    off: f32,
};

pub const RenderKind = enum {
    text,
    code,
    vector_math,
    vector_asset,
    raster_asset,
    chrome_only,
};

pub const TextPaint = struct {
    font: []const u8,
    bold_font: []const u8,
    italic_font: []const u8,
    code_font: []const u8,
    font_size: f32,
    line_height: f32,
    color: Color,
    link_color: Color,
    link_underline_width: f32,
    link_underline_offset: f32,
    inline_math_height_factor: f32,
    inline_math_spacing: f32,
    markdown_block_gap: f32,
    markdown_list_indent: f32,
    markdown_code_font_size: f32,
    markdown_code_line_height: f32,
    markdown_code_pad_x: f32,
    markdown_code_pad_y: f32,
    markdown_code_fill: ?Color,
    markdown_code_stroke: ?Color,
    markdown_code_line_width: f32,
    markdown_code_radius: f32,
    cjk_bold_passes: u32,
    cjk_bold_dx: f32,
    wrap: bool,
};

pub const MathPaint = struct {
    block_line_height: f32,
    block_min_height: f32,
    block_vertical_padding: f32,
    scale: f32,
};

pub const CodePaint = struct {
    language: ?[]const u8,
    plain: Color,
    keyword: Color,
    comment: Color,
    string: Color,
};

pub const ChromePaint = struct {
    fill: ?Color,
    stroke: ?Color,
    line_width: f32,
    radius: f32,
};

pub const UnderlinePaint = struct {
    color: ?Color,
    width: f32,
    offset: f32,
};

pub const RulePaint = struct {
    stroke: ?Color,
    line_width: f32,
    dash: ?Dash,
};

pub const ResolvedRender = struct {
    kind: RenderKind,
    text: ?TextPaint,
    math: ?MathPaint,
    code: ?CodePaint,
    chrome: ChromePaint,
    underline: UnderlinePaint,
    rule: RulePaint,
};

const FALLBACK_TEXT_COLOR = Color{ .r = 0.08, .g = 0.08, .b = 0.08 };
const FALLBACK_LINK_COLOR = Color{ .r = 0.1, .g = 0.25, .b = 0.75 };

pub fn resolve(ir: anytype, node: *const Node) ResolvedRender {
    const kind = resolveKind(ir, node);
    return .{
        .kind = kind,
        .text = resolveText(ir, node, kind),
        .math = resolveMath(ir, node, kind),
        .code = resolveCode(ir, node, kind),
        .chrome = resolveChrome(ir, node),
        .underline = resolveUnderline(ir, node),
        .rule = resolveRule(ir, node),
    };
}

pub fn resolveKind(ir: anytype, node: *const Node) RenderKind {
    if (parseRenderKindProperty(ir, node)) |kind| return kind;
    return .text;
}

fn resolveText(ir: anytype, node: *const Node, kind: RenderKind) ?TextPaint {
    switch (kind) {
        .text, .code => {},
        else => return null,
    }

    const layout_style = layout.styleForNode(ir, node);
    const font = stringProperty(ir, node, "text_font", "Helvetica");
    return .{
        .font = font,
        .bold_font = stringProperty(ir, node, "text_bold_font", font),
        .italic_font = stringProperty(ir, node, "text_italic_font", font),
        .code_font = stringProperty(ir, node, "text_code_font", "Courier"),
        .font_size = parseFloatProperty(ir, node, "text_size") orelse layout_style.font_size,
        .line_height = parseFloatProperty(ir, node, "text_line_height") orelse layout_style.line_height,
        .color = parseColorProperty(ir, node, "text_color") orelse FALLBACK_TEXT_COLOR,
        .link_color = parseColorProperty(ir, node, "text_link_color") orelse FALLBACK_LINK_COLOR,
        .link_underline_width = parseFloatProperty(ir, node, "text_link_underline_width") orelse 0,
        .link_underline_offset = parseFloatProperty(ir, node, "text_link_underline_offset") orelse 0,
        .inline_math_height_factor = parseFloatProperty(ir, node, "text_inline_math_height_factor") orelse 1,
        .inline_math_spacing = parseFloatProperty(ir, node, "text_inline_math_spacing") orelse 0,
        .markdown_block_gap = parseFloatProperty(ir, node, "text_markdown_block_gap") orelse 0,
        .markdown_list_indent = parseFloatProperty(ir, node, "text_markdown_list_indent") orelse 0,
        .markdown_code_font_size = parseFloatProperty(ir, node, "text_markdown_code_font_size") orelse layout_style.font_size,
        .markdown_code_line_height = parseFloatProperty(ir, node, "text_markdown_code_line_height") orelse layout_style.line_height,
        .markdown_code_pad_x = parseFloatProperty(ir, node, "text_markdown_code_pad_x") orelse 0,
        .markdown_code_pad_y = parseFloatProperty(ir, node, "text_markdown_code_pad_y") orelse 0,
        .markdown_code_fill = parseColorProperty(ir, node, "text_markdown_code_fill"),
        .markdown_code_stroke = parseColorProperty(ir, node, "text_markdown_code_stroke"),
        .markdown_code_line_width = parseFloatProperty(ir, node, "text_markdown_code_line_width") orelse 0,
        .markdown_code_radius = parseFloatProperty(ir, node, "text_markdown_code_radius") orelse 0,
        .cjk_bold_passes = parseIntProperty(ir, node, "text_cjk_bold_passes") orelse 1,
        .cjk_bold_dx = parseFloatProperty(ir, node, "text_cjk_bold_dx") orelse 0,
        .wrap = layout.shouldWrapNode(ir, node),
    };
}

fn resolveMath(ir: anytype, node: *const Node, kind: RenderKind) ?MathPaint {
    if (kind != .vector_math) return null;
    return .{
        .block_line_height = parseFloatProperty(ir, node, "math_block_line_height") orelse 22,
        .block_min_height = parseFloatProperty(ir, node, "math_block_min_height") orelse 30,
        .block_vertical_padding = parseFloatProperty(ir, node, "math_block_vertical_padding") orelse 2,
        .scale = parseFloatProperty(ir, node, "math_scale") orelse 1,
    };
}

fn resolveCode(ir: anytype, node: *const Node, kind: RenderKind) ?CodePaint {
    if (kind != .code) return null;
    const plain = parseColorProperty(ir, node, "code_plain_color") orelse parseColorProperty(ir, node, "text_color") orelse FALLBACK_TEXT_COLOR;
    return .{
        .language = class_fields.property(ir, node, "language"),
        .plain = plain,
        .keyword = parseColorProperty(ir, node, "code_keyword_color") orelse plain,
        .comment = parseColorProperty(ir, node, "code_comment_color") orelse plain,
        .string = parseColorProperty(ir, node, "code_string_color") orelse plain,
    };
}

fn resolveChrome(ir: anytype, node: *const Node) ChromePaint {
    return .{
        .fill = parseColorProperty(ir, node, "chrome_fill"),
        .stroke = parseColorProperty(ir, node, "chrome_stroke"),
        .line_width = parseFloatProperty(ir, node, "chrome_line_width") orelse 0,
        .radius = parseFloatProperty(ir, node, "chrome_radius") orelse 0,
    };
}

fn resolveUnderline(ir: anytype, node: *const Node) UnderlinePaint {
    return .{
        .color = parseColorProperty(ir, node, "underline_color"),
        .width = parseFloatProperty(ir, node, "underline_width") orelse 0,
        .offset = parseFloatProperty(ir, node, "underline_offset") orelse 0,
    };
}

fn resolveRule(ir: anytype, node: *const Node) RulePaint {
    return .{
        .stroke = parseColorProperty(ir, node, "rule_stroke"),
        .line_width = parseFloatProperty(ir, node, "rule_line_width") orelse 0,
        .dash = parseDashProperty(ir, node, "rule_dash"),
    };
}

fn parseRenderKindProperty(ir: anytype, node: *const Node) ?RenderKind {
    const value = class_fields.property(ir, node, "render_kind") orelse return null;
    if (std.mem.eql(u8, value, "text")) return .text;
    if (std.mem.eql(u8, value, "code")) return .code;
    if (std.mem.eql(u8, value, "vector_math")) return .vector_math;
    if (std.mem.eql(u8, value, "vector_asset")) return .vector_asset;
    if (std.mem.eql(u8, value, "raster_asset")) return .raster_asset;
    if (std.mem.eql(u8, value, "chrome") or std.mem.eql(u8, value, "chrome_only")) return .chrome_only;
    return null;
}

fn stringProperty(ir: anytype, node: *const Node, key: []const u8, fallback: []const u8) []const u8 {
    return class_fields.property(ir, node, key) orelse fallback;
}

fn parseFloatProperty(ir: anytype, node: *const Node, key: []const u8) ?f32 {
    const value = class_fields.property(ir, node, key) orelse return null;
    return std.fmt.parseFloat(f32, value) catch null;
}

fn parseIntProperty(ir: anytype, node: *const Node, key: []const u8) ?u32 {
    const raw = class_fields.property(ir, node, key) orelse return null;
    return std.fmt.parseInt(u32, raw, 10) catch null;
}

fn parseColorProperty(ir: anytype, node: *const Node, key: []const u8) ?Color {
    const value = class_fields.property(ir, node, key) orelse return null;
    return parseColor(value);
}

fn parseColor(value: []const u8) ?Color {
    var parts = std.mem.splitScalar(u8, value, ',');
    const r_text = parts.next() orelse return null;
    const g_text = parts.next() orelse return null;
    const b_text = parts.next() orelse return null;
    if (parts.next() != null) return null;
    return .{
        .r = std.fmt.parseFloat(f32, std.mem.trim(u8, r_text, " ")) catch return null,
        .g = std.fmt.parseFloat(f32, std.mem.trim(u8, g_text, " ")) catch return null,
        .b = std.fmt.parseFloat(f32, std.mem.trim(u8, b_text, " ")) catch return null,
    };
}

fn parseDashProperty(ir: anytype, node: *const Node, key: []const u8) ?Dash {
    const value = class_fields.property(ir, node, key) orelse return null;
    var parts = std.mem.splitScalar(u8, value, ',');
    const on_text = parts.next() orelse return null;
    const off_text = parts.next() orelse return null;
    if (parts.next() != null) return null;
    return .{
        .on = std.fmt.parseFloat(f32, std.mem.trim(u8, on_text, " ")) catch return null,
        .off = std.fmt.parseFloat(f32, std.mem.trim(u8, off_text, " ")) catch return null,
    };
}
