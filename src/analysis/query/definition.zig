const std = @import("std");
const ast = @import("ast");
const core = @import("core");

const context_query = @import("context.zig");
const import_query = @import("imports.zig");
const resolve_query = @import("resolve.zig");
const types = @import("types.zig");
const utils = @import("utils");
const fallback = @import("fallback.zig");

pub fn at(
    allocator: std.mem.Allocator,
    snapshot: anytype,
    req: types.SourceRequest,
    opts: types.QueryOptions,
) ![]types.DefinitionTarget {
    const budget = types.QueryBudget.start(opts);
    if (budget.expired()) return fallback.definition(allocator, snapshot, req, opts);
    var context = context_query.Context.initFromSnapshot(allocator, snapshot, req, budget) catch |err| switch (err) {
        error.NoQueryTarget => return if (budget.expired()) fallback.definition(allocator, snapshot, req, opts) else allocator.alloc(types.DefinitionTarget, 0),
        else => return err,
    };
    defer context.deinit(allocator);
    if (context.expired()) return fallback.definition(allocator, snapshot, req, opts);

    var out = std.ArrayList(types.DefinitionTarget).empty;
    defer out.deinit(allocator);
    if (!try appendImportTarget(allocator, &out, snapshot, &context, req.path) and !context.expired()) {
        _ = try appendResolvedTarget(allocator, &out, snapshot, &context, req);
    }
    if (budget.canceled()) return allocator.alloc(types.DefinitionTarget, 0);
    if (budget.expired()) return fallback.definition(allocator, snapshot, req, opts);
    return out.toOwnedSlice(allocator);
}

fn appendImportTarget(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(types.DefinitionTarget),
    snapshot: anytype,
    context: *const context_query.Context,
    request_path: []const u8,
) !bool {
    const module_id = import_query.moduleIdForContext(snapshot, context, request_path) orelse return false;
    try out.append(allocator, moduleTarget(snapshot, module_id, request_path));
    return true;
}

fn appendResolvedTarget(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(types.DefinitionTarget),
    snapshot: anytype,
    context: *const context_query.Context,
    req: types.SourceRequest,
) !bool {
    if (import_query.selectedBindingAt(snapshot, context, req.path)) |selected| {
        inline for (.{ core.DefinitionKind.constant, core.DefinitionKind.function }) |kind| {
            if (resolve_query.exportedDefinition(context.budget, snapshot, selected.module_id, selected.name, kind)) |definition| {
                try out.append(allocator, definitionTarget(snapshot, definition, req.path));
                return true;
            }
        }
        if (resolve_query.exportedTypeDefinition(context.budget, snapshot, selected.module_id, selected.name)) |definition| {
            try out.append(allocator, typeDefinitionTarget(snapshot, definition, req.path));
        }
        return true;
    }
    if (context.isImportAlias()) return false;
    if (context.isQualifiedCallableQualifier()) return false;
    if (context.importSpecAtOffset()) return false;
    const module = snapshot.moduleForPath(req.path) orelse return false;
    if (context.typeParameter()) |parameter| {
        return appendTargetFromSpan(allocator, out, snapshot, module.id, parameter.span, req.path);
    }
    if (try appendStructuredTarget(allocator, out, snapshot, module.id, context, req.path)) return true;
    if (context.expired()) return true;
    if (!context.isValueName() and !context.targetKindIs(.enum_name) and !context.targetKindIs(.type_name)) return true;
    const qualifier = context.qualifiedCallableAlias();
    if (context.isValueName()) {
        var callee = ast.CallableName.bare(context.target);
        callee.qualifier = qualifier;
        switch (try resolve_query.selectedValue(context.budget, snapshot, module.id, req.offset, callee)) {
            .local => return appendVisibleVariable(context.budget, allocator, out, snapshot, module.id, req, context.target, req.path),
            .constant, .function => |binding| return appendDefinitionOfKind(context.budget, allocator, out, snapshot, module.id, binding.name, qualifier, binding.kind, req.path),
            .primitive => return true,
            .unknown => {},
        }
    }
    return appendTypeDefinitionTarget(context.budget, allocator, out, snapshot, module.id, context.target, qualifier, req.path);
}

