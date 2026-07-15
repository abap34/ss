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
    min_height: f32,
    raw_tex_width_ratio: f32,
    scale: f32,
    horizontal_align: HorizontalAlign,
};

pub const AssetPaint = struct {
    scale: f32,
    pdf_page: usize,
    pdf_box: PdfPageBox,
};

pub const PdfPageBox = enum {
    media,
    crop,
    bleed,
    trim,
    art,
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
    asset: ?AssetPaint,
    code: ?CodePaint,
    shape: ?ShapePaint,
    chrome: ChromePaint,
    underline: UnderlinePaint,
    rule: RulePaint,
};

const FALLBACK_TEXT_COLOR = Color{ .r = 0.08, .g = 0.08, .b = 0.08 };
const FALLBACK_LINK_COLOR = Color{ .r = 0.1, .g = 0.25, .b = 0.75 };

pub fn resolve(state: anytype, node: *const Node) ResolvedRender {
    const kind = resolveKind(state, node);
    return .{
        .kind = kind,
        .text = resolveText(state, node, kind),
        .math = resolveMath(state, node, kind),
        .asset = resolveAsset(state, node, kind),
        .code = resolveCode(state, node, kind),
        .shape = resolveShape(state, node, kind),
        .chrome = resolveChrome(state, node),
        .underline = resolveUnderline(state, node),
        .rule = resolveRule(state, node),
    };
}

pub fn resolvePageBackground(state: anytype, page: *const Node) ?Color {
    if (parseColorProperty(state, page, "background_fill")) |color| return color;
    const document = state.getNode(state.document_id) orelse return null;
    return parseColorProperty(state, document, "background_fill");
}

pub fn resolveKind(state: anytype, node: *const Node) RenderKind {
    if (parseRenderKindProperty(state, node)) |kind| return kind;
    return .text;
}

