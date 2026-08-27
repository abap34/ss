const std = @import("std");
const core = @import("core");
const render = @import("render");
const utils = @import("utils");
const items = @import("compile/items.zig");
const resource_compile = @import("render_resources");
const text_compile = @import("render_text");
const semantics = @import("compile/semantics.zig");

pub const FontEnvironmentToken = text_compile.FontEnvironment;

pub const Options = struct {
    jobs: ?usize = null,
    cache_dir: []const u8 = ".ss-cache/render",
    highlight_languages: []const utils.highlight.Language = &.{},
    resource_cache: ?*resource_compile.SourceCache = null,
    text_cache: ?*text_compile.Cache = null,
    page_cache: ?*items.PageCache = null,
    font_environment: ?FontEnvironmentToken = null,
    thread_safe_allocator: bool = false,
};

pub const Progress = items.Progress;
pub const PageCache = items.PageCache;
pub const LayoutMeasurementScope = items.LayoutMeasurementScope;
pub const TreeSitterHealthItem = items.TreeSitterHealthItem;
pub const TreeSitterHealthReport = items.TreeSitterHealthReport;
pub const TreeSitterHealthStatus = items.TreeSitterHealthStatus;
pub const NativeRuntimeVersions = items.NativeRuntimeVersions;
pub const tree_sitter_language_version = items.tree_sitter_language_version;
pub const tree_sitter_min_compatible_language_version = items.tree_sitter_min_compatible_language_version;
pub const native_artifact_cache_version = items.native_artifact_cache_version;
pub const nativeRuntimeVersions = items.nativeRuntimeVersions;
pub const treeSitterHealthReport = items.treeSitterHealthReport;
pub const addFontFaceUnavailableDiagnostic = items.addFontFaceUnavailableDiagnostic;
pub const validateFontEnvironment = text_compile.validateFontEnvironment;
pub const refreshAndValidateFontEnvironment = text_compile.refreshAndValidateFontEnvironment;

pub fn addFontEnvironmentDiagnostic(state: *core.DocumentState, err: anyerror) !bool {
    const message = text_compile.diagnosticMessageForError(err) orelse return false;
    for (state.diagnostics.items) |diagnostic| {
        const existing_message = switch (diagnostic.data) {
            .user_report => |data| data.message,
            .render_failed => |data| data.reason,
            else => continue,
        };
        if (std.mem.indexOf(u8, existing_message, message) != null) return true;
    }
    const owned_message = try state.allocator.dupe(u8, message);
    try state.addRenderDiagnostic(.@"error", null, null, null, .{
        .user_report = .{ .message = owned_message },
    });
    return true;
}

pub fn acquireFontEnvironment(
    allocator: std.mem.Allocator,
    io: std.Io,
    state: *core.DocumentState,
    pages: *const core.prepared.PreparedPages,
) !FontEnvironmentToken {
    _ = state;
    const refresh_fonts_start = utils.measure_profile.start();
    _ = try text_compile.fontEnvironmentRefresh();
    utils.measure_profile.recordRenderCompile(.font_environment, refresh_fonts_start);
    _ = allocator;
    _ = io;
    _ = pages;
    const font_environment_start = utils.measure_profile.start();
    const font_environment = try text_compile.fontEnvironmentSnapshot();
    utils.measure_profile.recordRenderCompile(.font_environment, font_environment_start);
    return font_environment;
}

pub fn compile(
    allocator: std.mem.Allocator,
    io: std.Io,
    state: *core.DocumentState,
    pages: *const core.prepared.PreparedPages,
    options: Options,
) !render.Ir {
    var item_compiler = items.Compiler{ .io = io, .options = .{
        .jobs = options.jobs,
        .cache_dir = options.cache_dir,
        .highlight_languages = options.highlight_languages,
        .resource_cache = options.resource_cache,
        .text_cache = options.text_cache,
        .page_cache = options.page_cache,
        .font_environment = options.font_environment,
        .thread_safe_allocator = options.thread_safe_allocator,
    } };
    item_compiler.prepare(allocator, state, pages) catch |err| {
        _ = try addFontEnvironmentDiagnostic(state, err);
        return err;
    };
    const font_environment = item_compiler.font_environment orelse {
        const err = error.FontEnvironmentRefreshFailed;
        _ = try addFontEnvironmentDiagnostic(state, err);
        return err;
    };
    var ir = preparedDocument(allocator, state, pages, &item_compiler, options.resource_cache) catch |err| {
        _ = try addFontEnvironmentDiagnostic(state, err);
        return err;
    };
    text_compile.refreshAndValidateFontEnvironment(font_environment) catch |err| {
        ir.deinit(allocator);
        _ = try addFontEnvironmentDiagnostic(state, err);
        return err;
    };
    return ir;
}

