const std = @import("std");
const pdfjs_assets = @import("pdfjs_assets");

const document = @import("../document.zig");
const resources = @import("../resources.zig");

const controller_source = @embedFile("controller.js");
const geometry_source = @embedFile("geometry.js");
const placement_source = @embedFile("placement.js");
const queue_source = @embedFile("queue.js");
const renderer_source = @embedFile("index.js");
const service_source = @embedFile("service.js");

pub const Embedded = struct {
    import_map: []u8,
    renderer_module: []u8,
    pdfjs_module: []u8,
    worker_module: []u8,

    pub fn init(allocator: std.mem.Allocator) !Embedded {
        const controller_module = try moduleUrl(allocator, controller_source);
        defer allocator.free(controller_module);
        const geometry_module = try moduleUrl(allocator, geometry_source);
        defer allocator.free(geometry_module);
        const placement_module = try moduleUrl(allocator, placement_source);
        defer allocator.free(placement_module);
        const queue_module = try moduleUrl(allocator, queue_source);
        defer allocator.free(queue_module);
        const service_module = try moduleUrl(allocator, service_source);
        defer allocator.free(service_module);
        const import_map = try importMap(
            allocator,
            controller_module,
            geometry_module,
            placement_module,
            queue_module,
            service_module,
        );
        errdefer allocator.free(import_map);
        const renderer_module = try moduleUrl(allocator, renderer_source);
        errdefer allocator.free(renderer_module);
        const pdfjs_module = try moduleUrl(allocator, pdfjs_assets.runtime);
        errdefer allocator.free(pdfjs_module);
        const worker_module = try moduleUrl(allocator, pdfjs_assets.worker);
        errdefer allocator.free(worker_module);
        return .{
            .import_map = import_map,
            .renderer_module = renderer_module,
            .pdfjs_module = pdfjs_module,
            .worker_module = worker_module,
        };
    }

    pub fn deinit(self: Embedded, allocator: std.mem.Allocator) void {
        allocator.free(self.import_map);
        allocator.free(self.renderer_module);
        allocator.free(self.pdfjs_module);
        allocator.free(self.worker_module);
    }

    pub fn documentRuntime(self: Embedded) document.PdfRuntime {
        return .{
            .import_map = self.import_map,
            .renderer_module = self.renderer_module,
            .pdfjs_module = self.pdfjs_module,
            .worker_module = self.worker_module,
            .license = pdfjs_assets.license,
        };
    }
};

fn moduleUrl(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    return resources.dataUrl(allocator, "text/javascript;charset=utf-8", source);
}

fn importMap(
    allocator: std.mem.Allocator,
    controller_module: []const u8,
    geometry_module: []const u8,
    placement_module: []const u8,
    queue_module: []const u8,
    service_module: []const u8,
) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"imports\":{\"@ss/pdf/controller\":\"");
    try out.appendSlice(allocator, controller_module);
    try out.appendSlice(allocator, "\",\"@ss/pdf/geometry\":\"");
    try out.appendSlice(allocator, geometry_module);
    try out.appendSlice(allocator, "\",\"@ss/pdf/placement\":\"");
    try out.appendSlice(allocator, placement_module);
    try out.appendSlice(allocator, "\",\"@ss/pdf/queue\":\"");
    try out.appendSlice(allocator, queue_module);
    try out.appendSlice(allocator, "\",\"@ss/pdf/service\":\"");
    try out.appendSlice(allocator, service_module);
    try out.appendSlice(allocator, "\"}}");
    return out.toOwnedSlice(allocator);
}
