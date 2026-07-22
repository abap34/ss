const std = @import("std");

const base = @import("base.zig");
const relation = @import("../relation.zig");

pub const TextEdit = base.TextEdit;
pub const Result = base.Result;
pub const applyEdits = base.applyEdits;

pub const Kind = enum {
    rectangle,
    circle,
    arrow,
    speech_bubble,
    line,
};

pub const Bounds = struct {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
};

pub const Point = struct {
    x: f64,
    y: f64,
};

pub const Fill = struct {
    enabled: bool,
    color: []const u8,
    opacity: f64,
};

pub const StrokeStyle = enum {
    solid,
    dashed,
    dotted,
    dash_dot,
};

pub const Stroke = struct {
    enabled: bool,
    color: []const u8,
    width: f64,
    style: StrokeStyle,
};

pub const ClosedShape = struct {
    bounds: Bounds,
    fill: Fill,
    stroke: Stroke,
};

pub const LineShape = struct {
    bounds: Bounds,
    start: Point,
    end: Point,
    stroke: Stroke,
};

pub const LineGeometry = struct {
    bounds: Bounds,
    start: Point,
    end: Point,
};

pub const LineGeometryExpressions = struct {
    width: base.ByteSpan,
    height: base.ByteSpan,
    start_x: base.ByteSpan,
    start_y: base.ByteSpan,
    end_x: base.ByteSpan,
    end_y: base.ByteSpan,
};

pub const ClosedGeometryExpressions = struct {
    width: base.ByteSpan,
    height: base.ByteSpan,
};

pub const Shape = union(Kind) {
    rectangle: ClosedShape,
    circle: ClosedShape,
    arrow: ClosedShape,
    speech_bubble: ClosedShape,
    line: LineShape,
};

pub fn insert(
    allocator: std.mem.Allocator,
    source: []const u8,
    page_span: base.ByteSpan,
    first_constraint_start: ?usize,
    binding: []const u8,
    shape: Shape,
) !?base.Result {
    const bounds = shapeBounds(shape);
    const insertion = if (first_constraint_start) |start|
        if (start >= page_span.start and start <= page_span.end and start <= source.len)
            base.lineStartAt(source, start, page_span.start)
        else
            return null
    else
        base.pageEndLineStart(source, page_span) orelse return null;
    const indent = base.pageBodyIndent(source, page_span, insertion);

    var text = std.ArrayList(u8).empty;
    defer text.deinit(allocator);
    try text.appendSlice(allocator, indent);
    try text.appendSlice(allocator, "let ");
    try text.appendSlice(allocator, binding);
    try text.appendSlice(allocator, " = ");
    try appendConstructor(allocator, &text, shape);
    try text.append(allocator, '\n');

    try relation.appendNumeric(allocator, &text, true, indent, binding, "left", "page", "left", bounds.x);
    try text.append(allocator, '\n');
    try relation.appendNumeric(allocator, &text, true, indent, binding, "top", "page", "top", -bounds.y);
    try text.append(allocator, '\n');

    const edits = try allocator.alloc(base.TextEdit, 1);
    errdefer allocator.free(edits);
    edits[0] = .{
        .start = insertion,
        .end = insertion,
        .text = try text.toOwnedSlice(allocator),
    };
    return .{ .edits = edits };
}

pub fn fillExpression(allocator: std.mem.Allocator, fill: Fill) ![]u8 {
    if (!fill.enabled) return allocator.dupe(u8, "no_fill()");
    const opacity = try relation.numericLiteral(allocator, fill.opacity);
    defer allocator.free(opacity);
    return std.fmt.allocPrint(allocator, "solid_fill(c\"{s}\", {s})", .{ fill.color, opacity });
}

pub fn strokeExpression(allocator: std.mem.Allocator, stroke: Stroke) ![]u8 {
    if (!stroke.enabled) return allocator.dupe(u8, "no_stroke()");
    const width = try relation.numericLiteral(allocator, stroke.width);
    defer allocator.free(width);
    const constructor = switch (stroke.style) {
        .solid => "solid_stroke",
        .dashed => "dashed_stroke",
        .dotted => "dotted_stroke",
        .dash_dot => "dash_dot_stroke",
    };
    return std.fmt.allocPrint(allocator, "{s}(c\"{s}\", {s})", .{ constructor, stroke.color, width });
}

pub fn normalizeLine(start: Point, end: Point, page_width: f64, page_height: f64) ?LineGeometry {
    if (!validPoint(start, page_width, page_height) or !validPoint(end, page_width, page_height)) return null;
    if (start.x == end.x and start.y == end.y) return null;
    const horizontal = normalizeAxis(start.x, end.x, page_width) orelse return null;
    const vertical = normalizeAxis(start.y, end.y, page_height) orelse return null;
    return .{
        .bounds = .{
            .x = horizontal.origin,
            .y = vertical.origin,
            .width = horizontal.size,
            .height = vertical.size,
        },
        .start = .{ .x = horizontal.start, .y = vertical.start },
        .end = .{ .x = horizontal.end, .y = vertical.end },
    };
}

pub fn lineGeometryEdits(
    allocator: std.mem.Allocator,
    expressions: LineGeometryExpressions,
    geometry: LineGeometry,
) !base.Result {
    const spans = [_]base.ByteSpan{
        expressions.width,
        expressions.height,
        expressions.start_x,
        expressions.start_y,
        expressions.end_x,
        expressions.end_y,
    };
    const values = [_]f64{
        geometry.bounds.width,
        geometry.bounds.height,
        geometry.start.x,
        geometry.start.y,
        geometry.end.x,
        geometry.end.y,
    };
    const edits = try allocator.alloc(base.TextEdit, spans.len);
    var initialized: usize = 0;
    errdefer {
        for (edits[0..initialized]) |*edit| edit.deinit(allocator);
        allocator.free(edits);
    }
    for (spans, values, 0..) |span, value, index| {
        edits[index] = .{
            .start = span.start,
            .end = span.end,
            .text = try relation.numericLiteral(allocator, value),
        };
        initialized += 1;
    }
    return .{ .edits = edits };
}

