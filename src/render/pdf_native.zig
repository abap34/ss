const std = @import("std");
const core = @import("core");
const scene = @import("scene.zig");
const render_cache = @import("render_cache.zig");
const render_progress = @import("progress.zig");
const target = @import("target.zig");
const cache = @import("cache");
const cache_generation = cache.generation;
const cache_gc = cache.gc;
const cache_lease = cache.lease;
const cache_manifest = cache.manifest;
const cache_publish = cache.publish;
const cache_store = cache.store;

const c = @cImport({
    @cInclude("pdf.h");
});

const Allocator = std.mem.Allocator;
const Color = scene.Color;
const FontFace = scene.FontFace;

const NativePdfError = error{
    CairoCreateFailed,
    CairoFailed,
    PangoCreateFailed,
    ImageDecodeFailed,
    AssetConversionFailed,
    InvalidPdfCache,
};

const external_command_timeout = std.Io.Clock.Duration{
    .raw = std.Io.Duration.fromSeconds(120),
    .clock = .awake,
};

const DrawContext = struct {
    allocator: Allocator,
    io: std.Io,
    pdf: *c.SsPdf,
};

pub const RenderOptions = target.PdfOptions;

pub const RenderProgress = render_progress.Callback;

var temp_cache_counter: usize = 0;

