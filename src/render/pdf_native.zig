const std = @import("std");
const core = @import("core");
const utils = @import("utils");
const build_options = @import("build_options");

const declarations = @import("../language/declarations.zig");
const semantic_env = @import("../language/env.zig");
const text_tokenize = core.text_tokenize;
const wrap_layout = core.render_wrap;

const c = @cImport({
    @cInclude("pdf.h");
});

const TSLanguage = opaque {};
const TSParser = opaque {};
const TSTree = opaque {};
const TSQuery = opaque {};
const TSQueryCursor = opaque {};

const TSQueryError = enum(c_int) {
    none = 0,
    syntax = 1,
    node_type = 2,
    field = 3,
    capture = 4,
    structure = 5,
    language = 6,
};

const TSNode = extern struct {
    context: [4]u32,
    id: ?*const anyopaque,
    tree: ?*const TSTree,
};

const TSQueryCapture = extern struct {
    node: TSNode,
    index: u32,
};

const TSQueryMatch = extern struct {
    id: u32,
    pattern_index: u16,
    capture_count: u16,
    captures: [*c]const TSQueryCapture,
};

extern fn tree_sitter_ss() *const TSLanguage;
extern fn tree_sitter_bash() *const TSLanguage;
extern fn tree_sitter_c() *const TSLanguage;
extern fn tree_sitter_cpp() *const TSLanguage;
extern fn tree_sitter_css() *const TSLanguage;
extern fn tree_sitter_go() *const TSLanguage;
extern fn tree_sitter_html() *const TSLanguage;
extern fn tree_sitter_java() *const TSLanguage;
extern fn tree_sitter_javascript() *const TSLanguage;
extern fn tree_sitter_json() *const TSLanguage;
extern fn tree_sitter_julia() *const TSLanguage;
extern fn tree_sitter_python() *const TSLanguage;
extern fn tree_sitter_rust() *const TSLanguage;
extern fn tree_sitter_toml() *const TSLanguage;
extern fn tree_sitter_typescript() *const TSLanguage;
extern fn tree_sitter_tsx() *const TSLanguage;
extern fn tree_sitter_yaml() *const TSLanguage;
extern fn tree_sitter_zig() *const TSLanguage;

extern fn ts_parser_new() ?*TSParser;
extern fn ts_parser_delete(*TSParser) void;
extern fn ts_parser_set_language(*TSParser, *const TSLanguage) bool;
extern fn ts_parser_parse_string(*TSParser, ?*const TSTree, [*c]const u8, u32) ?*TSTree;
extern fn ts_tree_delete(*TSTree) void;
extern fn ts_tree_root_node(*const TSTree) TSNode;
extern fn ts_query_new(*const TSLanguage, [*c]const u8, u32, *u32, *TSQueryError) ?*TSQuery;
extern fn ts_query_delete(*TSQuery) void;
extern fn ts_query_capture_name_for_id(*const TSQuery, u32, *u32) ?[*]const u8;
extern fn ts_query_cursor_new() ?*TSQueryCursor;
extern fn ts_query_cursor_delete(*TSQueryCursor) void;
extern fn ts_query_cursor_exec(*TSQueryCursor, *const TSQuery, TSNode) void;
extern fn ts_query_cursor_next_capture(*TSQueryCursor, *TSQueryMatch, *u32) bool;
extern fn ts_node_start_byte(TSNode) u32;
extern fn ts_node_end_byte(TSNode) u32;

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
pub const page_pdf_cache_version = "ss-native-page-pdf-v22";
pub const qpdf_cache_version = "ss-native-qpdf-v1";
pub const native_artifact_cache_version = "ss-native-artifacts-v2";
const external_command_timeout = std.Io.Clock.Duration{
    .raw = std.Io.Duration.fromSeconds(120),
    .clock = .awake,
};
const command_failure_output_limit: usize = 1600;
const warm_render_job_cap: usize = 4;
const cold_render_job_cap: usize = 16;
const artifact_job_slack: usize = 2;
const highlight_query_read_limit = 1024 * 1024;
pub const tree_sitter_language_version: u32 = build_options.tree_sitter_language_version;
pub const tree_sitter_min_compatible_language_version: u32 = build_options.tree_sitter_min_compatible_language_version;

pub const NativeRuntimeVersions = struct {
    cairo: []const u8,
    pango: []const u8,
    librsvg: []const u8,
    fontconfig: u32,
    harfbuzz: []const u8,
};

pub fn nativeRuntimeVersions() NativeRuntimeVersions {
    return .{
        .cairo = spanCString(c.ss_pdf_cairo_version_string()),
        .pango = spanCString(c.ss_pdf_pango_version_string()),
        .librsvg = spanCString(c.ss_pdf_librsvg_version_string()),
        .fontconfig = @intCast(c.ss_pdf_fontconfig_version()),
        .harfbuzz = spanCString(c.ss_pdf_harfbuzz_version_string()),
    };
}

const DrawContext = struct {
    allocator: Allocator,
    io: std.Io,
    pdf: *c.SsPdf,
    asset_base_dir: []const u8,
    cache_dir: []const u8,
    highlight_languages: []const utils.highlight.Language,
    command_failure: ?*CommandFailureSink = null,
    link_annotations: ?*std.ArrayList(LinkAnnotation) = null,
    destinations: ?*std.ArrayList(DestinationAnnotation) = null,
};

const LinkAnnotation = struct {
    kind: Kind,
    target: []const u8,
    x: f32,
    y: f32,
    width: f32,
    height: f32,

    const Kind = enum { uri, dest };

    fn deinit(self: LinkAnnotation, allocator: Allocator) void {
        allocator.free(self.target);
    }
};

const DestinationAnnotation = struct {
    name: []const u8,
    x: f32,
    y: f32,

    fn deinit(self: DestinationAnnotation, allocator: Allocator) void {
        allocator.free(self.name);
    }
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
    icon: IconPreload,
    vector_pdf: VectorPdfPreload,
    raster: RasterPreload,
};

const MathPreload = struct {
    source: []const u8,
    preamble: []const TexPreambleEntry,
    kind: MathKind,
    target: RenderDiagnosticTarget = .{},
};

const RasterPreload = struct {
    source: []const u8,
    target_width: f32,
    target_height: f32,
    target: RenderDiagnosticTarget = .{},
};

const IconPreload = struct {
    source: []const u8,
    target: RenderDiagnosticTarget = .{},
};

const VectorPdfPreload = struct {
    source: []const u8,
    target: RenderDiagnosticTarget = .{},
};

const RenderDiagnosticTarget = struct {
    page_id: ?core.NodeId = null,
    node_id: ?core.NodeId = null,
    origin: ?[]const u8 = null,
    payload_kind: ?core.PayloadKind = null,
    content_provenance: []const core.ContentProvenance = &.{},
    content_start: ?usize = null,
    content_end: ?usize = null,
};

const CommandFailureSink = struct {
    allocator: Allocator,
    message: ?[]u8 = null,

    fn deinit(self: *CommandFailureSink) void {
        if (self.message) |message| self.allocator.free(message);
    }

    fn record(self: *CommandFailureSink, message: []const u8) !void {
        if (self.message != null) return;
        self.message = try self.allocator.dupe(u8, message);
    }
};

pub const RenderOptions = struct {
    jobs: ?usize = null,
    keep_temps: bool = false,
    cache_dir: []const u8 = ".ss-cache/render",
    cache_id: ?[]const u8 = null,
    highlight_languages: []const utils.highlight.Language = &.{},
};

const HighlightSpan = struct {
    start: usize,
    end: usize,
    color: Color,
};

const HighlightLanguageHandle = struct {
    language: *const TSLanguage,

    fn deinit(_: *HighlightLanguageHandle) void {}
};

pub const TreeSitterHealthStatus = enum {
    ok,
    warning,
    fail,
};

pub const TreeSitterHealthItem = struct {
    name: []u8,
    parser: []u8,
    query: []u8,
    status: TreeSitterHealthStatus,
    detail: []u8,
    capture_count: usize = 0,
    mapped_capture_count: usize = 0,

    pub fn deinit(self: *TreeSitterHealthItem, allocator: Allocator) void {
        allocator.free(self.name);
        allocator.free(self.parser);
        allocator.free(self.query);
        allocator.free(self.detail);
    }
};

pub const TreeSitterHealthReport = struct {
    configured_languages: usize,
    failures: usize,
    warnings: usize,
    items: []TreeSitterHealthItem,

    pub fn deinit(self: *TreeSitterHealthReport, allocator: Allocator) void {
        for (self.items) |*item| item.deinit(allocator);
        allocator.free(self.items);
    }
};

const TreeSitterRuntime = struct {
    parser_new: *const fn () callconv(.c) ?*TSParser,
    parser_delete: *const fn (*TSParser) callconv(.c) void,
    parser_set_language: *const fn (*TSParser, *const TSLanguage) callconv(.c) bool,
    parser_parse_string: *const fn (*TSParser, ?*const TSTree, [*c]const u8, u32) callconv(.c) ?*TSTree,
    tree_delete: *const fn (*TSTree) callconv(.c) void,
    tree_root_node: *const fn (*const TSTree) callconv(.c) TSNode,
    query_new: *const fn (*const TSLanguage, [*c]const u8, u32, *u32, *TSQueryError) callconv(.c) ?*TSQuery,
    query_delete: *const fn (*TSQuery) callconv(.c) void,
    query_capture_name_for_id: *const fn (*const TSQuery, u32, *u32) callconv(.c) ?[*]const u8,
    query_cursor_new: *const fn () callconv(.c) ?*TSQueryCursor,
    query_cursor_delete: *const fn (*TSQueryCursor) callconv(.c) void,
    query_cursor_exec: *const fn (*TSQueryCursor, *const TSQuery, TSNode) callconv(.c) void,
    query_cursor_next_capture: *const fn (*TSQueryCursor, *TSQueryMatch, *u32) callconv(.c) bool,
    node_start_byte: *const fn (TSNode) callconv(.c) u32,
    node_end_byte: *const fn (TSNode) callconv(.c) u32,

    fn deinit(self: *TreeSitterRuntime) void {
        _ = self;
    }
};

