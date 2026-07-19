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
};

const DecorationSegment = struct {
    start: render.Point,
    end: render.Point,
    line_width: f64,
};

pub const Emitter = struct {
    page: *render.Page,
    resources: *resources_compile.Builder,
    fonts: *render.FontBuilder,
    math: *render.MathBuilder,
    io: std.Io,
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
        var layout = try text.shape(allocator, self.io, self.resources, self.fonts, content, font, font_size, width, wrap);
        var owns_layout = true;
        errdefer if (owns_layout) layout.deinit(allocator);
        var segments = std.ArrayList(DecorationSegment).empty;
        defer segments.deinit(allocator);
        const layout_y = baseline_y - layout.firstBaseline();
        if (decoration.strikethrough or decoration.underline) {
            for (layout.runs) |run| {
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
                );
                if (decoration.underline) try appendDecorationSegment(
                    allocator,
                    &segments,
                    x + run.x,
                    run_baseline,
                    run.advance,
                    font_size * instance.underline_position_ratio,
                    font_size * instance.underline_thickness_ratio,
                );
            }
        }
        try self.page.appendTextLayout(
            allocator,
            self.node_id,
            x,
            baseline_y,
            width,
            layout,
            font_size,
            color,
        );
        owns_layout = false;
        for (segments.items) |segment| try self.page.appendStrokeLine(
            allocator,
            self.node_id,
            segment.start,
            segment.end,
            segment.line_width,
            color,
            0,
            0,
        );
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
    thickness: f64,
) !void {
    const center_y = baseline_y - position + thickness / 2;
    try segments.append(allocator, .{
        .start = .{ .x = x, .y = center_y },
        .end = .{ .x = x + advance, .y = center_y },
        .line_width = thickness,
    });
}
