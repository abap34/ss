const std = @import("std");
const utils = @import("utils");

const testing = std.testing;
const json = utils.json;

test "utils json spec: buffer object writer escapes primitive fields" {
    const allocator = testing.allocator;
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    var object = try json.Object.beginBuffer(allocator, &out);
    try object.stringField("text", "quote: \" newline:\n");
    try object.intField("count", @as(i64, 42));
    try object.boolField("enabled", true);
    var nested = try json.parseValue(allocator, "{\"name\":\"child\"}", .{});
    defer nested.deinit();
    try object.valueField("meta", nested.value);
    var items = try object.arrayField("items");
    try items.valueItem(nested.value);
    try items.end();
    try object.end();

    var parsed = try json.parseValue(allocator, out.items, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value == .object);
    const root = &parsed.value.object;
    try testing.expectEqualStrings("quote: \" newline:\n", json.stringField(root, "text").?);
    try testing.expectEqual(@as(i64, 42), json.integerField(root, "count").?);
    try testing.expectEqual(true, json.boolField(root, "enabled").?);
    try testing.expectEqualStrings("child", json.stringField(json.objectFieldObject(root, "meta").?, "name").?);
    try testing.expectEqual(@as(usize, 1), json.arrayFieldObject(root, "items").?.items.len);
}

test "utils json spec: field readers expose nested values" {
    const allocator = testing.allocator;
    var parsed = try json.parseValue(allocator,
        \\{"name":"deck","size":12.5,"meta":{"active":false},"items":[{"id":1}]}
    , .{});
    defer parsed.deinit();

    try testing.expect(parsed.value == .object);
    const root = &parsed.value.object;
    try testing.expectEqualStrings("deck", json.stringField(root, "name").?);
    try testing.expectEqual(@as(f64, 12.5), json.numberField(root, "size").?);
    try testing.expect(json.integerField(root, "size") == null);

    const meta = json.objectFieldObject(root, "meta").?;
    try testing.expectEqual(false, json.boolField(meta, "active").?);

    const items = json.arrayFieldObject(root, "items").?;
    try testing.expectEqual(@as(usize, 1), items.items.len);
    try testing.expect(items.items[0] == .object);
    try testing.expectEqual(@as(i64, 1), json.integerField(&items.items[0].object, "id").?);
}

test "utils json spec: value appender preserves parsed JSON" {
    const allocator = testing.allocator;
    var parsed = try json.parseValue(allocator, "{\"items\":[1,2],\"ok\":true}", .{});
    defer parsed.deinit();

    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    try json.appendValue(allocator, &out, parsed.value);

    var reparsed = try json.parseValue(allocator, out.items, .{});
    defer reparsed.deinit();
    try testing.expect(reparsed.value == .object);
    const root = &reparsed.value.object;
    try testing.expectEqual(true, json.boolField(root, "ok").?);
    const items = json.arrayFieldObject(root, "items").?;
    try testing.expectEqual(@as(usize, 2), items.items.len);
}