fn appendStructuredTarget(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(types.DefinitionTarget),
    snapshot: anytype,
    current_module_id: core.SourceModuleId,
    context: *const context_query.Context,
    request_path: []const u8,
) !bool {
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    if (try resolve_query.structuredField(scratch.allocator(), context.budget, snapshot, current_module_id, context)) |field| {
        return appendTargetFromSpan(allocator, out, snapshot, field.module_id, field.name_span, request_path);
    }
    if (context.targetKindIs(.member_name) or context.targetKindIs(.enum_case_name)) {
        if (context.qualifier) |receiver| {
            const binding = try resolve_query.selectedValue(context.budget, snapshot, current_module_id, context.offset, ast.CallableName.bare(receiver));
            if (binding == .unknown) return appendEnumCaseTarget(context.budget, allocator, out, snapshot, current_module_id, receiver, context.target, request_path);
        }
    }
    return false;
}

fn appendEnumCaseTarget(
    budget: ?types.QueryBudget,
    allocator: std.mem.Allocator,
    out: *std.ArrayList(types.DefinitionTarget),
    snapshot: anytype,
    current_module_id: core.SourceModuleId,
    receiver: []const u8,
    case_name: []const u8,
    request_path: []const u8,
) !bool {
    const ty = resolve_query.resolvedTypeName(budget, snapshot, current_module_id, receiver) orelse return false;
    if (ty.kind != .enum_type) return false;
    const id = ty.nominalId() orelse return false;
    return appendEnumCaseInModule(budget, allocator, out, snapshot, id.module_id, id.name, case_name, request_path);
}

fn appendEnumCaseInModule(
    budget: ?types.QueryBudget,
    allocator: std.mem.Allocator,
    out: *std.ArrayList(types.DefinitionTarget),
    snapshot: anytype,
    module_id: core.SourceModuleId,
    enum_name: []const u8,
    case_name: []const u8,
    request_path: []const u8,
) !bool {
    var index = snapshot.enum_cases.len;
    while (index > 0) {
        if (budget) |value| if (value.expired()) return false;
        index -= 1;
        const item = snapshot.enum_cases[index];
        if (item.module_id != module_id) continue;
        if (!std.mem.eql(u8, item.enum_name, enum_name)) continue;
        if (!std.mem.eql(u8, item.name, case_name)) continue;
        return appendTargetFromSpan(allocator, out, snapshot, item.module_id, item.name_span, request_path);
    }
    return false;
}

fn appendTargetFromSpan(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(types.DefinitionTarget),
    snapshot: anytype,
    module_id: core.SourceModuleId,
    maybe_span: ?ast.Span,
    request_path: []const u8,
) !bool {
    const span = maybe_span orelse return false;
    const module = snapshot.moduleById(module_id) orelse return false;
    var target = moduleBackedTarget(snapshot, module_id, request_path);
    const start = module.line_index.utf16PositionAt(span.start);
    const end = module.line_index.utf16PositionAt(span.end);
    target.line = start.line;
    target.character = start.character;
    target.end_line = end.line;
    target.end_character = end.character;
    try out.append(allocator, target);
    return true;
}

fn appendVisibleVariable(
    budget: ?types.QueryBudget,
    allocator: std.mem.Allocator,
    out: *std.ArrayList(types.DefinitionTarget),
    snapshot: anytype,
    module_id: core.SourceModuleId,
    req: types.SourceRequest,
    target: []const u8,
    request_path: []const u8,
) !bool {
    const definition = resolve_query.visibleVariable(budget, snapshot, module_id, req.offset, target) orelse return false;
    try out.append(allocator, definitionTarget(snapshot, definition, request_path));
    return true;
}