pub fn renderSceneToPdfWithOptions(
    allocator: Allocator,
    io: std.Io,
    document: *const scene.Document,
    options: RenderOptions,
    progress: ?RenderProgress,
) ![]const u8 {
    try std.Io.Dir.cwd().createDirPath(io, options.cache_dir);

    const serial = @atomicRmw(usize, &temp_cache_counter, .Add, 1, .monotonic);
    const run_id = try std.fmt.allocPrint(allocator, "scene-run-{d}-{d}", .{ std.c.getpid(), serial });
    defer allocator.free(run_id);

    const run_dir = try std.fs.path.join(allocator, &.{ options.cache_dir, "runs", run_id });
    defer allocator.free(run_dir);
    const deck_id = try render_cache.deckId(allocator, document, options.cache_id);
    defer allocator.free(deck_id);
    const deck_dir = try std.fs.path.join(allocator, &.{ options.cache_dir, "decks", deck_id });
    defer allocator.free(deck_dir);
    const generations_dir = try std.fs.path.join(allocator, &.{ deck_dir, "generations" });
    defer allocator.free(generations_dir);
    const current_path = try std.fs.path.join(allocator, &.{ deck_dir, "current.json" });
    defer allocator.free(current_path);
    const building_name = try std.fmt.allocPrint(allocator, ".building-{s}", .{run_id});
    defer allocator.free(building_name);
    const generation_name = try std.fmt.allocPrint(allocator, "gen-{s}", .{run_id});
    defer allocator.free(generation_name);
    const building_dir = try std.fs.path.join(allocator, &.{ generations_dir, building_name });
    defer allocator.free(building_dir);
    const generation_dir = try std.fs.path.join(allocator, &.{ generations_dir, generation_name });
    defer allocator.free(generation_dir);
    const pages_dir = try std.fs.path.join(allocator, &.{ building_dir, "pages" });
    defer allocator.free(pages_dir);
    const leases_dir = try std.fs.path.join(allocator, &.{ options.cache_dir, "leases" });
    defer allocator.free(leases_dir);
    const lease_path = try std.fmt.allocPrint(allocator, "{s}/{s}.json", .{ leases_dir, run_id });
    defer allocator.free(lease_path);
    const final_pdf_path = try std.fs.path.join(allocator, &.{ run_dir, "document.pdf" });
    defer allocator.free(final_pdf_path);

    try std.Io.Dir.cwd().createDirPath(io, run_dir);
    try std.Io.Dir.cwd().createDirPath(io, generations_dir);
    try std.Io.Dir.cwd().createDirPath(io, pages_dir);
    try std.Io.Dir.cwd().createDirPath(io, leases_dir);
    defer if (!options.keep_temps) std.Io.Dir.cwd().deleteTree(io, run_dir) catch {};

    var generation_published = false;
    defer if (!generation_published and !options.keep_temps) std.Io.Dir.cwd().deleteTree(io, building_dir) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, lease_path) catch {};

    const previous_generation_id = try cache_generation.readCurrent(allocator, io, current_path);
    defer if (previous_generation_id) |id| allocator.free(id);
    var protected_buf: [1][]const u8 = undefined;
    const protected = if (previous_generation_id) |id| blk: {
        protected_buf[0] = id;
        break :blk protected_buf[0..1];
    } else protected_buf[0..0];
    try cache_lease.write(allocator, io, lease_path, .{
        .pid = @intCast(std.c.getpid()),
        .run_id = run_id,
        .owner_id = deck_id,
        .protected_generations = protected,
    });

    var previous_manifest: ?cache_manifest.PageManifest = null;
    var previous_pages_dir: ?[]u8 = null;
    if (previous_generation_id) |id| {
        const previous_dir = try std.fs.path.join(allocator, &.{ generations_dir, id });
        defer allocator.free(previous_dir);
        const manifest_path = try std.fs.path.join(allocator, &.{ previous_dir, "manifest.json" });
        defer allocator.free(manifest_path);
        previous_manifest = cache_manifest.readPageManifest(allocator, io, manifest_path) catch null;
        if (previous_manifest != null) previous_pages_dir = try std.fs.path.join(allocator, &.{ previous_dir, "pages" });
    }
    defer if (previous_manifest) |*manifest| manifest.deinit(allocator);
    defer if (previous_pages_dir) |path| allocator.free(path);

    var ctx = DrawContext{
        .allocator = allocator,
        .io = io,
        .pdf = undefined,
    };

    const page_count = document.pages.items.len;
    const hashes = try allocator.alloc(u64, page_count);
    defer allocator.free(hashes);
    const page_paths = try allocator.alloc([]const u8, page_count);
    defer {
        for (page_paths) |path| allocator.free(path);
        allocator.free(page_paths);
    }

    for (document.pages.items, 0..) |*page, index| {
        const page_hash = render_cache.pageHash(document, page);
        hashes[index] = page_hash;
        const page_path = try render_cache.pagePath(allocator, pages_dir, index);
        page_paths[index] = page_path;
        if (try reuseScenePage(&ctx, previous_manifest, previous_pages_dir, index, page_hash, page_path)) {
            if (progress) |p| p.pageCompleted(p.context, index + 1, page_count);
            continue;
        }
        try renderScenePagePdf(&ctx, document, page, page_path);
        if (progress) |p| p.pageCompleted(p.context, index + 1, page_count);
    }

    const manifest_path = try std.fs.path.join(allocator, &.{ building_dir, "manifest.json" });
    defer allocator.free(manifest_path);
    try cache_manifest.writePageManifest(allocator, io, manifest_path, hashes);

    if (progress) |p| p.assemblyCompleted(p.context, 0, 1);
    if (page_paths.len == 0) {
        try writeZeroPagePdf(&ctx, final_pdf_path);
    } else {
        try mergePdfInputs(&ctx, page_paths, true, final_pdf_path);
    }
    if (progress) |p| p.assemblyCompleted(p.context, 1, 1);

    try cache_generation.publishDirectory(io, building_dir, generation_dir);
    generation_published = true;
    try cache_generation.writeCurrent(allocator, io, current_path, generation_name);
    std.Io.Dir.cwd().deleteFile(io, lease_path) catch {};
    try cache_gc.pruneGenerationsExcept(allocator, io, generations_dir, leases_dir, generation_name);

    return std.Io.Dir.cwd().readFileAlloc(io, final_pdf_path, allocator, .unlimited);
}

fn reuseScenePage(
    ctx: *DrawContext,
    previous_manifest: ?cache_manifest.PageManifest,
    previous_pages_dir: ?[]const u8,
    page_index: usize,
    page_hash: u64,
    dest_path: []const u8,
) !bool {
    const manifest = previous_manifest orelse return false;
    const pages_dir = previous_pages_dir orelse return false;
    if (page_index >= manifest.hashes.len) return false;
    if (manifest.hashes[page_index] != page_hash) return false;
    const previous_path = try render_cache.pagePath(ctx.allocator, pages_dir, page_index);
    defer ctx.allocator.free(previous_path);
    if (!(try cachedPdfAvailable(ctx, previous_path))) return false;
    cache_publish.copyOrLink(ctx.io, previous_path, dest_path) catch return false;
    return cachedPdfAvailable(ctx, dest_path) catch false;
}

