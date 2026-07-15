const std = @import("std");
const c = @import("pdf_ffi").c;
const render = @import("render");

pub const Builder = struct {
    entries: std.ArrayList(render.Resource) = .empty,

    pub fn deinit(self: *Builder, allocator: std.mem.Allocator) void {
        for (self.entries.items) |*entry| entry.deinit(allocator);
        self.entries.deinit(allocator);
        self.* = .{};
    }

    pub fn addPath(
        self: *Builder,
        allocator: std.mem.Allocator,
        io: std.Io,
        kind: render.ResourceKind,
        path: []const u8,
    ) !render.ResourceId {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited);
        errdefer allocator.free(bytes);
        const id = render.identifyResource(kind, bytes);
        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, &entry.id, &id)) {
                allocator.free(bytes);
                if (entry.kind != kind) return error.RenderResourceKindConflict;
                return id;
            }
        }
        const name = try allocator.dupe(u8, std.fs.path.basename(path));
        errdefer allocator.free(name);
        var metadata = try probeMetadata(allocator, path, kind, bytes);
        errdefer metadata.deinit(allocator);
        try self.entries.append(allocator, .{ .id = id, .kind = kind, .name = name, .bytes = bytes, .metadata = metadata });
        return id;
    }

    pub fn take(self: *Builder, allocator: std.mem.Allocator) !render.ResourceGraph {
        const entries = try self.entries.toOwnedSlice(allocator);
        self.* = .{};
        return .{ .entries = entries };
    }

    pub fn find(self: *const Builder, id: render.ResourceId) ?*const render.Resource {
        for (self.entries.items) |*entry| {
            if (std.mem.eql(u8, &entry.id, &id)) return entry;
        }
        return null;
    }
};

fn probeMetadata(
    allocator: std.mem.Allocator,
    path: []const u8,
    kind: render.ResourceKind,
    bytes: []const u8,
) !render.ResourceMetadata {
    return switch (kind) {
        .font => .{ .font = .{ .collection = std.mem.startsWith(u8, bytes, "ttcf") } },
        .raster => .{ .raster = try rasterMetadata(allocator, path) },
        .svg => .{ .svg = try svgMetadata(allocator, path, bytes) },
        .pdf => .{ .pdf = try pdfMetadata(allocator, path) },
        .math_pdf => .{ .math_pdf = try pdfMetadata(allocator, path) },
    };
}

fn rasterMetadata(allocator: std.mem.Allocator, path: []const u8) !render.RasterMetadata {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    var value: c.SsRasterMetadata = undefined;
    if (c.ss_raster_metadata(path_z.ptr, &value) != 0) return error.InvalidRasterResource;
    if (value.orientation < 1 or value.orientation > 8) return error.InvalidRasterResource;
    const orientation: render.RasterOrientation = @enumFromInt(@as(u8, @intCast(value.orientation)));
    return .{
        .pixel_width = value.pixel_width,
        .pixel_height = value.pixel_height,
        .oriented_width = value.oriented_width,
        .oriented_height = value.oriented_height,
        .orientation = orientation,
        .color_space = switch (value.color_space) {
            1 => .srgb,
            2 => .icc,
            else => .unknown,
        },
        .has_alpha = value.has_alpha != 0,
    };
}

fn svgMetadata(allocator: std.mem.Allocator, path: []const u8, bytes: []const u8) !render.SvgMetadata {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    var value: c.SsSvgMetadata = undefined;
    if (c.ss_svg_metadata(path_z.ptr, &value) != 0) return error.InvalidSvgResource;
    const aspect = preserveAspectRatio(bytes);
    return .{
        .width = value.width,
        .height = value.height,
        .view_box = if (value.has_view_box != 0) .{
            .x = value.view_box_x,
            .y = value.view_box_y,
            .width = value.view_box_width,
            .height = value.view_box_height,
        } else null,
        .alignment = aspect.alignment,
        .scale = aspect.scale,
    };
}

