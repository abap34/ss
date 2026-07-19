const std = @import("std");
const core = @import("core");
const ast = @import("ast");

const checker = @import("check.zig");
const semantic_env = @import("../language/env.zig");
const semantic_types = @import("types.zig");
const type_defs = @import("../language/type_defs.zig");

const SemanticEnv = semantic_env.SemanticEnv;
const TypeEnv = semantic_types.TypeEnv;
const continueAfterDiagnostic = checker.continueAfterDiagnostic;

fn appendFunctionDeclarations(
    functions: *core.FunctionMap,
    program: ast.Module,
    module_id: core.SourceModuleId,
) !void {
    for (program.functions.items) |func| {
        try functions.put(core.functionKey(module_id, func.name), func);
    }
}

fn appendConstDeclarations(
    constants: *core.ConstMap,
    program: ast.Module,
    module_id: core.SourceModuleId,
) !void {
    for (program.constants.items) |constant_decl| {
        try constants.put(core.constKey(module_id, constant_decl.name), constant_decl);
    }
}

pub fn checkTypeDeclarations(allocator: std.mem.Allocator, state: *core.DocumentState) !void {
    for (state.module_order.items) |module_id| {
        const module = state.moduleById(module_id) orelse continue;
        const origin_path = checker.originPathForModule(module);
        var names = std.StringHashMap([]const u8).init(allocator);
        defer names.deinit();

        for (module.syntax.objects.items) |object_decl| {
            if (isBuiltinTypeName(object_decl.name)) {
                const origin = try checker.sourceOrigin(allocator, origin_path, object_decl.span);
                defer allocator.free(origin);
                try state.addValidationDiagnostic(.@"error", null, null, origin, .{
                    .user_report = .{ .message = try std.fmt.allocPrint(state.allocator, "DuplicateType: type '{s}' conflicts with a built-in type", .{object_decl.name}) },
                });
                return error.UnknownType;
            }
            if (names.get(object_decl.name)) |existing_kind| {
                const origin = try checker.sourceOrigin(allocator, origin_path, object_decl.span);
                defer allocator.free(origin);
                try state.addValidationDiagnostic(.@"error", null, null, origin, .{
                    .user_report = .{ .message = try std.fmt.allocPrint(state.allocator, "DuplicateType: {s} type '{s}' is already defined in this module", .{ existing_kind, object_decl.name }) },
                });
                return error.UnknownType;
            }
            try names.put(object_decl.name, "object");
        }

        for (module.syntax.records.items) |record_decl| {
            if (isBuiltinTypeName(record_decl.name)) {
                const origin = try checker.sourceOrigin(allocator, origin_path, record_decl.span);
                defer allocator.free(origin);
                try state.addValidationDiagnostic(.@"error", null, null, origin, .{
                    .user_report = .{ .message = try std.fmt.allocPrint(state.allocator, "DuplicateType: type '{s}' conflicts with a built-in type", .{record_decl.name}) },
                });
                return error.UnknownType;
            }
            if (names.get(record_decl.name)) |existing_kind| {
                const origin = try checker.sourceOrigin(allocator, origin_path, record_decl.span);
                defer allocator.free(origin);
                try state.addValidationDiagnostic(.@"error", null, null, origin, .{
                    .user_report = .{ .message = try std.fmt.allocPrint(state.allocator, "DuplicateType: {s} type '{s}' is already defined in this module", .{ existing_kind, record_decl.name }) },
                });
                return error.UnknownType;
            }
            try names.put(record_decl.name, "record");
        }

        for (module.syntax.types.items) |decl| {
            if (isBuiltinTypeName(decl.name)) {
                const origin = try checker.sourceOrigin(allocator, origin_path, decl.span);
                defer allocator.free(origin);
                try state.addValidationDiagnostic(.@"error", null, null, origin, .{
                    .user_report = .{ .message = try std.fmt.allocPrint(state.allocator, "DuplicateType: type '{s}' conflicts with a built-in type", .{decl.name}) },
                });
                return error.UnknownType;
            }
            if (names.get(decl.name)) |existing_kind| {
                const origin = try checker.sourceOrigin(allocator, origin_path, decl.span);
                defer allocator.free(origin);
                try state.addValidationDiagnostic(.@"error", null, null, origin, .{
                    .user_report = .{ .message = try std.fmt.allocPrint(state.allocator, "DuplicateType: {s} type '{s}' is already defined in this module", .{ existing_kind, decl.name }) },
                });
                return error.UnknownType;
            }
            try names.put(decl.name, "enum");
            if (try type_defs.duplicateEnumCase(allocator, decl.cases.items)) |case_name| {
                const origin = try checker.sourceOrigin(allocator, origin_path, decl.span);
                defer allocator.free(origin);
                try state.addValidationDiagnostic(.@"error", null, null, origin, .{
                    .user_report = .{ .message = try std.fmt.allocPrint(state.allocator, "DuplicateEnumCase: enum '{s}' already has case '{s}'", .{ decl.name, case_name }) },
                });
                return error.UnknownType;
            }
        }
    }
}

fn isBuiltinTypeName(name: []const u8) bool {
    return semantic_env.isBuiltinTypeName(name);
}

