const std = @import("std");
const model = @import("model");
const color_utils = @import("utils").color;
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

pub const HorizontalAlign = enum {
    left,
    center,
    right,
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
    markdown_bold_color: ?Color,
    link_underline_width: f32,
    link_underline_offset: f32,
    inline_math_height_factor: f32,
    inline_math_spacing: f32,
    display_math_height_factor: f32,
    math_align: HorizontalAlign,
    emoji_spacing: f32,
    markdown_block_gap: f32,
    markdown_list_inset: f32,
    markdown_list_indent: f32,
    markdown_code_font_size: f32,
    markdown_code_line_height: f32,
    markdown_code_pad_x: f32,
    markdown_code_pad_y: f32,
    markdown_code_fill: ?Color,
    markdown_code_stroke: ?Color,
    markdown_code_line_width: f32,
    markdown_code_radius: f32,
    markdown_table_cell_pad_x: f32,
    markdown_table_cell_pad_y: f32,
    markdown_table_border: ?Color,
    markdown_table_line_width: f32,
    markdown_table_header_fill: ?Color,
    markdown_table_alt_row_fill: ?Color,
    cjk_bold_passes: u32,
    cjk_bold_dx: f32,
    wrap: bool,
};

pub const MathPaint = struct {
    block_line_height: f32,
    block_min_height: f32,
    block_vertical_padding: f32,
    scale: f32,
    horizontal_align: HorizontalAlign,
    color: Color,
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
    pad_x: f32,
    pad_y: f32,
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

pub fn resolveWithEnv(ir: anytype, node: *const Node, sema: anytype) ResolvedRender {
    const kind = resolveKindWithEnv(node, sema);
    return .{
        .kind = kind,
        .text = resolveTextWithEnv(ir, node, kind, sema),
        .math = resolveMathWithEnv(ir, node, kind, sema),
        .code = resolveCodeWithEnv(node, kind, sema),
        .chrome = resolveChromeWithEnv(node, sema),
        .underline = resolveUnderlineWithEnv(node, sema),
        .rule = resolveRuleWithEnv(node, sema),
    };
}

pub fn resolvePageBackground(ir: anytype, page: *const Node) ?Color {
    if (parseColorProperty(ir, page, "background_fill")) |color| return color;
    const document = ir.getNode(ir.document_id) orelse return null;
    return parseColorProperty(ir, document, "background_fill");
}

pub fn resolvePageBackgroundWithEnv(ir: anytype, page: *const Node, sema: anytype) ?Color {
    if (parseColorPropertyWithEnv(page, "background_fill", sema)) |color| return color;
    const document = ir.getNode(ir.document_id) orelse return null;
    return parseColorPropertyWithEnv(document, "background_fill", sema);
}

pub fn resolveKind(ir: anytype, node: *const Node) RenderKind {
    if (parseRenderKindProperty(ir, node)) |kind| return kind;
    return .text;
}

pub fn resolveKindWithEnv(node: *const Node, sema: anytype) RenderKind {
    if (parseRenderKindPropertyWithEnv(node, sema)) |kind| return kind;
    return .text;
}

fn resolveText(ir: anytype, node: *const Node, kind: RenderKind) ?TextPaint {
    switch (kind) {
        .text, .code => {},
        else => return null,
    }

    const layout_style = layout.styleForNode(ir, node);
    const text_metrics = layout.style.textMetricsForNode(ir, node);
    const font = stringProperty(ir, node, "text_font", "Helvetica");
    return .{
        .font = font,
        .bold_font = stringProperty(ir, node, "text_bold_font", font),
        .italic_font = stringProperty(ir, node, "text_italic_font", font),
        .code_font = stringProperty(ir, node, "text_code_font", "Courier"),
        .font_size = text_metrics.font_size,
        .line_height = text_metrics.line_height,
        .color = parseColorProperty(ir, node, "text_color") orelse FALLBACK_TEXT_COLOR,
        .link_color = parseColorProperty(ir, node, "text_link_color") orelse FALLBACK_LINK_COLOR,
        .markdown_bold_color = parseColorProperty(ir, node, "text_markdown_bold_color"),
        .link_underline_width = nonNegativeFloatProperty(ir, node, "text_link_underline_width") orelse 0,
        .link_underline_offset = parseFloatProperty(ir, node, "text_link_underline_offset") orelse 0,
        .inline_math_height_factor = positiveFloatProperty(ir, node, "text_inline_math_height_factor") orelse 1,
        .inline_math_spacing = nonNegativeFloatProperty(ir, node, "text_inline_math_spacing") orelse 0,
        .display_math_height_factor = positiveFloatProperty(ir, node, "text_display_math_height_factor") orelse 2,
        .math_align = inheritedHorizontalAlignProperty(ir, node, "math_align") orelse .center,
        .emoji_spacing = nonNegativeFloatProperty(ir, node, "text_emoji_spacing") orelse 0,
        .markdown_block_gap = nonNegativeFloatProperty(ir, node, "text_markdown_block_gap") orelse 0,
        .markdown_list_inset = nonNegativeFloatProperty(ir, node, "text_markdown_list_inset") orelse 0,
        .markdown_list_indent = nonNegativeFloatProperty(ir, node, "text_markdown_list_indent") orelse 0,
        .markdown_code_font_size = positiveFloatProperty(ir, node, "text_markdown_code_font_size") orelse layout_style.font_size,
        .markdown_code_line_height = positiveFloatProperty(ir, node, "text_markdown_code_line_height") orelse layout_style.line_height,
        .markdown_code_pad_x = nonNegativeFloatProperty(ir, node, "text_markdown_code_pad_x") orelse 0,
        .markdown_code_pad_y = nonNegativeFloatProperty(ir, node, "text_markdown_code_pad_y") orelse 0,
        .markdown_code_fill = parseColorProperty(ir, node, "text_markdown_code_fill"),
        .markdown_code_stroke = parseColorProperty(ir, node, "text_markdown_code_stroke"),
        .markdown_code_line_width = nonNegativeFloatProperty(ir, node, "text_markdown_code_line_width") orelse 0,
        .markdown_code_radius = nonNegativeFloatProperty(ir, node, "text_markdown_code_radius") orelse 0,
        .markdown_table_cell_pad_x = nonNegativeFloatProperty(ir, node, "text_markdown_table_cell_pad_x") orelse @max(@as(f32, 6.0), layout_style.font_size * 0.55),
        .markdown_table_cell_pad_y = nonNegativeFloatProperty(ir, node, "text_markdown_table_cell_pad_y") orelse @max(@as(f32, 4.0), layout_style.font_size * 0.32),
        .markdown_table_border = parseColorProperty(ir, node, "text_markdown_table_border"),
        .markdown_table_line_width = nonNegativeFloatProperty(ir, node, "text_markdown_table_line_width") orelse 0.8,
        .markdown_table_header_fill = parseColorProperty(ir, node, "text_markdown_table_header_fill"),
        .markdown_table_alt_row_fill = parseColorProperty(ir, node, "text_markdown_table_alt_row_fill"),
        .cjk_bold_passes = parseIntProperty(ir, node, "text_cjk_bold_passes") orelse 1,
        .cjk_bold_dx = parseFloatProperty(ir, node, "text_cjk_bold_dx") orelse 0,
        .wrap = layout.shouldWrapNode(ir, node),
    };
}

fn resolveMath(ir: anytype, node: *const Node, kind: RenderKind) ?MathPaint {
    if (kind != .vector_math) return null;
    return .{
        .block_line_height = positiveFloatProperty(ir, node, "math_block_line_height") orelse 22,
        .block_min_height = positiveFloatProperty(ir, node, "math_block_min_height") orelse 30,
        .block_vertical_padding = nonNegativeFloatProperty(ir, node, "math_block_vertical_padding") orelse 2,
        .scale = positiveFloatProperty(ir, node, "math_scale") orelse 1,
        .horizontal_align = inheritedHorizontalAlignProperty(ir, node, "math_align") orelse .center,
        .color = parseColorProperty(ir, node, "text_color") orelse FALLBACK_TEXT_COLOR,
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

fn resolveTextWithEnv(ir: anytype, node: *const Node, kind: RenderKind, sema: anytype) ?TextPaint {
    switch (kind) {
        .text, .code => {},
        else => return null,
    }

    const layout_style = layout.styleForNode(ir, node);
    const text_metrics = layout.style.textMetricsForNode(ir, node);
    const font = stringPropertyWithEnv(node, "text_font", "Helvetica", sema);
    return .{
        .font = font,
        .bold_font = stringPropertyWithEnv(node, "text_bold_font", font, sema),
        .italic_font = stringPropertyWithEnv(node, "text_italic_font", font, sema),
        .code_font = stringPropertyWithEnv(node, "text_code_font", "Courier", sema),
        .font_size = text_metrics.font_size,
        .line_height = text_metrics.line_height,
        .color = parseColorPropertyWithEnv(node, "text_color", sema) orelse FALLBACK_TEXT_COLOR,
        .link_color = parseColorPropertyWithEnv(node, "text_link_color", sema) orelse FALLBACK_LINK_COLOR,
        .markdown_bold_color = parseColorPropertyWithEnv(node, "text_markdown_bold_color", sema),
        .link_underline_width = nonNegativeFloatPropertyWithEnv(node, "text_link_underline_width", sema) orelse 0,
        .link_underline_offset = parseFloatPropertyWithEnv(node, "text_link_underline_offset", sema) orelse 0,
        .inline_math_height_factor = positiveFloatPropertyWithEnv(node, "text_inline_math_height_factor", sema) orelse 1,
        .inline_math_spacing = nonNegativeFloatPropertyWithEnv(node, "text_inline_math_spacing", sema) orelse 0,
        .display_math_height_factor = positiveFloatPropertyWithEnv(node, "text_display_math_height_factor", sema) orelse 2,
        .math_align = inheritedHorizontalAlignPropertyWithEnv(ir, node, "math_align", sema) orelse .center,
        .emoji_spacing = nonNegativeFloatPropertyWithEnv(node, "text_emoji_spacing", sema) orelse 0,
        .markdown_block_gap = nonNegativeFloatPropertyWithEnv(node, "text_markdown_block_gap", sema) orelse 0,
        .markdown_list_inset = nonNegativeFloatPropertyWithEnv(node, "text_markdown_list_inset", sema) orelse 0,
        .markdown_list_indent = nonNegativeFloatPropertyWithEnv(node, "text_markdown_list_indent", sema) orelse 0,
        .markdown_code_font_size = positiveFloatPropertyWithEnv(node, "text_markdown_code_font_size", sema) orelse layout_style.font_size,
        .markdown_code_line_height = positiveFloatPropertyWithEnv(node, "text_markdown_code_line_height", sema) orelse layout_style.line_height,
        .markdown_code_pad_x = nonNegativeFloatPropertyWithEnv(node, "text_markdown_code_pad_x", sema) orelse 0,
        .markdown_code_pad_y = nonNegativeFloatPropertyWithEnv(node, "text_markdown_code_pad_y", sema) orelse 0,
        .markdown_code_fill = parseColorPropertyWithEnv(node, "text_markdown_code_fill", sema),
        .markdown_code_stroke = parseColorPropertyWithEnv(node, "text_markdown_code_stroke", sema),
        .markdown_code_line_width = nonNegativeFloatPropertyWithEnv(node, "text_markdown_code_line_width", sema) orelse 0,
        .markdown_code_radius = nonNegativeFloatPropertyWithEnv(node, "text_markdown_code_radius", sema) orelse 0,
        .markdown_table_cell_pad_x = nonNegativeFloatPropertyWithEnv(node, "text_markdown_table_cell_pad_x", sema) orelse @max(@as(f32, 6.0), layout_style.font_size * 0.55),
        .markdown_table_cell_pad_y = nonNegativeFloatPropertyWithEnv(node, "text_markdown_table_cell_pad_y", sema) orelse @max(@as(f32, 4.0), layout_style.font_size * 0.32),
        .markdown_table_border = parseColorPropertyWithEnv(node, "text_markdown_table_border", sema),
        .markdown_table_line_width = nonNegativeFloatPropertyWithEnv(node, "text_markdown_table_line_width", sema) orelse 0.8,
        .markdown_table_header_fill = parseColorPropertyWithEnv(node, "text_markdown_table_header_fill", sema),
        .markdown_table_alt_row_fill = parseColorPropertyWithEnv(node, "text_markdown_table_alt_row_fill", sema),
        .cjk_bold_passes = parseIntPropertyWithEnv(node, "text_cjk_bold_passes", sema) orelse 1,
        .cjk_bold_dx = parseFloatPropertyWithEnv(node, "text_cjk_bold_dx", sema) orelse 0,
        .wrap = layout.shouldWrapNode(ir, node),
    };
}

fn resolveMathWithEnv(ir: anytype, node: *const Node, kind: RenderKind, sema: anytype) ?MathPaint {
    if (kind != .vector_math) return null;
    return .{
        .block_line_height = positiveFloatPropertyWithEnv(node, "math_block_line_height", sema) orelse 22,
        .block_min_height = positiveFloatPropertyWithEnv(node, "math_block_min_height", sema) orelse 30,
        .block_vertical_padding = nonNegativeFloatPropertyWithEnv(node, "math_block_vertical_padding", sema) orelse 2,
        .scale = positiveFloatPropertyWithEnv(node, "math_scale", sema) orelse 1,
        .horizontal_align = inheritedHorizontalAlignPropertyWithEnv(ir, node, "math_align", sema) orelse .center,
        .color = parseColorPropertyWithEnv(node, "text_color", sema) orelse FALLBACK_TEXT_COLOR,
    };
}

fn resolveCodeWithEnv(node: *const Node, kind: RenderKind, sema: anytype) ?CodePaint {
    if (kind != .code) return null;
    const plain = parseColorPropertyWithEnv(node, "code_plain_color", sema) orelse parseColorPropertyWithEnv(node, "text_color", sema) orelse FALLBACK_TEXT_COLOR;
    return .{
        .language = class_fields.propertyWithEnv(node, "language", sema),
        .plain = plain,
        .keyword = parseColorPropertyWithEnv(node, "code_keyword_color", sema) orelse plain,
        .comment = parseColorPropertyWithEnv(node, "code_comment_color", sema) orelse plain,
        .string = parseColorPropertyWithEnv(node, "code_string_color", sema) orelse plain,
    };
}

fn resolveChromeWithEnv(node: *const Node, sema: anytype) ChromePaint {
    return .{
        .fill = parseColorPropertyWithEnv(node, "chrome_fill", sema),
        .stroke = parseColorPropertyWithEnv(node, "chrome_stroke", sema),
        .line_width = nonNegativeFloatPropertyWithEnv(node, "chrome_line_width", sema) orelse 0,
        .radius = nonNegativeFloatPropertyWithEnv(node, "chrome_radius", sema) orelse 0,
        .pad_x = nonNegativeFloatPropertyWithEnv(node, "chrome_pad_x", sema) orelse 0,
        .pad_y = nonNegativeFloatPropertyWithEnv(node, "chrome_pad_y", sema) orelse 0,
    };
}

fn resolveUnderlineWithEnv(node: *const Node, sema: anytype) UnderlinePaint {
    return .{
        .color = parseColorPropertyWithEnv(node, "underline_color", sema),
        .width = nonNegativeFloatPropertyWithEnv(node, "underline_width", sema) orelse 0,
        .offset = parseFloatPropertyWithEnv(node, "underline_offset", sema) orelse 0,
    };
}

fn resolveRuleWithEnv(node: *const Node, sema: anytype) RulePaint {
    return .{
        .stroke = parseColorPropertyWithEnv(node, "rule_stroke", sema),
        .line_width = nonNegativeFloatPropertyWithEnv(node, "rule_line_width", sema) orelse 0,
        .dash = parseDashPropertyWithEnv(node, "rule_dash", sema),
    };
}

fn resolveChrome(ir: anytype, node: *const Node) ChromePaint {
    return .{
        .fill = parseColorProperty(ir, node, "chrome_fill"),
        .stroke = parseColorProperty(ir, node, "chrome_stroke"),
        .line_width = nonNegativeFloatProperty(ir, node, "chrome_line_width") orelse 0,
        .radius = nonNegativeFloatProperty(ir, node, "chrome_radius") orelse 0,
        .pad_x = nonNegativeFloatProperty(ir, node, "chrome_pad_x") orelse 0,
        .pad_y = nonNegativeFloatProperty(ir, node, "chrome_pad_y") orelse 0,
    };
}

fn resolveUnderline(ir: anytype, node: *const Node) UnderlinePaint {
    return .{
        .color = parseColorProperty(ir, node, "underline_color"),
        .width = nonNegativeFloatProperty(ir, node, "underline_width") orelse 0,
        .offset = parseFloatProperty(ir, node, "underline_offset") orelse 0,
    };
}

fn resolveRule(ir: anytype, node: *const Node) RulePaint {
    return .{
        .stroke = parseColorProperty(ir, node, "rule_stroke"),
        .line_width = nonNegativeFloatProperty(ir, node, "rule_line_width") orelse 0,
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
    if (std.mem.eql(u8, value, "chrome_only")) return .chrome_only;
    return null;
}

fn parseRenderKindPropertyWithEnv(node: *const Node, sema: anytype) ?RenderKind {
    const value = class_fields.propertyWithEnv(node, "render_kind", sema) orelse return null;
    return parseRenderKind(value);
}

fn parseRenderKind(value: []const u8) ?RenderKind {
    if (std.mem.eql(u8, value, "text")) return .text;
    if (std.mem.eql(u8, value, "code")) return .code;
    if (std.mem.eql(u8, value, "vector_math")) return .vector_math;
    if (std.mem.eql(u8, value, "vector_asset")) return .vector_asset;
    if (std.mem.eql(u8, value, "raster_asset")) return .raster_asset;
    if (std.mem.eql(u8, value, "chrome_only")) return .chrome_only;
    return null;
}

fn parseHorizontalAlignProperty(ir: anytype, node: *const Node, key: []const u8) ?HorizontalAlign {
    const value = class_fields.property(ir, node, key) orelse return null;
    return parseHorizontalAlign(value);
}

fn parseHorizontalAlignPropertyWithEnv(node: *const Node, key: []const u8, sema: anytype) ?HorizontalAlign {
    const value = class_fields.propertyWithEnv(node, key, sema) orelse return null;
    return parseHorizontalAlign(value);
}

fn inheritedHorizontalAlignProperty(ir: anytype, node: *const Node, key: []const u8) ?HorizontalAlign {
    if (explicitHorizontalAlignProperty(node, key)) |value| return value;
    if (node.kind == .object) {
        if (ir.parentPageOf(node.id)) |page_id| {
            if (ir.getNode(page_id)) |page| {
                if (explicitHorizontalAlignProperty(page, key)) |value| return value;
            }
        }
    }
    if (node.kind == .object or node.kind == .page) {
        if (ir.getNode(ir.document_id)) |document| {
            if (explicitHorizontalAlignProperty(document, key)) |value| return value;
        }
    }
    return parseHorizontalAlignProperty(ir, node, key);
}

fn inheritedHorizontalAlignPropertyWithEnv(ir: anytype, node: *const Node, key: []const u8, sema: anytype) ?HorizontalAlign {
    if (explicitHorizontalAlignProperty(node, key)) |value| return value;
    if (node.kind == .object) {
        if (ir.parentPageOf(node.id)) |page_id| {
            if (ir.getNode(page_id)) |page| {
                if (explicitHorizontalAlignProperty(page, key)) |value| return value;
            }
        }
    }
    if (node.kind == .object or node.kind == .page) {
        if (ir.getNode(ir.document_id)) |document| {
            if (explicitHorizontalAlignProperty(document, key)) |value| return value;
        }
    }
    return parseHorizontalAlignPropertyWithEnv(node, key, sema);
}

fn explicitHorizontalAlignProperty(node: *const Node, key: []const u8) ?HorizontalAlign {
    const value = model.nodeProperty(node, key) orelse return null;
    return parseHorizontalAlign(value);
}

fn parseHorizontalAlign(value: []const u8) ?HorizontalAlign {
    if (std.mem.eql(u8, value, "left")) return .left;
    if (std.mem.eql(u8, value, "center")) return .center;
    if (std.mem.eql(u8, value, "right")) return .right;
    return null;
}

fn stringProperty(ir: anytype, node: *const Node, key: []const u8, fallback: []const u8) []const u8 {
    return class_fields.property(ir, node, key) orelse fallback;
}

fn stringPropertyWithEnv(node: *const Node, key: []const u8, fallback: []const u8, sema: anytype) []const u8 {
    return class_fields.propertyWithEnv(node, key, sema) orelse fallback;
}

fn parseFloatProperty(ir: anytype, node: *const Node, key: []const u8) ?f32 {
    const value = class_fields.property(ir, node, key) orelse return null;
    const parsed = std.fmt.parseFloat(f32, value) catch return null;
    return if (std.math.isFinite(parsed)) parsed else null;
}

fn parseFloatPropertyWithEnv(node: *const Node, key: []const u8, sema: anytype) ?f32 {
    const value = class_fields.propertyWithEnv(node, key, sema) orelse return null;
    const parsed = std.fmt.parseFloat(f32, value) catch return null;
    return if (std.math.isFinite(parsed)) parsed else null;
}

fn positiveFloatProperty(ir: anytype, node: *const Node, key: []const u8) ?f32 {
    const value = parseFloatProperty(ir, node, key) orelse return null;
    return if (value > 0) value else null;
}

fn positiveFloatPropertyWithEnv(node: *const Node, key: []const u8, sema: anytype) ?f32 {
    const value = parseFloatPropertyWithEnv(node, key, sema) orelse return null;
    return if (value > 0) value else null;
}

fn nonNegativeFloatProperty(ir: anytype, node: *const Node, key: []const u8) ?f32 {
    const value = parseFloatProperty(ir, node, key) orelse return null;
    return if (value >= 0) value else null;
}

fn nonNegativeFloatPropertyWithEnv(node: *const Node, key: []const u8, sema: anytype) ?f32 {
    const value = parseFloatPropertyWithEnv(node, key, sema) orelse return null;
    return if (value >= 0) value else null;
}

fn parseIntProperty(ir: anytype, node: *const Node, key: []const u8) ?u32 {
    const raw = class_fields.property(ir, node, key) orelse return null;
    return std.fmt.parseInt(u32, raw, 10) catch null;
}

fn parseIntPropertyWithEnv(node: *const Node, key: []const u8, sema: anytype) ?u32 {
    const raw = class_fields.propertyWithEnv(node, key, sema) orelse return null;
    return std.fmt.parseInt(u32, raw, 10) catch null;
}

fn parseColorProperty(ir: anytype, node: *const Node, key: []const u8) ?Color {
    const value = class_fields.property(ir, node, key) orelse return null;
    return parseColor(value);
}

fn parseColorPropertyWithEnv(node: *const Node, key: []const u8, sema: anytype) ?Color {
    const value = class_fields.propertyWithEnv(node, key, sema) orelse return null;
    return parseColor(value);
}

fn parseColor(value: []const u8) ?Color {
    const rgb = color_utils.parse(value) orelse return null;
    return .{ .r = rgb.r, .g = rgb.g, .b = rgb.b };
}

fn parseDashProperty(ir: anytype, node: *const Node, key: []const u8) ?Dash {
    const value = class_fields.property(ir, node, key) orelse return null;
    return parseDash(value);
}

fn parseDashPropertyWithEnv(node: *const Node, key: []const u8, sema: anytype) ?Dash {
    const value = class_fields.propertyWithEnv(node, key, sema) orelse return null;
    return parseDash(value);
}

fn parseDash(value: []const u8) ?Dash {
    var parts = std.mem.splitScalar(u8, value, ',');
    const on_text = parts.next() orelse return null;
    const off_text = parts.next() orelse return null;
    if (parts.next() != null) return null;
    const on = std.fmt.parseFloat(f32, std.mem.trim(u8, on_text, " ")) catch return null;
    const off = std.fmt.parseFloat(f32, std.mem.trim(u8, off_text, " ")) catch return null;
    if (!std.math.isFinite(on) or !std.math.isFinite(off)) return null;
    if (on <= 0 or off <= 0) return null;
    return .{ .on = on, .off = off };
}
