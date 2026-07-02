const std = @import("std");
const model = @import("model");
const color_utils = @import("utils").color;
const fields = @import("fields.zig");
const font_model = @import("font.zig");
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
    shape,
    chrome_only,
};

pub const ShapeMarker = enum {
    plain,
    arrow,
};

pub const HorizontalAlign = enum {
    left,
    center,
    right,
};

pub const FontFace = font_model.Face;

pub const TextPaint = struct {
    font: FontFace,
    bold_font: FontFace,
    italic_font: FontFace,
    code_font: FontFace,
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
    markdown_code_plain_color: ?Color,
    markdown_code_keyword_color: ?Color,
    markdown_code_function_color: ?Color,
    markdown_code_type_color: ?Color,
    markdown_code_constant_color: ?Color,
    markdown_code_number_color: ?Color,
    markdown_code_variable_color: ?Color,
    markdown_code_operator_color: ?Color,
    markdown_code_comment_color: ?Color,
    markdown_code_string_color: ?Color,
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
};

pub const CodePaint = struct {
    language: ?[]const u8,
    plain: Color,
    keyword: Color,
    function: Color,
    type: Color,
    constant: Color,
    number: Color,
    variable: Color,
    operator: Color,
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

pub const ShapePaint = struct {
    stroke: ?Color,
    line_width: f32,
    dash: ?Dash,
    start_x: f32,
    start_y: f32,
    end_x: f32,
    end_y: f32,
    marker_start: ShapeMarker,
    marker_end: ShapeMarker,
    marker_size: f32,
};

pub const ResolvedRender = struct {
    kind: RenderKind,
    text: ?TextPaint,
    math: ?MathPaint,
    code: ?CodePaint,
    shape: ?ShapePaint,
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
        .shape = resolveShape(ir, node, kind),
        .chrome = resolveChrome(ir, node),
        .underline = resolveUnderline(ir, node),
        .rule = resolveRule(ir, node),
    };
}

pub fn resolveWithEnv(ir: anytype, node: *const Node, sema: anytype) ResolvedRender {
    _ = sema;
    return resolve(ir, node);
}

pub fn resolvePageBackground(ir: anytype, page: *const Node) ?Color {
    if (parseColorProperty(ir, page, "background_fill")) |color| return color;
    const document = ir.getNode(ir.document_id) orelse return null;
    return parseColorProperty(ir, document, "background_fill");
}

