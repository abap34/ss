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
const fields = @import("fields.zig");
const infer = @import("infer.zig");
const analysis_index = @import("index.zig");
const registry = @import("../language/registry.zig");
const schedule = @import("schedule.zig");
const analysis_scope = @import("scope.zig");
const semantic_types = @import("types.zig");
const syntax = @import("../syntax/parse.zig");
const syntax_hole = @import("../syntax/hole.zig");
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
    constants: core.ConstMap,
    functions: core.FunctionMap,

    pub fn deinit(self: *ProgramIndex) void {
        self.constants.deinit();
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
    parse_holes: ?syntax_hole.Result = null,
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

pub fn collectConstantsFromPrograms(
    allocator: std.mem.Allocator,
    programs: []const *const ast.Program,
) !core.ConstMap {
    var constants = core.ConstMap.init(allocator);
    for (programs, 0..) |program, module_index| {
        for (program.constants.items) |constant_decl| {
            try constants.put(core.constKey(@intCast(module_index), constant_decl.name), constant_decl);
        }
    }
    return constants;
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

    var had_diagnostics = false;
    var const_it = ir.constants.iterator();
    while (const_it.next()) |entry| {
        const module_id = entry.key_ptr.module_id;
        const origin_path = blk: {
            if (ir.moduleById(module_id)) |module| break :blk checker.originPathForModule(module);
            break :blk "";
        };
        const module_sema = sema.forModule(module_id);
        const diagnostic_count = ir.diagnostics.items.len;
        checker.checkConst(allocator, ir, &module_sema, origin_path, entry.value_ptr.*) catch |err| {
            try continueAfterDiagnostic(ir, diagnostic_count, err);
            had_diagnostics = true;
        };
    }

    var it = sema.functions.iterator();
    while (it.next()) |entry| {
        const module_id = entry.key_ptr.module_id;
        const origin_path = blk: {
            if (ir.moduleById(module_id)) |module| break :blk checker.originPathForModule(module);
            break :blk "";
        };
        const module_sema = sema.forModule(module_id);
        const diagnostic_count = ir.diagnostics.items.len;
        checker.checkFunction(allocator, ir, &module_sema, origin_path, entry.value_ptr.*) catch |err| {
            try continueAfterDiagnostic(ir, diagnostic_count, err);
            had_diagnostics = true;
        };
    }
    if (had_diagnostics) return error.DiagnosticsFailed;
}

fn continueAfterDiagnostic(ir: *const core.Ir, diagnostic_count_before: usize, err: anyerror) !void {
    if (ir.diagnostics.items.len > diagnostic_count_before) return;
    return err;
}

pub fn analyzeProgram(
    allocator: std.mem.Allocator,
    ir: *core.Ir,
) !void {
    try analyzeProgramWithoutSchedule(allocator, ir);
    try schedule.analyzeDependencies(allocator, ir);
}

pub fn analyzeProgramForEvaluation(
    allocator: std.mem.Allocator,
    ir: *core.Ir,
) !schedule.ScheduleGraph {
    try analyzeProgramWithoutSchedule(allocator, ir);
    return schedule.ScheduleGraph.build(allocator, ir, ir, .{ .page_id_mode = .create });
}

fn analyzeProgramWithoutSchedule(
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
    try rebuildConstDeclarations(allocator, ir);
    try rebuildFunctionDeclarations(allocator, ir);
    try checkDuplicateValueDeclarations(allocator, ir);
    try checkTypeAnnotations(allocator, ir, &sema);
    try fields.checkObjectDeclarations(allocator, ir, &sema);
    try checker.checkPageNamesUnique(allocator, ir);
    try checkPlacementEffectDeclarations(allocator, ir);
    try checkFunctionDefinitionsWithEnv(allocator, ir, &sema);
    for (ir.module_order.items) |module_id| {
        const module = ir.moduleById(module_id) orelse continue;
        const module_sema = sema.forModule(module_id);
        try checker.checkPageStatements(allocator, ir, &module_sema, checker.originPathForModule(module), module.program);
    }
    try addDependencyQueryDiagnostics(allocator, ir, &sema);
}

const DependencyQuery = struct {
    span: ast.Span,
};

const DependencyQueryTarget = struct {
    stmt: ast.Statement,
    context: []const ast.Statement,
    scope: dependencies.ResourceScope,
    scope_display: dependencies.ScopeDisplayName,
};

fn addDependencyQueryDiagnostics(allocator: std.mem.Allocator, ir: *core.Ir, sema: *const SemanticEnv) !void {
    for (ir.module_order.items) |module_id| {
        const module = ir.moduleById(module_id) orelse continue;
        if (std.mem.indexOf(u8, module.source, "^dep?") == null) continue;
        const module_sema = sema.forModule(module_id);
        var query_iter = DependencyQueryIterator.init(module.source);
        while (query_iter.next()) |query| {
            const target = dependencyQueryTarget(module, query.span.start) orelse continue;
            var analyzer = dependencies.Analyzer.initWithScope(allocator, &module_sema, target.scope);
            defer analyzer.deinit();
            for (target.context) |stmt| {
                var context_summary = try analyzer.statement(stmt);
                context_summary.deinit();
            }
            var summary = try analyzer.statement(target.stmt);
            defer summary.deinit();
            const scope_displays = [_]dependencies.ScopeDisplay{.{
                .scope = target.scope,
                .name = target.scope_display,
            }};
            const message = try dependencies.formatAccessSummaryWithOptions(ir.allocator, summary, .{
                .variable_scope_displays = &scope_displays,
                .pages_scope_displays = &scope_displays,
            });
            errdefer ir.allocator.free(message);
            const origin = try queryOrigin(allocator, module, query.span);
            defer allocator.free(origin);
            try ir.addValidationDiagnostic(.warning, null, null, origin, .{
                .user_report = .{ .message = message },
            });
        }
    }
}

const DependencyQueryIterator = struct {
    lines: utils.source.LineIterator,

    fn init(text: []const u8) DependencyQueryIterator {
        return .{ .lines = utils.source.lineIterator(text) };
    }

    fn next(self: *DependencyQueryIterator) ?DependencyQuery {
        while (self.lines.next()) |view| {
            const line = view.text(self.lines.source);
            const comment_index = std.mem.indexOf(u8, line, ";;") orelse continue;
            const comment = line[comment_index + 2 ..];
            const marker_index = std.mem.indexOf(u8, comment, "^dep?") orelse continue;
            const start = view.span.start + comment_index + 2 + marker_index;
            return .{ .span = .{ .start = start, .end = start + "^dep?".len } };
        }
        return null;
    }
};

fn dependencyQueryTarget(module: *const core.SourceModule, query_start: usize) ?DependencyQueryTarget {
    var best: ?DependencyQueryTarget = null;
    var best_end: usize = 0;
    const document_display = dependencies.ScopeDisplayName{ .document = dependencyQueryDocumentName(module) };
    for (module.program.document_statements.items, 0..) |stmt, index| {
        updateDependencyQueryTarget(&best, &best_end, stmt, module.program.document_statements.items[0..index], .{ .document = module.id }, document_display, query_start);
    }
    for (module.program.pages.items, 0..) |page, page_index| {
        const page_scope = dependencies.ResourceScope{ .page = dependencyQuerySyntheticPageId(page_index) };
        const page_display = dependencies.ScopeDisplayName{ .page = page.name };
        for (page.statements.items, 0..) |stmt, index| {
            updateDependencyQueryTarget(&best, &best_end, stmt, page.statements.items[0..index], page_scope, page_display, query_start);
        }
    }
    const caller_display: dependencies.ScopeDisplayName = .caller;
    for (module.program.functions.items) |func| {
        for (func.statements.items, 0..) |stmt, index| {
            updateDependencyQueryTarget(&best, &best_end, stmt, func.statements.items[0..index], .any, caller_display, query_start);
        }
    }
    return best;
}

fn dependencyQueryDocumentName(module: *const core.SourceModule) []const u8 {
    const origin_path = checker.originPathForModule(module);
    if (origin_path.len == 0) return module.spec;
    return std.fs.path.basename(origin_path);
}

fn dependencyQuerySyntheticPageId(page_index: usize) core.NodeId {
    return std.math.maxInt(core.NodeId) - @as(core.NodeId, @intCast(page_index));
}

fn updateDependencyQueryTarget(
    best: *?DependencyQueryTarget,
    best_end: *usize,
    stmt: ast.Statement,
    context: []const ast.Statement,
    scope: dependencies.ResourceScope,
    scope_display: dependencies.ScopeDisplayName,
    query_start: usize,
) void {
    if (stmt.span.end <= query_start and stmt.span.end >= best_end.*) {
        best.* = .{ .stmt = stmt, .context = context, .scope = scope, .scope_display = scope_display };
        best_end.* = stmt.span.end;
    }
    switch (stmt.kind) {
        .if_stmt => |if_stmt| {
            for (if_stmt.then_statements.items) |nested| updateDependencyQueryTarget(best, best_end, nested, context, scope, scope_display, query_start);
            for (if_stmt.else_statements.items) |nested| updateDependencyQueryTarget(best, best_end, nested, context, scope, scope_display, query_start);
        },
        else => {},
    }
}

fn queryOrigin(allocator: std.mem.Allocator, module: *const core.SourceModule, span: ast.Span) ![]const u8 {
    const origin_path = checker.originPathForModule(module);
    if (origin_path.len != 0) {
        return std.fmt.allocPrint(allocator, "path:{s}:bytes:{d}-{d}", .{ origin_path, span.start, span.end });
    }
    return std.fmt.allocPrint(allocator, "bytes:{d}-{d}", .{ span.start, span.end });
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

        for (module.program.records.items) |record_decl| {
            if (isBuiltinTypeName(record_decl.name)) {
                const origin = try originForModuleSpan(allocator, origin_path, record_decl.span);
                defer allocator.free(origin);
                try ir.addValidationDiagnostic(.@"error", null, null, origin, .{
                    .user_report = .{ .message = try std.fmt.allocPrint(ir.allocator, "DuplicateType: type '{s}' conflicts with a built-in type", .{record_decl.name}) },
                });
                return error.UnknownType;
            }
            if (names.get(record_decl.name)) |existing_kind| {
                const origin = try originForModuleSpan(allocator, origin_path, record_decl.span);
                defer allocator.free(origin);
                try ir.addValidationDiagnostic(.@"error", null, null, origin, .{
                    .user_report = .{ .message = try std.fmt.allocPrint(ir.allocator, "DuplicateType: {s} type '{s}' is already defined in this module", .{ existing_kind, record_decl.name }) },
                });
                return error.UnknownType;
            }
            try names.put(record_decl.name, "record");
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
    var had_diagnostics = false;
    for (ir.module_order.items) |module_id| {
        const module = ir.moduleById(module_id) orelse continue;
        const origin_path = checker.originPathForModule(module);

        for (module.program.records.items) |record_decl| {
            for (record_decl.fields.items) |field| {
                const diagnostic_count = ir.diagnostics.items.len;
                checkFieldTypeAnnotation(allocator, ir, sema, module_id, origin_path, field) catch |err| {
                    try continueAfterDiagnostic(ir, diagnostic_count, err);
                    had_diagnostics = true;
                };
            }
        }
        for (module.program.objects.items) |object_decl| {
            for (object_decl.fields.items) |field| {
                const diagnostic_count = ir.diagnostics.items.len;
                checkFieldTypeAnnotation(allocator, ir, sema, module_id, origin_path, field) catch |err| {
                    try continueAfterDiagnostic(ir, diagnostic_count, err);
                    had_diagnostics = true;
                };
            }
        }
        for (module.program.object_extensions.items) |extension| {
            for (extension.fields.items) |field| {
                const diagnostic_count = ir.diagnostics.items.len;
                checkFieldTypeAnnotation(allocator, ir, sema, module_id, origin_path, field) catch |err| {
                    try continueAfterDiagnostic(ir, diagnostic_count, err);
                    had_diagnostics = true;
                };
            }
        }

        for (module.program.functions.items) |func| {
            const origin = try originForModuleSpan(allocator, origin_path, func.span);
            defer allocator.free(origin);
            for (func.params.items) |param| {
                const diagnostic_count = ir.diagnostics.items.len;
                checkTypeAnnotation(ir, sema, module_id, param.ty, origin) catch |err| {
                    try continueAfterDiagnostic(ir, diagnostic_count, err);
                    had_diagnostics = true;
                };
                if (param.default_value) |default_value| {
                    const expr_diagnostic_count = ir.diagnostics.items.len;
                    checkExprTypeAnnotations(allocator, ir, sema, module_id, origin_path, default_value.*) catch |err| {
                        try continueAfterDiagnostic(ir, expr_diagnostic_count, err);
                        had_diagnostics = true;
                    };
                }
            }
            const result_diagnostic_count = ir.diagnostics.items.len;
            checkTypeAnnotation(ir, sema, module_id, func.result_type, origin) catch |err| {
                try continueAfterDiagnostic(ir, result_diagnostic_count, err);
                had_diagnostics = true;
            };
        }

        for (module.program.constants.items) |constant_decl| {
            const origin = try originForModuleSpan(allocator, origin_path, constant_decl.span);
            defer allocator.free(origin);
            const type_diagnostic_count = ir.diagnostics.items.len;
            checkTypeAnnotation(ir, sema, module_id, constant_decl.value_type, origin) catch |err| {
                try continueAfterDiagnostic(ir, type_diagnostic_count, err);
                had_diagnostics = true;
            };
            const expr_diagnostic_count = ir.diagnostics.items.len;
            checkExprTypeAnnotations(allocator, ir, sema, module_id, origin_path, constant_decl.value) catch |err| {
                try continueAfterDiagnostic(ir, expr_diagnostic_count, err);
                had_diagnostics = true;
            };
        }

        for (module.program.document_statements.items) |stmt| {
            const diagnostic_count = ir.diagnostics.items.len;
            checkStatementTypeAnnotations(allocator, ir, sema, module_id, origin_path, stmt) catch |err| {
                try continueAfterDiagnostic(ir, diagnostic_count, err);
                had_diagnostics = true;
            };
        }
        for (module.program.pages.items) |page| {
            for (page.statements.items) |stmt| {
                const diagnostic_count = ir.diagnostics.items.len;
                checkStatementTypeAnnotations(allocator, ir, sema, module_id, origin_path, stmt) catch |err| {
                    try continueAfterDiagnostic(ir, diagnostic_count, err);
                    had_diagnostics = true;
                };
            }
        }
    }
    if (had_diagnostics) return error.DiagnosticsFailed;
}

fn checkFieldTypeAnnotation(
    allocator: std.mem.Allocator,
    ir: *core.Ir,
    sema: *const SemanticEnv,
    module_id: core.SourceModuleId,
    origin_path: []const u8,
    field: ast.ObjectFieldDecl,
) !void {
    const origin = try originForModuleSpan(allocator, origin_path, field.span);
    defer allocator.free(origin);
    var had_diagnostics = false;
    const type_diagnostic_count = ir.diagnostics.items.len;
    checkTypeAnnotation(ir, sema, module_id, field.value_type, origin) catch |err| {
        try continueAfterDiagnostic(ir, type_diagnostic_count, err);
        had_diagnostics = true;
    };
    if (field.default_value) |default_value| {
        const expr_diagnostic_count = ir.diagnostics.items.len;
        checkExprTypeAnnotations(allocator, ir, sema, module_id, origin_path, default_value.*) catch |err| {
            try continueAfterDiagnostic(ir, expr_diagnostic_count, err);
            had_diagnostics = true;
        };
    }
    if (had_diagnostics) return error.DiagnosticsFailed;
}

fn resolveTypeReferences(
    allocator: std.mem.Allocator,
    ir: *core.Ir,
    sema: *const SemanticEnv,
) !void {
    for (ir.modules.items) |*module| {
        try resolveProgramTypeReferences(allocator, &module.program, module.id, sema);
    }
}

fn resolveProgramTypeReferences(
    allocator: std.mem.Allocator,
    program: *ast.Program,
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
        .property_set => |*property_set| try resolveExprTypeReferences(allocator, &property_set.value, module_id, sema),
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
    var value = (try staticPropertyValueFromExpr(allocator, expr)) orelse return null;
    defer value.deinit(allocator);
    if (value == .none) return try allocator.dupe(u8, "none");
    const text = try core.value_text.propertyString(allocator, value);
    if (core.value_text.propertyStringNeedsFree(value)) return text;
    return try allocator.dupe(u8, text);
}

fn staticPropertyValueFromExpr(allocator: std.mem.Allocator, expr: ast.Expr) anyerror!?core.Value {
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
        .record => |record| try staticRecordPropertyValue(allocator, record),
        .call => |call| staticNumericPropertyValue(call),
        else => null,
    };
}

fn staticRecordPropertyValue(allocator: std.mem.Allocator, record_expr: ast.RecordExpr) anyerror!?core.Value {
    var record = core.RecordValue.init(record_expr.type_name);
    errdefer record.deinit(allocator);
    for (record_expr.fields.items) |field| {
        var value = (try staticPropertyValueFromExpr(allocator, field.value)) orelse {
            record.deinit(allocator);
            return null;
        };
        errdefer value.deinit(allocator);
        try record.fields.append(allocator, .{
            .name = field.name,
            .value = value,
            .explicit = true,
        });
    }
    return .{ .record = record };
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

fn rebuildConstDeclarations(
    allocator: std.mem.Allocator,
    ir: *core.Ir,
) !void {
    _ = allocator;
    ir.constants.clearRetainingCapacity();
    for (ir.module_order.items) |module_id| {
        const module = ir.moduleById(module_id) orelse continue;
        try appendConstDeclarations(&ir.constants, module.program, module.id);
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
        .hole => {},
        .let_binding => |binding| {
            const origin = try originForModuleSpan(allocator, origin_path, stmt.span);
            defer allocator.free(origin);
            var had_diagnostics = false;
            if (binding.type_annotation) |annotation| {
                const diagnostic_count = ir.diagnostics.items.len;
                checkTypeAnnotation(ir, sema, module_id, annotation, origin) catch |err| {
                    try continueAfterDiagnostic(ir, diagnostic_count, err);
                    had_diagnostics = true;
                };
            }
            const expr_diagnostic_count = ir.diagnostics.items.len;
            checkExprTypeAnnotations(allocator, ir, sema, module_id, origin_path, binding.expr) catch |err| {
                try continueAfterDiagnostic(ir, expr_diagnostic_count, err);
                had_diagnostics = true;
            };
            if (had_diagnostics) return error.DiagnosticsFailed;
        },
        .return_expr => |expr| try checkExprTypeAnnotations(allocator, ir, sema, module_id, origin_path, expr),
        .return_void => {},
        .property_set => |property_set| try checkExprTypeAnnotations(allocator, ir, sema, module_id, origin_path, property_set.value),
        .if_stmt => |if_stmt| {
            try checkExprTypeAnnotations(allocator, ir, sema, module_id, origin_path, if_stmt.condition);
            var had_diagnostics = false;
            for (if_stmt.then_statements.items) |nested| {
                const diagnostic_count = ir.diagnostics.items.len;
                checkStatementTypeAnnotations(allocator, ir, sema, module_id, origin_path, nested) catch |err| {
                    try continueAfterDiagnostic(ir, diagnostic_count, err);
                    had_diagnostics = true;
                };
            }
            for (if_stmt.else_statements.items) |nested| {
                const diagnostic_count = ir.diagnostics.items.len;
                checkStatementTypeAnnotations(allocator, ir, sema, module_id, origin_path, nested) catch |err| {
                    try continueAfterDiagnostic(ir, diagnostic_count, err);
                    had_diagnostics = true;
                };
            }
            if (had_diagnostics) return error.DiagnosticsFailed;
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
        .ident, .hole, .string, .color, .number, .boolean, .none, .enum_case => {},
        .call => |call| {
            var had_diagnostics = false;
            for (call.args.items) |arg| {
                const diagnostic_count = ir.diagnostics.items.len;
                checkExprTypeAnnotations(allocator, ir, sema, module_id, origin_path, arg) catch |err| {
                    try continueAfterDiagnostic(ir, diagnostic_count, err);
                    had_diagnostics = true;
                };
            }
            if (had_diagnostics) return error.DiagnosticsFailed;
        },
        .apply => |apply| {
            try checkExprTypeAnnotations(allocator, ir, sema, module_id, origin_path, apply.callee.*);
            var had_diagnostics = false;
            for (apply.args.items) |arg| {
                const diagnostic_count = ir.diagnostics.items.len;
                checkExprTypeAnnotations(allocator, ir, sema, module_id, origin_path, arg) catch |err| {
                    try continueAfterDiagnostic(ir, diagnostic_count, err);
                    had_diagnostics = true;
                };
            }
            if (had_diagnostics) return error.DiagnosticsFailed;
        },
        .lambda => |lambda| {
            const origin = try originForModuleSpan(allocator, origin_path, lambda.span);
            defer allocator.free(origin);
            var had_diagnostics = false;
            for (lambda.params.items) |param| {
                const diagnostic_count = ir.diagnostics.items.len;
                checkTypeAnnotation(ir, sema, module_id, param.ty, origin) catch |err| {
                    try continueAfterDiagnostic(ir, diagnostic_count, err);
                    had_diagnostics = true;
                };
            }
            const body_diagnostic_count = ir.diagnostics.items.len;
            checkExprTypeAnnotations(allocator, ir, sema, module_id, origin_path, lambda.body.*) catch |err| {
                try continueAfterDiagnostic(ir, body_diagnostic_count, err);
                had_diagnostics = true;
            };
            if (had_diagnostics) return error.DiagnosticsFailed;
        },
        .record => |record| {
            var had_diagnostics = false;
            for (record.fields.items) |field| {
                const diagnostic_count = ir.diagnostics.items.len;
                checkExprTypeAnnotations(allocator, ir, sema, module_id, origin_path, field.value) catch |err| {
                    try continueAfterDiagnostic(ir, diagnostic_count, err);
                    had_diagnostics = true;
                };
            }
            if (had_diagnostics) return error.DiagnosticsFailed;
        },
        .record_update => |update| {
            try checkExprTypeAnnotations(allocator, ir, sema, module_id, origin_path, update.target.*);
            var had_diagnostics = false;
            for (update.fields.items) |field| {
                const diagnostic_count = ir.diagnostics.items.len;
                checkExprTypeAnnotations(allocator, ir, sema, module_id, origin_path, field.value) catch |err| {
                    try continueAfterDiagnostic(ir, diagnostic_count, err);
                    had_diagnostics = true;
                };
            }
            if (had_diagnostics) return error.DiagnosticsFailed;
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
    if (ty.kind == .enum_type or ty.kind == .color or ty.kind == .none or ty.kind == .hole) return;
    if (ty.kind == .optional) {
        if (ty.optional_child) |child| try checkTypeAnnotation(ir, sema, module_id, child.*, origin);
        return;
    }
    if (ty.kind == .record) {
        const record_name = ty.class_name orelse return;
        if (!sema.recordExists(record_name)) return reportUnknownType(ir, origin, record_name);
    } else if (ty.class_name) |class_name| {
        if (!sema.classExists(class_name)) {
            return reportUnknownType(ir, origin, class_name);
        }
    }
    if (ty.param_class_name) |class_name| {
        if (!sema.classExists(class_name)) return reportUnknownType(ir, origin, class_name);
    }
    if (ty.kind == .function) {
        var had_diagnostics = false;
        for (ty.fn_params) |param| {
            const diagnostic_count = ir.diagnostics.items.len;
            checkTypeAnnotation(ir, sema, module_id, param, origin) catch |err| {
                try continueAfterDiagnostic(ir, diagnostic_count, err);
                had_diagnostics = true;
            };
        }
        if (ty.fn_result) |result| {
            const diagnostic_count = ir.diagnostics.items.len;
            checkTypeAnnotation(ir, sema, module_id, result.*, origin) catch |err| {
                try continueAfterDiagnostic(ir, diagnostic_count, err);
                had_diagnostics = true;
            };
        }
        if (had_diagnostics) return error.DiagnosticsFailed;
    }
}

fn reportUnknownType(ir: *core.Ir, origin: []const u8, type_name: []const u8) !void {
    try ir.addValidationDiagnostic(.@"error", null, null, origin, .{
        .user_report = .{ .message = try std.fmt.allocPrint(ir.allocator, "UnknownType: unknown type: {s}", .{type_name}) },
    });
    return error.UnknownType;
}

fn checkDuplicateValueDeclarations(
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
        for (module.program.constants.items) |constant_decl| {
            if (names.contains(constant_decl.name)) {
                const origin = try originForModuleSpan(allocator, origin_path, constant_decl.span);
                defer allocator.free(origin);
                try ir.addValidationDiagnostic(.@"error", null, null, origin, .{
                    .user_report = .{ .message = try std.fmt.allocPrint(ir.allocator, "DuplicateValue: value '{s}' is already defined in this module", .{constant_decl.name}) },
                });
                return error.DiagnosticsFailed;
            }
            try names.put(constant_decl.name, {});
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
            const param_span = param.name_span orelse func.span;
            try appendScopedVariable(allocator, &variables, param.name, info, module_id, func_scope, param_span.start, param_span.end, func.span.start, func.span.end);
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

fn appendConstDeclarations(
    constants: *core.ConstMap,
    program: ast.Program,
    module_id: core.SourceModuleId,
) !void {
    for (program.constants.items) |constant_decl| {
        try constants.put(core.constKey(module_id, constant_decl.name), constant_decl);
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
    if (options.parse_holes) |holes| {
        try addParseHoleDiagnostics(&ir, holes);
    }

    ir.constants = index.constants;
    index.constants = core.ConstMap.init(allocator);
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
        try rebuildConstDeclarations(allocator, &ir);
        try rebuildFunctionDeclarations(allocator, &ir);
    }
    const variable_diagnostic_ir: ?*core.Ir = if (options.allow_diagnostics) null else &ir;
    var variable_infos: ?std.StringHashMap(VariableInfo) = collectVariableInfoFromProgram(allocator, &ir.functions, ir.projectProgram(), variable_diagnostic_ir) catch |err| blk: {
        if (!options.allow_diagnostics) {
            printIrDiagnosticsOrFallback(&ir, err);
            return error.DiagnosticsFailed;
        }
        break :blk null;
    };
    if (variable_infos) |*infos| infos.deinit();
    try analysis_index.populateIrAnalysis(allocator, &ir);
    return ir;
}

fn addParseHoleDiagnostics(ir: *core.Ir, holes: syntax_hole.Result) !void {
    const origin_path = ir.projectPath();
    for (holes.diagnostics) |diagnostic| {
        const origin = try originForModuleSpan(ir.allocator, origin_path, diagnostic.span);
        defer ir.allocator.free(origin);
        var message_buf: [256]u8 = undefined;
        const message_text = utils.err.formatParseDiagnostic(&message_buf, diagnostic);
        try ir.addValidationDiagnostic(.@"error", null, null, origin, .{
            .user_report = .{ .message = try ir.allocator.dupe(u8, message_text) },
        });
    }
}

fn printIrDiagnosticsOrFallback(ir: *core.Ir, err: anyerror) void {
    if (utils.err.hasIrErrors(ir)) {
        utils.err.printIrDiagnostics(ir.projectPath(), ir.projectSource(), ir);
    } else {
        var message_buf: [128]u8 = undefined;
        utils.err.print(.{
            .path = ir.projectPath(),
            .source = ir.projectSource(),
            .severity = .@"error",
            .message = std.fmt.bufPrint(&message_buf, "BuildFailed: {s}", .{@errorName(err)}) catch "BuildFailed: internal analysis failure",
            .span = null,
        });
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
    recovering: bool = false,
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
        .recovering = options.recovering,
    });
    errdefer graph.deinit();

    var index = ProgramIndex{
        .allocator = allocator,
        .modules = graph.modules,
        .module_order = graph.module_order,
        .project_implicit_import_ids = graph.project_implicit_import_ids,
        .project_import_ids = graph.project_import_ids,
        .constants = core.ConstMap.init(allocator),
        .functions = core.FunctionMap.init(allocator),
    };
    graph.modules = .empty;
    graph.module_order = .empty;
    graph.project_implicit_import_ids = .empty;
    graph.project_import_ids = .empty;

    errdefer index.deinit();

    for (index.module_order.items) |module_id| {
        const module = findModuleById(index.modules.items, module_id) orelse continue;
        try appendConstDeclarations(&index.constants, module.program, module.id);
        try appendFunctionDeclarations(&index.functions, module.program, module.id);
    }
    try appendConstDeclarations(&index.constants, project_program, 0);
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
        .hole => {},
        .let_binding => |binding| {
            const inferred = try inferExprInfo(allocator, diagnostic_ir, sema, env, binding.expr, origin);
            const info = letBindingInfo(binding, inferred);
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
        .hole => {},
        .let_binding => |binding| {
            const inferred = try inferExprInfo(allocator, diagnostic_ir, sema, env, binding.expr, origin);
            const info = letBindingInfo(binding, inferred);
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

fn letBindingInfo(binding: anytype, inferred: VariableInfo) VariableInfo {
    if (binding.type_annotation) |annotation| return semantic_types.infoFromType(annotation);
    return inferred;
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
