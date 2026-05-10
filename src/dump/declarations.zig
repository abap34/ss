const std = @import("std");
const ast = @import("ast");
const core = @import("core");

const declarations = @import("../language/declarations.zig");
const json = @import("utils").json;

pub fn writeField(root: *json.Object, allocator: std.mem.Allocator, ir: *core.Ir) !void {
    var index = try declarations.build(allocator, ir);
    defer index.deinit();

    var object = try root.objectField("declarations");

    var value_domains = try object.arrayField("valueDomains");
    for (index.value_domains.items) |domain| {
        var item = try value_domains.objectItem();
        try item.stringField("name", domain.name);
        try item.stringField("body", domain.body);
        try item.optionalStringField("refinement", domain.refinement);
        try item.intField("moduleId", domain.module_id);
        try item.end();
    }
    try value_domains.end();

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
        try item.optionalStringField("default", field.default_value);
        try item.intField("moduleId", field.module_id);
        try item.end();
    }
    try fields.end();

    var annotations = try object.arrayField("functionAnnotations");
    for (index.function_annotations.items) |annotation| {
        var item = try annotations.objectItem();
        try item.stringField("function", annotation.function_name);
        try item.stringField("annotation", annotation.annotation_name);
        try writeAnnotationArgs(&item, annotation.args);
        try item.intField("moduleId", annotation.module_id);
        try item.end();
    }
    try annotations.end();

    var removed_annotations = try object.arrayField("removedAnnotations");
    for (index.removed_annotations.items) |annotation| {
        var item = try removed_annotations.objectItem();
        try item.stringField("function", annotation.function_name);
        try item.stringField("annotation", annotation.annotation_name);
        try writeAnnotationArgs(&item, annotation.args);
        try item.intField("moduleId", annotation.module_id);
        try item.end();
    }
    try removed_annotations.end();

    var passes = try object.arrayField("passes");
    for (index.passes.items) |pass| {
        var item = try passes.objectItem();
        try item.stringField("id", pass.id);
        try item.stringField("function", pass.function_name);
        try item.stringField("slot", pass.slot_name);
        try item.optionalStringField("effects", pass.effects_text);
        try writeStringArrayField(&item, "after", pass.after);
        try writeStringArrayField(&item, "before", pass.before);
        try item.intField("moduleId", pass.module_id);
        try item.intField("sourceOrder", pass.source_order);
        try item.end();
    }
    try passes.end();

    var host_capabilities = try object.arrayField("hostCapabilities");
    for (index.host_capabilities.items) |capability| {
        var item = try host_capabilities.objectItem();
        try item.stringField("function", capability.function_name);
        try writeAnnotationArgs(&item, capability.args);
        try item.optionalStringField("effects", capability.effects_text);
        if (capability.cache) |cache| try writeAnnotationValue(&item, "cache", cache);
        try item.intField("moduleId", capability.module_id);
        try item.end();
    }
    try host_capabilities.end();

    var render_ops = try object.arrayField("renderOps");
    for (index.render_ops.items) |op| {
        var item = try render_ops.objectItem();
        try item.stringField("function", op.function_name);
        try writeAnnotationArgs(&item, op.args);
        try item.optionalStringField("effects", op.effects_text);
        try item.intField("moduleId", op.module_id);
        try item.end();
    }
    try render_ops.end();

    try object.end();
}

fn writeStringArrayField(object: *json.Object, name: []const u8, values: []const []const u8) !void {
    var array = try object.arrayField(name);
    for (values) |value| try array.stringItem(value);
    try array.end();
}

fn writeAnnotationArgs(object: *json.Object, args: []const ast.AnnotationArg) !void {
    var array = try object.arrayField("args");
    for (args) |arg| {
        var item = try array.objectItem();
        switch (arg) {
            .positional => |value| {
                try item.stringField("kind", "positional");
                try writeAnnotationValue(&item, "value", value);
            },
            .named => |named| {
                try item.stringField("kind", "named");
                try item.stringField("name", named.name);
                try writeAnnotationValue(&item, "value", named.value);
            },
        }
        try item.end();
    }
    try array.end();
}

fn writeAnnotationValue(object: *json.Object, field_name: []const u8, value: ast.AnnotationValue) !void {
    var value_object = try object.objectField(field_name);
    switch (value) {
        .ident => |text| {
            try value_object.stringField("kind", "ident");
            try value_object.stringField("value", text);
        },
        .string => |text| {
            try value_object.stringField("kind", "string");
            try value_object.stringField("value", text);
        },
        .expr => |expr| {
            try value_object.stringField("kind", "expr");
            try writeExprValue(&value_object, expr);
        },
        .list => |items| {
            try value_object.stringField("kind", "list");
            var array = try value_object.arrayField("items");
            for (items.items) |item| {
                var nested = try array.objectItem();
                try writeAnnotationValueInline(&nested, item);
                try nested.end();
            }
            try array.end();
        },
    }
    try value_object.end();
}

fn writeAnnotationValueInline(object: *json.Object, value: ast.AnnotationValue) !void {
    switch (value) {
        .ident => |text| {
            try object.stringField("kind", "ident");
            try object.stringField("value", text);
        },
        .string => |text| {
            try object.stringField("kind", "string");
            try object.stringField("value", text);
        },
        .expr => |expr| {
            try object.stringField("kind", "expr");
            try writeExprValue(object, expr);
        },
        .list => |items| {
            try object.stringField("kind", "list");
            var array = try object.arrayField("items");
            for (items.items) |item| {
                var nested = try array.objectItem();
                try writeAnnotationValueInline(&nested, item);
                try nested.end();
            }
            try array.end();
        },
    }
}

fn writeExprValue(object: *json.Object, expr: ast.Expr) !void {
    switch (expr) {
        .ident => |name| {
            try object.stringField("exprKind", "ident");
            try object.stringField("value", name);
        },
        .string => |text| {
            try object.stringField("exprKind", "string");
            try object.stringField("value", text);
        },
        .number => |number| {
            try object.stringField("exprKind", "number");
            try object.floatField("value", number, "{d:.4}");
        },
        .call => |call| {
            try object.stringField("exprKind", "call");
            try object.stringField("name", call.name);
        },
    }
}
