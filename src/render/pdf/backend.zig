const std = @import("std");
const core = @import("core");
const c = @import("pdf_ffi").c;
const render_ir = @import("render");

const Allocator = std.mem.Allocator;
var materialization_counter: usize = 0;

pub fn render(
    allocator: Allocator,
    io: std.Io,
    ir: *const render_ir.Ir,
    page_index: usize,
    output: []const u8,
    resources: *const ResourceFiles,
) !void {
    c.ss_pdf_clear_last_error();
    if (page_index >= ir.pages.len) return error.InvalidPageIndex;
    const page = &ir.pages[page_index];
    errdefer deleteFileIfExists(io, output);
    if (page.hasPdfPages()) {
        try renderComposed(allocator, io, ir, page, output, resources);
    } else {
        try renderCairo(allocator, ir, page, output, resources);
    }
}

fn renderCairo(
    allocator: Allocator,
    ir: *const render_ir.Ir,
    page: *const render_ir.Page,
    output: []const u8,
    resources: *const ResourceFiles,
) !void {
    const output_z = try allocator.dupeZ(u8, output);
    defer allocator.free(output_z);
    const pdf = c.ss_pdf_create(output_z.ptr, page.width, page.height) orelse return cairoCreateFailure();
    defer c.ss_pdf_destroy(pdf);
    c.ss_pdf_set_creator(pdf, "ss page Cairo/Pango backend");
    c.ss_pdf_begin_page(pdf, page.width, page.height);
    try replayItems(allocator, pdf, ir, page.items.items, resources);
    try emitAnnotations(pdf, page);
    c.ss_pdf_end_page(pdf);
    if (c.ss_pdf_finish(pdf) != 0) return cairoFailure(pdf);
}

fn renderComposed(
    allocator: Allocator,
    io: std.Io,
    ir: *const render_ir.Ir,
    page: *const render_ir.Page,
    output: []const u8,
    resources: *const ResourceFiles,
) !void {
    var plan = std.ArrayList(CompositionStep).empty;
    defer plan.deinit(allocator);

    var segment_start: usize = 0;
    var first_native_layer = true;
    for (page.items.items, 0..) |item, item_index| {
        if (!isExternalPdfItem(item)) continue;
        if (segment_start < item_index or first_native_layer) {
            try plan.append(allocator, .{ .native = .{
                .start = segment_start,
                .end = item_index,
                .first_layer = first_native_layer,
            } });
            first_native_layer = false;
        }
        try plan.append(allocator, .{ .external = item_index });
        segment_start = item_index + 1;
    }
    if (segment_start < page.items.items.len) {
        try plan.append(allocator, .{ .native = .{
            .start = segment_start,
            .end = page.items.items.len,
            .first_layer = first_native_layer,
        } });
    }

    var composition = Composition.init(allocator, io, ir, page, output, resources);
    defer composition.deinit();
    try composition.prepareNativeLayers(plan.items);

    var native_page_index: usize = 0;
    for (plan.items) |step| switch (step) {
        .native => {
            try composition.appendNativeLayer(native_page_index);
            native_page_index += 1;
        },
        .external => |item_index| switch (page.items.items[item_index]) {
            .pdf_page => |value| try composition.appendPdfLayer(value),
            .latex => |value| try composition.appendLatexLayer(value),
            else => unreachable,
        },
    };
    if (native_page_index == 0) {
        return error.InvalidRenderComposition;
    }
    try composition.write();
}

const NativeSegment = struct {
    start: usize,
    end: usize,
    first_layer: bool,
};

const CompositionStep = union(enum) {
    native: NativeSegment,
    external: usize,
};

fn isExternalPdfItem(item: render_ir.Item) bool {
    return switch (item) {
        .pdf_page => true,
        .latex => true,
        else => false,
    };
}

