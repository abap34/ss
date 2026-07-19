const std = @import("std");
const core = @import("core");
const render = @import("render");
const utils = @import("utils");
const items = @import("compile/items.zig");
const resource_compile = @import("render_resources");
const semantics = @import("compile/semantics.zig");

pub const Options = struct {
    jobs: ?usize = null,
    cache_dir: []const u8 = ".ss-cache/render",
    highlight_languages: []const utils.highlight.Language = &.{},
};

pub const Progress = items.Progress;
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
    } };
    try item_compiler.prepare(allocator, state, pages);
    return try preparedDocument(allocator, state, pages, &item_compiler);
}

pub fn compilePrepared(
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
    } };
    return try preparedDocument(allocator, state, pages, &item_compiler);
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
    return try sequentialDocument(allocator, state, prepared_pages, compiler);
}

fn preparedDocument(
    allocator: std.mem.Allocator,
    state: *core.DocumentState,
    prepared_pages: *const core.prepared.PreparedPages,
    compiler: *items.Compiler,
) !render.Ir {
    const worker_count = renderWorkerCount(prepared_pages.pages.len, compiler.options.jobs);
    if (worker_count <= 1) return try sequentialDocument(allocator, state, prepared_pages, compiler);
    return try parallelPreparedDocument(allocator, state, prepared_pages, compiler, worker_count);
}

fn sequentialDocument(
    allocator: std.mem.Allocator,
    state: *core.DocumentState,
    prepared_pages: *const core.prepared.PreparedPages,
    compiler: anytype,
) !render.Ir {
    var resources = resource_compile.Builder{};
    defer resources.deinit(allocator);
    var fonts = render.FontBuilder{};
    defer fonts.deinit(allocator);
    var math = render.MathBuilder{};
    defer math.deinit(allocator);
    var pages = std.ArrayList(render.Page).empty;
    errdefer deinitPages(allocator, &pages);
    for (prepared_pages.pages) |*prepared_page| {
        var page = try compiler.compilePage(
            allocator,
            state,
            prepared_page,
            &resources,
            &fonts,
            &math,
        );
        errdefer page.deinit(allocator);
        try pages.append(allocator, page);
    }
    return try finishDocument(allocator, state, prepared_pages, &resources, &fonts, &math, &pages);
}

const PageCompilation = struct {
    page: ?render.Page = null,
    math: render.MathBuilder = .{},
    err: ?anyerror = null,

    fn deinit(self: *PageCompilation, allocator: std.mem.Allocator) void {
        if (self.page) |*page| page.deinit(allocator);
        self.math.deinit(allocator);
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
    worker_count: usize,
) !render.Ir {
    var locked_allocator = LockedAllocator{ .child = allocator, .io = compiler.io };
    const worker_allocator = locked_allocator.allocator();
    const outputs = try allocator.alloc(PageCompilation, prepared_pages.pages.len);
    defer allocator.free(outputs);
    for (outputs) |*output| output.* = .{};
    defer for (outputs) |*output| output.deinit(allocator);

    var resources = resource_compile.Builder{};
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
    while (started < worker_count) : (started += 1) {
        threads[started] = try std.Thread.spawn(.{}, pageCompilationWorker, .{&work});
    }
    for (threads[0..started]) |thread| thread.join();
    joined = true;
    if (work.failed.load(.seq_cst)) {
        for (outputs) |output| if (output.err) |err| return err;
        return error.RenderPageCompilationFailed;
    }

    var math = render.MathBuilder{};
    defer math.deinit(allocator);
    var pages = std.ArrayList(render.Page).empty;
    errdefer deinitPages(allocator, &pages);
    try pages.ensureTotalCapacity(allocator, outputs.len);
    for (outputs) |*output| {
        const math_mapping = try math.mergeFrom(allocator, &output.math);
        defer allocator.free(math_mapping);
        const page = if (output.page) |*value| value else return error.RenderPageCompilationFailed;
        try remapMathTrees(page, math_mapping);
        pages.appendAssumeCapacity(page.*);
        output.page = null;
    }
    return try finishDocument(allocator, state, prepared_pages, &resources, &fonts, &math, &pages);
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
            &output.math,
        ) catch |err| {
            output.err = err;
            work.failed.store(true, .seq_cst);
            return;
        };
    }
}

fn remapMathTrees(page: *render.Page, mapping: []const render.MathTreeId) !void {
    for (page.items.items) |*item| switch (item.*) {
        .math => |*value| {
            if (value.tree == 0 or value.tree > mapping.len) return error.InvalidMathTree;
            value.tree = mapping[value.tree - 1];
        },
        else => {},
    };
}

fn finishDocument(
    allocator: std.mem.Allocator,
    state: *core.DocumentState,
    prepared_pages: *const core.prepared.PreparedPages,
    resources: *resource_compile.Builder,
    fonts: *render.FontBuilder,
    math: *render.MathBuilder,
    pages: *std.ArrayList(render.Page),
) !render.Ir {
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
    var ir = render.Ir{ .pages = &.{} };
    errdefer ir.deinit(allocator);
    ir.semantics = try semantics.build(allocator, state, prepared_pages, pages.items);
    ir.resources = try resources.take(allocator);
    ir.fonts = try fonts.take(allocator);
    ir.math = try math.take(allocator);
    ir.pages = try pages.toOwnedSlice(allocator);
    pages.* = .empty;
    try ir.validate();
    return ir;
}

fn deinitPages(allocator: std.mem.Allocator, pages: *std.ArrayList(render.Page)) void {
    for (pages.items) |*page| page.deinit(allocator);
    pages.deinit(allocator);
}

fn renderWorkerCount(page_count: usize, requested_jobs: ?usize) usize {
    if (page_count == 0) return 0;
    if (requested_jobs) |jobs| return @min(@max(@as(usize, 1), jobs), page_count);
    if (std.c.getenv("SS_RENDER_JOBS")) |raw| {
        const text = std.mem.span(raw);
        if (std.ascii.eqlIgnoreCase(text, "off")) return 1;
        if (std.fmt.parseUnsigned(usize, text, 10)) |jobs| {
            return @min(@max(@as(usize, 1), jobs), page_count);
        } else |_| {}
    }
    return @min(@max(@as(usize, 1), std.Thread.getCpuCount() catch 1), page_count);
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
