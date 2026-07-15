const std = @import("std");
const render = @import("render");
const pdfjs_assets = @import("pdfjs_assets");

const document = @import("html/document.zig");
const resources = @import("html/resources.zig");

const pdf_runtime = @embedFile("html/pdf.js");
const browser_runtime = @embedFile("html/runtime.js");

var publication_counter: usize = 0;

pub const Options = struct {};
pub const ResourceKind = render.ResourceKind;
pub const ResourceId = render.ResourceId;

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
    const html = try document.fragment(allocator, ir, &assets);
    errdefer allocator.free(html);
    const style_sheet = try document.styleSheet(allocator, ir, &assets, false);
    return .{ .html = html, .css = style_sheet, .assets = assets };
}

pub fn write(
    allocator: std.mem.Allocator,
    io: std.Io,
    ir: *const render.Ir,
    output_directory: []const u8,
    options: Options,
) !void {
    _ = options;
    try ir.validate();
    var assets = try resources.collect(allocator, ir);
    defer assets.deinit(allocator);
    const index = try document.generate(allocator, ir, &assets);
    defer allocator.free(index);
    const style_sheet = try document.styleSheet(allocator, ir, &assets, true);
    defer allocator.free(style_sheet);
    const manifest = try manifestJson(allocator, &assets);
    defer allocator.free(manifest);

    const serial = @atomicRmw(usize, &publication_counter, .Add, 1, .monotonic);
    const building = try std.fmt.allocPrint(allocator, "{s}.building-{d}-{d}", .{ output_directory, std.c.getpid(), serial });
    defer allocator.free(building);
    const previous = try std.fmt.allocPrint(allocator, "{s}.previous-{d}-{d}", .{ output_directory, std.c.getpid(), serial });
    defer allocator.free(previous);
    const cwd = std.Io.Dir.cwd();
    cwd.deleteTree(io, building) catch {};
    cwd.deleteTree(io, previous) catch {};
    errdefer cwd.deleteTree(io, building) catch {};

    try cwd.createDirPath(io, building);
    try writeRelative(allocator, io, building, "index.html", index);
    try writeRelative(allocator, io, building, "ss.css", style_sheet);
    try writeRelative(allocator, io, building, "manifest.json", manifest);
    for (assets.assets) |asset| try writeRelative(allocator, io, building, asset.relative_path, asset.bytes);
    if (assets.has_pdf) {
        try writeRelative(allocator, io, building, "ss.js", browser_runtime);
        try writeRelative(allocator, io, building, "pdf.js", pdf_runtime);
        try writeRelative(allocator, io, building, "pdfjs/pdf.mjs", pdfjs_assets.runtime);
        try writeRelative(allocator, io, building, "pdfjs/pdf.worker.mjs", pdfjs_assets.worker);
        try writeRelative(allocator, io, building, "pdfjs/LICENSE", pdfjs_assets.license);
    }

    var moved_previous = false;
    cwd.rename(output_directory, cwd, previous, io) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    moved_previous = pathExists(io, previous);
    cwd.rename(building, cwd, output_directory, io) catch |err| {
        if (moved_previous) cwd.rename(previous, cwd, output_directory, io) catch {};
        return err;
    };
    if (moved_previous) cwd.deleteTree(io, previous) catch {};
}

fn manifestJson(allocator: std.mem.Allocator, assets: *const resources.Set) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"schema\":1,\"kind\":\"ss-html-bundle\",\"resources\":[");
    for (assets.assets, 0..) |asset, index| {
        if (index != 0) try out.append(allocator, ',');
        try out.appendSlice(allocator, "{\"kind\":\"");
        try out.appendSlice(allocator, @tagName(asset.kind));
        try out.appendSlice(allocator, "\",\"path\":\"");
        try appendJsonStringContent(allocator, &out, asset.relative_path);
        try out.appendSlice(allocator, "\",\"bytes\":");
        const size = try std.fmt.allocPrint(allocator, "{d}", .{asset.bytes.len});
        defer allocator.free(size);
        try out.appendSlice(allocator, size);
        try out.append(allocator, '}');
    }
    try out.appendSlice(allocator, "],\"pdfjs\":");
    try out.appendSlice(allocator, if (assets.has_pdf) "\"4.8.69\"" else "null");
    try out.appendSlice(allocator, "}\n");
    return try out.toOwnedSlice(allocator);
}

fn appendJsonStringContent(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: []const u8) !void {
    for (value) |byte| switch (byte) {
        '"', '\\' => {
            try out.append(allocator, '\\');
            try out.append(allocator, byte);
        },
        0...0x1f => return error.InvalidHtmlResourceName,
        else => try out.append(allocator, byte),
    };
}

fn writeRelative(allocator: std.mem.Allocator, io: std.Io, root: []const u8, relative: []const u8, bytes: []const u8) !void {
    if (std.fs.path.isAbsolute(relative) or std.mem.indexOf(u8, relative, "..") != null) return error.InvalidHtmlResourceName;
    const path = try std.fs.path.join(allocator, &.{ root, relative });
    defer allocator.free(path);
    if (std.fs.path.dirname(path)) |parent| try std.Io.Dir.cwd().createDirPath(io, parent);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes, .flags = .{ .truncate = true } });
}

fn pathExists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}