pub fn checkTypeAnnotations(
    allocator: std.mem.Allocator,
    state: *core.DocumentState,
    sema: *const SemanticEnv,
) !void {
    var had_diagnostics = false;
    for (state.module_order.items) |module_id| {
        const module = state.moduleById(module_id) orelse continue;
        const origin_path = checker.originPathForModule(module);

        for (module.syntax.records.items) |record_decl| {
            for (record_decl.fields.items) |field| {
                const diagnostic_count = state.diagnostics.items.len;
                checkFieldTypeAnnotation(allocator, state, sema, module_id, origin_path, field) catch |err| {
                    try checker.continueAfterDiagnostic(state, diagnostic_count, err);
                    had_diagnostics = true;
                };
            }
        }
        for (module.syntax.objects.items) |object_decl| {
            for (object_decl.fields.items) |field| {
                const diagnostic_count = state.diagnostics.items.len;
                checkFieldTypeAnnotation(allocator, state, sema, module_id, origin_path, field) catch |err| {
                    try continueAfterDiagnostic(state, diagnostic_count, err);
                    had_diagnostics = true;
                };
            }
        }
        for (module.syntax.object_extensions.items) |extension| {
            for (extension.fields.items) |field| {
                const diagnostic_count = state.diagnostics.items.len;
                checkFieldTypeAnnotation(allocator, state, sema, module_id, origin_path, field) catch |err| {
                    try continueAfterDiagnostic(state, diagnostic_count, err);
                    had_diagnostics = true;
                };
            }
        }

        for (module.syntax.functions.items) |func| {
            const origin = try checker.sourceOrigin(allocator, origin_path, func.span);
            defer allocator.free(origin);
            for (func.params.items) |param| {
                const diagnostic_count = state.diagnostics.items.len;
                checkTypeAnnotation(state, sema, module_id, param.ty, origin) catch |err| {
                    try continueAfterDiagnostic(state, diagnostic_count, err);
                    had_diagnostics = true;
                };
                if (param.default_value) |default_value| {
                    const expr_diagnostic_count = state.diagnostics.items.len;
                    checkExprTypeAnnotations(allocator, state, sema, module_id, origin_path, default_value.*) catch |err| {
                        try continueAfterDiagnostic(state, expr_diagnostic_count, err);
                        had_diagnostics = true;
                    };
                }
            }
            const result_diagnostic_count = state.diagnostics.items.len;
            checkTypeAnnotation(state, sema, module_id, func.result_type, origin) catch |err| {
                try continueAfterDiagnostic(state, result_diagnostic_count, err);
                had_diagnostics = true;
            };
        }

        for (module.syntax.constants.items) |constant_decl| {
            const origin = try checker.sourceOrigin(allocator, origin_path, constant_decl.span);
            defer allocator.free(origin);
            const type_diagnostic_count = state.diagnostics.items.len;
            checkTypeAnnotation(state, sema, module_id, constant_decl.value_type, origin) catch |err| {
                try continueAfterDiagnostic(state, type_diagnostic_count, err);
                had_diagnostics = true;
            };
            const expr_diagnostic_count = state.diagnostics.items.len;
            checkExprTypeAnnotations(allocator, state, sema, module_id, origin_path, constant_decl.value) catch |err| {
                try continueAfterDiagnostic(state, expr_diagnostic_count, err);
                had_diagnostics = true;
            };
        }

        for (module.syntax.document_statements.items) |stmt| {
            const diagnostic_count = state.diagnostics.items.len;
            checkStatementTypeAnnotations(allocator, state, sema, module_id, origin_path, stmt) catch |err| {
                try continueAfterDiagnostic(state, diagnostic_count, err);
                had_diagnostics = true;
            };
        }
        for (module.syntax.pages.items) |page| {
            for (page.statements.items) |stmt| {
                const diagnostic_count = state.diagnostics.items.len;
                checkStatementTypeAnnotations(allocator, state, sema, module_id, origin_path, stmt) catch |err| {
                    try continueAfterDiagnostic(state, diagnostic_count, err);
                    had_diagnostics = true;
                };
            }
        }
    }
    if (had_diagnostics) return error.DiagnosticsFailed;
}

fn checkFieldTypeAnnotation(
    allocator: std.mem.Allocator,
    state: *core.DocumentState,
    sema: *const SemanticEnv,
    module_id: core.SourceModuleId,
    origin_path: []const u8,
    field: ast.ObjectFieldDecl,
) !void {
    const origin = try checker.sourceOrigin(allocator, origin_path, field.span);
    defer allocator.free(origin);
    var had_diagnostics = false;
    const type_diagnostic_count = state.diagnostics.items.len;
    checkTypeAnnotation(state, sema, module_id, field.value_type, origin) catch |err| {
        try continueAfterDiagnostic(state, type_diagnostic_count, err);
        had_diagnostics = true;
    };
    if (field.default_value) |default_value| {
        const expr_diagnostic_count = state.diagnostics.items.len;
        checkExprTypeAnnotations(allocator, state, sema, module_id, origin_path, default_value.*) catch |err| {
            try continueAfterDiagnostic(state, expr_diagnostic_count, err);
            had_diagnostics = true;
        };
    }
    if (had_diagnostics) return error.DiagnosticsFailed;
}

