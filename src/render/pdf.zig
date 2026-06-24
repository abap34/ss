const std = @import("std");
const core = @import("core");
const native = @import("pdf_native.zig");
const utils = @import("utils");

pub const RenderProgress = native.RenderProgress;
pub const RenderOptions = native.RenderOptions;
pub const TreeSitterHealthItem = native.TreeSitterHealthItem;
pub const TreeSitterHealthReport = native.TreeSitterHealthReport;
pub const TreeSitterHealthStatus = native.TreeSitterHealthStatus;
pub const tree_sitter_language_version = native.tree_sitter_language_version;
pub const tree_sitter_min_compatible_language_version = native.tree_sitter_min_compatible_language_version;

pub fn renderDocumentToPdf(allocator: std.mem.Allocator, io: std.Io, ir: *core.Ir) ![]const u8 {
    return native.renderDocumentToPdfWithOptions(allocator, io, ir, .{}, null);
}

pub fn renderDocumentToPdfWithProgress(allocator: std.mem.Allocator, io: std.Io, ir: *core.Ir, progress: ?RenderProgress) ![]const u8 {
    return native.renderDocumentToPdfWithOptions(allocator, io, ir, .{}, progress);
}

pub fn renderDocumentToPdfWithOptions(allocator: std.mem.Allocator, io: std.Io, ir: *core.Ir, options: RenderOptions, progress: ?RenderProgress) ![]const u8 {
    return native.renderDocumentToPdfWithOptions(allocator, io, ir, options, progress);
}

pub fn treeSitterHealthReport(
    allocator: std.mem.Allocator,
    io: std.Io,
    languages: []const utils.highlight.Language,
) !TreeSitterHealthReport {
    return native.treeSitterHealthReport(allocator, io, languages);
}
