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
        .cache_dir = options.cache_dir,
        .highlight_languages = options.highlight_languages,
    } };
    return try document(allocator, state, pages, &item_compiler);
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
    var resources = resource_compile.Builder{};
    defer resources.deinit(allocator);
    var fonts = render.FontBuilder{};
    defer fonts.deinit(allocator);
    var math = render.MathBuilder{};
    defer math.deinit(allocator);
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

    var pages = std.ArrayList(render.Page).empty;
    errdefer {
        for (pages.items) |*page| page.deinit(allocator);
        pages.deinit(allocator);
    }
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
        page.name = if (state.getNode(prepared_page.page_id)) |page_node|
            try allocator.dupe(u8, page_node.name)
        else
            try std.fmt.allocPrint(allocator, "Page {d}", .{prepared_page.index + 1});
        for (page.items.items) |*item| item.setSource(if (item.nodeId()) |node_id| source_ranges.get(node_id) else null);
        try pages.append(allocator, page);
    }
    var ir = render.Ir{ .pages = &.{} };
    errdefer ir.deinit(allocator);
    ir.semantics = try semantics.build(allocator, state, prepared_pages, pages.items);
    ir.resources = try resources.take(allocator);
    ir.fonts = try fonts.take(allocator);
    ir.math = try math.take(allocator);
    ir.pages = try pages.toOwnedSlice(allocator);
    pages = .empty;
    try ir.validate();
    return ir;
}
