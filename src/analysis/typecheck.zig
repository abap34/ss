const std = @import("std");
const core = @import("core");
const ast = @import("ast");
const names = @import("../language/names.zig");
const declarations = @import("../language/declarations.zig");
const semantic_env = @import("../language/env.zig");
const registry = @import("../language/registry.zig");
const module_loader = @import("../modules/loader.zig");
const calls = @import("calls.zig");
const contracts = @import("contracts.zig");
const editor = @import("editor.zig");
const fields = @import("fields.zig");
const semantic_types = @import("types.zig");
const syntax = @import("../syntax/parse.zig");
const utils = @import("utils");
const Type = ast.Type;
const SemanticEnv = semantic_env.SemanticEnv;

const TypeInfo = semantic_types.TypeInfo;
const TypeEnv = semantic_types.TypeEnv;
pub const VariableInfo = semantic_types.TypeInfo;
const ensureSort = semantic_types.ensureSort;
const ensureType = semantic_types.ensureType;
const infoFromSort = semantic_types.infoFromSort;
const infoFromType = semantic_types.infoFromType;
const isPropertyTarget = semantic_types.isPropertyTarget;
const mergeObjectClass = semantic_types.mergeObjectClass;
const mergeTypeInfo = semantic_types.mergeTypeInfo;
const resolveStringLiteral = semantic_types.resolveStringLiteral;
const targetClassForInfo = semantic_types.targetClassForInfo;
const typeLabelAlloc = semantic_types.typeLabelAlloc;

var diagnostic_origin_path: []const u8 = "";
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

fn isConst(func: ast.FunctionDecl) bool {
    return func.kind == .constant;
}

fn originPathForModule(module: *const core.SourceModule) []const u8 {
    return module.path orelse module.spec;
}

fn setDiagnosticOriginModule(module: *const core.SourceModule) void {
    diagnostic_origin_path = originPathForModule(module);
}

fn clearDiagnosticOriginModule() void {
    diagnostic_origin_path = "";
}

fn addUserReport(ir: ?*core.Ir, origin: []const u8, comptime fmt: []const u8, args: anytype) !void {
    const sink = ir orelse return;
    const message = try std.fmt.allocPrint(sink.allocator, fmt, args);
    const diagnostic_origin = try sink.allocator.dupe(u8, origin);
    try sink.addValidationDiagnostic(.@"error", null, null, diagnostic_origin, .{
        .user_report = .{ .message = message },
    });
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
    defer clearDiagnosticOriginModule();
    try calls.checkFunctionCallGraph(allocator, ir, sema);

    var it = sema.functions.iterator();
    while (it.next()) |entry| {
        if (ir.function_metadata.get(entry.key_ptr.*)) |metadata| {
            if (ir.moduleById(metadata.module_id)) |module| setDiagnosticOriginModule(module);
        } else {
            clearDiagnosticOriginModule();
        }
        try checkFunction(allocator, ir, sema, entry.value_ptr.*);
    }
}

pub fn typecheckProgram(
    allocator: std.mem.Allocator,
    ir: *core.Ir,
) !void {
    defer clearDiagnosticOriginModule();
    var declaration_index = try declarations.build(allocator, ir);
    defer declaration_index.deinit();
    const sema = SemanticEnv.init(ir, &declaration_index, &ir.functions);

    try fields.checkObjectDeclarations(allocator, ir, &sema);
    try checkPageNamesUnique(allocator, ir);
    try checkFunctionDefinitionsWithEnv(allocator, ir, &sema);
    for (ir.module_order.items) |module_id| {
        const module = ir.moduleById(module_id) orelse continue;
        setDiagnosticOriginModule(module);
        try checkPageStatements(allocator, ir, &sema, module.program);
    }
}

