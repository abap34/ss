const std = @import("std");
const core = @import("core");
const utils = @import("utils");
const build_options = @import("build_options");
const fontawesome_assets = @import("fontawesome_assets");

const text_tokenize = core.text_tokenize;
const wrap_layout = core.render_wrap;
const json = utils.json;
const render_emitter = @import("render_emitter");
const c = @import("pdf_ffi").c;
const render_ir = @import("render");
const render_resources = @import("render_resources");
const render_math = @import("render_math");
const render_compile = @import("../compile.zig");
const fingerprint = @import("fingerprint.zig");
const text_measure = core.render_text_measure;

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
const Defaults = core.layout.Defaults;
const RenderKind = core.render_policy.RenderKind;
const HorizontalAlign = core.render_policy.HorizontalAlign;
const FontFace = core.font.Face;
const ResolvedRender = core.render_policy.ResolvedRender;
const TextPaint = core.render_policy.TextPaint;
const CodePaint = core.render_policy.CodePaint;
const MathPaint = core.render_policy.MathPaint;
const ShapePaint = core.render_policy.ShapePaint;
const ShapeMarker = core.render_policy.ShapeMarker;
const MarkdownDocument = core.markdown.MarkdownDocument;
const Line = core.markdown.Line;
const Block = core.markdown.Block;
const Run = core.markdown.Run;
const TexPreambleEntry = core.render_env.TexPreambleEntry;

const NativePdfError = error{
    ImageDecodeFailed,
    AssetConversionFailed,
    InvalidPdfCache,
    InvalidFontAwesomeIcon,
    UnsupportedAssetType,
};

pub const native_artifact_cache_version = "ss-native-artifacts-v6";
const layout_measurement_cache_version = "ss-native-layout-measure-v13";
const layout_measurement_cache_file_format = "ss-layout-measurements-v1";
const layout_measurement_cache_read_limit = 16 * 1024 * 1024;
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
    gdk_pixbuf: []const u8,
    fontconfig: u32,
    harfbuzz: []const u8,
    qpdf: []const u8,
};

pub fn nativeRuntimeVersions() NativeRuntimeVersions {
    return .{
        .cairo = spanCString(c.ss_pdf_cairo_version_string()),
        .pango = spanCString(c.ss_pdf_pango_version_string()),
        .librsvg = spanCString(c.ss_pdf_librsvg_version_string()),
        .gdk_pixbuf = spanCString(c.ss_pdf_gdk_pixbuf_version_string()),
        .fontconfig = @intCast(c.ss_pdf_fontconfig_version()),
        .harfbuzz = spanCString(c.ss_pdf_harfbuzz_version_string()),
        .qpdf = spanCString(c.ss_qpdf_version_string()),
    };
}

const DrawContext = struct {
    allocator: Allocator,
    io: std.Io,
    asset_base_dir: []const u8,
    cache_dir: []const u8,
    highlight_languages: []const utils.highlight.Language,
    command_failure: ?*CommandFailure = null,
    link_annotations: ?*std.ArrayList(LinkAnnotation) = null,
    destinations: ?*std.ArrayList(DestinationAnnotation) = null,
    emitter: ?render_emitter.Emitter = null,
    measurement_bounds: ?*MeasurementBounds = null,
    tex_preamble: []const TexPreambleEntry = &.{},
};

const MeasurementBounds = struct {
    ink: ?render_ir.Rect = null,

    fn include(self: *MeasurementBounds, rect: render_ir.Rect) void {
        if (rect.width <= 0 or rect.height <= 0) return;
        self.ink = if (self.ink) |current| current.unioned(rect) else rect;
    }
};

fn activeEmitter(ctx: *DrawContext) *render_emitter.Emitter {
    return if (ctx.emitter) |*emitter| emitter else unreachable;
}

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

const MathKind = enum { inline_math, display, block, raw_block };

const AtomContent = union(enum) {
    text,
    structured_math: struct {
        tree: render_ir.MathTreeId,
        layout: render_ir.MathLayout,
    },
    raw_math: struct {
        path: []const u8,
        page_index: usize,
    },
    icon: struct { path: []const u8 },

    fn deinit(self: *AtomContent, allocator: Allocator) void {
        switch (self.*) {
            .text => {},
            .structured_math => |*math| math.layout.deinit(allocator),
            .raw_math => |math| allocator.free(math.path),
            .icon => |icon| allocator.free(icon.path),
        }
    }
};

const Atom = struct {
    content: AtomContent = .text,
    text: []const u8,
    font: FontFace,
    color: Color,
    width: f32,
    height: f32 = 0,
    baseline_from_bottom: f32 = 0,
    is_space: bool,
    is_emoji: bool = false,
    strikethrough: bool = false,
    underline: bool = false,
    link_url: ?[]const u8 = null,
};

const AtomPaint = struct {
    font_size: f32,
    line_height: f32,
    emoji_spacing: f32,
    inline_math_spacing: f32,
};

const AtomPosition = struct {
    index: usize,
    offset: f32,
};

const AtomVisualLine = struct {
    start: usize,
    end: usize,
    width: f32,
};

const SvgAsset = struct {
    path: []const u8,
    width: f32,
    height: f32,
};

const MathAsset = struct {
    path: []const u8,
    page_index: usize,
    width: f32,
    height: f32,
    baseline_from_bottom: f32,
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

const CommandFailure = struct {
    allocator: Allocator,
    message: ?[]u8 = null,

    fn deinit(self: *CommandFailure) void {
        if (self.message) |message| self.allocator.free(message);
    }

    fn record(self: *CommandFailure, message: []const u8) !void {
        if (self.message != null) return;
        self.message = try self.allocator.dupe(u8, message);
    }
};

pub const Options = struct {
    jobs: ?usize = null,
    cache_dir: []const u8 = ".ss-cache/render",
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

const ObjectCommand = struct {
    page_id: core.NodeId,
    node_id: core.NodeId,
    frame: Frame,
    content: []const u8,
    content_provenance: []const core.ContentProvenance = &.{},
    link_id: ?[]const u8 = null,
    render: ResolvedRender,
    parse_mode: core.markdown.ParseMode,
    markdown_doc: ?*const MarkdownDocument = null,
    text_layout: ?*const core.markdown.TextLayout = null,
    asset_deps: []const core.prepared.AssetDependency = &.{},
    tex_preamble: []const TexPreambleEntry,
    math_kind: MathKind = .block,
    origin: ?[]const u8 = null,
    payload_kind: ?core.PayloadKind = null,

    fn deinit(self: *ObjectCommand, allocator: Allocator) void {
        allocator.free(self.tex_preamble);
    }
};

const PreloadWork = struct {
    plan: []const PreloadTask,
    cached: []const bool,
    next: std.atomic.Value(usize) = .init(0),
    completed: std.atomic.Value(usize),
    failed: std.atomic.Value(bool) = .init(false),
    io: std.Io,
    asset_base_dir: []const u8,
    cache_dir: []const u8,
};

const MathBatchEntry = struct {
    task_index: usize,
    source: []const u8,
    preamble: []const TexPreambleEntry,
    kind: MathKind,
    out: []u8,
};

const MathBatchGroup = struct {
    key: []u8,
    entries: std.ArrayList(MathBatchEntry) = .empty,

    fn deinit(self: *MathBatchGroup, allocator: Allocator) void {
        allocator.free(self.key);
        for (self.entries.items) |entry| allocator.free(entry.out);
        self.entries.deinit(allocator);
    }
};

pub const Progress = struct {
    context: *anyopaque,
    artifactCompleted: *const fn (context: *anyopaque, completed: usize, total: usize) void,
};

var temp_cache_counter: usize = 0;

pub const LayoutMeasurementScope = struct {
    allocator: Allocator,
    io: std.Io,
    asset_cache_dir: []const u8,
    measurement_cache_dir: []const u8,
    measurement_cache_path: []const u8,
    ctx: DrawContext,
    prepared_objects: std.AutoHashMap(core.NodeId, *const core.prepared.PreparedObject),
    cache_mutex: std.Io.Mutex = std.Io.Mutex.init,
    persistent_measurements: std.AutoHashMap(u64, core.LayoutMeasurement),
    run_measurements: std.AutoHashMap(u64, core.LayoutMeasurement),
    measurement_cache_dirty: bool = false,

    pub fn init(
        allocator: Allocator,
        io: std.Io,
        state: *core.DocumentState,
        pages: *const core.prepared.PreparedPages,
    ) !LayoutMeasurementScope {
        const default_options: Options = .{};
        const cache_dir = default_options.cache_dir;
        try std.Io.Dir.cwd().createDirPath(io, cache_dir);
        const asset_cache_dir = try std.fs.path.join(allocator, &.{ cache_dir, "artifacts", "native" });
        errdefer allocator.free(asset_cache_dir);
        try std.Io.Dir.cwd().createDirPath(io, asset_cache_dir);
        const measurement_cache_dir = try std.fs.path.join(allocator, &.{ asset_cache_dir, "measurements" });
        errdefer allocator.free(measurement_cache_dir);
        try std.Io.Dir.cwd().createDirPath(io, measurement_cache_dir);
        const measurement_cache_path = try std.fs.path.join(allocator, &.{ measurement_cache_dir, "measurements.tsv" });
        errdefer allocator.free(measurement_cache_path);

        var persistent_measurements = std.AutoHashMap(u64, core.LayoutMeasurement).init(allocator);
        errdefer persistent_measurements.deinit();
        try readPersistedMeasurements(allocator, io, measurement_cache_path, &persistent_measurements);

        var prepared_objects = try buildPreparedObjectLookup(allocator, pages);
        errdefer prepared_objects.deinit();

        return .{
            .allocator = allocator,
            .io = io,
            .asset_cache_dir = asset_cache_dir,
            .measurement_cache_dir = measurement_cache_dir,
            .measurement_cache_path = measurement_cache_path,
            .ctx = .{
                .allocator = allocator,
                .io = io,
                .asset_base_dir = if (state.asset_base_dir.len == 0) "." else state.asset_base_dir,
                .cache_dir = asset_cache_dir,
                .highlight_languages = &.{},
            },
            .prepared_objects = prepared_objects,
            .persistent_measurements = persistent_measurements,
            .run_measurements = std.AutoHashMap(u64, core.LayoutMeasurement).init(allocator),
        };
    }

    pub fn deinit(self: *LayoutMeasurementScope) void {
        self.flushMeasurementCache() catch {};
        self.prepared_objects.deinit();
        self.persistent_measurements.deinit();
        self.run_measurements.deinit();
        self.allocator.free(self.measurement_cache_path);
        self.allocator.free(self.measurement_cache_dir);
        self.allocator.free(self.asset_cache_dir);
    }

    pub fn provider(self: *LayoutMeasurementScope) core.LayoutMeasurementProvider {
        return .{
            .context = self,
            .measure = measureLayoutNode,
        };
    }

    fn measureLayoutNode(
        context: *anyopaque,
        state_ptr: *anyopaque,
        node: *const core.Node,
        width: f32,
        mode: core.LayoutMeasurementMode,
    ) anyerror!?core.LayoutMeasurement {
        const scope: *LayoutMeasurementScope = @ptrCast(@alignCast(context));
        const state: *core.DocumentState = @ptrCast(@alignCast(state_ptr));
        return try scope.measureNode(state, node, width, mode);
    }

    fn measureNode(self: *LayoutMeasurementScope, state: *core.DocumentState, node: *const core.Node, width: f32, mode: core.LayoutMeasurementMode) !?core.LayoutMeasurement {
        const profile_total = utils.measure_profile.start();
        defer utils.measure_profile.recordLayoutMeasurementTotal(profile_total);

        if (node.kind != .object) return null;

        const profile_object_command = utils.measure_profile.start();
        var command = try self.objectCommandForNode(state.allocator, node, width, mode);
        utils.measure_profile.recordLayoutMeasurementObjectCommand(profile_object_command);
        defer command.deinit(state.allocator);

        const profile_cache_key = utils.measure_profile.start();
        var key_ctx = self.ctx;
        key_ctx.allocator = state.allocator;
        const cache_key = try fingerprint.layoutMeasurementKey(
            .{
                .allocator = key_ctx.allocator,
                .io = key_ctx.io,
                .asset_base_dir = key_ctx.asset_base_dir,
            },
            layout_measurement_cache_version,
            native_artifact_cache_version,
            Defaults.width,
            Defaults.height,
            mode,
            width,
            .{
                .frame = command.frame,
                .content = command.content,
                .link_id = command.link_id,
                .parse_mode = @tagName(command.parse_mode),
                .render = command.render,
                .tex_preamble = command.tex_preamble,
                .math_kind = @tagName(command.math_kind),
                .raw_tex = command.math_kind == .raw_block,
            },
        );
        utils.measure_profile.recordLayoutMeasurementCacheKey(profile_cache_key);

        if (try self.cachedMeasurement(cache_key, true)) |cached| return cached;

        if (try self.cachedMeasurement(cache_key, false)) |cached| return cached;

        var target = CommandFailure{ .allocator = state.allocator };
        defer target.deinit();
        var measurement_ctx = self.ctx;
        measurement_ctx.allocator = state.allocator;
        measurement_ctx.command_failure = &target;
        const profile_intrinsic = utils.measure_profile.start();
        defer utils.measure_profile.recordRenderIntrinsic(profileRenderMeasureKind(command.render.kind), profile_intrinsic);
        var measured = measureObjectCommandIntrinsic(&measurement_ctx, &command, width, mode) catch |err| {
            try addMeasurementRenderDiagnostic(&measurement_ctx, state, &command, err, target.message);
            return err;
        };
        if (measured) |*value| {
            value.cache_key = cache_key;
            try self.storeMeasurement(cache_key, value.*);
        }
        return measured;
    }

    fn cachedMeasurement(self: *LayoutMeasurementScope, cache_key: u64, record_miss: bool) !?core.LayoutMeasurement {
        const profile_lock = utils.measure_profile.start();
        self.cache_mutex.lockUncancelable(self.io);
        utils.measure_profile.recordLayoutMeasurementLockWait(profile_lock);
        defer self.cache_mutex.unlock(self.io);

        const profile_memory_cache = utils.measure_profile.start();
        if (self.run_measurements.get(cache_key)) |cached| {
            utils.measure_profile.recordLayoutMeasurementCache(.memory_hit, profile_memory_cache);
            return cached;
        }

        const profile_persistent_cache = utils.measure_profile.start();
        if (self.persistent_measurements.get(cache_key)) |cached| {
            utils.measure_profile.recordLayoutMeasurementCache(.file_hit, profile_persistent_cache);
            try self.run_measurements.put(cache_key, cached);
            return cached;
        }
        if (record_miss) {
            utils.measure_profile.recordLayoutMeasurementCache(.file_miss, profile_persistent_cache);
        }
        return null;
    }

    fn storeMeasurement(self: *LayoutMeasurementScope, cache_key: u64, measurement: core.LayoutMeasurement) !void {
        const profile_lock = utils.measure_profile.start();
        self.cache_mutex.lockUncancelable(self.io);
        utils.measure_profile.recordLayoutMeasurementLockWait(profile_lock);
        defer self.cache_mutex.unlock(self.io);

        try self.run_measurements.put(cache_key, measurement);
        self.measurement_cache_dirty = true;
    }

    fn flushMeasurementCache(self: *LayoutMeasurementScope) !void {
        if (!self.measurement_cache_dirty or self.run_measurements.count() == 0) return;
        const profile_write = utils.measure_profile.start();
        defer utils.measure_profile.recordLayoutMeasurementCache(.write, profile_write);

        const tmp = try tempCachePath(&self.ctx, self.measurement_cache_path, "tsv");
        defer self.allocator.free(tmp);
        errdefer deleteFileIfExists(&self.ctx, tmp);

        var out = std.ArrayList(u8).empty;
        defer out.deinit(self.allocator);
        try out.print(self.allocator, "{s}\t{s}\n", .{ layout_measurement_cache_file_format, layout_measurement_cache_version });
        var iterator = self.run_measurements.iterator();
        while (iterator.next()) |entry| {
            const measurement = entry.value_ptr.*;
            if (!(measurement.width > 0) or !(measurement.height > 0)) continue;
            try out.print(self.allocator, "{x}\t{d:.6}\t{d:.6}\n", .{ entry.key_ptr.*, measurement.width, measurement.height });
        }
        try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = tmp, .data = out.items, .flags = .{ .truncate = true } });
        try renameReplacing(&self.ctx, tmp, self.measurement_cache_path);
        self.measurement_cache_dirty = false;
    }

    fn objectCommandForNode(self: *LayoutMeasurementScope, allocator: Allocator, node: *const core.Node, width: f32, mode: core.LayoutMeasurementMode) !ObjectCommand {
        const object = self.preparedObject(node.id) orelse return error.MissingPreparedObject;
        return try objectCommandForObject(allocator, node, object, width, mode);
    }

    fn objectCommandForObject(
        allocator: Allocator,
        node: *const core.Node,
        object: *const core.prepared.PreparedObject,
        width: f32,
        mode: core.LayoutMeasurementMode,
    ) !ObjectCommand {
        var render = object.render;
        if (mode == .natural) {
            if (render.text) |*text| text.wrap = false;
        }
        return .{
            .page_id = 0,
            .node_id = node.id,
            .frame = .{
                .x = 0,
                .y = 0,
                .width = @max(width, 1),
                .height = measurementFrameHeight(node, mode),
            },
            .content = object.content,
            .content_provenance = object.content_provenance,
            .link_id = object.link_id,
            .render = render,
            .parse_mode = object.parse_mode,
            .markdown_doc = object.markdownDocument(),
            .text_layout = object.textLayout(),
            .asset_deps = object.asset_deps,
            .tex_preamble = try cloneTexPreambleEntries(allocator, object.tex_preamble),
            .math_kind = mathKindForNode(node),
            .origin = object.origin,
            .payload_kind = object.payload_kind,
        };
    }

    fn preparedObject(self: *const LayoutMeasurementScope, node_id: core.NodeId) ?*const core.prepared.PreparedObject {
        return self.prepared_objects.get(node_id);
    }
};

fn measurementFrameHeight(node: *const core.Node, mode: core.LayoutMeasurementMode) f32 {
    if (mode == .width_constrained and node.frame.height > 0) {
        return @max(node.frame.height, 1);
    }
    return Defaults.height;
}

fn buildPreparedObjectLookup(
    allocator: Allocator,
    pages: *const core.prepared.PreparedPages,
) !std.AutoHashMap(core.NodeId, *const core.prepared.PreparedObject) {
    var lookup = std.AutoHashMap(core.NodeId, *const core.prepared.PreparedObject).init(allocator);
    errdefer lookup.deinit();

    for (pages.pages) |*page| {
        for (page.objects) |*object| {
            try lookup.put(object.node_id, object);
        }
    }
    return lookup;
}

