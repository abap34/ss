const std = @import("std");
const core = @import("core");
const scene = @import("scene.zig");
const input = @import("input.zig");
const math_artifact = @import("artifacts/math.zig");
const icon_artifact = @import("artifacts/icon.zig");
const image_artifact = @import("artifacts/image.zig");
const fingerprint = @import("artifacts/fingerprint.zig");

pub const MathMode = input.MathMode;

pub const default_cache_dir = ".ss-cache/render/artifacts/shared";

pub const Context = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    asset_base_dir: []const u8,
    cache_dir: []const u8 = default_cache_dir,

    pub fn resolveAssetPath(self: Context, source: []const u8) ![]u8 {
        return fingerprint.resolveAssetPath(self.allocator, self.asset_base_dir, source);
    }
};

pub const MathSvgRequest = struct {
    source: []const u8,
    preamble: []const core.render_env.TexPreambleEntry,
    mode: MathMode,
    color_sensitive: bool = false,
};

pub const IconSvgRequest = struct {
    source: []const u8,
};

pub const RasterImageRequest = struct {
    source: []const u8,
    target_width: f32,
    target_height: f32,
};

pub const VectorImageRequest = struct {
    source: []const u8,
    target_width: f32,
    target_height: f32,
};

pub const Request = union(enum) {
    math_svg: MathSvgRequest,
    icon_svg: IconSvgRequest,
    raster_image: RasterImageRequest,
    vector_image: VectorImageRequest,
};

pub const Generated = struct {
    kind: scene.ResourceKind,
    path: []u8,
    logical_key: []u8,
    intrinsic_width: f32,
    intrinsic_height: f32,
    tintable: bool = false,

    pub fn deinit(self: *Generated, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.logical_key);
    }
};

pub const Provider = struct {
    context: *anyopaque,
    resolveAsset: *const fn (context: *anyopaque, source: []const u8) anyerror![]u8,
    generate: *const fn (context: *anyopaque, request: Request) anyerror!Generated,
};

pub fn generate(ctx: Context, request: Request) !Generated {
    try std.Io.Dir.cwd().createDirPath(ctx.io, ctx.cache_dir);
    switch (request) {
        .math_svg => |math| {
            var asset = try math_artifact.generate(ctx, math.source, math.preamble, math.mode);
            defer asset.deinit(ctx.allocator);
            return .{
                .kind = .svg,
                .path = try ctx.allocator.dupe(u8, asset.path),
                .logical_key = try ctx.allocator.dupe(u8, asset.logical_key),
                .intrinsic_width = asset.width,
                .intrinsic_height = asset.height,
                .tintable = asset.tintable,
            };
        },
        .icon_svg => |icon| {
            var asset = try icon_artifact.generate(ctx, icon.source);
            defer asset.deinit(ctx.allocator);
            return .{
                .kind = .svg,
                .path = try ctx.allocator.dupe(u8, asset.path),
                .logical_key = try ctx.allocator.dupe(u8, asset.logical_key),
                .intrinsic_width = asset.width,
                .intrinsic_height = asset.height,
                .tintable = asset.tintable,
            };
        },
        .raster_image => |raster| {
            var asset = try image_artifact.generateRaster(ctx, raster.source, raster.target_width, raster.target_height);
            defer asset.deinit(ctx.allocator);
            return .{
                .kind = asset.kind,
                .path = try ctx.allocator.dupe(u8, asset.path),
                .logical_key = try ctx.allocator.dupe(u8, asset.logical_key),
                .intrinsic_width = asset.width,
                .intrinsic_height = asset.height,
                .tintable = asset.tintable,
            };
        },
        .vector_image => |vector| {
            var asset = try image_artifact.generateVector(ctx, vector.source, vector.target_width, vector.target_height);
            defer asset.deinit(ctx.allocator);
            return .{
                .kind = asset.kind,
                .path = try ctx.allocator.dupe(u8, asset.path),
                .logical_key = try ctx.allocator.dupe(u8, asset.logical_key),
                .intrinsic_width = asset.width,
                .intrinsic_height = asset.height,
                .tintable = asset.tintable,
            };
        },
    }
}

pub fn addResource(allocator: std.mem.Allocator, resources: *std.ArrayList(scene.Resource), generated: Generated) !scene.ResourceId {
    for (resources.items) |resource| {
        if (std.mem.eql(u8, resource.logical_key, generated.logical_key) and std.mem.eql(u8, resource.path, generated.path)) {
            return resource.id;
        }
    }
    const id: scene.ResourceId = @intCast(resources.items.len + 1);
    try resources.append(allocator, .{
        .id = id,
        .kind = generated.kind,
        .path = try allocator.dupe(u8, generated.path),
        .logical_key = try allocator.dupe(u8, generated.logical_key),
        .intrinsic_width = generated.intrinsic_width,
        .intrinsic_height = generated.intrinsic_height,
        .tintable = generated.tintable,
    });
    return id;
}
