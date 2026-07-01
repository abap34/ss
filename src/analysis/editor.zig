const std = @import("std");
const ast = @import("ast");
const core = @import("core");

const language_names = @import("../language/names.zig");
const registry = @import("../language/registry.zig");
const semantic_env = @import("../language/env.zig");
const analysis_scope = @import("scope.zig");
const utils = @import("utils");

const SemanticEnv = semantic_env.SemanticEnv;

pub const SourceIdentifierLocation = struct {
    offset: usize,
    length: usize,
};

pub fn sourceCallableNameAt(source_text: []const u8, offset: usize) ?SourceIdentifierLocation {
    const span = utils.source.wordSpanAt(source_text, offset, language_names.isCallableNameChar) orelse return null;
    return .{
        .offset = span.start,
        .length = span.end - span.start,
    };
}

pub const QualifiedCallableRole = enum {
    qualifier,
    name,
};

pub const QualifiedCallableTarget = struct {
    qualifier: []const u8,
    name: []const u8,
    role: QualifiedCallableRole,
};

pub const CallableTarget = struct {
    callee: ast.CallableName,
    role: QualifiedCallableRole,
};

pub fn callableAt(program: *const ast.Program, offset: usize) ?CallableTarget {
    for (program.records.items) |record| {
        if (callableInFields(record.fields.items, offset)) |target| return target;
    }
    for (program.objects.items) |object| {
        if (callableInFields(object.fields.items, offset)) |target| return target;
    }
    for (program.object_extensions.items) |extension| {
        if (callableInFields(extension.fields.items, offset)) |target| return target;
    }
    for (program.constants.items) |constant_decl| {
        if (callableInExpr(constant_decl.value, offset)) |target| return target;
    }
    for (program.functions.items) |func| {
        if (callableInStatements(func.statements.items, offset)) |target| return target;
    }
    if (callableInStatements(program.document_statements.items, offset)) |target| return target;
    for (program.pages.items) |page| {
        if (callableInStatements(page.statements.items, offset)) |target| return target;
    }
    return null;
}

pub fn qualifiedCallableAt(program: *const ast.Program, offset: usize) ?QualifiedCallableTarget {
    const target = callableAt(program, offset) orelse return null;
    const qualifier = target.callee.qualifier orelse return null;
    return .{
        .qualifier = qualifier,
        .name = target.callee.name,
        .role = target.role,
    };
}

pub fn qualifiedCallableQualifierForName(program: *const ast.Program, offset: usize) ?[]const u8 {
    const target = qualifiedCallableAt(program, offset) orelse return null;
    if (target.role != .name) return null;
    return target.qualifier;
}

pub fn isQualifiedCallableQualifierAt(program: *const ast.Program, offset: usize) bool {
    const target = qualifiedCallableAt(program, offset) orelse return false;
    return target.role == .qualifier;
}

pub fn isImportAliasAt(program: *const ast.Program, offset: usize) bool {
    for (program.imports.items) |import_decl| {
        const alias_span = import_decl.alias_span orelse continue;
        if (spanContainsOffset(alias_span, offset)) return true;
    }
    return false;
}

pub fn importSpecAt(program: *const ast.Program, offset: usize) ?[]const u8 {
    for (program.imports.items) |import_decl| {
        if (spanContainsOffset(import_decl.spec_span, offset)) return import_decl.spec;
    }
    return null;
}

fn callableInFields(fields: []const ast.ObjectFieldDecl, offset: usize) ?CallableTarget {
    for (fields) |field| {
        const default_value = field.default_value orelse continue;
        if (callableInExpr(default_value.*, offset)) |target| return target;
    }
    return null;
}

fn callableInStatements(statements: []const ast.Statement, offset: usize) ?CallableTarget {
    for (statements) |stmt| {
        if (callableInStatement(stmt, offset)) |target| return target;
    }
    return null;
}

fn callableInStatement(stmt: ast.Statement, offset: usize) ?CallableTarget {
    return switch (stmt.kind) {
        .let_binding => |binding| callableInExpr(binding.expr, offset),
        .return_expr => |expr| callableInExpr(expr, offset),
        .return_void => null,
        .constrain => |constraint| if (constraint.offset) |expr| callableInExpr(expr, offset) else null,
        .property_set => |property_set| callableInExpr(property_set.value, offset),
        .if_stmt => |if_stmt| blk: {
            if (callableInExpr(if_stmt.condition, offset)) |target| break :blk target;
            if (callableInStatements(if_stmt.then_statements.items, offset)) |target| break :blk target;
            break :blk callableInStatements(if_stmt.else_statements.items, offset);
        },
        .expr_stmt => |expr| callableInExpr(expr, offset),
    };
}

