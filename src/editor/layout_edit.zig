const std = @import("std");

pub const TextEdit = struct {
    start_line: usize,
    start_character: usize,
    end_line: usize,
    end_character: usize,
    text: []u8,

    pub fn deinit(self: *TextEdit, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
    }
};

pub const Result = struct {
    edits: []TextEdit,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        for (self.edits) |*edit| edit.deinit(allocator);
        allocator.free(self.edits);
    }
};

const Line = struct {
    index: usize,
    start: usize,
    end: usize,
    text: []const u8,
};

const PageBlock = struct {
    end_line: Line,
    indent: []const u8,
};

pub const AnchorRelation = struct {
    target_anchor: []const u8,
    source_name: []const u8,
    source_anchor: []const u8,
    offset: f64,
};

pub fn absoluteTopLeft(
    allocator: std.mem.Allocator,
    source: []const u8,
    page_name: []const u8,
    object_name: []const u8,
    left: f64,
    top_from_page_top: f64,
) !?Result {
    return absoluteTopLeftWithPageIndex(allocator, source, page_name, null, object_name, left, top_from_page_top);
}

pub fn absoluteTopLeftWithPageIndex(
    allocator: std.mem.Allocator,
    source: []const u8,
    page_name: []const u8,
    page_index: ?i64,
    object_name: []const u8,
    left: f64,
    top_from_page_top: f64,
) !?Result {
    const page = findPageBlock(source, page_name, page_index) orelse return null;
    var text = std.ArrayList(u8).empty;
    errdefer text.deinit(allocator);
    try appendDiscardLine(allocator, &text, page.indent, object_name, "horizontal");
    try appendConstraintLine(allocator, &text, page.indent, object_name, "left", "page", "left", left);
    try appendDiscardLine(allocator, &text, page.indent, object_name, "vertical");
    try appendConstraintLine(allocator, &text, page.indent, object_name, "top", "page", "top", -top_from_page_top);

    var edits = std.ArrayList(TextEdit).empty;
    errdefer {
        for (edits.items) |*edit| edit.deinit(allocator);
        edits.deinit(allocator);
    }
    try edits.append(allocator, .{
        .start_line = page.end_line.index,
        .start_character = 0,
        .end_line = page.end_line.index,
        .end_character = 0,
        .text = try text.toOwnedSlice(allocator),
    });

    return .{
        .edits = try edits.toOwnedSlice(allocator),
    };
}

pub fn anchorRelationsWithPageIndex(
    allocator: std.mem.Allocator,
    source: []const u8,
    page_name: []const u8,
    page_index: ?i64,
    object_name: []const u8,
    relations: []const AnchorRelation,
) !?Result {
    const page = findPageBlock(source, page_name, page_index) orelse return null;

    var edits = std.ArrayList(TextEdit).empty;
    errdefer {
        for (edits.items) |*edit| edit.deinit(allocator);
        edits.deinit(allocator);
    }

    var text = std.ArrayList(u8).empty;
    errdefer text.deinit(allocator);
    for (relations) |relation| {
        try appendDiscardLine(allocator, &text, page.indent, object_name, relation.target_anchor);
        try appendConstraintLine(
            allocator,
            &text,
            page.indent,
            object_name,
            relation.target_anchor,
            relation.source_name,
            relation.source_anchor,
            relation.offset,
        );
    }
    try edits.append(allocator, .{
        .start_line = page.end_line.index,
        .start_character = 0,
        .end_line = page.end_line.index,
        .end_character = 0,
        .text = try text.toOwnedSlice(allocator),
    });

    return .{
        .edits = try edits.toOwnedSlice(allocator),
    };
}

pub fn applyEdits(allocator: std.mem.Allocator, source: []const u8, edits: []const TextEdit) ![]u8 {
    var ranges = try allocator.alloc(struct { start: usize, end: usize, text: []const u8 }, edits.len);
    defer allocator.free(ranges);
    for (edits, 0..) |edit, index| {
        ranges[index] = .{
            .start = offsetFromLineCharacter(source, edit.start_line, edit.start_character),
            .end = offsetFromLineCharacter(source, edit.end_line, edit.end_character),
            .text = edit.text,
        };
    }
    std.mem.sort(@TypeOf(ranges[0]), ranges, {}, struct {
        fn lessThan(_: void, a: @TypeOf(ranges[0]), b: @TypeOf(ranges[0])) bool {
            return a.start < b.start;
        }
    }.lessThan);

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var cursor: usize = 0;
    for (ranges) |range| {
        if (range.start < cursor or range.end < range.start or range.end > source.len) return error.OverlappingTextEdits;
        try out.appendSlice(allocator, source[cursor..range.start]);
        try out.appendSlice(allocator, range.text);
        cursor = range.end;
    }
    try out.appendSlice(allocator, source[cursor..]);
    return out.toOwnedSlice(allocator);
}

fn appendConstraintLine(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    indent: []const u8,
    object_name: []const u8,
    target_anchor: []const u8,
    source_name: []const u8,
    source_anchor: []const u8,
    offset: f64,
) !void {
    try appendConstraintLineWithoutTrailingNewline(allocator, out, indent, object_name, target_anchor, source_name, source_anchor, offset);
    try out.append(allocator, '\n');
}

