const std = @import("std");
const core = @import("core");
const input = @import("../input.zig");
const fingerprint = @import("fingerprint.zig");
const cache = @import("cache");
const publish = cache.publish;
const store = cache.store;

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

const external_command_timeout = std.Io.Clock.Duration{
    .raw = std.Io.Duration.fromSeconds(120),
    .clock = .awake,
};

pub fn generate(ctx: anytype, source: []const u8, preamble: []const core.render_env.TexPreambleEntry, mode: input.MathMode) !SvgAsset {
    try std.Io.Dir.cwd().createDirPath(ctx.io, ctx.cache_dir);
    const out = try cachedMathPath(ctx, source, preamble, mode, "svg");
    errdefer ctx.allocator.free(out);
    if (try cachedSvg(ctx, out)) |asset| return asset;

    const dir = try publish.tempPath(ctx.allocator, out, "dir");
    defer ctx.allocator.free(dir);
    defer std.Io.Dir.cwd().deleteTree(ctx.io, dir) catch {};
    errdefer std.Io.Dir.cwd().deleteTree(ctx.io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(ctx.io, dir);

    const tex_path = try std.fs.path.join(ctx.allocator, &.{ dir, "main.tex" });
    defer ctx.allocator.free(tex_path);
    const pdf_path = try std.fs.path.join(ctx.allocator, &.{ dir, "main.pdf" });
    defer ctx.allocator.free(pdf_path);
    const tex = try documentSource(ctx, source, preamble, mode);
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

pub fn cachedMathPath(ctx: anytype, source: []const u8, preamble: []const core.render_env.TexPreambleEntry, mode: input.MathMode, extension: []const u8) ![]u8 {
    var hasher = std.hash.Wyhash.init(0);
    fingerprint.hashString(&hasher, "ss-render-artifact-v3");
    fingerprint.hashString(&hasher, "math");
    fingerprint.hashString(&hasher, @tagName(mode));
    fingerprint.hashString(&hasher, source);
    try fingerprint.hashTexPreambleEntries(ctx.allocator, ctx.io, ctx.asset_base_dir, &hasher, preamble);
    return std.fmt.allocPrint(ctx.allocator, "{s}/math-{x}.{s}", .{ ctx.cache_dir, hasher.final(), extension });
}

fn documentSource(ctx: anytype, source: []const u8, preamble: []const core.render_env.TexPreambleEntry, mode: input.MathMode) ![]u8 {
    const preamble_lines = try preambleLines(ctx, preamble);
    defer ctx.allocator.free(preamble_lines);
    const fragment = try texFragment(ctx.allocator, source, mode);
    defer ctx.allocator.free(fragment);
    return std.fmt.allocPrint(ctx.allocator,
        \\ \documentclass[border=0pt]{{standalone}}
        \\ \usepackage{{amsmath,amssymb}}
        \\ \usepackage{{graphicx}}
        \\ \usepackage{{xcolor}}
        \\{s}
        \\ \begin{{document}}
        \\{s}
        \\ \end{{document}}
        \\
    , .{ preamble_lines, fragment });
}

fn texFragment(allocator: std.mem.Allocator, source: []const u8, mode: input.MathMode) ![]u8 {
    switch (mode) {
        .@"inline" => return std.fmt.allocPrint(allocator, "$\\mathstrut {s}$\n", .{source}),
        .display => return std.fmt.allocPrint(allocator, "$\\displaystyle\\mathstrut {s}$\n", .{source}),
        .raw_block => return allocator.dupe(u8, source),
        .block => {
            var normalized = std.ArrayList(u8).empty;
            defer normalized.deinit(allocator);
            var lines = std.mem.splitScalar(u8, source, '\n');
            while (lines.next()) |line| {
                const trimmed = std.mem.trim(u8, line, " \t\r\n");
                if (trimmed.len == 0) continue;
                if (normalized.items.len > 0) try normalized.append(allocator, '\n');
                try normalized.appendSlice(allocator, trimmed);
            }
            return std.fmt.allocPrint(allocator,
                \\$\displaystyle
                \\\begin{{array}}{{l}}
                \\{s}
                \\\end{{array}}$
                \\
            , .{normalized.items});
        },
    }
}

fn preambleLines(ctx: anytype, preamble: []const core.render_env.TexPreambleEntry) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(ctx.allocator);
    for (preamble) |entry| {
        const text = switch (entry.source) {
            .text => entry.value,
            .file => try readPreambleFile(ctx, entry.value),
        };
        defer if (entry.source == .file) ctx.allocator.free(text);
        if (std.mem.trim(u8, text, " \t\r\n").len == 0) continue;
        try out.append(ctx.allocator, '\n');
        try out.appendSlice(ctx.allocator, text);
        if (text[text.len - 1] != '\n') try out.append(ctx.allocator, '\n');
    }
    return out.toOwnedSlice(ctx.allocator);
}

fn readPreambleFile(ctx: anytype, path: []const u8) ![]const u8 {
    const resolved = try fingerprint.resolveAssetPath(ctx.allocator, ctx.asset_base_dir, path);
    defer ctx.allocator.free(resolved);
    return std.Io.Dir.cwd().readFileAlloc(ctx.io, resolved, ctx.allocator, .unlimited);
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