fn resolveText(state: anytype, node: *const Node, kind: RenderKind) ?TextPaint {
    switch (kind) {
        .text, .code => {},
        else => return null,
    }

    const layout_style = layout.styleForNode(state, node);
    const text_metrics = layout.style.textMetricsForNode(state, node);
    const fonts = font_model.textFacesForNode(state, node);
    return .{
        .font = fonts.normal,
        .bold_font = fonts.bold,
        .italic_font = fonts.italic,
        .code_font = fonts.code,
        .font_size = text_metrics.font_size,
        .line_height = text_metrics.line_height,
        .color = parseRecordColorProperty(state, node, "text", "color") orelse FALLBACK_TEXT_COLOR,
        .link_color = parseRecordColorProperty(state, node, "text", "link_color") orelse FALLBACK_LINK_COLOR,
        .markdown_bold_color = parseRecordColorProperty(state, node, "text", "markdown_bold_color"),
        .link_underline_width = nonNegativeRecordFloatProperty(state, node, "text", "link_underline_width") orelse 0,
        .link_underline_offset = recordFloatProperty(state, node, "text", "link_underline_offset") orelse 0,
        .inline_math_height_factor = positiveRecordFloatProperty(state, node, "text", "inline_math_height_factor") orelse 1,
        .inline_math_spacing = nonNegativeRecordFloatProperty(state, node, "text", "inline_math_spacing") orelse 0,
        .display_math_height_factor = positiveRecordFloatProperty(state, node, "text", "display_math_height_factor") orelse 2,
        .math_align = inheritedTextHorizontalAlign(state, node) orelse .center,
        .emoji_spacing = nonNegativeRecordFloatProperty(state, node, "text", "emoji_spacing") orelse 0,
        .markdown_block_gap = nonNegativeRecordFloatProperty(state, node, "text", "markdown_block_gap") orelse 0,
        .markdown_list_inset = nonNegativeRecordFloatProperty(state, node, "text", "markdown_list_inset") orelse 0,
        .markdown_list_indent = nonNegativeRecordFloatProperty(state, node, "text", "markdown_list_indent") orelse 0,
        .markdown_code_font_size = positiveRecordFloatProperty(state, node, "text", "markdown_code_font_size") orelse layout_style.font_size,
        .markdown_code_line_height = positiveRecordFloatProperty(state, node, "text", "markdown_code_line_height") orelse layout_style.line_height,
        .markdown_code_pad_x = nonNegativeRecordFloatProperty(state, node, "text", "markdown_code_pad_x") orelse 0,
        .markdown_code_pad_y = nonNegativeRecordFloatProperty(state, node, "text", "markdown_code_pad_y") orelse 0,
        .markdown_code_fill = themedRecordColorProperty(state, node, "text", "markdown_code_fill", "code_theme_fill"),
        .markdown_code_stroke = themedRecordColorProperty(state, node, "text", "markdown_code_stroke", "code_theme_stroke"),
        .markdown_code_line_width = nonNegativeRecordFloatProperty(state, node, "text", "markdown_code_line_width") orelse 0,
        .markdown_code_radius = nonNegativeRecordFloatProperty(state, node, "text", "markdown_code_radius") orelse 0,
        .markdown_code_plain_color = themedRecordColorProperty(state, node, "text", "markdown_code_plain_color", "code_theme_plain_color"),
        .markdown_code_keyword_color = themedRecordColorProperty(state, node, "text", "markdown_code_keyword_color", "code_theme_keyword_color"),
        .markdown_code_function_color = themedRecordColorProperty(state, node, "text", "markdown_code_function_color", "code_theme_function_color"),
        .markdown_code_type_color = themedRecordColorProperty(state, node, "text", "markdown_code_type_color", "code_theme_type_color"),
        .markdown_code_constant_color = themedRecordColorProperty(state, node, "text", "markdown_code_constant_color", "code_theme_constant_color"),
        .markdown_code_number_color = themedRecordColorProperty(state, node, "text", "markdown_code_number_color", "code_theme_number_color"),
        .markdown_code_variable_color = themedRecordColorProperty(state, node, "text", "markdown_code_variable_color", "code_theme_variable_color"),
        .markdown_code_operator_color = themedRecordColorProperty(state, node, "text", "markdown_code_operator_color", "code_theme_operator_color"),
        .markdown_code_comment_color = themedRecordColorProperty(state, node, "text", "markdown_code_comment_color", "code_theme_comment_color"),
        .markdown_code_string_color = themedRecordColorProperty(state, node, "text", "markdown_code_string_color", "code_theme_string_color"),
        .markdown_table_cell_pad_x = nonNegativeRecordFloatProperty(state, node, "text", "markdown_table_cell_pad_x") orelse @max(@as(f32, 6.0), layout_style.font_size * 0.55),
        .markdown_table_cell_pad_y = nonNegativeRecordFloatProperty(state, node, "text", "markdown_table_cell_pad_y") orelse @max(@as(f32, 4.0), layout_style.font_size * 0.32),
        .markdown_table_border = parseRecordColorProperty(state, node, "text", "markdown_table_border"),
        .markdown_table_line_width = nonNegativeRecordFloatProperty(state, node, "text", "markdown_table_line_width") orelse 0.8,
        .markdown_table_header_fill = parseRecordColorProperty(state, node, "text", "markdown_table_header_fill"),
        .markdown_table_alt_row_fill = parseRecordColorProperty(state, node, "text", "markdown_table_alt_row_fill"),
        .cjk_bold_passes = recordIntProperty(state, node, "text", "cjk_bold_passes") orelse 1,
        .cjk_bold_dx = recordFloatProperty(state, node, "text", "cjk_bold_dx") orelse 0,
        .wrap = layout.shouldWrapNode(state, node),
    };
}

fn resolveMath(state: anytype, node: *const Node, kind: RenderKind) ?MathPaint {
    if (kind != .vector_math) return null;
    return .{
        .min_height = positiveRecordFloatProperty(state, node, "math", "min_height") orelse 30,
        .raw_tex_width_ratio = inheritedMathRawTexWidthRatio(state, node) orelse 0.96,
        .scale = positiveRecordFloatProperty(state, node, "math", "scale") orelse 1,
        .horizontal_align = inheritedMathHorizontalAlign(state, node) orelse .center,
    };
}

fn resolveAsset(state: anytype, node: *const Node, kind: RenderKind) ?AssetPaint {
    return switch (kind) {
        .vector_asset, .raster_asset => .{
            .scale = positiveRecordFloatProperty(state, node, "asset", "scale") orelse 1,
            .pdf_page = resolvedPdfPage(state, node),
            .pdf_box = resolvedPdfPageBox(state, node),
        },
        else => null,
    };
}