fn appendDiscardLine(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    indent: []const u8,
    object_name: []const u8,
    selector: []const u8,
) !void {
    try out.appendSlice(allocator, indent);
    try out.appendSlice(allocator, "!~ ");
    try out.appendSlice(allocator, object_name);
    try out.append(allocator, '.');
    try out.appendSlice(allocator, selector);
    try out.append(allocator, '\n');
}

fn appendConstraintLineWithoutTrailingNewline(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    indent: []const u8,
    object_name: []const u8,
    target_anchor: []const u8,
    source_name: []const u8,
    source_anchor: []const u8,
    offset: f64,
) !void {
    const number = try formatNumber(allocator, @abs(offset));
    defer allocator.free(number);
    try out.appendSlice(allocator, indent);
    try out.appendSlice(allocator, "~ ");
    try out.appendSlice(allocator, object_name);
    try out.append(allocator, '.');
    try out.appendSlice(allocator, target_anchor);
    try out.appendSlice(allocator, " == ");
    try out.appendSlice(allocator, source_name);
    try out.append(allocator, '.');
    try out.appendSlice(allocator, source_anchor);
    try out.appendSlice(allocator, if (offset < 0) " - " else " + ");
    try out.appendSlice(allocator, number);
}

fn formatNumber(allocator: std.mem.Allocator, value: f64) ![]u8 {
    var text = try std.fmt.allocPrint(allocator, "{d:.2}", .{value});
    var end = text.len;
    while (end > 0 and text[end - 1] == '0') end -= 1;
    if (end > 0 and text[end - 1] == '.') end -= 1;
    if (end == text.len) return text;
    const trimmed = try allocator.dupe(u8, text[0..end]);
    allocator.free(text);
    return trimmed;
}

fn findPageBlock(source: []const u8, page_name: []const u8, page_index: ?i64) ?PageBlock {
    var lines = LineIterator.init(source);
    var current_page_index: i64 = 0;
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line.text, " \t\r");
        if (!isPageDeclaration(trimmed)) continue;
        current_page_index += 1;
        const rest = std.mem.trim(u8, trimmed["page".len..], " \t");
        if (!std.mem.eql(u8, rest, page_name) and (page_index == null or page_index.? != current_page_index)) continue;
        var body = lines;
        var indent: ?[]const u8 = null;
        var nested_depth: usize = 0;
        while (body.next()) |body_line| {
            const body_trimmed = std.mem.trim(u8, body_line.text, " \t\r");
            if (indent == null and body_trimmed.len != 0) {
                indent = body_line.text[0..leadingWhitespace(body_line.text)];
            }
            if (std.mem.eql(u8, body_trimmed, "end")) {
                if (nested_depth == 0) {
                    return .{ .end_line = body_line, .indent = indent orelse "  " };
                }
                nested_depth -= 1;
                continue;
            }
            if (startsNestedBlock(body_trimmed)) nested_depth += 1;
        }
        return null;
    }
    return null;
}

fn isPageDeclaration(trimmed: []const u8) bool {
    if (!std.mem.startsWith(u8, trimmed, "page")) return false;
    return trimmed.len == "page".len or std.ascii.isWhitespace(trimmed["page".len]);
}

fn leadingWhitespace(text: []const u8) usize {
    var index: usize = 0;
    while (index < text.len and (text[index] == ' ' or text[index] == '\t')) index += 1;
    return index;
}

fn startsNestedBlock(trimmed: []const u8) bool {
    const keywords = [_][]const u8{ "if", "for", "fn", "fn/!", "document", "page", "type", "extend", "protocol" };
    for (keywords) |keyword| {
        if (std.mem.eql(u8, trimmed, keyword)) return true;
        if (std.mem.startsWith(u8, trimmed, keyword) and trimmed.len > keyword.len and std.ascii.isWhitespace(trimmed[keyword.len])) return true;
    }
    return false;
}

fn offsetFromLineCharacter(source: []const u8, target_line: usize, target_character: usize) usize {
    var line: usize = 0;
    var index: usize = 0;
    while (index < source.len and line < target_line) : (index += 1) {
        if (source[index] == '\n') line += 1;
    }
    var character: usize = 0;
    while (index < source.len and source[index] != '\n' and character < target_character) : (index += 1) {
        character += 1;
    }
    return index;
}

const LineIterator = struct {
    source: []const u8,
    offset: usize = 0,
    index: usize = 0,

    fn init(source: []const u8) LineIterator {
        return .{ .source = source };
    }

    fn next(self: *LineIterator) ?Line {
        if (self.offset >= self.source.len) return null;
        const start = self.offset;
        var end = start;
        while (end < self.source.len and self.source[end] != '\n') end += 1;
        self.offset = if (end < self.source.len) end + 1 else end;
        const line = Line{
            .index = self.index,
            .start = start,
            .end = end,
            .text = self.source[start..end],
        };
        self.index += 1;
        return line;
    }
};
