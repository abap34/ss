const std = @import("std");
const core = @import("core");
const ast = @import("ast");
const registry = @import("registry.zig");
const theme_loader = @import("../theme_loader.zig");
const syntax = @import("syntax.zig");
const utils = @import("utils");
const source_utils = utils.source;

pub const FunctionContract = struct {
    min_param_count: usize,
    max_param_count: usize,
    returns_value: bool,
    result_sort: core.SemanticSort,
};

const SortEnv = std.StringHashMap(core.SemanticSort);

pub const FunctionSource = core.FunctionSource;
pub const FunctionMetadata = core.FunctionMetadata;

pub const ProgramIndex = struct {
    allocator: std.mem.Allocator,
    base_source: ?[]u8 = null,
    base_path: ?[]u8 = null,
    base_program: ?ast.Program = null,
    theme_source: ?[]u8 = null,
    theme_path: ?[]u8 = null,
    theme_program: ?ast.Program = null,
    functions: std.StringHashMap(ast.FunctionDecl),
    function_metadata: std.StringHashMap(FunctionMetadata),

    pub fn deinit(self: *ProgramIndex) void {
        self.function_metadata.deinit();
        self.functions.deinit();
        if (self.theme_program) |*program| program.deinit(self.allocator);
        if (self.base_program) |*program| program.deinit(self.allocator);
        if (self.theme_source) |source| self.allocator.free(source);
        if (self.theme_path) |path| self.allocator.free(path);
        if (self.base_source) |source| self.allocator.free(source);
        if (self.base_path) |path| self.allocator.free(path);
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
    ir: *core.Ir,
    page_id: ?core.NodeId,
    value: core.Value,
    expected: core.SemanticSort,
    origin: []const u8,
) !void {
    return ensureValueSortWithCode(ir, page_id, value, expected, origin, .UnmatchedArgumentType);
}

pub fn ensureValueSortWithCode(
    ir: *core.Ir,
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

fn addUserReport(ir: ?*core.Ir, origin: []const u8, comptime fmt: []const u8, args: anytype) !void {
    const sink = ir orelse return;
    const message = try std.fmt.allocPrint(sink.allocator, fmt, args);
    try sink.addValidationDiagnostic(.@"error", null, null, origin, .{
        .user_report = .{ .message = message },
    });
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
    try checkFunctionCallGraph(allocator, ir, functions);

    var it = functions.iterator();
    while (it.next()) |entry| {
        try checkFunction(allocator, ir, functions, entry.value_ptr.*);
    }
}

pub fn typecheckProgram(
    allocator: std.mem.Allocator,
    ir: *core.Ir,
) !void {
    try checkFunctionDefinitions(allocator, ir, &ir.functions);
    try checkPageStatements(allocator, ir, &ir.functions, ir.project_module.program);
}

pub fn collectVariableTypesFromProgram(
    allocator: std.mem.Allocator,
    functions: *const std.StringHashMap(ast.FunctionDecl),
    program: ast.Program,
) !std.StringHashMap(core.SemanticSort) {
    var variables = std.StringHashMap(core.SemanticSort).init(allocator);
    errdefer variables.deinit();

    for (program.functions.items) |func| {
        var env = SortEnv.init(allocator);
        defer env.deinit();

        for (func.params.items) |param| {
            if (param.default_value) |default_value| {
                const sort = try inferExprSort(allocator, null, functions, &env, default_value.*, "");
                try ensureSort(null, sort, param.sort, "", .UnmatchedArgumentType);
            }
            try env.put(param.name, param.sort);
            try variables.put(param.name, param.sort);
        }

        for (func.statements.items) |stmt| {
            try collectVariableTypesFromStatement(allocator, &env, functions, stmt, &variables);
        }
    }

    for (program.pages.items) |page| {
        var env = SortEnv.init(allocator);
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
    source: FunctionSource,
    path: ?[]const u8,
) !void {
    _ = path;
    for (program.functions.items) |func| {
        try functions.put(func.name, func);
        try metadata.put(func.name, .{ .source = source });
    }
}

pub fn buildIr(
    allocator: std.mem.Allocator,
    input_path: []const u8,
    project_source: []u8,
    project_program: ast.Program,
    index: *ProgramIndex,
) !core.Ir {
    const asset_base_dir = try allocator.dupe(u8, std.fs.path.dirname(input_path) orelse ".");
    const project_path = try allocator.dupe(u8, input_path);
    var ir = try core.Ir.init(allocator, asset_base_dir, project_path, project_source, project_program);
    errdefer ir.deinit();

    if (index.base_source) |base_source| {
        ir.base_module = .{
            .kind = .base,
            .path = index.base_path.?,
            .source = base_source,
            .program = index.base_program.?,
        };
        index.base_source = null;
        index.base_path = null;
        index.base_program = null;
    }

    if (index.theme_source) |theme_source| {
        ir.theme_module = .{
            .kind = .theme,
            .path = index.theme_path.?,
            .source = theme_source,
            .program = index.theme_program.?,
        };
        index.theme_source = null;
        index.theme_path = null;
        index.theme_program = null;
    }

    ir.functions = index.functions;
    index.functions = std.StringHashMap(ast.FunctionDecl).init(allocator);
    ir.function_metadata = index.function_metadata;
    index.function_metadata = std.StringHashMap(FunctionMetadata).init(allocator);
    ir.variable_types = try collectVariableTypesFromProgram(allocator, &ir.functions, ir.project_module.program);
    try populateIrAnalysis(allocator, &ir);
    return ir;
}

pub fn populateIrAnalysis(allocator: std.mem.Allocator, ir: *core.Ir) !void {
    if (ir.base_module) |base_module| {
        try collectDefinitionsFromProgram(allocator, base_module.source, base_module.program, base_module.path, false, &ir.definitions);
    }
    if (ir.theme_module) |theme_module| {
        try collectDefinitionsFromProgram(allocator, theme_module.source, theme_module.program, theme_module.path, false, &ir.definitions);
    }
    try collectDefinitionsFromProgram(allocator, ir.projectSource(), ir.project_module.program, null, true, &ir.definitions);
    try collectProgramHints(allocator, &ir.hints, ir.projectSource(), ir.project_module.program, &ir.functions);
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
    var index = ProgramIndex{
        .allocator = allocator,
        .functions = std.StringHashMap(ast.FunctionDecl).init(allocator),
        .function_metadata = std.StringHashMap(FunctionMetadata).init(allocator),
    };
    errdefer index.deinit();

    const base_module = try theme_loader.loadThemeModule(allocator, io, base_dir, "base");
    index.base_path = base_module.path;
    index.base_source = base_module.source;
    index.base_program = try syntax.parse(allocator, index.base_source.?);
    try validateThemeProgram(index.base_program.?);
    try appendFunctionDeclarations(&index.functions, &index.function_metadata, index.base_program.?, .base, index.base_path.?);

    const theme_name = project_program.theme_name orelse "default";
    if (!std.mem.eql(u8, theme_name, "base")) {
        const theme_module = try theme_loader.loadThemeModule(allocator, io, base_dir, theme_name);
        index.theme_path = theme_module.path;
        index.theme_source = theme_module.source;
        index.theme_program = try syntax.parse(allocator, index.theme_source.?);
        try validateThemeProgram(index.theme_program.?);
        try appendFunctionDeclarations(&index.functions, &index.function_metadata, index.theme_program.?, .theme, index.theme_path.?);
    }

    try appendFunctionDeclarations(&index.functions, &index.function_metadata, project_program, .project, null);
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

pub fn validateThemeProgram(program: ast.Program) !void {
    if (program.theme_name != null) return error.InvalidThemeModule;
    if (program.pages.items.len != 0) return error.InvalidThemeModule;
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
    if (expectedPrimitiveArgSort(descriptor, index)) |sort| {
        return std.fmt.allocPrint(allocator, "{s}: {s}", .{ name, @tagName(sort) });
    }
    return allocator.dupe(u8, name);
}

pub fn formatUserSignature(
    allocator: std.mem.Allocator,
    name: []const u8,
    func: ast.FunctionDecl,
) ![]const u8 {
    var params = std.ArrayList(u8).empty;
    defer params.deinit(allocator);
    for (func.params.items, 0..) |param, index| {
        if (index != 0) try params.appendSlice(allocator, ", ");
        const label = try formatUserParam(allocator, param);
        defer allocator.free(label);
        try params.appendSlice(allocator, label);
    }
    return std.fmt.allocPrint(allocator, "{s}({s}) -> {s}", .{ name, params.items, @tagName(func.result_sort) });
}

pub fn formatUserParam(allocator: std.mem.Allocator, param: ast.ParamDecl) ![]const u8 {
    if (param.default_value) |default_value| {
        const text = try formatExpr(allocator, default_value.*);
        defer allocator.free(text);
        return std.fmt.allocPrint(allocator, "{s}: {s} = {s}", .{ param.name, @tagName(param.sort), text });
    }
    return std.fmt.allocPrint(allocator, "{s}: {s}", .{ param.name, @tagName(param.sort) });
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
    file: ?[]const u8,
    include_variables: bool,
    definitions: *std.StringHashMap(core.Definition),
) !void {
    for (program.functions.items) |func| {
        if (findIdentifierOffsetAfterKeyword(source, func.span.start, "fn", func.name)) |location| {
            const loc = utils.err.computeLineColumn(source, location.offset);
            try putDefinition(allocator, definitions, func.name, loc.line, loc.column, location.length, .function, file);
        }
        if (include_variables) {
            for (func.statements.items) |stmt| {
                try collectDefinitionsFromStatement(allocator, source, stmt, definitions);
            }
        }
    }
    if (include_variables) {
        for (program.pages.items) |page| {
            for (page.statements.items) |stmt| {
                try collectDefinitionsFromStatement(allocator, source, stmt, definitions);
            }
        }
    }
}

fn collectDefinitionsFromStatement(
    allocator: std.mem.Allocator,
    source: []const u8,
    stmt: ast.Statement,
    definitions: *std.StringHashMap(core.Definition),
) !void {
    switch (stmt.kind) {
        .let_binding => |binding| try putStatementDefinition(allocator, source, stmt, "let", binding.name, definitions),
        .bind_binding => |binding| try putStatementDefinition(allocator, source, stmt, "bind", binding.name, definitions),
        else => {},
    }
}

fn putStatementDefinition(
    allocator: std.mem.Allocator,
    source: []const u8,
    stmt: ast.Statement,
    keyword: []const u8,
    name: []const u8,
    definitions: *std.StringHashMap(core.Definition),
) !void {
    if (findIdentifierOffsetAfterKeyword(source, stmt.span.start, keyword, name)) |location| {
        const loc = utils.err.computeLineColumn(source, location.offset);
        try putDefinition(allocator, definitions, name, loc.line, loc.column, location.length, .variable, null);
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
    env: *SortEnv,
    functions: *const std.StringHashMap(ast.FunctionDecl),
    stmt: ast.Statement,
    variables: *std.StringHashMap(core.SemanticSort),
) !void {
    switch (stmt.kind) {
        .let_binding => |binding| {
            const sort = try inferExprSort(allocator, null, functions, env, binding.expr, "");
            try env.put(binding.name, sort);
            try variables.put(binding.name, sort);
        },
        .bind_binding => |binding| {
            _ = try inferExprSort(allocator, null, functions, env, binding.expr, "");
            try env.put(binding.name, .fragment);
            try variables.put(binding.name, .fragment);
        },
        .return_expr => |expr| {
            _ = try inferExprSort(allocator, null, functions, env, expr, "");
        },
        .expr_stmt => |expr| {
            _ = try inferExprSort(allocator, null, functions, env, expr, "");
        },
        .constrain => |decl| {
            if (decl.offset) |expr| {
                _ = try inferExprSort(allocator, null, functions, env, expr, "");
            }
        },
        else => {},
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
        .constrain => |decl| if (decl.offset) |expr| try collectExprCallees(allocator, functions, expr, callees),
        .expr_stmt => |expr| try collectExprCallees(allocator, functions, expr, callees),
        else => {},
    }
}

fn collectExprCallees(
    allocator: std.mem.Allocator,
    functions: *const std.StringHashMap(ast.FunctionDecl),
    expr: ast.Expr,
    callees: *std.ArrayList([]const u8),
) !void {
    switch (expr) {
        .call => |call| {
            if (functions.contains(call.name)) try appendUniqueCallee(allocator, callees, call.name);
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
    var env = SortEnv.init(allocator);
    defer env.deinit();

    const func_origin = try statementOrigin(allocator, func.span);
    defer allocator.free(func_origin);
    for (func.params.items) |param| {
        if (param.default_value) |default_value| {
            const sort = try inferExprSort(allocator, ir, functions, &env, default_value.*, func_origin);
            try ensureSort(ir, sort, param.sort, func_origin, .UnmatchedArgumentType);
        }
        try env.put(param.name, param.sort);
    }

    for (func.statements.items) |stmt| {
        try checkStatement(allocator, ir, functions, &env, func.result_sort, stmt);
    }
}

fn checkPageStatements(
    allocator: std.mem.Allocator,
    ir: *core.Ir,
    functions: *const std.StringHashMap(ast.FunctionDecl),
    program: ast.Program,
) !void {
    for (program.pages.items) |page| {
        var env = SortEnv.init(allocator);
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
    env: *SortEnv,
    stmt: ast.Statement,
) !void {
    const origin = try statementOrigin(allocator, stmt.span);
    switch (stmt.kind) {
        .let_binding => |binding| {
            const sort = try inferExprSort(allocator, ir, functions, env, binding.expr, origin);
            try env.put(binding.name, sort);
        },
        .bind_binding => |binding| {
            _ = try inferExprSort(allocator, ir, functions, env, binding.expr, origin);
            try env.put(binding.name, .fragment);
        },
        .return_expr => {
            try addUserReport(ir, origin, "ReturnOutsideFunction: return is only valid inside a function", .{});
            return error.ReturnOutsideFunction;
        },
        .expr_stmt => |expr| {
            _ = try inferExprSort(allocator, ir, functions, env, expr, origin);
        },
        .constrain => |decl| {
            if (decl.offset) |expr| {
                const actual = try inferExprSort(allocator, ir, functions, env, expr, origin);
                try ensureSort(ir, actual, .number, origin, .UnmatchedArgumentType);
            }
        },
        .title, .subtitle, .math, .mathtex, .figure, .image, .pdf_ref, .code, .page_number, .toc, .highlight => {},
    }
}

fn checkStatement(
    allocator: std.mem.Allocator,
    ir: *core.Ir,
    functions: *const std.StringHashMap(ast.FunctionDecl),
    env: *SortEnv,
    result_sort: core.SemanticSort,
    stmt: ast.Statement,
) !void {
    const origin = try statementOrigin(allocator, stmt.span);
    switch (stmt.kind) {
        .let_binding => |binding| {
            const sort = try inferExprSort(allocator, ir, functions, env, binding.expr, origin);
            try env.put(binding.name, sort);
        },
        .bind_binding => |binding| {
            _ = try inferExprSort(allocator, ir, functions, env, binding.expr, origin);
            try env.put(binding.name, .fragment);
        },
        .return_expr => |expr| {
            const actual = try inferExprSort(allocator, ir, functions, env, expr, origin);
            try ensureSort(ir, actual, result_sort, origin, .UnmatchedReturnType);
        },
        .expr_stmt => |expr| {
            _ = try inferExprSort(allocator, ir, functions, env, expr, origin);
        },
        .constrain => |decl| {
            if (decl.offset) |expr| {
                const actual = try inferExprSort(allocator, ir, functions, env, expr, origin);
                try ensureSort(ir, actual, .number, origin, .UnmatchedArgumentType);
            }
        },
        .title, .subtitle, .math, .mathtex, .figure, .image, .pdf_ref, .code, .page_number, .toc, .highlight => {},
    }
}

fn inferExprSort(
    allocator: std.mem.Allocator,
    ir: ?*core.Ir,
    functions: *const std.StringHashMap(ast.FunctionDecl),
    env: *const SortEnv,
    expr: ast.Expr,
    origin: []const u8,
) anyerror!core.SemanticSort {
    return switch (expr) {
        .string => .string,
        .number => .number,
        .ident => |name| blk: {
            if (env.get(name)) |sort| break :blk sort;
            if (functions.contains(name)) break :blk .function;
            try addUserReport(ir, origin, "UnknownIdentifier: unknown identifier: {s}", .{name});
            return error.UnknownIdentifier;
        },
        .call => |call| try inferCallSort(allocator, ir, functions, env, call, origin),
    };
}

fn inferCallSort(
    allocator: std.mem.Allocator,
    ir: ?*core.Ir,
    functions: *const std.StringHashMap(ast.FunctionDecl),
    env: *const SortEnv,
    call: ast.CallExpr,
    origin: []const u8,
) anyerror!core.SemanticSort {
    if (functions.get(call.name)) |func| {
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
            const actual = try inferExprSort(allocator, ir, functions, env, arg, origin);
            try ensureSort(ir, actual, param.sort, origin, .UnmatchedArgumentType);
        }
        return func.result_sort;
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
            const actual = try inferExprSort(allocator, ir, functions, env, arg, origin);
            if (expectedPrimitiveArgSort(descriptor, index)) |expected| {
                try ensureSort(ir, actual, expected, origin, .UnmatchedArgumentType);
            }
        }
        return descriptor.result_sort orelse .object;
    }

    try addUserReport(ir, origin, "UnknownFunction: unknown function: {s}", .{call.name});
    return error.UnknownFunction;
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

fn statementOrigin(allocator: std.mem.Allocator, span: ast.Span) ![]const u8 {
    return std.fmt.allocPrint(allocator, "bytes:{d}-{d}", .{ span.start, span.end });
}
