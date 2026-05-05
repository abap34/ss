const std = @import("std");
const core = @import("core");
const ast = @import("ast");
const names = @import("../language/names.zig");
const declarations = @import("../language/declarations.zig");
const registry = @import("../language/registry.zig");
const module_loader = @import("../modules/loader.zig");
const syntax = @import("../syntax/parse.zig");
const property_schema = @import("../property_schema.zig");
const utils = @import("utils");
const source_utils = utils.source;
const Type = ast.Type;

pub const FunctionContract = struct {
    min_param_count: usize,
    max_param_count: usize,
    returns_value: bool,
    result_sort: core.SemanticSort,
};

const TypeInfo = struct {
    ty: Type = Type.any,
    sort: core.SemanticSort,
    object_shape: property_schema.ObjectShape = .unknown,
    object_class: ?[]const u8 = null,
    string_literal: ?[]const u8 = null,
};

const TypeEnv = std.StringHashMap(TypeInfo);
pub const VariableInfo = TypeInfo;

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

pub fn valueSort(value: core.Value) core.SemanticSort {
    return switch (value) {
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
        .fragment => .fragment,
    };
}

pub fn ensureValueSort(
    ir: anytype,
    page_id: ?core.NodeId,
    value: core.Value,
    expected: core.SemanticSort,
    origin: []const u8,
) !void {
    return ensureValueSortWithCode(ir, page_id, value, expected, origin, .UnmatchedArgumentType);
}

pub fn ensureValueSortWithCode(
    ir: anytype,
    page_id: ?core.NodeId,
    value: core.Value,
    expected: core.SemanticSort,
    origin: []const u8,
    code: core.TypeMismatchCode,
) !void {
    const actual = valueSort(value);
    if (actual != expected) {
        try ir.addValidationDiagnostic(.@"error", page_id, null, origin, .{
            .type_mismatch = .{ .code = code, .expected = expected, .actual = actual },
        });
        return error.InvalidSemanticSort;
    }
}

pub fn functionRefFor(allocator: std.mem.Allocator, func: ast.FunctionDecl) !core.FunctionRef {
    const contract = functionContract(func);
    const param_sorts = try allocator.alloc(core.SemanticSort, func.params.items.len);
    for (func.params.items, 0..) |param, index| {
        param_sorts[index] = param.sort;
    }
    return .{
        .name = func.name,
        .param_count = contract.max_param_count,
        .param_sorts = param_sorts,
        .returns_value = contract.returns_value,
        .result_sort = contract.result_sort,
        .effect = .unknown,
    };
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
    try sink.addValidationDiagnostic(.@"error", null, null, origin, .{
        .user_report = .{ .message = message },
    });
}

fn infoFromSort(sort: core.SemanticSort) TypeInfo {
    return .{ .ty = Type.fromSort(sort), .sort = sort };
}

fn infoFromType(ty: Type) TypeInfo {
    return .{
        .ty = ty,
        .sort = ty.toRuntimeSort() orelse .fragment,
        .object_class = if (ty.tag == .object) ty.class_name else if (ty.tag == .selection and ty.param == .object) ty.param_class_name else null,
    };
}

fn infoForSelectionItem(sort: core.SelectionItemSort) TypeInfo {
    return infoFromType(Type.fromSelectionItemSort(sort));
}

fn typeLabelAlloc(allocator: std.mem.Allocator, ty: Type) ![]const u8 {
    return ty.formatAlloc(allocator);
}

pub fn functionContract(func: ast.FunctionDecl) FunctionContract {
    return .{
        .min_param_count = requiredParamCount(func),
        .max_param_count = func.params.items.len,
        .returns_value = functionReturnsValue(func),
        .result_sort = func.result_sort,
    };
}

pub fn requiredParamCount(func: ast.FunctionDecl) usize {
    var required: usize = 0;
    for (func.params.items) |param| {
        if (param.default_value == null) required += 1;
    }
    return required;
}

pub fn functionReturnsValue(func: ast.FunctionDecl) bool {
    return functionBodyReturns(func.statements.items);
}

pub fn functionBodyReturns(statements: []const ast.Statement) bool {
    for (statements) |stmt| {
        switch (stmt.kind) {
            .return_expr => return true,
            else => {},
        }
    }
    return false;
}

pub fn checkFunctionDefinitions(
    allocator: std.mem.Allocator,
    ir: *core.Ir,
    functions: *const std.StringHashMap(ast.FunctionDecl),
) !void {
    defer clearDiagnosticOriginModule();
    try checkFunctionCallGraph(allocator, ir, functions);

    var it = functions.iterator();
    while (it.next()) |entry| {
        if (ir.function_metadata.get(entry.key_ptr.*)) |metadata| {
            if (ir.moduleById(metadata.module_id)) |module| setDiagnosticOriginModule(module);
        } else {
            clearDiagnosticOriginModule();
        }
        try checkFunction(allocator, ir, functions, entry.value_ptr.*);
    }
}

pub fn typecheckProgram(
    allocator: std.mem.Allocator,
    ir: *core.Ir,
) !void {
    defer clearDiagnosticOriginModule();
    try checkObjectDeclarations(allocator, ir);
    try checkPropertyDeclarations(allocator, ir);
    try checkFunctionDefinitions(allocator, ir, &ir.functions);
    for (ir.module_order.items) |module_id| {
        const module = ir.moduleById(module_id) orelse continue;
        setDiagnosticOriginModule(module);
        try checkPageStatements(allocator, ir, &ir.functions, module.program);
    }
}

fn checkObjectDeclarations(allocator: std.mem.Allocator, ir: *core.Ir) !void {
    var roles = std.StringHashMap([]const u8).init(allocator);
    defer roles.deinit();
    defer clearDiagnosticOriginModule();

    for (ir.module_order.items) |module_id| {
        const module = ir.moduleById(module_id) orelse continue;
        setDiagnosticOriginModule(module);
        for (module.program.objects.items) |object_decl| {
            try checkObjectDeclaration(allocator, ir, module.id, object_decl);
            try checkRolesUnique(allocator, ir, &roles, object_decl.name, object_decl.roles.items, object_decl.span);
        }
        for (module.program.object_extensions.items) |extension| {
            try checkObjectExtension(allocator, ir, module.id, extension);
            try checkRolesUnique(allocator, ir, &roles, extension.target, extension.roles.items, extension.span);
        }
    }
}

fn checkObjectDeclaration(
    allocator: std.mem.Allocator,
    ir: *core.Ir,
    module_id: core.SourceModuleId,
    object_decl: ast.ObjectDecl,
) !void {
    const origin = try statementOrigin(allocator, object_decl.span);
    defer allocator.free(origin);
    if (object_decl.base) |base| {
        if (!declarations.classExists(ir, base)) {
            try addUserReport(ir, origin, "InvalidObjectDeclaration: unknown base object class: {s}", .{base});
            return error.InvalidSemanticSort;
        }
    }
    try checkObjectFields(allocator, ir, module_id, object_decl.fields.items);
}

fn checkObjectExtension(
    allocator: std.mem.Allocator,
    ir: *core.Ir,
    module_id: core.SourceModuleId,
    extension: ast.ObjectExtensionDecl,
) !void {
    const origin = try statementOrigin(allocator, extension.span);
    defer allocator.free(origin);
    if (!declarations.classExists(ir, extension.target)) {
        try addUserReport(ir, origin, "InvalidObjectExtension: unknown object class: {s}", .{extension.target});
        return error.InvalidSemanticSort;
    }
    if (extension.implements) |implements| {
        if (!declarations.classExists(ir, implements)) {
            try addUserReport(ir, origin, "InvalidObjectExtension: unknown protocol: {s}", .{implements});
            return error.InvalidSemanticSort;
        }
    }
    try checkObjectFields(allocator, ir, module_id, extension.fields.items);
}

fn checkObjectFields(
    allocator: std.mem.Allocator,
    ir: *core.Ir,
    module_id: core.SourceModuleId,
    fields: []const ast.ObjectFieldDecl,
) !void {
    for (fields) |field| {
        if (property_schema.resolveValueType(ir, module_id, field.value_type) != null) continue;
        const origin = try statementOrigin(allocator, field.span);
        defer allocator.free(origin);
        try addUserReport(ir, origin, "InvalidFieldSchema: unknown field value type: {s}", .{field.value_type});
        return error.InvalidSemanticSort;
    }
}

