const std = @import("std");
const core = @import("core");

const typecheck = @import("../analysis/typecheck.zig");
const json = @import("utils").json;

pub fn writeVariablesField(allocator: std.mem.Allocator, root: *json.Object, ir: *core.Ir) !void {
    var variables = try root.arrayField("variables");
    for (ir.modules.items) |module| {
        if (module.path == null) continue;
        var variable_infos = try typecheck.collectScopedVariableInfoFromProgram(allocator, &ir.functions, module.program, module.id, module.source.len, ir);
        defer variable_infos.deinit(allocator);
        for (variable_infos.items) |entry| {
            var item = try variables.objectItem();
            try item.stringField("name", entry.name);
            const type_label = try entry.info.ty.formatAlloc(allocator);
            defer allocator.free(type_label);
            try item.stringField("type", type_label);
            try item.optionalStringField("objectClass", entry.info.object_class);
            try item.intField("moduleId", entry.module_id);
            try item.enumTagField("scopeKind", entry.scope_kind);
            try item.optionalStringField("scopeName", entry.scope_name);
            try item.intField("spanStart", entry.span_start);
            try item.intField("spanEnd", entry.span_end);
            try item.intField("visibleStart", entry.visible_start);
            try item.intField("visibleEnd", entry.visible_end);
            try item.end();
        }
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
        try item.intField("visibleStart", definition.visible_start);
        try item.intField("visibleEnd", definition.visible_end);
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
