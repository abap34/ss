const std = @import("std");
const core = @import("core");

const json = @import("utils").json;

pub fn writeField(root: *json.Object, allocator: std.mem.Allocator, state: *core.DocumentState) !void {
    const index = state.declaration_index;

    var object = try root.objectField("declarations");

    var types = try object.arrayField("types");
    for (index.types.items) |ty| {
        var item = try types.objectItem();
        try item.stringField("name", ty.name);
        try writeEnumCasesField(&item, "cases", ty.cases);
        try item.intField("moduleId", ty.module_id);
        try item.end();
    }
    try types.end();

    var records = try object.arrayField("records");
    for (index.records.items) |record| {
        var item = try records.objectItem();
        try item.stringField("name", record.name);
        try item.intField("moduleId", record.module_id);
        try item.end();
    }
    try records.end();

    var record_fields = try object.arrayField("recordFields");
    for (index.record_fields.items) |field| {
        var item = try record_fields.objectItem();
        const type_label = try field.value_type.formatAlloc(allocator);
        defer allocator.free(type_label);
        try item.stringField("name", field.name);
        try item.stringField("record", field.record_name);
        try item.stringField("type", type_label);
        try item.optionalStringField("defaultProperty", field.default_property_value);
        try item.intField("moduleId", field.module_id);
        try item.end();
    }
    try record_fields.end();

    try object.end();
}

fn writeEnumCasesField(object: *json.Object, name: []const u8, values: anytype) !void {
    var array = try object.arrayField(name);
    for (values) |value| try array.stringItem(value.name);
    try array.end();
}
