const std = @import("std");
const core = @import("core");
const ast = @import("ast");
const declarations = @import("../language/declarations.zig");
const language_names = @import("../language/names.zig");
const semantic_env = @import("../language/env.zig");
const module_index = @import("module_index.zig");
const calls = @import("calls.zig");
const checker = @import("check.zig");
const dependencies = @import("dependencies.zig");
const fields = @import("fields.zig");
const infer = @import("infer.zig");
const analysis_index = @import("index.zig");
const registry = @import("../language/registry.zig");
const execution = @import("execution.zig");
const analysis_scope = @import("scope.zig");
const semantic_types = @import("types.zig");
const semantics = @import("semantics.zig");
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
const FunctionBoolMap = std.HashMap(core.FunctionKey, bool, core.FunctionKeyContext, std.hash_map.default_max_load_percentage);
const FunctionVisitSet = std.HashMap(core.FunctionKey, void, core.FunctionKeyContext, std.hash_map.default_max_load_percentage);

pub const BuildDocumentStateOptions = struct {
    allow_diagnostics: bool = false,
    parse_holes: ?syntax_hole.Result = null,
};

pub const AnalysisMode = enum {
    diagnostics_only,
    evaluation,
};

pub fn collectFunctionsFromModules(
    allocator: std.mem.Allocator,
    programs: []const *const ast.Module,
) !core.FunctionMap {
    var functions = core.FunctionMap.init(allocator);
    for (programs, 0..) |program, program_index| {
        for (program.functions.items) |func| {
            try functions.put(core.functionKey(@intCast(program_index), func.name), func);
        }
    }
    return functions;
}

pub fn collectConstantsFromModules(
    allocator: std.mem.Allocator,
    programs: []const *const ast.Module,
) !core.ConstMap {
    var constants = core.ConstMap.init(allocator);
    for (programs, 0..) |program, program_index| {
        for (program.constants.items) |constant_decl| {
            try constants.put(core.constKey(@intCast(program_index), constant_decl.name), constant_decl);
        }
    }
    return constants;
}

pub fn checkFunctionDefinitions(
    allocator: std.mem.Allocator,
    state: *core.DocumentState,
    functions: *const core.FunctionMap,
) !void {
    var declaration_index = try declarations.build(allocator, state);
    defer declaration_index.deinit();
    const sema = SemanticEnv.init(state, &declaration_index, functions);
    try checkFunctionDefinitionsWithEnv(allocator, state, &sema);
}

fn checkFunctionDefinitionsWithEnv(
    allocator: std.mem.Allocator,
    state: *core.DocumentState,
    sema: *const SemanticEnv,
) !void {
    {
        const measure_start = utils.measure_profile.start();
        defer utils.measure_profile.recordAnalysis(.semantics_call_graph, measure_start);
        try calls.checkFunctionCallGraph(allocator, state, sema);
    }

    const bodies_start = utils.measure_profile.start();
    defer utils.measure_profile.recordAnalysis(.semantics_function_bodies, bodies_start);
    var had_diagnostics = false;
    var const_it = state.constants.iterator();
    while (const_it.next()) |entry| {
        const module_id = entry.key_ptr.module_id;
        const origin_path = blk: {
            if (state.moduleById(module_id)) |module| break :blk checker.originPathForModule(module);
            break :blk "";
        };
        const module_sema = sema.forModule(module_id);
        const diagnostic_count = state.diagnostics.items.len;
        checker.checkConst(allocator, state, &module_sema, origin_path, entry.value_ptr.*) catch |err| {
            try checker.continueAfterDiagnostic(state, diagnostic_count, err);
            had_diagnostics = true;
        };
    }

    var it = sema.functions.iterator();
    while (it.next()) |entry| {
        const module_id = entry.key_ptr.module_id;
        const origin_path = blk: {
            if (state.moduleById(module_id)) |module| break :blk checker.originPathForModule(module);
            break :blk "";
        };
        const module_sema = sema.forModule(module_id);
        const diagnostic_count = state.diagnostics.items.len;
        checker.checkFunction(allocator, state, &module_sema, origin_path, entry.value_ptr.*) catch |err| {
            try checker.continueAfterDiagnostic(state, diagnostic_count, err);
            had_diagnostics = true;
        };
    }
    if (had_diagnostics) return error.DiagnosticsFailed;
}

