const std = @import("std");
const model = @import("model.zig");
const layout = @import("layout.zig");

const Node = model.Node;
const PayloadKind = model.PayloadKind;
const roleEq = model.roleEq;

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

const DEFAULT_TEXT_COLOR = Color{ .r = 0.08, .g = 0.08, .b = 0.08 };
const DEFAULT_LINK_COLOR = Color{ .r = 0.1, .g = 0.25, .b = 0.75 };
const SEMINAR_BLUE = Color{ .r = 70.0 / 255.0, .g = 130.0 / 255.0, .b = 180.0 / 255.0 };
const SEMINAR_BLACK = Color{ .r = 0.0, .g = 0.0, .b = 9.0 / 255.0 };
const SEMINAR_GRAY = Color{ .r = 0.5, .g = 0.5, .b = 0.5 };
const SEMINAR_ORANGE = Color{ .r = 1.0, .g = 152.0 / 255.0, .b = 0.0 };
const CODE_KEYWORD_BLUE = Color{ .r = 44.0 / 255.0, .g = 88.0 / 255.0, .b = 201.0 / 255.0 };
const CODE_COMMENT_GREEN = Color{ .r = 78.0 / 255.0, .g = 138.0 / 255.0, .b = 92.0 / 255.0 };
const CODE_STRING_RED = Color{ .r = 178.0 / 255.0, .g = 65.0 / 255.0, .b = 55.0 / 255.0 };

const TextDefaults = struct {
    role: []const u8,
    font: []const u8,
    color: Color,
};

const TEXT_DEFAULTS = [_]TextDefaults{
    .{ .role = "title", .font = "Helvetica", .color = SEMINAR_BLACK },
    .{ .role = "subtitle", .font = "Helvetica", .color = SEMINAR_BLACK },
    .{ .role = "byline", .font = "Helvetica", .color = SEMINAR_BLUE },
    .{ .role = "label", .font = "Helvetica", .color = SEMINAR_BLUE },
    .{ .role = "body", .font = "Helvetica", .color = SEMINAR_BLACK },
    .{ .role = "math", .font = "Courier", .color = Color{ .r = 0.05, .g = 0.05, .b = 0.25 } },
    .{ .role = "figure", .font = "Courier", .color = Color{ .r = 0.18, .g = 0.18, .b = 0.18 } },
    .{ .role = "code", .font = "Courier", .color = Color{ .r = 0.12, .g = 0.12, .b = 0.12 } },
    .{ .role = "toc", .font = "Helvetica", .color = SEMINAR_BLACK },
    .{ .role = "highlight", .font = "Helvetica", .color = SEMINAR_ORANGE },
    .{ .role = "page_number", .font = "Helvetica", .color = SEMINAR_GRAY },
    .{ .role = "heading1", .font = "Helvetica", .color = SEMINAR_BLACK },
    .{ .role = "toc_entry", .font = "Helvetica", .color = SEMINAR_BLACK },
    .{ .role = "note", .font = "Helvetica", .color = SEMINAR_BLACK },
    .{ .role = "rule", .font = "Helvetica", .color = SEMINAR_BLACK },
    .{ .role = "panel", .font = "Helvetica", .color = SEMINAR_BLACK },
};

pub fn resolve(engine: anytype, node: *const Node) ResolvedRender {
    const kind = resolveKind(node);
    return .{
        .kind = kind,
        .text = resolveText(engine, node, kind),
        .math = resolveMath(kind),
        .code = resolveCode(node, kind),
        .chrome = resolveChrome(node),
        .underline = resolveUnderline(node),
        .rule = resolveRule(node),
    };
}

pub fn resolveKind(node: *const Node) RenderKind {
    if (roleEq(node.role, "panel") or roleEq(node.role, "rule") or roleEq(node.role, "group")) return .chrome_only;
    if (roleEq(node.role, "code") or node.payload_kind == .code) return .code;
    if (node.payload_kind == .math_tex) return .vector_math;
    if (node.payload_kind == .pdf_ref) return .vector_asset;
    if (node.payload_kind == .image_ref) return .raster_asset;
    return .text;
}

