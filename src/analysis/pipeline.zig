const std = @import("std");
const core = @import("core");
const ast = @import("ast");
const declarations = @import("../language/declarations.zig");
const semantic_env = @import("../language/env.zig");
const module_index = @import("module_index.zig");
const calls = @import("calls.zig");
const checker = @import("check.zig");
const dependencies = @import("dependencies.zig");
const fields = @import("fields.zig");
const infer = @import("infer.zig");
const analysis_index = @import("index.zig");
const execution = @import("execution.zig");
const semantics = @import("semantics.zig");
const syntax = @import("../syntax/parse.zig");
const syntax_hole = @import("../syntax/hole.zig");
const type_defs = @import("../language/type_defs.zig");
const utils = @import("utils");
const SemanticEnv = semantic_env.SemanticEnv;

pub const BuildDocumentStateOptions = struct {
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
            try functions.put(core.functionDeclarationKey(@intCast(program_index), func), func);
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
    const sema = SemanticEnv.init(state, state.declaration_index, functions);
    var inference_context = infer.Context.init(allocator);
    defer inference_context.deinit();
    try checkFunctionDefinitionsWithEnv(&inference_context, allocator, state, &sema);
    try calls.checkFunctionCallGraph(allocator, state, &sema);
}

fn checkFunctionDefinitionsWithEnv(
    inference_context: *infer.Context,
    allocator: std.mem.Allocator,
    state: *core.DocumentState,
    sema: *const SemanticEnv,
) !void {
    {
        const measure_start = utils.measure_profile.start();
        defer utils.measure_profile.recordAnalysis(.semantics_call_graph, measure_start);
        try calls.checkFunctionCallGraphBeforeTypes(allocator, state, sema);
    }

    const bodies_start = utils.measure_profile.start();
    defer utils.measure_profile.recordAnalysis(.semantics_function_bodies, bodies_start);
    var had_diagnostics = false;
    var const_it = state.constants.declarations.iterator();
    while (const_it.next()) |entry| {
        try state.checkAnalysisCanceled();
        const module_id = entry.key_ptr.module_id;
        const origin_path = blk: {
            if (state.moduleById(module_id)) |module| break :blk checker.originPathForModule(module);
            break :blk "";
        };
        const module_sema = sema.forModule(module_id);
        const diagnostic_count = state.diagnostics.entries.items.len;
        checker.checkConst(inference_context, allocator, state, &module_sema, origin_path, entry.value_ptr.*) catch |err| {
            try checker.continueAfterDiagnostic(state, diagnostic_count, err);
            try inference_context.invalid_declarations.put(entry.key_ptr.*, {});
            had_diagnostics = true;
        };
    }

    var keys: std.ArrayList(core.FunctionKey) = .empty;
    defer keys.deinit(allocator);
    var it = sema.functions.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.type_params.items.len != 0 or entry.value_ptr.instance_id != null) continue;
        try keys.append(allocator, entry.key_ptr.*);
    }
    for (keys.items) |key| {
        try state.checkAnalysisCanceled();
        const func = sema.functions.get(key).?;
        const module_id = key.module_id;
        const origin_path = blk: {
            if (state.moduleById(module_id)) |module| break :blk checker.originPathForModule(module);
            break :blk "";
        };
        const module_sema = sema.forModule(module_id);
        const diagnostic_count = state.diagnostics.entries.items.len;
        checker.checkFunction(inference_context, allocator, state, &module_sema, origin_path, func) catch |err| {
            try checker.continueAfterDiagnostic(state, diagnostic_count, err);
            try inference_context.invalid_declarations.put(key, {});
            had_diagnostics = true;
        };
    }
    if (had_diagnostics) return error.DiagnosticsFailed;
}

pub fn analyzeDocumentState(
    allocator: std.mem.Allocator,
    state: *core.DocumentState,
) !void {
    _ = try analyzeDocumentStateWithMode(allocator, state, .diagnostics_only);
}

