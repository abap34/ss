const std = @import("std");
const core = @import("core");
const render_ir = @import("render");
const render_text = @import("render_text");
const render_emitter = @import("render_emitter");
const artifacts = @import("artifacts.zig");
const text_measure = core.render_text_measure;
const Allocator = std.mem.Allocator;
const Color = core.render_policy.Color;
const FontFace = core.font.Face;
const TextPaint = core.render_policy.TextPaint;
const ContentRange = render_text.ContentRange;
const Line = core.markdown.Line;
const Run = core.markdown.Run;
const LatexFragmentKind = @import("latex.zig").FragmentKind;
const Size = artifacts.Size;

// Prepared spans borrow Markdown source and paint strings while owning native
// layouts and generated inline asset paths. They do not own an IR destination.
pub const Context = struct {
    assets: artifacts.Context,
    text_cache: ?*render_text.Cache = null,
    latex_preamble: []const core.render_env.LatexPreambleEntry = &.{},
    latex_engine: core.render_env.LatexEngine = .pdflatex,
};

pub const InlineContent = union(enum) {
    text,
    latex: struct {
        path: []const u8,
        page_index: usize,
    },
    icon: struct { path: []const u8 },

    pub fn deinit(self: *InlineContent, allocator: Allocator) void {
        switch (self.*) {
            .text => {},
            .latex => |latex| allocator.free(latex.path),
            .icon => |icon| allocator.free(icon.path),
        }
    }
};

pub const InlineSpan = struct {
    content: InlineContent = .text,
    text: []const u8,
    font: FontFace,
    color: Color,
    width: f32 = 0,
    height: f32 = 0,
    baseline_from_bottom: f32 = 0,
    content_range: ?ContentRange = null,
    strikethrough: bool = false,
    underline: bool = false,
    underline_paint: core.render_policy.MarkdownUnderlinePaint = .{},
    link_url: ?[]const u8 = null,
};

pub const ParagraphPaint = struct {
    font: FontFace,
    font_size: f32,
    line_height: f32,
    emoji_spacing: f32,
    inline_math_spacing: f32,
};

pub const PreparedParagraph = struct {
    layout: *render_text.paragraph.Layout,
    starts: []usize,

    pub fn deinit(self: *PreparedParagraph, allocator: Allocator) void {
        self.layout.release();
        allocator.free(self.starts);
    }

    pub fn spanAt(self: PreparedParagraph, offset: usize) usize {
        var low: usize = 0;
        var high = self.starts.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (self.starts[middle] <= offset) low = middle + 1 else high = middle;
        }
        return low - 1;
    }
};

pub fn prepareLineSpans(ctx: Context, line: Line, text: TextPaint, spans: *std.ArrayList(InlineSpan)) !void {
    try prepareRunSpans(ctx, line.runs.items, text, spans);
}

pub fn prepareRunSpans(ctx: Context, runs: []const Run, text: TextPaint, spans: *std.ArrayList(InlineSpan)) !void {
    try spans.ensureUnusedCapacity(ctx.assets.allocator, runs.len);

    for (runs) |run| {
        switch (run.kind) {
            .math, .display_math => {
                try appendMathSpan(ctx, spans, run.text, text, if (run.kind == .display_math) .display_math else .inline_math);
            },
            .icon => if (run.icon) |source| try appendIconSpan(ctx, spans, source, text),
            .bold => try appendTextSpan(ctx, spans, run.text, text.bold_font, text.markdown_bold_color orelse text.color, null, run.strikethrough, run.underline, text.markdown_underline, .{ .start = run.source_start, .end = run.source_end }),
            .italic => try appendTextSpan(ctx, spans, run.text, text.italic_font, text.color, null, run.strikethrough, run.underline, text.markdown_underline, .{ .start = run.source_start, .end = run.source_end }),
            .code => try appendTextSpan(ctx, spans, run.text, text.code_font, text.color, null, run.strikethrough, run.underline, text.markdown_underline, .{ .start = run.source_start, .end = run.source_end }),
            .link => try appendTextSpan(ctx, spans, run.text, text.font, text.link_color, run.url, run.strikethrough, true, .{}, .{ .start = run.source_start, .end = run.source_end }),
            .text => try appendTextSpan(ctx, spans, run.text, text.font, text.color, null, run.strikethrough, run.underline, text.markdown_underline, .{ .start = run.source_start, .end = run.source_end }),
        }
    }
}

pub fn appendTextSpan(
    ctx: Context,
    spans: *std.ArrayList(InlineSpan),
    value: []const u8,
    font: FontFace,
    color: Color,
    link_url: ?[]const u8,
    strikethrough: bool,
    underline: bool,
    underline_paint: core.render_policy.MarkdownUnderlinePaint,
    content_range: ?ContentRange,
) !void {
    if (value.len == 0) return;
    try spans.append(ctx.assets.allocator, .{
        .text = value,
        .font = font,
        .color = color,
        .strikethrough = strikethrough,
        .underline = underline,
        .underline_paint = underline_paint,
        .link_url = link_url,
        .content_range = content_range,
    });
}

