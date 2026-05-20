const std = @import("std");
const core = @import("core");
const native = @import("pdf_native.zig");

pub const RenderProgress = native.RenderProgress;

pub fn renderDocumentToPdf(allocator: std.mem.Allocator, io: std.Io, ir: *core.Ir) ![]const u8 {
    return native.renderDocumentToPdfWithProgress(allocator, io, ir, null);
}

pub fn renderDocumentToPdfWithProgress(allocator: std.mem.Allocator, io: std.Io, ir: *core.Ir, progress: ?RenderProgress) ![]const u8 {
    return native.renderDocumentToPdfWithProgress(allocator, io, ir, progress);
}