fn checkRolesUnique(
    allocator: std.mem.Allocator,
    ir: *core.Ir,
    roles: *std.StringHashMap([]const u8),
    class_name: []const u8,
    role_names: []const []const u8,
    span: ast.Span,
) !void {
    for (role_names) |role_name| {
        if (roles.get(role_name)) |existing_class| {
            const origin = try statementOrigin(allocator, span);
            defer allocator.free(origin);
            try addUserReport(
                ir,
                origin,
                "DuplicateRole: role '{s}' is already provided by {s}",
                .{ role_name, existing_class },
            );
            return error.InvalidSemanticSort;
        }
        try roles.put(role_name, class_name);
    }
}

fn checkPropertyDeclarations(allocator: std.mem.Allocator, ir: *core.Ir) !void {
    defer clearDiagnosticOriginModule();
    for (ir.modules.items) |module| {
        setDiagnosticOriginModule(&module);
        for (module.program.properties.items) |property| {
            try checkPropertyDeclaration(allocator, ir, module.id, property);
        }
    }
}

fn checkPropertyDeclaration(
    allocator: std.mem.Allocator,
    ir: *core.Ir,
    module_id: core.SourceModuleId,
    property: ast.PropertyDecl,
) !void {
    const origin = try statementOrigin(allocator, property.span);
    defer allocator.free(origin);
    if (property_schema.resolveValueType(ir, module_id, property.value_type) == null) {
        try addUserReport(ir, origin, "InvalidPropertySchema: unknown property value type: {s}", .{property.value_type});
        return error.InvalidSemanticSort;
    }
    for (property.shapes.items) |shape_name| {
        if (std.mem.eql(u8, shape_name, "any")) continue;
        if (property_schema.parseShape(shape_name) != null) continue;
        try addUserReport(ir, origin, "InvalidPropertySchema: unknown property shape: {s}", .{shape_name});
        return error.InvalidSemanticSort;
    }
}