pub fn appendMathSpan(ctx: Context, spans: *std.ArrayList(InlineSpan), value: []const u8, text: TextPaint, kind: LatexFragmentKind) !void {
    const target_height = @max(text.font_size * text.inline_math_height_factor, 1);
    const asset = try artifacts.renderLatexToPdf(ctx.assets, value, ctx.latex_preamble, ctx.latex_engine, kind);
    errdefer ctx.assets.allocator.free(asset.path);
    const scale = if (asset.reference_height > 0) target_height / asset.reference_height else 1;
    try spans.append(ctx.assets.allocator, .{
        .content = .{ .latex = .{ .path = asset.path, .page_index = asset.page_index } },
        .text = value,
        .font = text.font,
        .color = text.color,
        .width = @max(asset.width * scale, 1),
        .height = @max(asset.height * scale, 1),
        .baseline_from_bottom = asset.baseline_from_bottom * scale,
    });
}

pub fn appendIconSpan(ctx: Context, spans: *std.ArrayList(InlineSpan), source: []const u8, text: TextPaint) !void {
    const svg = try artifacts.renderIconToSvg(ctx.assets, source);
    errdefer ctx.assets.allocator.free(svg.path);
    const target_height = @max(text.font_size, 1);
    const scale = if (svg.height > 0) target_height / svg.height else 1;
    const font_metrics = try text_measure.lineMetrics(ctx.assets.allocator, text.font, text.font_size);
    const font_height = font_metrics.ascent + font_metrics.descent;
    try spans.append(ctx.assets.allocator, .{
        .content = .{ .icon = .{ .path = svg.path } },
        .text = source,
        .font = text.font,
        .color = text.link_color,
        .width = @max(svg.width * scale, 1),
        .height = target_height,
        .baseline_from_bottom = target_height * font_metrics.descent / font_height,
    });
}

pub fn paragraphPaint(text: TextPaint) ParagraphPaint {
    return .{
        .font = text.font,
        .font_size = text.font_size,
        .line_height = text.line_height,
        .emoji_spacing = text.emoji_spacing,
        .inline_math_spacing = text.inline_math_spacing,
    };
}

pub fn prepareParagraph(ctx: Context, spans: []const InlineSpan, paint: ParagraphPaint, width: f32, wrap: bool) !PreparedParagraph {
    var source = std.ArrayList(u8).empty;
    defer source.deinit(ctx.assets.allocator);
    var styles = std.ArrayList(render_text.paragraph.Style).empty;
    defer styles.deinit(ctx.assets.allocator);
    var objects = std.ArrayList(render_text.paragraph.Object).empty;
    defer objects.deinit(ctx.assets.allocator);
    const starts = try ctx.assets.allocator.alloc(usize, spans.len);
    errdefer ctx.assets.allocator.free(starts);
    for (spans, starts) |span, *start| {
        start.* = source.items.len;
        switch (span.content) {
            .text => {
                try source.appendSlice(ctx.assets.allocator, span.text);
                try styles.append(ctx.assets.allocator, .{ .start = start.*, .end = source.items.len, .font = span.font });
            },
            .latex, .icon => {
                try source.appendSlice(ctx.assets.allocator, "\u{fffc}");
                try objects.append(ctx.assets.allocator, .{
                    .source_start = start.*,
                    .width = span.width,
                    .height = span.height,
                    .baseline_from_bottom = span.baseline_from_bottom,
                    .spacing = if (span.content == .latex) paint.font_size * paint.inline_math_spacing else 0,
                });
            },
        }
    }
    const layout = try render_text.shapeParagraph(ctx.assets.allocator, ctx.assets.io, .{
        .source = source.items,
        .font = paint.font,
        .font_size = paint.font_size,
        .line_height = paint.line_height,
        .width = width,
        .wrap = wrap,
        .emoji_spacing = paint.font_size * paint.emoji_spacing,
        .styles = styles.items,
        .objects = objects.items,
    }, ctx.text_cache);
    return .{ .layout = layout, .starts = starts };
}

pub fn deinitInlineSpans(allocator: Allocator, spans: []InlineSpan) void {
    for (spans) |*span| span.content.deinit(allocator);
}

pub fn displayMathSource(allocator: Allocator, runs: []const Run) ![]const u8 {
    var joined = std.ArrayList(u8).empty;
    defer joined.deinit(allocator);
    for (runs) |run| {
        try joined.appendSlice(allocator, run.text);
    }
    const trimmed = std.mem.trim(u8, joined.items, " \t\r\n");
    return allocator.dupe(u8, trimmed);
}

