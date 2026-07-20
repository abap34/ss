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
};

pub const Bounds = struct {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
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

pub fn insert(
    allocator: std.mem.Allocator,
    source: []const u8,
    page_span: base.ByteSpan,
    first_constraint_start: ?usize,
    binding: []const u8,
    kind: Kind,
    bounds: Bounds,
    fill: Fill,
    stroke: Stroke,
) !?base.Result {
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
    try appendConstructor(allocator, &text, kind, bounds, fill, stroke);
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

fn appendConstructor(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    kind: Kind,
    bounds: Bounds,
    fill: Fill,
    stroke: Stroke,
) !void {
    const width = try relation.numericLiteral(allocator, bounds.width);
    defer allocator.free(width);
    const height = try relation.numericLiteral(allocator, bounds.height);
    defer allocator.free(height);
    switch (kind) {
        .rectangle => {
            try out.appendSlice(allocator, "rectangle!(");
            try out.appendSlice(allocator, width);
            try out.appendSlice(allocator, ", ");
            try out.appendSlice(allocator, height);
        },
        .circle => {
            try out.appendSlice(allocator, "circle!(");
            try out.appendSlice(allocator, width);
        },
        .arrow => {
            try out.appendSlice(allocator, "arrow_shape!(");
            try out.appendSlice(allocator, width);
            try out.appendSlice(allocator, ", ");
            try out.appendSlice(allocator, height);
        },
    }
    const fill_text = try fillExpression(allocator, fill);
    defer allocator.free(fill_text);
    const stroke_text = try strokeExpression(allocator, stroke);
    defer allocator.free(stroke_text);
    try out.appendSlice(allocator, ", VectorStyle { fill = ");
    try out.appendSlice(allocator, fill_text);
    try out.appendSlice(allocator, " stroke = ");
    try out.appendSlice(allocator, stroke_text);
    try out.appendSlice(allocator, " }");
    try out.append(allocator, ')');
}