const RenderOp = struct {
    page_id: core.NodeId,
    node_id: core.NodeId,
    frame: Frame,
    content: []const u8,
    content_provenance: []const core.ContentProvenance = &.{},
    link_id: ?[]const u8 = null,
    render: ResolvedRender,
    parse_mode: core.markdown.ParseMode,
    tex_preamble: []const TexPreambleEntry,
    math_kind: MathKind = .block,
    origin: ?[]const u8 = null,
    payload_kind: ?core.PayloadKind = null,

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
    chunks_dir: []const u8,
    final_pdf_path: []const u8,
    previous_chunks_dir: ?[]const u8,
    previous_document_path: ?[]const u8,
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
        self.allocator.free(self.chunks_dir);
        self.allocator.free(self.final_pdf_path);
        if (self.previous_chunks_dir) |path| self.allocator.free(path);
        if (self.previous_document_path) |path| self.allocator.free(path);
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
    highlight_languages: []const utils.highlight.Language,
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
        .highlight_languages = options.highlight_languages,
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

    executeRenderDag(&ctx, &plan, options, progress) catch |err| {
        try collectPlanRenderDiagnostics(&ctx, ir, &plan, err);
        return error.DiagnosticsFailed;
    };
    try writeRenderManifest(&ctx, &plan);
    var assembly_failure = CommandFailureSink{ .allocator = ir.allocator };
    defer assembly_failure.deinit();
    var assembly_ctx = ctx;
    assembly_ctx.command_failure = &assembly_failure;
    const reused_document = try reusePreviousDocumentPdf(&assembly_ctx, &plan, progress);
    if (!reused_document) {
        assembleRenderPlan(&assembly_ctx, &plan, options, progress) catch |err| {
            try addGenericRenderDiagnostic(ir, err, assembly_failure.message);
            return error.DiagnosticsFailed;
        };
    }
    storeRenderPlanDocumentPdf(&assembly_ctx, &plan) catch |err| {
        try addGenericRenderDiagnostic(ir, err, assembly_failure.message);
        return error.DiagnosticsFailed;
    };
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
    const chunks_dir = try std.fs.path.join(ctx.allocator, &.{ building_dir, "chunks" });
    errdefer ctx.allocator.free(chunks_dir);
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
                const uses_asset_content = switch (node.payload_kind orelse .text) {
                    .image_ref, .pdf_ref => true,
                    else => false,
                };
                var op = RenderOp{
                    .page_id = page.id,
                    .node_id = node.id,
                    .frame = node.frame,
                    .content = if (uses_asset_content) node.content orelse "" else core.nodeDisplayContent(node),
                    .content_provenance = if (uses_asset_content) node.content_provenance.items else core.nodeDisplayContentProvenance(node),
                    .link_id = core.nodeProperty(node, "link_id"),
                    .render = core.render_policy.resolveWithEnv(ir, node, sema),
                    .parse_mode = core.markdown.parseModeForNode(ir, node),
                    .tex_preamble = try cloneTexPreambleEntries(ctx.allocator, env.tex_preamble.items),
                    .math_kind = mathKindForNode(node),
                    .origin = node.origin,
                    .payload_kind = node.payload_kind,
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
    const previous_chunks_dir = try previousGenerationSubdir(ctx, if (previous_generation) |*previous| previous else null, "chunks");
    errdefer if (previous_chunks_dir) |path| ctx.allocator.free(path);
    const previous_document_path = try reusablePreviousDocumentPdf(ctx, if (previous_generation) |*previous| previous else null, page_slice);
    errdefer if (previous_document_path) |path| ctx.allocator.free(path);

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
        .chunks_dir = chunks_dir,
        .final_pdf_path = final_pdf_path,
        .previous_chunks_dir = previous_chunks_dir,
        .previous_document_path = previous_document_path,
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

fn documentPdfPath(allocator: Allocator, generation_dir: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ generation_dir, "document.pdf" });
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

fn previousGenerationSubdir(ctx: *DrawContext, previous: ?*const PreviousGeneration, name: []const u8) !?[]u8 {
    const generation = previous orelse return null;
    return try std.fs.path.join(ctx.allocator, &.{ generation.dir, name });
}

fn reusablePreviousDocumentPdf(ctx: *DrawContext, previous: ?*const PreviousGeneration, pages: []const RenderPage) !?[]u8 {
    const generation = previous orelse return null;
    if (generation.manifest.hashes.len != pages.len) return null;
    for (pages, 0..) |page, index| {
        if (generation.manifest.hashes[index] != page.page_hash) return null;
    }

    const path = try documentPdfPath(ctx.allocator, generation.dir);
    errdefer ctx.allocator.free(path);
    if (!(try cachedPdfAvailable(ctx, path))) {
        ctx.allocator.free(path);
        return null;
    }
    return path;
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

fn qpdfPageHashCachePath(allocator: Allocator, cache_dir: []const u8, prefix: []const u8, pages: []const RenderPage) ![]u8 {
    var hasher = std.hash.Wyhash.init(0);
    hashString(&hasher, qpdf_cache_version);
    hashString(&hasher, prefix);
    hashBool(&hasher, true);
    hashUsize(&hasher, pages.len);
    for (pages) |page| hashU64(&hasher, page.page_hash);
    return qpdfCachePath(allocator, cache_dir, prefix, hasher.final());
}

fn qpdfCachePath(allocator: Allocator, cache_dir: []const u8, prefix: []const u8, hash: u64) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}-{x}.pdf", .{ cache_dir, prefix, hash });
}

fn renderPageHash(ctx: *DrawContext, asset_fingerprints: *std.StringHashMap(FileFingerprint), background: ?Color, ops: []const RenderOp) !u64 {
    var hasher = std.hash.Wyhash.init(0);
    hashString(&hasher, page_pdf_cache_version);
    hashNativePdfRuntime(&hasher);
    hashF32(&hasher, PageLayout.width);
    hashF32(&hasher, PageLayout.height);
    hashF32(&hasher, raster_cache_scale);
    try hashHighlightLanguages(ctx, asset_fingerprints, &hasher);
    hashOptionalColor(&hasher, background);
    hashUsize(&hasher, ops.len);
    for (ops) |*op| try hashRenderOp(ctx, asset_fingerprints, &hasher, op);
    return hasher.final();
}

fn hashHighlightLanguages(ctx: *DrawContext, asset_fingerprints: *std.StringHashMap(FileFingerprint), hasher: *std.hash.Wyhash) !void {
    hashUsize(hasher, ctx.highlight_languages.len);
    for (ctx.highlight_languages) |language| {
        hashString(hasher, language.name);
        hashString(hasher, language.parser);
        hashString(hasher, language.query);
        if (!std.mem.startsWith(u8, language.query, "builtin:")) {
            const fingerprint = try assetFileFingerprint(ctx, asset_fingerprints, language.query);
            hashBool(hasher, fingerprint.present);
            hashU64(hasher, fingerprint.digest);
        }
    }
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
        hashOptionalColor(hasher, text.markdown_code_plain_color);
        hashOptionalColor(hasher, text.markdown_code_keyword_color);
        hashOptionalColor(hasher, text.markdown_code_function_color);
        hashOptionalColor(hasher, text.markdown_code_type_color);
        hashOptionalColor(hasher, text.markdown_code_constant_color);
        hashOptionalColor(hasher, text.markdown_code_number_color);
        hashOptionalColor(hasher, text.markdown_code_variable_color);
        hashOptionalColor(hasher, text.markdown_code_operator_color);
        hashOptionalColor(hasher, text.markdown_code_comment_color);
        hashOptionalColor(hasher, text.markdown_code_string_color);
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
    }
}

fn hashOptionalCodePaint(hasher: *std.hash.Wyhash, maybe: ?CodePaint) void {
    hashBool(hasher, maybe != null);
    if (maybe) |code| {
        hashBool(hasher, code.language != null);
        if (code.language) |language| hashString(hasher, language);
        hashColor(hasher, code.plain);
        hashColor(hasher, code.keyword);
        hashColor(hasher, code.function);
        hashColor(hasher, code.type);
        hashColor(hasher, code.constant);
        hashColor(hasher, code.number);
        hashColor(hasher, code.variable);
        hashColor(hasher, code.operator);
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

fn hashCString(hasher: *std.hash.Wyhash, ptr: [*c]const u8) void {
    hashBool(hasher, ptr != null);
    if (ptr == null) return;
    hashString(hasher, spanCString(ptr));
}

fn hashNativePdfRuntime(hasher: *std.hash.Wyhash) void {
    hashCString(hasher, c.ss_pdf_cairo_version_string());
    hashCString(hasher, c.ss_pdf_pango_version_string());
    hashCString(hasher, c.ss_pdf_librsvg_version_string());
    hashU32(hasher, @intCast(c.ss_pdf_fontconfig_version()));
    hashCString(hasher, c.ss_pdf_harfbuzz_version_string());
}

fn spanCString(ptr: [*c]const u8) []const u8 {
    if (ptr == null) return "unknown";
    const sentinel: [*:0]const u8 = @ptrCast(ptr);
    return std.mem.span(sentinel);
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
    const target = opDiagnosticTarget(op);
    switch (op.render.kind) {
        .text => if (op.render.text != null) try collectTextOpPreloads(ctx, op, target, tasks, seen, page_deps),
        .vector_math => {
            try registerPlanPreloadTask(ctx, tasks, seen, page_deps, .{ .math = .{
                .source = try ctx.allocator.dupe(u8, op.content),
                .preamble = try cloneTexPreambleEntries(ctx.allocator, op.tex_preamble),
                .kind = op.math_kind,
                .target = targetWithContentSpan(target, 0, op.content.len),
            } });
        },
        .vector_asset => {
            const source = try resolveAssetPath(ctx, op.content);
            if (std.ascii.eqlIgnoreCase(std.fs.path.extension(source), ".pdf")) {
                try registerPlanPreloadTask(ctx, tasks, seen, page_deps, .{ .vector_pdf = .{
                    .source = source,
                    .target = targetWithContentSpan(target, 0, op.content.len),
                } });
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
                    .target = targetWithContentSpan(target, 0, op.content.len),
                } });
            }
        },
        .code, .chrome_only => {},
    }
}

fn opDiagnosticTarget(op: *const RenderOp) RenderDiagnosticTarget {
    return .{
        .page_id = op.page_id,
        .node_id = op.node_id,
        .origin = op.origin,
        .payload_kind = op.payload_kind,
        .content_provenance = op.content_provenance,
    };
}

fn targetWithContentSpan(target: RenderDiagnosticTarget, start: usize, end: usize) RenderDiagnosticTarget {
    var refined = target;
    refined.content_start = start;
    refined.content_end = end;
    return refined;
}

fn targetWithRunSpan(target: RenderDiagnosticTarget, runs: []const Run) RenderDiagnosticTarget {
    if (runs.len == 0) return target;
    var start = runs[0].source_start;
    var end = runs[0].source_end;
    for (runs[1..]) |run| {
        start = @min(start, run.source_start);
        end = @max(end, run.source_end);
    }
    return targetWithContentSpan(target, start, end);
}

fn collectTextOpPreloads(
    ctx: *DrawContext,
    op: *const RenderOp,
    target: RenderDiagnosticTarget,
    tasks: *std.ArrayList(PreloadTask),
    seen: *std.StringHashMap(usize),
    page_deps: *std.ArrayList(usize),
) !void {
    switch (op.parse_mode) {
        .none => return,
        .block => {
            var doc = try core.markdown.parseMarkdownContent(ctx.allocator, op.content);
            defer doc.deinit();
            try collectMarkdownBlockPreloadsForPlan(ctx, doc.blocks.items, op.tex_preamble, target, tasks, seen, page_deps);
        },
        .@"inline" => {
            var layout = try core.markdown.parseTextLayoutContent(ctx.allocator, op.content);
            defer layout.deinit(ctx.allocator);
            try collectLinePreloadsForPlan(ctx, layout.lines.items, op.tex_preamble, target, tasks, seen, page_deps);
        },
    }
}

