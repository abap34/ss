const std = @import("std");
const model = @import("model");
const color_utils = @import("utils").color;
const fields = @import("fields.zig");
const font_model = @import("font.zig");

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
    vector_path,
    connector,
    chrome_only,
};

pub const LineCap = enum { butt, round, square };
pub const LineJoin = enum { miter, round, bevel };
pub const FillRule = enum { nonzero, even_odd };
pub const PaintSpace = enum { local, page };
pub const GradientSpread = enum { pad, repeat, reflect };
pub const VectorFillKind = enum { none, solid, linear, radial };
pub const ConnectorAnchor = enum { center, left, right, top, bottom };
pub const ConnectorRoute = enum { straight, horizontal_then_vertical, vertical_then_horizontal, curve };

pub const DashPattern = struct {
    values: [8]f32 = @splat(0),
    count: u8 = 0,
    offset: f32 = 0,

    pub fn slice(self: *const DashPattern) []const f32 {
        return self.values[0..self.count];
    }
};

pub const VectorStrokePaint = struct {
    color: Color,
    width: f32,
    cap: LineCap,
    join: LineJoin,
    miter_limit: f32,
    dash: DashPattern,
};

pub const PatternPaint = struct {
    path: model.Path,
    cell_width: f32,
    cell_height: f32,
    xx: f32,
    yx: f32,
    xy: f32,
    yy: f32,
    x0: f32,
    y0: f32,
    space: PaintSpace,
    fill: ?Color,
    stroke: ?VectorStrokePaint,
};

pub const VectorFillPaint = struct {
    kind: VectorFillKind,
    color: ?Color,
    color2: ?Color,
    start_x: f32,
    start_y: f32,
    start_radius: f32,
    end_x: f32,
    end_y: f32,
    end_radius: f32,
    spread: GradientSpread,
    space: PaintSpace,
    rule: FillRule,
    opacity: f32,
    pattern: ?PatternPaint,
};

pub const MarkerPaint = struct {
    path: model.Path,
    width: f32,
    height: f32,
    fill: VectorFillPaint,
    stroke: ?VectorStrokePaint,
};

pub const VectorPathPaint = struct {
    path: model.Path,
    fill: VectorFillPaint,
    stroke: ?VectorStrokePaint,
};

pub const ConnectorPaint = struct {
    source: model.NodeId,
    target: model.NodeId,
    source_anchor: ConnectorAnchor,
    target_anchor: ConnectorAnchor,
    route: ConnectorRoute,
    curve: f32,
    stroke: VectorStrokePaint,
    marker_start: ?MarkerPaint,
    marker_end: ?MarkerPaint,
};

pub const HorizontalAlign = enum {
    left,
    center,
    right,
};

pub const FontFace = font_model.Face;

pub const TextMetrics = struct {
    font_size: f32,
    line_height: f32,
};

pub const MarkdownUnderlinePaint = struct {
    color: ?Color = null,
    opacity: f32 = 1,
    width: ?f32 = null,
    offset: f32 = 0,
    dash: ?Dash = null,
};

pub const MarkdownQuotePaint = struct {
    color: ?Color = null,
    inset: f32 = 0,
    pad_x: f32 = 0,
    pad_y: f32 = 0,
    fill: ?Color = null,
    radius: f32 = 0,
    bar_color: ?Color = null,
    bar_width: f32 = 0,
    bar_dash: ?Dash = null,
};

