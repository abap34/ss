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
    const pdf = c.ss_pdf_create(output_z.ptr, page.width, page.height) orelse return error.CairoCreateFailed;
    defer c.ss_pdf_destroy(pdf);
    c.ss_pdf_set_creator(pdf, "ss page Cairo/Pango backend");
    c.ss_pdf_begin_page(pdf, page.width, page.height);
    try replayItems(allocator, pdf, ir, page.items.items, resources);
    try emitAnnotations(pdf, page);
    c.ss_pdf_end_page(pdf);
    if (c.ss_pdf_finish(pdf) != 0) return error.CairoFailed;
}

fn renderComposed(
    allocator: Allocator,
    io: std.Io,
    ir: *const render_ir.Ir,
    page: *const render_ir.Page,
    output: []const u8,
    resources: *const ResourceFiles,
) !void {
    var composition = Composition.init(allocator, io, ir, page, output, resources);
    defer composition.deinit();

    var segment_start: usize = 0;
    var first_native_layer = true;
    for (page.items.items, 0..) |item, item_index| {
        if (!isExternalPdfItem(item)) continue;
        if (segment_start < item_index or first_native_layer) {
            try composition.appendNativeLayer(segment_start, item_index, first_native_layer);
            first_native_layer = false;
        }
        switch (item) {
            .pdf_page => |value| try composition.appendPdfLayer(value),
            .math => |value| try composition.appendMathLayer(value),
            else => unreachable,
        }
        segment_start = item_index + 1;
    }
    if (segment_start < page.items.items.len) {
        try composition.appendNativeLayer(segment_start, page.items.items.len, first_native_layer);
    }
    try composition.write();
}

