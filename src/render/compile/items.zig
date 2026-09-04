const std = @import("std");
const core = @import("core");
const utils = @import("utils");

const text_tokenize = core.text_tokenize;
const wrap_layout = core.render_wrap;
const json = utils.json;
const render_emitter = @import("render_emitter");
const c = @import("pdf_ffi").c;
const render_ir = @import("render");
const render_resources = @import("render_resources");
const render_text = @import("render_text");
const render_compile = @import("../compile.zig");
const fingerprint = @import("fingerprint.zig");
const latex_document = @import("latex.zig");
const page_cache = @import("page_cache.zig");
const external_process = @import("external_process.zig");
const syntax_highlight = @import("syntax_highlight.zig");
const text_measure = core.render_text_measure;

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
const LatexPaint = core.render_policy.LatexPaint;
const VectorPathPaint = core.render_policy.VectorPathPaint;
const ConnectorPaint = core.render_policy.ConnectorPaint;
const MarkerPaint = core.render_policy.MarkerPaint;
const MarkdownDocument = core.markdown.MarkdownDocument;
const Line = core.markdown.Line;
const Block = core.markdown.Block;
const Run = core.markdown.Run;
const LatexPreambleEntry = core.render_env.LatexPreambleEntry;
const LatexEngine = core.render_env.LatexEngine;

const ContentRange = render_text.ContentRange;

const NativePdfError = error{
    ImageDecodeFailed,
    AssetConversionFailed,
    InvalidPdfCache,
    InvalidFontAwesomeIcon,
    UnsupportedAssetType,
    InvalidRenderPolicy,
};

pub const native_artifact_cache_version = "ss-native-artifacts-v7";
const render_page_cache_version = "ss-render-page-v2";
const layout_measurement_cache_version = "ss-native-layout-measure-v18";
const layout_measurement_cache_file_format = "ss-layout-measurements-v1";
const layout_measurement_cache_read_limit = 16 * 1024 * 1024;
const command_failure_output_limit: usize = 1600;
const warm_render_job_cap: usize = 4;
const cold_render_job_cap: usize = 16;
const artifact_job_slack: usize = 2;

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
    text_cache: ?*render_text.Cache = null,
    resource_cache: ?*render_resources.SourceCache = null,
    command_failure: ?*CommandFailure = null,
    synthetic_font_detected: ?*bool = null,
    link_annotations: ?*std.ArrayList(LinkAnnotation) = null,
    destinations: ?*std.ArrayList(DestinationAnnotation) = null,
    emitter: ?render_emitter.Emitter = null,
    measurement_bounds: ?*MeasurementBounds = null,
    capture_measurement_content: bool = false,
    latex_preamble: []const LatexPreambleEntry = &.{},
    latex_engine: LatexEngine = .pdflatex,
    commands: ?[]const ObjectCommand = null,
};

const MeasurementBounds = struct {
    ink: ?render_ir.Rect = null,

    fn include(self: *MeasurementBounds, rect: render_ir.Rect) void {
        if (rect.width <= 0 or rect.height <= 0) return;
        self.ink = if (self.ink) |current| current.unioned(rect) else rect;
    }
};