pub fn collectVariableTypesFromProgram(
    allocator: std.mem.Allocator,
    functions: *const std.StringHashMap(ast.FunctionDecl),
    program: ast.Program,
) !std.StringHashMap(core.SemanticSort) {
    var infos = try collectVariableInfoFromProgram(allocator, functions, program);
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
) !std.StringHashMap(VariableInfo) {
    var variables = std.StringHashMap(VariableInfo).init(allocator);
    errdefer variables.deinit();

    for (program.functions.items) |func| {
        var env = TypeEnv.init(allocator);
        defer env.deinit();

        for (func.params.items) |param| {
            if (param.default_value) |default_value| {
                const info = try inferExprInfo(allocator, null, functions, &env, default_value.*, "");
                try ensureType(null, allocator, info, param.ty, "", .UnmatchedArgumentType);
            }
            try env.put(param.name, .{ .ty = param.ty, .sort = param.sort });
            try variables.put(param.name, .{ .ty = param.ty, .sort = param.sort });
        }

        for (func.statements.items) |stmt| {
            try collectVariableTypesFromStatement(allocator, &env, functions, stmt, &variables);
        }
    }

    for (program.pages.items) |page| {
        var env = TypeEnv.init(allocator);
        defer env.deinit();

        for (page.statements.items) |stmt| {
            try collectVariableTypesFromStatement(allocator, &env, functions, stmt, &variables);
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
    ir.variable_types = try collectVariableTypesFromProgram(allocator, &ir.functions, ir.projectProgram());
    try populateIrAnalysis(allocator, &ir);
    return ir;
}

pub fn populateIrAnalysis(allocator: std.mem.Allocator, ir: *core.Ir) !void {
    for (ir.modules.items) |module| {
        if (module.kind == .project) continue;
        try collectDefinitionsFromProgram(allocator, module.source, module.program, module.id, module.path, false, &ir.definitions);
    }
    try collectDefinitionsFromProgram(allocator, ir.projectSource(), ir.projectProgram(), ir.project_module_id, null, true, &ir.definitions);
    try collectProgramHints(allocator, &ir.hints, ir.projectSource(), ir.projectProgram(), &ir.functions);
}

pub fn refreshSolvedFrameHints(allocator: std.mem.Allocator, ir: *core.Ir) !void {
    var write_index: usize = 0;
    for (ir.hints.items) |hint| {
        if (hint.kind == .solved_frame) {
            allocator.free(hint.label);
            continue;
        }
        ir.hints.items[write_index] = hint;
        write_index += 1;
    }
    ir.hints.items.len = write_index;
    try collectSolvedSizeHints(allocator, ir.projectSource(), ir, &ir.hints);
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

pub fn formatPrimitiveSignature(
    allocator: std.mem.Allocator,
    descriptor: registry.PrimitiveDescriptor,
) ![]const u8 {
    var params = std.ArrayList(u8).empty;
    defer params.deinit(allocator);
    for (descriptor.arg_names, 0..) |_, index| {
        if (index != 0) try params.appendSlice(allocator, ", ");
        const label = try formatPrimitiveParam(allocator, descriptor, index);
        defer allocator.free(label);
        try params.appendSlice(allocator, label);
    }
    return std.fmt.allocPrint(allocator, "{s}({s}) -> {s}", .{ descriptor.name, params.items, resultText(descriptor.result_sort) });
}

pub fn formatPrimitiveParam(
    allocator: std.mem.Allocator,
    descriptor: registry.PrimitiveDescriptor,
    index: usize,
) ![]const u8 {
    const name = descriptor.arg_names[index];
    if (registry.primitiveArgType(descriptor, index)) |ty| {
        const label = try ty.formatAlloc(allocator);
        defer allocator.free(label);
        return std.fmt.allocPrint(allocator, "{s}: {s}", .{ name, label });
    }
    return allocator.dupe(u8, name);
}

pub fn formatUserSignature(
    allocator: std.mem.Allocator,
    name: []const u8,
    func: ast.FunctionDecl,
) ![]const u8 {
    const result_label = try func.result_type.formatAlloc(allocator);
    defer allocator.free(result_label);
    if (isConst(func)) return std.fmt.allocPrint(allocator, "const {s}: {s}", .{ name, result_label });

    var params = std.ArrayList(u8).empty;
    defer params.deinit(allocator);
    for (func.params.items, 0..) |param, index| {
        if (index != 0) try params.appendSlice(allocator, ", ");
        const label = try formatUserParam(allocator, param);
        defer allocator.free(label);
        try params.appendSlice(allocator, label);
    }
    return std.fmt.allocPrint(allocator, "{s}({s}) -> {s}", .{ name, params.items, result_label });
}

pub fn formatUserParam(allocator: std.mem.Allocator, param: ast.ParamDecl) ![]const u8 {
    const label = try param.ty.formatAlloc(allocator);
    defer allocator.free(label);
    if (param.default_value) |default_value| {
        const text = try formatExpr(allocator, default_value.*);
        defer allocator.free(text);
        return std.fmt.allocPrint(allocator, "{s}: {s} = {s}", .{ param.name, label, text });
    }
    return std.fmt.allocPrint(allocator, "{s}: {s}", .{ param.name, label });
}

fn formatExpr(allocator: std.mem.Allocator, expr: ast.Expr) ![]const u8 {
    return switch (expr) {
        .ident => |name| allocator.dupe(u8, name),
        .string => |text| std.fmt.allocPrint(allocator, "\"{s}\"", .{text}),
        .number => |value| std.fmt.allocPrint(allocator, "{d}", .{value}),
        .call => |call| blk: {
            var args = std.ArrayList(u8).empty;
            defer args.deinit(allocator);
            for (call.args.items, 0..) |arg, index| {
                if (index != 0) try args.appendSlice(allocator, ", ");
                const text = try formatExpr(allocator, arg);
                defer allocator.free(text);
                try args.appendSlice(allocator, text);
            }
            break :blk std.fmt.allocPrint(allocator, "{s}({s})", .{ call.name, args.items });
        },
    };
}

pub fn resultText(result_sort: ?core.SemanticSort) []const u8 {
    return if (result_sort) |sort| @tagName(sort) else "unknown";
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

fn collectDefinitionsFromProgram(
    allocator: std.mem.Allocator,
    source: []const u8,
    program: ast.Program,
    module_id: core.SourceModuleId,
    file: ?[]const u8,
    include_variables: bool,
    definitions: *std.StringHashMap(core.Definition),
) !void {
    for (program.functions.items) |func| {
        const keyword = if (isConst(func)) "const" else "fn";
        const kind: core.DefinitionKind = if (isConst(func)) .constant else .function;
        if (findIdentifierOffsetAfterKeyword(source, func.span.start, keyword, func.name)) |location| {
            const loc = utils.err.computeLineColumn(source, location.offset);
            try putDefinition(allocator, definitions, func.name, loc.line, loc.column, location.length, kind, module_id, file);
        }
        if (include_variables) {
            for (func.statements.items) |stmt| {
                try collectDefinitionsFromStatement(allocator, source, module_id, stmt, definitions);
            }
        }
    }
    if (include_variables) {
        for (program.pages.items) |page| {
            for (page.statements.items) |stmt| {
                try collectDefinitionsFromStatement(allocator, source, module_id, stmt, definitions);
            }
        }
    }
}

fn collectDefinitionsFromStatement(
    allocator: std.mem.Allocator,
    source: []const u8,
    module_id: core.SourceModuleId,
    stmt: ast.Statement,
    definitions: *std.StringHashMap(core.Definition),
) !void {
    switch (stmt.kind) {
        .let_binding => |binding| try putStatementDefinition(allocator, source, module_id, stmt, "let", binding.name, definitions),
        .bind_binding => |binding| try putStatementDefinition(allocator, source, module_id, stmt, "bind", binding.name, definitions),
        else => {},
    }
}

fn putStatementDefinition(
    allocator: std.mem.Allocator,
    source: []const u8,
    module_id: core.SourceModuleId,
    stmt: ast.Statement,
    keyword: []const u8,
    name: []const u8,
    definitions: *std.StringHashMap(core.Definition),
) !void {
    if (findIdentifierOffsetAfterKeyword(source, stmt.span.start, keyword, name)) |location| {
        const loc = utils.err.computeLineColumn(source, location.offset);
        try putDefinition(allocator, definitions, name, loc.line, loc.column, location.length, .variable, module_id, null);
    }
}

fn putDefinition(
    allocator: std.mem.Allocator,
    definitions: *std.StringHashMap(core.Definition),
    name: []const u8,
    line: usize,
    column: usize,
    length: usize,
    kind: core.DefinitionKind,
    module_id: core.SourceModuleId,
    file: ?[]const u8,
) !void {
    if (definitions.fetchRemove(name)) |entry| {
        allocator.free(entry.key);
        if (entry.value.file) |old_file| allocator.free(old_file);
    }
    try definitions.put(
        try allocator.dupe(u8, name),
        .{
            .line = line,
            .column = column,
            .length = length,
            .kind = kind,
            .module_id = module_id,
            .file = if (file) |path| try allocator.dupe(u8, path) else null,
        },
    );
}

fn collectProgramHints(
    allocator: std.mem.Allocator,
    hints: *std.ArrayList(core.InlayHint),
    source: []const u8,
    program: ast.Program,
    functions: *const std.StringHashMap(ast.FunctionDecl),
) !void {
    for (program.functions.items) |func| {
        for (func.statements.items) |stmt| {
            try collectStatementHints(allocator, hints, functions, source, stmt);
        }
    }
    for (program.pages.items) |page| {
        for (page.statements.items) |stmt| {
            try collectStatementHints(allocator, hints, functions, source, stmt);
        }
    }
}

fn collectStatementHints(
    allocator: std.mem.Allocator,
    hints: *std.ArrayList(core.InlayHint),
    functions: *const std.StringHashMap(ast.FunctionDecl),
    source: []const u8,
    stmt: ast.Statement,
) !void {
    switch (stmt.kind) {
        .let_binding => |binding| try collectExprHints(allocator, hints, functions, source, stmt.span, binding.expr),
        .bind_binding => |binding| try collectExprHints(allocator, hints, functions, source, stmt.span, binding.expr),
        .return_expr => |expr| try collectExprHints(allocator, hints, functions, source, stmt.span, expr),
        .property_set => |property_set| try collectExprHints(allocator, hints, functions, source, stmt.span, property_set.value),
        .expr_stmt => |expr| try collectExprHints(allocator, hints, functions, source, stmt.span, expr),
        else => {},
    }
}

fn collectExprHints(
    allocator: std.mem.Allocator,
    hints: *std.ArrayList(core.InlayHint),
    functions: *const std.StringHashMap(ast.FunctionDecl),
    source: []const u8,
    span: ast.Span,
    expr: ast.Expr,
) !void {
    switch (expr) {
        .call => |call| {
            try hintForCallExpr(allocator, hints, functions, source, span, call);
            for (call.args.items) |arg| try collectExprHints(allocator, hints, functions, source, span, arg);
        },
        else => {},
    }
}

fn hintForCallExpr(
    allocator: std.mem.Allocator,
    hints: *std.ArrayList(core.InlayHint),
    functions: *const std.StringHashMap(ast.FunctionDecl),
    source: []const u8,
    span: ast.Span,
    call: ast.CallExpr,
) !void {
    if (call.args.items.len == 0) return;
    const slice = source[span.start..@min(span.end, source.len)];
    const arg_starts = try findCallArgStartOffsets(allocator, slice, call.name, call.args.items.len);
    defer allocator.free(arg_starts);
    const hint_count = @min(call.args.items.len, arg_starts.len);
    for (0..hint_count) |index| {
        const param_name = callParamName(functions, call.name, index) orelse continue;
        const label = try std.fmt.allocPrint(allocator, "{s}:", .{param_name});
        try appendInlayHint(allocator, hints, source, span.start + arg_starts[index], label, .parameter_names);
    }
}

fn callParamName(functions: *const std.StringHashMap(ast.FunctionDecl), call_name: []const u8, index: usize) ?[]const u8 {
    if (functions.get(call_name)) |func| {
        if (index < func.params.items.len) return func.params.items[index].name;
        return null;
    }
    if (registry.lookupPrimitiveCall(call_name)) |descriptor| {
        if (descriptor.arg_names.len == 0) return null;
        return if (index < descriptor.arg_names.len) descriptor.arg_names[index] else descriptor.arg_names[descriptor.arg_names.len - 1];
    }
    return null;
}

fn collectSolvedSizeHints(
    allocator: std.mem.Allocator,
    source: []const u8,
    ir: *core.Ir,
    hints: *std.ArrayList(core.InlayHint),
) !void {
    var best_by_origin = std.StringHashMap(core.NodeId).init(allocator);
    defer best_by_origin.deinit();

    for (ir.nodes.items) |node| {
        if ((node.kind != .object and node.kind != .derived) or !node.attached) continue;
        const origin = node.origin orelse continue;
        if (node.role != null and std.mem.eql(u8, node.role.?, "panel")) continue;
        if (best_by_origin.get(origin)) |existing| {
            if (node.id > existing) try best_by_origin.put(origin, node.id);
        } else {
            try best_by_origin.put(origin, node.id);
        }
    }

    var iterator = best_by_origin.iterator();
    while (iterator.next()) |entry| {
        const span = utils.err.parseByteOrigin(entry.key_ptr.*) orelse continue;
        const node = ir.getNode(entry.value_ptr.*) orelse continue;
        const label = try std.fmt.allocPrint(
            allocator,
            " x={d:.0} y={d:.0} w={d:.0} h={d:.0}",
            .{ node.frame.x, node.frame.y, node.frame.width, node.frame.height },
        );
        try appendInlayHint(allocator, hints, source, trimHintByteIndexToLineEnd(source, span.end), label, .solved_frame);
    }
}

fn appendInlayHint(
    allocator: std.mem.Allocator,
    hints: *std.ArrayList(core.InlayHint),
    source: []const u8,
    byte_index: usize,
    label: []const u8,
    kind: core.InlayHintKind,
) !void {
    const loc = utils.err.computeLineColumn(source, @min(byte_index, source.len));
    try hints.append(allocator, .{
        .line = loc.line,
        .column = loc.column,
        .label = label,
        .kind = kind,
    });
}

fn trimHintByteIndexToLineEnd(source: []const u8, byte_index: usize) usize {
    var index = @min(byte_index, source.len);
    while (index < source.len and source[index] != '\n') : (index += 1) {}
    return index;
}

fn findCallArgStartOffsets(
    allocator: std.mem.Allocator,
    slice: []const u8,
    call_name: []const u8,
    arg_count: usize,
) ![]usize {
    var offsets = std.ArrayList(usize).empty;
    defer offsets.deinit(allocator);

    const name_pos = std.mem.indexOf(u8, slice, call_name) orelse return try allocator.alloc(usize, 0);
    var index: usize = name_pos + call_name.len;
    while (index < slice.len and std.ascii.isWhitespace(slice[index])) : (index += 1) {}
    if (index >= slice.len or slice[index] != '(') return try allocator.alloc(usize, 0);
    index += 1;

    while (index < slice.len and offsets.items.len < arg_count) {
        while (index < slice.len and (std.ascii.isWhitespace(slice[index]) or slice[index] == ',')) : (index += 1) {}
        if (index >= slice.len or slice[index] == ')') break;
        try offsets.append(allocator, index);
        index = skipExpr(slice, index);
    }
    return offsets.toOwnedSlice(allocator);
}

fn skipExpr(slice: []const u8, start: usize) usize {
    var index = start;
    var depth: usize = 0;
    while (index < slice.len) : (index += 1) {
        const ch = slice[index];
        switch (ch) {
            '"' => index = skipString(slice, index),
            '(' => depth += 1,
            ')' => {
                if (depth == 0) break;
                depth -= 1;
                if (depth == 0) return index + 1;
            },
            ',' => if (depth == 0) break,
            else => {},
        }
    }
    return index;
}

fn skipString(slice: []const u8, start: usize) usize {
    var index = start + 1;
    var escaped = false;
    while (index < slice.len) : (index += 1) {
        if (escaped) {
            escaped = false;
            continue;
        }
        if (slice[index] == '\\') {
            escaped = true;
            continue;
        }
        if (slice[index] == '"') return index;
    }
    return slice.len;
}

fn findIdentifierOffsetAfterKeyword(source: []const u8, start: usize, keyword: []const u8, expected_name: []const u8) ?struct { offset: usize, length: usize } {
    var index = start;
    while (index < source.len and std.ascii.isWhitespace(source[index])) : (index += 1) {}
    if (index + keyword.len > source.len or !std.mem.eql(u8, source[index .. index + keyword.len], keyword)) return null;
    index += keyword.len;
    while (index < source.len and std.ascii.isWhitespace(source[index])) : (index += 1) {}
    const ident_start = index;
    if (index >= source.len or !source_utils.isIdentifierStart(source[index])) return null;
    index += 1;
    while (index < source.len and source_utils.isIdentifierContinue(source[index])) : (index += 1) {}
    if (!std.mem.eql(u8, source[ident_start..index], expected_name)) return null;
    return .{ .offset = ident_start, .length = index - ident_start };
}

fn collectVariableTypesFromStatement(
    allocator: std.mem.Allocator,
    env: *TypeEnv,
    functions: *const std.StringHashMap(ast.FunctionDecl),
    stmt: ast.Statement,
    variables: *std.StringHashMap(VariableInfo),
) !void {
    const origin = try statementOrigin(allocator, stmt.span);
    defer allocator.free(origin);
    switch (stmt.kind) {
        .let_binding => |binding| {
            const info = try inferExprInfo(allocator, null, functions, env, binding.expr, origin);
            try env.put(binding.name, info);
            try variables.put(binding.name, info);
        },
        .bind_binding => |binding| {
            _ = try inferExprInfo(allocator, null, functions, env, binding.expr, origin);
            try env.put(binding.name, infoFromSort(.fragment));
            try variables.put(binding.name, infoFromSort(.fragment));
        },
        .return_expr => |expr| {
            _ = try inferExprInfo(allocator, null, functions, env, expr, origin);
        },
        .property_set => |property_set| {
            _ = try inferExprInfo(allocator, null, functions, env, property_set.value, origin);
        },
        .expr_stmt => |expr| {
            _ = try inferExprInfo(allocator, null, functions, env, expr, origin);
        },
        .constrain => |decl| {
            if (decl.offset) |expr| {
                _ = try inferExprInfo(allocator, null, functions, env, expr, origin);
            }
        },
    }
}

fn checkFunctionCallGraph(
    allocator: std.mem.Allocator,
    ir: *core.Ir,
    functions: *const std.StringHashMap(ast.FunctionDecl),
) !void {
    var states = std.StringHashMap(u8).init(allocator);
    defer states.deinit();

    var it = functions.iterator();
    while (it.next()) |entry| {
        try visitFunction(allocator, ir, functions, &states, entry.key_ptr.*);
    }
}

fn visitFunction(
    allocator: std.mem.Allocator,
    ir: *core.Ir,
    functions: *const std.StringHashMap(ast.FunctionDecl),
    states: *std.StringHashMap(u8),
    name: []const u8,
) !void {
    if (states.get(name)) |state| {
        if (state == 1) {
            const func = functions.get(name).?;
            try reportRecursiveFunction(allocator, ir, func);
            return error.RecursiveFunction;
        }
        if (state == 2) return;
    }

    const func = functions.get(name) orelse return;
    try states.put(name, 1);

    var callees = std.ArrayList([]const u8).empty;
    defer callees.deinit(allocator);
    try collectFunctionCallees(allocator, functions, func, &callees);
    for (callees.items) |callee| {
        if (states.get(callee)) |state| {
            if (state == 1) {
                try reportRecursiveFunction(allocator, ir, func);
                return error.RecursiveFunction;
            }
        }
        try visitFunction(allocator, ir, functions, states, callee);
    }

    try states.put(name, 2);
}

fn reportRecursiveFunction(allocator: std.mem.Allocator, ir: *core.Ir, func: ast.FunctionDecl) !void {
    if (ir.function_metadata.get(func.name)) |metadata| {
        if (ir.moduleById(metadata.module_id)) |module| setDiagnosticOriginModule(module);
    }
    try ir.addValidationDiagnostic(.@"error", null, null, try statementOrigin(allocator, func.span), .{
        .recursive_function = .{ .function_name = func.name },
    });
}

fn collectFunctionCallees(
    allocator: std.mem.Allocator,
    functions: *const std.StringHashMap(ast.FunctionDecl),
    func: ast.FunctionDecl,
    callees: *std.ArrayList([]const u8),
) !void {
    for (func.params.items) |param| {
        if (param.default_value) |default_value| {
            try collectExprCallees(allocator, functions, default_value.*, callees);
        }
    }
    for (func.statements.items) |stmt| {
        try collectStatementCallees(allocator, functions, stmt, callees);
    }
}

fn collectStatementCallees(
    allocator: std.mem.Allocator,
    functions: *const std.StringHashMap(ast.FunctionDecl),
    stmt: ast.Statement,
    callees: *std.ArrayList([]const u8),
) !void {
    switch (stmt.kind) {
        .let_binding => |binding| try collectExprCallees(allocator, functions, binding.expr, callees),
        .bind_binding => |binding| try collectExprCallees(allocator, functions, binding.expr, callees),
        .return_expr => |expr| try collectExprCallees(allocator, functions, expr, callees),
        .property_set => |property_set| try collectExprCallees(allocator, functions, property_set.value, callees),
        .constrain => |decl| if (decl.offset) |expr| try collectExprCallees(allocator, functions, expr, callees),
        .expr_stmt => |expr| try collectExprCallees(allocator, functions, expr, callees),
    }
}

fn collectExprCallees(
    allocator: std.mem.Allocator,
    functions: *const std.StringHashMap(ast.FunctionDecl),
    expr: ast.Expr,
    callees: *std.ArrayList([]const u8),
) !void {
    switch (expr) {
        .ident => |name| {
            if (functions.get(name)) |func| {
                if (isConst(func)) try appendUniqueCallee(allocator, callees, name);
            }
        },
        .call => |call| {
            if (functions.get(call.name)) |func| {
                if (!isConst(func)) try appendUniqueCallee(allocator, callees, call.name);
            }
            if (registry.lookupPrimitiveCall(call.name)) |descriptor| {
                if (descriptor.op == .foreach or descriptor.op == .fold or descriptor.op == .join) {
                    const callback_index: usize = if (descriptor.op == .foreach) 1 else 2;
                    if (call.args.items.len > callback_index) {
                        switch (call.args.items[callback_index]) {
                            .ident => |name| if (functions.contains(name)) try appendUniqueCallee(allocator, callees, name),
                            else => {},
                        }
                    }
                }
            }
            for (call.args.items) |arg| try collectExprCallees(allocator, functions, arg, callees);
        },
        else => {},
    }
}

fn appendUniqueCallee(allocator: std.mem.Allocator, callees: *std.ArrayList([]const u8), name: []const u8) !void {
    for (callees.items) |existing| {
        if (std.mem.eql(u8, existing, name)) return;
    }
    try callees.append(allocator, name);
}

fn checkFunction(
    allocator: std.mem.Allocator,
    ir: *core.Ir,
    functions: *const std.StringHashMap(ast.FunctionDecl),
    func: ast.FunctionDecl,
) !void {
    var env = TypeEnv.init(allocator);
    defer env.deinit();

    const func_origin = try statementOrigin(allocator, func.span);
    defer allocator.free(func_origin);
    for (func.params.items) |param| {
        if (param.default_value) |default_value| {
            const info = try inferExprInfo(allocator, ir, functions, &env, default_value.*, func_origin);
            try ensureType(ir, allocator, info, param.ty, func_origin, .UnmatchedArgumentType);
        }
        var param_info = infoFromType(param.ty);
        param_info.sort = param.sort;
        try env.put(param.name, param_info);
    }

    for (func.statements.items) |stmt| {
        try checkStatement(allocator, ir, functions, &env, func.result_type, stmt);
    }
}

fn checkPageStatements(
    allocator: std.mem.Allocator,
    ir: *core.Ir,
    functions: *const std.StringHashMap(ast.FunctionDecl),
    program: ast.Program,
) !void {
    for (program.pages.items) |page| {
        var env = TypeEnv.init(allocator);
        defer env.deinit();

        for (page.statements.items) |stmt| {
            try checkTopLevelStatement(allocator, ir, functions, &env, stmt);
        }
    }
}

fn checkTopLevelStatement(
    allocator: std.mem.Allocator,
    ir: *core.Ir,
    functions: *const std.StringHashMap(ast.FunctionDecl),
    env: *TypeEnv,
    stmt: ast.Statement,
) !void {
    const origin = try statementOrigin(allocator, stmt.span);
    switch (stmt.kind) {
        .let_binding => |binding| {
            const info = try inferExprInfo(allocator, ir, functions, env, binding.expr, origin);
            try env.put(binding.name, info);
        },
        .bind_binding => |binding| {
            _ = try inferExprInfo(allocator, ir, functions, env, binding.expr, origin);
            try env.put(binding.name, infoFromSort(.fragment));
        },
        .return_expr => {
            try addUserReport(ir, origin, "ReturnOutsideFunction: return is only valid inside a function", .{});
            return error.ReturnOutsideFunction;
        },
        .property_set => |property_set| {
            try validatePropertySetStatement(allocator, ir, functions, env, property_set.object_name, property_set.property_name, property_set.value, origin);
        },
        .expr_stmt => |expr| {
            _ = try inferExprInfo(allocator, ir, functions, env, expr, origin);
        },
        .constrain => |decl| {
            if (decl.offset) |expr| {
                const actual = try inferExprInfo(allocator, ir, functions, env, expr, origin);
                try ensureType(ir, allocator, actual, Type.number, origin, .UnmatchedArgumentType);
            }
        },
    }
}

fn checkStatement(
    allocator: std.mem.Allocator,
    ir: *core.Ir,
    functions: *const std.StringHashMap(ast.FunctionDecl),
    env: *TypeEnv,
    result_type: Type,
    stmt: ast.Statement,
) !void {
    const origin = try statementOrigin(allocator, stmt.span);
    switch (stmt.kind) {
        .let_binding => |binding| {
            const info = try inferExprInfo(allocator, ir, functions, env, binding.expr, origin);
            try env.put(binding.name, info);
        },
        .bind_binding => |binding| {
            _ = try inferExprInfo(allocator, ir, functions, env, binding.expr, origin);
            try env.put(binding.name, infoFromSort(.fragment));
        },
        .return_expr => |expr| {
            const actual = try inferExprInfo(allocator, ir, functions, env, expr, origin);
            try ensureType(ir, allocator, actual, result_type, origin, .UnmatchedReturnType);
        },
        .property_set => |property_set| {
            try validatePropertySetStatement(allocator, ir, functions, env, property_set.object_name, property_set.property_name, property_set.value, origin);
        },
        .expr_stmt => |expr| {
            _ = try inferExprInfo(allocator, ir, functions, env, expr, origin);
        },
        .constrain => |decl| {
            if (decl.offset) |expr| {
                const actual = try inferExprInfo(allocator, ir, functions, env, expr, origin);
                try ensureType(ir, allocator, actual, Type.number, origin, .UnmatchedArgumentType);
            }
        },
    }
}

fn inferExprSort(
    allocator: std.mem.Allocator,
    ir: ?*core.Ir,
    functions: *const std.StringHashMap(ast.FunctionDecl),
    env: *const TypeEnv,
    expr: ast.Expr,
    origin: []const u8,
) anyerror!core.SemanticSort {
    return (try inferExprInfo(allocator, ir, functions, env, expr, origin)).sort;
}

fn inferExprInfo(
    allocator: std.mem.Allocator,
    ir: ?*core.Ir,
    functions: *const std.StringHashMap(ast.FunctionDecl),
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
            if (functions.get(name)) |func| {
                if (isConst(func)) break :blk infoFromType(func.result_type);
                break :blk infoFromSort(.function);
            }
            try addUserReport(ir, origin, "UnknownIdentifier: unknown identifier: {s}", .{name});
            return error.UnknownIdentifier;
        },
        .call => |call| try inferCallInfo(allocator, ir, functions, env, call, origin),
    };
}

fn inferCallInfo(
    allocator: std.mem.Allocator,
    ir: ?*core.Ir,
    functions: *const std.StringHashMap(ast.FunctionDecl),
    env: *const TypeEnv,
    call: ast.CallExpr,
    origin: []const u8,
) anyerror!TypeInfo {
    if (functions.get(call.name)) |func| {
        if (isConst(func)) {
            try addUserReport(ir, origin, "UnknownFunction: constants are values; use '{s}' without parentheses", .{call.name});
            return error.UnknownFunction;
        }
        const min_arity = requiredParamCount(func);
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
            const actual = try inferExprInfo(allocator, ir, functions, env, arg, origin);
            try ensureType(ir, allocator, actual, param.ty, origin, .UnmatchedArgumentType);
        }
        return try inferUserFunctionReturnInfo(allocator, ir, functions, env, func, call, origin);
    }

    if (registry.lookupPrimitiveCall(call.name)) |descriptor| {
        if (call.args.items.len < descriptor.min_arity or call.args.items.len > descriptor.max_arity) {
            if (descriptor.min_arity == descriptor.max_arity) {
                try addUserReport(ir, origin, "InvalidArity: expected {d}, got {d}", .{ descriptor.min_arity, call.args.items.len });
            } else {
                try addUserReport(ir, origin, "InvalidArity: expected {d}..{d}, got {d}", .{ descriptor.min_arity, descriptor.max_arity, call.args.items.len });
            }
            return error.InvalidArity;
        }
        for (call.args.items, 0..) |arg, index| {
            const actual = try inferExprInfo(allocator, ir, functions, env, arg, origin);
            if (registry.primitiveArgType(descriptor, index)) |expected| {
                try ensureType(ir, allocator, actual, expected, origin, .UnmatchedArgumentType);
            }
        }
        const info = try primitiveResultTypeInfo(allocator, ir, functions, env, call, descriptor, origin);
        if (ir != null) {
            switch (descriptor.op) {
                .set_prop => try validateSetPropCall(ir.?, call, env, functions, origin),
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
    functions: *const std.StringHashMap(ast.FunctionDecl),
    caller_env: *const TypeEnv,
    func: ast.FunctionDecl,
    call: ast.CallExpr,
    origin: []const u8,
) !TypeInfo {
    var visiting = std.StringHashMap(void).init(allocator);
    defer visiting.deinit();
    return inferUserFunctionReturnInfoInner(allocator, ir, functions, caller_env, func, call, origin, &visiting);
}

fn inferUserFunctionReturnInfoInner(
    allocator: std.mem.Allocator,
    ir: ?*core.Ir,
    functions: *const std.StringHashMap(ast.FunctionDecl),
    caller_env: *const TypeEnv,
    func: ast.FunctionDecl,
    call: ast.CallExpr,
    origin: []const u8,
    visiting: *std.StringHashMap(void),
) !TypeInfo {
    if (visiting.contains(func.name)) {
        var info = infoFromType(func.result_type);
        info.object_shape = .generic;
        info.object_class = func.result_type.class_name;
        return info;
    }
    try visiting.put(func.name, {});
    defer _ = visiting.remove(func.name);

    var env = TypeEnv.init(allocator);
    defer env.deinit();
    for (func.params.items, 0..) |param, index| {
        const info: TypeInfo = if (index < call.args.items.len)
            try inferExprInfo(allocator, ir, functions, caller_env, call.args.items[index], origin)
        else if (param.default_value) |default_value|
            try inferExprInfo(allocator, ir, functions, &env, default_value.*, origin)
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
                const info = try inferExprInfo(allocator, null, functions, &env, binding.expr, "");
                try env.put(binding.name, info);
            },
            .bind_binding => |binding| {
                _ = try inferExprInfo(allocator, null, functions, &env, binding.expr, "");
                try env.put(binding.name, infoFromSort(.fragment));
            },
            .return_expr => |expr| {
                const info = try inferExprInfo(allocator, null, functions, &env, expr, "");
                result = mergeTypeInfo(result, info);
            },
            .property_set => |property_set| {
                try validatePropertySetStatement(allocator, ir, functions, &env, property_set.object_name, property_set.property_name, property_set.value, "");
            },
            .expr_stmt => |expr| {
                _ = try inferExprInfo(allocator, null, functions, &env, expr, "");
            },
            .constrain => |decl| {
                if (decl.offset) |expr| _ = try inferExprInfo(allocator, null, functions, &env, expr, "");
            },
        }
    }
    result.ty = func.result_type;
    result.sort = func.result_sort;
    if (func.result_type.class_name) |class_name| result.object_class = class_name;
    return result;
}

fn mergeTypeInfo(a: TypeInfo, b: TypeInfo) TypeInfo {
    return .{
        .ty = a.ty,
        .sort = a.sort,
        .object_shape = mergeObjectShape(a.object_shape, b.object_shape),
        .object_class = mergeObjectClass(a.object_class, b.object_class),
        .string_literal = mergeStringLiteral(a.string_literal, b.string_literal),
    };
}

fn mergeObjectShape(a: property_schema.ObjectShape, b: property_schema.ObjectShape) property_schema.ObjectShape {
    if (a == .unknown) return b;
    if (b == .unknown) return a;
    if (a == b) return a;
    return .generic;
}

fn mergeObjectClass(a: ?[]const u8, b: ?[]const u8) ?[]const u8 {
    if (a == null) return b;
    if (b == null) return a;
    if (std.mem.eql(u8, a.?, b.?)) return a;
    return null;
}

fn mergeStringLiteral(a: ?[]const u8, b: ?[]const u8) ?[]const u8 {
    if (a == null) return b;
    if (b == null) return a;
    if (std.mem.eql(u8, a.?, b.?)) return a;
    return null;
}

fn primitiveResultTypeInfo(
    allocator: std.mem.Allocator,
    ir: ?*core.Ir,
    functions: *const std.StringHashMap(ast.FunctionDecl),
    env: *const TypeEnv,
    call: ast.CallExpr,
    descriptor: registry.PrimitiveDescriptor,
    origin: []const u8,
) !TypeInfo {
    if (descriptor.op == .first) {
        if (call.args.items.len == 0) return infoFromSort(.object);
        const selection_info = try inferExprInfo(allocator, ir, functions, env, call.args.items[0], origin);
        var info = switch (selection_info.ty.param) {
            .page => infoFromSort(.page),
            .object, .any, .none => infoFromSort(.object),
            else => infoFromSort(selection_info.sort),
        };
        if (info.sort == .object) {
            info.object_shape = selection_info.object_shape;
            info.object_class = selection_info.object_class;
            info.ty.class_name = selection_info.object_class;
        }
        return info;
    }

    if (descriptor.op == .foreach) {
        if (call.args.items.len < 2) return infoFromType(Type.selection(.any));
        const selection_info = try inferExprInfo(allocator, ir, functions, env, call.args.items[0], origin);
        try validateCallbackShape(allocator, ir, functions, env, call, origin, 1, selection_info, 1, null);
        return selection_info;
    }

    if (descriptor.op == .fold) {
        if (call.args.items.len < 3) return infoFromSort(.string);
        const selection_info = try inferExprInfo(allocator, ir, functions, env, call.args.items[0], origin);
        try validateCallbackShape(allocator, ir, functions, env, call, origin, 2, selection_info, 2, .string);
        return infoFromSort(.string);
    }

    if (descriptor.op == .join) {
        if (call.args.items.len < 3) return infoFromSort(.string);
        const selection_info = try inferExprInfo(allocator, ir, functions, env, call.args.items[0], origin);
        try validateCallbackShape(allocator, ir, functions, env, call, origin, 2, selection_info, 1, .string);
        return infoFromSort(.string);
    }

    if (descriptor.op == .set_content or descriptor.op == .clear_content or descriptor.op == .append_content) {
        if (call.args.items.len == 0) return infoFromSort(.object);
        return try inferExprInfo(allocator, ir, functions, env, call.args.items[0], origin);
    }

    if (descriptor.op == .selection_union or descriptor.op == .selection_intersection or descriptor.op == .selection_difference) {
        return try inferSelectionAlgebraInfo(allocator, ir, functions, env, call, origin);
    }

    if (descriptor.op == .select) {
        return try inferSelectCallInfo(allocator, ir, functions, env, call, origin);
    }

    if (descriptor.op == .derive) {
        return try inferDeriveCallInfo(allocator, ir, functions, env, call, origin);
    }

    if (descriptor.op == .set_style) {
        if (call.args.items.len == 0) return infoFromSort(.object);
        const target_info = try inferExprInfo(allocator, ir, functions, env, call.args.items[0], origin);
        if (!(target_info.ty.tag == .object or (target_info.ty.tag == .selection and (target_info.ty.param == .object or target_info.ty.param == .any)))) {
            try ensureType(ir, allocator, target_info, Type.object, origin, .UnmatchedArgumentType);
        }
        return target_info;
    }

    if (descriptor.op == .set_prop) {
        if (call.args.items.len == 0) return infoFromSort(.object);
        const target_info = try inferExprInfo(allocator, ir, functions, env, call.args.items[0], origin);
        return .{
            .ty = switch (target_info.ty.tag) {
                .document, .page, .object, .selection => target_info.ty,
                else => Type.object,
            },
            .sort = switch (target_info.sort) {
                .document, .page, .object, .selection => target_info.sort,
                else => .object,
            },
            .object_shape = target_info.object_shape,
            .object_class = target_info.object_class,
        };
    }

    const result_sort = descriptor.result_sort orelse .object;
    if (result_sort != .object) return infoFromSort(result_sort);

    const shape = switch (descriptor.op) {
        .group => .group,
        .set_style => blk: {
            const object_info = try inferExprInfo(allocator, ir, functions, env, call.args.items[0], origin);
            break :blk object_info.object_shape;
        },
        .object => inferObjectConstructorShape(env, call),
        .derive => inferDeriveShape(env, call),
        else => .generic,
    };
    var info = infoFromSort(result_sort);
    info.object_shape = shape;
    info.object_class = inferObjectConstructorClass(ir, env, call) orelse classNameForShape(shape);
    return info;
}

fn validateCallbackShape(
    allocator: std.mem.Allocator,
    ir: ?*core.Ir,
    functions: *const std.StringHashMap(ast.FunctionDecl),
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
    const callback = functions.get(callback_name) orelse {
        try addUserReport(ir, origin, "InvalidCallback: callback must be a named top-level function: {s}", .{callback_name});
        return error.UnknownFunction;
    };
    const extra_count = if (call.args.items.len > callback_index + 1) call.args.items.len - callback_index - 1 else 0;
    const expected_arg_count = fixed_prefix_count + extra_count;
    if (expected_arg_count < requiredParamCount(callback) or expected_arg_count > callback.params.items.len) {
        try addUserReport(ir, origin, "InvalidCallback: callback {s} receives {d} arguments here, but its contract is {d}..{d}", .{
            callback_name,
            expected_arg_count,
            requiredParamCount(callback),
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
        const actual = try inferExprInfo(allocator, ir, functions, env, call.args.items[callback_index + 1 + extra_index], origin);
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
    functions: *const std.StringHashMap(ast.FunctionDecl),
    env: *const TypeEnv,
    call: ast.CallExpr,
    origin: []const u8,
) !TypeInfo {
    if (call.args.items.len < 2) return infoFromType(Type.selection(.any));
    const left = try inferExprInfo(allocator, ir, functions, env, call.args.items[0], origin);
    const right = try inferExprInfo(allocator, ir, functions, env, call.args.items[1], origin);
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
    info.object_shape = mergeObjectShape(left.object_shape, right.object_shape);
    info.object_class = mergeObjectClass(left.object_class, right.object_class);
    if (info.ty.param == .object) info.ty.param_class_name = info.object_class;
    return info;
}

fn inferSelectCallInfo(
    allocator: std.mem.Allocator,
    ir: ?*core.Ir,
    functions: *const std.StringHashMap(ast.FunctionDecl),
    env: *const TypeEnv,
    call: ast.CallExpr,
    origin: []const u8,
) !TypeInfo {
    if (call.args.items.len < 2) return infoFromType(Type.selection(.any));
    const query_name = resolveStringLiteral(env, call.args.items[1]) orelse return infoFromType(Type.selection(.any));
    const query = registry.lookupQueryOp(query_name) orelse {
        try addUserReport(ir, origin, "UnknownQuery: unknown query: {s}", .{query_name});
        return error.UnknownQuery;
    };
    if (call.args.items.len != query.arity) {
        try addUserReport(ir, origin, "InvalidArity: query {s} expects {d} arguments, got {d}", .{ query_name, query.arity, call.args.items.len });
        return error.InvalidArity;
    }
    const base = try inferExprInfo(allocator, ir, functions, env, call.args.items[0], origin);
    try ensureType(ir, allocator, base, registry.queryInputType(query), origin, .UnmatchedInputType);
    for (query.extra_arg_sorts, 0..) |_, extra_index| {
        const arg_index = 2 + extra_index;
        if (arg_index >= call.args.items.len) break;
        const actual = try inferExprInfo(allocator, ir, functions, env, call.args.items[arg_index], origin);
        if (registry.argSortType(query.extra_arg_sorts[extra_index])) |expected| {
            try ensureType(ir, allocator, actual, expected, origin, .UnmatchedArgumentType);
        }
    }
    var info = infoFromType(registry.queryOutputType(query));
    info.object_shape = inferQueryOutputShape(env, query, call, base);
    info.object_class = inferQueryOutputClass(ir, env, query, call, base) orelse classNameForShape(info.object_shape);
    if (info.ty.tag == .selection and info.ty.param == .object) info.ty.param_class_name = info.object_class;
    return info;
}

fn inferQueryOutputShape(
    env: *const TypeEnv,
    query: registry.QueryDescriptor,
    call: ast.CallExpr,
    base: TypeInfo,
) property_schema.ObjectShape {
    return switch (query.op) {
        .self_object => base.object_shape,
        .page_objects_by_role, .document_objects_by_role => blk: {
            if (call.args.items.len < 3) break :blk .generic;
            const role_name = resolveStringLiteral(env, call.args.items[2]) orelse break :blk .generic;
            break :blk property_schema.shapeForRole(role_name);
        },
        .children, .descendants => .generic,
        .document_pages, .previous_page, .parent_page => .unknown,
    };
}

fn inferQueryOutputClass(
    ir: ?*core.Ir,
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
            if (ir) |sink| {
                if (declarations.findRoleClass(sink, role_name)) |class_name| break :blk class_name;
            }
            break :blk classNameForShape(property_schema.shapeForRole(role_name));
        },
        .children, .descendants, .document_pages, .previous_page, .parent_page => null,
    };
}

fn inferDeriveCallInfo(
    allocator: std.mem.Allocator,
    ir: ?*core.Ir,
    functions: *const std.StringHashMap(ast.FunctionDecl),
    env: *const TypeEnv,
    call: ast.CallExpr,
    origin: []const u8,
) !TypeInfo {
    if (call.args.items.len < 2) return infoFromSort(.object);
    const transform_name = resolveStringLiteral(env, call.args.items[1]) orelse {
        var info = infoFromSort(.object);
        info.object_shape = inferDeriveShape(env, call);
        return info;
    };
    const transform = registry.lookupTransformOp(transform_name) orelse {
        try addUserReport(ir, origin, "UnknownTransform: unknown transform: {s}", .{transform_name});
        return error.UnknownTransform;
    };
    if (call.args.items.len < transform.min_arity or call.args.items.len > transform.max_arity) {
        if (transform.min_arity == transform.max_arity) {
            try addUserReport(ir, origin, "InvalidArity: transform {s} expects {d} arguments, got {d}", .{ transform_name, transform.min_arity, call.args.items.len });
        } else {
            try addUserReport(ir, origin, "InvalidArity: transform {s} expects {d}..{d} arguments, got {d}", .{ transform_name, transform.min_arity, transform.max_arity, call.args.items.len });
        }
        return error.InvalidArity;
    }
    const base = try inferExprInfo(allocator, ir, functions, env, call.args.items[0], origin);
    if (registry.transformInputType(transform)) |expected| {
        try ensureType(ir, allocator, base, expected, origin, .UnmatchedInputType);
    } else if (transform.op == .highlight and !(base.ty.tag == .object or (base.ty.tag == .selection and (base.ty.param == .object or base.ty.param == .any)))) {
        try ensureType(ir, allocator, base, Type.object, origin, .UnmatchedInputType);
    }
    for (transform.extra_arg_sorts, 0..) |_, extra_index| {
        const arg_index = 2 + extra_index;
        if (arg_index >= call.args.items.len) break;
        const actual = try inferExprInfo(allocator, ir, functions, env, call.args.items[arg_index], origin);
        if (registry.argSortType(transform.extra_arg_sorts[extra_index])) |expected| {
            try ensureType(ir, allocator, actual, expected, origin, .UnmatchedArgumentType);
        }
    }
    var info = infoFromType(registry.transformOutputType(transform));
    info.object_shape = inferDeriveShape(env, call);
    info.object_class = classNameForShape(info.object_shape);
    return info;
}

fn inferObjectConstructorShape(env: *const TypeEnv, call: ast.CallExpr) property_schema.ObjectShape {
    if (call.args.items.len < 3) return .generic;
    const role_name = resolveStringLiteral(env, call.args.items[1]);
    const payload = if (resolveStringLiteral(env, call.args.items[2])) |text| names.parsePayloadName(text) else null;
    return property_schema.shapeForNode(role_name, if (payload) |p| p.object_kind else null, if (payload) |p| p.payload_kind else null);
}

fn inferObjectConstructorClass(ir: ?*core.Ir, env: *const TypeEnv, call: ast.CallExpr) ?[]const u8 {
    if (call.args.items.len < 3) return null;
    const role_name = resolveStringLiteral(env, call.args.items[1]) orelse return null;
    if (ir) |sink| {
        if (declarations.findRoleClass(sink, role_name)) |class_name| return class_name;
    }
    return classNameForShape(property_schema.shapeForRole(role_name));
}

fn inferDeriveShape(env: *const TypeEnv, call: ast.CallExpr) property_schema.ObjectShape {
    if (call.args.items.len < 2) return .generic;
    const name = resolveStringLiteral(env, call.args.items[1]) orelse return .generic;
    if (std.mem.eql(u8, name, "page_number")) return .page_number;
    if (std.mem.eql(u8, name, "toc")) return .toc;
    if (std.mem.eql(u8, name, "rewrite_text")) return .text;
    if (std.mem.eql(u8, name, "highlight")) return .generic;
    return .generic;
}

fn classNameForShape(shape: property_schema.ObjectShape) ?[]const u8 {
    return switch (shape) {
        .document => "DocumentObject",
        .page => "PageObject",
        .generic, .unknown => null,
        .text => "TextObject",
        .code => "CodeObject",
        .math => "MathObject",
        .figure => "FigureObject",
        .asset_image => "ImageObject",
        .asset_pdf => "PdfObject",
        .panel => "PanelObject",
        .rule => "RuleObject",
        .page_number => "PageNumberObject",
        .toc => "TocObject",
        .group => "GroupObject",
    };
}

fn validateSetPropCall(
    ir: *core.Ir,
    call: ast.CallExpr,
    env: *const TypeEnv,
    functions: *const std.StringHashMap(ast.FunctionDecl),
    origin: []const u8,
) !void {
    if (call.args.items.len < 3) return;
    const key = switch (call.args.items[1]) {
        .string => |text| text,
        else => return,
    };
    const target_info = try inferExprInfo(ir.allocator, ir, functions, env, call.args.items[0], origin);
    if (!isPropertyTarget(target_info)) {
        try addUserReport(
            ir,
            origin,
            "InvalidProperty: set_prop target must be document, page, object, or selection<object>; got {s}",
            .{@tagName(target_info.sort)},
        );
        return error.InvalidSemanticSort;
    }

    const value_info = try inferExprInfo(ir.allocator, ir, functions, env, call.args.items[2], origin);
    if (lookupFieldForTarget(ir, target_info, key)) |field| {
        try validateFieldValue(ir, field, key, value_info, origin);
        return;
    }

    if (property_schema.lookupInIr(ir, key)) |schema| {
        if (propertyShapeForInfo(target_info)) |target_shape| {
            if (!property_schema.isSchemaShapeAllowed(schema, target_shape)) {
                try addUserReport(
                    ir,
                    origin,
                    "InvalidProperty: property '{s}' is not valid for {s}",
                    .{ key, property_schema.shapeLabel(target_shape) },
                );
                return error.InvalidSemanticSort;
            }
        }
        if (!property_schema.schemaValueMatches(schema, value_info.string_literal, value_info.sort)) {
            try addUserReport(
                ir,
                origin,
                "InvalidPropertyValue: property '{s}' expects {s}, got {s}",
                .{ key, property_schema.schemaValueTypeLabel(schema), @tagName(value_info.sort) },
            );
            return error.InvalidSemanticSort;
        }
        return;
    }

    try addUserReport(ir, origin, "UnknownField: unknown field: {s}", .{key});
    return error.InvalidSemanticSort;
}

fn isPropertyTarget(info: TypeInfo) bool {
    return switch (info.ty.tag) {
        .document, .page, .object => true,
        .selection => info.ty.param == .object or info.ty.param == .any,
        else => false,
    };
}

fn lookupFieldForTarget(ir: *core.Ir, target_info: TypeInfo, key: []const u8) ?declarations.FieldDescriptor {
    if (targetClassForInfo(target_info)) |class_name| {
        return declarations.findField(ir, class_name, key);
    }
    if (target_info.ty.tag == .object or (target_info.ty.tag == .selection and (target_info.ty.param == .object or target_info.ty.param == .any))) {
        return declarations.findFieldByName(ir, key);
    }
    return null;
}

fn targetClassForInfo(info: TypeInfo) ?[]const u8 {
    return switch (info.ty.tag) {
        .document => "DocumentObject",
        .page => "PageObject",
        .object => info.object_class orelse classNameForShape(info.object_shape),
        .selection => if (info.ty.param == .object or info.ty.param == .any) info.object_class orelse classNameForShape(info.object_shape) else null,
        else => null,
    };
}

fn validateFieldValue(
    ir: *core.Ir,
    field: declarations.FieldDescriptor,
    key: []const u8,
    value_info: TypeInfo,
    origin: []const u8,
) !void {
    if (!property_schema.valueTypeNameMatches(ir, field.module_id, field.value_type, value_info.string_literal, value_info.sort)) {
        try addUserReport(
            ir,
            origin,
            "InvalidFieldValue: field '{s}' expects {s}, got {s}",
            .{ key, property_schema.valueTypeNameLabel(ir, field.module_id, field.value_type), @tagName(value_info.sort) },
        );
        return error.InvalidSemanticSort;
    }
}

fn propertyShapeForInfo(info: TypeInfo) ?property_schema.ObjectShape {
    return switch (info.ty.tag) {
        .document => .document,
        .page => .page,
        .object => info.object_shape,
        .selection => if (info.ty.param == .object or info.ty.param == .any) info.object_shape else null,
        else => null,
    };
}

fn validatePropertySetStatement(
    allocator: std.mem.Allocator,
    ir: ?*core.Ir,
    functions: *const std.StringHashMap(ast.FunctionDecl),
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
    const value_info = try inferExprInfo(allocator, ir, functions, env, value, origin);
    if (ir) |sink| {
        if (lookupFieldForTarget(sink, object_info, property_name)) |field| {
            try validateFieldValue(sink, field, property_name, value_info, origin);
            return;
        }
        if (lookupPropertySchema(ir, property_name)) |schema| {
            if (!property_schema.isSchemaShapeAllowed(schema, object_info.object_shape)) {
                try addUserReport(
                    ir,
                    origin,
                    "InvalidProperty: property '{s}' is not valid for {s}",
                    .{ property_name, property_schema.shapeLabel(object_info.object_shape) },
                );
                return error.InvalidSemanticSort;
            }
            if (!property_schema.schemaValueMatches(schema, value_info.string_literal, value_info.sort)) {
                try addUserReport(
                    ir,
                    origin,
                    "InvalidPropertyValue: property '{s}' expects {s}, got {s}",
                    .{ property_name, property_schema.schemaValueTypeLabel(schema), @tagName(value_info.sort) },
                );
                return error.InvalidSemanticSort;
            }
            return;
        }
        try addUserReport(ir, origin, "UnknownField: unknown field: {s}", .{property_name});
        return error.InvalidSemanticSort;
    }
}

fn lookupPropertySchema(ir: ?*core.Ir, property_name: []const u8) ?property_schema.SchemaRef {
    if (ir) |sink| return property_schema.lookupInIr(sink, property_name);
    return null;
}

fn resolveStringLiteral(env: *const TypeEnv, expr: ast.Expr) ?[]const u8 {
    return switch (expr) {
        .string => |text| text,
        .ident => |name| if (env.get(name)) |info| info.string_literal else null,
        else => null,
    };
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

fn ensureSort(
    ir: ?*core.Ir,
    actual: core.SemanticSort,
    expected: core.SemanticSort,
    origin: []const u8,
    code: core.TypeMismatchCode,
) !void {
    if (actual != expected) {
        if (ir) |sink| {
            try sink.addValidationDiagnostic(.@"error", null, null, origin, .{
                .type_mismatch = .{ .code = code, .expected = expected, .actual = actual },
            });
        }
        return error.InvalidSemanticSort;
    }
}

fn ensureType(
    ir: ?*core.Ir,
    allocator: std.mem.Allocator,
    actual: TypeInfo,
    expected: Type,
    origin: []const u8,
    code: core.TypeMismatchCode,
) !void {
    if (Type.accepts(expected, actual.ty)) return;
    const expected_sort = expected.toRuntimeSort() orelse actual.sort;
    if (expected_sort != actual.sort) return ensureSort(ir, actual.sort, expected_sort, origin, code);
    if (ir) |_| {
        const actual_label = try typeLabelAlloc(allocator, actual.ty);
        defer allocator.free(actual_label);
        const expected_label = try typeLabelAlloc(allocator, expected);
        defer allocator.free(expected_label);
        try addUserReport(ir, origin, "TypeMismatch: expected {s}, got {s}", .{ expected_label, actual_label });
    }
    return error.InvalidSemanticSort;
}

fn statementOrigin(allocator: std.mem.Allocator, span: ast.Span) ![]const u8 {
    if (diagnostic_origin_path.len != 0) {
        return std.fmt.allocPrint(allocator, "path:{s}:bytes:{d}-{d}", .{ diagnostic_origin_path, span.start, span.end });
    }
    return std.fmt.allocPrint(allocator, "bytes:{d}-{d}", .{ span.start, span.end });
}