pub fn compilePrepared(
    allocator: std.mem.Allocator,
    io: std.Io,
    state: *core.DocumentState,
    pages: *const core.prepared.PreparedPages,
    options: Options,
) !render.Ir {
    const font_environment = if (options.font_environment) |expected| blk: {
        const font_environment_start = utils.measure_profile.start();
        text_compile.refreshAndValidateFontEnvironment(expected) catch |err| {
            _ = try addFontEnvironmentDiagnostic(state, err);
            return err;
        };
        utils.measure_profile.recordRenderCompile(.font_environment, font_environment_start);
        break :blk expected;
    } else acquireFontEnvironment(allocator, io, state, pages) catch |err| {
        _ = try addFontEnvironmentDiagnostic(state, err);
        return err;
    };
    var item_compiler = items.Compiler{ .io = io, .options = .{
        .jobs = options.jobs,
        .cache_dir = options.cache_dir,
        .highlight_languages = options.highlight_languages,
        .resource_cache = options.resource_cache,
        .text_cache = options.text_cache,
        .page_cache = options.page_cache,
        .thread_safe_allocator = options.thread_safe_allocator,
    }, .font_environment = font_environment };
    var ir = preparedDocument(allocator, state, pages, &item_compiler, options.resource_cache) catch |err| {
        _ = try addFontEnvironmentDiagnostic(state, err);
        return err;
    };
    text_compile.refreshAndValidateFontEnvironment(font_environment) catch |err| {
        ir.deinit(allocator);
        _ = try addFontEnvironmentDiagnostic(state, err);
        return err;
    };
    return ir;
}

pub fn preload(
    allocator: std.mem.Allocator,
    io: std.Io,
    state: *core.DocumentState,
    pages: *const core.prepared.PreparedPages,
    options: Options,
    progress: ?Progress,
) !void {
    try items.preloadPreparedPageArtifacts(allocator, io, state, pages, .{
        .jobs = options.jobs,
        .cache_dir = options.cache_dir,
        .highlight_languages = options.highlight_languages,
    }, progress);
}

pub fn document(
    allocator: std.mem.Allocator,
    state: *core.DocumentState,
    prepared_pages: *const core.prepared.PreparedPages,
    compiler: anytype,
) !render.Ir {
    try compiler.prepare(allocator, state, prepared_pages);
    return try sequentialDocument(allocator, state, prepared_pages, compiler, null);
}

fn preparedDocument(
    allocator: std.mem.Allocator,
    state: *core.DocumentState,
    prepared_pages: *const core.prepared.PreparedPages,
    compiler: *items.Compiler,
    resource_cache: ?*resource_compile.SourceCache,
) !render.Ir {
    if (compiler.options.text_cache) |text_cache| {
        const text_cache_start = utils.measure_profile.start();
        try text_cache.beginDocument();
        defer text_cache.endDocument();
        utils.measure_profile.recordRenderCompile(.text_cache_begin, text_cache_start);
    }
    if (compiler.options.page_cache) |page_cache| {
        page_cache.beginDocument(prepared_pages.pages.len);
        return try sequentialDocument(allocator, state, prepared_pages, compiler, resource_cache);
    }
    const worker_count = renderWorkerCount(prepared_pages.pages.len, compiler.options.jobs);
    if (worker_count <= 1) return try sequentialDocument(allocator, state, prepared_pages, compiler, resource_cache);
    return try parallelPreparedDocument(allocator, state, prepared_pages, compiler, resource_cache, worker_count);
}