pub fn resolveTypeReferences(
    allocator: std.mem.Allocator,
    state: *core.DocumentState,
    sema: *const SemanticEnv,
) !void {
    for (state.modules.items) |*module| {
        try resolveModuleTypeReferences(allocator, &module.syntax, module.id, sema);
    }
}

fn resolveModuleTypeReferences(
    allocator: std.mem.Allocator,
    program: *ast.Module,
    module_id: core.SourceModuleId,
    sema: *const SemanticEnv,
) !void {
    for (program.records.items) |*record_decl| {
        for (record_decl.fields.items) |*field| {
            try resolveTypeReference(&field.value_type, module_id, sema);
            if (field.default_value) |default_value| try resolveExprTypeReferences(allocator, default_value, module_id, sema);
        }
    }
    for (program.objects.items) |*object_decl| {
        for (object_decl.fields.items) |*field| {
            try resolveTypeReference(&field.value_type, module_id, sema);
            if (field.default_value) |default_value| try resolveExprTypeReferences(allocator, default_value, module_id, sema);
        }
    }
    for (program.object_extensions.items) |*extension| {
        for (extension.fields.items) |*field| {
            try resolveTypeReference(&field.value_type, module_id, sema);
            if (field.default_value) |default_value| try resolveExprTypeReferences(allocator, default_value, module_id, sema);
        }
    }
    for (program.functions.items) |*func| {
        try resolveFunctionTypeReferences(allocator, func, module_id, sema);
    }
    for (program.constants.items) |*constant_decl| {
        try resolveTypeReference(&constant_decl.value_type, module_id, sema);
        try resolveExprTypeReferences(allocator, &constant_decl.value, module_id, sema);
    }
    for (program.document_statements.items) |*stmt| {
        try resolveStatementTypeReferences(allocator, stmt, module_id, sema);
    }
    for (program.pages.items) |*page| {
        for (page.statements.items) |*stmt| {
            try resolveStatementTypeReferences(allocator, stmt, module_id, sema);
        }
    }
}

fn resolveFunctionTypeReferences(
    allocator: std.mem.Allocator,
    func: *ast.FunctionDecl,
    module_id: core.SourceModuleId,
    sema: *const SemanticEnv,
) !void {
    for (func.params.items) |*param| {
        try resolveParamTypeReference(param, module_id, sema);
        if (param.default_value) |default_value| try resolveExprTypeReferences(allocator, default_value, module_id, sema);
    }
    try resolveTypeReference(&func.result_type, module_id, sema);
    for (func.statements.items) |*stmt| {
        try resolveStatementTypeReferences(allocator, stmt, module_id, sema);
    }
}

fn resolveStatementTypeReferences(
    allocator: std.mem.Allocator,
    stmt: *ast.Statement,
    module_id: core.SourceModuleId,
    sema: *const SemanticEnv,
) !void {
    switch (stmt.kind) {
        .hole => {},
        .let_binding => |*binding| {
            if (binding.type_annotation) |*annotation| try resolveTypeReference(annotation, module_id, sema);
            try resolveExprTypeReferences(allocator, &binding.expr, module_id, sema);
        },
        .return_expr => |*expr| try resolveExprTypeReferences(allocator, expr, module_id, sema),
        .return_void => {},
        .constrain => |*constraint| {
            if (constraint.offset) |*offset| try resolveExprTypeReferences(allocator, offset, module_id, sema);
        },
        .property_set => |*property_set| {
            try resolveExprTypeReferences(allocator, &property_set.target, module_id, sema);
            try resolveExprTypeReferences(allocator, &property_set.value, module_id, sema);
        },
        .if_stmt => |*if_stmt| {
            try resolveExprTypeReferences(allocator, &if_stmt.condition, module_id, sema);
            for (if_stmt.then_statements.items) |*nested| try resolveStatementTypeReferences(allocator, nested, module_id, sema);
            for (if_stmt.else_statements.items) |*nested| try resolveStatementTypeReferences(allocator, nested, module_id, sema);
        },
        .expr_stmt => |*expr| try resolveExprTypeReferences(allocator, expr, module_id, sema),
    }
}

fn resolveExprTypeReferences(
    allocator: std.mem.Allocator,
    expr: *ast.Expr,
    module_id: core.SourceModuleId,
    sema: *const SemanticEnv,
) !void {
    switch (expr.*) {
        .ident, .hole, .string, .color, .number, .boolean, .none, .enum_case => {},
        .call => |*call| {
            for (call.args.items) |*arg| try resolveExprTypeReferences(allocator, arg, module_id, sema);
        },
        .apply => |*apply| {
            try resolveExprTypeReferences(allocator, apply.callee, module_id, sema);
            for (apply.args.items) |*arg| try resolveExprTypeReferences(allocator, arg, module_id, sema);
        },
        .lambda => |*lambda| {
            for (lambda.params.items) |*param| try resolveParamTypeReference(param, module_id, sema);
            try resolveExprTypeReferences(allocator, lambda.body, module_id, sema);
        },
        .record => |*record| {
            try resolveRecordTypeName(allocator, module_id, sema, record);
            for (record.fields.items) |*field| try resolveExprTypeReferences(allocator, &field.value, module_id, sema);
        },
        .record_update => |*update| {
            try resolveExprTypeReferences(allocator, update.target, module_id, sema);
            for (update.fields.items) |*field| try resolveExprTypeReferences(allocator, &field.value, module_id, sema);
        },
        .member => |*member| try resolveExprTypeReferences(allocator, member.target, module_id, sema),
        .optional_check => |*check| try resolveExprTypeReferences(allocator, check.target, module_id, sema),
        .coalesce => |*coalesce| {
            try resolveExprTypeReferences(allocator, coalesce.target, module_id, sema);
            try resolveExprTypeReferences(allocator, coalesce.fallback, module_id, sema);
        },
    }
}

