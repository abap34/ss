const std = @import("std");

const base = @import("base.zig");

pub fn removeStatements(
    allocator: std.mem.Allocator,
    source: []const u8,
    page: base.ByteSpan,
    statements: []const base.ByteSpan,
) !base.Result {
    var spans = std.ArrayList(base.ByteSpan).empty;
    defer spans.deinit(allocator);
    for (statements) |statement| {
        const line = statementLine(source, page, statement) orelse
            return error.InvalidComponentStatement;
        if (containsSpan(spans.items, line)) continue;
        try spans.append(allocator, line);
    }
    std.mem.sort(base.ByteSpan, spans.items, {}, struct {
        fn lessThan(_: void, left: base.ByteSpan, right: base.ByteSpan) bool {
            return left.start < right.start;
        }
    }.lessThan);

    const edits = try allocator.alloc(base.TextEdit, spans.items.len);
    var initialized: usize = 0;
    errdefer {
        for (edits[0..initialized]) |*edit| edit.deinit(allocator);
        allocator.free(edits);
    }
    for (spans.items, 0..) |span, index| {
        if (index > 0 and span.start < spans.items[index - 1].end) {
            return error.OverlappingComponentStatements;
        }
        edits[index] = .{
            .start = span.start,
            .end = span.end,
            .text = try allocator.dupe(u8, ""),
        };
        initialized += 1;
    }
    return .{ .edits = edits };
}

fn statementLine(source: []const u8, page: base.ByteSpan, statement: base.ByteSpan) ?base.ByteSpan {
    if (page.end < page.start or page.end > source.len or
        statement.start < page.start or statement.end > page.end or
        statement.end <= statement.start)
    {
        return null;
    }
    const start = base.lineStartAt(source, statement.start, page.start);
    if (std.mem.trim(u8, source[start..statement.start], " \t\r").len != 0) return null;
    var end = statement.end;
    while (end < page.end and source[end] != '\n') end += 1;
    if (end < source.len and source[end] == '\n') end += 1;
    return .{ .start = start, .end = end };
}

fn containsSpan(spans: []const base.ByteSpan, candidate: base.ByteSpan) bool {
    for (spans) |span| {
        if (span.start == candidate.start and span.end == candidate.end) return true;
    }
    return false;
}
