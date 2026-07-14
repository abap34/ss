const std = @import("std");
const core = @import("core");
const c = @import("pdf_ffi.zig").c;
const render_scene = @import("scene.zig");

const Allocator = std.mem.Allocator;
const Color = core.render_policy.Color;

pub const Sink = union(enum) {
    pdf: *c.SsPdf,
    scene: SceneTarget,

    pub const SceneTarget = struct {
        page: *render_scene.Page,
        node_id: ?core.NodeId = null,
    };

    pub fn replaceNodeId(self: *Sink, node_id: ?core.NodeId) ?core.NodeId {
        return switch (self.*) {
            .pdf => null,
            .scene => |*target| blk: {
                const previous = target.node_id;
                target.node_id = node_id;
                break :blk previous;
            },
        };
    }

    pub fn isScene(self: Sink) bool {
        return self == .scene;
    }

    pub fn fillRect(self: *Sink, allocator: Allocator, rect: render_scene.Rect, color: Color) !void {
        switch (self.*) {
            .pdf => |pdf| c.ss_pdf_fill_rect(pdf, rect.x, rect.y, rect.width, rect.height, color.r, color.g, color.b),
            .scene => |target| try target.page.appendFillRect(allocator, target.node_id, rect, color),
        }
    }

    pub fn strokeLine(
        self: *Sink,
        allocator: Allocator,
        start: render_scene.Point,
        end: render_scene.Point,
        line_width: f32,
        color: Color,
        dash_on: f32,
        dash_off: f32,
    ) !void {
        switch (self.*) {
            .pdf => |pdf| c.ss_pdf_stroke_line(
                pdf,
                start.x,
                start.y,
                end.x,
                end.y,
                line_width,
                color.r,
                color.g,
                color.b,
                dash_on,
                dash_off,
            ),
            .scene => |target| try target.page.appendStrokeLine(
                allocator,
                target.node_id,
                start,
                end,
                line_width,
                color,
                dash_on,
                dash_off,
            ),
        }
    }

    pub fn roundedRect(
        self: *Sink,
        allocator: Allocator,
        rect: render_scene.Rect,
        radius: f32,
        fill: ?Color,
        stroke: ?Color,
        line_width: f32,
    ) !void {
        switch (self.*) {
            .pdf => |pdf| c.ss_pdf_fill_stroke_rounded_rect(
                pdf,
                rect.x,
                rect.y,
                rect.width,
                rect.height,
                radius,
                if (fill != null) 1 else 0,
                if (fill) |value| value.r else 0,
                if (fill) |value| value.g else 0,
                if (fill) |value| value.b else 0,
                if (stroke != null) 1 else 0,
                if (stroke) |value| value.r else 0,
                if (stroke) |value| value.g else 0,
                if (stroke) |value| value.b else 0,
                line_width,
            ),
            .scene => |target| try target.page.appendRoundedRect(
                allocator,
                target.node_id,
                rect,
                radius,
                fill,
                stroke,
                line_width,
            ),
        }
    }

    pub fn textBaseline(
        self: *Sink,
        allocator: Allocator,
        x: f32,
        baseline_y: f32,
        width: f32,
        content: []const u8,
        font: core.font.Face,
        font_size: f32,
        color: Color,
        wrap: bool,
        preserve_color_glyphs: bool,
    ) !void {
        switch (self.*) {
            .pdf => |pdf| {
                const family_z = try allocator.dupeZ(u8, font.family);
                defer allocator.free(family_z);
                const content_z = try allocator.dupeZ(u8, content);
                defer allocator.free(content_z);
                try drawTextBaselineZ(
                    pdf,
                    x,
                    baseline_y,
                    width,
                    content_z,
                    family_z,
                    font.weight,
                    font.style,
                    font.stretch,
                    font_size,
                    color,
                    wrap,
                    preserve_color_glyphs,
                );
            },
            .scene => |target| try target.page.appendText(
                allocator,
                target.node_id,
                x,
                baseline_y,
                width,
                content,
                font,
                font_size,
                color,
                wrap,
                preserve_color_glyphs,
            ),
        }
    }

    pub fn raster(self: *Sink, allocator: Allocator, rect: render_scene.Rect, path: []const u8) !void {
        switch (self.*) {
            .pdf => |pdf| {
                const path_z = try allocator.dupeZ(u8, path);
                defer allocator.free(path_z);
                try drawRasterZ(pdf, rect, path_z);
            },
            .scene => |target| try target.page.appendRaster(allocator, target.node_id, rect, path),
        }
    }

    pub fn svg(self: *Sink, allocator: Allocator, rect: render_scene.Rect, path: []const u8, tint: ?Color) !void {
        switch (self.*) {
            .pdf => |pdf| {
                const path_z = try allocator.dupeZ(u8, path);
                defer allocator.free(path_z);
                try drawSvgZ(pdf, rect, path_z, tint);
            },
            .scene => |target| try target.page.appendSvg(allocator, target.node_id, rect, path, tint),
        }
    }

    pub fn pdfPage(
        self: *Sink,
        allocator: Allocator,
        rect: render_scene.Rect,
        path: []const u8,
        page_index: usize,
        box: core.render_policy.PdfPageBox,
        copy_annotations: bool,
    ) !void {
        switch (self.*) {
            .pdf => return error.UnsupportedAssetType,
            .scene => |target| try target.page.appendPdfPage(
                allocator,
                target.node_id,
                rect,
                path,
                page_index,
                box,
                copy_annotations,
            ),
        }
    }

    pub fn replayItem(self: *Sink, item: render_scene.Item) !void {
        const pdf = switch (self.*) {
            .pdf => |value| value,
            .scene => return error.UnsupportedAssetType,
        };
        switch (item) {
            .fill_rect => |fill| c.ss_pdf_fill_rect(
                pdf,
                fill.rect.x,
                fill.rect.y,
                fill.rect.width,
                fill.rect.height,
                fill.color.r,
                fill.color.g,
                fill.color.b,
            ),
            .stroke_line => |line| c.ss_pdf_stroke_line(
                pdf,
                line.start.x,
                line.start.y,
                line.end.x,
                line.end.y,
                line.line_width,
                line.color.r,
                line.color.g,
                line.color.b,
                line.dash_on,
                line.dash_off,
            ),
            .rounded_rect => |rect| c.ss_pdf_fill_stroke_rounded_rect(
                pdf,
                rect.rect.x,
                rect.rect.y,
                rect.rect.width,
                rect.rect.height,
                rect.radius,
                if (rect.fill != null) 1 else 0,
                if (rect.fill) |color| color.r else 0,
                if (rect.fill) |color| color.g else 0,
                if (rect.fill) |color| color.b else 0,
                if (rect.stroke != null) 1 else 0,
                if (rect.stroke) |color| color.r else 0,
                if (rect.stroke) |color| color.g else 0,
                if (rect.stroke) |color| color.b else 0,
                rect.line_width,
            ),
            .text => |text| try drawTextBaselineZ(
                pdf,
                text.x,
                text.baseline_y,
                text.width,
                text.text,
                text.font_family,
                text.font_weight,
                text.font_style,
                text.font_stretch,
                text.font_size,
                text.color,
                text.wrap,
                text.preserve_color_glyphs,
            ),
            .raster => |image| try drawRasterZ(pdf, image.rect, image.path),
            .svg => |image| try drawSvgZ(pdf, image.rect, image.path, image.tint),
            .pdf_page => return error.UnsupportedAssetType,
        }
    }
};