const Composition = struct {
    allocator: Allocator,
    io: std.Io,
    ir: *const render_ir.Ir,
    page: *const render_ir.Page,
    output: []const u8,
    resources: *const ResourceFiles,
    layers: std.ArrayList(c.SsQpdfLayer) = .empty,
    native_path: ?[]u8 = null,
    native_path_z: ?[:0]u8 = null,

    fn init(
        allocator: Allocator,
        io: std.Io,
        ir: *const render_ir.Ir,
        page: *const render_ir.Page,
        output: []const u8,
        resources: *const ResourceFiles,
    ) Composition {
        return .{
            .allocator = allocator,
            .io = io,
            .ir = ir,
            .page = page,
            .output = output,
            .resources = resources,
        };
    }

    fn deinit(self: *Composition) void {
        if (self.native_path) |path| {
            deleteFileIfExists(self.io, path);
            self.allocator.free(path);
        }
        if (self.native_path_z) |path| self.allocator.free(path);
        self.layers.deinit(self.allocator);
    }

    fn prepareNativeLayers(self: *Composition, plan: []const CompositionStep) !void {
        std.debug.assert(self.native_path == null);
        std.debug.assert(self.native_path_z == null);
        const native_path = try layerPath(self.allocator, self.output, 0);
        errdefer self.allocator.free(native_path);
        errdefer deleteFileIfExists(self.io, native_path);
        try renderNativeLayers(self.allocator, self.ir, self.page, native_path, plan, self.resources);

        const native_path_z = try self.allocator.dupeZ(u8, native_path);
        self.native_path = native_path;
        self.native_path_z = native_path_z;
    }

    fn appendNativeLayer(self: *Composition, page_index: usize) !void {
        const native_path = self.native_path_z orelse return error.MissingNativeLayer;
        try self.layers.append(self.allocator, .{
            .path = native_path.ptr,
            .page_index = page_index,
            .box = @intFromEnum(core.render_policy.PdfPageBox.crop),
            .x = 0,
            .y = 0,
            .width = self.page.width,
            .height = self.page.height,
            .copy_annotations = 0,
            .effects = identityLayerEffects(),
        });
    }

    fn appendPdfLayer(self: *Composition, item: render_ir.PdfPage) !void {
        const path = try self.resources.resolve(item.resource, .pdf);
        try self.layers.append(self.allocator, .{
            .path = path.ptr,
            .page_index = item.page_index,
            .box = @intFromEnum(item.box),
            .x = item.rect.x,
            .y = self.page.height - item.rect.y - item.rect.height,
            .width = item.rect.width,
            .height = item.rect.height,
            .copy_annotations = if (item.copy_annotations) 1 else 0,
            .effects = layerEffects(item.header, self.page.height),
        });
    }

    fn appendLatexLayer(self: *Composition, item: render_ir.Latex) !void {
        const path = try self.resources.resolve(item.resource, .latex_pdf);
        try self.layers.append(self.allocator, .{
            .path = path.ptr,
            .page_index = item.page_index,
            .box = @intFromEnum(item.box),
            .x = item.rect.x,
            .y = self.page.height - item.rect.y - item.rect.height,
            .width = item.rect.width,
            .height = item.rect.height,
            .copy_annotations = 0,
            .effects = layerEffects(item.header, self.page.height),
        });
    }

    fn write(self: *Composition) !void {
        const output_z = try self.allocator.dupeZ(u8, self.output);
        defer self.allocator.free(output_z);
        if (c.ss_qpdf_compose(output_z.ptr, self.layers.items.ptr, self.layers.items.len) != 0) {
            return error.AssetConversionFailed;
        }
    }
};

fn identityLayerEffects() c.SsLayerEffects {
    return .{
        .xx = 1,
        .yx = 0,
        .xy = 0,
        .yy = 1,
        .x0 = 0,
        .y0 = 0,
        .has_clip = 0,
        .clip_x = 0,
        .clip_y = 0,
        .clip_width = 0,
        .clip_height = 0,
        .opacity = 1,
        .blend_mode = 0,
    };
}

