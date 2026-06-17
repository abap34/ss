const std = @import("std");
const cache = @import("cache");
const publish = cache.publish;
const store = cache.store;
const fingerprint = @import("fingerprint.zig");

const c = @cImport({
    @cInclude("pdf.h");
});

pub const SvgAsset = struct {
    path: []u8,
    logical_key: []u8,
    width: f32,
    height: f32,
    tintable: bool = true,

    pub fn deinit(self: *SvgAsset, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.logical_key);
    }
};

const IconSpec = struct {
    style: []const u8,
    name: []const u8,
};

const external_command_timeout = std.Io.Clock.Duration{
    .raw = std.Io.Duration.fromSeconds(120),
    .clock = .awake,
};

pub fn generate(ctx: anytype, source: []const u8) !SvgAsset {
    try std.Io.Dir.cwd().createDirPath(ctx.io, ctx.cache_dir);
    const out = try cachedIconPath(ctx, source, "svg");
    errdefer ctx.allocator.free(out);
    if (try cachedSvg(ctx, out)) |asset| return asset;
    const spec = parseIconSource(source) orelse return error.InvalidFontAwesomeIcon;

    const dir = try publish.tempPath(ctx.allocator, out, "dir");
    defer ctx.allocator.free(dir);
    defer std.Io.Dir.cwd().deleteTree(ctx.io, dir) catch {};
    errdefer std.Io.Dir.cwd().deleteTree(ctx.io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(ctx.io, dir);

    const tex_path = try std.fs.path.join(ctx.allocator, &.{ dir, "main.tex" });
    defer ctx.allocator.free(tex_path);
    const pdf_path = try std.fs.path.join(ctx.allocator, &.{ dir, "main.pdf" });
    defer ctx.allocator.free(pdf_path);
    const tex = try documentSource(ctx.allocator, spec);
    defer ctx.allocator.free(tex);
    try std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = tex_path, .data = tex, .flags = .{ .truncate = true } });
    try runChecked(ctx, &.{ "pdflatex", "-interaction=nonstopmode", "-halt-on-error", "main.tex" }, .{ .path = dir });
    const tmp = try publish.tempPath(ctx.allocator, out, "svg");
    defer ctx.allocator.free(tmp);
    errdefer publish.deleteFileIfExists(ctx.io, tmp);
    try runChecked(ctx, &.{ "pdftocairo", "-svg", pdf_path, tmp }, .inherit);
    _ = try svgAsset(ctx, tmp, out);
    try publish.publishFile(ctx.io, tmp, out);
    return try svgAsset(ctx, out, out);
}

pub fn cachedIconPath(ctx: anytype, source: []const u8, extension: []const u8) ![]u8 {
    var hasher = std.hash.Wyhash.init(0);
    fingerprint.hashString(&hasher, "ss-render-artifact-v3");
    fingerprint.hashString(&hasher, "fontawesome6");
    fingerprint.hashString(&hasher, source);
    return std.fmt.allocPrint(ctx.allocator, "{s}/fontawesome6-{x}.{s}", .{ ctx.cache_dir, hasher.final(), extension });
}

fn documentSource(allocator: std.mem.Allocator, spec: IconSpec) ![]const u8 {
    return std.fmt.allocPrint(allocator,
        \\ \documentclass[border=0pt]{{standalone}}
        \\ \usepackage{{xcolor}}
        \\ \usepackage{{fontawesome6}}
        \\ \begin{{document}}
        \\ \textcolor[rgb]{{0,0,0}}{{\faIcon[{s}]{{{s}}}}}
        \\ \end{{document}}
        \\
    , .{ spec.style, spec.name });
}

fn parseIconSource(source: []const u8) ?IconSpec {
    const variants = [_]struct { prefix: []const u8, style: []const u8 }{
        .{ .prefix = "fa:", .style = "solid" },
        .{ .prefix = "fas:", .style = "solid" },
        .{ .prefix = "far:", .style = "regular" },
        .{ .prefix = "fab:", .style = "brands" },
        .{ .prefix = "fa-solid:", .style = "solid" },
        .{ .prefix = "fa-regular:", .style = "regular" },
        .{ .prefix = "fa-brands:", .style = "brands" },
    };
    for (variants) |variant| {
        if (std.mem.startsWith(u8, source, variant.prefix)) {
            const name = source[variant.prefix.len..];
            if (!isValidIconName(name)) return null;
            return .{ .style = variant.style, .name = name };
        }
    }
    return null;
}

fn isValidIconName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |byte| {
        if (!(std.ascii.isAlphanumeric(byte) or byte == '-')) return false;
    }
    return true;
}

fn cachedSvg(ctx: anytype, path: []const u8) !?SvgAsset {
    if (!store.fileExists(path)) return null;
    return svgAsset(ctx, path, path) catch |err| switch (err) {
        error.ImageDecodeFailed => {
            publish.deleteFileIfExists(ctx.io, path);
            return null;
        },
        else => return err,
    };
}

fn svgAsset(ctx: anytype, path: []const u8, logical_key: []const u8) !SvgAsset {
    var source_width: f64 = 0;
    var source_height: f64 = 0;
    const svg_z = try ctx.allocator.dupeZ(u8, path);
    defer ctx.allocator.free(svg_z);
    if (c.ss_svg_size(svg_z.ptr, &source_width, &source_height) != 0) return error.ImageDecodeFailed;
    return .{
        .path = try ctx.allocator.dupe(u8, path),
        .logical_key = try ctx.allocator.dupe(u8, logical_key),
        .width = @floatCast(source_width),
        .height = @floatCast(source_height),
    };
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
