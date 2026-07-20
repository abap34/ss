const std = @import("std");
const render = @import("render");

const document = @import("html/document.zig");
const embedded_runtime = @import("html/embedded_runtime.zig");
const pdf_runtime = @import("html/pdf/runtime.zig");
const resources = @import("html/resources.zig");

const CachedFragment = struct {
    allocator: std.mem.Allocator,
    references: std.atomic.Value(usize) = .init(1),
    html: []u8,
    css: []u8,

    fn create(allocator: std.mem.Allocator, html: []u8, css: []u8) !*CachedFragment {
        const fragment = try allocator.create(CachedFragment);
        fragment.* = .{ .allocator = allocator, .html = html, .css = css };
        return fragment;
    }

    fn retain(self: *CachedFragment) void {
        _ = self.references.fetchAdd(1, .monotonic);
    }

    fn release(self: *CachedFragment) void {
        if (self.references.fetchSub(1, .acq_rel) != 1) return;
        self.allocator.free(self.html);
        self.allocator.free(self.css);
        self.allocator.destroy(self);
    }
};

pub const Cache = struct {
    allocator: std.mem.Allocator,
    resources: resources.Cache,
    fragments: std.AutoHashMap(render.Fingerprint, *CachedFragment),
    fragment_bytes: usize = 0,

    const max_fragments = 4;
    const max_fragment_bytes = 64 * 1024 * 1024;

    pub fn init(allocator: std.mem.Allocator) Cache {
        return .{
            .allocator = allocator,
            .resources = resources.Cache.init(allocator),
            .fragments = std.AutoHashMap(render.Fingerprint, *CachedFragment).init(allocator),
        };
    }

    pub fn deinit(self: *Cache) void {
        self.clearFragments();
        self.fragments.deinit();
        self.resources.deinit();
        self.* = undefined;
    }

    fn clearFragments(self: *Cache) void {
        var values = self.fragments.valueIterator();
        while (values.next()) |fragment| fragment.*.release();
        self.fragments.clearRetainingCapacity();
        self.fragment_bytes = 0;
    }
};

pub const Fragment = struct {
    html: []u8,
    css: []u8,
    assets: resources.Set,
    shared_text: *CachedFragment,

    pub fn deinit(self: *Fragment, allocator: std.mem.Allocator) void {
        self.shared_text.release();
        self.assets.deinit(allocator);
        self.* = undefined;
    }
};

pub fn prepareFragment(
    allocator: std.mem.Allocator,
    ir: *const render.Ir,
    key: render.Fingerprint,
    cache: *Cache,
) !Fragment {
    try ir.validate();
    var assets = try resources.collect(allocator, ir, &cache.resources);
    errdefer assets.deinit(allocator);
    if (cache.fragments.get(key)) |cached| {
        cached.retain();
        return .{
            .html = cached.html,
            .css = cached.css,
            .assets = assets,
            .shared_text = cached,
        };
    }
    const references = resources.References{ .set = &assets, .mode = .external };
    const html = try document.fragment(allocator, ir, references);
    errdefer allocator.free(html);
    const style_sheet = try document.styleSheet(allocator, ir, references, false);
    errdefer allocator.free(style_sheet);
    const byte_size = html.len +| style_sheet.len;
    if (byte_size > Cache.max_fragment_bytes) {
        const shared = try CachedFragment.create(allocator, html, style_sheet);
        return .{ .html = shared.html, .css = shared.css, .assets = assets, .shared_text = shared };
    }
    if (cache.fragments.count() >= Cache.max_fragments or
        cache.fragment_bytes > Cache.max_fragment_bytes - byte_size)
    {
        cache.clearFragments();
    }
    try cache.fragments.ensureUnusedCapacity(1);
    const shared = try CachedFragment.create(allocator, html, style_sheet);
    cache.fragments.putAssumeCapacityNoClobber(key, shared);
    cache.fragment_bytes += byte_size;
    shared.retain();
    return .{ .html = shared.html, .css = shared.css, .assets = assets, .shared_text = shared };
}

pub fn write(
    allocator: std.mem.Allocator,
    io: std.Io,
    ir: *const render.Ir,
    output_path: []const u8,
) !void {
    try ir.validate();
    var assets = try resources.collect(allocator, ir, null);
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
