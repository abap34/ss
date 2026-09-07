const std = @import("std");
const lsp = @import("lsp");
const state = lsp.state;
const tokens = lsp.semantic_tokens;
const colors = lsp.colors;
const testing = std.testing;

const original = "head\nx\u{1f680}y\nend\n";
const changes_json =
    \\[{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":0}},"text":"start\n"},
    \\ {"range":{"start":{"line":2,"character":1},"end":{"line":2,"character":3}},"text":"\u65e5"}]
;

test "LSP source positions: sequential edits update line indexes in the same generation" {
    try applyEdits(testing.allocator);
}

test "LSP source positions: partial updates retain ownership on allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, applyEdits, .{});
}

fn applyEdits(allocator: std.mem.Allocator) !void {
    var documents = state.DocumentStore.init(allocator);
    defer documents.deinit();
    const path = try documents.replaceUri("file:///tmp/ss-line-index.ss", original, 1);
    defer allocator.free(path);
    var changes = try std.json.parseFromSlice(std.json.Value, allocator, changes_json, .{});
    defer changes.deinit();
    const changed = documents.applyChangesAtPath(path, &changes.value.array) catch |err| {
        try testing.expectEqualStrings(original, documents.items.get(path).?.text);
        try testing.expectEqual(@as(u64, 1), documents.generation);
        return err;
    };
    try testing.expect(changed);
    try testing.expectEqual(@as(u64, 2), documents.generation);
    const index = documents.items.get(path).?.line_index;
    try testing.expectEqualStrings("start\nhead\nx\u{65e5}y\nend\n", index.text);
    try testing.expectEqual(@as(usize, 15), index.offsetForUtf16Position(2, 2));
    try testing.expectEqual(@as(usize, 3), index.utf16PositionAt(17).line);
}

test "LSP source positions: a later invalid edit does not publish an earlier edit" {
    var documents = state.DocumentStore.init(testing.allocator);
    defer documents.deinit();
    const path = try documents.replaceUri("file:///tmp/ss-line-index.ss", original, null);
    defer testing.allocator.free(path);
    var changes = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\[{"text":"changed\n"},{"range":false,"text":"invalid"}]
    , .{});
    defer changes.deinit();
    try testing.expectError(error.InvalidParams, documents.applyChangesAtPath(path, &changes.value.array));
    try testing.expectEqualStrings(original, documents.indexForPath(path).?.text);
    try testing.expectEqual(@as(u64, 1), documents.generation);
}

test "LSP source positions: tokens count non-BMP strings as UTF-16" {
    const text = "const label = \"\u{1f680}\" ++ c\"#112233\"\n";
    const result = try tokens.json(testing.allocator, text);
    defer testing.allocator.free(result);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, result, .{});
    defer parsed.deinit();
    const data = parsed.value.object.get("data").?.array.items;
    var start: i64 = 0;
    var found = false;
    var offset: usize = 0;
    while (offset < data.len) : (offset += 5) {
        start = if (data[offset].integer == 0) start + data[offset + 1].integer else data[offset + 1].integer;
        if (start == 14) {
            try testing.expectEqual(@as(i64, 4), data[offset + 2].integer);
            found = true;
        }
    }
    try testing.expect(found);
}

test "LSP source positions: colors use UTF-16 offsets after non-BMP strings" {
    const text = "const label = \"\u{1f680}\" ++ c\"#112233\"\n";
    const result = try colors.documentColorsJson(testing.allocator, text);
    defer testing.allocator.free(result);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, result, .{});
    defer parsed.deinit();
    const range = parsed.value.array.items[0].object.get("range").?.object;
    try testing.expectEqual(@as(i64, 22), range.get("start").?.object.get("character").?.integer);
    try testing.expectEqual(@as(i64, 32), range.get("end").?.object.get("character").?.integer);
}
