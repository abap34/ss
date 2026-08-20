const std = @import("std");
const core = @import("core");
const render = @import("render");
const resources_compile = @import("render_resources");
const text = @import("render_text");

const Allocator = std.mem.Allocator;
const Color = core.render_policy.Color;

pub const TextDecoration = struct {
    strikethrough: bool = false,
    underline: bool = false,
    underline_color: ?Color = null,
    underline_opacity: f64 = 1,
    underline_width: ?f64 = null,
    underline_offset: f64 = 0,
    underline_dash_on: f64 = 0,
    underline_dash_off: f64 = 0,
};

const DecorationSegment = struct {
    start: render.Point,
    end: render.Point,
    line_width: f64,
    color: Color,
    opacity: f64,
    dash_on: f64,
    dash_off: f64,
    behind_text: bool,
};

pub const Emitter = struct {
    page: *render.Page,
    resources: *resources_compile.Builder,
    fonts: *render.FontBuilder,
    math: *render.MathBuilder,
    io: std.Io,
    text_cache: ?*text.Cache = null,
    text_failure: ?*text.ShapeFailure = null,
    node_id: ?core.NodeId = null,

    pub fn replaceNodeId(self: *Emitter, node_id: ?core.NodeId) ?core.NodeId {
        const previous = self.node_id;
        self.node_id = node_id;
        return previous;
    }

    pub fn fillRect(self: *Emitter, allocator: Allocator, rect: render.Rect, color: Color) !void {
        try self.page.appendFillRect(allocator, self.node_id, rect, color);
    }

    pub fn strokeLine(
        self: *Emitter,
        allocator: Allocator,
        start: render.Point,
        end: render.Point,
        line_width: f64,
        color: Color,
        dash_on: f64,
        dash_off: f64,
    ) !void {
        try self.page.appendStrokeLine(allocator, self.node_id, start, end, line_width, color, dash_on, dash_off);
    }

    pub fn roundedRect(
        self: *Emitter,
        allocator: Allocator,
        rect: render.Rect,
        radius: f64,
        fill: ?Color,
        stroke: ?Color,
        line_width: f64,
    ) !void {
        try self.page.appendRoundedRect(allocator, self.node_id, rect, radius, fill, stroke, line_width);
    }

    pub fn vectorPath(
        self: *Emitter,
        allocator: Allocator,
        commands: []const render.PathCommand,
        fill: render.FillPaint,
        stroke: ?render.StrokePaint,
    ) !void {
        try self.page.appendVectorPath(allocator, self.node_id, commands, fill, stroke);
    }

    pub fn textBaseline(
        self: *Emitter,
        allocator: Allocator,
        x: f64,
        baseline_y: f64,
        width: f64,
        content: []const u8,
        font: core.font.Face,
        font_size: f64,
        color: Color,
        wrap: bool,
        decoration: TextDecoration,
    ) !void {
        const layout = if (self.text_failure) |failure|
            try text.shapeWithFailure(
                allocator,
                self.io,
                self.resources,
                self.fonts,
                content,
                font,
                font_size,
                width,
                wrap,
                self.text_cache,
                failure,
            )
        else
            try text.shape(
                allocator,
                self.io,
                self.resources,
                self.fonts,
                content,
                font,
                font_size,
                width,
                wrap,
                self.text_cache,
            );
        try self.textLayoutBaseline(
            allocator,
            x,
            baseline_y,
            width,
            layout,
            font_size,
            color,
            decoration,
        );
    }

    pub fn textLayoutBaseline(
        self: *Emitter,
        allocator: Allocator,
        x: f64,
        baseline_y: f64,
        width: f64,
        layout: render.TextLayout,
        font_size: f64,
        color: Color,
        decoration: TextDecoration,
    ) !void {
        var owned_layout = layout;
        var owns_layout = true;
        errdefer if (owns_layout) owned_layout.deinit(allocator);
        var segments = std.ArrayList(DecorationSegment).empty;
        defer segments.deinit(allocator);
        const layout_y = baseline_y - owned_layout.firstBaseline();
        if (decoration.strikethrough or decoration.underline) {
            for (owned_layout.runs) |run| {
                const instance = self.fonts.get(self.io, run.font_instance) orelse return error.MissingRenderFont;
                const run_baseline = layout_y + run.baseline_y;
                if (decoration.strikethrough) try appendDecorationSegment(
                    allocator,
                    &segments,
                    x + run.x,
                    run_baseline,
                    run.advance,
                    font_size * instance.strikethrough_position_ratio,
                    font_size * instance.strikethrough_thickness_ratio,
                    color,
                    1,
                    null,
                    0,
                    0,
                    0,
                    false,
                );
                if (decoration.underline) try appendDecorationSegment(
                    allocator,
                    &segments,
                    x + run.x,
                    run_baseline,
                    run.advance,
                    font_size * instance.underline_position_ratio,
                    font_size * instance.underline_thickness_ratio,
                    decoration.underline_color orelse color,
                    decoration.underline_opacity,
                    decoration.underline_width,
                    decoration.underline_offset,
                    decoration.underline_dash_on,
                    decoration.underline_dash_off,
                    true,
                );
            }
        }
        for (segments.items) |segment| {
            if (!segment.behind_text) continue;
            try self.page.appendStrokeLineWithOpacity(
                allocator,
                self.node_id,
                segment.start,
                segment.end,
                segment.line_width,
                segment.color,
                segment.dash_on,
                segment.dash_off,
                segment.opacity,
            );
        }
        owns_layout = false;
        try self.page.appendTextLayout(
            allocator,
            self.node_id,
            x,
            baseline_y,
            width,
            owned_layout,
            font_size,
            color,
        );
        for (segments.items) |segment| {
            if (segment.behind_text) continue;
            try self.page.appendStrokeLineWithOpacity(
                allocator,
                self.node_id,
                segment.start,
                segment.end,
                segment.line_width,
                segment.color,
                segment.dash_on,
                segment.dash_off,
                segment.opacity,
            );
        }
    }

    pub fn raster(self: *Emitter, allocator: Allocator, rect: render.Rect, path: []const u8) !void {
        const resource = try self.resources.addPath(allocator, self.io, .raster, path);
        try self.page.appendRaster(allocator, self.node_id, rect, resource);
    }

    pub fn svg(self: *Emitter, allocator: Allocator, rect: render.Rect, path: []const u8, tint: ?Color) !void {
        const resource = try self.resources.addPath(allocator, self.io, .svg, path);
        try self.page.appendSvg(allocator, self.node_id, rect, resource, tint);
    }

    pub fn pdfPage(
        self: *Emitter,
        allocator: Allocator,
        rect: render.Rect,
        path: []const u8,
        page_index: usize,
        box: core.render_policy.PdfPageBox,
        copy_annotations: bool,
    ) !void {
        const resource = try self.resources.addPath(allocator, self.io, .pdf, path);
        try self.page.appendPdfPage(allocator, self.node_id, rect, resource, page_index, box, copy_annotations);
    }

    pub fn rawMathPdf(
        self: *Emitter,
        allocator: Allocator,
        rect: render.Rect,
        source: []const u8,
        path: []const u8,
        page_index: usize,
    ) !void {
        const tree = try self.math.add(allocator, source, .raw);
        const resource = try self.resources.addPath(allocator, self.io, .math_pdf, path);
        try self.page.appendRawMathPdf(allocator, self.node_id, rect, tree, resource, page_index, .crop);
    }

    pub fn structuredMath(
        self: *Emitter,
        allocator: Allocator,
        rect: render.Rect,
        tree: render.MathTreeId,
        layout: render.MathLayout,
        color: Color,
    ) !void {
        try self.page.appendStructuredMath(allocator, self.node_id, rect, tree, layout, color);
    }
};

fn appendDecorationSegment(
    allocator: Allocator,
    segments: *std.ArrayList(DecorationSegment),
    x: f64,
    baseline_y: f64,
    advance: f64,
    position: f64,
    native_thickness: f64,
    color: Color,
    opacity: f64,
    width: ?f64,
    offset: f64,
    dash_on: f64,
    dash_off: f64,
    behind_text: bool,
) !void {
    const thickness = width orelse native_thickness;
    if (!(advance > 0) or !(thickness > 0) or !(opacity > 0)) return;
    const native_center_y = baseline_y - position + native_thickness / 2;
    const center_y = native_center_y + offset;
    try segments.append(allocator, .{
        .start = .{ .x = x, .y = center_y },
        .end = .{ .x = x + advance, .y = center_y },
        .line_width = thickness,
        .color = color,
        .opacity = opacity,
        .dash_on = dash_on,
        .dash_off = dash_off,
        .behind_text = behind_text,
    });
}
