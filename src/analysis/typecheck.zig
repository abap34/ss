const std = @import("std");
const core = @import("core");
const ast = @import("ast");
const declarations = @import("../language/declarations.zig");
const semantic_env = @import("../language/env.zig");
const module_loader = @import("../modules/loader.zig");
const calls = @import("calls.zig");
const checker = @import("check.zig");
const editor = @import("editor.zig");
const fields = @import("fields.zig");
const infer = @import("infer.zig");
const registry = @import("../language/registry.zig");
const semantic_types = @import("types.zig");
const syntax = @import("../syntax/parse.zig");
const utils = @import("utils");
const SemanticEnv = semantic_env.SemanticEnv;

const TypeEnv = semantic_types.TypeEnv;
pub const VariableInfo = semantic_types.TypeInfo;
const ensureType = semantic_types.ensureType;
const infoFromSort = semantic_types.infoFromSort;
const inferExprInfo = infer.exprInfo;
pub const expectedPrimitiveArgSort = infer.expectedPrimitiveArgSort;

pub const FunctionMetadata = core.FunctionMetadata;

pub const ProgramIndex = struct {
    allocator: std.mem.Allocator,
    modules: std.ArrayList(core.SourceModule),
    module_order: std.ArrayList(core.SourceModuleId),
    project_import_ids: std.ArrayList(core.SourceModuleId),
    functions: std.StringHashMap(ast.FunctionDecl),
    function_metadata: std.StringHashMap(FunctionMetadata),

    pub fn deinit(self: *ProgramIndex) void {
        self.function_metadata.deinit();
        self.functions.deinit();
        for (self.modules.items) |*module| module.deinit(self.allocator);
        self.modules.deinit(self.allocator);
        self.module_order.deinit(self.allocator);
        self.project_import_ids.deinit(self.allocator);
    }
};

pub const BuildIrOptions = struct {
    allow_diagnostics: bool = false,
};