pub fn resolveEnumCaseExpressionsAndDefaults(
    allocator: std.mem.Allocator,
    state: *core.DocumentState,
    sema: *const SemanticEnv,
) !void {
    for (state.modules.items) |*module| {
        try resolveModuleEnumCasesAndDefaults(allocator, module.id, sema, &module.syntax);
    }
}

fn resolveModuleEnumCasesAndDefaults(
    allocator: std.mem.Allocator,
    module_id: core.SourceModuleId,
    sema: *const SemanticEnv,
    program: *ast.Module,
) !void {
    for (program.objects.items) |*object_decl| {
        try resolveObjectFieldEnumCasesAndDefaults(allocator, module_id, sema, object_decl.fields.items);
    }
    for (program.records.items) |*record_decl| {
        try resolveObjectFieldEnumCasesAndDefaults(allocator, module_id, sema, record_decl.fields.items);
    }
    for (program.object_extensions.items) |*extension| {
        try resolveObjectFieldEnumCasesAndDefaults(allocator, module_id, sema, extension.fields.items);
    }
    for (program.functions.items) |*func| {
        try resolveFunctionEnumCases(allocator, module_id, sema, func);
    }
    for (program.constants.items) |*constant_decl| {
        var env = TypeEnv.init(allocator);
        defer env.deinit();
        try resolveExprEnumCases(allocator, module_id, sema, &env, &constant_decl.value);
    }
    {
        var env = TypeEnv.init(allocator);
        defer env.deinit();
        for (program.document_statements.items) |*stmt| {
            try resolveStatementEnumCases(allocator, module_id, sema, &env, stmt);
        }
    }
    for (program.pages.items) |*page| {
        var env = TypeEnv.init(allocator);
        defer env.deinit();
        for (page.statements.items) |*stmt| {
            try resolveStatementEnumCases(allocator, module_id, sema, &env, stmt);
        }
    }
}

fn resolveObjectFieldEnumCasesAndDefaults(
    allocator: std.mem.Allocator,
    module_id: core.SourceModuleId,
    sema: *const SemanticEnv,
    fields_list: []ast.ObjectFieldDecl,
) !void {
    for (fields_list) |*field| {
        const default_value = field.default_value orelse {
            try setDefaultPropertyValue(allocator, field, null);
            continue;
        };
        var env = TypeEnv.init(allocator);
        defer env.deinit();
        try resolveExprEnumCases(allocator, module_id, sema, &env, default_value);
        try setDefaultPropertyValue(allocator, field, try staticDefaultPropertyValue(allocator, sema, module_id, default_value.*));
    }
}

fn setDefaultPropertyValue(
    allocator: std.mem.Allocator,
    field: *ast.ObjectFieldDecl,
    maybe_value: ?[]const u8,
) !void {
    if (field.default_property_value) |value| allocator.free(value);
    field.default_property_value = maybe_value;
}

fn staticDefaultPropertyValue(
    allocator: std.mem.Allocator,
    sema: *const SemanticEnv,
    module_id: core.SourceModuleId,
    expr: ast.Expr,
) !?[]const u8 {
    var value = (try staticPropertyValueFromExpr(allocator, sema, module_id, expr)) orelse return null;
    defer value.deinit(allocator);
    if (value == .none) return try allocator.dupe(u8, "none");
    const text = try core.value_text.propertyString(allocator, value);
    if (core.value_text.propertyStringNeedsFree(value)) return text;
    return try allocator.dupe(u8, text);
}

fn staticPropertyValueFromExpr(
    allocator: std.mem.Allocator,
    sema: *const SemanticEnv,
    module_id: core.SourceModuleId,
    expr: ast.Expr,
) anyerror!?core.Value {
    return switch (expr) {
        .string => |literal| .{ .string = literal.text },
        .color => |text| .{ .string = text },
        .number => |value| .{ .number = value },
        .boolean => |value| .{ .boolean = value },
        .none => .{ .none = {} },
        .enum_case => |case| .{ .enum_case = .{
            .enum_name = case.enum_name,
            .case_name = case.case_name,
        } },
        .record => |record| try staticRecordPropertyValue(allocator, sema, module_id, record),
        .call => |call| staticNumericPropertyValue(call),
        else => null,
    };
}