fn resolvedPdfPage(state: anytype, node: *const Node) usize {
    const number = positiveRecordFloatProperty(state, node, "asset", "pdf_page") orelse 1;
    return @max(@as(usize, 1), @as(usize, @intFromFloat(@floor(number))));
}

fn resolvedPdfPageBox(state: anytype, node: *const Node) PdfPageBox {
    const name = fields.read(state.allocator, state, node, "asset", &.{"pdf_box"}, .text) orelse return .crop;
    return std.meta.stringToEnum(PdfPageBox, name) orelse .crop;
}

fn resolveCode(state: anytype, node: *const Node, kind: RenderKind) ?CodePaint {
    if (kind != .code) return null;
    const plain = themedRecordColorProperty(state, node, "code", "plain_color", "code_theme_plain_color") orelse parseRecordColorProperty(state, node, "text", "color") orelse FALLBACK_TEXT_COLOR;
    return .{
        .language = fields.read(state.allocator, state, node, "language", &.{}, .text),
        .plain = plain,
        .keyword = themedRecordColorProperty(state, node, "code", "keyword_color", "code_theme_keyword_color") orelse plain,
        .function = themedRecordColorProperty(state, node, "code", "function_color", "code_theme_function_color") orelse plain,
        .type = themedRecordColorProperty(state, node, "code", "type_color", "code_theme_type_color") orelse plain,
        .constant = themedRecordColorProperty(state, node, "code", "constant_color", "code_theme_constant_color") orelse plain,
        .number = themedRecordColorProperty(state, node, "code", "number_color", "code_theme_number_color") orelse plain,
        .variable = themedRecordColorProperty(state, node, "code", "variable_color", "code_theme_variable_color") orelse plain,
        .operator = themedRecordColorProperty(state, node, "code", "operator_color", "code_theme_operator_color") orelse plain,
        .comment = themedRecordColorProperty(state, node, "code", "comment_color", "code_theme_comment_color") orelse plain,
        .string = themedRecordColorProperty(state, node, "code", "string_color", "code_theme_string_color") orelse plain,
    };
}

fn resolveShape(state: anytype, node: *const Node, kind: RenderKind) ?ShapePaint {
    if (kind != .shape) return null;
    return .{
        .stroke = parseRecordColorProperty(state, node, "shape", "stroke"),
        .line_width = nonNegativeRecordFloatProperty(state, node, "shape", "line_width") orelse 0,
        .dash = parseRecordDashProperty(state, node, "shape", "dash"),
        .start_x = recordFloatProperty(state, node, "shape", "start_x") orelse 0,
        .start_y = recordFloatProperty(state, node, "shape", "start_y") orelse 0,
        .end_x = recordFloatProperty(state, node, "shape", "end_x") orelse 1,
        .end_y = recordFloatProperty(state, node, "shape", "end_y") orelse 1,
        .marker_start = parseRecordShapeMarkerProperty(state, node, "shape", "marker_start") orelse .plain,
        .marker_end = parseRecordShapeMarkerProperty(state, node, "shape", "marker_end") orelse .plain,
        .marker_size = nonNegativeRecordFloatProperty(state, node, "shape", "marker_size") orelse 0,
    };
}

fn resolveChrome(state: anytype, node: *const Node) ChromePaint {
    return .{
        .fill = parseRecordColorProperty(state, node, "chrome", "fill"),
        .stroke = parseRecordColorProperty(state, node, "chrome", "stroke"),
        .line_width = nonNegativeRecordFloatProperty(state, node, "chrome", "line_width") orelse 0,
        .radius = nonNegativeRecordFloatProperty(state, node, "chrome", "radius") orelse 0,
        .pad_x = nonNegativeRecordFloatProperty(state, node, "chrome", "pad_x") orelse 0,
        .pad_y = nonNegativeRecordFloatProperty(state, node, "chrome", "pad_y") orelse 0,
    };
}

fn resolveUnderline(state: anytype, node: *const Node) UnderlinePaint {
    return .{
        .color = parseRecordColorProperty(state, node, "underline", "color"),
        .width = nonNegativeRecordFloatProperty(state, node, "underline", "width") orelse 0,
        .offset = recordFloatProperty(state, node, "underline", "offset") orelse 0,
    };
}

