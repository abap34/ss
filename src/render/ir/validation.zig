const std = @import("std");

pub const Error = error{
    UnsupportedSchema,
    InvalidPageIndex,
    InvalidPageSize,
    InvalidItemId,
    InvalidPaintIndex,
    InvalidBounds,
    InvalidTransform,
    InvalidOpacity,
    InvalidItemGeometry,
    InvalidAnnotation,
    InvalidResource,
    MissingResource,
    InvalidSemantics,
    SemanticCycle,
};

pub fn document(ir: anytype) Error!void {
    if (ir.schema_version != 3) return error.UnsupportedSchema;
    for (ir.resources.entries, 0..) |resource, resource_index| {
        const expected = @import("resources.zig").identify(resource.kind, resource.bytes);
        if (!std.mem.eql(u8, &resource.id, &expected)) return error.InvalidResource;
        for (ir.resources.entries[0..resource_index]) |previous| {
            if (std.mem.eql(u8, &previous.id, &resource.id)) return error.InvalidResource;
        }
    }
    try semanticTree(ir);
    try mathCatalog(ir);
    for (ir.pages, 0..) |*page, page_index| {
        if (page.index != page_index) return error.InvalidPageIndex;
        if (!positiveFinite(page.width) or !positiveFinite(page.height)) return error.InvalidPageSize;
        for (page.items.items, 0..) |item, paint_index| {
            const header = item.header();
            if (header.paint_index != paint_index) return error.InvalidPaintIndex;
            const expected_id = (@as(u64, @intCast(page_index + 1)) << 32) | @as(u64, @intCast(paint_index));
            if (header.item_id != expected_id) return error.InvalidItemId;
            if (!header.bounds.isValid() or !header.ink_bounds.isValid()) return error.InvalidBounds;
            if (!header.transform.isFinite()) return error.InvalidTransform;
            if (!std.math.isFinite(header.opacity) or header.opacity < 0 or header.opacity > 1) return error.InvalidOpacity;
            try itemGeometry(ir, item);
            if (header.semantic_id) |semantic_id| {
                const semantic = ir.semantics.find(semantic_id) orelse return error.InvalidSemantics;
                var found = false;
                for (semantic.items) |item_id| if (item_id == header.item_id) {
                    found = true;
                    break;
                };
                if (!found) return error.InvalidSemantics;
            }
        }
        for (page.links.items) |link| if (!link.rect.isValid()) return error.InvalidAnnotation;
        for (page.destinations.items) |destination| {
            if (!std.math.isFinite(destination.point.x) or !std.math.isFinite(destination.point.y)) return error.InvalidAnnotation;
        }
        for (page.reading_order) |semantic_id| if (ir.semantics.find(semantic_id) == null) return error.InvalidSemantics;
    }
}

fn semanticTree(ir: anytype) Error!void {
    const root = ir.semantics.root orelse return error.InvalidSemantics;
    const root_node = ir.semantics.find(root) orelse return error.InvalidSemantics;
    if (root_node.role != .document) return error.InvalidSemantics;
    for (ir.semantics.nodes, 0..) |node, index| {
        for (ir.semantics.nodes[0..index]) |previous| if (previous.id == node.id) return error.InvalidSemantics;
        for (node.children) |child| if (ir.semantics.find(child) == null) return error.InvalidSemantics;
        try rejectSemanticCycle(ir, node.id, node.id, 0);
    }
}

fn rejectSemanticCycle(ir: anytype, origin: anytype, current: anytype, depth: usize) Error!void {
    if (depth > ir.semantics.nodes.len) return error.SemanticCycle;
    const node = ir.semantics.find(current) orelse return error.InvalidSemantics;
    for (node.children) |child| {
        if (child == origin) return error.SemanticCycle;
        try rejectSemanticCycle(ir, origin, child, depth + 1);
    }
}