pub const MarkdownHeadingPaint = struct {
    font: FontFace,
    bold_font: FontFace,
    italic_font: FontFace,
    code_font: FontFace,
    font_size: f32,
    line_height: f32,
    color: Color,
    link_color: Color,
    markdown_bold_color: ?Color,
    markdown_underline: MarkdownUnderlinePaint,
    inline_math_height_factor: f32,
    inline_math_spacing: f32,
    display_math_height_factor: f32,
    math_align: HorizontalAlign,
    emoji_spacing: f32,
};

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
    markdown_underline: MarkdownUnderlinePaint,
    markdown_quote: MarkdownQuotePaint,
    markdown_headings: [6]?MarkdownHeadingPaint,
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
    wrap: bool,

    pub fn forMarkdownHeading(self: TextPaint, level: u8) TextPaint {
        if (level < 1 or level > self.markdown_headings.len) return self;
        const heading = self.markdown_headings[level - 1] orelse return self;
        var result = self;
        result.font = heading.font;
        result.bold_font = heading.bold_font;
        result.italic_font = heading.italic_font;
        result.code_font = heading.code_font;
        result.font_size = heading.font_size;
        result.line_height = heading.line_height;
        result.color = heading.color;
        result.link_color = heading.link_color;
        result.markdown_bold_color = heading.markdown_bold_color;
        result.markdown_underline = heading.markdown_underline;
        result.inline_math_height_factor = heading.inline_math_height_factor;
        result.inline_math_spacing = heading.inline_math_spacing;
        result.display_math_height_factor = heading.display_math_height_factor;
        result.math_align = heading.math_align;
        result.emoji_spacing = heading.emoji_spacing;
        return result;
    }
};

pub const MathPaint = struct {
    min_height: f32,
    raw_tex_width_ratio: f32,
    scale: f32,
    horizontal_align: HorizontalAlign,
    color: Color,
};