fn isExternalPdfItem(item: render_ir.Item) bool {
    return switch (item) {
        .pdf_page => true,
        .math => |value| value.content == .raw_pdf,
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
    owned_paths: std.ArrayList([:0]u8) = .empty,
    native_paths: std.ArrayList([]u8) = .empty,
    next_layer_index: usize = 0,

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
        for (self.native_paths.items) |path| {
            deleteFileIfExists(self.io, path);
            self.allocator.free(path);
        }
        self.native_paths.deinit(self.allocator);
        for (self.owned_paths.items) |path| self.allocator.free(path);
        self.owned_paths.deinit(self.allocator);
        self.layers.deinit(self.allocator);
    }

    fn appendNativeLayer(self: *Composition, start: usize, end: usize, first_layer: bool) !void {
        const native_path = try layerPath(self.allocator, self.output, self.next_layer_index);
        errdefer self.allocator.free(native_path);
        errdefer deleteFileIfExists(self.io, native_path);
        try renderNativeLayer(self.allocator, self.ir, self.page, native_path, start, end, first_layer, self.resources);

        const native_path_z = try self.allocator.dupeZ(u8, native_path);
        self.owned_paths.append(self.allocator, native_path_z) catch |err| {
            self.allocator.free(native_path_z);
            return err;
        };
        try self.layers.append(self.allocator, .{
            .path = native_path_z.ptr,
            .page_index = 0,
            .box = @intFromEnum(core.render_policy.PdfPageBox.crop),
            .x = 0,
            .y = 0,
            .width = self.page.width,
            .height = self.page.height,
            .copy_annotations = 0,
            .effects = identityLayerEffects(),
        });
        try self.native_paths.append(self.allocator, native_path);
        self.next_layer_index += 1;
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

    fn appendMathLayer(self: *Composition, item: render_ir.Math) !void {
        const raw = switch (item.content) {
            .raw_pdf => |value| value,
            .structured => return error.MissingRenderResource,
        };
        const path = try self.resources.resolve(raw.resource, .math_pdf);
        try self.layers.append(self.allocator, .{
            .path = path.ptr,
            .page_index = raw.page_index,
            .box = @intFromEnum(raw.box),
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

fn identityLayerEffects() c.SsQpdfLayerEffects {
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

fn layerEffects(header: render_ir.ItemHeader, page_height: f64) c.SsQpdfLayerEffects {
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

fn renderNativeLayer(
    allocator: Allocator,
    ir: *const render_ir.Ir,
    page: *const render_ir.Page,
    path: []const u8,
    start: usize,
    end: usize,
    first_layer: bool,
    resources: *const ResourceFiles,
) !void {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const pdf = c.ss_pdf_create(path_z.ptr, page.width, page.height) orelse return error.CairoCreateFailed;
    defer c.ss_pdf_destroy(pdf);
    c.ss_pdf_set_creator(pdf, "ss page Cairo/Pango/libqpdf backend");
    c.ss_pdf_begin_page(pdf, page.width, page.height);
    if (first_layer) try emitAnnotations(pdf, page);
    try replayItems(allocator, pdf, ir, page.items.items[start..end], resources);
    c.ss_pdf_end_page(pdf);
    if (c.ss_pdf_finish(pdf) != 0) return error.CairoFailed;
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
        try beginItem(pdf, header);
        replayItem(allocator, pdf, ir, item, resources) catch |err| {
            _ = c.ss_pdf_end_item(pdf, header.opacity, @intFromEnum(header.blend_mode));
            return err;
        };
        if (c.ss_pdf_end_item(pdf, header.opacity, @intFromEnum(header.blend_mode)) != 0) return error.CairoFailed;
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
                return error.ImageDecodeFailed;
            }
        },
        .svg => |value| {
            const path = try resources.resolve(value.resource, .svg);
            const result = if (value.tint) |color|
                c.ss_pdf_draw_svg_tinted(pdf, path.ptr, value.rect.x, value.rect.y, value.rect.width, value.rect.height, color.r, color.g, color.b)
            else
                c.ss_pdf_draw_svg(pdf, path.ptr, value.rect.x, value.rect.y, value.rect.width, value.rect.height);
            if (result != 0) return error.ImageDecodeFailed;
        },
        .math => |value| try replayMath(allocator, pdf, ir, value, resources),
        .pdf_page => return error.UnsupportedAssetType,
    }
}

fn beginItem(pdf: *c.SsPdf, header: render_ir.ItemHeader) !void {
    var has_clip: c_int = 0;
    var clip = render_ir.Rect{ .x = 0, .y = 0, .width = 0, .height = 0 };
    if (header.clip) |value| switch (value) {
        .rect => |rect| {
            has_clip = 1;
            clip = rect;
        },
    };
    if (c.ss_pdf_begin_item(
        pdf,
        header.transform.xx,
        header.transform.yx,
        header.transform.xy,
        header.transform.yy,
        header.transform.x0,
        header.transform.y0,
        has_clip,
        clip.x,
        clip.y,
        clip.width,
        clip.height,
        header.opacity,
        @intFromEnum(header.blend_mode),
    ) != 0) return error.CairoFailed;
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

fn replayMath(
    allocator: Allocator,
    pdf: *c.SsPdf,
    ir: *const render_ir.Ir,
    math: render_ir.Math,
    resources: *const ResourceFiles,
) !void {
    const structured = switch (math.content) {
        .structured => |value| value,
        .raw_pdf => return error.UnsupportedAssetType,
    };
    const layout = structured.layout;
    for (layout.elements) |element| switch (element) {
        .text => |text| try replayTextLayout(
            allocator,
            pdf,
            ir,
            &text.layout,
            math.rect.x + text.x,
            math.rect.y + text.y,
            text.font_size,
            structured.color,
            resources,
        ),
        .rule => |rule| c.ss_pdf_fill_rect(
            pdf,
            math.rect.x + rule.rect.x,
            math.rect.y + rule.rect.y,
            rule.rect.width,
            rule.rect.height,
            structured.color.r,
            structured.color.g,
            structured.color.b,
        ),
    };
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
        ) != 0) return error.CairoFailed;
    }
}

fn emitAnnotations(pdf: *c.SsPdf, page: *const render_ir.Page) !void {
    for (page.destinations.items) |destination| {
        if (c.ss_pdf_add_destination(pdf, destination.name.ptr, destination.point.x, destination.point.y) != 0) {
            return error.CairoFailed;
        }
    }
    for (page.links.items) |link| {
        const result = switch (link.kind) {
            .destination => c.ss_pdf_begin_dest_link(pdf, link.rect.x, link.rect.y, link.rect.width, link.rect.height, link.target.ptr),
            .uri => c.ss_pdf_begin_uri_link(pdf, link.rect.x, link.rect.y, link.rect.width, link.rect.height, link.target.ptr),
        };
        if (result != 0) return error.CairoFailed;
        c.ss_pdf_end_link(pdf);
    }
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
        return .{ .allocator = allocator, .io = io, .directory = directory, .entries = entries };
    }

    pub fn deinit(self: *ResourceFiles) void {
        std.Io.Dir.cwd().deleteTree(self.io, self.directory) catch {};
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
