const std = @import("std");
const render = @import("render");

const document = @import("html/document.zig");
const embedded_runtime = @import("html/embedded_runtime.zig");
const pdf_runtime = @import("html/pdf/runtime.zig");
const resources = @import("html/resources.zig");

pub const Fragment = struct {
    html: []u8,
    css: []u8,
    assets: resources.Set,

    pub fn deinit(self: *Fragment, allocator: std.mem.Allocator) void {
        allocator.free(self.html);
        allocator.free(self.css);
        self.assets.deinit(allocator);
        self.* = undefined;
    }
};

pub fn prepareFragment(allocator: std.mem.Allocator, ir: *const render.Ir) !Fragment {
    try ir.validate();
    var assets = try resources.collect(allocator, ir);
    errdefer assets.deinit(allocator);
    const references = resources.References{ .set = &assets, .mode = .external };
    const html = try document.fragment(allocator, ir, references);
    errdefer allocator.free(html);
    const style_sheet = try document.styleSheet(allocator, ir, references, false);
    return .{ .html = html, .css = style_sheet, .assets = assets };
}

pub fn write(
    allocator: std.mem.Allocator,
    io: std.Io,
    ir: *const render.Ir,
    output_path: []const u8,
) !void {
    try ir.validate();
    var assets = try resources.collect(allocator, ir);
    defer assets.deinit(allocator);
    try assets.prepareEmbeddedResources(allocator);
    const references = resources.References{ .set = &assets, .mode = .embedded };
    const style_sheet = try document.styleSheet(allocator, ir, references, true);
    defer allocator.free(style_sheet);
    const style_sheet_url = try resources.dataUrl(allocator, "text/css;charset=utf-8", style_sheet);
    defer allocator.free(style_sheet_url);

    const pdf: ?document.PdfRuntime = if (references.hasPdf()) pdf_runtime.documentRuntime() else null;
    const runtime = document.Runtime{
        .resource_module = embedded_runtime.resource_module,
        .navigation_module = embedded_runtime.navigation_module,
        .text_module = embedded_runtime.text_module,
        .pdf = pdf,
    };

    const cwd = std.Io.Dir.cwd();
    var atomic = cwd.createFileAtomic(io, output_path, .{ .replace = true }) catch |err| switch (err) {
        error.NotDir => return error.OutputPathNotFile,
        else => return err,
    };
    defer atomic.deinit(io);
    var buffer: [64 * 1024]u8 = undefined;
    var writer = atomic.file.writerStreaming(io, &buffer);
    try document.write(allocator, &writer.interface, ir, references, style_sheet_url, runtime);
    try writer.interface.flush();
    atomic.replace(io) catch |err| switch (err) {
        error.IsDir, error.NotDir, error.DirNotEmpty => return error.OutputPathNotFile,
        else => return err,
    };
}
