const std = @import("std");
const ast = @import("ast");
const core = @import("core");

const language_names = @import("../language/names.zig");
const analysis_scope = @import("scope.zig");
const utils = @import("utils");

pub fn populateDocumentStateAnalysis(allocator: std.mem.Allocator, state: *core.DocumentState) !void {
    for (state.modules.items) |module| {
        if (module.kind == .project) continue;
        try collectDefinitionsFromModule(allocator, module.source, module.syntax, module.id, module.path, false, &state.definitions);
    }
    try collectDefinitionsFromModule(allocator, state.projectSource(), state.projectSyntax(), state.project_module_id, null, true, &state.definitions);
}

fn collectDefinitionsFromModule(
    allocator: std.mem.Allocator,
    source: []const u8,
    program: ast.Module,
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