fn renderScenePagePdf(ctx: *DrawContext, document: *const scene.Document, page: *const scene.Page, out_path: []const u8) !void {
    const tmp = try cache_publish.tempPath(ctx.allocator, out_path, "pdf");
    defer ctx.allocator.free(tmp);
    errdefer cache_publish.deleteFileIfExists(ctx.io, tmp);

    const out_path_z = try ctx.allocator.dupeZ(u8, tmp);
    defer ctx.allocator.free(out_path_z);
    const pdf = c.ss_pdf_create(out_path_z.ptr, page.frame.width, page.frame.height) orelse return NativePdfError.CairoCreateFailed;
    defer c.ss_pdf_destroy(pdf);
    c.ss_pdf_set_creator(pdf, "ss native Cairo/Pango backend");

    var page_ctx = ctx.*;
    page_ctx.pdf = pdf;
    c.ss_pdf_begin_page(pdf, page.frame.width, page.frame.height);
    try drawScenePage(&page_ctx, document, page);
    c.ss_pdf_end_page(pdf);
    if (c.ss_pdf_finish(pdf) != 0) return NativePdfError.CairoFailed;

    try validatePdfFile(ctx, tmp);
    try cache_publish.publishFile(ctx.io, tmp, out_path);
}

fn drawScenePage(ctx: *DrawContext, document: *const scene.Document, page: *const scene.Page) !void {
    for (page.items.items) |item| {
        try drawSceneItem(ctx, document, item);
    }
}

fn drawSceneItem(ctx: *DrawContext, document: *const scene.Document, item: scene.Item) !void {
    switch (item) {
        .shape => |shape| try drawSceneShape(ctx, shape),
        .text => |text| try drawSceneText(ctx, document, text),
        .resource => |resource| try drawSceneResource(ctx, document, resource),
    }
}

fn drawSceneShape(ctx: *DrawContext, item: scene.ShapeItem) !void {
    if (item.clip) pushSceneClipRect(ctx.pdf, item.frame);
    defer if (item.clip) c.ss_pdf_pop_clip(ctx.pdf);

    if (item.fill == null and item.stroke != null and item.frame.height <= @max(item.line_width * 2, 2)) {
        const color = item.stroke.?;
        const y = item.frame.y + item.frame.height * 0.5;
        c.ss_pdf_stroke_line(
            ctx.pdf,
            item.frame.x,
            y,
            item.frame.x + item.frame.width,
            y,
            item.line_width,
            color.r,
            color.g,
            color.b,
            if (item.dash) |dash| dash.on else 0,
            if (item.dash) |dash| dash.off else 0,
        );
        return;
    }

    c.ss_pdf_fill_stroke_rounded_rect(
        ctx.pdf,
        item.frame.x,
        item.frame.y,
        item.frame.width,
        item.frame.height,
        item.radius,
        if (item.fill != null) 1 else 0,
        if (item.fill) |value| value.r else 0,
        if (item.fill) |value| value.g else 0,
        if (item.fill) |value| value.b else 0,
        if (item.stroke != null) 1 else 0,
        if (item.stroke) |value| value.r else 0,
        if (item.stroke) |value| value.g else 0,
        if (item.stroke) |value| value.b else 0,
        item.line_width,
    );
}

fn drawSceneText(ctx: *DrawContext, document: *const scene.Document, item: scene.TextItem) !void {
    if (item.clip) pushSceneClipRect(ctx.pdf, item.frame);
    defer if (item.clip) c.ss_pdf_pop_clip(ctx.pdf);

    for (item.lines.items) |line| {
        for (line.spans.items) |span| {
            switch (span) {
                .glyphs => |glyphs| {
                    const x = item.frame.x + glyphs.x;
                    const y_top = line.baseline_y - glyphs.font_size;
                    try drawSceneRawText(
                        ctx,
                        x,
                        y_top,
                        @max(item.frame.width - glyphs.x, 1),
                        @max(line.line_height, glyphs.font_size),
                        glyphs.text,
                        glyphs.font,
                        glyphs.font_size,
                        glyphs.color,
                        false,
                    );
                    if (glyphs.strikethrough) {
                        const y = y_top + glyphs.font_size * 0.55;
                        const line_width = @max(@as(f32, 1.0), glyphs.font_size * 0.065);
                        const text_width = try measureTextVisualWidth(ctx, glyphs.text, glyphs.font, glyphs.font_size);
                        c.ss_pdf_stroke_line(ctx.pdf, x, y, x + @max(text_width, glyphs.font_size), y, line_width, glyphs.color.r, glyphs.color.g, glyphs.color.b, 0, 0);
                    }
                },
                .resource => |resource| {
                    const frame = scene.Frame{
                        .x = item.frame.x + resource.x,
                        .y = item.frame.y + resource.y,
                        .width = resource.width,
                        .height = resource.height,
                    };
                    const found = document.resourceById(resource.resource_id) orelse continue;
                    switch (found.kind) {
                        .svg => if (resource.tint) |tint| try drawSceneSvgFrameTinted(ctx, frame, found.path, tint) else try drawSceneSvgFrame(ctx, frame, found.path),
                        .png => try drawScenePngFrame(ctx, frame, found.path),
                    }
                },
            }
        }
    }
}

