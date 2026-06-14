const std = @import("std");
const core = @import("core");

const declarations = @import("../language/declarations.zig");
const semantic_env = @import("../language/env.zig");
const wrap_layout = core.render_wrap;

const c = @cImport({
    @cInclude("pdf.h");
});

const Allocator = std.mem.Allocator;
const Color = core.render_policy.Color;
const Frame = core.Frame;
const PageLayout = core.PageLayout;
const RenderKind = core.render_policy.RenderKind;
const HorizontalAlign = core.render_policy.HorizontalAlign;
const FontFace = core.font.Face;
const ResolvedRender = core.render_policy.ResolvedRender;
const TextPaint = core.render_policy.TextPaint;
const CodePaint = core.render_policy.CodePaint;
const MathPaint = core.render_policy.MathPaint;
const MarkdownDocument = core.markdown.MarkdownDocument;
const Line = core.markdown.Line;
const Block = core.markdown.Block;
const Run = core.markdown.Run;
const TexPreambleEntry = core.render_env.TexPreambleEntry;

const NativePdfError = error{
    CairoCreateFailed,
    CairoFailed,
    PangoCreateFailed,
    ImageDecodeFailed,
    AssetConversionFailed,
    InvalidPdfCache,
    InvalidFontAwesomeIcon,
    UnsupportedAssetType,
};

const raster_cache_scale: f32 = 3.0;
const page_pdf_cache_version = "ss-native-page-pdf-v10";
const qpdf_cache_version = "ss-native-qpdf-v1";
const native_artifact_cache_version = "ss-native-artifacts-v2";
const external_command_timeout = std.Io.Clock.Duration{
    .raw = std.Io.Duration.fromSeconds(120),
    .clock = .awake,
};
const warm_render_job_cap: usize = 4;
const cold_render_job_cap: usize = 16;
const artifact_job_slack: usize = 2;

const DrawContext = struct {
    allocator: Allocator,
    io: std.Io,
    pdf: *c.SsPdf,
    asset_base_dir: []const u8,
    cache_dir: []const u8,
};

const Atom = struct {
    kind: enum { text, math, icon } = .text,
    text: []const u8,
    font: FontFace,
    color: Color,
    width: f32,
    height: f32 = 0,
    is_space: bool,
    is_emoji: bool = false,
    strikethrough: bool = false,
    svg_path: ?[]const u8 = null,
    link_url: ?[]const u8 = null,
};

const AtomPaint = struct {
    font_size: f32,
    line_height: f32,
    emoji_spacing: f32,
    inline_math_spacing: f32,
};

const MathKind = enum { inline_math, display, block, raw_block };

const SvgAsset = struct {
    path: []const u8,
    width: f32,
    height: f32,
};

const IconSpec = struct {
    style: []const u8,
    name: []const u8,
};

const PreloadTask = union(enum) {
    math: MathPreload,
    icon: []const u8,
    vector_pdf: []const u8,
    raster: RasterPreload,
};

const MathPreload = struct {
    source: []const u8,
    preamble: []const TexPreambleEntry,
    kind: MathKind,
};

const RasterPreload = struct {
    source: []const u8,
    target_width: f32,
    target_height: f32,
};

pub const RenderOptions = struct {
    jobs: ?usize = null,
    keep_temps: bool = false,
    cache_dir: []const u8 = ".ss-cache/render",
    cache_id: ?[]const u8 = null,
};

const RenderOp = struct {
    node_id: core.NodeId,
    frame: Frame,
    content: []const u8,
    link_id: ?[]const u8 = null,
    render: ResolvedRender,
    parse_mode: core.markdown.ParseMode,
    tex_preamble: []const TexPreambleEntry,
    math_kind: MathKind = .block,

    fn deinit(self: *RenderOp, allocator: Allocator) void {
        allocator.free(self.tex_preamble);
    }
};

const RenderPage = struct {
    page_id: core.NodeId,
    index: usize,
    background: ?Color,
    ops: []RenderOp,
    artifact_deps: []usize,
    page_hash: u64,
    render_path: []const u8,
    cache_path: []const u8,
    cache_hit: bool,

    fn deinit(self: *RenderPage, allocator: Allocator) void {
        for (self.ops) |*op| op.deinit(allocator);
        allocator.free(self.ops);
        allocator.free(self.artifact_deps);
        allocator.free(self.render_path);
        allocator.free(self.cache_path);
    }
};

const RenderPlan = struct {
    allocator: Allocator,
    pages: []RenderPage,
    artifact_tasks: []PreloadTask,
    artifact_cached: []bool,
    artifact_miss_count: usize,
    page_cache_hit_count: usize,
    run_dir: []const u8,
    generations_dir: []const u8,
    building_dir: []const u8,
    generation_dir: []const u8,
    trash_dir: []const u8,
    leases_dir: []const u8,
    pages_dir: []const u8,
    final_pdf_path: []const u8,
    current_path: []const u8,
    lease_path: []const u8,
    generation_published: bool = false,

    fn deinit(self: *RenderPlan) void {
        for (self.pages) |*page| page.deinit(self.allocator);
        self.allocator.free(self.pages);
        freePreloadTasks(self.allocator, self.artifact_tasks);
        self.allocator.free(self.artifact_tasks);
        self.allocator.free(self.artifact_cached);
        self.allocator.free(self.run_dir);
        self.allocator.free(self.generations_dir);
        self.allocator.free(self.building_dir);
        self.allocator.free(self.generation_dir);
        self.allocator.free(self.trash_dir);
        self.allocator.free(self.leases_dir);
        self.allocator.free(self.pages_dir);
        self.allocator.free(self.final_pdf_path);
        self.allocator.free(self.current_path);
        self.allocator.free(self.lease_path);
    }
};

const PreloadCacheState = struct {
    cached: []bool,
    miss_count: usize,
};

const FileFingerprint = struct {
    present: bool,
    digest: u64,
};

const PageManifest = struct {
    hashes: []u64,

    fn deinit(self: *PageManifest, allocator: Allocator) void {
        allocator.free(self.hashes);
    }
};

const PreviousGeneration = struct {
    id: []u8,
    dir: []u8,
    manifest: PageManifest,

    fn deinit(self: *PreviousGeneration, allocator: Allocator) void {
        allocator.free(self.id);
        allocator.free(self.dir);
        self.manifest.deinit(allocator);
    }
};

const PreloadWork = struct {
    tasks: []const PreloadTask,
    next_index: std.atomic.Value(usize) = .init(0),
    completed: std.atomic.Value(usize) = .init(0),
    failed: std.atomic.Value(bool) = .init(false),
    io: std.Io,
    pdf: *c.SsPdf,
    asset_base_dir: []const u8,
    cache_dir: []const u8,
};

pub const RenderProgress = struct {
    context: *anyopaque,
    artifactCompleted: *const fn (context: *anyopaque, completed: usize, total: usize) void,
    pageCompleted: *const fn (context: *anyopaque, completed: usize, total: usize) void,
    assemblyCompleted: *const fn (context: *anyopaque, completed: usize, total: usize) void,
};

const RenderDag = struct {
    plan: *const RenderPlan,
    next_artifact: std.atomic.Value(usize) = .init(0),
    completed_artifacts: std.atomic.Value(usize) = .init(0),
    completed_pages: std.atomic.Value(usize) = .init(0),
    failed: std.atomic.Value(bool) = .init(false),
    artifact_done: []std.atomic.Value(bool),
    page_claimed: []std.atomic.Value(bool),
    page_done: []std.atomic.Value(bool),
    io: std.Io,
    asset_base_dir: []const u8,
    cache_dir: []const u8,
    progress: ?RenderProgress,
};

const MergeChunk = struct {
    inputs: []const []const u8,
    output: []const u8,
    single_page_inputs: bool,
};

const MergeWork = struct {
    chunks: []const MergeChunk,
    next_index: std.atomic.Value(usize) = .init(0),
    completed: std.atomic.Value(usize) = .init(0),
    failed: std.atomic.Value(bool) = .init(false),
    io: std.Io,
    cache_dir: []const u8,
    progress: ?RenderProgress,
    progress_offset: usize,
    progress_total: usize,
};

var temp_cache_counter: usize = 0;

pub fn renderDocumentToPdf(allocator: Allocator, io: std.Io, ir: *core.Ir) ![]const u8 {
    return renderDocumentToPdfWithOptions(allocator, io, ir, .{}, null);
}

pub fn renderDocumentToPdfWithProgress(allocator: Allocator, io: std.Io, ir: *core.Ir, progress: ?RenderProgress) ![]const u8 {
    return renderDocumentToPdfWithOptions(allocator, io, ir, .{}, progress);
}

pub fn renderDocumentToPdfWithOptions(allocator: Allocator, io: std.Io, ir: *core.Ir, options: RenderOptions, progress: ?RenderProgress) ![]const u8 {
    try std.Io.Dir.cwd().createDirPath(io, options.cache_dir);
    const asset_cache_dir = try std.fs.path.join(allocator, &.{ options.cache_dir, "artifacts", "native" });
    defer allocator.free(asset_cache_dir);
    try std.Io.Dir.cwd().createDirPath(io, asset_cache_dir);

    var ctx = DrawContext{
        .allocator = allocator,
        .io = io,
        .pdf = undefined,
        .asset_base_dir = if (ir.asset_base_dir.len == 0) "." else ir.asset_base_dir,
        .cache_dir = asset_cache_dir,
    };

    var declaration_index = try declarations.build(allocator, ir);
    defer declaration_index.deinit();
    const sema = semantic_env.SemanticEnv.init(ir, &declaration_index, &ir.functions);

    var plan = try buildRenderPlan(&ctx, ir, &sema, options);
    defer {
        if (!options.keep_temps) std.Io.Dir.cwd().deleteTree(io, plan.run_dir) catch {};
        if (!plan.generation_published and !options.keep_temps) std.Io.Dir.cwd().deleteTree(io, plan.building_dir) catch {};
        std.Io.Dir.cwd().deleteFile(io, plan.lease_path) catch {};
        plan.deinit();
    }

    try executeRenderDag(&ctx, &plan, options, progress);
    try writeRenderManifest(&ctx, &plan);
    try assembleRenderPlan(&ctx, &plan, options, progress);
    try publishRenderGeneration(&ctx, &plan);

    return try std.Io.Dir.cwd().readFileAlloc(io, plan.final_pdf_path, allocator, .unlimited);
}

fn buildRenderPlan(ctx: *DrawContext, ir: *core.Ir, sema: anytype, options: RenderOptions) !RenderPlan {
    const nonce = std.hash.Wyhash.hash(0, ir.projectSource());
    const pid = std.c.getpid();
    const serial = @atomicRmw(usize, &temp_cache_counter, .Add, 1, .monotonic);
    const run_id = try std.fmt.allocPrint(ctx.allocator, "run-{d}-{x}-{d}", .{ pid, nonce, serial });
    defer ctx.allocator.free(run_id);
    const run_dir = try std.fs.path.join(ctx.allocator, &.{ options.cache_dir, "runs", run_id });
    errdefer ctx.allocator.free(run_dir);
    const deck_id = try renderDeckId(ctx.allocator, ir, options);
    defer ctx.allocator.free(deck_id);
    const deck_dir = try std.fs.path.join(ctx.allocator, &.{ options.cache_dir, "decks", deck_id });
    defer ctx.allocator.free(deck_dir);
    const generations_dir = try std.fs.path.join(ctx.allocator, &.{ deck_dir, "generations" });
    errdefer ctx.allocator.free(generations_dir);
    const current_path = try std.fs.path.join(ctx.allocator, &.{ deck_dir, "current.json" });
    errdefer ctx.allocator.free(current_path);
    const building_name = try std.fmt.allocPrint(ctx.allocator, ".building-{s}", .{run_id});
    defer ctx.allocator.free(building_name);
    const generation_name = try std.fmt.allocPrint(ctx.allocator, "gen-{s}", .{run_id});
    defer ctx.allocator.free(generation_name);
    const building_dir = try std.fs.path.join(ctx.allocator, &.{ generations_dir, building_name });
    errdefer ctx.allocator.free(building_dir);
    const generation_dir = try std.fs.path.join(ctx.allocator, &.{ generations_dir, generation_name });
    errdefer ctx.allocator.free(generation_dir);
    const pages_dir = try std.fs.path.join(ctx.allocator, &.{ building_dir, "pages" });
    errdefer ctx.allocator.free(pages_dir);
    const final_pdf_path = try std.fs.path.join(ctx.allocator, &.{ run_dir, "document.pdf" });
    errdefer ctx.allocator.free(final_pdf_path);
    const trash_dir = try std.fs.path.join(ctx.allocator, &.{ options.cache_dir, "trash" });
    errdefer ctx.allocator.free(trash_dir);
    const leases_dir = try std.fs.path.join(ctx.allocator, &.{ options.cache_dir, "leases" });
    errdefer ctx.allocator.free(leases_dir);
    const lease_path = try std.fmt.allocPrint(ctx.allocator, "{s}/{s}.json", .{ leases_dir, run_id });
    errdefer ctx.allocator.free(lease_path);

    try std.Io.Dir.cwd().createDirPath(ctx.io, leases_dir);
    try writeLeaseFile(ctx, lease_path, deck_id, run_id, null);
    errdefer std.Io.Dir.cwd().deleteFile(ctx.io, lease_path) catch {};
    try std.Io.Dir.cwd().createDirPath(ctx.io, run_dir);
    try std.Io.Dir.cwd().createDirPath(ctx.io, generations_dir);
    try std.Io.Dir.cwd().createDirPath(ctx.io, pages_dir);
    try std.Io.Dir.cwd().createDirPath(ctx.io, trash_dir);

    var previous_generation = try readPreviousGeneration(ctx, generations_dir, current_path);
    defer if (previous_generation) |*previous| previous.deinit(ctx.allocator);

    var pages = std.ArrayList(RenderPage).empty;
    errdefer {
        for (pages.items) |*page| page.deinit(ctx.allocator);
        pages.deinit(ctx.allocator);
    }

    var tasks = std.ArrayList(PreloadTask).empty;
    errdefer {
        freePreloadTasks(ctx.allocator, tasks.items);
        tasks.deinit(ctx.allocator);
    }

    var seen = std.StringHashMap(usize).init(ctx.allocator);
    defer {
        var key_it = seen.keyIterator();
        while (key_it.next()) |key| ctx.allocator.free(key.*);
        seen.deinit();
    }

    var asset_fingerprints = std.StringHashMap(FileFingerprint).init(ctx.allocator);
    defer {
        var key_it = asset_fingerprints.keyIterator();
        while (key_it.next()) |key| ctx.allocator.free(key.*);
        asset_fingerprints.deinit();
    }

    for (ir.page_order.items, 0..) |page_id, page_index| {
        const page = ir.getNode(page_id) orelse continue;
        var ops = std.ArrayList(RenderOp).empty;
        errdefer {
            for (ops.items) |*op| op.deinit(ctx.allocator);
            ops.deinit(ctx.allocator);
        }
        var deps = std.ArrayList(usize).empty;
        errdefer deps.deinit(ctx.allocator);

        if (ir.contains.get(page.id)) |children| {
            for (children.items) |child_id| {
                const node = ir.getNode(child_id) orelse continue;
                if (node.kind != .object or !node.attached) continue;
                var env = try core.render_env.resolveForNode(ctx.allocator, ir, node);
                defer env.deinit(ctx.allocator);
                var op = RenderOp{
                    .node_id = node.id,
                    .frame = node.frame,
                    .content = node.content orelse "",
                    .link_id = core.nodeProperty(node, "link_id"),
                    .render = core.render_policy.resolveWithEnv(ir, node, sema),
                    .parse_mode = core.markdown.parseModeForNode(ir, node),
                    .tex_preamble = try cloneTexPreambleEntries(ctx.allocator, env.tex_preamble.items),
                    .math_kind = mathKindForNode(node),
                };
                errdefer op.deinit(ctx.allocator);
                try collectOpPreloads(ctx, &op, &tasks, &seen, &deps);
                try ops.append(ctx.allocator, op);
            }
        }

        const page_background = core.render_policy.resolvePageBackgroundWithEnv(ir, page, sema);
        const op_slice = try ops.toOwnedSlice(ctx.allocator);
        var op_slice_transferred = false;
        errdefer {
            if (!op_slice_transferred) {
                for (op_slice) |*op| op.deinit(ctx.allocator);
                ctx.allocator.free(op_slice);
            }
        }
        const dep_slice = try deps.toOwnedSlice(ctx.allocator);
        var dep_slice_transferred = false;
        errdefer if (!dep_slice_transferred) ctx.allocator.free(dep_slice);
        const page_hash = try renderPageHash(ctx, &asset_fingerprints, page_background, op_slice);
        const cache_path = try pagePath(ctx.allocator, pages_dir, page_index);
        var cache_path_transferred = false;
        errdefer if (!cache_path_transferred) ctx.allocator.free(cache_path);
        const render_path = try tempCachePath(ctx, cache_path, "pdf");
        var render_path_transferred = false;
        errdefer if (!render_path_transferred) ctx.allocator.free(render_path);
        const cache_hit = try reusePreviousPage(ctx, if (previous_generation) |*previous| previous else null, page_index, page_hash, cache_path);
        try pages.append(ctx.allocator, .{
            .page_id = page.id,
            .index = page_index,
            .background = page_background,
            .ops = op_slice,
            .artifact_deps = dep_slice,
            .page_hash = page_hash,
            .render_path = render_path,
            .cache_path = cache_path,
            .cache_hit = cache_hit,
        });
        op_slice_transferred = true;
        dep_slice_transferred = true;
        cache_path_transferred = true;
        render_path_transferred = true;
    }

    const page_slice = try pages.toOwnedSlice(ctx.allocator);
    errdefer {
        for (page_slice) |*page| page.deinit(ctx.allocator);
        ctx.allocator.free(page_slice);
    }
    const artifact_slice = try tasks.toOwnedSlice(ctx.allocator);
    errdefer freePreloadTasks(ctx.allocator, artifact_slice);
    const page_cache_hit_count = countPageCacheHits(page_slice);
    const artifact_cache = try buildPreloadCacheStateForPages(ctx, artifact_slice, page_slice);
    errdefer ctx.allocator.free(artifact_cache.cached);

    return .{
        .allocator = ctx.allocator,
        .pages = page_slice,
        .artifact_tasks = artifact_slice,
        .artifact_cached = artifact_cache.cached,
        .artifact_miss_count = artifact_cache.miss_count,
        .page_cache_hit_count = page_cache_hit_count,
        .run_dir = run_dir,
        .generations_dir = generations_dir,
        .building_dir = building_dir,
        .generation_dir = generation_dir,
        .trash_dir = trash_dir,
        .leases_dir = leases_dir,
        .pages_dir = pages_dir,
        .final_pdf_path = final_pdf_path,
        .current_path = current_path,
        .lease_path = lease_path,
    };
}

fn countPageCacheHits(pages: []const RenderPage) usize {
    var count: usize = 0;
    for (pages) |page| {
        if (page.cache_hit) count += 1;
    }
    return count;
}

