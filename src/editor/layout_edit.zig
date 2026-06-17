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
    replaced_left: bool,
    replaced_top: bool,

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
    start_line: Line,
    end_line: Line,
    indent: []const u8,
};

const AnchorLine = struct {
    line: Line,
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
    const left_line = findDirectConstraint(source, page, object_name, "left");
    const top_line = findDirectConstraint(source, page, object_name, "top");

    var edits = std.ArrayList(TextEdit).empty;
    errdefer {
        for (edits.items) |*edit| edit.deinit(allocator);
        edits.deinit(allocator);
    }

    if (left_line) |line| {
        try edits.append(allocator, try replaceLineEdit(allocator, line.line, page.indent, object_name, "left", "page.left", .plus, left));
    }
    if (top_line) |line| {
        try edits.append(allocator, try replaceLineEdit(allocator, line.line, page.indent, object_name, "top", "page.top", .minus, top_from_page_top));
    }
    if (left_line == null or top_line == null) {
        var text = std.ArrayList(u8).empty;
        errdefer text.deinit(allocator);
        if (left_line == null) {
            try appendConstraintLine(allocator, &text, page.indent, object_name, "left", "page.left", .plus, left);
        }
        if (top_line == null) {
            try appendConstraintLine(allocator, &text, page.indent, object_name, "top", "page.top", .minus, top_from_page_top);
        }
        try edits.append(allocator, .{
            .start_line = page.end_line.index,
            .start_character = 0,
            .end_line = page.end_line.index,
            .end_character = 0,
            .text = try text.toOwnedSlice(allocator),
        });
    }

    return .{
        .edits = try edits.toOwnedSlice(allocator),
        .replaced_left = left_line != null,
        .replaced_top = top_line != null,
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

const Sign = enum { plus, minus };

fn replaceLineEdit(
    allocator: std.mem.Allocator,
    line: Line,
    indent: []const u8,
    object_name: []const u8,
    target_anchor: []const u8,
    source_anchor: []const u8,
    sign: Sign,
    amount: f64,
) !TextEdit {
    var text = std.ArrayList(u8).empty;
    errdefer text.deinit(allocator);
    try appendConstraintLineWithoutTrailingNewline(allocator, &text, indent, object_name, target_anchor, source_anchor, sign, amount);
    return .{
        .start_line = line.index,
        .start_character = 0,
        .end_line = line.index,
        .end_character = line.text.len,
        .text = try text.toOwnedSlice(allocator),
    };
}

fn appendConstraintLine(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    indent: []const u8,
    object_name: []const u8,
    target_anchor: []const u8,
    source_anchor: []const u8,
    sign: Sign,
    amount: f64,
) !void {
    try appendConstraintLineWithoutTrailingNewline(allocator, out, indent, object_name, target_anchor, source_anchor, sign, amount);
    try out.append(allocator, '\n');
}

fn appendConstraintLineWithoutTrailingNewline(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    indent: []const u8,
    object_name: []const u8,
    target_anchor: []const u8,
    source_anchor: []const u8,
    sign: Sign,
    amount: f64,
) !void {
    const number = try formatNumber(allocator, @abs(amount));
    defer allocator.free(number);
    try out.appendSlice(allocator, indent);
    try out.appendSlice(allocator, "~ ");
    try out.appendSlice(allocator, object_name);
    try out.append(allocator, '.');
    try out.appendSlice(allocator, target_anchor);
    try out.appendSlice(allocator, " == ");
    try out.appendSlice(allocator, source_anchor);
    const use_minus = (sign == .minus and amount >= 0) or (sign == .plus and amount < 0);
    try out.appendSlice(allocator, if (use_minus) " - " else " + ");
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
                    return .{ .start_line = line, .end_line = body_line, .indent = indent orelse "  " };
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

fn findDirectConstraint(source: []const u8, page: PageBlock, object_name: []const u8, anchor: []const u8) ?AnchorLine {
    var lines = LineIterator.init(source);
    while (lines.next()) |line| {
        if (line.index <= page.start_line.index) continue;
        if (line.index >= page.end_line.index) return null;
        if (matchesDirectConstraint(line.text, object_name, anchor)) return .{ .line = line };
    }
    return null;
}

fn matchesDirectConstraint(line: []const u8, object_name: []const u8, anchor: []const u8) bool {
    var rest = std.mem.trim(u8, line, " \t\r");
    if (rest.len == 0 or rest[0] != '~') return false;
    rest = trimLeft(rest[1..], " \t");
    if (!consume(&rest, object_name)) return false;
    if (!consume(&rest, ".")) return false;
    if (!consume(&rest, anchor)) return false;
    rest = trimLeft(rest, " \t");
    if (!consume(&rest, "==")) return false;
    rest = trimLeft(rest, " \t");
    if (!consume(&rest, "page.")) return false;
    return consume(&rest, anchor);
}

fn consume(rest: *[]const u8, prefix: []const u8) bool {
    if (!std.mem.startsWith(u8, rest.*, prefix)) return false;
    rest.* = rest.*[prefix.len..];
    return true;
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

fn trimLeft(text: []const u8, cutset: []const u8) []const u8 {
    var index: usize = 0;
    while (index < text.len and std.mem.indexOfScalar(u8, cutset, text[index]) != null) index += 1;
    return text[index..];
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
