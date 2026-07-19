const std = @import("std");

pub fn catalog(ir: anytype) !void {
    for (ir.math.trees, 0..) |tree, tree_index| {
        if (tree.id != tree_index + 1 or tree.nodes.len == 0 or !std.unicode.utf8ValidateSlice(tree.source)) return error.InvalidItemGeometry;
        if (tree.find(tree.root) == null) return error.InvalidItemGeometry;
        for (tree.nodes, 0..) |node, node_index| {
            if (node.id != node_index) return error.InvalidItemGeometry;
            try validateNode(tree.input_kind, node);
            for (node.children, 0..) |child, child_index| {
                if (tree.find(child) == null) return error.InvalidItemGeometry;
                for (node.children[0..child_index]) |previous| if (previous == child) return error.InvalidItemGeometry;
            }
            const parent_count = parentCount(&tree, node.id);
            if ((node.id == tree.root and parent_count != 0) or (node.id != tree.root and parent_count != 1)) {
                return error.InvalidItemGeometry;
            }
            try rejectCycle(&tree, node.id, node.id, 0);
        }
        if (tree.input_kind == .raw and
            (tree.nodes.len != 1 or tree.root != 0 or tree.nodes[0].kind != .raw_tex)) return error.InvalidItemGeometry;
    }
}

fn validateNode(input_kind: anytype, node: anytype) !void {
    if (node.text) |text| if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidItemGeometry;
    switch (node.kind) {
        .identifier, .number, .operator, .text, .space, .raw_tex => {
            if (node.text == null or node.children.len != 0) return error.InvalidItemGeometry;
        },
        .row => if (node.text != null) return error.InvalidItemGeometry,
        .fraction, .superscript, .subscript => if (node.text != null or node.children.len != 2) return error.InvalidItemGeometry,
        .square_root => if (node.text != null or node.children.len != 1) return error.InvalidItemGeometry,
        .subscript_superscript => if (node.text != null or node.children.len != 3) return error.InvalidItemGeometry,
    }
    if ((input_kind == .raw) != (node.kind == .raw_tex)) return error.InvalidItemGeometry;
}

fn parentCount(tree: anytype, id: anytype) usize {
    var count: usize = 0;
    for (tree.nodes) |node| for (node.children) |child| if (child == id) {
        count += 1;
    };
    return count;
}

fn rejectCycle(tree: anytype, origin: anytype, current: anytype, depth: usize) !void {
    if (depth > tree.nodes.len) return error.InvalidItemGeometry;
    const node = tree.find(current) orelse return error.InvalidItemGeometry;
    for (node.children) |child| {
        if (child == origin) return error.InvalidItemGeometry;
        try rejectCycle(tree, origin, child, depth + 1);
    }
}