fn renderDeckId(allocator: Allocator, ir: *const core.Ir, options: RenderOptions) ![]u8 {
    var hasher = std.hash.Wyhash.init(0);
    hashString(&hasher, "ss-render-deck-v1");
    if (options.cache_id) |cache_id| {
        hashString(&hasher, cache_id);
    } else {
        hashString(&hasher, ir.projectPath());
        hashString(&hasher, if (ir.asset_base_dir.len == 0) "." else ir.asset_base_dir);
    }
    return std.fmt.allocPrint(allocator, "deck-{x}", .{hasher.final()});
}

fn pagePath(allocator: Allocator, pages_dir: []const u8, page_index: usize) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/page-{d:0>4}.pdf", .{ pages_dir, page_index + 1 });
}

fn readPreviousGeneration(ctx: *DrawContext, generations_dir: []const u8, current_path: []const u8) !?PreviousGeneration {
    const id = try readCurrentGenerationId(ctx, current_path) orelse return null;
    errdefer ctx.allocator.free(id);
    if (!safeCacheName(id)) {
        ctx.allocator.free(id);
        return null;
    }
    const dir = try std.fs.path.join(ctx.allocator, &.{ generations_dir, id });
    errdefer ctx.allocator.free(dir);
    var manifest = readPageManifest(ctx, dir) catch {
        ctx.allocator.free(id);
        ctx.allocator.free(dir);
        return null;
    };
    errdefer manifest.deinit(ctx.allocator);
    return .{
        .id = id,
        .dir = dir,
        .manifest = manifest,
    };
}

fn readCurrentGenerationId(ctx: *DrawContext, current_path: []const u8) !?[]u8 {
    const text = std.Io.Dir.cwd().readFileAlloc(ctx.io, current_path, ctx.allocator, .limited(64 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer ctx.allocator.free(text);
    var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, text, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const value = parsed.value.object.getPtr("generation") orelse return null;
    if (value.* != .string) return null;
    return try ctx.allocator.dupe(u8, value.string);
}

fn readPageManifest(ctx: *DrawContext, generation_dir: []const u8) !PageManifest {
    const path = try std.fs.path.join(ctx.allocator, &.{ generation_dir, "manifest.json" });
    defer ctx.allocator.free(path);
    const text = try std.Io.Dir.cwd().readFileAlloc(ctx.io, path, ctx.allocator, .limited(1024 * 1024));
    defer ctx.allocator.free(text);
    var parsed = try std.json.parseFromSlice(std.json.Value, ctx.allocator, text, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidRenderCacheManifest;
    const value = parsed.value.object.getPtr("pageHashes") orelse return error.InvalidRenderCacheManifest;
    if (value.* != .array) return error.InvalidRenderCacheManifest;
    const hashes = try ctx.allocator.alloc(u64, value.array.items.len);
    errdefer ctx.allocator.free(hashes);
    for (value.array.items, 0..) |item, index| {
        if (item != .string) return error.InvalidRenderCacheManifest;
        hashes[index] = std.fmt.parseUnsigned(u64, item.string, 16) catch return error.InvalidRenderCacheManifest;
    }
    return .{ .hashes = hashes };
}

fn safeCacheName(name: []const u8) bool {
    if (name.len == 0 or name.len > 160) return false;
    for (name) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.') continue;
        return false;
    }
    return true;
}

fn reusePreviousPage(ctx: *DrawContext, previous: ?*const PreviousGeneration, page_index: usize, page_hash: u64, dest_path: []const u8) !bool {
    const generation = previous orelse return false;
    if (page_index >= generation.manifest.hashes.len) return false;
    if (generation.manifest.hashes[page_index] != page_hash) return false;
    const previous_pages_dir = try std.fs.path.join(ctx.allocator, &.{ generation.dir, "pages" });
    defer ctx.allocator.free(previous_pages_dir);
    const previous_path = try pagePath(ctx.allocator, previous_pages_dir, page_index);
    defer ctx.allocator.free(previous_path);
    if (!(try cachedPdfAvailable(ctx, previous_path))) return false;
    copyOrLinkCacheFile(ctx, previous_path, dest_path) catch return false;
    return cachedPdfAvailable(ctx, dest_path) catch false;
}

fn copyOrLinkCacheFile(ctx: *DrawContext, source_path: []const u8, dest_path: []const u8) !void {
    if (fileExists(dest_path)) return;
    const cwd = std.Io.Dir.cwd();
    cwd.hardLink(source_path, cwd, dest_path, ctx.io, .{}) catch {
        try cwd.copyFile(source_path, cwd, dest_path, ctx.io, .{ .make_path = true, .replace = true });
    };
}

fn writeLeaseFile(ctx: *DrawContext, lease_path: []const u8, deck_id: []const u8, run_id: []const u8, previous_generation: ?[]const u8) !void {
    const tmp = try tempCachePath(ctx, lease_path, "json");
    defer ctx.allocator.free(tmp);
    errdefer deleteFileIfExists(ctx, tmp);
    var out = std.ArrayList(u8).empty;
    defer out.deinit(ctx.allocator);
    try out.appendSlice(ctx.allocator, "{\"schema\":1,\"pid\":");
    try appendUnsignedJson(ctx.allocator, &out, @as(u64, @intCast(std.c.getpid())));
    try out.appendSlice(ctx.allocator, ",\"runId\":");
    try appendJsonString(ctx.allocator, &out, run_id);
    try out.appendSlice(ctx.allocator, ",\"deckId\":");
    try appendJsonString(ctx.allocator, &out, deck_id);
    try out.appendSlice(ctx.allocator, ",\"protectedGenerations\":[");
    if (previous_generation) |id| try appendJsonString(ctx.allocator, &out, id);
    try out.appendSlice(ctx.allocator, "]}");
    try std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = tmp, .data = out.items, .flags = .{ .truncate = true } });
    try renameReplacing(ctx, tmp, lease_path);
}

fn writeRenderManifest(ctx: *DrawContext, plan: *const RenderPlan) !void {
    const path = try std.fs.path.join(ctx.allocator, &.{ plan.building_dir, "manifest.json" });
    defer ctx.allocator.free(path);
    const tmp = try tempCachePath(ctx, path, "json");
    defer ctx.allocator.free(tmp);
    errdefer deleteFileIfExists(ctx, tmp);
    var out = std.ArrayList(u8).empty;
    defer out.deinit(ctx.allocator);
    try out.appendSlice(ctx.allocator, "{\"schema\":1,\"pageHashes\":[");
    for (plan.pages, 0..) |page, index| {
        if (index != 0) try out.append(ctx.allocator, ',');
        try out.append(ctx.allocator, '"');
        const text = try std.fmt.allocPrint(ctx.allocator, "{x}", .{page.page_hash});
        defer ctx.allocator.free(text);
        try out.appendSlice(ctx.allocator, text);
        try out.append(ctx.allocator, '"');
    }
    try out.appendSlice(ctx.allocator, "]}");
    try std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = tmp, .data = out.items, .flags = .{ .truncate = true } });
    try renameReplacing(ctx, tmp, path);
}

fn publishRenderGeneration(ctx: *DrawContext, plan: *RenderPlan) !void {
    const cwd = std.Io.Dir.cwd();
    try cwd.rename(plan.building_dir, cwd, plan.generation_dir, ctx.io);
    errdefer cwd.deleteTree(ctx.io, plan.generation_dir) catch {};
    const generation_id = std.fs.path.basename(plan.generation_dir);
    try writeCurrentGeneration(ctx, plan.current_path, generation_id);
    plan.generation_published = true;
    std.Io.Dir.cwd().deleteFile(ctx.io, plan.lease_path) catch {};
    pruneOldGenerations(ctx, plan) catch {};
}

fn writeCurrentGeneration(ctx: *DrawContext, current_path: []const u8, generation_id: []const u8) !void {
    const tmp = try tempCachePath(ctx, current_path, "json");
    defer ctx.allocator.free(tmp);
    errdefer deleteFileIfExists(ctx, tmp);
    var out = std.ArrayList(u8).empty;
    defer out.deinit(ctx.allocator);
    try out.appendSlice(ctx.allocator, "{\"schema\":1,\"generation\":");
    try appendJsonString(ctx.allocator, &out, generation_id);
    try out.appendSlice(ctx.allocator, "}");
    try std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = tmp, .data = out.items, .flags = .{ .truncate = true } });
    try renameReplacing(ctx, tmp, current_path);
}