fn appendDefinitionOfKind(
    budget: ?types.QueryBudget,
    allocator: std.mem.Allocator,
    out: *std.ArrayList(types.DefinitionTarget),
    snapshot: anytype,
    current_module_id: core.SourceModuleId,
    target: []const u8,
    qualifier: ?[]const u8,
    kind: core.DefinitionKind,
    request_path: []const u8,
) !bool {
    const definition = resolve_query.valueDefinition(budget, snapshot, current_module_id, target, qualifier, kind) orelse return false;
    try out.append(allocator, definitionTarget(snapshot, definition, request_path));
    return true;
}

fn appendTypeDefinitionTarget(
    budget: ?types.QueryBudget,
    allocator: std.mem.Allocator,
    out: *std.ArrayList(types.DefinitionTarget),
    snapshot: anytype,
    current_module_id: core.SourceModuleId,
    target: []const u8,
    qualifier: ?[]const u8,
    request_path: []const u8,
) !bool {
    const resolved_target = resolve_query.typeNameReceiver(target);
    const target_name = if (resolved_target) |name| name.name else target;
    const target_qualifier = if (resolved_target) |name| name.qualifier else qualifier;
    const definition = resolve_query.typeDefinition(budget, snapshot, current_module_id, target_name, target_qualifier) orelse return false;
    try out.append(allocator, typeDefinitionTarget(snapshot, definition, request_path));
    return true;
}

fn definitionTarget(snapshot: anytype, definition: core.Definition, request_path: []const u8) types.DefinitionTarget {
    var target = moduleBackedTarget(snapshot, definition.module_id, request_path);
    if (definition.file) |path| {
        target.path = path;
        target.module_spec = null;
    }
    if (snapshot.moduleById(definition.module_id)) |module| {
        const start = module.line_index.utf16PositionAt(definition.span_start);
        const end = module.line_index.utf16PositionAt(@max(definition.span_end, definition.span_start +| 1));
        target.line = start.line;
        target.character = start.character;
        target.end_line = end.line;
        target.end_character = end.character;
        return target;
    }
    const start = lspLocation(definition.line, definition.column);
    target.line = start.line;
    target.character = start.character;
    target.end_line = start.line;
    target.end_character = start.character + @max(definition.length, 1);
    return target;
}

fn typeDefinitionTarget(snapshot: anytype, definition: anytype, request_path: []const u8) types.DefinitionTarget {
    var target = moduleBackedTarget(snapshot, definition.module_id, request_path);
    const start = lspLocation(definition.line, definition.column);
    target.line = start.line;
    target.character = start.character;
    target.end_line = start.line;
    target.end_character = start.character + @max(definition.length, 1);
    return target;
}

fn moduleTarget(snapshot: anytype, module_id: core.SourceModuleId, request_path: []const u8) types.DefinitionTarget {
    var target = moduleBackedTarget(snapshot, module_id, request_path);
    target.line = 0;
    target.character = 0;
    target.end_line = 0;
    target.end_character = 1;
    return target;
}

fn moduleBackedTarget(snapshot: anytype, module_id: core.SourceModuleId, request_path: []const u8) types.DefinitionTarget {
    const module = snapshot.moduleById(module_id) orelse return .{
        .path = request_path,
        .line = 0,
        .character = 0,
        .end_line = 0,
        .end_character = 1,
    };
    if (module.path) |path| return .{
        .path = path,
        .line = 0,
        .character = 0,
        .end_line = 0,
        .end_character = 1,
    };
    return .{
        .module_spec = module.spec,
        .line = 0,
        .character = 0,
        .end_line = 0,
        .end_character = 1,
    };
}

fn lspLocation(line: usize, column: usize) struct { line: usize, character: usize } {
    return .{
        .line = if (line == 0) 0 else line - 1,
        .character = if (column == 0) 0 else column - 1,
    };
}
