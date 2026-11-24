const std = @import("std");
const model = @import("model");
const color_utils = @import("utils").color;
const fields = @import("fields.zig");
const font_model = @import("font.zig");

const Node = model.Node;

const paint = @import("render_paint.zig");
const FALLBACK_TEXT_COLOR = paint.Color{ .r = 0.08, .g = 0.08, .b = 0.08 };
const FALLBACK_LINK_COLOR = paint.Color{ .r = 0.1, .g = 0.25, .b = 0.75 };

pub fn resolve(state: anytype, node: *const Node) paint.ResolvedRender {
    const kind = resolveKind(node);
    return .{
        .content = switch (kind) {
            .text => .{ .text = resolveText(state, node) },
            .code => .{ .code = .{
                .style = resolveCodeStyle(state, node),
                .language = fields.readExplicit(node, "content", &.{"language"}, .text),
                .highlight_lines = fields.readExplicit(node, "content", &.{"highlight_lines"}, .text) orelse "",
                .emoji_spacing = textEmojiSpacing(state, node),
                .wrap = shouldWrapText(state, node),
            } },
            .latex => .{ .latex = resolveLatex(state, node) },
            .raster_asset => .{ .raster_asset = resolveAsset(state, node) },
            .vector_asset => .{ .vector_asset = resolveAsset(state, node) },
            .vector_path => if (resolveVectorPath(node)) |path| .{ .vector_path = path } else .chrome_only,
            .chrome_only => .chrome_only,
        },
        .chrome = if (kind == .code) resolveChrome(state, node, "code", &.{"chrome"}) else resolveChrome(state, node, "chrome", &.{}),
        .rule = resolveRule(state, node),
    };
}

pub fn resolvePageBackground(state: anytype, page: *const Node) ?paint.Color {
    if (parseColorProperty(state, page, "background_fill")) |color| return color;
    const document = state.getNode(state.graph.document_id) orelse return null;
    if (parseColorProperty(state, document, "background_fill")) |color| return color;
    for ([_]*const Node{ page, document }) |owner| {
        if (model.nodeField(owner, "theme")) |theme| if (theme == .record) {
            const appearance = theme.record.field("page") orelse return null;
            return if (appearance == .record) recordColor(appearance.record, "background_fill") else null;
        };
    }
    return null;
}

pub fn resolveKind(node: *const Node) paint.RenderKind {
    if (node.placement) |placement| switch (placement.display) {
        .expanded, .group => return .chrome_only,
        .native => |kind| return switch (kind) {
            .text => if (model.nodeTextContentKind(node) == .code) .code else .text,
            .image => switch (model.nodeImageSourceKind(node) orelse return .chrome_only) {
                .file => .raster_asset,
                .pdf, .icon => .vector_asset,
                .latex => .latex,
            },
            .path_shape => .vector_path,
        },
        .pending, .running => {},
    };
    return .chrome_only;
}

pub fn resolveTextForNode(state: anytype, node: *const Node) ?paint.TextPaint {
    return switch (resolveKind(node)) {
        .text => resolveText(state, node),
        else => null,
    };
}

const heading_keys = [_][]const u8{ "h1", "h2", "h3", "h4", "h5", "h6" };

fn implicitHeading(node: *const Node) ?usize {
    const placement = node.placement orelse return null;
    if (placement.display != .native or placement.display.native != .text) return null;
    const style = placement.value.record.field("style") orelse return null;
    if (style != .none) return null;
    const level = fields.readExplicit(node, "content", &.{"heading_level"}, .number) orelse return null;
    return if (level >= 1 and level <= 6 and @floor(level) == level) @intFromFloat(level - 1) else 0;
}

fn typographyMetrics(state: anytype, node: *const Node) paint.TextMetrics {
    const size = positiveRecordFloatProperty(state, node, "size", &.{}) orelse 20;
    return .{ .font_size = size, .line_height = positiveRecordFloatProperty(state, node, "line_height", &.{}) orelse size * 1.45 };
}

fn headingMetrics(state: anytype, node: *const Node, key: []const u8, base: paint.TextMetrics) paint.TextMetrics {
    const size = positiveRecordFloatProperty(state, node, "headings", &.{ key, "size" }) orelse base.font_size;
    return .{ .font_size = size, .line_height = positiveRecordFloatProperty(state, node, "headings", &.{ key, "line_height" }) orelse base.line_height * (size / base.font_size) };
}