fn pruneOldGenerations(ctx: *DrawContext, plan: *const RenderPlan) !void {
    try pruneStaleLeases(ctx, plan.leases_dir);
    if (try activeRenderLeaseExists(ctx, plan.leases_dir)) return;
    var dir = std.Io.Dir.cwd().openDir(ctx.io, plan.generations_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close(ctx.io);
    var iterator = dir.iterate();
    const current = std.fs.path.basename(plan.generation_dir);
    while (try iterator.next(ctx.io)) |entry| {
        if (entry.kind != .directory) continue;
        if (std.mem.eql(u8, entry.name, current)) continue;
        if (std.mem.startsWith(u8, entry.name, ".building-")) continue;
        const victim = try std.fs.path.join(ctx.allocator, &.{ plan.generations_dir, entry.name });
        defer ctx.allocator.free(victim);
        const trash_name = try std.fmt.allocPrint(ctx.allocator, "{s}-{d}-{d}", .{ entry.name, std.c.getpid(), @atomicRmw(usize, &temp_cache_counter, .Add, 1, .monotonic) });
        defer ctx.allocator.free(trash_name);
        const trash_path = try std.fs.path.join(ctx.allocator, &.{ plan.trash_dir, trash_name });
        defer ctx.allocator.free(trash_path);
        std.Io.Dir.cwd().rename(victim, std.Io.Dir.cwd(), trash_path, ctx.io) catch continue;
        std.Io.Dir.cwd().deleteTree(ctx.io, trash_path) catch {};
    }
}

fn pruneStaleLeases(ctx: *DrawContext, leases_dir: []const u8) !void {
    var dir = std.Io.Dir.cwd().openDir(ctx.io, leases_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close(ctx.io);
    var iterator = dir.iterate();
    while (try iterator.next(ctx.io)) |entry| {
        if (entry.kind != .file) continue;
        if (!isFinalLeaseFile(entry.name)) continue;
        const lease_path = try std.fs.path.join(ctx.allocator, &.{ leases_dir, entry.name });
        defer ctx.allocator.free(lease_path);
        if (try leaseBelongsToLiveProcess(ctx, lease_path)) continue;
        deleteFileIfExists(ctx, lease_path);
    }
}

fn activeRenderLeaseExists(ctx: *DrawContext, leases_dir: []const u8) !bool {
    var dir = std.Io.Dir.cwd().openDir(ctx.io, leases_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer dir.close(ctx.io);
    var iterator = dir.iterate();
    while (try iterator.next(ctx.io)) |entry| {
        if (entry.kind != .file) continue;
        if (!isFinalLeaseFile(entry.name)) continue;
        const lease_path = try std.fs.path.join(ctx.allocator, &.{ leases_dir, entry.name });
        defer ctx.allocator.free(lease_path);
        if (try leaseBelongsToLiveProcess(ctx, lease_path)) return true;
    }
    return false;
}

fn isFinalLeaseFile(name: []const u8) bool {
    return std.mem.endsWith(u8, name, ".json") and std.mem.indexOf(u8, name, ".tmp-") == null;
}

fn leaseBelongsToLiveProcess(ctx: *DrawContext, lease_path: []const u8) !bool {
    const text = std.Io.Dir.cwd().readFileAlloc(ctx.io, lease_path, ctx.allocator, .limited(64 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer ctx.allocator.free(text);
    var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, text, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const pid_value = parsed.value.object.getPtr("pid") orelse return false;
    if (pid_value.* != .integer) return false;
    if (pid_value.integer <= 0 or pid_value.integer > std.math.maxInt(std.c.pid_t)) return false;
    const pid: std.c.pid_t = @intCast(pid_value.integer);
    const signal: std.c.SIG = @enumFromInt(0);
    switch (std.c.errno(std.c.kill(pid, signal))) {
        .SUCCESS => return true,
        .SRCH => return false,
        .PERM => return true,
        else => return true,
    }
}

fn appendUnsignedJson(allocator: Allocator, out: *std.ArrayList(u8), value: u64) !void {
    const text = try std.fmt.allocPrint(allocator, "{d}", .{value});
    defer allocator.free(text);
    try out.appendSlice(allocator, text);
}

fn appendJsonString(allocator: Allocator, out: *std.ArrayList(u8), value: []const u8) !void {
    try out.append(allocator, '"');
    for (value) |byte| switch (byte) {
        '\\' => try out.appendSlice(allocator, "\\\\"),
        '"' => try out.appendSlice(allocator, "\\\""),
        '\n' => try out.appendSlice(allocator, "\\n"),
        '\r' => try out.appendSlice(allocator, "\\r"),
        '\t' => try out.appendSlice(allocator, "\\t"),
        else => try out.append(allocator, byte),
    };
    try out.append(allocator, '"');
}

fn renameReplacing(ctx: *DrawContext, tmp_path: []const u8, final_path: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    cwd.rename(tmp_path, cwd, final_path, ctx.io) catch |err| {
        deleteFileIfExists(ctx, final_path);
        cwd.rename(tmp_path, cwd, final_path, ctx.io) catch return err;
    };
}

fn qpdfInputCachePath(allocator: Allocator, cache_dir: []const u8, prefix: []const u8, inputs: []const []const u8, single_page_inputs: bool) ![]u8 {
    var hasher = std.hash.Wyhash.init(0);
    hashString(&hasher, qpdf_cache_version);
    hashString(&hasher, prefix);
    hashBool(&hasher, single_page_inputs);
    hashUsize(&hasher, inputs.len);
    for (inputs) |input| hashString(&hasher, input);
    return qpdfCachePath(allocator, cache_dir, prefix, hasher.final());
}

fn qpdfCachePath(allocator: Allocator, cache_dir: []const u8, prefix: []const u8, hash: u64) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}-{x}.pdf", .{ cache_dir, prefix, hash });
}

fn renderPageHash(ctx: *DrawContext, asset_fingerprints: *std.StringHashMap(FileFingerprint), background: ?Color, ops: []const RenderOp) !u64 {
    var hasher = std.hash.Wyhash.init(0);
    hashString(&hasher, page_pdf_cache_version);
    hashF32(&hasher, PageLayout.width);
    hashF32(&hasher, PageLayout.height);
    hashF32(&hasher, raster_cache_scale);
    hashOptionalColor(&hasher, background);
    hashUsize(&hasher, ops.len);
    for (ops) |*op| try hashRenderOp(ctx, asset_fingerprints, &hasher, op);
    return hasher.final();
}

fn hashRenderOp(ctx: *DrawContext, asset_fingerprints: *std.StringHashMap(FileFingerprint), hasher: *std.hash.Wyhash, op: *const RenderOp) !void {
    hashFrame(hasher, op.frame);
    hashString(hasher, op.content);
    hashOptionalString(hasher, op.link_id);
    hashString(hasher, @tagName(op.parse_mode));
    try hashTexPreambleEntries(ctx, asset_fingerprints, hasher, op.tex_preamble);
    hashResolvedRender(hasher, op);
    switch (op.render.kind) {
        .vector_math => hashString(hasher, @tagName(op.math_kind)),
        .vector_asset, .raster_asset => {
            const source = try resolveAssetPath(ctx, op.content);
            defer ctx.allocator.free(source);
            try hashAssetFile(ctx, asset_fingerprints, hasher, source);
        },
        else => {},
    }
}

fn hashResolvedRender(hasher: *std.hash.Wyhash, op: *const RenderOp) void {
    const render = op.render;
    hashString(hasher, @tagName(render.kind));
    hashOptionalTextPaint(hasher, render.text);
    hashOptionalMathPaint(hasher, render.math);
    hashOptionalCodePaint(hasher, render.code);
    hashChromePaint(hasher, render.chrome);
    hashUnderlinePaint(hasher, render.underline);
    hashRulePaint(hasher, render.rule);
}

fn hashTexPreambleEntries(
    ctx: *DrawContext,
    asset_fingerprints: ?*std.StringHashMap(FileFingerprint),
    hasher: *std.hash.Wyhash,
    preamble: []const TexPreambleEntry,
) !void {
    hashUsize(hasher, preamble.len);
    for (preamble) |entry| {
        hashString(hasher, @tagName(entry.source));
        hashString(hasher, entry.value);
        if (entry.source == .file) {
            const source = try resolveAssetPath(ctx, entry.value);
            defer ctx.allocator.free(source);
            hashLogicalAssetPath(ctx, hasher, source);
            const fingerprint = if (asset_fingerprints) |fingerprints|
                try assetFileFingerprint(ctx, fingerprints, source)
            else
                try streamFileFingerprint(ctx, source);
            hashBool(hasher, fingerprint.present);
            hashU64(hasher, fingerprint.digest);
        }
    }
}

fn hashAssetFile(ctx: *DrawContext, asset_fingerprints: *std.StringHashMap(FileFingerprint), hasher: *std.hash.Wyhash, source: []const u8) !void {
    hashLogicalAssetPath(ctx, hasher, source);
    const fingerprint = try assetFileFingerprint(ctx, asset_fingerprints, source);
    hashBool(hasher, fingerprint.present);
    hashU64(hasher, fingerprint.digest);
}

fn assetFileFingerprint(ctx: *DrawContext, asset_fingerprints: *std.StringHashMap(FileFingerprint), source: []const u8) !FileFingerprint {
    if (asset_fingerprints.get(source)) |fingerprint| return fingerprint;
    const fingerprint = try streamFileFingerprint(ctx, source);
    const owned_source = try ctx.allocator.dupe(u8, source);
    errdefer ctx.allocator.free(owned_source);
    try asset_fingerprints.put(owned_source, fingerprint);
    return fingerprint;
}

fn streamFileFingerprint(ctx: *DrawContext, source: []const u8) !FileFingerprint {
    var file = std.Io.Dir.cwd().openFile(ctx.io, source, .{}) catch |err| switch (err) {
        error.FileNotFound => return .{ .present = false, .digest = 0 },
        else => return err,
    };
    defer file.close(ctx.io);

    var file_buffer: [16 * 1024]u8 = undefined;
    var reader = std.Io.File.Reader.init(file, ctx.io, file_buffer[0..]);
    var chunk: [16 * 1024]u8 = undefined;
    var digest_hasher = std.hash.Wyhash.init(0);
    while (true) {
        const read_len = reader.interface.readSliceShort(chunk[0..]) catch return NativePdfError.AssetConversionFailed;
        if (read_len == 0) break;
        digest_hasher.update(chunk[0..read_len]);
    }
    return .{ .present = true, .digest = digest_hasher.final() };
}

fn hashOptionalTextPaint(hasher: *std.hash.Wyhash, maybe: ?TextPaint) void {
    hashBool(hasher, maybe != null);
    if (maybe) |text| {
        hashFontFace(hasher, text.font);
        hashFontFace(hasher, text.bold_font);
        hashFontFace(hasher, text.italic_font);
        hashFontFace(hasher, text.code_font);
        hashF32(hasher, text.font_size);
        hashF32(hasher, text.line_height);
        hashColor(hasher, text.color);
        hashColor(hasher, text.link_color);
        hashOptionalColor(hasher, text.markdown_bold_color);
        hashF32(hasher, text.link_underline_width);
        hashF32(hasher, text.link_underline_offset);
        hashF32(hasher, text.inline_math_height_factor);
        hashF32(hasher, text.inline_math_spacing);
        hashF32(hasher, text.display_math_height_factor);
        hashHorizontalAlign(hasher, text.math_align);
        hashF32(hasher, text.emoji_spacing);
        hashF32(hasher, text.markdown_block_gap);
        hashF32(hasher, text.markdown_list_inset);
        hashF32(hasher, text.markdown_list_indent);
        hashF32(hasher, text.markdown_code_font_size);
        hashF32(hasher, text.markdown_code_line_height);
        hashF32(hasher, text.markdown_code_pad_x);
        hashF32(hasher, text.markdown_code_pad_y);
        hashOptionalColor(hasher, text.markdown_code_fill);
        hashOptionalColor(hasher, text.markdown_code_stroke);
        hashF32(hasher, text.markdown_code_line_width);
        hashF32(hasher, text.markdown_code_radius);
        hashF32(hasher, text.markdown_table_cell_pad_x);
        hashF32(hasher, text.markdown_table_cell_pad_y);
        hashOptionalColor(hasher, text.markdown_table_border);
        hashF32(hasher, text.markdown_table_line_width);
        hashOptionalColor(hasher, text.markdown_table_header_fill);
        hashOptionalColor(hasher, text.markdown_table_alt_row_fill);
        hashU32(hasher, text.cjk_bold_passes);
        hashF32(hasher, text.cjk_bold_dx);
        hashBool(hasher, text.wrap);
    }
}

fn hashOptionalMathPaint(hasher: *std.hash.Wyhash, maybe: ?MathPaint) void {
    hashBool(hasher, maybe != null);
    if (maybe) |math| {
        hashF32(hasher, math.block_line_height);
        hashF32(hasher, math.block_min_height);
        hashF32(hasher, math.block_vertical_padding);
        hashF32(hasher, math.scale);
        hashHorizontalAlign(hasher, math.horizontal_align);
        hashColor(hasher, math.color);
    }
}

fn hashOptionalCodePaint(hasher: *std.hash.Wyhash, maybe: ?CodePaint) void {
    hashBool(hasher, maybe != null);
    if (maybe) |code| {
        hashBool(hasher, code.language != null);
        if (code.language) |language| hashString(hasher, language);
        hashColor(hasher, code.plain);
        hashColor(hasher, code.keyword);
        hashColor(hasher, code.comment);
        hashColor(hasher, code.string);
    }
}

fn hashChromePaint(hasher: *std.hash.Wyhash, chrome: core.render_policy.ChromePaint) void {
    hashOptionalColor(hasher, chrome.fill);
    hashOptionalColor(hasher, chrome.stroke);
    hashF32(hasher, chrome.line_width);
    hashF32(hasher, chrome.radius);
    hashF32(hasher, chrome.pad_x);
    hashF32(hasher, chrome.pad_y);
}

fn hashUnderlinePaint(hasher: *std.hash.Wyhash, underline: core.render_policy.UnderlinePaint) void {
    hashOptionalColor(hasher, underline.color);
    hashF32(hasher, underline.width);
    hashF32(hasher, underline.offset);
}

fn hashRulePaint(hasher: *std.hash.Wyhash, rule: core.render_policy.RulePaint) void {
    hashOptionalColor(hasher, rule.stroke);
    hashF32(hasher, rule.line_width);
    hashBool(hasher, rule.dash != null);
    if (rule.dash) |dash| {
        hashF32(hasher, dash.on);
        hashF32(hasher, dash.off);
    }
}

fn hashFrame(hasher: *std.hash.Wyhash, frame: Frame) void {
    hashF32(hasher, frame.x);
    hashF32(hasher, frame.y);
    hashF32(hasher, frame.width);
    hashF32(hasher, frame.height);
}

fn hashOptionalColor(hasher: *std.hash.Wyhash, maybe: ?Color) void {
    hashBool(hasher, maybe != null);
    if (maybe) |color| hashColor(hasher, color);
}

fn hashColor(hasher: *std.hash.Wyhash, color: Color) void {
    hashF32(hasher, color.r);
    hashF32(hasher, color.g);
    hashF32(hasher, color.b);
}

fn hashHorizontalAlign(hasher: *std.hash.Wyhash, value: HorizontalAlign) void {
    const normalized: u32 = @intFromEnum(value);
    hashU32(hasher, normalized);
}

fn hashString(hasher: *std.hash.Wyhash, value: []const u8) void {
    hashUsize(hasher, value.len);
    hasher.update(value);
}

fn hashFontFace(hasher: *std.hash.Wyhash, face: FontFace) void {
    hashString(hasher, face.family);
    hashU32(hasher, @intCast(face.weight));
    hashU32(hasher, @intFromEnum(face.style));
    hashU32(hasher, @intFromEnum(face.stretch));
}

fn hashOptionalString(hasher: *std.hash.Wyhash, value: ?[]const u8) void {
    hashBool(hasher, value != null);
    if (value) |text| hashString(hasher, text);
}

fn hashBool(hasher: *std.hash.Wyhash, value: bool) void {
    const byte: u8 = if (value) 1 else 0;
    hasher.update(&.{byte});
}

fn hashUsize(hasher: *std.hash.Wyhash, value: usize) void {
    const normalized: u64 = @intCast(value);
    hashU64(hasher, normalized);
}

fn hashU64(hasher: *std.hash.Wyhash, value: u64) void {
    hasher.update(std.mem.asBytes(&value));
}

fn hashU32(hasher: *std.hash.Wyhash, value: u32) void {
    hasher.update(std.mem.asBytes(&value));
}

fn hashF32(hasher: *std.hash.Wyhash, value: f32) void {
    hasher.update(std.mem.asBytes(&value));
}

fn collectOpPreloads(
    ctx: *DrawContext,
    op: *const RenderOp,
    tasks: *std.ArrayList(PreloadTask),
    seen: *std.StringHashMap(usize),
    page_deps: *std.ArrayList(usize),
) !void {
    switch (op.render.kind) {
        .text => if (op.render.text != null) try collectTextOpPreloads(ctx, op, tasks, seen, page_deps),
        .vector_math => {
            try registerPlanPreloadTask(ctx, tasks, seen, page_deps, .{ .math = .{
                .source = try ctx.allocator.dupe(u8, op.content),
                .preamble = try cloneTexPreambleEntries(ctx.allocator, op.tex_preamble),
                .kind = op.math_kind,
            } });
        },
        .vector_asset => {
            const source = try resolveAssetPath(ctx, op.content);
            if (std.ascii.eqlIgnoreCase(std.fs.path.extension(source), ".pdf")) {
                try registerPlanPreloadTask(ctx, tasks, seen, page_deps, .{ .vector_pdf = source });
            } else {
                ctx.allocator.free(source);
            }
        },
        .raster_asset => {
            const source = try resolveAssetPath(ctx, op.content);
            if (std.ascii.eqlIgnoreCase(std.fs.path.extension(source), ".svg")) {
                ctx.allocator.free(source);
            } else {
                const content_frame = contentFrameForRender(op.frame, op.render);
                try registerPlanPreloadTask(ctx, tasks, seen, page_deps, .{ .raster = .{
                    .source = source,
                    .target_width = content_frame.width * raster_cache_scale,
                    .target_height = content_frame.height * raster_cache_scale,
                } });
            }
        },
        .code, .chrome_only => {},
    }
}

fn collectTextOpPreloads(
    ctx: *DrawContext,
    op: *const RenderOp,
    tasks: *std.ArrayList(PreloadTask),
    seen: *std.StringHashMap(usize),
    page_deps: *std.ArrayList(usize),
) !void {
    switch (op.parse_mode) {
        .none => return,
        .block => {
            var doc = try core.markdown.parseMarkdownContent(ctx.allocator, op.content);
            defer doc.deinit();
            try collectMarkdownBlockPreloadsForPlan(ctx, doc.blocks.items, op.tex_preamble, tasks, seen, page_deps);
        },
        .inline_text => {
            var layout = try core.markdown.parseTextLayoutContent(ctx.allocator, op.content);
            defer layout.deinit(ctx.allocator);
            try collectLinePreloadsForPlan(ctx, layout.lines.items, op.tex_preamble, tasks, seen, page_deps);
        },
    }
}

fn collectMarkdownBlockPreloadsForPlan(
    ctx: *DrawContext,
    blocks: []const *Block,
    preamble: []const TexPreambleEntry,
    tasks: *std.ArrayList(PreloadTask),
    seen: *std.StringHashMap(usize),
    page_deps: *std.ArrayList(usize),
) !void {
    for (blocks) |block| {
        switch (block.kind) {
            .paragraph, .code_block => if (block.paragraph) |paragraph| {
                try collectLinePreloadsForPlan(ctx, paragraph.lines.items, preamble, tasks, seen, page_deps);
            },
            .bullet_list, .ordered_list => if (block.list) |list| {
                for (list.items.items) |item| {
                    try collectMarkdownBlockPreloadsForPlan(ctx, item.blocks.items, preamble, tasks, seen, page_deps);
                }
            },
            .table => if (block.table) |table| {
                for (table.rows.items) |row| {
                    for (row.cells.items) |cell| {
                        try collectLinePreloadsForPlan(ctx, cell.lines.items, preamble, tasks, seen, page_deps);
                    }
                }
            },
        }
    }
}

fn collectLinePreloadsForPlan(
    ctx: *DrawContext,
    lines: []const Line,
    preamble: []const TexPreambleEntry,
    tasks: *std.ArrayList(PreloadTask),
    seen: *std.StringHashMap(usize),
    page_deps: *std.ArrayList(usize),
) !void {
    for (lines) |line| {
        const runs = line.runs.items;
        var index: usize = 0;
        while (index < runs.len) {
            const run = runs[index];
            switch (run.kind) {
                .display_math => {
                    const start = index;
                    while (index < runs.len and runs[index].kind == .display_math) : (index += 1) {}
                    const source = try displayMathSource(ctx.allocator, runs[start..index]);
                    defer ctx.allocator.free(source);
                    if (source.len > 0) {
                        try registerPlanPreloadTask(ctx, tasks, seen, page_deps, .{ .math = .{
                            .source = try ctx.allocator.dupe(u8, source),
                            .preamble = try cloneTexPreambleEntries(ctx.allocator, preamble),
                            .kind = .display,
                        } });
                    }
                    continue;
                },
                .math => try registerPlanPreloadTask(ctx, tasks, seen, page_deps, .{ .math = .{
                    .source = try ctx.allocator.dupe(u8, run.text),
                    .preamble = try cloneTexPreambleEntries(ctx.allocator, preamble),
                    .kind = .inline_math,
                } }),
                .icon => if (run.icon) |source| try registerPlanPreloadTask(ctx, tasks, seen, page_deps, .{
                    .icon = try ctx.allocator.dupe(u8, source),
                }),
                else => {},
            }
            index += 1;
        }
    }
}

fn registerPlanPreloadTask(
    ctx: *DrawContext,
    tasks: *std.ArrayList(PreloadTask),
    seen: *std.StringHashMap(usize),
    page_deps: *std.ArrayList(usize),
    task: PreloadTask,
) !void {
    const key = try preloadTaskKey(ctx, task);
    errdefer {
        ctx.allocator.free(key);
        freePreloadTask(ctx.allocator, task);
    }
    if (seen.get(key)) |existing_index| {
        ctx.allocator.free(key);
        freePreloadTask(ctx.allocator, task);
        try appendUniqueIndex(ctx.allocator, page_deps, existing_index);
        return;
    }
    const index = tasks.items.len;
    try seen.put(key, index);
    try tasks.append(ctx.allocator, task);
    try appendUniqueIndex(ctx.allocator, page_deps, index);
}

fn appendUniqueIndex(allocator: Allocator, values: *std.ArrayList(usize), value: usize) !void {
    for (values.items) |existing| {
        if (existing == value) return;
    }
    try values.append(allocator, value);
}

fn executeRenderDag(ctx: *DrawContext, plan: *const RenderPlan, options: RenderOptions, progress: ?RenderProgress) !void {
    const initial_artifacts_done = plan.artifact_tasks.len - plan.artifact_miss_count;
    const initial_pages_done = plan.page_cache_hit_count;
    if (progress) |p| {
        p.artifactCompleted(p.context, initial_artifacts_done, plan.artifact_tasks.len);
        p.pageCompleted(p.context, initial_pages_done, plan.pages.len);
    }
    const work_count = plan.artifact_miss_count + (plan.pages.len - plan.page_cache_hit_count);
    if (work_count == 0) return;
    const worker_count = renderDagWorkerCount(plan, options);
    if (worker_count <= 1) return executeRenderDagSequential(ctx, plan, progress);

    const artifact_done = try ctx.allocator.alloc(std.atomic.Value(bool), plan.artifact_tasks.len);
    defer ctx.allocator.free(artifact_done);
    for (artifact_done, 0..) |*flag, index| flag.* = .init(plan.artifact_cached[index]);

    const page_claimed = try ctx.allocator.alloc(std.atomic.Value(bool), plan.pages.len);
    defer ctx.allocator.free(page_claimed);
    for (page_claimed) |*flag| flag.* = .init(false);

    const page_done = try ctx.allocator.alloc(std.atomic.Value(bool), plan.pages.len);
    defer ctx.allocator.free(page_done);
    for (page_done, 0..) |*flag, index| flag.* = .init(plan.pages[index].cache_hit);

    var work = RenderDag{
        .plan = plan,
        .completed_artifacts = .init(initial_artifacts_done),
        .completed_pages = .init(initial_pages_done),
        .artifact_done = artifact_done,
        .page_claimed = page_claimed,
        .page_done = page_done,
        .io = ctx.io,
        .asset_base_dir = ctx.asset_base_dir,
        .cache_dir = ctx.cache_dir,
        .progress = progress,
    };

    var threads = try ctx.allocator.alloc(std.Thread, worker_count);
    defer ctx.allocator.free(threads);

    var started: usize = 0;
    errdefer {
        work.failed.store(true, .seq_cst);
        for (threads[0..started]) |thread| thread.join();
    }

    while (started < worker_count) : (started += 1) {
        threads[started] = try std.Thread.spawn(.{}, renderDagWorker, .{&work});
    }

    var last_artifacts: usize = initial_artifacts_done;
    var last_pages: usize = initial_pages_done;
    while (!work.failed.load(.seq_cst) and work.completed_pages.load(.acquire) < plan.pages.len) {
        const artifacts_done = work.completed_artifacts.load(.acquire);
        const pages_done = work.completed_pages.load(.acquire);
        if (progress) |p| {
            if (artifacts_done != last_artifacts) {
                p.artifactCompleted(p.context, artifacts_done, plan.artifact_tasks.len);
                last_artifacts = artifacts_done;
            }
            if (pages_done != last_pages) {
                p.pageCompleted(p.context, pages_done, plan.pages.len);
                last_pages = pages_done;
            }
        }
        std.Io.sleep(ctx.io, std.Io.Duration.fromMilliseconds(50), .awake) catch {};
    }

    for (threads[0..started]) |thread| thread.join();

    if (progress) |p| {
        const artifacts_done = work.completed_artifacts.load(.acquire);
        const pages_done = work.completed_pages.load(.acquire);
        if (artifacts_done != last_artifacts) p.artifactCompleted(p.context, artifacts_done, plan.artifact_tasks.len);
        if (pages_done != last_pages) p.pageCompleted(p.context, pages_done, plan.pages.len);
    }

    if (work.failed.load(.seq_cst)) return NativePdfError.AssetConversionFailed;
}

fn executeRenderDagSequential(ctx: *DrawContext, plan: *const RenderPlan, progress: ?RenderProgress) !void {
    var artifacts_done = plan.artifact_tasks.len - plan.artifact_miss_count;
    for (plan.artifact_tasks, 0..) |task, index| {
        if (plan.artifact_cached[index]) continue;
        try preloadOne(ctx, task);
        artifacts_done += 1;
        if (progress) |p| p.artifactCompleted(p.context, artifacts_done, plan.artifact_tasks.len);
    }
    var pages_done = plan.page_cache_hit_count;
    for (plan.pages) |*page| {
        if (page.cache_hit) continue;
        try renderOnePage(ctx, page);
        pages_done += 1;
        if (progress) |p| p.pageCompleted(p.context, pages_done, plan.pages.len);
    }
}

fn renderDagWorker(work: *RenderDag) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();

    while (!work.failed.load(.monotonic)) {
        if (tryClaimReadyPage(work)) |page_index| {
            var ctx = DrawContext{
                .allocator = arena.allocator(),
                .io = work.io,
                .pdf = undefined,
                .asset_base_dir = work.asset_base_dir,
                .cache_dir = work.cache_dir,
            };
            renderOnePage(&ctx, &work.plan.pages[page_index]) catch |err| {
                work.failed.store(true, .seq_cst);
                std.debug.print("native pdf: page render failed ({s})\n", .{@errorName(err)});
                break;
            };
            work.page_done[page_index].store(true, .release);
            _ = work.completed_pages.fetchAdd(1, .release);
            _ = arena.reset(.retain_capacity);
            continue;
        }

        const artifact_index = work.next_artifact.fetchAdd(1, .monotonic);
        if (artifact_index < work.plan.artifact_tasks.len) {
            if (work.artifact_done[artifact_index].load(.acquire)) continue;
            var ctx = DrawContext{
                .allocator = arena.allocator(),
                .io = work.io,
                .pdf = undefined,
                .asset_base_dir = work.asset_base_dir,
                .cache_dir = work.cache_dir,
            };
            preloadOne(&ctx, work.plan.artifact_tasks[artifact_index]) catch |err| {
                work.failed.store(true, .seq_cst);
                std.debug.print("native pdf: preload failed ({s})\n", .{@errorName(err)});
                break;
            };
            work.artifact_done[artifact_index].store(true, .release);
            _ = work.completed_artifacts.fetchAdd(1, .release);
            _ = arena.reset(.retain_capacity);
            continue;
        }

        if (work.completed_pages.load(.acquire) >= work.plan.pages.len) break;
        std.Io.sleep(work.io, std.Io.Duration.fromMilliseconds(2), .awake) catch {};
    }
}

fn tryClaimReadyPage(work: *RenderDag) ?usize {
    for (work.plan.pages, 0..) |page, page_index| {
        if (work.page_done[page_index].load(.acquire)) continue;
        if (!pageArtifactsReady(work, page)) continue;
        if (work.page_claimed[page_index].cmpxchgStrong(false, true, .acq_rel, .acquire) == null) {
            return page_index;
        }
    }
    return null;
}

fn pageArtifactsReady(work: *RenderDag, page: RenderPage) bool {
    for (page.artifact_deps) |dep| {
        if (!work.artifact_done[dep].load(.acquire)) return false;
    }
    return true;
}

fn renderOnePage(parent_ctx: *DrawContext, page: *const RenderPage) !void {
    if (page.cache_hit) return;
    const pdf_path_z = try parent_ctx.allocator.dupeZ(u8, page.render_path);
    defer parent_ctx.allocator.free(pdf_path_z);
    const pdf = c.ss_pdf_create(pdf_path_z.ptr, PageLayout.width, PageLayout.height) orelse return NativePdfError.CairoCreateFailed;
    defer c.ss_pdf_destroy(pdf);
    c.ss_pdf_set_creator(pdf, "ss native Cairo/Pango backend");

    var ctx = DrawContext{
        .allocator = parent_ctx.allocator,
        .io = parent_ctx.io,
        .pdf = pdf,
        .asset_base_dir = parent_ctx.asset_base_dir,
        .cache_dir = parent_ctx.cache_dir,
    };

    c.ss_pdf_begin_page(pdf, PageLayout.width, PageLayout.height);
    try drawRenderPage(&ctx, page);
    c.ss_pdf_end_page(pdf);
    if (c.ss_pdf_finish(pdf) != 0) return NativePdfError.CairoFailed;
    try validatePdfFile(parent_ctx, page.render_path);
    try publishCacheFile(parent_ctx, page.render_path, page.cache_path);
}

fn drawRenderPage(ctx: *DrawContext, page: *const RenderPage) !void {
    if (page.background) |fill| {
        c.ss_pdf_fill_rect(ctx.pdf, 0, 0, PageLayout.width, PageLayout.height, fill.r, fill.g, fill.b);
    }
    for (page.ops) |*op| {
        if (op.render.kind == .chrome_only) try drawRenderOp(ctx, op);
    }
    for (page.ops) |*op| {
        if (op.render.kind != .chrome_only) try drawRenderOp(ctx, op);
    }
}

fn drawRenderOp(ctx: *DrawContext, op: *const RenderOp) !void {
    try addDestination(ctx, op.link_id, op.frame);
    drawObjectChrome(ctx.pdf, op.frame, op.render);
    const content_frame = contentFrameForRender(op.frame, op.render);
    pushClipRect(ctx.pdf, content_frame);
    defer popClip(ctx.pdf);
    switch (op.render.kind) {
        .text => if (op.render.text) |text| try drawTextOp(ctx, op, content_frame, text),
        .code => if (op.render.text) |text| {
            var code_text = text;
            code_text.font = text.code_font;
            try drawCodeBlock(ctx, content_frame, op.content, code_text, op.render.code);
        },
        .chrome_only => {},
        .vector_math => try drawVectorMathOp(ctx, op, content_frame, op.render.math),
        .vector_asset => try drawVectorAsset(ctx, content_frame, op.content),
        .raster_asset => try drawRasterAsset(ctx, content_frame, op.content),
    }
}

fn drawPage(ctx: *DrawContext, ir: *core.Ir, sema: anytype, page: *const core.Node) !void {
    if (core.render_policy.resolvePageBackgroundWithEnv(ir, page, sema)) |fill| {
        c.ss_pdf_fill_rect(ctx.pdf, 0, 0, PageLayout.width, PageLayout.height, fill.r, fill.g, fill.b);
    }

    if (ir.contains.get(page.id)) |children| {
        for (children.items) |child_id| {
            const node = ir.getNode(child_id) orelse continue;
            if (node.kind != .object or !node.attached) continue;
            const render = core.render_policy.resolveWithEnv(ir, node, sema);
            if (render.kind == .chrome_only) try drawObjectResolved(ctx, ir, node, render);
        }
        for (children.items) |child_id| {
            const node = ir.getNode(child_id) orelse continue;
            if (node.kind != .object or !node.attached) continue;
            const render = core.render_policy.resolveWithEnv(ir, node, sema);
            if (render.kind != .chrome_only) try drawObjectResolved(ctx, ir, node, render);
        }
    }
}

fn preloadRenderCache(ctx: *DrawContext, ir: *core.Ir, sema: anytype, progress: ?RenderProgress) !void {
    var tasks = std.ArrayList(PreloadTask).empty;
    defer tasks.deinit(ctx.allocator);
    defer freePreloadTasks(ctx.allocator, tasks.items);

    var seen = std.StringHashMap(void).init(ctx.allocator);
    defer {
        var key_it = seen.keyIterator();
        while (key_it.next()) |key| ctx.allocator.free(key.*);
        seen.deinit();
    }

    const page_count = ir.page_order.items.len;
    for (ir.page_order.items[0..page_count]) |page_id| {
        const page = ir.getNode(page_id) orelse continue;
        if (ir.contains.get(page.id)) |children| {
            for (children.items) |child_id| {
                const node = ir.getNode(child_id) orelse continue;
                if (node.kind != .object or !node.attached) continue;
                const render = core.render_policy.resolveWithEnv(ir, node, sema);
                try collectNodePreloads(ctx, ir, node, render, &tasks, &seen);
            }
        }
    }

    try runPreloadTasks(ctx, tasks.items, progress);
}

fn collectNodePreloads(
    ctx: *DrawContext,
    ir: *core.Ir,
    node: *const core.Node,
    render: ResolvedRender,
    tasks: *std.ArrayList(PreloadTask),
    seen: *std.StringHashMap(void),
) !void {
    switch (render.kind) {
        .text => if (render.text) |text| try collectTextPreloads(ctx, ir, node, text, tasks, seen),
        .vector_math => {
            var env = try core.render_env.resolveForNode(ctx.allocator, ir, node);
            defer env.deinit(ctx.allocator);
            try registerPreloadTask(ctx, tasks, seen, .{ .math = .{
                .source = try ctx.allocator.dupe(u8, node.content orelse ""),
                .preamble = try cloneTexPreambleEntries(ctx.allocator, env.tex_preamble.items),
                .kind = mathKindForNode(node),
            } });
        },
        .vector_asset => {
            const source = try resolveAssetPath(ctx, node.content orelse "");
            if (std.ascii.eqlIgnoreCase(std.fs.path.extension(source), ".pdf")) {
                try registerPreloadTask(ctx, tasks, seen, .{ .vector_pdf = source });
            } else {
                ctx.allocator.free(source);
            }
        },
        .raster_asset => {
            const source = try resolveAssetPath(ctx, node.content orelse "");
            if (std.ascii.eqlIgnoreCase(std.fs.path.extension(source), ".svg")) {
                ctx.allocator.free(source);
            } else {
                const content_frame = contentFrameForRender(node.frame, render);
                try registerPreloadTask(ctx, tasks, seen, .{ .raster = .{
                    .source = source,
                    .target_width = content_frame.width * raster_cache_scale,
                    .target_height = content_frame.height * raster_cache_scale,
                } });
            }
        },
        .code, .chrome_only => {},
    }
}

fn collectTextPreloads(
    ctx: *DrawContext,
    ir: *core.Ir,
    node: *const core.Node,
    text: TextPaint,
    tasks: *std.ArrayList(PreloadTask),
    seen: *std.StringHashMap(void),
) !void {
    _ = text;
    const content = node.content orelse "";
    var env = try core.render_env.resolveForNode(ctx.allocator, ir, node);
    defer env.deinit(ctx.allocator);
    if (core.markdown.shouldParseBlocksNode(ir, node)) {
        var doc = try core.markdown.parseMarkdownDocumentForNode(ctx.allocator, ir, node, content);
        defer doc.deinit();
        try collectMarkdownBlockPreloads(ctx, doc.blocks.items, env.tex_preamble.items, tasks, seen);
        return;
    }

    var layout = try core.markdown.parseTextLayoutForNode(ctx.allocator, ir, node, content);
    defer layout.deinit(ctx.allocator);
    try collectLinePreloads(ctx, layout.lines.items, env.tex_preamble.items, tasks, seen);
}

fn collectMarkdownBlockPreloads(
    ctx: *DrawContext,
    blocks: []const *Block,
    preamble: []const TexPreambleEntry,
    tasks: *std.ArrayList(PreloadTask),
    seen: *std.StringHashMap(void),
) !void {
    for (blocks) |block| {
        switch (block.kind) {
            .paragraph, .code_block => if (block.paragraph) |paragraph| {
                try collectLinePreloads(ctx, paragraph.lines.items, preamble, tasks, seen);
            },
            .bullet_list, .ordered_list => if (block.list) |list| {
                for (list.items.items) |item| {
                    try collectMarkdownBlockPreloads(ctx, item.blocks.items, preamble, tasks, seen);
                }
            },
            .table => if (block.table) |table| {
                for (table.rows.items) |row| {
                    for (row.cells.items) |cell| {
                        try collectLinePreloads(ctx, cell.lines.items, preamble, tasks, seen);
                    }
                }
            },
        }
    }
}

fn collectLinePreloads(
    ctx: *DrawContext,
    lines: []const Line,
    preamble: []const TexPreambleEntry,
    tasks: *std.ArrayList(PreloadTask),
    seen: *std.StringHashMap(void),
) !void {
    for (lines) |line| {
        const runs = line.runs.items;
        var index: usize = 0;
        while (index < runs.len) {
            const run = runs[index];
            switch (run.kind) {
                .display_math => {
                    const start = index;
                    while (index < runs.len and runs[index].kind == .display_math) : (index += 1) {}
                    const source = try displayMathSource(ctx.allocator, runs[start..index]);
                    defer ctx.allocator.free(source);
                    if (source.len > 0) {
                        try registerPreloadTask(ctx, tasks, seen, .{ .math = .{
                            .source = try ctx.allocator.dupe(u8, source),
                            .preamble = try cloneTexPreambleEntries(ctx.allocator, preamble),
                            .kind = .display,
                        } });
                    }
                    continue;
                },
                .math => try registerPreloadTask(ctx, tasks, seen, .{ .math = .{
                    .source = try ctx.allocator.dupe(u8, run.text),
                    .preamble = try cloneTexPreambleEntries(ctx.allocator, preamble),
                    .kind = .inline_math,
                } }),
                .icon => if (run.icon) |source| try registerPreloadTask(ctx, tasks, seen, .{
                    .icon = try ctx.allocator.dupe(u8, source),
                }),
                else => {},
            }
            index += 1;
        }
    }
}

fn cloneTexPreambleEntries(allocator: Allocator, preamble: []const TexPreambleEntry) ![]const TexPreambleEntry {
    const cloned = try allocator.alloc(TexPreambleEntry, preamble.len);
    @memcpy(cloned, preamble);
    return cloned;
}

fn registerPreloadTask(
    ctx: *DrawContext,
    tasks: *std.ArrayList(PreloadTask),
    seen: *std.StringHashMap(void),
    task: PreloadTask,
) !void {
    const key = try preloadTaskKey(ctx, task);
    errdefer {
        ctx.allocator.free(key);
        freePreloadTask(ctx.allocator, task);
    }
    if (seen.contains(key)) {
        ctx.allocator.free(key);
        freePreloadTask(ctx.allocator, task);
        return;
    }
    try seen.put(key, {});
    try tasks.append(ctx.allocator, task);
}

fn freePreloadTasks(allocator: Allocator, tasks: []const PreloadTask) void {
    for (tasks) |task| freePreloadTask(allocator, task);
}

fn freePreloadTask(allocator: Allocator, task: PreloadTask) void {
    switch (task) {
        .math => |math| {
            allocator.free(math.source);
            allocator.free(math.preamble);
        },
        .icon => |source| allocator.free(source),
        .vector_pdf => |source| allocator.free(source),
        .raster => |raster| allocator.free(raster.source),
    }
}

fn preloadTaskKey(ctx: *DrawContext, task: PreloadTask) ![]u8 {
    return switch (task) {
        .math => |math| cachedMathPath(ctx, math.source, math.preamble, math.kind, "svg"),
        .icon => |source| cachedIconPath(ctx, source, "svg"),
        .vector_pdf => |source| cachedAssetPath(ctx, "pdf", source, "svg"),
        .raster => |raster| cachedSizedAssetPath(ctx, "raster-fit", raster.source, raster.target_width, raster.target_height, "png"),
    };
}

fn countMissingPreloadTasks(ctx: *DrawContext, tasks: []const PreloadTask) !usize {
    var missing: usize = 0;
    for (tasks) |task| {
        if (!try preloadTaskCached(ctx, task)) missing += 1;
    }
    return missing;
}

fn buildPreloadCacheStateForPages(ctx: *DrawContext, tasks: []const PreloadTask, pages: []const RenderPage) !PreloadCacheState {
    const cached = try ctx.allocator.alloc(bool, tasks.len);
    errdefer ctx.allocator.free(cached);
    for (cached) |*value| value.* = true;

    const visited = try ctx.allocator.alloc(bool, tasks.len);
    defer ctx.allocator.free(visited);
    for (visited) |*value| value.* = false;

    var miss_count: usize = 0;
    for (pages) |page| {
        if (page.cache_hit) continue;
        for (page.artifact_deps) |dep| {
            if (dep >= tasks.len or visited[dep]) continue;
            visited[dep] = true;
            cached[dep] = try preloadTaskPresent(ctx, tasks[dep]);
            if (!cached[dep]) miss_count += 1;
        }
    }

    return .{
        .cached = cached,
        .miss_count = miss_count,
    };
}

fn preloadTaskPresent(ctx: *DrawContext, task: PreloadTask) !bool {
    switch (task) {
        .math => |math| {
            const out = try cachedMathPath(ctx, math.source, math.preamble, math.kind, "svg");
            defer ctx.allocator.free(out);
            return fileExists(out);
        },
        .icon => |source| {
            const out = try cachedIconPath(ctx, source, "svg");
            defer ctx.allocator.free(out);
            return fileExists(out);
        },
        .vector_pdf => |source| {
            const out = try cachedAssetPath(ctx, "pdf", source, "svg");
            defer ctx.allocator.free(out);
            return fileExists(out);
        },
        .raster => |raster| {
            if (try rasterSourceFitsTarget(ctx, raster.source, raster.target_width, raster.target_height)) return true;
            const out = try cachedSizedAssetPath(ctx, "raster-fit", raster.source, raster.target_width, raster.target_height, "png");
            defer ctx.allocator.free(out);
            return fileExists(out);
        },
    }
}

fn preloadTaskCached(ctx: *DrawContext, task: PreloadTask) !bool {
    switch (task) {
        .math => |math| {
            const out = try cachedMathPath(ctx, math.source, math.preamble, math.kind, "svg");
            defer ctx.allocator.free(out);
            return (try cachedSvgAsset(ctx, out)) != null;
        },
        .icon => |source| {
            const out = try cachedIconPath(ctx, source, "svg");
            defer ctx.allocator.free(out);
            return (try cachedSvgAsset(ctx, out)) != null;
        },
        .vector_pdf => |source| {
            const out = try cachedAssetPath(ctx, "pdf", source, "svg");
            defer ctx.allocator.free(out);
            return (try cachedSvgAsset(ctx, out)) != null;
        },
        .raster => |raster| {
            if (try rasterSourceFitsTarget(ctx, raster.source, raster.target_width, raster.target_height)) return true;
            const out = try cachedSizedAssetPath(ctx, "raster-fit", raster.source, raster.target_width, raster.target_height, "png");
            defer ctx.allocator.free(out);
            return cachedPngAvailable(ctx, out);
        },
    }
}

fn rasterSourceFitsTarget(ctx: *DrawContext, source: []const u8, target_width: f32, target_height: f32) !bool {
    if (!std.ascii.eqlIgnoreCase(std.fs.path.extension(source), ".png")) return false;
    var source_width: f64 = 0;
    var source_height: f64 = 0;
    const source_z = try ctx.allocator.dupeZ(u8, source);
    defer ctx.allocator.free(source_z);
    return c.ss_png_size(source_z.ptr, &source_width, &source_height) == 0 and
        source_width <= @as(f64, @floatCast(target_width)) and
        source_height <= @as(f64, @floatCast(target_height));
}

fn runPreloadTasks(ctx: *DrawContext, tasks: []const PreloadTask, progress: ?RenderProgress) !void {
    if (tasks.len == 0) return;
    const missing_count = try countMissingPreloadTasks(ctx, tasks);
    const worker_count = preloadWorkerCount(tasks.len, missing_count, .{});
    if (worker_count <= 1) return runPreloadTasksSequential(ctx, tasks, progress);

    var work = PreloadWork{
        .tasks = tasks,
        .io = ctx.io,
        .pdf = ctx.pdf,
        .asset_base_dir = ctx.asset_base_dir,
        .cache_dir = ctx.cache_dir,
    };

    if (progress) |p| p.artifactCompleted(p.context, 0, tasks.len);

    var threads = try ctx.allocator.alloc(std.Thread, worker_count);
    defer ctx.allocator.free(threads);

    var started: usize = 0;
    errdefer {
        work.failed.store(true, .seq_cst);
        for (threads[0..started]) |thread| thread.join();
    }

    while (started < worker_count) : (started += 1) {
        threads[started] = try std.Thread.spawn(.{}, preloadWorker, .{&work});
    }

    var last_reported: usize = 0;
    while (true) {
        const completed = work.completed.load(.acquire);
        if (progress) |p| {
            if (completed != last_reported) {
                p.artifactCompleted(p.context, completed, tasks.len);
                last_reported = completed;
            }
        }
        if (completed >= tasks.len or work.failed.load(.seq_cst)) break;
        std.Io.sleep(ctx.io, std.Io.Duration.fromMilliseconds(100), .awake) catch {};
    }

    for (threads[0..started]) |thread| thread.join();

    const completed = work.completed.load(.acquire);
    if (progress) |p| {
        if (completed != last_reported) p.artifactCompleted(p.context, completed, tasks.len);
    }

    if (work.failed.load(.seq_cst)) return NativePdfError.AssetConversionFailed;
}

fn runPreloadTasksSequential(ctx: *DrawContext, tasks: []const PreloadTask, progress: ?RenderProgress) !void {
    if (progress) |p| p.artifactCompleted(p.context, 0, tasks.len);
    for (tasks, 0..) |task, index| {
        try preloadOne(ctx, task);
        if (progress) |p| p.artifactCompleted(p.context, index + 1, tasks.len);
    }
}

fn preloadWorker(work: *PreloadWork) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();
    while (!work.failed.load(.monotonic)) {
        const index = work.next_index.fetchAdd(1, .monotonic);
        if (index >= work.tasks.len) break;
        var ctx = DrawContext{
            .allocator = arena.allocator(),
            .io = work.io,
            .pdf = work.pdf,
            .asset_base_dir = work.asset_base_dir,
            .cache_dir = work.cache_dir,
        };
        preloadOne(&ctx, work.tasks[index]) catch |err| {
            work.failed.store(true, .seq_cst);
            std.debug.print("native pdf: preload failed ({s})\n", .{@errorName(err)});
            break;
        };
        _ = work.completed.fetchAdd(1, .release);
        _ = arena.reset(.retain_capacity);
    }
}

fn preloadOne(ctx: *DrawContext, task: PreloadTask) !void {
    switch (task) {
        .math => |math| {
            const svg = try renderMathToSvg(ctx, math.source, math.preamble, math.kind);
            ctx.allocator.free(svg.path);
        },
        .icon => |source| {
            const svg = try renderIconToSvg(ctx, source);
            ctx.allocator.free(svg.path);
        },
        .vector_pdf => |source| {
            const svg_path = try pdfToSvg(ctx, source);
            ctx.allocator.free(svg_path);
        },
        .raster => |raster| {
            const png_path = try rasterToSizedPng(ctx, raster.source, raster.target_width, raster.target_height);
            ctx.allocator.free(png_path);
        },
    }
}

fn renderDagWorkerCount(plan: *const RenderPlan, options: RenderOptions) usize {
    const task_count = plan.artifact_miss_count + (plan.pages.len - plan.page_cache_hit_count);
    if (configuredWorkerCount(task_count, options)) |count| return count;
    return preloadWorkerCount(task_count, plan.artifact_miss_count, options);
}

fn preloadWorkerCount(task_count: usize, missing_artifacts: usize, options: RenderOptions) usize {
    if (configuredWorkerCount(task_count, options)) |count| return count;
    const cpu = autoCpuCount();
    const desired = if (missing_artifacts == 0)
        @min(cpu, warm_render_job_cap)
    else if (missing_artifacts < cpu)
        @min(cpu, @max(warm_render_job_cap, missing_artifacts + artifact_job_slack))
    else
        @min(cpu * 2, cold_render_job_cap);
    return clampWorkerCount(desired, task_count);
}

fn mergeWorkerCount(task_count: usize, options: RenderOptions) usize {
    if (configuredWorkerCount(task_count, options)) |count| return count;
    return clampWorkerCount(@min(autoCpuCount(), warm_render_job_cap), task_count);
}

fn configuredWorkerCount(task_count: usize, options: RenderOptions) ?usize {
    if (options.jobs) |jobs| return clampWorkerCount(jobs, task_count);
    if (std.c.getenv("SS_RENDER_JOBS")) |raw| {
        const text = std.mem.span(raw);
        if (std.ascii.eqlIgnoreCase(text, "off")) return 1;
        if (std.fmt.parseUnsigned(usize, text, 10)) |value| {
            return clampWorkerCount(value, task_count);
        } else |_| {}
    }
    return null;
}

fn autoCpuCount() usize {
    return @max(@as(usize, 1), std.Thread.getCpuCount() catch 1);
}

fn clampWorkerCount(value: usize, task_count: usize) usize {
    if (task_count == 0) return 0;
    return @min(@max(@as(usize, 1), value), task_count);
}

fn drawObjectResolved(ctx: *DrawContext, ir: *core.Ir, node: *const core.Node, render: ResolvedRender) !void {
    try addDestination(ctx, core.nodeProperty(node, "link_id"), node.frame);
    drawObjectChrome(ctx.pdf, node.frame, render);
    const content_frame = contentFrameForRender(node.frame, render);
    pushClipRect(ctx.pdf, content_frame);
    defer popClip(ctx.pdf);
    switch (render.kind) {
        .text => if (render.text) |text| try drawTextNode(ctx, ir, node, content_frame, text),
        .code => if (render.text) |text| {
            var code_text = text;
            code_text.font = text.code_font;
            try drawCodeBlock(ctx, content_frame, node.content orelse "", code_text, render.code);
        },
        .chrome_only => {},
        .vector_math => try drawVectorMath(ctx, ir, node, content_frame, node.content orelse "", render.math),
        .vector_asset => try drawVectorAsset(ctx, content_frame, node.content orelse ""),
        .raster_asset => try drawRasterAsset(ctx, content_frame, node.content orelse ""),
    }
}

fn addDestination(ctx: *DrawContext, maybe_link_id: ?[]const u8, frame: Frame) !void {
    const link_id = maybe_link_id orelse return;
    if (link_id.len == 0) return;
    const name_z = try ctx.allocator.dupeZ(u8, link_id);
    defer ctx.allocator.free(name_z);
    if (c.ss_pdf_add_destination(ctx.pdf, name_z.ptr, frame.x, topOf(frame)) != 0) return NativePdfError.CairoFailed;
}

fn pushClipRect(pdf: *c.SsPdf, frame: Frame) void {
    c.ss_pdf_push_clip_rect(pdf, frame.x, topOf(frame), frame.width, frame.height);
}

fn popClip(pdf: *c.SsPdf) void {
    c.ss_pdf_pop_clip(pdf);
}

fn contentFrameForRender(frame: Frame, render: ResolvedRender) Frame {
    return .{
        .x = frame.x + render.chrome.pad_x,
        .y = frame.y + render.chrome.pad_y,
        .width = @max(@as(f32, 1.0), frame.width - 2.0 * render.chrome.pad_x),
        .height = @max(@as(f32, 1.0), frame.height - 2.0 * render.chrome.pad_y),
        .x_set = frame.x_set,
        .y_set = frame.y_set,
    };
}

fn drawObjectChrome(pdf: *c.SsPdf, frame: Frame, render: ResolvedRender) void {
    if (render.rule.stroke) |stroke| {
        const line_width = render.rule.line_width;
        const y = toTopY(frame.y + @max(frame.height / 2.0, 1.5));
        const dash = render.rule.dash;
        c.ss_pdf_stroke_line(
            pdf,
            frame.x,
            y,
            frame.x + frame.width,
            y,
            line_width,
            stroke.r,
            stroke.g,
            stroke.b,
            if (dash) |d| d.on else 0,
            if (dash) |d| d.off else 0,
        );
    }

    if (render.chrome.fill != null or render.chrome.stroke != null) {
        const fill = render.chrome.fill;
        const stroke = render.chrome.stroke;
        c.ss_pdf_fill_stroke_rounded_rect(
            pdf,
            frame.x,
            topOf(frame),
            frame.width,
            frame.height,
            render.chrome.radius,
            if (fill != null) 1 else 0,
            if (fill) |value| value.r else 0,
            if (fill) |value| value.g else 0,
            if (fill) |value| value.b else 0,
            if (stroke != null) 1 else 0,
            if (stroke) |value| value.r else 0,
            if (stroke) |value| value.g else 0,
            if (stroke) |value| value.b else 0,
            render.chrome.line_width,
        );
    }

    if (render.underline.color) |color| {
        const y = toTopY(frame.y + render.underline.offset);
        c.ss_pdf_stroke_line(pdf, frame.x, y, frame.x + frame.width, y, render.underline.width, color.r, color.g, color.b, 0, 0);
    }
}

fn drawTextNode(ctx: *DrawContext, ir: *core.Ir, node: *const core.Node, frame: Frame, text: TextPaint) !void {
    const content = node.content orelse "";
    var env = try core.render_env.resolveForNode(ctx.allocator, ir, node);
    defer env.deinit(ctx.allocator);
    if (core.markdown.shouldParseBlocksNode(ir, node)) {
        var doc = try core.markdown.parseMarkdownDocumentForNode(ctx.allocator, ir, node, content);
        defer doc.deinit();
        _ = try drawMarkdownBlocks(ctx, frame, doc.blocks.items, text, 0, env.tex_preamble.items);
        return;
    }

    var layout = try core.markdown.parseTextLayoutForNode(ctx.allocator, ir, node, content);
    defer layout.deinit(ctx.allocator);
    const baseline = baselineBlForBox(frame, text.font_size);
    _ = try drawInlineLines(ctx, frame.x, baseline, frame.width, layout.lines.items, text, text.wrap, env.tex_preamble.items);
}

fn drawTextOp(ctx: *DrawContext, op: *const RenderOp, frame: Frame, text: TextPaint) !void {
    switch (op.parse_mode) {
        .none => return,
        .block => {
            var doc = try core.markdown.parseMarkdownContent(ctx.allocator, op.content);
            defer doc.deinit();
            _ = try drawMarkdownBlocks(ctx, frame, doc.blocks.items, text, 0, op.tex_preamble);
        },
        .inline_text => {
            var layout = try core.markdown.parseTextLayoutContent(ctx.allocator, op.content);
            defer layout.deinit(ctx.allocator);
            const baseline = baselineBlForBox(frame, text.font_size);
            _ = try drawInlineLines(ctx, frame.x, baseline, frame.width, layout.lines.items, text, text.wrap, op.tex_preamble);
        },
    }
}

fn drawMarkdownBlocks(ctx: *DrawContext, frame: Frame, blocks: []const *Block, text: TextPaint, list_depth: usize, preamble: []const TexPreambleEntry) anyerror!f32 {
    return drawMarkdownBlocksAt(ctx, frame, baselineBlForBox(frame, text.font_size), blocks, text, list_depth, preamble);
}

fn drawMarkdownBlocksAt(ctx: *DrawContext, frame: Frame, baseline_bl: f32, blocks: []const *Block, text: TextPaint, list_depth: usize, preamble: []const TexPreambleEntry) anyerror!f32 {
    var cursor_bl = baseline_bl;
    for (blocks, 0..) |block, index| {
        switch (block.kind) {
            .paragraph => {
                if (block.paragraph) |paragraph| {
                    cursor_bl = try drawInlineLines(ctx, frame.x, cursor_bl, frame.width, paragraph.lines.items, text, true, preamble);
                }
            },
            .code_block => cursor_bl = try drawMarkdownCodeBlock(ctx, frame.x, cursor_bl, frame.width, block, text),
            .bullet_list, .ordered_list => cursor_bl = try drawList(ctx, frame, cursor_bl, block, text, list_depth, preamble),
            .table => cursor_bl = try drawTable(ctx, frame.x, cursor_bl, frame.width, block, text, preamble),
        }
        if (index + 1 < blocks.len) cursor_bl -= text.markdown_block_gap;
    }
    return cursor_bl;
}

fn drawList(ctx: *DrawContext, frame: Frame, baseline_bl: f32, block: *const Block, text: TextPaint, list_depth: usize, preamble: []const TexPreambleEntry) anyerror!f32 {
    const list = block.list orelse return baseline_bl;
    var cursor_bl = baseline_bl;
    const list_inset: f32 = if (list_depth == 0) @max(text.markdown_list_inset, 0) else @max(text.markdown_list_indent, 0);
    const item_x = frame.x + list_inset;
    const item_width = @max(frame.width - list_inset, 1);
    for (list.items.items, 0..) |item, item_index| {
        const marker = try listMarker(ctx.allocator, block.kind, list_depth, list.start + item_index);
        defer ctx.allocator.free(marker);
        try drawRawText(ctx, item_x, baselineTop(cursor_bl, text.font_size), item_width, text.font_size * 2, marker, text.font, text.font_size, text.color, false);
        const marker_width = try measureText(ctx, marker, text.font, text.font_size);
        const content_x = item_x + marker_width + @max(@as(f32, 8.0), text.font_size * 0.35);
        const content_frame = Frame{
            .x = content_x,
            .y = frame.y,
            .width = @max(item_width - marker_width - @max(@as(f32, 8.0), text.font_size * 0.35), 1),
            .height = frame.height,
        };
        cursor_bl = try drawMarkdownBlocksAt(ctx, content_frame, cursor_bl, item.blocks.items, text, list_depth + 1, preamble);
        if (item_index + 1 < list.items.items.len) cursor_bl -= text.markdown_block_gap;
    }
    return cursor_bl;
}

fn drawMarkdownCodeBlock(ctx: *DrawContext, x: f32, baseline_bl: f32, width: f32, block: *const Block, text: TextPaint) !f32 {
    const lines = block.paragraph.?.lines.items;
    const placement = markdownCodeBlockPlacement(x, baseline_bl, width, core.markdown.codeBlockPhysicalLineCount(block), text);
    const frame = placement.frame;

    c.ss_pdf_fill_stroke_rounded_rect(
        ctx.pdf,
        frame.x,
        topOf(frame),
        frame.width,
        frame.height,
        text.markdown_code_radius,
        if (text.markdown_code_fill != null) 1 else 0,
        if (text.markdown_code_fill) |color| color.r else 0,
        if (text.markdown_code_fill) |color| color.g else 0,
        if (text.markdown_code_fill) |color| color.b else 0,
        if (text.markdown_code_stroke != null) 1 else 0,
        if (text.markdown_code_stroke) |color| color.r else 0,
        if (text.markdown_code_stroke) |color| color.g else 0,
        if (text.markdown_code_stroke) |color| color.b else 0,
        text.markdown_code_line_width,
    );

    var cursor_bl = placement.first_baseline_bl;
    for (lines) |line| {
        var plain = std.ArrayList(u8).empty;
        defer plain.deinit(ctx.allocator);
        for (line.runs.items) |run| try plain.appendSlice(ctx.allocator, run.text);
        if (plain.items.len == 0) {
            cursor_bl -= text.markdown_code_line_height;
            continue;
        }

        var physical = std.mem.splitScalar(u8, plain.items, '\n');
        while (physical.next()) |segment| {
            if (segment.len == 0 and physical.index == null and plain.items[plain.items.len - 1] == '\n') break;
            _ = try drawCodeTextAtTop(ctx, x + text.markdown_code_pad_x, baselineTop(cursor_bl, text.markdown_code_font_size), @max(width - text.markdown_code_pad_x * 2, 1), text.markdown_code_line_height, segment, text.code_font, text.markdown_code_font_size, text.color, text.emoji_spacing);
            cursor_bl -= text.markdown_code_line_height;
        }
    }
    return placement.next_baseline_bl;
}

const MarkdownCodeBlockPlacement = struct {
    frame: Frame,
    first_baseline_bl: f32,
    next_baseline_bl: f32,
};

fn markdownCodeBlockPlacement(x: f32, baseline_bl: f32, width: f32, physical_line_count: usize, text: TextPaint) MarkdownCodeBlockPlacement {
    const line_count: f32 = @floatFromInt(physical_line_count);
    const box_height = line_count * text.markdown_code_line_height + text.markdown_code_pad_y * 2;
    const box_top = baseline_bl + text.font_size;
    const box_bottom = box_top - box_height;
    return .{
        .frame = .{ .x = x, .y = box_bottom, .width = width, .height = box_height },
        .first_baseline_bl = box_top - text.markdown_code_pad_y - text.markdown_code_font_size,
        .next_baseline_bl = box_bottom - text.font_size,
    };
}

fn drawTable(ctx: *DrawContext, x: f32, baseline_bl: f32, width: f32, block: *const Block, text: TextPaint, preamble: []const TexPreambleEntry) !f32 {
    const table = block.table orelse return baseline_bl;
    const columns = @max(table.columns, 1);
    const column_width = width / @as(f32, @floatFromInt(columns));
    var cursor_top_bl = baseline_bl + text.font_size - text.markdown_table_line_width * 0.5;
    var body_row_index: usize = 0;

    for (table.rows.items) |row| {
        var row_lines: usize = 1;
        const content_width = @max(column_width - text.markdown_table_cell_pad_x * 2, 1);
        for (row.cells.items) |cell| {
            var cell_text = text;
            cell_text.font = if (row.header) text.bold_font else text.font;
            row_lines = @max(row_lines, try markdownTableCellVisualLineCount(ctx, cell.lines.items, cell_text, content_width, preamble));
        }
        const row_height = @as(f32, @floatFromInt(row_lines)) * text.line_height + text.markdown_table_cell_pad_y * 2;
        const row_bottom = cursor_top_bl - row_height;
        const fill = if (row.header)
            text.markdown_table_header_fill
        else if (text.markdown_table_alt_row_fill != null and body_row_index % 2 == 1)
            text.markdown_table_alt_row_fill
        else
            null;
        if (!row.header) body_row_index += 1;

        for (0..columns) |column_index| {
            const cell_x = x + @as(f32, @floatFromInt(column_index)) * column_width;
            const cell_frame = Frame{ .x = cell_x, .y = row_bottom, .width = column_width, .height = row_height };
            c.ss_pdf_fill_stroke_rounded_rect(
                ctx.pdf,
                cell_frame.x,
                topOf(cell_frame),
                cell_frame.width,
                cell_frame.height,
                0,
                if (fill != null) 1 else 0,
                if (fill) |color| color.r else 0,
                if (fill) |color| color.g else 0,
                if (fill) |color| color.b else 0,
                if (text.markdown_table_border != null) 1 else 0,
                if (text.markdown_table_border) |color| color.r else 0,
                if (text.markdown_table_border) |color| color.g else 0,
                if (text.markdown_table_border) |color| color.b else 0,
                text.markdown_table_line_width,
            );

            if (column_index < row.cells.items.len) {
                const cell = row.cells.items[column_index];
                var cell_text = text;
                cell_text.font = if (row.header) text.bold_font else text.font;
                var line_bl = cursor_top_bl - text.markdown_table_cell_pad_y - text.font_size;
                for (cell.lines.items) |line| {
                    const one_line = [_]Line{line};
                    line_bl = try drawInlineLines(ctx, cell_x + text.markdown_table_cell_pad_x, line_bl, content_width, one_line[0..], cell_text, true, preamble);
                }
            }
        }
        cursor_top_bl = row_bottom;
    }
    return cursor_top_bl - text.font_size;
}

fn markdownTableCellVisualLineCount(ctx: *DrawContext, lines: []const Line, text: TextPaint, max_width: f32, preamble: []const TexPreambleEntry) !usize {
    if (lines.len == 0) return 1;
    var total: usize = 0;
    for (lines) |line| {
        total += try markdownTableLineVisualLineCount(ctx, line, text, max_width, preamble);
    }
    return @max(total, 1);
}

fn markdownTableLineVisualLineCount(ctx: *DrawContext, line: Line, text: TextPaint, max_width: f32, preamble: []const TexPreambleEntry) !usize {
    if (lineContainsDisplayMath(line)) {
        return try lineWithDisplayMathVisualLineCount(ctx, line, text, max_width, preamble);
    }
    var atoms = std.ArrayList(Atom).empty;
    defer atoms.deinit(ctx.allocator);
    defer freeAtoms(ctx.allocator, atoms.items);
    try layoutAtoms(ctx, line, text, preamble, &atoms);
    return atomVisualLineCount(atoms.items, atomPaint(text), max_width);
}

fn drawInlineLines(ctx: *DrawContext, x: f32, baseline_bl: f32, width: f32, lines: []const Line, text: TextPaint, wrap: bool, preamble: []const TexPreambleEntry) !f32 {
    var cursor_bl = baseline_bl;
    for (lines) |line| {
        if (lineContainsDisplayMath(line)) {
            cursor_bl = try drawLineWithDisplayMath(ctx, x, cursor_bl, width, line, text, wrap, preamble);
            continue;
        }
        var atoms = std.ArrayList(Atom).empty;
        defer atoms.deinit(ctx.allocator);
        defer freeAtoms(ctx.allocator, atoms.items);
        try layoutAtoms(ctx, line, text, preamble, &atoms);
        cursor_bl = try drawAtoms(ctx, x, cursor_bl, width, atoms.items, atomPaint(text), wrap);
    }
    if (lines.len == 0) cursor_bl -= text.line_height;
    return cursor_bl;
}

fn layoutAtoms(ctx: *DrawContext, line: Line, text: TextPaint, preamble: []const TexPreambleEntry, atoms: *std.ArrayList(Atom)) !void {
    try layoutRunAtoms(ctx, line.runs.items, text, preamble, atoms);
}

fn layoutRunAtoms(ctx: *DrawContext, runs: []const Run, text: TextPaint, preamble: []const TexPreambleEntry, atoms: *std.ArrayList(Atom)) !void {
    for (runs) |run| {
        switch (run.kind) {
            .math, .display_math => {
                try appendMathAtom(ctx, atoms, run.text, text, preamble, if (run.kind == .display_math) .display else .inline_math);
            },
            .icon => if (run.icon) |source| try appendIconAtom(ctx, atoms, source, text),
            .bold => try appendTextAtoms(ctx, atoms, run.text, text.bold_font, text.markdown_bold_color orelse text.color, text.font_size, null, run.strikethrough),
            .italic => try appendTextAtoms(ctx, atoms, run.text, text.italic_font, text.color, text.font_size, null, run.strikethrough),
            .code => try appendTextAtoms(ctx, atoms, run.text, text.code_font, text.color, text.font_size, null, run.strikethrough),
            .link => try appendTextAtoms(ctx, atoms, run.text, text.font, text.link_color, text.font_size, run.url, run.strikethrough),
            .text => try appendTextAtoms(ctx, atoms, run.text, text.font, text.color, text.font_size, null, run.strikethrough),
        }
    }
}

fn lineContainsDisplayMath(line: Line) bool {
    for (line.runs.items) |run| {
        if (run.kind == .display_math) return true;
    }
    return false;
}

fn drawLineWithDisplayMath(ctx: *DrawContext, x: f32, baseline_bl: f32, width: f32, line: Line, text: TextPaint, wrap: bool, preamble: []const TexPreambleEntry) !f32 {
    const runs = line.runs.items;
    var cursor_bl = baseline_bl;
    var segment_start: usize = 0;
    var index: usize = 0;
    while (index < runs.len) {
        if (runs[index].kind != .display_math) {
            index += 1;
            continue;
        }

        if (segment_start < index) {
            cursor_bl = try drawInlineRunSlice(ctx, x, cursor_bl, width, runs[segment_start..index], text, wrap, preamble);
        }

        const display_start = index;
        while (index < runs.len and runs[index].kind == .display_math) : (index += 1) {}
        const source = try displayMathSource(ctx.allocator, runs[display_start..index]);
        defer ctx.allocator.free(source);
        if (source.len > 0) {
            cursor_bl = try drawDisplayMathBlock(ctx, x, cursor_bl, width, source, text, preamble);
        }
        segment_start = index;
    }

    if (segment_start < runs.len) {
        cursor_bl = try drawInlineRunSlice(ctx, x, cursor_bl, width, runs[segment_start..], text, wrap, preamble);
    }
    return cursor_bl;
}

fn drawInlineRunSlice(ctx: *DrawContext, x: f32, baseline_bl: f32, width: f32, runs: []const Run, text: TextPaint, wrap: bool, preamble: []const TexPreambleEntry) !f32 {
    var atoms = std.ArrayList(Atom).empty;
    defer atoms.deinit(ctx.allocator);
    defer freeAtoms(ctx.allocator, atoms.items);
    try layoutRunAtoms(ctx, runs, text, preamble, &atoms);
    if (atoms.items.len == 0) return baseline_bl;
    return try drawAtoms(ctx, x, baseline_bl, width, atoms.items, atomPaint(text), wrap);
}

fn drawDisplayMathBlock(ctx: *DrawContext, x: f32, baseline_bl: f32, width: f32, source: []const u8, text: TextPaint, preamble: []const TexPreambleEntry) !f32 {
    const svg = try renderMathToSvg(ctx, source, preamble, .display);
    defer ctx.allocator.free(svg.path);

    const block_height = displayMathBlockHeight(source, text);
    const target_height = displayMathTargetHeight(source, text);
    const scale = if (svg.width > 0 and svg.height > 0)
        @min(width / svg.width, target_height / svg.height)
    else
        1;
    const fitted = Size{
        .width = @max(svg.width * scale, 1),
        .height = @max(svg.height * scale, 1),
    };
    const block_top = baseline_bl + text.font_size;
    const block_bottom = block_top - block_height;
    const draw_frame = Frame{
        .x = alignedX(x, width, fitted.width, text.math_align),
        .y = block_bottom + @max((block_height - fitted.height) / 2, 0),
        .width = fitted.width,
        .height = fitted.height,
    };
    try drawSvgFrameTinted(ctx, draw_frame, svg.path, text.color);
    return block_bottom - text.font_size;
}

fn lineWithDisplayMathVisualLineCount(ctx: *DrawContext, line: Line, text: TextPaint, max_width: f32, preamble: []const TexPreambleEntry) !usize {
    const runs = line.runs.items;
    var total: usize = 0;
    var segment_start: usize = 0;
    var index: usize = 0;
    while (index < runs.len) {
        if (runs[index].kind != .display_math) {
            index += 1;
            continue;
        }
        if (segment_start < index) {
            total += try inlineRunSliceVisualLineCount(ctx, runs[segment_start..index], text, max_width, preamble);
        }
        const display_start = index;
        while (index < runs.len and runs[index].kind == .display_math) : (index += 1) {}
        const source = try displayMathSource(ctx.allocator, runs[display_start..index]);
        defer ctx.allocator.free(source);
        if (source.len > 0) {
            total += @max(@as(usize, 1), @as(usize, @intFromFloat(@ceil(displayMathBlockHeight(source, text) / @max(text.line_height, 1)))));
        }
        segment_start = index;
    }
    if (segment_start < runs.len) {
        total += try inlineRunSliceVisualLineCount(ctx, runs[segment_start..], text, max_width, preamble);
    }
    return @max(total, 1);
}

fn inlineRunSliceVisualLineCount(ctx: *DrawContext, runs: []const Run, text: TextPaint, max_width: f32, preamble: []const TexPreambleEntry) !usize {
    var atoms = std.ArrayList(Atom).empty;
    defer atoms.deinit(ctx.allocator);
    defer freeAtoms(ctx.allocator, atoms.items);
    try layoutRunAtoms(ctx, runs, text, preamble, &atoms);
    if (atoms.items.len == 0) return 0;
    return atomVisualLineCount(atoms.items, atomPaint(text), max_width);
}

fn displayMathSource(allocator: Allocator, runs: []const Run) ![]const u8 {
    var joined = std.ArrayList(u8).empty;
    defer joined.deinit(allocator);
    for (runs) |run| {
        try joined.appendSlice(allocator, run.text);
    }
    const trimmed = std.mem.trim(u8, joined.items, " \t\r\n");
    return allocator.dupe(u8, trimmed);
}

fn displayMathTargetHeight(source: []const u8, text: TextPaint) f32 {
    const visual_lines = @as(f32, @floatFromInt(@max(mathVisualLineCount(source), 1)));
    const line_height = @max(text.line_height, text.font_size * text.display_math_height_factor);
    return visual_lines * line_height;
}

fn displayMathBlockHeight(source: []const u8, text: TextPaint) f32 {
    return displayMathTargetHeight(source, text) + @max(text.line_height * 0.2, 2.0) * 2.0;
}

fn freeAtoms(allocator: Allocator, atoms: []const Atom) void {
    for (atoms) |atom| {
        if (atom.svg_path) |path| allocator.free(path);
    }
}

fn appendTextAtoms(ctx: *DrawContext, atoms: *std.ArrayList(Atom), value: []const u8, font: FontFace, color: Color, font_size: f32, link_url: ?[]const u8, strikethrough: bool) !void {
    var tokenizer = Tokenizer.init(value);
    while (tokenizer.next()) |token| {
        const is_emoji = isEmojiToken(token);
        const measured_width = if (is_emoji)
            try measureTextVisualWidth(ctx, token, font, font_size)
        else
            try measureText(ctx, token, font, font_size);
        const width = if (is_emoji) @max(measured_width, font_size * 1.05) else measured_width;
        try atoms.append(ctx.allocator, .{
            .kind = .text,
            .text = token,
            .font = font,
            .color = color,
            .width = width,
            .is_space = isWhitespace(token),
            .is_emoji = is_emoji,
            .strikethrough = strikethrough,
            .link_url = link_url,
        });
    }
}

fn appendMathAtom(ctx: *DrawContext, atoms: *std.ArrayList(Atom), value: []const u8, text: TextPaint, preamble: []const TexPreambleEntry, kind: MathKind) !void {
    const svg = try renderMathToSvg(ctx, value, preamble, kind);
    errdefer ctx.allocator.free(svg.path);
    const target_height = @max(text.font_size * text.inline_math_height_factor, 1);
    const scale = if (svg.height > 0) target_height / svg.height else 1;
    try atoms.append(ctx.allocator, .{
        .kind = .math,
        .text = value,
        .font = text.font,
        .color = text.color,
        .width = @max(svg.width * scale, 1),
        .height = target_height,
        .is_space = false,
        .svg_path = svg.path,
    });
}

fn appendIconAtom(ctx: *DrawContext, atoms: *std.ArrayList(Atom), source: []const u8, text: TextPaint) !void {
    const svg = try renderIconToSvg(ctx, source);
    errdefer ctx.allocator.free(svg.path);
    const target_height = @max(text.font_size, 1);
    const scale = if (svg.height > 0) target_height / svg.height else 1;
    try atoms.append(ctx.allocator, .{
        .kind = .icon,
        .text = source,
        .font = text.font,
        .color = text.link_color,
        .width = @max(svg.width * scale, 1),
        .height = target_height,
        .is_space = false,
        .svg_path = svg.path,
    });
}

fn atomPaint(text: TextPaint) AtomPaint {
    return .{
        .font_size = text.font_size,
        .line_height = text.line_height,
        .emoji_spacing = text.emoji_spacing,
        .inline_math_spacing = text.inline_math_spacing,
    };
}

fn drawAtoms(ctx: *DrawContext, x: f32, baseline_bl: f32, width: f32, atoms: []const Atom, paint: AtomPaint, wrap: bool) !f32 {
    return drawAtomsWithOptions(ctx, x, baseline_bl, width, atoms, paint, wrap, false);
}

fn drawAtomsWithOptions(
    ctx: *DrawContext,
    x: f32,
    baseline_bl: f32,
    width: f32,
    atoms: []const Atom,
    paint: AtomPaint,
    wrap: bool,
    preserve_leading_space: bool,
) !f32 {
    var cursor_bl = baseline_bl;
    var cursor = wrap_layout.Cursor{ .preserve_leading_space = preserve_leading_space };
    for (atoms, 0..) |atom, index| {
        const measured_atom = measuredWrapAtom(atoms, index, paint);
        switch (cursor.next(measured_atom, width, wrap)) {
            .skip => continue,
            .break_then_draw => cursor_bl -= paint.line_height,
            .draw => {},
        }
        const cursor_x = x + cursor.offset;
        switch (atom.kind) {
            .text => {
                const y_top = baselineTop(cursor_bl, paint.font_size);
                if (atom.link_url) |url| {
                    try drawLinkedRawText(ctx, cursor_x, y_top, @max(atom.width, 1), paint.line_height, atom, paint, url);
                } else {
                    try drawRawText(ctx, cursor_x, y_top, @max(atom.width + paint.font_size, 1), paint.line_height, atom.text, atom.font, paint.font_size, atom.color, false);
                }
                if (atom.strikethrough) {
                    drawStrikethrough(ctx, cursor_x, y_top, atom, paint);
                }
                cursor.advance(measured_atom.advance);
            },
            .math => {
                const path = atom.svg_path orelse continue;
                const frame = Frame{ .x = cursor_x, .y = cursor_bl - atom.height * 0.25, .width = atom.width, .height = atom.height };
                try drawSvgFrameTinted(ctx, frame, path, atom.color);
                cursor.advance(measured_atom.advance);
            },
            .icon => {
                const path = atom.svg_path orelse continue;
                const frame = Frame{ .x = cursor_x, .y = cursor_bl - atom.height * 0.2, .width = atom.width, .height = atom.height };
                try drawSvgFrameTinted(ctx, frame, path, atom.color);
                cursor.advance(measured_atom.advance);
            },
        }
    }
    return cursor_bl - paint.line_height;
}

fn atomVisualLineCount(atoms: []const Atom, paint: AtomPaint, max_width: f32) usize {
    if (atoms.len == 0) return 1;
    var lines: usize = 1;
    var cursor = wrap_layout.Cursor{};
    for (atoms, 0..) |_, index| {
        const measured_atom = measuredWrapAtom(atoms, index, paint);
        switch (cursor.next(measured_atom, max_width, true)) {
            .skip => continue,
            .break_then_draw => lines += 1,
            .draw => {},
        }
        cursor.advance(measured_atom.advance);
    }
    return lines;
}

fn measuredWrapAtom(atoms: []const Atom, index: usize, paint: AtomPaint) wrap_layout.Atom {
    const atom = atoms[index];
    return .{
        .width = atom.width,
        .advance = atomAdvance(atoms, index, paint),
        .is_space = atom.is_space,
    };
}

fn atomLineAdvance(atoms: []const Atom, paint: AtomPaint) f32 {
    var width: f32 = 0;
    for (atoms, 0..) |_, index| width += atomAdvance(atoms, index, paint);
    return width;
}

fn atomAdvance(atoms: []const Atom, index: usize, paint: AtomPaint) f32 {
    const atom = atoms[index];
    return switch (atom.kind) {
        .text => atom.width + atomSpacingAfter(atoms, index, paint),
        .math => atom.width + paint.font_size * paint.inline_math_spacing,
        .icon => atom.width,
    };
}

fn atomSpacingAfter(atoms: []const Atom, index: usize, paint: AtomPaint) f32 {
    if (index + 1 >= atoms.len) return 0;
    if (!atoms[index].is_emoji or atoms[index + 1].is_space) return 0;
    return paint.font_size * paint.emoji_spacing;
}

fn drawPlainTextAtTop(
    ctx: *DrawContext,
    x: f32,
    y_top: f32,
    width: f32,
    line_height: f32,
    content: []const u8,
    font: FontFace,
    font_size: f32,
    color: Color,
    wrap: bool,
    emoji_spacing: f32,
) !f32 {
    return drawPlainTextAtTopWithOptions(ctx, x, y_top, width, line_height, content, font, font_size, color, wrap, emoji_spacing, false);
}

fn drawCodeTextAtTop(
    ctx: *DrawContext,
    x: f32,
    y_top: f32,
    width: f32,
    line_height: f32,
    content: []const u8,
    font: FontFace,
    font_size: f32,
    color: Color,
    emoji_spacing: f32,
) !f32 {
    return drawPlainTextAtTopWithOptions(ctx, x, y_top, width, line_height, content, font, font_size, color, false, emoji_spacing, true);
}

fn drawPlainTextAtTopWithOptions(
    ctx: *DrawContext,
    x: f32,
    y_top: f32,
    width: f32,
    line_height: f32,
    content: []const u8,
    font: FontFace,
    font_size: f32,
    color: Color,
    wrap: bool,
    emoji_spacing: f32,
    preserve_leading_space: bool,
) !f32 {
    var atoms = std.ArrayList(Atom).empty;
    defer atoms.deinit(ctx.allocator);
    defer freeAtoms(ctx.allocator, atoms.items);
    try appendTextAtoms(ctx, &atoms, content, font, color, font_size, null, false);
    const paint = AtomPaint{
        .font_size = font_size,
        .line_height = line_height,
        .emoji_spacing = emoji_spacing,
        .inline_math_spacing = 0,
    };
    const baseline_bl = PageLayout.height - (y_top + font_size);
    _ = try drawAtomsWithOptions(ctx, x, baseline_bl, width, atoms.items, paint, wrap, preserve_leading_space);
    return atomLineAdvance(atoms.items, paint);
}

fn drawStrikethrough(ctx: *DrawContext, x: f32, y_top: f32, atom: Atom, paint: AtomPaint) void {
    const y = y_top + paint.font_size * 0.55;
    const line_width = @max(@as(f32, 1.0), paint.font_size * 0.065);
    c.ss_pdf_stroke_line(ctx.pdf, x, y, x + @max(atom.width, 1), y, line_width, atom.color.r, atom.color.g, atom.color.b, 0, 0);
}

fn drawCodeBlock(ctx: *DrawContext, frame: Frame, content: []const u8, text: TextPaint, code: ?CodePaint) !void {
    const code_paint = code orelse CodePaint{
        .language = null,
        .plain = text.color,
        .keyword = text.color,
        .comment = text.color,
        .string = text.color,
    };
    var cursor_bl = baselineBlForBox(frame, text.font_size);
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        try drawCodeLine(ctx, frame.x, baselineTop(cursor_bl, text.font_size), frame.width, line, text.code_font, text.font_size, text.line_height, code_paint, text.emoji_spacing);
        cursor_bl -= text.line_height;
    }
}

