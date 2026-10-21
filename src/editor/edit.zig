const std = @import("std");
const relation = @import("relation.zig");
const base = @import("edit/base.zig");

pub const ByteSpan = base.ByteSpan;
pub const RelationSource = relation.Source;
pub const TextEdit = base.TextEdit;
pub const Result = base.Result;
pub const applyEdits = base.applyEdits;
pub const pageEndLineStart = base.pageEndLineStart;
pub const pageBodyIndent = base.pageBodyIndent;
pub const minimum_component_width: f64 = 4;
pub const generated = @import("edit/generated.zig");
pub const shape = @import("edit/shape.zig");
pub const icon = @import("edit/icon.zig");
pub const component = @import("edit/component.zig");

pub const BindingIntroduction = struct {
    statement: ByteSpan,
    line_text: ?struct { callee: ByteSpan, text: ByteSpan } = null,
};

pub const ExistingUpdate = struct {
    source: relation.Source,
    horizontal: bool,
};

pub const ExistingWidthUpdate = struct {
    value: ByteSpan,
    direct_dimension: bool,
};

pub fn absolutePosition(
    allocator: std.mem.Allocator,
    source: []const u8,
    page_span: ByteSpan,
    binding: []const u8,
    left: f64,
    top: f64,
    existing_updates: []const ExistingUpdate,
    binding_introduction: ?BindingIntroduction,
) !?Result {
    const insertion = pageEndLineStart(source, page_span) orelse return null;
    const indent = pageBodyIndent(source, page_span, insertion);

    var edits = std.ArrayList(TextEdit).empty;
    errdefer deinitEdits(allocator, &edits);
    var horizontal_updated = false;
    var vertical_updated = false;
    for (existing_updates) |update| {
        const horizontal = update.horizontal;
        const target_text = try std.fmt.allocPrint(
            allocator,
            "{s}.{s}",
            .{ binding, if (horizontal) "left" else "top" },
        );
        try edits.append(allocator, .{
            .start = update.source.target.start,
            .end = update.source.target.end,
            .text = target_text,
        });
        try edits.append(allocator, .{
            .start = update.source.source.start,
            .end = update.source.source.end,
            .text = try allocator.dupe(u8, if (horizontal) "page.left" else "page.top"),
        });
        const offset = if (horizontal) left else -top;
        const offset_span = update.source.offset;
        try edits.append(allocator, .{
            .start = if (offset_span) |span| span.start else update.source.source.end,
            .end = if (offset_span) |span| span.end else update.source.source.end,
            .text = try relation.numericOffset(allocator, offset, offset_span == null),
        });
        if (horizontal) horizontal_updated = true else vertical_updated = true;
    }

    if (binding_introduction) |introduction| {
        const binding_name = binding[0 .. std.mem.indexOfScalar(u8, binding, '.') orelse binding.len];
        try appendBindingIntroduction(allocator, &edits, source, binding_name, introduction);
    }

    var text = std.ArrayList(u8).empty;
    defer text.deinit(allocator);
    if (!horizontal_updated) try appendConstraint(allocator, &text, true, indent, binding, "left", "page", "left", left);
    if (!vertical_updated) try appendConstraint(allocator, &text, true, indent, binding, "top", "page", "top", -top);
    if (text.items.len != 0) {
        try edits.append(allocator, .{
            .start = insertion,
            .end = insertion,
            .text = try text.toOwnedSlice(allocator),
        });
    }
    return .{ .edits = try edits.toOwnedSlice(allocator) };
}

pub fn componentWidth(
    allocator: std.mem.Allocator,
    source: []const u8,
    page_span: ByteSpan,
    binding: []const u8,
    width: f64,
    existing_update: ?ExistingWidthUpdate,
    binding_introduction: ?BindingIntroduction,
) !?Result {
    var edits = std.ArrayList(TextEdit).empty;
    errdefer deinitEdits(allocator, &edits);

    if (binding_introduction) |introduction| {
        const binding_name = binding[0 .. std.mem.indexOfScalar(u8, binding, '.') orelse binding.len];
        try appendBindingIntroduction(allocator, &edits, source, binding_name, introduction);
    }

    if (existing_update) |update| {
        if (update.value.start > update.value.end or update.value.end > source.len) {
            return error.InvalidConstraintOrigin;
        }
        try edits.append(allocator, .{
            .start = update.value.start,
            .end = update.value.end,
            .text = if (update.direct_dimension)
                try relation.numericLiteral(allocator, width)
            else
                try relation.numericOffset(allocator, width, false),
        });
    } else {
        const insertion = pageEndLineStart(source, page_span) orelse return null;
        const indent = pageBodyIndent(source, page_span, insertion);
        const literal = try relation.numericLiteral(allocator, width);
        defer allocator.free(literal);
        try edits.append(allocator, .{
            .start = insertion,
            .end = insertion,
            .text = try std.fmt.allocPrint(
                allocator,
                "{s}~!~ {s}.width == {s}\n",
                .{ indent, binding, literal },
            ),
        });
    }

    return .{ .edits = try edits.toOwnedSlice(allocator) };
}

