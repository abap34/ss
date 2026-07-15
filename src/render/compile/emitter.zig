const std = @import("std");
const core = @import("core");
const render = @import("render");
const resources_compile = @import("render_resources");
const text = @import("render_text");

const Allocator = std.mem.Allocator;
const Color = core.render_policy.Color;

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
    ) !void {
        const layout = try text.shape(allocator, self.io, self.resources, self.fonts, content, font, font_size, width, wrap);
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

    pub fn mathItem(
        self: *Emitter,
        allocator: Allocator,
        rect: render.Rect,
        source: []const u8,
        input_kind: render.MathInputKind,
        path: []const u8,
        page_index: usize,
    ) !void {
        const tree = try self.math.add(allocator, source, input_kind);
        const resource = try self.resources.addPath(allocator, self.io, .math_pdf, path);
        try self.page.appendMath(allocator, self.node_id, rect, tree, null, .{ .r = 0, .g = 0, .b = 0 }, resource, page_index, .crop);
    }
};