fn callableInExpr(expr: ast.Expr, offset: usize) ?CallableTarget {
    return switch (expr) {
        .call => |call| blk: {
            if (callableNameAt(call.callee, offset)) |target| break :blk target;
            for (call.args.items) |arg| {
                if (callableInExpr(arg, offset)) |target| break :blk target;
            }
            break :blk null;
        },
        .apply => |apply| blk: {
            if (callableInExpr(apply.callee.*, offset)) |target| break :blk target;
            for (apply.args.items) |arg| {
                if (callableInExpr(arg, offset)) |target| break :blk target;
            }
            break :blk null;
        },
        .lambda => |lambda| callableInExpr(lambda.body.*, offset),
        .record => |record| blk: {
            for (record.fields.items) |field| {
                if (callableInExpr(field.value, offset)) |target| break :blk target;
            }
            break :blk null;
        },
        .record_update => |update| blk: {
            if (callableInExpr(update.target.*, offset)) |target| break :blk target;
            for (update.fields.items) |field| {
                if (callableInExpr(field.value, offset)) |target| break :blk target;
            }
            break :blk null;
        },
        .member => |member| callableInExpr(member.target.*, offset),
        .optional_check => |check| callableInExpr(check.target.*, offset),
        .coalesce => |coalesce| blk: {
            if (callableInExpr(coalesce.target.*, offset)) |target| break :blk target;
            break :blk callableInExpr(coalesce.fallback.*, offset);
        },
        else => null,
    };
}

fn callableNameAt(name: ast.CallableName, offset: usize) ?CallableTarget {
    if (name.qualifier_span) |qualifier_span| {
        if (spanContainsOffset(qualifier_span, offset)) {
            return .{
                .callee = name,
                .role = .qualifier,
            };
        }
    }
    const name_span = name.name_span orelse return null;
    if (spanContainsOffset(name_span, offset)) {
        return .{
            .callee = name,
            .role = .name,
        };
    }
    return null;
}

fn spanContainsOffset(span: ast.Span, offset: usize) bool {
    return offset >= span.start and offset <= span.end;
}

