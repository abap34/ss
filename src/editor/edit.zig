const std = @import("std");
const utils = @import("utils");

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

pub const RelationUpdate = struct {
    span: ByteSpan,
    target: []const u8,
    target_anchor: []const u8,
    source: []const u8,
    source_anchor: []const u8,
    offset: f64,
};

pub const ParsedRelation = struct {
    indent: []const u8,
    target: []const u8,
    target_anchor: []const u8,
    source: []const u8,
    source_anchor: []const u8,
};

pub fn absolutePosition(
    allocator: std.mem.Allocator,
    source: []const u8,
    page_span: ByteSpan,
    binding: []const u8,
    left: f64,
    top: f64,
    replaced_constraints: []const ByteSpan,
) !?Result {
    const insertion = pageEndLineStart(source, page_span) orelse return null;
    const indent = pageBodyIndent(source, page_span, insertion);

    var edits = std.ArrayList(TextEdit).empty;
    errdefer deinitEdits(allocator, &edits);
    var normalized = std.ArrayList(ByteSpan).empty;
    defer normalized.deinit(allocator);
    for (replaced_constraints) |span| {
        const line = constraintLineSpan(source, span) orelse continue;
        if (containsSpan(normalized.items, line)) continue;
        try normalized.append(allocator, line);
    }
    std.mem.sort(ByteSpan, normalized.items, {}, spanLessThan);
    for (normalized.items) |span| {
        try edits.append(allocator, .{
            .start = span.start,
            .end = span.end,
            .text = try allocator.dupe(u8, ""),
        });
    }

    var text = std.ArrayList(u8).empty;
    errdefer text.deinit(allocator);
    try appendConstraint(allocator, &text, indent, binding, "left", "page", "left", left);
    try appendConstraint(allocator, &text, indent, binding, "top", "page", "top", -top);
    try edits.append(allocator, .{
        .start = insertion,
        .end = insertion,
        .text = try text.toOwnedSlice(allocator),
    });
    return .{ .edits = try edits.toOwnedSlice(allocator) };
}

pub fn preserveRelations(
    allocator: std.mem.Allocator,
    source: []const u8,
    updates: []const RelationUpdate,
) !Result {
    var edits = std.ArrayList(TextEdit).empty;
    errdefer deinitEdits(allocator, &edits);
    for (updates) |update| {
        const line_span = constraintLineSpan(source, update.span) orelse return error.InvalidConstraintOrigin;
        const line = source[line_span.start..trimLineEnding(source, line_span.end)];
        const parsed = parseRelation(line) orelse return error.InvalidConstraintOrigin;
        var text = std.ArrayList(u8).empty;
        errdefer text.deinit(allocator);
        try appendConstraintWithoutIndent(
            allocator,
            &text,
            parsed.indent,
            update.target,
            update.target_anchor,
            update.source,
            update.source_anchor,
            update.offset,
        );
        if (line_span.end > line_span.start and source[line_span.end - 1] == '\n') try text.append(allocator, '\n');
        try edits.append(allocator, .{
            .start = line_span.start,
            .end = line_span.end,
            .text = try text.toOwnedSlice(allocator),
        });
    }
    return .{ .edits = try edits.toOwnedSlice(allocator) };
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

pub fn parseRelation(line: []const u8) ?ParsedRelation {
    const indent_end = leadingWhitespace(line);
    const body = std.mem.trim(u8, line[indent_end..], " \t\r\n");
    if (body.len == 0 or body[0] != '~') return null;
    const equality = std.mem.indexOf(u8, body[1..], "==") orelse return null;
    const equality_start = equality + 1;
    const target = parseEndpoint(std.mem.trim(u8, body[1..equality_start], " \t")) orelse return null;
    const right = std.mem.trim(u8, body[equality_start + 2 ..], " \t");
    const endpoint_end = endpointPrefixEnd(right) orelse return null;
    const source_endpoint = parseEndpoint(right[0..endpoint_end]) orelse return null;
    return .{
        .indent = line[0..indent_end],
        .target = target.name,
        .target_anchor = target.anchor,
        .source = source_endpoint.name,
        .source_anchor = source_endpoint.anchor,
    };
}

const Endpoint = struct {
    name: []const u8,
    anchor: []const u8,
};

fn parseEndpoint(text: []const u8) ?Endpoint {
    const dot = std.mem.lastIndexOfScalar(u8, text, '.') orelse return null;
    if (dot == 0 or dot + 1 >= text.len) return null;
    const name = std.mem.trim(u8, text[0..dot], " \t");
    const anchor = std.mem.trim(u8, text[dot + 1 ..], " \t");
    if (name.len == 0 or !validAnchor(anchor)) return null;
    return .{ .name = name, .anchor = anchor };
}

fn endpointPrefixEnd(text: []const u8) ?usize {
    var index: usize = 0;
    while (index < text.len and !std.ascii.isWhitespace(text[index]) and text[index] != '+' and text[index] != '-') index += 1;
    if (index == 0) return null;
    return index;
}

fn validAnchor(anchor: []const u8) bool {
    const anchors = [_][]const u8{ "left", "right", "top", "bottom", "center_x", "center_y" };
    for (anchors) |candidate| if (std.mem.eql(u8, anchor, candidate)) return true;
    return false;
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
    indent: []const u8,
    target: []const u8,
    target_anchor: []const u8,
    source: []const u8,
    source_anchor: []const u8,
    offset: f64,
) !void {
    try appendConstraintWithoutIndent(allocator, out, indent, target, target_anchor, source, source_anchor, offset);
    try out.append(allocator, '\n');
}

fn appendConstraintWithoutIndent(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    indent: []const u8,
    target: []const u8,
    target_anchor: []const u8,
    source: []const u8,
    source_anchor: []const u8,
    offset: f64,
) !void {
    const number = try formatNumber(allocator, @abs(offset));
    defer allocator.free(number);
    try out.appendSlice(allocator, indent);
    try out.appendSlice(allocator, "~ ");
    try out.appendSlice(allocator, target);
    try out.append(allocator, '.');
    try out.appendSlice(allocator, target_anchor);
    try out.appendSlice(allocator, " == ");
    try out.appendSlice(allocator, source);
    try out.append(allocator, '.');
    try out.appendSlice(allocator, source_anchor);
    if (@abs(offset) > 0.0005) {
        try out.appendSlice(allocator, if (offset < 0) " - " else " + ");
        try out.appendSlice(allocator, number);
    }
}

fn formatNumber(allocator: std.mem.Allocator, value: f64) ![]u8 {
    const text = try std.fmt.allocPrint(allocator, "{d:.2}", .{value});
    var end = text.len;
    while (end > 0 and text[end - 1] == '0') end -= 1;
    if (end > 0 and text[end - 1] == '.') end -= 1;
    if (end == text.len) return text;
    const result = try allocator.dupe(u8, text[0..end]);
    allocator.free(text);
    return result;
}

fn leadingWhitespace(text: []const u8) usize {
    var index: usize = 0;
    while (index < text.len and (text[index] == ' ' or text[index] == '\t')) index += 1;
    return index;
}

fn spanLessThan(_: void, left: ByteSpan, right: ByteSpan) bool {
    return left.start < right.start;
}

fn containsSpan(spans: []const ByteSpan, needle: ByteSpan) bool {
    for (spans) |span| if (span.start == needle.start and span.end == needle.end) return true;
    return false;
}

fn deinitEdits(allocator: std.mem.Allocator, edits: *std.ArrayList(TextEdit)) void {
    for (edits.items) |*edit| edit.deinit(allocator);
    edits.deinit(allocator);
}