fn layerEffects(header: render_ir.ItemHeader, page_height: f64) c.SsLayerEffects {
    const transform = header.transform;
    var effects = identityLayerEffects();
    effects.xx = transform.xx;
    effects.yx = -transform.yx;
    effects.xy = -transform.xy;
    effects.yy = transform.yy;
    effects.x0 = transform.xy * page_height + transform.x0;
    effects.y0 = page_height * (1 - transform.yy) - transform.y0;
    effects.opacity = header.opacity;
    effects.blend_mode = @intFromEnum(header.blend_mode);
    if (header.clip) |value| switch (value) {
        .rect => |rect| {
            effects.has_clip = 1;
            effects.clip_x = rect.x;
            effects.clip_y = page_height - rect.y - rect.height;
            effects.clip_width = rect.width;
            effects.clip_height = rect.height;
        },
    };
    return effects;
}

fn renderNativeLayers(
    allocator: Allocator,
    ir: *const render_ir.Ir,
    page: *const render_ir.Page,
    path: []const u8,
    plan: []const CompositionStep,
    resources: *const ResourceFiles,
) !void {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const pdf = c.ss_pdf_create(path_z.ptr, page.width, page.height) orelse return cairoCreateFailure();
    defer c.ss_pdf_destroy(pdf);
    c.ss_pdf_set_creator(pdf, "ss page Cairo/Pango/libqpdf backend");
    var rendered_pages: usize = 0;
    for (plan) |step| switch (step) {
        .native => |segment| {
            c.ss_pdf_begin_page(pdf, page.width, page.height);
            if (segment.first_layer) try emitAnnotations(pdf, page);
            try replayItems(allocator, pdf, ir, page.items.items[segment.start..segment.end], resources);
            c.ss_pdf_end_page(pdf);
            rendered_pages += 1;
        },
        .external => {},
    };
    if (rendered_pages == 0) return error.MissingNativeLayer;
    if (c.ss_pdf_finish(pdf) != 0) return cairoFailure(pdf);
}

fn replayItems(
    allocator: Allocator,
    pdf: *c.SsPdf,
    ir: *const render_ir.Ir,
    items: []const render_ir.Item,
    resources: *const ResourceFiles,
) !void {
    for (items) |item| {
        const header = item.header();
        const effects = itemEffects(header);
        if (c.ss_pdf_begin_item(pdf, &effects) != 0) return cairoFailure(pdf);
        replayItem(allocator, pdf, ir, item, resources) catch |err| {
            _ = c.ss_pdf_end_item(pdf);
            return err;
        };
        if (c.ss_pdf_end_item(pdf) != 0) return cairoFailure(pdf);
    }
}

fn replayItem(
    allocator: Allocator,
    pdf: *c.SsPdf,
    ir: *const render_ir.Ir,
    item: render_ir.Item,
    resources: *const ResourceFiles,
) !void {
    switch (item) {
        .fill_rect => |value| c.ss_pdf_fill_rect(
            pdf,
            value.rect.x,
            value.rect.y,
            value.rect.width,
            value.rect.height,
            value.color.r,
            value.color.g,
            value.color.b,
        ),
        .stroke_line => |value| c.ss_pdf_stroke_line(
            pdf,
            value.start.x,
            value.start.y,
            value.end.x,
            value.end.y,
            value.line_width,
            value.color.r,
            value.color.g,
            value.color.b,
            value.dash_on,
            value.dash_off,
        ),
        .vector_path => |value| try replayVectorPath(allocator, pdf, value),
        .rounded_rect => |value| c.ss_pdf_fill_stroke_rounded_rect(
            pdf,
            value.rect.x,
            value.rect.y,
            value.rect.width,
            value.rect.height,
            value.radius,
            @intFromBool(value.fill != null),
            if (value.fill) |color| color.r else 0,
            if (value.fill) |color| color.g else 0,
            if (value.fill) |color| color.b else 0,
            @intFromBool(value.stroke != null),
            if (value.stroke) |color| color.r else 0,
            if (value.stroke) |color| color.g else 0,
            if (value.stroke) |color| color.b else 0,
            value.line_width,
        ),
        .text => |value| try replayText(allocator, pdf, ir, value, resources),
        .raster => |value| {
            const path = try resources.resolve(value.resource, .raster);
            if (c.ss_pdf_draw_raster(pdf, path.ptr, value.rect.x, value.rect.y, value.rect.width, value.rect.height) != 0) {
                return imageFailure(pdf);
            }
        },
        .svg => |value| {
            const path = try resources.resolve(value.resource, .svg);
            const result = if (value.tint) |color|
                c.ss_pdf_draw_svg_tinted(pdf, path.ptr, value.rect.x, value.rect.y, value.rect.width, value.rect.height, color.r, color.g, color.b)
            else
                c.ss_pdf_draw_svg(pdf, path.ptr, value.rect.x, value.rect.y, value.rect.width, value.rect.height);
            if (result != 0) return imageFailure(pdf);
        },
        .latex => return error.UnsupportedAssetType,
        .pdf_page => return error.UnsupportedAssetType,
    }
}