fn staticRecordPropertyValue(
    allocator: std.mem.Allocator,
    sema: *const SemanticEnv,
    module_id: core.SourceModuleId,
    record_expr: ast.RecordExpr,
) anyerror!?core.Value {
    var record = core.RecordValue.init(record_expr.type_name);
    errdefer record.deinit(allocator);

    if (sema.declarations) |index| {
        for (index.record_fields.items) |field| {
            if (!std.mem.eql(u8, field.record_name, record_expr.type_name)) continue;
            const default_value = field.default_value orelse continue;
            var value = (try staticPropertyValueFromExpr(allocator, sema, field.module_id, default_value.*)) orelse {
                record.deinit(allocator);
                return null;
            };
            errdefer value.deinit(allocator);
            try putStaticRecordFieldValue(allocator, &record, field.name, value, false);
        }
    }

    for (record_expr.fields.items) |field| {
        var value = (try staticPropertyValueFromExpr(allocator, sema, module_id, field.value)) orelse {
            record.deinit(allocator);
            return null;
        };
        errdefer value.deinit(allocator);
        try putStaticRecordFieldValue(allocator, &record, field.name, value, true);
    }
    return .{ .record = record };
}

fn putStaticRecordFieldValue(
    allocator: std.mem.Allocator,
    record: *core.RecordValue,
    name: []const u8,
    value: core.Value,
    explicit: bool,
) !void {
    var owned = value;
    errdefer owned.deinit(allocator);
    for (record.fields.items) |*field| {
        if (!std.mem.eql(u8, field.name, name)) continue;
        field.value.deinit(allocator);
        field.value = owned;
        field.explicit = explicit;
        return;
    }
    try record.fields.append(allocator, .{
        .name = name,
        .value = owned,
        .explicit = explicit,
    });
}

fn staticNumericPropertyValue(call: ast.CallExpr) ?core.Value {
    if (!std.mem.eql(u8, call.callee.name, "neg") or call.args.items.len != 1) return null;
    return switch (call.args.items[0]) {
        .number => |value| .{ .number = -value },
        else => null,
    };
}

fn resolveRecordTypeName(
    allocator: std.mem.Allocator,
    module_id: core.SourceModuleId,
    sema: *const SemanticEnv,
    record: *ast.RecordExpr,
) !void {
    const resolved = sema.resolveTypeNameInContext(module_id, record.type_name) orelse return;
    const resolved_name = switch (resolved.kind) {
        .record, .object => resolved.class_name orelse return,
        .enum_type => resolved.enum_name orelse return,
        else => return,
    };
    if (std.mem.eql(u8, record.type_name, resolved_name)) return;
    const owned_name = try allocator.dupe(u8, resolved_name);
    allocator.free(record.type_name);
    record.type_name = owned_name;
}

fn resolveFunctionEnumCases(
    allocator: std.mem.Allocator,
    module_id: core.SourceModuleId,
    sema: *const SemanticEnv,
    func: *ast.FunctionDecl,
) !void {
    var env = TypeEnv.init(allocator);
    defer env.deinit();
    for (func.params.items) |*param| {
        if (param.default_value) |default_value| {
            try resolveExprEnumCases(allocator, module_id, sema, &env, default_value);
        }
        try env.put(param.name, semantic_types.infoFromType(param.ty));
    }
    for (func.statements.items) |*stmt| {
        try resolveStatementEnumCases(allocator, module_id, sema, &env, stmt);
    }
}

fn resolveStatementEnumCases(
    allocator: std.mem.Allocator,
    module_id: core.SourceModuleId,
    sema: *const SemanticEnv,
    env: *TypeEnv,
    stmt: *ast.Statement,
) !void {
    switch (stmt.kind) {
        .hole => {},
        .let_binding => |*binding| {
            try resolveExprEnumCases(allocator, module_id, sema, env, &binding.expr);
            const info = if (binding.type_annotation) |annotation|
                semantic_types.infoFromType(annotation)
            else
                semantic_types.infoFromType(ast.Type.any);
            try env.put(binding.name, info);
        },
        .return_expr => |*expr| try resolveExprEnumCases(allocator, module_id, sema, env, expr),
        .return_void => {},
        .constrain => |*constraint| {
            if (constraint.offset) |*offset| try resolveExprEnumCases(allocator, module_id, sema, env, offset);
        },
        .property_set => |*property_set| {
            try resolveExprEnumCases(allocator, module_id, sema, env, &property_set.target);
            try resolveExprEnumCases(allocator, module_id, sema, env, &property_set.value);
        },
        .if_stmt => |*if_stmt| {
            try resolveExprEnumCases(allocator, module_id, sema, env, &if_stmt.condition);
            var then_env = try env.clone();
            defer then_env.deinit();
            for (if_stmt.then_statements.items) |*nested| try resolveStatementEnumCases(allocator, module_id, sema, &then_env, nested);
            var else_env = try env.clone();
            defer else_env.deinit();
            for (if_stmt.else_statements.items) |*nested| try resolveStatementEnumCases(allocator, module_id, sema, &else_env, nested);
        },
        .expr_stmt => |*expr| try resolveExprEnumCases(allocator, module_id, sema, env, expr),
    }
}