fn drawCodeLine(
    ctx: *DrawContext,
    x: f32,
    y_top: f32,
    width: f32,
    line: []const u8,
    font: FontFace,
    font_size: f32,
    line_height: f32,
    code: CodePaint,
    emoji_spacing: f32,
) !void {
    if (code.language == null or !std.ascii.eqlIgnoreCase(code.language.?, "python")) {
        _ = try drawCodeTextAtTop(ctx, x, y_top, width, line_height, line, font, font_size, code.plain, emoji_spacing);
        return;
    }

    var cursor_x = x;
    var index: usize = 0;
    while (index < line.len and cursor_x < x + width) {
        const start = index;
        const byte = line[index];
        if (byte == '#') {
            try drawCodeSegment(ctx, &cursor_x, y_top, line[start..], font, font_size, line_height, code.comment, emoji_spacing);
            break;
        }
        if (byte == '"' or byte == '\'') {
            index = stringLiteralEnd(line, index);
            try drawCodeSegment(ctx, &cursor_x, y_top, line[start..index], font, font_size, line_height, code.string, emoji_spacing);
            continue;
        }
        if (isIdentifierStart(byte)) {
            index += 1;
            while (index < line.len and isIdentifierContinue(line[index])) index += 1;
            const segment = line[start..index];
            try drawCodeSegment(ctx, &cursor_x, y_top, segment, font, font_size, line_height, if (isPythonKeyword(segment)) code.keyword else code.plain, emoji_spacing);
            continue;
        }
        index += utf8ByteSequenceLength(byte);
        try drawCodeSegment(ctx, &cursor_x, y_top, line[start..@min(index, line.len)], font, font_size, line_height, code.plain, emoji_spacing);
    }
}

