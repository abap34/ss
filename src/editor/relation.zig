const std = @import("std");
const utils = @import("utils");

pub const ByteSpan = utils.source.ByteSpan;
const number_zero_threshold: f64 = 0.005;

pub const Adjustment = struct {
    pub const Action = union(enum) {
        replace: ByteSpan,
        append_update: ?ByteSpan,
    };

    action: Action,
    target: []const u8,
    target_anchor: []const u8,
    source: []const u8,
    source_anchor: []const u8,
    evaluated_offset: f64,
    delta: f64,
};

pub const Parsed = struct {
    update: bool,
    indent: []const u8,
    target: []const u8,
    target_anchor: []const u8,
    source: []const u8,
    source_anchor: []const u8,
    offset_source: []const u8,
    semicolon: bool,
    comment: []const u8,
};

pub fn parse(line: []const u8) ?Parsed {
    const indent_end = leadingWhitespace(line);
    const uncommented = utils.source.stripLineComment(line);
    var code = std.mem.trimEnd(u8, uncommented, " \t\r\n");
    const semicolon = code.len != 0 and code[code.len - 1] == ';';
    if (semicolon) code = std.mem.trimEnd(u8, code[0 .. code.len - 1], " \t");
    if (indent_end > code.len) return null;
    const body = std.mem.trim(u8, code[indent_end..], " \t\r\n");
    const update = std.mem.startsWith(u8, body, "~!~");
    const marker_len: usize = if (update) 3 else if (std.mem.startsWith(u8, body, "~")) 1 else return null;
    const equality = std.mem.indexOf(u8, body[marker_len..], "==") orelse return null;
    const equality_start = equality + marker_len;
    const target = parseEndpoint(std.mem.trim(u8, body[marker_len..equality_start], " \t")) orelse return null;
    const right = std.mem.trim(u8, body[equality_start + 2 ..], " \t");
    const endpoint_end = endpointPrefixEnd(right) orelse return null;
    const source_endpoint = parseEndpoint(right[0..endpoint_end]) orelse return null;
    const offset_source = std.mem.trim(u8, right[endpoint_end..], " \t");
    if (offset_source.len != 0 and offset_source[0] != '+' and offset_source[0] != '-') return null;
    return .{
        .update = update,
        .indent = line[0..indent_end],
        .target = target.name,
        .target_anchor = target.anchor,
        .source = source_endpoint.name,
        .source_anchor = source_endpoint.anchor,
        .offset_source = offset_source,
        .semicolon = semicolon,
        .comment = line[uncommented.len..],
    };
}

pub fn matches(parsed: Parsed, adjustment: Adjustment) bool {
    return sameObjectPath(parsed.target, adjustment.target) and
        std.mem.eql(u8, parsed.target_anchor, adjustment.target_anchor) and
        sameObjectPath(parsed.source, adjustment.source) and
        std.mem.eql(u8, parsed.source_anchor, adjustment.source_anchor);
}

pub fn sameObjectPath(left: []const u8, right: []const u8) bool {
    var left_index: usize = 0;
    var right_index: usize = 0;
    while (true) {
        while (left_index < left.len and utils.source.isInlineSpace(left[left_index])) left_index += 1;
        while (right_index < right.len and utils.source.isInlineSpace(right[right_index])) right_index += 1;
        if (left_index == left.len or right_index == right.len) return left_index == left.len and right_index == right.len;
        if (left[left_index] != right[right_index]) return false;
        left_index += 1;
        right_index += 1;
    }
}

pub fn appendAdjusted(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    update: bool,
    indent: []const u8,
    adjustment: Adjustment,
    offset_source: ?[]const u8,
) !void {
    try appendEndpoints(
        allocator,
        out,
        update,
        indent,
        adjustment.target,
        adjustment.target_anchor,
        adjustment.source,
        adjustment.source_anchor,
    );
    if (offset_source) |original| {
        try appendAdjustedOffset(allocator, out, original, adjustment.delta);
    } else {
        try appendNumericOffset(allocator, out, adjustment.evaluated_offset + adjustment.delta);
    }
}

pub fn appendNumeric(
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
    try appendEndpoints(allocator, out, update, indent, target, target_anchor, source, source_anchor);
    try appendNumericOffset(allocator, out, offset);
}

pub fn appendSuffix(allocator: std.mem.Allocator, out: *std.ArrayList(u8), parsed: Parsed) !void {
    if (parsed.semicolon) try out.append(allocator, ';');
    if (parsed.comment.len != 0) {
        try out.append(allocator, ' ');
        try out.appendSlice(allocator, parsed.comment);
    }
}

pub fn isHorizontal(anchor: []const u8) ?bool {
    if (std.mem.eql(u8, anchor, "left") or std.mem.eql(u8, anchor, "right") or std.mem.eql(u8, anchor, "center_x")) return true;
    if (std.mem.eql(u8, anchor, "top") or std.mem.eql(u8, anchor, "bottom") or std.mem.eql(u8, anchor, "center_y")) return false;
    return null;
}

fn appendEndpoints(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    update: bool,
    indent: []const u8,
    target: []const u8,
    target_anchor: []const u8,
    source: []const u8,
    source_anchor: []const u8,
) !void {
    try out.appendSlice(allocator, indent);
    try out.appendSlice(allocator, if (update) "~!~ " else "~ ");
    try out.appendSlice(allocator, target);
    try out.append(allocator, '.');
    try out.appendSlice(allocator, target_anchor);
    try out.appendSlice(allocator, " == ");
    try out.appendSlice(allocator, source);
    try out.append(allocator, '.');
    try out.appendSlice(allocator, source_anchor);
}