fn codeMetrics(state: anytype, node: *const Node) paint.TextMetrics {
    const size = positiveRecordFloatProperty(state, node, "code", &.{"size"}) orelse 16;
    return .{ .font_size = size, .line_height = positiveRecordFloatProperty(state, node, "code", &.{"line_height"}) orelse size * 1.45 };
}

fn textEmojiSpacing(state: anytype, node: *const Node) f32 {
    return nonNegativeRecordFloatProperty(state, node, "emoji_spacing", &.{}) orelse 0;
}

pub fn resolveTextMetrics(state: anytype, node: *const Node) paint.TextMetrics {
    if (model.nodeTextContentKind(node) == .code) return codeMetrics(state, node);
    const base = typographyMetrics(state, node);
    return if (implicitHeading(node)) |index| headingMetrics(state, node, heading_keys[index], base) else base;
}

pub fn shouldWrapText(state: anytype, node: *const Node) bool {
    if (node.placement) |placement| if (placement.display == .native and placement.display.native != .text) return false;
    if (naturalPathSize(node) != null) return false;
    switch (model.nodePayloadKind(node) orelse .text) {
        .image_ref, .pdf_ref => return false,
        else => {},
    }
    if (fields.read(state.allocator, state, node, "layout", &.{"wrap"}, .text)) |wrap_mode| {
        if (std.mem.eql(u8, wrap_mode, "on")) return true;
        if (std.mem.eql(u8, wrap_mode, "off")) return false;
    }
    return if (node.placement) |placement| placement.display == .native and placement.display.native == .text else false;
}

fn baseTypography(state: anytype, node: *const Node) paint.Typography {
    const text_metrics = typographyMetrics(state, node);
    return .{
        .font = font_model.bodyFont(node),
        .font_size = text_metrics.font_size,
        .line_height = text_metrics.line_height,
        .horizontal_align = parseRecordHorizontalAlign(state, node, "align", &.{}) orelse .left,
        .color = parseRecordColorProperty(state, node, "color", &.{}) orelse FALLBACK_TEXT_COLOR,
        .emoji_spacing = textEmojiSpacing(state, node),
    };
}

pub fn resolveTypography(state: anytype, node: *const Node) paint.Typography {
    if (model.nodeTextContentKind(node) == .code) {
        const metrics = codeMetrics(state, node);
        return .{
            .font = font_model.codeFont(node),
            .font_size = metrics.font_size,
            .line_height = metrics.line_height,
            .color = codePlainColor(state, node),
            .emoji_spacing = textEmojiSpacing(state, node),
        };
    }
    const base = baseTypography(state, node);
    return if (implicitHeading(node)) |level| resolveHeading(state, node, heading_keys[level], base) orelse base else base;
}

fn resolveText(state: anytype, node: *const Node) paint.TextPaint {
    const typography = baseTypography(state, node);
    var base: paint.TextPaint = .{
        .typography = typography,
        .headings = @splat(null),
        .markdown = resolveMarkdown(state, node, typography.font_size),
        .code = .{ .style = resolveCodeStyle(state, node), .chrome = resolveChrome(state, node, "code", &.{"chrome"}) },
        .math = .{
            .scale = positiveRecordFloatProperty(state, node, "math", &.{"scale"}) orelse 1,
            .inline_spacing = nonNegativeRecordFloatProperty(state, node, "math", &.{"inline_spacing"}) orelse 0,
            .display_gap = nonNegativeRecordFloatProperty(state, node, "math", &.{"display_gap"}) orelse 0.2,
            .display_fit = parseEnum(paint.MathFit, fields.read(state.allocator, state, node, "math", &.{"display_fit"}, .text)) orelse .none,
            .horizontal_align = parseRecordHorizontalAlign(state, node, "math", &.{"align"}) orelse .center,
        },
        .wrap = shouldWrapText(state, node),
    };
    for (heading_keys, 0..) |key, i| {
        base.headings[i] = resolveHeading(state, node, key, typography);
    }
    if (implicitHeading(node)) |index| return base.forMarkdownHeading(@intCast(index + 1));
    return base;
}