fn sequentialDocument(
    allocator: std.mem.Allocator,
    state: *core.DocumentState,
    prepared_pages: *const core.prepared.PreparedPages,
    compiler: anytype,
    resource_cache: ?*resource_compile.SourceCache,
) !render.Ir {
    var resources = resource_compile.Builder{ .cache = resource_cache };
    defer resources.deinit(allocator);
    var fonts = render.FontBuilder{};
    defer fonts.deinit(allocator);
    var pages = std.ArrayList(render.Page).empty;
    errdefer deinitPages(allocator, &pages);
    try pages.ensureTotalCapacity(allocator, prepared_pages.pages.len);
    for (prepared_pages.pages) |*prepared_page| {
        var page = try compiler.compilePage(
            allocator,
            state,
            prepared_page,
            &resources,
            &fonts,
        );
        errdefer page.deinit(allocator);
        pages.appendAssumeCapacity(page);
    }
    return try finishDocument(allocator, state, prepared_pages, &resources, &fonts, &pages);
}

const PageCompilation = struct {
    page: ?render.Page = null,
    err: ?anyerror = null,

    fn deinit(self: *PageCompilation, allocator: std.mem.Allocator) void {
        if (self.page) |*page| page.deinit(allocator);
        self.* = .{};
    }
};

const PageCompilationWork = struct {
    allocator: std.mem.Allocator,
    state: *core.DocumentState,
    prepared_pages: *const core.prepared.PreparedPages,
    compiler: *items.Compiler,
    resources: *resource_compile.Builder,
    fonts: *render.FontBuilder,
    outputs: []PageCompilation,
    next: std.atomic.Value(usize) = .init(0),
    failed: std.atomic.Value(bool) = .init(false),
};

fn parallelPreparedDocument(
    allocator: std.mem.Allocator,
    state: *core.DocumentState,
    prepared_pages: *const core.prepared.PreparedPages,
    compiler: *items.Compiler,
    resource_cache: ?*resource_compile.SourceCache,
    worker_count: usize,
) !render.Ir {
    var locked_allocator = LockedAllocator{ .child = allocator, .io = compiler.io };
    const worker_allocator = if (compiler.options.thread_safe_allocator)
        allocator
    else
        locked_allocator.allocator();
    const outputs = try allocator.alloc(PageCompilation, prepared_pages.pages.len);
    defer allocator.free(outputs);
    for (outputs) |*output| output.* = .{};
    defer for (outputs) |*output| output.deinit(allocator);

    var resources = resource_compile.Builder{ .cache = resource_cache };
    defer resources.deinit(allocator);
    var fonts = render.FontBuilder{};
    defer fonts.deinit(allocator);

    var work = PageCompilationWork{
        .allocator = worker_allocator,
        .state = state,
        .prepared_pages = prepared_pages,
        .compiler = compiler,
        .resources = &resources,
        .fonts = &fonts,
        .outputs = outputs,
    };
    const threads = try allocator.alloc(std.Thread, worker_count);
    defer allocator.free(threads);
    var started: usize = 0;
    var joined = false;
    errdefer if (!joined) {
        work.failed.store(true, .seq_cst);
        for (threads[0..started]) |thread| thread.join();
    };
    const workers_start = utils.measure_profile.start();
    while (started < worker_count) : (started += 1) {
        threads[started] = try std.Thread.spawn(.{}, pageCompilationWorker, .{&work});
    }
    for (threads[0..started]) |thread| thread.join();
    utils.measure_profile.recordRenderCompile(.workers, workers_start);
    joined = true;
    if (work.failed.load(.seq_cst)) {
        for (outputs) |output| if (output.err) |err| return err;
        return error.RenderPageCompilationFailed;
    }

    const merge_start = utils.measure_profile.start();
    var pages = std.ArrayList(render.Page).empty;
    errdefer deinitPages(allocator, &pages);
    try pages.ensureTotalCapacity(allocator, outputs.len);
    for (outputs) |*output| {
        const page = if (output.page) |*value| value else return error.RenderPageCompilationFailed;
        pages.appendAssumeCapacity(page.*);
        output.page = null;
    }
    utils.measure_profile.recordRenderCompile(.merge_pages, merge_start);
    return try finishDocument(allocator, state, prepared_pages, &resources, &fonts, &pages);
}