fn drawCodeSegment(ctx: *DrawContext, cursor_x: *f32, y_top: f32, segment: []const u8, font: FontFace, font_size: f32, line_height: f32, color: Color, emoji_spacing: f32) !void {
    if (segment.len == 0) return;
    const segment_width = try drawCodeTextAtTop(ctx, cursor_x.*, y_top, 1, line_height, segment, font, font_size, color, emoji_spacing);
    cursor_x.* += segment_width;
}

fn stringLiteralEnd(line: []const u8, start: usize) usize {
    const quote = line[start];
    var index = start + 1;
    while (index < line.len) : (index += 1) {
        if (line[index] == '\\') {
            index += 1;
            continue;
        }
        if (line[index] == quote) return index + 1;
    }
    return line.len;
}

fn isIdentifierStart(byte: u8) bool {
    return std.ascii.isAlphabetic(byte) or byte == '_';
}

fn isIdentifierContinue(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}

fn isPythonKeyword(segment: []const u8) bool {
    const keywords = [_][]const u8{
        "False",  "None",   "True",    "and",      "as",       "assert", "async",
        "await",  "break",  "class",   "continue", "def",      "del",    "elif",
        "else",   "except", "finally", "for",      "from",     "global", "if",
        "import", "in",     "is",      "lambda",   "nonlocal", "not",    "or",
        "pass",   "raise",  "return",  "try",      "while",    "with",   "yield",
    };
    for (keywords) |keyword| {
        if (std.mem.eql(u8, segment, keyword)) return true;
    }
    return false;
}