pub fn fitDisplayMathBlockSize(source_width: f32, source_height: f32, max_width: f32, text: TextPaint) Size {
    if (source_width <= 0 or source_height <= 0) return .{ .width = @max(max_width, 1), .height = @max(text.line_height, 1) };
    const target_height = @max(text.line_height, text.font_size * text.display_math_height_factor);
    const scale = @min(max_width / source_width, target_height / source_height);
    return .{ .width = @max(source_width * scale, 1), .height = @max(source_height * scale, 1) };
}

pub fn spanDecoration(span: *const InlineSpan) render_emitter.TextDecoration {
    const dash = span.underline_paint.dash;
    return .{
        .strikethrough = span.strikethrough,
        .underline = span.underline,
        .underline_color = span.underline_paint.color,
        .underline_opacity = span.underline_paint.opacity,
        .underline_width = if (span.underline_paint.width) |value| @as(f64, value) else null,
        .underline_offset = span.underline_paint.offset,
        .underline_dash_on = if (dash) |value| value.on else 0,
        .underline_dash_off = if (dash) |value| value.off else 0,
    };
}

pub fn lineContainsDisplayMath(line: Line) bool {
    for (line.runs.items) |run| {
        if (run.kind == .display_math) return true;
    }
    return false;
}

pub const Fragment = struct { start: usize, end: usize, span_index: usize };

pub const Fragments = struct {
    prepared: *const PreparedParagraph,
    start: usize,
    end: usize,

    pub fn init(prepared: *const PreparedParagraph, run_index: usize) Fragments {
        const run = prepared.layout.native.runs[run_index];
        return .{ .prepared = prepared, .start = run.cluster_start, .end = run.cluster_start + run.cluster_count };
    }

    pub fn next(self: *Fragments) ?Fragment {
        if (self.start == self.end) return null;
        const prepared = self.prepared;
        const layout = prepared.layout;
        const span_index = prepared.spanAt(layout.native.clusters[self.start].source_start);
        const span_end = if (span_index + 1 < prepared.starts.len) prepared.starts[span_index + 1] else layout.source.len;
        var end = self.start + 1;
        // A cluster crossing a paint boundary takes the paint of its first logical character.
        while (end < self.end) : (end += 1) {
            const offset = layout.native.clusters[end].source_start;
            if (offset < prepared.starts[span_index] or offset >= span_end) break;
        }
        const result = Fragment{ .start = self.start, .end = end, .span_index = span_index };
        self.start = end;
        return result;
    }
};

fn include(bounds: *?render_ir.Rect, rect: render_ir.Rect) void {
    if (rect.width <= 0 or rect.height <= 0) return;
    bounds.* = if (bounds.*) |current| current.unioned(rect) else rect;
}

pub fn fragmentInk(layout: *const render_text.paragraph.Layout, run_index: usize, start: usize, end: usize, decoration: render_emitter.TextDecoration) ?render_ir.Rect {
    const run = layout.native.runs[run_index];
    const clusters = layout.native.clusters[start..end];
    const first = clusters[0];
    const last = clusters[clusters.len - 1];
    const x = run.x + first.x;
    const advance = last.x + last.advance_x - first.x;
    var ink: ?render_ir.Rect = null;
    for (clusters) |cluster| include(&ink, .{ .x = cluster.ink_bounds.x, .y = cluster.ink_bounds.y, .width = cluster.ink_bounds.width, .height = cluster.ink_bounds.height });
    if (decoration.strikethrough) if (render_emitter.decorationBounds(x, run.baseline_y, advance, run.strikethrough_position, run.strikethrough_thickness, null, 0, 1)) |rect| include(&ink, rect);
    if (decoration.underline) if (render_emitter.decorationBounds(x, run.baseline_y, advance, run.underline_position, run.underline_thickness, decoration.underline_width, decoration.underline_offset, decoration.underline_opacity)) |rect| include(&ink, rect);
    return ink;
}

fn paragraphInk(prepared: *const PreparedParagraph, spans: []const InlineSpan) ?render_ir.Rect {
    const layout = prepared.layout;
    var ink: ?render_ir.Rect = null;
    for (0..layout.native.run_count) |run_index| {
        var fragments = Fragments.init(prepared, run_index);
        while (fragments.next()) |fragment| {
            if (fragmentInk(layout, run_index, fragment.start, fragment.end, spanDecoration(&spans[fragment.span_index]))) |rect| include(&ink, rect);
        }
    }
    var object_index: usize = 0;
    for (spans) |span| {
        if (span.content == .text) continue;
        const position = layout.objects[object_index];
        object_index += 1;
        include(&ink, .{ .x = position.x, .y = position.baseline_y + span.baseline_from_bottom - span.height, .width = span.width, .height = span.height });
    }
    return ink;
}

