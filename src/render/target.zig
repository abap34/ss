const std = @import("std");
const core = @import("core");
const c = @import("pdf_ffi").c;
const render_ir = @import("render");

const Allocator = std.mem.Allocator;
const Color = core.render_policy.Color;

pub const ResourceResolver = struct {
    context: *const anyopaque,
    resolveFn: *const fn (*const anyopaque, render_ir.ResourceId, render_ir.ResourceKind) anyerror![:0]const u8,

    pub fn resolve(self: ResourceResolver, id: render_ir.ResourceId, kind: render_ir.ResourceKind) ![:0]const u8 {
        return try self.resolveFn(self.context, id, kind);
    }
};

pub const Target = union(enum) {
    pdf: *c.SsPdf,
    ir: IrTarget,

    pub const IrTarget = struct {
        page: *render_ir.Page,
        resources: *render_ir.ResourceBuilder,
        math: *render_ir.MathBuilder,
        io: std.Io,
        node_id: ?core.NodeId = null,
    };

    pub fn replaceNodeId(self: *Target, node_id: ?core.NodeId) ?core.NodeId {
        return switch (self.*) {
            .pdf => null,
            .ir => |*target| blk: {
                const previous = target.node_id;
                target.node_id = node_id;
                break :blk previous;
            },
        };
    }

    pub fn recordsIr(self: Target) bool {
        return self == .ir;
    }

    pub fn fillRect(self: *Target, allocator: Allocator, rect: render_ir.Rect, color: Color) !void {
        switch (self.*) {
            .pdf => |pdf| c.ss_pdf_fill_rect(pdf, rect.x, rect.y, rect.width, rect.height, color.r, color.g, color.b),
            .ir => |target| try target.page.appendFillRect(allocator, target.node_id, rect, color),
        }
    }

    pub fn strokeLine(
        self: *Target,
        allocator: Allocator,
        start: render_ir.Point,
        end: render_ir.Point,
        line_width: f64,
        color: Color,
        dash_on: f64,
        dash_off: f64,
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
            .ir => |target| try target.page.appendStrokeLine(
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
        self: *Target,
        allocator: Allocator,
        rect: render_ir.Rect,
        radius: f64,
        fill: ?Color,
        stroke: ?Color,
        line_width: f64,
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
            .ir => |target| try target.page.appendRoundedRect(
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
        self: *Target,
        allocator: Allocator,
        x: f64,
        baseline_y: f64,
        width: f64,
        content: []const u8,
        font: core.font.Face,
        font_size: f64,
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
            .ir => |target| {
                const family_z = try allocator.dupeZ(u8, font.family);
                defer allocator.free(family_z);
                const content_z = try allocator.dupeZ(u8, content);
                defer allocator.free(content_z);
                var native_shape = std.mem.zeroes(c.SsTextShape);
                if (c.ss_text_shape(
                    content_z.ptr,
                    family_z.ptr,
                    @intCast(font.weight),
                    core.font.styleCode(font.style),
                    core.font.stretchCode(font.stretch),
                    font_size,
                    width,
                    if (wrap) 1 else 0,
                    &native_shape,
                ) != 0) return error.PangoCreateFailed;
                defer c.ss_text_shape_free(&native_shape);
                const layout = try copyTextLayout(allocator, target.io, target.resources, content, native_shape);
                try target.page.appendTextLayout(
                    allocator,
                    target.node_id,
                    x,
                    baseline_y,
                    width,
                    layout,
                    font,
                    font_size,
                    color,
                    wrap,
                    preserve_color_glyphs,
                );
            },
        }
    }

    pub fn raster(self: *Target, allocator: Allocator, rect: render_ir.Rect, path: []const u8) !void {
        switch (self.*) {
            .pdf => |pdf| {
                const path_z = try allocator.dupeZ(u8, path);
                defer allocator.free(path_z);
                try drawRasterZ(pdf, rect, path_z);
            },
            .ir => |target| {
                const resource = try target.resources.addPath(allocator, target.io, .raster, path);
                try target.page.appendRaster(allocator, target.node_id, rect, resource);
            },
        }
    }

    pub fn svg(self: *Target, allocator: Allocator, rect: render_ir.Rect, path: []const u8, tint: ?Color) !void {
        switch (self.*) {
            .pdf => |pdf| {
                const path_z = try allocator.dupeZ(u8, path);
                defer allocator.free(path_z);
                try drawSvgZ(pdf, rect, path_z, tint);
            },
            .ir => |target| {
                const resource = try target.resources.addPath(allocator, target.io, .svg, path);
                try target.page.appendSvg(allocator, target.node_id, rect, resource, tint);
            },
        }
    }

    pub fn pdfPage(
        self: *Target,
        allocator: Allocator,
        rect: render_ir.Rect,
        path: []const u8,
        page_index: usize,
        box: core.render_policy.PdfPageBox,
        copy_annotations: bool,
    ) !void {
        switch (self.*) {
            .pdf => return error.UnsupportedAssetType,
            .ir => |target| {
                const resource = try target.resources.addPath(allocator, target.io, .pdf, path);
                try target.page.appendPdfPage(
                    allocator,
                    target.node_id,
                    rect,
                    resource,
                    page_index,
                    box,
                    copy_annotations,
                );
            },
        }
    }

    pub fn math(
        self: *Target,
        allocator: Allocator,
        rect: render_ir.Rect,
        source: []const u8,
        input_kind: render_ir.MathInputKind,
        path: []const u8,
        page_index: usize,
    ) !void {
        switch (self.*) {
            .pdf => return error.UnsupportedAssetType,
            .ir => |target| {
                const tree = try target.math.add(allocator, source, input_kind);
                const resource = try target.resources.addPath(allocator, target.io, .math_pdf, path);
                try target.page.appendMath(allocator, target.node_id, rect, tree, resource, page_index, .crop);
            },
        }
    }

    pub fn replayItem(self: *Target, item: render_ir.Item, resources: ResourceResolver) !void {
        const pdf = switch (self.*) {
            .pdf => |value| value,
            .ir => return error.UnsupportedAssetType,
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
                text.baselineY(),
                text.width,
                text.layout.source_text,
                if (text.layout.runs.len == 0) return error.PangoCreateFailed else text.layout.runs[0].font_family,
                text.font_weight,
                text.font_style,
                text.font_stretch,
                text.font_size,
                text.color,
                text.wrap,
                text.preserve_color_glyphs,
            ),
            .raster => |image| try drawRasterZ(pdf, image.rect, try resources.resolve(image.resource, .raster)),
            .svg => |image| try drawSvgZ(pdf, image.rect, try resources.resolve(image.resource, .svg), image.tint),
            .math => return error.UnsupportedAssetType,
            .pdf_page => return error.UnsupportedAssetType,
        }
    }
};

