const std = @import("std");
const core = @import("core");
const ast = @import("ast");
const declarations = @import("../language/declarations.zig");
const language_names = @import("../language/names.zig");
const semantic_env = @import("../language/env.zig");
const module_loader = @import("../modules/loader.zig");
const calls = @import("calls.zig");
const checker = @import("check.zig");
const dependencies = @import("dependencies.zig");
const editor = @import("editor.zig");
const fields = @import("fields.zig");
const infer = @import("infer.zig");
const registry = @import("../language/registry.zig");
const analysis_scope = @import("scope.zig");
const semantic_types = @import("types.zig");
const syntax = @import("../syntax/parse.zig");
const type_defs = @import("../language/type_defs.zig");
const utils = @import("utils");
const SemanticEnv = semantic_env.SemanticEnv;

const TypeEnv = semantic_types.TypeEnv;
pub const VariableInfo = semantic_types.TypeInfo;
pub const ScopedVariableInfo = struct {
    name: []const u8,
    info: VariableInfo,
    module_id: core.SourceModuleId,
    scope_kind: core.DefinitionScopeKind,
    scope_name: ?[]const u8,
    span_start: usize,
    span_end: usize,
    visible_start: usize,
    visible_end: usize,
};
const ensureType = semantic_types.ensureType;
const inferExprInfo = infer.exprInfo;
pub const expectedPrimitiveArgType = infer.expectedPrimitiveArgType;

pub const ProgramIndex = struct {
    allocator: std.mem.Allocator,
    modules: std.ArrayList(core.SourceModule),
    module_order: std.ArrayList(core.SourceModuleId),
    project_implicit_import_ids: std.ArrayList(core.SourceModuleId),
    project_import_ids: std.ArrayList(core.SourceModuleId),
    functions: core.FunctionMap,

    pub fn deinit(self: *ProgramIndex) void {
        self.functions.deinit();
        for (self.modules.items) |*module| module.deinit(self.allocator);
        self.modules.deinit(self.allocator);
        self.module_order.deinit(self.allocator);
        self.project_implicit_import_ids.deinit(self.allocator);
        self.project_import_ids.deinit(self.allocator);
    }
};

pub const BuildIrOptions = struct {
    allow_diagnostics: bool = false,
};

pub fn collectFunctionsFromPrograms(
    allocator: std.mem.Allocator,
    programs: []const *const ast.Program,
) !core.FunctionMap {
    var functions = core.FunctionMap.init(allocator);
    for (programs, 0..) |program, module_index| {
        for (program.functions.items) |func| {
            try functions.put(core.functionKey(@intCast(module_index), func.name), func);
        }
    }
    return functions;
}

fn findModuleById(modules: []const core.SourceModule, module_id: core.SourceModuleId) ?core.SourceModule {
    for (modules) |module| {
        if (module.id == module_id) return module;
    }
    return null;
}

pub fn checkFunctionDefinitions(
    allocator: std.mem.Allocator,
    ir: *core.Ir,
    functions: *const core.FunctionMap,
) !void {
    const sema = SemanticEnv.init(ir, null, functions);
    try checkFunctionDefinitionsWithEnv(allocator, ir, &sema);
}

fn checkFunctionDefinitionsWithEnv(
    allocator: std.mem.Allocator,
    ir: *core.Ir,
    sema: *const SemanticEnv,
) !void {
    try calls.checkFunctionCallGraph(allocator, ir, sema);

    var it = sema.functions.iterator();
    while (it.next()) |entry| {
        const module_id = entry.key_ptr.module_id;
        const origin_path = blk: {
            if (ir.moduleById(module_id)) |module| break :blk checker.originPathForModule(module);
            break :blk "";
        };
        const module_sema = sema.forModule(module_id);
        try checker.checkFunction(allocator, ir, &module_sema, origin_path, entry.value_ptr.*);
    }
}

pub fn typecheckProgram(
    allocator: std.mem.Allocator,
    ir: *core.Ir,
) !void {
    var declaration_index = try declarations.build(allocator, ir);
    defer declaration_index.deinit();
    var sema = SemanticEnv.init(ir, &declaration_index, &ir.functions);

    try checkTypeDeclarations(allocator, ir);
    try resolveTypeReferences(allocator, ir, &sema);
    try resolveEnumCaseExpressionsAndDefaults(allocator, ir, &sema);
    const next_declaration_index = try declarations.build(allocator, ir);
    declaration_index.deinit();
    declaration_index = next_declaration_index;
    sema = SemanticEnv.init(ir, &declaration_index, &ir.functions);
    try rebuildFunctionDeclarations(allocator, ir);
    try checkDuplicateFunctionDeclarations(allocator, ir);
    try fields.checkObjectDeclarations(allocator, ir, &sema);
    try checkTypeAnnotations(allocator, ir, &sema);
    try checker.checkPageNamesUnique(allocator, ir);
    try checkPlacementEffectDeclarations(allocator, ir);
    try checkFunctionDefinitionsWithEnv(allocator, ir, &sema);
    for (ir.module_order.items) |module_id| {
        const module = ir.moduleById(module_id) orelse continue;
        const module_sema = sema.forModule(module_id);
        try checker.checkPageStatements(allocator, ir, &module_sema, checker.originPathForModule(module), module.program);
    }
}