fn resolveExprEnumCases(
    allocator: std.mem.Allocator,
    module_id: core.SourceModuleId,
    sema: *const SemanticEnv,
    env: *TypeEnv,
    expr: *ast.Expr,
) !void {
    switch (expr.*) {
        .ident, .hole, .string, .color, .number, .boolean, .none, .enum_case => {},
        .call => |*call| {
            for (call.args.items) |*arg| try resolveExprEnumCases(allocator, module_id, sema, env, arg);
        },
        .apply => |*apply| {
            try resolveExprEnumCases(allocator, module_id, sema, env, apply.callee);
            for (apply.args.items) |*arg| try resolveExprEnumCases(allocator, module_id, sema, env, arg);
        },
        .lambda => |*lambda| {
            var local_env = try env.clone();
            defer local_env.deinit();
            for (lambda.params.items) |*param| {
                if (param.default_value) |default_value| try resolveExprEnumCases(allocator, module_id, sema, &local_env, default_value);
                try local_env.put(param.name, semantic_types.infoFromType(param.ty));
            }
            try resolveExprEnumCases(allocator, module_id, sema, &local_env, lambda.body);
        },
        .member => |*member| {
            if (try resolveMemberAsEnumCase(allocator, module_id, sema, env, expr, member)) return;
            try resolveExprEnumCases(allocator, module_id, sema, env, member.target);
        },
        .record => |*record| {
            for (record.fields.items) |*field| try resolveExprEnumCases(allocator, module_id, sema, env, &field.value);
        },
        .record_update => |*update| {
            try resolveExprEnumCases(allocator, module_id, sema, env, update.target);
            for (update.fields.items) |*field| try resolveExprEnumCases(allocator, module_id, sema, env, &field.value);
        },
        .optional_check => |*check| try resolveExprEnumCases(allocator, module_id, sema, env, check.target),
        .coalesce => |*coalesce| {
            try resolveExprEnumCases(allocator, module_id, sema, env, coalesce.target);
            try resolveExprEnumCases(allocator, module_id, sema, env, coalesce.fallback);
        },
    }
}

fn resolveMemberAsEnumCase(
    allocator: std.mem.Allocator,
    module_id: core.SourceModuleId,
    sema: *const SemanticEnv,
    env: *const TypeEnv,
    expr: *ast.Expr,
    member: *ast.MemberExpr,
) !bool {
    switch (member.target.*) {
        .ident => |enum_ident| {
            const enum_name = enum_ident.name;
            const qualified = std.mem.indexOf(u8, enum_name, "::") != null;
            if (!qualified and (env.get(enum_name) != null or sema.function(enum_name) != null or sema.constant(enum_name) != null)) return false;
            const resolved = sema.resolveTypeNameInContext(module_id, enum_name) orelse return false;
            if (resolved.kind != .enum_type) return false;
            const resolved_enum_name = resolved.enum_name orelse return false;
            if (!sema.enumHasCase(module_id, resolved_enum_name, member.name)) return false;
            const target = member.target;
            const case_name = member.name;
            allocator.destroy(target);
            expr.* = .{ .enum_case = .{
                .enum_name = try allocator.dupe(u8, resolved_enum_name),
                .enum_name_span = enum_ident.name_span,
                .case_name = case_name,
                .case_name_span = member.name_span,
            } };
            allocator.free(enum_name);
            return true;
        },
        else => return false,
    }
}

fn resolveParamTypeReference(
    param: *ast.ParamDecl,
    module_id: core.SourceModuleId,
    sema: *const SemanticEnv,
) !void {
    try resolveTypeReference(&param.ty, module_id, sema);
}

fn resolveTypeReference(
    ty: *ast.Type,
    module_id: core.SourceModuleId,
    sema: *const SemanticEnv,
) !void {
    switch (ty.kind) {
        .object => if (ty.class_name) |name| {
            if (sema.resolveTypeNameInContext(module_id, name)) |resolved| {
                const class_name_span = ty.class_name_span;
                ty.* = resolved;
                switch (ty.kind) {
                    .object, .record => ty.class_name_span = class_name_span,
                    .enum_type => ty.enum_name_span = class_name_span,
                    else => {},
                }
            }
        },
        .selection => if (ty.param_class_name) |name| {
            if (sema.resolveTypeNameInContext(module_id, name)) |resolved| {
                const param_class_name_span = ty.param_class_name_span;
                if (resolved.kind == .object) ty.param_class_name = resolved.class_name;
                ty.param_class_name_span = param_class_name_span;
            }
        },
        .function => {
            for (ty.fn_params) |*param| try resolveTypeReference(param, module_id, sema);
            if (ty.fn_result) |result| try resolveTypeReference(result, module_id, sema);
        },
        .optional => if (ty.optional_child) |child| try resolveTypeReference(child, module_id, sema),
        else => {},
    }
}

pub fn rebuildConstDeclarations(
    allocator: std.mem.Allocator,
    state: *core.DocumentState,
) !void {
    _ = allocator;
    state.constants.clearRetainingCapacity();
    for (state.module_order.items) |module_id| {
        const module = state.moduleById(module_id) orelse continue;
        try appendConstDeclarations(&state.constants, module.syntax, module.id);
    }
}