fn replayVectorPath(allocator: Allocator, pdf: *c.SsPdf, value: render_ir.VectorPath) !void {
    switch (value.fill.base) {
        .none => {},
        .solid => |color| {
            appendPdfPath(pdf, value.commands, .{}, 0, 0);
            c.ss_pdf_path_fill_solid(pdf, color.r, color.g, color.b, value.fill.opacity, @intFromEnum(value.fill.rule));
        },
        .linear => |gradient| {
            const arrays = try gradientArrays(allocator, gradient.stops);
            defer arrays.deinit(allocator);
            appendPdfPath(pdf, value.commands, .{}, 0, 0);
            c.ss_pdf_path_fill_linear(
                pdf,
                gradient.start.x,
                gradient.start.y,
                gradient.end.x,
                gradient.end.y,
                arrays.offsets.ptr,
                arrays.colors.ptr,
                gradient.stops.len,
                @intFromEnum(gradient.spread),
                value.fill.opacity,
                @intFromEnum(value.fill.rule),
            );
        },
        .radial => |gradient| {
            const arrays = try gradientArrays(allocator, gradient.stops);
            defer arrays.deinit(allocator);
            appendPdfPath(pdf, value.commands, .{}, 0, 0);
            c.ss_pdf_path_fill_radial(
                pdf,
                gradient.start_center.x,
                gradient.start_center.y,
                gradient.start_radius,
                gradient.end_center.x,
                gradient.end_center.y,
                gradient.end_radius,
                arrays.offsets.ptr,
                arrays.colors.ptr,
                gradient.stops.len,
                @intFromEnum(gradient.spread),
                value.fill.opacity,
                @intFromEnum(value.fill.rule),
            );
        },
    }
    if (value.fill.overlay) |pattern| try replayTilePattern(pdf, value, pattern);
    if (value.stroke) |stroke| {
        appendPdfPath(pdf, value.commands, .{}, 0, 0);
        strokePdfPath(pdf, stroke, 1);
    }
}

const GradientArrays = struct {
    offsets: []f64,
    colors: []f64,

    fn deinit(self: GradientArrays, allocator: Allocator) void {
        allocator.free(self.offsets);
        allocator.free(self.colors);
    }
};

fn gradientArrays(allocator: Allocator, stops: []const render_ir.GradientStop) !GradientArrays {
    const offsets = try allocator.alloc(f64, stops.len);
    errdefer allocator.free(offsets);
    const colors = try allocator.alloc(f64, stops.len * 3);
    errdefer allocator.free(colors);
    for (stops, 0..) |stop, index| {
        offsets[index] = stop.offset;
        colors[index * 3] = stop.color.r;
        colors[index * 3 + 1] = stop.color.g;
        colors[index * 3 + 2] = stop.color.b;
    }
    return .{ .offsets = offsets, .colors = colors };
}