fn checkPageNamesUnique(
    allocator: std.mem.Allocator,
    ir: *core.Ir,
) !void {
    var pages = std.StringHashMap(void).init(allocator);
    defer pages.deinit();

    for (ir.module_order.items) |module_id| {
        const module = ir.moduleById(module_id) orelse continue;
        setDiagnosticOriginModule(module);
        for (module.program.pages.items) |page| {
            if (pages.contains(page.name)) {
                const origin = try statementOrigin(allocator, page.span);
                defer allocator.free(origin);
                try addUserReport(ir, origin, "DuplicatePage: page '{s}' is already defined", .{page.name});
                return error.DuplicatePage;
            }
            try pages.put(page.name, {});
        }
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

fn checkFunction(
    allocator: std.mem.Allocator,
    ir: *core.Ir,
    sema: *const SemanticEnv,
    func: ast.FunctionDecl,
) !void {
    var env = TypeEnv.init(allocator);
    defer env.deinit();

    const func_origin = try statementOrigin(allocator, func.span);
    defer allocator.free(func_origin);
    for (func.params.items) |param| {
        if (param.default_value) |default_value| {
            const info = try inferExprInfo(allocator, ir, sema, &env, default_value.*, func_origin);
            try ensureType(ir, allocator, info, param.ty, func_origin, .UnmatchedArgumentType);
        }
        var param_info = infoFromType(param.ty);
        param_info.sort = param.sort;
        try env.put(param.name, param_info);
    }

    for (func.statements.items) |stmt| {
        try checkStatement(allocator, ir, sema, &env, func.result_type, stmt);
    }
}

fn checkPageStatements(
    allocator: std.mem.Allocator,
    ir: *core.Ir,
    sema: *const SemanticEnv,
    program: ast.Program,
) !void {
    {
        var env = TypeEnv.init(allocator);
        defer env.deinit();
        for (program.document_statements.items) |stmt| {
            try checkTopLevelStatement(allocator, ir, sema, &env, stmt);
        }
    }
    for (program.pages.items) |page| {
        var env = TypeEnv.init(allocator);
        defer env.deinit();

        for (page.statements.items) |stmt| {
            try checkTopLevelStatement(allocator, ir, sema, &env, stmt);
        }
    }
}

fn checkTopLevelStatement(
    allocator: std.mem.Allocator,
    ir: *core.Ir,
    sema: *const SemanticEnv,
    env: *TypeEnv,
    stmt: ast.Statement,
) !void {
    const origin = try statementOrigin(allocator, stmt.span);
    switch (stmt.kind) {
        .let_binding => |binding| {
            const info = try inferExprInfo(allocator, ir, sema, env, binding.expr, origin);
            try env.put(binding.name, info);
        },
        .bind_binding => |binding| {
            _ = try inferExprInfo(allocator, ir, sema, env, binding.expr, origin);
            try env.put(binding.name, infoFromSort(.fragment));
        },
        .return_expr => {
            try addUserReport(ir, origin, "ReturnOutsideFunction: return is only valid inside a function", .{});
            return error.ReturnOutsideFunction;
        },
        .property_set => |property_set| {
            try validatePropertySetStatement(allocator, ir, sema, env, property_set.object_name, property_set.property_name, property_set.value, origin);
        },
        .expr_stmt => |expr| {
            _ = try inferExprInfo(allocator, ir, sema, env, expr, origin);
        },
        .constrain => |decl| {
            if (decl.offset) |expr| {
                const actual = try inferExprInfo(allocator, ir, sema, env, expr, origin);
                try ensureType(ir, allocator, actual, Type.number, origin, .UnmatchedArgumentType);
            }
        },
    }
}

fn checkStatement(
    allocator: std.mem.Allocator,
    ir: *core.Ir,
    sema: *const SemanticEnv,
    env: *TypeEnv,
    result_type: Type,
    stmt: ast.Statement,
) !void {
    const origin = try statementOrigin(allocator, stmt.span);
    switch (stmt.kind) {
        .let_binding => |binding| {
            const info = try inferExprInfo(allocator, ir, sema, env, binding.expr, origin);
            try env.put(binding.name, info);
        },
        .bind_binding => |binding| {
            _ = try inferExprInfo(allocator, ir, sema, env, binding.expr, origin);
            try env.put(binding.name, infoFromSort(.fragment));
        },
        .return_expr => |expr| {
            const actual = try inferExprInfo(allocator, ir, sema, env, expr, origin);
            try ensureType(ir, allocator, actual, result_type, origin, .UnmatchedReturnType);
        },
        .property_set => |property_set| {
            try validatePropertySetStatement(allocator, ir, sema, env, property_set.object_name, property_set.property_name, property_set.value, origin);
        },
        .expr_stmt => |expr| {
            _ = try inferExprInfo(allocator, ir, sema, env, expr, origin);
        },
        .constrain => |decl| {
            if (decl.offset) |expr| {
                const actual = try inferExprInfo(allocator, ir, sema, env, expr, origin);
                try ensureType(ir, allocator, actual, Type.number, origin, .UnmatchedArgumentType);
            }
        },
    }
}

fn inferExprSort(
    allocator: std.mem.Allocator,
    ir: ?*core.Ir,
    sema: *const SemanticEnv,
    env: *const TypeEnv,
    expr: ast.Expr,
    origin: []const u8,
) anyerror!core.SemanticSort {
    return (try inferExprInfo(allocator, ir, sema, env, expr, origin)).sort;
}

fn inferExprInfo(
    allocator: std.mem.Allocator,
    ir: ?*core.Ir,
    sema: *const SemanticEnv,
    env: *const TypeEnv,
    expr: ast.Expr,
    origin: []const u8,
) anyerror!TypeInfo {
    return switch (expr) {
        .string => |text| blk: {
            var info = infoFromSort(.string);
            info.string_literal = text;
            break :blk info;
        },
        .number => infoFromSort(.number),
        .ident => |name| blk: {
            if (env.get(name)) |info| break :blk info;
            if (sema.function(name)) |func| {
                if (isConst(func)) break :blk infoFromType(func.result_type);
                break :blk infoFromSort(.function);
            }
            try addUserReport(ir, origin, "UnknownIdentifier: unknown identifier: {s}", .{name});
            return error.UnknownIdentifier;
        },
        .call => |call| try inferCallInfo(allocator, ir, sema, env, call, origin),
    };
}

fn inferCallInfo(
    allocator: std.mem.Allocator,
    ir: ?*core.Ir,
    sema: *const SemanticEnv,
    env: *const TypeEnv,
    call: ast.CallExpr,
    origin: []const u8,
) anyerror!TypeInfo {
    if (sema.function(call.name)) |func| {
        if (isConst(func)) {
            try addUserReport(ir, origin, "UnknownFunction: constants are values; use '{s}' without parentheses", .{call.name});
            return error.UnknownFunction;
        }
        const min_arity = contracts.requiredParamCount(func);
        const max_arity = func.params.items.len;
        if (call.args.items.len < min_arity or call.args.items.len > max_arity) {
            if (min_arity == max_arity) {
                try addUserReport(ir, origin, "InvalidArity: expected {d}, got {d}", .{ max_arity, call.args.items.len });
            } else {
                try addUserReport(ir, origin, "InvalidArity: expected {d}..{d}, got {d}", .{ min_arity, max_arity, call.args.items.len });
            }
            return error.InvalidArity;
        }
        for (call.args.items, 0..) |arg, index| {
            const param = func.params.items[index];
            const actual = try inferExprInfo(allocator, ir, sema, env, arg, origin);
            try ensureType(ir, allocator, actual, param.ty, origin, .UnmatchedArgumentType);
        }
        return try inferUserFunctionReturnInfo(allocator, ir, sema, env, func, call, origin);
    }

    if (sema.primitive(call.name)) |descriptor| {
        if (call.args.items.len < descriptor.min_arity or call.args.items.len > descriptor.max_arity) {
            if (descriptor.min_arity == descriptor.max_arity) {
                try addUserReport(ir, origin, "InvalidArity: expected {d}, got {d}", .{ descriptor.min_arity, call.args.items.len });
            } else {
                try addUserReport(ir, origin, "InvalidArity: expected {d}..{d}, got {d}", .{ descriptor.min_arity, descriptor.max_arity, call.args.items.len });
            }
            return error.InvalidArity;
        }
        for (call.args.items, 0..) |arg, index| {
            const actual = try inferExprInfo(allocator, ir, sema, env, arg, origin);
            if (registry.primitiveArgType(descriptor, index)) |expected| {
                try ensureType(ir, allocator, actual, expected, origin, .UnmatchedArgumentType);
            }
        }
        const info = try primitiveResultTypeInfo(allocator, ir, sema, env, call, descriptor, origin);
        if (ir != null) {
            switch (descriptor.op) {
                .set_prop => try validateSetPropCall(ir.?, call, env, sema, origin),
                .extend_render_env => try validateExtendRenderEnvCall(ir.?, call, env, sema, origin),
                else => {},
            }
        }
        return info;
    }

    try addUserReport(ir, origin, "UnknownFunction: unknown function: {s}", .{call.name});
    return error.UnknownFunction;
}

fn inferUserFunctionReturnInfo(
    allocator: std.mem.Allocator,
    ir: ?*core.Ir,
    sema: *const SemanticEnv,
    caller_env: *const TypeEnv,
    func: ast.FunctionDecl,
    call: ast.CallExpr,
    origin: []const u8,
) !TypeInfo {
    var visiting = std.StringHashMap(void).init(allocator);
    defer visiting.deinit();
    return inferUserFunctionReturnInfoInner(allocator, ir, sema, caller_env, func, call, origin, &visiting);
}

fn inferUserFunctionReturnInfoInner(
    allocator: std.mem.Allocator,
    ir: ?*core.Ir,
    sema: *const SemanticEnv,
    caller_env: *const TypeEnv,
    func: ast.FunctionDecl,
    call: ast.CallExpr,
    origin: []const u8,
    visiting: *std.StringHashMap(void),
) !TypeInfo {
    if (visiting.contains(func.name)) {
        var info = infoFromType(func.result_type);
        info.object_class = func.result_type.class_name;
        return info;
    }
    try visiting.put(func.name, {});
    defer _ = visiting.remove(func.name);

    var env = TypeEnv.init(allocator);
    defer env.deinit();
    for (func.params.items, 0..) |param, index| {
        const info: TypeInfo = if (index < call.args.items.len)
            try inferExprInfo(allocator, ir, sema, caller_env, call.args.items[index], origin)
        else if (param.default_value) |default_value|
            try inferExprInfo(allocator, ir, sema, &env, default_value.*, origin)
        else blk: {
            var param_info = infoFromType(param.ty);
            param_info.sort = param.sort;
            break :blk param_info;
        };
        try env.put(param.name, info);
    }

    var result = infoFromType(func.result_type);
    for (func.statements.items) |stmt| {
        switch (stmt.kind) {
            .let_binding => |binding| {
                const info = try inferExprInfo(allocator, null, sema, &env, binding.expr, "");
                try env.put(binding.name, info);
            },
            .bind_binding => |binding| {
                _ = try inferExprInfo(allocator, null, sema, &env, binding.expr, "");
                try env.put(binding.name, infoFromSort(.fragment));
            },
            .return_expr => |expr| {
                const info = try inferExprInfo(allocator, null, sema, &env, expr, "");
                result = mergeTypeInfo(result, info);
            },
            .property_set => |property_set| {
                try validatePropertySetStatement(allocator, ir, sema, &env, property_set.object_name, property_set.property_name, property_set.value, "");
            },
            .expr_stmt => |expr| {
                _ = try inferExprInfo(allocator, null, sema, &env, expr, "");
            },
            .constrain => |decl| {
                if (decl.offset) |expr| _ = try inferExprInfo(allocator, null, sema, &env, expr, "");
            },
        }
    }
    result.ty = func.result_type;
    result.sort = func.result_sort;
    if (func.result_type.class_name) |class_name| result.object_class = class_name;
    return result;
}

fn primitiveResultTypeInfo(
    allocator: std.mem.Allocator,
    ir: ?*core.Ir,
    sema: *const SemanticEnv,
    env: *const TypeEnv,
    call: ast.CallExpr,
    descriptor: registry.PrimitiveDescriptor,
    origin: []const u8,
) !TypeInfo {
    if (descriptor.op == .first) {
        if (call.args.items.len == 0) return infoFromSort(.object);
        const selection_info = try inferExprInfo(allocator, ir, sema, env, call.args.items[0], origin);
        var info = switch (selection_info.ty.param) {
            .page => infoFromSort(.page),
            .object, .any, .none => infoFromSort(.object),
            else => infoFromSort(selection_info.sort),
        };
        if (info.sort == .object) {
            info.object_class = selection_info.object_class;
            info.ty.class_name = selection_info.object_class;
        }
        return info;
    }

    if (descriptor.op == .foreach) {
        if (call.args.items.len < 2) return infoFromType(Type.selection(.any));
        const selection_info = try inferExprInfo(allocator, ir, sema, env, call.args.items[0], origin);
        try validateCallbackShape(allocator, ir, sema, env, call, origin, 1, selection_info, 1, null);
        return selection_info;
    }

    if (descriptor.op == .fold) {
        if (call.args.items.len < 3) return infoFromSort(.string);
        const selection_info = try inferExprInfo(allocator, ir, sema, env, call.args.items[0], origin);
        try validateCallbackShape(allocator, ir, sema, env, call, origin, 2, selection_info, 2, .string);
        return infoFromSort(.string);
    }

    if (descriptor.op == .join) {
        if (call.args.items.len < 3) return infoFromSort(.string);
        const selection_info = try inferExprInfo(allocator, ir, sema, env, call.args.items[0], origin);
        try validateCallbackShape(allocator, ir, sema, env, call, origin, 2, selection_info, 1, .string);
        return infoFromSort(.string);
    }

    if (descriptor.op == .rewrite_text or descriptor.op == .set_content or descriptor.op == .clear_content or descriptor.op == .append_content) {
        if (call.args.items.len == 0) return infoFromSort(.object);
        return try inferExprInfo(allocator, ir, sema, env, call.args.items[0], origin);
    }

    if (descriptor.op == .selection_union or descriptor.op == .selection_intersection or descriptor.op == .selection_difference) {
        return try inferSelectionAlgebraInfo(allocator, ir, sema, env, call, origin);
    }

    if (descriptor.op == .select) {
        return try inferSelectCallInfo(allocator, ir, sema, env, call, origin);
    }

    if (descriptor.op == .set_style) {
        if (call.args.items.len == 0) return infoFromSort(.object);
        const target_info = try inferExprInfo(allocator, ir, sema, env, call.args.items[0], origin);
        if (!(target_info.ty.tag == .object or (target_info.ty.tag == .selection and (target_info.ty.param == .object or target_info.ty.param == .any)))) {
            try ensureType(ir, allocator, target_info, Type.object, origin, .UnmatchedArgumentType);
        }
        return target_info;
    }

    if (descriptor.op == .set_prop or descriptor.op == .extend_render_env) {
        if (call.args.items.len == 0) return infoFromSort(.object);
        const target_info = try inferExprInfo(allocator, ir, sema, env, call.args.items[0], origin);
        return .{
            .ty = switch (target_info.ty.tag) {
                .document, .page, .object, .selection => target_info.ty,
                else => Type.object,
            },
            .sort = switch (target_info.sort) {
                .document, .page, .object, .selection => target_info.sort,
                else => .object,
            },
            .object_class = target_info.object_class,
        };
    }

    const result_sort = descriptor.result_sort orelse .object;
    if (result_sort != .object) return infoFromSort(result_sort);

    var info = infoFromSort(result_sort);
    info.object_class = switch (descriptor.op) {
        .group => "GroupObject",
        .set_style => blk: {
            const object_info = try inferExprInfo(allocator, ir, sema, env, call.args.items[0], origin);
            break :blk object_info.object_class;
        },
        .object => inferObjectConstructorClass(sema, env, call),
        else => null,
    };
    if (info.object_class) |class_name| info.ty.class_name = class_name;
    return info;
}

fn validateCallbackShape(
    allocator: std.mem.Allocator,
    ir: ?*core.Ir,
    sema: *const SemanticEnv,
    env: *const TypeEnv,
    call: ast.CallExpr,
    origin: []const u8,
    callback_index: usize,
    selection_info: TypeInfo,
    fixed_prefix_count: usize,
    expected_result: ?core.SemanticSort,
) !void {
    if (call.args.items.len <= callback_index) return;
    const callback_name = switch (call.args.items[callback_index]) {
        .ident => |name| name,
        else => {
            try addUserReport(ir, origin, "InvalidCallback: callback must be a named top-level function", .{});
            return error.InvalidSemanticSort;
        },
    };
    const callback = sema.function(callback_name) orelse {
        try addUserReport(ir, origin, "InvalidCallback: callback must be a named top-level function: {s}", .{callback_name});
        return error.UnknownFunction;
    };
    const extra_count = if (call.args.items.len > callback_index + 1) call.args.items.len - callback_index - 1 else 0;
    const expected_arg_count = fixed_prefix_count + extra_count;
    if (expected_arg_count < contracts.requiredParamCount(callback) or expected_arg_count > callback.params.items.len) {
        try addUserReport(ir, origin, "InvalidCallback: callback {s} receives {d} arguments here, but its contract is {d}..{d}", .{
            callback_name,
            expected_arg_count,
            contracts.requiredParamCount(callback),
            callback.params.items.len,
        });
        return error.InvalidArity;
    }
    const item_type = switch (selection_info.ty.param) {
        .page => Type.page,
        .object, .any, .none => Type.object,
        else => Type.any,
    };
    if (fixed_prefix_count == 1) {
        try ensureType(ir, allocator, infoFromType(callback.params.items[0].ty), item_type, origin, .UnmatchedArgumentType);
    } else if (fixed_prefix_count == 2) {
        try ensureType(ir, allocator, infoFromType(callback.params.items[0].ty), Type.string, origin, .UnmatchedArgumentType);
        try ensureType(ir, allocator, infoFromType(callback.params.items[1].ty), item_type, origin, .UnmatchedArgumentType);
    }
    var extra_index: usize = 0;
    while (extra_index < extra_count) : (extra_index += 1) {
        const actual = try inferExprInfo(allocator, ir, sema, env, call.args.items[callback_index + 1 + extra_index], origin);
        const param_index = fixed_prefix_count + extra_index;
        try ensureType(ir, allocator, actual, callback.params.items[param_index].ty, origin, .UnmatchedArgumentType);
    }
    if (expected_result) |result_sort| {
        try ensureSort(ir, callback.result_sort, result_sort, origin, .UnmatchedReturnType);
    }
}

fn inferSelectionAlgebraInfo(
    allocator: std.mem.Allocator,
    ir: ?*core.Ir,
    sema: *const SemanticEnv,
    env: *const TypeEnv,
    call: ast.CallExpr,
    origin: []const u8,
) !TypeInfo {
    if (call.args.items.len < 2) return infoFromType(Type.selection(.any));
    const left = try inferExprInfo(allocator, ir, sema, env, call.args.items[0], origin);
    const right = try inferExprInfo(allocator, ir, sema, env, call.args.items[1], origin);
    try ensureType(ir, allocator, left, Type.selection(.any), origin, .UnmatchedArgumentType);
    try ensureType(ir, allocator, right, Type.selection(.any), origin, .UnmatchedArgumentType);

    if (left.ty.param != .any and right.ty.param != .any and left.ty.param != right.ty.param) {
        const left_label = try typeLabelAlloc(allocator, left.ty);
        defer allocator.free(left_label);
        const right_label = try typeLabelAlloc(allocator, right.ty);
        defer allocator.free(right_label);
        try addUserReport(
            ir,
            origin,
            "InvalidSelectionAlgebra: cannot combine {s} and {s}",
            .{ left_label, right_label },
        );
        return error.InvalidSemanticSort;
    }

    const item_tag = if (left.ty.param != .any) left.ty.param else right.ty.param;
    var info = infoFromType(Type.selection(item_tag));
    info.object_class = mergeObjectClass(left.object_class, right.object_class);
    if (info.ty.param == .object) info.ty.param_class_name = info.object_class;
    return info;
}

fn inferSelectCallInfo(
    allocator: std.mem.Allocator,
    ir: ?*core.Ir,
    sema: *const SemanticEnv,
    env: *const TypeEnv,
    call: ast.CallExpr,
    origin: []const u8,
) !TypeInfo {
    if (call.args.items.len < 2) return infoFromType(Type.selection(.any));
    const query_name = resolveStringLiteral(env, call.args.items[1]) orelse return infoFromType(Type.selection(.any));
    const query = sema.query(query_name) orelse {
        try addUserReport(ir, origin, "UnknownQuery: unknown query: {s}", .{query_name});
        return error.UnknownQuery;
    };
    if (call.args.items.len != query.arity) {
        try addUserReport(ir, origin, "InvalidArity: query {s} expects {d} arguments, got {d}", .{ query_name, query.arity, call.args.items.len });
        return error.InvalidArity;
    }
    const base = try inferExprInfo(allocator, ir, sema, env, call.args.items[0], origin);
    try ensureType(ir, allocator, base, registry.queryInputType(query), origin, .UnmatchedInputType);
    for (query.extra_arg_sorts, 0..) |_, extra_index| {
        const arg_index = 2 + extra_index;
        if (arg_index >= call.args.items.len) break;
        const actual = try inferExprInfo(allocator, ir, sema, env, call.args.items[arg_index], origin);
        if (registry.argSortType(query.extra_arg_sorts[extra_index])) |expected| {
            try ensureType(ir, allocator, actual, expected, origin, .UnmatchedArgumentType);
        }
    }
    var info = infoFromType(registry.queryOutputType(query));
    info.object_class = inferQueryOutputClass(sema, env, query, call, base);
    if (info.ty.tag == .selection and info.ty.param == .object) info.ty.param_class_name = info.object_class;
    return info;
}

fn inferQueryOutputClass(
    sema: *const SemanticEnv,
    env: *const TypeEnv,
    query: registry.QueryDescriptor,
    call: ast.CallExpr,
    base: TypeInfo,
) ?[]const u8 {
    return switch (query.op) {
        .self_object => base.object_class,
        .page_objects_by_role, .document_objects_by_role => blk: {
            if (call.args.items.len < 3) break :blk null;
            const role_name = resolveStringLiteral(env, call.args.items[2]) orelse break :blk null;
            if (sema.roleClass(role_name)) |class_name| break :blk class_name;
            break :blk null;
        },
        .children, .descendants, .document_pages, .previous_page, .parent_page => null,
    };
}

fn inferObjectConstructorClass(sema: *const SemanticEnv, env: *const TypeEnv, call: ast.CallExpr) ?[]const u8 {
    if (call.args.items.len < 3) return null;
    const role_name = resolveStringLiteral(env, call.args.items[1]) orelse return null;
    return sema.roleClass(role_name);
}

fn validateSetPropCall(
    ir: *core.Ir,
    call: ast.CallExpr,
    env: *const TypeEnv,
    sema: *const SemanticEnv,
    origin: []const u8,
) !void {
    if (call.args.items.len < 3) return;
    const key = switch (call.args.items[1]) {
        .string => |text| text,
        else => return,
    };
    const target_info = try inferExprInfo(ir.allocator, ir, sema, env, call.args.items[0], origin);
    if (!isPropertyTarget(target_info)) {
        try addUserReport(
            ir,
            origin,
            "InvalidProperty: set_prop target must be document, page, object, or selection<object>; got {s}",
            .{@tagName(target_info.sort)},
        );
        return error.InvalidSemanticSort;
    }

    const value_info = try inferExprInfo(ir.allocator, ir, sema, env, call.args.items[2], origin);
    if (lookupFieldForTarget(sema, target_info, key)) |field| {
        try validateFieldValue(ir, sema, field, key, value_info, origin);
        return;
    }

    try addUserReport(ir, origin, "UnknownField: unknown field: {s}", .{key});
    return error.InvalidSemanticSort;
}

fn validateExtendRenderEnvCall(
    ir: *core.Ir,
    call: ast.CallExpr,
    env: *const TypeEnv,
    sema: *const SemanticEnv,
    origin: []const u8,
) !void {
    if (call.args.items.len < 4) return;
    const target_info = try inferExprInfo(ir.allocator, ir, sema, env, call.args.items[0], origin);
    if (!isPropertyTarget(target_info)) {
        try addUserReport(
            ir,
            origin,
            "InvalidRenderEnv: extend_render_env target must be document, page, object, or selection<object>; got {s}",
            .{@tagName(target_info.sort)},
        );
        return error.InvalidSemanticSort;
    }

    const op = resolveStringLiteral(env, call.args.items[1]);
    const key = resolveStringLiteral(env, call.args.items[2]);
    if (op) |literal| {
        if (!std.mem.eql(u8, literal, core.render_env.OpAdd)) {
            try addUserReport(ir, origin, "InvalidRenderEnv: unsupported render environment op: {s}", .{literal});
            return error.InvalidSemanticSort;
        }
    }
    if (key) |literal| {
        if (!std.mem.eql(u8, literal, core.render_env.KeyMathLatexPackages)) {
            try addUserReport(ir, origin, "InvalidRenderEnv: unsupported render environment key: {s}", .{literal});
            return error.InvalidSemanticSort;
        }
    }
    if (op != null and key != null and !core.render_env.isSupported(op.?, key.?)) {
        try addUserReport(ir, origin, "InvalidRenderEnv: unsupported render environment operation", .{});
        return error.InvalidSemanticSort;
    }
    if (key != null and std.mem.eql(u8, key.?, core.render_env.KeyMathLatexPackages)) {
        if (resolveStringLiteral(env, call.args.items[3])) |package| {
            if (!core.render_env.isValidLatexPackageName(package)) {
                try addUserReport(ir, origin, "InvalidRenderEnv: invalid LaTeX package name: {s}", .{package});
                return error.InvalidSemanticSort;
            }
        }
    }
}

fn lookupFieldForTarget(sema: *const SemanticEnv, target_info: TypeInfo, key: []const u8) ?declarations.FieldDescriptor {
    if (targetClassForInfo(target_info)) |class_name| {
        return sema.field(class_name, key);
    }
    if (target_info.ty.tag == .object or (target_info.ty.tag == .selection and (target_info.ty.param == .object or target_info.ty.param == .any))) {
        return sema.fieldByName(key);
    }
    return null;
}

fn validateFieldValue(
    ir: *core.Ir,
    sema: *const SemanticEnv,
    field: declarations.FieldDescriptor,
    key: []const u8,
    value_info: TypeInfo,
    origin: []const u8,
) !void {
    if (!sema.valueMatches(field.module_id, field.value_type, value_info.string_literal, value_info.sort)) {
        try addUserReport(
            ir,
            origin,
            "InvalidFieldValue: field '{s}' expects {s}, got {s}",
            .{ key, sema.valueLabel(field.module_id, field.value_type), @tagName(value_info.sort) },
        );
        return error.InvalidSemanticSort;
    }
}

fn validatePropertySetStatement(
    allocator: std.mem.Allocator,
    ir: ?*core.Ir,
    sema: *const SemanticEnv,
    env: *const TypeEnv,
    object_name: []const u8,
    property_name: []const u8,
    value: ast.Expr,
    origin: []const u8,
) !void {
    const object_info = env.get(object_name) orelse {
        try addUserReport(ir, origin, "UnknownIdentifier: unknown identifier: {s}", .{object_name});
        return error.UnknownIdentifier;
    };
    try ensureSort(ir, object_info.sort, .object, origin, .UnmatchedArgumentType);
    const value_info = try inferExprInfo(allocator, ir, sema, env, value, origin);
    if (ir) |sink| {
        if (lookupFieldForTarget(sema, object_info, property_name)) |field| {
            try validateFieldValue(sink, sema, field, property_name, value_info, origin);
            return;
        }
        try addUserReport(ir, origin, "UnknownField: unknown field: {s}", .{property_name});
        return error.InvalidSemanticSort;
    }
}

pub fn expectedPrimitiveArgSort(descriptor: registry.PrimitiveDescriptor, index: usize) ?core.SemanticSort {
    const arg_sort = if (descriptor.arg_sorts.len == 0)
        return null
    else if (index < descriptor.arg_sorts.len)
        descriptor.arg_sorts[index]
    else
        descriptor.arg_sorts[descriptor.arg_sorts.len - 1];

    return switch (arg_sort) {
        .any => null,
        .document => .document,
        .page => .page,
        .object => .object,
        .selection => .selection,
        .anchor => .anchor,
        .function => .function,
        .style => .style,
        .string => .string,
        .number => .number,
        .constraints => .constraints,
    };
}

fn statementOrigin(allocator: std.mem.Allocator, span: ast.Span) ![]const u8 {
    if (diagnostic_origin_path.len != 0) {
        return std.fmt.allocPrint(allocator, "path:{s}:bytes:{d}-{d}", .{ diagnostic_origin_path, span.start, span.end });
    }
    return std.fmt.allocPrint(allocator, "bytes:{d}-{d}", .{ span.start, span.end });
}
