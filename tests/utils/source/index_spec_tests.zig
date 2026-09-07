const std = @import("std");
const source = @import("utils").source;
const testing = std.testing;

test "source index: line boundaries and positions preserve CRLF and Unicode behavior" {
    for ([_][]const u8{ "", "\n", "a\r\nb\n", "first\r\nx\u{1f680}y\u{301}\n\nlast", "\xff\nend" }) |text| {
        const index = try source.LineIndex.init(testing.allocator, text);
        defer index.deinit(testing.allocator);
        for (0..text.len + 4) |offset| {
            try testing.expectEqualDeep(source.lineAt(text, offset), index.lineAt(offset));
            try testing.expectEqualDeep(source.lineAt(text, offset).span, source.lineSpanAt(text, offset));
            try testing.expectEqualDeep(source.locationAt(text, offset), index.locationAt(offset));
            try testing.expectEqualDeep(source.utf16PositionAt(text, offset), index.utf16PositionAt(offset));
        }
        for (0..source.lineCount(text) + 3) |line| {
            try testing.expectEqualDeep(source.lineByNumber(text, line), index.lineByNumber(line));
            for (0..16) |character| {
                try testing.expectEqual(source.offsetForUtf16Position(text, line, character), index.offsetForUtf16Position(line, character));
            }
        }
    }
}

test "source index: UTF-16 surrogate interiors and out of range positions stay on a line" {
    const index = try source.LineIndex.init(testing.allocator, "first\r\nx\u{1f680}y\u{301}\n\nlast");
    defer index.deinit(testing.allocator);
    try testing.expectEqualDeep(source.Utf16Position{ .line = 1, .character = 3 }, index.utf16PositionAt(12));
    try testing.expectEqual(@as(usize, 8), index.offsetForUtf16Position(1, 2));
    try testing.expectEqual(@as(usize, 12), index.offsetForUtf16Position(1, 3));
    try testing.expectEqual(@as(usize, 6), index.offsetForUtf16Position(0, 100));
    try testing.expectEqual(@as(usize, 16), index.offsetForUtf16Position(2, 100));
    try testing.expectEqual(index.text.len, index.offsetForUtf16Position(100, 0));
}

test "source index: cloned generations own separate indexes" {
    const text = "first\nsecond\n";
    const original = try source.LineIndex.init(testing.allocator, text);
    defer original.deinit(testing.allocator);
    const copy = try testing.allocator.dupe(u8, text);
    defer testing.allocator.free(copy);
    const clone = try original.clone(testing.allocator, copy);
    defer clone.deinit(testing.allocator);
    try testing.expect(original.starts.ptr != clone.starts.ptr);
    try testing.expectEqualDeep(original.locationAt(8), clone.locationAt(8));
    try testing.checkAllAllocationFailures(testing.allocator, createIndexes, .{});
}

fn createIndexes(allocator: std.mem.Allocator) !void {
    const index = try source.LineIndex.init(allocator, "first\nsecond\n");
    defer index.deinit(allocator);
    const clone = try index.clone(allocator, index.text);
    defer clone.deinit(allocator);
}