pub fn resolvePageBackgroundWithEnv(ir: anytype, page: *const Node, sema: anytype) ?Color {
    _ = sema;
    return resolvePageBackground(ir, page);
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
    const text_metrics = layout.style.textMetricsForNode(ir, node);
    const fonts = font_model.textFacesForNode(ir, node);
    return .{
        .font = fonts.normal,
        .bold_font = fonts.bold,
        .italic_font = fonts.italic,
        .code_font = fonts.code,
        .font_size = text_metrics.font_size,
        .line_height = text_metrics.line_height,
        .color = parseRecordColorProperty(ir, node, "text", "color") orelse FALLBACK_TEXT_COLOR,
        .link_color = parseRecordColorProperty(ir, node, "text", "link_color") orelse FALLBACK_LINK_COLOR,
        .markdown_bold_color = parseRecordColorProperty(ir, node, "text", "markdown_bold_color"),
        .link_underline_width = nonNegativeRecordFloatProperty(ir, node, "text", "link_underline_width") orelse 0,
        .link_underline_offset = recordFloatProperty(ir, node, "text", "link_underline_offset") orelse 0,
        .inline_math_height_factor = positiveRecordFloatProperty(ir, node, "text", "inline_math_height_factor") orelse 1,
        .inline_math_spacing = nonNegativeRecordFloatProperty(ir, node, "text", "inline_math_spacing") orelse 0,
        .display_math_height_factor = positiveRecordFloatProperty(ir, node, "text", "display_math_height_factor") orelse 2,
        .math_align = inheritedTextHorizontalAlign(ir, node) orelse .center,
        .emoji_spacing = nonNegativeRecordFloatProperty(ir, node, "text", "emoji_spacing") orelse 0,
        .markdown_block_gap = nonNegativeRecordFloatProperty(ir, node, "text", "markdown_block_gap") orelse 0,
        .markdown_list_inset = nonNegativeRecordFloatProperty(ir, node, "text", "markdown_list_inset") orelse 0,
        .markdown_list_indent = nonNegativeRecordFloatProperty(ir, node, "text", "markdown_list_indent") orelse 0,
        .markdown_code_font_size = positiveRecordFloatProperty(ir, node, "text", "markdown_code_font_size") orelse layout_style.font_size,
        .markdown_code_line_height = positiveRecordFloatProperty(ir, node, "text", "markdown_code_line_height") orelse layout_style.line_height,
        .markdown_code_pad_x = nonNegativeRecordFloatProperty(ir, node, "text", "markdown_code_pad_x") orelse 0,
        .markdown_code_pad_y = nonNegativeRecordFloatProperty(ir, node, "text", "markdown_code_pad_y") orelse 0,
        .markdown_code_fill = themedRecordColorProperty(ir, node, "text", "markdown_code_fill", "code_theme_fill"),
        .markdown_code_stroke = themedRecordColorProperty(ir, node, "text", "markdown_code_stroke", "code_theme_stroke"),
        .markdown_code_line_width = nonNegativeRecordFloatProperty(ir, node, "text", "markdown_code_line_width") orelse 0,
        .markdown_code_radius = nonNegativeRecordFloatProperty(ir, node, "text", "markdown_code_radius") orelse 0,
        .markdown_code_plain_color = themedRecordColorProperty(ir, node, "text", "markdown_code_plain_color", "code_theme_plain_color"),
        .markdown_code_keyword_color = themedRecordColorProperty(ir, node, "text", "markdown_code_keyword_color", "code_theme_keyword_color"),
        .markdown_code_function_color = themedRecordColorProperty(ir, node, "text", "markdown_code_function_color", "code_theme_function_color"),
        .markdown_code_type_color = themedRecordColorProperty(ir, node, "text", "markdown_code_type_color", "code_theme_type_color"),
        .markdown_code_constant_color = themedRecordColorProperty(ir, node, "text", "markdown_code_constant_color", "code_theme_constant_color"),
        .markdown_code_number_color = themedRecordColorProperty(ir, node, "text", "markdown_code_number_color", "code_theme_number_color"),
        .markdown_code_variable_color = themedRecordColorProperty(ir, node, "text", "markdown_code_variable_color", "code_theme_variable_color"),
        .markdown_code_operator_color = themedRecordColorProperty(ir, node, "text", "markdown_code_operator_color", "code_theme_operator_color"),
        .markdown_code_comment_color = themedRecordColorProperty(ir, node, "text", "markdown_code_comment_color", "code_theme_comment_color"),
        .markdown_code_string_color = themedRecordColorProperty(ir, node, "text", "markdown_code_string_color", "code_theme_string_color"),
        .markdown_table_cell_pad_x = nonNegativeRecordFloatProperty(ir, node, "text", "markdown_table_cell_pad_x") orelse @max(@as(f32, 6.0), layout_style.font_size * 0.55),
        .markdown_table_cell_pad_y = nonNegativeRecordFloatProperty(ir, node, "text", "markdown_table_cell_pad_y") orelse @max(@as(f32, 4.0), layout_style.font_size * 0.32),
        .markdown_table_border = parseRecordColorProperty(ir, node, "text", "markdown_table_border"),
        .markdown_table_line_width = nonNegativeRecordFloatProperty(ir, node, "text", "markdown_table_line_width") orelse 0.8,
        .markdown_table_header_fill = parseRecordColorProperty(ir, node, "text", "markdown_table_header_fill"),
        .markdown_table_alt_row_fill = parseRecordColorProperty(ir, node, "text", "markdown_table_alt_row_fill"),
        .cjk_bold_passes = recordIntProperty(ir, node, "text", "cjk_bold_passes") orelse 1,
        .cjk_bold_dx = recordFloatProperty(ir, node, "text", "cjk_bold_dx") orelse 0,
        .wrap = layout.shouldWrapNode(ir, node),
    };
}