fn drawVectorMath(ctx: *DrawContext, ir: *core.Ir, node: *const core.Node, frame: Frame, content: []const u8, math: ?MathPaint) !void {
    var env = try core.render_env.resolveForNode(ctx.allocator, ir, node);
    defer env.deinit(ctx.allocator);
    const svg = try renderMathToSvg(ctx, content, env.tex_preamble.items, mathKindForNode(node));
    defer ctx.allocator.free(svg.path);
    const fitted = fitMathBlockSize(svg.width, svg.height, frame.width, frame.height, content, math);
    const horizontal_align = if (math) |m| m.horizontal_align else HorizontalAlign.center;
    const draw_frame = Frame{
        .x = alignedX(frame.x, frame.width, fitted.width, horizontal_align),
        .y = frame.y + @max((frame.height - fitted.height) / 2, 0),
        .width = fitted.width,
        .height = fitted.height,
    };
    const color = if (math) |m| m.color else Color{ .r = 0, .g = 0, .b = 0 };
    try drawSvgFrameTinted(ctx, draw_frame, svg.path, color);
}

fn drawVectorMathOp(ctx: *DrawContext, op: *const RenderOp, frame: Frame, math: ?MathPaint) !void {
    const svg = try renderMathToSvg(ctx, op.content, op.tex_preamble, op.math_kind);
    defer ctx.allocator.free(svg.path);
    const fitted = fitMathBlockSize(svg.width, svg.height, frame.width, frame.height, op.content, math);
    const horizontal_align = if (math) |m| m.horizontal_align else HorizontalAlign.center;
    const draw_frame = Frame{
        .x = alignedX(frame.x, frame.width, fitted.width, horizontal_align),
        .y = frame.y + @max((frame.height - fitted.height) / 2, 0),
        .width = fitted.width,
        .height = fitted.height,
    };
    const color = if (math) |m| m.color else Color{ .r = 0, .g = 0, .b = 0 };
    try drawSvgFrameTinted(ctx, draw_frame, svg.path, color);
}

