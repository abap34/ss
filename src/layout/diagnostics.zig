const std = @import("std");
const model = @import("model");
const fields = @import("../core/fields.zig");
const graph = @import("graph.zig");
const metrics = @import("metrics.zig");

const Node = model.Node;
const NodeId = model.NodeId;
const PageLayout = model.PageLayout;

const OverflowDiagnostic = struct {
    node_id: NodeId,
    origin: ?[]const u8,
    policy: OverflowPolicy,
    overflow_left: f32,
    overflow_right: f32,
    overflow_top: f32,
    overflow_bottom: f32,
};

pub fn collectPageDiagnostics(ir: anytype, page_id: NodeId, child_ids: []const NodeId) !void {
    try collectPageDiagnosticsWithCache(ir, page_id, child_ids, null);
}

pub fn collectPageDiagnosticsCached(ir: anytype, page_id: NodeId, child_ids: []const NodeId, measurement_cache: *metrics.MeasurementCache) !void {
    try collectPageDiagnosticsWithCache(ir, page_id, child_ids, measurement_cache);
}

fn collectPageDiagnosticsWithCache(ir: anytype, page_id: NodeId, child_ids: []const NodeId, measurement_cache: ?*metrics.MeasurementCache) !void {
    var overflows = std.ArrayList(OverflowDiagnostic).empty;
    defer overflows.deinit(ir.allocator);

    for (child_ids) |child_id| {
        const node = ir.getNode(child_id) orelse return error.UnknownNode;

        if (!node.frame.x_set or !node.frame.y_set) {
            continue;
        }

        const overflow_left = @max(@as(f32, 0.0), -node.frame.x);
        const overflow_right = @max(@as(f32, 0.0), node.frame.x + node.frame.width - PageLayout.width);
        const overflow_bottom = @max(@as(f32, 0.0), -node.frame.y);
        const overflow_top = @max(@as(f32, 0.0), node.frame.y + node.frame.height - PageLayout.height);

        if (overflow_left > graph.ConstraintTolerance or overflow_right > graph.ConstraintTolerance or overflow_bottom > graph.ConstraintTolerance or overflow_top > graph.ConstraintTolerance) {
            const policy = overflowPolicy(ir, node);
            switch (policy) {
                .ignore => {},
                .warn, .@"error" => try appendOverflowDiagnostic(ir.allocator, &overflows, .{
                    .node_id = child_id,
                    .origin = node.origin,
                    .policy = policy,
                    .overflow_left = overflow_left,
                    .overflow_right = overflow_right,
                    .overflow_top = overflow_top,
                    .overflow_bottom = overflow_bottom,
                }),
            }
        }

        if (shouldCheckContentOverflow(ir, node)) {
            const required_height = if (measurement_cache) |cache|
                try metrics.intrinsicHeightCached(ir, node, cache)
            else
                metrics.intrinsicHeight(ir, node);
            const overflow_height = @max(@as(f32, 0.0), required_height - node.frame.height);
            if (overflow_height > graph.ConstraintTolerance) {
                switch (overflowPolicy(ir, node)) {
                    .ignore => {},
                    .warn => try ir.addLayoutWarning(page_id, child_id, .{ .content_overflow = .{
                        .required_height = required_height,
                        .frame_height = node.frame.height,
                        .overflow_height = overflow_height,
                    } }),
                    .@"error" => try ir.addLayoutError(page_id, child_id, .{ .content_overflow = .{
                        .required_height = required_height,
                        .frame_height = node.frame.height,
                        .overflow_height = overflow_height,
                    } }),
                }
            }
        }
    }

    for (overflows.items) |overflow| {
        const data: model.Diagnostic.Data = .{ .page_overflow = .{
            .overflow_left = overflow.overflow_left,
            .overflow_right = overflow.overflow_right,
            .overflow_top = overflow.overflow_top,
            .overflow_bottom = overflow.overflow_bottom,
        } };
        switch (overflow.policy) {
            .ignore => {},
            .warn => try ir.addLayoutWarning(page_id, overflow.node_id, data),
            .@"error" => try ir.addLayoutError(page_id, overflow.node_id, data),
        }
    }
}

const OverflowPolicy = enum {
    warn,
    @"error",
    ignore,
};

fn shouldCheckContentOverflow(ir: anytype, node: *const Node) bool {
    _ = ir;
    if (node.kind != .object) return false;
    return true;
}

fn overflowPolicy(ir: anytype, node: *const Node) OverflowPolicy {
    const fit = fields.read(ir.allocator, ir, node, "layout", &.{"fit"}, .text);
    if (fit) |value| {
        if (std.meta.stringToEnum(OverflowPolicy, value)) |parsed| return parsed;
    }
    return .warn;
}

fn appendOverflowDiagnostic(
    allocator: std.mem.Allocator,
    overflows: *std.ArrayList(OverflowDiagnostic),
    incoming: OverflowDiagnostic,
) !void {
    for (overflows.items) |*existing| {
        if (existing.policy != incoming.policy) continue;
        if (!sameOriginOrNode(existing.*, incoming)) continue;
        existing.overflow_left = @max(existing.overflow_left, incoming.overflow_left);
        existing.overflow_right = @max(existing.overflow_right, incoming.overflow_right);
        existing.overflow_top = @max(existing.overflow_top, incoming.overflow_top);
        existing.overflow_bottom = @max(existing.overflow_bottom, incoming.overflow_bottom);
        return;
    }
    try overflows.append(allocator, incoming);
}

fn sameOriginOrNode(a: OverflowDiagnostic, b: OverflowDiagnostic) bool {
    if (a.origin) |a_origin| {
        if (b.origin) |b_origin| return std.mem.eql(u8, a_origin, b_origin);
    } else if (b.origin == null) {
        return a.node_id == b.node_id;
    }
    return false;
}