pub const Segment = struct {
    top: f32,
    content: union(enum) {
        paragraph: struct { spans: []InlineSpan, prepared: PreparedParagraph },
        display_math: struct { asset: artifacts.LatexAsset, size: Size },
    },

    fn deinit(self: *Segment, allocator: Allocator) void {
        switch (self.content) {
            .paragraph => |*paragraph| {
                paragraph.prepared.deinit(allocator);
                deinitInlineSpans(allocator, paragraph.spans);
                allocator.free(paragraph.spans);
            },
            .display_math => |math| allocator.free(math.asset.path),
        }
    }
};

pub const PreparedBlock = struct {
    segments: []Segment,
    paint: ParagraphPaint,
    height: f32,
    logical_width: f32,
    ink_bounds: ?render_ir.Rect,

    pub fn deinit(self: *PreparedBlock, allocator: Allocator) void {
        for (self.segments) |*segment| segment.deinit(allocator);
        allocator.free(self.segments);
        self.* = undefined;
    }
};

const BlockBuilder = struct {
    ctx: Context,
    text: TextPaint,
    width: f32,
    segments: std.ArrayList(Segment) = .empty,
    height: f32 = 0,
    logical_width: f32 = 0,
    ink: ?render_ir.Rect = null,

    fn deinit(self: *BlockBuilder) void {
        for (self.segments.items) |*segment| segment.deinit(self.ctx.assets.allocator);
        self.segments.deinit(self.ctx.assets.allocator);
    }

    fn appendRuns(self: *BlockBuilder, runs: []const Run) !void {
        const allocator = self.ctx.assets.allocator;
        var spans = std.ArrayList(InlineSpan).empty;
        defer spans.deinit(allocator);
        errdefer deinitInlineSpans(allocator, spans.items);
        try prepareRunSpans(self.ctx, runs, self.text, &spans);
        var prepared = try prepareParagraph(self.ctx, spans.items, paragraphPaint(self.text), self.width, true);
        errdefer prepared.deinit(allocator);
        try self.segments.ensureUnusedCapacity(allocator, 1);
        const owned_spans = try spans.toOwnedSlice(allocator);
        self.segments.appendAssumeCapacity(.{ .top = self.height, .content = .{ .paragraph = .{ .spans = owned_spans, .prepared = prepared } } });
        if (paragraphInk(&prepared, owned_spans)) |rect| include(&self.ink, .{ .x = rect.x, .y = rect.y + self.height, .width = rect.width, .height = rect.height });
        self.height += @floatCast(prepared.layout.native.logical_bounds.height);
        self.logical_width = @max(self.logical_width, @as(f32, @floatCast(prepared.layout.native.logical_bounds.width)));
    }

    fn appendDisplayMath(self: *BlockBuilder, runs: []const Run) !void {
        const allocator = self.ctx.assets.allocator;
        const source = try displayMathSource(allocator, runs);
        defer allocator.free(source);
        if (source.len == 0) return;
        const asset = try artifacts.renderLatexToPdf(self.ctx.assets, source, self.ctx.latex_preamble, self.ctx.latex_engine, .display_math);
        errdefer allocator.free(asset.path);
        const size = fitDisplayMathBlockSize(asset.width, asset.height, self.width, self.text);
        const pad = @max(self.text.line_height * 0.2, 2);
        try self.segments.append(allocator, .{ .top = self.height + pad, .content = .{ .display_math = .{ .asset = asset, .size = size } } });
        include(&self.ink, .{ .x = 0, .y = self.height + pad, .width = size.width, .height = size.height });
        self.height += size.height + pad * 2;
        self.logical_width = @max(self.logical_width, size.width);
    }
};

pub fn prepareBlock(ctx: Context, lines: []const Line, text: TextPaint, width: f32) !PreparedBlock {
    var builder = BlockBuilder{ .ctx = ctx, .text = text, .width = width };
    defer builder.deinit();
    for (lines) |line| {
        try std.Io.checkCancel(ctx.assets.io);
        if (!lineContainsDisplayMath(line)) {
            try builder.appendRuns(line.runs.items);
            continue;
        }
        const runs = line.runs.items;
        var start: usize = 0;
        while (start < runs.len) {
            const math = runs[start].kind == .display_math;
            var end = start + 1;
            while (end < runs.len and (runs[end].kind == .display_math) == math) : (end += 1) {}
            if (math) try builder.appendDisplayMath(runs[start..end]) else try builder.appendRuns(runs[start..end]);
            start = end;
        }
    }
    return .{ .segments = try builder.segments.toOwnedSlice(ctx.assets.allocator), .paint = paragraphPaint(text), .height = @max(builder.height, text.line_height), .logical_width = builder.logical_width, .ink_bounds = builder.ink };
}