pub fn analyzeDocumentState(
    allocator: std.mem.Allocator,
    state: *core.DocumentState,
) !void {
    defer state.deduplicateValidationUserReports();
    var declaration_index: declarations.DeclarationIndex = undefined;
    {
        const measure_start = utils.measure_profile.start();
        defer utils.measure_profile.recordAnalysis(.static_semantics, measure_start);
        declaration_index = try analyzeDocumentStateSemantics(allocator, state);
    }
    defer declaration_index.deinit();
    {
        const measure_start = utils.measure_profile.start();
        defer utils.measure_profile.recordAnalysis(.execution_graph, measure_start);
        try execution.validateDependencies(allocator, state, &declaration_index);
    }
}

pub fn analyzeDocumentStateWithMode(
    allocator: std.mem.Allocator,
    state: *core.DocumentState,
    mode: AnalysisMode,
) !?execution.ExecutionGraph {
    defer state.deduplicateValidationUserReports();
    var declaration_index: declarations.DeclarationIndex = undefined;
    {
        const measure_start = utils.measure_profile.start();
        defer utils.measure_profile.recordAnalysis(.static_semantics, measure_start);
        declaration_index = try analyzeDocumentStateSemantics(allocator, state);
    }
    defer declaration_index.deinit();
    const measure_start = utils.measure_profile.start();
    defer utils.measure_profile.recordAnalysis(.execution_graph, measure_start);
    return switch (mode) {
        .diagnostics_only => blk: {
            try execution.validateDependencies(allocator, state, &declaration_index);
            break :blk null;
        },
        .evaluation => try execution.ExecutionGraph.build(allocator, state, state, &declaration_index, .{ .page_id_mode = .create }),
    };
}