fn drawTextBaselineZ(
    pdf: *c.SsPdf,
    x: f64,
    baseline_y: f64,
    width: f64,
    content: [:0]const u8,
    font_family: [:0]const u8,
    font_weight: u16,
    font_style: core.font.Style,
    font_stretch: core.font.Stretch,
    font_size: f64,
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

fn copyTextLayout(
    allocator: Allocator,
    io: std.Io,
    resources: *render_ir.ResourceBuilder,
    source: []const u8,
    native: c.SsTextShape,
) !render_ir.TextLayout {
    const owned_source = try allocator.dupeZ(u8, source);
    errdefer allocator.free(owned_source);
    const lines = try allocator.alloc(render_ir.TextLine, native.line_count);
    errdefer allocator.free(lines);
    const runs = try allocator.alloc(render_ir.TextRun, native.run_count);
    var initialized_runs: usize = 0;
    errdefer {
        for (runs[0..initialized_runs]) |*run| {
            allocator.free(run.font_family);
            allocator.free(run.font_postscript_name);
        }
        allocator.free(runs);
    }
    const glyphs = try allocator.alloc(render_ir.Glyph, native.glyph_count);
    errdefer allocator.free(glyphs);
    var clusters = std.ArrayList(render_ir.TextCluster).empty;
    errdefer clusters.deinit(allocator);

    for (native.lines[0..native.line_count], 0..) |line, index| lines[index] = .{
        .source = .{ .start = @intCast(line.source_start), .end = @intCast(line.source_end) },
        .run_range = .{ .start = @intCast(line.run_start), .end = @intCast(line.run_start + line.run_count) },
        .baseline_y = line.baseline_y,
        .logical_bounds = nativeRect(line.logical_bounds),
        .ink_bounds = nativeRect(line.ink_bounds),
    };
    for (native.runs[0..native.run_count], 0..) |run, index| {
        const family = try allocator.dupeZ(u8, std.mem.span(run.font_family));
        errdefer allocator.free(family);
        const postscript_name = try allocator.dupeZ(u8, std.mem.span(run.font_postscript_name));
        errdefer allocator.free(postscript_name);
        const font_path = std.mem.span(run.font_path);
        const font_resource = if (font_path.len == 0)
            null
        else
            try resources.addPath(allocator, io, .font, font_path);
        runs[index] = .{
            .source = .{ .start = @intCast(run.source_start), .end = @intCast(run.source_end) },
            .glyph_range = .{ .start = @intCast(run.glyph_start), .end = @intCast(run.glyph_start + run.glyph_count) },
            .cluster_range = .{ .start = 0, .end = 0 },
            .x = run.x,
            .baseline_y = run.baseline_y,
            .advance = run.advance,
            .font_family = family,
            .font_resource = font_resource,
            .font_index = @intCast(run.font_index),
            .font_postscript_name = postscript_name,
        };
        initialized_runs += 1;
    }
    for (native.glyphs[0..native.glyph_count], 0..) |glyph, index| glyphs[index] = .{
        .id = glyph.id,
        .source_index = glyph.source_index,
        .offset_x = glyph.offset_x,
        .offset_y = glyph.offset_y,
        .advance_x = glyph.advance_x,
        .advance_y = glyph.advance_y,
    };
    for (runs) |*run| {
        run.cluster_range.start = @intCast(clusters.items.len);
        try appendClusters(allocator, &clusters, run.*, glyphs);
        run.cluster_range.end = @intCast(clusters.items.len);
    }
    return .{
        .source_text = owned_source,
        .lines = lines,
        .runs = runs,
        .clusters = try clusters.toOwnedSlice(allocator),
        .glyphs = glyphs,
        .logical_bounds = nativeRect(native.logical_bounds),
        .ink_bounds = nativeRect(native.ink_bounds),
    };
}

fn appendClusters(
    allocator: Allocator,
    output: *std.ArrayList(render_ir.TextCluster),
    run: render_ir.TextRun,
    glyphs: []const render_ir.Glyph,
) !void {
    var visual = std.ArrayList(render_ir.TextCluster).empty;
    defer visual.deinit(allocator);
    var glyph_index: usize = run.glyph_range.start;
    var x: f64 = 0;
    while (glyph_index < run.glyph_range.end) {
        const start = glyph_index;
        const source_start = glyphs[glyph_index].source_index;
        var advance: f64 = 0;
        while (glyph_index < run.glyph_range.end and glyphs[glyph_index].source_index == source_start) : (glyph_index += 1) {
            advance += glyphs[glyph_index].advance_x;
        }
        try visual.append(allocator, .{
            .source = .{ .start = source_start, .end = run.source.end },
            .glyph_range = .{ .start = @intCast(start), .end = @intCast(glyph_index) },
            .x = x,
            .advance = advance,
        });
        x += advance;
    }
    for (visual.items) |*cluster| {
        for (visual.items) |candidate| {
            if (candidate.source.start > cluster.source.start and candidate.source.start < cluster.source.end) {
                cluster.source.end = candidate.source.start;
            }
        }
    }
    std.mem.sort(render_ir.TextCluster, visual.items, {}, struct {
        fn lessThan(_: void, lhs: render_ir.TextCluster, rhs: render_ir.TextCluster) bool {
            return lhs.source.start < rhs.source.start;
        }
    }.lessThan);
    try output.appendSlice(allocator, visual.items);
}

fn nativeRect(value: c.SsPdfInkExtents) render_ir.Rect {
    return .{ .x = value.x, .y = value.y, .width = value.width, .height = value.height };
}

fn drawRasterZ(pdf: *c.SsPdf, rect: render_ir.Rect, path: [:0]const u8) !void {
    if (c.ss_pdf_draw_raster(pdf, path.ptr, rect.x, rect.y, rect.width, rect.height) != 0) {
        return error.ImageDecodeFailed;
    }
}

fn drawSvgZ(pdf: *c.SsPdf, rect: render_ir.Rect, path: [:0]const u8, tint: ?Color) !void {
    const result = if (tint) |color|
        c.ss_pdf_draw_svg_tinted(pdf, path.ptr, rect.x, rect.y, rect.width, rect.height, color.r, color.g, color.b)
    else
        c.ss_pdf_draw_svg(pdf, path.ptr, rect.x, rect.y, rect.width, rect.height);
    if (result != 0) return error.ImageDecodeFailed;
}
