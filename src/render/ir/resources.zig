const std = @import("std");

pub const Id = [32]u8;

pub const Kind = enum {
    font,
    raster,
    svg,
    pdf,
    math_pdf,
};

pub const RasterOrientation = enum(u8) {
    normal = 1,
    mirror_horizontal = 2,
    rotate_180 = 3,
    mirror_vertical = 4,
    transpose = 5,
    rotate_90 = 6,
    transverse = 7,
    rotate_270 = 8,
};

pub const RasterColorSpace = enum {
    srgb,
    icc,
    unknown,
};

pub const RasterInterpolation = enum {
    nearest,
    bilinear,
};

pub const RasterMetadata = struct {
    pixel_width: usize,
    pixel_height: usize,
    oriented_width: usize,
    oriented_height: usize,
    orientation: RasterOrientation,
    color_space: RasterColorSpace,
    has_alpha: bool,
    interpolation: RasterInterpolation = .bilinear,
};

pub const SvgAlign = enum {
    none,
    x_min_y_min,
    x_mid_y_min,
    x_max_y_min,
    x_min_y_mid,
    x_mid_y_mid,
    x_max_y_mid,
    x_min_y_max,
    x_mid_y_max,
    x_max_y_max,
};

pub const SvgScale = enum {
    meet,
    slice,
};

pub const SvgViewBox = struct {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
};

pub const SvgMetadata = struct {
    width: f64,
    height: f64,
    view_box: ?SvgViewBox,
    alignment: SvgAlign = .x_mid_y_mid,
    scale: SvgScale = .meet,
};

pub const PdfBox = struct {
    left: f64,
    bottom: f64,
    right: f64,
    top: f64,

    pub fn width(self: PdfBox) f64 {
        return self.right - self.left;
    }

    pub fn height(self: PdfBox) f64 {
        return self.top - self.bottom;
    }
};

pub const PdfPageMetadata = struct {
    media: PdfBox,
    crop: PdfBox,
    bleed: PdfBox,
    trim: PdfBox,
    art: PdfBox,
    user_unit: f64,
    rotation: u16,
    annotation_count: usize,
    has_unsafe_annotations: bool,

    pub fn box(self: *const PdfPageMetadata, kind: @import("core").render_policy.PdfPageBox) PdfBox {
        return switch (kind) {
            .media => self.media,
            .crop => self.crop,
            .bleed => self.bleed,
            .trim => self.trim,
            .art => self.art,
        };
    }
};

pub const PdfMetadata = struct {
    pages: []PdfPageMetadata,
    encrypted: bool,
    has_javascript: bool,

    fn deinit(self: *PdfMetadata, allocator: std.mem.Allocator) void {
        allocator.free(self.pages);
    }
};

pub const FontMetadata = struct {
    collection: bool,
};

pub const Metadata = union(Kind) {
    font: FontMetadata,
    raster: RasterMetadata,
    svg: SvgMetadata,
    pdf: PdfMetadata,
    math_pdf: PdfMetadata,

    pub fn deinit(self: *Metadata, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .pdf => |*value| value.deinit(allocator),
            .math_pdf => |*value| value.deinit(allocator),
            .font, .raster, .svg => {},
        }
    }
};

pub const Resource = struct {
    id: Id,
    kind: Kind,
    name: []u8,
    bytes: []u8,
    metadata: Metadata,

    pub fn deinit(self: *Resource, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.bytes);
        self.metadata.deinit(allocator);
    }

    pub fn extension(self: *const Resource) []const u8 {
        return extensionFor(self.kind, self.bytes);
    }

    pub fn mediaType(self: *const Resource) []const u8 {
        return switch (self.kind) {
            .font => if (std.mem.startsWith(u8, self.bytes, "ttcf"))
                "font/collection"
            else if (std.mem.startsWith(u8, self.bytes, "wOF2"))
                "font/woff2"
            else if (std.mem.startsWith(u8, self.bytes, "wOFF"))
                "font/woff"
            else
                "font/sfnt",
            .svg => "image/svg+xml",
            .pdf, .math_pdf => "application/pdf",
            .raster => if (std.mem.startsWith(u8, self.bytes, "\x89PNG\r\n\x1a\n"))
                "image/png"
            else if (std.mem.startsWith(u8, self.bytes, "GIF87a") or std.mem.startsWith(u8, self.bytes, "GIF89a"))
                "image/gif"
            else if (self.bytes.len >= 2 and self.bytes[0] == 0xff and self.bytes[1] == 0xd8)
                "image/jpeg"
            else
                "application/octet-stream",
        };
    }
};

pub const Graph = struct {
    entries: []Resource = &.{},

    pub fn deinit(self: *Graph, allocator: std.mem.Allocator) void {
        for (self.entries) |*entry| entry.deinit(allocator);
        allocator.free(self.entries);
        self.* = .{};
    }

    pub fn find(self: *const Graph, id: Id) ?*const Resource {
        var low: usize = 0;
        var high: usize = self.entries.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            switch (std.mem.order(u8, &self.entries[middle].id, &id)) {
                .lt => low = middle + 1,
                .gt => high = middle,
                .eq => return &self.entries[middle],
            }
        }
        return null;
    }
};

pub fn identify(kind: Kind, bytes: []const u8) Id {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("ss-render-resource-v1\x00");
    hasher.update(@tagName(kind));
    hasher.update("\x00");
    hasher.update(bytes);
    var id: Id = undefined;
    hasher.final(&id);
    return id;
}

pub fn extensionFor(kind: Kind, bytes: []const u8) []const u8 {
    return switch (kind) {
        .font => if (std.mem.startsWith(u8, bytes, "OTTO"))
            "otf"
        else if (std.mem.startsWith(u8, bytes, "ttcf"))
            "ttc"
        else if (std.mem.startsWith(u8, bytes, "wOF2"))
            "woff2"
        else if (std.mem.startsWith(u8, bytes, "wOFF"))
            "woff"
        else
            "ttf",
        .svg => "svg",
        .pdf, .math_pdf => "pdf",
        .raster => if (std.mem.startsWith(u8, bytes, "\x89PNG\r\n\x1a\n"))
            "png"
        else if (std.mem.startsWith(u8, bytes, "GIF87a") or std.mem.startsWith(u8, bytes, "GIF89a"))
            "gif"
        else if (bytes.len >= 2 and bytes[0] == 0xff and bytes[1] == 0xd8)
            "jpg"
        else
            "bin",
    };
}
