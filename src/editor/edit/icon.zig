const std = @import("std");

const base = @import("base.zig");
const relation = @import("../relation.zig");

pub const Bounds = struct {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
};

pub fn insert(
    allocator: std.mem.Allocator,
    source: []const u8,
    page_span: base.ByteSpan,
    first_constraint_start: ?usize,
    binding: []const u8,
    icon_source: []const u8,
    bounds: Bounds,
    color: []const u8,
) !?base.Result {
    const insertion = if (first_constraint_start) |start|
        if (start >= page_span.start and start <= page_span.end and start <= source.len)
            base.lineStartAt(source, start, page_span.start)
        else
            return null
    else
        base.pageEndLineStart(source, page_span) orelse return null;
    const indent = base.pageBodyIndent(source, page_span, insertion);
    const width = try relation.numericLiteral(allocator, bounds.width);
    defer allocator.free(width);
    const height = try relation.numericLiteral(allocator, bounds.height);
    defer allocator.free(height);

    var text = std.ArrayList(u8).empty;
    defer text.deinit(allocator);
    try text.appendSlice(allocator, indent);
    try text.appendSlice(allocator, "let ");
    try text.appendSlice(allocator, binding);
    try text.appendSlice(allocator, " = icon!(\"");
    try text.appendSlice(allocator, icon_source);
    try text.appendSlice(allocator, "\", ");
    try text.appendSlice(allocator, width);
    try text.appendSlice(allocator, ", ");
    try text.appendSlice(allocator, height);
    try text.appendSlice(allocator, ", c\"");
    try text.appendSlice(allocator, color);
    try text.appendSlice(allocator, "\")\n");
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
