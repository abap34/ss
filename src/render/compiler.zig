const std = @import("std");
const core = @import("core");
const render = @import("render");
const utils = @import("utils");

const document = @import("compile.zig");
const items = @import("compile/items.zig");

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
    return try document.document(allocator, state, pages, &item_compiler);
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
