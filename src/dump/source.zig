const std = @import("std");
const ast = @import("ast");
const core = @import("core");

const json = @import("utils").json;

pub fn writeModulesField(allocator: std.mem.Allocator, root: *json.Object, modules: []const core.SourceModule) !void {
    var array = try root.arrayField("modules");
    for (modules) |module| try writeModule(allocator, &array, module, modules);
    try array.end();
}

fn writeModule(allocator: std.mem.Allocator, modules: *json.Array, module: core.SourceModule, all_modules: []const core.SourceModule) !void {
    var item = try modules.objectItem();
    try item.intField("id", module.id);
    try item.enumTagField("kind", module.kind);
    try item.stringField("spec", module.spec);
    try item.optionalStringField("path", module.path);
    var implicit_imports = try item.arrayField("implicitImports");
    for (module.implicit_import_ids.items) |module_id| {
        var import_item = try implicit_imports.objectItem();
        try import_item.intField("module_id", module_id);
        if (moduleSpecById(all_modules, module_id)) |spec| {
            try import_item.stringField("spec", spec);
        } else {
            try import_item.nullField("spec");
        }
        try import_item.end();
    }
    try implicit_imports.end();
    var imports = try item.arrayField("imports");
    for (module.program.imports.items, 0..) |import_decl, index| {
        var import_item = try imports.objectItem();
        try import_item.stringField("spec", import_decl.spec);
        try writeImportMode(&import_item, import_decl.mode);
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

fn moduleSpecById(modules: []const core.SourceModule, module_id: core.SourceModuleId) ?[]const u8 {
    for (modules) |module| {
        if (module.id == module_id) return module.spec;
    }
    return null;
}

fn writeProgram(allocator: std.mem.Allocator, object: *json.Object, program: ast.Program) !void {
    var program_object = try object.objectField("program");

    var imports = try program_object.arrayField("imports");
    for (program.imports.items) |import_decl| {
        var item = try imports.objectItem();
        try item.stringField("spec", import_decl.spec);
        try writeImportMode(&item, import_decl.mode);
        try writeSpan(&item, import_decl.span);
        try item.end();
    }
    try imports.end();

    var top_level_items = try program_object.arrayField("topLevelItems");
    for (program.top_level_items.items) |top_level_item| {
        var item = try top_level_items.objectItem();
        switch (top_level_item) {
            .import => |index| {
                try item.stringField("kind", "import");
                try item.intField("index", index);
            },
            .document => |index| {
                try item.stringField("kind", "document");
                try item.intField("index", index);
            },
            .page => |index| {
                try item.stringField("kind", "page");
                try item.intField("index", index);
            },
        }
        try item.end();
    }
    try top_level_items.end();

    var types = try program_object.arrayField("types");
    for (program.types.items) |type_decl| {
        var item = try types.objectItem();
        try item.stringField("name", type_decl.name);
        try writeStringArrayField(&item, "cases", type_decl.cases.items);
        try writeSpan(&item, type_decl.span);
        try item.end();
    }
    try types.end();

    var records = try program_object.arrayField("records");
    for (program.records.items) |record_decl| try writeRecordDeclaration(&records, record_decl);
    try records.end();

    var objects = try program_object.arrayField("objects");
    for (program.objects.items) |object_decl| try writeObjectDeclaration(&objects, object_decl);
    try objects.end();

    var object_extensions = try program_object.arrayField("objectExtensions");
    for (program.object_extensions.items) |extension| try writeObjectExtension(&object_extensions, extension);
    try object_extensions.end();

    var constants = try program_object.arrayField("constants");
    for (program.constants.items) |constant_decl| {
        var item = try constants.objectItem();
        try item.stringField("name", constant_decl.name);
        try writeSpan(&item, constant_decl.span);
        const value_label = try constant_decl.value_type.formatAlloc(allocator);
        defer allocator.free(value_label);
        try item.stringField("type", value_label);
        try writeExpr(allocator, &item, "value", constant_decl.value);
        try item.end();
    }
    try constants.end();

    var functions = try program_object.arrayField("functions");
    for (program.functions.items) |func| {
        var item = try functions.objectItem();
        try item.stringField("name", func.name);
        try writeSpan(&item, func.span);
        const result_label = try func.result_type.formatAlloc(allocator);
        defer allocator.free(result_label);
        try item.stringField("resultType", result_label);
        var params = try item.arrayField("params");
        for (func.params.items) |param| {
            var param_item = try params.objectItem();
            try param_item.stringField("name", param.name);
            const param_label = try param.ty.formatAlloc(allocator);
            defer allocator.free(param_label);
            try param_item.stringField("type", param_label);
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

    var document_blocks = try program_object.arrayField("documentBlocks");
    for (program.document_blocks.items) |block| {
        var item = try document_blocks.objectItem();
        try item.intField("statementStart", block.statement_start);
        try item.intField("statementCount", block.statement_count);
        try writeSpan(&item, block.span);
        try item.end();
    }
    try document_blocks.end();

    var pages = try program_object.arrayField("pages");
    for (program.pages.items) |page| {
        var item = try pages.objectItem();
        try item.stringField("name", page.name);
        try writeSpan(&item, page.span);
        var statements = try item.arrayField("statements");
        for (page.statements.items) |stmt| try writeStatement(allocator, &statements, stmt);
        try statements.end();
        try item.end();
    }
    try pages.end();
    try program_object.end();
}

fn writeImportMode(object: *json.Object, mode: ast.ImportDecl.Mode) !void {
    const mode_name = if (mode.alias != null and mode.unqualified)
        "alias_and_unqualified"
    else if (mode.alias != null)
        "alias"
    else
        "unqualified";
    try object.stringField("mode", mode_name);
    try object.optionalStringField("alias", mode.alias);
    try object.boolField("unqualified", mode.unqualified);
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

fn writeRecordDeclaration(records: *json.Array, record_decl: ast.RecordDecl) !void {
    var item = try records.objectItem();
    try item.stringField("name", record_decl.name);
    try writeObjectFieldsField(&item, record_decl.fields.items);
    try writeSpan(&item, record_decl.span);
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
        if (field.default_value) |default_value| {
            var default_object = try item.objectField("default");
            try writeExprValue(&default_object, default_value.*);
            try default_object.end();
        } else {
            try item.nullField("default");
        }
        try item.optionalStringField("defaultProperty", field.default_property_value);
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

fn writeExprValue(object: *json.Object, expr: ast.Expr) !void {
    switch (expr) {
        .ident => |name| {
            try object.stringField("exprKind", "ident");
            try object.stringField("value", name);
        },
        .string => |literal| {
            try object.stringField("exprKind", "string");
            try object.stringField("value", literal.text);
        },
        .color => |text| {
            try object.stringField("exprKind", "color");
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
        .none => {
            try object.stringField("exprKind", "none");
        },
        .call => |call| {
            try object.stringField("exprKind", "call");
            try object.stringField("name", call.callee.name);
            try object.optionalStringField("qualifier", call.callee.qualifier);
        },
        .apply => |apply| {
            try object.stringField("exprKind", "apply");
            var callee = try object.objectField("callee");
            try writeExprValue(&callee, apply.callee.*);
            try callee.end();
        },
        .lambda => |lambda| {
            try object.stringField("exprKind", "lambda");
            try object.intField("paramCount", lambda.params.items.len);
        },
        .record => |record| {
            try object.stringField("exprKind", "record");
            try object.stringField("type", record.type_name);
            try object.intField("fieldCount", record.fields.items.len);
        },
        .record_update => |update| {
            try object.stringField("exprKind", "record_update");
            try object.intField("fieldCount", update.fields.items.len);
        },
        .member => |member| {
            try object.stringField("exprKind", "member");
            try object.stringField("name", member.name);
        },
        .enum_case => |case| {
            try object.stringField("exprKind", "enum_case");
            try object.stringField("enum", case.enum_name);
            try object.stringField("case", case.case_name);
        },
        .optional_check => {
            try object.stringField("exprKind", "optional_check");
        },
        .coalesce => {
            try object.stringField("exprKind", "coalesce");
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
        .return_void => {
            try item.stringField("kind", "return_void");
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
        .string => |literal| {
            try item.stringField("kind", "string");
            try item.stringField("value", literal.text);
        },
        .color => |text| {
            try item.stringField("kind", "color");
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
        .none => {
            try item.stringField("kind", "none");
        },
        .call => |call| {
            try item.stringField("kind", "call");
            try item.stringField("name", call.callee.name);
            try item.optionalStringField("qualifier", call.callee.qualifier);
            var args = try item.arrayField("args");
            for (call.args.items) |arg| try writeExprItem(allocator, &args, arg);
            try args.end();
        },
        .apply => |apply| {
            try item.stringField("kind", "apply");
            try writeExpr(allocator, item, "callee", apply.callee.*);
            var args = try item.arrayField("args");
            for (apply.args.items) |arg| try writeExprItem(allocator, &args, arg);
            try args.end();
        },
        .lambda => |lambda| {
            try item.stringField("kind", "lambda");
            var params = try item.arrayField("params");
            for (lambda.params.items) |param| {
                var param_item = try params.objectItem();
                try param_item.stringField("name", param.name);
                const label = try param.ty.formatAlloc(allocator);
                defer allocator.free(label);
                try param_item.stringField("type", label);
                try param_item.end();
            }
            try params.end();
            try writeExpr(allocator, item, "body", lambda.body.*);
        },
        .record => |record| {
            try item.stringField("kind", "record");
            try item.stringField("type", record.type_name);
            var fields = try item.arrayField("fields");
            for (record.fields.items) |field| {
                var field_item = try fields.objectItem();
                try field_item.stringField("name", field.name);
                try writeExpr(allocator, &field_item, "value", field.value);
                try field_item.end();
            }
            try fields.end();
        },
        .record_update => |update| {
            try item.stringField("kind", "record_update");
            try writeExpr(allocator, item, "target", update.target.*);
            var fields = try item.arrayField("fields");
            for (update.fields.items) |field| {
                var field_item = try fields.objectItem();
                var path = try field_item.arrayField("path");
                for (field.path.items) |segment| try path.stringItem(segment);
                try path.end();
                try writeExpr(allocator, &field_item, "value", field.value);
                try field_item.end();
            }
            try fields.end();
        },
        .member => |member| {
            try item.stringField("kind", "member");
            try item.stringField("name", member.name);
            try writeExpr(allocator, item, "target", member.target.*);
        },
        .enum_case => |case| {
            try item.stringField("kind", "enum_case");
            try item.stringField("enum", case.enum_name);
            try item.stringField("case", case.case_name);
        },
        .optional_check => |check| {
            try item.stringField("kind", "optional_check");
            try writeExpr(allocator, item, "target", check.target.*);
        },
        .coalesce => |coalesce| {
            try item.stringField("kind", "coalesce");
            try writeExpr(allocator, item, "target", coalesce.target.*);
            try writeExpr(allocator, item, "fallback", coalesce.fallback.*);
        },
    }
}