pub fn closedGeometryEdits(
    allocator: std.mem.Allocator,
    expressions: ClosedGeometryExpressions,
    bounds: Bounds,
) !base.Result {
    const spans = [_]base.ByteSpan{ expressions.width, expressions.height };
    const values = [_]f64{ bounds.width, bounds.height };
    const edits = try allocator.alloc(base.TextEdit, spans.len);
    var initialized: usize = 0;
    errdefer {
        for (edits[0..initialized]) |*edit| edit.deinit(allocator);
        allocator.free(edits);
    }
    for (spans, values, 0..) |span, value, index| {
        edits[index] = .{
            .start = span.start,
            .end = span.end,
            .text = try relation.numericLiteral(allocator, value),
        };
        initialized += 1;
    }
    return .{ .edits = edits };
}

fn appendConstructor(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    shape: Shape,
) !void {
    switch (shape) {
        .rectangle => |value| try appendClosedConstructor(allocator, out, "rectangle!", value),
        .circle => |value| try appendClosedConstructor(allocator, out, "ellipse!", value),
        .arrow => |value| try appendClosedConstructor(allocator, out, "arrow_shape!", value),
        .speech_bubble => |value| try appendClosedConstructor(allocator, out, "speech_bubble!", value),
        .line => |value| try appendLineConstructor(allocator, out, value),
    }
}

fn appendClosedConstructor(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    constructor: []const u8,
    shape: ClosedShape,
) !void {
    const bounds = shape.bounds;
    const width = try relation.numericLiteral(allocator, bounds.width);
    defer allocator.free(width);
    const height = try relation.numericLiteral(allocator, bounds.height);
    defer allocator.free(height);
    try out.appendSlice(allocator, constructor);
    try out.append(allocator, '(');
    try out.appendSlice(allocator, width);
    try out.appendSlice(allocator, ", ");
    try out.appendSlice(allocator, height);
    const fill_text = try fillExpression(allocator, shape.fill);
    defer allocator.free(fill_text);
    const stroke_text = try strokeExpression(allocator, shape.stroke);
    defer allocator.free(stroke_text);
    try out.appendSlice(allocator, ", VectorStyle { fill = ");
    try out.appendSlice(allocator, fill_text);
    try out.appendSlice(allocator, " stroke = ");
    try out.appendSlice(allocator, stroke_text);
    try out.appendSlice(allocator, " }");
    try out.append(allocator, ')');
}

fn appendLineConstructor(allocator: std.mem.Allocator, out: *std.ArrayList(u8), shape: LineShape) !void {
    const width = try relation.numericLiteral(allocator, shape.bounds.width);
    defer allocator.free(width);
    const height = try relation.numericLiteral(allocator, shape.bounds.height);
    defer allocator.free(height);
    const start_x = try relation.numericLiteral(allocator, shape.start.x);
    defer allocator.free(start_x);
    const start_y = try relation.numericLiteral(allocator, shape.start.y);
    defer allocator.free(start_y);
    const end_x = try relation.numericLiteral(allocator, shape.end.x);
    defer allocator.free(end_x);
    const end_y = try relation.numericLiteral(allocator, shape.end.y);
    defer allocator.free(end_y);
    const stroke_text = try strokeExpression(allocator, shape.stroke);
    defer allocator.free(stroke_text);

    try out.appendSlice(allocator, "line!(");
    try out.appendSlice(allocator, width);
    try out.appendSlice(allocator, ", ");
    try out.appendSlice(allocator, height);
    try out.appendSlice(allocator, ", LineStyle { start_x = ");
    try out.appendSlice(allocator, start_x);
    try out.appendSlice(allocator, " start_y = ");
    try out.appendSlice(allocator, start_y);
    try out.appendSlice(allocator, " end_x = ");
    try out.appendSlice(allocator, end_x);
    try out.appendSlice(allocator, " end_y = ");
    try out.appendSlice(allocator, end_y);
    try out.appendSlice(allocator, " stroke = ");
    try out.appendSlice(allocator, stroke_text);
    try out.appendSlice(allocator, " })");
}

fn shapeBounds(shape: Shape) Bounds {
    return switch (shape) {
        inline else => |value| value.bounds,
    };
}

const NormalizedAxis = struct {
    origin: f64,
    size: f64,
    start: f64,
    end: f64,
};

fn validPoint(point: Point, page_width: f64, page_height: f64) bool {
    return std.math.isFinite(point.x) and std.math.isFinite(point.y) and
        std.math.isFinite(page_width) and std.math.isFinite(page_height) and
        point.x >= 0 and point.y >= 0 and point.x <= page_width and point.y <= page_height;
}

fn normalizeAxis(start: f64, end: f64, page_extent: f64) ?NormalizedAxis {
    const minimum_extent = 1.0;
    if (!std.math.isFinite(page_extent) or page_extent < minimum_extent) return null;
    const natural_size = @abs(end - start);
    const size = @max(natural_size, minimum_extent);
    const centered_origin = (start + end - size) / 2;
    const origin = std.math.clamp(centered_origin, 0, page_extent - size);
    return .{
        .origin = origin,
        .size = size,
        .start = (start - origin) / size,
        .end = (end - origin) / size,
    };
}