fn resolveHeading(state: anytype, node: *const Node, key: []const u8, base: paint.Typography) ?paint.Typography {
    const levels = model.nodeField(node, "headings") orelse return null;
    const patch = fields.pathValue(levels, &.{key}) orelse return null;
    if (patch != .record) return null;
    const metrics = headingMetrics(state, node, key, .{ .font_size = base.font_size, .line_height = base.line_height });
    return .{
        .font = font_model.headingFont(node, key, base.font),
        .font_size = metrics.font_size,
        .line_height = metrics.line_height,
        .horizontal_align = parseRecordHorizontalAlign(state, node, "headings", &.{ key, "align" }) orelse base.horizontal_align,
        .color = recordColor(patch.record, "color") orelse base.color,
        .emoji_spacing = nonNegativeRecordFloatProperty(state, node, "headings", &.{ key, "emoji_spacing" }) orelse base.emoji_spacing,
    };
}

fn resolveMarkdown(state: anytype, node: *const Node, font_size: f32) paint.MarkdownPaint {
    return .{
        .emphasis = .{
            .bold_color = parseRecordColorProperty(state, node, "markdown", &.{ "bold", "color" }),
            .link_color = parseRecordColorProperty(state, node, "markdown", &.{ "link", "color" }) orelse FALLBACK_LINK_COLOR,
            .code_color = parseRecordColorProperty(state, node, "markdown", &.{ "code", "color" }),
            .code_fill = parseRecordColorProperty(state, node, "markdown", &.{ "code", "fill" }),
            .highlight_fill = parseRecordColorProperty(state, node, "markdown", &.{"highlight_fill"}),
            .underline = resolveMarkdownUnderline(state, node),
            .bold_weight = font_model.boldWeight(state, node),
            .italic_style = font_model.italicStyle(state, node),
        },
        .table = .{
            .cell_pad_x = nonNegativeRecordFloatProperty(state, node, "markdown", &.{ "table", "cell_pad_x" }) orelse @max(@as(f32, 6.0), font_size * 0.55),
            .cell_pad_y = nonNegativeRecordFloatProperty(state, node, "markdown", &.{ "table", "cell_pad_y" }) orelse @max(@as(f32, 4.0), font_size * 0.32),
            .border = parseRecordColorProperty(state, node, "markdown", &.{ "table", "border" }),
            .line_width = nonNegativeRecordFloatProperty(state, node, "markdown", &.{ "table", "line_width" }) orelse 0.8,
            .header_fill = parseRecordColorProperty(state, node, "markdown", &.{ "table", "header_fill" }),
            .alt_row_fill = parseRecordColorProperty(state, node, "markdown", &.{ "table", "alt_row_fill" }),
        },
        .quote = resolveMarkdownQuote(state, node),
        .list = .{
            .inset = nonNegativeRecordFloatProperty(state, node, "markdown", &.{ "list", "inset" }) orelse 0,
            .indent = nonNegativeRecordFloatProperty(state, node, "markdown", &.{ "list", "indent" }) orelse 0,
        },
        .block_gap = nonNegativeRecordFloatProperty(state, node, "markdown", &.{"block_gap"}) orelse 0,
    };
}

fn codePlainColor(state: anytype, node: *const Node) paint.Color {
    return parseRecordColorProperty(state, node, "code", &.{ "colors", "plain" }) orelse parseRecordColorProperty(state, node, "color", &.{}) orelse FALLBACK_TEXT_COLOR;
}

fn resolveCodeStyle(state: anytype, node: *const Node) paint.CodeStyle {
    const metrics = codeMetrics(state, node);
    const plain = codePlainColor(state, node);
    var colors: paint.CodeColors = undefined;
    var backgrounds: paint.CodeBackgrounds = .initFill(null);
    inline for (comptime std.meta.tags(paint.CodeRole)) |role| {
        const name = if (role == .type) "type_name" else @tagName(role);
        colors.set(role, if (role == .plain) plain else parseRecordColorProperty(state, node, "code", &.{ "colors", name }) orelse plain);
    }
    inline for (.{ .addition, .deletion, .change }) |role| {
        backgrounds.set(role, parseRecordColorProperty(state, node, "code", &.{ "colors", @tagName(role) ++ "_fill" }));
    }
    return .{
        .font = font_model.codeFont(node),
        .font_size = metrics.font_size,
        .line_height = metrics.line_height,
        .line_highlight_fill = parseRecordColorProperty(state, node, "code", &.{"line_highlight_fill"}),
        .colors = colors,
        .backgrounds = backgrounds,
    };
}

