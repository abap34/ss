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

pub fn pageEndLineStart(source: []const u8, page_span: ByteSpan) ?usize {
    if (page_span.start >= source.len) return null;
    var cursor = @min(page_span.end, source.len);
    while (cursor > page_span.start) {
        const line_end = cursor;
        const line_start = lineStartAt(source, line_end, page_span.start);
        const line = std.mem.trim(u8, source[line_start..line_end], " \t\r\n");
        if (std.mem.eql(u8, line, "end")) return line_start;
        if (line_start == page_span.start) break;
        cursor = line_start - 1;
    }
    return null;
}

pub fn pageBodyIndent(source: []const u8, page_span: ByteSpan, insertion: usize) []const u8 {
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

pub fn lineStartAt(source: []const u8, before: usize, lower_bound: usize) usize {
    var start = @min(before, source.len);
    while (start > lower_bound and source[start - 1] != '\n') start -= 1;
    return start;
}

fn leadingWhitespace(text: []const u8) usize {
    var index: usize = 0;
    while (index < text.len and (text[index] == ' ' or text[index] == '\t')) index += 1;
    return index;
}
