const std = @import("std");
const scene = @import("../scene.zig");
const cache = @import("cache");
const publish = cache.publish;
const store = cache.store;
const fingerprint = @import("fingerprint.zig");

const c = @cImport({
    @cInclude("pdf.h");
});

pub const ImageAsset = struct {
    kind: scene.ResourceKind,
    path: []u8,
    logical_key: []u8,
    width: f32,
    height: f32,
    tintable: bool = false,

    pub fn deinit(self: *ImageAsset, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.logical_key);
    }
};

const raster_cache_scale: f32 = 3.0;
const external_command_timeout = std.Io.Clock.Duration{
    .raw = std.Io.Duration.fromSeconds(120),
    .clock = .awake,
};

pub fn generateVector(ctx: anytype, source_text: []const u8, target_width: f32, target_height: f32) !ImageAsset {
    const source = try fingerprint.resolveAssetPath(ctx.allocator, ctx.asset_base_dir, source_text);
    defer ctx.allocator.free(source);
    const extension = std.fs.path.extension(source);
    if (std.ascii.eqlIgnoreCase(extension, ".svg")) return validatedSvg(ctx, source, source_text);
    if (std.ascii.eqlIgnoreCase(extension, ".pdf")) {
        _ = target_width;
        _ = target_height;
        const out = try pdfToSvg(ctx, source, source_text);
        errdefer out.deinit(ctx.allocator);
        return out;
    }
    return error.UnsupportedAssetType;
}

pub fn generateRaster(ctx: anytype, source_text: []const u8, target_width: f32, target_height: f32) !ImageAsset {
    const source = try fingerprint.resolveAssetPath(ctx.allocator, ctx.asset_base_dir, source_text);
    defer ctx.allocator.free(source);
    if (std.ascii.eqlIgnoreCase(std.fs.path.extension(source), ".svg")) return validatedSvg(ctx, source, source_text);
    return rasterToPng(ctx, source, source_text, target_width * raster_cache_scale, target_height * raster_cache_scale);
}

fn pdfToSvg(ctx: anytype, source: []const u8, logical_source: []const u8) !ImageAsset {
    const out = try cachedAssetPath(ctx, "pdf", source, "svg");
    errdefer ctx.allocator.free(out);
    if (try cachedSvg(ctx, out, logical_source)) |asset| return asset;
    const tmp = try publish.tempPath(ctx.allocator, out, "svg");
    defer ctx.allocator.free(tmp);
    errdefer publish.deleteFileIfExists(ctx.io, tmp);
    try runChecked(ctx, &.{ "pdftocairo", "-svg", source, tmp }, .inherit);
    _ = try svgAsset(ctx, tmp, logical_source);
    try publish.publishFile(ctx.io, tmp, out);
    return try svgAsset(ctx, out, logical_source);
}

fn rasterToPng(ctx: anytype, source: []const u8, logical_source: []const u8, target_width: f32, target_height: f32) !ImageAsset {
    if (std.ascii.eqlIgnoreCase(std.fs.path.extension(source), ".png")) {
        if (try pngAsset(ctx, source, logical_source)) |asset| {
            if (asset.width <= target_width and asset.height <= target_height) return asset;
            var owned = asset;
            owned.deinit(ctx.allocator);
        }
    }

    const out = try cachedSizedAssetPath(ctx, "raster-fit", source, target_width, target_height, "png");
    errdefer ctx.allocator.free(out);
    if (try cachedPng(ctx, out, logical_source)) |asset| return asset;
    const tmp = try publish.tempPath(ctx.allocator, out, "png");
    defer ctx.allocator.free(tmp);
    errdefer publish.deleteFileIfExists(ctx.io, tmp);

    var geometry_buf: [64]u8 = undefined;
    const geometry = try std.fmt.bufPrint(&geometry_buf, "{d}x{d}>", .{
        rasterTargetPixels(target_width),
        rasterTargetPixels(target_height),
    });
    try runChecked(ctx, &.{ "magick", source, "-auto-orient", "-resize", geometry, "-strip", tmp }, .inherit);
    _ = try pngAsset(ctx, tmp, logical_source) orelse return error.ImageDecodeFailed;
    try publish.publishFile(ctx.io, tmp, out);
    return (try pngAsset(ctx, out, logical_source)) orelse error.ImageDecodeFailed;
}

fn validatedSvg(ctx: anytype, source: []const u8, logical_source: []const u8) !ImageAsset {
    return try svgAsset(ctx, source, logical_source);
}