fn drawVectorAsset(ctx: *DrawContext, frame: Frame, content: []const u8) !void {
    const source = try resolveAssetPath(ctx, content);
    defer ctx.allocator.free(source);
    const extension = std.fs.path.extension(source);
    if (std.ascii.eqlIgnoreCase(extension, ".svg")) {
        try drawSvgFit(ctx, frame, source);
        return;
    }
    if (std.ascii.eqlIgnoreCase(extension, ".pdf")) {
        const svg_path = try pdfToSvg(ctx, source);
        defer ctx.allocator.free(svg_path);
        try drawSvgFit(ctx, frame, svg_path);
        return;
    }
    std.debug.print("native pdf: unsupported vector asset type: {s}\n", .{source});
    return NativePdfError.UnsupportedAssetType;
}

fn drawRasterAsset(ctx: *DrawContext, frame: Frame, content: []const u8) !void {
    const source = try resolveAssetPath(ctx, content);
    defer ctx.allocator.free(source);
    if (std.ascii.eqlIgnoreCase(std.fs.path.extension(source), ".svg")) {
        try drawSvgFit(ctx, frame, source);
        return;
    }
    const png_path = try rasterToSizedPng(ctx, source, frame.width * raster_cache_scale, frame.height * raster_cache_scale);
    defer ctx.allocator.free(png_path);
    try drawPngFit(ctx, frame, png_path);
}

const direct_merge_page_limit: usize = 96;
const merge_chunk_size: usize = 16;

fn assembleRenderPlan(ctx: *DrawContext, plan: *const RenderPlan, options: RenderOptions, progress: ?RenderProgress) !void {
    const page_paths = try ctx.allocator.alloc([]const u8, plan.pages.len);
    defer ctx.allocator.free(page_paths);
    for (plan.pages, 0..) |page, index| page_paths[index] = page.cache_path;

    if (page_paths.len == 0) {
        if (progress) |p| p.assemblyCompleted(p.context, 0, 1);
        try writeZeroPagePdf(ctx, plan.final_pdf_path);
        if (progress) |p| p.assemblyCompleted(p.context, 1, 1);
        return;
    }

    if (page_paths.len <= direct_merge_page_limit) {
        if (progress) |p| p.assemblyCompleted(p.context, 0, 1);
        try mergePdfInputs(ctx, page_paths, true, plan.final_pdf_path);
        if (progress) |p| p.assemblyCompleted(p.context, 1, 1);
        return;
    }

    const chunk_cache_dir = try std.fs.path.join(ctx.allocator, &.{ plan.run_dir, "chunks" });
    defer ctx.allocator.free(chunk_cache_dir);
    try std.Io.Dir.cwd().createDirPath(ctx.io, chunk_cache_dir);

    const chunk_count = std.math.divCeil(usize, page_paths.len, merge_chunk_size) catch unreachable;

    const chunks = try ctx.allocator.alloc(MergeChunk, chunk_count);
    defer {
        for (chunks) |chunk| ctx.allocator.free(chunk.output);
        ctx.allocator.free(chunks);
    }

    var missing_chunks = std.ArrayList(MergeChunk).empty;
    defer missing_chunks.deinit(ctx.allocator);

    for (chunks, 0..) |*chunk, chunk_index| {
        const start = chunk_index * merge_chunk_size;
        const end = @min(page_paths.len, start + merge_chunk_size);
        const output = try qpdfInputCachePath(ctx.allocator, chunk_cache_dir, "chunk", page_paths[start..end], true);
        errdefer ctx.allocator.free(output);
        const cache_hit = try cachedPdfAvailable(ctx, output);
        chunk.* = .{
            .inputs = page_paths[start..end],
            .output = output,
            .single_page_inputs = true,
        };
        if (!cache_hit) try missing_chunks.append(ctx.allocator, chunk.*);
    }

    const total_steps = missing_chunks.items.len + 1;
    if (progress) |p| p.assemblyCompleted(p.context, 0, total_steps);
    try runMergeChunks(ctx, missing_chunks.items, options, progress, 0, total_steps);

    const chunk_paths = try ctx.allocator.alloc([]const u8, chunk_count);
    defer ctx.allocator.free(chunk_paths);
    for (chunks, 0..) |chunk, index| chunk_paths[index] = chunk.output;
    try mergePdfInputs(ctx, chunk_paths, false, plan.final_pdf_path);
    if (progress) |p| p.assemblyCompleted(p.context, total_steps, total_steps);
}

fn runMergeChunks(
    ctx: *DrawContext,
    chunks: []const MergeChunk,
    options: RenderOptions,
    progress: ?RenderProgress,
    progress_offset: usize,
    progress_total: usize,
) !void {
    if (chunks.len == 0) return;
    const worker_count = mergeWorkerCount(chunks.len, options);
    if (worker_count <= 1) {
        for (chunks, 0..) |chunk, index| {
            try mergePdfInputsToCache(ctx, chunk.inputs, chunk.single_page_inputs, chunk.output);
            if (progress) |p| p.assemblyCompleted(p.context, progress_offset + index + 1, progress_total);
        }
        return;
    }

    var work = MergeWork{
        .chunks = chunks,
        .io = ctx.io,
        .cache_dir = ctx.cache_dir,
        .progress = progress,
        .progress_offset = progress_offset,
        .progress_total = progress_total,
    };

    var threads = try ctx.allocator.alloc(std.Thread, worker_count);
    defer ctx.allocator.free(threads);

    var started: usize = 0;
    errdefer {
        work.failed.store(true, .seq_cst);
        for (threads[0..started]) |thread| thread.join();
    }

    while (started < worker_count) : (started += 1) {
        threads[started] = try std.Thread.spawn(.{}, mergeWorker, .{&work});
    }

    var last_completed: usize = 0;
    while (!work.failed.load(.seq_cst) and work.completed.load(.acquire) < chunks.len) {
        const completed = work.completed.load(.acquire);
        if (progress) |p| {
            if (completed != last_completed) {
                p.assemblyCompleted(p.context, progress_offset + completed, progress_total);
                last_completed = completed;
            }
        }
        std.Io.sleep(ctx.io, std.Io.Duration.fromMilliseconds(50), .awake) catch {};
    }

    for (threads[0..started]) |thread| thread.join();

    if (progress) |p| {
        const completed = work.completed.load(.acquire);
        if (completed != last_completed) p.assemblyCompleted(p.context, progress_offset + completed, progress_total);
    }
    if (work.failed.load(.seq_cst)) return NativePdfError.AssetConversionFailed;
}

fn mergeWorker(work: *MergeWork) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();
    while (!work.failed.load(.monotonic)) {
        const index = work.next_index.fetchAdd(1, .monotonic);
        if (index >= work.chunks.len) break;
        var ctx = DrawContext{
            .allocator = arena.allocator(),
            .io = work.io,
            .pdf = undefined,
            .asset_base_dir = ".",
            .cache_dir = work.cache_dir,
        };
        const chunk = work.chunks[index];
        mergePdfInputsToCache(&ctx, chunk.inputs, chunk.single_page_inputs, chunk.output) catch |err| {
            work.failed.store(true, .seq_cst);
            std.debug.print("native pdf: qpdf merge failed ({s})\n", .{@errorName(err)});
            break;
        };
        _ = work.completed.fetchAdd(1, .release);
        _ = arena.reset(.retain_capacity);
    }
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
}

fn writeZeroPagePdf(ctx: *DrawContext, output: []const u8) !void {
    try runCheckedAllowQpdfWarnings(ctx, &.{ "qpdf", "--deterministic-id", "--empty", output }, .inherit);
}

fn mergePdfInputsToCache(ctx: *DrawContext, inputs: []const []const u8, single_page_inputs: bool, output: []const u8) !void {
    if (try cachedPdfAvailable(ctx, output)) return;
    const tmp = try tempCachePath(ctx, output, "pdf");
    defer ctx.allocator.free(tmp);
    errdefer deleteFileIfExists(ctx, tmp);
    try mergePdfInputs(ctx, inputs, single_page_inputs, tmp);
    try validatePdfFile(ctx, tmp);
    try publishCacheFile(ctx, tmp, output);
}

fn drawRawText(
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

fn drawLinkedRawText(
    ctx: *DrawContext,
    x: f32,
    y_top: f32,
    link_width: f32,
    height: f32,
    atom: Atom,
    paint: AtomPaint,
    url: []const u8,
) !void {
    const target = if (isInternalLink(url)) url[1..] else url;
    if (target.len == 0) {
        try drawRawText(ctx, x, y_top, @max(atom.width + paint.font_size, 1), height, atom.text, atom.font, paint.font_size, atom.color, false);
        return;
    }
    const target_z = try ctx.allocator.dupeZ(u8, target);
    defer ctx.allocator.free(target_z);
    const begin_result = if (isInternalLink(url))
        c.ss_pdf_begin_dest_link(ctx.pdf, x, y_top, @max(link_width, 1), height, target_z.ptr)
    else
        c.ss_pdf_begin_uri_link(ctx.pdf, x, y_top, @max(link_width, 1), height, target_z.ptr);
    if (begin_result != 0) return NativePdfError.CairoFailed;
    defer c.ss_pdf_end_link(ctx.pdf);
    try drawRawText(ctx, x, y_top, @max(atom.width + paint.font_size, 1), height, atom.text, atom.font, paint.font_size, atom.color, false);
}

fn isInternalLink(url: []const u8) bool {
    return url.len > 1 and url[0] == '#';
}

fn measureText(ctx: *DrawContext, content: []const u8, font: FontFace, font_size: f32) !f32 {
    if (content.len == 0) return 0;
    const family_z = try ctx.allocator.dupeZ(u8, font.family);
    defer ctx.allocator.free(family_z);
    const content_z = try ctx.allocator.dupeZ(u8, content);
    defer ctx.allocator.free(content_z);
    return @floatCast(c.ss_pdf_measure_text(
        ctx.pdf,
        content_z.ptr,
        family_z.ptr,
        @intCast(font.weight),
        core.font.styleCode(font.style),
        core.font.stretchCode(font.stretch),
        font_size,
    ));
}

fn measureTextVisualWidth(ctx: *DrawContext, content: []const u8, font: FontFace, font_size: f32) !f32 {
    if (content.len == 0) return 0;
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

fn baselineBlForBox(frame: Frame, font_size: f32) f32 {
    return frame.y + frame.height - font_size;
}

fn baselineTop(baseline_bl: f32, font_size: f32) f32 {
    return PageLayout.height - baseline_bl - font_size;
}

fn listMarker(allocator: Allocator, kind: core.markdown.BlockKind, depth: usize, ordinal: usize) ![]const u8 {
    if (kind == .ordered_list) return std.fmt.allocPrint(allocator, "{d}.", .{ordinal});
    return allocator.dupe(u8, if (depth == 0) "•" else "◦");
}

const Tokenizer = struct {
    text: []const u8,
    index: usize = 0,

    fn init(text: []const u8) Tokenizer {
        return .{ .text = text };
    }

    fn next(self: *Tokenizer) ?[]const u8 {
        if (self.index >= self.text.len) return null;
        const start = self.index;
        const first_codepoint = utf8CodepointAt(self.text, self.index);
        const first_len = first_codepoint.len;
        const first_end = @min(self.text.len, self.index + first_len);
        const first = self.text[start..first_end];
        self.index = first_end;

        if (isWhitespace(first)) {
            while (self.index < self.text.len) {
                const len = utf8ByteSequenceLength(self.text[self.index]);
                const end = @min(self.text.len, self.index + len);
                if (!isWhitespace(self.text[self.index..end])) break;
                self.index = end;
            }
            return self.text[start..self.index];
        }

        if (isEmojiStart(first_codepoint.value)) {
            self.index = consumeEmojiSequence(self.text, self.index, first_codepoint.value);
            return self.text[start..self.index];
        }

        if (isAsciiWordByte(first[0])) {
            while (self.index < self.text.len and isAsciiWordByte(self.text[self.index])) self.index += 1;
            return self.text[start..self.index];
        }

        return first;
    }
};

const Utf8Codepoint = struct {
    value: u21,
    len: usize,
};

fn utf8CodepointAt(text: []const u8, index: usize) Utf8Codepoint {
    if (index >= text.len) return .{ .value = 0, .len = 0 };
    const len = @min(utf8ByteSequenceLength(text[index]), text.len - index);
    const value = std.unicode.utf8Decode(text[index .. index + len]) catch text[index];
    return .{ .value = value, .len = len };
}

fn utf8ByteSequenceLength(first: u8) usize {
    if (first < 0x80) return 1;
    if ((first & 0xe0) == 0xc0) return 2;
    if ((first & 0xf0) == 0xe0) return 3;
    if ((first & 0xf8) == 0xf0) return 4;
    return 1;
}

fn consumeEmojiSequence(text: []const u8, index: usize, first: u21) usize {
    var cursor = index;
    if (isRegionalIndicator(first)) {
        const next = utf8CodepointAt(text, cursor);
        if (isRegionalIndicator(next.value)) cursor += next.len;
        return cursor;
    }

    while (cursor < text.len) {
        const next = utf8CodepointAt(text, cursor);
        if (next.len == 0) break;
        if (isEmojiModifier(next.value) or next.value == 0xfe0f) {
            cursor += next.len;
            continue;
        }
        if (next.value == 0x200d) {
            const joiner_start = cursor;
            cursor += next.len;
            const joined = utf8CodepointAt(text, cursor);
            if (joined.len == 0 or !isEmojiStart(joined.value)) return joiner_start;
            cursor += joined.len;
            continue;
        }
        break;
    }
    return cursor;
}

fn isEmojiStart(value: u21) bool {
    return (value >= 0x1f000 and value <= 0x1faff) or
        (value >= 0x2600 and value <= 0x27bf) or
        isRegionalIndicator(value);
}

fn isEmojiModifier(value: u21) bool {
    return (value >= 0x1f3fb and value <= 0x1f3ff) or value == 0xfe0e or value == 0xfe0f;
}

fn isRegionalIndicator(value: u21) bool {
    return value >= 0x1f1e6 and value <= 0x1f1ff;
}

fn isAsciiWordByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '.' or byte == '/' or byte == ':' or byte == '+' or byte == '-';
}

fn isWhitespace(text: []const u8) bool {
    for (text) |byte| {
        if (byte != ' ' and byte != '\t' and byte != '\r' and byte != '\n') return false;
    }
    return text.len > 0;
}

fn isEmojiToken(text: []const u8) bool {
    if (text.len == 0) return false;
    const first = utf8CodepointAt(text, 0);
    return first.len > 0 and isEmojiStart(first.value);
}

fn drawPngFit(ctx: *DrawContext, frame: Frame, png_path: []const u8) !void {
    var source_width: f64 = 0;
    var source_height: f64 = 0;
    const png_z = try ctx.allocator.dupeZ(u8, png_path);
    defer ctx.allocator.free(png_z);
    if (c.ss_png_size(png_z.ptr, &source_width, &source_height) != 0) return NativePdfError.ImageDecodeFailed;
    const fitted = fitSize(@floatCast(source_width), @floatCast(source_height), frame.width, frame.height);
    const draw_x = frame.x;
    const draw_y = topOf(Frame{
        .x = frame.x,
        .y = frame.y + @max((frame.height - fitted.height) / 2, 0),
        .width = fitted.width,
        .height = fitted.height,
    });
    if (c.ss_pdf_draw_png(ctx.pdf, png_z.ptr, draw_x, draw_y, fitted.width, fitted.height) != 0) return NativePdfError.ImageDecodeFailed;
}

fn drawSvgFit(ctx: *DrawContext, frame: Frame, svg_path: []const u8) !void {
    var source_width: f64 = 0;
    var source_height: f64 = 0;
    const svg_z = try ctx.allocator.dupeZ(u8, svg_path);
    defer ctx.allocator.free(svg_z);
    if (c.ss_svg_size(svg_z.ptr, &source_width, &source_height) != 0) return NativePdfError.ImageDecodeFailed;
    const fitted = fitSize(@floatCast(source_width), @floatCast(source_height), frame.width, frame.height);
    const draw_x = frame.x;
    const draw_y = topOf(Frame{
        .x = frame.x,
        .y = frame.y + @max((frame.height - fitted.height) / 2, 0),
        .width = fitted.width,
        .height = fitted.height,
    });
    if (c.ss_pdf_draw_svg(ctx.pdf, svg_z.ptr, draw_x, draw_y, fitted.width, fitted.height) != 0) return NativePdfError.ImageDecodeFailed;
}

fn drawSvgFrame(ctx: *DrawContext, frame: Frame, svg_path: []const u8) !void {
    const svg_z = try ctx.allocator.dupeZ(u8, svg_path);
    defer ctx.allocator.free(svg_z);
    if (c.ss_pdf_draw_svg(ctx.pdf, svg_z.ptr, frame.x, topOf(frame), frame.width, frame.height) != 0) return NativePdfError.ImageDecodeFailed;
}

fn drawSvgFrameTinted(ctx: *DrawContext, frame: Frame, svg_path: []const u8, color: Color) !void {
    const svg_z = try ctx.allocator.dupeZ(u8, svg_path);
    defer ctx.allocator.free(svg_z);
    if (c.ss_pdf_draw_svg_tinted(ctx.pdf, svg_z.ptr, frame.x, topOf(frame), frame.width, frame.height, color.r, color.g, color.b) != 0) return NativePdfError.ImageDecodeFailed;
}

const Size = struct { width: f32, height: f32 };

fn fitSize(source_width: f32, source_height: f32, max_width: f32, max_height: f32) Size {
    if (source_width <= 0 or source_height <= 0) return .{ .width = max_width, .height = max_height };
    const scale = @min(max_width / source_width, max_height / source_height);
    return .{ .width = source_width * scale, .height = source_height * scale };
}

fn fitMathBlockSize(source_width: f32, source_height: f32, max_width: f32, max_height: f32, source_text: []const u8, math: ?MathPaint) Size {
    if (source_width <= 0 or source_height <= 0) return .{ .width = max_width, .height = max_height };
    const paint = math orelse MathPaint{
        .block_line_height = 22,
        .block_min_height = 30,
        .block_vertical_padding = 2,
        .scale = 1,
        .horizontal_align = .center,
        .color = .{ .r = 0, .g = 0, .b = 0 },
    };
    const target_height = @max(
        paint.block_min_height,
        @as(f32, @floatFromInt(mathVisualLineCount(source_text))) * paint.block_line_height + paint.block_vertical_padding,
    ) * paint.scale;
    const scale = @min(@min(max_width / source_width, max_height / source_height), target_height / source_height);
    return .{ .width = source_width * scale, .height = source_height * scale };
}

fn alignedX(x: f32, width: f32, content_width: f32, horizontal_align: HorizontalAlign) f32 {
    const slack = @max(width - content_width, 0);
    return switch (horizontal_align) {
        .left => x,
        .center => x + slack / 2,
        .right => x + slack,
    };
}

fn mathVisualLineCount(source_text: []const u8) usize {
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, source_text, '\n');
    while (lines.next()) |line| {
        if (std.mem.trim(u8, line, " \t\r\n").len == 0) continue;
        count += 1;
        var cursor: usize = 0;
        while (std.mem.indexOfPos(u8, line, cursor, "\\\\")) |break_index| {
            count += 1;
            cursor = break_index + 2;
        }
    }
    return @max(count, 1);
}

