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