fn checkPlacementEffectDeclarations(allocator: std.mem.Allocator, ir: *core.Ir) !void {
    var base_sema = SemanticEnv.init(ir, null, &ir.functions);
    var analyzer = dependencies.Analyzer.init(allocator, &base_sema);
    defer analyzer.deinit();
    var it = ir.functions.iterator();
    while (it.next()) |entry| {
        const func = entry.value_ptr.*;
        if (dependencies.callableNamePlacesObjects(func.name)) continue;
        const module_id = entry.key_ptr.module_id;
        analyzer.sema = base_sema.forModule(module_id);
        var summary = try analyzer.functionBody(func);
        defer summary.deinit();
        if (!summary.places_objects) continue;
        const origin = try functionOrigin(allocator, ir, module_id, func.name);
        defer allocator.free(origin);
        try ir.addValidationDiagnostic(.@"error", null, null, origin, .{
            .user_report = .{ .message = try std.fmt.allocPrint(ir.allocator, "PlacementEffect: function '{s}' calls a placing operation and must end with '!'", .{func.name}) },
        });
        return error.DiagnosticsFailed;
    }
}

fn checkTypeDeclarations(allocator: std.mem.Allocator, ir: *core.Ir) !void {
    for (ir.module_order.items) |module_id| {
        const module = ir.moduleById(module_id) orelse continue;
        const origin_path = checker.originPathForModule(module);
        var names = std.StringHashMap([]const u8).init(allocator);
        defer names.deinit();

        for (module.program.objects.items) |object_decl| {
            if (isBuiltinTypeName(object_decl.name)) {
                const origin = try originForModuleSpan(allocator, origin_path, object_decl.span);
                defer allocator.free(origin);
                try ir.addValidationDiagnostic(.@"error", null, null, origin, .{
                    .user_report = .{ .message = try std.fmt.allocPrint(ir.allocator, "DuplicateType: type '{s}' conflicts with a built-in type", .{object_decl.name}) },
                });
                return error.UnknownType;
            }
            if (names.get(object_decl.name)) |existing_kind| {
                const origin = try originForModuleSpan(allocator, origin_path, object_decl.span);
                defer allocator.free(origin);
                try ir.addValidationDiagnostic(.@"error", null, null, origin, .{
                    .user_report = .{ .message = try std.fmt.allocPrint(ir.allocator, "DuplicateType: {s} type '{s}' is already defined in this module", .{ existing_kind, object_decl.name }) },
                });
                return error.UnknownType;
            }
            try names.put(object_decl.name, "object");
        }

        for (module.program.types.items) |decl| {
            if (isBuiltinTypeName(decl.name)) {
                const origin = try originForModuleSpan(allocator, origin_path, decl.span);
                defer allocator.free(origin);
                try ir.addValidationDiagnostic(.@"error", null, null, origin, .{
                    .user_report = .{ .message = try std.fmt.allocPrint(ir.allocator, "DuplicateType: type '{s}' conflicts with a built-in type", .{decl.name}) },
                });
                return error.UnknownType;
            }
            if (names.get(decl.name)) |existing_kind| {
                const origin = try originForModuleSpan(allocator, origin_path, decl.span);
                defer allocator.free(origin);
                try ir.addValidationDiagnostic(.@"error", null, null, origin, .{
                    .user_report = .{ .message = try std.fmt.allocPrint(ir.allocator, "DuplicateType: {s} type '{s}' is already defined in this module", .{ existing_kind, decl.name }) },
                });
                return error.UnknownType;
            }
            try names.put(decl.name, "enum");
            if (try type_defs.duplicateEnumCase(allocator, decl.cases.items)) |case_name| {
                const origin = try originForModuleSpan(allocator, origin_path, decl.span);
                defer allocator.free(origin);
                try ir.addValidationDiagnostic(.@"error", null, null, origin, .{
                    .user_report = .{ .message = try std.fmt.allocPrint(ir.allocator, "DuplicateEnumCase: enum '{s}' already has case '{s}'", .{ decl.name, case_name }) },
                });
                return error.UnknownType;
            }
        }
    }
}

fn isBuiltinTypeName(name: []const u8) bool {
    return semantic_env.isBuiltinTypeName(name);
}

fn checkTypeAnnotations(
    allocator: std.mem.Allocator,
    ir: *core.Ir,
    sema: *const SemanticEnv,
) !void {
    for (ir.module_order.items) |module_id| {
        const module = ir.moduleById(module_id) orelse continue;
        const origin_path = checker.originPathForModule(module);

        for (module.program.functions.items) |func| {
            const origin = try originForModuleSpan(allocator, origin_path, func.span);
            defer allocator.free(origin);
            for (func.params.items) |param| {
                try checkTypeAnnotation(ir, sema, module_id, param.ty, origin);
                if (param.default_value) |default_value| {
                    try checkExprTypeAnnotations(allocator, ir, sema, module_id, origin_path, default_value.*);
                }
            }
            try checkTypeAnnotation(ir, sema, module_id, func.result_type, origin);
        }

        for (module.program.document_statements.items) |stmt| {
            try checkStatementTypeAnnotations(allocator, ir, sema, module_id, origin_path, stmt);
        }
        for (module.program.pages.items) |page| {
            for (page.statements.items) |stmt| {
                try checkStatementTypeAnnotations(allocator, ir, sema, module_id, origin_path, stmt);
            }
        }
    }
}