pub fn analyzeDocumentStateWithMode(
    allocator: std.mem.Allocator,
    state: *core.DocumentState,
    mode: AnalysisMode,
) !?execution.ExecutionGraph {
    defer state.diagnostics.deduplicateValidationUserReports(state.allocator);
    var declaration_index: *const declarations.DeclarationIndex = undefined;
    {
        const measure_start = utils.measure_profile.start();
        defer utils.measure_profile.recordAnalysis(.static_semantics, measure_start);
        declaration_index = try analyzeDocumentStateSemantics(allocator, state);
    }
    const measure_start = utils.measure_profile.start();
    defer utils.measure_profile.recordAnalysis(.execution_graph, measure_start);
    var graph = try execution.ExecutionGraph.build(allocator, state, declaration_index, .{
        .page_id_mode = if (mode == .evaluation) .create else .synthetic,
    });
    errdefer graph.deinit();
    {
        const query_start = utils.measure_profile.start();
        defer utils.measure_profile.recordAnalysis(.semantics_dependency_queries, query_start);
        const sema = SemanticEnv.init(state, declaration_index, &state.functions);
        try addDependencyQueryDiagnostics(allocator, state, &sema, &graph);
    }
    if (mode == .diagnostics_only) {
        graph.deinit();
        return null;
    }
    return graph;
}

fn analyzeDocumentStateSemantics(
    allocator: std.mem.Allocator,
    state: *core.DocumentState,
) !*const declarations.DeclarationIndex {
    const declaration_index = state.declaration_index;
    const sema = SemanticEnv.init(state, declaration_index, &state.functions);
    var inference_context = infer.Context.init(allocator);
    defer inference_context.deinit();

    try checkDocumentDeclarations(allocator, state, &sema);
    try checkDocumentBodies(&inference_context, allocator, state, &sema);
    // Effects of overloaded constructors require the checked argument types.
    try calls.checkFunctionCallGraph(allocator, state, &sema);
    return declaration_index;
}

fn checkDocumentDeclarations(allocator: std.mem.Allocator, state: *core.DocumentState, sema: *const SemanticEnv) !void {
    {
        const measure_start = utils.measure_profile.start();
        defer utils.measure_profile.recordAnalysis(.semantics_types, measure_start);
        try semantics.checkSelectedImports(state, sema);
        try semantics.checkTypeDeclarations(allocator, state);
    }
    {
        const measure_start = utils.measure_profile.start();
        defer utils.measure_profile.recordAnalysis(.semantics_fields, measure_start);
        try semantics.checkDuplicateValueDeclarations(allocator, state);
        try semantics.checkTypeAnnotations(allocator, state, sema);
        try semantics.checkDisplayDeclarations(allocator, state);
        {
            const type_fields_start = utils.measure_profile.start();
            defer utils.measure_profile.recordAnalysis(.semantics_type_fields, type_fields_start);
            try fields.checkTypeFields(allocator, state, sema);
        }
        try checker.checkPageNamesUnique(allocator, state);
    }
}

