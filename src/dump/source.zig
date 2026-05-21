const std = @import("std");
const ast = @import("ast");
const core = @import("core");

const json = @import("utils").json;

pub fn writeModulesField(allocator: std.mem.Allocator, root: *json.Object, modules: []const core.SourceModule) !void {
    var array = try root.arrayField("modules");
    for (modules) |module| try writeModule(allocator, &array, module);
    try array.end();
}

fn writeModule(allocator: std.mem.Allocator, modules: *json.Array, module: core.SourceModule) !void {
    var item = try modules.objectItem();
    try item.intField("id", module.id);
    try item.enumTagField("kind", module.kind);
    try item.stringField("spec", module.spec);
    try item.optionalStringField("path", module.path);
    var imports = try item.arrayField("imports");
    for (module.program.imports.items, 0..) |import_decl, index| {
        var import_item = try imports.objectItem();
        try import_item.stringField("spec", import_decl.spec);
        try writeSpan(&import_item, import_decl.span);
        if (index < module.resolved_import_ids.items.len) {
            try import_item.intField("module_id", module.resolved_import_ids.items[index]);
        } else {
            try import_item.nullField("module_id");
        }
        try import_item.end();
    }
    try imports.end();
    try item.stringField("source", module.source);
    try writeProgram(allocator, &item, module.program);
    try item.end();
}

fn writeProgram(allocator: std.mem.Allocator, object: *json.Object, program: ast.Program) !void {
    var program_object = try object.objectField("program");

    var imports = try program_object.arrayField("imports");
    for (program.imports.items) |import_decl| {
        var item = try imports.objectItem();
        try item.stringField("spec", import_decl.spec);
        try writeSpan(&item, import_decl.span);
        try item.end();
    }
    try imports.end();

    var types = try program_object.arrayField("types");
    for (program.types.items) |type_decl| {
        var item = try types.objectItem();
        try item.stringField("name", type_decl.name);
        try item.stringField("body", type_decl.body);
        try item.optionalStringField("refinement", type_decl.refinement);
        try writeSpan(&item, type_decl.span);
        try item.end();
    }
    try types.end();

    var objects = try program_object.arrayField("objects");
    for (program.objects.items) |object_decl| try writeObjectDeclaration(&objects, object_decl);
    try objects.end();

    var object_extensions = try program_object.arrayField("objectExtensions");
    for (program.object_extensions.items) |extension| try writeObjectExtension(&object_extensions, extension);
    try object_extensions.end();

    var functions = try program_object.arrayField("functions");
    for (program.functions.items) |func| {
        var item = try functions.objectItem();
        try item.stringField("name", func.name);
        try item.enumTagField("kind", func.kind);
        try writeSpan(&item, func.span);
        const result_label = try func.result_type.formatAlloc(allocator);
        defer allocator.free(result_label);
        try item.stringField("resultType", result_label);
        try item.enumTagField("resultSort", func.result_sort);
        try item.optionalStringField("effects", func.effects);
        var annotations = try item.arrayField("annotations");
        for (func.annotations.items) |annotation| try writeAnnotation(&annotations, annotation);
        try annotations.end();
        var params = try item.arrayField("params");
        for (func.params.items) |param| {
            var param_item = try params.objectItem();
            try param_item.stringField("name", param.name);
            const param_label = try param.ty.formatAlloc(allocator);
            defer allocator.free(param_label);
            try param_item.stringField("type", param_label);
            try param_item.enumTagField("runtimeSort", param.sort);
            try param_item.end();
        }
        try params.end();
        var statements = try item.arrayField("statements");
        for (func.statements.items) |stmt| try writeStatement(allocator, &statements, stmt);
        try statements.end();
        try item.end();
    }
    try functions.end();

    var document_statements = try program_object.arrayField("documentStatements");
    for (program.document_statements.items) |stmt| try writeStatement(allocator, &document_statements, stmt);
    try document_statements.end();

    var pages = try program_object.arrayField("pages");
    for (program.pages.items) |page| {
        var item = try pages.objectItem();
        try item.stringField("name", page.name);
        var statements = try item.arrayField("statements");
        for (page.statements.items) |stmt| try writeStatement(allocator, &statements, stmt);
        try statements.end();
        try item.end();
    }
    try pages.end();
    try program_object.end();
}

fn writeObjectDeclaration(objects: *json.Array, object_decl: ast.ObjectDecl) !void {
    var item = try objects.objectItem();
    try item.stringField("name", object_decl.name);
    try item.optionalStringField("base", object_decl.base);
    try writeStringArrayField(&item, "roles", object_decl.roles.items);
    try writeObjectFieldsField(&item, object_decl.fields.items);
    try writeSpan(&item, object_decl.span);
    try item.end();
}

fn writeObjectExtension(extensions: *json.Array, extension: ast.ObjectExtensionDecl) !void {
    var item = try extensions.objectItem();
    try item.stringField("target", extension.target);
    try item.optionalStringField("implements", extension.implements);
    try writeStringArrayField(&item, "roles", extension.roles.items);
    try writeObjectFieldsField(&item, extension.fields.items);
    try writeSpan(&item, extension.span);
    try item.end();
}