fn resolveTypeReferences(
    allocator: std.mem.Allocator,
    ir: *core.Ir,
    sema: *const SemanticEnv,
) !void {
    _ = allocator;
    for (ir.modules.items) |*module| {
        try resolveProgramTypeReferences(&module.program, module.id, sema);
    }
}

fn resolveProgramTypeReferences(
    program: *ast.Program,
    module_id: core.SourceModuleId,
    sema: *const SemanticEnv,
) !void {
    for (program.functions.items) |*func| {
        try resolveFunctionTypeReferences(func, module_id, sema);
    }
    for (program.document_statements.items) |*stmt| {
        try resolveStatementTypeReferences(stmt, module_id, sema);
    }
    for (program.pages.items) |*page| {
        for (page.statements.items) |*stmt| {
            try resolveStatementTypeReferences(stmt, module_id, sema);
        }
    }
}

fn resolveFunctionTypeReferences(
    func: *ast.FunctionDecl,
    module_id: core.SourceModuleId,
    sema: *const SemanticEnv,
) !void {
    for (func.params.items) |*param| {
        try resolveParamTypeReference(param, module_id, sema);
        if (param.default_value) |default_value| try resolveExprTypeReferences(default_value, module_id, sema);
    }
    try resolveTypeReference(&func.result_type, module_id, sema);
    for (func.statements.items) |*stmt| {
        try resolveStatementTypeReferences(stmt, module_id, sema);
    }
}

fn resolveStatementTypeReferences(
    stmt: *ast.Statement,
    module_id: core.SourceModuleId,
    sema: *const SemanticEnv,
) !void {
    switch (stmt.kind) {
        .let_binding => |*binding| try resolveExprTypeReferences(&binding.expr, module_id, sema),
        .return_expr => |*expr| try resolveExprTypeReferences(expr, module_id, sema),
        .return_void => {},
        .constrain => |*constraint| {
            if (constraint.offset) |*offset| try resolveExprTypeReferences(offset, module_id, sema);
        },
        .property_set => |*property_set| try resolveExprTypeReferences(&property_set.value, module_id, sema),
        .if_stmt => |*if_stmt| {
            try resolveExprTypeReferences(&if_stmt.condition, module_id, sema);
            for (if_stmt.then_statements.items) |*nested| try resolveStatementTypeReferences(nested, module_id, sema);
            for (if_stmt.else_statements.items) |*nested| try resolveStatementTypeReferences(nested, module_id, sema);
        },
        .expr_stmt => |*expr| try resolveExprTypeReferences(expr, module_id, sema),
    }
}

fn resolveExprTypeReferences(
    expr: *ast.Expr,
    module_id: core.SourceModuleId,
    sema: *const SemanticEnv,
) !void {
    switch (expr.*) {
        .ident, .string, .color, .number, .boolean, .none, .enum_case => {},
        .call => |*call| {
            for (call.args.items) |*arg| try resolveExprTypeReferences(arg, module_id, sema);
        },
        .apply => |*apply| {
            try resolveExprTypeReferences(apply.callee, module_id, sema);
            for (apply.args.items) |*arg| try resolveExprTypeReferences(arg, module_id, sema);
        },
        .lambda => |*lambda| {
            for (lambda.params.items) |*param| try resolveParamTypeReference(param, module_id, sema);
            try resolveExprTypeReferences(lambda.body, module_id, sema);
        },
        .member => |*member| try resolveExprTypeReferences(member.target, module_id, sema),
        .optional_check => |*check| try resolveExprTypeReferences(check.target, module_id, sema),
        .coalesce => |*coalesce| {
            try resolveExprTypeReferences(coalesce.target, module_id, sema);
            try resolveExprTypeReferences(coalesce.fallback, module_id, sema);
        },
    }
}

fn resolveEnumCaseExpressionsAndDefaults(
    allocator: std.mem.Allocator,
    ir: *core.Ir,
    sema: *const SemanticEnv,
) !void {
    for (ir.modules.items) |*module| {
        try resolveProgramEnumCasesAndDefaults(allocator, module.id, sema, &module.program);
    }
}

