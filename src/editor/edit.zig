const std = @import("std");
const utils = @import("utils");
const relation = @import("relation.zig");

pub const ByteSpan = utils.source.ByteSpan;

pub const TextEdit = struct {
    start: usize,
    end: usize,
    text: []u8,

    pub fn deinit(self: *TextEdit, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        self.* = .{ .start = 0, .end = 0, .text = &.{} };
    }
};

pub const Result = struct {
    edits: []TextEdit,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        for (self.edits) |*edit| edit.deinit(allocator);
        allocator.free(self.edits);
        self.* = .{ .edits = &.{} };
    }
};

pub const BindingIntroduction = struct {
    statement: ByteSpan,
};

pub fn absolutePosition(
    allocator: std.mem.Allocator,
    source: []const u8,
    page_span: ByteSpan,
    binding: []const u8,
    left: f64,
    top: f64,
    existing_updates: []const ByteSpan,
    binding_introduction: ?BindingIntroduction,
) !?Result {
    const insertion = pageEndLineStart(source, page_span) orelse return null;
    const indent = pageBodyIndent(source, page_span, insertion);

    var edits = std.ArrayList(TextEdit).empty;
    errdefer deinitEdits(allocator, &edits);
    var horizontal_updated = false;
    var vertical_updated = false;
    var seen_updates = std.ArrayList(ByteSpan).empty;
    defer seen_updates.deinit(allocator);
    for (existing_updates) |origin| {
        const span = constraintLineSpan(source, origin) orelse continue;
        if (containsSpan(seen_updates.items, span)) continue;
        try seen_updates.append(allocator, span);
        const line = source[span.start..trimLineEnding(source, span.end)];
        const parsed = relation.parse(line) orelse continue;
        if (!parsed.update or !relation.sameObjectPath(parsed.target, binding)) continue;
        const horizontal = relation.isHorizontal(parsed.target_anchor) orelse continue;
        var text = std.ArrayList(u8).empty;
        errdefer text.deinit(allocator);
        try relation.appendNumeric(
            allocator,
            &text,
            true,
            parsed.indent,
            binding,
            if (horizontal) "left" else "top",
            "page",
            if (horizontal) "left" else "top",
            if (horizontal) left else -top,
        );
        try relation.appendSuffix(allocator, &text, parsed);
        if (span.end > span.start and source[span.end - 1] == '\n') try text.append(allocator, '\n');
        try edits.append(allocator, .{
            .start = span.start,
            .end = span.end,
            .text = try text.toOwnedSlice(allocator),
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
                const located = try locateRelation(source, origin, adjustment);
                var text = std.ArrayList(u8).empty;
                errdefer text.deinit(allocator);
                try relation.appendAdjusted(allocator, &text, located.parsed.update, located.parsed.indent, adjustment, located.parsed.offset_source);
                try relation.appendSuffix(allocator, &text, located.parsed);
                if (located.span.end > located.span.start and source[located.span.end - 1] == '\n') try text.append(allocator, '\n');
                try edits.append(allocator, .{
                    .start = located.span.start,
                    .end = located.span.end,
                    .text = try text.toOwnedSlice(allocator),
                });
            },
            .append_update => |origin| {
                if (insertion == null) {
                    insertion = pageEndLineStart(source, page_span) orelse return null;
                    insertion_indent = pageBodyIndent(source, page_span, insertion.?);
                }
                const offset_source = if (origin) |span|
                    (try locateRelation(source, span, adjustment)).parsed.offset_source
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

const LocatedRelation = struct {
    span: ByteSpan,
    parsed: relation.Parsed,
};

fn locateRelation(source: []const u8, origin: ByteSpan, adjustment: relation.Adjustment) !LocatedRelation {
    const span = constraintLineSpan(source, origin) orelse return error.InvalidConstraintOrigin;
    const parsed = relation.parse(source[span.start..trimLineEnding(source, span.end)]) orelse return error.InvalidConstraintOrigin;
    if (!relation.matches(parsed, adjustment)) return error.InvalidConstraintOrigin;
    return .{ .span = span, .parsed = parsed };
}

pub fn applyEdits(allocator: std.mem.Allocator, source: []const u8, edits: []const TextEdit) ![]u8 {
    const OrderedEdit = struct { start: usize, end: usize, text: []const u8 };
    const ordered = try allocator.alloc(OrderedEdit, edits.len);
    defer allocator.free(ordered);
    for (edits, 0..) |edit, index| {
        if (edit.end < edit.start or edit.end > source.len) return error.InvalidTextEdit;
        ordered[index] = .{ .start = edit.start, .end = edit.end, .text = edit.text };
    }
    std.mem.sort(OrderedEdit, ordered, {}, struct {
        fn lessThan(_: void, left: OrderedEdit, right: OrderedEdit) bool {
            return left.start < right.start;
        }
    }.lessThan);
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var cursor: usize = 0;
    for (ordered) |edit| {
        if (edit.start < cursor) return error.OverlappingTextEdits;
        try out.appendSlice(allocator, source[cursor..edit.start]);
        try out.appendSlice(allocator, edit.text);
        cursor = edit.end;
    }
    try out.appendSlice(allocator, source[cursor..]);
    return try out.toOwnedSlice(allocator);
}

fn pageEndLineStart(source: []const u8, page_span: ByteSpan) ?usize {
    if (page_span.start >= source.len) return null;
    var cursor = @min(page_span.end, source.len);
    while (cursor > page_span.start) {
        const line_end = cursor;
        const line_start = lineStartBefore(source, line_end, page_span.start);
        const line = std.mem.trim(u8, source[line_start..line_end], " \t\r\n");
        if (std.mem.eql(u8, line, "end")) return line_start;
        if (line_start == page_span.start) break;
        cursor = line_start - 1;
    }
    return null;
}

fn pageBodyIndent(source: []const u8, page_span: ByteSpan, insertion: usize) []const u8 {
    const first_newline = std.mem.indexOfScalarPos(u8, source, page_span.start, '\n') orelse return "  ";
    var cursor = first_newline + 1;
    while (cursor < insertion) {
        const end = std.mem.indexOfScalarPos(u8, source, cursor, '\n') orelse insertion;
        const line = source[cursor..@min(end, insertion)];
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len != 0 and !std.mem.startsWith(u8, trimmed, "#")) return line[0..leadingWhitespace(line)];
        cursor = @min(end + 1, insertion);
    }
    return "  ";
}

fn constraintLineSpan(source: []const u8, span: ByteSpan) ?ByteSpan {
    if (span.start >= source.len or span.end < span.start) return null;
    const start = lineStartBefore(source, span.start, 0);
    var end = @min(span.end, source.len);
    while (end < source.len and source[end] != '\n') end += 1;
    if (end < source.len) end += 1;
    const line = std.mem.trim(u8, source[start..end], " \t\r\n");
    if (line.len == 0 or line[0] != '~') return null;
    return .{ .start = start, .end = end };
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

fn containsSpan(spans: []const ByteSpan, needle: ByteSpan) bool {
    for (spans) |span| if (span.start == needle.start and span.end == needle.end) return true;
    return false;
}

fn deinitEdits(allocator: std.mem.Allocator, edits: *std.ArrayList(TextEdit)) void {
    for (edits.items) |*edit| edit.deinit(allocator);
    edits.deinit(allocator);
}
