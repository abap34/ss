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
    for (ir.module_order.items) |module_id| {
        const module = ir.moduleById(module_id) orelse continue;
        try checker.checkPageStatements(allocator, ir, &sema, checker.originPathForModule(module), module.program);
    }
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
    ir.variable_types = collectVariableTypesFromProgramWithDiagnostics(allocator, &ir.functions, ir.projectProgram(), &ir) catch |err| {
        printIrDiagnosticsOrFallback(&ir, err);
        return error.DiagnosticsFailed;
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
    var graph = try module_loader.loadGraph(allocator, io, base_dir, project_program);
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
        .bind_binding => |binding| {
            _ = try inferExprInfo(allocator, diagnostic_ir, sema, env, binding.expr, origin);
            try env.put(binding.name, infoFromSort(.fragment));
            try variables.put(binding.name, infoFromSort(.fragment));
        },
        .return_expr => |expr| {
            _ = try inferExprInfo(allocator, diagnostic_ir, sema, env, expr, origin);
        },
        .property_set => |property_set| {
            _ = try inferExprInfo(allocator, diagnostic_ir, sema, env, property_set.value, origin);
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
