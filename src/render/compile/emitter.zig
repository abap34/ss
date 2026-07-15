const std = @import("std");
const core = @import("core");
const c = @import("pdf_ffi").c;
const render = @import("render");

const Allocator = std.mem.Allocator;
const Color = core.render_policy.Color;

pub const Emitter = struct {
    page: *render.Page,
    resources: *render.ResourceBuilder,
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
        preserve_color_glyphs: bool,
    ) !void {
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
        const layout = try copyTextLayout(allocator, self.io, self.resources, content, native_shape);
        try self.page.appendTextLayout(
            allocator,
            self.node_id,
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
        try self.page.appendMath(allocator, self.node_id, rect, tree, resource, page_index, .crop);
    }
};

fn copyTextLayout(
    allocator: Allocator,
    io: std.Io,
    resources: *render.ResourceBuilder,
    source: []const u8,
    native: c.SsTextShape,
) !render.TextLayout {
    const owned_source = try allocator.dupeZ(u8, source);
    errdefer allocator.free(owned_source);
    const lines = try allocator.alloc(render.TextLine, native.line_count);
    errdefer allocator.free(lines);
    const runs = try allocator.alloc(render.TextRun, native.run_count);
    var initialized_runs: usize = 0;
    errdefer {
        for (runs[0..initialized_runs]) |*run| {
            allocator.free(run.font_family);
            allocator.free(run.font_postscript_name);
        }
        allocator.free(runs);
    }
    const glyphs = try allocator.alloc(render.Glyph, native.glyph_count);
    errdefer allocator.free(glyphs);
    var clusters = std.ArrayList(render.TextCluster).empty;
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
    output: *std.ArrayList(render.TextCluster),
    run: render.TextRun,
    glyphs: []const render.Glyph,
) !void {
    var visual = std.ArrayList(render.TextCluster).empty;
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
    std.mem.sort(render.TextCluster, visual.items, {}, struct {
        fn lessThan(_: void, lhs: render.TextCluster, rhs: render.TextCluster) bool {
            return lhs.source.start < rhs.source.start;
        }
    }.lessThan);
    try output.appendSlice(allocator, visual.items);
}

fn nativeRect(value: c.SsPdfInkExtents) render.Rect {
    return .{ .x = value.x, .y = value.y, .width = value.width, .height = value.height };
}