fn resolveRule(state: anytype, node: *const Node) RulePaint {
    return .{
        .stroke = parseRecordColorProperty(state, node, "rule", "stroke"),
        .line_width = nonNegativeRecordFloatProperty(state, node, "rule", "line_width") orelse 0,
        .dash = parseRecordDashProperty(state, node, "rule", "dash"),
    };
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

fn recordIntProperty(state: anytype, node: *const Node, record_key: []const u8, field_name: []const u8) ?u32 {
    const value = recordFloatProperty(state, node, record_key, field_name) orelse return null;
    if (!std.math.isFinite(value) or value < 0) return null;
    return @intFromFloat(@round(value));
}

fn parseRecordColorProperty(state: anytype, node: *const Node, record_key: []const u8, field_name: []const u8) ?Color {
    const value = fields.read(state.allocator, state, node, record_key, &.{field_name}, .text) orelse return null;
    return parseColor(value);
}

fn parseRecordDashProperty(state: anytype, node: *const Node, record_key: []const u8, field_name: []const u8) ?Dash {
    const value = fields.read(state.allocator, state, node, record_key, &.{field_name}, .text) orelse return null;
    return parseDash(value);
}

fn parseRecordShapeMarkerProperty(state: anytype, node: *const Node, record_key: []const u8, field_name: []const u8) ?ShapeMarker {
    const value = fields.read(state.allocator, state, node, record_key, &.{field_name}, .text) orelse return null;
    return parseShapeMarker(value);
}

fn inheritedTextHorizontalAlign(state: anytype, node: *const Node) ?HorizontalAlign {
    if (explicitRecordHorizontalAlign(node, "text", "math_align")) |value| return value;
    if (inheritedHorizontalAlignProperty(state, node, "math_align")) |value| return value;
    const value = fields.read(state.allocator, state, node, "text", &.{"math_align"}, .text) orelse return null;
    return parseHorizontalAlign(value);
}

fn inheritedMathHorizontalAlign(state: anytype, node: *const Node) ?HorizontalAlign {
    if (explicitRecordHorizontalAlign(node, "math", "align")) |value| return value;
    if (inheritedHorizontalAlignProperty(state, node, "math_align")) |value| return value;
    const value = fields.read(state.allocator, state, node, "math", &.{"align"}, .text) orelse return null;
    return parseHorizontalAlign(value);
}

fn inheritedMathRawTexWidthRatio(state: anytype, node: *const Node) ?f32 {
    if (explicitPositiveRecordFloatProperty(node, "math", "raw_tex_width_ratio")) |value| return value;
    return inheritedPositiveFloatProperty(state, node, "raw_tex_width_ratio");
}

fn explicitPositiveRecordFloatProperty(node: *const Node, record_key: []const u8, field_name: []const u8) ?f32 {
    const value = explicitRecordFloatProperty(node, record_key, field_name) orelse return null;
    return if (value > 0) value else null;
}

fn explicitRecordFloatProperty(node: *const Node, record_key: []const u8, field_name: []const u8) ?f32 {
    const record_value = model.nodeField(node, record_key) orelse return null;
    if (record_value != .record) return null;
    for (record_value.record.fields.items) |field| {
        if (!field.explicit or !std.mem.eql(u8, field.name, field_name)) continue;
        return switch (field.value) {
            .number => |value| @floatCast(value),
            else => null,
        };
    }
    return null;
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

fn themedRecordColorProperty(state: anytype, node: *const Node, record_key: []const u8, field_name: []const u8, theme_key: []const u8) ?Color {
    if (explicitRecordColorProperty(node, record_key, field_name)) |color| return color;
    if (node.kind == .object) {
        if (state.parentPageOf(node.id)) |page_id| {
            if (state.getNode(page_id)) |page| {
                if (explicitColorProperty(page, theme_key)) |color| return color;
            }
        }
    }
    if (node.kind == .object or node.kind == .page) {
        if (state.getNode(state.document_id)) |document| {
            if (explicitColorProperty(document, theme_key)) |color| return color;
        }
    }
    return parseRecordColorProperty(state, node, record_key, field_name);
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

fn parseRenderKindProperty(state: anytype, node: *const Node) ?RenderKind {
    const value = fields.read(state.allocator, state, node, "render_kind", &.{}, .text) orelse return null;
    return parseRenderKind(value);
}

fn parseRenderKind(value: []const u8) ?RenderKind {
    return std.meta.stringToEnum(RenderKind, value);
}

fn parseShapeMarkerProperty(state: anytype, node: *const Node, key: []const u8) ?ShapeMarker {
    const value = fields.read(state.allocator, state, node, key, &.{}, .text) orelse return null;
    return parseShapeMarker(value);
}

fn parseShapeMarker(value: []const u8) ?ShapeMarker {
    return std.meta.stringToEnum(ShapeMarker, value);
}

fn parseHorizontalAlignProperty(state: anytype, node: *const Node, key: []const u8) ?HorizontalAlign {
    const value = fields.read(state.allocator, state, node, key, &.{}, .text) orelse return null;
    return parseHorizontalAlign(value);
}

fn inheritedHorizontalAlignProperty(state: anytype, node: *const Node, key: []const u8) ?HorizontalAlign {
    if (explicitHorizontalAlignProperty(node, key)) |value| return value;
    if (node.kind == .object) {
        if (state.parentPageOf(node.id)) |page_id| {
            if (state.getNode(page_id)) |page| {
                if (explicitHorizontalAlignProperty(page, key)) |value| return value;
            }
        }
    }
    if (node.kind == .object or node.kind == .page) {
        if (state.getNode(state.document_id)) |document| {
            if (explicitHorizontalAlignProperty(document, key)) |value| return value;
        }
    }
    return parseHorizontalAlignProperty(state, node, key);
}

fn inheritedPositiveFloatProperty(state: anytype, node: *const Node, key: []const u8) ?f32 {
    if (explicitPositiveFloatProperty(node, key)) |value| return value;
    if (node.kind == .object) {
        if (state.parentPageOf(node.id)) |page_id| {
            if (state.getNode(page_id)) |page| {
                if (explicitPositiveFloatProperty(page, key)) |value| return value;
            }
        }
    }
    if (node.kind == .object or node.kind == .page) {
        if (state.getNode(state.document_id)) |document| {
            if (explicitPositiveFloatProperty(document, key)) |value| return value;
        }
    }
    return positiveFloatProperty(state, node, key);
}

fn explicitPositiveFloatProperty(node: *const Node, key: []const u8) ?f32 {
    const value = model.nodeField(node, key) orelse return null;
    return switch (value) {
        .number => |number| if (number > 0) @floatCast(number) else null,
        else => null,
    };
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

fn parseFloatProperty(state: anytype, node: *const Node, key: []const u8) ?f32 {
    return fields.read(state.allocator, state, node, key, &.{}, .number);
}

fn positiveFloatProperty(state: anytype, node: *const Node, key: []const u8) ?f32 {
    const value = parseFloatProperty(state, node, key) orelse return null;
    return if (value > 0) value else null;
}

fn nonNegativeFloatProperty(state: anytype, node: *const Node, key: []const u8) ?f32 {
    const value = parseFloatProperty(state, node, key) orelse return null;
    return if (value >= 0) value else null;
}

fn parseIntProperty(state: anytype, node: *const Node, key: []const u8) ?u32 {
    const raw = fields.read(state.allocator, state, node, key, &.{}, .number) orelse return null;
    if (!std.math.isFinite(raw) or raw < 0) return null;
    return @intFromFloat(@round(raw));
}

fn parseColorProperty(state: anytype, node: *const Node, key: []const u8) ?Color {
    const value = fields.read(state.allocator, state, node, key, &.{}, .text) orelse return null;
    return parseColor(value);
}

fn themedColorProperty(state: anytype, node: *const Node, key: []const u8, theme_key: []const u8) ?Color {
    if (explicitColorProperty(node, key)) |color| return color;
    if (node.kind == .object) {
        if (state.parentPageOf(node.id)) |page_id| {
            if (state.getNode(page_id)) |page| {
                if (explicitColorProperty(page, theme_key)) |color| return color;
            }
        }
    }
    if (node.kind == .object or node.kind == .page) {
        if (state.getNode(state.document_id)) |document| {
            if (explicitColorProperty(document, theme_key)) |color| return color;
        }
    }
    return parseColorProperty(state, node, key);
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

fn parseDashProperty(state: anytype, node: *const Node, key: []const u8) ?Dash {
    const value = fields.read(state.allocator, state, node, key, &.{}, .text) orelse return null;
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