fn activeEmitter(ctx: *DrawContext) *render_emitter.Emitter {
    const emitter = if (ctx.emitter) |*value| value else unreachable;
    emitter.text_failure = if (ctx.command_failure) |failure| &failure.text_failure else null;
    return emitter;
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

const LatexFragmentKind = latex_document.FragmentKind;

const AtomContent = union(enum) {
    text: ?render_ir.TextLayout,
    latex: struct {
        path: []const u8,
        page_index: usize,
    },
    icon: struct { path: []const u8 },

    fn deinit(self: *AtomContent, allocator: Allocator) void {
        switch (self.*) {
            .text => |*maybe_layout| if (maybe_layout.*) |*layout| layout.deinit(allocator),
            .latex => |latex| allocator.free(latex.path),
            .icon => |icon| allocator.free(icon.path),
        }
    }
};

const Atom = struct {
    content: AtomContent = .{ .text = null },
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
    underline_paint: core.render_policy.MarkdownUnderlinePaint = .{},
    link_url: ?[]const u8 = null,
};

const AtomPaint = struct {
    font: FontFace,
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
    ascent: f32 = 0,
    descent: f32 = 0,
};

const SvgAsset = struct {
    path: []const u8,
    width: f32,
    height: f32,
};

const LatexAsset = struct {
    path: []const u8,
    page_index: usize,
    width: f32,
    height: f32,
    baseline_from_bottom: f32,
    reference_height: f32,
};

const LatexAssetGeometry = struct {
    baseline_from_bottom: f32,
    reference_height: f32,
};

const PreloadTask = union(enum) {
    latex: LatexPreload,
    icon: IconPreload,
    vector_pdf: VectorPdfPreload,
    raster: RasterPreload,
};

const LatexPreload = struct {
    source: []const u8,
    preamble: []const LatexPreambleEntry,
    engine: LatexEngine,
    kind: LatexFragmentKind,
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
    text_failure: render_text.ShapeFailure = .{},
    content_start: ?usize = null,
    content_end: ?usize = null,

    fn deinit(self: *CommandFailure) void {
        if (self.message) |message| self.allocator.free(message);
        self.text_failure.deinit(self.allocator);
    }

    fn record(self: *CommandFailure, message: []const u8) !void {
        if (self.message != null) return;
        self.message = try self.allocator.dupe(u8, message);
    }

    fn recordContentRange(self: *CommandFailure, start: usize, end: usize) void {
        if (self.content_start != null or self.content_end != null) return;
        self.content_start = start;
        self.content_end = @max(start, end);
    }
};

pub const Options = struct {
    jobs: ?usize = null,
    cache_dir: []const u8 = ".ss-cache/render",
    highlight_languages: []const utils.highlight.Language = &.{},
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
    latex_preamble: []const LatexPreambleEntry,
    latex_engine: LatexEngine,
    latex_kind: LatexFragmentKind = .body,
    origin: ?[]const u8 = null,
    payload_kind: ?core.PayloadKind = null,

    fn deinit(_: *ObjectCommand, _: Allocator) void {}
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
    highlight_languages: []const utils.highlight.Language,
};

const LatexBatchEntry = struct {
    task_index: usize,
    source: []const u8,
    preamble: []const LatexPreambleEntry,
    engine: LatexEngine,
    kind: LatexFragmentKind,
    out: []u8,
};

const LatexBatchGroup = struct {
    key: []u8,
    entries: std.ArrayList(LatexBatchEntry) = .empty,

    fn deinit(self: *LatexBatchGroup, allocator: Allocator) void {
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
    font_environment: render_text.FontEnvironment,
    measurement_cache_dirty: bool = false,

    pub fn init(
        allocator: Allocator,
        io: std.Io,
        state: *core.DocumentState,
        pages: *const core.prepared.PreparedPages,
        resource_cache: ?*render_resources.SourceCache,
        highlight_languages: []const utils.highlight.Language,
        font_environment: render_text.FontEnvironment,
    ) !LayoutMeasurementScope {
        const default_options: Options = .{};
        const cache_dir = default_options.cache_dir;
        try render_text.validateFontEnvironment(font_environment);
        try createRenderCacheDirectory(io, state, cache_dir);
        const asset_cache_dir = try std.fs.path.join(allocator, &.{ cache_dir, "artifacts", "native" });
        errdefer allocator.free(asset_cache_dir);
        try createRenderCacheDirectory(io, state, asset_cache_dir);
        const measurement_cache_dir = try std.fs.path.join(allocator, &.{ asset_cache_dir, "measurements" });
        errdefer allocator.free(measurement_cache_dir);
        try createRenderCacheDirectory(io, state, measurement_cache_dir);
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
                .highlight_languages = highlight_languages,
                .resource_cache = resource_cache,
            },
            .prepared_objects = prepared_objects,
            .persistent_measurements = persistent_measurements,
            .run_measurements = std.AutoHashMap(u64, core.LayoutMeasurement).init(allocator),
            .font_environment = font_environment,
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
        try std.Io.checkCancel(self.io);
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
        var target = CommandFailure{ .allocator = state.allocator };
        defer target.deinit();
        var measurement_ctx = self.ctx;
        measurement_ctx.allocator = state.allocator;
        measurement_ctx.command_failure = &target;
        const cache_key = fingerprint.layoutMeasurementKey(
            .{
                .allocator = key_ctx.allocator,
                .io = key_ctx.io,
                .asset_base_dir = key_ctx.asset_base_dir,
                .resource_cache = key_ctx.resource_cache,
                .font_environment = self.font_environment.id,
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
                .latex_preamble = command.latex_preamble,
                .latex_engine = command.latex_engine,
                .latex_kind = @tagName(command.latex_kind),
                .document_body = command.latex_kind == .body,
            },
        ) catch |err| {
            if (err == error.Canceled) return error.Canceled;
            recordLatexPreambleFingerprintFailure(&measurement_ctx, command.latex_preamble);
            try addMeasurementRenderDiagnostic(&measurement_ctx, state, &command, err, &target);
            return err;
        };
        utils.measure_profile.recordLayoutMeasurementCacheKey(profile_cache_key);

        if (try self.cachedMeasurement(cache_key, true)) |cached| return cached;

        if (try self.cachedMeasurement(cache_key, false)) |cached| return cached;

        try render_text.validateFontEnvironment(self.font_environment);
        const profile_intrinsic = utils.measure_profile.start();
        defer utils.measure_profile.recordRenderIntrinsic(profileRenderMeasureKind(command.render.kind), profile_intrinsic);
        var measured = measureObjectCommandIntrinsic(&measurement_ctx, &command, width, mode) catch |err| {
            if (err == error.Canceled) return error.Canceled;
            try addMeasurementRenderDiagnostic(&measurement_ctx, state, &command, err, &target);
            return err;
        };
        if (measured) |*value| {
            try render_text.validateFontEnvironment(self.font_environment);
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

    fn objectCommandForNode(self: *LayoutMeasurementScope, _: Allocator, node: *const core.Node, width: f32, mode: core.LayoutMeasurementMode) !ObjectCommand {
        const object = self.preparedObject(node.id) orelse return error.MissingPreparedObject;
        return objectCommandForObject(node, object, width, mode);
    }

    fn objectCommandForObject(
        node: *const core.Node,
        object: *const core.prepared.PreparedObject,
        width: f32,
        mode: core.LayoutMeasurementMode,
    ) ObjectCommand {
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
            .latex_preamble = object.latex_preamble,
            .latex_engine = object.latex_engine,
            .latex_kind = .body,
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
    const text = utils.fs.readFileAllocLimited(io, allocator, path, .limited(layout_measurement_cache_read_limit)) catch return;
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
    try createRenderCacheDirectory(io, state, options.cache_dir);
    const asset_cache_dir = try std.fs.path.join(allocator, &.{ options.cache_dir, "artifacts", "native" });
    defer allocator.free(asset_cache_dir);
    try createRenderCacheDirectory(io, state, asset_cache_dir);

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
        var failure = CommandFailure{ .allocator = state.allocator };
        defer failure.deinit();
        var diagnostic_ctx = ctx;
        diagnostic_ctx.command_failure = &failure;
        cached[index] = preloadTaskPresent(&diagnostic_ctx, task) catch |err| {
            utils.measure_profile.recordArtifactScan(profilePreloadKind(task), false, profile_scan);
            if (err != error.Canceled) try addPreloadRenderDiagnostic(state, task, err, &failure);
            return err;
        };
        utils.measure_profile.recordArtifactScan(profilePreloadKind(task), cached[index], profile_scan);
        if (!cached[index]) miss_count += 1;
    }

    const initial_done = tasks.len - miss_count;
    if (progress) |p| p.artifactCompleted(p.context, initial_done, tasks.len);
    if (miss_count == 0) return;

    const profile_build_wall = utils.measure_profile.start();
    defer utils.measure_profile.recordArtifactBuildWall(miss_count, profile_build_wall);
    executePreloadTaskList(&ctx, tasks, cached, miss_count, options, progress) catch |err| {
        if (err == error.Canceled) return error.Canceled;
        try collectPreloadTaskDiagnostics(&ctx, state, tasks, cached);
        return err;
    };
}

fn createRenderCacheDirectory(io: std.Io, state: *core.DocumentState, path: []const u8) !void {
    std.Io.Dir.cwd().createDirPath(io, path) catch |err| {
        var reason_buf: [256]u8 = undefined;
        const message = try std.fmt.allocPrint(
            state.allocator,
            "RenderCacheAccessFailed: could not create render cache directory '{s}': {s}; remove a conflicting file or fix its permissions",
            .{ path, utils.err.formatErrorReason(&reason_buf, err) },
        );
        try state.addRenderDiagnostic(.@"error", null, null, null, .{
            .user_report = .{ .message = message },
        });
        return err;
    };
}

pub const Compiler = struct {
    io: std.Io,
    options: render_compile.Options,
    font_environment: ?render_text.FontEnvironment = null,
    diagnostic_mutex: std.Io.Mutex = .init,

    pub fn prepare(
        self: *Compiler,
        allocator: Allocator,
        state: *core.DocumentState,
        pages: *const core.prepared.PreparedPages,
    ) !void {
        const expected_environment = self.options.font_environment;
        if (expected_environment) |expected| {
            try render_text.refreshAndValidateFontEnvironment(expected);
        } else {
            _ = try render_text.fontEnvironmentRefresh();
        }
        try preloadPreparedPageArtifacts(allocator, self.io, state, pages, .{
            .jobs = self.options.jobs,
            .cache_dir = self.options.cache_dir,
            .highlight_languages = self.options.highlight_languages,
        }, null);
        if (expected_environment) |expected| {
            try render_text.validateFontEnvironment(expected);
            self.font_environment = expected;
        } else {
            self.font_environment = try render_text.fontEnvironmentSnapshot();
        }
        try std.Io.checkCancel(self.io);
    }

    pub fn compilePage(
        self: *Compiler,
        allocator: Allocator,
        state: *core.DocumentState,
        prepared_page: *const core.prepared.PreparedPage,
        resources: *render_resources.Builder,
        fonts: *render_ir.FontBuilder,
    ) !render_ir.Page {
        try std.Io.checkCancel(self.io);
        const font_environment = self.font_environment orelse
            try render_text.fontEnvironmentSnapshot();
        try render_text.validateFontEnvironment(font_environment);
        const asset_cache_dir = try std.fs.path.join(allocator, &.{ self.options.cache_dir, "artifacts", "native" });
        defer allocator.free(asset_cache_dir);
        var synthetic_font_detected = false;
        var draw_context = DrawContext{
            .allocator = allocator,
            .io = self.io,
            .asset_base_dir = if (state.asset_base_dir.len == 0) "." else state.asset_base_dir,
            .cache_dir = asset_cache_dir,
            .highlight_languages = self.options.highlight_languages,
            .text_cache = self.options.text_cache,
            .resource_cache = self.options.resource_cache,
            .synthetic_font_detected = &synthetic_font_detected,
        };

        const commands = try buildObjectCommands(allocator, state, prepared_page);
        defer {
            for (commands) |*command| command.deinit(allocator);
            allocator.free(commands);
        }
        if (self.options.page_cache) |cache| {
            const page_cache_start = utils.measure_profile.start();
            const key = try fingerprint.renderPageKey(
                .{
                    .allocator = allocator,
                    .io = self.io,
                    .asset_base_dir = draw_context.asset_base_dir,
                    .resource_cache = self.options.resource_cache,
                    .font_environment = font_environment.id,
                },
                render_page_cache_version,
                prepared_page.page_id,
                prepared_page.index,
                prepared_page.background,
                self.options.highlight_languages,
                commands,
            );
            if (try cache.materialize(key, allocator, self.io, resources, fonts)) |page| {
                utils.measure_profile.recordRenderPage(true, page_cache_start);
                return page;
            }

            var local_resources = render_resources.Builder{ .cache = self.options.resource_cache };
            defer local_resources.deinit(allocator);
            var local_fonts = render_ir.FontBuilder{};
            defer local_fonts.deinit(allocator);
            var page = try buildRenderPage(
                self,
                &draw_context,
                state,
                prepared_page.page_id,
                prepared_page.index,
                prepared_page.background,
                commands,
                &local_resources,
                &local_fonts,
            );
            var page_live = true;
            errdefer if (page_live) page.deinit(allocator);
            const source_dependencies = try local_resources.sourceDependencies(allocator, self.io);
            defer render_resources.deinitSourceDependencies(allocator, source_dependencies);
            var resource_graph = try local_resources.take(allocator);
            defer resource_graph.deinit(allocator);
            var font_catalog = try local_fonts.take(allocator);
            defer font_catalog.deinit(allocator);
            try render_text.validateFontEnvironment(font_environment);
            const cached = if (synthetic_font_detected)
                false
            else
                try cache.put(
                    key,
                    allocator,
                    &page,
                    &resource_graph,
                    source_dependencies,
                    &font_catalog,
                );
            if (!cached) {
                try mergeUncachedPage(
                    allocator,
                    self.io,
                    &page,
                    &resource_graph,
                    &font_catalog,
                    resources,
                    fonts,
                );
                utils.measure_profile.recordRenderPage(false, page_cache_start);
                return page;
            }
            page.deinit(allocator);
            page_live = false;
            const materialized = (try cache.materialize(key, allocator, self.io, resources, fonts)) orelse return error.InvalidRenderPageCache;
            utils.measure_profile.recordRenderPage(false, page_cache_start);
            return materialized;
        }
        return try buildRenderPage(
            self,
            &draw_context,
            state,
            prepared_page.page_id,
            prepared_page.index,
            prepared_page.background,
            commands,
            resources,
            fonts,
        );
    }
};

pub const PageCache = page_cache.Cache;

fn mergeUncachedPage(
    allocator: Allocator,
    io: std.Io,
    page: *render_ir.Page,
    resource_graph: *const render_ir.ResourceGraph,
    font_catalog: *const render_ir.FontCatalog,
    resources: *render_resources.Builder,
    fonts: *render_ir.FontBuilder,
) !void {
    for (resource_graph.entries) |*resource| {
        const added = try resources.addResource(allocator, io, resource);
        if (!std.mem.eql(u8, &added, &resource.id)) return error.InvalidRenderPageCache;
    }
    for (font_catalog.instances) |*font| {
        const added = try fonts.add(allocator, io, font.spec());
        if (!std.mem.eql(u8, &added, &font.id)) return error.InvalidRenderPageCache;
    }
    _ = page;
}

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
    try commands.ensureTotalCapacity(allocator, page_unit.objects.len);
    for (page_unit.objects) |*object| {
        const node = state.getNode(object.node_id) orelse continue;
        if (node.kind != .object or !object.attached) continue;
        if ((state.parentPageOf(node.id) orelse continue) != page_unit.page_id) continue;
        commands.appendAssumeCapacity(initObjectCommand(page_unit.page_id, node, object, node.frame));
    }
    return try commands.toOwnedSlice(allocator);
}

fn initObjectCommand(
    page_id: core.NodeId,
    node: *const core.Node,
    object: *const core.prepared.PreparedObject,
    frame: Frame,
) ObjectCommand {
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
        .latex_preamble = object.latex_preamble,
        .latex_engine = object.latex_engine,
        .latex_kind = .body,
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
                const kind: LatexFragmentKind = if (dep.kind == .display_math) .display_math else .inline_math;
                try registerPlanPreloadTask(ctx, tasks, seen, deps, .{ .latex = .{
                    .source = try ctx.allocator.dupe(u8, dep.source),
                    .preamble = try cloneLatexPreambleEntries(ctx.allocator, object.latex_preamble),
                    .engine = object.latex_engine,
                    .kind = kind,
                    .target = dep_target,
                } });
            },
            .latex_body => {
                try registerPlanPreloadTask(ctx, tasks, seen, deps, .{ .latex = .{
                    .source = try ctx.allocator.dupe(u8, dep.source),
                    .preamble = try cloneLatexPreambleEntries(ctx.allocator, object.latex_preamble),
                    .engine = object.latex_engine,
                    .kind = .body,
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
        if (command.render.kind == .text or command.render.kind == .latex or command.render.kind == .vector_asset) return;
    } else if (command.render.kind == .text) {
        return;
    }
    switch (command.render.kind) {
        .text => {},
        .latex => {
            if (command.latex_kind == .body) try registerPlanPreloadTask(ctx, tasks, seen, page_deps, .{ .latex = .{
                .source = try ctx.allocator.dupe(u8, command.content),
                .preamble = try cloneLatexPreambleEntries(ctx.allocator, command.latex_preamble),
                .engine = command.latex_engine,
                .kind = command.latex_kind,
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
        .code, .vector_path, .connector, .chrome_only => {},
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
                const kind: LatexFragmentKind = if (dep.kind == .display_math) .display_math else .inline_math;
                try registerPlanPreloadTask(ctx, tasks, seen, page_deps, .{ .latex = .{
                    .source = try ctx.allocator.dupe(u8, dep.source),
                    .preamble = try cloneLatexPreambleEntries(ctx.allocator, command.latex_preamble),
                    .engine = command.latex_engine,
                    .kind = kind,
                    .target = dep_target,
                } });
            },
            .latex_body => {
                if (command.latex_kind == .body) try registerPlanPreloadTask(ctx, tasks, seen, page_deps, .{ .latex = .{
                    .source = try ctx.allocator.dupe(u8, dep.source),
                    .preamble = try cloneLatexPreambleEntries(ctx.allocator, command.latex_preamble),
                    .engine = command.latex_engine,
                    .kind = command.latex_kind,
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

fn addPreloadRenderDiagnostic(state: *core.DocumentState, task: PreloadTask, err: anyerror, failure: ?*const CommandFailure) !void {
    const target = preloadTaskTarget(task);
    try addTargetedRenderDiagnostic(state, target, preloadTaskLabel(task), err, failure);
}

fn addTargetedRenderDiagnostic(
    state: *core.DocumentState,
    target: RenderDiagnosticTarget,
    label: []const u8,
    err: anyerror,
    failure: ?*const CommandFailure,
) !void {
    var resolved_target = target;
    if (failure) |detail| {
        if (detail.content_start) |start| {
            if (detail.content_end) |end| resolved_target = targetWithContentSpan(resolved_target, start, end);
        }
    }
    var origin = try preloadTaskDiagnosticOrigin(state, resolved_target);
    defer origin.deinit(state.allocator);
    var detail_buffer: [512]u8 = undefined;
    const recorded_message = if (failure) |value| value.message else null;
    const detail = recorded_message orelse
        render_text.diagnosticMessageForError(err) orelse
        renderFailureDiagnosticMessage(&detail_buffer, err);
    const reason = try std.fmt.allocPrint(state.allocator, "{s}: {s}", .{ label, detail });
    try state.addRenderDiagnostic(.@"error", resolved_target.page_id, resolved_target.node_id, origin.text, .{
        .render_failed = .{
            .reason = reason,
            .payload_kind = resolved_target.payload_kind,
        },
    });
}

pub fn addFontFaceSubstitutionWarning(
    state: *core.DocumentState,
    page_id: ?core.NodeId,
    node_id: ?core.NodeId,
    origin: ?[]const u8,
    failure: ?*const render_text.SyntheticFontFailure,
) !void {
    var message_buffer: [1024]u8 = undefined;
    const message = if (failure) |detail|
        render_text.formatSyntheticFontWarning(&message_buffer, detail)
    else
        render_text.genericSyntheticFontWarning();
    for (state.diagnostics.items) |diagnostic| {
        if (diagnostic.phase != .render or diagnostic.severity != .warning) continue;
        const existing = switch (diagnostic.data) {
            .user_report => |report| report.message,
            else => continue,
        };
        if (std.mem.eql(u8, existing, message)) return;
    }
    const owned_message = try state.allocator.dupe(u8, message);
    try state.addRenderDiagnostic(.warning, page_id, node_id, origin, .{
        .user_report = .{ .message = owned_message },
    });
}

fn renderFailureDiagnosticMessage(buffer: []u8, err: anyerror) []const u8 {
    return switch (err) {
        error.ImageDecodeFailed => "ImageDecodeFailed: could not decode the image; verify that its contents match a supported image format",
        error.AssetConversionFailed => "AssetConversionFailed: could not convert the asset; verify the input and the required external tool",
        error.InvalidPdfCache => "InvalidPdfCache: a generated or cached PDF artifact is invalid; verify the LaTeX or PDF input, then run 'ss cache project clear' if the failure persists",
        error.InvalidFontAwesomeIcon => "InvalidFontAwesomeIcon: the icon name is not in the bundled catalog; choose a valid fa-solid, fa-regular, or fa-brands icon",
        error.UnsupportedAssetType => "UnsupportedAssetType: this object cannot render the asset type; use image! for images and pdf! for PDF files",
        error.InvalidRasterResource => "InvalidRasterResource: the file is not a valid raster image; verify its contents and use pdf! for PDF files",
        error.InvalidSvgResource => "InvalidSvgResource: the file is not a valid SVG with usable intrinsic dimensions; repair or replace the SVG",
        error.InvalidPdfResource => "InvalidPdfResource: the file is not a readable PDF or the requested page is unavailable; verify the PDF and page number",
        error.ResourceChangedDuringRead => "ResourceChangedDuringRead: the asset changed repeatedly while it was being read; wait for the writer to finish and retry",
        error.UnknownTreeSitterLanguage => "UnknownTreeSitterLanguage: the configured parser is unavailable; select a supported built-in parser in ss.toml",
        error.TreeSitterParserCreateFailed => "TreeSitterParserCreateFailed: could not initialize syntax highlighting; retry or disable highlighting for this language",
        error.TreeSitterLanguageRejected => "TreeSitterLanguageRejected: the bundled parser is incompatible with the tree-sitter runtime; reinstall or update ss, and report the failure if it persists",
        error.TreeSitterParseFailed => "TreeSitterParseFailed: tree-sitter could not create a syntax tree; retry, and report this as an ss bug if the failure persists",
        error.TreeSitterQueryFailed => "TreeSitterQueryFailed: the highlight query is invalid; fix the query file or select a built-in query",
        error.TreeSitterQueryCursorCreateFailed => "TreeSitterQueryCursorCreateFailed: could not initialize the syntax highlighter; retry or disable highlighting for this language",
        else => utils.err.formatErrorReason(buffer, err),
    };
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

fn addObjectCommandDiagnostic(state: *core.DocumentState, command: *const ObjectCommand, err: anyerror, failure: ?*const CommandFailure) !void {
    try addTargetedRenderDiagnostic(state, objectCommandDiagnosticTarget(command), objectCommandLabel(command), err, failure);
}

fn addObjectFontSubstitutionWarning(state: *core.DocumentState, command: *const ObjectCommand, failure: *const CommandFailure) !void {
    var target = objectCommandDiagnosticTarget(command);
    if (failure.content_start) |start| {
        if (failure.content_end) |end| target = targetWithContentSpan(target, start, end);
    }
    var origin = try preloadTaskDiagnosticOrigin(state, target);
    defer origin.deinit(state.allocator);
    const synthetic_font = if (failure.text_failure.synthetic_font) |*detail| detail else null;
    try addFontFaceSubstitutionWarning(state, target.page_id, target.node_id, origin.text, synthetic_font);
}

fn addMeasurementRenderDiagnostic(ctx: *DrawContext, state: *core.DocumentState, command: *const ObjectCommand, err: anyerror, failure: ?*const CommandFailure) !void {
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
        try addObjectCommandDiagnostic(state, command, err, failure);
        return;
    };

    for (tasks.items) |task| {
        var target = CommandFailure{ .allocator = state.allocator };
        defer target.deinit();
        var diagnostic_ctx = ctx.*;
        diagnostic_ctx.command_failure = &target;
        preloadOne(&diagnostic_ctx, task) catch |task_err| {
            try addPreloadRenderDiagnostic(state, task, task_err, &target);
            return;
        };
    }

    try addObjectCommandDiagnostic(state, command, err, failure);
}

fn objectCommandDiagnosticTarget(command: *const ObjectCommand) RenderDiagnosticTarget {
    const target = objectDiagnosticTarget(command);
    return switch (command.render.kind) {
        .latex, .vector_asset, .raster_asset => targetWithContentSpan(target, 0, command.content.len),
        else => target,
    };
}

fn objectCommandLabel(command: *const ObjectCommand) []const u8 {
    return switch (command.render.kind) {
        .text => "text object",
        .code => "code block",
        .chrome_only => "object chrome",
        .vector_path => "vector path object",
        .connector => "connector object",
        .latex => "LaTeX fragment",
        .vector_asset => "vector asset",
        .raster_asset => "raster asset",
    };
}

fn profileRenderMeasureKind(kind: RenderKind) utils.measure_profile.RenderMeasureKind {
    return switch (kind) {
        .text => .text,
        .code => .code,
        .latex => .latex,
        .vector_asset => .vector_asset,
        .raster_asset => .raster_asset,
        .vector_path => .shape,
        .connector => .shape,
        .chrome_only => .chrome_only,
    };
}

fn preloadTaskTarget(task: PreloadTask) RenderDiagnosticTarget {
    return switch (task) {
        .latex => |latex| latex.target,
        .icon => |icon| icon.target,
        .vector_pdf => |asset| asset.target,
        .raster => |raster| raster.target,
    };
}

fn preloadTaskLabel(task: PreloadTask) []const u8 {
    return switch (task) {
        .latex => "LaTeX fragment",
        .icon => "icon",
        .vector_pdf => "PDF asset",
        .raster => "raster asset",
    };
}

fn profilePreloadKind(task: PreloadTask) utils.measure_profile.ArtifactKind {
    return switch (task) {
        .latex => .latex,
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

fn preloadLatexTaskBatches(
    ctx: *DrawContext,
    tasks: []const PreloadTask,
    cached: []bool,
    progress: ?Progress,
    completed: *usize,
) !void {
    var groups = std.ArrayList(LatexBatchGroup).empty;
    var group_indices = std.StringHashMap(usize).init(ctx.allocator);
    defer group_indices.deinit();
    defer {
        for (groups.items) |*group| group.deinit(ctx.allocator);
        groups.deinit(ctx.allocator);
    }

    for (tasks, 0..) |task, index| {
        if (cached[index]) continue;
        const latex = switch (task) {
            .latex => |value| value,
            else => continue,
        };

        const out = try cachedLatexPath(ctx, latex.source, latex.preamble, latex.engine, latex.kind, "ref");
        var out_owned = true;
        errdefer if (out_owned) ctx.allocator.free(out);
        const key = try latexBatchGroupKey(ctx, latex.preamble, latex.engine);
        var key_owned = true;
        errdefer if (key_owned) ctx.allocator.free(key);

        if (group_indices.get(key)) |candidate_index| {
            ctx.allocator.free(key);
            key_owned = false;
            try groups.items[candidate_index].entries.append(ctx.allocator, .{
                .task_index = index,
                .source = latex.source,
                .preamble = latex.preamble,
                .engine = latex.engine,
                .kind = latex.kind,
                .out = out,
            });
            out_owned = false;
        } else {
            try groups.append(ctx.allocator, .{ .key = key });
            key_owned = false;
            const candidate_index = groups.items.len - 1;
            try group_indices.put(groups.items[candidate_index].key, candidate_index);
            try groups.items[candidate_index].entries.append(ctx.allocator, .{
                .task_index = index,
                .source = latex.source,
                .preamble = latex.preamble,
                .engine = latex.engine,
                .kind = latex.kind,
                .out = out,
            });
            out_owned = false;
        }
    }

    for (groups.items) |group| {
        if (group.entries.items.len == 0) continue;
        const document_entries = try latexDocumentEntries(ctx.allocator, group.entries.items);
        defer ctx.allocator.free(document_entries);
        var start: usize = 0;
        while (start < group.entries.items.len) {
            const end = latex_document.batchChunkEnd(document_entries, start);
            const chunk = group.entries.items[start..end];
            const profile_build = utils.measure_profile.start();
            try preloadLatexBatchGroup(ctx, chunk, progress, completed, tasks.len);
            utils.measure_profile.recordArtifactBuildMany(.latex, chunk.len, profile_build);
            for (chunk) |entry| cached[entry.task_index] = true;
            start = end;
        }
    }
}

fn latexBatchGroupKey(ctx: *DrawContext, preamble: []const LatexPreambleEntry, engine: LatexEngine) ![]u8 {
    var hasher = std.hash.Wyhash.init(0);
    hashString(&hasher, native_artifact_cache_version);
    hashString(&hasher, "latex-batch");
    hashString(&hasher, @tagName(engine));
    for (preamble) |entry| {
        hashString(&hasher, @tagName(entry.source));
        hashString(&hasher, entry.value);
    }
    return std.fmt.allocPrint(ctx.allocator, "{x}", .{hasher.final()});
}

fn preloadLatexBatchGroup(
    ctx: *DrawContext,
    entries: []const LatexBatchEntry,
    progress: ?Progress,
    completed: *usize,
    total: usize,
) !void {
    if (entries.len == 0) return;
    const document_entries = try latexDocumentEntries(ctx.allocator, entries);
    defer ctx.allocator.free(document_entries);
    const tex = try latexDocumentSource(ctx, entries[0].preamble, document_entries);
    defer ctx.allocator.free(tex);
    var generated = try compileLatexDocument(ctx, entries[0].out, entries[0].engine, tex);
    defer generated.deinit(ctx);
    try publishLatexBatch(ctx, entries, generated.pdf_path, generated.metrics_path, progress, completed, total);
}

fn publishLatexBatch(
    ctx: *DrawContext,
    entries: []const LatexBatchEntry,
    generated_pdf_path: []const u8,
    metrics_path: []const u8,
    progress: ?Progress,
    completed: *usize,
    total: usize,
) !void {
    if (entries.len == 0) return;
    const batch_path = try latexBatchPdfPath(ctx, entries);
    defer ctx.allocator.free(batch_path);
    try publishGeneratedPdf(ctx, generated_pdf_path, batch_path);

    const batch_path_z = try ctx.allocator.dupeZ(u8, batch_path);
    defer ctx.allocator.free(batch_path_z);
    const widths = try ctx.allocator.alloc(f64, entries.len);
    defer ctx.allocator.free(widths);
    const heights = try ctx.allocator.alloc(f64, entries.len);
    defer ctx.allocator.free(heights);
    const document_entries = try latexDocumentEntries(ctx.allocator, entries);
    defer ctx.allocator.free(document_entries);
    const metrics = try readLatexMetrics(ctx, metrics_path, document_entries);
    defer ctx.allocator.free(metrics);
    if (c.ss_qpdf_page_sizes(batch_path_z.ptr, @intFromEnum(core.render_policy.PdfPageBox.crop), widths.ptr, heights.ptr, entries.len) != 0) {
        try recordQpdfFailure(ctx, "read LaTeX PDF page geometry");
        return NativePdfError.AssetConversionFailed;
    }

    for (entries, 0..) |entry, index| {
        const baseline_from_bottom = if (metrics[index]) |metric| heights[index] * metric.baseline_ratio else 0;
        const reference_height = if (metrics[index]) |metric| heights[index] * metric.reference_height_ratio else heights[index];
        try writeLatexReference(
            ctx,
            entry.out,
            batch_path,
            index,
            widths[index],
            heights[index],
            baseline_from_bottom,
            reference_height,
        );
        completed.* += 1;
        if (progress) |p| p.artifactCompleted(p.context, completed.*, total);
    }
}

fn latexBatchPdfPath(ctx: *DrawContext, entries: []const LatexBatchEntry) ![]u8 {
    var hasher = std.hash.Wyhash.init(0);
    hashString(&hasher, native_artifact_cache_version);
    hashString(&hasher, "latex-batch-pdf");
    for (entries) |entry| hashString(&hasher, entry.out);
    return std.fmt.allocPrint(ctx.allocator, "{s}/latex-batch-{x}.pdf", .{ ctx.cache_dir, hasher.final() });
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

fn writeLatexReference(
    ctx: *DrawContext,
    output: []const u8,
    pdf_path: []const u8,
    page_index: usize,
    width: f64,
    height: f64,
    baseline_from_bottom: f64,
    reference_height: f64,
) !void {
    const contents = try std.fmt.allocPrint(ctx.allocator, "{d}\t{d}\t{d}\t{d}\t{d}\t{s}\n", .{
        page_index,
        width,
        height,
        baseline_from_bottom,
        reference_height,
        std.fs.path.basename(pdf_path),
    });
    defer ctx.allocator.free(contents);
    const tmp = try tempCachePath(ctx, output, "ref");
    defer ctx.allocator.free(tmp);
    errdefer deleteFileIfExists(ctx, tmp);
    try std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = tmp, .data = contents, .flags = .{ .truncate = true } });
    try publishCacheFile(ctx, tmp, output);
}

const GeneratedLatexDocument = struct {
    dir: []u8,
    pdf_path: []u8,
    metrics_path: []u8,

    fn deinit(self: *GeneratedLatexDocument, ctx: *DrawContext) void {
        std.Io.Dir.cwd().deleteTree(ctx.io, self.dir) catch {};
        ctx.allocator.free(self.metrics_path);
        ctx.allocator.free(self.pdf_path);
        ctx.allocator.free(self.dir);
        self.* = undefined;
    }
};

fn compileLatexDocument(
    ctx: *DrawContext,
    output_anchor: []const u8,
    engine: LatexEngine,
    source: []const u8,
) !GeneratedLatexDocument {
    const dir = try tempCachePath(ctx, output_anchor, "latex-dir");
    errdefer ctx.allocator.free(dir);
    errdefer std.Io.Dir.cwd().deleteTree(ctx.io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(ctx.io, dir);

    const tex_path = try std.fs.path.join(ctx.allocator, &.{ dir, "main.tex" });
    defer ctx.allocator.free(tex_path);
    const pdf_path = try std.fs.path.join(ctx.allocator, &.{ dir, "main.pdf" });
    errdefer ctx.allocator.free(pdf_path);
    const metrics_path = try std.fs.path.join(ctx.allocator, &.{ dir, "main.ssm" });
    errdefer ctx.allocator.free(metrics_path);

    try std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = tex_path, .data = source, .flags = .{ .truncate = true } });
    try runChecked(ctx, &.{ engine.executable(), "-interaction=nonstopmode", "-halt-on-error", "main.tex" }, .{ .path = dir });
    return .{ .dir = dir, .pdf_path = pdf_path, .metrics_path = metrics_path };
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
    try preloadLatexTaskBatches(ctx, tasks, cached, progress, &completed);

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
        .highlight_languages = ctx.highlight_languages,
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
            .highlight_languages = work.highlight_languages,
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
            try addPreloadRenderDiagnostic(state, task, err, &target);
        };
    }
}

fn buildRenderPage(
    compiler: *Compiler,
    parent_ctx: *DrawContext,
    state: *core.DocumentState,
    page_id: core.NodeId,
    page_index: usize,
    background: ?Color,
    commands: []ObjectCommand,
    resources: *render_resources.Builder,
    fonts: *render_ir.FontBuilder,
) !render_ir.Page {
    var page = render_ir.Page{
        .page_id = page_id,
        .index = page_index,
        .width = Defaults.width,
        .height = Defaults.height,
    };
    errdefer page.deinit(parent_ctx.allocator);
    try page.items.ensureTotalCapacity(parent_ctx.allocator, commands.len + 1);

    var ctx = DrawContext{
        .allocator = parent_ctx.allocator,
        .io = parent_ctx.io,
        .asset_base_dir = parent_ctx.asset_base_dir,
        .cache_dir = parent_ctx.cache_dir,
        .highlight_languages = parent_ctx.highlight_languages,
        .text_cache = parent_ctx.text_cache,
        .resource_cache = parent_ctx.resource_cache,
        .command_failure = parent_ctx.command_failure,
        .synthetic_font_detected = parent_ctx.synthetic_font_detected,
        .emitter = .{
            .page = &page,
            .resources = resources,
            .fonts = fonts,
            .io = parent_ctx.io,
            .text_cache = parent_ctx.text_cache,
        },
        .commands = commands,
    };

    const page_fill = background orelse Color{ .r = 1, .g = 1, .b = 1 };
    try activeEmitter(&ctx).fillRect(ctx.allocator, .{ .x = 0, .y = 0, .width = Defaults.width, .height = Defaults.height }, page_fill);

    var links = std.ArrayList(LinkAnnotation).empty;
    defer links.deinit(ctx.allocator);
    defer deinitLinkAnnotations(ctx.allocator, links.items);
    try links.ensureTotalCapacity(ctx.allocator, commands.len);
    var destinations = std.ArrayList(DestinationAnnotation).empty;
    defer destinations.deinit(ctx.allocator);
    defer deinitDestinationAnnotations(ctx.allocator, destinations.items);
    try destinations.ensureTotalCapacity(ctx.allocator, commands.len);
    ctx.link_annotations = &links;
    ctx.destinations = &destinations;

    for (commands) |*command| {
        if (command.render.kind == .chrome_only) try drawObjectCommandIntoIrWithDiagnostic(compiler, &ctx, state, command);
    }
    for (commands) |*command| {
        if (command.render.kind != .chrome_only) try drawObjectCommandIntoIrWithDiagnostic(compiler, &ctx, state, command);
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

fn drawObjectCommandIntoIrWithDiagnostic(
    compiler: *Compiler,
    ctx: *DrawContext,
    state: *core.DocumentState,
    command: *const ObjectCommand,
) !void {
    var failure = CommandFailure{ .allocator = ctx.allocator };
    defer failure.deinit();
    const previous_failure = ctx.command_failure;
    ctx.command_failure = &failure;
    defer ctx.command_failure = previous_failure;

    drawObjectCommandIntoIr(ctx, command) catch |err| {
        if (err == error.Canceled or render_text.diagnosticMessageForError(err) != null) return err;
        compiler.diagnostic_mutex.lockUncancelable(compiler.io);
        defer compiler.diagnostic_mutex.unlock(compiler.io);
        try addObjectCommandDiagnostic(state, command, err, &failure);
        return err;
    };
    if (failure.text_failure.synthetic_font != null) {
        if (ctx.synthetic_font_detected) |detected| detected.* = true;
        compiler.diagnostic_mutex.lockUncancelable(compiler.io);
        defer compiler.diagnostic_mutex.unlock(compiler.io);
        try addObjectFontSubstitutionWarning(state, command, &failure);
    }
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
    const previous_preamble = ctx.latex_preamble;
    const previous_engine = ctx.latex_engine;
    ctx.latex_preamble = command.latex_preamble;
    ctx.latex_engine = command.latex_engine;
    defer {
        ctx.latex_preamble = previous_preamble;
        ctx.latex_engine = previous_engine;
    }
    if (command.render.kind == .text or
        command.render.kind == .code or
        command.render.kind == .latex or
        (command.render.kind == .vector_asset and !isPdfAssetOp(command)) or
        command.render.kind == .raster_asset)
    {
        var measurement = MeasurementScope.init(ctx);
        try measurement.beginCapturing();
        defer measurement.deinit();
        try drawObjectContent(ctx, command);
        const measured = try measurement.inkFrame();
        measurement.end();

        const visual_frame = expandFrameToMeasuredInk(command.frame, command.render, measured);
        try addDestination(ctx, command.link_id, visual_frame);
        try drawObjectChrome(ctx, visual_frame, command.render);
        try measurement.commitCapturedContent();
        return;
    }

    const visual_frame = try measuredObjectCommandVisualFrame(ctx, command);
    try addDestination(ctx, command.link_id, visual_frame);
    try drawObjectChrome(ctx, visual_frame, command.render);
    try drawObjectContent(ctx, command);
}

fn drawObjectContent(ctx: *DrawContext, command: *const ObjectCommand) !void {
    const content_frame = contentFrameForRender(command.frame, command.render);
    switch (command.render.kind) {
        .text => if (command.render.text) |text| try drawTextCommand(ctx, command, content_frame, text),
        .code => if (command.render.text) |text| {
            var code_text = text;
            code_text.font = text.code_font;
            try drawCodeBlock(ctx, content_frame, command.content, code_text, command.render.code);
        },
        .chrome_only => {},
        .latex => try drawLatexCommand(ctx, command, content_frame, try requiredLatexPaint(command)),
        .vector_asset => try drawVectorAsset(ctx, content_frame, command.content, command.render.asset),
        .raster_asset => try drawRasterAsset(ctx, content_frame, command.content, command.render.asset),
        .vector_path => if (command.render.vector_path) |path| try drawVectorPathOp(ctx, content_frame, path),
        .connector => if (command.render.connector) |connector| try drawConnectorOp(ctx, connector),
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
        .latex, .vector_asset, .raster_asset => {
            const measured = try measureObjectCommandContent(ctx, command, null);
            return expandFrameToMeasuredInk(command.frame, command.render, measured);
        },
        .vector_path, .connector => return command.frame,
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
    previous_capture_measurement_content: bool,
    active: bool = false,
    bounds: MeasurementBounds = .{},
    page: render_ir.Page = .{
        .page_id = 0,
        .index = 0,
        .width = Defaults.width,
        .height = Defaults.height,
    },
    resources: render_resources.Builder = .{},
    fonts: render_ir.FontBuilder = .{},
    links: std.ArrayList(LinkAnnotation) = .empty,
    destinations: std.ArrayList(DestinationAnnotation) = .empty,

    fn init(ctx: *DrawContext) MeasurementScope {
        return .{
            .ctx = ctx,
            .previous_links = ctx.link_annotations,
            .previous_destinations = ctx.destinations,
            .previous_emitter = ctx.emitter,
            .previous_measurement_bounds = ctx.measurement_bounds,
            .previous_capture_measurement_content = ctx.capture_measurement_content,
        };
    }

    fn begin(self: *MeasurementScope) !void {
        try self.beginWithCapture(false);
    }

    fn beginCapturing(self: *MeasurementScope) !void {
        try self.beginWithCapture(true);
    }

    fn beginWithCapture(self: *MeasurementScope, capture_content: bool) !void {
        const resources = if (self.previous_emitter) |*emitter| emitter.resources else &self.resources;
        const fonts = if (self.previous_emitter) |*emitter| emitter.fonts else &self.fonts;
        self.ctx.emitter = .{
            .page = &self.page,
            .resources = resources,
            .fonts = fonts,
            .io = self.ctx.io,
            .text_cache = if (self.previous_emitter) |emitter| emitter.text_cache else self.ctx.text_cache,
            .node_id = if (self.previous_emitter) |emitter| emitter.node_id else null,
        };
        self.ctx.link_annotations = &self.links;
        self.ctx.destinations = &self.destinations;
        self.ctx.measurement_bounds = &self.bounds;
        self.ctx.capture_measurement_content = capture_content;
        self.active = true;
    }

    fn inkFrame(self: *MeasurementScope) !?Frame {
        if (self.active and self.ctx.capture_measurement_content) {
            for (self.page.items.items) |item| self.bounds.include(item.header().ink_bounds);
        }
        const ink = self.bounds.ink orelse return null;
        return .{
            .x = @floatCast(ink.x),
            .y = @floatCast(Defaults.height - ink.y - ink.height),
            .width = @floatCast(ink.width),
            .height = @floatCast(ink.height),
        };
    }

    fn end(self: *MeasurementScope) void {
        if (!self.active) return;
        self.ctx.link_annotations = self.previous_links;
        self.ctx.destinations = self.previous_destinations;
        self.ctx.emitter = self.previous_emitter;
        self.ctx.measurement_bounds = self.previous_measurement_bounds;
        self.ctx.capture_measurement_content = self.previous_capture_measurement_content;
        self.active = false;
    }

    fn commitCapturedContent(self: *MeasurementScope) !void {
        std.debug.assert(!self.active);
        const emitter = activeEmitter(self.ctx);
        const destination_page = emitter.page;
        const destination_links = self.ctx.link_annotations;
        const destination_destinations = self.ctx.destinations;

        try destination_page.items.ensureUnusedCapacity(self.ctx.allocator, self.page.items.items.len);
        if (destination_links) |links| try links.ensureUnusedCapacity(self.ctx.allocator, self.links.items.len);
        if (destination_destinations) |destinations| try destinations.ensureUnusedCapacity(self.ctx.allocator, self.destinations.items.len);

        for (self.page.items.items) |item| {
            var moved = item;
            remapMovedItem(&moved, destination_page.index, destination_page.items.items.len);
            destination_page.items.appendAssumeCapacity(moved);
        }
        self.page.items.clearRetainingCapacity();

        if (destination_links) |links| {
            for (self.links.items) |link| links.appendAssumeCapacity(link);
            self.links.clearRetainingCapacity();
        }
        if (destination_destinations) |destinations| {
            for (self.destinations.items) |destination| destinations.appendAssumeCapacity(destination);
            self.destinations.clearRetainingCapacity();
        }
    }

    fn deinit(self: *MeasurementScope) void {
        self.end();
        deinitLinkAnnotations(self.ctx.allocator, self.links.items);
        self.links.deinit(self.ctx.allocator);
        deinitDestinationAnnotations(self.ctx.allocator, self.destinations.items);
        self.destinations.deinit(self.ctx.allocator);
        self.page.deinit(self.ctx.allocator);
        self.resources.deinit(self.ctx.allocator);
        self.fonts.deinit(self.ctx.allocator);
    }
};

fn remapMovedItem(item: *render_ir.Item, page_index: usize, paint_index: usize) void {
    const index: u32 = @intCast(paint_index);
    const item_id = (@as(u64, @intCast(page_index + 1)) << 32) | index;
    switch (item.*) {
        inline else => |*value| {
            value.header.paint_index = index;
            value.header.item_id = item_id;
        },
    }
}

fn measureObjectCommandContent(ctx: *DrawContext, command: *const ObjectCommand, maybe_text: ?TextPaint) !?Frame {
    var measurement = MeasurementScope.init(ctx);
    try measurement.begin();
    defer measurement.deinit();

    const content_frame = contentFrameForRender(command.frame, command.render);
    switch (command.render.kind) {
        .text => if (maybe_text) |text| try drawTextCommand(ctx, command, content_frame, text),
        .code => if (maybe_text) |text| try drawCodeBlock(ctx, content_frame, command.content, text, command.render.code),
        .latex => try drawLatexCommand(ctx, command, content_frame, try requiredLatexPaint(command)),
        .vector_asset => try drawVectorAsset(ctx, content_frame, command.content, command.render.asset),
        .raster_asset => try drawRasterAsset(ctx, content_frame, command.content, command.render.asset),
        .vector_path => if (command.render.vector_path) |path| try drawVectorPathOp(ctx, content_frame, path),
        .connector => if (command.render.connector) |connector| try drawConnectorOp(ctx, connector),
        else => return null,
    }
    return try measurement.inkFrame();
}

fn measureObjectCommandIntrinsic(ctx: *DrawContext, command: *const ObjectCommand, outer_width: f32, mode: core.LayoutMeasurementMode) !?core.LayoutMeasurement {
    const previous_preamble = ctx.latex_preamble;
    const previous_engine = ctx.latex_engine;
    ctx.latex_preamble = command.latex_preamble;
    ctx.latex_engine = command.latex_engine;
    defer {
        ctx.latex_preamble = previous_preamble;
        ctx.latex_engine = previous_engine;
    }
    var render = command.render;
    if (mode == .natural) {
        if (render.text) |*text| text.wrap = false;
    }
    if (render.kind == .vector_path or render.kind == .connector or render.kind == .chrome_only) {
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
        .latex => try measureLatexIntrinsic(ctx, command, content_frame.width, content_frame.height),
        .vector_asset, .raster_asset => try measureAssetIntrinsic(
            ctx,
            command,
            content_frame.width,
            content_frame.height,
            mode,
        ),
        .vector_path, .connector, .chrome_only => unreachable,
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
        .vector_path => if (command.render.vector_path) |path| try drawVectorPathOp(ctx, content_frame, path),
        .connector => if (command.render.connector) |connector| try drawConnectorOp(ctx, connector),
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

fn measureLatexIntrinsic(ctx: *DrawContext, command: *const ObjectCommand, width: f32, height: f32) !core.LayoutMeasurement {
    const latex = try renderLatexToPdf(ctx, command.content, command.latex_preamble, command.latex_engine, command.latex_kind);
    defer ctx.allocator.free(latex.path);
    const fitted = fitLatexSize(latex.width, latex.height, @max(width, 1), @max(height, 1), try requiredLatexPaint(command));
    return .{ .width = @max(fitted.width, 1), .height = @max(fitted.height, 1) };
}

fn measureAssetIntrinsic(
    ctx: *DrawContext,
    command: *const ObjectCommand,
    width: f32,
    height: f32,
    mode: core.LayoutMeasurementMode,
) !core.LayoutMeasurement {
    if (core.fontawesome.parseSource(command.content)) |spec| {
        if (!core.fontawesome.contains(spec)) return NativePdfError.InvalidFontAwesomeIcon;
        if (mode == .natural) return .{ .width = 72, .height = 72 };
        return .{ .width = @max(width, 1), .height = @max(height, 1) };
    }
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

fn cloneLatexPreambleEntries(allocator: Allocator, preamble: []const LatexPreambleEntry) ![]const LatexPreambleEntry {
    const cloned = try allocator.alloc(LatexPreambleEntry, preamble.len);
    @memcpy(cloned, preamble);
    return cloned;
}

fn freePreloadTasks(allocator: Allocator, tasks: []const PreloadTask) void {
    for (tasks) |task| freePreloadTask(allocator, task);
}

fn freePreloadTask(allocator: Allocator, task: PreloadTask) void {
    switch (task) {
        .latex => |latex| {
            allocator.free(latex.source);
            allocator.free(latex.preamble);
        },
        .icon => |icon| allocator.free(icon.source),
        .vector_pdf => |asset| allocator.free(asset.source),
        .raster => |raster| allocator.free(raster.source),
    }
}

fn preloadTaskKey(ctx: *DrawContext, task: PreloadTask) ![]u8 {
    return switch (task) {
        .latex => |latex| latexPreloadTaskKey(ctx, latex),
        .icon => |icon| cachedIconPath(ctx, icon.source, "svg"),
        .vector_pdf => |asset| ctx.allocator.dupe(u8, asset.source),
        .raster => |raster| ctx.allocator.dupe(u8, raster.source),
    };
}

fn latexPreloadTaskKey(ctx: *DrawContext, latex: LatexPreload) ![]u8 {
    var hasher = std.hash.Wyhash.init(0);
    hashString(&hasher, native_artifact_cache_version);
    hashString(&hasher, "latex-preload");
    hashString(&hasher, latex.source);
    hashString(&hasher, @tagName(latex.engine));
    hashString(&hasher, @tagName(latex.kind));
    hashUsize(&hasher, latex.preamble.len);
    for (latex.preamble) |entry| {
        hashString(&hasher, @tagName(entry.source));
        hashString(&hasher, entry.value);
    }
    return std.fmt.allocPrint(ctx.allocator, "latex-{x}", .{hasher.final()});
}

fn preloadTaskPresent(ctx: *DrawContext, task: PreloadTask) !bool {
    switch (task) {
        .latex => |latex| return cachedLatexAvailable(ctx, latex),
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
        .latex => |latex| return cachedLatexAvailable(ctx, latex),
        .icon => |icon| {
            const out = try cachedIconPath(ctx, icon.source, "svg");
            defer ctx.allocator.free(out);
            return (try cachedSvgAsset(ctx, out)) != null;
        },
        .vector_pdf => return false,
        .raster => return false,
    }
}

fn cachedLatexAvailable(ctx: *DrawContext, latex: LatexPreload) !bool {
    const out = try cachedLatexPath(ctx, latex.source, latex.preamble, latex.engine, latex.kind, "ref");
    defer ctx.allocator.free(out);
    const asset = try cachedLatexReference(ctx, out) orelse return false;
    ctx.allocator.free(asset.path);
    return true;
}

fn preloadOne(ctx: *DrawContext, task: PreloadTask) !void {
    switch (task) {
        .latex => |latex| {
            const asset = try renderLatexToPdf(ctx, latex.source, latex.preamble, latex.engine, latex.kind);
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
    if (options.jobs) |jobs| return clampWorkerCount(jobs, task_count);
    const cpu = autoCpuCount();
    const desired = if (missing_artifacts == 0)
        @min(cpu, warm_render_job_cap)
    else if (missing_artifacts < cpu)
        @min(cpu, @max(warm_render_job_cap, missing_artifacts + artifact_job_slack))
    else
        @min(cpu * 2, cold_render_job_cap);
    return clampWorkerCount(desired, task_count);
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

fn drawVectorPathOp(ctx: *DrawContext, frame: Frame, paint: VectorPathPaint) !void {
    const mapping = PathMapping{
        .xx = frame.width,
        .yx = 0,
        .xy = 0,
        .yy = frame.height,
        .x0 = frame.x,
        .y0 = toTopY(frame.y + frame.height),
        .radius_scale = @min(frame.width, frame.height),
    };
    try drawStyledPath(ctx, paint.path, mapping, paint.fill, paint.stroke);
    const tangents = vectorPathTangents(paint.path, mapping) orelse return;
    if (paint.marker_start) |marker| try drawMarker(ctx, marker, tangents.start, tangents.start_tangent);
    if (paint.marker_end) |marker| try drawMarker(ctx, marker, tangents.end, tangents.end_tangent);
}

const VectorPathTangents = struct {
    start: render_ir.Point,
    start_tangent: render_ir.Point,
    end: render_ir.Point,
    end_tangent: render_ir.Point,
};

fn vectorPathTangents(path: core.Path, mapping: PathMapping) ?VectorPathTangents {
    var current: ?render_ir.Point = null;
    var subpath_start: ?render_ir.Point = null;
    var result: ?VectorPathTangents = null;
    for (path.commands) |command| switch (command) {
        .move_to => |point| {
            current = mapping.point(point);
            subpath_start = current;
        },
        .line_to => |point| {
            const previous = current orelse continue;
            const next = mapping.point(point);
            if (pointsDiffer(previous, next)) {
                if (result == null) result = .{
                    .start = previous,
                    .start_tangent = next,
                    .end = next,
                    .end_tangent = previous,
                } else if (result) |*value| {
                    value.end = next;
                    value.end_tangent = previous;
                }
            }
            current = next;
        },
        .cubic_to => |cubic| {
            const previous = current orelse continue;
            const control1 = mapping.point(cubic.control1);
            const control2 = mapping.point(cubic.control2);
            const next = mapping.point(cubic.end);
            if (pointsDiffer(previous, next)) {
                if (result == null) result = .{
                    .start = previous,
                    .start_tangent = if (pointsDiffer(previous, control1)) control1 else next,
                    .end = next,
                    .end_tangent = if (pointsDiffer(control2, next)) control2 else previous,
                } else if (result) |*value| {
                    value.end = next;
                    value.end_tangent = if (pointsDiffer(control2, next)) control2 else previous;
                }
            }
            current = next;
        },
        .close => {
            const previous = current orelse continue;
            const next = subpath_start orelse continue;
            if (pointsDiffer(previous, next)) {
                if (result == null) result = .{
                    .start = previous,
                    .start_tangent = next,
                    .end = next,
                    .end_tangent = previous,
                } else if (result) |*value| {
                    value.end = next;
                    value.end_tangent = previous;
                }
            }
            current = next;
        },
    };
    return result;
}

const PathMapping = struct {
    xx: f64,
    yx: f64,
    xy: f64,
    yy: f64,
    x0: f64,
    y0: f64,
    radius_scale: f64,

    fn point(self: PathMapping, value: core.PathPoint) render_ir.Point {
        return .{
            .x = self.xx * value.x + self.xy * value.y + self.x0,
            .y = self.yx * value.x + self.yy * value.y + self.y0,
        };
    }
};

const identity_path_mapping = PathMapping{
    .xx = 1,
    .yx = 0,
    .xy = 0,
    .yy = 1,
    .x0 = 0,
    .y0 = 0,
    .radius_scale = 1,
};

fn drawStyledPath(
    ctx: *DrawContext,
    path: core.Path,
    mapping: PathMapping,
    fill: core.render_policy.VectorFillPaint,
    stroke_paint: ?core.render_policy.VectorStrokePaint,
) !void {
    var commands = try renderPathCommands(ctx.allocator, path, mapping);
    defer commands.deinit(ctx.allocator);
    if (commands.items.len == 0) return;

    var stops: [2]render_ir.GradientStop = undefined;
    var base: render_ir.BaseFillPaint = .{ .none = {} };
    switch (fill.kind) {
        .none => {},
        .solid => {
            if (fill.color) |color| base = .{ .solid = color };
        },
        .linear => {
            if (fill.color) |color1| if (fill.color2) |color2| {
                stops = .{ .{ .offset = 0, .color = color1 }, .{ .offset = 1, .color = color2 } };
                base = .{ .linear = .{
                    .start = paintPoint(fill.space, mapping, fill.start_x, fill.start_y),
                    .end = paintPoint(fill.space, mapping, fill.end_x, fill.end_y),
                    .stops = &stops,
                    .spread = @enumFromInt(@intFromEnum(fill.spread)),
                } };
            };
        },
        .radial => {
            if (fill.color) |color1| if (fill.color2) |color2| {
                stops = .{ .{ .offset = 0, .color = color1 }, .{ .offset = 1, .color = color2 } };
                base = .{ .radial = .{
                    .start_center = paintPoint(fill.space, mapping, fill.start_x, fill.start_y),
                    .start_radius = paintRadius(fill.space, mapping, fill.start_radius),
                    .end_center = paintPoint(fill.space, mapping, fill.end_x, fill.end_y),
                    .end_radius = paintRadius(fill.space, mapping, fill.end_radius),
                    .stops = &stops,
                    .spread = @enumFromInt(@intFromEnum(fill.spread)),
                } };
            };
        },
    }

    var pattern_commands = std.ArrayList(render_ir.PathCommand).empty;
    defer pattern_commands.deinit(ctx.allocator);
    var pattern_dash_storage: [8]f64 = @splat(0);
    var overlay: ?render_ir.TilePatternPaint = null;
    if (fill.pattern) |pattern| {
        pattern_commands = try renderPathCommands(ctx.allocator, pattern.path, identity_path_mapping);
        overlay = .{
            .commands = pattern_commands.items,
            .cell_width = pattern.cell_width,
            .cell_height = pattern.cell_height,
            .transform = .{
                .xx = pattern.xx,
                .yx = pattern.yx,
                .xy = pattern.xy,
                .yy = pattern.yy,
                .x0 = pattern.x0 + if (pattern.space == .local) mapping.x0 else 0,
                .y0 = pattern.y0 + if (pattern.space == .local) mapping.y0 else 0,
            },
            .fill = pattern.fill,
            .stroke = if (pattern.stroke) |stroke| renderStroke(stroke, &pattern_dash_storage) else null,
        };
    }

    var dash_storage: [8]f64 = @splat(0);
    const stroke = if (stroke_paint) |value| renderStroke(value, &dash_storage) else null;
    try activeEmitter(ctx).vectorPath(ctx.allocator, commands.items, .{
        .base = base,
        .overlay = overlay,
        .rule = @enumFromInt(@intFromEnum(fill.rule)),
        .opacity = fill.opacity,
    }, stroke);
}

fn paintPoint(space: core.render_policy.PaintSpace, mapping: PathMapping, x: f32, y: f32) render_ir.Point {
    if (space == .page) return .{ .x = x, .y = y };
    return mapping.point(.{ .x = x, .y = y });
}

fn paintRadius(space: core.render_policy.PaintSpace, mapping: PathMapping, value: f32) f64 {
    return if (space == .page) value else mapping.radius_scale * value;
}

fn drawConnectorOp(ctx: *DrawContext, paint: ConnectorPaint) !void {
    const commands = ctx.commands orelse return;
    const source_frame = commandFrame(commands, paint.source) orelse return;
    const target_frame = commandFrame(commands, paint.target) orelse return;
    const start = connectorAnchorPoint(source_frame, paint.source_anchor);
    const end = connectorAnchorPoint(target_frame, paint.target_anchor);

    var path_commands: [4]render_ir.PathCommand = undefined;
    var path_len: usize = 0;
    var start_tangent = end;
    var end_tangent = start;
    path_commands[path_len] = .{ .move_to = start };
    path_len += 1;
    switch (paint.route) {
        .straight => {
            path_commands[path_len] = .{ .line_to = end };
            path_len += 1;
        },
        .horizontal_then_vertical => {
            const middle = render_ir.Point{ .x = end.x, .y = start.y };
            path_commands[path_len] = .{ .line_to = middle };
            path_len += 1;
            path_commands[path_len] = .{ .line_to = end };
            path_len += 1;
            start_tangent = if (pointsDiffer(start, middle)) middle else end;
            end_tangent = if (pointsDiffer(middle, end)) middle else start;
        },
        .vertical_then_horizontal => {
            const middle = render_ir.Point{ .x = start.x, .y = end.y };
            path_commands[path_len] = .{ .line_to = middle };
            path_len += 1;
            path_commands[path_len] = .{ .line_to = end };
            path_len += 1;
            start_tangent = if (pointsDiffer(start, middle)) middle else end;
            end_tangent = if (pointsDiffer(middle, end)) middle else start;
        },
        .curve => {
            const amount = std.math.clamp(@as(f64, paint.curve), 0, 1);
            const distance = std.math.hypot(end.x - start.x, end.y - start.y) * amount;
            const source_direction = connectorDirection(paint.source_anchor, start, end);
            const target_direction = connectorDirection(paint.target_anchor, end, start);
            const control1 = render_ir.Point{
                .x = start.x + source_direction.x * distance,
                .y = start.y + source_direction.y * distance,
            };
            const control2 = render_ir.Point{
                .x = end.x + target_direction.x * distance,
                .y = end.y + target_direction.y * distance,
            };
            path_commands[path_len] = .{ .cubic_to = .{ .control1 = control1, .control2 = control2, .end = end } };
            path_len += 1;
            start_tangent = control1;
            end_tangent = control2;
        },
    }

    var dash_storage: [8]f64 = @splat(0);
    const stroke = renderStroke(paint.stroke, &dash_storage);
    try activeEmitter(ctx).vectorPath(ctx.allocator, path_commands[0..path_len], .{}, stroke);
    if (paint.marker_start) |marker| try drawMarker(ctx, marker, start, start_tangent);
    if (paint.marker_end) |marker| try drawMarker(ctx, marker, end, end_tangent);
}

fn drawMarker(ctx: *DrawContext, marker: MarkerPaint, tip: render_ir.Point, tangent: render_ir.Point) !void {
    const dx = tip.x - tangent.x;
    const dy = tip.y - tangent.y;
    const length = std.math.hypot(dx, dy);
    const direction = if (length == 0)
        render_ir.Point{ .x = 1, .y = 0 }
    else
        render_ir.Point{ .x = dx / length, .y = dy / length };
    const perpendicular = render_ir.Point{ .x = -direction.y, .y = direction.x };
    const xx = direction.x * marker.width;
    const yx = direction.y * marker.width;
    const xy = perpendicular.x * marker.height;
    const yy = perpendicular.y * marker.height;
    try drawStyledPath(ctx, marker.path, .{
        .xx = xx,
        .yx = yx,
        .xy = xy,
        .yy = yy,
        .x0 = tip.x - xx - xy * 0.5,
        .y0 = tip.y - yx - yy * 0.5,
        .radius_scale = @min(marker.width, marker.height),
    }, marker.fill, marker.stroke);
}

fn connectorDirection(anchor: core.render_policy.ConnectorAnchor, point: render_ir.Point, other: render_ir.Point) render_ir.Point {
    return switch (anchor) {
        .left => .{ .x = -1, .y = 0 },
        .right => .{ .x = 1, .y = 0 },
        .top => .{ .x = 0, .y = -1 },
        .bottom => .{ .x = 0, .y = 1 },
        .center => blk: {
            const dx = other.x - point.x;
            const dy = other.y - point.y;
            const length = std.math.hypot(dx, dy);
            if (length == 0) break :blk .{ .x = 1, .y = 0 };
            break :blk .{ .x = dx / length, .y = dy / length };
        },
    };
}

fn pointsDiffer(left: render_ir.Point, right: render_ir.Point) bool {
    return left.x != right.x or left.y != right.y;
}

fn commandFrame(commands: []const ObjectCommand, node_id: core.NodeId) ?Frame {
    for (commands) |command| if (command.node_id == node_id) return command.frame;
    return null;
}

fn connectorAnchorPoint(frame: Frame, anchor: core.render_policy.ConnectorAnchor) render_ir.Point {
    const left = @as(f64, frame.x);
    const right = @as(f64, frame.x + frame.width);
    const top = @as(f64, toTopY(frame.y + frame.height));
    const bottom = @as(f64, toTopY(frame.y));
    return switch (anchor) {
        .center => .{ .x = (left + right) / 2, .y = (top + bottom) / 2 },
        .left => .{ .x = left, .y = (top + bottom) / 2 },
        .right => .{ .x = right, .y = (top + bottom) / 2 },
        .top => .{ .x = (left + right) / 2, .y = top },
        .bottom => .{ .x = (left + right) / 2, .y = bottom },
    };
}

fn renderPathCommands(allocator: Allocator, path: core.Path, mapping: PathMapping) !std.ArrayList(render_ir.PathCommand) {
    var result = std.ArrayList(render_ir.PathCommand).empty;
    errdefer result.deinit(allocator);
    for (path.commands) |command| {
        const converted: render_ir.PathCommand = switch (command) {
            .move_to => |point| .{ .move_to = mapping.point(point) },
            .line_to => |point| .{ .line_to = mapping.point(point) },
            .cubic_to => |cubic| .{ .cubic_to = .{
                .control1 = mapping.point(cubic.control1),
                .control2 = mapping.point(cubic.control2),
                .end = mapping.point(cubic.end),
            } },
            .close => .{ .close = {} },
        };
        try result.append(allocator, converted);
    }
    return result;
}

fn renderStroke(paint: core.render_policy.VectorStrokePaint, storage: *[8]f64) render_ir.StrokePaint {
    for (paint.dash.slice(), 0..) |value, index| storage[index] = value;
    return .{
        .color = paint.color,
        .width = paint.width,
        .cap = @enumFromInt(@intFromEnum(paint.cap)),
        .join = @enumFromInt(@intFromEnum(paint.join)),
        .miter_limit = paint.miter_limit,
        .dash = storage[0..paint.dash.count],
        .dash_offset = paint.dash.offset,
    };
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
        if (!ctx.capture_measurement_content) return;
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
        if (!ctx.capture_measurement_content) return;
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
            .block_quote => cursor_bl = try drawMarkdownQuote(ctx, frame, cursor_bl, block, text, list_depth),
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

fn markdownQuoteText(text: TextPaint) TextPaint {
    var result = text;
    if (text.markdown_quote.color) |color| result.color = color;
    return result;
}

fn drawMarkdownQuote(ctx: *DrawContext, frame: Frame, baseline_bl: f32, block: *const Block, text: TextPaint, list_depth: usize) !f32 {
    const quote = block.quote orelse return baseline_bl;
    const paint = text.markdown_quote;
    const quote_x = frame.x + paint.inset;
    const quote_width = @max(frame.width - paint.inset, 1);
    const content_x = quote_x + paint.pad_x;
    const content_width = @max(quote_width - paint.pad_x * 2, 1);
    const quote_text = markdownQuoteText(text);
    const content_height = try measureMarkdownBlocksLogicalHeight(ctx, quote.blocks.items, quote_text, content_width, list_depth);
    const outer_baseline_from_top = try lineBaselineFromTop(ctx, text.font, text.font_size, text.line_height);
    const box_top = baseline_bl + outer_baseline_from_top;
    const box_height = paint.pad_y * 2 + content_height;
    const box_bottom = box_top - box_height;
    const quote_frame = Frame{ .x = quote_x, .y = box_bottom, .width = quote_width, .height = box_height };

    if (paint.fill != null) try drawRoundedRect(ctx, quote_frame, paint.radius, paint.fill, null, 0);
    if (paint.bar_color) |bar_color| {
        if (paint.bar_width > 0) {
            const top = topOf(quote_frame) + paint.bar_width / 2;
            const bottom = topOf(quote_frame) + quote_frame.height - paint.bar_width / 2;
            const dash = paint.bar_dash;
            try strokeLine(ctx, quote_x + paint.bar_width / 2, top, quote_x + paint.bar_width / 2, @max(bottom, top), paint.bar_width, bar_color, if (dash) |value| value.on else 0, if (dash) |value| value.off else 0);
        }
    }

    const first_text = markdownFirstBlockText(quote_text, quote.blocks.items);
    const first_baseline_from_top = try lineBaselineFromTop(ctx, first_text.font, first_text.font_size, first_text.line_height);
    const first_baseline_bl = box_top - paint.pad_y - first_baseline_from_top;
    const content_frame = Frame{ .x = content_x, .y = frame.y, .width = content_width, .height = frame.height };
    _ = try drawMarkdownBlocksAt(ctx, content_frame, first_baseline_bl, quote.blocks.items, quote_text, list_depth);
    return box_bottom - outer_baseline_from_top;
}

fn measureMarkdownBlocksLogicalHeight(ctx: *DrawContext, blocks: []const *Block, text: TextPaint, width: f32, list_depth: usize) !f32 {
    if (blocks.len == 0) return text.line_height;
    const baseline_bl = Defaults.height * 0.5;
    var measurement = MeasurementScope.init(ctx);
    try measurement.begin();
    defer measurement.deinit();
    const frame = Frame{ .x = 0, .y = 0, .width = width, .height = Defaults.height };
    const next_bl = try drawMarkdownBlocksAt(ctx, frame, baseline_bl, blocks, text, list_depth);
    return @max(baseline_bl - next_bl, text.line_height);
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
        if (utils.highlight.findLanguage(ctx.highlight_languages, language) != null) {
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
            .block_quote => {
                const quote = block.quote orelse continue;
                const quote_text = markdownQuoteText(text);
                if (try markdownBlocksNaturalInlineAdvance(ctx, quote.blocks.items, quote_text, list_depth)) |width| {
                    max_width = @max(max_width, text.markdown_quote.inset + text.markdown_quote.pad_x * 2 + width);
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
            .block_quote => try markdownQuoteConstrainedLogicalWidth(ctx, block, text, list_depth, width),
            .bullet_list, .ordered_list => try markdownListConstrainedLogicalWidth(ctx, block, text, list_depth, width),
            .table => try markdownTableConstrainedLogicalWidth(ctx, block, text, width),
        };
        max_width = @max(max_width, block_width);
    }
    return max_width;
}

fn markdownQuoteConstrainedLogicalWidth(ctx: *DrawContext, block: *const Block, text: TextPaint, list_depth: usize, width: f32) !f32 {
    const quote = block.quote orelse return 0;
    const paint = text.markdown_quote;
    const quote_width = @max(width - paint.inset, 1);
    const content_width = @max(quote_width - paint.pad_x * 2, 1);
    const child_width = try markdownBlocksConstrainedLogicalWidth(ctx, quote.blocks.items, markdownQuoteText(text), list_depth, content_width);
    return paint.inset + paint.pad_x * 2 + child_width;
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
            const asset = try renderLatexToPdf(ctx, source_text, ctx.latex_preamble, ctx.latex_engine, .display_math);
            defer ctx.allocator.free(asset.path);
            const fitted = fitDisplayMathBlockSize(asset.width, asset.height, width, text);
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
    var atom_count = atoms.items.len;
    for (runs) |run| {
        atom_count += switch (run.kind) {
            .math, .display_math => 1,
            .icon => @intFromBool(run.icon != null),
            .bold, .italic, .code, .link, .text => countTextTokens(run.text),
        };
    }
    try atoms.ensureTotalCapacity(ctx.allocator, atom_count);

    for (runs) |run| {
        switch (run.kind) {
            .math, .display_math => {
                try appendMathAtom(ctx, atoms, run.text, text, if (run.kind == .display_math) .display_math else .inline_math);
            },
            .icon => if (run.icon) |source| try appendIconAtom(ctx, atoms, source, text),
            .bold => try appendTextAtoms(ctx, atoms, run.text, text.bold_font, text.markdown_bold_color orelse text.color, text.font_size, null, run.strikethrough, run.underline, text.markdown_underline, .{ .start = run.source_start, .end = run.source_end }),
            .italic => try appendTextAtoms(ctx, atoms, run.text, text.italic_font, text.color, text.font_size, null, run.strikethrough, run.underline, text.markdown_underline, .{ .start = run.source_start, .end = run.source_end }),
            .code => try appendTextAtoms(ctx, atoms, run.text, text.code_font, text.color, text.font_size, null, run.strikethrough, run.underline, text.markdown_underline, .{ .start = run.source_start, .end = run.source_end }),
            .link => try appendTextAtoms(ctx, atoms, run.text, text.font, text.link_color, text.font_size, run.url, run.strikethrough, true, .{}, .{ .start = run.source_start, .end = run.source_end }),
            .text => try appendTextAtoms(ctx, atoms, run.text, text.font, text.color, text.font_size, null, run.strikethrough, run.underline, text.markdown_underline, .{ .start = run.source_start, .end = run.source_end }),
        }
    }
}

fn countTextTokens(value: []const u8) usize {
    var count: usize = 0;
    var tokenizer = text_tokenize.Tokenizer.init(value);
    while (tokenizer.next() != null) count += 1;
    return count;
}

fn subsliceOffset(value: []const u8, subslice: []const u8) ?usize {
    const value_start = @intFromPtr(value.ptr);
    const subslice_start = @intFromPtr(subslice.ptr);
    if (subslice_start < value_start) return null;
    const offset = subslice_start - value_start;
    if (offset > value.len or subslice.len > value.len - offset) return null;
    return offset;
}

fn recordTextFailureRange(
    failure: *CommandFailure,
    content_range: ?ContentRange,
    value: []const u8,
    token: []const u8,
) void {
    const run_range = content_range orelse return;
    const synthetic_font = if (failure.text_failure.synthetic_font) |*detail| detail else {
        failure.recordContentRange(run_range.start, run_range.end);
        return;
    };
    const token_offset = subsliceOffset(value, token) orelse {
        failure.recordContentRange(run_range.start, run_range.end);
        return;
    };
    const resolved = synthetic_font.contentRange(run_range, token_offset);
    failure.recordContentRange(resolved.start, resolved.end);
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
    const asset = try renderLatexToPdf(ctx, source, ctx.latex_preamble, ctx.latex_engine, .display_math);
    defer ctx.allocator.free(asset.path);
    const fitted = fitDisplayMathBlockSize(asset.width, asset.height, width, text);
    const draw_width = fitted.width;
    const draw_height = fitted.height;
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
    try placeLatexPdf(ctx, draw_frame, asset.path, asset.page_index);
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

fn appendTextAtoms(
    ctx: *DrawContext,
    atoms: *std.ArrayList(Atom),
    value: []const u8,
    font: FontFace,
    color: Color,
    font_size: f32,
    link_url: ?[]const u8,
    strikethrough: bool,
    underline: bool,
    underline_paint: core.render_policy.MarkdownUnderlinePaint,
    content_range: ?ContentRange,
) !void {
    var tokenizer = text_tokenize.Tokenizer.init(value);
    while (tokenizer.next()) |token| {
        const is_emoji = text_tokenize.isEmojiToken(token);
        var shaped_layout: ?render_ir.TextLayout = null;
        errdefer if (shaped_layout) |*layout| layout.deinit(ctx.allocator);
        const width = if (ctx.capture_measurement_content or ctx.measurement_bounds == null) blk: {
            const emitter = activeEmitter(ctx);
            const had_synthetic_font = if (emitter.text_failure) |failure|
                failure.synthetic_font != null
            else
                false;
            const shape_result = if (emitter.text_failure) |failure|
                render_text.shapeWithFailure(
                    ctx.allocator,
                    ctx.io,
                    emitter.resources,
                    emitter.fonts,
                    token,
                    font,
                    font_size,
                    0,
                    false,
                    emitter.text_cache,
                    failure,
                )
            else
                render_text.shape(
                    ctx.allocator,
                    ctx.io,
                    emitter.resources,
                    emitter.fonts,
                    token,
                    font,
                    font_size,
                    0,
                    false,
                    emitter.text_cache,
                );
            shaped_layout = try shape_result;
            if (!had_synthetic_font) {
                if (ctx.command_failure) |failure| {
                    if (failure.text_failure.synthetic_font != null) {
                        recordTextFailureRange(failure, content_range, value, token);
                    }
                }
            }
            const layout = &shaped_layout.?;
            const logical_width: f32 = @floatCast(layout.logical_bounds.width);
            if (!is_emoji) break :blk logical_width;
            const ink_right: f32 = @floatCast(layout.ink_bounds.x + layout.ink_bounds.width);
            break :blk @max(logical_width, ink_right);
        } else if (is_emoji)
            try measureTextVisualWidth(ctx, token, font, font_size)
        else
            try measureText(ctx, token, font, font_size);
        try atoms.append(ctx.allocator, .{
            .content = .{ .text = shaped_layout },
            .text = token,
            .font = font,
            .color = color,
            .width = width,
            .is_space = text_tokenize.isWhitespace(token),
            .is_emoji = is_emoji,
            .strikethrough = strikethrough,
            .underline = underline,
            .underline_paint = underline_paint,
            .link_url = link_url,
        });
        shaped_layout = null;
    }
}

fn appendMathAtom(ctx: *DrawContext, atoms: *std.ArrayList(Atom), value: []const u8, text: TextPaint, kind: LatexFragmentKind) !void {
    const target_height = @max(text.font_size * text.inline_math_height_factor, 1);
    const asset = try renderLatexToPdf(ctx, value, ctx.latex_preamble, ctx.latex_engine, kind);
    errdefer ctx.allocator.free(asset.path);
    const scale = if (asset.reference_height > 0) target_height / asset.reference_height else 1;
    try atoms.append(ctx.allocator, .{
        .content = .{ .latex = .{ .path = asset.path, .page_index = asset.page_index } },
        .text = value,
        .font = text.font,
        .color = text.color,
        .width = @max(asset.width * scale, 1),
        .height = @max(asset.height * scale, 1),
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
        .font = text.font,
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
    try positions.ensureTotalCapacity(ctx.allocator, atoms.len);
    var lines = std.ArrayList(AtomVisualLine).empty;
    defer lines.deinit(ctx.allocator);
    try lines.ensureTotalCapacity(ctx.allocator, atoms.len);

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
    const default_ascent = try lineBaselineFromTop(ctx, paint.font, paint.font_size, paint.line_height);
    const default_descent = @max(paint.line_height - default_ascent, 0);
    for (lines.items) |*line| {
        line.ascent = default_ascent;
        line.descent = default_descent;
        for (positions.items[line.start..line.end]) |position| {
            const extents = atomVerticalExtents(&atoms[position.index], default_ascent, default_descent);
            line.ascent = @max(line.ascent, extents.ascent);
            line.descent = @max(line.descent, extents.descent);
        }
    }

    var line_bl = baseline_bl - @max(lines.items[0].ascent - default_ascent, 0);
    for (lines.items, 0..) |line, line_index| {
        if (line_index > 0) {
            const previous = lines.items[line_index - 1];
            line_bl -= @max(paint.line_height, previous.descent + line.ascent);
        }
        const line_x = alignedX(x, width, line.width, horizontal_align);
        for (positions.items[line.start..line.end]) |position| {
            try drawPositionedAtom(ctx, &atoms[position.index], line_x + position.offset, line_bl, paint);
        }
    }
    const last = lines.items[lines.items.len - 1];
    return line_bl - @max(paint.line_height, last.descent + default_ascent);
}

fn appendAtomVisualLine(allocator: Allocator, lines: *std.ArrayList(AtomVisualLine), start: usize, end: usize, width: f32) !void {
    if (start == end) return;
    try lines.append(allocator, .{
        .start = start,
        .end = end,
        .width = width,
    });
}

const AtomVerticalExtents = struct {
    ascent: f32,
    descent: f32,
};

fn atomVerticalExtents(atom: *const Atom, default_ascent: f32, default_descent: f32) AtomVerticalExtents {
    return switch (atom.content) {
        .text => .{ .ascent = default_ascent, .descent = default_descent },
        .latex, .icon => .{
            .ascent = @max(atom.height - atom.baseline_from_bottom, 0),
            .descent = @max(atom.baseline_from_bottom, 0),
        },
    };
}

fn drawPositionedAtom(ctx: *DrawContext, atom: *Atom, x: f32, baseline_bl: f32, paint: AtomPaint) !void {
    switch (atom.content) {
        .text => {
            const y_top = baselineTop(baseline_bl, paint.font_size);
            if (atom.link_url) |url| {
                try drawLinkedRawText(ctx, x, y_top, @max(atom.width, 1), paint.line_height, atom, paint, url);
            } else {
                try drawAtomRawText(ctx, x, y_top, @max(atom.width + paint.font_size, 1), atom, paint, false);
            }
        },
        .latex => |latex| {
            const frame = Frame{ .x = x, .y = baseline_bl - atom.baseline_from_bottom, .width = atom.width, .height = atom.height };
            try placeLatexPdf(ctx, frame, latex.path, latex.page_index);
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
        .latex => atom.width + paint.font_size * paint.inline_math_spacing,
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
    try appendTextAtoms(ctx, &atoms, content, font, color, font_size, null, false, false, .{}, null);
    const paint = AtomPaint{
        .font = font,
        .font_size = font_size,
        .line_height = line_height,
        .emoji_spacing = emoji_spacing,
        .inline_math_spacing = 0,
    };
    const baseline_bl = Defaults.height - (y_top + font_size);
    _ = try drawAtomsWithOptions(ctx, x, baseline_bl, width, atoms.items, paint, wrap, preserve_leading_space, .left);
    return atomLineAdvance(atoms.items, paint);
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

    var failure: syntax_highlight.Failure = .none;
    var spans = syntax_highlight.collectSpans(
        ctx.allocator,
        ctx.io,
        ctx.highlight_languages,
        language,
        content,
        &failure,
    ) catch |err| {
        try recordSyntaxHighlightFailure(ctx, failure);
        return err;
    };
    defer spans.deinit(ctx.allocator);

    var cursor_bl = first_baseline_bl;
    var lines = utils.source.lineIterator(content);
    while (lines.next()) |line_view| {
        const line = line_view.text(content);
        if (trim_trailing_empty_line and line.len == 0 and line_view.raw_end == content.len and content.len > 0 and content[content.len - 1] == '\n') break;
        const line_start = line_view.span.start;
        const line_end = line_view.span.end;
        try drawHighlightedCodeLine(ctx, x, baselineTop(cursor_bl, font_size), width, content, line_start, line_end, spans.items, font, font_size, line_height, code, emoji_spacing);
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
    spans: []const syntax_highlight.Span,
    font: FontFace,
    font_size: f32,
    line_height: f32,
    code: CodePaint,
    emoji_spacing: f32,
) !void {
    var cursor_x = x;
    var pos = line_start;
    _ = width;
    while (pos < line_end) {
        var next = syntax_highlight.nextBoundary(spans, pos, line_end);
        if (next <= pos) next = @min(pos + 1, line_end);
        const color = if (syntax_highlight.roleAt(spans, pos, next)) |role| colorForHighlightRole(code, role) else code.plain;
        try drawCodeSegment(ctx, &cursor_x, y_top, content[pos..next], font, font_size, line_height, color, emoji_spacing);
        pos = next;
    }
}

fn recordSyntaxHighlightFailure(ctx: *DrawContext, failure: syntax_highlight.Failure) !void {
    const command_failure = ctx.command_failure orelse return;
    const message = try failure.messageAlloc(ctx.allocator) orelse return;
    defer ctx.allocator.free(message);
    try command_failure.record(message);
}

fn colorForHighlightRole(code: CodePaint, role: utils.highlight.CaptureRole) Color {
    return switch (role) {
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
        if (utils.highlight.findLanguage(ctx.highlight_languages, language) != null) {
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

fn drawLatexCommand(ctx: *DrawContext, command: *const ObjectCommand, frame: Frame, latex: LatexPaint) !void {
    const asset = try renderLatexToPdf(ctx, command.content, command.latex_preamble, command.latex_engine, command.latex_kind);
    defer ctx.allocator.free(asset.path);
    const fitted = fitLatexSize(asset.width, asset.height, frame.width, frame.height, latex);
    const draw_frame = Frame{
        .x = alignedX(frame.x, frame.width, fitted.width, latex.horizontal_align),
        .y = frame.y + @max((frame.height - fitted.height) / 2, 0),
        .width = fitted.width,
        .height = fitted.height,
    };
    try placeLatexPdf(ctx, draw_frame, asset.path, asset.page_index);
}

fn requiredLatexPaint(command: *const ObjectCommand) !LatexPaint {
    if (command.render.kind != .latex) return NativePdfError.InvalidRenderPolicy;
    return command.render.latex orelse NativePdfError.InvalidRenderPolicy;
}

fn drawVectorAsset(ctx: *DrawContext, frame: Frame, content: []const u8, asset: ?core.render_policy.AssetPaint) !void {
    if (core.fontawesome.parseSource(content) != null) {
        const icon = try renderIconToSvg(ctx, content);
        defer ctx.allocator.free(icon.path);
        try drawSvgFrame(ctx, frame, icon.path, if (asset) |paint| paint.tint else null);
        return;
    }
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
            .tint = null,
            .pdf_page = 1,
            .pdf_box = .crop,
        };
        const rect = render_ir.Rect{ .x = fitted.x, .y = topOf(fitted), .width = fitted.width, .height = fitted.height };
        if (ctx.measurement_bounds) |bounds| {
            bounds.include(rect);
            if (!ctx.capture_measurement_content) return;
        }
        try activeEmitter(ctx).pdfPage(ctx.allocator, rect, source, paint.pdf_page - 1, paint.pdf_box, true);
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
        if (ctx.capture_measurement_content) {
            try activeEmitter(ctx).textBaseline(ctx.allocator, x, baseline_y, width, content, font, font_size, color, wrap, decoration);
            return;
        }
        const measurement = try text_measure.layout(ctx.allocator, content, font, font_size, width, wrap, .{
            .strikethrough = decoration.strikethrough,
            .underline = decoration.underline,
            .underline_opacity = @floatCast(decoration.underline_opacity),
            .underline_width = if (decoration.underline_width) |value| @floatCast(value) else null,
            .underline_offset = @floatCast(decoration.underline_offset),
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

fn drawAtomRawText(ctx: *DrawContext, x: f32, y_top: f32, width: f32, atom: *Atom, paint: AtomPaint, wrap: bool) !void {
    const dash = atom.underline_paint.dash;
    const decoration = render_emitter.TextDecoration{
        .strikethrough = atom.strikethrough,
        .underline = atom.underline,
        .underline_color = atom.underline_paint.color,
        .underline_opacity = atom.underline_paint.opacity,
        .underline_width = if (atom.underline_paint.width) |value| @as(f64, value) else null,
        .underline_offset = atom.underline_paint.offset,
        .underline_dash_on = if (dash) |value| value.on else 0,
        .underline_dash_off = if (dash) |value| value.off else 0,
    };
    if (atom.content.text) |layout| {
        atom.content.text = null;
        try activeEmitter(ctx).textLayoutBaseline(
            ctx.allocator,
            x,
            y_top + paint.font_size,
            width,
            layout,
            paint.font_size,
            atom.color,
            decoration,
        );
        return;
    }
    try drawRawText(ctx, x, y_top, width, atom.text, atom.font, paint.font_size, atom.color, wrap, .{
        .strikethrough = decoration.strikethrough,
        .underline = decoration.underline,
        .underline_color = decoration.underline_color,
        .underline_opacity = decoration.underline_opacity,
        .underline_width = decoration.underline_width,
        .underline_offset = decoration.underline_offset,
        .underline_dash_on = decoration.underline_dash_on,
        .underline_dash_off = decoration.underline_dash_off,
    });
}

fn drawLinkedRawText(
    ctx: *DrawContext,
    x: f32,
    y_top: f32,
    link_width: f32,
    height: f32,
    atom: *Atom,
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
        if (!ctx.capture_measurement_content) return;
    }
    try activeEmitter(ctx).raster(ctx.allocator, rect, source);
}

fn drawSvgNatural(ctx: *DrawContext, frame: Frame, svg_path: []const u8, asset: ?core.render_policy.AssetPaint) !void {
    const svg = try svgAsset(ctx, svg_path);
    const fitted = naturalAssetFrame(frame, scaledAssetSize(.{ .width = svg.width, .height = svg.height }, asset));
    const rect = render_ir.Rect{ .x = fitted.x, .y = topOf(fitted), .width = fitted.width, .height = fitted.height };
    if (ctx.measurement_bounds) |bounds| {
        bounds.include(rect);
        if (!ctx.capture_measurement_content) return;
    }
    try activeEmitter(ctx).svg(ctx.allocator, rect, svg_path, if (asset) |paint| paint.tint else null);
}

fn drawSvgFrameTinted(ctx: *DrawContext, frame: Frame, svg_path: []const u8, color: Color) !void {
    try drawSvgFrame(ctx, frame, svg_path, color);
}

fn drawSvgFrame(ctx: *DrawContext, frame: Frame, svg_path: []const u8, tint: ?Color) !void {
    const rect = render_ir.Rect{ .x = frame.x, .y = topOf(frame), .width = frame.width, .height = frame.height };
    if (ctx.measurement_bounds) |bounds| {
        bounds.include(rect);
        if (!ctx.capture_measurement_content) return;
    }
    try activeEmitter(ctx).svg(ctx.allocator, rect, svg_path, tint);
}

fn placeLatexPdf(
    ctx: *DrawContext,
    frame: Frame,
    path: []const u8,
    page_index: usize,
) !void {
    const rect = render_ir.Rect{ .x = frame.x, .y = topOf(frame), .width = frame.width, .height = frame.height };
    if (ctx.measurement_bounds) |bounds| {
        bounds.include(rect);
        if (!ctx.capture_measurement_content) return;
    }
    try activeEmitter(ctx).latexPdf(ctx.allocator, rect, path, page_index);
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
            .latex_pdf => |value| value,
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

fn cachedLatexReference(ctx: *DrawContext, reference_path: []const u8) !?LatexAsset {
    if (!fileExists(reference_path)) return null;
    return readLatexReference(ctx, reference_path) catch |err| switch (err) {
        error.InvalidPdfCache => {
            deleteFileIfExists(ctx, reference_path);
            return null;
        },
        else => return err,
    };
}

fn readLatexReference(ctx: *DrawContext, reference_path: []const u8) !LatexAsset {
    const contents = utils.fs.readFileAllocLimited(ctx.io, ctx.allocator, reference_path, .limited(4096)) catch return NativePdfError.InvalidPdfCache;
    defer ctx.allocator.free(contents);
    const trimmed = std.mem.trim(u8, contents, " \t\r\n");
    var fields = std.mem.splitScalar(u8, trimmed, '\t');
    const page_text = fields.next() orelse return NativePdfError.InvalidPdfCache;
    const width_text = fields.next() orelse return NativePdfError.InvalidPdfCache;
    const height_text = fields.next() orelse return NativePdfError.InvalidPdfCache;
    const baseline_text = fields.next() orelse return NativePdfError.InvalidPdfCache;
    const reference_height_text = fields.next() orelse return NativePdfError.InvalidPdfCache;
    const pdf_name = fields.next() orelse return NativePdfError.InvalidPdfCache;
    if (fields.next() != null or pdf_name.len == 0 or !std.mem.eql(u8, std.fs.path.basename(pdf_name), pdf_name)) {
        return NativePdfError.InvalidPdfCache;
    }
    const page_index = std.fmt.parseInt(usize, page_text, 10) catch return NativePdfError.InvalidPdfCache;
    const width = std.fmt.parseFloat(f32, width_text) catch return NativePdfError.InvalidPdfCache;
    const height = std.fmt.parseFloat(f32, height_text) catch return NativePdfError.InvalidPdfCache;
    const baseline_from_bottom = std.fmt.parseFloat(f32, baseline_text) catch return NativePdfError.InvalidPdfCache;
    const reference_height = std.fmt.parseFloat(f32, reference_height_text) catch return NativePdfError.InvalidPdfCache;
    if (!std.math.isFinite(width) or !std.math.isFinite(height) or !std.math.isFinite(baseline_from_bottom) or !std.math.isFinite(reference_height) or
        width <= 0 or height <= 0 or reference_height <= 0)
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
        .reference_height = reference_height,
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

fn fitLatexSize(source_width: f32, source_height: f32, max_width: f32, max_height: f32, latex: LatexPaint) Size {
    if (source_width <= 0 or source_height <= 0) return .{ .width = max_width, .height = max_height };
    return fitLatexObjectSize(source_width, source_height, max_width, max_height, latex);
}

fn fitLatexObjectSize(source_width: f32, source_height: f32, max_width: f32, max_height: f32, paint: LatexPaint) Size {
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

fn renderLatexToPdf(
    ctx: *DrawContext,
    source: []const u8,
    preamble: []const LatexPreambleEntry,
    engine: LatexEngine,
    kind: LatexFragmentKind,
) !LatexAsset {
    const reference_path = try cachedLatexPath(ctx, source, preamble, engine, kind, "ref");
    defer ctx.allocator.free(reference_path);
    if (try cachedLatexReference(ctx, reference_path)) |asset| return asset;
    const output_pdf_path = try cachedLatexPath(ctx, source, preamble, engine, kind, "pdf");
    defer ctx.allocator.free(output_pdf_path);
    const document_entries = [_]latex_document.Entry{.{ .source = source, .kind = kind }};
    const tex = try latexDocumentSource(ctx, preamble, &document_entries);
    defer ctx.allocator.free(tex);
    var generated = try compileLatexDocument(ctx, reference_path, engine, tex);
    defer generated.deinit(ctx);
    try publishGeneratedPdf(ctx, generated.pdf_path, output_pdf_path);
    const size = try pdfAssetSize(ctx, output_pdf_path, null, .latex_pdf);
    const geometry: LatexAssetGeometry = if (kind == .body)
        .{ .baseline_from_bottom = @as(f32, 0), .reference_height = size.height }
    else blk: {
        const metrics = try readLatexMetrics(ctx, generated.metrics_path, &document_entries);
        defer ctx.allocator.free(metrics);
        const metric = metrics[0] orelse return NativePdfError.AssetConversionFailed;
        break :blk .{
            .baseline_from_bottom = size.height * @as(f32, @floatCast(metric.baseline_ratio)),
            .reference_height = size.height * @as(f32, @floatCast(metric.reference_height_ratio)),
        };
    };
    try writeLatexReference(
        ctx,
        reference_path,
        output_pdf_path,
        0,
        size.width,
        size.height,
        geometry.baseline_from_bottom,
        geometry.reference_height,
    );
    return (try cachedLatexReference(ctx, reference_path)) orelse NativePdfError.InvalidPdfCache;
}

fn renderIconToSvg(ctx: *DrawContext, source: []const u8) !SvgAsset {
    const out = try cachedIconPath(ctx, source, "svg");
    errdefer ctx.allocator.free(out);
    if (try cachedSvgAsset(ctx, out)) |asset| return asset;
    const spec = core.fontawesome.parseSource(source) orelse return NativePdfError.InvalidFontAwesomeIcon;
    const icon_svg = core.fontawesome.extractSvg(ctx.allocator, spec) catch return NativePdfError.InvalidFontAwesomeIcon;
    defer ctx.allocator.free(icon_svg);
    const tmp = try tempCachePath(ctx, out, "svg");
    defer ctx.allocator.free(tmp);
    errdefer deleteFileIfExists(ctx, tmp);
    try std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = tmp, .data = icon_svg, .flags = .{ .truncate = true } });
    var validation_ctx = ctx.*;
    validation_ctx.emitter = null;
    _ = try svgAsset(&validation_ctx, tmp);
    try publishCacheFile(ctx, tmp, out);
    return try svgAsset(ctx, out);
}

fn readLatexMetrics(
    ctx: *DrawContext,
    path: []const u8,
    entries: []const latex_document.Entry,
) ![]?latex_document.Metrics {
    const contents = utils.fs.readFileAllocLimited(
        ctx.io,
        ctx.allocator,
        path,
        .limited(latex_document.metrics_read_limit),
    ) catch {
        return NativePdfError.AssetConversionFailed;
    };
    defer ctx.allocator.free(contents);
    return latex_document.parseMetrics(ctx.allocator, contents, entries) catch
        return NativePdfError.AssetConversionFailed;
}

fn latexDocumentSource(
    ctx: *DrawContext,
    preamble: []const LatexPreambleEntry,
    entries: []const latex_document.Entry,
) ![]u8 {
    const preamble_lines = try latexPreambleLines(ctx, preamble);
    defer ctx.allocator.free(preamble_lines);
    return latex_document.documentSource(ctx.allocator, preamble_lines, entries);
}

fn latexDocumentEntries(allocator: Allocator, entries: []const LatexBatchEntry) ![]latex_document.Entry {
    const document_entries = try allocator.alloc(latex_document.Entry, entries.len);
    for (entries, document_entries) |entry, *document_entry| {
        document_entry.* = .{ .source = entry.source, .kind = entry.kind };
    }
    return document_entries;
}

fn latexPreambleLines(ctx: *DrawContext, preamble: []const LatexPreambleEntry) ![]const u8 {
    const allocator = ctx.allocator;
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    for (preamble) |entry| {
        const text = switch (entry.source) {
            .text => entry.value,
            .file => try readLatexPreambleFile(ctx, entry.value),
        };
        defer if (entry.source == .file) allocator.free(text);
        if (std.mem.trim(u8, text, " \t\r\n").len == 0) continue;
        try out.append(allocator, '\n');
        try out.appendSlice(allocator, text);
        if (text[text.len - 1] != '\n') try out.append(allocator, '\n');
    }
    return try out.toOwnedSlice(allocator);
}

fn readLatexPreambleFile(ctx: *DrawContext, path: []const u8) ![]const u8 {
    const resolved = try resolveAssetPath(ctx, path);
    defer ctx.allocator.free(resolved);
    return utils.fs.readFileAllocLimited(
        ctx.io,
        ctx.allocator,
        resolved,
        .limited(latex_document.preamble_read_limit),
    ) catch |err| {
        if (ctx.command_failure) |target| {
            var reason_buf: [256]u8 = undefined;
            const message = try std.fmt.allocPrint(
                ctx.allocator,
                "LaTeX preamble '{s}' could not be read (resolved to '{s}'): {s}",
                .{ path, resolved, utils.err.formatErrorReason(&reason_buf, err) },
            );
            defer ctx.allocator.free(message);
            try target.record(message);
        }
        return err;
    };
}

fn cachedLatexPath(
    ctx: *DrawContext,
    source: []const u8,
    preamble: []const LatexPreambleEntry,
    engine: LatexEngine,
    kind: LatexFragmentKind,
    extension: []const u8,
) ![]u8 {
    const key = fingerprint.latexArtifactKey(
        .{
            .allocator = ctx.allocator,
            .io = ctx.io,
            .asset_base_dir = ctx.asset_base_dir,
            .resource_cache = ctx.resource_cache,
        },
        native_artifact_cache_version,
        source,
        preamble,
        engine,
        @tagName(kind),
    ) catch |err| {
        recordLatexPreambleFingerprintFailure(ctx, preamble);
        return err;
    };
    return std.fmt.allocPrint(ctx.allocator, "{s}/latex-{x}.{s}", .{ ctx.cache_dir, key, extension });
}

fn recordLatexPreambleFingerprintFailure(ctx: *DrawContext, preamble: []const LatexPreambleEntry) void {
    if (ctx.command_failure == null) return;
    for (preamble) |entry| {
        if (entry.source != .file) continue;
        const text = readLatexPreambleFile(ctx, entry.value) catch return;
        ctx.allocator.free(text);
    }
}

fn cachedIconPath(ctx: *DrawContext, source: []const u8, extension: []const u8) ![]u8 {
    var hasher = std.hash.Wyhash.init(0);
    hashString(&hasher, native_artifact_cache_version);
    hashString(&hasher, core.fontawesome.cache_namespace);
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
    const result = external_process.run(ctx.allocator, ctx.io, argv, cwd) catch |err| {
        if (err == error.Canceled) return error.Canceled;
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
    if (err == error.FileNotFound and argv.len != 0) {
        try out.appendSlice(allocator, "executable '");
        try out.appendSlice(allocator, argv[0]);
        try out.appendSlice(allocator, "' was not found in PATH; install it or select an available latex_engine; command:");
    } else if (err == error.InvalidExe and argv.len != 0) {
        try out.appendSlice(allocator, "executable '");
        try out.appendSlice(allocator, argv[0]);
        try out.appendSlice(allocator, "' is not runnable on this platform; install a compatible executable or select another latex_engine; command:");
    } else if (err == error.Timeout) {
        const prefix = try std.fmt.allocPrint(
            allocator,
            "command exceeded the {d}-second limit; fix LaTeX source or configured preamble content that stalls the engine; command:",
            .{external_process.timeout_seconds},
        );
        defer allocator.free(prefix);
        try out.appendSlice(allocator, prefix);
    } else if (err == error.CommandStdoutTooLong) {
        const prefix = try std.fmt.allocPrint(
            allocator,
            "command wrote more than {d} KiB to stdout; fix repeated diagnostics in the LaTeX source or configured preamble; command:",
            .{external_process.stdout_limit / 1024},
        );
        defer allocator.free(prefix);
        try out.appendSlice(allocator, prefix);
    } else if (err == error.CommandStderrTooLong) {
        const prefix = try std.fmt.allocPrint(
            allocator,
            "command wrote more than {d} KiB to stderr; fix repeated diagnostics in the LaTeX source or configured preamble; command:",
            .{external_process.stderr_limit / 1024},
        );
        defer allocator.free(prefix);
        try out.appendSlice(allocator, prefix);
    } else {
        var reason_buf: [256]u8 = undefined;
        try out.appendSlice(allocator, "failed to run command: ");
        try out.appendSlice(allocator, utils.err.formatErrorReason(&reason_buf, err));
        try out.appendSlice(allocator, "; command:");
    }
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
