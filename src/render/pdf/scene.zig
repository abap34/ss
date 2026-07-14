const std = @import("std");
const core = @import("core");
const draw_sink = @import("render_sink");
const c = @import("pdf_ffi").c;
const render_scene = @import("render_scene");

const Allocator = std.mem.Allocator;

pub const Page = render_scene.Page;

pub fn render(allocator: Allocator, io: std.Io, scene: *const render_scene.Page, output: []const u8) !void {
    errdefer deleteFileIfExists(io, output);
    if (scene.hasPdfPages()) {
        try renderComposed(allocator, io, scene, output);
    } else {
        try renderCairo(allocator, scene, output);
    }
}

fn renderCairo(allocator: Allocator, scene: *const render_scene.Page, output: []const u8) !void {
    const output_z = try allocator.dupeZ(u8, output);
    defer allocator.free(output_z);
    const pdf = c.ss_pdf_create(output_z.ptr, scene.width, scene.height) orelse return error.CairoCreateFailed;
    defer c.ss_pdf_destroy(pdf);
    c.ss_pdf_set_creator(pdf, "ss scene Cairo/Pango backend");
    c.ss_pdf_begin_page(pdf, scene.width, scene.height);
    try replayItems(pdf, scene.items.items);
    try emitAnnotations(pdf, scene);
    c.ss_pdf_end_page(pdf);
    if (c.ss_pdf_finish(pdf) != 0) return error.CairoFailed;
}

fn renderComposed(allocator: Allocator, io: std.Io, scene: *const render_scene.Page, output: []const u8) !void {
    var composition = Composition.init(allocator, io, scene, output);
    defer composition.deinit();

    var segment_start: usize = 0;
    var first_native_layer = true;
    for (scene.items.items, 0..) |item, item_index| {
        if (item != .pdf_page) continue;
        if (segment_start < item_index or first_native_layer) {
            try composition.appendNativeLayer(segment_start, item_index, first_native_layer);
            first_native_layer = false;
        }
        try composition.appendPdfLayer(item.pdf_page);
        segment_start = item_index + 1;
    }
    if (segment_start < scene.items.items.len) {
        try composition.appendNativeLayer(segment_start, scene.items.items.len, first_native_layer);
    }
    try composition.write();
}

const Composition = struct {
    allocator: Allocator,
    io: std.Io,
    scene: *const render_scene.Page,
    output: []const u8,
    layers: std.ArrayList(c.SsQpdfLayer) = .empty,
    owned_paths: std.ArrayList([:0]u8) = .empty,
    native_paths: std.ArrayList([]u8) = .empty,
    next_layer_index: usize = 0,

    fn init(allocator: Allocator, io: std.Io, scene: *const render_scene.Page, output: []const u8) Composition {
        return .{
            .allocator = allocator,
            .io = io,
            .scene = scene,
            .output = output,
        };
    }

    fn deinit(self: *Composition) void {
        for (self.native_paths.items) |path| {
            deleteFileIfExists(self.io, path);
            self.allocator.free(path);
        }
        self.native_paths.deinit(self.allocator);
        for (self.owned_paths.items) |path| self.allocator.free(path);
        self.owned_paths.deinit(self.allocator);
        self.layers.deinit(self.allocator);
    }

    fn appendNativeLayer(self: *Composition, start: usize, end: usize, first_layer: bool) !void {
        const native_path = try layerPath(self.allocator, self.output, self.next_layer_index);
        errdefer self.allocator.free(native_path);
        errdefer deleteFileIfExists(self.io, native_path);
        try renderNativeLayer(self.allocator, self.scene, native_path, start, end, first_layer);

        const native_path_z = try self.allocator.dupeZ(u8, native_path);
        self.owned_paths.append(self.allocator, native_path_z) catch |err| {
            self.allocator.free(native_path_z);
            return err;
        };
        try self.layers.append(self.allocator, .{
            .path = native_path_z.ptr,
            .page_index = 0,
            .box = @intFromEnum(core.render_policy.PdfPageBox.crop),
            .x = 0,
            .y = 0,
            .width = self.scene.width,
            .height = self.scene.height,
            .copy_annotations = 0,
        });
        try self.native_paths.append(self.allocator, native_path);
        self.next_layer_index += 1;
    }

    fn appendPdfLayer(self: *Composition, item: render_scene.PdfPage) !void {
        try self.layers.append(self.allocator, .{
            .path = item.path.ptr,
            .page_index = item.page_index,
            .box = @intFromEnum(item.box),
            .x = item.rect.x,
            .y = self.scene.height - item.rect.y - item.rect.height,
            .width = item.rect.width,
            .height = item.rect.height,
            .copy_annotations = if (item.copy_annotations) 1 else 0,
        });
    }

    fn write(self: *Composition) !void {
        const output_z = try self.allocator.dupeZ(u8, self.output);
        defer self.allocator.free(output_z);
        if (c.ss_qpdf_compose(output_z.ptr, self.layers.items.ptr, self.layers.items.len) != 0) {
            return error.AssetConversionFailed;
        }
    }
};

fn renderNativeLayer(
    allocator: Allocator,
    scene: *const render_scene.Page,
    path: []const u8,
    start: usize,
    end: usize,
    first_layer: bool,
) !void {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const pdf = c.ss_pdf_create(path_z.ptr, scene.width, scene.height) orelse return error.CairoCreateFailed;
    defer c.ss_pdf_destroy(pdf);
    c.ss_pdf_set_creator(pdf, "ss scene Cairo/Pango/libqpdf backend");
    c.ss_pdf_begin_page(pdf, scene.width, scene.height);
    if (first_layer) try emitAnnotations(pdf, scene);
    try replayItems(pdf, scene.items.items[start..end]);
    c.ss_pdf_end_page(pdf);
    if (c.ss_pdf_finish(pdf) != 0) return error.CairoFailed;
}

fn replayItems(pdf: *c.SsPdf, items: []const render_scene.Item) !void {
    var sink = draw_sink.Sink{ .pdf = pdf };
    for (items) |item| try sink.replayItem(item);
}

fn emitAnnotations(pdf: *c.SsPdf, scene: *const render_scene.Page) !void {
    for (scene.destinations.items) |destination| {
        if (c.ss_pdf_add_destination(pdf, destination.name.ptr, destination.point.x, destination.point.y) != 0) {
            return error.CairoFailed;
        }
    }
    for (scene.links.items) |link| {
        const result = switch (link.kind) {
            .destination => c.ss_pdf_begin_dest_link(pdf, link.rect.x, link.rect.y, link.rect.width, link.rect.height, link.target.ptr),
            .uri => c.ss_pdf_begin_uri_link(pdf, link.rect.x, link.rect.y, link.rect.width, link.rect.height, link.target.ptr),
        };
        if (result != 0) return error.CairoFailed;
        c.ss_pdf_end_link(pdf);
    }
}

fn layerPath(allocator: Allocator, output: []const u8, index: usize) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}.layer-{d}.pdf", .{ output, index });
}

fn deleteFileIfExists(io: std.Io, path: []const u8) void {
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
}