fn resolveProgramEnumCasesAndDefaults(
    allocator: std.mem.Allocator,
    module_id: core.SourceModuleId,
    sema: *const SemanticEnv,
    program: *ast.Program,
) !void {
    for (program.objects.items) |*object_decl| {
        try resolveObjectFieldEnumCasesAndDefaults(allocator, module_id, sema, object_decl.fields.items);
    }
    for (program.object_extensions.items) |*extension| {
        try resolveObjectFieldEnumCasesAndDefaults(allocator, module_id, sema, extension.fields.items);
    }
    for (program.functions.items) |*func| {
        try resolveFunctionEnumCases(allocator, module_id, sema, func);
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
        try setDefaultPropertyValue(allocator, field, try staticDefaultPropertyValue(allocator, default_value.*));
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

fn staticDefaultPropertyValue(allocator: std.mem.Allocator, expr: ast.Expr) !?[]const u8 {
    return switch (expr) {
        .string => |text| try allocator.dupe(u8, text),
        .color => |text| try allocator.dupe(u8, text),
        .number => |value| try std.fmt.allocPrint(allocator, "{d}", .{value}),
        .boolean => |value| try allocator.dupe(u8, if (value) "true" else "false"),
        .none => try allocator.dupe(u8, "none"),
        .enum_case => |case| try allocator.dupe(u8, case.case_name),
        .call => |call| try staticNumericDefaultPropertyValue(allocator, call),
        else => null,
    };
}

fn staticNumericDefaultPropertyValue(allocator: std.mem.Allocator, call: ast.CallExpr) !?[]const u8 {
    if (!std.mem.eql(u8, call.callee.name, "neg") or call.args.items.len != 1) return null;
    return switch (call.args.items[0]) {
        .number => |value| try std.fmt.allocPrint(allocator, "-{d}", .{value}),
        else => null,
    };
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
        .let_binding => |*binding| {
            try resolveExprEnumCases(allocator, module_id, sema, env, &binding.expr);
            try env.put(binding.name, semantic_types.infoFromType(ast.Type.any));
        },
        .return_expr => |*expr| try resolveExprEnumCases(allocator, module_id, sema, env, expr),
        .return_void => {},
        .constrain => |*constraint| {
            if (constraint.offset) |*offset| try resolveExprEnumCases(allocator, module_id, sema, env, offset);
        },
        .property_set => |*property_set| try resolveExprEnumCases(allocator, module_id, sema, env, &property_set.value),
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
        .ident, .string, .color, .number, .boolean, .none, .enum_case => {},
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
        .ident => |enum_name| {
            if (env.get(enum_name) != null or sema.function(enum_name) != null) return false;
            if (!sema.enumHasCase(module_id, enum_name, member.name)) return false;
            const target = member.target;
            const case_name = member.name;
            allocator.destroy(target);
            expr.* = .{ .enum_case = .{
                .enum_name = enum_name,
                .case_name = case_name,
            } };
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
            if (!sema.classExists(name)) {
                if (sema.enumDescriptor(module_id, name) != null) ty.* = ast.Type.enumType(name);
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

fn rebuildFunctionDeclarations(
    allocator: std.mem.Allocator,
    ir: *core.Ir,
) !void {
    _ = allocator;
    ir.functions.clearRetainingCapacity();
    for (ir.module_order.items) |module_id| {
        const module = ir.moduleById(module_id) orelse continue;
        try appendFunctionDeclarations(&ir.functions, module.program, module.id);
    }
}

fn checkStatementTypeAnnotations(
    allocator: std.mem.Allocator,
    ir: *core.Ir,
    sema: *const SemanticEnv,
    module_id: core.SourceModuleId,
    origin_path: []const u8,
    stmt: ast.Statement,
) !void {
    switch (stmt.kind) {
        .let_binding => |binding| try checkExprTypeAnnotations(allocator, ir, sema, module_id, origin_path, binding.expr),
        .return_expr => |expr| try checkExprTypeAnnotations(allocator, ir, sema, module_id, origin_path, expr),
        .return_void => {},
        .property_set => |property_set| try checkExprTypeAnnotations(allocator, ir, sema, module_id, origin_path, property_set.value),
        .if_stmt => |if_stmt| {
            try checkExprTypeAnnotations(allocator, ir, sema, module_id, origin_path, if_stmt.condition);
            for (if_stmt.then_statements.items) |nested| try checkStatementTypeAnnotations(allocator, ir, sema, module_id, origin_path, nested);
            for (if_stmt.else_statements.items) |nested| try checkStatementTypeAnnotations(allocator, ir, sema, module_id, origin_path, nested);
        },
        .expr_stmt => |expr| try checkExprTypeAnnotations(allocator, ir, sema, module_id, origin_path, expr),
        .constrain => |constraint| {
            if (constraint.offset) |expr| try checkExprTypeAnnotations(allocator, ir, sema, module_id, origin_path, expr);
        },
    }
}

fn checkExprTypeAnnotations(
    allocator: std.mem.Allocator,
    ir: *core.Ir,
    sema: *const SemanticEnv,
    module_id: core.SourceModuleId,
    origin_path: []const u8,
    expr: ast.Expr,
) !void {
    switch (expr) {
        .ident, .string, .color, .number, .boolean, .none, .enum_case => {},
        .call => |call| {
            for (call.args.items) |arg| try checkExprTypeAnnotations(allocator, ir, sema, module_id, origin_path, arg);
        },
        .apply => |apply| {
            try checkExprTypeAnnotations(allocator, ir, sema, module_id, origin_path, apply.callee.*);
            for (apply.args.items) |arg| try checkExprTypeAnnotations(allocator, ir, sema, module_id, origin_path, arg);
        },
        .lambda => |lambda| {
            const origin = try originForModuleSpan(allocator, origin_path, lambda.span);
            defer allocator.free(origin);
            for (lambda.params.items) |param| {
                try checkTypeAnnotation(ir, sema, module_id, param.ty, origin);
            }
            try checkExprTypeAnnotations(allocator, ir, sema, module_id, origin_path, lambda.body.*);
        },
        .member => |member| try checkExprTypeAnnotations(allocator, ir, sema, module_id, origin_path, member.target.*),
        .optional_check => |check| try checkExprTypeAnnotations(allocator, ir, sema, module_id, origin_path, check.target.*),
        .coalesce => |coalesce| {
            try checkExprTypeAnnotations(allocator, ir, sema, module_id, origin_path, coalesce.target.*);
            try checkExprTypeAnnotations(allocator, ir, sema, module_id, origin_path, coalesce.fallback.*);
        },
    }
}

fn checkTypeAnnotation(
    ir: *core.Ir,
    sema: *const SemanticEnv,
    module_id: core.SourceModuleId,
    ty: ast.Type,
    origin: []const u8,
) !void {
    if (ty.kind == .enum_type or ty.kind == .color or ty.kind == .none) return;
    if (ty.kind == .optional) {
        if (ty.optional_child) |child| try checkTypeAnnotation(ir, sema, module_id, child.*, origin);
        return;
    }
    if (ty.class_name) |class_name| {
        if (!sema.classExists(class_name)) {
            return reportUnknownType(ir, origin, class_name);
        }
    }
    if (ty.param_class_name) |class_name| {
        if (!sema.classExists(class_name)) return reportUnknownType(ir, origin, class_name);
    }
    if (ty.kind == .function) {
        for (ty.fn_params) |param| try checkTypeAnnotation(ir, sema, module_id, param, origin);
        if (ty.fn_result) |result| try checkTypeAnnotation(ir, sema, module_id, result.*, origin);
    }
}

fn reportUnknownType(ir: *core.Ir, origin: []const u8, type_name: []const u8) !void {
    try ir.addValidationDiagnostic(.@"error", null, null, origin, .{
        .user_report = .{ .message = try std.fmt.allocPrint(ir.allocator, "UnknownType: unknown type: {s}", .{type_name}) },
    });
    return error.UnknownType;
}

fn checkDuplicateFunctionDeclarations(
    allocator: std.mem.Allocator,
    ir: *core.Ir,
) !void {
    for (ir.module_order.items) |module_id| {
        const module = ir.moduleById(module_id) orelse continue;
        var names = std.StringHashMap(void).init(allocator);
        defer names.deinit();
        const origin_path = checker.originPathForModule(module);
        for (module.program.functions.items) |func| {
            if (names.contains(func.name)) {
                const origin = try originForModuleSpan(allocator, origin_path, func.span);
                defer allocator.free(origin);
                try ir.addValidationDiagnostic(.@"error", null, null, origin, .{
                    .user_report = .{ .message = try std.fmt.allocPrint(ir.allocator, "DuplicateFunction: function '{s}' is already defined in this module", .{func.name}) },
                });
                return error.DiagnosticsFailed;
            }
            try names.put(func.name, {});
        }
    }
}

fn originForModuleSpan(allocator: std.mem.Allocator, origin_path: []const u8, span: ast.Span) ![]const u8 {
    if (origin_path.len != 0) {
        return std.fmt.allocPrint(allocator, "path:{s}:bytes:{d}-{d}", .{ origin_path, span.start, span.end });
    }
    return std.fmt.allocPrint(allocator, "bytes:{d}-{d}", .{ span.start, span.end });
}

fn functionOrigin(
    allocator: std.mem.Allocator,
    ir: *const core.Ir,
    module_id: core.SourceModuleId,
    function_name: []const u8,
) ![]const u8 {
    const module = ir.moduleById(module_id);
    const path = if (module) |m| m.path orelse m.spec else "";
    if (module) |m| {
        for (m.program.functions.items) |func| {
            if (!std.mem.eql(u8, func.name, function_name)) continue;
            if (path.len == 0) return std.fmt.allocPrint(allocator, "bytes:{d}-{d}", .{ func.span.start, func.span.end });
            return std.fmt.allocPrint(allocator, "path:{s}:bytes:{d}-{d}", .{ path, func.span.start, func.span.end });
        }
    }
    if (path.len == 0) return std.fmt.allocPrint(allocator, "function:{s}", .{function_name});
    return std.fmt.allocPrint(allocator, "path:{s}", .{path});
}

pub fn collectVariableInfoFromProgram(
    allocator: std.mem.Allocator,
    functions: *const core.FunctionMap,
    program: ast.Program,
    diagnostic_ir: ?*core.Ir,
) !std.StringHashMap(VariableInfo) {
    const sema = SemanticEnv.init(diagnostic_ir, null, functions);
    var variables = std.StringHashMap(VariableInfo).init(allocator);
    errdefer variables.deinit();

    for (program.functions.items) |func| {
        var env = TypeEnv.init(allocator);
        defer env.deinit();

        for (func.params.items) |param| {
            if (param.default_value) |default_value| {
                const origin = try statementOrigin(allocator, func.span);
                defer allocator.free(origin);
                const info = try inferExprInfo(allocator, diagnostic_ir, &sema, &env, default_value.*, origin);
                try ensureType(diagnostic_ir, allocator, info, param.ty, origin, .UnmatchedArgumentType);
            }
            const info = semantic_types.infoFromType(param.ty);
            try env.put(param.name, info);
            try variables.put(param.name, info);
        }

        for (func.statements.items) |stmt| {
            try collectVariableTypesFromStatement(allocator, diagnostic_ir, &env, &sema, stmt, &variables);
        }
    }

    {
        var env = TypeEnv.init(allocator);
        defer env.deinit();
        for (program.document_statements.items) |stmt| {
            try collectVariableTypesFromStatement(allocator, diagnostic_ir, &env, &sema, stmt, &variables);
        }
    }

    for (program.pages.items) |page| {
        var env = TypeEnv.init(allocator);
        defer env.deinit();

        for (page.statements.items) |stmt| {
            try collectVariableTypesFromStatement(allocator, diagnostic_ir, &env, &sema, stmt, &variables);
        }
    }

    return variables;
}

pub fn collectScopedVariableInfoFromProgram(
    allocator: std.mem.Allocator,
    functions: *const core.FunctionMap,
    program: ast.Program,
    module_id: core.SourceModuleId,
    source_len: usize,
    diagnostic_ir: ?*core.Ir,
) !std.ArrayList(ScopedVariableInfo) {
    const root_sema = SemanticEnv.init(diagnostic_ir, null, functions);
    const sema = root_sema.forModule(module_id);
    var variables = std.ArrayList(ScopedVariableInfo).empty;
    errdefer variables.deinit(allocator);

    for (program.functions.items) |func| {
        var env = TypeEnv.init(allocator);
        defer env.deinit();

        for (func.params.items) |param| {
            if (param.default_value) |default_value| {
                const origin = try statementOrigin(allocator, func.span);
                defer allocator.free(origin);
                const info = try inferExprInfo(allocator, diagnostic_ir, &sema, &env, default_value.*, origin);
                try ensureType(diagnostic_ir, allocator, info, param.ty, origin, .UnmatchedArgumentType);
            }
            const info = semantic_types.infoFromType(param.ty);
            try env.put(param.name, info);
            const func_scope = analysis_scope.functionScope(func);
            try appendScopedVariable(allocator, &variables, param.name, info, module_id, func_scope, func.span.start, func.span.start, func.span.start, func.span.end);
        }

        for (func.statements.items) |stmt| {
            try collectScopedVariableTypesFromStatement(allocator, diagnostic_ir, &env, &sema, stmt, &variables, module_id, analysis_scope.functionScope(func), func.span.end);
        }
    }

    {
        var env = TypeEnv.init(allocator);
        defer env.deinit();
        const document_scope = analysis_scope.documentScope(source_len);
        for (program.document_statements.items) |stmt| {
            try collectScopedVariableTypesFromStatement(allocator, diagnostic_ir, &env, &sema, stmt, &variables, module_id, document_scope, source_len);
        }
    }

    for (program.pages.items) |page| {
        var env = TypeEnv.init(allocator);
        defer env.deinit();
        const page_scope = analysis_scope.pageScope(page);

        for (page.statements.items) |stmt| {
            try collectScopedVariableTypesFromStatement(allocator, diagnostic_ir, &env, &sema, stmt, &variables, module_id, page_scope, page.span.end);
        }
    }

    return variables;
}

fn appendFunctionDeclarations(
    functions: *core.FunctionMap,
    program: ast.Program,
    module_id: core.SourceModuleId,
) !void {
    for (program.functions.items) |func| {
        try functions.put(core.functionKey(module_id, func.name), func);
    }
}

pub fn buildIr(
    allocator: std.mem.Allocator,
    input_path: []const u8,
    asset_base_path: []const u8,
    project_source: *[]u8,
    project_program: *ast.Program,
    index: *ProgramIndex,
) !core.Ir {
    return buildIrWithOptions(allocator, input_path, asset_base_path, project_source, project_program, index, .{});
}

pub fn buildIrWithOptions(
    allocator: std.mem.Allocator,
    input_path: []const u8,
    asset_base_path: []const u8,
    project_source: *[]u8,
    project_program: *ast.Program,
    index: *ProgramIndex,
    options: BuildIrOptions,
) !core.Ir {
    const asset_base_dir = try allocator.dupe(u8, asset_base_path);
    var owns_asset_base_dir = true;
    errdefer if (owns_asset_base_dir) allocator.free(asset_base_dir);
    const project_path = try allocator.dupe(u8, input_path);
    var owns_project_path = true;
    errdefer if (owns_project_path) allocator.free(project_path);
    var ir = try core.Ir.init(allocator, asset_base_dir, project_path, project_source.*, project_program.*);
    owns_asset_base_dir = false;
    owns_project_path = false;
    project_source.* = &.{};
    project_program.* = ast.Program.init();
    errdefer ir.deinit();

    ir.functions = index.functions;
    index.functions = core.FunctionMap.init(allocator);
    ir.module_order = index.module_order;
    index.module_order = .empty;
    ir.projectModuleMutable().implicit_import_ids = index.project_implicit_import_ids;
    index.project_implicit_import_ids = .empty;
    ir.projectModuleMutable().resolved_import_ids = index.project_import_ids;
    index.project_import_ids = .empty;
    for (index.modules.items) |module| try ir.modules.append(allocator, module);
    index.modules = .empty;
    if (ir.module_order.items.len == 0 or ir.module_order.items[ir.module_order.items.len - 1] != ir.project_module_id) {
        try ir.module_order.append(allocator, ir.project_module_id);
    }
    {
        var declaration_index = try declarations.build(allocator, &ir);
        defer declaration_index.deinit();
        const sema = SemanticEnv.init(&ir, &declaration_index, &ir.functions);
        try resolveTypeReferences(allocator, &ir, &sema);
        try resolveEnumCaseExpressionsAndDefaults(allocator, &ir, &sema);
        try rebuildFunctionDeclarations(allocator, &ir);
    }
    var variable_infos: ?std.StringHashMap(VariableInfo) = collectVariableInfoFromProgram(allocator, &ir.functions, ir.projectProgram(), &ir) catch |err| blk: {
        if (!options.allow_diagnostics) {
            printIrDiagnosticsOrFallback(&ir, err);
            return error.DiagnosticsFailed;
        }
        break :blk null;
    };
    if (variable_infos) |*infos| infos.deinit();
    try editor.populateIrAnalysis(allocator, &ir);
    return ir;
}

fn printIrDiagnosticsOrFallback(ir: *core.Ir, err: anyerror) void {
    if (utils.err.hasIrErrors(ir)) {
        utils.err.printIrDiagnostics(ir.projectPath(), ir.projectSource(), ir);
    } else {
        std.debug.print("error: {s}\n", .{@errorName(err)});
    }
}

pub fn loadProgramIndex(
    allocator: std.mem.Allocator,
    io: std.Io,
    base_dir: []const u8,
    project_program: ast.Program,
) !ProgramIndex {
    return loadProgramIndexWithOverlay(allocator, io, base_dir, project_program, null);
}

pub fn loadProgramIndexWithOverlay(
    allocator: std.mem.Allocator,
    io: std.Io,
    base_dir: []const u8,
    project_program: ast.Program,
    overlay: ?*const module_loader.SourceOverlay,
) !ProgramIndex {
    return loadProgramIndexWithOptions(allocator, io, base_dir, project_program, .{ .overlay = overlay });
}

pub const LoadProgramIndexOptions = struct {
    overlay: ?*const module_loader.SourceOverlay = null,
    diagnostics: ?*module_loader.LoadDiagnostics = null,
    print_diagnostics: bool = true,
};

pub fn loadProgramIndexWithOptions(
    allocator: std.mem.Allocator,
    io: std.Io,
    base_dir: []const u8,
    project_program: ast.Program,
    options: LoadProgramIndexOptions,
) !ProgramIndex {
    var graph = try module_loader.loadGraphWithOptions(allocator, io, base_dir, project_program, .{
        .overlay = options.overlay,
        .diagnostics = options.diagnostics,
        .print_diagnostics = options.print_diagnostics,
    });
    errdefer graph.deinit();

    var index = ProgramIndex{
        .allocator = allocator,
        .modules = graph.modules,
        .module_order = graph.module_order,
        .project_implicit_import_ids = graph.project_implicit_import_ids,
        .project_import_ids = graph.project_import_ids,
        .functions = core.FunctionMap.init(allocator),
    };
    graph.modules = .empty;
    graph.module_order = .empty;
    graph.project_implicit_import_ids = .empty;
    graph.project_import_ids = .empty;

    errdefer index.deinit();

    for (index.module_order.items) |module_id| {
        const module = findModuleById(index.modules.items, module_id) orelse continue;
        try appendFunctionDeclarations(&index.functions, module.program, module.id);
    }
    try appendFunctionDeclarations(&index.functions, project_program, 0);
    return index;
}

pub fn loadProgramIndexForPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    input_path: []const u8,
    project_program: ast.Program,
) !ProgramIndex {
    const base_dir = std.fs.path.dirname(input_path) orelse ".";
    return loadProgramIndex(allocator, io, base_dir, project_program);
}

fn collectVariableTypesFromStatement(
    allocator: std.mem.Allocator,
    diagnostic_ir: ?*core.Ir,
    env: *TypeEnv,
    sema: *const SemanticEnv,
    stmt: ast.Statement,
    variables: *std.StringHashMap(VariableInfo),
) !void {
    const origin = try statementOrigin(allocator, stmt.span);
    defer allocator.free(origin);
    switch (stmt.kind) {
        .let_binding => |binding| {
            const info = try inferExprInfo(allocator, diagnostic_ir, sema, env, binding.expr, origin);
            if (language_names.isDiscardBindingName(binding.name)) return;
            try env.put(binding.name, info);
            try variables.put(binding.name, info);
        },
        .return_expr => |expr| {
            _ = try inferExprInfo(allocator, diagnostic_ir, sema, env, expr, origin);
        },
        .return_void => {},
        .property_set => |property_set| {
            _ = try inferExprInfo(allocator, diagnostic_ir, sema, env, property_set.value, origin);
        },
        .if_stmt => |if_stmt| {
            const condition = try inferExprInfo(allocator, diagnostic_ir, sema, env, if_stmt.condition, origin);
            try semantic_types.ensureType(diagnostic_ir, allocator, condition, ast.Type.boolean, origin, .UnmatchedArgumentType);
            var then_env = try env.clone();
            defer then_env.deinit();
            for (if_stmt.then_statements.items) |nested| {
                try collectVariableTypesFromStatement(allocator, diagnostic_ir, &then_env, sema, nested, variables);
            }
            var else_env = try env.clone();
            defer else_env.deinit();
            for (if_stmt.else_statements.items) |nested| {
                try collectVariableTypesFromStatement(allocator, diagnostic_ir, &else_env, sema, nested, variables);
            }
        },
        .expr_stmt => |expr| {
            _ = try inferExprInfo(allocator, diagnostic_ir, sema, env, expr, origin);
        },
        .constrain => |decl| {
            if (decl.offset) |expr| {
                _ = try inferExprInfo(allocator, diagnostic_ir, sema, env, expr, origin);
            }
        },
    }
}

fn collectScopedVariableTypesFromStatement(
    allocator: std.mem.Allocator,
    diagnostic_ir: ?*core.Ir,
    env: *TypeEnv,
    sema: *const SemanticEnv,
    stmt: ast.Statement,
    variables: *std.ArrayList(ScopedVariableInfo),
    module_id: core.SourceModuleId,
    scope: analysis_scope.SourceScope,
    visible_end: usize,
) !void {
    const origin = try statementOrigin(allocator, stmt.span);
    defer allocator.free(origin);
    switch (stmt.kind) {
        .let_binding => |binding| {
            const info = try inferExprInfo(allocator, diagnostic_ir, sema, env, binding.expr, origin);
            if (language_names.isDiscardBindingName(binding.name)) return;
            try env.put(binding.name, info);
            try appendScopedVariable(allocator, variables, binding.name, info, module_id, scope, stmt.span.start, stmt.span.end, stmt.span.start, visible_end);
        },
        .return_expr => |expr| {
            _ = try inferExprInfo(allocator, diagnostic_ir, sema, env, expr, origin);
        },
        .return_void => {},
        .property_set => |property_set| {
            _ = try inferExprInfo(allocator, diagnostic_ir, sema, env, property_set.value, origin);
        },
        .if_stmt => |if_stmt| {
            const condition = try inferExprInfo(allocator, diagnostic_ir, sema, env, if_stmt.condition, origin);
            try semantic_types.ensureType(diagnostic_ir, allocator, condition, ast.Type.boolean, origin, .UnmatchedArgumentType);
            var then_env = try env.clone();
            defer then_env.deinit();
            const then_end = analysis_scope.statementsVisibleEnd(if_stmt.then_statements.items, stmt.span.end);
            for (if_stmt.then_statements.items) |nested| {
                try collectScopedVariableTypesFromStatement(allocator, diagnostic_ir, &then_env, sema, nested, variables, module_id, scope, then_end);
            }
            var else_env = try env.clone();
            defer else_env.deinit();
            const else_end = analysis_scope.statementsVisibleEnd(if_stmt.else_statements.items, stmt.span.end);
            for (if_stmt.else_statements.items) |nested| {
                try collectScopedVariableTypesFromStatement(allocator, diagnostic_ir, &else_env, sema, nested, variables, module_id, scope, else_end);
            }
        },
        .expr_stmt => |expr| {
            _ = try inferExprInfo(allocator, diagnostic_ir, sema, env, expr, origin);
        },
        .constrain => |decl| {
            if (decl.offset) |expr| {
                _ = try inferExprInfo(allocator, diagnostic_ir, sema, env, expr, origin);
            }
        },
    }
}

fn appendScopedVariable(
    allocator: std.mem.Allocator,
    variables: *std.ArrayList(ScopedVariableInfo),
    name: []const u8,
    info: VariableInfo,
    module_id: core.SourceModuleId,
    scope: analysis_scope.SourceScope,
    span_start: usize,
    span_end: usize,
    visible_start: usize,
    visible_end: usize,
) !void {
    try variables.append(allocator, .{
        .name = name,
        .info = info,
        .module_id = module_id,
        .scope_kind = scope.kind,
        .scope_name = scope.name,
        .span_start = span_start,
        .span_end = span_end,
        .visible_start = visible_start,
        .visible_end = visible_end,
    });
}

fn statementOrigin(allocator: std.mem.Allocator, span: ast.Span) ![]const u8 {
    return std.fmt.allocPrint(allocator, "bytes:{d}-{d}", .{ span.start, span.end });
}
