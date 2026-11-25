const std = @import("std");
const completion = @import("lsp").completion;
const testing = std.testing;

test "LSP completion: incomplete candidates request recomputation on further typing" {
    inline for (.{ false, true }) |is_incomplete| {
        const encoded = try completion.json(testing.allocator, .{
            .items = &.{},
            .is_incomplete = is_incomplete,
        });
        defer testing.allocator.free(encoded);
        var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, encoded, .{});
        defer parsed.deinit();
        try testing.expectEqual(is_incomplete, parsed.value.object.get("isIncomplete").?.bool);
        try testing.expectEqual(@as(usize, 0), parsed.value.object.get("items").?.array.items.len);
    }
}

test "LSP completion serializes replacement ranges and quoted import text" {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(testing.allocator);
    try out.append(testing.allocator, '[');
    var builder = completion.Builder.init(testing.allocator, &out);
    defer builder.deinit();
    try builder.addCandidate(.{
        .label = "std:text",
        .kind = .module,
        .text_edit = .{ .start = .{ .line = 2, .character = 8 }, .end = .{ .line = 2, .character = 14 }, .text = "std:text\"" },
    });
    try out.append(testing.allocator, ']');
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, out.items, .{});
    defer parsed.deinit();
    const item = parsed.value.array.items[0].object;
    try testing.expectEqual(@as(i64, 9), item.get("kind").?.integer);
    const edit = item.get("textEdit").?.object;
    try testing.expectEqualStrings("std:text\"", edit.get("newText").?.string);
    const range = edit.get("range").?.object;
    try testing.expectEqual(@as(i64, 8), range.get("start").?.object.get("character").?.integer);
    try testing.expectEqual(@as(i64, 14), range.get("end").?.object.get("character").?.integer);
}
