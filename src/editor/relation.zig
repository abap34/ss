const std = @import("std");
const utils = @import("utils");

pub const ByteSpan = utils.source.ByteSpan;
const number_zero_threshold: f64 = 0.005;

pub const Source = struct {
    target: ByteSpan,
    source: ByteSpan,
    offset: ?ByteSpan,
};

pub const Adjustment = struct {
    pub const Action = union(enum) {
        replace: Source,
        append_update: ?Source,
    };

    action: Action,
    target: []const u8,
    target_anchor: []const u8,
    source: []const u8,
    source_anchor: []const u8,
    evaluated_offset: f64,
    delta: f64,
};

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

pub fn adjustedOffset(
    allocator: std.mem.Allocator,
    offset_source: ?[]const u8,
    evaluated_offset: f64,
    delta: f64,
    include_leading_space: bool,
) ![]u8 {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    if (offset_source) |original| {
        try appendAdjustedOffset(allocator, &out, original, delta);
    } else {
        try appendNumericOffset(allocator, &out, evaluated_offset + delta);
    }
    const result = if (include_leading_space) out.items else withoutLeadingSpace(out.items);
    return try allocator.dupe(u8, result);
}

pub fn numericOffset(allocator: std.mem.Allocator, offset: f64, include_leading_space: bool) ![]u8 {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    try appendNumericOffset(allocator, &out, offset);
    const result = if (include_leading_space) out.items else withoutLeadingSpace(out.items);
    return try allocator.dupe(u8, result);
}

pub fn numericLiteral(allocator: std.mem.Allocator, value: f64) ![]u8 {
    return formatNumber(allocator, if (@abs(value) <= number_zero_threshold) 0 else value);
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
    const expression = std.mem.trim(u8, offset_source[1..], " \t\r\n");
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
    const base = std.mem.trim(u8, expression[0..index], " \t\r\n");
    const number_source = std.mem.trim(u8, expression[index + 1 ..], " \t\r\n");
    if (base.len == 0 or number_source.len == 0) return null;
    const number = std.fmt.parseFloat(f64, number_source) catch return null;
    return .{
        .base = base,
        .value = if (expression[index] == '-') -number else number,
    };
}

fn stripOuterParentheses(expression: []const u8) []const u8 {
    var result = std.mem.trim(u8, expression, " \t\r\n");
    while (result.len >= 2 and result[0] == '(' and result[result.len - 1] == ')' and outerParenthesesCover(result)) {
        result = std.mem.trim(u8, result[1 .. result.len - 1], " \t\r\n");
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

fn withoutLeadingSpace(text: []const u8) []const u8 {
    var start: usize = 0;
    while (start < text.len and (text[start] == ' ' or text[start] == '\t')) start += 1;
    return text[start..];
}
