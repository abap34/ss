const std = @import("std");
const model = @import("model");
const fields = @import("../core/fields.zig");
const render_policy = @import("../core/render_policy.zig");
const graph = @import("graph.zig");
const metrics = @import("metrics.zig");

const Node = model.Node;
const NodeId = model.NodeId;
const PageLayout = model.PageLayout;
const Axis = model.Axis;

const OverflowDiagnostic = struct {
    node_id: NodeId,
    origin: ?[]const u8,
    policy: OverflowPolicy,
    overflow_left: f32,
    overflow_right: f32,
    overflow_top: f32,
    overflow_bottom: f32,
};

const FrameRequirement = struct {
    width: f32,
    height: f32,
};

const FixedAxes = struct {
    horizontal: bool,
    vertical: bool,
};

const VisualFrame = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
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

        const requirement = try frameRequirement(ir, node, measurement_cache);
        if (pageVisualFrame(ir, node, requirement)) |visual| {
            const visual_top = visual.y + visual.height;
            const visual_bottom = visual.y;

            const overflow_left = @max(@as(f32, 0.0), -visual.x);
            const overflow_right = @max(@as(f32, 0.0), visual.x + visual.width - PageLayout.width);
            const overflow_bottom = @max(@as(f32, 0.0), -visual_bottom);
            const overflow_top = @max(@as(f32, 0.0), visual_top - PageLayout.height);

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
        }

        if (requirement) |measured| {
            const fixed_axes = fixedAxesForNode(ir, child_id);
            const overflow_width = if (fixed_axes.horizontal)
                @max(@as(f32, 0.0), measured.width - node.frame.width)
            else
                0;
            const overflow_height = if (fixed_axes.vertical)
                @max(@as(f32, 0.0), measured.height - node.frame.height)
            else
                0;
            if (overflow_width > graph.ConstraintTolerance or overflow_height > graph.ConstraintTolerance) {
                switch (overflowPolicy(ir, node)) {
                    .ignore => {},
                    .warn => try ir.addLayoutWarning(page_id, child_id, .{ .content_overflow = .{
                        .required_width = measured.width,
                        .frame_width = node.frame.width,
                        .overflow_width = overflow_width,
                        .required_height = measured.height,
                        .frame_height = node.frame.height,
                        .overflow_height = overflow_height,
                    } }),
                    .@"error" => try ir.addLayoutError(page_id, child_id, .{ .content_overflow = .{
                        .required_width = measured.width,
                        .frame_width = node.frame.width,
                        .overflow_width = overflow_width,
                        .required_height = measured.height,
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

fn frameRequirement(ir: anytype, node: *const Node, measurement_cache: ?*metrics.MeasurementCache) !?FrameRequirement {
    if (!shouldCheckContentOverflow(ir, node)) return null;
    if (measurement_cache) |cache| {
        if (try metrics.frameConstrainedMeasurementCached(ir, node, cache)) |measured| {
            if (measured.width > 0 and measured.height > 0) {
                return .{
                    .width = measured.width,
                    .height = measured.height,
                };
            }
        }
    }
    return .{
        .width = if (measurement_cache) |cache|
            try metrics.intrinsicWidthCached(ir, node, cache)
        else
            metrics.intrinsicWidth(ir, node),
        .height = if (measurement_cache) |cache|
            try metrics.intrinsicHeightCached(ir, node, cache)
        else
            metrics.intrinsicHeight(ir, node),
    };
}

fn fixedAxesForNode(ir: anytype, node_id: NodeId) FixedAxes {
    return .{
        .horizontal = axisFrameFixedByUserConstraints(ir, node_id, .horizontal),
        .vertical = axisFrameFixedByUserConstraints(ir, node_id, .vertical),
    };
}

fn axisFrameFixedByUserConstraints(ir: anytype, node_id: NodeId, axis: Axis) bool {
    var has_start = false;
    var has_end = false;
    var has_center = false;

    for (ir.constraints.items) |constraint| {
        if (constraint.target_node != node_id) continue;
        if (graph.anchorAxis(constraint.target_anchor) != axis) continue;

        switch (graph.classifySelfConstraint(constraint, axis)) {
            .size => return true,
            .none => {},
            .tautology, .conflict => continue,
        }

        switch (constraint.target_anchor) {
            .left, .bottom => has_start = true,
            .right, .top => has_end = true,
            .center_x, .center_y => has_center = true,
        }
    }

    return (has_start and has_end) or
        (has_start and has_center) or
        (has_end and has_center);
}

fn pageVisualFrame(ir: anytype, node: *const Node, requirement: ?FrameRequirement) ?VisualFrame {
    const render = render_policy.resolve(ir, node);
    var visual: ?VisualFrame = if (hasFrameInk(render))
        frameToVisual(node.frame)
    else
        null;

    if (contentVisualFrame(ir, node, render, requirement)) |content| {
        visual = unionVisualFrames(visual, content);
    }

    return visual;
}

fn frameToVisual(frame: model.Frame) VisualFrame {
    return .{
        .x = frame.x,
        .y = frame.y,
        .width = frame.width,
        .height = frame.height,
    };
}

fn contentVisualFrame(ir: anytype, node: *const Node, render: render_policy.ResolvedRender, requirement: ?FrameRequirement) ?VisualFrame {
    const measured = requirement orelse return switch (render.kind) {
        .chrome_only => null,
        else => frameToVisual(node.frame),
    };
    const content_frame = metrics.contentFrame(ir, node);
    const content_width = @max(@as(f32, 1.0), measured.width - 2.0 * metrics.chromePadX(ir, node));
    const content_height = @max(@as(f32, 1.0), measured.height - 2.0 * metrics.chromePadY(ir, node));

    return switch (render.kind) {
        .vector_math => mathContentVisualFrame(content_frame, content_width, content_height, render.math),
        .vector_asset, .raster_asset, .text, .code => topAnchoredContentVisualFrame(content_frame, content_width, content_height),
        .shape, .chrome_only => null,
    };
}

fn topAnchoredContentVisualFrame(frame: model.Frame, width: f32, height: f32) VisualFrame {
    return .{
        .x = frame.x,
        .y = frame.y + frame.height - height,
        .width = width,
        .height = height,
    };
}

fn mathContentVisualFrame(frame: model.Frame, width: f32, height: f32, math: ?render_policy.MathPaint) VisualFrame {
    const horizontal_align = if (math) |paint| paint.horizontal_align else render_policy.HorizontalAlign.center;
    return .{
        .x = alignedX(frame.x, frame.width, width, horizontal_align),
        .y = frame.y + @max((frame.height - height) / 2.0, 0),
        .width = width,
        .height = height,
    };
}

fn alignedX(x: f32, width: f32, content_width: f32, horizontal_align: render_policy.HorizontalAlign) f32 {
    const slack = @max(width - content_width, 0);
    return switch (horizontal_align) {
        .left => x,
        .center => x + slack / 2.0,
        .right => x + slack,
    };
}

fn hasFrameInk(render: render_policy.ResolvedRender) bool {
    if (render.chrome.fill != null) return true;
    if (render.chrome.stroke != null and render.chrome.line_width > 0) return true;
    if (render.rule.stroke != null and render.rule.line_width > 0) return true;
    if (render.underline.color != null and render.underline.width > 0) return true;
    if (render.shape) |shape| {
        if (shape.stroke != null and shape.line_width > 0) return true;
    }
    return false;
}

fn unionVisualFrames(current: ?VisualFrame, incoming: VisualFrame) VisualFrame {
    const existing = current orelse return incoming;
    const left = @min(existing.x, incoming.x);
    const bottom = @min(existing.y, incoming.y);
    const right = @max(existing.x + existing.width, incoming.x + incoming.width);
    const top = @max(existing.y + existing.height, incoming.y + incoming.height);
    return .{
        .x = left,
        .y = bottom,
        .width = @max(right - left, 1),
        .height = @max(top - bottom, 1),
    };
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
