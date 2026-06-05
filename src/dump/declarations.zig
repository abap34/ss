const std = @import("std");
const core = @import("core");

const declarations = @import("../language/declarations.zig");
const json = @import("utils").json;

pub fn writeField(root: *json.Object, allocator: std.mem.Allocator, ir: *core.Ir) !void {
    var index = try declarations.build(allocator, ir);
    defer index.deinit();

    var object = try root.objectField("declarations");

    var types = try object.arrayField("types");
    for (index.types.items) |ty| {
        var item = try types.objectItem();
        try item.stringField("name", ty.name);
        try item.stringField("body", ty.body);
        try item.intField("moduleId", ty.module_id);
        try item.end();
    }
    try types.end();

    var classes = try object.arrayField("classes");
    for (index.classes.items) |class| {
        var item = try classes.objectItem();
        try item.stringField("name", class.name);
        try item.optionalStringField("base", class.base);
        try item.intField("moduleId", class.module_id);
        try item.end();
    }
    try classes.end();

    var roles = try object.arrayField("roles");
    for (index.roles.items) |role| {
        var item = try roles.objectItem();
        try item.stringField("name", role.name);
        try item.stringField("class", role.class_name);
        try item.intField("moduleId", role.module_id);
        try item.end();
    }
    try roles.end();

    var fields = try object.arrayField("fields");
    for (index.fields.items) |field| {
        var item = try fields.objectItem();
        try item.stringField("name", field.name);
        try item.stringField("class", field.class_name);
        try item.stringField("type", field.value_type);
        try item.optionalStringField("defaultProperty", field.default_property_value);
        try item.intField("moduleId", field.module_id);
        try item.end();
    }
    try fields.end();

    try object.end();
}