fn readPersistedMeasurements(
    allocator: Allocator,
    io: std.Io,
    path: []const u8,
    target: *std.AutoHashMap(u64, core.LayoutMeasurement),
) !void {
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(layout_measurement_cache_read_limit)) catch return;
    defer allocator.free(text);

    var lines = std.mem.splitScalar(u8, text, '\n');
    const header = std.mem.trim(u8, lines.next() orelse return, " \t\r\n");
    if (!measurementCacheHeaderMatches(header)) return;

    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r\n");
        if (line.len == 0) continue;
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        const key_text = fields.next() orelse continue;
        const width_text = fields.next() orelse continue;
        const height_text = fields.next() orelse continue;
        const key = std.fmt.parseUnsigned(u64, key_text, 16) catch continue;
        const width = std.fmt.parseFloat(f32, width_text) catch continue;
        const height = std.fmt.parseFloat(f32, height_text) catch continue;
        if (!(width > 0) or !(height > 0)) continue;
        try target.put(key, .{
            .width = width,
            .height = height,
            .cache_key = key,
        });
    }
}

fn measurementCacheHeaderMatches(header: []const u8) bool {
    var fields = std.mem.tokenizeAny(u8, header, " \t");
    const format = fields.next() orelse return false;
    const version = fields.next() orelse return false;
    return std.mem.eql(u8, format, layout_measurement_cache_file_format) and
        std.mem.eql(u8, version, layout_measurement_cache_version);
}

pub fn preloadPreparedPageArtifacts(
    allocator: Allocator,
    io: std.Io,
    state: *core.DocumentState,
    pages: *const core.prepared.PreparedPages,
    options: Options,
    progress: ?Progress,
) !void {
    try std.Io.Dir.cwd().createDirPath(io, options.cache_dir);
    const asset_cache_dir = try std.fs.path.join(allocator, &.{ options.cache_dir, "artifacts", "native" });
    defer allocator.free(asset_cache_dir);
    try std.Io.Dir.cwd().createDirPath(io, asset_cache_dir);

    var ctx = DrawContext{
        .allocator = allocator,
        .io = io,
        .asset_base_dir = if (state.asset_base_dir.len == 0) "." else state.asset_base_dir,
        .cache_dir = asset_cache_dir,
        .highlight_languages = options.highlight_languages,
    };

    const tasks = try collectPreparedPagePreloadTasks(&ctx, pages);
    defer {
        freePreloadTasks(allocator, tasks);
        allocator.free(tasks);
    }
    const cached = try allocator.alloc(bool, tasks.len);
    defer allocator.free(cached);

    var miss_count: usize = 0;
    for (tasks, 0..) |task, index| {
        const profile_scan = utils.measure_profile.start();
        cached[index] = try preloadTaskPresent(&ctx, task);
        utils.measure_profile.recordArtifactScan(profilePreloadKind(task), cached[index], profile_scan);
        if (!cached[index]) miss_count += 1;
    }

    const initial_done = tasks.len - miss_count;
    if (progress) |p| p.artifactCompleted(p.context, initial_done, tasks.len);
    if (miss_count == 0) return;

    const profile_build_wall = utils.measure_profile.start();
    defer utils.measure_profile.recordArtifactBuildWall(miss_count, profile_build_wall);
    executePreloadTaskList(&ctx, tasks, cached, miss_count, options, progress) catch |err| {
        try collectPreloadTaskDiagnostics(&ctx, state, tasks, cached);
        return err;
    };
}

pub const Compiler = struct {
    io: std.Io,
    options: render_compile.Options,

    pub fn prepare(
        self: *Compiler,
        allocator: Allocator,
        state: *core.DocumentState,
        pages: *const core.prepared.PreparedPages,
    ) !void {
        try preloadPreparedPageArtifacts(allocator, self.io, state, pages, .{
            .cache_dir = self.options.cache_dir,
            .highlight_languages = self.options.highlight_languages,
        }, null);
    }

    pub fn compilePage(
        self: *Compiler,
        allocator: Allocator,
        state: *core.DocumentState,
        prepared_page: *const core.prepared.PreparedPage,
        resources: *render_resources.Builder,
        fonts: *render_ir.FontBuilder,
        math: *render_ir.MathBuilder,
    ) !render_ir.Page {
        const asset_cache_dir = try std.fs.path.join(allocator, &.{ self.options.cache_dir, "artifacts", "native" });
        defer allocator.free(asset_cache_dir);
        var draw_context = DrawContext{
            .allocator = allocator,
            .io = self.io,
            .asset_base_dir = if (state.asset_base_dir.len == 0) "." else state.asset_base_dir,
            .cache_dir = asset_cache_dir,
            .highlight_languages = self.options.highlight_languages,
        };

        const commands = try buildObjectCommands(allocator, state, prepared_page);
        defer {
            for (commands) |*command| command.deinit(allocator);
            allocator.free(commands);
        }
        return try buildRenderPage(
            &draw_context,
            prepared_page.page_id,
            prepared_page.index,
            prepared_page.background,
            commands,
            resources,
            fonts,
            math,
        );
    }
};

fn buildObjectCommands(
    allocator: Allocator,
    state: *core.DocumentState,
    page_unit: *const core.prepared.PreparedPage,
) ![]ObjectCommand {
    var commands = std.ArrayList(ObjectCommand).empty;
    errdefer {
        for (commands.items) |*command| command.deinit(allocator);
        commands.deinit(allocator);
    }
    for (page_unit.objects) |*object| {
        const node = state.getNode(object.node_id) orelse continue;
        if (node.kind != .object or !object.attached) continue;
        if ((state.parentPageOf(node.id) orelse continue) != page_unit.page_id) continue;
        try commands.append(allocator, try initObjectCommand(allocator, page_unit.page_id, node, object, node.frame));
    }
    return try commands.toOwnedSlice(allocator);
}

fn initObjectCommand(
    allocator: Allocator,
    page_id: core.NodeId,
    node: *const core.Node,
    object: *const core.prepared.PreparedObject,
    frame: Frame,
) !ObjectCommand {
    return .{
        .page_id = page_id,
        .node_id = node.id,
        .frame = frame,
        .content = object.content,
        .content_provenance = object.content_provenance,
        .link_id = object.link_id,
        .render = object.render,
        .parse_mode = object.parse_mode,
        .markdown_doc = object.markdownDocument(),
        .text_layout = object.textLayout(),
        .asset_deps = object.asset_deps,
        .tex_preamble = try cloneTexPreambleEntries(allocator, object.tex_preamble),
        .math_kind = mathKindForNode(node),
        .origin = object.origin,
        .payload_kind = object.payload_kind,
    };
}

fn renameReplacing(ctx: *DrawContext, tmp_path: []const u8, final_path: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    cwd.rename(tmp_path, cwd, final_path, ctx.io) catch |err| {
        deleteFileIfExists(ctx, final_path);
        cwd.rename(tmp_path, cwd, final_path, ctx.io) catch return err;
    };
}

fn hashString(hasher: *std.hash.Wyhash, value: []const u8) void {
    hashUsize(hasher, value.len);
    hasher.update(value);
}

fn spanCString(ptr: [*c]const u8) []const u8 {
    if (ptr == null) return "unknown";
    const sentinel: [*:0]const u8 = @ptrCast(ptr);
    return std.mem.span(sentinel);
}

fn hashUsize(hasher: *std.hash.Wyhash, value: usize) void {
    const normalized: u64 = @intCast(value);
    hashU64(hasher, normalized);
}

fn hashU64(hasher: *std.hash.Wyhash, value: u64) void {
    hasher.update(std.mem.asBytes(&value));
}

fn collectPreparedPagePreloadTasks(ctx: *DrawContext, pages: *const core.prepared.PreparedPages) ![]PreloadTask {
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

    var deps = std.ArrayList(usize).empty;
    defer deps.deinit(ctx.allocator);

    for (pages.pages) |*page| {
        for (page.objects) |*object| {
            if (!object.attached or object.asset_deps.len == 0) continue;
            deps.clearRetainingCapacity();
            const target = preparedObjectDiagnosticTarget(page.page_id, object);
            try collectPreparedObjectPreloads(ctx, object, target, &tasks, &seen, &deps);
        }
    }

    return try tasks.toOwnedSlice(ctx.allocator);
}

fn collectPreparedObjectPreloads(
    ctx: *DrawContext,
    object: *const core.prepared.PreparedObject,
    target: RenderDiagnosticTarget,
    tasks: *std.ArrayList(PreloadTask),
    seen: *std.StringHashMap(usize),
    deps: *std.ArrayList(usize),
) !void {
    for (object.asset_deps) |dep| {
        const dep_target = targetWithContentSpan(target, dep.content_start, dep.content_end);
        switch (dep.kind) {
            .inline_math, .display_math => {
                const kind: MathKind = if (dep.kind == .display_math) .display else .inline_math;
                if (object.tex_preamble.len != 0 and !try supportsStructuredMath(ctx.allocator, dep.source, kind)) {
                    try registerPlanPreloadTask(ctx, tasks, seen, deps, .{ .math = .{
                        .source = try ctx.allocator.dupe(u8, dep.source),
                        .preamble = try cloneTexPreambleEntries(ctx.allocator, object.tex_preamble),
                        .kind = kind,
                        .target = dep_target,
                    } });
                }
            },
            .block_math => {
                const kind = mathKindForPreparedObject(object);
                if (kind == .raw_block) try registerPlanPreloadTask(ctx, tasks, seen, deps, .{ .math = .{
                    .source = try ctx.allocator.dupe(u8, dep.source),
                    .preamble = try cloneTexPreambleEntries(ctx.allocator, object.tex_preamble),
                    .kind = kind,
                    .target = dep_target,
                } });
            },
            .icon => try registerPlanPreloadTask(ctx, tasks, seen, deps, .{ .icon = .{
                .source = try ctx.allocator.dupe(u8, dep.source),
                .target = dep_target,
            } }),
            .vector_pdf => {
                const source = try resolveAssetPath(ctx, dep.source);
                try registerPlanPreloadTask(ctx, tasks, seen, deps, .{ .vector_pdf = .{
                    .source = source,
                    .target = dep_target,
                } });
            },
            .raster_asset => {},
        }
    }
}

fn preparedObjectDiagnosticTarget(page_id: core.NodeId, object: *const core.prepared.PreparedObject) RenderDiagnosticTarget {
    return .{
        .page_id = page_id,
        .node_id = object.node_id,
        .origin = object.origin,
        .payload_kind = object.payload_kind,
        .content_provenance = object.content_provenance,
    };
}

fn mathKindForPreparedObject(object: *const core.prepared.PreparedObject) MathKind {
    return switch (object.payload_kind orelse .text) {
        .math_tex => .raw_block,
        .math_text => .block,
        else => .block,
    };
}

fn collectObjectPreloads(
    ctx: *DrawContext,
    command: *const ObjectCommand,
    tasks: *std.ArrayList(PreloadTask),
    seen: *std.StringHashMap(usize),
    page_deps: *std.ArrayList(usize),
) !void {
    const target = objectDiagnosticTarget(command);
    if (command.asset_deps.len != 0) {
        try collectAssetDepsForPlan(ctx, command, target, tasks, seen, page_deps);
        if (command.render.kind == .text or command.render.kind == .vector_math or command.render.kind == .vector_asset) return;
    } else if (command.render.kind == .text) {
        return;
    }
    switch (command.render.kind) {
        .text => {},
        .vector_math => {
            if (command.math_kind == .raw_block) try registerPlanPreloadTask(ctx, tasks, seen, page_deps, .{ .math = .{
                .source = try ctx.allocator.dupe(u8, command.content),
                .preamble = try cloneTexPreambleEntries(ctx.allocator, command.tex_preamble),
                .kind = command.math_kind,
                .target = targetWithContentSpan(target, 0, command.content.len),
            } });
        },
        .vector_asset => {
            const source = try resolveAssetPath(ctx, command.content);
            if (std.ascii.eqlIgnoreCase(std.fs.path.extension(source), ".pdf")) {
                try registerPlanPreloadTask(ctx, tasks, seen, page_deps, .{ .vector_pdf = .{
                    .source = source,
                    .target = targetWithContentSpan(target, 0, command.content.len),
                } });
            } else {
                ctx.allocator.free(source);
            }
        },
        .raster_asset => {
            const source = try resolveAssetPath(ctx, command.content);
            if (std.ascii.eqlIgnoreCase(std.fs.path.extension(source), ".svg")) {
                ctx.allocator.free(source);
            } else {
                try registerPlanPreloadTask(ctx, tasks, seen, page_deps, .{ .raster = .{
                    .source = source,
                    .target = targetWithContentSpan(target, 0, command.content.len),
                } });
            }
        },
        .code, .shape, .chrome_only => {},
    }
}

fn collectAssetDepsForPlan(
    ctx: *DrawContext,
    command: *const ObjectCommand,
    target: RenderDiagnosticTarget,
    tasks: *std.ArrayList(PreloadTask),
    seen: *std.StringHashMap(usize),
    page_deps: *std.ArrayList(usize),
) !void {
    for (command.asset_deps) |dep| {
        const dep_target = targetWithContentSpan(target, dep.content_start, dep.content_end);
        switch (dep.kind) {
            .inline_math, .display_math => {
                const kind: MathKind = if (dep.kind == .display_math) .display else .inline_math;
                if (command.tex_preamble.len != 0 and !try supportsStructuredMath(ctx.allocator, dep.source, kind)) {
                    try registerPlanPreloadTask(ctx, tasks, seen, page_deps, .{ .math = .{
                        .source = try ctx.allocator.dupe(u8, dep.source),
                        .preamble = try cloneTexPreambleEntries(ctx.allocator, command.tex_preamble),
                        .kind = kind,
                        .target = dep_target,
                    } });
                }
            },
            .block_math => {
                if (command.math_kind == .raw_block) try registerPlanPreloadTask(ctx, tasks, seen, page_deps, .{ .math = .{
                    .source = try ctx.allocator.dupe(u8, dep.source),
                    .preamble = try cloneTexPreambleEntries(ctx.allocator, command.tex_preamble),
                    .kind = command.math_kind,
                    .target = dep_target,
                } });
            },
            .icon => try registerPlanPreloadTask(ctx, tasks, seen, page_deps, .{ .icon = .{
                .source = try ctx.allocator.dupe(u8, dep.source),
                .target = dep_target,
            } }),
            .vector_pdf => {
                const source = try resolveAssetPath(ctx, dep.source);
                try registerPlanPreloadTask(ctx, tasks, seen, page_deps, .{ .vector_pdf = .{
                    .source = source,
                    .target = dep_target,
                } });
            },
            .raster_asset => {},
        }
    }
}

fn objectDiagnosticTarget(command: *const ObjectCommand) RenderDiagnosticTarget {
    return .{
        .page_id = command.page_id,
        .node_id = command.node_id,
        .origin = command.origin,
        .payload_kind = command.payload_kind,
        .content_provenance = command.content_provenance,
    };
}

