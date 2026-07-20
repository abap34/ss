const std = @import("std");
const core = @import("core");
const render = @import("render");
const resources_compile = @import("render_resources");
const text = @import("render_text");

pub fn appendText(
    allocator: std.mem.Allocator,
    io: std.Io,
    page: *render.Page,
    resources: *resources_compile.Builder,
    fonts: *render.FontBuilder,
    node_id: ?core.NodeId,
    x: f64,
    baseline_y: f64,
    width: f64,
    source: []const u8,
    face: core.font.Face,
    font_size: f64,
    color: core.render_policy.Color,
) !void {
    const layout = try text.shape(allocator, io, resources, fonts, source, face, font_size, width, false, null);
    try page.appendTextLayout(allocator, node_id, x, baseline_y, width, layout, font_size, color);
}

pub fn takeCatalogs(
    allocator: std.mem.Allocator,
    resources: *resources_compile.Builder,
    fonts: *render.FontBuilder,
) !struct { resources: render.ResourceGraph, fonts: render.FontCatalog } {
    const resource_graph = try resources.take(allocator);
    errdefer {
        var owned = resource_graph;
        owned.deinit(allocator);
    }
    const font_catalog = try fonts.take(allocator);
    return .{ .resources = resource_graph, .fonts = font_catalog };
}