fn appendAdjustedOffset(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    offset_source: []const u8,
    delta: f64,
) !void {
    if (offset_source.len == 0) return appendNumericOffset(allocator, out, delta);
    if (@abs(delta) <= number_zero_threshold) {
        try out.append(allocator, ' ');
        try out.appendSlice(allocator, offset_source);
        return;
    }

    const sign = offset_source[0];
    if (sign != '+' and sign != '-') return error.InvalidConstraintOrigin;
    const expression = std.mem.trim(u8, offset_source[1..], " \t");
    if (expression.len == 0) return error.InvalidConstraintOrigin;
    if (std.fmt.parseFloat(f64, expression)) |number| {
        return appendNumericOffset(allocator, out, (if (sign == '-') -number else number) + delta);
    } else |_| {}

    if (sign == '+') {
        if (trailingNumber(expression)) |trailing| {
            try appendSymbolicOffset(allocator, out, stripOuterParentheses(trailing.base), trailing.value + delta);
            return;
        }
        try appendSymbolicOffset(allocator, out, stripOuterParentheses(expression), delta);
        return;
    }

    try out.appendSlice(allocator, " + (-(");
    try out.appendSlice(allocator, expression);
    try out.appendSlice(allocator, "))");
    try appendNumericOffset(allocator, out, delta);
}

fn appendSymbolicOffset(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    expression: []const u8,
    numeric_term: f64,
) !void {
    try out.appendSlice(allocator, " + (");
    try out.appendSlice(allocator, expression);
    try out.append(allocator, ')');
    try appendNumericOffset(allocator, out, numeric_term);
}

fn appendNumericOffset(allocator: std.mem.Allocator, out: *std.ArrayList(u8), offset: f64) !void {
    if (@abs(offset) <= number_zero_threshold) return;
    const number = try formatNumber(allocator, @abs(offset));
    defer allocator.free(number);
    try out.appendSlice(allocator, if (offset < 0) " - " else " + ");
    try out.appendSlice(allocator, number);
}

const TrailingNumber = struct {
    base: []const u8,
    value: f64,
};

fn trailingNumber(expression: []const u8) ?TrailingNumber {
    var depth: usize = 0;
    var candidate: ?usize = null;
    var bytes = utils.source.codeBytes(expression, 0, expression.len);
    while (bytes.next()) |item| {
        const ch = item.byte;
        const index = item.pos;
        switch (ch) {
            '(' => depth += 1,
            ')' => if (depth > 0) {
                depth -= 1;
            },
            '+', '-' => {
                if (depth != 0 or index == 0) continue;
                const previous = expression[index - 1];
                if (previous == 'e' or previous == 'E') continue;
                candidate = index;
            },
            else => {},
        }
    }
    const index = candidate orelse return null;
    const base = std.mem.trim(u8, expression[0..index], " \t");
    const number_source = std.mem.trim(u8, expression[index + 1 ..], " \t");
    if (base.len == 0 or number_source.len == 0) return null;
    const number = std.fmt.parseFloat(f64, number_source) catch return null;
    return .{
        .base = base,
        .value = if (expression[index] == '-') -number else number,
    };
}

fn stripOuterParentheses(expression: []const u8) []const u8 {
    var result = std.mem.trim(u8, expression, " \t");
    while (result.len >= 2 and result[0] == '(' and result[result.len - 1] == ')' and outerParenthesesCover(result)) {
        result = std.mem.trim(u8, result[1 .. result.len - 1], " \t");
    }
    return result;
}

fn outerParenthesesCover(expression: []const u8) bool {
    var depth: usize = 0;
    var bytes = utils.source.codeBytes(expression, 0, expression.len);
    while (bytes.next()) |item| {
        const ch = item.byte;
        const index = item.pos;
        if (ch == '(') depth += 1;
        if (ch == ')') {
            if (depth == 0) return false;
            depth -= 1;
            if (depth == 0 and index + 1 != expression.len) return false;
        }
    }
    return depth == 0;
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
    if (!validObjectPath(name) or !validAnchor(anchor)) return null;
    return .{ .name = name, .anchor = anchor };
}

fn validObjectPath(path: []const u8) bool {
    var index: usize = 0;
    while (true) {
        while (index < path.len and utils.source.isInlineSpace(path[index])) index += 1;
        if (index == path.len or !utils.source.isIdentifierStart(path[index])) return false;
        index += 1;
        while (index < path.len and utils.source.isIdentifierContinue(path[index])) index += 1;
        while (index < path.len and utils.source.isInlineSpace(path[index])) index += 1;
        if (index == path.len) return true;
        if (path[index] != '.') return false;
        index += 1;
    }
}

fn endpointPrefixEnd(text: []const u8) ?usize {
    var index: usize = 0;
    while (index < text.len and text[index] != '+' and text[index] != '-') index += 1;
    const end = std.mem.trimEnd(u8, text[0..index], " \t").len;
    return if (end == 0) null else end;
}

fn validAnchor(anchor: []const u8) bool {
    const anchors = [_][]const u8{ "left", "right", "top", "bottom", "center_x", "center_y" };
    for (anchors) |candidate| if (std.mem.eql(u8, anchor, candidate)) return true;
    return false;
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