fn resolveMarkdownUnderline(state: anytype, node: *const Node) paint.MarkdownUnderlinePaint {
    const opacity = recordFloatProperty(state, node, "markdown", &.{ "underline", "opacity" }) orelse 1;
    return .{
        .color = parseRecordColorProperty(state, node, "markdown", &.{ "underline", "color" }),
        .opacity = normalizedOpacity(opacity),
        .width = nonNegativeRecordFloatProperty(state, node, "markdown", &.{ "underline", "width" }),
        .offset = recordFloatProperty(state, node, "markdown", &.{ "underline", "offset" }) orelse 0,
        .dash = parseRecordDashProperty(state, node, "markdown", &.{ "underline", "dash" }),
    };
}

fn resolveMarkdownQuote(state: anytype, node: *const Node) paint.MarkdownQuotePaint {
    return .{
        .color = parseRecordColorProperty(state, node, "markdown", &.{ "quote", "color" }),
        .inset = nonNegativeRecordFloatProperty(state, node, "markdown", &.{ "quote", "inset" }) orelse 0,
        .pad_x = nonNegativeRecordFloatProperty(state, node, "markdown", &.{ "quote", "pad_x" }) orelse 0,
        .pad_y = nonNegativeRecordFloatProperty(state, node, "markdown", &.{ "quote", "pad_y" }) orelse 0,
        .fill = parseRecordColorProperty(state, node, "markdown", &.{ "quote", "fill" }),
        .radius = nonNegativeRecordFloatProperty(state, node, "markdown", &.{ "quote", "radius" }) orelse 0,
        .bar = .{
            .stroke = parseRecordColorProperty(state, node, "markdown", &.{ "quote", "bar", "color" }),
            .line_width = nonNegativeRecordFloatProperty(state, node, "markdown", &.{ "quote", "bar", "width" }) orelse 0,
            .dash = parseRecordDashProperty(state, node, "markdown", &.{ "quote", "bar", "dash" }),
        },
    };
}

pub fn resolveLatex(state: anytype, node: *const Node) paint.LatexPaint {
    return .{
        .min_height = positiveRecordFloatProperty(state, node, "image_source", &.{"min_height"}) orelse paint.default_latex_min_height,
        .scale = positiveRecordFloatProperty(state, node, "image", &.{"scale"}) orelse 1,
        .horizontal_align = parseRecordHorizontalAlign(state, node, "image", &.{"align"}) orelse .center,
    };
}

fn resolveAsset(state: anytype, node: *const Node) paint.AssetPaint {
    return .{
        .format = if (isPdfInput(node)) .pdf else .image,
        .scale = positiveRecordFloatProperty(state, node, "image", &.{"scale"}) orelse 1,
        .tint = parseRecordColorProperty(state, node, "image", &.{"tint"}),
        .pdf_page = resolvedPdfPage(state, node),
        .pdf_box = resolvedPdfPageBox(state, node),
        .horizontal_align = parseRecordHorizontalAlign(state, node, "image", &.{"align"}) orelse .left,
    };
}

fn isPdfInput(node: *const Node) bool {
    return model.nodeImageSourceKind(node) == .pdf;
}

fn resolvedPdfPage(state: anytype, node: *const Node) usize {
    const number = positiveRecordFloatProperty(state, node, "image_source", &.{"pdf_page"}) orelse 1;
    return pdfPageNumber(@floor(number)) orelse 1;
}

pub fn pdfPageNumber(number: f32) ?usize {
    if (!std.math.isFinite(number) or number < 1 or @floor(number) != number) return null;
    const upper_bound = @as(f64, @floatFromInt(std.math.maxInt(usize))) + 1;
    if (@as(f64, number) >= upper_bound) return null;
    return @intFromFloat(number);
}

fn resolvedPdfPageBox(state: anytype, node: *const Node) paint.PdfPageBox {
    const name = fields.read(state.allocator, state, node, "image_source", &.{"pdf_box"}, .text) orelse return .crop;
    return std.meta.stringToEnum(paint.PdfPageBox, name) orelse .crop;
}

