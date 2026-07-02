const std = @import("std");
const ast = @import("ast");
const core = @import("core");

const language_names = @import("../language/names.zig");
const semantic_env = @import("../language/env.zig");
const analysis_scope = @import("scope.zig");
const utils = @import("utils");

const SemanticEnv = semantic_env.SemanticEnv;

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
        try putDefinitionAtSpan(allocator, definitions, source, func.name, func.name_span, 0, source.len, .function, module_id, file, .module, null);
        if (include_variables) {
            const scope = analysis_scope.functionScope(func);
            for (func.params.items) |param| {
                try putDefinitionAtSpan(allocator, definitions, source, param.name, param.name_span, func.span.start, func.span.end, .variable, module_id, null, scope.kind, scope.name);
            }
            for (func.statements.items) |stmt| {
                try collectDefinitionsFromStatement(allocator, source, module_id, stmt, definitions, scope, func.span.end);
            }
        }
    }
    for (program.constants.items) |constant_decl| {
        try putDefinitionAtSpan(allocator, definitions, source, constant_decl.name, constant_decl.name_span, 0, source.len, .constant, module_id, file, .module, null);
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
                try putDefinitionAtSpan(allocator, definitions, source, binding.name, binding.name_span, stmt.span.start, visible_end, .variable, module_id, null, scope.kind, scope.name);
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

fn putDefinitionAtSpan(
    allocator: std.mem.Allocator,
    definitions: *std.ArrayList(core.Definition),
    source: []const u8,
    name: []const u8,
    name_span: ?ast.Span,
    visible_start: usize,
    visible_end: usize,
    kind: core.DefinitionKind,
    module_id: core.SourceModuleId,
    file: ?[]const u8,
    scope_kind: core.DefinitionScopeKind,
    scope_name: ?[]const u8,
) !void {
    const span = name_span orelse return;
    const loc = utils.source.locationAt(source, span.start);
    try putDefinition(allocator, definitions, name, loc.line, loc.column, span.start, @max(span.end, span.start) - span.start, visible_start, visible_end, kind, module_id, file, scope_kind, scope_name);
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
            try hintForCallExpr(allocator, ir, hints, functions, source, source_path, module_id, call);
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
    call: ast.CallExpr,
) !void {
    if (call.args.items.len == 0) return;
    const hint_count = @min(call.args.items.len, call.arg_spans.items.len);
    const sema = SemanticEnv.init(ir, null, functions).forModule(module_id);
    for (0..hint_count) |index| {
        const param_name = sema.callCalleeParamName(call.callee, index) orelse continue;
        const label = try std.fmt.allocPrint(allocator, "{s}:", .{param_name});
        try appendInlayHint(allocator, hints, source, source_path, module_id, call.arg_spans.items[index].start, label, .parameter_names);
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