fn replayTilePattern(pdf: *c.SsPdf, value: render_ir.VectorPath, pattern: render_ir.TilePatternPaint) !void {
    c.ss_pdf_state_save(pdf);
    defer c.ss_pdf_state_restore(pdf);
    appendPdfPath(pdf, value.commands, .{}, 0, 0);
    c.ss_pdf_path_clip(pdf, @intFromEnum(value.fill.rule));

    const bounds = try inverseTransformBounds(value.header.bounds, pattern.transform);
    const first_x = @floor(bounds.x / pattern.cell_width) * pattern.cell_width - pattern.cell_width;
    const first_y = @floor(bounds.y / pattern.cell_height) * pattern.cell_height - pattern.cell_height;
    const last_x = bounds.x + bounds.width + pattern.cell_width;
    const last_y = bounds.y + bounds.height + pattern.cell_height;
    var tile_count: usize = 0;
    var y = first_y;
    while (y <= last_y) : (y += pattern.cell_height) {
        var x = first_x;
        while (x <= last_x) : (x += pattern.cell_width) {
            tile_count += 1;
            if (tile_count > 1_000_000) return error.InvalidItemGeometry;
            if (pattern.fill) |color| {
                appendPdfPath(pdf, pattern.commands, pattern.transform, x, y);
                c.ss_pdf_path_fill_solid(pdf, color.r, color.g, color.b, value.fill.opacity, @intFromEnum(value.fill.rule));
            }
            if (pattern.stroke) |stroke| {
                appendPdfPath(pdf, pattern.commands, pattern.transform, x, y);
                strokePdfPath(pdf, stroke, value.fill.opacity);
            }
        }
    }
}

fn inverseTransformBounds(bounds: render_ir.Rect, transform: render_ir.Transform) !render_ir.Rect {
    const determinant = transform.xx * transform.yy - transform.xy * transform.yx;
    if (!std.math.isFinite(determinant) or @abs(determinant) <= 1e-12) return error.InvalidItemGeometry;
    const corners = [_]render_ir.Point{
        .{ .x = bounds.x, .y = bounds.y },
        .{ .x = bounds.x + bounds.width, .y = bounds.y },
        .{ .x = bounds.x, .y = bounds.y + bounds.height },
        .{ .x = bounds.x + bounds.width, .y = bounds.y + bounds.height },
    };
    var min_x = std.math.inf(f64);
    var min_y = std.math.inf(f64);
    var max_x = -std.math.inf(f64);
    var max_y = -std.math.inf(f64);
    for (corners) |corner| {
        const x = corner.x - transform.x0;
        const y = corner.y - transform.y0;
        const local_x = (transform.yy * x - transform.xy * y) / determinant;
        const local_y = (-transform.yx * x + transform.xx * y) / determinant;
        min_x = @min(min_x, local_x);
        min_y = @min(min_y, local_y);
        max_x = @max(max_x, local_x);
        max_y = @max(max_y, local_y);
    }
    return .{ .x = min_x, .y = min_y, .width = max_x - min_x, .height = max_y - min_y };
}

fn strokePdfPath(pdf: *c.SsPdf, stroke: render_ir.StrokePaint, opacity: f64) void {
    c.ss_pdf_path_stroke(
        pdf,
        stroke.color.r,
        stroke.color.g,
        stroke.color.b,
        opacity,
        stroke.width,
        @intFromEnum(stroke.cap),
        @intFromEnum(stroke.join),
        stroke.miter_limit,
        if (stroke.dash.len == 0) null else stroke.dash.ptr,
        stroke.dash.len,
        stroke.dash_offset,
    );
}

fn appendPdfPath(pdf: *c.SsPdf, commands: []const render_ir.PathCommand, transform: render_ir.Transform, offset_x: f64, offset_y: f64) void {
    c.ss_pdf_path_new(pdf);
    for (commands) |command| switch (command) {
        .move_to => |point| {
            const value = transformPoint(point, transform, offset_x, offset_y);
            c.ss_pdf_path_move_to(pdf, value.x, value.y);
        },
        .line_to => |point| {
            const value = transformPoint(point, transform, offset_x, offset_y);
            c.ss_pdf_path_line_to(pdf, value.x, value.y);
        },
        .cubic_to => |cubic| {
            const control1 = transformPoint(cubic.control1, transform, offset_x, offset_y);
            const control2 = transformPoint(cubic.control2, transform, offset_x, offset_y);
            const end = transformPoint(cubic.end, transform, offset_x, offset_y);
            c.ss_pdf_path_curve_to(pdf, control1.x, control1.y, control2.x, control2.y, end.x, end.y);
        },
        .close => c.ss_pdf_path_close(pdf),
    };
}