pub const AssetPaint = struct {
    scale: f32,
    tint: ?Color,
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

pub const ResolvedRender = struct {
    kind: RenderKind,
    text: ?TextPaint,
    math: ?MathPaint,
    asset: ?AssetPaint,
    code: ?CodePaint,
    vector_path: ?VectorPathPaint,
    connector: ?ConnectorPaint,
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
        .vector_path = resolveVectorPath(node, kind),
        .connector = resolveConnector(node, kind),
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

pub fn resolveTextForNode(state: anytype, node: *const Node) ?TextPaint {
    return resolveText(state, node, resolveKind(state, node));
}

pub fn resolveTextMetrics(state: anytype, node: *const Node) TextMetrics {
    const text_font_size = positiveRecordFloatProperty(state, node, "text", "size") orelse 20;
    const font_size = positiveRecordFloatProperty(state, node, "layout", "font_size") orelse text_font_size;
    const text_line_height = positiveRecordFloatProperty(state, node, "text", "line_height") orelse font_size * 1.45;
    return .{
        .font_size = font_size,
        .line_height = positiveRecordFloatProperty(state, node, "layout", "line_height") orelse text_line_height,
    };
}

pub fn shouldWrapText(state: anytype, node: *const Node) bool {
    if (positiveFloatProperty(state, node, "asset_width") != null) return false;
    if (fields.read(state.allocator, state, node, "layout", &.{"wrap"}, .text)) |wrap_mode| {
        if (std.mem.eql(u8, wrap_mode, "on")) return true;
        if (std.mem.eql(u8, wrap_mode, "off")) return false;
    }
    return recordFloatProperty(state, node, "layout", "right_inset") != null;
}

fn resolveText(state: anytype, node: *const Node, kind: RenderKind) ?TextPaint {
    switch (kind) {
        .text, .code => {},
        else => return null,
    }

    const text_metrics = resolveTextMetrics(state, node);
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
        .markdown_underline = resolveMarkdownUnderline(state, node),
        .markdown_quote = resolveMarkdownQuote(state, node),
        .markdown_headings = .{
            resolveMarkdownHeading(node, "h1"),
            resolveMarkdownHeading(node, "h2"),
            resolveMarkdownHeading(node, "h3"),
            resolveMarkdownHeading(node, "h4"),
            resolveMarkdownHeading(node, "h5"),
            resolveMarkdownHeading(node, "h6"),
        },
        .inline_math_height_factor = positiveRecordFloatProperty(state, node, "text", "inline_math_height_factor") orelse 1,
        .inline_math_spacing = nonNegativeRecordFloatProperty(state, node, "text", "inline_math_spacing") orelse 0,
        .display_math_height_factor = positiveRecordFloatProperty(state, node, "text", "display_math_height_factor") orelse 2,
        .math_align = inheritedTextHorizontalAlign(state, node) orelse .center,
        .emoji_spacing = nonNegativeRecordFloatProperty(state, node, "text", "emoji_spacing") orelse 0,
        .markdown_block_gap = nonNegativeRecordFloatProperty(state, node, "text", "markdown_block_gap") orelse 0,
        .markdown_list_inset = nonNegativeRecordFloatProperty(state, node, "text", "markdown_list_inset") orelse 0,
        .markdown_list_indent = nonNegativeRecordFloatProperty(state, node, "text", "markdown_list_indent") orelse 0,
        .markdown_code_font_size = positiveRecordFloatProperty(state, node, "text", "markdown_code_font_size") orelse text_metrics.font_size,
        .markdown_code_line_height = positiveRecordFloatProperty(state, node, "text", "markdown_code_line_height") orelse text_metrics.line_height,
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
        .markdown_table_cell_pad_x = nonNegativeRecordFloatProperty(state, node, "text", "markdown_table_cell_pad_x") orelse @max(@as(f32, 6.0), text_metrics.font_size * 0.55),
        .markdown_table_cell_pad_y = nonNegativeRecordFloatProperty(state, node, "text", "markdown_table_cell_pad_y") orelse @max(@as(f32, 4.0), text_metrics.font_size * 0.32),
        .markdown_table_border = parseRecordColorProperty(state, node, "text", "markdown_table_border"),
        .markdown_table_line_width = nonNegativeRecordFloatProperty(state, node, "text", "markdown_table_line_width") orelse 0.8,
        .markdown_table_header_fill = parseRecordColorProperty(state, node, "text", "markdown_table_header_fill"),
        .markdown_table_alt_row_fill = parseRecordColorProperty(state, node, "text", "markdown_table_alt_row_fill"),
        .wrap = shouldWrapText(state, node),
    };
}

fn resolveMarkdownHeading(node: *const Node, field_name: []const u8) ?MarkdownHeadingPaint {
    const font_size = positiveMarkdownHeadingTextFloatProperty(node, field_name, "size") orelse return null;
    const fonts = font_model.markdownHeadingTextFacesForNode(node, field_name) orelse return null;
    return .{
        .font = fonts.normal,
        .bold_font = fonts.bold,
        .italic_font = fonts.italic,
        .code_font = fonts.code,
        .font_size = font_size,
        .line_height = positiveMarkdownHeadingTextFloatProperty(node, field_name, "line_height") orelse font_size * 1.45,
        .color = parseMarkdownHeadingTextColor(node, field_name, "color") orelse FALLBACK_TEXT_COLOR,
        .link_color = parseMarkdownHeadingTextColor(node, field_name, "link_color") orelse FALLBACK_LINK_COLOR,
        .markdown_bold_color = parseMarkdownHeadingTextColor(node, field_name, "markdown_bold_color"),
        .markdown_underline = resolveMarkdownHeadingUnderline(node, field_name),
        .inline_math_height_factor = positiveMarkdownHeadingTextFloatProperty(node, field_name, "inline_math_height_factor") orelse 1,
        .inline_math_spacing = nonNegativeMarkdownHeadingTextFloatProperty(node, field_name, "inline_math_spacing") orelse 0,
        .display_math_height_factor = positiveMarkdownHeadingTextFloatProperty(node, field_name, "display_math_height_factor") orelse 2,
        .math_align = parseMarkdownHeadingHorizontalAlign(node, field_name) orelse .center,
        .emoji_spacing = nonNegativeMarkdownHeadingTextFloatProperty(node, field_name, "emoji_spacing") orelse 0,
    };
}

fn resolveMarkdownUnderline(state: anytype, node: *const Node) MarkdownUnderlinePaint {
    const opacity = markdownUnderlineFloatProperty(state, node, "opacity") orelse 1;
    return .{
        .color = parseMarkdownUnderlineColor(state, node),
        .opacity = normalizedOpacity(opacity),
        .width = nonNegativeMarkdownUnderlineFloatProperty(state, node, "width"),
        .offset = markdownUnderlineFloatProperty(state, node, "offset") orelse 0,
        .dash = parseMarkdownUnderlineDash(state, node),
    };
}

fn resolveMarkdownQuote(state: anytype, node: *const Node) MarkdownQuotePaint {
    return .{
        .color = parseMarkdownQuoteColor(state, node, "color"),
        .inset = nonNegativeMarkdownQuoteFloatProperty(state, node, "inset") orelse 0,
        .pad_x = nonNegativeMarkdownQuoteFloatProperty(state, node, "pad_x") orelse 0,
        .pad_y = nonNegativeMarkdownQuoteFloatProperty(state, node, "pad_y") orelse 0,
        .fill = parseMarkdownQuoteColor(state, node, "fill"),
        .radius = nonNegativeMarkdownQuoteFloatProperty(state, node, "radius") orelse 0,
        .bar_color = parseMarkdownQuoteColor(state, node, "bar_color"),
        .bar_width = nonNegativeMarkdownQuoteFloatProperty(state, node, "bar_width") orelse 0,
        .bar_dash = parseMarkdownQuoteDash(state, node),
    };
}

fn resolveMarkdownHeadingUnderline(node: *const Node, heading_field: []const u8) MarkdownUnderlinePaint {
    const opacity = markdownHeadingUnderlineFloatProperty(node, heading_field, "opacity") orelse 1;
    return .{
        .color = parseMarkdownHeadingUnderlineColor(node, heading_field),
        .opacity = normalizedOpacity(opacity),
        .width = nonNegativeMarkdownHeadingUnderlineFloatProperty(node, heading_field, "width"),
        .offset = markdownHeadingUnderlineFloatProperty(node, heading_field, "offset") orelse 0,
        .dash = parseMarkdownHeadingUnderlineDash(node, heading_field),
    };
}

fn resolveMath(state: anytype, node: *const Node, kind: RenderKind) ?MathPaint {
    if (kind != .vector_math) return null;
    return .{
        .min_height = positiveRecordFloatProperty(state, node, "math", "min_height") orelse 30,
        .raw_tex_width_ratio = inheritedMathRawTexWidthRatio(state, node) orelse 0.96,
        .scale = positiveRecordFloatProperty(state, node, "math", "scale") orelse 1,
        .horizontal_align = inheritedMathHorizontalAlign(state, node) orelse .center,
        .color = parseRecordColorProperty(state, node, "math", "color") orelse FALLBACK_TEXT_COLOR,
    };
}

fn resolveAsset(state: anytype, node: *const Node, kind: RenderKind) ?AssetPaint {
    return switch (kind) {
        .vector_asset, .raster_asset => .{
            .scale = positiveRecordFloatProperty(state, node, "asset", "scale") orelse 1,
            .tint = parseRecordColorProperty(state, node, "asset", "tint"),
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

fn resolveVectorPath(node: *const Node, kind: RenderKind) ?VectorPathPaint {
    if (kind != .vector_path) return null;
    const path_value = model.nodeField(node, "path") orelse return null;
    const path = switch (path_value) {
        .path => |value| value,
        else => return null,
    };
    const fill = if (model.nodeField(node, "fill")) |fill_value| switch (fill_value) {
        .record => |record| vectorFillFromRecord(record),
        else => defaultVectorFill(),
    } else defaultVectorFill();
    const stroke = resolveVectorStroke(node, "stroke");
    return .{ .path = path, .fill = fill, .stroke = stroke };
}

fn resolveConnector(node: *const Node, kind: RenderKind) ?ConnectorPaint {
    if (kind != .connector) return null;
    const value = model.nodeField(node, "connector") orelse return null;
    const record = switch (value) {
        .record => |record| record,
        else => return null,
    };
    const source = recordObject(record, "source") orelse return null;
    const target = recordObject(record, "target") orelse return null;
    const stroke_value = record.field("stroke") orelse return null;
    const stroke_record = switch (stroke_value) {
        .record => |stroke_record| stroke_record,
        else => return null,
    };
    const stroke = vectorStrokeFromRecord(stroke_record) orelse return null;
    return .{
        .source = source,
        .target = target,
        .source_anchor = parseEnum(ConnectorAnchor, recordText(record, "source_anchor")) orelse .right,
        .target_anchor = parseEnum(ConnectorAnchor, recordText(record, "target_anchor")) orelse .left,
        .route = parseEnum(ConnectorRoute, recordText(record, "route")) orelse .straight,
        .curve = recordNumber(record, "curve") orelse 0.5,
        .stroke = stroke,
        .marker_start = markerFromRecord(record, "marker_start"),
        .marker_end = markerFromRecord(record, "marker_end"),
    };
}

fn resolveVectorStroke(node: *const Node, key: []const u8) ?VectorStrokePaint {
    const value = model.nodeField(node, key) orelse return null;
    return switch (value) {
        .record => |record| vectorStrokeFromRecord(record),
        else => null,
    };
}

fn defaultVectorFill() VectorFillPaint {
    return .{
        .kind = .none,
        .color = null,
        .color2 = null,
        .start_x = 0,
        .start_y = 0,
        .start_radius = 0,
        .end_x = 1,
        .end_y = 1,
        .end_radius = 1,
        .spread = .pad,
        .space = .local,
        .rule = .nonzero,
        .opacity = 1,
        .pattern = null,
    };
}

fn vectorFillFromRecord(record: model.RecordValue) VectorFillPaint {
    return .{
        .kind = parseEnum(VectorFillKind, recordText(record, "kind")) orelse .none,
        .color = recordColor(record, "color"),
        .color2 = recordColor(record, "color2"),
        .start_x = recordNumber(record, "start_x") orelse 0,
        .start_y = recordNumber(record, "start_y") orelse 0,
        .start_radius = recordNumber(record, "start_radius") orelse 0,
        .end_x = recordNumber(record, "end_x") orelse 1,
        .end_y = recordNumber(record, "end_y") orelse 1,
        .end_radius = recordNumber(record, "end_radius") orelse 1,
        .spread = parseEnum(GradientSpread, recordText(record, "spread")) orelse .pad,
        .space = parseEnum(PaintSpace, recordText(record, "space")) orelse .local,
        .rule = parseEnum(FillRule, recordText(record, "rule")) orelse .nonzero,
        .opacity = recordNumber(record, "opacity") orelse 1,
        .pattern = resolvePattern(record),
    };
}

fn markerFromRecord(record: model.RecordValue, field_name: []const u8) ?MarkerPaint {
    const value = record.field(field_name) orelse return null;
    const marker = switch (value) {
        .record => |marker| marker,
        else => return null,
    };
    const path_value = marker.field("path") orelse return null;
    const path = switch (path_value) {
        .path => |path| path,
        else => return null,
    };
    const fill = if (marker.field("fill")) |fill_value| switch (fill_value) {
        .record => |fill_record| vectorFillFromRecord(fill_record),
        else => defaultVectorFill(),
    } else defaultVectorFill();
    const stroke = if (marker.field("stroke")) |stroke_value| switch (stroke_value) {
        .record => |stroke_record| vectorStrokeFromRecord(stroke_record),
        else => null,
    } else null;
    return .{
        .path = path,
        .width = recordNumber(marker, "width") orelse 10,
        .height = recordNumber(marker, "height") orelse 10,
        .fill = fill,
        .stroke = stroke,
    };
}

fn resolvePattern(fill_record: model.RecordValue) ?PatternPaint {
    const pattern_value = fill_record.field("pattern") orelse return null;
    const pattern = switch (pattern_value) {
        .record => |record| record,
        else => return null,
    };
    const path_value = pattern.field("path") orelse return null;
    const path = switch (path_value) {
        .path => |value| value,
        else => return null,
    };
    const fill = recordColor(pattern, "fill");
    const stroke = if (pattern.field("stroke")) |value| switch (value) {
        .record => |record| vectorStrokeFromRecord(record),
        else => null,
    } else null;
    if (fill == null and stroke == null) return null;
    const rotation = (recordNumber(pattern, "rotation") orelse 0) * std.math.pi / 180;
    const cosine = @cos(rotation);
    const sine = @sin(rotation);
    const xx = recordNumber(pattern, "xx") orelse 1;
    const yx = recordNumber(pattern, "yx") orelse 0;
    const xy = recordNumber(pattern, "xy") orelse 0;
    const yy = recordNumber(pattern, "yy") orelse 1;
    return .{
        .path = path,
        .cell_width = recordNumber(pattern, "cell_width") orelse 8,
        .cell_height = recordNumber(pattern, "cell_height") orelse 8,
        .xx = cosine * xx - sine * yx,
        .yx = sine * xx + cosine * yx,
        .xy = cosine * xy - sine * yy,
        .yy = sine * xy + cosine * yy,
        .x0 = recordNumber(pattern, "x0") orelse 0,
        .y0 = recordNumber(pattern, "y0") orelse 0,
        .space = parseEnum(PaintSpace, recordText(pattern, "space")) orelse .local,
        .fill = fill,
        .stroke = stroke,
    };
}

fn vectorStrokeFromRecord(record: model.RecordValue) ?VectorStrokePaint {
    const color = recordColor(record, "color") orelse return null;
    var dash = parseDashPattern(recordText(record, "dash") orelse "");
    dash.offset = recordNumber(record, "dash_offset") orelse 0;
    return .{
        .color = color,
        .width = recordNumber(record, "width") orelse 1,
        .cap = parseEnum(LineCap, recordText(record, "cap")) orelse .butt,
        .join = parseEnum(LineJoin, recordText(record, "join")) orelse .miter,
        .miter_limit = recordNumber(record, "miter_limit") orelse 10,
        .dash = dash,
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

fn markdownHeadingTextFloatProperty(node: *const Node, heading_field: []const u8, field_name: []const u8) ?f32 {
    return fields.readExplicit(node, "markdown_headings", &.{ heading_field, "text", field_name }, .number);
}

fn positiveMarkdownHeadingTextFloatProperty(node: *const Node, heading_field: []const u8, field_name: []const u8) ?f32 {
    const value = markdownHeadingTextFloatProperty(node, heading_field, field_name) orelse return null;
    return if (value > 0) value else null;
}

fn nonNegativeMarkdownHeadingTextFloatProperty(node: *const Node, heading_field: []const u8, field_name: []const u8) ?f32 {
    const value = markdownHeadingTextFloatProperty(node, heading_field, field_name) orelse return null;
    return if (value >= 0) value else null;
}

fn markdownUnderlineFloatProperty(state: anytype, node: *const Node, field_name: []const u8) ?f32 {
    return fields.read(state.allocator, state, node, "text", &.{ "markdown_underline", field_name }, .number);
}

fn markdownQuoteFloatProperty(state: anytype, node: *const Node, field_name: []const u8) ?f32 {
    return fields.read(state.allocator, state, node, "text", &.{ "markdown_quote", field_name }, .number);
}

fn nonNegativeMarkdownQuoteFloatProperty(state: anytype, node: *const Node, field_name: []const u8) ?f32 {
    const value = markdownQuoteFloatProperty(state, node, field_name) orelse return null;
    return if (value >= 0) value else null;
}

fn parseMarkdownQuoteColor(state: anytype, node: *const Node, field_name: []const u8) ?Color {
    const value = fields.read(state.allocator, state, node, "text", &.{ "markdown_quote", field_name }, .text) orelse return null;
    return parseColor(value);
}

fn parseMarkdownQuoteDash(state: anytype, node: *const Node) ?Dash {
    const value = fields.read(state.allocator, state, node, "text", &.{ "markdown_quote", "bar_dash" }, .text) orelse return null;
    return parseDash(value);
}

fn nonNegativeMarkdownUnderlineFloatProperty(state: anytype, node: *const Node, field_name: []const u8) ?f32 {
    const value = markdownUnderlineFloatProperty(state, node, field_name) orelse return null;
    return if (value >= 0) value else null;
}

fn parseMarkdownUnderlineColor(state: anytype, node: *const Node) ?Color {
    const value = fields.read(state.allocator, state, node, "text", &.{ "markdown_underline", "color" }, .text) orelse return null;
    return parseColor(value);
}

fn parseMarkdownUnderlineDash(state: anytype, node: *const Node) ?Dash {
    const value = fields.read(state.allocator, state, node, "text", &.{ "markdown_underline", "dash" }, .text) orelse return null;
    return parseDash(value);
}

fn markdownHeadingUnderlineFloatProperty(node: *const Node, heading_field: []const u8, field_name: []const u8) ?f32 {
    return fields.readExplicit(node, "markdown_headings", &.{ heading_field, "text", "markdown_underline", field_name }, .number);
}

fn nonNegativeMarkdownHeadingUnderlineFloatProperty(node: *const Node, heading_field: []const u8, field_name: []const u8) ?f32 {
    const value = markdownHeadingUnderlineFloatProperty(node, heading_field, field_name) orelse return null;
    return if (value >= 0) value else null;
}

fn parseMarkdownHeadingUnderlineColor(node: *const Node, heading_field: []const u8) ?Color {
    const value = fields.readExplicit(node, "markdown_headings", &.{ heading_field, "text", "markdown_underline", "color" }, .text) orelse return null;
    return parseColor(value);
}

fn parseMarkdownHeadingUnderlineDash(node: *const Node, heading_field: []const u8) ?Dash {
    const value = fields.readExplicit(node, "markdown_headings", &.{ heading_field, "text", "markdown_underline", "dash" }, .text) orelse return null;
    return parseDash(value);
}

fn normalizedOpacity(value: f32) f32 {
    if (!std.math.isFinite(value)) return 1;
    return std.math.clamp(value, 0, 1);
}

fn parseRecordColorProperty(state: anytype, node: *const Node, record_key: []const u8, field_name: []const u8) ?Color {
    const value = fields.read(state.allocator, state, node, record_key, &.{field_name}, .text) orelse return null;
    return parseColor(value);
}

fn parseMarkdownHeadingTextColor(node: *const Node, heading_field: []const u8, field_name: []const u8) ?Color {
    const value = fields.readExplicit(node, "markdown_headings", &.{ heading_field, "text", field_name }, .text) orelse return null;
    return parseColor(value);
}

fn parseMarkdownHeadingHorizontalAlign(node: *const Node, heading_field: []const u8) ?HorizontalAlign {
    const value = fields.readExplicit(node, "markdown_headings", &.{ heading_field, "text", "math_align" }, .text) orelse return null;
    return parseHorizontalAlign(value);
}

fn parseRecordDashProperty(state: anytype, node: *const Node, record_key: []const u8, field_name: []const u8) ?Dash {
    const value = fields.read(state.allocator, state, node, record_key, &.{field_name}, .text) orelse return null;
    return parseDash(value);
}

fn parseEnum(comptime T: type, maybe_value: ?[]const u8) ?T {
    const value = maybe_value orelse return null;
    return std.meta.stringToEnum(T, value);
}

fn recordNumber(record: model.RecordValue, field_name: []const u8) ?f32 {
    const value = record.field(field_name) orelse return null;
    return switch (value) {
        .number => |number| if (std.math.isFinite(number)) number else null,
        else => null,
    };
}

fn recordText(record: model.RecordValue, field_name: []const u8) ?[]const u8 {
    const value = record.field(field_name) orelse return null;
    return switch (value) {
        .string => |text| text,
        .enum_case => |case| case.case_name,
        else => null,
    };
}

fn recordColor(record: model.RecordValue, field_name: []const u8) ?Color {
    return parseColor(recordText(record, field_name) orelse return null);
}

fn recordObject(record: model.RecordValue, field_name: []const u8) ?model.NodeId {
    const value = record.field(field_name) orelse return null;
    return switch (value) {
        .object => |node_id| node_id,
        else => null,
    };
}

fn parseDashPattern(value: []const u8) DashPattern {
    var result = DashPattern{};
    var parts = std.mem.splitScalar(u8, value, ',');
    while (parts.next()) |part| {
        if (result.count == result.values.len) return .{};
        const trimmed = std.mem.trim(u8, part, " \t");
        if (trimmed.len == 0) return .{};
        const parsed = std.fmt.parseFloat(f32, trimmed) catch return .{};
        if (!std.math.isFinite(parsed) or parsed <= 0) return .{};
        result.values[result.count] = parsed;
        result.count += 1;
    }
    if (result.count % 2 == 1) {
        if (result.count * 2 > result.values.len) return .{};
        const original_count = result.count;
        for (0..original_count) |index| result.values[original_count + index] = result.values[index];
        result.count *= 2;
    }
    return result;
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
