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
    var definition_iterator = ir.definitions.iterator();
    while (definition_iterator.next()) |entry| {
        var item = try definitions.objectItem();
        try item.stringField("name", entry.key_ptr.*);
        try item.enumTagField("kind", entry.value_ptr.kind);
        try item.intField("line", entry.value_ptr.line);
        try item.intField("column", entry.value_ptr.column);
        try item.intField("length", entry.value_ptr.length);
        try item.intField("moduleId", entry.value_ptr.module_id);
        if (ir.moduleById(entry.value_ptr.module_id)) |module| {
            try item.stringField("moduleSpec", module.spec);
            try item.enumTagField("moduleKind", module.kind);
        } else {
            try item.nullField("moduleSpec");
            try item.stringField("moduleKind", "unknown");
        }
        try item.optionalStringField("file", entry.value_ptr.file);
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
