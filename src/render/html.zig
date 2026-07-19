const std = @import("std");
const render = @import("render");

const document = @import("html/document.zig");
const pdf_runtime = @import("html/pdf/runtime.zig");
const resources = @import("html/resources.zig");

const resource_runtime = @embedFile("html/resources.js");
const navigation_runtime = @embedFile("html/navigation.js");
const text_runtime = @embedFile("html/text.js");

var publication_counter: usize = 0;

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

    const resource_module_url = try resources.dataUrl(allocator, "text/javascript;charset=utf-8", resource_runtime);
    defer allocator.free(resource_module_url);
    const navigation_module_url = try resources.dataUrl(allocator, "text/javascript;charset=utf-8", navigation_runtime);
    defer allocator.free(navigation_module_url);
    const text_module_url = try resources.dataUrl(allocator, "text/javascript;charset=utf-8", text_runtime);
    defer allocator.free(text_module_url);

    const embedded_pdf: ?pdf_runtime.Embedded = if (references.hasPdf())
        try pdf_runtime.Embedded.init(allocator)
    else
        null;
    defer if (embedded_pdf) |runtime| runtime.deinit(allocator);
    const pdf: ?document.PdfRuntime = if (embedded_pdf) |runtime|
        runtime.documentRuntime()
    else
        null;
    const html = try document.generate(allocator, ir, references, style_sheet_url, .{
        .resource_module = resource_module_url,
        .navigation_module = navigation_module_url,
        .text_module = text_module_url,
        .pdf = pdf,
    });
    defer allocator.free(html);

    const serial = @atomicRmw(usize, &publication_counter, .Add, 1, .monotonic);
    const building = try std.fmt.allocPrint(allocator, "{s}.building-{d}-{d}", .{ output_path, std.c.getpid(), serial });
    defer allocator.free(building);
    const cwd = std.Io.Dir.cwd();
    deleteTemporaryFile(io, building);
    errdefer deleteTemporaryFile(io, building);
    try cwd.writeFile(io, .{ .sub_path = building, .data = html, .flags = .{ .truncate = true } });
    cwd.rename(building, cwd, output_path, io) catch |err| switch (err) {
        error.IsDir, error.NotDir, error.DirNotEmpty => return error.OutputPathNotFile,
        else => return err,
    };
}

fn deleteTemporaryFile(io: std.Io, path: []const u8) void {
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
}