fn drawTextBaselineZ(
    pdf: *c.SsPdf,
    x: f32,
    baseline_y: f32,
    width: f32,
    content: [:0]const u8,
    font_family: [:0]const u8,
    font_weight: u16,
    font_style: core.font.Style,
    font_stretch: core.font.Stretch,
    font_size: f32,
    color: Color,
    wrap: bool,
    preserve_color_glyphs: bool,
) !void {
    const result = if (preserve_color_glyphs)
        c.ss_pdf_draw_color_text_baseline(
            pdf,
            x,
            baseline_y,
            width,
            content.ptr,
            font_family.ptr,
            @intCast(font_weight),
            core.font.styleCode(font_style),
            core.font.stretchCode(font_stretch),
            font_size,
            color.r,
            color.g,
            color.b,
            if (wrap) 1 else 0,
        )
    else
        c.ss_pdf_draw_text_baseline(
            pdf,
            x,
            baseline_y,
            width,
            content.ptr,
            font_family.ptr,
            @intCast(font_weight),
            core.font.styleCode(font_style),
            core.font.stretchCode(font_stretch),
            font_size,
            color.r,
            color.g,
            color.b,
            if (wrap) 1 else 0,
        );
    if (result != 0) return error.PangoCreateFailed;
}

fn drawRasterZ(pdf: *c.SsPdf, rect: render_scene.Rect, path: [:0]const u8) !void {
    if (c.ss_pdf_draw_raster(pdf, path.ptr, rect.x, rect.y, rect.width, rect.height) != 0) {
        return error.ImageDecodeFailed;
    }
}

fn drawSvgZ(pdf: *c.SsPdf, rect: render_scene.Rect, path: [:0]const u8, tint: ?Color) !void {
    const result = if (tint) |color|
        c.ss_pdf_draw_svg_tinted(pdf, path.ptr, rect.x, rect.y, rect.width, rect.height, color.r, color.g, color.b)
    else
        c.ss_pdf_draw_svg(pdf, path.ptr, rect.x, rect.y, rect.width, rect.height);
    if (result != 0) return error.ImageDecodeFailed;
}