pub fn populateIrAnalysis(allocator: std.mem.Allocator, ir: *core.Ir) !void {
    for (ir.modules.items) |module| {
        if (module.kind == .project) continue;
        try collectDefinitionsFromProgram(allocator, module.source, module.program, module.id, module.path, false, &ir.definitions);
        try collectProgramHints(allocator, ir, &ir.hints, module.source, module.path, module.program, module.id, &ir.functions);
    }
    try collectDefinitionsFromProgram(allocator, ir.projectSource(), ir.projectProgram(), ir.project_module_id, null, true, &ir.definitions);
    try collectProgramHints(allocator, ir, &ir.hints, ir.projectSource(), ir.projectPath(), ir.projectProgram(), ir.project_module_id, &ir.functions);
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
    try collectSolvedSizeHints(allocator, ir, &ir.hints);
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
    const result_label = if (registry.primitiveResultType(descriptor)) |result_type|
        try result_type.formatAlloc(allocator)
    else
        try allocator.dupe(u8, "dependent");
    defer allocator.free(result_label);
    return std.fmt.allocPrint(allocator, "{s}({s}) -> {s}", .{ descriptor.name, params.items, result_label });
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

pub fn formatConstSignature(
    allocator: std.mem.Allocator,
    name: []const u8,
    constant_decl: ast.ConstDecl,
) ![]const u8 {
    const result_label = try constant_decl.value_type.formatAlloc(allocator);
    defer allocator.free(result_label);
    return std.fmt.allocPrint(allocator, "const {s}: {s}", .{ name, result_label });
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
        .string => |literal| std.fmt.allocPrint(allocator, "\"{s}\"", .{literal.text}),
        .color => |text| std.fmt.allocPrint(allocator, "c\"{s}\"", .{text}),
        .number => |value| std.fmt.allocPrint(allocator, "{d}", .{value}),
        .boolean => |value| allocator.dupe(u8, if (value) "true" else "false"),
        .none => allocator.dupe(u8, "none"),
        .enum_case => |case| std.fmt.allocPrint(allocator, "{s}.{s}", .{ case.enum_name, case.case_name }),
        .record => |record| blk: {
            var fields = std.ArrayList(u8).empty;
            defer fields.deinit(allocator);
            for (record.fields.items, 0..) |field, index| {
                if (index != 0) try fields.appendSlice(allocator, ", ");
                const text = try formatExpr(allocator, field.value);
                defer allocator.free(text);
                try fields.appendSlice(allocator, field.name);
                try fields.appendSlice(allocator, " = ");
                try fields.appendSlice(allocator, text);
            }
            break :blk std.fmt.allocPrint(allocator, "{s} {{ {s} }}", .{ record.type_name, fields.items });
        },
        .record_update => |update| blk: {
            const target = try formatExpr(allocator, update.target.*);
            defer allocator.free(target);
            var fields = std.ArrayList(u8).empty;
            defer fields.deinit(allocator);
            for (update.fields.items, 0..) |field, index| {
                if (index != 0) try fields.appendSlice(allocator, ", ");
                for (field.path.items, 0..) |segment, segment_index| {
                    if (segment_index != 0) try fields.append(allocator, '.');
                    try fields.appendSlice(allocator, segment);
                }
                const text = try formatExpr(allocator, field.value);
                defer allocator.free(text);
                try fields.appendSlice(allocator, " = ");
                try fields.appendSlice(allocator, text);
            }
            break :blk std.fmt.allocPrint(allocator, "{s} with {{ {s} }}", .{ target, fields.items });
        },
        .call => |call| blk: {
            const callee = try call.callee.displayAlloc(allocator);
            defer allocator.free(callee);
            var args = std.ArrayList(u8).empty;
            defer args.deinit(allocator);
            for (call.args.items, 0..) |arg, index| {
                if (index != 0) try args.appendSlice(allocator, ", ");
                const text = try formatExpr(allocator, arg);
                defer allocator.free(text);
                try args.appendSlice(allocator, text);
            }
            break :blk std.fmt.allocPrint(allocator, "{s}({s})", .{ callee, args.items });
        },
        .apply => |apply| blk: {
            const callee = try formatExpr(allocator, apply.callee.*);
            defer allocator.free(callee);
            var args = std.ArrayList(u8).empty;
            defer args.deinit(allocator);
            for (apply.args.items, 0..) |arg, index| {
                if (index != 0) try args.appendSlice(allocator, ", ");
                const text = try formatExpr(allocator, arg);
                defer allocator.free(text);
                try args.appendSlice(allocator, text);
            }
            break :blk std.fmt.allocPrint(allocator, "{s}({s})", .{ callee, args.items });
        },
        .lambda => allocator.dupe(u8, "<lambda>"),
        .member => |member| blk: {
            const target = try formatExpr(allocator, member.target.*);
            defer allocator.free(target);
            break :blk std.fmt.allocPrint(allocator, "{s}.{s}", .{ target, member.name });
        },
        .optional_check => |check| blk: {
            const target = try formatExpr(allocator, check.target.*);
            defer allocator.free(target);
            break :blk std.fmt.allocPrint(allocator, "{s}?", .{target});
        },
        .coalesce => |coalesce| blk: {
            const target = try formatExpr(allocator, coalesce.target.*);
            defer allocator.free(target);
            const fallback = try formatExpr(allocator, coalesce.fallback.*);
            defer allocator.free(fallback);
            break :blk std.fmt.allocPrint(allocator, "{s} ?? {s}", .{ target, fallback });
        },
    };
}

fn collectDefinitionsFromProgram(
    allocator: std.mem.Allocator,
    source: []const u8,
    program: ast.Program,
    module_id: core.SourceModuleId,
    file: ?[]const u8,
    include_variables: bool,
    definitions: *std.ArrayList(core.Definition),
) !void {
    for (program.functions.items) |func| {
        if (identifierOffsetAfterKeyword(source, func.span.start, "fn", func.name)) |location| {
            const loc = utils.source.locationAt(source, location.offset);
            try putDefinition(allocator, definitions, func.name, loc.line, loc.column, location.offset, location.length, 0, source.len, .function, module_id, file, .module, null);
        }
        if (include_variables) {
            const scope = analysis_scope.functionScope(func);
            for (func.statements.items) |stmt| {
                try collectDefinitionsFromStatement(allocator, source, module_id, stmt, definitions, scope, func.span.end);
            }
        }
    }
    for (program.constants.items) |constant_decl| {
        if (identifierOffsetAfterKeyword(source, constant_decl.span.start, "const", constant_decl.name)) |location| {
            const loc = utils.source.locationAt(source, location.offset);
            try putDefinition(allocator, definitions, constant_decl.name, loc.line, loc.column, location.offset, location.length, 0, source.len, .constant, module_id, file, .module, null);
        }
    }
    if (include_variables) {
        const document_scope = analysis_scope.documentScope(source.len);
        for (program.document_statements.items) |stmt| {
            try collectDefinitionsFromStatement(allocator, source, module_id, stmt, definitions, document_scope, source.len);
        }
        for (program.pages.items) |page| {
            const scope = analysis_scope.pageScope(page);
            for (page.statements.items) |stmt| {
                try collectDefinitionsFromStatement(allocator, source, module_id, stmt, definitions, scope, page.span.end);
            }
        }
    }
}