fn checkDocumentBodies(inference_context: *infer.Context, allocator: std.mem.Allocator, state: *core.DocumentState, sema: *const SemanticEnv) !void {
    var had_body_diagnostics = false;
    {
        const measure_start = utils.measure_profile.start();
        defer utils.measure_profile.recordAnalysis(.semantics_functions, measure_start);
        checkFunctionDefinitionsWithEnv(inference_context, allocator, state, sema) catch |err| {
            if (err != error.DiagnosticsFailed) return err;
            had_body_diagnostics = true;
        };
    }
    {
        const measure_start = utils.measure_profile.start();
        defer utils.measure_profile.recordAnalysis(.semantics_pages, measure_start);
        for (state.modules.order.items) |module_id| {
            try state.checkAnalysisCanceled();
            const module = state.moduleById(module_id) orelse continue;
            const module_sema = sema.forModule(module_id);
            checker.checkPageStatements(inference_context, allocator, state, &module_sema, checker.originPathForModule(module), module.syntax) catch |err| {
                if (err != error.DiagnosticsFailed) return err;
                had_body_diagnostics = true;
            };
        }
    }
    if (had_body_diagnostics) return error.DiagnosticsFailed;
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

fn addDependencyQueryDiagnostics(allocator: std.mem.Allocator, state: *core.DocumentState, sema: *const SemanticEnv, graph: *const execution.ExecutionGraph) !void {
    for (state.modules.order.items) |module_id| {
        const module = state.moduleById(module_id) orelse continue;
        if (std.mem.indexOf(u8, module.source, "^dep?") == null) continue;
        const module_sema = sema.forModule(module_id);
        var query_iter = DependencyQueryIterator.init(module.source);
        while (query_iter.next()) |query| {
            const target = dependencyQueryTarget(module, query.span.start) orelse continue;
            var analyzer = dependencies.Analyzer.initWithScope(allocator, &module_sema, target.scope);
            defer analyzer.deinit();
            var scope = target.scope;
            var summary = dependencies.AccessSummary.init(allocator);
            defer summary.deinit();
            var scheduled = false;
            for (graph.units.items) |unit| {
                if (unit.kind == .display) continue;
                if (unit.module_id != module_id or unit.span.start != target.stmt.span.start or unit.span.end != target.stmt.span.end) continue;
                summary = try unit.summary.clone(allocator);
                scope = switch (unit.kind) {
                    .display => unreachable,
                    .document_statement => .{ .document = module_id },
                    .page_statement => |page| .{ .page = page.page_id },
                };
                scheduled = true;
                break;
            }
            if (!scheduled) {
                // Function bodies and nested statements have no execution unit.
                for (target.context) |stmt| {
                    var context_summary = try analyzer.statement(stmt);
                    context_summary.deinit();
                }
                summary = try analyzer.statement(target.stmt);
            }
            const scope_displays = [_]dependencies.ScopeDisplay{.{ .scope = scope, .name = target.scope_display }};
            const message = try dependencies.formatAccessSummaryWithOptions(state.allocator, summary, .{
                .variable_scope_displays = &scope_displays,
                .pages_scope_displays = &scope_displays,
            });
            const origin = core.SourceOrigin.at(checker.originPathForModule(module), query.span);

            try state.addValidationDiagnostic(.warning, null, null, origin, .{
                .user_report = .{ .code = "DependencyQuery", .message = message },
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

    state.constants.declarations = index.constants;
    index.constants = core.ConstMap.init(allocator);
    state.functions = index.functions;
    index.functions = core.FunctionMap.init(allocator);
    state.modules.order = index.module_graph.module_order;
    index.module_graph.module_order = .empty;
    state.projectModuleMutable().implicit_import_ids = index.module_graph.project_implicit_import_ids;
    index.module_graph.project_implicit_import_ids = .empty;
    state.projectModuleMutable().resolved_import_ids = index.module_graph.project_import_ids;
    index.module_graph.project_import_ids = .empty;
    try index.module_graph.moveModulesTo(&state.modules.entries);
    if (state.modules.order.items.len == 0 or state.modules.order.items[state.modules.order.items.len - 1] != state.modules.project_id) {
        try state.modules.order.append(allocator, state.modules.project_id);
    }
    try state.rebuildDeclarationIndex();
    {
        const sema = SemanticEnv.init(&state, state.declaration_index, &state.functions);
        try semantics.resolveTypeReferences(allocator, &state, &sema);
        try state.rebuildDeclarationIndex();
        try semantics.resolveEnumCaseExpressionsAndDefaults(allocator, &state, &sema);
        var transform = @import("instantiate.zig").Transform{ .allocator = allocator, .next_expression_id = &state.next_expression_id };
        for (state.modules.entries.items) |*module| try transform.module(&module.syntax);
        try semantics.rebuildConstDeclarations(allocator, &state);
        try semantics.rebuildFunctionDeclarations(allocator, &state);
    }
    try state.rebuildDeclarationIndex();
    try analysis_index.populateDocumentStateAnalysis(allocator, &state);
    return state;
}

fn addParseHoleDiagnostics(state: *core.DocumentState, holes: syntax_hole.Result) !void {
    const origin_path = state.projectPath();
    for (holes.diagnostics) |diagnostic| {
        const origin = core.SourceOrigin.at(origin_path, diagnostic.span);

        var message_buf: [256]u8 = undefined;
        const message_text = utils.err.parseDiagnosticMessage(&message_buf, diagnostic);
        try state.addValidationDiagnostic(.@"error", null, null, origin, .{
            .user_report = .{ .code = utils.err.parseDiagnosticCode(diagnostic.err), .message = try state.allocator.dupe(u8, message_text) },
        });
    }
}
