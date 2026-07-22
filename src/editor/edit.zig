const std = @import("std");
const utils = @import("utils");
const relation = @import("relation.zig");
const base = @import("edit/base.zig");

pub const ByteSpan = base.ByteSpan;
pub const RelationSource = relation.Source;
pub const TextEdit = base.TextEdit;
pub const Result = base.Result;
pub const applyEdits = base.applyEdits;
pub const pageEndLineStart = base.pageEndLineStart;
pub const pageBodyIndent = base.pageBodyIndent;
pub const shape = @import("edit/shape.zig");
pub const icon = @import("edit/icon.zig");
pub const component = @import("edit/component.zig");

pub const BindingIntroduction = struct {
    statement: ByteSpan,
};

pub const ExistingUpdate = struct {
    source: relation.Source,
    horizontal: bool,
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
        try appendBindingIntroduction(allocator, &edits, source, binding_name, introduction.statement);
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

pub fn relativePosition(
    allocator: std.mem.Allocator,
    source: []const u8,
    page_span: ByteSpan,
    adjustments: []const relation.Adjustment,
) !?Result {
    var edits = std.ArrayList(TextEdit).empty;
    errdefer deinitEdits(allocator, &edits);
    var additions = std.ArrayList(u8).empty;
    defer additions.deinit(allocator);
    var insertion: ?usize = null;
    var insertion_indent: []const u8 = "";

    for (adjustments) |adjustment| {
        switch (adjustment.action) {
            .replace => |origin| {
                const offset_source = if (origin.offset) |span| try sourceSlice(source, span) else null;
                try edits.append(allocator, .{
                    .start = if (origin.offset) |span| span.start else origin.source.end,
                    .end = if (origin.offset) |span| span.end else origin.source.end,
                    .text = try relation.adjustedOffset(
                        allocator,
                        offset_source,
                        adjustment.evaluated_offset,
                        adjustment.delta,
                        origin.offset == null,
                    ),
                });
            },
            .append_update => |origin| {
                if (insertion == null) {
                    insertion = pageEndLineStart(source, page_span) orelse return null;
                    insertion_indent = pageBodyIndent(source, page_span, insertion.?);
                }
                const offset_source = if (origin) |source_edit|
                    if (source_edit.offset) |span| try sourceSlice(source, span) else null
                else
                    null;
                try relation.appendAdjusted(
                    allocator,
                    &additions,
                    true,
                    insertion_indent,
                    adjustment,
                    offset_source,
                );
                try additions.append(allocator, '\n');
            },
        }
    }
    if (insertion) |offset| {
        try edits.append(allocator, .{
            .start = offset,
            .end = offset,
            .text = try additions.toOwnedSlice(allocator),
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
    statement: ByteSpan,
) !void {
    if (statement.start >= statement.end or statement.end > source.len) return error.InvalidBindingStatement;
    const statement_end = trimLineEnding(source, statement.end);
    if (statement_end <= statement.start) return error.InvalidBindingStatement;
    const statement_text = source[statement.start..statement_end];
    const callee_end = std.mem.indexOfAny(u8, statement_text, " \t\r\n(") orelse statement_text.len;
    if (callee_end == 0) return error.InvalidBindingStatement;
    const raw_rest = statement_text[callee_end..];
    const rest = raw_rest[leadingWhitespace(raw_rest)..];
    if (rest.len == 0 or rest[0] == '(' or rest[0] == '"' or std.mem.startsWith(u8, rest, "<<")) {
        try edits.append(allocator, .{
            .start = statement.start,
            .end = statement.start,
            .text = try std.fmt.allocPrint(allocator, "let {s} = ", .{binding}),
        });
        return;
    }

    const line_start = lineStartBefore(source, statement.start, 0);
    const indent = source[line_start..statement.start];
    const raw_text = std.mem.trim(u8, statement_text[callee_end..], " \t\r\n");
    const replacement = try std.fmt.allocPrint(
        allocator,
        "let {s} = {s} <<\n{s}{s}\n{s}>>",
        .{ binding, statement_text[0..callee_end], indent, raw_text, indent },
    );
    try edits.append(allocator, .{
        .start = statement.start,
        .end = statement_end,
        .text = replacement,
    });
}

fn leadingWhitespace(text: []const u8) usize {
    var index: usize = 0;
    while (index < text.len and (text[index] == ' ' or text[index] == '\t')) index += 1;
    return index;
}

fn deinitEdits(allocator: std.mem.Allocator, edits: *std.ArrayList(TextEdit)) void {
    for (edits.items) |*edit| edit.deinit(allocator);
    edits.deinit(allocator);
}