fn drawSceneResource(ctx: *DrawContext, document: *const scene.Document, item: scene.ResourceItem) !void {
    const resource = document.resourceById(item.resource_id) orelse return;
    if (item.clip) pushSceneClipRect(ctx.pdf, item.frame);
    defer if (item.clip) c.ss_pdf_pop_clip(ctx.pdf);
    switch (resource.kind) {
        .svg => if (item.tint) |tint| try drawSceneSvgFrameTinted(ctx, item.frame, resource.path, tint) else try drawSceneSvgFrame(ctx, item.frame, resource.path),
        .png => try drawScenePngFrame(ctx, item.frame, resource.path),
    }
}

fn pushSceneClipRect(pdf: *c.SsPdf, frame: scene.Frame) void {
    c.ss_pdf_push_clip_rect(pdf, frame.x, frame.y, frame.width, frame.height);
}

fn drawSceneRawText(
    ctx: *DrawContext,
    x: f32,
    y_top: f32,
    width: f32,
    height: f32,
    content: []const u8,
    font: FontFace,
    font_size: f32,
    color: Color,
    wrap: bool,
) !void {
    const family_z = try ctx.allocator.dupeZ(u8, font.family);
    defer ctx.allocator.free(family_z);
    const content_z = try ctx.allocator.dupeZ(u8, content);
    defer ctx.allocator.free(content_z);
    const baseline_y = y_top + font_size;
    if (c.ss_pdf_draw_text_baseline(
        ctx.pdf,
        x,
        baseline_y,
        y_top,
        width,
        height,
        content_z.ptr,
        family_z.ptr,
        @intCast(font.weight),
        core.font.styleCode(font.style),
        core.font.stretchCode(font.stretch),
        font_size,
        color.r,
        color.g,
        color.b,
        if (wrap) 1 else 0,
    ) != 0) return NativePdfError.PangoCreateFailed;
}

fn measureTextVisualWidth(ctx: *DrawContext, content: []const u8, font: FontFace, font_size: f32) !f32 {
    const family_z = try ctx.allocator.dupeZ(u8, font.family);
    defer ctx.allocator.free(family_z);
    const content_z = try ctx.allocator.dupeZ(u8, content);
    defer ctx.allocator.free(content_z);
    return @floatCast(c.ss_pdf_measure_text_visual_width(
        ctx.pdf,
        content_z.ptr,
        family_z.ptr,
        @intCast(font.weight),
        core.font.styleCode(font.style),
        core.font.stretchCode(font.stretch),
        font_size,
    ));
}

fn drawSceneSvgFrame(ctx: *DrawContext, frame: scene.Frame, svg_path: []const u8) !void {
    const svg_z = try ctx.allocator.dupeZ(u8, svg_path);
    defer ctx.allocator.free(svg_z);
    if (c.ss_pdf_draw_svg(ctx.pdf, svg_z.ptr, frame.x, frame.y, frame.width, frame.height) != 0) return NativePdfError.ImageDecodeFailed;
}

fn drawSceneSvgFrameTinted(ctx: *DrawContext, frame: scene.Frame, svg_path: []const u8, color: Color) !void {
    const svg_z = try ctx.allocator.dupeZ(u8, svg_path);
    defer ctx.allocator.free(svg_z);
    if (c.ss_pdf_draw_svg_tinted(ctx.pdf, svg_z.ptr, frame.x, frame.y, frame.width, frame.height, color.r, color.g, color.b) != 0) return NativePdfError.ImageDecodeFailed;
}

fn drawScenePngFrame(ctx: *DrawContext, frame: scene.Frame, png_path: []const u8) !void {
    const png_z = try ctx.allocator.dupeZ(u8, png_path);
    defer ctx.allocator.free(png_z);
    if (c.ss_pdf_draw_png(ctx.pdf, png_z.ptr, frame.x, frame.y, frame.width, frame.height) != 0) return NativePdfError.ImageDecodeFailed;
}