fn pdfMetadata(allocator: std.mem.Allocator, path: []const u8) !render.PdfResourceMetadata {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    var document: c.SsPdfDocumentMetadata = undefined;
    if (c.ss_qpdf_metadata(path_z.ptr, &document, null, 0) != 0 or document.page_count == 0) return error.InvalidPdfResource;
    const native_pages = try allocator.alloc(c.SsPdfPageMetadata, document.page_count);
    defer allocator.free(native_pages);
    if (c.ss_qpdf_metadata(path_z.ptr, &document, native_pages.ptr, native_pages.len) != 0) return error.InvalidPdfResource;
    const pages = try allocator.alloc(render.PdfPageMetadata, native_pages.len);
    errdefer allocator.free(pages);
    for (native_pages, 0..) |native, index| {
        pages[index] = .{
            .media = pdfBox(native.boxes[0]),
            .crop = pdfBox(native.boxes[1]),
            .bleed = pdfBox(native.boxes[2]),
            .trim = pdfBox(native.boxes[3]),
            .art = pdfBox(native.boxes[4]),
            .user_unit = native.user_unit,
            .rotation = @intCast(native.rotation),
            .annotation_count = native.annotation_count,
            .has_unsafe_annotations = native.has_unsafe_annotations != 0,
        };
    }
    return .{
        .pages = pages,
        .encrypted = document.encrypted != 0,
        .has_javascript = document.has_javascript != 0,
    };
}

fn pdfBox(values: [4]f64) render.PdfBox {
    return .{ .left = values[0], .bottom = values[1], .right = values[2], .top = values[3] };
}

fn preserveAspectRatio(bytes: []const u8) struct { alignment: render.SvgAlign, scale: render.SvgScale } {
    const value = svgAttribute(bytes, "preserveAspectRatio") orelse return .{ .alignment = .x_mid_y_mid, .scale = .meet };
    var tokens = std.mem.tokenizeAny(u8, value, " \t\r\n");
    var first = tokens.next() orelse return .{ .alignment = .x_mid_y_mid, .scale = .meet };
    if (std.mem.eql(u8, first, "defer")) first = tokens.next() orelse return .{ .alignment = .x_mid_y_mid, .scale = .meet };
    const alignment: render.SvgAlign = if (std.mem.eql(u8, first, "none"))
        .none
    else if (std.mem.eql(u8, first, "xMinYMin"))
        .x_min_y_min
    else if (std.mem.eql(u8, first, "xMidYMin"))
        .x_mid_y_min
    else if (std.mem.eql(u8, first, "xMaxYMin"))
        .x_max_y_min
    else if (std.mem.eql(u8, first, "xMinYMid"))
        .x_min_y_mid
    else if (std.mem.eql(u8, first, "xMidYMid"))
        .x_mid_y_mid
    else if (std.mem.eql(u8, first, "xMaxYMid"))
        .x_max_y_mid
    else if (std.mem.eql(u8, first, "xMinYMax"))
        .x_min_y_max
    else if (std.mem.eql(u8, first, "xMidYMax"))
        .x_mid_y_max
    else if (std.mem.eql(u8, first, "xMaxYMax"))
        .x_max_y_max
    else
        .x_mid_y_mid;
    const scale: render.SvgScale = if (tokens.next()) |token|
        if (std.mem.eql(u8, token, "slice")) .slice else .meet
    else
        .meet;
    return .{ .alignment = alignment, .scale = scale };
}

fn svgAttribute(bytes: []const u8, name: []const u8) ?[]const u8 {
    const svg_start = std.mem.indexOf(u8, bytes, "<svg") orelse return null;
    const tag_end_relative = std.mem.indexOfScalar(u8, bytes[svg_start..], '>') orelse return null;
    const tag = bytes[svg_start .. svg_start + tag_end_relative];
    var offset: usize = 0;
    while (std.mem.indexOfPos(u8, tag, offset, name)) |start| {
        const before_valid = start == 0 or std.ascii.isWhitespace(tag[start - 1]);
        var cursor = start + name.len;
        const after_valid = cursor == tag.len or std.ascii.isWhitespace(tag[cursor]) or tag[cursor] == '=';
        if (!before_valid or !after_valid) {
            offset = cursor;
            continue;
        }
        while (cursor < tag.len and std.ascii.isWhitespace(tag[cursor])) cursor += 1;
        if (cursor >= tag.len or tag[cursor] != '=') return null;
        cursor += 1;
        while (cursor < tag.len and std.ascii.isWhitespace(tag[cursor])) cursor += 1;
        if (cursor >= tag.len or (tag[cursor] != '"' and tag[cursor] != '\'')) return null;
        const quote = tag[cursor];
        cursor += 1;
        const end = std.mem.indexOfScalarPos(u8, tag, cursor, quote) orelse return null;
        return tag[cursor..end];
    }
    return null;
}