fn writeObjectFieldsField(object: *json.Object, fields: []const ast.ObjectFieldDecl) !void {
    var array = try object.arrayField("fields");
    for (fields) |field| {
        var item = try array.objectItem();
        try item.stringField("name", field.name);
        try item.stringField("type", field.value_type);
        try item.optionalStringField("default", field.default_value);
        try writeSpan(&item, field.span);
        try item.end();
    }
    try array.end();
}

fn writeStringArrayField(object: *json.Object, name: []const u8, values: []const []const u8) !void {
    var array = try object.arrayField(name);
    for (values) |value| try array.stringItem(value);
    try array.end();
}

fn writeAnnotation(annotations: *json.Array, annotation: ast.Annotation) !void {
    var item = try annotations.objectItem();
    try item.stringField("name", annotation.name);
    try writeAnnotationArgs(&item, annotation.args.items);
    try writeSpan(&item, annotation.span);
    try item.end();
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
        .boolean => |boolean| {
            try object.stringField("exprKind", "boolean");
            try object.boolField("value", boolean);
        },
        .call => |call| {
            try object.stringField("exprKind", "call");
            try object.stringField("name", call.name);
        },
    }
}

fn writeSpan(object: *json.Object, span: ast.Span) !void {
    var span_object = try object.objectField("span");
    try span_object.intField("start", span.start);
    try span_object.intField("end", span.end);
    try span_object.end();
}

fn writeStatement(allocator: std.mem.Allocator, statements: *json.Array, stmt: ast.Statement) !void {
    var item = try statements.objectItem();
    try writeSpan(&item, stmt.span);
    switch (stmt.kind) {
        .let_binding => |binding| {
            try item.stringField("kind", "let_binding");
            try item.stringField("name", binding.name);
            try writeExpr(allocator, &item, "expr", binding.expr);
        },
        .return_expr => |expr| {
            try item.stringField("kind", "return_expr");
            try writeExpr(allocator, &item, "expr", expr);
        },
        .expr_stmt => |expr| {
            try item.stringField("kind", "expr_stmt");
            try writeExpr(allocator, &item, "expr", expr);
        },
        .constrain => |decl| {
            try item.stringField("kind", "constrain");
            try writeAnchorRef(&item, "target", decl.target);
            try writeAnchorRef(&item, "source", decl.source);
            if (decl.offset) |expr| {
                try writeExpr(allocator, &item, "offset", expr);
            } else {
                try item.nullField("offset");
            }
        },
        .property_set => |property_set| {
            try item.stringField("kind", "property_set");
            try item.stringField("object_name", property_set.object_name);
            try item.stringField("property_name", property_set.property_name);
            try writeExpr(allocator, &item, "value", property_set.value);
        },
        .if_stmt => |if_stmt| {
            try item.stringField("kind", "if_stmt");
            try writeExpr(allocator, &item, "condition", if_stmt.condition);
            var then_items = try item.arrayField("then");
            for (if_stmt.then_statements.items) |nested| try writeStatement(allocator, &then_items, nested);
            try then_items.end();
            var else_items = try item.arrayField("else");
            for (if_stmt.else_statements.items) |nested| try writeStatement(allocator, &else_items, nested);
            try else_items.end();
        },
    }
    try item.end();
}

fn writeAnchorRef(object: *json.Object, key: []const u8, anchor_ref: ast.AnchorRef) !void {
    var item = try object.objectField(key);
    try item.stringField("kind", @tagName(anchor_ref.kind));
    try item.enumTagField("anchor", anchor_ref.anchor);
    try item.optionalStringField("node_name", anchor_ref.node_name);
    try item.end();
}

fn writeExpr(allocator: std.mem.Allocator, object: *json.Object, key: []const u8, expr: ast.Expr) anyerror!void {
    var item = try object.objectField(key);
    try writeExprFields(allocator, &item, expr);
    try item.end();
}

fn writeExprItem(allocator: std.mem.Allocator, items: *json.Array, expr: ast.Expr) anyerror!void {
    var item = try items.objectItem();
    try writeExprFields(allocator, &item, expr);
    try item.end();
}

fn writeExprFields(allocator: std.mem.Allocator, item: *json.Object, expr: ast.Expr) anyerror!void {
    switch (expr) {
        .ident => |name| {
            try item.stringField("kind", "ident");
            try item.stringField("name", name);
        },
        .string => |text| {
            try item.stringField("kind", "string");
            try item.stringField("value", text);
        },
        .number => |value| {
            try item.stringField("kind", "number");
            try item.floatField("value", value, "{d:.4}");
        },
        .boolean => |value| {
            try item.stringField("kind", "boolean");
            try item.boolField("value", value);
        },
        .call => |call| {
            try item.stringField("kind", "call");
            try item.stringField("name", call.name);
            var args = try item.arrayField("args");
            for (call.args.items) |arg| try writeExprItem(allocator, &args, arg);
            try args.end();
        },
    }
}