fn collectMarkdownBlockPreloadsForPlan(
    ctx: *DrawContext,
    blocks: []const *Block,
    preamble: []const TexPreambleEntry,
    target: RenderDiagnosticTarget,
    tasks: *std.ArrayList(PreloadTask),
    seen: *std.StringHashMap(usize),
    page_deps: *std.ArrayList(usize),
) !void {
    for (blocks) |block| {
        switch (block.kind) {
            .paragraph, .code_block => if (block.paragraph) |paragraph| {
                try collectLinePreloadsForPlan(ctx, paragraph.lines.items, preamble, target, tasks, seen, page_deps);
            },
            .bullet_list, .ordered_list => if (block.list) |list| {
                for (list.items.items) |item| {
                    try collectMarkdownBlockPreloadsForPlan(ctx, item.blocks.items, preamble, target, tasks, seen, page_deps);
                }
            },
            .table => if (block.table) |table| {
                for (table.rows.items) |row| {
                    for (row.cells.items) |cell| {
                        try collectLinePreloadsForPlan(ctx, cell.lines.items, preamble, target, tasks, seen, page_deps);
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
    target: RenderDiagnosticTarget,
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
                            .target = targetWithRunSpan(target, runs[start..index]),
                        } });
                    }
                    continue;
                },
                .math => try registerPlanPreloadTask(ctx, tasks, seen, page_deps, .{ .math = .{
                    .source = try ctx.allocator.dupe(u8, run.text),
                    .preamble = try cloneTexPreambleEntries(ctx.allocator, preamble),
                    .kind = .inline_math,
                    .target = targetWithContentSpan(target, run.source_start, run.source_end),
                } }),
                .icon => if (run.icon) |source| try registerPlanPreloadTask(ctx, tasks, seen, page_deps, .{
                    .icon = .{
                        .source = try ctx.allocator.dupe(u8, source),
                        .target = targetWithContentSpan(target, run.source_start, run.source_end),
                    },
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

fn collectPlanRenderDiagnostics(ctx: *DrawContext, ir: *core.Ir, plan: *const RenderPlan, original_err: anyerror) !void {
    ir.clearDiagnosticsForPhase(.render);
    var added = false;
    for (plan.artifact_tasks, 0..) |task, index| {
        if (index < plan.artifact_cached.len and plan.artifact_cached[index]) continue;
        if (try preloadTaskCached(ctx, task)) continue;

        var sink = CommandFailureSink{ .allocator = ir.allocator };
        defer sink.deinit();
        var diagnostic_ctx = ctx.*;
        diagnostic_ctx.command_failure = &sink;
        preloadOne(&diagnostic_ctx, task) catch |err| {
            try addPreloadRenderDiagnostic(ir, task, err, sink.message);
            added = true;
        };
    }

    if (!added) {
        added = try collectPageRenderDiagnostics(ctx, ir, plan);
    }

    if (!added) try addGenericRenderDiagnostic(ir, original_err, null);
}

fn addPreloadRenderDiagnostic(ir: *core.Ir, task: PreloadTask, err: anyerror, maybe_message: ?[]const u8) !void {
    const target = preloadTaskTarget(task);
    try addTargetedRenderDiagnostic(ir, target, preloadTaskLabel(task), err, maybe_message);
}

fn addTargetedRenderDiagnostic(
    ir: *core.Ir,
    target: RenderDiagnosticTarget,
    label: []const u8,
    err: anyerror,
    maybe_message: ?[]const u8,
) !void {
    var origin = try preloadTaskDiagnosticOrigin(ir, target);
    defer origin.deinit(ir.allocator);
    const detail = maybe_message orelse @errorName(err);
    const reason = try std.fmt.allocPrint(ir.allocator, "{s}: {s}", .{ label, detail });
    try ir.addRenderDiagnostic(.@"error", target.page_id, target.node_id, origin.text, .{
        .render_failed = .{
            .reason = reason,
            .payload_kind = target.payload_kind,
        },
    });
}

const DiagnosticOrigin = struct {
    text: ?[]const u8,
    owned: bool = false,

    fn deinit(self: *DiagnosticOrigin, allocator: Allocator) void {
        if (self.owned) {
            if (self.text) |text| allocator.free(text);
        }
    }
};

fn preloadTaskDiagnosticOrigin(ir: *core.Ir, target: RenderDiagnosticTarget) !DiagnosticOrigin {
    if (target.content_start) |start| {
        if (target.content_end) |end| {
            if (try originForContentSpan(ir.allocator, target.content_provenance, start, end)) |origin| {
                return .{ .text = origin, .owned = true };
            }
        }
    }
    return .{ .text = target.origin };
}

fn originForContentSpan(
    allocator: Allocator,
    entries: []const core.ContentProvenance,
    content_start: usize,
    content_end: usize,
) !?[]const u8 {
    const normalized_end = @max(content_end, content_start);
    for (entries) |entry| {
        if (content_start < entry.content_start or normalized_end > entry.content_end) continue;
        const located = utils.err.parseLocatedOrigin(entry.origin) orelse continue;
        const start = located.span.start + (content_start - entry.content_start);
        const end = located.span.start + (normalized_end - entry.content_start);
        if (located.path) |path| {
            return try std.fmt.allocPrint(allocator, "path:{s}:bytes:{d}-{d}", .{ path, start, end });
        }
        return try std.fmt.allocPrint(allocator, "bytes:{d}-{d}", .{ start, end });
    }
    return null;
}

fn addGenericRenderDiagnostic(ir: *core.Ir, err: anyerror, maybe_message: ?[]const u8) !void {
    const detail = maybe_message orelse @errorName(err);
    const reason = try std.fmt.allocPrint(ir.allocator, "render backend: {s}", .{detail});
    try ir.addRenderDiagnostic(.@"error", null, null, null, .{
        .render_failed = .{
            .reason = reason,
        },
    });
}

fn collectPageRenderDiagnostics(ctx: *DrawContext, ir: *core.Ir, plan: *const RenderPlan) !bool {
    var added = false;
    for (plan.pages) |*page| {
        if (page.cache_hit) continue;
        if (try collectPageRenderDiagnostic(ctx, ir, page)) added = true;
    }
    return added;
}

fn collectPageRenderDiagnostic(ctx: *DrawContext, ir: *core.Ir, page: *const RenderPage) !bool {
    const path = try tempCachePath(ctx, page.render_path, "pdf");
    defer ctx.allocator.free(path);
    defer deleteFileIfExists(ctx, path);

    const path_z = try ctx.allocator.dupeZ(u8, path);
    defer ctx.allocator.free(path_z);

    const pdf = c.ss_pdf_create(path_z.ptr, PageLayout.width, PageLayout.height) orelse return false;
    defer c.ss_pdf_destroy(pdf);
    c.ss_pdf_set_creator(pdf, "ss native Cairo/Pango backend");

    var diagnostic_ctx = ctx.*;
    diagnostic_ctx.pdf = pdf;

    c.ss_pdf_begin_page(pdf, PageLayout.width, PageLayout.height);
    const added = try drawRenderPageDiagnostics(&diagnostic_ctx, ir, page);
    c.ss_pdf_end_page(pdf);
    return added;
}

fn drawRenderPageDiagnostics(ctx: *DrawContext, ir: *core.Ir, page: *const RenderPage) !bool {
    if (page.background) |fill| {
        c.ss_pdf_fill_rect(ctx.pdf, 0, 0, PageLayout.width, PageLayout.height, fill.r, fill.g, fill.b);
    }
    for (page.ops) |*op| {
        if (op.render.kind == .chrome_only) {
            if (try drawRenderOpDiagnostic(ctx, ir, op)) return true;
        }
    }
    for (page.ops) |*op| {
        if (op.render.kind != .chrome_only) {
            if (try drawRenderOpDiagnostic(ctx, ir, op)) return true;
        }
    }
    return false;
}

fn drawRenderOpDiagnostic(ctx: *DrawContext, ir: *core.Ir, op: *const RenderOp) !bool {
    var sink = CommandFailureSink{ .allocator = ir.allocator };
    defer sink.deinit();
    var diagnostic_ctx = ctx.*;
    diagnostic_ctx.command_failure = &sink;
    drawRenderOp(&diagnostic_ctx, op) catch |err| {
        try addRenderOpDiagnostic(ir, op, err, sink.message);
        return true;
    };
    return false;
}

fn addRenderOpDiagnostic(ir: *core.Ir, op: *const RenderOp, err: anyerror, maybe_message: ?[]const u8) !void {
    try addTargetedRenderDiagnostic(ir, renderOpDiagnosticTarget(op), renderOpLabel(op), err, maybe_message);
}

fn renderOpDiagnosticTarget(op: *const RenderOp) RenderDiagnosticTarget {
    const target = opDiagnosticTarget(op);
    return switch (op.render.kind) {
        .vector_math, .vector_asset, .raster_asset => targetWithContentSpan(target, 0, op.content.len),
        else => target,
    };
}

fn renderOpLabel(op: *const RenderOp) []const u8 {
    return switch (op.render.kind) {
        .text => "text object",
        .code => "code block",
        .chrome_only => "object chrome",
        .vector_math => "math expression",
        .vector_asset => "vector asset",
        .raster_asset => "raster asset",
    };
}

fn preloadTaskTarget(task: PreloadTask) RenderDiagnosticTarget {
    return switch (task) {
        .math => |math| math.target,
        .icon => |icon| icon.target,
        .vector_pdf => |asset| asset.target,
        .raster => |raster| raster.target,
    };
}

fn preloadTaskLabel(task: PreloadTask) []const u8 {
    return switch (task) {
        .math => "math expression",
        .icon => "icon",
        .vector_pdf => "PDF asset",
        .raster => "raster asset",
    };
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
        .highlight_languages = ctx.highlight_languages,
        .progress = progress,
    };

    var threads = try ctx.allocator.alloc(std.Thread, worker_count);
    defer ctx.allocator.free(threads);

    var started: usize = 0;
    var joined = false;
    errdefer {
        if (!joined) {
            work.failed.store(true, .seq_cst);
            for (threads[0..started]) |thread| thread.join();
        }
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
    joined = true;

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
                .highlight_languages = work.highlight_languages,
            };
            renderOnePage(&ctx, &work.plan.pages[page_index]) catch {
                work.failed.store(true, .seq_cst);
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
                .highlight_languages = &.{},
            };
            preloadOne(&ctx, work.plan.artifact_tasks[artifact_index]) catch {
                work.failed.store(true, .seq_cst);
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
        .highlight_languages = parent_ctx.highlight_languages,
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
    var links = std.ArrayList(LinkAnnotation).empty;
    defer links.deinit(ctx.allocator);
    defer deinitLinkAnnotations(ctx.allocator, links.items);
    var destinations = std.ArrayList(DestinationAnnotation).empty;
    defer destinations.deinit(ctx.allocator);
    defer deinitDestinationAnnotations(ctx.allocator, destinations.items);
    ctx.link_annotations = &links;
    ctx.destinations = &destinations;
    defer {
        ctx.link_annotations = null;
        ctx.destinations = null;
    }

    if (c.ss_pdf_begin_recording(ctx.pdf) != 0) return NativePdfError.CairoCreateFailed;
    for (page.ops) |*op| {
        if (op.render.kind == .chrome_only) try drawRenderOp(ctx, op);
    }
    for (page.ops) |*op| {
        if (op.render.kind != .chrome_only) try drawRenderOp(ctx, op);
    }
    var fit: c.SsPdfRecordingFit = undefined;
    if (c.ss_pdf_recording_fit(ctx.pdf, PageLayout.width, PageLayout.height, 1.0, &fit) != 0) return NativePdfError.CairoFailed;
    if (c.ss_pdf_paint_recording_with_fit(ctx.pdf, &fit) != 0) return NativePdfError.CairoFailed;
    try emitPageAnnotations(ctx, fit, destinations.items, links.items);
}

fn deinitLinkAnnotations(allocator: Allocator, links: []const LinkAnnotation) void {
    for (links) |link| link.deinit(allocator);
}

fn deinitDestinationAnnotations(allocator: Allocator, destinations: []const DestinationAnnotation) void {
    for (destinations) |destination| destination.deinit(allocator);
}

fn emitPageAnnotations(ctx: *DrawContext, fit: c.SsPdfRecordingFit, destinations: []const DestinationAnnotation, links: []const LinkAnnotation) !void {
    for (destinations) |destination| {
        const transformed = transformPoint(fit, destination.x, destination.y);
        try emitDestination(ctx, destination.name, transformed.x, transformed.y);
    }
    for (links) |link| {
        const rect = transformRect(fit, link.x, link.y, link.width, link.height);
        try emitLinkAnnotation(ctx, link.kind, link.target, rect.x, rect.y, rect.width, rect.height);
    }
}

const TransformedPoint = struct {
    x: f64,
    y: f64,
};

const TransformedRect = struct {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
};

fn transformPoint(fit: c.SsPdfRecordingFit, x: f32, y: f32) TransformedPoint {
    return .{
        .x = fit.tx + @as(f64, @floatCast(x)) * fit.scale,
        .y = fit.ty + @as(f64, @floatCast(y)) * fit.scale,
    };
}

fn transformRect(fit: c.SsPdfRecordingFit, x: f32, y: f32, width: f32, height: f32) TransformedRect {
    return .{
        .x = fit.tx + @as(f64, @floatCast(x)) * fit.scale,
        .y = fit.ty + @as(f64, @floatCast(y)) * fit.scale,
        .width = @as(f64, @floatCast(width)) * fit.scale,
        .height = @as(f64, @floatCast(height)) * fit.scale,
    };
}

fn drawRenderOp(ctx: *DrawContext, op: *const RenderOp) !void {
    const visual_frame = try measuredRenderOpVisualFrame(ctx, op);
    try addDestination(ctx, op.link_id, visual_frame);
    drawObjectChrome(ctx.pdf, visual_frame, op.render);
    const content_frame = contentFrameForRender(op.frame, op.render);
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

fn measuredRenderOpVisualFrame(ctx: *DrawContext, op: *const RenderOp) !Frame {
    switch (op.render.kind) {
        .text => if (op.render.text) |text| {
            const measured = try measureRenderedOpContent(ctx, op, text);
            return expandFrameToMeasuredInk(op.frame, op.render, measured);
        },
        .code => if (op.render.text) |text| {
            var code_text = text;
            code_text.font = text.code_font;
            const measured = try measureRenderedOpContent(ctx, op, code_text);
            return expandFrameToMeasuredInk(op.frame, op.render, measured);
        },
        .vector_math, .vector_asset, .raster_asset => {
            const measured = try measureRenderedOpContent(ctx, op, null);
            return expandFrameToMeasuredInk(op.frame, op.render, measured);
        },
        else => {},
    }
    return op.frame;
}

fn expandFrameToMeasuredInk(frame: Frame, render: ResolvedRender, maybe_ink: ?Frame) Frame {
    const current_content = contentFrameForRender(frame, render);
    var content_left = current_content.x;
    var content_right = current_content.x + current_content.width;
    var content_bottom = current_content.y;
    var content_top = current_content.y + current_content.height;
    if (maybe_ink) |ink| {
        content_left = @min(content_left, ink.x);
        content_right = @max(content_right, ink.x + ink.width);
        content_bottom = @min(content_bottom, ink.y);
        content_top = @max(content_top, ink.y + ink.height);
    }
    return .{
        .x = content_left - render.chrome.pad_x,
        .y = content_bottom - render.chrome.pad_y,
        .width = @max(content_right - content_left, 1) + render.chrome.pad_x * 2,
        .height = @max(content_top - content_bottom, 1) + render.chrome.pad_y * 2,
        .x_set = frame.x_set,
        .y_set = frame.y_set,
    };
}

const MeasurementScope = struct {
    ctx: *DrawContext,
    previous_links: ?*std.ArrayList(LinkAnnotation),
    previous_destinations: ?*std.ArrayList(DestinationAnnotation),
    links: std.ArrayList(LinkAnnotation) = .empty,
    destinations: std.ArrayList(DestinationAnnotation) = .empty,
    active: bool = false,

    fn init(ctx: *DrawContext) MeasurementScope {
        return .{
            .ctx = ctx,
            .previous_links = ctx.link_annotations,
            .previous_destinations = ctx.destinations,
        };
    }

    fn begin(self: *MeasurementScope) !void {
        if (c.ss_pdf_begin_measurement(self.ctx.pdf) != 0) return NativePdfError.CairoCreateFailed;
        self.active = true;
        self.ctx.link_annotations = &self.links;
        self.ctx.destinations = &self.destinations;
    }

    fn inkFrame(self: *MeasurementScope) !?Frame {
        var extents: c.SsPdfRecordingExtents = undefined;
        if (c.ss_pdf_measurement_ink_extents(self.ctx.pdf, &extents) != 0) return NativePdfError.CairoFailed;
        return recordingExtentsToFrame(extents);
    }

    fn deinit(self: *MeasurementScope) void {
        self.ctx.link_annotations = self.previous_links;
        self.ctx.destinations = self.previous_destinations;
        deinitLinkAnnotations(self.ctx.allocator, self.links.items);
        self.links.deinit(self.ctx.allocator);
        deinitDestinationAnnotations(self.ctx.allocator, self.destinations.items);
        self.destinations.deinit(self.ctx.allocator);
        if (self.active) {
            _ = c.ss_pdf_end_measurement(self.ctx.pdf);
            self.active = false;
        }
    }
};

fn recordingExtentsToFrame(extents: c.SsPdfRecordingExtents) ?Frame {
    if (extents.width <= 0 or extents.height <= 0) return null;
    const x: f32 = @floatCast(extents.x);
    const y_top: f32 = @floatCast(extents.y);
    const width: f32 = @floatCast(extents.width);
    const height: f32 = @floatCast(extents.height);
    return .{
        .x = x,
        .y = PageLayout.height - y_top - height,
        .width = width,
        .height = height,
    };
}

fn measureRenderedOpContent(ctx: *DrawContext, op: *const RenderOp, maybe_text: ?TextPaint) !?Frame {
    var measurement = MeasurementScope.init(ctx);
    try measurement.begin();
    defer measurement.deinit();

    const content_frame = contentFrameForRender(op.frame, op.render);
    switch (op.render.kind) {
        .text => if (maybe_text) |text| try drawTextOp(ctx, op, content_frame, text),
        .code => if (maybe_text) |text| try drawCodeBlock(ctx, content_frame, op.content, text, op.render.code),
        .vector_math => try drawVectorMathOp(ctx, op, content_frame, op.render.math),
        .vector_asset => try drawVectorAsset(ctx, content_frame, op.content),
        .raster_asset => try drawRasterAsset(ctx, content_frame, op.content),
        else => return null,
    }
    return try measurement.inkFrame();
}

fn cloneTexPreambleEntries(allocator: Allocator, preamble: []const TexPreambleEntry) ![]const TexPreambleEntry {
    const cloned = try allocator.alloc(TexPreambleEntry, preamble.len);
    @memcpy(cloned, preamble);
    return cloned;
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
        .icon => |icon| allocator.free(icon.source),
        .vector_pdf => |asset| allocator.free(asset.source),
        .raster => |raster| allocator.free(raster.source),
    }
}

fn preloadTaskKey(ctx: *DrawContext, task: PreloadTask) ![]u8 {
    return switch (task) {
        .math => |math| cachedMathPath(ctx, math.source, math.preamble, math.kind, "svg"),
        .icon => |icon| cachedIconPath(ctx, icon.source, "svg"),
        .vector_pdf => |asset| cachedAssetPath(ctx, "pdf", asset.source, "svg"),
        .raster => |raster| cachedSizedAssetPath(ctx, "raster-fit", raster.source, raster.target_width, raster.target_height, "png"),
    };
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
        .icon => |icon| {
            const out = try cachedIconPath(ctx, icon.source, "svg");
            defer ctx.allocator.free(out);
            return fileExists(out);
        },
        .vector_pdf => |asset| {
            const out = try cachedAssetPath(ctx, "pdf", asset.source, "svg");
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
        .icon => |icon| {
            const out = try cachedIconPath(ctx, icon.source, "svg");
            defer ctx.allocator.free(out);
            return (try cachedSvgAsset(ctx, out)) != null;
        },
        .vector_pdf => |asset| {
            const out = try cachedAssetPath(ctx, "pdf", asset.source, "svg");
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

fn preloadOne(ctx: *DrawContext, task: PreloadTask) !void {
    switch (task) {
        .math => |math| {
            const svg = try renderMathToSvg(ctx, math.source, math.preamble, math.kind);
            ctx.allocator.free(svg.path);
        },
        .icon => |icon| {
            const svg = try renderIconToSvg(ctx, icon.source);
            ctx.allocator.free(svg.path);
        },
        .vector_pdf => |asset| {
            const svg_path = try pdfToSvg(ctx, asset.source);
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

fn addDestination(ctx: *DrawContext, maybe_link_id: ?[]const u8, frame: Frame) !void {
    const link_id = maybe_link_id orelse return;
    if (link_id.len == 0) return;
    const x = frame.x;
    const y = topOf(frame);
    if (ctx.destinations) |destinations| {
        const owned_name = try ctx.allocator.dupe(u8, link_id);
        errdefer ctx.allocator.free(owned_name);
        try destinations.append(ctx.allocator, .{
            .name = owned_name,
            .x = x,
            .y = y,
        });
        return;
    }
    try emitDestination(ctx, link_id, @floatCast(x), @floatCast(y));
}

fn emitDestination(ctx: *DrawContext, name: []const u8, x: f64, y: f64) !void {
    const name_z = try ctx.allocator.dupeZ(u8, name);
    defer ctx.allocator.free(name_z);
    if (c.ss_pdf_add_destination(ctx.pdf, name_z.ptr, x, y) != 0) return NativePdfError.CairoFailed;
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

fn drawTextOp(ctx: *DrawContext, op: *const RenderOp, frame: Frame, text: TextPaint) !void {
    switch (op.parse_mode) {
        .none => return,
        .block => {
            var doc = try core.markdown.parseMarkdownContent(ctx.allocator, op.content);
            defer doc.deinit();
            _ = try drawMarkdownBlocks(ctx, frame, doc.blocks.items, text, 0, op.tex_preamble);
        },
        .@"inline" => {
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
    const source = try markdownCodeBlockContent(ctx.allocator, block);
    defer ctx.allocator.free(source);
    const code_paint = markdownCodeBlockPaint(block, text);
    const initial_content_width = @max(width - text.markdown_code_pad_x * 2, 1);
    const measured = try measureMarkdownCodeBlockContent(ctx, source, initial_content_width, text, code_paint);
    const placement = markdownCodeBlockPlacement(x, baseline_bl, width, measured, text);
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

    try drawMarkdownCodeBlockContent(ctx, placement.content_x, placement.first_baseline_bl, placement.content_width, source, text, code_paint);
    return placement.next_baseline_bl;
}

fn markdownCodeBlockPaint(block: *const Block, text: TextPaint) CodePaint {
    return .{
        .language = block.language,
        .plain = text.markdown_code_plain_color orelse text.color,
        .keyword = text.markdown_code_keyword_color orelse text.link_color,
        .function = text.markdown_code_function_color orelse text.markdown_code_keyword_color orelse text.link_color,
        .type = text.markdown_code_type_color orelse text.markdown_code_keyword_color orelse text.link_color,
        .constant = text.markdown_code_constant_color orelse text.markdown_code_keyword_color orelse text.link_color,
        .number = text.markdown_code_number_color orelse text.markdown_code_constant_color orelse text.link_color,
        .variable = text.markdown_code_variable_color orelse text.markdown_code_plain_color orelse text.color,
        .operator = text.markdown_code_operator_color orelse text.markdown_code_keyword_color orelse text.link_color,
        .comment = text.markdown_code_comment_color orelse Color{ .r = 0.38, .g = 0.42, .b = 0.48 },
        .string = text.markdown_code_string_color orelse text.markdown_bold_color orelse text.link_color,
    };
}

fn drawMarkdownCodeBlockContent(ctx: *DrawContext, x: f32, first_baseline_bl: f32, width: f32, source: []const u8, text: TextPaint, code_paint: CodePaint) !void {
    if (code_paint.language) |language| {
        if (highlightLanguageFor(ctx, language) != null) {
            try drawHighlightedCodeLines(ctx, x, first_baseline_bl, width, source, text.code_font, text.markdown_code_font_size, text.markdown_code_line_height, code_paint, text.emoji_spacing, true);
            return;
        }
    }

    var cursor_bl = first_baseline_bl;
    var physical = std.mem.splitScalar(u8, source, '\n');
    while (physical.next()) |segment| {
        if (segment.len == 0 and physical.index == null and source.len > 0 and source[source.len - 1] == '\n') break;
        _ = try drawCodeTextAtTop(ctx, x, baselineTop(cursor_bl, text.markdown_code_font_size), width, text.markdown_code_line_height, segment, text.code_font, text.markdown_code_font_size, code_paint.plain, text.emoji_spacing);
        cursor_bl -= text.markdown_code_line_height;
    }
}

const MarkdownCodeBlockPlacement = struct {
    frame: Frame,
    content_x: f32,
    content_width: f32,
    first_baseline_bl: f32,
    next_baseline_bl: f32,
};

const MarkdownCodeBlockMeasure = struct {
    left: f32,
    right: f32,
    top_over_baseline: f32,
    bottom_under_baseline: f32,
};

fn measureMarkdownCodeBlockContent(ctx: *DrawContext, source: []const u8, width: f32, text: TextPaint, code_paint: CodePaint) !MarkdownCodeBlockMeasure {
    const baseline_bl = PageLayout.height * 0.5;
    var measurement = MeasurementScope.init(ctx);
    try measurement.begin();
    defer measurement.deinit();

    try drawMarkdownCodeBlockContent(ctx, 0, baseline_bl, width, source, text, code_paint);
    if (try measurement.inkFrame()) |ink| {
        return .{
            .left = ink.x,
            .right = ink.x + ink.width,
            .top_over_baseline = @max(@as(f32, 0), ink.y + ink.height - baseline_bl),
            .bottom_under_baseline = @max(@as(f32, 0), baseline_bl - ink.y),
        };
    }

    const line_count: f32 = @floatFromInt(@max(physicalCodeLineCount(source), 1));
    const default_height = @max(line_count * text.markdown_code_line_height, text.markdown_code_font_size);
    return .{
        .left = 0,
        .right = 1,
        .top_over_baseline = text.markdown_code_font_size,
        .bottom_under_baseline = @max(default_height - text.markdown_code_font_size, 0),
    };
}

fn physicalCodeLineCount(source: []const u8) usize {
    if (source.len == 0) return 1;
    var count: usize = 1;
    for (source) |ch| {
        if (ch == '\n') count += 1;
    }
    if (source[source.len - 1] == '\n' and count > 1) count -= 1;
    return count;
}

fn markdownCodeBlockPlacement(x: f32, baseline_bl: f32, width: f32, measured: MarkdownCodeBlockMeasure, text: TextPaint) MarkdownCodeBlockPlacement {
    const box_top = baseline_bl + text.font_size;
    const first_baseline_bl = box_top - text.markdown_code_pad_y - measured.top_over_baseline;
    const content_left = x + text.markdown_code_pad_x + measured.left;
    const content_right = x + text.markdown_code_pad_x + measured.right;
    const frame_x = @min(x, content_left - text.markdown_code_pad_x);
    const frame_right = @max(x + width, content_right + text.markdown_code_pad_x);
    const box_height = text.markdown_code_pad_y * 2 + measured.top_over_baseline + measured.bottom_under_baseline;
    const box_bottom = box_top - box_height;
    return .{
        .frame = .{ .x = frame_x, .y = box_bottom, .width = @max(frame_right - frame_x, 1), .height = @max(box_height, 1) },
        .content_x = x + text.markdown_code_pad_x,
        .content_width = @max(width - text.markdown_code_pad_x * 2, 1),
        .first_baseline_bl = first_baseline_bl,
        .next_baseline_bl = box_bottom - text.font_size,
    };
}

fn markdownCodeBlockContent(allocator: Allocator, block: *const Block) ![]u8 {
    const paragraph = block.paragraph orelse return allocator.dupe(u8, "");
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    for (paragraph.lines.items, 0..) |line, line_index| {
        for (line.runs.items) |run| try out.appendSlice(allocator, run.text);
        if (line_index + 1 < paragraph.lines.items.len) try out.append(allocator, '\n');
    }
    return out.toOwnedSlice(allocator);
}

fn drawTable(ctx: *DrawContext, x: f32, baseline_bl: f32, width: f32, block: *const Block, text: TextPaint, preamble: []const TexPreambleEntry) !f32 {
    const table = block.table orelse return baseline_bl;
    const columns = @max(table.columns, 1);
    const column_width = width / @as(f32, @floatFromInt(columns));
    var cursor_top_bl = baseline_bl + text.font_size - text.markdown_table_line_width * 0.5;
    var body_row_index: usize = 0;

    for (table.rows.items) |row| {
        const content_width = @max(column_width - text.markdown_table_cell_pad_x * 2, 1);
        var row_top_overhang: f32 = 0;
        var row_bottom_depth: f32 = text.line_height;
        for (row.cells.items) |cell| {
            var cell_text = text;
            cell_text.font = if (row.header) text.bold_font else text.font;
            const measured = try measureInlineLinesInkBlock(ctx, cell.lines.items, cell_text, content_width, preamble);
            row_top_overhang = @max(row_top_overhang, measured.top_overhang);
            row_bottom_depth = @max(row_bottom_depth, measured.bottom_depth);
        }
        const row_height = row_top_overhang + row_bottom_depth + text.markdown_table_cell_pad_y * 2;
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
                var line_bl = cursor_top_bl - text.markdown_table_cell_pad_y - row_top_overhang - text.font_size;
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

const InlineInkBlock = struct {
    top_overhang: f32,
    bottom_depth: f32,
};

fn measureInlineLinesInkBlock(ctx: *DrawContext, lines: []const Line, text: TextPaint, width: f32, preamble: []const TexPreambleEntry) !InlineInkBlock {
    const baseline_bl = PageLayout.height * 0.5;
    const content_top_bl = baseline_bl + text.font_size;
    var measurement = MeasurementScope.init(ctx);
    try measurement.begin();
    defer measurement.deinit();

    const next_bl = try drawInlineLines(ctx, 0, baseline_bl, width, lines, text, true, preamble);
    var top_overhang: f32 = 0;
    var bottom_depth = @max(baseline_bl - next_bl, text.line_height);
    if (try measurement.inkFrame()) |ink| {
        top_overhang = @max(@as(f32, 0), ink.y + ink.height - content_top_bl);
        bottom_depth = @max(bottom_depth, content_top_bl - ink.y);
    }
    return .{
        .top_overhang = top_overhang,
        .bottom_depth = @max(bottom_depth, text.line_height),
    };
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
    try drawSvgFrame(ctx, draw_frame, svg.path);
    return block_bottom - text.font_size;
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
    var tokenizer = text_tokenize.Tokenizer.init(value);
    while (tokenizer.next()) |token| {
        const is_emoji = text_tokenize.isEmojiToken(token);
        const measured_width = if (is_emoji)
            try measureTextVisualWidth(ctx, token, font, font_size)
        else
            try measureText(ctx, token, font, font_size);
        const width = measured_width;
        try atoms.append(ctx.allocator, .{
            .kind = .text,
            .text = token,
            .font = font,
            .color = color,
            .width = width,
            .is_space = text_tokenize.isWhitespace(token),
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
                    try drawAtomRawText(ctx, cursor_x, y_top, @max(atom.width + paint.font_size, 1), paint.line_height, atom, paint, false);
                }
                if (atom.strikethrough) {
                    drawStrikethrough(ctx, cursor_x, y_top, atom, paint);
                }
                cursor.advance(measured_atom.advance);
            },
            .math => {
                const path = atom.svg_path orelse continue;
                const frame = Frame{ .x = cursor_x, .y = cursor_bl - atom.height * 0.25, .width = atom.width, .height = atom.height };
                try drawSvgFrame(ctx, frame, path);
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

fn highlightLanguageFor(ctx: *DrawContext, language: []const u8) ?*const utils.highlight.Language {
    for (ctx.highlight_languages) |*configured| {
        if (std.ascii.eqlIgnoreCase(configured.name, language)) return configured;
    }
    return null;
}

fn drawTreeSitterCodeBlock(ctx: *DrawContext, frame: Frame, content: []const u8, text: TextPaint, code: CodePaint, font_size: f32, line_height: f32) !void {
    const first_baseline_bl = baselineBlForBox(frame, font_size);
    try drawHighlightedCodeLines(ctx, frame.x, first_baseline_bl, frame.width, content, text.code_font, font_size, line_height, code, text.emoji_spacing, false);
}

fn drawHighlightedCodeLines(
    ctx: *DrawContext,
    x: f32,
    first_baseline_bl: f32,
    width: f32,
    content: []const u8,
    font: FontFace,
    font_size: f32,
    line_height: f32,
    code: CodePaint,
    emoji_spacing: f32,
    trim_trailing_empty_line: bool,
) !void {
    const language = code.language orelse {
        var cursor_bl = first_baseline_bl;
        var plain_lines = std.mem.splitScalar(u8, content, '\n');
        while (plain_lines.next()) |line| {
            if (trim_trailing_empty_line and line.len == 0 and plain_lines.index == null and content.len > 0 and content[content.len - 1] == '\n') break;
            _ = try drawCodeTextAtTop(ctx, x, baselineTop(cursor_bl, font_size), width, line_height, line, font, font_size, code.plain, emoji_spacing);
            cursor_bl -= line_height;
        }
        return;
    };

    var spans = try collectTreeSitterHighlightSpans(ctx, language, content, code);
    defer spans.deinit(ctx.allocator);

    var cursor_bl = first_baseline_bl;
    var offset: usize = 0;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (trim_trailing_empty_line and line.len == 0 and lines.index == null and content.len > 0 and content[content.len - 1] == '\n') break;
        const line_start = offset;
        const line_end = line_start + line.len;
        try drawHighlightedCodeLine(ctx, x, baselineTop(cursor_bl, font_size), width, content, line_start, line_end, spans.items, font, font_size, line_height, code.plain, emoji_spacing);
        cursor_bl -= line_height;
        offset = @min(line_end + 1, content.len);
    }
}

fn drawHighlightedCodeLine(
    ctx: *DrawContext,
    x: f32,
    y_top: f32,
    width: f32,
    content: []const u8,
    line_start: usize,
    line_end: usize,
    spans: []const HighlightSpan,
    font: FontFace,
    font_size: f32,
    line_height: f32,
    plain_color: Color,
    emoji_spacing: f32,
) !void {
    var cursor_x = x;
    var pos = line_start;
    _ = width;
    while (pos < line_end) {
        var next = nextHighlightBoundary(spans, pos, line_end);
        if (next <= pos) next = @min(pos + 1, line_end);
        const color = highlightColorAt(spans, pos, next) orelse plain_color;
        try drawCodeSegment(ctx, &cursor_x, y_top, content[pos..next], font, font_size, line_height, color, emoji_spacing);
        pos = next;
    }
}

fn collectTreeSitterHighlightSpans(ctx: *DrawContext, language_name: []const u8, content: []const u8, code: CodePaint) !std.ArrayList(HighlightSpan) {
    var spans = std.ArrayList(HighlightSpan).empty;
    errdefer spans.deinit(ctx.allocator);
    const configured = highlightLanguageFor(ctx, language_name) orelse return spans;
    if (content.len > std.math.maxInt(u32)) return spans;

    var runtime = try loadTreeSitterRuntime();
    defer runtime.deinit();

    var handle = try loadTreeSitterLanguage(configured);
    defer handle.deinit();

    var query_source = try loadHighlightQuerySource(ctx, configured);
    defer query_source.deinit(ctx.allocator);

    const parser = runtime.parser_new() orelse return error.TreeSitterParserCreateFailed;
    defer runtime.parser_delete(parser);
    if (!runtime.parser_set_language(parser, handle.language)) return error.TreeSitterLanguageRejected;
    const tree = runtime.parser_parse_string(parser, null, @ptrCast(content.ptr), @intCast(content.len)) orelse return error.TreeSitterParseFailed;
    defer runtime.tree_delete(tree);

    var query_error_offset: u32 = 0;
    var query_error_type: TSQueryError = .none;
    const query = runtime.query_new(handle.language, @ptrCast(query_source.text.ptr), @intCast(query_source.text.len), &query_error_offset, &query_error_type) orelse return error.TreeSitterQueryFailed;
    defer runtime.query_delete(query);

    const cursor = runtime.query_cursor_new() orelse return error.TreeSitterQueryCursorCreateFailed;
    defer runtime.query_cursor_delete(cursor);
    runtime.query_cursor_exec(cursor, query, runtime.tree_root_node(tree));

    var match = std.mem.zeroes(TSQueryMatch);
    var capture_index: u32 = 0;
    while (runtime.query_cursor_next_capture(cursor, &match, &capture_index)) {
        if (capture_index >= match.capture_count) continue;
        const capture = match.captures[capture_index];
        var capture_name_len: u32 = 0;
        const capture_name_ptr = runtime.query_capture_name_for_id(query, capture.index, &capture_name_len) orelse continue;
        const capture_name = @as([*]const u8, @ptrCast(capture_name_ptr))[0..capture_name_len];
        const color = colorForCapture(code, capture_name) orelse continue;
        const start: usize = runtime.node_start_byte(capture.node);
        const end: usize = runtime.node_end_byte(capture.node);
        if (start >= end or end > content.len) continue;
        try spans.append(ctx.allocator, .{ .start = start, .end = end, .color = color });
    }

    std.mem.sort(HighlightSpan, spans.items, {}, highlightSpanLessThan);
    return spans;
}

pub fn treeSitterHealthReport(
    allocator: Allocator,
    io: std.Io,
    languages: []const utils.highlight.Language,
) !TreeSitterHealthReport {
    var items = std.ArrayList(TreeSitterHealthItem).empty;
    errdefer {
        for (items.items) |*item| item.deinit(allocator);
        items.deinit(allocator);
    }

    var failures: usize = 0;
    var warnings: usize = 0;
    for (languages) |language| {
        var item = try checkTreeSitterLanguageHealth(allocator, io, language);
        const status = item.status;
        items.append(allocator, item) catch |err| {
            item.deinit(allocator);
            return err;
        };
        switch (status) {
            .ok => {},
            .warning => warnings += 1,
            .fail => failures += 1,
        }
    }

    return .{
        .configured_languages = languages.len,
        .failures = failures,
        .warnings = warnings,
        .items = try items.toOwnedSlice(allocator),
    };
}

fn checkTreeSitterLanguageHealth(
    allocator: Allocator,
    io: std.Io,
    language: utils.highlight.Language,
) !TreeSitterHealthItem {
    var runtime = loadTreeSitterRuntime() catch |err| {
        return makeTreeSitterHealthItem(allocator, language, .fail, 0, 0, "runtime unavailable: {s}", .{@errorName(err)});
    };
    defer runtime.deinit();

    var handle = loadTreeSitterLanguage(&language) catch |err| {
        return makeTreeSitterHealthItem(allocator, language, .fail, 0, 0, "language load failed: {s}", .{@errorName(err)});
    };
    defer handle.deinit();

    var query_source = loadHighlightQuerySourceForHealth(allocator, io, &language) catch |err| {
        return makeTreeSitterHealthItem(allocator, language, .fail, 0, 0, "query load failed: {s}", .{@errorName(err)});
    };
    defer query_source.deinit(allocator);
    if (query_source.text.len == 0) {
        return makeTreeSitterHealthItem(allocator, language, .fail, 0, 0, "query source is empty", .{});
    }

    const parser = runtime.parser_new() orelse {
        return makeTreeSitterHealthItem(allocator, language, .fail, 0, 0, "parser creation failed", .{});
    };
    defer runtime.parser_delete(parser);
    if (!runtime.parser_set_language(parser, handle.language)) {
        return makeTreeSitterLanguageRejectedHealthItem(allocator, language);
    }

    const sample = treeSitterHealthSample(language.parser);
    const tree = runtime.parser_parse_string(parser, null, @ptrCast(sample.ptr), @intCast(sample.len)) orelse {
        return makeTreeSitterHealthItem(allocator, language, .fail, 0, 0, "sample parse failed", .{});
    };
    defer runtime.tree_delete(tree);

    var query_error_offset: u32 = 0;
    var query_error_type: TSQueryError = .none;
    const query = runtime.query_new(handle.language, @ptrCast(query_source.text.ptr), @intCast(query_source.text.len), &query_error_offset, &query_error_type) orelse {
        return makeTreeSitterHealthItem(
            allocator,
            language,
            .fail,
            0,
            0,
            "query compile failed at byte {d}: {s}",
            .{ query_error_offset, @tagName(query_error_type) },
        );
    };
    defer runtime.query_delete(query);

    const cursor = runtime.query_cursor_new() orelse {
        return makeTreeSitterHealthItem(allocator, language, .fail, 0, 0, "query cursor creation failed", .{});
    };
    defer runtime.query_cursor_delete(cursor);
    runtime.query_cursor_exec(cursor, query, runtime.tree_root_node(tree));

    var capture_count: usize = 0;
    var mapped_capture_count: usize = 0;
    var match = std.mem.zeroes(TSQueryMatch);
    var capture_index: u32 = 0;
    while (runtime.query_cursor_next_capture(cursor, &match, &capture_index)) {
        if (capture_index >= match.capture_count) continue;
        const capture = match.captures[capture_index];
        var capture_name_len: u32 = 0;
        const capture_name_ptr = runtime.query_capture_name_for_id(query, capture.index, &capture_name_len) orelse continue;
        const capture_name = @as([*]const u8, @ptrCast(capture_name_ptr))[0..capture_name_len];
        capture_count += 1;
        if (utils.highlight.roleForCapture(capture_name) != null) mapped_capture_count += 1;
    }

    if (capture_count == 0) {
        return makeTreeSitterHealthItem(allocator, language, .warning, capture_count, mapped_capture_count, "query compiled but sample produced no captures", .{});
    }
    if (mapped_capture_count == 0) {
        return makeTreeSitterHealthItem(allocator, language, .warning, capture_count, mapped_capture_count, "query captures do not map to ss highlight roles", .{});
    }
    return makeTreeSitterHealthItem(
        allocator,
        language,
        .ok,
        capture_count,
        mapped_capture_count,
        "parser/query ok; captures={d}, mapped={d}",
        .{ capture_count, mapped_capture_count },
    );
}

fn makeTreeSitterLanguageRejectedHealthItem(
    allocator: Allocator,
    language: utils.highlight.Language,
) !TreeSitterHealthItem {
    if (builtinTreeSitterLanguage(language.parser) != null) {
        return makeTreeSitterHealthItem(
            allocator,
            language,
            .fail,
            0,
            0,
            "parser rejected language; tree-sitter runtime accepts ABI range {d}..{d}",
            .{ tree_sitter_min_compatible_language_version, tree_sitter_language_version },
        );
    }
    return makeTreeSitterHealthItem(
        allocator,
        language,
        .fail,
        0,
        0,
        "parser rejected language",
        .{},
    );
}

fn makeTreeSitterHealthItem(
    allocator: Allocator,
    language: utils.highlight.Language,
    status: TreeSitterHealthStatus,
    capture_count: usize,
    mapped_capture_count: usize,
    comptime fmt: []const u8,
    args: anytype,
) !TreeSitterHealthItem {
    const name = try allocator.dupe(u8, language.name);
    errdefer allocator.free(name);
    const parser = try allocator.dupe(u8, language.parser);
    errdefer allocator.free(parser);
    const query = try allocator.dupe(u8, language.query);
    errdefer allocator.free(query);
    const detail = try std.fmt.allocPrint(allocator, fmt, args);
    return .{
        .name = name,
        .parser = parser,
        .query = query,
        .status = status,
        .detail = detail,
        .capture_count = capture_count,
        .mapped_capture_count = mapped_capture_count,
    };
}

fn treeSitterHealthSample(parser: []const u8) []const u8 {
    if (std.ascii.eqlIgnoreCase(parser, "ss")) return "import std:themes/default as *\n\npage sample\ntext!(\"hello\")\nend\n";
    if (std.ascii.eqlIgnoreCase(parser, "bash") or std.ascii.eqlIgnoreCase(parser, "sh") or std.ascii.eqlIgnoreCase(parser, "shell")) return "echo \"$HOME\"\n";
    if (std.ascii.eqlIgnoreCase(parser, "c")) return "#include <stdio.h>\nint main(void) { return 0; }\n";
    if (std.ascii.eqlIgnoreCase(parser, "cpp") or std.ascii.eqlIgnoreCase(parser, "c++") or std.ascii.eqlIgnoreCase(parser, "cc")) return "class Sample { public: auto method() { return nullptr; } };\n";
    if (std.ascii.eqlIgnoreCase(parser, "css")) return "body { color: red; }\n";
    if (std.ascii.eqlIgnoreCase(parser, "go") or std.ascii.eqlIgnoreCase(parser, "golang")) return "package main\nfunc main() { println(\"hello\") }\n";
    if (std.ascii.eqlIgnoreCase(parser, "html")) return "<!doctype html><p class=\"sample\">hello</p>\n";
    if (std.ascii.eqlIgnoreCase(parser, "java")) return "class Main { public static void main(String[] args) { System.out.println(\"hello\"); } }\n";
    if (std.ascii.eqlIgnoreCase(parser, "javascript") or std.ascii.eqlIgnoreCase(parser, "js")) return "function main() { return 1; }\n";
    if (std.ascii.eqlIgnoreCase(parser, "json")) return "{\"name\": true, \"count\": 1}\n";
    if (std.ascii.eqlIgnoreCase(parser, "julia") or std.ascii.eqlIgnoreCase(parser, "jl")) return "function f(x)\n  x + 1\nend\n";
    if (std.ascii.eqlIgnoreCase(parser, "python") or std.ascii.eqlIgnoreCase(parser, "py")) return "def f(x):\n    return x + 1\n";
    if (std.ascii.eqlIgnoreCase(parser, "rust") or std.ascii.eqlIgnoreCase(parser, "rs")) return "fn main() { let value = 1; }\n";
    if (std.ascii.eqlIgnoreCase(parser, "toml")) return "name = \"ss\"\ncount = 1\n";
    if (std.ascii.eqlIgnoreCase(parser, "typescript") or std.ascii.eqlIgnoreCase(parser, "ts")) return "const value: number = 1;\n";
    if (std.ascii.eqlIgnoreCase(parser, "tsx")) return "const value = <div>{1}</div>;\n";
    if (std.ascii.eqlIgnoreCase(parser, "yaml") or std.ascii.eqlIgnoreCase(parser, "yml")) return "name: ss\nitems:\n  - one\n";
    if (std.ascii.eqlIgnoreCase(parser, "zig")) return "pub fn main() void { const value = 1; }\n";
    return "value\n";
}

const LoadedHighlightQuery = struct {
    text: []const u8,
    owned: bool = false,

    fn deinit(self: *LoadedHighlightQuery, allocator: Allocator) void {
        if (self.owned) allocator.free(self.text);
    }
};

fn loadHighlightQuerySource(ctx: *DrawContext, configured: *const utils.highlight.Language) !LoadedHighlightQuery {
    if (builtinHighlightQuery(configured.query)) |query| return .{ .text = query };
    return .{
        .text = try std.Io.Dir.cwd().readFileAlloc(ctx.io, configured.query, ctx.allocator, .limited(highlight_query_read_limit)),
        .owned = true,
    };
}

fn loadHighlightQuerySourceForHealth(allocator: Allocator, io: std.Io, configured: *const utils.highlight.Language) !LoadedHighlightQuery {
    if (builtinHighlightQuery(configured.query)) |query| return .{ .text = query };
    return .{
        .text = try std.Io.Dir.cwd().readFileAlloc(io, configured.query, allocator, .limited(highlight_query_read_limit)),
        .owned = true,
    };
}

fn builtinHighlightQuery(query: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, query, "builtin:ss")) return build_options.ss_highlight_query;
    if (std.mem.eql(u8, query, "builtin:bash")) return build_options.bash_highlight_query;
    if (std.mem.eql(u8, query, "builtin:c")) return build_options.c_highlight_query;
    if (std.mem.eql(u8, query, "builtin:cpp")) return build_options.cpp_highlight_query;
    if (std.mem.eql(u8, query, "builtin:css")) return build_options.css_highlight_query;
    if (std.mem.eql(u8, query, "builtin:go")) return build_options.go_highlight_query;
    if (std.mem.eql(u8, query, "builtin:html")) return build_options.html_highlight_query;
    if (std.mem.eql(u8, query, "builtin:java")) return build_options.java_highlight_query;
    if (std.mem.eql(u8, query, "builtin:javascript")) return build_options.javascript_highlight_query;
    if (std.mem.eql(u8, query, "builtin:json")) return build_options.json_highlight_query;
    if (std.mem.eql(u8, query, "builtin:julia")) return build_options.julia_highlight_query;
    if (std.mem.eql(u8, query, "builtin:python")) return build_options.python_highlight_query;
    if (std.mem.eql(u8, query, "builtin:rust")) return build_options.rust_highlight_query;
    if (std.mem.eql(u8, query, "builtin:toml")) return build_options.toml_highlight_query;
    if (std.mem.eql(u8, query, "builtin:typescript")) return build_options.typescript_highlight_query;
    if (std.mem.eql(u8, query, "builtin:yaml")) return build_options.yaml_highlight_query;
    if (std.mem.eql(u8, query, "builtin:zig")) return build_options.zig_highlight_query;
    return null;
}

fn loadTreeSitterLanguage(configured: *const utils.highlight.Language) !HighlightLanguageHandle {
    if (builtinTreeSitterLanguage(configured.parser)) |language| {
        return .{ .language = language };
    }
    return error.UnknownTreeSitterLanguage;
}

fn builtinTreeSitterLanguage(parser: []const u8) ?*const TSLanguage {
    if (std.ascii.eqlIgnoreCase(parser, "ss")) return tree_sitter_ss();
    if (std.ascii.eqlIgnoreCase(parser, "bash")) return tree_sitter_bash();
    if (std.ascii.eqlIgnoreCase(parser, "sh")) return tree_sitter_bash();
    if (std.ascii.eqlIgnoreCase(parser, "shell")) return tree_sitter_bash();
    if (std.ascii.eqlIgnoreCase(parser, "c")) return tree_sitter_c();
    if (std.ascii.eqlIgnoreCase(parser, "cpp")) return tree_sitter_cpp();
    if (std.ascii.eqlIgnoreCase(parser, "c++")) return tree_sitter_cpp();
    if (std.ascii.eqlIgnoreCase(parser, "cc")) return tree_sitter_cpp();
    if (std.ascii.eqlIgnoreCase(parser, "css")) return tree_sitter_css();
    if (std.ascii.eqlIgnoreCase(parser, "go")) return tree_sitter_go();
    if (std.ascii.eqlIgnoreCase(parser, "golang")) return tree_sitter_go();
    if (std.ascii.eqlIgnoreCase(parser, "html")) return tree_sitter_html();
    if (std.ascii.eqlIgnoreCase(parser, "java")) return tree_sitter_java();
    if (std.ascii.eqlIgnoreCase(parser, "javascript")) return tree_sitter_javascript();
    if (std.ascii.eqlIgnoreCase(parser, "js")) return tree_sitter_javascript();
    if (std.ascii.eqlIgnoreCase(parser, "json")) return tree_sitter_json();
    if (std.ascii.eqlIgnoreCase(parser, "julia")) return tree_sitter_julia();
    if (std.ascii.eqlIgnoreCase(parser, "jl")) return tree_sitter_julia();
    if (std.ascii.eqlIgnoreCase(parser, "python")) return tree_sitter_python();
    if (std.ascii.eqlIgnoreCase(parser, "py")) return tree_sitter_python();
    if (std.ascii.eqlIgnoreCase(parser, "rust")) return tree_sitter_rust();
    if (std.ascii.eqlIgnoreCase(parser, "rs")) return tree_sitter_rust();
    if (std.ascii.eqlIgnoreCase(parser, "toml")) return tree_sitter_toml();
    if (std.ascii.eqlIgnoreCase(parser, "typescript")) return tree_sitter_typescript();
    if (std.ascii.eqlIgnoreCase(parser, "ts")) return tree_sitter_typescript();
    if (std.ascii.eqlIgnoreCase(parser, "tsx")) return tree_sitter_tsx();
    if (std.ascii.eqlIgnoreCase(parser, "yaml")) return tree_sitter_yaml();
    if (std.ascii.eqlIgnoreCase(parser, "yml")) return tree_sitter_yaml();
    if (std.ascii.eqlIgnoreCase(parser, "zig")) return tree_sitter_zig();
    return null;
}

fn loadTreeSitterRuntime() !TreeSitterRuntime {
    return .{
        .parser_new = ts_parser_new,
        .parser_delete = ts_parser_delete,
        .parser_set_language = ts_parser_set_language,
        .parser_parse_string = ts_parser_parse_string,
        .tree_delete = ts_tree_delete,
        .tree_root_node = ts_tree_root_node,
        .query_new = ts_query_new,
        .query_delete = ts_query_delete,
        .query_capture_name_for_id = ts_query_capture_name_for_id,
        .query_cursor_new = ts_query_cursor_new,
        .query_cursor_delete = ts_query_cursor_delete,
        .query_cursor_exec = ts_query_cursor_exec,
        .query_cursor_next_capture = ts_query_cursor_next_capture,
        .node_start_byte = ts_node_start_byte,
        .node_end_byte = ts_node_end_byte,
    };
}

fn colorForCapture(code: CodePaint, capture_name: []const u8) ?Color {
    return switch (utils.highlight.roleForCapture(capture_name) orelse return null) {
        .plain => code.plain,
        .keyword => code.keyword,
        .function => code.function,
        .type => code.type,
        .constant => code.constant,
        .number => code.number,
        .variable => code.variable,
        .operator => code.operator,
        .comment => code.comment,
        .string => code.string,
    };
}

fn highlightSpanLessThan(_: void, lhs: HighlightSpan, rhs: HighlightSpan) bool {
    if (lhs.start != rhs.start) return lhs.start < rhs.start;
    const lhs_len = lhs.end - lhs.start;
    const rhs_len = rhs.end - rhs.start;
    return lhs_len < rhs_len;
}

fn nextHighlightBoundary(spans: []const HighlightSpan, pos: usize, line_end: usize) usize {
    var next = line_end;
    for (spans) |span| {
        if (span.end <= pos or span.start >= line_end) continue;
        if (span.start > pos) next = @min(next, span.start);
        if (span.start <= pos and span.end > pos) next = @min(next, span.end);
    }
    return next;
}

fn highlightColorAt(spans: []const HighlightSpan, start: usize, end: usize) ?Color {
    var best: ?HighlightSpan = null;
    for (spans) |span| {
        if (span.start > start or span.end < end) continue;
        if (best == null or highlightSpanMoreSpecific(span, best.?)) {
            best = span;
        }
    }
    return if (best) |span| span.color else null;
}

fn highlightSpanMoreSpecific(candidate: HighlightSpan, current: HighlightSpan) bool {
    const candidate_len = candidate.end - candidate.start;
    const current_len = current.end - current.start;
    if (candidate_len != current_len) return candidate_len < current_len;
    return candidate.start >= current.start;
}

fn drawCodeBlock(ctx: *DrawContext, frame: Frame, content: []const u8, text: TextPaint, code: ?CodePaint) !void {
    const code_paint = code orelse CodePaint{
        .language = null,
        .plain = text.color,
        .keyword = text.color,
        .function = text.color,
        .type = text.color,
        .constant = text.color,
        .number = text.color,
        .variable = text.color,
        .operator = text.color,
        .comment = text.color,
        .string = text.color,
    };
    if (code_paint.language) |language| {
        if (highlightLanguageFor(ctx, language) != null) {
            return drawTreeSitterCodeBlock(ctx, frame, content, text, code_paint, text.font_size, text.line_height);
        }
    }
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
    while (index < line.len) {
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
        index += text_tokenize.utf8ByteSequenceLength(byte);
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
    try drawSvgFrame(ctx, draw_frame, svg.path);
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

const direct_merge_page_limit: usize = 16;
const merge_chunk_size: usize = 16;

fn reusePreviousDocumentPdf(ctx: *DrawContext, plan: *const RenderPlan, progress: ?RenderProgress) !bool {
    const source = plan.previous_document_path orelse return false;
    if (progress) |p| p.assemblyCompleted(p.context, 0, 1);
    copyOrLinkCacheFile(ctx, source, plan.final_pdf_path) catch return false;
    if (!(try cachedPdfAvailable(ctx, plan.final_pdf_path))) return false;
    if (progress) |p| p.assemblyCompleted(p.context, 1, 1);
    return true;
}

fn storeRenderPlanDocumentPdf(ctx: *DrawContext, plan: *const RenderPlan) !void {
    const destination = try documentPdfPath(ctx.allocator, plan.building_dir);
    defer ctx.allocator.free(destination);
    try copyOrLinkCacheFile(ctx, plan.final_pdf_path, destination);
    if (!(try cachedPdfAvailable(ctx, destination))) return NativePdfError.InvalidPdfCache;
}

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

    try std.Io.Dir.cwd().createDirPath(ctx.io, plan.chunks_dir);

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
        const output = try qpdfPageHashCachePath(ctx.allocator, plan.chunks_dir, "chunk", plan.pages[start..end]);
        errdefer ctx.allocator.free(output);
        const cache_hit = (try cachedPdfAvailable(ctx, output)) or (try reusePreviousMergeChunk(ctx, plan, output));
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

fn reusePreviousMergeChunk(ctx: *DrawContext, plan: *const RenderPlan, destination: []const u8) !bool {
    const previous_chunks_dir = plan.previous_chunks_dir orelse return false;
    const source = try std.fs.path.join(ctx.allocator, &.{ previous_chunks_dir, std.fs.path.basename(destination) });
    defer ctx.allocator.free(source);
    if (!(try cachedPdfAvailable(ctx, source))) return false;
    copyOrLinkCacheFile(ctx, source, destination) catch return false;
    return cachedPdfAvailable(ctx, destination) catch false;
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
    var joined = false;
    errdefer {
        if (!joined) {
            work.failed.store(true, .seq_cst);
            for (threads[0..started]) |thread| thread.join();
        }
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
    joined = true;

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
            .highlight_languages = &.{},
        };
        const chunk = work.chunks[index];
        mergePdfInputsToCache(&ctx, chunk.inputs, chunk.single_page_inputs, chunk.output) catch {
            work.failed.store(true, .seq_cst);
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
    return drawRawTextWithMode(ctx, x, y_top, width, height, content, font, font_size, color, wrap, false);
}

fn drawColorRawText(
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
    return drawRawTextWithMode(ctx, x, y_top, width, height, content, font, font_size, color, wrap, true);
}

fn drawAtomRawText(ctx: *DrawContext, x: f32, y_top: f32, width: f32, height: f32, atom: Atom, paint: AtomPaint, wrap: bool) !void {
    if (atom.is_emoji) {
        try drawColorRawText(ctx, x, y_top, width, height, atom.text, atom.font, paint.font_size, atom.color, wrap);
    } else {
        try drawRawText(ctx, x, y_top, width, height, atom.text, atom.font, paint.font_size, atom.color, wrap);
    }
}

fn drawRawTextWithMode(
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
    preserve_color_glyphs: bool,
) !void {
    const family_z = try ctx.allocator.dupeZ(u8, font.family);
    defer ctx.allocator.free(family_z);
    const content_z = try ctx.allocator.dupeZ(u8, content);
    defer ctx.allocator.free(content_z);
    const baseline_y = y_top + font_size;
    const result = if (preserve_color_glyphs)
        c.ss_pdf_draw_color_text_baseline(
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
        )
    else
        c.ss_pdf_draw_text_baseline(
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
        );
    if (result != 0) return NativePdfError.PangoCreateFailed;
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
        try drawAtomRawText(ctx, x, y_top, @max(atom.width + paint.font_size, 1), height, atom, paint, false);
        return;
    }

    const kind: LinkAnnotation.Kind = if (isInternalLink(url)) .dest else .uri;
    const resolved_width = @max(link_width, 1);
    if (ctx.link_annotations) |links| {
        const owned_target = try ctx.allocator.dupe(u8, target);
        errdefer ctx.allocator.free(owned_target);
        try links.append(ctx.allocator, .{
            .kind = kind,
            .target = owned_target,
            .x = x,
            .y = y_top,
            .width = resolved_width,
            .height = height,
        });
        try drawAtomRawText(ctx, x, y_top, @max(atom.width + paint.font_size, 1), height, atom, paint, false);
        return;
    }

    try beginLinkAnnotation(ctx, kind, target, @floatCast(x), @floatCast(y_top), @floatCast(resolved_width), @floatCast(height));
    defer c.ss_pdf_end_link(ctx.pdf);
    try drawAtomRawText(ctx, x, y_top, @max(atom.width + paint.font_size, 1), height, atom, paint, false);
}

fn isInternalLink(url: []const u8) bool {
    return url.len > 1 and url[0] == '#';
}

fn emitLinkAnnotation(ctx: *DrawContext, kind: LinkAnnotation.Kind, target: []const u8, x: f64, y: f64, width: f64, height: f64) !void {
    try beginLinkAnnotation(ctx, kind, target, x, y, width, height);
    c.ss_pdf_end_link(ctx.pdf);
}

fn beginLinkAnnotation(ctx: *DrawContext, kind: LinkAnnotation.Kind, target: []const u8, x: f64, y: f64, width: f64, height: f64) !void {
    const target_z = try ctx.allocator.dupeZ(u8, target);
    defer ctx.allocator.free(target_z);
    const result = switch (kind) {
        .dest => c.ss_pdf_begin_dest_link(ctx.pdf, x, y, width, height, target_z.ptr),
        .uri => c.ss_pdf_begin_uri_link(ctx.pdf, x, y, width, height, target_z.ptr),
    };
    if (result != 0) return NativePdfError.CairoFailed;
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
    try runCheckedAllowQpdfWarnings(ctx, &.{ "qpdf", pdf_path, out }, .inherit);
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
        if (ctx.command_failure) |sink| {
            const message = try std.fmt.allocPrint(ctx.allocator, "TeX preamble file not found: {s} (resolved: {s})", .{ path, resolved });
            defer ctx.allocator.free(message);
            try sink.record(message);
        }
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
        const message = try commandSpawnFailureMessage(ctx.allocator, argv, err);
        defer ctx.allocator.free(message);
        if (ctx.command_failure) |sink| try sink.record(message);
        return NativePdfError.AssetConversionFailed;
    };
    defer ctx.allocator.free(result.stdout);
    defer ctx.allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code == 0 or (allow_qpdf_warning_exit and code == 3)) return,
        else => {},
    }
    const message = try commandTermFailureMessage(ctx.allocator, argv, result.term, result.stdout, result.stderr);
    defer ctx.allocator.free(message);
    if (ctx.command_failure) |sink| try sink.record(message);
    return NativePdfError.AssetConversionFailed;
}

fn commandSpawnFailureMessage(allocator: Allocator, argv: []const []const u8, err: anyerror) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "failed to run command (");
    try out.appendSlice(allocator, @errorName(err));
    try out.appendSlice(allocator, "):");
    try appendCommandLine(allocator, &out, argv);
    return try out.toOwnedSlice(allocator);
}

fn commandTermFailureMessage(
    allocator: Allocator,
    argv: []const []const u8,
    term: std.process.Child.Term,
    stdout: []const u8,
    stderr: []const u8,
) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "command failed (");
    try appendCommandTerm(allocator, &out, term);
    try out.appendSlice(allocator, "):");
    try appendCommandLine(allocator, &out, argv);
    try appendCommandOutput(allocator, &out, "stdout", stdout);
    try appendCommandOutput(allocator, &out, "stderr", stderr);
    return try out.toOwnedSlice(allocator);
}

fn appendCommandLine(allocator: Allocator, out: *std.ArrayList(u8), argv: []const []const u8) !void {
    for (argv) |arg| {
        try out.append(allocator, ' ');
        try out.appendSlice(allocator, arg);
    }
}

fn appendCommandTerm(allocator: Allocator, out: *std.ArrayList(u8), term: std.process.Child.Term) !void {
    switch (term) {
        .exited => |code| {
            const text = try std.fmt.allocPrint(allocator, "exit {d}", .{code});
            defer allocator.free(text);
            try out.appendSlice(allocator, text);
        },
        .signal => |signal| {
            const text = try std.fmt.allocPrint(allocator, "signal {d}", .{@intFromEnum(signal)});
            defer allocator.free(text);
            try out.appendSlice(allocator, text);
        },
        .stopped => |signal| {
            const text = try std.fmt.allocPrint(allocator, "stopped {d}", .{@intFromEnum(signal)});
            defer allocator.free(text);
            try out.appendSlice(allocator, text);
        },
        .unknown => |code| {
            const text = try std.fmt.allocPrint(allocator, "unknown {d}", .{code});
            defer allocator.free(text);
            try out.appendSlice(allocator, text);
        },
    }
}

fn appendCommandOutput(allocator: Allocator, out: *std.ArrayList(u8), label: []const u8, value: []const u8) !void {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len == 0) return;
    const summary = try commandOutputSummary(allocator, trimmed);
    defer allocator.free(summary);
    try out.append(allocator, '\n');
    try out.appendSlice(allocator, label);
    try out.appendSlice(allocator, ":\n");
    try out.appendSlice(allocator, summary);
}

fn commandOutputSummary(allocator: Allocator, output: []const u8) ![]u8 {
    var summary = std.ArrayList(u8).empty;
    defer summary.deinit(allocator);

    var include_following: usize = 0;
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        const trimmed_line = std.mem.trim(u8, line, " \t\r\n");
        const interesting = commandOutputLineLooksRelevant(trimmed_line);
        if (interesting) include_following = 2;
        if (interesting or include_following > 0) {
            try appendLimitedOutputLine(allocator, &summary, line);
            if (!interesting and include_following > 0) include_following -= 1;
            if (summary.items.len >= command_failure_output_limit) break;
        }
    }

    if (summary.items.len > 0) return try summary.toOwnedSlice(allocator);
    return try commandOutputTail(allocator, output);
}

fn commandOutputLineLooksRelevant(line: []const u8) bool {
    if (line.len == 0) return false;
    if (line[0] == '!') return true;
    return containsAsciiIgnoreCase(line, "error") or
        containsAsciiIgnoreCase(line, "failed") or
        containsAsciiIgnoreCase(line, "fatal");
}

fn appendLimitedOutputLine(allocator: Allocator, out: *std.ArrayList(u8), line: []const u8) !void {
    if (out.items.len != 0) try out.append(allocator, '\n');
    const remaining = command_failure_output_limit - @min(out.items.len, command_failure_output_limit);
    if (remaining == 0) return;
    const end = @min(line.len, remaining);
    try out.appendSlice(allocator, line[0..end]);
}

fn commandOutputTail(allocator: Allocator, output: []const u8) ![]u8 {
    if (output.len <= command_failure_output_limit) return allocator.dupe(u8, output);
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "... output truncated ...\n");
    const start = output.len - command_failure_output_limit;
    try out.appendSlice(allocator, output[start..]);
    return try out.toOwnedSlice(allocator);
}

fn containsAsciiIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var index: usize = 0;
    while (index + needle.len <= haystack.len) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[index .. index + needle.len], needle)) return true;
    }
    return false;
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
