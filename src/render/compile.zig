const std = @import("std");
const core = @import("core");
const render = @import("render");
const utils = @import("utils");

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
    var math = render.MathBuilder{};
    defer math.deinit(allocator);

    var pages = std.ArrayList(render.Page).empty;
    errdefer {
        for (pages.items) |*page| page.deinit(allocator);
        pages.deinit(allocator);
    }
    for (prepared_pages.pages) |*prepared_page| {
        try pages.append(allocator, try compiler.compilePage(
            allocator,
            state,
            prepared_page,
            &resources,
            &math,
        ));
    }
    var semantic_tree = try buildSemantics(allocator, pages.items);
    errdefer semantic_tree.deinit(allocator);
    const resource_graph = try resources.take(allocator);
    errdefer {
        var owned_resources = resource_graph;
        owned_resources.deinit(allocator);
    }
    var math_catalog = try math.take(allocator);
    errdefer math_catalog.deinit(allocator);
    var ir = render.Ir{
        .resources = resource_graph,
        .semantics = semantic_tree,
        .math = math_catalog,
        .pages = try pages.toOwnedSlice(allocator),
    };
    errdefer ir.deinit(allocator);
    try ir.validate();
    return ir;
}

fn buildSemantics(allocator: std.mem.Allocator, pages: []render.Page) !render.SemanticTree {
    var nodes = std.ArrayList(render.SemanticNode).empty;
    errdefer {
        for (nodes.items) |*node| node.deinit(allocator);
        nodes.deinit(allocator);
    }
    try nodes.append(allocator, .{ .id = 1, .role = .document });
    var document_children = std.ArrayList(render.SemanticId).empty;
    defer document_children.deinit(allocator);

    for (pages, 0..) |*page, page_index| {
        const page_semantic_id: render.SemanticId = @intCast(nodes.items.len + 1);
        const page_node_index = nodes.items.len;
        const page_name = try std.fmt.allocPrint(allocator, "Page {d}", .{page_index + 1});
        errdefer allocator.free(page_name);
        try nodes.append(allocator, .{ .id = page_semantic_id, .role = .page, .text = page_name });
        try document_children.append(allocator, page_semantic_id);

        var object_order = std.ArrayList(core.NodeId).empty;
        defer object_order.deinit(allocator);
        for (page.items.items) |item| {
            if (item.nodeId()) |node_id| {
                var seen = false;
                for (object_order.items) |existing| if (existing == node_id) {
                    seen = true;
                    break;
                };
                if (!seen) try object_order.append(allocator, node_id);
            }
        }
        var page_children = std.ArrayList(render.SemanticId).empty;
        defer page_children.deinit(allocator);
        for (object_order.items) |node_id| {
            const semantic_id: render.SemanticId = @intCast(nodes.items.len + 1);
            var item_ids = std.ArrayList(u64).empty;
            defer item_ids.deinit(allocator);
            var text = std.ArrayList(u8).empty;
            defer text.deinit(allocator);
            var role: render.SemanticRole = .group;
            for (page.items.items) |*item| {
                if (item.nodeId() != node_id) continue;
                item.setSemanticId(semantic_id);
                try item_ids.append(allocator, item.header().item_id);
                switch (item.*) {
                    .text => |value| {
                        role = .paragraph;
                        try text.appendSlice(allocator, value.layout.source_text);
                    },
                    .raster, .svg, .pdf_page => if (role == .group) {
                        role = .figure;
                    },
                    .math => role = .math,
                    else => {},
                }
            }
            try nodes.append(allocator, .{
                .id = semantic_id,
                .role = role,
                .items = try item_ids.toOwnedSlice(allocator),
                .text = if (text.items.len == 0) null else try text.toOwnedSlice(allocator),
            });
            try page_children.append(allocator, semantic_id);
        }
        nodes.items[page_node_index].children = try page_children.toOwnedSlice(allocator);
        page.reading_order = try allocator.dupe(render.SemanticId, nodes.items[page_node_index].children);
    }
    nodes.items[0].children = try document_children.toOwnedSlice(allocator);
    return .{ .root = 1, .nodes = try nodes.toOwnedSlice(allocator) };
}