pub fn rebuildFunctionDeclarations(
    allocator: std.mem.Allocator,
    state: *core.DocumentState,
) !void {
    _ = allocator;
    state.functions.clearRetainingCapacity();
    for (state.module_order.items) |module_id| {
        const module = state.moduleById(module_id) orelse continue;
        try appendFunctionDeclarations(&state.functions, module.syntax, module.id);
    }
}

fn checkStatementTypeAnnotations(
    allocator: std.mem.Allocator,
    state: *core.DocumentState,
    sema: *const SemanticEnv,
    module_id: core.SourceModuleId,
    origin_path: []const u8,
    stmt: ast.Statement,
) !void {
    switch (stmt.kind) {
        .hole => {},
        .let_binding => |binding| {
            const origin = try checker.sourceOrigin(allocator, origin_path, stmt.span);
            defer allocator.free(origin);
            var had_diagnostics = false;
            if (binding.type_annotation) |annotation| {
                const diagnostic_count = state.diagnostics.items.len;
                checkTypeAnnotation(state, sema, module_id, annotation, origin) catch |err| {
                    try continueAfterDiagnostic(state, diagnostic_count, err);
                    had_diagnostics = true;
                };
            }
            const expr_diagnostic_count = state.diagnostics.items.len;
            checkExprTypeAnnotations(allocator, state, sema, module_id, origin_path, binding.expr) catch |err| {
                try continueAfterDiagnostic(state, expr_diagnostic_count, err);
                had_diagnostics = true;
            };
            if (had_diagnostics) return error.DiagnosticsFailed;
        },
        .return_expr => |expr| try checkExprTypeAnnotations(allocator, state, sema, module_id, origin_path, expr),
        .return_void => {},
        .property_set => |property_set| {
            try checkExprTypeAnnotations(allocator, state, sema, module_id, origin_path, property_set.target);
            try checkExprTypeAnnotations(allocator, state, sema, module_id, origin_path, property_set.value);
        },
        .if_stmt => |if_stmt| {
            try checkExprTypeAnnotations(allocator, state, sema, module_id, origin_path, if_stmt.condition);
            var had_diagnostics = false;
            for (if_stmt.then_statements.items) |nested| {
                const diagnostic_count = state.diagnostics.items.len;
                checkStatementTypeAnnotations(allocator, state, sema, module_id, origin_path, nested) catch |err| {
                    try continueAfterDiagnostic(state, diagnostic_count, err);
                    had_diagnostics = true;
                };
            }
            for (if_stmt.else_statements.items) |nested| {
                const diagnostic_count = state.diagnostics.items.len;
                checkStatementTypeAnnotations(allocator, state, sema, module_id, origin_path, nested) catch |err| {
                    try continueAfterDiagnostic(state, diagnostic_count, err);
                    had_diagnostics = true;
                };
            }
            if (had_diagnostics) return error.DiagnosticsFailed;
        },
        .expr_stmt => |expr| try checkExprTypeAnnotations(allocator, state, sema, module_id, origin_path, expr),
        .constrain => |constraint| {
            if (constraint.offset) |expr| try checkExprTypeAnnotations(allocator, state, sema, module_id, origin_path, expr);
        },
    }
}

fn checkExprTypeAnnotations(
    allocator: std.mem.Allocator,
    state: *core.DocumentState,
    sema: *const SemanticEnv,
    module_id: core.SourceModuleId,
    origin_path: []const u8,
    expr: ast.Expr,
) !void {
    switch (expr) {
        .ident, .hole, .string, .color, .number, .boolean, .none, .enum_case => {},
        .call => |call| {
            var had_diagnostics = false;
            for (call.args.items) |arg| {
                const diagnostic_count = state.diagnostics.items.len;
                checkExprTypeAnnotations(allocator, state, sema, module_id, origin_path, arg) catch |err| {
                    try continueAfterDiagnostic(state, diagnostic_count, err);
                    had_diagnostics = true;
                };
            }
            if (had_diagnostics) return error.DiagnosticsFailed;
        },
        .apply => |apply| {
            try checkExprTypeAnnotations(allocator, state, sema, module_id, origin_path, apply.callee.*);
            var had_diagnostics = false;
            for (apply.args.items) |arg| {
                const diagnostic_count = state.diagnostics.items.len;
                checkExprTypeAnnotations(allocator, state, sema, module_id, origin_path, arg) catch |err| {
                    try continueAfterDiagnostic(state, diagnostic_count, err);
                    had_diagnostics = true;
                };
            }
            if (had_diagnostics) return error.DiagnosticsFailed;
        },
        .lambda => |lambda| {
            const origin = try checker.sourceOrigin(allocator, origin_path, lambda.span);
            defer allocator.free(origin);
            var had_diagnostics = false;
            for (lambda.params.items) |param| {
                const diagnostic_count = state.diagnostics.items.len;
                checkTypeAnnotation(state, sema, module_id, param.ty, origin) catch |err| {
                    try continueAfterDiagnostic(state, diagnostic_count, err);
                    had_diagnostics = true;
                };
            }
            const body_diagnostic_count = state.diagnostics.items.len;
            checkExprTypeAnnotations(allocator, state, sema, module_id, origin_path, lambda.body.*) catch |err| {
                try continueAfterDiagnostic(state, body_diagnostic_count, err);
                had_diagnostics = true;
            };
            if (had_diagnostics) return error.DiagnosticsFailed;
        },
        .record => |record| {
            var had_diagnostics = false;
            for (record.fields.items) |field| {
                const diagnostic_count = state.diagnostics.items.len;
                checkExprTypeAnnotations(allocator, state, sema, module_id, origin_path, field.value) catch |err| {
                    try continueAfterDiagnostic(state, diagnostic_count, err);
                    had_diagnostics = true;
                };
            }
            if (had_diagnostics) return error.DiagnosticsFailed;
        },
        .record_update => |update| {
            try checkExprTypeAnnotations(allocator, state, sema, module_id, origin_path, update.target.*);
            var had_diagnostics = false;
            for (update.fields.items) |field| {
                const diagnostic_count = state.diagnostics.items.len;
                checkExprTypeAnnotations(allocator, state, sema, module_id, origin_path, field.value) catch |err| {
                    try continueAfterDiagnostic(state, diagnostic_count, err);
                    had_diagnostics = true;
                };
            }
            if (had_diagnostics) return error.DiagnosticsFailed;
        },
        .member => |member| try checkExprTypeAnnotations(allocator, state, sema, module_id, origin_path, member.target.*),
        .optional_check => |check| try checkExprTypeAnnotations(allocator, state, sema, module_id, origin_path, check.target.*),
        .coalesce => |coalesce| {
            try checkExprTypeAnnotations(allocator, state, sema, module_id, origin_path, coalesce.target.*);
            try checkExprTypeAnnotations(allocator, state, sema, module_id, origin_path, coalesce.fallback.*);
        },
    }
}