fn transformPoint(point: render_ir.Point, transform: render_ir.Transform, offset_x: f64, offset_y: f64) render_ir.Point {
    return .{
        .x = transform.xx * (point.x + offset_x) + transform.xy * (point.y + offset_y) + transform.x0,
        .y = transform.yx * (point.x + offset_x) + transform.yy * (point.y + offset_y) + transform.y0,
    };
}

fn itemEffects(header: render_ir.ItemHeader) c.SsLayerEffects {
    var effects = identityLayerEffects();
    effects.xx = header.transform.xx;
    effects.yx = header.transform.yx;
    effects.xy = header.transform.xy;
    effects.yy = header.transform.yy;
    effects.x0 = header.transform.x0;
    effects.y0 = header.transform.y0;
    effects.opacity = header.opacity;
    effects.blend_mode = @intFromEnum(header.blend_mode);
    if (header.clip) |value| switch (value) {
        .rect => |rect| {
            effects.has_clip = 1;
            effects.clip_x = rect.x;
            effects.clip_y = rect.y;
            effects.clip_width = rect.width;
            effects.clip_height = rect.height;
        },
    };
    return effects;
}

fn replayText(
    allocator: Allocator,
    pdf: *c.SsPdf,
    ir: *const render_ir.Ir,
    text: render_ir.Text,
    resources: *const ResourceFiles,
) !void {
    try replayTextLayout(allocator, pdf, ir, &text.layout, text.x, text.y, text.font_size, text.color, resources);
}

fn replayTextLayout(
    allocator: Allocator,
    pdf: *c.SsPdf,
    ir: *const render_ir.Ir,
    layout: *const render_ir.TextLayout,
    x: f64,
    y: f64,
    font_size: f64,
    color: core.render_policy.Color,
    resources: *const ResourceFiles,
) !void {
    for (layout.runs) |run| {
        const font = ir.fonts.find(run.font_instance) orelse return error.MissingRenderFont;
        const font_path = try resources.resolve(font.resource, .font);
        const glyph_source = layout.glyphs[run.glyph_range.start..run.glyph_range.end];
        const glyphs = try allocator.alloc(c.SsReplayGlyph, glyph_source.len);
        defer allocator.free(glyphs);
        var cursor = x + run.x;
        for (glyph_source, 0..) |glyph, index| {
            glyphs[index] = .{
                .id = glyph.id,
                .x = cursor + glyph.offset_x,
                .y = y + run.baseline_y - glyph.offset_y,
            };
            cursor += glyph.advance_x;
        }

        const cluster_source = layout.clusters[run.cluster_range.start..run.cluster_range.end];
        const cluster_order = try allocator.alloc(usize, cluster_source.len);
        defer allocator.free(cluster_order);
        for (cluster_order, 0..) |*entry, index| entry.* = index;
        std.mem.sort(usize, cluster_order, cluster_source, struct {
            fn lessThan(clusters: []const render_ir.TextCluster, lhs: usize, rhs: usize) bool {
                return clusters[lhs].glyph_range.start < clusters[rhs].glyph_range.start;
            }
        }.lessThan);
        const clusters = try allocator.alloc(c.SsReplayCluster, cluster_source.len);
        defer allocator.free(clusters);
        var byte_count: usize = 0;
        var glyph_count: usize = 0;
        for (cluster_order, 0..) |source_index, output_index| {
            const cluster = cluster_source[source_index];
            const bytes = cluster.source.end - cluster.source.start;
            const cluster_glyphs = cluster.glyph_range.end - cluster.glyph_range.start;
            clusters[output_index] = .{ .bytes = @intCast(bytes), .glyphs = @intCast(cluster_glyphs) };
            byte_count += bytes;
            glyph_count += cluster_glyphs;
        }
        const source = layout.source_text[run.source.start..run.source.end];
        if (byte_count != source.len or glyph_count != glyphs.len) return error.InvalidTextLayout;
        if (c.ss_pdf_draw_glyph_run(
            pdf,
            font_path.ptr,
            @intCast(font.face_index),
            font_size,
            color.r,
            color.g,
            color.b,
            source.ptr,
            @intCast(source.len),
            glyphs.ptr,
            @intCast(glyphs.len),
            clusters.ptr,
            @intCast(clusters.len),
            @intFromBool(run.direction == .right_to_left),
        ) != 0) return cairoFailure(pdf);
    }
}

