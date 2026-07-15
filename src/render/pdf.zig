const native = @import("pdf/native.zig");
const render_compile = @import("compile.zig");
const core = @import("core");
const render = @import("render");
const std = @import("std");

pub const Progress = native.Progress;
pub const Options = native.Options;
pub const CompileOptions = render_compile.Options;
pub const TreeSitterHealthItem = native.TreeSitterHealthItem;
pub const TreeSitterHealthReport = native.TreeSitterHealthReport;
pub const TreeSitterHealthStatus = native.TreeSitterHealthStatus;
pub const tree_sitter_language_version = native.tree_sitter_language_version;
pub const tree_sitter_min_compatible_language_version = native.tree_sitter_min_compatible_language_version;
pub const NativeRuntimeVersions = native.NativeRuntimeVersions;
pub const LayoutMeasurementScope = native.LayoutMeasurementScope;
pub const page_pdf_cache_version = native.page_pdf_cache_version;
pub const qpdf_cache_version = native.qpdf_cache_version;
pub const native_artifact_cache_version = native.native_artifact_cache_version;
pub const nativeRuntimeVersions = native.nativeRuntimeVersions;
pub const renderDocumentToPdf = native.renderDocumentToPdf;
pub const preloadPreparedPageArtifacts = native.preloadPreparedPageArtifacts;
pub const treeSitterHealthReport = native.treeSitterHealthReport;

pub fn compileRenderIr(
    allocator: std.mem.Allocator,
    io: std.Io,
    compiler_context: *core.Context,
    pages: *const core.prepared.PreparedPages,
    options: CompileOptions,
) !render.Ir {
    var compiler = native.Compiler{ .io = io, .options = options };
    return try render_compile.document(allocator, compiler_context, pages, &compiler);
}
