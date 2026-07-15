const std = @import("std");
const core = @import("core");
const utils = @import("utils");
const render = @import("render");

const document = @import("pdf/document.zig");
const native = @import("pdf/native.zig");
const render_compile = @import("compile.zig");

pub const CompileOptions = render_compile.Options;
pub const TreeSitterHealthItem = native.TreeSitterHealthItem;
pub const TreeSitterHealthReport = native.TreeSitterHealthReport;
pub const TreeSitterHealthStatus = native.TreeSitterHealthStatus;
pub const tree_sitter_language_version = native.tree_sitter_language_version;
pub const tree_sitter_min_compatible_language_version = native.tree_sitter_min_compatible_language_version;
pub const NativeRuntimeVersions = native.NativeRuntimeVersions;
pub const LayoutMeasurementScope = native.LayoutMeasurementScope;
pub const page_pdf_cache_version = "ss-render-ir-page-v1";
pub const qpdf_cache_version = native.qpdf_cache_version;
pub const native_artifact_cache_version = native.native_artifact_cache_version;
pub const nativeRuntimeVersions = native.nativeRuntimeVersions;
pub const treeSitterHealthReport = native.treeSitterHealthReport;

pub const Options = struct {
    jobs: ?usize = null,
    cache_dir: []const u8 = ".ss-cache/render",
    cache_id: ?[]const u8 = null,
    highlight_languages: []const utils.highlight.Language = &.{},
};

pub const Progress = struct {
    context: *anyopaque,
    artifactCompleted: *const fn (context: *anyopaque, completed: usize, total: usize) void,
    pageCompleted: *const fn (context: *anyopaque, completed: usize, total: usize) void,
    assemblyCompleted: *const fn (context: *anyopaque, completed: usize, total: usize) void,
};

pub fn compileRenderIr(
    allocator: std.mem.Allocator,
    io: std.Io,
    state: *core.DocumentState,
    pages: *const core.prepared.PreparedPages,
    options: CompileOptions,
) !render.Ir {
    var compiler = native.Compiler{ .io = io, .options = options };
    return try render_compile.document(allocator, state, pages, &compiler);
}

pub fn writeRenderIr(
    allocator: std.mem.Allocator,
    io: std.Io,
    ir: *const render.Ir,
    output: []const u8,
    options: Options,
    progress: ?Progress,
) !void {
    try document.write(allocator, io, ir, output, .{
        .jobs = options.jobs,
        .cache_dir = options.cache_dir,
    }, if (progress) |value| .{
        .context = value.context,
        .artifactCompleted = value.artifactCompleted,
        .pageCompleted = value.pageCompleted,
        .assemblyCompleted = value.assemblyCompleted,
    } else null);
}

pub fn preloadPreparedPageArtifacts(
    allocator: std.mem.Allocator,
    io: std.Io,
    state: *core.DocumentState,
    pages: *const core.prepared.PreparedPages,
    options: Options,
    progress: ?Progress,
) !void {
    try native.preloadPreparedPageArtifacts(allocator, io, state, pages, .{
        .jobs = options.jobs,
        .cache_dir = options.cache_dir,
        .cache_id = options.cache_id,
        .highlight_languages = options.highlight_languages,
    }, if (progress) |value| .{
        .context = value.context,
        .artifactCompleted = value.artifactCompleted,
        .pageCompleted = value.pageCompleted,
        .assemblyCompleted = value.assemblyCompleted,
    } else null);
}