fn collectDefinitionsFromStatement(
    allocator: std.mem.Allocator,
    source: []const u8,
    module_id: core.SourceModuleId,
    stmt: ast.Statement,
    definitions: *std.ArrayList(core.Definition),
    scope: analysis_scope.SourceScope,
    visible_end: usize,
) !void {
    switch (stmt.kind) {
        .let_binding => |binding| {
            if (!language_names.isDiscardBindingName(binding.name)) {
                try putStatementDefinition(allocator, source, module_id, stmt, "let", binding.name, definitions, scope.kind, scope.name, visible_end);
            }
        },
        .if_stmt => |if_stmt| {
            const then_end = analysis_scope.statementsVisibleEnd(if_stmt.then_statements.items, stmt.span.end);
            for (if_stmt.then_statements.items) |nested| try collectDefinitionsFromStatement(allocator, source, module_id, nested, definitions, scope, then_end);
            const else_end = analysis_scope.statementsVisibleEnd(if_stmt.else_statements.items, stmt.span.end);
            for (if_stmt.else_statements.items) |nested| try collectDefinitionsFromStatement(allocator, source, module_id, nested, definitions, scope, else_end);
        },
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
    definitions: *std.ArrayList(core.Definition),
    scope_kind: core.DefinitionScopeKind,
    scope_name: ?[]const u8,
    visible_end: usize,
) !void {
    if (identifierOffsetAfterKeyword(source, stmt.span.start, keyword, name)) |location| {
        const loc = utils.source.locationAt(source, location.offset);
        try putDefinition(allocator, definitions, name, loc.line, loc.column, location.offset, location.length, stmt.span.start, visible_end, .variable, module_id, null, scope_kind, scope_name);
    }
}

fn putDefinition(
    allocator: std.mem.Allocator,
    definitions: *std.ArrayList(core.Definition),
    name: []const u8,
    line: usize,
    column: usize,
    span_start: usize,
    length: usize,
    visible_start: usize,
    visible_end: usize,
    kind: core.DefinitionKind,
    module_id: core.SourceModuleId,
    file: ?[]const u8,
    scope_kind: core.DefinitionScopeKind,
    scope_name: ?[]const u8,
) !void {
    try definitions.append(allocator, .{
        .name = try allocator.dupe(u8, name),
        .line = line,
        .column = column,
        .length = length,
        .span_start = span_start,
        .span_end = span_start + length,
        .visible_start = visible_start,
        .visible_end = visible_end,
        .kind = kind,
        .module_id = module_id,
        .file = if (file) |path| try allocator.dupe(u8, path) else null,
        .scope_kind = scope_kind,
        .scope_name = if (scope_name) |scope| try allocator.dupe(u8, scope) else null,
    });
}

fn collectProgramHints(
    allocator: std.mem.Allocator,
    ir: *const core.Ir,
    hints: *std.ArrayList(core.InlayHint),
    source: []const u8,
    source_path: ?[]const u8,
    program: ast.Program,
    module_id: core.SourceModuleId,
    functions: *const core.FunctionMap,
) !void {
    for (program.functions.items) |func| {
        for (func.statements.items) |stmt| {
            try collectStatementHints(allocator, ir, hints, functions, source, source_path, module_id, stmt);
        }
    }
    for (program.constants.items) |constant_decl| {
        try collectExprHints(allocator, ir, hints, functions, source, source_path, module_id, constant_decl.span, constant_decl.value);
    }
    for (program.document_statements.items) |stmt| {
        try collectStatementHints(allocator, ir, hints, functions, source, source_path, module_id, stmt);
    }
    for (program.pages.items) |page| {
        for (page.statements.items) |stmt| {
            try collectStatementHints(allocator, ir, hints, functions, source, source_path, module_id, stmt);
        }
    }
}

fn collectStatementHints(
    allocator: std.mem.Allocator,
    ir: *const core.Ir,
    hints: *std.ArrayList(core.InlayHint),
    functions: *const core.FunctionMap,
    source: []const u8,
    source_path: ?[]const u8,
    module_id: core.SourceModuleId,
    stmt: ast.Statement,
) !void {
    switch (stmt.kind) {
        .let_binding => |binding| try collectExprHints(allocator, ir, hints, functions, source, source_path, module_id, stmt.span, binding.expr),
        .return_expr => |expr| try collectExprHints(allocator, ir, hints, functions, source, source_path, module_id, stmt.span, expr),
        .property_set => |property_set| try collectExprHints(allocator, ir, hints, functions, source, source_path, module_id, stmt.span, property_set.value),
        .if_stmt => |if_stmt| {
            try collectExprHints(allocator, ir, hints, functions, source, source_path, module_id, stmt.span, if_stmt.condition);
            for (if_stmt.then_statements.items) |nested| try collectStatementHints(allocator, ir, hints, functions, source, source_path, module_id, nested);
            for (if_stmt.else_statements.items) |nested| try collectStatementHints(allocator, ir, hints, functions, source, source_path, module_id, nested);
        },
        .expr_stmt => |expr| try collectExprHints(allocator, ir, hints, functions, source, source_path, module_id, stmt.span, expr),
        else => {},
    }
}

fn collectExprHints(
    allocator: std.mem.Allocator,
    ir: *const core.Ir,
    hints: *std.ArrayList(core.InlayHint),
    functions: *const core.FunctionMap,
    source: []const u8,
    source_path: ?[]const u8,
    module_id: core.SourceModuleId,
    span: ast.Span,
    expr: ast.Expr,
) !void {
    switch (expr) {
        .call => |call| {
            try hintForCallExpr(allocator, ir, hints, functions, source, source_path, module_id, span, call);
            for (call.args.items) |arg| try collectExprHints(allocator, ir, hints, functions, source, source_path, module_id, span, arg);
        },
        .apply => |apply| {
            try collectExprHints(allocator, ir, hints, functions, source, source_path, module_id, span, apply.callee.*);
            for (apply.args.items) |arg| try collectExprHints(allocator, ir, hints, functions, source, source_path, module_id, span, arg);
        },
        .lambda => |lambda| try collectExprHints(allocator, ir, hints, functions, source, source_path, module_id, span, lambda.body.*),
        .record_update => |update| {
            try collectExprHints(allocator, ir, hints, functions, source, source_path, module_id, span, update.target.*);
            for (update.fields.items) |field| try collectExprHints(allocator, ir, hints, functions, source, source_path, module_id, span, field.value);
        },
        .member => |member| try collectExprHints(allocator, ir, hints, functions, source, source_path, module_id, span, member.target.*),
        .optional_check => |check| try collectExprHints(allocator, ir, hints, functions, source, source_path, module_id, span, check.target.*),
        .coalesce => |coalesce| {
            try collectExprHints(allocator, ir, hints, functions, source, source_path, module_id, span, coalesce.target.*);
            try collectExprHints(allocator, ir, hints, functions, source, source_path, module_id, span, coalesce.fallback.*);
        },
        else => {},
    }
}

fn hintForCallExpr(
    allocator: std.mem.Allocator,
    ir: *const core.Ir,
    hints: *std.ArrayList(core.InlayHint),
    functions: *const core.FunctionMap,
    source: []const u8,
    source_path: ?[]const u8,
    module_id: core.SourceModuleId,
    span: ast.Span,
    call: ast.CallExpr,
) !void {
    if (call.args.items.len == 0) return;
    const slice = source[span.start..@min(span.end, source.len)];
    const arg_starts = try findCallArgStartOffsets(allocator, slice, call.callee.name, call.args.items.len);
    defer allocator.free(arg_starts);
    const hint_count = @min(call.args.items.len, arg_starts.len);
    const sema = SemanticEnv.init(ir, null, functions).forModule(module_id);
    for (0..hint_count) |index| {
        const param_name = sema.callCalleeParamName(call.callee, index) orelse continue;
        const label = try std.fmt.allocPrint(allocator, "{s}:", .{param_name});
        try appendInlayHint(allocator, hints, source, source_path, module_id, span.start + arg_starts[index], label, .parameter_names);
    }
}

fn collectSolvedSizeHints(
    allocator: std.mem.Allocator,
    ir: *core.Ir,
    hints: *std.ArrayList(core.InlayHint),
) !void {
    var best_by_origin = std.StringHashMap(core.NodeId).init(allocator);
    defer best_by_origin.deinit();

    for (ir.nodes.items) |node| {
        if (node.kind != .object or !node.attached) continue;
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
        const origin = utils.err.parseLocatedOrigin(entry.key_ptr.*) orelse continue;
        const module = moduleForHintOrigin(ir, origin.path);
        const node = ir.getNode(entry.value_ptr.*) orelse continue;
        const label = try std.fmt.allocPrint(
            allocator,
            " x={d:.0} y={d:.0} w={d:.0} h={d:.0}",
            .{ node.frame.x, node.frame.y, node.frame.width, node.frame.height },
        );
        try appendInlayHint(allocator, hints, module.source, module.file, module.id, utils.source.lineAt(module.source, origin.span.end).span.end, label, .solved_frame);
    }
}

fn moduleForHintOrigin(ir: *const core.Ir, file: ?[]const u8) struct { id: core.SourceModuleId, source: []const u8, file: ?[]const u8 } {
    if (file) |origin_path| {
        if (ir.moduleByPathOrSpec(origin_path)) |module| {
            return .{ .id = module.id, .source = module.source, .file = module.path orelse origin_path };
        }
    }
    return .{ .id = ir.project_module_id, .source = ir.projectSource(), .file = ir.projectPath() };
}

fn appendInlayHint(
    allocator: std.mem.Allocator,
    hints: *std.ArrayList(core.InlayHint),
    source: []const u8,
    source_path: ?[]const u8,
    module_id: core.SourceModuleId,
    byte_index: usize,
    label: []const u8,
    kind: core.InlayHintKind,
) !void {
    const loc = utils.source.locationAt(source, @min(byte_index, source.len));
    try hints.append(allocator, .{
        .line = loc.line,
        .column = loc.column,
        .label = label,
        .kind = kind,
        .module_id = module_id,
        .file = source_path,
    });
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
    index = utils.source.skipWhitespaceUntil(slice, index, slice.len);
    if (index >= slice.len or slice[index] != '(') return try allocator.alloc(usize, 0);
    index += 1;

    while (index < slice.len and offsets.items.len < arg_count) {
        while (index < slice.len) {
            index = utils.source.skipWhitespaceUntil(slice, index, slice.len);
            if (index < slice.len and slice[index] == ',') {
                index += 1;
                continue;
            }
            break;
        }
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
            '"' => {
                const after = utils.source.skipDoubleQuotedString(slice, index, slice.len);
                index = if (after == 0) after else after - 1;
            },
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

pub fn identifierOffsetAfterKeyword(source: []const u8, start: usize, keyword: []const u8, expected_name: []const u8) ?SourceIdentifierLocation {
    const line = utils.source.lineAt(source, start).span;
    const line_end = line.end;
    var index = utils.source.skipInlineSpacesUntil(source, start, line_end);
    if (index + keyword.len > line_end or !std.mem.eql(u8, source[index .. index + keyword.len], keyword)) return null;
    index += keyword.len;
    const paired_function = std.mem.eql(u8, keyword, "fn") and index + 2 <= line_end and std.mem.eql(u8, source[index .. index + 2], "/!");
    if (paired_function) index += 2;
    if (index < line_end and language_names.isCallableNameChar(source[index])) return null;
    index = utils.source.skipInlineSpacesUntil(source, index, line_end);
    const ident_start = index;
    if (index >= line_end or !utils.source.isIdentifierStart(source[index])) return null;
    index += 1;
    while (index < line_end and language_names.isCallableNameChar(source[index])) : (index += 1) {}
    if (std.mem.eql(u8, keyword, "fn") and index < line_end and source[index] == '!') index += 1;
    const source_name = source[ident_start..index];
    const matches_source_name = std.mem.eql(u8, source_name, expected_name);
    const matches_paired_generated_name = paired_function and expected_name.len == source_name.len + 1 and expected_name[expected_name.len - 1] == '!' and std.mem.eql(u8, source_name, expected_name[0 .. expected_name.len - 1]);
    if (!matches_source_name and !matches_paired_generated_name) return null;
    return .{ .offset = ident_start, .length = index - ident_start };
}