fn analyzeDocumentStateSemantics(
    allocator: std.mem.Allocator,
    state: *core.DocumentState,
) !declarations.DeclarationIndex {
    var declaration_index = try declarations.build(allocator, state);
    errdefer declaration_index.deinit();
    const sema = SemanticEnv.init(state, &declaration_index, &state.functions);

    {
        const measure_start = utils.measure_profile.start();
        defer utils.measure_profile.recordAnalysis(.semantics_types, measure_start);
        try semantics.checkTypeDeclarations(allocator, state);
    }
    {
        const measure_start = utils.measure_profile.start();
        defer utils.measure_profile.recordAnalysis(.semantics_fields, measure_start);
        try semantics.checkDuplicateValueDeclarations(allocator, state);
        try semantics.checkTypeAnnotations(allocator, state, &sema);
        {
            const object_declarations_start = utils.measure_profile.start();
            defer utils.measure_profile.recordAnalysis(.semantics_object_declarations, object_declarations_start);
            try fields.checkObjectDeclarations(allocator, state, &sema);
        }
        try checker.checkPageNamesUnique(allocator, state);
        {
            const placement_effects_start = utils.measure_profile.start();
            defer utils.measure_profile.recordAnalysis(.semantics_placement_effects, placement_effects_start);
            try checkPlacementEffectDeclarations(allocator, state, &sema);
        }
    }
    {
        const measure_start = utils.measure_profile.start();
        defer utils.measure_profile.recordAnalysis(.semantics_functions, measure_start);
        try checkFunctionDefinitionsWithEnv(allocator, state, &sema);
    }
    {
        const measure_start = utils.measure_profile.start();
        defer utils.measure_profile.recordAnalysis(.semantics_pages, measure_start);
        for (state.module_order.items) |module_id| {
            const module = state.moduleById(module_id) orelse continue;
            const module_sema = sema.forModule(module_id);
            try checker.checkPageStatements(allocator, state, &module_sema, checker.originPathForModule(module), module.syntax);
        }
    }
    {
        const measure_start = utils.measure_profile.start();
        defer utils.measure_profile.recordAnalysis(.semantics_dependency_queries, measure_start);
        try addDependencyQueryDiagnostics(allocator, state, &sema);
    }
    return declaration_index;
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

fn addDependencyQueryDiagnostics(allocator: std.mem.Allocator, state: *core.DocumentState, sema: *const SemanticEnv) !void {
    for (state.module_order.items) |module_id| {
        const module = state.moduleById(module_id) orelse continue;
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
            const message = try dependencies.formatAccessSummaryWithOptions(state.allocator, summary, .{
                .variable_scope_displays = &scope_displays,
                .pages_scope_displays = &scope_displays,
            });
            errdefer state.allocator.free(message);
            const origin = try queryOrigin(allocator, module, query.span);
            defer allocator.free(origin);
            try state.addValidationDiagnostic(.warning, null, null, origin, .{
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
    for (module.syntax.document_statements.items, 0..) |stmt, index| {
        updateDependencyQueryTarget(&best, &best_end, stmt, module.syntax.document_statements.items[0..index], .{ .document = module.id }, document_display, query_start);
    }
    for (module.syntax.pages.items, 0..) |page, page_index| {
        const page_scope = dependencies.ResourceScope{ .page = dependencyQuerySyntheticPageId(page_index) };
        const page_display = dependencies.ScopeDisplayName{ .page = page.name };
        for (page.statements.items, 0..) |stmt, index| {
            updateDependencyQueryTarget(&best, &best_end, stmt, page.statements.items[0..index], page_scope, page_display, query_start);
        }
    }
    const caller_display: dependencies.ScopeDisplayName = .caller;
    for (module.syntax.functions.items) |func| {
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

fn checkPlacementEffectDeclarations(allocator: std.mem.Allocator, state: *core.DocumentState, sema: *const SemanticEnv) !void {
    var analyzer = PlacementEffectAnalyzer.init(allocator, sema);
    defer analyzer.deinit();
    var it = state.functions.iterator();
    while (it.next()) |entry| {
        const func = entry.value_ptr.*;
        if (dependencies.callableNamePlacesObjects(func.name)) continue;
        const module_id = entry.key_ptr.module_id;
        if (!try analyzer.functionBody(entry.key_ptr.*, module_id, func)) continue;
        const origin = try functionOrigin(allocator, state, module_id, func.name);
        defer allocator.free(origin);
        try state.addValidationDiagnostic(.@"error", null, null, origin, .{
            .user_report = .{ .message = try std.fmt.allocPrint(state.allocator, "PlacementEffect: function '{s}' calls a placing operation and must end with '!'", .{func.name}) },
        });
        return error.DiagnosticsFailed;
    }
}

const PlacementEffectAnalyzer = struct {
    allocator: std.mem.Allocator,
    root_sema: SemanticEnv,
    function_memo: FunctionBoolMap,
    function_visiting: FunctionVisitSet,
    const_memo: FunctionBoolMap,
    const_visiting: FunctionVisitSet,

    fn init(allocator: std.mem.Allocator, sema: *const SemanticEnv) PlacementEffectAnalyzer {
        return .{
            .allocator = allocator,
            .root_sema = sema.*,
            .function_memo = FunctionBoolMap.init(allocator),
            .function_visiting = FunctionVisitSet.init(allocator),
            .const_memo = FunctionBoolMap.init(allocator),
            .const_visiting = FunctionVisitSet.init(allocator),
        };
    }

    fn deinit(self: *PlacementEffectAnalyzer) void {
        self.const_visiting.deinit();
        self.const_memo.deinit();
        self.function_visiting.deinit();
        self.function_memo.deinit();
    }

    fn functionBody(
        self: *PlacementEffectAnalyzer,
        key: core.FunctionKey,
        module_id: core.SourceModuleId,
        func: ast.FunctionDecl,
    ) !bool {
        if (self.function_memo.get(key)) |cached| return cached;
        if (self.function_visiting.contains(key)) return false;
        try self.function_visiting.put(key, {});
        defer _ = self.function_visiting.remove(key);

        var locals = std.StringHashMap(void).init(self.allocator);
        defer locals.deinit();
        for (func.params.items) |param| try locals.put(param.name, {});
        const sema = self.root_sema.forModule(module_id);
        const places_objects = try self.statements(&sema, &locals, func.statements.items);
        try self.function_memo.put(key, places_objects);
        return places_objects;
    }

    fn constValue(
        self: *PlacementEffectAnalyzer,
        resolved: semantic_env.ResolvedConst,
    ) !bool {
        if (self.const_memo.get(resolved.key)) |cached| return cached;
        if (self.const_visiting.contains(resolved.key)) return false;
        try self.const_visiting.put(resolved.key, {});
        defer _ = self.const_visiting.remove(resolved.key);

        var locals = std.StringHashMap(void).init(self.allocator);
        defer locals.deinit();
        const const_sema = self.root_sema.forModule(resolved.module_id);
        const places_objects = try self.expr(&const_sema, &locals, resolved.decl.value);
        try self.const_memo.put(resolved.key, places_objects);
        return places_objects;
    }

    fn statements(
        self: *PlacementEffectAnalyzer,
        sema: *const SemanticEnv,
        locals: *std.StringHashMap(void),
        statements_list: []const ast.Statement,
    ) anyerror!bool {
        for (statements_list) |stmt| {
            if (try self.statement(sema, locals, stmt)) return true;
        }
        return false;
    }

    fn statement(
        self: *PlacementEffectAnalyzer,
        sema: *const SemanticEnv,
        locals: *std.StringHashMap(void),
        stmt: ast.Statement,
    ) anyerror!bool {
        return switch (stmt.kind) {
            .hole, .return_void => false,
            .let_binding => |binding| blk: {
                if (try self.expr(sema, locals, binding.expr)) break :blk true;
                if (!language_names.isDiscardBindingName(binding.name)) try locals.put(binding.name, {});
                break :blk false;
            },
            .return_expr => |return_value| try self.expr(sema, locals, return_value),
            .property_set => |property_set| (try self.expr(sema, locals, property_set.target)) or
                (try self.expr(sema, locals, property_set.value)),
            .expr_stmt => |expression| try self.expr(sema, locals, expression),
            .constrain => |constraint| if (constraint.offset) |offset| try self.expr(sema, locals, offset) else false,
            .if_stmt => |if_stmt| blk: {
                if (try self.expr(sema, locals, if_stmt.condition)) break :blk true;
                var then_locals = try locals.clone();
                defer then_locals.deinit();
                if (try self.statements(sema, &then_locals, if_stmt.then_statements.items)) break :blk true;
                var else_locals = try locals.clone();
                defer else_locals.deinit();
                break :blk try self.statements(sema, &else_locals, if_stmt.else_statements.items);
            },
        };
    }

    fn expr(
        self: *PlacementEffectAnalyzer,
        sema: *const SemanticEnv,
        locals: *const std.StringHashMap(void),
        value: ast.Expr,
    ) anyerror!bool {
        return switch (value) {
            .hole,
            .string,
            .color,
            .number,
            .boolean,
            .none,
            .enum_case,
            => false,
            .ident => |ident| blk: {
                if (locals.contains(ident.name)) break :blk false;
                const resolved = sema.resolvedConst(ast.CallableName.bare(ident.name)) orelse break :blk false;
                break :blk try self.constValue(resolved);
            },
            .lambda => |lambda| blk: {
                var lambda_locals = try locals.clone();
                defer lambda_locals.deinit();
                for (lambda.params.items) |param| try lambda_locals.put(param.name, {});
                break :blk try self.expr(sema, &lambda_locals, lambda.body.*);
            },
            .record => |record| blk: {
                for (record.fields.items) |field| {
                    if (try self.expr(sema, locals, field.value)) break :blk true;
                }
                break :blk false;
            },
            .record_update => |update| blk: {
                if (try self.expr(sema, locals, update.target.*)) break :blk true;
                for (update.fields.items) |field| {
                    if (try self.expr(sema, locals, field.value)) break :blk true;
                }
                break :blk false;
            },
            .apply => |apply| blk: {
                if (try self.expr(sema, locals, apply.callee.*)) break :blk true;
                break :blk try self.exprList(sema, locals, apply.args.items);
            },
            .member => |member| try self.expr(sema, locals, member.target.*),
            .optional_check => |check| try self.expr(sema, locals, check.target.*),
            .coalesce => |coalesce| (try self.expr(sema, locals, coalesce.target.*)) or
                (try self.expr(sema, locals, coalesce.fallback.*)),
            .call => |call_expr| try self.call(sema, locals, call_expr),
        };
    }

    fn exprList(
        self: *PlacementEffectAnalyzer,
        sema: *const SemanticEnv,
        locals: *const std.StringHashMap(void),
        expressions: []const ast.Expr,
    ) anyerror!bool {
        for (expressions) |expr_value| {
            if (try self.expr(sema, locals, expr_value)) return true;
        }
        return false;
    }

    fn call(
        self: *PlacementEffectAnalyzer,
        sema: *const SemanticEnv,
        locals: *const std.StringHashMap(void),
        call_expr: ast.CallExpr,
    ) anyerror!bool {
        if (try self.exprList(sema, locals, call_expr.args.items)) return true;
        if (!call_expr.callee.isQualified() and locals.contains(call_expr.callee.name)) return false;
        if (sema.resolvedConst(call_expr.callee)) |resolved| {
            return try self.constValue(resolved);
        }
        const descriptor = sema.callCallee(call_expr.callee) orelse return false;
        return switch (descriptor) {
            .primitive => |primitive| primitive.places_objects or
                try self.primitiveCallback(sema, locals, call_expr, primitive),
            .function => |resolved| blk: {
                if (dependencies.callableNamePlacesObjects(call_expr.callee.name)) break :blk true;
                break :blk try self.functionBody(resolved.key, resolved.module_id, resolved.decl);
            },
        };
    }

    fn primitiveCallback(
        self: *PlacementEffectAnalyzer,
        sema: *const SemanticEnv,
        locals: *const std.StringHashMap(void),
        call_expr: ast.CallExpr,
        primitive: registry.PrimitiveDescriptor,
    ) !bool {
        const callback = primitive.callback orelse return false;
        if (call_expr.args.items.len <= callback.function_arg_index) return false;
        const callback_expr = call_expr.args.items[callback.function_arg_index];
        return switch (callback_expr) {
            .ident => |ident| blk: {
                if (locals.contains(ident.name)) break :blk false;
                const resolved = sema.resolvedFunction(ast.CallableName.bare(ident.name)) orelse break :blk false;
                break :blk try self.functionBody(resolved.key, resolved.module_id, resolved.decl);
            },
            else => false,
        };
    }
};

fn functionOrigin(
    allocator: std.mem.Allocator,
    state: *const core.DocumentState,
    module_id: core.SourceModuleId,
    function_name: []const u8,
) ![]const u8 {
    const module = state.moduleById(module_id);
    const path = if (module) |m| m.path orelse m.spec else "";
    if (module) |m| {
        for (m.syntax.functions.items) |func| {
            if (!std.mem.eql(u8, func.name, function_name)) continue;
            if (path.len == 0) return std.fmt.allocPrint(allocator, "bytes:{d}-{d}", .{ func.span.start, func.span.end });
            return std.fmt.allocPrint(allocator, "path:{s}:bytes:{d}-{d}", .{ path, func.span.start, func.span.end });
        }
    }
    if (path.len == 0) return std.fmt.allocPrint(allocator, "function:{s}", .{function_name});
    return std.fmt.allocPrint(allocator, "path:{s}", .{path});
}

pub fn collectVariableInfoFromModule(
    allocator: std.mem.Allocator,
    functions: *const core.FunctionMap,
    program: ast.Module,
    diagnostic_state: ?*core.DocumentState,
) !std.StringHashMap(VariableInfo) {
    var declaration_index: ?declarations.DeclarationIndex = if (diagnostic_state) |state|
        try declarations.build(allocator, state)
    else
        null;
    defer if (declaration_index) |*index| index.deinit();
    const declaration_ptr = if (declaration_index) |*index| index else null;
    const sema = SemanticEnv.init(diagnostic_state, declaration_ptr, functions);
    var variables = std.StringHashMap(VariableInfo).init(allocator);
    errdefer variables.deinit();

    for (program.functions.items) |func| {
        var env = TypeEnv.init(allocator);
        defer env.deinit();

        for (func.params.items) |param| {
            if (param.default_value) |default_value| {
                const origin = try statementOrigin(allocator, func.span);
                defer allocator.free(origin);
                const info = try inferExprInfo(allocator, diagnostic_state, &sema, &env, default_value.*, origin);
                try ensureType(diagnostic_state, allocator, info, param.ty, origin, .UnmatchedArgumentType);
            }
            const info = semantic_types.infoFromType(param.ty);
            try env.put(param.name, info);
            try variables.put(param.name, info);
        }

        for (func.statements.items) |stmt| {
            try collectVariableTypesFromStatement(allocator, diagnostic_state, &env, &sema, stmt, &variables);
        }
    }

    {
        var env = TypeEnv.init(allocator);
        defer env.deinit();
        for (program.document_statements.items) |stmt| {
            try collectVariableTypesFromStatement(allocator, diagnostic_state, &env, &sema, stmt, &variables);
        }
    }

    for (program.pages.items) |page| {
        var env = TypeEnv.init(allocator);
        defer env.deinit();

        for (page.statements.items) |stmt| {
            try collectVariableTypesFromStatement(allocator, diagnostic_state, &env, &sema, stmt, &variables);
        }
    }

    return variables;
}

pub fn collectScopedVariableInfoFromModule(
    allocator: std.mem.Allocator,
    state: *core.DocumentState,
    declaration_index: *const declarations.DeclarationIndex,
    program: ast.Module,
    module_id: core.SourceModuleId,
    source_len: usize,
) !std.ArrayList(ScopedVariableInfo) {
    const root_sema = SemanticEnv.init(state, declaration_index, &state.functions);
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
                const info = try inferExprInfo(allocator, state, &sema, &env, default_value.*, origin);
                try ensureType(state, allocator, info, param.ty, origin, .UnmatchedArgumentType);
            }
            const info = semantic_types.infoFromType(param.ty);
            try env.put(param.name, info);
            const func_scope = analysis_scope.functionScope(func);
            const param_span = param.name_span orelse func.span;
            try appendScopedVariable(allocator, &variables, param.name, info, module_id, func_scope, param_span.start, param_span.end, func.span.start, func.span.end);
        }

        for (func.statements.items) |stmt| {
            try collectScopedVariableTypesFromStatement(allocator, state, &env, &sema, stmt, &variables, module_id, analysis_scope.functionScope(func), func.span.end);
        }
    }

    {
        var env = TypeEnv.init(allocator);
        defer env.deinit();
        const document_scope = analysis_scope.documentScope(source_len);
        for (program.document_statements.items) |stmt| {
            try collectScopedVariableTypesFromStatement(allocator, state, &env, &sema, stmt, &variables, module_id, document_scope, source_len);
        }
    }

    for (program.pages.items) |page| {
        var env = TypeEnv.init(allocator);
        defer env.deinit();
        const page_scope = analysis_scope.pageScope(page);

        for (page.statements.items) |stmt| {
            try collectScopedVariableTypesFromStatement(allocator, state, &env, &sema, stmt, &variables, module_id, page_scope, page.span.end);
        }
    }

    return variables;
}

pub fn buildDocumentState(
    allocator: std.mem.Allocator,
    input_path: []const u8,
    asset_base_path: []const u8,
    project_source: *[]u8,
    project_syntax: *ast.Module,
    index: *module_index.Index,
) !core.DocumentState {
    return buildDocumentStateWithOptions(allocator, input_path, asset_base_path, project_source, project_syntax, index, .{});
}

pub fn buildDocumentStateWithOptions(
    allocator: std.mem.Allocator,
    input_path: []const u8,
    asset_base_path: []const u8,
    project_source: *[]u8,
    project_syntax: *ast.Module,
    index: *module_index.Index,
    options: BuildDocumentStateOptions,
) !core.DocumentState {
    const measure_start = utils.measure_profile.start();
    defer utils.measure_profile.recordAnalysis(.document_state, measure_start);
    const asset_base_dir = try allocator.dupe(u8, asset_base_path);
    var owns_asset_base_dir = true;
    errdefer if (owns_asset_base_dir) allocator.free(asset_base_dir);
    const project_path = try allocator.dupe(u8, input_path);
    var owns_project_path = true;
    errdefer if (owns_project_path) allocator.free(project_path);
    var state = try core.DocumentState.init(allocator, asset_base_dir, project_path, project_source.*, project_syntax.*);
    owns_asset_base_dir = false;
    owns_project_path = false;
    project_source.* = &.{};
    project_syntax.* = ast.Module.init();
    errdefer state.deinit();
    if (options.parse_holes) |holes| {
        try addParseHoleDiagnostics(&state, holes);
    }

    state.constants = index.constants;
    index.constants = core.ConstMap.init(allocator);
    state.functions = index.functions;
    index.functions = core.FunctionMap.init(allocator);
    state.module_order = index.module_graph.module_order;
    index.module_graph.module_order = .empty;
    state.projectModuleMutable().implicit_import_ids = index.module_graph.project_implicit_import_ids;
    index.module_graph.project_implicit_import_ids = .empty;
    state.projectModuleMutable().resolved_import_ids = index.module_graph.project_import_ids;
    index.module_graph.project_import_ids = .empty;
    for (index.module_graph.modules.items) |module| try state.modules.append(allocator, module);
    index.module_graph.modules = .empty;
    if (state.module_order.items.len == 0 or state.module_order.items[state.module_order.items.len - 1] != state.project_module_id) {
        try state.module_order.append(allocator, state.project_module_id);
    }
    {
        var declaration_index = try declarations.build(allocator, &state);
        defer declaration_index.deinit();
        const sema = SemanticEnv.init(&state, &declaration_index, &state.functions);
        try semantics.resolveTypeReferences(allocator, &state, &sema);
        try semantics.resolveEnumCaseExpressionsAndDefaults(allocator, &state, &sema);
        try semantics.rebuildConstDeclarations(allocator, &state);
        try semantics.rebuildFunctionDeclarations(allocator, &state);
    }
    try analysis_index.populateDocumentStateAnalysis(allocator, &state);
    return state;
}

fn addParseHoleDiagnostics(state: *core.DocumentState, holes: syntax_hole.Result) !void {
    const origin_path = state.projectPath();
    for (holes.diagnostics) |diagnostic| {
        const origin = try checker.sourceOrigin(state.allocator, origin_path, diagnostic.span);
        defer state.allocator.free(origin);
        var message_buf: [256]u8 = undefined;
        const message_text = utils.err.formatParseDiagnostic(&message_buf, diagnostic);
        try state.addValidationDiagnostic(.@"error", null, null, origin, .{
            .user_report = .{ .message = try state.allocator.dupe(u8, message_text) },
        });
    }
}

fn collectVariableTypesFromStatement(
    allocator: std.mem.Allocator,
    diagnostic_state: ?*core.DocumentState,
    env: *TypeEnv,
    sema: *const SemanticEnv,
    stmt: ast.Statement,
    variables: *std.StringHashMap(VariableInfo),
) anyerror!void {
    const diagnostic_count = if (diagnostic_state) |state| state.diagnostics.items.len else 0;
    collectVariableTypesFromStatementUnchecked(allocator, diagnostic_state, env, sema, stmt, variables) catch |err| {
        if (diagnostic_state) |state| {
            if (state.diagnostics.items.len > diagnostic_count) return;
        }
        if (isFactInferenceFailure(err)) return;
        return err;
    };
}

fn collectVariableTypesFromStatementUnchecked(
    allocator: std.mem.Allocator,
    diagnostic_state: ?*core.DocumentState,
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
            const inferred = try inferExprInfo(allocator, diagnostic_state, sema, env, binding.expr, origin);
            const info = letBindingInfo(binding, inferred);
            if (language_names.isDiscardBindingName(binding.name)) return;
            try env.put(binding.name, info);
            try variables.put(binding.name, info);
        },
        .return_expr => |expr| {
            _ = try inferExprInfo(allocator, diagnostic_state, sema, env, expr, origin);
        },
        .return_void => {},
        .property_set => |property_set| {
            _ = try inferExprInfo(allocator, diagnostic_state, sema, env, property_set.target, origin);
            _ = try inferExprInfo(allocator, diagnostic_state, sema, env, property_set.value, origin);
        },
        .if_stmt => |if_stmt| {
            const condition = try inferExprInfo(allocator, diagnostic_state, sema, env, if_stmt.condition, origin);
            try semantic_types.ensureType(diagnostic_state, allocator, condition, ast.Type.boolean, origin, .UnmatchedArgumentType);
            var then_env = try env.clone();
            defer then_env.deinit();
            for (if_stmt.then_statements.items) |nested| {
                try collectVariableTypesFromStatement(allocator, diagnostic_state, &then_env, sema, nested, variables);
            }
            var else_env = try env.clone();
            defer else_env.deinit();
            for (if_stmt.else_statements.items) |nested| {
                try collectVariableTypesFromStatement(allocator, diagnostic_state, &else_env, sema, nested, variables);
            }
        },
        .expr_stmt => |expr| {
            _ = try inferExprInfo(allocator, diagnostic_state, sema, env, expr, origin);
        },
        .constrain => |decl| {
            if (decl.offset) |expr| {
                _ = try inferExprInfo(allocator, diagnostic_state, sema, env, expr, origin);
            }
        },
    }
}

fn collectScopedVariableTypesFromStatement(
    allocator: std.mem.Allocator,
    diagnostic_state: ?*core.DocumentState,
    env: *TypeEnv,
    sema: *const SemanticEnv,
    stmt: ast.Statement,
    variables: *std.ArrayList(ScopedVariableInfo),
    module_id: core.SourceModuleId,
    scope: analysis_scope.SourceScope,
    visible_end: usize,
) anyerror!void {
    const diagnostic_count = if (diagnostic_state) |state| state.diagnostics.items.len else 0;
    collectScopedVariableTypesFromStatementUnchecked(allocator, diagnostic_state, env, sema, stmt, variables, module_id, scope, visible_end) catch |err| {
        if (diagnostic_state) |state| {
            if (state.diagnostics.items.len > diagnostic_count) return;
        }
        if (isFactInferenceFailure(err)) return;
        return err;
    };
}

fn collectScopedVariableTypesFromStatementUnchecked(
    allocator: std.mem.Allocator,
    diagnostic_state: ?*core.DocumentState,
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
            const inferred = try inferExprInfo(allocator, diagnostic_state, sema, env, binding.expr, origin);
            const info = letBindingInfo(binding, inferred);
            if (language_names.isDiscardBindingName(binding.name)) return;
            try env.put(binding.name, info);
            try appendScopedVariable(allocator, variables, binding.name, info, module_id, scope, stmt.span.start, stmt.span.end, stmt.span.start, visible_end);
        },
        .return_expr => |expr| {
            _ = try inferExprInfo(allocator, diagnostic_state, sema, env, expr, origin);
        },
        .return_void => {},
        .property_set => |property_set| {
            _ = try inferExprInfo(allocator, diagnostic_state, sema, env, property_set.target, origin);
            _ = try inferExprInfo(allocator, diagnostic_state, sema, env, property_set.value, origin);
        },
        .if_stmt => |if_stmt| {
            const condition = try inferExprInfo(allocator, diagnostic_state, sema, env, if_stmt.condition, origin);
            try semantic_types.ensureType(diagnostic_state, allocator, condition, ast.Type.boolean, origin, .UnmatchedArgumentType);
            var then_env = try env.clone();
            defer then_env.deinit();
            const then_end = analysis_scope.statementsVisibleEnd(if_stmt.then_statements.items, stmt.span.end);
            for (if_stmt.then_statements.items) |nested| {
                try collectScopedVariableTypesFromStatement(allocator, diagnostic_state, &then_env, sema, nested, variables, module_id, scope, then_end);
            }
            var else_env = try env.clone();
            defer else_env.deinit();
            const else_end = analysis_scope.statementsVisibleEnd(if_stmt.else_statements.items, stmt.span.end);
            for (if_stmt.else_statements.items) |nested| {
                try collectScopedVariableTypesFromStatement(allocator, diagnostic_state, &else_env, sema, nested, variables, module_id, scope, else_end);
            }
        },
        .expr_stmt => |expr| {
            _ = try inferExprInfo(allocator, diagnostic_state, sema, env, expr, origin);
        },
        .constrain => |decl| {
            if (decl.offset) |expr| {
                _ = try inferExprInfo(allocator, diagnostic_state, sema, env, expr, origin);
            }
        },
    }
}

fn letBindingInfo(binding: anytype, inferred: VariableInfo) VariableInfo {
    if (binding.type_annotation) |annotation| return semantic_types.infoFromType(annotation);
    return inferred;
}

fn isFactInferenceFailure(err: anyerror) bool {
    return switch (err) {
        error.DuplicateBinding,
        error.InvalidArity,
        error.InvalidType,
        error.UnknownFunction,
        error.UnknownIdentifier,
        error.UnknownQuery,
        => true,
        else => false,
    };
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
