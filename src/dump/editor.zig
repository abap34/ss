const std = @import("std");
const core = @import("core");

const typecheck = @import("../analysis/typecheck.zig");
const json = @import("utils").json;

pub fn writeVariablesField(allocator: std.mem.Allocator, root: *json.Object, ir: *core.Ir) !void {
    var variables = try root.arrayField("variables");
    var variable_infos = try typecheck.collectVariableInfoFromProgram(allocator, &ir.functions, ir.projectProgram(), null);
    defer variable_infos.deinit();
    var variable_iterator = variable_infos.iterator();
    while (variable_iterator.next()) |entry| {
        var item = try variables.objectItem();
        try item.stringField("name", entry.key_ptr.*);
        const type_label = try entry.value_ptr.ty.formatAlloc(allocator);
        defer allocator.free(type_label);
        try item.stringField("type", type_label);
        try item.enumTagField("runtimeSort", entry.value_ptr.sort);
        try item.optionalStringField("objectClass", entry.value_ptr.object_class);
        try item.end();
    }
    try variables.end();
}

pub fn writeDefinitionsField(root: *json.Object, ir: *core.Ir) !void {
    var definitions = try root.arrayField("definitions");
    for (ir.definitions.items) |definition| {
        var item = try definitions.objectItem();
        try item.stringField("name", definition.name);
        try item.enumTagField("kind", definition.kind);
        try item.intField("line", definition.line);
        try item.intField("column", definition.column);
        try item.intField("length", definition.length);
        try item.intField("spanStart", definition.span_start);
        try item.intField("spanEnd", definition.span_end);
        try item.intField("moduleId", definition.module_id);
        if (ir.moduleById(definition.module_id)) |module| {
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

pub fn writeHintsField(root: *json.Object, hints: []const core.InlayHint) !void {
    var array = try root.arrayField("hints");
    for (hints) |hint| {
        var item = try array.objectItem();
        try item.intField("line", hint.line);
        try item.intField("column", hint.column);
        try item.stringField("label", hint.label);
        try item.enumTagField("kind", hint.kind);
        try item.intField("moduleId", hint.module_id);
        try item.optionalStringField("file", hint.file);
        try item.end();
    }
    try array.end();
}
