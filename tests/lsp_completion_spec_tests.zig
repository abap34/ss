const std = @import("std");
const lsp_completion = @import("lsp_completion");

const JsonValue = std.json.Value;

const completion_json =
    \\{
    \\  "declarations": {
    \\    "classes": [
    \\      {"name": "BaseObject", "base": null},
    \\      {"name": "TitleObject", "base": "BaseObject"},
    \\      {"name": "OtherObject", "base": null},
    \\      {"name": "Doc", "base": null}
    \\    ],
    \\    "fields": [
    \\      {"name": "base_margin", "class": "BaseObject", "type": "Number"},
    \\      {"name": "text_size", "class": "TitleObject", "type": "Number"},
    \\      {"name": "text_size", "class": "BaseObject", "type": "Number"},
    \\      {"name": "other_only", "class": "OtherObject", "type": "String"},
    \\      {"name": "page_size", "class": "Doc", "type": "String"}
    \\    ]
    \\  },
    \\  "variables": [
    \\    {"name": "title", "type": "Object<TitleObject>", "objectClass": "TitleObject"},
    \\    {"name": "object", "type": "Object", "objectClass": null},
    \\    {"name": "doc", "type": "Document", "objectClass": null},
    \\    {"name": "text", "type": "String", "objectClass": null}
    \\  ]
    \\}
;

test "lsp completion: access context detects dot and module qualifiers" {
    const dot_source = "page main\n  title.text";
    const dot = lsp_completion.accessBeforeOffset(dot_source, dot_source.len) orelse return error.ExpectedDotAccess;
    try std.testing.expectEqual(lsp_completion.AccessSeparator.dot, dot.separator);
    try std.testing.expectEqualStrings("title", dot.receiver);
    try std.testing.expectEqual(std.mem.indexOfScalar(u8, dot_source, '.').?, dot.separator_offset);

    const module_source = "default::h";
    const module = lsp_completion.accessBeforeOffset(module_source, module_source.len) orelse return error.ExpectedModuleAccess;
    try std.testing.expectEqual(lsp_completion.AccessSeparator.double_colon, module.separator);
    try std.testing.expectEqualStrings("default", module.receiver);
    try std.testing.expectEqual(std.mem.indexOf(u8, module_source, "::").?, module.separator_offset);

    try std.testing.expect(lsp_completion.accessBeforeOffset("title", 5) == null);
}

test "lsp completion: property targets come from variable type information" {
    const allocator = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(JsonValue, allocator, completion_json, .{});
    defer parsed.deinit();
    const variables = parsed.value.object.get("variables").?.array;

    const title_target = lsp_completion.propertyTargetForVariable(&variables.items[0].object) orelse return error.ExpectedTitleTarget;
    switch (title_target) {
        .class => |name| try std.testing.expectEqualStrings("TitleObject", name),
        else => return error.ExpectedClassTarget,
    }

    const object_target = lsp_completion.propertyTargetForVariable(&variables.items[1].object) orelse return error.ExpectedObjectTarget;
    try std.testing.expectEqual(lsp_completion.PropertyTarget.any_object, object_target);

    const doc_target = lsp_completion.propertyTargetForVariable(&variables.items[2].object) orelse return error.ExpectedDocTarget;
    switch (doc_target) {
        .class => |name| try std.testing.expectEqualStrings("Doc", name),
        else => return error.ExpectedClassTarget,
    }

    try std.testing.expect(lsp_completion.propertyTargetForVariable(&variables.items[3].object) == null);
}

test "lsp completion: fields are filtered by class ancestry" {
    const allocator = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(JsonValue, allocator, completion_json, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    const fields = root.get("declarations").?.object.get("fields").?.array;

    const title_target = lsp_completion.PropertyTarget{ .class = "TitleObject" };
    try std.testing.expect(lsp_completion.fieldAppliesToTarget(&root, &fields.items[0].object, title_target));
    try std.testing.expect(lsp_completion.fieldAppliesToTarget(&root, &fields.items[1].object, title_target));
    try std.testing.expect(!lsp_completion.fieldAppliesToTarget(&root, &fields.items[3].object, title_target));

    const object_target = lsp_completion.PropertyTarget.any_object;
    try std.testing.expect(lsp_completion.fieldAppliesToTarget(&root, &fields.items[3].object, object_target));
}