fn resolveMath(ir: anytype, node: *const Node, kind: RenderKind) ?MathPaint {
    if (kind != .vector_math) return null;
    return .{
        .block_line_height = positiveRecordFloatProperty(ir, node, "math", "block_line_height") orelse 22,
        .block_min_height = positiveRecordFloatProperty(ir, node, "math", "block_min_height") orelse 30,
        .block_vertical_padding = nonNegativeRecordFloatProperty(ir, node, "math", "block_vertical_padding") orelse 2,
        .scale = positiveRecordFloatProperty(ir, node, "math", "scale") orelse 1,
        .horizontal_align = inheritedMathHorizontalAlign(ir, node) orelse .center,
    };
}

fn resolveCode(ir: anytype, node: *const Node, kind: RenderKind) ?CodePaint {
    if (kind != .code) return null;
    const plain = themedRecordColorProperty(ir, node, "code", "plain_color", "code_theme_plain_color") orelse parseRecordColorProperty(ir, node, "text", "color") orelse FALLBACK_TEXT_COLOR;
    return .{
        .language = fields.read(ir.allocator, ir, node, "language", &.{}, .text),
        .plain = plain,
        .keyword = themedRecordColorProperty(ir, node, "code", "keyword_color", "code_theme_keyword_color") orelse plain,
        .function = themedRecordColorProperty(ir, node, "code", "function_color", "code_theme_function_color") orelse plain,
        .type = themedRecordColorProperty(ir, node, "code", "type_color", "code_theme_type_color") orelse plain,
        .constant = themedRecordColorProperty(ir, node, "code", "constant_color", "code_theme_constant_color") orelse plain,
        .number = themedRecordColorProperty(ir, node, "code", "number_color", "code_theme_number_color") orelse plain,
        .variable = themedRecordColorProperty(ir, node, "code", "variable_color", "code_theme_variable_color") orelse plain,
        .operator = themedRecordColorProperty(ir, node, "code", "operator_color", "code_theme_operator_color") orelse plain,
        .comment = themedRecordColorProperty(ir, node, "code", "comment_color", "code_theme_comment_color") orelse plain,
        .string = themedRecordColorProperty(ir, node, "code", "string_color", "code_theme_string_color") orelse plain,
    };
}

fn resolveShape(ir: anytype, node: *const Node, kind: RenderKind) ?ShapePaint {
    if (kind != .shape) return null;
    return .{
        .stroke = parseRecordColorProperty(ir, node, "shape", "stroke"),
        .line_width = nonNegativeRecordFloatProperty(ir, node, "shape", "line_width") orelse 0,
        .dash = parseRecordDashProperty(ir, node, "shape", "dash"),
        .start_x = recordFloatProperty(ir, node, "shape", "start_x") orelse 0,
        .start_y = recordFloatProperty(ir, node, "shape", "start_y") orelse 0,
        .end_x = recordFloatProperty(ir, node, "shape", "end_x") orelse 1,
        .end_y = recordFloatProperty(ir, node, "shape", "end_y") orelse 1,
        .marker_start = parseRecordShapeMarkerProperty(ir, node, "shape", "marker_start") orelse .plain,
        .marker_end = parseRecordShapeMarkerProperty(ir, node, "shape", "marker_end") orelse .plain,
        .marker_size = nonNegativeRecordFloatProperty(ir, node, "shape", "marker_size") orelse 0,
    };
}

fn resolveChrome(ir: anytype, node: *const Node) ChromePaint {
    return .{
        .fill = parseRecordColorProperty(ir, node, "chrome", "fill"),
        .stroke = parseRecordColorProperty(ir, node, "chrome", "stroke"),
        .line_width = nonNegativeRecordFloatProperty(ir, node, "chrome", "line_width") orelse 0,
        .radius = nonNegativeRecordFloatProperty(ir, node, "chrome", "radius") orelse 0,
        .pad_x = nonNegativeRecordFloatProperty(ir, node, "chrome", "pad_x") orelse 0,
        .pad_y = nonNegativeRecordFloatProperty(ir, node, "chrome", "pad_y") orelse 0,
    };
}

