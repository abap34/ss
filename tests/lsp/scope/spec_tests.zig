const std = @import("std");
const lsp_scope = @import("lsp_scope");

const JsonValue = std.json.Value;

const scoped_json =
    \\{
    \\  "modules": [
    \\    {
    \\      "id": 0,
    \\      "path": "/tmp/deck.ss",
    \\      "program": {
    \\        "functions": [
    \\          {"name": "format", "span": {"start": 220, "end": 300}}
    \\        ],
    \\        "pages": [
    \\          {"name": "first", "span": {"start": 40, "end": 90}}
    \\        ]
    \\      }
    \\    },
    \\    {"id": 1, "path": "/tmp/other.ss", "program": {"functions": [], "pages": []}}
    \\  ],
    \\  "variables": [
    \\    {"name": "x", "type": "String", "moduleId": 0, "scopeKind": "document", "scopeName": null, "spanStart": 10, "visibleStart": 10, "visibleEnd": 200},
    \\    {"name": "x", "type": "Number", "moduleId": 0, "scopeKind": "page", "scopeName": "first", "spanStart": 50, "visibleStart": 50, "visibleEnd": 80},
    \\    {"name": "x", "type": "Bool", "moduleId": 1, "scopeKind": "document", "scopeName": null, "spanStart": 70, "visibleStart": 0, "visibleEnd": 200},
    \\    {"name": "x", "type": "Color", "moduleId": 0, "scopeKind": "function", "scopeName": "format", "spanStart": 230, "visibleStart": 220, "visibleEnd": 300}
    \\  ],
    \\  "definitions": [
    \\    {"name": "x", "kind": "variable", "moduleId": 0, "scopeKind": "document", "scopeName": null, "line": 1, "column": 4, "length": 1, "spanStart": 10, "visibleStart": 10, "visibleEnd": 200},
    \\    {"name": "x", "kind": "variable", "moduleId": 0, "scopeKind": "page", "scopeName": "first", "line": 3, "column": 4, "length": 1, "spanStart": 50, "visibleStart": 50, "visibleEnd": 80},
    \\    {"name": "x", "kind": "variable", "moduleId": 1, "scopeKind": "document", "scopeName": null, "line": 5, "column": 4, "length": 1, "spanStart": 70, "visibleStart": 0, "visibleEnd": 200},
    \\    {"name": "x", "kind": "variable", "moduleId": 0, "scopeKind": "function", "scopeName": "format", "line": 8, "column": 4, "length": 1, "spanStart": 230, "visibleStart": 220, "visibleEnd": 300}
    \\  ]
    \\}
;

test "lsp scope: visible variables select nearest binding in current file" {
    const allocator = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(JsonValue, allocator, scoped_json, .{});
    defer parsed.deinit();
    const root = parsed.value.object;

    var context = lsp_scope.RequestContext{
        .target = try allocator.dupe(u8, "x"),
        .doc_path = try allocator.dupe(u8, "/tmp/deck.ss"),
        .source = "",
        .offset = 45,
    };
    defer context.deinit(allocator);

    try std.testing.expect(lsp_scope.bestVisibleVariable(allocator, &root, "x", &context) == null);

    context.offset = 60;
    const page_variable = lsp_scope.bestVisibleVariable(allocator, &root, "x", &context) orelse return error.ExpectedVariable;
    try std.testing.expectEqualStrings("Number", lsp_scope.stringField(page_variable, "type") orelse @as([]const u8, ""));
    const page_definition = lsp_scope.bestVisibleDefinition(allocator, &root, "x", &context) orelse return error.ExpectedDefinition;
    try std.testing.expectEqual(@as(i64, 50), lsp_scope.intField(page_definition, "spanStart") orelse -1);

    context.offset = 95;
    const document_variable = lsp_scope.bestVisibleVariable(allocator, &root, "x", &context) orelse return error.ExpectedVariable;
    try std.testing.expectEqualStrings("String", lsp_scope.stringField(document_variable, "type") orelse @as([]const u8, ""));

    context.offset = 240;
    const function_variable = lsp_scope.bestVisibleVariable(allocator, &root, "x", &context) orelse return error.ExpectedVariable;
    try std.testing.expectEqualStrings("Color", lsp_scope.stringField(function_variable, "type") orelse @as([]const u8, ""));
}

test "lsp scope: completion keeps only the best visible variable" {
    const allocator = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(JsonValue, allocator, scoped_json, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    const variables = root.get("variables").?.array;

    var context = lsp_scope.RequestContext{
        .target = try allocator.dupe(u8, "x"),
        .doc_path = try allocator.dupe(u8, "/tmp/deck.ss"),
        .source = "",
        .offset = 60,
    };
    defer context.deinit(allocator);

    var visible_count: usize = 0;
    var best_count: usize = 0;
    for (variables.items) |*item| {
        if (item.* != .object) continue;
        if (!lsp_scope.variableVisibleAt(allocator, &root, &item.object, &context)) continue;
        visible_count += 1;
        if (lsp_scope.isBestVisibleVariable(allocator, &root, &item.object, &context)) {
            best_count += 1;
            try std.testing.expectEqualStrings("Number", lsp_scope.stringField(&item.object, "type") orelse @as([]const u8, ""));
        }
    }

    try std.testing.expectEqual(@as(usize, 1), visible_count);
    try std.testing.expectEqual(@as(usize, 1), best_count);
}
