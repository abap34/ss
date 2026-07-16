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
    try validateBundle(allocator, io, building, &assets);

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
        try out.appendSlice(allocator, "\",\"resource_id\":\"");
        const resource_hex = std.fmt.bytesToHex(asset.resource, .lower);
        try out.appendSlice(allocator, &resource_hex);
        try out.appendSlice(allocator, "\",\"font_index\":");
        if (asset.font_index) |font_index| {
            const font_index_text = try std.fmt.allocPrint(allocator, "{d}", .{font_index});
            defer allocator.free(font_index_text);
            try out.appendSlice(allocator, font_index_text);
        } else try out.appendSlice(allocator, "null");
        try out.appendSlice(allocator, ",\"media_type\":\"");
        try appendJsonStringContent(allocator, &out, asset.media_type);
        try out.appendSlice(allocator, "\",\"digest\":\"sha256:");
        const digest_hex = std.fmt.bytesToHex(asset.digest, .lower);
        try out.appendSlice(allocator, &digest_hex);
        try out.appendSlice(allocator, "\",\"path\":\"");
        try appendJsonStringContent(allocator, &out, asset.relative_path);
        try out.appendSlice(allocator, "\",\"bytes\":");
        const size = try std.fmt.allocPrint(allocator, "{d}", .{asset.bytes.len});
        defer allocator.free(size);
        try out.appendSlice(allocator, size);
        try out.append(allocator, '}');
    }
    try out.appendSlice(allocator, "],\"local_fonts\":[");
    for (assets.local_fonts, 0..) |font, index| {
        if (index != 0) try out.append(allocator, ',');
        try out.appendSlice(allocator, "{\"resource_id\":\"");
        const resource_hex = std.fmt.bytesToHex(font.resource, .lower);
        try out.appendSlice(allocator, &resource_hex);
        try out.appendSlice(allocator, "\",\"font_index\":");
        const font_index = try std.fmt.allocPrint(allocator, "{d}", .{font.face_index});
        defer allocator.free(font_index);
        try out.appendSlice(allocator, font_index);
        try out.appendSlice(allocator, ",\"family\":\"");
        try appendJsonStringContent(allocator, &out, font.family);
        try out.append(allocator, '"');
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
    if (!validRelativePath(relative)) return error.InvalidHtmlResourceName;
    const path = try std.fs.path.join(allocator, &.{ root, relative });
    defer allocator.free(path);
    if (std.fs.path.dirname(path)) |parent| try std.Io.Dir.cwd().createDirPath(io, parent);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes, .flags = .{ .truncate = true } });
}

fn validateBundle(allocator: std.mem.Allocator, io: std.Io, root: []const u8, assets: *const resources.Set) !void {
    var paths = std.StringHashMap(void).init(allocator);
    defer paths.deinit();
    for (assets.assets) |asset| {
        if (!validRelativePath(asset.relative_path)) return error.InvalidHtmlResourceName;
        const entry = try paths.getOrPut(asset.relative_path);
        if (entry.found_existing) return error.DuplicateHtmlResource;
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(asset.bytes, &digest, .{});
        if (!std.mem.eql(u8, &digest, &asset.digest)) return error.InvalidHtmlResourceDigest;
        const path = try std.fs.path.join(allocator, &.{ root, asset.relative_path });
        defer allocator.free(path);
        const published = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(asset.bytes.len + 1));
        defer allocator.free(published);
        if (!std.mem.eql(u8, published, asset.bytes)) return error.InvalidHtmlResourceDigest;
    }
    try validateRequiredFiles(allocator, io, root, &.{ "index.html", "ss.css", "manifest.json" });
    if (assets.has_pdf) {
        try validateRequiredFiles(allocator, io, root, &.{ "ss.js", "pdf.js", "pdfjs/pdf.mjs", "pdfjs/pdf.worker.mjs", "pdfjs/LICENSE" });
    }
    const manifest_path = try std.fs.path.join(allocator, &.{ root, "manifest.json" });
    defer allocator.free(manifest_path);
    const manifest = try std.Io.Dir.cwd().readFileAlloc(io, manifest_path, allocator, .limited(4 * 1024 * 1024));
    defer allocator.free(manifest);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, manifest, .{});
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |value| value,
        else => return error.InvalidHtmlManifest,
    };
    const schema = object.get("schema") orelse return error.InvalidHtmlManifest;
    if (schema != .integer or schema.integer != 1) return error.InvalidHtmlManifest;
    const kind = object.get("kind") orelse return error.InvalidHtmlManifest;
    if (kind != .string or !std.mem.eql(u8, kind.string, "ss-html-bundle")) return error.InvalidHtmlManifest;
    const manifest_resources = object.get("resources") orelse return error.InvalidHtmlManifest;
    if (manifest_resources != .array or manifest_resources.array.items.len != assets.assets.len) return error.InvalidHtmlManifest;
}

fn validateRequiredFiles(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    relative_paths: []const []const u8,
) !void {
    for (relative_paths) |relative| {
        const path = try std.fs.path.join(allocator, &.{ root, relative });
        defer allocator.free(path);
        try std.Io.Dir.cwd().access(io, path, .{});
    }
}

fn validRelativePath(path: []const u8) bool {
    if (path.len == 0 or std.fs.path.isAbsolute(path) or std.mem.indexOfScalar(u8, path, '\\') != null) return false;
    var components = std.mem.splitScalar(u8, path, '/');
    while (components.next()) |component| {
        if (component.len == 0 or std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) return false;
    }
    return true;
}

fn pathExists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}
