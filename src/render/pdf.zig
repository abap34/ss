const std = @import("std");
const core = @import("core");
const native = @import("pdf_native.zig");
const render_compile = @import("compile.zig");

pub const RenderProgress = native.RenderProgress;
pub const RenderOptions = native.RenderOptions;

pub fn renderDocumentToPdf(allocator: std.mem.Allocator, io: std.Io, ir: *core.Ir) ![]const u8 {
    return renderDocumentToPdfWithOptions(allocator, io, ir, .{}, null);
}

pub fn renderDocumentToPdfWithProgress(allocator: std.mem.Allocator, io: std.Io, ir: *core.Ir, progress: ?RenderProgress) ![]const u8 {
    return renderDocumentToPdfWithOptions(allocator, io, ir, .{}, progress);
}

pub fn renderDocumentToPdfWithOptions(allocator: std.mem.Allocator, io: std.Io, ir: *core.Ir, options: RenderOptions, progress: ?RenderProgress) ![]const u8 {
    const artifact_cache_dir = try std.fs.path.join(allocator, &.{ options.cache_dir, "artifacts", "shared" });
    defer allocator.free(artifact_cache_dir);
    try std.Io.Dir.cwd().createDirPath(io, artifact_cache_dir);
    var document = try render_compile.sceneFromIr(allocator, ir, .{
        .target = .pdf,
        .io = io,
        .cache_dir = artifact_cache_dir,
        .highlight_languages = options.highlight_languages,
    });
    defer document.deinit(allocator);
    return native.renderSceneToPdfWithOptions(allocator, io, &document, options, progress);
}