fn emitAnnotations(pdf: *c.SsPdf, page: *const render_ir.Page) !void {
    for (page.destinations.items) |destination| {
        if (c.ss_pdf_add_destination(pdf, destination.name.ptr, destination.point.x, destination.point.y) != 0) {
            return cairoFailure(pdf);
        }
    }
    for (page.links.items) |link| {
        const result = switch (link.kind) {
            .destination => c.ss_pdf_begin_dest_link(pdf, link.rect.x, link.rect.y, link.rect.width, link.rect.height, link.target.ptr),
            .uri => c.ss_pdf_begin_uri_link(pdf, link.rect.x, link.rect.y, link.rect.width, link.rect.height, link.target.ptr),
        };
        if (result != 0) return cairoFailure(pdf);
        c.ss_pdf_end_link(pdf);
    }
}

pub fn lastFailureDetail() ?[]const u8 {
    const detail = std.mem.span(c.ss_pdf_last_error());
    return if (detail.len == 0) null else detail;
}

fn cairoCreateFailure() error{ CairoCreateFailed, CairoWriteFailed } {
    return if (c.ss_pdf_failure_is_write(null) != 0) error.CairoWriteFailed else error.CairoCreateFailed;
}

fn cairoFailure(pdf: *c.SsPdf) error{ CairoFailed, CairoWriteFailed } {
    _ = c.ss_pdf_status_string(pdf);
    return if (c.ss_pdf_failure_is_write(pdf) != 0) error.CairoWriteFailed else error.CairoFailed;
}

fn imageFailure(pdf: *c.SsPdf) error{ ImageDecodeFailed, CairoWriteFailed } {
    _ = c.ss_pdf_status_string(pdf);
    return if (c.ss_pdf_failure_is_write(pdf) != 0) error.CairoWriteFailed else error.ImageDecodeFailed;
}

fn layerPath(allocator: Allocator, output: []const u8, index: usize) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}.layer-{d}.pdf", .{ output, index });
}

fn deleteFileIfExists(io: std.Io, path: []const u8) void {
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
}