fn targetWithContentSpan(target: RenderDiagnosticTarget, start: usize, end: usize) RenderDiagnosticTarget {
    var refined = target;
    refined.content_start = start;
    refined.content_end = end;
    return refined;
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

fn addPreloadRenderDiagnostic(state: *core.DocumentState, task: PreloadTask, err: anyerror, maybe_message: ?[]const u8) !void {
    const target = preloadTaskTarget(task);
    try addTargetedRenderDiagnostic(state, target, preloadTaskLabel(task), err, maybe_message);
}

fn addTargetedRenderDiagnostic(
    state: *core.DocumentState,
    target: RenderDiagnosticTarget,
    label: []const u8,
    err: anyerror,
    maybe_message: ?[]const u8,
) !void {
    var origin = try preloadTaskDiagnosticOrigin(state, target);
    defer origin.deinit(state.allocator);
    const detail = maybe_message orelse @errorName(err);
    const reason = try std.fmt.allocPrint(state.allocator, "{s}: {s}", .{ label, detail });
    try state.addRenderDiagnostic(.@"error", target.page_id, target.node_id, origin.text, .{
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

fn preloadTaskDiagnosticOrigin(state: *core.DocumentState, target: RenderDiagnosticTarget) !DiagnosticOrigin {
    if (target.content_start) |start| {
        if (target.content_end) |end| {
            if (try originForContentSpan(state.allocator, target.content_provenance, start, end)) |origin| {
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

fn addObjectCommandDiagnostic(state: *core.DocumentState, command: *const ObjectCommand, err: anyerror, maybe_message: ?[]const u8) !void {
    try addTargetedRenderDiagnostic(state, objectCommandDiagnosticTarget(command), objectCommandLabel(command), err, maybe_message);
}

fn addMeasurementRenderDiagnostic(ctx: *DrawContext, state: *core.DocumentState, command: *const ObjectCommand, err: anyerror, maybe_message: ?[]const u8) !void {
    if (err == error.UnsupportedMathSyntax and try addUnsupportedMathDiagnostic(ctx, state, command)) return;

    var tasks = std.ArrayList(PreloadTask).empty;
    defer {
        freePreloadTasks(ctx.allocator, tasks.items);
        tasks.deinit(ctx.allocator);
    }
    var seen = std.StringHashMap(usize).init(ctx.allocator);
    defer {
        var key_it = seen.keyIterator();
        while (key_it.next()) |key| ctx.allocator.free(key.*);
        seen.deinit();
    }
    var page_deps = std.ArrayList(usize).empty;
    defer page_deps.deinit(ctx.allocator);

    collectObjectPreloads(ctx, command, &tasks, &seen, &page_deps) catch {
        try addObjectCommandDiagnostic(state, command, err, maybe_message);
        return;
    };

    for (tasks.items) |task| {
        var target = CommandFailure{ .allocator = state.allocator };
        defer target.deinit();
        var diagnostic_ctx = ctx.*;
        diagnostic_ctx.command_failure = &target;
        preloadOne(&diagnostic_ctx, task) catch |task_err| {
            try addPreloadRenderDiagnostic(state, task, task_err, target.message);
            return;
        };
    }

    try addObjectCommandDiagnostic(state, command, err, maybe_message);
}

fn addUnsupportedMathDiagnostic(
    ctx: *DrawContext,
    state: *core.DocumentState,
    command: *const ObjectCommand,
) !bool {
    const target = objectDiagnosticTarget(command);
    for (command.asset_deps) |dep| {
        const kind: MathKind = switch (dep.kind) {
            .inline_math => .inline_math,
            .display_math => .display,
            .block_math => if (command.math_kind == .raw_block) continue else command.math_kind,
            .icon, .vector_pdf, .raster_asset => continue,
        };
        if (try supportsStructuredMath(ctx.allocator, dep.source, kind)) continue;
        try addTargetedRenderDiagnostic(
            state,
            targetWithContentSpan(target, dep.content_start, dep.content_end),
            "math expression",
            error.UnsupportedMathSyntax,
            null,
        );
        return true;
    }
    return false;
}

fn objectCommandDiagnosticTarget(command: *const ObjectCommand) RenderDiagnosticTarget {
    const target = objectDiagnosticTarget(command);
    return switch (command.render.kind) {
        .vector_math, .vector_asset, .raster_asset => targetWithContentSpan(target, 0, command.content.len),
        else => target,
    };
}

fn objectCommandLabel(command: *const ObjectCommand) []const u8 {
    return switch (command.render.kind) {
        .text => "text object",
        .code => "code block",
        .chrome_only => "object chrome",
        .shape => "shape object",
        .vector_math => "math expression",
        .vector_asset => "vector asset",
        .raster_asset => "raster asset",
    };
}

fn profileRenderMeasureKind(kind: RenderKind) utils.measure_profile.RenderMeasureKind {
    return switch (kind) {
        .text => .text,
        .code => .code,
        .vector_math => .vector_math,
        .vector_asset => .vector_asset,
        .raster_asset => .raster_asset,
        .shape => .shape,
        .chrome_only => .chrome_only,
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

fn profilePreloadKind(task: PreloadTask) utils.measure_profile.ArtifactKind {
    return switch (task) {
        .math => .math,
        .icon => .icon,
        .vector_pdf => .vector_pdf,
        .raster => .raster,
    };
}

fn countCachedPreloadTasks(cached: []const bool) usize {
    var count: usize = 0;
    for (cached) |value| {
        if (value) count += 1;
    }
    return count;
}

fn preloadMathTaskBatches(
    ctx: *DrawContext,
    tasks: []const PreloadTask,
    cached: []bool,
    progress: ?Progress,
    completed: *usize,
) !void {
    var groups = std.ArrayList(MathBatchGroup).empty;
    defer {
        for (groups.items) |*group| group.deinit(ctx.allocator);
        groups.deinit(ctx.allocator);
    }

    for (tasks, 0..) |task, index| {
        if (cached[index]) continue;
        const math = switch (task) {
            .math => |value| value,
            else => continue,
        };
        if (math.kind == .raw_block) continue;

        const out = try cachedMathPath(ctx, math.source, math.preamble, math.kind, "ref");
        var out_owned = true;
        errdefer if (out_owned) ctx.allocator.free(out);
        const key = try mathBatchGroupKey(ctx, math.preamble);
        var key_owned = true;
        errdefer if (key_owned) ctx.allocator.free(key);

        var group_index: ?usize = null;
        for (groups.items, 0..) |group, candidate_index| {
            if (std.mem.eql(u8, group.key, key)) {
                group_index = candidate_index;
                break;
            }
        }
        if (group_index) |candidate_index| {
            ctx.allocator.free(key);
            key_owned = false;
            try groups.items[candidate_index].entries.append(ctx.allocator, .{
                .task_index = index,
                .source = math.source,
                .preamble = math.preamble,
                .kind = math.kind,
                .out = out,
            });
            out_owned = false;
        } else {
            try groups.append(ctx.allocator, .{ .key = key });
            key_owned = false;
            try groups.items[groups.items.len - 1].entries.append(ctx.allocator, .{
                .task_index = index,
                .source = math.source,
                .preamble = math.preamble,
                .kind = math.kind,
                .out = out,
            });
            out_owned = false;
        }
    }

    for (groups.items) |group| {
        if (group.entries.items.len == 0) continue;
        const profile_build = utils.measure_profile.start();
        try preloadMathBatchGroup(ctx, group.entries.items, progress, completed, tasks.len);
        utils.measure_profile.recordArtifactBuildMany(.math, group.entries.items.len, profile_build);
        for (group.entries.items) |entry| cached[entry.task_index] = true;
    }
}

fn mathBatchGroupKey(ctx: *DrawContext, preamble: []const TexPreambleEntry) ![]u8 {
    var hasher = std.hash.Wyhash.init(0);
    hashString(&hasher, native_artifact_cache_version);
    hashString(&hasher, "math-batch");
    for (preamble) |entry| {
        hashString(&hasher, @tagName(entry.source));
        hashString(&hasher, entry.value);
    }
    return std.fmt.allocPrint(ctx.allocator, "{x}", .{hasher.final()});
}

fn preloadMathBatchGroup(
    ctx: *DrawContext,
    entries: []const MathBatchEntry,
    progress: ?Progress,
    completed: *usize,
    total: usize,
) !void {
    if (entries.len == 0) return;
    const dir = try tempCachePath(ctx, entries[0].out, "math-batch-dir");
    defer ctx.allocator.free(dir);
    defer std.Io.Dir.cwd().deleteTree(ctx.io, dir) catch {};
    errdefer std.Io.Dir.cwd().deleteTree(ctx.io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(ctx.io, dir);

    const tex_path = try std.fs.path.join(ctx.allocator, &.{ dir, "main.tex" });
    defer ctx.allocator.free(tex_path);
    const pdf_path = try std.fs.path.join(ctx.allocator, &.{ dir, "main.pdf" });
    defer ctx.allocator.free(pdf_path);
    const metrics_path = try std.fs.path.join(ctx.allocator, &.{ dir, "main.ssm" });
    defer ctx.allocator.free(metrics_path);

    const tex = try mathBatchDocumentSource(ctx, entries);
    defer ctx.allocator.free(tex);
    try std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = tex_path, .data = tex, .flags = .{ .truncate = true } });
    try runChecked(ctx, &.{ "pdflatex", "-interaction=nonstopmode", "-halt-on-error", "main.tex" }, .{ .path = dir });
    try publishMathBatch(ctx, entries, pdf_path, metrics_path, progress, completed, total);
}

fn publishMathBatch(
    ctx: *DrawContext,
    entries: []const MathBatchEntry,
    generated_pdf_path: []const u8,
    metrics_path: []const u8,
    progress: ?Progress,
    completed: *usize,
    total: usize,
) !void {
    if (entries.len == 0) return;
    const batch_path = try mathBatchPdfPath(ctx, entries);
    defer ctx.allocator.free(batch_path);
    try publishGeneratedPdf(ctx, generated_pdf_path, batch_path);

    const batch_path_z = try ctx.allocator.dupeZ(u8, batch_path);
    defer ctx.allocator.free(batch_path_z);
    const widths = try ctx.allocator.alloc(f64, entries.len);
    defer ctx.allocator.free(widths);
    const heights = try ctx.allocator.alloc(f64, entries.len);
    defer ctx.allocator.free(heights);
    const baseline_ratios = try readMathBaselineRatios(ctx, metrics_path, entries.len);
    defer ctx.allocator.free(baseline_ratios);
    if (c.ss_qpdf_page_sizes(batch_path_z.ptr, @intFromEnum(core.render_policy.PdfPageBox.crop), widths.ptr, heights.ptr, entries.len) != 0) {
        try recordQpdfFailure(ctx, "read TeX PDF page geometry");
        return NativePdfError.AssetConversionFailed;
    }

    for (entries, 0..) |entry, index| {
        try writeMathReference(ctx, entry.out, batch_path, index, widths[index], heights[index], heights[index] * baseline_ratios[index]);
        completed.* += 1;
        if (progress) |p| p.artifactCompleted(p.context, completed.*, total);
    }
}

fn mathBatchPdfPath(ctx: *DrawContext, entries: []const MathBatchEntry) ![]u8 {
    var hasher = std.hash.Wyhash.init(0);
    hashString(&hasher, native_artifact_cache_version);
    hashString(&hasher, "math-batch-pdf");
    for (entries) |entry| hashString(&hasher, entry.out);
    return std.fmt.allocPrint(ctx.allocator, "{s}/math-batch-{x}.pdf", .{ ctx.cache_dir, hasher.final() });
}

fn publishGeneratedPdf(ctx: *DrawContext, generated_path: []const u8, output: []const u8) !void {
    if (try cachedPdfAvailable(ctx, output)) return;
    const tmp = try tempCachePath(ctx, output, "pdf");
    defer ctx.allocator.free(tmp);
    errdefer deleteFileIfExists(ctx, tmp);
    const cwd = std.Io.Dir.cwd();
    try cwd.rename(generated_path, cwd, tmp, ctx.io);
    try validatePdfFile(ctx, tmp);
    try publishCacheFile(ctx, tmp, output);
}

fn writeMathReference(ctx: *DrawContext, output: []const u8, pdf_path: []const u8, page_index: usize, width: f64, height: f64, baseline_from_bottom: f64) !void {
    const contents = try std.fmt.allocPrint(ctx.allocator, "{d}\t{d}\t{d}\t{d}\t{s}\n", .{ page_index, width, height, baseline_from_bottom, std.fs.path.basename(pdf_path) });
    defer ctx.allocator.free(contents);
    const tmp = try tempCachePath(ctx, output, "ref");
    defer ctx.allocator.free(tmp);
    errdefer deleteFileIfExists(ctx, tmp);
    try std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = tmp, .data = contents, .flags = .{ .truncate = true } });
    try publishCacheFile(ctx, tmp, output);
}

fn executePreloadTaskList(
    ctx: *DrawContext,
    tasks: []const PreloadTask,
    cached: []bool,
    miss_count: usize,
    options: Options,
    progress: ?Progress,
) !void {
    if (tasks.len == 0 or miss_count == 0) return;
    var completed = tasks.len - miss_count;
    try preloadMathTaskBatches(ctx, tasks, cached, progress, &completed);

    const remaining_miss_count = tasks.len - countCachedPreloadTasks(cached);
    if (remaining_miss_count == 0) return;

    const initial_done = tasks.len - remaining_miss_count;
    const worker_count = preloadWorkerCount(tasks.len, remaining_miss_count, options);
    if (worker_count <= 1) return executePreloadTaskListSequential(ctx, tasks, cached, initial_done, progress);

    var work = PreloadWork{
        .plan = tasks,
        .cached = cached,
        .completed = .init(initial_done),
        .io = ctx.io,
        .asset_base_dir = ctx.asset_base_dir,
        .cache_dir = ctx.cache_dir,
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
        threads[started] = try std.Thread.spawn(.{}, preloadTaskWorker, .{&work});
    }

    var last_done: usize = initial_done;
    while (!work.failed.load(.seq_cst) and work.completed.load(.acquire) < tasks.len) {
        const done = work.completed.load(.acquire);
        if (progress) |p| {
            if (done != last_done) {
                p.artifactCompleted(p.context, done, tasks.len);
                last_done = done;
            }
        }
        std.Io.sleep(ctx.io, std.Io.Duration.fromMilliseconds(50), .awake) catch {};
    }

    for (threads[0..started]) |thread| thread.join();
    joined = true;

    if (progress) |p| {
        const done = work.completed.load(.acquire);
        if (done != last_done) p.artifactCompleted(p.context, done, tasks.len);
    }

    if (work.failed.load(.seq_cst)) return NativePdfError.AssetConversionFailed;
}

fn executePreloadTaskListSequential(
    ctx: *DrawContext,
    tasks: []const PreloadTask,
    cached: []const bool,
    initial_done: usize,
    progress: ?Progress,
) !void {
    var done = initial_done;
    for (tasks, 0..) |task, index| {
        if (cached[index]) continue;
        const profile_build = utils.measure_profile.start();
        preloadOne(ctx, task) catch |err| {
            utils.measure_profile.recordArtifactBuild(profilePreloadKind(task), profile_build);
            return err;
        };
        utils.measure_profile.recordArtifactBuild(profilePreloadKind(task), profile_build);
        done += 1;
        if (progress) |p| p.artifactCompleted(p.context, done, tasks.len);
    }
}

fn preloadTaskWorker(work: *PreloadWork) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();

    while (!work.failed.load(.monotonic)) {
        const index = work.next.fetchAdd(1, .monotonic);
        if (index >= work.plan.len) break;
        if (work.cached[index]) continue;
        var ctx = DrawContext{
            .allocator = arena.allocator(),
            .io = work.io,
            .asset_base_dir = work.asset_base_dir,
            .cache_dir = work.cache_dir,
            .highlight_languages = &.{},
        };
        const profile_build = utils.measure_profile.start();
        preloadOne(&ctx, work.plan[index]) catch {
            utils.measure_profile.recordArtifactBuild(profilePreloadKind(work.plan[index]), profile_build);
            work.failed.store(true, .seq_cst);
            break;
        };
        utils.measure_profile.recordArtifactBuild(profilePreloadKind(work.plan[index]), profile_build);
        _ = work.completed.fetchAdd(1, .release);
        _ = arena.reset(.retain_capacity);
    }
}

fn collectPreloadTaskDiagnostics(
    ctx: *DrawContext,
    state: *core.DocumentState,
    tasks: []const PreloadTask,
    cached: []const bool,
) !void {
    for (tasks, 0..) |task, index| {
        if (cached[index]) continue;
        if (preloadTaskCached(ctx, task) catch false) continue;
        var target = CommandFailure{ .allocator = state.allocator };
        defer target.deinit();
        var diagnostic_ctx = ctx.*;
        diagnostic_ctx.command_failure = &target;
        preloadOne(&diagnostic_ctx, task) catch |err| {
            try addPreloadRenderDiagnostic(state, task, err, target.message);
        };
    }
}

fn buildRenderPage(
    parent_ctx: *DrawContext,
    page_id: core.NodeId,
    page_index: usize,
    background: ?Color,
    commands: []ObjectCommand,
    resources: *render_resources.Builder,
    fonts: *render_ir.FontBuilder,
    math: *render_ir.MathBuilder,
) !render_ir.Page {
    var page = render_ir.Page{
        .page_id = page_id,
        .index = page_index,
        .width = Defaults.width,
        .height = Defaults.height,
    };
    errdefer page.deinit(parent_ctx.allocator);

    var ctx = DrawContext{
        .allocator = parent_ctx.allocator,
        .io = parent_ctx.io,
        .asset_base_dir = parent_ctx.asset_base_dir,
        .cache_dir = parent_ctx.cache_dir,
        .highlight_languages = parent_ctx.highlight_languages,
        .command_failure = parent_ctx.command_failure,
        .emitter = .{ .page = &page, .resources = resources, .fonts = fonts, .math = math, .io = parent_ctx.io },
    };

    const page_fill = background orelse Color{ .r = 1, .g = 1, .b = 1 };
    try activeEmitter(&ctx).fillRect(ctx.allocator, .{ .x = 0, .y = 0, .width = Defaults.width, .height = Defaults.height }, page_fill);

    var links = std.ArrayList(LinkAnnotation).empty;
    defer links.deinit(ctx.allocator);
    defer deinitLinkAnnotations(ctx.allocator, links.items);
    var destinations = std.ArrayList(DestinationAnnotation).empty;
    defer destinations.deinit(ctx.allocator);
    defer deinitDestinationAnnotations(ctx.allocator, destinations.items);
    ctx.link_annotations = &links;
    ctx.destinations = &destinations;

    for (commands) |*command| {
        if (command.render.kind == .chrome_only) try drawObjectCommandIntoIr(&ctx, command);
    }
    for (commands) |*command| {
        if (command.render.kind != .chrome_only) try drawObjectCommandIntoIr(&ctx, command);
    }

    for (destinations.items) |destination| {
        try page.appendDestination(ctx.allocator, destination.name, .{ .x = destination.x, .y = destination.y });
    }
    for (links.items) |link| {
        try page.appendLink(
            ctx.allocator,
            if (link.kind == .uri) .uri else .destination,
            link.target,
            .{ .x = link.x, .y = link.y, .width = link.width, .height = link.height },
        );
    }

    return page;
}

fn drawObjectCommandIntoIr(ctx: *DrawContext, command: *const ObjectCommand) !void {
    const emitter = activeEmitter(ctx);
    const previous_node_id = emitter.replaceNodeId(command.node_id);
    defer _ = emitter.replaceNodeId(previous_node_id);
    try drawObjectCommand(ctx, command);
}

fn isPdfAssetOp(command: *const ObjectCommand) bool {
    return command.render.kind == .vector_asset and std.ascii.eqlIgnoreCase(std.fs.path.extension(command.content), ".pdf");
}

fn pdfAssetPlacement(ctx: *DrawContext, command: *const ObjectCommand, source_z: [:0]const u8) !Frame {
    const content_frame = contentFrameForRender(command.frame, command.render);
    const source = std.mem.span(source_z.ptr);
    const size = try pdfAssetSize(ctx, source, command.render.asset, .pdf);
    return naturalAssetFrame(content_frame, scaledAssetSize(size, command.render.asset));
}

fn deinitLinkAnnotations(allocator: Allocator, links: []const LinkAnnotation) void {
    for (links) |link| link.deinit(allocator);
}

fn deinitDestinationAnnotations(allocator: Allocator, destinations: []const DestinationAnnotation) void {
    for (destinations) |destination| destination.deinit(allocator);
}

fn drawObjectCommand(ctx: *DrawContext, command: *const ObjectCommand) !void {
    const previous_preamble = ctx.tex_preamble;
    ctx.tex_preamble = command.tex_preamble;
    defer ctx.tex_preamble = previous_preamble;
    const visual_frame = try measuredObjectCommandVisualFrame(ctx, command);
    try addDestination(ctx, command.link_id, visual_frame);
    try drawObjectChrome(ctx, visual_frame, command.render);
    const content_frame = contentFrameForRender(command.frame, command.render);
    switch (command.render.kind) {
        .text => if (command.render.text) |text| try drawTextCommand(ctx, command, content_frame, text),
        .code => if (command.render.text) |text| {
            var code_text = text;
            code_text.font = text.code_font;
            try drawCodeBlock(ctx, content_frame, command.content, code_text, command.render.code);
        },
        .chrome_only => {},
        .vector_math => try drawVectorMathCommand(ctx, command, content_frame, command.render.math),
        .vector_asset => try drawVectorAsset(ctx, content_frame, command.content, command.render.asset),
        .raster_asset => try drawRasterAsset(ctx, content_frame, command.content, command.render.asset),
        .shape => if (command.render.shape) |shape| try drawShapeOp(ctx, content_frame, shape),
    }
}

fn measuredObjectCommandVisualFrame(ctx: *DrawContext, command: *const ObjectCommand) !Frame {
    if (isPdfAssetOp(command)) {
        const source = try resolveAssetPath(ctx, command.content);
        defer ctx.allocator.free(source);
        const source_z = try ctx.allocator.dupeZ(u8, source);
        defer ctx.allocator.free(source_z);
        const placement = try pdfAssetPlacement(ctx, command, source_z);
        return expandFrameToMeasuredInk(command.frame, command.render, placement);
    }
    switch (command.render.kind) {
        .text => if (command.render.text) |text| {
            const measured = try measureObjectCommandContent(ctx, command, text);
            return expandFrameToMeasuredInk(command.frame, command.render, measured);
        },
        .code => if (command.render.text) |text| {
            var code_text = text;
            code_text.font = text.code_font;
            const measured = try measureObjectCommandContent(ctx, command, code_text);
            return expandFrameToMeasuredInk(command.frame, command.render, measured);
        },
        .vector_math, .vector_asset, .raster_asset => {
            const measured = try measureObjectCommandContent(ctx, command, null);
            return expandFrameToMeasuredInk(command.frame, command.render, measured);
        },
        .shape => return command.frame,
        else => {},
    }
    return command.frame;
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
    previous_emitter: ?render_emitter.Emitter,
    previous_measurement_bounds: ?*MeasurementBounds,
    bounds: MeasurementBounds = .{},
    page: render_ir.Page = .{
        .page_id = 0,
        .index = 0,
        .width = Defaults.width,
        .height = Defaults.height,
    },
    resources: render_resources.Builder = .{},
    fonts: render_ir.FontBuilder = .{},
    math: render_ir.MathBuilder = .{},
    links: std.ArrayList(LinkAnnotation) = .empty,
    destinations: std.ArrayList(DestinationAnnotation) = .empty,

    fn init(ctx: *DrawContext) MeasurementScope {
        return .{
            .ctx = ctx,
            .previous_links = ctx.link_annotations,
            .previous_destinations = ctx.destinations,
            .previous_emitter = ctx.emitter,
            .previous_measurement_bounds = ctx.measurement_bounds,
        };
    }

    fn begin(self: *MeasurementScope) !void {
        const resources = if (self.previous_emitter) |*emitter| emitter.resources else &self.resources;
        const fonts = if (self.previous_emitter) |*emitter| emitter.fonts else &self.fonts;
        const math = if (self.previous_emitter) |*emitter| emitter.math else &self.math;
        self.ctx.emitter = .{
            .page = &self.page,
            .resources = resources,
            .fonts = fonts,
            .math = math,
            .io = self.ctx.io,
            .node_id = if (self.previous_emitter) |emitter| emitter.node_id else null,
        };
        self.ctx.link_annotations = &self.links;
        self.ctx.destinations = &self.destinations;
        self.ctx.measurement_bounds = &self.bounds;
    }

    fn inkFrame(self: *MeasurementScope) !?Frame {
        const ink = self.bounds.ink orelse return null;
        return .{
            .x = @floatCast(ink.x),
            .y = @floatCast(Defaults.height - ink.y - ink.height),
            .width = @floatCast(ink.width),
            .height = @floatCast(ink.height),
        };
    }

    fn deinit(self: *MeasurementScope) void {
        self.ctx.link_annotations = self.previous_links;
        self.ctx.destinations = self.previous_destinations;
        self.ctx.emitter = self.previous_emitter;
        self.ctx.measurement_bounds = self.previous_measurement_bounds;
        deinitLinkAnnotations(self.ctx.allocator, self.links.items);
        self.links.deinit(self.ctx.allocator);
        deinitDestinationAnnotations(self.ctx.allocator, self.destinations.items);
        self.destinations.deinit(self.ctx.allocator);
        self.page.deinit(self.ctx.allocator);
        self.resources.deinit(self.ctx.allocator);
        self.fonts.deinit(self.ctx.allocator);
        self.math.deinit(self.ctx.allocator);
    }
};

fn measureObjectCommandContent(ctx: *DrawContext, command: *const ObjectCommand, maybe_text: ?TextPaint) !?Frame {
    var measurement = MeasurementScope.init(ctx);
    try measurement.begin();
    defer measurement.deinit();

    const content_frame = contentFrameForRender(command.frame, command.render);
    switch (command.render.kind) {
        .text => if (maybe_text) |text| try drawTextCommand(ctx, command, content_frame, text),
        .code => if (maybe_text) |text| try drawCodeBlock(ctx, content_frame, command.content, text, command.render.code),
        .vector_math => try drawVectorMathCommand(ctx, command, content_frame, command.render.math),
        .vector_asset => try drawVectorAsset(ctx, content_frame, command.content, command.render.asset),
        .raster_asset => try drawRasterAsset(ctx, content_frame, command.content, command.render.asset),
        .shape => if (command.render.shape) |shape| try drawShapeOp(ctx, content_frame, shape),
        else => return null,
    }
    return try measurement.inkFrame();
}

fn measureObjectCommandIntrinsic(ctx: *DrawContext, command: *const ObjectCommand, outer_width: f32, mode: core.LayoutMeasurementMode) !?core.LayoutMeasurement {
    const previous_preamble = ctx.tex_preamble;
    ctx.tex_preamble = command.tex_preamble;
    defer ctx.tex_preamble = previous_preamble;
    var render = command.render;
    if (mode == .natural) {
        if (render.text) |*text| text.wrap = false;
    }
    if (render.kind == .shape or render.kind == .chrome_only) {
        const frame_width: f32 = if (mode == .natural) 1 else @max(outer_width, 1);
        return try measureFrameIntrinsic(ctx, command, Frame{ .x = 0, .y = 0, .width = frame_width, .height = 1 });
    }
    const frame = Frame{ .x = 0, .y = 0, .width = @max(outer_width, 1), .height = @max(command.frame.height, 1) };
    const content_frame = contentFrameForRender(frame, render);
    const content_measure = switch (render.kind) {
        .text => if (render.text) |text|
            try measureTextIntrinsic(ctx, command, content_frame.width, text, mode)
        else
            return null,
        .code => if (render.text) |text| blk: {
            var code_text = text;
            code_text.font = text.code_font;
            break :blk try measureCodeIntrinsic(ctx, command, content_frame.width, code_text);
        } else return null,
        .vector_math => try measureVectorMathIntrinsic(ctx, command, content_frame.width, content_frame.height),
        .vector_asset, .raster_asset => try measureAssetIntrinsic(ctx, command, content_frame.width),
        .shape, .chrome_only => unreachable,
    };
    return expandContentMeasurement(render, content_measure);
}

fn measureFrameIntrinsic(ctx: *DrawContext, command: *const ObjectCommand, frame: Frame) !core.LayoutMeasurement {
    var measurement = MeasurementScope.init(ctx);
    try measurement.begin();
    defer measurement.deinit();

    try drawObjectChrome(ctx, frame, command.render);
    const content_frame = contentFrameForRender(frame, command.render);
    switch (command.render.kind) {
        .shape => if (command.render.shape) |shape| try drawShapeOp(ctx, content_frame, shape),
        .chrome_only => {},
        else => unreachable,
    }
    if (try measurement.inkFrame()) |ink| {
        return .{ .width = @max(ink.width, frame.width), .height = @max(ink.height, frame.height) };
    }
    return .{ .width = frame.width, .height = frame.height };
}

fn expandContentMeasurement(render: ResolvedRender, content: core.LayoutMeasurement) core.LayoutMeasurement {
    return .{
        .width = @max(content.width + render.chrome.pad_x * 2, 1),
        .height = @max(content.height + render.chrome.pad_y * 2, 1),
    };
}

fn measureTextIntrinsic(ctx: *DrawContext, command: *const ObjectCommand, width: f32, text: TextPaint, mode: core.LayoutMeasurementMode) !core.LayoutMeasurement {
    const baseline_bl = Defaults.height * 0.5;
    return switch (command.parse_mode) {
        .none => .{ .width = 1, .height = 1 },
        .block => blk: {
            var owned_doc: ?MarkdownDocument = null;
            defer if (owned_doc) |*doc| doc.deinit();
            const doc = command.markdown_doc orelse blk2: {
                owned_doc = try core.markdown.parseMarkdownContent(ctx.allocator, command.content);
                break :blk2 &owned_doc.?;
            };
            var measurement = MeasurementScope.init(ctx);
            try measurement.begin();
            defer measurement.deinit();
            const frame = Frame{ .x = 0, .y = 0, .width = @max(width, 1), .height = Defaults.height };
            const first_text = markdownFirstBlockText(text, doc.blocks.items);
            const next_bl = try drawMarkdownBlocksAt(ctx, frame, baseline_bl, doc.blocks.items, text, 0);
            var measured = try measurementFromInk(
                &measurement,
                baseline_bl,
                next_bl,
                try lineBaselineFromTop(ctx, first_text.font, first_text.font_size, first_text.line_height),
                first_text.line_height,
            );
            if (mode == .natural) {
                if (try markdownBlocksNaturalInlineAdvance(ctx, doc.blocks.items, text, 0)) |natural_width| {
                    measured.width = @max(measured.width, natural_width, 1);
                }
            } else {
                measured.width = @max(try markdownBlocksConstrainedLogicalWidth(ctx, doc.blocks.items, text, 0, width), 1);
            }
            break :blk measured;
        },
        .@"inline" => blk: {
            var owned_layout: ?core.markdown.TextLayout = null;
            defer if (owned_layout) |*layout| layout.deinit(ctx.allocator);
            const layout = command.text_layout orelse blk2: {
                owned_layout = try core.markdown.parseTextLayoutContent(ctx.allocator, command.content);
                break :blk2 &owned_layout.?;
            };
            var inline_text = text;
            if (mode == .natural) inline_text.wrap = false;
            var measurement = MeasurementScope.init(ctx);
            try measurement.begin();
            defer measurement.deinit();
            const next_bl = try drawInlineLines(ctx, 0, baseline_bl, @max(width, 1), layout.lines.items, inline_text, inline_text.wrap);
            var measured = try measurementFromInk(
                &measurement,
                baseline_bl,
                next_bl,
                try lineBaselineFromTop(ctx, inline_text.font, inline_text.font_size, inline_text.line_height),
                inline_text.line_height,
            );
            if (mode == .natural) {
                if (try inlineLinesNaturalAdvance(ctx, layout.lines.items, inline_text)) |natural_width| {
                    measured.width = @max(measured.width, natural_width, 1);
                }
            } else {
                measured.width = @max(try inlineLinesConstrainedLogicalWidth(ctx, layout.lines.items, inline_text, width, inline_text.wrap), 1);
            }
            break :blk measured;
        },
    };
}

fn measureCodeIntrinsic(ctx: *DrawContext, command: *const ObjectCommand, width: f32, text: TextPaint) !core.LayoutMeasurement {
    var measurement = MeasurementScope.init(ctx);
    try measurement.begin();
    defer measurement.deinit();
    const frame = Frame{ .x = 0, .y = 0, .width = @max(width, 1), .height = Defaults.height };
    try drawCodeBlock(ctx, frame, command.content, text, command.render.code);
    if (try measurement.inkFrame()) |ink| {
        return .{ .width = @max(ink.width, 1), .height = @max(ink.height, text.line_height) };
    }
    return .{ .width = 1, .height = text.line_height };
}

fn measureVectorMathIntrinsic(ctx: *DrawContext, command: *const ObjectCommand, width: f32, height: f32) !core.LayoutMeasurement {
    if (command.math_kind != .raw_block) {
        var resources = render_resources.Builder{};
        defer resources.deinit(ctx.allocator);
        var fonts = render_ir.FontBuilder{};
        defer fonts.deinit(ctx.allocator);
        var math = render_ir.MathBuilder{};
        defer math.deinit(ctx.allocator);
        var compiled = try render_math.compile(
            ctx.allocator,
            ctx.io,
            &resources,
            &fonts,
            &math,
            command.content,
            mathInputKind(command.math_kind),
            .{ .font_size = structured_math_design_size, .display = command.math_kind != .inline_math },
        );
        defer compiled.layout.deinit(ctx.allocator);
        const fitted = fitVectorMathSize(
            @floatCast(compiled.layout.width),
            @floatCast(compiled.layout.height),
            @max(width, 1),
            @max(height, 1),
            command.math_kind,
            command.render.math,
        );
        return .{ .width = @max(fitted.width, 1), .height = @max(fitted.height, 1) };
    }
    const math = try renderMathToPdf(ctx, command.content, command.tex_preamble, command.math_kind);
    defer ctx.allocator.free(math.path);
    const fitted = fitVectorMathSize(math.width, math.height, @max(width, 1), @max(height, 1), command.math_kind, command.render.math);
    return .{ .width = @max(fitted.width, 1), .height = @max(fitted.height, 1) };
}

fn measureAssetIntrinsic(ctx: *DrawContext, command: *const ObjectCommand, width: f32) !core.LayoutMeasurement {
    const source = try resolveAssetPath(ctx, command.content);
    defer ctx.allocator.free(source);
    const extension = std.fs.path.extension(source);
    var natural: Size = undefined;
    if (std.ascii.eqlIgnoreCase(extension, ".pdf")) {
        natural = try pdfAssetSize(ctx, source, command.render.asset, .pdf);
    } else if (std.ascii.eqlIgnoreCase(extension, ".svg")) {
        const svg = try svgAsset(ctx, source);
        natural = .{ .width = svg.width, .height = svg.height };
    } else {
        _ = width;
        natural = try rasterAssetSize(ctx, source);
    }
    const scaled = scaledAssetSize(natural, command.render.asset);
    return .{ .width = @max(scaled.width, 1), .height = @max(scaled.height, 1) };
}

fn measurementFromInk(measurement: *MeasurementScope, baseline_bl: f32, next_bl: f32, baseline_from_top: f32, line_height: f32) !core.LayoutMeasurement {
    const content_top_bl = baseline_bl + baseline_from_top;
    var left: f32 = 0;
    var right: f32 = 1;
    var top_overhang: f32 = 0;
    var bottom_depth = @max(baseline_bl - next_bl, line_height);
    if (try measurement.inkFrame()) |ink| {
        left = @min(left, ink.x);
        right = @max(right, ink.x + ink.width);
        top_overhang = @max(@as(f32, 0), ink.y + ink.height - content_top_bl);
        bottom_depth = @max(bottom_depth, content_top_bl - ink.y);
    }
    return .{
        .width = @max(right - left, 1),
        .height = @max(top_overhang + bottom_depth, line_height),
    };
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
        .math => |math| cachedMathPath(ctx, math.source, math.preamble, math.kind, "ref"),
        .icon => |icon| cachedIconPath(ctx, icon.source, "svg"),
        .vector_pdf => |asset| ctx.allocator.dupe(u8, asset.source),
        .raster => |raster| ctx.allocator.dupe(u8, raster.source),
    };
}

fn preloadTaskPresent(ctx: *DrawContext, task: PreloadTask) !bool {
    switch (task) {
        .math => |math| {
            const out = try cachedMathPath(ctx, math.source, math.preamble, math.kind, "ref");
            defer ctx.allocator.free(out);
            const asset = try cachedMathReference(ctx, out) orelse return false;
            ctx.allocator.free(asset.path);
            return true;
        },
        .icon => |icon| {
            const out = try cachedIconPath(ctx, icon.source, "svg");
            defer ctx.allocator.free(out);
            return fileExists(out);
        },
        .vector_pdf => return false,
        .raster => return false,
    }
}

fn preloadTaskCached(ctx: *DrawContext, task: PreloadTask) !bool {
    switch (task) {
        .math => |math| {
            const out = try cachedMathPath(ctx, math.source, math.preamble, math.kind, "ref");
            defer ctx.allocator.free(out);
            const asset = try cachedMathReference(ctx, out) orelse return false;
            ctx.allocator.free(asset.path);
            return true;
        },
        .icon => |icon| {
            const out = try cachedIconPath(ctx, icon.source, "svg");
            defer ctx.allocator.free(out);
            return (try cachedSvgAsset(ctx, out)) != null;
        },
        .vector_pdf => return false,
        .raster => return false,
    }
}

fn preloadOne(ctx: *DrawContext, task: PreloadTask) !void {
    switch (task) {
        .math => |math| {
            const asset = try renderMathToPdf(ctx, math.source, math.preamble, math.kind);
            ctx.allocator.free(asset.path);
        },
        .icon => |icon| {
            const svg = try renderIconToSvg(ctx, icon.source);
            ctx.allocator.free(svg.path);
        },
        .vector_pdf => |asset| _ = try pdfAssetSize(ctx, asset.source, null, .pdf),
        .raster => |raster| _ = try rasterAssetSize(ctx, raster.source),
    }
}

fn preloadWorkerCount(task_count: usize, missing_artifacts: usize, options: Options) usize {
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

fn configuredWorkerCount(task_count: usize, options: Options) ?usize {
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
    const destinations = ctx.destinations orelse return error.MissingRenderAnnotationSink;
    const owned_name = try ctx.allocator.dupe(u8, link_id);
    errdefer ctx.allocator.free(owned_name);
    try destinations.append(ctx.allocator, .{
        .name = owned_name,
        .x = x,
        .y = y,
    });
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

fn drawShapeOp(ctx: *DrawContext, frame: Frame, shape: ShapePaint) !void {
    const stroke = shape.stroke orelse return;
    if (shape.line_width <= 0) return;

    const x1 = frame.x + frame.width * shape.start_x;
    const y1 = toTopY(frame.y + frame.height * shape.start_y);
    const x2 = frame.x + frame.width * shape.end_x;
    const y2 = toTopY(frame.y + frame.height * shape.end_y);
    const dash_on = if (shape.dash) |dash| dash.on else 0;
    const dash_off = if (shape.dash) |dash| dash.off else 0;

    try strokeLine(ctx, x1, y1, x2, y2, shape.line_width, stroke, dash_on, dash_off);
    if (shape.marker_start == .arrow) {
        try drawArrowHead(ctx, x1, y1, x1 - x2, y1 - y2, shape.line_width, stroke, shape.marker_size);
    }
    if (shape.marker_end == .arrow) {
        try drawArrowHead(ctx, x2, y2, x2 - x1, y2 - y1, shape.line_width, stroke, shape.marker_size);
    }
}

fn drawArrowHead(ctx: *DrawContext, tip_x: f32, tip_y: f32, dir_x: f32, dir_y: f32, line_width: f32, color: Color, marker_size: f32) !void {
    const length = @sqrt(dir_x * dir_x + dir_y * dir_y);
    if (length <= 0.001) return;

    const size = @max(marker_size, line_width * 3.0);
    const ux = dir_x / length;
    const uy = dir_y / length;
    const px = -uy;
    const py = ux;
    const wing = size * 0.42;
    const base_x = tip_x - ux * size;
    const base_y = tip_y - uy * size;

    try strokeLine(ctx, tip_x, tip_y, base_x + px * wing, base_y + py * wing, line_width, color, 0, 0);
    try strokeLine(ctx, tip_x, tip_y, base_x - px * wing, base_y - py * wing, line_width, color, 0, 0);
}

fn strokeLine(ctx: *DrawContext, x1: f32, y1: f32, x2: f32, y2: f32, line_width: f32, color: Color, dash_on: f32, dash_off: f32) !void {
    if (ctx.measurement_bounds) |bounds| {
        const dx = x2 - x1;
        const dy = y2 - y1;
        const length = @sqrt(dx * dx + dy * dy);
        const half_width = @max(line_width / 2, 0);
        const x_padding = if (length > 0) half_width * @abs(dy) / length else 0;
        const y_padding = if (length > 0) half_width * @abs(dx) / length else 0;
        bounds.include(.{
            .x = @min(x1, x2) - x_padding,
            .y = @min(y1, y2) - y_padding,
            .width = @abs(dx) + x_padding * 2,
            .height = @abs(dy) + y_padding * 2,
        });
        return;
    }
    try activeEmitter(ctx).strokeLine(ctx.allocator, .{ .x = x1, .y = y1 }, .{ .x = x2, .y = y2 }, line_width, color, dash_on, dash_off);
}

fn drawObjectChrome(ctx: *DrawContext, frame: Frame, render: ResolvedRender) !void {
    if (render.rule.stroke) |stroke| {
        const line_width = render.rule.line_width;
        const y = toTopY(frame.y + @max(frame.height / 2.0, 1.5));
        const dash = render.rule.dash;
        try strokeLine(ctx, frame.x, y, frame.x + frame.width, y, line_width, stroke, if (dash) |d| d.on else 0, if (dash) |d| d.off else 0);
    }

    if (render.chrome.fill != null or render.chrome.stroke != null) {
        const fill = render.chrome.fill;
        const stroke = render.chrome.stroke;
        if (fill) |value| {
            try drawRoundedRect(ctx, frame, render.chrome.radius, value, null, 0);
        }
        if (stroke) |value| {
            if (render.chrome.line_width > 0) {
                const stroke_frame = insetUniformFrame(frame, render.chrome.line_width / 2.0);
                const stroke_radius = @max(render.chrome.radius - render.chrome.line_width / 2.0, 0);
                try drawRoundedRect(ctx, stroke_frame, stroke_radius, null, value, render.chrome.line_width);
            }
        }
    }

    if (render.underline.color) |color| {
        const y = toTopY(frame.y + render.underline.offset);
        try strokeLine(ctx, frame.x, y, frame.x + frame.width, y, render.underline.width, color, 0, 0);
    }
}

fn drawRoundedRect(ctx: *DrawContext, frame: Frame, radius: f32, fill: ?Color, stroke: ?Color, line_width: f32) !void {
    if (ctx.measurement_bounds) |bounds| {
        const half_width = if (stroke != null) @max(line_width / 2, 0) else 0;
        bounds.include(.{
            .x = frame.x - half_width,
            .y = topOf(frame) - half_width,
            .width = frame.width + half_width * 2,
            .height = frame.height + half_width * 2,
        });
        return;
    }
    try activeEmitter(ctx).roundedRect(
        ctx.allocator,
        .{ .x = frame.x, .y = topOf(frame), .width = frame.width, .height = frame.height },
        radius,
        fill,
        stroke,
        line_width,
    );
}

fn insetUniformFrame(frame: Frame, inset: f32) Frame {
    const x_inset = @min(inset, frame.width / 2.0);
    const y_inset = @min(inset, frame.height / 2.0);
    return .{
        .x = frame.x + x_inset,
        .y = frame.y + y_inset,
        .width = @max(frame.width - x_inset * 2.0, 0),
        .height = @max(frame.height - y_inset * 2.0, 0),
    };
}

fn drawTextCommand(ctx: *DrawContext, command: *const ObjectCommand, frame: Frame, text: TextPaint) !void {
    switch (command.parse_mode) {
        .none => return,
        .block => {
            var owned_doc: ?MarkdownDocument = null;
            defer if (owned_doc) |*doc| doc.deinit();
            const doc = command.markdown_doc orelse blk: {
                owned_doc = try core.markdown.parseMarkdownContent(ctx.allocator, command.content);
                break :blk &owned_doc.?;
            };
            _ = try drawMarkdownBlocks(ctx, frame, doc.blocks.items, text, 0);
        },
        .@"inline" => {
            var owned_layout: ?core.markdown.TextLayout = null;
            defer if (owned_layout) |*layout| layout.deinit(ctx.allocator);
            const layout = command.text_layout orelse blk: {
                owned_layout = try core.markdown.parseTextLayoutContent(ctx.allocator, command.content);
                break :blk &owned_layout.?;
            };
            const baseline = try baselineBlForBox(ctx, frame, text.font, text.font_size, text.line_height);
            _ = try drawInlineLines(ctx, frame.x, baseline, frame.width, layout.lines.items, text, text.wrap);
        },
    }
}

fn drawMarkdownBlocks(ctx: *DrawContext, frame: Frame, blocks: []const *Block, text: TextPaint, list_depth: usize) anyerror!f32 {
    const first_text = markdownFirstBlockText(text, blocks);
    return drawMarkdownBlocksAt(
        ctx,
        frame,
        try baselineBlForBox(ctx, frame, first_text.font, first_text.font_size, first_text.line_height),
        blocks,
        text,
        list_depth,
    );
}

fn drawMarkdownBlocksAt(ctx: *DrawContext, frame: Frame, baseline_bl: f32, blocks: []const *Block, text: TextPaint, list_depth: usize) anyerror!f32 {
    var cursor_bl = baseline_bl;
    for (blocks, 0..) |block, index| {
        const block_text = markdownBlockText(text, block);
        switch (block.kind) {
            .paragraph, .heading => {
                if (block.paragraph) |paragraph| {
                    cursor_bl = try drawInlineLines(ctx, frame.x, cursor_bl, frame.width, paragraph.lines.items, block_text, block_text.wrap);
                }
            },
            .code_block => cursor_bl = try drawMarkdownCodeBlock(ctx, frame.x, cursor_bl, frame.width, block, text),
            .bullet_list, .ordered_list => cursor_bl = try drawList(ctx, frame, cursor_bl, block, text, list_depth),
            .table => cursor_bl = try drawTable(ctx, frame.x, cursor_bl, frame.width, block, text),
        }
        if (index + 1 < blocks.len) cursor_bl -= text.markdown_block_gap;
    }
    return cursor_bl;
}

fn markdownFirstBlockText(text: TextPaint, blocks: []const *Block) TextPaint {
    if (blocks.len == 0) return text;
    return markdownBlockText(text, blocks[0]);
}

fn markdownBlockText(text: TextPaint, block: *const Block) TextPaint {
    if (block.kind != .heading) return text;
    return text.forMarkdownHeading(block.heading_level orelse 2);
}

fn drawList(ctx: *DrawContext, frame: Frame, baseline_bl: f32, block: *const Block, text: TextPaint, list_depth: usize) anyerror!f32 {
    const list = block.list orelse return baseline_bl;
    var cursor_bl = baseline_bl;
    const list_inset: f32 = if (list_depth == 0) @max(text.markdown_list_inset, 0) else @max(text.markdown_list_indent, 0);
    const item_x = frame.x + list_inset;
    const item_width = @max(frame.width - list_inset, 1);
    for (list.items.items, 0..) |item, item_index| {
        const marker = try listMarker(ctx.allocator, block.kind, list_depth, list.start + item_index);
        defer ctx.allocator.free(marker);
        try drawRawText(ctx, item_x, baselineTop(cursor_bl, text.font_size), item_width, marker, text.font, text.font_size, text.color, false, .{});
        const marker_width = try measureText(ctx, marker, text.font, text.font_size);
        const content_x = item_x + marker_width + @max(@as(f32, 8.0), text.font_size * 0.35);
        const content_frame = Frame{
            .x = content_x,
            .y = frame.y,
            .width = @max(item_width - marker_width - @max(@as(f32, 8.0), text.font_size * 0.35), 1),
            .height = frame.height,
        };
        cursor_bl = try drawMarkdownBlocksAt(ctx, content_frame, cursor_bl, item.blocks.items, text, list_depth + 1);
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
    const placement = markdownCodeBlockPlacement(x, baseline_bl, width, measured, text, try lineBaselineFromTop(ctx, text.font, text.font_size, text.line_height));
    const frame = placement.frame;

    try drawRoundedRect(ctx, frame, text.markdown_code_radius, text.markdown_code_fill, text.markdown_code_stroke, text.markdown_code_line_width);

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
    var physical = utils.source.lineIterator(source);
    while (physical.next()) |line| {
        const segment = line.text(source);
        if (segment.len == 0 and line.raw_end == source.len and source.len > 0 and source[source.len - 1] == '\n') break;
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
    const baseline_bl = Defaults.height * 0.5;
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
    const baseline_from_top = try lineBaselineFromTop(ctx, text.code_font, text.markdown_code_font_size, text.markdown_code_line_height);
    const default_height = @max(line_count * text.markdown_code_line_height, baseline_from_top);
    return .{
        .left = 0,
        .right = 1,
        .top_over_baseline = baseline_from_top,
        .bottom_under_baseline = @max(default_height - baseline_from_top, 0),
    };
}

fn physicalCodeLineCount(source: []const u8) usize {
    if (source.len == 0) return 1;
    var count = utils.source.lineCount(source);
    if (source[source.len - 1] == '\n' and count > 1) count -= 1;
    return count;
}

fn markdownCodeBlockPlacement(x: f32, baseline_bl: f32, width: f32, measured: MarkdownCodeBlockMeasure, text: TextPaint, baseline_from_top: f32) MarkdownCodeBlockPlacement {
    const box_top = baseline_bl + baseline_from_top;
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
        .next_baseline_bl = box_bottom - baseline_from_top,
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

fn drawTable(ctx: *DrawContext, x: f32, baseline_bl: f32, width: f32, block: *const Block, text: TextPaint) !f32 {
    const table = block.table orelse return baseline_bl;
    const columns = core.markdown.tableColumnCount(table);
    const border_width = if (text.markdown_table_border != null and text.markdown_table_line_width > 0) text.markdown_table_line_width else 0;
    const stroke_inset = border_width * 0.5;
    const table_x = x + stroke_inset;
    const table_width = @max(width - border_width, 1);
    const column_width = table_width / @as(f32, @floatFromInt(columns));
    const baseline_from_top = try lineBaselineFromTop(ctx, text.font, text.font_size, text.line_height);
    var cursor_top_bl = baseline_bl + baseline_from_top - stroke_inset;
    var body_row_index: usize = 0;

    for (table.rows.items) |row| {
        const content_width = @max(column_width - text.markdown_table_cell_pad_x * 2, 1);
        var row_top_overhang: f32 = 0;
        var row_bottom_depth: f32 = text.line_height;
        for (row.cells.items) |cell| {
            var cell_text = text;
            cell_text.font = if (row.header) text.bold_font else text.font;
            const measured = try measureInlineLinesInkBlock(ctx, cell.lines.items, cell_text, content_width);
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
            const cell_x = table_x + @as(f32, @floatFromInt(column_index)) * column_width;
            const cell_frame = Frame{ .x = cell_x, .y = row_bottom, .width = column_width, .height = row_height };
            try drawRoundedRect(ctx, cell_frame, 0, fill, text.markdown_table_border, text.markdown_table_line_width);

            if (column_index < row.cells.items.len) {
                const cell = row.cells.items[column_index];
                var cell_text = text;
                cell_text.font = if (row.header) text.bold_font else text.font;
                var line_bl = cursor_top_bl - text.markdown_table_cell_pad_y - row_top_overhang - baseline_from_top;
                for (cell.lines.items) |line| {
                    const one_line = [_]Line{line};
                    line_bl = try drawInlineLinesAligned(
                        ctx,
                        cell_x + text.markdown_table_cell_pad_x,
                        line_bl,
                        content_width,
                        one_line[0..],
                        cell_text,
                        true,
                        tableCellHorizontalAlign(cell.alignment),
                    );
                }
            }
        }
        cursor_top_bl = row_bottom;
    }
    return cursor_top_bl - baseline_from_top;
}

fn tableCellHorizontalAlign(alignment: core.markdown.Align) HorizontalAlign {
    return switch (alignment) {
        .default, .left => .left,
        .center => .center,
        .right => .right,
    };
}

fn drawInlineLines(ctx: *DrawContext, x: f32, baseline_bl: f32, width: f32, lines: []const Line, text: TextPaint, wrap: bool) !f32 {
    var cursor_bl = baseline_bl;
    for (lines) |line| {
        if (lineContainsDisplayMath(line)) {
            cursor_bl = try drawLineWithDisplayMath(ctx, x, cursor_bl, width, line, text, wrap);
            continue;
        }
        var atoms = std.ArrayList(Atom).empty;
        defer atoms.deinit(ctx.allocator);
        defer freeAtoms(ctx.allocator, atoms.items);
        try layoutAtoms(ctx, line, text, &atoms);
        cursor_bl = try drawAtoms(ctx, x, cursor_bl, width, atoms.items, atomPaint(text), wrap);
    }
    if (lines.len == 0) cursor_bl -= text.line_height;
    return cursor_bl;
}

fn drawInlineLinesAligned(ctx: *DrawContext, x: f32, baseline_bl: f32, width: f32, lines: []const Line, text: TextPaint, wrap: bool, horizontal_align: HorizontalAlign) !f32 {
    var cursor_bl = baseline_bl;
    for (lines) |line| {
        if (lineContainsDisplayMath(line)) {
            cursor_bl = try drawLineWithDisplayMathAligned(ctx, x, cursor_bl, width, line, text, wrap, horizontal_align);
            continue;
        }
        var atoms = std.ArrayList(Atom).empty;
        defer atoms.deinit(ctx.allocator);
        defer freeAtoms(ctx.allocator, atoms.items);
        try layoutAtoms(ctx, line, text, &atoms);
        cursor_bl = try drawAtomsAligned(ctx, x, cursor_bl, width, atoms.items, atomPaint(text), wrap, horizontal_align);
    }
    if (lines.len == 0) cursor_bl -= text.line_height;
    return cursor_bl;
}

fn markdownBlocksNaturalInlineAdvance(ctx: *DrawContext, blocks: []const *Block, text: TextPaint, list_depth: usize) !?f32 {
    var max_width: f32 = 0;
    var found = false;
    for (blocks) |block| {
        switch (block.kind) {
            .paragraph, .heading => {
                if (block.paragraph) |paragraph| {
                    if (try inlineLinesNaturalAdvance(ctx, paragraph.lines.items, markdownBlockText(text, block))) |width| {
                        max_width = @max(max_width, width);
                        found = true;
                    }
                }
            },
            .bullet_list, .ordered_list => {
                const list = block.list orelse continue;
                const list_inset: f32 = if (list_depth == 0) @max(text.markdown_list_inset, 0) else @max(text.markdown_list_indent, 0);
                for (list.items.items, 0..) |item, item_index| {
                    const marker = try listMarker(ctx.allocator, block.kind, list_depth, list.start + item_index);
                    defer ctx.allocator.free(marker);
                    const marker_width = try measureText(ctx, marker, text.font, text.font_size);
                    const marker_gap = @max(@as(f32, 8.0), text.font_size * 0.35);
                    const content_width = (try markdownBlocksNaturalInlineAdvance(ctx, item.blocks.items, text, list_depth + 1)) orelse 0;
                    max_width = @max(max_width, list_inset + marker_width + marker_gap + content_width);
                    found = true;
                }
            },
            .code_block, .table => {},
        }
    }
    if (!found) return null;
    return max_width;
}

fn inlineLinesNaturalAdvance(ctx: *DrawContext, lines: []const Line, text: TextPaint) !?f32 {
    var max_width: f32 = 0;
    var found = false;
    for (lines) |line| {
        if (lineContainsDisplayMath(line)) continue;
        var atoms = std.ArrayList(Atom).empty;
        defer atoms.deinit(ctx.allocator);
        defer freeAtoms(ctx.allocator, atoms.items);
        try layoutAtoms(ctx, line, text, &atoms);
        max_width = @max(max_width, atomLineAdvance(atoms.items, atomPaint(text)));
        found = true;
    }
    if (!found) return null;
    return max_width;
}

fn markdownBlocksConstrainedLogicalWidth(ctx: *DrawContext, blocks: []const *Block, text: TextPaint, list_depth: usize, width: f32) anyerror!f32 {
    var max_width: f32 = 0;
    for (blocks) |block| {
        const block_width = switch (block.kind) {
            .paragraph, .heading => blk: {
                const paragraph = block.paragraph orelse break :blk 0;
                const block_text = markdownBlockText(text, block);
                break :blk try inlineLinesConstrainedLogicalWidth(ctx, paragraph.lines.items, block_text, width, block_text.wrap);
            },
            .code_block => try markdownCodeBlockConstrainedLogicalWidth(ctx, block, text, width),
            .bullet_list, .ordered_list => try markdownListConstrainedLogicalWidth(ctx, block, text, list_depth, width),
            .table => try markdownTableConstrainedLogicalWidth(ctx, block, text, width),
        };
        max_width = @max(max_width, block_width);
    }
    return max_width;
}

fn markdownListConstrainedLogicalWidth(ctx: *DrawContext, block: *const Block, text: TextPaint, list_depth: usize, width: f32) anyerror!f32 {
    const list = block.list orelse return 0;
    const list_inset: f32 = if (list_depth == 0) @max(text.markdown_list_inset, 0) else @max(text.markdown_list_indent, 0);
    const item_width = @max(width - list_inset, 1);
    var max_width: f32 = 0;
    for (list.items.items, 0..) |item, item_index| {
        const marker = try listMarker(ctx.allocator, block.kind, list_depth, list.start + item_index);
        defer ctx.allocator.free(marker);
        const marker_width = try measureText(ctx, marker, text.font, text.font_size);
        const marker_gap = @max(@as(f32, 8.0), text.font_size * 0.35);
        const content_width = @max(item_width - marker_width - marker_gap, 1);
        const item_content_width = try markdownBlocksConstrainedLogicalWidth(ctx, item.blocks.items, text, list_depth + 1, content_width);
        max_width = @max(max_width, list_inset + marker_width + marker_gap + item_content_width);
    }
    return max_width;
}

fn markdownCodeBlockConstrainedLogicalWidth(ctx: *DrawContext, block: *const Block, text: TextPaint, width: f32) !f32 {
    const source_text = try markdownCodeBlockContent(ctx.allocator, block);
    defer ctx.allocator.free(source_text);
    const code_paint = markdownCodeBlockPaint(block, text);
    const content_width = @max(width - text.markdown_code_pad_x * 2, 1);
    const measured = try measureMarkdownCodeBlockContent(ctx, source_text, content_width, text, code_paint);
    const placement = markdownCodeBlockPlacement(
        0,
        Defaults.height * 0.5,
        width,
        measured,
        text,
        try lineBaselineFromTop(ctx, text.font, text.font_size, text.line_height),
    );
    return placement.frame.width;
}

fn markdownTableConstrainedLogicalWidth(ctx: *DrawContext, block: *const Block, text: TextPaint, width: f32) !f32 {
    const table = block.table orelse return 0;
    const columns = core.markdown.tableColumnCount(table);
    const border_width = if (text.markdown_table_border != null and text.markdown_table_line_width > 0) text.markdown_table_line_width else 0;
    const table_width = @max(width - border_width, 1);
    const column_width = table_width / @as(f32, @floatFromInt(columns));
    const content_width = @max(column_width - text.markdown_table_cell_pad_x * 2, 1);
    var required_column_width = column_width;
    for (table.rows.items) |row| {
        for (row.cells.items) |cell| {
            var cell_text = text;
            cell_text.font = if (row.header) text.bold_font else text.font;
            const cell_content_width = try inlineLinesConstrainedLogicalWidth(ctx, cell.lines.items, cell_text, content_width, true);
            required_column_width = @max(required_column_width, cell_content_width + text.markdown_table_cell_pad_x * 2);
        }
    }
    return required_column_width * @as(f32, @floatFromInt(columns)) + border_width;
}

fn inlineLinesConstrainedLogicalWidth(ctx: *DrawContext, lines: []const Line, text: TextPaint, width: f32, wrap: bool) !f32 {
    var max_width: f32 = 0;
    for (lines) |line| {
        max_width = @max(max_width, try inlineLineConstrainedLogicalWidth(ctx, line, text, width, wrap));
    }
    return max_width;
}

fn inlineLineConstrainedLogicalWidth(ctx: *DrawContext, line: Line, text: TextPaint, width: f32, wrap: bool) !f32 {
    if (!lineContainsDisplayMath(line)) {
        var atoms = std.ArrayList(Atom).empty;
        defer atoms.deinit(ctx.allocator);
        defer freeAtoms(ctx.allocator, atoms.items);
        try layoutAtoms(ctx, line, text, &atoms);
        return atomLinesLogicalWidth(atoms.items, atomPaint(text), width, wrap, false);
    }

    const runs = line.runs.items;
    var max_width: f32 = 0;
    var segment_start: usize = 0;
    var index: usize = 0;
    while (index < runs.len) {
        if (runs[index].kind != .display_math) {
            index += 1;
            continue;
        }

        if (segment_start < index) {
            max_width = @max(max_width, try inlineRunSliceConstrainedLogicalWidth(ctx, runs[segment_start..index], text, width, wrap));
        }

        const display_start = index;
        while (index < runs.len and runs[index].kind == .display_math) : (index += 1) {}
        const source_text = try displayMathSource(ctx.allocator, runs[display_start..index]);
        defer ctx.allocator.free(source_text);
        if (source_text.len > 0) {
            const fitted = if (try compileMarkdownMath(ctx, source_text, .display)) |result| blk: {
                var compiled = result;
                defer compiled.layout.deinit(ctx.allocator);
                break :blk fitDisplayMathBlockSize(
                    @floatCast(compiled.layout.width),
                    @floatCast(compiled.layout.height),
                    width,
                    text,
                );
            } else blk: {
                const asset = try renderMathToPdf(ctx, source_text, ctx.tex_preamble, .display);
                defer ctx.allocator.free(asset.path);
                break :blk fitDisplayMathBlockSize(asset.width, asset.height, width, text);
            };
            max_width = @max(max_width, fitted.width);
        }
        segment_start = index;
    }

    if (segment_start < runs.len) {
        max_width = @max(max_width, try inlineRunSliceConstrainedLogicalWidth(ctx, runs[segment_start..], text, width, wrap));
    }
    return max_width;
}

fn inlineRunSliceConstrainedLogicalWidth(ctx: *DrawContext, runs: []const Run, text: TextPaint, width: f32, wrap: bool) !f32 {
    var atoms = std.ArrayList(Atom).empty;
    defer atoms.deinit(ctx.allocator);
    defer freeAtoms(ctx.allocator, atoms.items);
    try layoutRunAtoms(ctx, runs, text, &atoms);
    return atomLinesLogicalWidth(atoms.items, atomPaint(text), width, wrap, false);
}

fn atomLinesLogicalWidth(atoms: []const Atom, paint: AtomPaint, width: f32, wrap: bool, preserve_leading_space: bool) f32 {
    var cursor = wrap_layout.Cursor{ .preserve_leading_space = preserve_leading_space };
    var max_width: f32 = 0;
    var line_width: f32 = 0;
    for (atoms, 0..) |_, index| {
        const measured_atom = measuredWrapAtom(atoms, index, paint);
        switch (cursor.next(measured_atom, width, wrap)) {
            .skip => continue,
            .break_then_draw => {
                max_width = @max(max_width, line_width);
                line_width = 0;
            },
            .draw => {},
        }
        const atom_right = cursor.offset + measured_atom.width;
        cursor.advance(measured_atom.advance);
        line_width = @max(line_width, atom_right);
    }
    return @max(max_width, line_width);
}

const InlineInkBlock = struct {
    top_overhang: f32,
    bottom_depth: f32,
};

fn measureInlineLinesInkBlock(ctx: *DrawContext, lines: []const Line, text: TextPaint, width: f32) !InlineInkBlock {
    const baseline_bl = Defaults.height * 0.5;
    const content_top_bl = baseline_bl + try lineBaselineFromTop(ctx, text.font, text.font_size, text.line_height);
    var measurement = MeasurementScope.init(ctx);
    try measurement.begin();
    defer measurement.deinit();

    const next_bl = try drawInlineLines(ctx, 0, baseline_bl, width, lines, text, true);
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

fn layoutAtoms(ctx: *DrawContext, line: Line, text: TextPaint, atoms: *std.ArrayList(Atom)) !void {
    try layoutRunAtoms(ctx, line.runs.items, text, atoms);
}

fn layoutRunAtoms(ctx: *DrawContext, runs: []const Run, text: TextPaint, atoms: *std.ArrayList(Atom)) !void {
    for (runs) |run| {
        switch (run.kind) {
            .math, .display_math => {
                try appendMathAtom(ctx, atoms, run.text, text, if (run.kind == .display_math) .display else .inline_math);
            },
            .icon => if (run.icon) |source| try appendIconAtom(ctx, atoms, source, text),
            .bold => try appendTextAtoms(ctx, atoms, run.text, text.bold_font, text.markdown_bold_color orelse text.color, text.font_size, null, run.strikethrough, run.underline),
            .italic => try appendTextAtoms(ctx, atoms, run.text, text.italic_font, text.color, text.font_size, null, run.strikethrough, run.underline),
            .code => try appendTextAtoms(ctx, atoms, run.text, text.code_font, text.color, text.font_size, null, run.strikethrough, run.underline),
            .link => try appendTextAtoms(ctx, atoms, run.text, text.font, text.link_color, text.font_size, run.url, run.strikethrough, true),
            .text => try appendTextAtoms(ctx, atoms, run.text, text.font, text.color, text.font_size, null, run.strikethrough, run.underline),
        }
    }
}

fn lineContainsDisplayMath(line: Line) bool {
    for (line.runs.items) |run| {
        if (run.kind == .display_math) return true;
    }
    return false;
}

fn drawLineWithDisplayMath(ctx: *DrawContext, x: f32, baseline_bl: f32, width: f32, line: Line, text: TextPaint, wrap: bool) !f32 {
    return drawLineWithDisplayMathWithAlign(ctx, x, baseline_bl, width, line, text, wrap, .left, text.math_align);
}

fn drawLineWithDisplayMathAligned(ctx: *DrawContext, x: f32, baseline_bl: f32, width: f32, line: Line, text: TextPaint, wrap: bool, horizontal_align: HorizontalAlign) !f32 {
    return drawLineWithDisplayMathWithAlign(ctx, x, baseline_bl, width, line, text, wrap, horizontal_align, horizontal_align);
}

fn drawLineWithDisplayMathWithAlign(
    ctx: *DrawContext,
    x: f32,
    baseline_bl: f32,
    width: f32,
    line: Line,
    text: TextPaint,
    wrap: bool,
    inline_align: HorizontalAlign,
    display_math_align: HorizontalAlign,
) !f32 {
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
            cursor_bl = try drawInlineRunSliceAligned(ctx, x, cursor_bl, width, runs[segment_start..index], text, wrap, inline_align);
        }

        const display_start = index;
        while (index < runs.len and runs[index].kind == .display_math) : (index += 1) {}
        const source = try displayMathSource(ctx.allocator, runs[display_start..index]);
        defer ctx.allocator.free(source);
        if (source.len > 0) {
            cursor_bl = try drawDisplayMathBlockAligned(ctx, x, cursor_bl, width, source, text, display_math_align);
        }
        segment_start = index;
    }

    if (segment_start < runs.len) {
        cursor_bl = try drawInlineRunSliceAligned(ctx, x, cursor_bl, width, runs[segment_start..], text, wrap, inline_align);
    }
    return cursor_bl;
}

fn drawInlineRunSliceAligned(ctx: *DrawContext, x: f32, baseline_bl: f32, width: f32, runs: []const Run, text: TextPaint, wrap: bool, horizontal_align: HorizontalAlign) !f32 {
    var atoms = std.ArrayList(Atom).empty;
    defer atoms.deinit(ctx.allocator);
    defer freeAtoms(ctx.allocator, atoms.items);
    try layoutRunAtoms(ctx, runs, text, &atoms);
    if (atoms.items.len == 0) return baseline_bl;
    return try drawAtomsAligned(ctx, x, baseline_bl, width, atoms.items, atomPaint(text), wrap, horizontal_align);
}

fn drawDisplayMathBlockAligned(ctx: *DrawContext, x: f32, baseline_bl: f32, width: f32, source: []const u8, text: TextPaint, horizontal_align: HorizontalAlign) !f32 {
    var compiled = try compileMarkdownMath(ctx, source, .display);
    defer if (compiled) |*value| value.layout.deinit(ctx.allocator);
    var raw_asset: ?MathAsset = null;
    defer if (raw_asset) |asset| ctx.allocator.free(asset.path);
    const source_size: Size = if (compiled) |value|
        .{ .width = @floatCast(value.layout.width), .height = @floatCast(value.layout.height) }
    else blk: {
        raw_asset = try renderMathToPdf(ctx, source, ctx.tex_preamble, .display);
        break :blk .{ .width = raw_asset.?.width, .height = raw_asset.?.height };
    };
    const fitted = fitDisplayMathBlockSize(source_size.width, source_size.height, width, text);
    if (compiled) |*value| try scaleMathLayoutToSize(&value.layout, fitted);
    const draw_width = if (compiled) |value| @as(f32, @floatCast(value.layout.width)) else fitted.width;
    const draw_height = if (compiled) |value| @as(f32, @floatCast(value.layout.height)) else fitted.height;
    const vertical_pad = @max(text.line_height * 0.2, 2.0);
    const block_height = draw_height + vertical_pad * 2.0;
    const baseline_from_top = try lineBaselineFromTop(ctx, text.font, text.font_size, text.line_height);
    const block_top = baseline_bl + baseline_from_top;
    const block_bottom = block_top - block_height;
    const draw_frame = Frame{
        .x = alignedX(x, width, draw_width, horizontal_align),
        .y = block_bottom + vertical_pad,
        .width = draw_width,
        .height = draw_height,
    };
    if (compiled) |*value| {
        const owned_layout = value.layout;
        value.layout = emptyMathLayout();
        try emitStructuredMath(ctx, .{
            .x = draw_frame.x,
            .y = topOf(draw_frame),
            .width = draw_frame.width,
            .height = draw_frame.height,
        }, value.tree, owned_layout, text.color);
    } else {
        const asset = raw_asset.?;
        try placeRawMathPdf(ctx, draw_frame, asset.path, asset.page_index, source);
    }
    return block_bottom - baseline_from_top;
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

fn fitDisplayMathBlockSize(source_width: f32, source_height: f32, max_width: f32, text: TextPaint) Size {
    if (source_width <= 0 or source_height <= 0) return .{ .width = @max(max_width, 1), .height = @max(text.line_height, 1) };
    const target_height = @max(text.line_height, text.font_size * text.display_math_height_factor);
    const scale = @min(max_width / source_width, target_height / source_height);
    return .{ .width = @max(source_width * scale, 1), .height = @max(source_height * scale, 1) };
}

fn freeAtoms(allocator: Allocator, atoms: []Atom) void {
    for (atoms) |*atom| atom.content.deinit(allocator);
}

fn appendTextAtoms(ctx: *DrawContext, atoms: *std.ArrayList(Atom), value: []const u8, font: FontFace, color: Color, font_size: f32, link_url: ?[]const u8, strikethrough: bool, underline: bool) !void {
    var tokenizer = text_tokenize.Tokenizer.init(value);
    while (tokenizer.next()) |token| {
        const is_emoji = text_tokenize.isEmojiToken(token);
        const measured_width = if (is_emoji)
            try measureTextVisualWidth(ctx, token, font, font_size)
        else
            try measureText(ctx, token, font, font_size);
        const width = measured_width;
        try atoms.append(ctx.allocator, .{
            .content = .text,
            .text = token,
            .font = font,
            .color = color,
            .width = width,
            .is_space = text_tokenize.isWhitespace(token),
            .is_emoji = is_emoji,
            .strikethrough = strikethrough,
            .underline = underline,
            .link_url = link_url,
        });
    }
}

fn appendMathAtom(ctx: *DrawContext, atoms: *std.ArrayList(Atom), value: []const u8, text: TextPaint, kind: MathKind) !void {
    const target_height = @max(text.font_size * text.inline_math_height_factor, 1);
    if (try compileMarkdownMath(ctx, value, kind)) |result| {
        var compiled = result;
        errdefer compiled.layout.deinit(ctx.allocator);
        const scale = @as(f64, target_height) / @max(compiled.layout.height, 1);
        try render_math.scale(&compiled.layout, scale);
        try atoms.append(ctx.allocator, .{
            .content = .{ .structured_math = .{ .tree = compiled.tree, .layout = compiled.layout } },
            .text = value,
            .font = text.font,
            .color = text.color,
            .width = @floatCast(@max(compiled.layout.width, 1)),
            .height = @floatCast(@max(compiled.layout.height, 1)),
            .is_space = false,
        });
        compiled.layout = emptyMathLayout();
        return;
    }

    const asset = try renderMathToPdf(ctx, value, ctx.tex_preamble, kind);
    errdefer ctx.allocator.free(asset.path);
    const scale = if (asset.height > 0) target_height / asset.height else 1;
    try atoms.append(ctx.allocator, .{
        .content = .{ .raw_math = .{ .path = asset.path, .page_index = asset.page_index } },
        .text = value,
        .font = text.font,
        .color = text.color,
        .width = @max(asset.width * scale, 1),
        .height = target_height,
        .baseline_from_bottom = asset.baseline_from_bottom * scale,
        .is_space = false,
    });
}

fn appendIconAtom(ctx: *DrawContext, atoms: *std.ArrayList(Atom), source: []const u8, text: TextPaint) !void {
    const svg = try renderIconToSvg(ctx, source);
    errdefer ctx.allocator.free(svg.path);
    const target_height = @max(text.font_size, 1);
    const scale = if (svg.height > 0) target_height / svg.height else 1;
    const font_metrics = try text_measure.lineMetrics(ctx.allocator, text.font, text.font_size);
    const font_height = font_metrics.ascent + font_metrics.descent;
    try atoms.append(ctx.allocator, .{
        .content = .{ .icon = .{ .path = svg.path } },
        .text = source,
        .font = text.font,
        .color = text.link_color,
        .width = @max(svg.width * scale, 1),
        .height = target_height,
        .baseline_from_bottom = target_height * font_metrics.descent / font_height,
        .is_space = false,
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

fn drawAtoms(ctx: *DrawContext, x: f32, baseline_bl: f32, width: f32, atoms: []Atom, paint: AtomPaint, wrap: bool) !f32 {
    return drawAtomsWithOptions(ctx, x, baseline_bl, width, atoms, paint, wrap, false, .left);
}

fn drawAtomsAligned(ctx: *DrawContext, x: f32, baseline_bl: f32, width: f32, atoms: []Atom, paint: AtomPaint, wrap: bool, horizontal_align: HorizontalAlign) !f32 {
    return drawAtomsWithOptions(ctx, x, baseline_bl, width, atoms, paint, wrap, false, horizontal_align);
}

fn drawAtomsWithOptions(
    ctx: *DrawContext,
    x: f32,
    baseline_bl: f32,
    width: f32,
    atoms: []Atom,
    paint: AtomPaint,
    wrap: bool,
    preserve_leading_space: bool,
    horizontal_align: HorizontalAlign,
) !f32 {
    var positions = std.ArrayList(AtomPosition).empty;
    defer positions.deinit(ctx.allocator);
    var lines = std.ArrayList(AtomVisualLine).empty;
    defer lines.deinit(ctx.allocator);

    var cursor = wrap_layout.Cursor{ .preserve_leading_space = preserve_leading_space };
    var line_start: usize = 0;
    var line_width: f32 = 0;
    for (atoms, 0..) |_, index| {
        const measured_atom = measuredWrapAtom(atoms, index, paint);
        switch (cursor.next(measured_atom, width, wrap)) {
            .skip => continue,
            .break_then_draw => {
                try appendAtomVisualLine(ctx.allocator, &lines, line_start, positions.items.len, line_width);
                line_start = positions.items.len;
                line_width = 0;
            },
            .draw => {},
        }
        const atom_right = cursor.offset + measured_atom.width;
        try positions.append(ctx.allocator, .{ .index = index, .offset = cursor.offset });
        cursor.advance(measured_atom.advance);
        line_width = @max(line_width, atom_right);
    }
    try appendAtomVisualLine(ctx.allocator, &lines, line_start, positions.items.len, line_width);

    if (lines.items.len == 0) return baseline_bl - paint.line_height;
    for (lines.items, 0..) |line, line_index| {
        const line_x = alignedX(x, width, line.width, horizontal_align);
        const line_bl = baseline_bl - @as(f32, @floatFromInt(line_index)) * paint.line_height;
        for (positions.items[line.start..line.end]) |position| {
            try drawPositionedAtom(ctx, &atoms[position.index], line_x + position.offset, line_bl, paint);
        }
    }
    return baseline_bl - @as(f32, @floatFromInt(lines.items.len)) * paint.line_height;
}

fn appendAtomVisualLine(allocator: Allocator, lines: *std.ArrayList(AtomVisualLine), start: usize, end: usize, width: f32) !void {
    if (start == end) return;
    try lines.append(allocator, .{
        .start = start,
        .end = end,
        .width = width,
    });
}

fn drawPositionedAtom(ctx: *DrawContext, atom: *Atom, x: f32, baseline_bl: f32, paint: AtomPaint) !void {
    switch (atom.content) {
        .text => {
            const y_top = baselineTop(baseline_bl, paint.font_size);
            if (atom.link_url) |url| {
                try drawLinkedRawText(ctx, x, y_top, @max(atom.width, 1), paint.line_height, atom.*, paint, url);
            } else {
                try drawAtomRawText(ctx, x, y_top, @max(atom.width + paint.font_size, 1), atom.*, paint, false);
            }
        },
        .structured_math => |*math| {
            const layout = math.layout;
            math.layout = emptyMathLayout();
            try emitStructuredMath(ctx, .{
                .x = x,
                .y = Defaults.height - baseline_bl - layout.baseline,
                .width = layout.width,
                .height = layout.height,
            }, math.tree, layout, atom.color);
        },
        .raw_math => |math| {
            const frame = Frame{ .x = x, .y = baseline_bl - atom.baseline_from_bottom, .width = atom.width, .height = atom.height };
            try placeRawMathPdf(ctx, frame, math.path, math.page_index, atom.text);
        },
        .icon => |icon| {
            const frame = Frame{ .x = x, .y = baseline_bl - atom.baseline_from_bottom, .width = atom.width, .height = atom.height };
            try drawSvgFrameTinted(ctx, frame, icon.path, atom.color);
        },
    }
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
    return switch (atom.content) {
        .text => atom.width + atomSpacingAfter(atoms, index, paint),
        .structured_math, .raw_math => atom.width + paint.font_size * paint.inline_math_spacing,
        .icon => atom.width,
    };
}

fn atomSpacingAfter(atoms: []const Atom, index: usize, paint: AtomPaint) f32 {
    if (index + 1 >= atoms.len) return 0;
    if (!atoms[index].is_emoji or atoms[index + 1].is_space) return 0;
    return paint.font_size * paint.emoji_spacing;
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
    try appendTextAtoms(ctx, &atoms, content, font, color, font_size, null, false, false);
    const paint = AtomPaint{
        .font_size = font_size,
        .line_height = line_height,
        .emoji_spacing = emoji_spacing,
        .inline_math_spacing = 0,
    };
    const baseline_bl = Defaults.height - (y_top + font_size);
    _ = try drawAtomsWithOptions(ctx, x, baseline_bl, width, atoms.items, paint, wrap, preserve_leading_space, .left);
    return atomLineAdvance(atoms.items, paint);
}

fn highlightLanguageFor(ctx: *DrawContext, language: []const u8) ?*const utils.highlight.Language {
    for (ctx.highlight_languages) |*configured| {
        if (std.ascii.eqlIgnoreCase(configured.name, language)) return configured;
    }
    return null;
}

fn drawTreeSitterCodeBlock(ctx: *DrawContext, frame: Frame, content: []const u8, text: TextPaint, code: CodePaint, font_size: f32, line_height: f32) !void {
    const first_baseline_bl = try baselineBlForBox(ctx, frame, text.code_font, font_size, line_height);
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
        var plain_lines = utils.source.lineIterator(content);
        while (plain_lines.next()) |line_view| {
            const line = line_view.text(content);
            if (trim_trailing_empty_line and line.len == 0 and line_view.raw_end == content.len and content.len > 0 and content[content.len - 1] == '\n') break;
            _ = try drawCodeTextAtTop(ctx, x, baselineTop(cursor_bl, font_size), width, line_height, line, font, font_size, code.plain, emoji_spacing);
            cursor_bl -= line_height;
        }
        return;
    };

    var spans = try collectTreeSitterHighlightSpans(ctx, language, content, code);
    defer spans.deinit(ctx.allocator);

    var cursor_bl = first_baseline_bl;
    var lines = utils.source.lineIterator(content);
    while (lines.next()) |line_view| {
        const line = line_view.text(content);
        if (trim_trailing_empty_line and line.len == 0 and line_view.raw_end == content.len and content.len > 0 and content[content.len - 1] == '\n') break;
        const line_start = line_view.span.start;
        const line_end = line_view.span.end;
        try drawHighlightedCodeLine(ctx, x, baselineTop(cursor_bl, font_size), width, content, line_start, line_end, spans.items, font, font_size, line_height, code.plain, emoji_spacing);
        cursor_bl -= line_height;
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
    var cursor_bl = try baselineBlForBox(ctx, frame, text.code_font, text.font_size, text.line_height);
    var lines = utils.source.lineIterator(content);
    while (lines.next()) |line_view| {
        const line = line_view.text(content);
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
            index = utils.source.skipQuotedString(line, index, line.len, byte);
            try drawCodeSegment(ctx, &cursor_x, y_top, line[start..index], font, font_size, line_height, code.string, emoji_spacing);
            continue;
        }
        if (utils.source.isIdentifierStart(byte)) {
            index += 1;
            while (index < line.len and utils.source.isIdentifierContinue(line[index])) index += 1;
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

fn drawVectorMathCommand(ctx: *DrawContext, command: *const ObjectCommand, frame: Frame, math: ?MathPaint) !void {
    if (command.math_kind != .raw_block) {
        try drawStructuredMath(ctx, command.content, command.math_kind, frame, math);
        return;
    }
    const asset = try renderMathToPdf(ctx, command.content, command.tex_preamble, command.math_kind);
    defer ctx.allocator.free(asset.path);
    const fitted = fitVectorMathSize(asset.width, asset.height, frame.width, frame.height, command.math_kind, math);
    const horizontal_align = if (math) |m| m.horizontal_align else HorizontalAlign.center;
    const draw_frame = Frame{
        .x = alignedX(frame.x, frame.width, fitted.width, horizontal_align),
        .y = frame.y + @max((frame.height - fitted.height) / 2, 0),
        .width = fitted.width,
        .height = fitted.height,
    };
    try placeRawMathPdf(ctx, draw_frame, asset.path, asset.page_index, command.content);
}

const structured_math_design_size: f64 = 48;

fn mathInputKind(kind: MathKind) render_ir.MathInputKind {
    return switch (kind) {
        .inline_math => .@"inline",
        .display => .display,
        .block => .block,
        .raw_block => .raw,
    };
}

fn compileStructuredMath(ctx: *DrawContext, source: []const u8, kind: MathKind) !render_math.Compiled {
    const emitter = activeEmitter(ctx);
    return render_math.compile(
        ctx.allocator,
        ctx.io,
        emitter.resources,
        emitter.fonts,
        emitter.math,
        source,
        mathInputKind(kind),
        .{ .font_size = structured_math_design_size, .display = kind != .inline_math },
    );
}

fn emitStructuredMath(
    ctx: *DrawContext,
    rect: render_ir.Rect,
    tree: render_ir.MathTreeId,
    layout: render_ir.MathLayout,
    color: Color,
) !void {
    if (ctx.measurement_bounds) |bounds| {
        var owned_layout = layout;
        defer owned_layout.deinit(ctx.allocator);
        bounds.include(rect);
        return;
    }
    try activeEmitter(ctx).structuredMath(ctx.allocator, rect, tree, layout, color);
}

fn supportsStructuredMath(allocator: Allocator, source: []const u8, kind: MathKind) !bool {
    var math = render_ir.MathBuilder{};
    defer math.deinit(allocator);
    _ = math.add(allocator, source, mathInputKind(kind)) catch |err| switch (err) {
        error.UnsupportedMathSyntax => return false,
        else => return err,
    };
    return true;
}

fn compileMarkdownMath(ctx: *DrawContext, source: []const u8, kind: MathKind) !?render_math.Compiled {
    return compileStructuredMath(ctx, source, kind) catch |err| switch (err) {
        error.UnsupportedMathSyntax => if (ctx.tex_preamble.len != 0) null else return err,
        else => return err,
    };
}

fn scaleMathLayoutToSize(layout: *render_ir.MathLayout, size: Size) !void {
    const factor = @min(
        @as(f64, size.width) / @max(layout.width, 1),
        @as(f64, size.height) / @max(layout.height, 1),
    );
    try render_math.scale(layout, factor);
}

fn emptyMathLayout() render_ir.MathLayout {
    return .{ .width = 0, .height = 0, .baseline = 0, .elements = &.{} };
}

fn drawStructuredMath(ctx: *DrawContext, source: []const u8, kind: MathKind, frame: Frame, maybe_paint: ?MathPaint) !void {
    var compiled = try compileStructuredMath(ctx, source, kind);
    errdefer compiled.layout.deinit(ctx.allocator);
    const fitted = fitVectorMathSize(
        @floatCast(compiled.layout.width),
        @floatCast(compiled.layout.height),
        frame.width,
        frame.height,
        kind,
        maybe_paint,
    );
    try scaleMathLayoutToSize(&compiled.layout, fitted);
    const width: f32 = @floatCast(compiled.layout.width);
    const height: f32 = @floatCast(compiled.layout.height);
    const paint = maybe_paint orelse defaultMathPaint();
    const rect = render_ir.Rect{
        .x = alignedX(frame.x, frame.width, width, paint.horizontal_align),
        .y = topOf(.{
            .x = frame.x,
            .y = frame.y + @max((frame.height - height) / 2, 0),
            .width = width,
            .height = height,
        }),
        .width = width,
        .height = height,
    };
    const owned_layout = compiled.layout;
    compiled.layout = emptyMathLayout();
    try emitStructuredMath(ctx, rect, compiled.tree, owned_layout, paint.color);
}

fn drawVectorAsset(ctx: *DrawContext, frame: Frame, content: []const u8, asset: ?core.render_policy.AssetPaint) !void {
    const source = try resolveAssetPath(ctx, content);
    defer ctx.allocator.free(source);
    const extension = std.fs.path.extension(source);
    if (std.ascii.eqlIgnoreCase(extension, ".svg")) {
        try drawSvgNatural(ctx, frame, source, asset);
        return;
    }
    if (std.ascii.eqlIgnoreCase(extension, ".pdf")) {
        const size = try pdfAssetSize(ctx, source, asset, .pdf);
        const fitted = naturalAssetFrame(frame, scaledAssetSize(size, asset));
        const paint = asset orelse core.render_policy.AssetPaint{
            .scale = 1,
            .pdf_page = 1,
            .pdf_box = .crop,
        };
        const rect = render_ir.Rect{ .x = fitted.x, .y = topOf(fitted), .width = fitted.width, .height = fitted.height };
        if (ctx.measurement_bounds) |bounds| {
            bounds.include(rect);
        } else {
            try activeEmitter(ctx).pdfPage(ctx.allocator, rect, source, paint.pdf_page - 1, paint.pdf_box, true);
        }
        return;
    }
    return NativePdfError.UnsupportedAssetType;
}

fn drawRasterAsset(ctx: *DrawContext, frame: Frame, content: []const u8, asset: ?core.render_policy.AssetPaint) !void {
    const source = try resolveAssetPath(ctx, content);
    defer ctx.allocator.free(source);
    if (std.ascii.eqlIgnoreCase(std.fs.path.extension(source), ".svg")) {
        try drawSvgNatural(ctx, frame, source, asset);
        return;
    }
    try drawRasterNatural(ctx, frame, source, asset);
}

fn recordQpdfFailure(ctx: *DrawContext, operation: []const u8) !void {
    const detail_pointer = c.ss_qpdf_last_error();
    const detail = if (detail_pointer == null) "unknown libqpdf error" else std.mem.span(detail_pointer);
    if (ctx.command_failure) |target| {
        const message = try std.fmt.allocPrint(ctx.allocator, "failed to {s}: {s}", .{ operation, detail });
        defer ctx.allocator.free(message);
        try target.record(message);
    }
}

fn drawRawText(
    ctx: *DrawContext,
    x: f32,
    y_top: f32,
    width: f32,
    content: []const u8,
    font: FontFace,
    font_size: f32,
    color: Color,
    wrap: bool,
    decoration: render_emitter.TextDecoration,
) !void {
    const baseline_y = y_top + font_size;
    if (ctx.measurement_bounds) |bounds| {
        if (content.len == 0) return;
        const measurement = try text_measure.layout(ctx.allocator, content, font, font_size, width, wrap, .{
            .strikethrough = decoration.strikethrough,
            .underline = decoration.underline,
        });
        const layout_y = baseline_y - measurement.first_baseline;
        const ink = measurement.ink_bounds;
        bounds.include(.{
            .x = x + ink.x,
            .y = layout_y + ink.y,
            .width = ink.width,
            .height = ink.height,
        });
        if (measurement.decoration_bounds) |decorated| bounds.include(.{
            .x = x + decorated.x,
            .y = layout_y + decorated.y,
            .width = decorated.width,
            .height = decorated.height,
        });
        return;
    }
    try activeEmitter(ctx).textBaseline(ctx.allocator, x, baseline_y, width, content, font, font_size, color, wrap, decoration);
}

fn drawAtomRawText(ctx: *DrawContext, x: f32, y_top: f32, width: f32, atom: Atom, paint: AtomPaint, wrap: bool) !void {
    try drawRawText(ctx, x, y_top, width, atom.text, atom.font, paint.font_size, atom.color, wrap, .{
        .strikethrough = atom.strikethrough,
        .underline = atom.underline,
    });
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
        try drawAtomRawText(ctx, x, y_top, @max(atom.width + paint.font_size, 1), atom, paint, false);
        return;
    }

    const kind: LinkAnnotation.Kind = if (isInternalLink(url)) .dest else .uri;
    const resolved_width = @max(link_width, 1);
    const links = ctx.link_annotations orelse return error.MissingRenderAnnotationSink;
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
    try drawAtomRawText(ctx, x, y_top, @max(atom.width + paint.font_size, 1), atom, paint, false);
}

fn isInternalLink(url: []const u8) bool {
    return url.len > 1 and url[0] == '#';
}

fn measureText(ctx: *DrawContext, content: []const u8, font: FontFace, font_size: f32) !f32 {
    return text_measure.advanceWidth(ctx.allocator, content, font, font_size);
}

fn measureTextVisualWidth(ctx: *DrawContext, content: []const u8, font: FontFace, font_size: f32) !f32 {
    return text_measure.visualWidth(ctx.allocator, content, font, font_size);
}

fn lineBaselineFromTop(ctx: *DrawContext, font: FontFace, font_size: f32, line_height: f32) !f32 {
    const metrics = try text_measure.lineMetrics(ctx.allocator, font, font_size);
    return metrics.ascent + (line_height - metrics.ascent - metrics.descent) / 2;
}

fn baselineBlForBox(ctx: *DrawContext, frame: Frame, font: FontFace, font_size: f32, line_height: f32) !f32 {
    return frame.y + frame.height - try lineBaselineFromTop(ctx, font, font_size, line_height);
}

fn baselineTop(baseline_bl: f32, font_size: f32) f32 {
    return Defaults.height - baseline_bl - font_size;
}

fn listMarker(allocator: Allocator, kind: core.markdown.BlockKind, depth: usize, ordinal: usize) ![]const u8 {
    if (kind == .ordered_list) return std.fmt.allocPrint(allocator, "{d}.", .{ordinal});
    return allocator.dupe(u8, if (depth == 0) "•" else "◦");
}

fn drawRasterNatural(ctx: *DrawContext, frame: Frame, source: []const u8, asset: ?core.render_policy.AssetPaint) !void {
    const size = try rasterAssetSize(ctx, source);
    const fitted = naturalAssetFrame(frame, scaledAssetSize(size, asset));
    const rect = render_ir.Rect{ .x = fitted.x, .y = topOf(fitted), .width = fitted.width, .height = fitted.height };
    if (ctx.measurement_bounds) |bounds| {
        bounds.include(rect);
    } else {
        try activeEmitter(ctx).raster(ctx.allocator, rect, source);
    }
}

fn drawSvgNatural(ctx: *DrawContext, frame: Frame, svg_path: []const u8, asset: ?core.render_policy.AssetPaint) !void {
    const svg = try svgAsset(ctx, svg_path);
    const fitted = naturalAssetFrame(frame, scaledAssetSize(.{ .width = svg.width, .height = svg.height }, asset));
    const rect = render_ir.Rect{ .x = fitted.x, .y = topOf(fitted), .width = fitted.width, .height = fitted.height };
    if (ctx.measurement_bounds) |bounds| {
        bounds.include(rect);
    } else {
        try activeEmitter(ctx).svg(ctx.allocator, rect, svg_path, null);
    }
}

fn drawSvgFrameTinted(ctx: *DrawContext, frame: Frame, svg_path: []const u8, color: Color) !void {
    const rect = render_ir.Rect{ .x = frame.x, .y = topOf(frame), .width = frame.width, .height = frame.height };
    if (ctx.measurement_bounds) |bounds| {
        bounds.include(rect);
    } else {
        try activeEmitter(ctx).svg(ctx.allocator, rect, svg_path, color);
    }
}

fn placeRawMathPdf(
    ctx: *DrawContext,
    frame: Frame,
    path: []const u8,
    page_index: usize,
    source: []const u8,
) !void {
    const rect = render_ir.Rect{ .x = frame.x, .y = topOf(frame), .width = frame.width, .height = frame.height };
    if (ctx.measurement_bounds) |bounds| {
        bounds.include(rect);
    } else {
        try activeEmitter(ctx).rawMathPdf(ctx.allocator, rect, source, path, page_index);
    }
}

const Size = struct { width: f32, height: f32 };

fn rasterAssetSize(ctx: *DrawContext, source: []const u8) !Size {
    if (ctx.emitter) |*emitter| {
        const id = try emitter.resources.addPath(ctx.allocator, ctx.io, .raster, source);
        const resource = emitter.resources.get(ctx.io, id) orelse return error.MissingRenderResource;
        const metadata = switch (resource.metadata) {
            .raster => |value| value,
            else => return error.RenderResourceKindConflict,
        };
        return .{ .width = @floatFromInt(metadata.oriented_width), .height = @floatFromInt(metadata.oriented_height) };
    }
    var source_width: f64 = 0;
    var source_height: f64 = 0;
    const source_z = try ctx.allocator.dupeZ(u8, source);
    defer ctx.allocator.free(source_z);
    if (c.ss_raster_size(source_z.ptr, &source_width, &source_height) != 0) return NativePdfError.ImageDecodeFailed;
    return .{ .width = @floatCast(source_width), .height = @floatCast(source_height) };
}

fn pdfAssetSize(
    ctx: *DrawContext,
    source: []const u8,
    asset: ?core.render_policy.AssetPaint,
    kind: render_ir.ResourceKind,
) !Size {
    if (ctx.emitter) |*emitter| {
        const id = try emitter.resources.addPath(ctx.allocator, ctx.io, kind, source);
        const resource = emitter.resources.get(ctx.io, id) orelse return error.MissingRenderResource;
        const metadata = switch (resource.metadata) {
            .pdf => |value| value,
            .math_pdf => |value| value,
            else => return error.RenderResourceKindConflict,
        };
        const page_number = if (asset) |paint| paint.pdf_page else 1;
        if (page_number == 0 or page_number > metadata.pages.len) return error.InvalidPdfResource;
        const page = &metadata.pages[page_number - 1];
        const page_box = if (asset) |paint| paint.pdf_box else .crop;
        const box = page.box(page_box);
        var width = box.width() * page.user_unit;
        var height = box.height() * page.user_unit;
        if (page.rotation == 90 or page.rotation == 270) std.mem.swap(f64, &width, &height);
        return .{ .width = @floatCast(width), .height = @floatCast(height) };
    }
    var source_width: f64 = 0;
    var source_height: f64 = 0;
    const source_z = try ctx.allocator.dupeZ(u8, source);
    defer ctx.allocator.free(source_z);
    const page_number = if (asset) |paint| paint.pdf_page else 1;
    const page_box = if (asset) |paint| paint.pdf_box else .crop;
    if (c.ss_qpdf_page_size(source_z.ptr, page_number - 1, @intFromEnum(page_box), &source_width, &source_height) != 0) {
        try recordQpdfFailure(ctx, "read PDF page geometry");
        return NativePdfError.ImageDecodeFailed;
    }
    return .{ .width = @floatCast(source_width), .height = @floatCast(source_height) };
}

fn cachedMathReference(ctx: *DrawContext, reference_path: []const u8) !?MathAsset {
    if (!fileExists(reference_path)) return null;
    return readMathReference(ctx, reference_path) catch |err| switch (err) {
        error.InvalidPdfCache => {
            deleteFileIfExists(ctx, reference_path);
            return null;
        },
        else => return err,
    };
}

fn readMathReference(ctx: *DrawContext, reference_path: []const u8) !MathAsset {
    const contents = std.Io.Dir.cwd().readFileAlloc(ctx.io, reference_path, ctx.allocator, .limited(4096)) catch return NativePdfError.InvalidPdfCache;
    defer ctx.allocator.free(contents);
    const trimmed = std.mem.trim(u8, contents, " \t\r\n");
    var fields = std.mem.splitScalar(u8, trimmed, '\t');
    const page_text = fields.next() orelse return NativePdfError.InvalidPdfCache;
    const width_text = fields.next() orelse return NativePdfError.InvalidPdfCache;
    const height_text = fields.next() orelse return NativePdfError.InvalidPdfCache;
    const baseline_text = fields.next() orelse return NativePdfError.InvalidPdfCache;
    const pdf_name = fields.next() orelse return NativePdfError.InvalidPdfCache;
    if (fields.next() != null or pdf_name.len == 0 or !std.mem.eql(u8, std.fs.path.basename(pdf_name), pdf_name)) {
        return NativePdfError.InvalidPdfCache;
    }
    const page_index = std.fmt.parseInt(usize, page_text, 10) catch return NativePdfError.InvalidPdfCache;
    const width = std.fmt.parseFloat(f32, width_text) catch return NativePdfError.InvalidPdfCache;
    const height = std.fmt.parseFloat(f32, height_text) catch return NativePdfError.InvalidPdfCache;
    const baseline_from_bottom = std.fmt.parseFloat(f32, baseline_text) catch return NativePdfError.InvalidPdfCache;
    if (!std.math.isFinite(width) or !std.math.isFinite(height) or !std.math.isFinite(baseline_from_bottom) or
        width <= 0 or height <= 0)
    {
        return NativePdfError.InvalidPdfCache;
    }
    const directory = std.fs.path.dirname(reference_path) orelse ".";
    const pdf_path = try std.fs.path.join(ctx.allocator, &.{ directory, pdf_name });
    errdefer ctx.allocator.free(pdf_path);
    if (!try cachedPdfAvailable(ctx, pdf_path)) return NativePdfError.InvalidPdfCache;
    return .{
        .path = pdf_path,
        .page_index = page_index,
        .width = width,
        .height = height,
        .baseline_from_bottom = baseline_from_bottom,
    };
}

fn naturalAssetFrame(frame: Frame, size: Size) Frame {
    return .{
        .x = frame.x,
        .y = frame.y + frame.height - @max(size.height, 1),
        .width = @max(size.width, 1),
        .height = @max(size.height, 1),
    };
}

fn assetScale(asset: ?core.render_policy.AssetPaint) f32 {
    if (asset) |paint| return @max(paint.scale, 0.0001);
    return 1;
}

fn scaledAssetSize(size: Size, asset: ?core.render_policy.AssetPaint) Size {
    const scale = assetScale(asset);
    return .{
        .width = size.width * scale,
        .height = size.height * scale,
    };
}

fn fitVectorMathSize(source_width: f32, source_height: f32, max_width: f32, max_height: f32, kind: MathKind, math: ?MathPaint) Size {
    if (source_width <= 0 or source_height <= 0) return .{ .width = max_width, .height = max_height };
    const paint = math orelse defaultMathPaint();
    return switch (kind) {
        .raw_block => fitRawTexObjectSize(source_width, source_height, max_width, max_height, paint),
        .inline_math, .display, .block => fitFormulaObjectSize(source_width, source_height, max_width, max_height, paint),
    };
}

fn defaultMathPaint() MathPaint {
    return .{
        .min_height = 30,
        .raw_tex_width_ratio = 0.96,
        .scale = 1,
        .horizontal_align = .center,
        .color = .{ .r = 0, .g = 0, .b = 0.0353 },
    };
}

fn fitRawTexObjectSize(source_width: f32, source_height: f32, max_width: f32, max_height: f32, paint: MathPaint) Size {
    // Raw TeX is commonly used as a slide-level diagram or algorithm box, so it uses most of the available content width.
    const target_width = @max(max_width * paint.raw_tex_width_ratio * paint.scale, 1);
    const scale = @min(target_width / source_width, max_height / source_height);
    return .{ .width = @max(source_width * scale, 1), .height = @max(source_height * scale, 1) };
}

fn fitFormulaObjectSize(source_width: f32, source_height: f32, max_width: f32, max_height: f32, paint: MathPaint) Size {
    // Formula objects keep their natural TeX size, with scale acting like an authored size change.
    const styled_height = @max(source_height * paint.scale, paint.min_height * paint.scale);
    const style_scale = styled_height / source_height;
    const styled_width = source_width * style_scale;
    const fit_scale = @min(@as(f32, 1.0), @min(max_width / styled_width, max_height / styled_height));
    return .{ .width = styled_width * fit_scale, .height = styled_height * fit_scale };
}

fn alignedX(x: f32, width: f32, content_width: f32, horizontal_align: HorizontalAlign) f32 {
    const slack = @max(width - content_width, 0);
    return switch (horizontal_align) {
        .left => x,
        .center => x + slack / 2,
        .right => x + slack,
    };
}

fn resolveAssetPath(ctx: *DrawContext, rel_path: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(rel_path)) return ctx.allocator.dupe(u8, rel_path);
    return std.fs.path.join(ctx.allocator, &.{ ctx.asset_base_dir, rel_path });
}

fn renderMathToPdf(ctx: *DrawContext, source: []const u8, preamble: []const TexPreambleEntry, kind: MathKind) !MathAsset {
    const reference_path = try cachedMathPath(ctx, source, preamble, kind, "ref");
    defer ctx.allocator.free(reference_path);
    if (try cachedMathReference(ctx, reference_path)) |asset| return asset;
    const output_pdf_path = try cachedMathPath(ctx, source, preamble, kind, "pdf");
    defer ctx.allocator.free(output_pdf_path);
    const dir = try tempCachePath(ctx, reference_path, "dir");
    defer ctx.allocator.free(dir);
    defer std.Io.Dir.cwd().deleteTree(ctx.io, dir) catch {};
    errdefer std.Io.Dir.cwd().deleteTree(ctx.io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(ctx.io, dir);
    const tex_path = try std.fs.path.join(ctx.allocator, &.{ dir, "main.tex" });
    defer ctx.allocator.free(tex_path);
    const pdf_path = try std.fs.path.join(ctx.allocator, &.{ dir, "main.pdf" });
    defer ctx.allocator.free(pdf_path);
    const metrics_path = try std.fs.path.join(ctx.allocator, &.{ dir, "main.ssm" });
    defer ctx.allocator.free(metrics_path);
    const tex = try mathDocumentSource(ctx, source, preamble, kind);
    defer ctx.allocator.free(tex);
    try std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = tex_path, .data = tex, .flags = .{ .truncate = true } });
    try runChecked(ctx, &.{ "pdflatex", "-interaction=nonstopmode", "-halt-on-error", "main.tex" }, .{ .path = dir });
    try publishGeneratedPdf(ctx, pdf_path, output_pdf_path);
    const size = try pdfAssetSize(ctx, output_pdf_path, null, .math_pdf);
    const baseline_from_bottom = if (kind == .raw_block)
        0
    else blk: {
        const ratios = try readMathBaselineRatios(ctx, metrics_path, 1);
        defer ctx.allocator.free(ratios);
        break :blk size.height * ratios[0];
    };
    try writeMathReference(ctx, reference_path, output_pdf_path, 0, size.width, size.height, baseline_from_bottom);
    return (try cachedMathReference(ctx, reference_path)) orelse NativePdfError.InvalidPdfCache;
}

fn renderIconToSvg(ctx: *DrawContext, source: []const u8) !SvgAsset {
    const out = try cachedIconPath(ctx, source, "svg");
    errdefer ctx.allocator.free(out);
    if (try cachedSvgAsset(ctx, out)) |asset| return asset;
    const spec = parseIconSource(source) orelse return NativePdfError.InvalidFontAwesomeIcon;
    const sprite = fontAwesomeSprite(spec.style) orelse return NativePdfError.InvalidFontAwesomeIcon;
    const icon_svg = try extractFontAwesomeIcon(ctx.allocator, sprite, spec.name);
    defer ctx.allocator.free(icon_svg);
    const tmp = try tempCachePath(ctx, out, "svg");
    defer ctx.allocator.free(tmp);
    errdefer deleteFileIfExists(ctx, tmp);
    try std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = tmp, .data = icon_svg, .flags = .{ .truncate = true } });
    _ = try svgAsset(ctx, tmp);
    try publishCacheFile(ctx, tmp, out);
    return try svgAsset(ctx, out);
}

fn fontAwesomeSprite(style: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, style, "solid")) return fontawesome_assets.solid;
    if (std.mem.eql(u8, style, "regular")) return fontawesome_assets.regular;
    if (std.mem.eql(u8, style, "brands")) return fontawesome_assets.brands;
    return null;
}

fn extractFontAwesomeIcon(allocator: Allocator, sprite: []const u8, name: []const u8) ![]u8 {
    const marker = try std.fmt.allocPrint(allocator, "<symbol id=\"{s}\" ", .{name});
    defer allocator.free(marker);
    const symbol_start = std.mem.indexOf(u8, sprite, marker) orelse return NativePdfError.InvalidFontAwesomeIcon;
    const opening_end = std.mem.indexOfScalarPos(u8, sprite, symbol_start, '>') orelse return NativePdfError.InvalidFontAwesomeIcon;
    const symbol_end = std.mem.indexOfPos(u8, sprite, opening_end + 1, "</symbol>") orelse return NativePdfError.InvalidFontAwesomeIcon;
    const opening = sprite[symbol_start .. opening_end + 1];
    const view_box_marker = "viewBox=\"";
    const view_box_start_rel = std.mem.indexOf(u8, opening, view_box_marker) orelse return NativePdfError.InvalidFontAwesomeIcon;
    const view_box_start = view_box_start_rel + view_box_marker.len;
    const view_box_end = std.mem.indexOfScalarPos(u8, opening, view_box_start, '"') orelse return NativePdfError.InvalidFontAwesomeIcon;
    return std.fmt.allocPrint(
        allocator,
        "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"{s}\">{s}</svg>",
        .{ opening[view_box_start..view_box_end], sprite[opening_end + 1 .. symbol_end] },
    );
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

fn readMathBaselineRatios(ctx: *DrawContext, path: []const u8, expected_count: usize) ![]f64 {
    const contents = std.Io.Dir.cwd().readFileAlloc(ctx.io, path, ctx.allocator, .limited(1024 * 1024)) catch {
        return NativePdfError.AssetConversionFailed;
    };
    defer ctx.allocator.free(contents);
    const ratios = try ctx.allocator.alloc(f64, expected_count);
    errdefer ctx.allocator.free(ratios);
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        if (count >= expected_count) return NativePdfError.AssetConversionFailed;
        var fields = std.mem.tokenizeAny(u8, trimmed, " \t,");
        const width_sp = std.fmt.parseInt(i64, fields.next() orelse return NativePdfError.AssetConversionFailed, 10) catch {
            return NativePdfError.AssetConversionFailed;
        };
        const height_sp = std.fmt.parseInt(i64, fields.next() orelse return NativePdfError.AssetConversionFailed, 10) catch {
            return NativePdfError.AssetConversionFailed;
        };
        const depth_sp = std.fmt.parseInt(i64, fields.next() orelse return NativePdfError.AssetConversionFailed, 10) catch {
            return NativePdfError.AssetConversionFailed;
        };
        const total_height_sp = std.math.add(i64, height_sp, depth_sp) catch return NativePdfError.AssetConversionFailed;
        if (fields.next() != null or width_sp <= 0 or total_height_sp <= 0) {
            return NativePdfError.AssetConversionFailed;
        }
        ratios[count] = @as(f64, @floatFromInt(depth_sp)) / @as(f64, @floatFromInt(total_height_sp));
        count += 1;
    }
    if (count != expected_count) return NativePdfError.AssetConversionFailed;
    return ratios;
}

fn mathDocumentSource(ctx: *DrawContext, source: []const u8, preamble: []const TexPreambleEntry, kind: MathKind) ![]const u8 {
    const preamble_lines = try mathPreambleLines(ctx, preamble);
    defer ctx.allocator.free(preamble_lines);
    const fragment = try mathTexFragment(ctx.allocator, source, kind);
    defer ctx.allocator.free(fragment);
    if (kind == .raw_block) return std.fmt.allocPrint(ctx.allocator,
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
    return std.fmt.allocPrint(ctx.allocator,
        \\ \documentclass[border=0pt]{{standalone}}
        \\ \usepackage{{amsmath,amssymb}}
        \\ \usepackage{{graphicx}}
        \\ \usepackage{{xcolor}}
        \\{s}
        \\ \newwrite\ssmetrics
        \\ \begin{{document}}
        \\ \immediate\openout\ssmetrics=main.ssm
        \\ \setbox0=\hbox{{{s}}}
        \\ \immediate\write\ssmetrics{{\number\wd0,\number\ht0,\number\dp0}}
        \\ \copy0
        \\ \immediate\closeout\ssmetrics
        \\ \end{{document}}
        \\
    , .{ preamble_lines, fragment });
}

fn mathBatchDocumentSource(ctx: *DrawContext, entries: []const MathBatchEntry) ![]const u8 {
    const preamble_lines = try mathPreambleLines(ctx, entries[0].preamble);
    defer ctx.allocator.free(preamble_lines);

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(ctx.allocator);
    try out.appendSlice(ctx.allocator,
        \\ \documentclass{article}
        \\ \usepackage[active,tightpage]{preview}
        \\ \PreviewBorder=0pt
        \\ \usepackage{amsmath,amssymb}
        \\ \usepackage{graphicx}
        \\ \usepackage{xcolor}
        \\ \newwrite\ssmetrics
        \\
    );
    try out.appendSlice(ctx.allocator, preamble_lines);
    try out.appendSlice(ctx.allocator,
        \\ \pagestyle{empty}
        \\ \begin{document}
        \\ \immediate\openout\ssmetrics=main.ssm
        \\
    );
    for (entries) |entry| {
        const fragment = try mathTexFragment(ctx.allocator, entry.source, entry.kind);
        defer ctx.allocator.free(fragment);
        try out.appendSlice(ctx.allocator, "\\setbox0=\\hbox{");
        try out.appendSlice(ctx.allocator, fragment);
        try out.appendSlice(ctx.allocator,
            \\ }
            \\ \immediate\write\ssmetrics{\number\wd0,\number\ht0,\number\dp0}
            \\ \begin{preview}
            \\ \copy0
            \\ \end{preview}
            \\
        );
    }
    try out.appendSlice(ctx.allocator,
        \\ \immediate\closeout\ssmetrics
        \\ \end{document}
        \\
    );
    return try out.toOwnedSlice(ctx.allocator);
}

fn mathTexFragment(allocator: Allocator, source: []const u8, kind: MathKind) ![]const u8 {
    switch (kind) {
        .inline_math => return std.fmt.allocPrint(allocator, "$\\mathstrut {s}$\n", .{source}),
        .display => return std.fmt.allocPrint(allocator, "$\\displaystyle\\mathstrut {s}$\n", .{source}),
        .raw_block => return allocator.dupe(u8, source),
        .block => {
            var normalized = std.ArrayList(u8).empty;
            defer normalized.deinit(allocator);
            var lines = utils.source.lineIterator(source);
            while (lines.next()) |line_view| {
                const line = line_view.text(source);
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
        if (ctx.command_failure) |target| {
            const message = try std.fmt.allocPrint(ctx.allocator, "TeX preamble file not found: {s} (resolved: {s})", .{ path, resolved });
            defer ctx.allocator.free(message);
            try target.record(message);
        }
        return err;
    };
}

fn cachedMathPath(ctx: *DrawContext, source: []const u8, preamble: []const TexPreambleEntry, kind: MathKind, extension: []const u8) ![]u8 {
    const key = try fingerprint.mathArtifactKey(
        .{
            .allocator = ctx.allocator,
            .io = ctx.io,
            .asset_base_dir = ctx.asset_base_dir,
        },
        native_artifact_cache_version,
        source,
        preamble,
        @tagName(kind),
    );
    return std.fmt.allocPrint(ctx.allocator, "{s}/math-{x}.{s}", .{ ctx.cache_dir, key, extension });
}

fn cachedIconPath(ctx: *DrawContext, source: []const u8, extension: []const u8) ![]u8 {
    var hasher = std.hash.Wyhash.init(0);
    hashString(&hasher, native_artifact_cache_version);
    hashString(&hasher, "fontawesome-free-7.2.0");
    hashString(&hasher, source);
    return std.fmt.allocPrint(ctx.allocator, "{s}/fontawesome-{x}.{s}", .{ ctx.cache_dir, hasher.final(), extension });
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
    if (ctx.emitter) |*emitter| {
        const id = try emitter.resources.addPath(ctx.allocator, ctx.io, .svg, path);
        const resource = emitter.resources.get(ctx.io, id) orelse return error.MissingRenderResource;
        const metadata = switch (resource.metadata) {
            .svg => |value| value,
            else => return error.RenderResourceKindConflict,
        };
        return .{
            .path = path,
            .width = @floatCast(metadata.width),
            .height = @floatCast(metadata.height),
        };
    }
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
    const profile_command = utils.measure_profile.start();
    const result = std.process.run(ctx.allocator, ctx.io, .{
        .argv = argv,
        .cwd = cwd,
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(128 * 1024),
        .timeout = .{ .duration = external_command_timeout },
    }) catch |err| {
        if (argv.len > 0) utils.measure_profile.recordCommand(argv[0], true, profile_command);
        const message = try commandSpawnFailureMessage(ctx.allocator, argv, err);
        defer ctx.allocator.free(message);
        if (ctx.command_failure) |target| try target.record(message);
        return NativePdfError.AssetConversionFailed;
    };
    defer ctx.allocator.free(result.stdout);
    defer ctx.allocator.free(result.stderr);
    const failed = switch (result.term) {
        .exited => |code| code != 0,
        else => true,
    };
    if (argv.len > 0) utils.measure_profile.recordCommand(argv[0], failed, profile_command);
    if (!failed) return;
    const message = try commandTermFailureMessage(ctx.allocator, argv, result.term, result.stdout, result.stderr);
    defer ctx.allocator.free(message);
    if (ctx.command_failure) |target| try target.record(message);
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
    var lines = utils.source.lineIterator(output);
    while (lines.next()) |line_view| {
        const line = line_view.text(output);
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

fn topOf(frame: Frame) f32 {
    return Defaults.height - frame.y - frame.height;
}

fn toTopY(bottom_y: f32) f32 {
    return Defaults.height - bottom_y;
}