pub fn relativePosition(
    allocator: std.mem.Allocator,
    source: []const u8,
    page_span: ByteSpan,
    adjustments: []const relation.Adjustment,
) !?Result {
    var edits = std.ArrayList(TextEdit).empty;
    errdefer deinitEdits(allocator, &edits);
    const Addition = struct { offset: usize, text: std.ArrayList(u8) = .empty };
    var additions = std.ArrayList(Addition).empty;
    defer {
        for (additions.items) |*addition| addition.text.deinit(allocator);
        additions.deinit(allocator);
    }

    for (adjustments) |adjustment| {
        switch (adjustment.action) {
            .replace => |origin| {
                const offset_source = if (origin.offset) |span| try sourceSlice(source, span) else null;
                const text = try relation.adjustedOffset(
                    allocator,
                    offset_source,
                    adjustment.evaluated_offset,
                    adjustment.delta,
                    origin.offset == null,
                );
                errdefer allocator.free(text);
                try edits.append(allocator, .{
                    .start = if (origin.offset) |span| span.start else origin.source.end,
                    .end = if (origin.offset) |span| span.end else origin.source.end,
                    .text = text,
                });
            },
            .append_update => |origin| {
                const insertion = if (adjustment.insertion_before) |before| blk: {
                    if (before < page_span.start or before >= page_span.end or before >= source.len) return error.InvalidConstraintOrigin;
                    const start = lineStartBefore(source, before, page_span.start);
                    if (std.mem.trim(u8, source[start..before], " \t\r").len != 0) return error.InvalidConstraintOrigin;
                    break :blk start;
                } else pageEndLineStart(source, page_span) orelse return null;
                const insertion_indent = pageBodyIndent(source, page_span, insertion);
                const addition_index = for (additions.items, 0..) |addition, index| {
                    if (addition.offset == insertion) break index;
                } else blk: {
                    try additions.append(allocator, .{ .offset = insertion });
                    break :blk additions.items.len - 1;
                };
                const text = &additions.items[addition_index].text;
                const offset_source = if (origin) |source_edit|
                    if (source_edit.offset) |span| try sourceSlice(source, span) else null
                else
                    null;
                try relation.appendAdjusted(
                    allocator,
                    text,
                    true,
                    insertion_indent,
                    adjustment,
                    offset_source,
                );
                try text.append(allocator, '\n');
            },
        }
    }
    try edits.ensureUnusedCapacity(allocator, additions.items.len);
    for (additions.items) |*addition| {
        edits.appendAssumeCapacity(.{
            .start = addition.offset,
            .end = addition.offset,
            .text = try addition.text.toOwnedSlice(allocator),
        });
    }
    return .{ .edits = try edits.toOwnedSlice(allocator) };
}

fn sourceSlice(source: []const u8, span: ByteSpan) ![]const u8 {
    if (span.end < span.start or span.end > source.len) return error.InvalidConstraintOrigin;
    return source[span.start..span.end];
}

fn lineStartBefore(source: []const u8, before: usize, lower_bound: usize) usize {
    var start = @min(before, source.len);
    while (start > lower_bound and source[start - 1] != '\n') start -= 1;
    return start;
}

fn trimLineEnding(source: []const u8, end: usize) usize {
    var cursor = @min(end, source.len);
    while (cursor > 0 and (source[cursor - 1] == '\n' or source[cursor - 1] == '\r')) cursor -= 1;
    return cursor;
}

fn appendConstraint(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    update: bool,
    indent: []const u8,
    target: []const u8,
    target_anchor: []const u8,
    source: []const u8,
    source_anchor: []const u8,
    offset: f64,
) !void {
    try relation.appendNumeric(allocator, out, update, indent, target, target_anchor, source, source_anchor, offset);
    try out.append(allocator, '\n');
}

fn appendBindingIntroduction(
    allocator: std.mem.Allocator,
    edits: *std.ArrayList(TextEdit),
    source: []const u8,
    binding: []const u8,
    introduction: BindingIntroduction,
) !void {
    const statement = introduction.statement;
    if (statement.start >= statement.end or statement.end > source.len) return error.InvalidBindingStatement;
    if (introduction.line_text) |line| {
        if (line.callee.start != statement.start or line.callee.end <= line.callee.start or line.callee.end > line.text.start or
            line.text.start > line.text.end or line.text.end > statement.end)
            return error.InvalidBindingStatement;
        const line_start = lineStartBefore(source, statement.start, 0);
        const indent = source[line_start..statement.start];
        try edits.append(allocator, .{
            .start = statement.start,
            .end = trimLineEnding(source, statement.end),
            .text = try std.fmt.allocPrint(
                allocator,
                "let {s} = {s} <<\n{s}{s}\n{s}>>",
                .{ binding, source[line.callee.start..line.callee.end], indent, source[line.text.start..line.text.end], indent },
            ),
        });
    } else {
        try edits.append(allocator, .{
            .start = statement.start,
            .end = statement.start,
            .text = try std.fmt.allocPrint(allocator, "let {s} = ", .{binding}),
        });
    }
}

fn deinitEdits(allocator: std.mem.Allocator, edits: *std.ArrayList(TextEdit)) void {
    for (edits.items) |*edit| edit.deinit(allocator);
    edits.deinit(allocator);
}