pub const ResourceFiles = struct {
    allocator: Allocator,
    io: std.Io,
    directory: []u8,
    entries: []Entry,
    cleanup_directory: bool,

    const Entry = struct {
        id: render_ir.ResourceId,
        kind: render_ir.ResourceKind,
        path: [:0]u8,
    };

    pub fn init(
        allocator: Allocator,
        io: std.Io,
        graph: *const render_ir.ResourceGraph,
        output: []const u8,
    ) !ResourceFiles {
        const serial = @atomicRmw(usize, &materialization_counter, .Add, 1, .monotonic);
        const directory = try std.fmt.allocPrint(allocator, "{s}.resources-{d}-{d}", .{ output, std.c.getpid(), serial });
        errdefer allocator.free(directory);
        std.Io.Dir.cwd().deleteTree(io, directory) catch {};
        try std.Io.Dir.cwd().createDirPath(io, directory);
        errdefer std.Io.Dir.cwd().deleteTree(io, directory) catch {};

        const entries = try allocator.alloc(Entry, graph.entries.len);
        var initialized: usize = 0;
        errdefer {
            for (entries[0..initialized]) |entry| allocator.free(entry.path);
            allocator.free(entries);
        }
        for (graph.entries, 0..) |*resource, index| {
            const hex = std.fmt.bytesToHex(resource.id, .lower);
            const path = try std.fmt.allocPrintSentinel(allocator, "{s}/{s}.{s}", .{ directory, hex, resource.extension() }, 0);
            errdefer allocator.free(path);
            try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = resource.bytes, .flags = .{ .truncate = true } });
            entries[index] = .{ .id = resource.id, .kind = resource.kind, .path = path };
            initialized += 1;
        }
        return .{
            .allocator = allocator,
            .io = io,
            .directory = directory,
            .entries = entries,
            .cleanup_directory = true,
        };
    }

    pub fn initCached(
        allocator: Allocator,
        io: std.Io,
        graph: *const render_ir.ResourceGraph,
        cache_root: []const u8,
    ) !ResourceFiles {
        const directory = try std.fs.path.join(allocator, &.{ cache_root, "resources" });
        errdefer allocator.free(directory);
        try std.Io.Dir.cwd().createDirPath(io, directory);

        const entries = try allocator.alloc(Entry, graph.entries.len);
        var initialized: usize = 0;
        errdefer {
            for (entries[0..initialized]) |entry| allocator.free(entry.path);
            allocator.free(entries);
        }
        for (graph.entries, 0..) |*resource, index| {
            const hex = std.fmt.bytesToHex(resource.id, .lower);
            const path = try std.fmt.allocPrintSentinel(allocator, "{s}/{s}.{s}", .{ directory, hex, resource.extension() }, 0);
            errdefer allocator.free(path);
            try materializeCachedResource(allocator, io, path, resource.bytes);
            entries[index] = .{ .id = resource.id, .kind = resource.kind, .path = path };
            initialized += 1;
        }
        return .{
            .allocator = allocator,
            .io = io,
            .directory = directory,
            .entries = entries,
            .cleanup_directory = false,
        };
    }

    pub fn deinit(self: *ResourceFiles) void {
        if (self.cleanup_directory) std.Io.Dir.cwd().deleteTree(self.io, self.directory) catch {};
        for (self.entries) |entry| self.allocator.free(entry.path);
        self.allocator.free(self.entries);
        self.allocator.free(self.directory);
    }

    fn resolve(self: *const ResourceFiles, id: render_ir.ResourceId, kind: render_ir.ResourceKind) ![:0]const u8 {
        for (self.entries) |entry| {
            if (entry.kind == kind and std.mem.eql(u8, &entry.id, &id)) return entry.path;
        }
        return error.MissingRenderResource;
    }
};

fn materializeCachedResource(
    allocator: Allocator,
    io: std.Io,
    path: []const u8,
    bytes: []const u8,
) !void {
    if (cachedResourceFileAvailable(io, path, bytes)) return;
    const serial = @atomicRmw(usize, &materialization_counter, .Add, 1, .monotonic);
    const temporary = try std.fmt.allocPrint(allocator, "{s}.tmp-{d}-{d}", .{ path, std.c.getpid(), serial });
    defer allocator.free(temporary);
    errdefer deleteFileIfExists(io, temporary);
    const cwd = std.Io.Dir.cwd();
    try cwd.writeFile(io, .{ .sub_path = temporary, .data = bytes, .flags = .{ .truncate = true } });
    cwd.rename(temporary, cwd, path, io) catch |err| {
        if (cachedResourceFileAvailable(io, path, bytes)) {
            deleteFileIfExists(io, temporary);
            return;
        }
        return err;
    };
}

fn cachedResourceFileAvailable(io: std.Io, path: []const u8, expected: []const u8) bool {
    var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    defer file.close(io);
    const stat = file.stat(io) catch return false;
    if (stat.kind != .file or stat.size != @as(u64, @intCast(expected.len))) return false;

    var buffer: [64 * 1024]u8 = undefined;
    var offset: usize = 0;
    while (offset < expected.len) {
        const length = @min(buffer.len, expected.len - offset);
        var vectors = [_][]u8{buffer[0..length]};
        const read = file.readPositional(io, &vectors, offset) catch return false;
        if (read != length or !std.mem.eql(u8, buffer[0..length], expected[offset .. offset + length])) return false;
        offset += length;
    }
    return true;
}
