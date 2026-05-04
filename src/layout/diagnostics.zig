const std = @import("std");
const model = @import("model");
const graph = @import("graph.zig");

const Node = model.Node;
const NodeId = model.NodeId;
const PageLayout = model.PageLayout;

pub fn collectPageDiagnostics(ir: anytype, page_id: NodeId, child_ids: []const NodeId) !void {
    for (child_ids) |child_id| {
        const node = ir.getNode(child_id) orelse return error.UnknownNode;

        if (!node.frame.x_set or !node.frame.y_set) {
            try ir.addLayoutError(page_id, child_id, .{
                .unresolved_frame = .{
                    .missing_horizontal = !node.frame.x_set,
                    .missing_vertical = !node.frame.y_set,
                },
            });
            continue;
        }

        const overflow_left = @max(@as(f32, 0.0), -node.frame.x);
        const overflow_right = @max(@as(f32, 0.0), node.frame.x + node.frame.width - PageLayout.width);
        const overflow_bottom = @max(@as(f32, 0.0), -node.frame.y);
        const overflow_top = @max(@as(f32, 0.0), node.frame.y + node.frame.height - PageLayout.height);

        if (overflow_left > graph.ConstraintTolerance or overflow_right > graph.ConstraintTolerance or overflow_bottom > graph.ConstraintTolerance or overflow_top > graph.ConstraintTolerance) {
            switch (overflowPolicy(node)) {
                .ignore => {},
                .warn => try ir.addLayoutWarning(page_id, child_id, .{
                    .page_overflow = .{
                        .overflow_left = overflow_left,
                        .overflow_right = overflow_right,
                        .overflow_top = overflow_top,
                        .overflow_bottom = overflow_bottom,
                    },
                }),
                .@"error" => try ir.addLayoutError(page_id, child_id, .{
                    .page_overflow = .{
                        .overflow_left = overflow_left,
                        .overflow_right = overflow_right,
                        .overflow_top = overflow_top,
                        .overflow_bottom = overflow_bottom,
                    },
                }),
            }
        }
    }
}

const OverflowPolicy = enum {
    warn,
    @"error",
    ignore,
};

fn overflowPolicy(node: *const Node) OverflowPolicy {
    const fit = model.nodeProperty(node, "fit");
    if (fit) |value| {
        if (std.mem.eql(u8, value, "ignore")) return .ignore;
        if (std.mem.eql(u8, value, "error")) return .@"error";
    }
    return .warn;
}