fn resolveText(engine: anytype, node: *const Node, kind: RenderKind) ?TextPaint {
    switch (kind) {
        .text, .code => {},
        else => return null,
    }

    const layout_style = layout.styleForNode(engine, node);
    const role = node.role orelse "body";
    const defaults = lookupTextDefaults(role);
    return .{
        .font = model.nodeProperty(node, "text_font") orelse defaults.font,
        .bold_font = model.nodeProperty(node, "text_bold_font") orelse defaultBoldFont(model.nodeProperty(node, "text_font") orelse defaults.font),
        .italic_font = model.nodeProperty(node, "text_italic_font") orelse defaultItalicFont(model.nodeProperty(node, "text_font") orelse defaults.font),
        .code_font = model.nodeProperty(node, "text_code_font") orelse "Courier",
        .font_size = parseFloatProperty(node, "text_size") orelse layout_style.font_size,
        .line_height = parseFloatProperty(node, "text_line_height") orelse layout_style.line_height,
        .color = parseColorProperty(node, "text_color") orelse defaults.color,
        .link_color = parseColorProperty(node, "text_link_color") orelse DEFAULT_LINK_COLOR,
        .link_underline_width = parseFloatProperty(node, "text_link_underline_width") orelse 0.8,
        .link_underline_offset = parseFloatProperty(node, "text_link_underline_offset") orelse -1.5,
        .inline_math_height_factor = parseFloatProperty(node, "text_inline_math_height_factor") orelse 1.02,
        .inline_math_spacing = parseFloatProperty(node, "text_inline_math_spacing") orelse 0.08,
        .markdown_block_gap = parseFloatProperty(node, "text_markdown_block_gap") orelse layout_style.line_height * 0.15,
        .markdown_list_indent = parseFloatProperty(node, "text_markdown_list_indent") orelse layout_style.font_size * 1.3,
        .markdown_code_font_size = parseFloatProperty(node, "text_markdown_code_font_size") orelse 15.0,
        .markdown_code_line_height = parseFloatProperty(node, "text_markdown_code_line_height") orelse 20.0,
        .markdown_code_pad_x = parseFloatProperty(node, "text_markdown_code_pad_x") orelse 12.0,
        .markdown_code_pad_y = parseFloatProperty(node, "text_markdown_code_pad_y") orelse 10.0,
        .markdown_code_fill = parseColorProperty(node, "text_markdown_code_fill"),
        .markdown_code_stroke = parseColorProperty(node, "text_markdown_code_stroke"),
        .markdown_code_line_width = parseFloatProperty(node, "text_markdown_code_line_width") orelse 1.0,
        .markdown_code_radius = parseFloatProperty(node, "text_markdown_code_radius") orelse 10.0,
        .cjk_bold_passes = parseIntProperty(node, "text_cjk_bold_passes") orelse 1,
        .cjk_bold_dx = parseFloatProperty(node, "text_cjk_bold_dx") orelse 0.05,
        .wrap = layout.shouldWrapNode(engine, node),
    };
}

fn resolveMath(kind: RenderKind) ?MathPaint {
    if (kind != .vector_math) return null;
    return .{
        .block_line_height = 22.0,
        .block_min_height = 30.0,
        .block_vertical_padding = 2.0,
    };
}

fn resolveCode(node: *const Node, kind: RenderKind) ?CodePaint {
    if (kind != .code) return null;
    const plain = parseColorProperty(node, "code_plain_color") orelse parseColorProperty(node, "text_color") orelse lookupTextDefaults(node.role orelse "code").color;
    return .{
        .language = model.nodeProperty(node, "language"),
        .plain = plain,
        .keyword = parseColorProperty(node, "code_keyword_color") orelse CODE_KEYWORD_BLUE,
        .comment = parseColorProperty(node, "code_comment_color") orelse CODE_COMMENT_GREEN,
        .string = parseColorProperty(node, "code_string_color") orelse CODE_STRING_RED,
    };
}

fn resolveChrome(node: *const Node) ChromePaint {
    return .{
        .fill = parseColorProperty(node, "chrome_fill"),
        .stroke = parseColorProperty(node, "chrome_stroke"),
        .line_width = parseFloatProperty(node, "chrome_line_width") orelse 1.0,
        .radius = parseFloatProperty(node, "chrome_radius") orelse 10.0,
    };
}

fn resolveUnderline(node: *const Node) UnderlinePaint {
    return .{
        .color = parseColorProperty(node, "underline_color"),
        .width = parseFloatProperty(node, "underline_width") orelse 1.0,
        .offset = parseFloatProperty(node, "underline_offset") orelse -2.0,
    };
}

fn resolveRule(node: *const Node) RulePaint {
    return .{
        .stroke = parseColorProperty(node, "rule_stroke"),
        .line_width = parseFloatProperty(node, "rule_line_width") orelse 1.0,
        .dash = parseDashProperty(node, "rule_dash"),
    };
}

fn lookupTextDefaults(role: []const u8) TextDefaults {
    for (TEXT_DEFAULTS) |entry| {
        if (std.mem.eql(u8, entry.role, role)) return entry;
    }
    return .{ .role = role, .font = "Helvetica", .color = DEFAULT_TEXT_COLOR };
}

fn defaultBoldFont(font: []const u8) []const u8 {
    if (std.mem.eql(u8, font, "Helvetica")) return "Helvetica-Bold";
    if (std.mem.eql(u8, font, "Courier")) return "Courier-Bold";
    return font;
}

fn defaultItalicFont(font: []const u8) []const u8 {
    if (std.mem.eql(u8, font, "Helvetica")) return "Helvetica-Oblique";
    if (std.mem.eql(u8, font, "Courier")) return "Courier-Oblique";
    return font;
}

fn parseFloatProperty(node: *const Node, key: []const u8) ?f32 {
    const value = model.nodeProperty(node, key) orelse return null;
    return std.fmt.parseFloat(f32, value) catch null;
}

fn parseIntProperty(node: *const Node, key: []const u8) ?u32 {
    const raw = model.nodeProperty(node, key) orelse return null;
    return std.fmt.parseInt(u32, raw, 10) catch null;
}

fn parseColorProperty(node: *const Node, key: []const u8) ?Color {
    const value = model.nodeProperty(node, key) orelse return null;
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

fn parseDashProperty(node: *const Node, key: []const u8) ?Dash {
    const value = model.nodeProperty(node, key) orelse return null;
    var parts = std.mem.splitScalar(u8, value, ',');
    const on_text = parts.next() orelse return null;
    const off_text = parts.next() orelse return null;
    if (parts.next() != null) return null;
    return .{
        .on = std.fmt.parseFloat(f32, std.mem.trim(u8, on_text, " ")) catch return null,
        .off = std.fmt.parseFloat(f32, std.mem.trim(u8, off_text, " ")) catch return null,
    };
}