pub fn collectFunctionsFromPrograms(
    allocator: std.mem.Allocator,
    programs: []const *const ast.Program,
) !std.StringHashMap(ast.FunctionDecl) {
    var functions = std.StringHashMap(ast.FunctionDecl).init(allocator);
    for (programs) |program| {
        for (program.functions.items) |func| {
            try functions.put(func.name, func);
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
    functions: *const std.StringHashMap(ast.FunctionDecl),
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
        const origin_path = blk: {
            if (ir.function_metadata.get(entry.key_ptr.*)) |metadata| {
                if (ir.moduleById(metadata.module_id)) |module| break :blk checker.originPathForModule(module);
            }
            break :blk "";
        };
        try checker.checkFunction(allocator, ir, sema, origin_path, entry.value_ptr.*);
    }
}

pub fn typecheckProgram(
    allocator: std.mem.Allocator,
    ir: *core.Ir,
) !void {
    var declaration_index = try declarations.build(allocator, ir);
    defer declaration_index.deinit();
    const sema = SemanticEnv.init(ir, &declaration_index, &ir.functions);

    try fields.checkObjectDeclarations(allocator, ir, &sema);
    try checker.checkPageNamesUnique(allocator, ir);
    try checkFunctionDefinitionsWithEnv(allocator, ir, &sema);
    try checkAnnotationContracts(allocator, ir, &declaration_index);
    try checkOrdinaryFunctionEffectContracts(allocator, ir, &sema);
    for (ir.module_order.items) |module_id| {
        const module = ir.moduleById(module_id) orelse continue;
        try checker.checkPageStatements(allocator, ir, &sema, checker.originPathForModule(module), module.program);
    }
}

fn checkOrdinaryFunctionEffectContracts(
    allocator: std.mem.Allocator,
    ir: *core.Ir,
    sema: *const SemanticEnv,
) !void {
    var it = sema.functions.iterator();
    while (it.next()) |entry| {
        const func = entry.value_ptr.*;
        if (func.effects == null) continue;
        if (hasAnnotation(func, "pass") or hasAnnotation(func, "host") or hasAnnotation(func, "op")) continue;
        const origin = try functionOriginForDecl(allocator, ir, func);
        const declared = declarations.parseEffectSet(func.effects.?) catch {
            try ir.addValidationDiagnostic(.@"error", null, null, origin, .{
                .user_report = .{ .message = try ir.allocator.dupe(u8, "UnknownEffect: function declares an unknown effect") },
            });
            return error.UnknownEffect;
        };
        var visiting = std.StringHashMap(void).init(allocator);
        defer visiting.deinit();
        const inferred = try inferFunctionEffects(sema, func, &visiting);
        const required = inferred.withoutPure();
        if (!declared.containsAll(required)) {
            const missing = required.difference(declared);
            const missing_text = try missing.formatAlloc(allocator);
            defer allocator.free(missing_text);
            try ir.addValidationDiagnostic(.@"error", null, null, origin, .{
                .user_report = .{ .message = try std.fmt.allocPrint(ir.allocator, "MissingEffects: function body uses effects not listed in its signature: {s}", .{missing_text}) },
            });
            return error.MissingEffects;
        }
    }
}

fn inferFunctionEffects(
    sema: *const SemanticEnv,
    func: ast.FunctionDecl,
    visiting: *std.StringHashMap(void),
) anyerror!core.EffectSet {
    if (visiting.contains(func.name)) {
        if (func.effects) |effects| return declarations.parseEffectSet(effects) catch core.EffectSet.empty();
        return core.EffectSet.empty();
    }
    try visiting.put(func.name, {});
    defer _ = visiting.remove(func.name);

    var set = core.EffectSet.empty();
    for (func.params.items) |param| {
        if (param.default_value) |default_expr| {
            set.unionWith(try inferExprEffects(sema, default_expr.*, visiting));
        }
    }
    for (func.statements.items) |stmt| set.unionWith(try inferStatementEffects(sema, stmt, visiting));
    return set;
}

fn inferStatementEffects(
    sema: *const SemanticEnv,
    stmt: ast.Statement,
    visiting: *std.StringHashMap(void),
) anyerror!core.EffectSet {
    var set = core.EffectSet.empty();
    switch (stmt.kind) {
        .let_binding => |binding| set.unionWith(try inferExprEffects(sema, binding.expr, visiting)),
        .return_expr => |expr| set.unionWith(try inferExprEffects(sema, expr, visiting)),
        .property_set => |property| {
            set.insert(.WriteProperty);
            set.unionWith(try inferExprEffects(sema, property.value, visiting));
        },
        .if_stmt => |if_stmt| {
            set.unionWith(try inferExprEffects(sema, if_stmt.condition, visiting));
            for (if_stmt.then_statements.items) |nested| set.unionWith(try inferStatementEffects(sema, nested, visiting));
            for (if_stmt.else_statements.items) |nested| set.unionWith(try inferStatementEffects(sema, nested, visiting));
        },
        .expr_stmt => |expr| set.unionWith(try inferExprEffects(sema, expr, visiting)),
        .constrain => |decl| {
            set.insert(.WriteConstraint);
            if (decl.offset) |expr| set.unionWith(try inferExprEffects(sema, expr, visiting));
        },
    }
    return set;
}

fn inferExprEffects(
    sema: *const SemanticEnv,
    expr: ast.Expr,
    visiting: *std.StringHashMap(void),
) anyerror!core.EffectSet {
    return switch (expr) {
        .ident, .string, .number, .boolean => core.EffectSet.empty(),
        .call => |call| try inferCallEffects(sema, call, visiting),
    };
}

fn inferCallEffects(
    sema: *const SemanticEnv,
    call: ast.CallExpr,
    visiting: *std.StringHashMap(void),
) anyerror!core.EffectSet {
    var set = core.EffectSet.empty();
    for (call.args.items) |arg| set.unionWith(try inferExprEffects(sema, arg, visiting));
    const descriptor = sema.call(call.name) orelse return set;
    switch (descriptor) {
        .primitive => |primitive| {
            set.unionWith(registry.primitiveEffects(primitive));
            if (primitive.callback_arg_index) |raw_index| {
                const callback_index: usize = raw_index;
                if (call.args.items.len > callback_index) switch (call.args.items[callback_index]) {
                    .ident => |callback_name| if (sema.function(callback_name)) |callback| {
                        set.unionWith(try inferFunctionEffects(sema, callback, visiting));
                    },
                    else => {},
                };
            }
        },
        .function => |callee| set.unionWith(try inferFunctionEffects(sema, callee, visiting)),
    }
    return set;
}

fn hasAnnotation(func: ast.FunctionDecl, name: []const u8) bool {
    for (func.annotations.items) |annotation| {
        if (std.mem.eql(u8, annotation.name, name)) return true;
    }
    return false;
}

fn functionOriginForDecl(
    allocator: std.mem.Allocator,
    ir: *const core.Ir,
    func: ast.FunctionDecl,
) ![]const u8 {
    if (ir.function_metadata.get(func.name)) |metadata| {
        return functionOrigin(allocator, ir, metadata.module_id, func.name);
    }
    return std.fmt.allocPrint(allocator, "bytes:{d}-{d}", .{ func.span.start, func.span.end });
}

fn checkAnnotationContracts(
    allocator: std.mem.Allocator,
    ir: *core.Ir,
    index: *const declarations.DeclarationIndex,
) !void {
    for (index.removed_annotations.items) |annotation| {
        const origin = try functionOrigin(allocator, ir, annotation.module_id, annotation.function_name);
        try ir.addValidationDiagnostic(.@"error", null, null, origin, .{
            .user_report = .{ .message = try ir.allocator.dupe(u8, "@phase is removed; use @pass(augment), @pass(resolve), @pass(inspect_layout), or @pass(prepare_render)") },
        });
        return error.LegacyPhaseAnnotation;
    }
    for (index.host_capabilities.items) |capability| {
        if (capability.effects != null) continue;
        const origin = try functionOrigin(allocator, ir, capability.module_id, capability.function_name);
        if (capability.effects_text != null) {
            try ir.addValidationDiagnostic(.@"error", null, null, origin, .{
                .user_report = .{ .message = try ir.allocator.dupe(u8, "UnknownEffect: @host declares an unknown effect") },
            });
            return error.UnknownEffect;
        }
        try ir.addValidationDiagnostic(.@"error", null, null, origin, .{
            .user_report = .{ .message = try ir.allocator.dupe(u8, "@host functions must declare effects with '! Effect | Effect'") },
        });
        return error.MissingEffects;
    }
    for (index.render_ops.items) |op| {
        if (op.effects != null) continue;
        const origin = try functionOrigin(allocator, ir, op.module_id, op.function_name);
        if (op.effects_text != null) {
            try ir.addValidationDiagnostic(.@"error", null, null, origin, .{
                .user_report = .{ .message = try ir.allocator.dupe(u8, "UnknownEffect: @op declares an unknown effect") },
            });
            return error.UnknownEffect;
        }
        try ir.addValidationDiagnostic(.@"error", null, null, origin, .{
            .user_report = .{ .message = try ir.allocator.dupe(u8, "@op functions must declare effects with '! Effect | Effect'") },
        });
        return error.MissingEffects;
    }
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

pub fn collectVariableTypesFromProgram(
    allocator: std.mem.Allocator,
    functions: *const std.StringHashMap(ast.FunctionDecl),
    program: ast.Program,
) !std.StringHashMap(core.SemanticSort) {
    var infos = try collectVariableInfoFromProgram(allocator, functions, program, null);
    defer infos.deinit();
    var variables = std.StringHashMap(core.SemanticSort).init(allocator);
    errdefer variables.deinit();
    var iterator = infos.iterator();
    while (iterator.next()) |entry| {
        try variables.put(entry.key_ptr.*, entry.value_ptr.sort);
    }
    return variables;
}

pub fn collectVariableInfoFromProgram(
    allocator: std.mem.Allocator,
    functions: *const std.StringHashMap(ast.FunctionDecl),
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
            try env.put(param.name, .{ .ty = param.ty, .sort = param.sort });
            try variables.put(param.name, .{ .ty = param.ty, .sort = param.sort });
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

fn appendFunctionDeclarations(
    functions: *std.StringHashMap(ast.FunctionDecl),
    metadata: *std.StringHashMap(FunctionMetadata),
    program: ast.Program,
    module_id: core.SourceModuleId,
) !void {
    for (program.functions.items) |func| {
        try functions.put(func.name, func);
        try metadata.put(func.name, .{ .module_id = module_id });
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
    errdefer allocator.free(asset_base_dir);
    const project_path = try allocator.dupe(u8, input_path);
    errdefer allocator.free(project_path);
    var ir = try core.Ir.init(allocator, asset_base_dir, project_path, project_source.*, project_program.*);
    project_source.* = &.{};
    project_program.* = ast.Program.init();
    errdefer ir.deinit();

    ir.functions = index.functions;
    index.functions = std.StringHashMap(ast.FunctionDecl).init(allocator);
    ir.function_metadata = index.function_metadata;
    index.function_metadata = std.StringHashMap(FunctionMetadata).init(allocator);
    ir.module_order = index.module_order;
    index.module_order = .empty;
    ir.projectModuleMutable().resolved_import_ids = index.project_import_ids;
    index.project_import_ids = .empty;
    for (index.modules.items) |module| try ir.modules.append(allocator, module);
    index.modules = .empty;
    if (ir.module_order.items.len == 0 or ir.module_order.items[ir.module_order.items.len - 1] != ir.project_module_id) {
        try ir.module_order.append(allocator, ir.project_module_id);
    }
    ir.variable_types = collectVariableTypesFromProgramWithDiagnostics(allocator, &ir.functions, ir.projectProgram(), &ir) catch |err| blk: {
        if (!options.allow_diagnostics) {
            printIrDiagnosticsOrFallback(&ir, err);
            return error.DiagnosticsFailed;
        }
        break :blk std.StringHashMap(core.SemanticSort).init(allocator);
    };
    try editor.populateIrAnalysis(allocator, &ir);
    return ir;
}

fn collectVariableTypesFromProgramWithDiagnostics(
    allocator: std.mem.Allocator,
    functions: *const std.StringHashMap(ast.FunctionDecl),
    program: ast.Program,
    diagnostic_ir: *core.Ir,
) !std.StringHashMap(core.SemanticSort) {
    var infos = try collectVariableInfoFromProgram(allocator, functions, program, diagnostic_ir);
    defer infos.deinit();
    var variables = std.StringHashMap(core.SemanticSort).init(allocator);
    errdefer variables.deinit();
    var iterator = infos.iterator();
    while (iterator.next()) |entry| {
        try variables.put(entry.key_ptr.*, entry.value_ptr.sort);
    }
    return variables;
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
    var graph = try module_loader.loadGraphWithOverlay(allocator, io, base_dir, project_program, overlay);
    errdefer graph.deinit();

    var index = ProgramIndex{
        .allocator = allocator,
        .modules = graph.modules,
        .module_order = graph.module_order,
        .project_import_ids = graph.project_import_ids,
        .functions = std.StringHashMap(ast.FunctionDecl).init(allocator),
        .function_metadata = std.StringHashMap(FunctionMetadata).init(allocator),
    };
    graph.modules = .empty;
    graph.module_order = .empty;
    graph.project_import_ids = .empty;

    errdefer index.deinit();

    for (index.module_order.items) |module_id| {
        const module = findModuleById(index.modules.items, module_id) orelse continue;
        try appendFunctionDeclarations(&index.functions, &index.function_metadata, module.program, module.id);
    }
    try appendFunctionDeclarations(&index.functions, &index.function_metadata, project_program, 0);
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

pub fn collectVariableTypesForProgram(
    allocator: std.mem.Allocator,
    io: std.Io,
    input_path: []const u8,
    program: ast.Program,
) !std.StringHashMap(core.SemanticSort) {
    var index = try loadProgramIndexForPath(allocator, io, input_path, program);
    defer index.deinit();
    return try collectVariableTypesFromProgram(allocator, &index.functions, program);
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
            try env.put(binding.name, info);
            try variables.put(binding.name, info);
        },
        .return_expr => |expr| {
            _ = try inferExprInfo(allocator, diagnostic_ir, sema, env, expr, origin);
        },
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

fn statementOrigin(allocator: std.mem.Allocator, span: ast.Span) ![]const u8 {
    return std.fmt.allocPrint(allocator, "bytes:{d}-{d}", .{ span.start, span.end });
}