fn pageCompilationWorker(work: *PageCompilationWork) void {
    while (!work.failed.load(.monotonic)) {
        const index = work.next.fetchAdd(1, .monotonic);
        if (index >= work.prepared_pages.pages.len) return;
        const prepared_page = &work.prepared_pages.pages[index];
        const output = &work.outputs[index];
        output.page = work.compiler.compilePage(
            work.allocator,
            work.state,
            prepared_page,
            work.resources,
            work.fonts,
        ) catch |err| {
            output.err = err;
            work.failed.store(true, .seq_cst);
            return;
        };
    }
}

fn finishDocument(
    allocator: std.mem.Allocator,
    state: *core.DocumentState,
    prepared_pages: *const core.prepared.PreparedPages,
    resources: *resource_compile.Builder,
    fonts: *render.FontBuilder,
    pages: *std.ArrayList(render.Page),
) !render.Ir {
    const profile_start = utils.measure_profile.start();
    defer utils.measure_profile.recordRenderCompile(.finish_document, profile_start);
    const sources_start = utils.measure_profile.start();
    var source_ranges = std.AutoHashMap(core.NodeId, render.SourceRange).init(allocator);
    defer source_ranges.deinit();
    for (state.object_sources.items) |source| {
        const entry = try source_ranges.getOrPut(source.node_id);
        if (!entry.found_existing) entry.value_ptr.* = .{
            .module_id = source.module_id,
            .start = source.span_start,
            .end = source.span_end,
        };
    }
    for (pages.items, prepared_pages.pages) |*page, prepared_page| {
        page.name = if (state.getNode(prepared_page.page_id)) |page_node|
            try allocator.dupe(u8, page_node.name)
        else
            try std.fmt.allocPrint(allocator, "Page {d}", .{prepared_page.index + 1});
        for (page.items.items) |*item| item.setSource(if (item.nodeId()) |node_id| source_ranges.get(node_id) else null);
    }
    utils.measure_profile.recordRenderCompile(.finish_sources, sources_start);
    var ir = render.Ir{ .pages = &.{} };
    errdefer ir.deinit(allocator);
    const semantics_start = utils.measure_profile.start();
    ir.semantics = try semantics.build(allocator, state, prepared_pages, pages.items);
    utils.measure_profile.recordRenderCompile(.finish_semantics, semantics_start);
    const catalogs_start = utils.measure_profile.start();
    ir.resources = try resources.take(allocator);
    ir.fonts = try fonts.take(allocator);
    ir.pages = try pages.toOwnedSlice(allocator);
    pages.* = .empty;
    utils.measure_profile.recordRenderCompile(.finish_catalogs, catalogs_start);
    const validation_start = utils.measure_profile.start();
    try ir.validate();
    utils.measure_profile.recordRenderCompile(.finish_validation, validation_start);
    return ir;
}

fn deinitPages(allocator: std.mem.Allocator, pages: *std.ArrayList(render.Page)) void {
    for (pages.items) |*page| page.deinit(allocator);
    pages.deinit(allocator);
}

fn renderWorkerCount(page_count: usize, requested_jobs: ?usize) usize {
    const automatic_job_cap = 8;
    if (page_count == 0) return 0;
    if (requested_jobs) |jobs| return @min(@max(@as(usize, 1), jobs), page_count);
    return @min(@max(@as(usize, 1), std.Thread.getCpuCount() catch 1), @min(page_count, automatic_job_cap));
}

const LockedAllocator = struct {
    child: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,

    fn allocator(self: *LockedAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = std.mem.Allocator.VTable{
        .alloc = allocate,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn allocate(context: *anyopaque, len: usize, alignment: std.mem.Alignment, return_address: usize) ?[*]u8 {
        const self: *LockedAllocator = @ptrCast(@alignCast(context));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.child.rawAlloc(len, alignment, return_address);
    }

    fn resize(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, return_address: usize) bool {
        const self: *LockedAllocator = @ptrCast(@alignCast(context));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.child.rawResize(memory, alignment, new_len, return_address);
    }

    fn remap(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, return_address: usize) ?[*]u8 {
        const self: *LockedAllocator = @ptrCast(@alignCast(context));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.child.rawRemap(memory, alignment, new_len, return_address);
    }

    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, return_address: usize) void {
        const self: *LockedAllocator = @ptrCast(@alignCast(context));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.child.rawFree(memory, alignment, return_address);
    }
};