fn checkTypeAnnotation(
    state: *core.DocumentState,
    sema: *const SemanticEnv,
    module_id: core.SourceModuleId,
    ty: ast.Type,
    origin: []const u8,
) !void {
    if (ty.kind == .enum_type or ty.kind == .color or ty.kind == .none or ty.kind == .hole) return;
    if (ty.kind == .optional) {
        if (ty.optional_child) |child| try checkTypeAnnotation(state, sema, module_id, child.*, origin);
        return;
    }
    if (ty.kind == .record) {
        const record_name = ty.class_name orelse return;
        if (!sema.recordExists(record_name)) return reportUnknownType(state, origin, record_name);
    } else if (ty.class_name) |class_name| {
        if (!sema.classExists(class_name)) {
            return reportUnknownType(state, origin, class_name);
        }
    }
    if (ty.param_class_name) |class_name| {
        if (!sema.classExists(class_name)) return reportUnknownType(state, origin, class_name);
    }
    if (ty.kind == .function) {
        var had_diagnostics = false;
        for (ty.fn_params) |param| {
            const diagnostic_count = state.diagnostics.items.len;
            checkTypeAnnotation(state, sema, module_id, param, origin) catch |err| {
                try continueAfterDiagnostic(state, diagnostic_count, err);
                had_diagnostics = true;
            };
        }
        if (ty.fn_result) |result| {
            const diagnostic_count = state.diagnostics.items.len;
            checkTypeAnnotation(state, sema, module_id, result.*, origin) catch |err| {
                try continueAfterDiagnostic(state, diagnostic_count, err);
                had_diagnostics = true;
            };
        }
        if (had_diagnostics) return error.DiagnosticsFailed;
    }
}

fn reportUnknownType(state: *core.DocumentState, origin: []const u8, type_name: []const u8) !void {
    try state.addValidationDiagnostic(.@"error", null, null, origin, .{
        .user_report = .{ .message = try std.fmt.allocPrint(state.allocator, "UnknownType: unknown type: {s}", .{type_name}) },
    });
    return error.UnknownType;
}

pub fn checkDuplicateValueDeclarations(
    allocator: std.mem.Allocator,
    state: *core.DocumentState,
) !void {
    for (state.module_order.items) |module_id| {
        const module = state.moduleById(module_id) orelse continue;
        var names = std.StringHashMap(void).init(allocator);
        defer names.deinit();
        const origin_path = checker.originPathForModule(module);
        for (module.syntax.functions.items) |func| {
            if (names.contains(func.name)) {
                const origin = try checker.sourceOrigin(allocator, origin_path, func.span);
                defer allocator.free(origin);
                try state.addValidationDiagnostic(.@"error", null, null, origin, .{
                    .user_report = .{ .message = try std.fmt.allocPrint(state.allocator, "DuplicateFunction: function '{s}' is already defined in this module", .{func.name}) },
                });
                return error.DiagnosticsFailed;
            }
            try names.put(func.name, {});
        }
        for (module.syntax.constants.items) |constant_decl| {
            if (names.contains(constant_decl.name)) {
                const origin = try checker.sourceOrigin(allocator, origin_path, constant_decl.span);
                defer allocator.free(origin);
                try state.addValidationDiagnostic(.@"error", null, null, origin, .{
                    .user_report = .{ .message = try std.fmt.allocPrint(state.allocator, "DuplicateValue: value '{s}' is already defined in this module", .{constant_decl.name}) },
                });
                return error.DiagnosticsFailed;
            }
            try names.put(constant_decl.name, {});
        }
    }
}
