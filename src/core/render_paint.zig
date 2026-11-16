const std = @import("std");
const model = @import("model");
const font = @import("font.zig");
pub const CodeRole = @import("utils").highlight.CaptureRole;

pub const Color = @import("utils").color.Rgb;

pub const Dash = struct {
    on: f32,
    off: f32,
};

pub const RenderKind = enum {
    text,
    code,
    latex,
    vector_asset,
    raster_asset,
    vector_path,
    chrome_only,
};

pub const LineCap = enum { butt, round, square };
pub const LineJoin = enum { miter, round, bevel };
pub const FillRule = enum { nonzero, even_odd };
pub const PaintSpace = enum { local, page };
pub const GradientSpread = enum { pad, repeat, reflect };
pub const VectorFillKind = enum { none, solid, linear, radial };

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
    transform: struct { xx: f32, yx: f32, xy: f32, yy: f32, x0: f32, y0: f32 },
    space: PaintSpace,
    fill: ?Color,
    stroke: ?VectorStrokePaint,
};

pub const Gradient = struct {
    start: model.PathPoint,
    end: model.PathPoint,
    colors: [2]Color,
    spread: GradientSpread,
    space: PaintSpace,
};

pub const VectorFillPaint = struct {
    base: union(VectorFillKind) {
        none,
        solid: Color,
        linear: Gradient,
        radial: struct { gradient: Gradient, start_radius: f32, end_radius: f32 },
    } = .none,
    rule: FillRule = .nonzero,
    opacity: f32 = 1,
    pattern: ?PatternPaint = null,

    pub fn usesPageSpace(self: *const VectorFillPaint) bool {
        if (self.pattern) |pattern| if (pattern.space == .page) return true;
        return switch (self.base) {
            .linear => |g| g.space == .page,
            .radial => |r| r.gradient.space == .page,
            .solid, .none => false,
        };
    }
};

pub const MarkerPaint = struct {
    path: model.Path,
    width: f32,
    height: f32,
    fill: VectorFillPaint,
    stroke: ?VectorStrokePaint,
};

pub const VectorPathPaint = struct {
    pub const Size = struct { width: f32, height: f32 };

    path: model.Path,
    natural_size: ?Size = null,
    fill: VectorFillPaint,
    stroke: ?VectorStrokePaint,
    marker_start: ?MarkerPaint,
    marker_end: ?MarkerPaint,
};

pub const HorizontalAlign = enum {
    left,
    center,
    right,
};

pub const FontFace = font.Face;

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
    bar: RulePaint = .{},
};

pub const MathFit = enum { none, shrink };

pub const Typography = struct {
    font: FontFace,
    font_size: f32,
    line_height: f32,
    horizontal_align: HorizontalAlign = .left,
    color: Color,
    emoji_spacing: f32,

    pub fn emojiSpacingInPoints(self: Typography) f32 {
        return self.font_size * self.emoji_spacing;
    }
};

pub const InlineMarkdown = struct {
    bold_weight: u16,
    italic_style: font.Style,
    bold_color: ?Color,
    link_color: Color,
    highlight_fill: ?Color,
    underline: MarkdownUnderlinePaint,
};

pub const TablePaint = struct {
    cell_pad_x: f32,
    cell_pad_y: f32,
    border: ?Color,
    line_width: f32,
    header_fill: ?Color,
    alt_row_fill: ?Color,
};

pub const MarkdownPaint = struct {
    emphasis: InlineMarkdown,
    quote: MarkdownQuotePaint,
    table: TablePaint,
    list: struct { inset: f32, indent: f32 },
    block_gap: f32,
};

pub const MathPaint = struct {
    scale: f32,
    inline_spacing: f32,
    display_gap: f32,
    display_fit: MathFit,
    horizontal_align: HorizontalAlign,
};

pub const CodeColors = std.EnumArray(CodeRole, Color);

pub const CodeStyle = struct {
    font: FontFace,
    font_size: f32,
    line_height: f32,
    line_highlight_fill: ?Color,
    colors: CodeColors,
};

pub const FencedCodePaint = struct {
    style: CodeStyle,
    chrome: ChromePaint,
};

pub const CodeBlockPaint = struct {
    style: CodeStyle,
    language: ?[]const u8,
    highlight_lines: []const u8,
    emoji_spacing: f32,
    wrap: bool,
};

pub const TextPaint = struct {
    typography: Typography,
    headings: [6]?Typography,
    markdown: MarkdownPaint,
    math: MathPaint,
    code: FencedCodePaint,
    wrap: bool,

    pub fn forMarkdownHeading(self: TextPaint, level: u8) TextPaint {
        if (level < 1 or level > self.headings.len) return self;
        const heading = self.headings[level - 1] orelse return self;
        var result = self;
        result.typography = heading;
        return result;
    }

    pub fn boldFont(self: *const TextPaint) FontFace {
        var face = self.typography.font;
        face.weight = @max(face.weight, self.markdown.emphasis.bold_weight);
        return face;
    }

    pub fn italicFont(self: *const TextPaint) FontFace {
        var face = self.typography.font;
        face.style = self.markdown.emphasis.italic_style;
        return face;
    }
};

pub const LatexPaint = struct {
    min_height: f32,
    scale: f32,
    horizontal_align: HorizontalAlign,
};

pub const default_latex_min_height: f32 = 30;

pub const AssetPaint = struct {
    format: enum { image, pdf } = .image,
    scale: f32,
    tint: ?Color,
    pdf_page: usize,
    pdf_box: PdfPageBox,
    horizontal_align: HorizontalAlign = .left,
};

pub const PdfPageBox = enum {
    media,
    crop,
    bleed,
    trim,
    art,
};

pub const ChromePaint = struct {
    fill: ?Color,
    stroke: ?Color,
    line_width: f32,
    radius: f32,
    pad_x: f32,
    pad_y: f32,
    bottom_rule: BottomRulePaint,
};

pub const BottomRulePaint = struct {
    color: ?Color = null,
    width: f32 = 0,
    offset: f32 = 0,
};

pub const RulePaint = struct {
    stroke: ?Color = null,
    line_width: f32 = 0,
    dash: ?Dash = null,
};

pub const ContentPaint = union(RenderKind) {
    text: TextPaint,
    code: CodeBlockPaint,
    latex: LatexPaint,
    vector_asset: AssetPaint,
    raster_asset: AssetPaint,
    vector_path: VectorPathPaint,
    chrome_only,

    pub fn setWrap(self: *ContentPaint, wrap: bool) void {
        switch (self.*) {
            .text => |*style| style.wrap = wrap,
            .code => |*code| code.wrap = wrap,
            else => {},
        }
    }

    pub fn asset(self: *const ContentPaint) ?AssetPaint {
        return switch (self.*) {
            .vector_asset, .raster_asset => |value| value,
            else => null,
        };
    }
};

pub const ResolvedRender = struct {
    content: ContentPaint,
    chrome: ChromePaint,
    rule: RulePaint,

    pub fn kind(self: *const ResolvedRender) RenderKind {
        return self.content;
    }
};
