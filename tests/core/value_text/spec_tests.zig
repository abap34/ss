const std = @import("std");
const ast = @import("ast");
const core = @import("core");

const testing = std.testing;

const tagged_style_json =
    \\{"kind":"record","type":"TextStyle","fields":[{"name":"font","explicit":true,"value":{"kind":"record","type":"FontFace","fields":[{"name":"family","explicit":true,"value":{"kind":"string","value":"Helvetica"}},{"name":"weight","explicit":true,"value":{"kind":"enum","type":"FontWeight","case":"bold"}}]}},{"name":"line_height","explicit":false,"value":{"kind":"number","value":28}},{"name":"enabled","explicit":true,"value":{"kind":"bool","value":true}}]}
;

test "core value text spec: tagged property value deinit frees duplicated names and strings" {
    var value = try core.value_text.parsePropertyValue(testing.allocator, tagged_style_json);
    defer core.value_text.deinitParsedPropertyValue(testing.allocator, &value);

    try testing.expectEqualStrings("TextStyle", value.record.type_name);
    const font = value.record.field("font").?.record;
    try testing.expectEqualStrings("FontFace", font.type_name);
    try testing.expectEqualStrings("Helvetica", font.field("family").?.string);
    const weight = font.field("weight").?.enum_case;
    try testing.expectEqualStrings("FontWeight", weight.enum_name);
    try testing.expectEqualStrings("bold", weight.case_name);
}

test "core value text spec: class default slots deinit tagged record property values" {
    var ir = try initIrWithTaggedRecordDefault();
    defer ir.deinit();

    const document = ir.getNode(ir.document_id).?;
    for (0..16) |_| {
        var slot = (try core.fields.get(testing.allocator, &ir, document, "style")).?;
        try testing.expect(slot.owned);
        try testing.expect(slot.owns_tagged_text);
        try testing.expectEqualStrings("TextStyle", slot.value.record.type_name);
        const font = slot.value.record.field("font").?.record;
        try testing.expectEqualStrings("Helvetica", font.field("family").?.string);
        slot.deinit(testing.allocator);
    }
}

fn initIrWithTaggedRecordDefault() !core.Ir {
    const allocator = testing.allocator;
    const asset_base_dir = try allocator.dupe(u8, ".");
    errdefer allocator.free(asset_base_dir);
    const project_path = try allocator.dupe(u8, "value-text-defaults.ss");
    errdefer allocator.free(project_path);
    const project_source = try allocator.dupe(u8, "");
    errdefer allocator.free(project_source);

    var program = ast.Program.init();
    errdefer program.deinit(allocator);

    try program.objects.append(allocator, .{
        .name = try allocator.dupe(u8, "Doc"),
        .roles = .empty,
        .fields = .empty,
        .span = zeroSpan(),
    });
    try program.objects.items[0].fields.append(allocator, .{
        .name = try allocator.dupe(u8, "style"),
        .value_type = ast.Type.recordType("TextStyle"),
        .default_property_value = try allocator.dupe(u8, tagged_style_json),
        .span = zeroSpan(),
    });

    var ir = try core.Ir.init(allocator, asset_base_dir, project_path, project_source, program);
    program = ast.Program.init();
    errdefer ir.deinit();
    try ir.module_order.append(allocator, ir.project_module_id);
    return ir;
}

fn zeroSpan() ast.Span {
    return .{ .start = 0, .end = 0 };
}