fn resolveUnderline(ir: anytype, node: *const Node) UnderlinePaint {
    return .{
        .color = parseRecordColorProperty(ir, node, "underline", "color"),
        .width = nonNegativeRecordFloatProperty(ir, node, "underline", "width") orelse 0,
        .offset = recordFloatProperty(ir, node, "underline", "offset") orelse 0,
    };
}

fn resolveRule(ir: anytype, node: *const Node) RulePaint {
    return .{
        .stroke = parseRecordColorProperty(ir, node, "rule", "stroke"),
        .line_width = nonNegativeRecordFloatProperty(ir, node, "rule", "line_width") orelse 0,
        .dash = parseRecordDashProperty(ir, node, "rule", "dash"),
    };
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

fn recordIntProperty(ir: anytype, node: *const Node, record_key: []const u8, field_name: []const u8) ?u32 {
    const value = recordFloatProperty(ir, node, record_key, field_name) orelse return null;
    if (!std.math.isFinite(value) or value < 0) return null;
    return @intFromFloat(@round(value));
}

fn parseRecordColorProperty(ir: anytype, node: *const Node, record_key: []const u8, field_name: []const u8) ?Color {
    const value = fields.read(ir.allocator, ir, node, record_key, &.{field_name}, .text) orelse return null;
    return parseColor(value);
}

fn parseRecordDashProperty(ir: anytype, node: *const Node, record_key: []const u8, field_name: []const u8) ?Dash {
    const value = fields.read(ir.allocator, ir, node, record_key, &.{field_name}, .text) orelse return null;
    return parseDash(value);
}

fn parseRecordShapeMarkerProperty(ir: anytype, node: *const Node, record_key: []const u8, field_name: []const u8) ?ShapeMarker {
    const value = fields.read(ir.allocator, ir, node, record_key, &.{field_name}, .text) orelse return null;
    return parseShapeMarker(value);
}

fn inheritedTextHorizontalAlign(ir: anytype, node: *const Node) ?HorizontalAlign {
    if (explicitRecordHorizontalAlign(node, "text", "math_align")) |value| return value;
    if (inheritedHorizontalAlignProperty(ir, node, "math_align")) |value| return value;
    const value = fields.read(ir.allocator, ir, node, "text", &.{"math_align"}, .text) orelse return null;
    return parseHorizontalAlign(value);
}

fn inheritedMathHorizontalAlign(ir: anytype, node: *const Node) ?HorizontalAlign {
    if (explicitRecordHorizontalAlign(node, "math", "align")) |value| return value;
    if (inheritedHorizontalAlignProperty(ir, node, "math_align")) |value| return value;
    const value = fields.read(ir.allocator, ir, node, "math", &.{"align"}, .text) orelse return null;
    return parseHorizontalAlign(value);
}

fn explicitRecordHorizontalAlign(node: *const Node, record_key: []const u8, field_name: []const u8) ?HorizontalAlign {
    const record_value = model.nodeField(node, record_key) orelse return null;
    if (record_value != .record) return null;
    for (record_value.record.fields.items) |field| {
        if (!field.explicit or !std.mem.eql(u8, field.name, field_name)) continue;
        return switch (field.value) {
            .enum_case => |case| parseHorizontalAlign(case.case_name),
            .string => |text| parseHorizontalAlign(text),
            else => null,
        };
    }
    return null;
}

fn themedRecordColorProperty(ir: anytype, node: *const Node, record_key: []const u8, field_name: []const u8, theme_key: []const u8) ?Color {
    if (explicitRecordColorProperty(node, record_key, field_name)) |color| return color;
    if (node.kind == .object) {
        if (ir.parentPageOf(node.id)) |page_id| {
            if (ir.getNode(page_id)) |page| {
                if (explicitColorProperty(page, theme_key)) |color| return color;
            }
        }
    }
    if (node.kind == .object or node.kind == .page) {
        if (ir.getNode(ir.document_id)) |document| {
            if (explicitColorProperty(document, theme_key)) |color| return color;
        }
    }
    return parseRecordColorProperty(ir, node, record_key, field_name);
}

fn explicitRecordColorProperty(node: *const Node, record_key: []const u8, field_name: []const u8) ?Color {
    const record_value = model.nodeField(node, record_key) orelse return null;
    if (record_value != .record) return null;
    for (record_value.record.fields.items) |field| {
        if (!field.explicit or !std.mem.eql(u8, field.name, field_name)) continue;
        return switch (field.value) {
            .string => |text| parseColor(text),
            else => null,
        };
    }
    return null;
}

fn parseRenderKindProperty(ir: anytype, node: *const Node) ?RenderKind {
    const value = fields.read(ir.allocator, ir, node, "render_kind", &.{}, .text) orelse return null;
    return parseRenderKind(value);
}

fn parseRenderKind(value: []const u8) ?RenderKind {
    return std.meta.stringToEnum(RenderKind, value);
}

fn parseShapeMarkerProperty(ir: anytype, node: *const Node, key: []const u8) ?ShapeMarker {
    const value = fields.read(ir.allocator, ir, node, key, &.{}, .text) orelse return null;
    return parseShapeMarker(value);
}

fn parseShapeMarker(value: []const u8) ?ShapeMarker {
    return std.meta.stringToEnum(ShapeMarker, value);
}

fn parseHorizontalAlignProperty(ir: anytype, node: *const Node, key: []const u8) ?HorizontalAlign {
    const value = fields.read(ir.allocator, ir, node, key, &.{}, .text) orelse return null;
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

fn explicitHorizontalAlignProperty(node: *const Node, key: []const u8) ?HorizontalAlign {
    const value = model.nodeField(node, key) orelse return null;
    return switch (value) {
        .enum_case => |case| parseHorizontalAlign(case.case_name),
        .string => |text| parseHorizontalAlign(text),
        else => null,
    };
}

fn parseHorizontalAlign(value: []const u8) ?HorizontalAlign {
    return std.meta.stringToEnum(HorizontalAlign, value);
}

fn parseFloatProperty(ir: anytype, node: *const Node, key: []const u8) ?f32 {
    return fields.read(ir.allocator, ir, node, key, &.{}, .number);
}

fn positiveFloatProperty(ir: anytype, node: *const Node, key: []const u8) ?f32 {
    const value = parseFloatProperty(ir, node, key) orelse return null;
    return if (value > 0) value else null;
}

fn nonNegativeFloatProperty(ir: anytype, node: *const Node, key: []const u8) ?f32 {
    const value = parseFloatProperty(ir, node, key) orelse return null;
    return if (value >= 0) value else null;
}

fn parseIntProperty(ir: anytype, node: *const Node, key: []const u8) ?u32 {
    const raw = fields.read(ir.allocator, ir, node, key, &.{}, .number) orelse return null;
    if (!std.math.isFinite(raw) or raw < 0) return null;
    return @intFromFloat(@round(raw));
}

fn parseColorProperty(ir: anytype, node: *const Node, key: []const u8) ?Color {
    const value = fields.read(ir.allocator, ir, node, key, &.{}, .text) orelse return null;
    return parseColor(value);
}

fn themedColorProperty(ir: anytype, node: *const Node, key: []const u8, theme_key: []const u8) ?Color {
    if (explicitColorProperty(node, key)) |color| return color;
    if (node.kind == .object) {
        if (ir.parentPageOf(node.id)) |page_id| {
            if (ir.getNode(page_id)) |page| {
                if (explicitColorProperty(page, theme_key)) |color| return color;
            }
        }
    }
    if (node.kind == .object or node.kind == .page) {
        if (ir.getNode(ir.document_id)) |document| {
            if (explicitColorProperty(document, theme_key)) |color| return color;
        }
    }
    return parseColorProperty(ir, node, key);
}

fn explicitColorProperty(node: *const Node, key: []const u8) ?Color {
    const value = model.nodeField(node, key) orelse return null;
    return switch (value) {
        .string => |text| parseColor(text),
        else => null,
    };
}

fn parseColor(value: []const u8) ?Color {
    const rgb = color_utils.parse(value) orelse return null;
    return .{ .r = rgb.r, .g = rgb.g, .b = rgb.b };
}

fn parseDashProperty(ir: anytype, node: *const Node, key: []const u8) ?Dash {
    const value = fields.read(ir.allocator, ir, node, key, &.{}, .text) orelse return null;
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
