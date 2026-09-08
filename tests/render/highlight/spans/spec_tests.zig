const std = @import("std");
const highlight = @import("highlight_spans");
const CaptureRole = @import("utils").highlight.CaptureRole;
const testing = std.testing;

fn referenceBoundary(spans: []const highlight.Span, position: usize, line_end: usize) usize {
    var next = line_end;
    for (spans) |span| {
        if (span.end <= position or span.start >= line_end) continue;
        if (span.start > position) next = @min(next, span.start);
        if (span.start <= position and span.end > position) next = @min(next, span.end);
    }
    return next;
}

fn referenceRole(spans: []const highlight.Span, start: usize, end: usize) ?CaptureRole {
    var best: ?highlight.Span = null;
    for (spans) |span| {
        if (span.start > start or span.end < end) continue;
        if (best) |current| {
            const length = span.end - span.start;
            const current_length = current.end - current.start;
            if (length > current_length or (length == current_length and span.start < current.start)) continue;
        }
        best = span;
    }
    return if (best) |span| span.role else null;
}

fn expectReference(spans: []const highlight.Span, length: usize, line_width: usize) !void {
    const segments = try highlight.compile(testing.allocator, spans, length);
    defer testing.allocator.free(segments);
    var cursor = highlight.Cursor{ .segments = segments };
    var start: usize = 0;
    while (start < length) : (start += line_width + 2) {
        const line_end = @min(start + line_width, length);
        var position = start;
        while (position < line_end) {
            const expected_end = referenceBoundary(spans, position, line_end);
            const actual = cursor.next(position, line_end) orelse return error.MissingSegment;
            try testing.expectEqual(position, actual.start);
            try testing.expectEqual(expected_end, actual.end);
            try testing.expectEqual(referenceRole(spans, position, expected_end), actual.role);
            position = actual.end;
        }
        try testing.expect(cursor.next(position, line_end) == null);
    }
}

test "highlight spans: ordered boundaries preserve overlap specificity and equal-range precedence" {
    const spans = [_]highlight.Span{
        .{ .start = 2, .end = 18, .role = .comment },
        .{ .start = 2, .end = 7, .role = .keyword },
        .{ .start = 5, .end = 10, .role = .string },
        .{ .start = 6, .end = 8, .role = .variable },
        .{ .start = 6, .end = 8, .role = .number },
        .{ .start = 18, .end = 20, .role = .constant },
        .{ .start = 3, .end = 19, .role = .operator },
    };
    for ([_]usize{ 1, 3, 7, 24 }) |width| try expectReference(&spans, 24, width);
    try expectReference(&.{}, 24, 7);
    try expectReference(&.{}, 0, 1);
}

test "highlight spans: generated overlapping captures match the full-scan reference" {
    var spans: [64]highlight.Span = undefined;
    for (0..32) |seed| {
        for (&spans, 0..) |*span, index| {
            const start = (index * 7 + seed) % 96;
            span.* = .{
                .start = start,
                .end = start + 1 + (index * 13 + seed) % (96 - start),
                .role = @enumFromInt(index % 10),
            };
        }
        for ([_]usize{ 5, 13, 96 }) |width| try expectReference(&spans, 96, width);
    }
}

test "highlight spans: a cursor crosses thousands of captures without revisiting earlier segments" {
    for ([_]usize{ 128, 1024, 8192 }) |count| {
        const spans = try testing.allocator.alloc(highlight.Span, count);
        defer testing.allocator.free(spans);
        for (spans, 0..) |*span, index| span.* = .{ .start = index * 4 + 1, .end = index * 4 + 3, .role = .number };
        const segments = try highlight.compile(testing.allocator, spans, count * 4);
        defer testing.allocator.free(segments);
        try testing.expectEqual(count * 2 + 1, segments.len);
        var cursor = highlight.Cursor{ .segments = segments };
        var position: usize = 0;
        var visited: usize = 0;
        while (cursor.next(position, count * 4)) |segment| {
            try testing.expectEqual(position, segment.start);
            try testing.expect(segment.end > segment.start);
            try testing.expectEqual(visited + 1, cursor.index);
            try testing.expectEqual(if (visited % 2 == 1) @as(?CaptureRole, .number) else null, segment.role);
            position = segment.end;
            visited += 1;
        }
        try testing.expectEqual(count * 4, position);
        try testing.expectEqual(segments.len, visited);
    }
}

fn compileWithAllocationFailures(allocator: std.mem.Allocator) !void {
    const spans = [_]highlight.Span{
        .{ .start = 0, .end = 12, .role = .comment },
        .{ .start = 3, .end = 8, .role = .number },
        .{ .start = 4, .end = 9, .role = .string },
        .{ .start = 4, .end = 5, .role = .keyword },
    };
    const segments = try highlight.compile(allocator, &spans, 16);
    defer allocator.free(segments);
}

test "highlight spans: allocation failures release partially compiled segments" {
    try testing.checkAllAllocationFailures(testing.allocator, compileWithAllocationFailures, .{});
}
