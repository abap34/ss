const std = @import("std");
const core = @import("core");
const render = @import("render");
const utils = @import("utils");
const semantics = @import("compile/semantics.zig");

pub const Options = struct {
    cache_dir: []const u8 = ".ss-cache/render",
    highlight_languages: []const utils.highlight.Language = &.{},
};

pub fn document(
    allocator: std.mem.Allocator,
    state: *core.DocumentState,
    prepared_pages: *const core.prepared.PreparedPages,
    compiler: anytype,
) !render.Ir {
    try compiler.prepare(allocator, state, prepared_pages);
    var resources = render.ResourceBuilder{};
    defer resources.deinit(allocator);
    var fonts = render.FontBuilder{};
    defer fonts.deinit(allocator);
    var math = render.MathBuilder{};
    defer math.deinit(allocator);

    var pages = std.ArrayList(render.Page).empty;
    errdefer {
        for (pages.items) |*page| page.deinit(allocator);
        pages.deinit(allocator);
    }
    for (prepared_pages.pages) |*prepared_page| {
        var page = try compiler.compilePage(
            allocator,
            state,
            prepared_page,
            &resources,
            &fonts,
            &math,
        );
        errdefer page.deinit(allocator);
        page.name = if (state.getNode(prepared_page.page_id)) |page_node|
            try allocator.dupe(u8, page_node.name)
        else
            try std.fmt.allocPrint(allocator, "Page {d}", .{prepared_page.index + 1});
        for (page.items.items) |*item| item.setSource(sourceRange(state, item.nodeId()));
        try pages.append(allocator, page);
    }
    var semantic_tree = try semantics.build(allocator, state, prepared_pages, pages.items);
    errdefer semantic_tree.deinit(allocator);
    const resource_graph = try resources.take(allocator);
    errdefer {
        var owned_resources = resource_graph;
        owned_resources.deinit(allocator);
    }
    var font_catalog = try fonts.take(allocator);
    errdefer font_catalog.deinit(allocator);
    var math_catalog = try math.take(allocator);
    errdefer math_catalog.deinit(allocator);
    var ir = render.Ir{
        .resources = resource_graph,
        .fonts = font_catalog,
        .semantics = semantic_tree,
        .math = math_catalog,
        .pages = try pages.toOwnedSlice(allocator),
    };
    errdefer ir.deinit(allocator);
    try ir.validate();
    return ir;
}

fn sourceRange(state: *const core.DocumentState, node_id: ?core.NodeId) ?render.SourceRange {
    const resolved_node_id = node_id orelse return null;
    for (state.object_sources.items) |source| {
        if (source.node_id != resolved_node_id) continue;
        return .{ .module_id = source.module_id, .start = source.span_start, .end = source.span_end };
    }
    return null;
}