pub fn naturalPathSize(node: *const Node) ?paint.VectorPathPaint.Size {
    const placement = node.placement orelse return null;
    if (placement.display != .native or placement.display.native != .path_shape) return null;
    return .{
        .width = @floatCast(placement.value.record.field("width").?.number),
        .height = @floatCast(placement.value.record.field("height").?.number),
    };
}

fn resolveVectorPath(node: *const Node) ?paint.VectorPathPaint {
    const path_value = model.nodeField(node, "path") orelse return null;
    const path = switch (path_value) {
        .path => |value| value,
        else => return null,
    };
    const fill = if (model.nodeField(node, "fill")) |fill_value| switch (fill_value) {
        .record => |record| vectorFillFromRecord(record),
        else => paint.VectorFillPaint{},
    } else paint.VectorFillPaint{};
    const stroke = resolveVectorStroke(node, "stroke");
    return .{
        .path = path,
        .natural_size = naturalPathSize(node),
        .fill = fill,
        .stroke = stroke,
        .marker_start = markerFromNode(node, "marker_start"),
        .marker_end = markerFromNode(node, "marker_end"),
    };
}

fn markerFromNode(node: *const Node, field_name: []const u8) ?paint.MarkerPaint {
    const value = model.nodeField(node, field_name) orelse return null;
    const marker = switch (value) {
        .record => |record| record,
        else => return null,
    };
    return markerFromValue(marker);
}

fn resolveVectorStroke(node: *const Node, key: []const u8) ?paint.VectorStrokePaint {
    const value = model.nodeField(node, key) orelse return null;
    return switch (value) {
        .record => |record| vectorStrokeFromRecord(record),
        else => null,
    };
}

fn vectorFillFromRecord(record: model.RecordValue) paint.VectorFillPaint {
    const kind = parseEnum(paint.VectorFillKind, recordText(record, "kind")) orelse .none;
    return .{
        .base = switch (kind) {
            .none => .none,
            .solid => if (recordColor(record, "color")) |color| .{ .solid = color } else .none,
            .linear, .radial => blk: {
                const gradient: paint.Gradient = .{
                    .colors = .{ recordColor(record, "color") orelse break :blk .none, recordColor(record, "color2") orelse break :blk .none },
                    .start = .{ .x = recordNumber(record, "start_x") orelse 0, .y = recordNumber(record, "start_y") orelse 0 },
                    .end = .{ .x = recordNumber(record, "end_x") orelse 1, .y = recordNumber(record, "end_y") orelse 1 },
                    .spread = parseEnum(paint.GradientSpread, recordText(record, "spread")) orelse .pad,
                    .space = parseEnum(paint.PaintSpace, recordText(record, "space")) orelse .local,
                };
                break :blk if (kind == .linear) .{ .linear = gradient } else .{ .radial = .{
                    .gradient = gradient,
                    .start_radius = recordNumber(record, "start_radius") orelse 0,
                    .end_radius = recordNumber(record, "end_radius") orelse 1,
                } };
            },
        },
        .rule = parseEnum(paint.FillRule, recordText(record, "rule")) orelse .nonzero,
        .opacity = recordNumber(record, "opacity") orelse 1,
        .pattern = resolvePattern(record),
    };
}

fn markerFromValue(marker: model.RecordValue) ?paint.MarkerPaint {
    const path_value = marker.field("path") orelse return null;
    const path = switch (path_value) {
        .path => |path| path,
        else => return null,
    };
    const fill = if (marker.field("fill")) |fill_value| switch (fill_value) {
        .record => |fill_record| vectorFillFromRecord(fill_record),
        else => paint.VectorFillPaint{},
    } else paint.VectorFillPaint{};
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

fn resolvePattern(fill_record: model.RecordValue) ?paint.PatternPaint {
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
        .transform = .{
            .xx = cosine * xx - sine * yx,
            .yx = sine * xx + cosine * yx,
            .xy = cosine * xy - sine * yy,
            .yy = sine * xy + cosine * yy,
            .x0 = recordNumber(pattern, "x0") orelse 0,
            .y0 = recordNumber(pattern, "y0") orelse 0,
        },
        .space = parseEnum(paint.PaintSpace, recordText(pattern, "space")) orelse .local,
        .fill = fill,
        .stroke = stroke,
    };
}

