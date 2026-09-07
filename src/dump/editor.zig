const std = @import("std");
const core = @import("core");

const json = @import("utils").json;

pub fn writeVariablesField(allocator: std.mem.Allocator, root: *json.Object, state: *const core.DocumentState) !void {
    var variables = try root.arrayField("variables");
    for (state.definitions.items) |definition| {
        if (definition.kind != .variable) continue;
        const info = state.bindingTypeAt(definition.module_id, definition.span_start) orelse continue;
        var item = try variables.objectItem();
        try item.stringField("name", definition.name);
        const type_label = try info.ty.formatAlloc(allocator);
        defer allocator.free(type_label);
        try item.stringField("type", type_label);
        try item.optionalStringField("objectClass", if (info.object_class) |id| id.name else null);
        if (info.object_class) |id| try item.intField("objectClassModuleId", id.module_id);
        try item.intField("moduleId", definition.module_id);
        try item.enumTagField("scopeKind", definition.scope_kind);
        try item.optionalStringField("scopeName", definition.scope_name);
        try item.intField("spanStart", definition.span_start);
        try item.intField("spanEnd", definition.span_end);
        try item.intField("visibleStart", definition.visible_start);
        try item.intField("visibleEnd", definition.visible_end);
        try item.end();
    }
    try variables.end();
}

pub fn writeDefinitionsField(root: *json.Object, state: *core.DocumentState) !void {
    var definitions = try root.arrayField("definitions");
    for (state.definitions.items) |definition| {
        var item = try definitions.objectItem();
        try item.stringField("name", definition.name);
        try item.enumTagField("kind", definition.kind);
        try item.intField("line", definition.line);
        try item.intField("column", definition.column);
        try item.intField("length", definition.length);
        try item.intField("spanStart", definition.span_start);
        try item.intField("spanEnd", definition.span_end);
        try item.intField("visibleStart", definition.visible_start);
        try item.intField("visibleEnd", definition.visible_end);
        try item.intField("moduleId", definition.module_id);
        if (state.moduleById(definition.module_id)) |module| {
            try item.stringField("moduleSpec", module.spec);
            try item.enumTagField("moduleKind", module.kind);
        } else {
            try item.nullField("moduleSpec");
            try item.stringField("moduleKind", "unknown");
        }
        try item.optionalStringField("file", definition.file);
        try item.enumTagField("scopeKind", definition.scope_kind);
        try item.optionalStringField("scopeName", definition.scope_name);
        try item.end();
    }
    try definitions.end();
}