fn resolveAssetPath(ctx: *DrawContext, rel_path: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(rel_path)) return ctx.allocator.dupe(u8, rel_path);
    return std.fs.path.join(ctx.allocator, &.{ ctx.asset_base_dir, rel_path });
}

fn hashLogicalAssetPath(ctx: *DrawContext, hasher: *std.hash.Wyhash, source: []const u8) void {
    const base = ctx.asset_base_dir;
    if (base.len > 0 and !std.mem.eql(u8, base, ".")) {
        if (std.mem.eql(u8, source, base)) {
            hashString(hasher, ".");
            return;
        }
        if (source.len > base.len and source[base.len] == std.fs.path.sep and std.mem.eql(u8, source[0..base.len], base)) {
            hashString(hasher, source[base.len + 1 ..]);
            return;
        }
    }
    if (std.mem.startsWith(u8, source, "./")) {
        hashString(hasher, source[2..]);
        return;
    }
    hashString(hasher, source);
}

fn rasterToSizedPng(ctx: *DrawContext, source: []const u8, target_width: f32, target_height: f32) ![]const u8 {
    if (std.ascii.eqlIgnoreCase(std.fs.path.extension(source), ".png")) {
        var source_width: f64 = 0;
        var source_height: f64 = 0;
        const source_z = try ctx.allocator.dupeZ(u8, source);
        defer ctx.allocator.free(source_z);
        if (c.ss_png_size(source_z.ptr, &source_width, &source_height) == 0 and
            source_width <= @as(f64, @floatCast(target_width)) and
            source_height <= @as(f64, @floatCast(target_height)))
        {
            return ctx.allocator.dupe(u8, source);
        }
    }

    const out = try cachedSizedAssetPath(ctx, "raster-fit", source, target_width, target_height, "png");
    errdefer ctx.allocator.free(out);
    if (try cachedPngAvailable(ctx, out)) return out;

    const tmp = try tempCachePath(ctx, out, "png");
    defer ctx.allocator.free(tmp);
    errdefer deleteFileIfExists(ctx, tmp);

    var geometry_buf: [64]u8 = undefined;
    const geometry = try std.fmt.bufPrint(&geometry_buf, "{d}x{d}>", .{
        rasterTargetPixels(target_width),
        rasterTargetPixels(target_height),
    });
    try runChecked(ctx, &.{ "magick", source, "-auto-orient", "-resize", geometry, "-strip", tmp }, .inherit);
    try validatePng(tmp);
    try publishCacheFile(ctx, tmp, out);
    return out;
}

fn pdfToSvg(ctx: *DrawContext, source: []const u8) ![]const u8 {
    const out = try cachedAssetPath(ctx, "pdf", source, "svg");
    errdefer ctx.allocator.free(out);
    if (try cachedSvgAsset(ctx, out) != null) return out;
    const tmp = try tempCachePath(ctx, out, "svg");
    defer ctx.allocator.free(tmp);
    errdefer deleteFileIfExists(ctx, tmp);
    try runChecked(ctx, &.{ "pdftocairo", "-svg", source, tmp }, .inherit);
    _ = try svgAsset(ctx, tmp);
    try publishCacheFile(ctx, tmp, out);
    return out;
}

fn renderMathToSvg(ctx: *DrawContext, source: []const u8, preamble: []const TexPreambleEntry, kind: MathKind) !SvgAsset {
    const out = try cachedMathPath(ctx, source, preamble, kind, "svg");
    errdefer ctx.allocator.free(out);
    if (try cachedSvgAsset(ctx, out)) |asset| return asset;
    const dir = try tempCachePath(ctx, out, "dir");
    defer ctx.allocator.free(dir);
    defer std.Io.Dir.cwd().deleteTree(ctx.io, dir) catch {};
    errdefer std.Io.Dir.cwd().deleteTree(ctx.io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(ctx.io, dir);
    const tex_path = try std.fs.path.join(ctx.allocator, &.{ dir, "main.tex" });
    defer ctx.allocator.free(tex_path);
    const pdf_path = try std.fs.path.join(ctx.allocator, &.{ dir, "main.pdf" });
    defer ctx.allocator.free(pdf_path);
    const tex = try mathDocumentSource(ctx, source, preamble, kind);
    defer ctx.allocator.free(tex);
    try std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = tex_path, .data = tex, .flags = .{ .truncate = true } });
    try runChecked(ctx, &.{ "pdflatex", "-interaction=nonstopmode", "-halt-on-error", "main.tex" }, .{ .path = dir });
    const tmp = try tempCachePath(ctx, out, "svg");
    defer ctx.allocator.free(tmp);
    errdefer deleteFileIfExists(ctx, tmp);
    try runChecked(ctx, &.{ "pdftocairo", "-svg", pdf_path, tmp }, .inherit);
    _ = try svgAsset(ctx, tmp);
    try publishCacheFile(ctx, tmp, out);
    return try svgAsset(ctx, out);
}

fn renderIconToSvg(ctx: *DrawContext, source: []const u8) !SvgAsset {
    const out = try cachedIconPath(ctx, source, "svg");
    errdefer ctx.allocator.free(out);
    if (try cachedSvgAsset(ctx, out)) |asset| return asset;
    const spec = parseIconSource(source) orelse return NativePdfError.InvalidFontAwesomeIcon;
    const dir = try tempCachePath(ctx, out, "dir");
    defer ctx.allocator.free(dir);
    defer std.Io.Dir.cwd().deleteTree(ctx.io, dir) catch {};
    errdefer std.Io.Dir.cwd().deleteTree(ctx.io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(ctx.io, dir);
    const tex_path = try std.fs.path.join(ctx.allocator, &.{ dir, "main.tex" });
    defer ctx.allocator.free(tex_path);
    const pdf_path = try std.fs.path.join(ctx.allocator, &.{ dir, "main.pdf" });
    defer ctx.allocator.free(pdf_path);
    const tex = try iconDocumentSource(ctx.allocator, spec);
    defer ctx.allocator.free(tex);
    try std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = tex_path, .data = tex, .flags = .{ .truncate = true } });
    try runChecked(ctx, &.{ "pdflatex", "-interaction=nonstopmode", "-halt-on-error", "main.tex" }, .{ .path = dir });
    const tmp = try tempCachePath(ctx, out, "svg");
    defer ctx.allocator.free(tmp);
    errdefer deleteFileIfExists(ctx, tmp);
    try runChecked(ctx, &.{ "pdftocairo", "-svg", pdf_path, tmp }, .inherit);
    _ = try svgAsset(ctx, tmp);
    try publishCacheFile(ctx, tmp, out);
    return try svgAsset(ctx, out);
}

fn normalizePdf(ctx: *DrawContext, pdf_path: []const u8) ![]const u8 {
    const out = try std.fmt.allocPrint(ctx.allocator, "{s}.qpdf.pdf", .{pdf_path});
    errdefer ctx.allocator.free(out);
    errdefer std.Io.Dir.cwd().deleteFile(ctx.io, out) catch {};
    runCheckedAllowQpdfWarnings(ctx, &.{ "qpdf", pdf_path, out }, .inherit) catch |err| {
        std.debug.print("native pdf: qpdf is required to normalize generated PDFs\n", .{});
        return err;
    };
    return out;
}

fn iconDocumentSource(allocator: Allocator, spec: IconSpec) ![]const u8 {
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

fn mathDocumentSource(ctx: *DrawContext, source: []const u8, preamble: []const TexPreambleEntry, kind: MathKind) ![]const u8 {
    const preamble_lines = try mathPreambleLines(ctx, preamble);
    defer ctx.allocator.free(preamble_lines);
    const fragment = try mathTexFragment(ctx.allocator, source, kind);
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

fn mathTexFragment(allocator: Allocator, source: []const u8, kind: MathKind) ![]const u8 {
    switch (kind) {
        .inline_math => return std.fmt.allocPrint(allocator, "$\\mathstrut {s}$\n", .{source}),
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

fn mathKindForNode(node: *const core.Node) MathKind {
    return switch (node.payload_kind orelse .text) {
        .math_tex => .raw_block,
        .math_text => .block,
        else => .block,
    };
}

fn mathPreambleLines(ctx: *DrawContext, preamble: []const TexPreambleEntry) ![]const u8 {
    const allocator = ctx.allocator;
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    for (preamble) |entry| {
        const text = switch (entry.source) {
            .text => entry.value,
            .file => try readTexPreambleFile(ctx, entry.value),
        };
        defer if (entry.source == .file) allocator.free(text);
        if (std.mem.trim(u8, text, " \t\r\n").len == 0) continue;
        try out.append(allocator, '\n');
        try out.appendSlice(allocator, text);
        if (text[text.len - 1] != '\n') try out.append(allocator, '\n');
    }
    return try out.toOwnedSlice(allocator);
}

fn readTexPreambleFile(ctx: *DrawContext, path: []const u8) ![]const u8 {
    const resolved = try resolveAssetPath(ctx, path);
    defer ctx.allocator.free(resolved);
    return std.Io.Dir.cwd().readFileAlloc(ctx.io, resolved, ctx.allocator, .unlimited) catch |err| {
        std.debug.print("native pdf: TeX preamble file not found: {s} (resolved: {s})\n", .{ path, resolved });
        return err;
    };
}

fn cachedAssetPath(ctx: *DrawContext, kind: []const u8, source: []const u8, extension: []const u8) ![]u8 {
    const fingerprint = try streamFileFingerprint(ctx, source);
    var hasher = std.hash.Wyhash.init(0);
    hashString(&hasher, native_artifact_cache_version);
    hashString(&hasher, kind);
    hashLogicalAssetPath(ctx, &hasher, source);
    hashBool(&hasher, fingerprint.present);
    hashU64(&hasher, fingerprint.digest);
    return std.fmt.allocPrint(ctx.allocator, "{s}/{s}-{x}.{s}", .{ ctx.cache_dir, kind, hasher.final(), extension });
}

fn cachedSizedAssetPath(ctx: *DrawContext, kind: []const u8, source: []const u8, target_width: f32, target_height: f32, extension: []const u8) ![]u8 {
    const fingerprint = try streamFileFingerprint(ctx, source);
    const target_width_px = rasterTargetPixels(target_width);
    const target_height_px = rasterTargetPixels(target_height);
    var hasher = std.hash.Wyhash.init(0);
    hashString(&hasher, native_artifact_cache_version);
    hashString(&hasher, kind);
    hashLogicalAssetPath(ctx, &hasher, source);
    hashU32(&hasher, target_width_px);
    hashU32(&hasher, target_height_px);
    hashBool(&hasher, fingerprint.present);
    hashU64(&hasher, fingerprint.digest);
    return std.fmt.allocPrint(ctx.allocator, "{s}/{s}-{x}.{s}", .{ ctx.cache_dir, kind, hasher.final(), extension });
}

fn rasterTargetPixels(value: f32) u32 {
    return @intFromFloat(@ceil(@max(value, 1.0)));
}

fn cachedTextPath(ctx: *DrawContext, kind: []const u8, source: []const u8, extension: []const u8) ![]u8 {
    var hasher = std.hash.Wyhash.init(0);
    hashString(&hasher, native_artifact_cache_version);
    hashString(&hasher, kind);
    hashString(&hasher, source);
    return std.fmt.allocPrint(ctx.allocator, "{s}/{s}-{x}.{s}", .{ ctx.cache_dir, kind, hasher.final(), extension });
}

fn cachedMathPath(ctx: *DrawContext, source: []const u8, preamble: []const TexPreambleEntry, kind: MathKind, extension: []const u8) ![]u8 {
    var hasher = std.hash.Wyhash.init(0);
    hashString(&hasher, native_artifact_cache_version);
    hashString(&hasher, "math");
    hashString(&hasher, @tagName(kind));
    hashString(&hasher, source);
    try hashTexPreambleEntries(ctx, null, &hasher, preamble);
    return std.fmt.allocPrint(ctx.allocator, "{s}/math-{x}.{s}", .{ ctx.cache_dir, hasher.final(), extension });
}

fn cachedIconPath(ctx: *DrawContext, source: []const u8, extension: []const u8) ![]u8 {
    var hasher = std.hash.Wyhash.init(0);
    hashString(&hasher, native_artifact_cache_version);
    hashString(&hasher, "fontawesome6");
    hashString(&hasher, source);
    return std.fmt.allocPrint(ctx.allocator, "{s}/fontawesome6-{x}.{s}", .{ ctx.cache_dir, hasher.final(), extension });
}

fn tempCachePath(ctx: *DrawContext, final_path: []const u8, extension: []const u8) ![]u8 {
    const serial = @atomicRmw(usize, &temp_cache_counter, .Add, 1, .monotonic);
    return std.fmt.allocPrint(
        ctx.allocator,
        "{s}.tmp-{d}-{d}.{s}",
        .{ final_path, std.c.getpid(), serial, extension },
    );
}

fn publishCacheFile(ctx: *DrawContext, tmp_path: []const u8, final_path: []const u8) !void {
    if (fileExists(final_path)) {
        deleteFileIfExists(ctx, tmp_path);
        return;
    }
    const cwd = std.Io.Dir.cwd();
    cwd.rename(tmp_path, cwd, final_path, ctx.io) catch |err| {
        if (fileExists(final_path)) {
            deleteFileIfExists(ctx, tmp_path);
            return;
        }
        return err;
    };
}

fn deleteFileIfExists(ctx: *DrawContext, path: []const u8) void {
    std.Io.Dir.cwd().deleteFile(ctx.io, path) catch {};
}

fn validatePng(path: []const u8) !void {
    var source_width: f64 = 0;
    var source_height: f64 = 0;
    var buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (path.len >= buf.len) return NativePdfError.ImageDecodeFailed;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    if (c.ss_png_size(@ptrCast(&buf), &source_width, &source_height) != 0) return NativePdfError.ImageDecodeFailed;
    if (source_width <= 0 or source_height <= 0) return NativePdfError.ImageDecodeFailed;
}

fn cachedPngAvailable(ctx: *DrawContext, path: []const u8) !bool {
    if (!fileExists(path)) return false;
    validatePng(path) catch |err| switch (err) {
        error.ImageDecodeFailed => {
            deleteFileIfExists(ctx, path);
            return false;
        },
        else => return err,
    };
    return true;
}

fn cachedPdfAvailable(ctx: *DrawContext, path: []const u8) !bool {
    if (!fileExists(path)) return false;
    validatePdfFile(ctx, path) catch |err| switch (err) {
        error.InvalidPdfCache => {
            deleteFileIfExists(ctx, path);
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

fn cachedSvgAsset(ctx: *DrawContext, path: []const u8) !?SvgAsset {
    if (!fileExists(path)) return null;
    return svgAsset(ctx, path) catch |err| switch (err) {
        error.ImageDecodeFailed => {
            deleteFileIfExists(ctx, path);
            return null;
        },
        else => return err,
    };
}

fn svgAsset(ctx: *DrawContext, path: []const u8) !SvgAsset {
    var source_width: f64 = 0;
    var source_height: f64 = 0;
    const svg_z = try ctx.allocator.dupeZ(u8, path);
    defer ctx.allocator.free(svg_z);
    if (c.ss_svg_size(svg_z.ptr, &source_width, &source_height) != 0) return NativePdfError.ImageDecodeFailed;
    return .{
        .path = path,
        .width = @floatCast(source_width),
        .height = @floatCast(source_height),
    };
}

fn runChecked(ctx: *DrawContext, argv: []const []const u8, cwd: std.process.Child.Cwd) !void {
    try runCheckedWithOptions(ctx, argv, cwd, false);
}

fn runCheckedAllowQpdfWarnings(ctx: *DrawContext, argv: []const []const u8, cwd: std.process.Child.Cwd) !void {
    try runCheckedWithOptions(ctx, argv, cwd, true);
}

fn runCheckedWithOptions(ctx: *DrawContext, argv: []const []const u8, cwd: std.process.Child.Cwd, allow_qpdf_warning_exit: bool) !void {
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
        .exited => |code| if (code == 0 or (allow_qpdf_warning_exit and code == 3)) return,
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

fn fileExists(path: []const u8) bool {
    var buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (path.len >= buf.len) return false;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return std.c.access(@ptrCast(&buf), 0) == 0;
}

fn insetFrame(frame: Frame, dx: f32, dy: f32) Frame {
    return .{
        .x = frame.x + dx,
        .y = frame.y + dy,
        .width = @max(frame.width - dx * 2, 0),
        .height = @max(frame.height - dy * 2, 0),
    };
}

fn topOf(frame: Frame) f32 {
    return PageLayout.height - frame.y - frame.height;
}

fn toTopY(bottom_y: f32) f32 {
    return PageLayout.height - bottom_y;
}