fn vectorStrokeFromRecord(record: model.RecordValue) ?paint.VectorStrokePaint {
    const color = recordColor(record, "color") orelse return null;
    var dash = parseDashPattern(recordText(record, "dash") orelse "");
    dash.offset = recordNumber(record, "dash_offset") orelse 0;
    return .{
        .color = color,
        .width = recordNumber(record, "width") orelse 1,
        .cap = parseEnum(paint.LineCap, recordText(record, "cap")) orelse .butt,
        .join = parseEnum(paint.LineJoin, recordText(record, "join")) orelse .miter,
        .miter_limit = recordNumber(record, "miter_limit") orelse 10,
        .dash = dash,
    };
}

fn resolveChrome(state: anytype, node: *const Node, comptime key: []const u8, comptime path: []const []const u8) paint.ChromePaint {
    return .{
        .bottom_rule = resolveBottomRule(state, node, key, path ++ .{"bottom_rule"}),
        .fill = parseRecordColorProperty(state, node, key, path ++ .{"fill"}),
        .stroke = parseRecordColorProperty(state, node, key, path ++ .{"stroke"}),
        .line_width = nonNegativeRecordFloatProperty(state, node, key, path ++ .{"line_width"}) orelse 0,
        .radius = nonNegativeRecordFloatProperty(state, node, key, path ++ .{"radius"}) orelse 0,
        .pad_x = nonNegativeRecordFloatProperty(state, node, key, path ++ .{"pad_x"}) orelse 0,
        .pad_y = nonNegativeRecordFloatProperty(state, node, key, path ++ .{"pad_y"}) orelse 0,
    };
}

fn resolveBottomRule(state: anytype, node: *const Node, comptime key: []const u8, comptime path: []const []const u8) paint.BottomRulePaint {
    return .{
        .color = parseRecordColorProperty(state, node, key, path ++ .{"color"}),
        .width = nonNegativeRecordFloatProperty(state, node, key, path ++ .{"width"}) orelse 0,
        .offset = recordFloatProperty(state, node, key, path ++ .{"offset"}) orelse 0,
    };
}

fn resolveRule(state: anytype, node: *const Node) paint.RulePaint {
    return .{
        .stroke = parseRecordColorProperty(state, node, "rule", &.{"stroke"}),
        .line_width = nonNegativeRecordFloatProperty(state, node, "rule", &.{"line_width"}) orelse 0,
        .dash = parseRecordDashProperty(state, node, "rule", &.{"dash"}),
    };
}

const recordFloatProperty = fields.recordPathFloatProperty;

const positiveRecordFloatProperty = fields.positivePathFloatProperty;

const nonNegativeRecordFloatProperty = fields.nonNegativePathFloatProperty;

fn normalizedOpacity(value: f32) f32 {
    if (!std.math.isFinite(value)) return 1;
    return std.math.clamp(value, 0, 1);
}

fn parseRecordColorProperty(state: anytype, node: *const Node, record_key: []const u8, path: []const []const u8) ?paint.Color {
    const value = fields.read(state.allocator, state, node, record_key, path, .text) orelse return null;
    return parseColor(value);
}

fn parseRecordDashProperty(state: anytype, node: *const Node, record_key: []const u8, path: []const []const u8) ?paint.Dash {
    const value = fields.read(state.allocator, state, node, record_key, path, .text) orelse return null;
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

fn recordColor(record: model.RecordValue, field_name: []const u8) ?paint.Color {
    return parseColor(recordText(record, field_name) orelse return null);
}

fn parseDashPattern(value: []const u8) paint.DashPattern {
    var result = paint.DashPattern{};
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

fn parseRecordHorizontalAlign(state: anytype, node: *const Node, key: []const u8, path: []const []const u8) ?paint.HorizontalAlign {
    return parseEnum(paint.HorizontalAlign, fields.read(state.allocator, state, node, key, path, .text));
}

fn parseColorProperty(state: anytype, node: *const Node, key: []const u8) ?paint.Color {
    const value = fields.read(state.allocator, state, node, key, &.{}, .text) orelse return null;
    return parseColor(value);
}

const parseColor = color_utils.parse;

fn parseDash(value: []const u8) ?paint.Dash {
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