fn cachedSvg(ctx: anytype, path: []const u8, logical_source: []const u8) !?ImageAsset {
    if (!store.fileExists(path)) return null;
    return svgAsset(ctx, path, logical_source) catch |err| switch (err) {
        error.ImageDecodeFailed => {
            publish.deleteFileIfExists(ctx.io, path);
            return null;
        },
        else => return err,
    };
}

fn cachedPng(ctx: anytype, path: []const u8, logical_source: []const u8) !?ImageAsset {
    if (!store.fileExists(path)) return null;
    return pngAsset(ctx, path, logical_source) catch |err| switch (err) {
        error.ImageDecodeFailed => {
            publish.deleteFileIfExists(ctx.io, path);
            return null;
        },
        else => return err,
    };
}

fn svgAsset(ctx: anytype, path: []const u8, logical_source: []const u8) !ImageAsset {
    var width: f64 = 0;
    var height: f64 = 0;
    const path_z = try ctx.allocator.dupeZ(u8, path);
    defer ctx.allocator.free(path_z);
    if (c.ss_svg_size(path_z.ptr, &width, &height) != 0) return error.ImageDecodeFailed;
    return .{
        .kind = .svg,
        .path = try ctx.allocator.dupe(u8, path),
        .logical_key = try ctx.allocator.dupe(u8, logical_source),
        .width = @floatCast(width),
        .height = @floatCast(height),
    };
}

fn pngAsset(ctx: anytype, path: []const u8, logical_source: []const u8) !?ImageAsset {
    var width: f64 = 0;
    var height: f64 = 0;
    const path_z = try ctx.allocator.dupeZ(u8, path);
    defer ctx.allocator.free(path_z);
    if (c.ss_png_size(path_z.ptr, &width, &height) != 0) return error.ImageDecodeFailed;
    if (width <= 0 or height <= 0) return error.ImageDecodeFailed;
    return .{
        .kind = .png,
        .path = try ctx.allocator.dupe(u8, path),
        .logical_key = try ctx.allocator.dupe(u8, logical_source),
        .width = @floatCast(width),
        .height = @floatCast(height),
    };
}

fn cachedAssetPath(ctx: anytype, kind: []const u8, source: []const u8, extension: []const u8) ![]u8 {
    const file = try fingerprint.streamFileFingerprint(ctx.allocator, ctx.io, source);
    var hasher = std.hash.Wyhash.init(0);
    fingerprint.hashString(&hasher, "ss-render-artifact-v3");
    fingerprint.hashString(&hasher, kind);
    fingerprint.hashLogicalAssetPath(&hasher, ctx.asset_base_dir, source);
    fingerprint.hashFile(&hasher, file);
    return std.fmt.allocPrint(ctx.allocator, "{s}/{s}-{x}.{s}", .{ ctx.cache_dir, kind, hasher.final(), extension });
}

fn cachedSizedAssetPath(ctx: anytype, kind: []const u8, source: []const u8, target_width: f32, target_height: f32, extension: []const u8) ![]u8 {
    const file = try fingerprint.streamFileFingerprint(ctx.allocator, ctx.io, source);
    var hasher = std.hash.Wyhash.init(0);
    fingerprint.hashString(&hasher, "ss-render-artifact-v3");
    fingerprint.hashString(&hasher, kind);
    fingerprint.hashLogicalAssetPath(&hasher, ctx.asset_base_dir, source);
    fingerprint.hashU32(&hasher, rasterTargetPixels(target_width));
    fingerprint.hashU32(&hasher, rasterTargetPixels(target_height));
    fingerprint.hashFile(&hasher, file);
    return std.fmt.allocPrint(ctx.allocator, "{s}/{s}-{x}.{s}", .{ ctx.cache_dir, kind, hasher.final(), extension });
}

fn rasterTargetPixels(value: f32) u32 {
    return @intFromFloat(@ceil(@max(value, 1.0)));
}

fn runChecked(ctx: anytype, argv: []const []const u8, cwd: std.process.Child.Cwd) !void {
    const result = std.process.run(ctx.allocator, ctx.io, .{
        .argv = argv,
        .cwd = cwd,
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(128 * 1024),
        .timeout = .{ .duration = external_command_timeout },
    }) catch return error.ArtifactConversionFailed;
    defer ctx.allocator.free(result.stdout);
    defer ctx.allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code == 0) return,
        else => {},
    }
    std.debug.print("render artifact: command failed:", .{});
    for (argv) |arg| std.debug.print(" {s}", .{arg});
    if (result.stdout.len > 0) std.debug.print("\nstdout:\n{s}", .{result.stdout});
    if (result.stderr.len > 0) std.debug.print("\nstderr:\n{s}\n", .{result.stderr});
    return error.ArtifactConversionFailed;
}