fn mergePdfInputs(ctx: *DrawContext, inputs: []const []const u8, single_page_inputs: bool, output: []const u8) !void {
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(ctx.allocator);
    try argv.append(ctx.allocator, "qpdf");
    try argv.append(ctx.allocator, "--deterministic-id");
    try argv.append(ctx.allocator, "--empty");
    try argv.append(ctx.allocator, "--pages");
    for (inputs) |input| {
        try argv.append(ctx.allocator, input);
        if (single_page_inputs) try argv.append(ctx.allocator, "1");
    }
    try argv.append(ctx.allocator, "--");
    try argv.append(ctx.allocator, output);
    try runCheckedAllowQpdfWarnings(ctx, argv.items, .inherit);
    try validatePdfFile(ctx, output);
}

fn writeZeroPagePdf(ctx: *DrawContext, output: []const u8) !void {
    try runCheckedAllowQpdfWarnings(ctx, &.{ "qpdf", "--deterministic-id", "--empty", output }, .inherit);
    try validatePdfFile(ctx, output);
}

fn cachedPdfAvailable(ctx: *DrawContext, path: []const u8) !bool {
    if (!cache_store.fileExists(path)) return false;
    validatePdfFile(ctx, path) catch |err| switch (err) {
        error.InvalidPdfCache => {
            cache_publish.deleteFileIfExists(ctx.io, path);
            return false;
        },
        else => return err,
    };
    return true;
}

fn validatePdfFile(ctx: *DrawContext, path: []const u8) !void {
    var file = std.Io.Dir.cwd().openFile(ctx.io, path, .{}) catch return NativePdfError.InvalidPdfCache;
    defer file.close(ctx.io);

    const stat = file.stat(ctx.io) catch return NativePdfError.InvalidPdfCache;
    if (stat.kind != .file or stat.size < 8) return NativePdfError.InvalidPdfCache;

    var header: [5]u8 = undefined;
    var header_vec = [_][]u8{header[0..]};
    const header_len = file.readPositional(ctx.io, header_vec[0..], 0) catch return NativePdfError.InvalidPdfCache;
    if (header_len != header.len or !std.mem.eql(u8, header[0..], "%PDF-")) return NativePdfError.InvalidPdfCache;

    const tail_len_u64 = @min(stat.size, 4096);
    const tail_len: usize = @intCast(tail_len_u64);
    const tail = try ctx.allocator.alloc(u8, tail_len);
    defer ctx.allocator.free(tail);
    var tail_vec = [_][]u8{tail};
    const tail_offset = stat.size - tail_len_u64;
    const read_len = file.readPositional(ctx.io, tail_vec[0..], tail_offset) catch return NativePdfError.InvalidPdfCache;
    if (read_len == 0) return NativePdfError.InvalidPdfCache;
    if (std.mem.indexOf(u8, tail[0..read_len], "%%EOF") == null) return NativePdfError.InvalidPdfCache;
}

fn runCheckedAllowQpdfWarnings(ctx: *DrawContext, argv: []const []const u8, cwd: std.process.Child.Cwd) !void {
    const result = std.process.run(ctx.allocator, ctx.io, .{
        .argv = argv,
        .cwd = cwd,
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(128 * 1024),
        .timeout = .{ .duration = external_command_timeout },
    }) catch |err| {
        std.debug.print("native pdf: failed to run command ({s}):", .{@errorName(err)});
        for (argv) |arg| std.debug.print(" {s}", .{arg});
        std.debug.print("\n", .{});
        return NativePdfError.AssetConversionFailed;
    };
    defer ctx.allocator.free(result.stdout);
    defer ctx.allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code == 0 or code == 3) return,
        else => {},
    }
    std.debug.print("native pdf: command failed (", .{});
    switch (result.term) {
        .exited => |code| std.debug.print("exit {d}", .{code}),
        .signal => |signal| std.debug.print("signal {d}", .{@intFromEnum(signal)}),
        .stopped => |signal| std.debug.print("stopped {d}", .{@intFromEnum(signal)}),
        .unknown => |code| std.debug.print("unknown {d}", .{code}),
    }
    std.debug.print("):", .{});
    for (argv) |arg| std.debug.print(" {s}", .{arg});
    if (result.stdout.len > 0) std.debug.print("\nstdout:\n{s}", .{result.stdout});
    std.debug.print("\nstderr:\n{s}\n", .{result.stderr});
    return NativePdfError.AssetConversionFailed;
}