fn itemGeometry(ir: anytype, item: anytype) Error!void {
    switch (item) {
        .fill_rect => |value| if (!value.rect.isValid()) return error.InvalidItemGeometry,
        .stroke_line => |value| {
            if (!pointFinite(value.start) or !pointFinite(value.end) or
                !nonNegativeFinite(value.line_width) or
                !nonNegativeFinite(value.dash_on) or
                !nonNegativeFinite(value.dash_off)) return error.InvalidItemGeometry;
        },
        .rounded_rect => |value| {
            if (!value.rect.isValid() or !nonNegativeFinite(value.radius) or !nonNegativeFinite(value.line_width)) {
                return error.InvalidItemGeometry;
            }
        },
        .text => |value| {
            if (!std.math.isFinite(value.x) or !std.math.isFinite(value.y) or
                !nonNegativeFinite(value.width) or !positiveFinite(value.font_size)) return error.InvalidItemGeometry;
            if (!value.layout.logical_bounds.isValid() or !value.layout.ink_bounds.isValid()) return error.InvalidItemGeometry;
            for (value.layout.lines) |line| {
                if (!line.logical_bounds.isValid() or !line.ink_bounds.isValid() or !std.math.isFinite(line.baseline_y)) return error.InvalidItemGeometry;
            }
            for (value.layout.runs) |run| {
                if (!std.math.isFinite(run.x) or !std.math.isFinite(run.baseline_y) or !std.math.isFinite(run.advance)) return error.InvalidItemGeometry;
                if (run.source.start > run.source.end or run.source.end > value.layout.source_text.len) return error.InvalidItemGeometry;
                if (run.glyph_range.start > run.glyph_range.end or run.glyph_range.end > value.layout.glyphs.len) return error.InvalidItemGeometry;
                if (run.cluster_range.start > run.cluster_range.end or run.cluster_range.end > value.layout.clusters.len) return error.InvalidItemGeometry;
                if (run.font_resource) |resource| try requireResource(ir, resource, .font);
            }
            for (value.layout.clusters) |cluster| {
                if (cluster.source.start > cluster.source.end or cluster.source.end > value.layout.source_text.len) return error.InvalidItemGeometry;
                if (cluster.glyph_range.start > cluster.glyph_range.end or cluster.glyph_range.end > value.layout.glyphs.len) return error.InvalidItemGeometry;
                if (!std.math.isFinite(cluster.x) or !nonNegativeFinite(cluster.advance)) return error.InvalidItemGeometry;
            }
        },
        .raster => |value| {
            if (!value.rect.isValid()) return error.InvalidItemGeometry;
            try requireResource(ir, value.resource, .raster);
        },
        .svg => |value| {
            if (!value.rect.isValid()) return error.InvalidItemGeometry;
            try requireResource(ir, value.resource, .svg);
        },
        .math => |value| {
            if (!value.rect.isValid()) return error.InvalidItemGeometry;
            if (ir.math.find(value.tree) == null) return error.InvalidItemGeometry;
            try requireResource(ir, value.pdf_resource, .math_pdf);
        },
        .pdf_page => |value| {
            if (!value.rect.isValid()) return error.InvalidItemGeometry;
            try requireResource(ir, value.resource, .pdf);
        },
    }
}

fn mathCatalog(ir: anytype) Error!void {
    for (ir.math.trees, 0..) |tree, tree_index| {
        for (ir.math.trees[0..tree_index]) |previous| if (previous.id == tree.id) return error.InvalidItemGeometry;
        if (tree.find(tree.root) == null) return error.InvalidItemGeometry;
        for (tree.nodes, 0..) |node, node_index| {
            if (node.id != node_index) return error.InvalidItemGeometry;
            for (node.children) |child| if (tree.find(child) == null) return error.InvalidItemGeometry;
            try rejectMathCycle(&tree, node.id, node.id, 0);
        }
    }
}

fn rejectMathCycle(tree: anytype, origin: anytype, current: anytype, depth: usize) Error!void {
    if (depth > tree.nodes.len) return error.InvalidItemGeometry;
    const node = tree.find(current) orelse return error.InvalidItemGeometry;
    for (node.children) |child| {
        if (child == origin) return error.InvalidItemGeometry;
        try rejectMathCycle(tree, origin, child, depth + 1);
    }
}

fn requireResource(ir: anytype, id: anytype, kind: anytype) Error!void {
    const resource = ir.resources.find(id) orelse return error.MissingResource;
    if (resource.kind != kind) return error.InvalidResource;
}

fn pointFinite(point: anytype) bool {
    return std.math.isFinite(point.x) and std.math.isFinite(point.y);
}

fn nonNegativeFinite(value: f64) bool {
    return std.math.isFinite(value) and value >= 0;
}

fn positiveFinite(value: f64) bool {
    return std.math.isFinite(value) and value > 0;
}
