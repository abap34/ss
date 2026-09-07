const std = @import("std");
const ast = @import("ast");
const core = @import("core");

const context_query = @import("context.zig");
const cursor = @import("cursor.zig");
const import_query = @import("imports.zig");
const resolve_query = @import("resolve.zig");
const types = @import("types.zig");
const utils = @import("utils");

pub fn at(
    allocator: std.mem.Allocator,
    snapshot: anytype,
    req: types.SourceRequest,
    opts: types.QueryOptions,
) ![]types.DefinitionTarget {
    const budget = types.QueryBudget.start(opts);
    if (budget.expired()) return allocator.alloc(types.DefinitionTarget, 0);
    var context = context_query.Context.initFromSnapshot(allocator, snapshot, req, budget) catch |err| switch (err) {
        error.NoQueryTarget => return allocator.alloc(types.DefinitionTarget, 0),
        else => return err,
    };
    defer context.deinit(allocator);

    var out = std.ArrayList(types.DefinitionTarget).empty;
    errdefer out.deinit(allocator);
    if (try appendImportTarget(allocator, &out, snapshot, &context, req.path)) {
        return out.toOwnedSlice(allocator);
    }
    if (try appendResolvedTarget(allocator, &out, snapshot, &context, req)) {
        return out.toOwnedSlice(allocator);
    }
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
    if (context.isImportAlias()) return false;
    if (context.isQualifiedCallableQualifier()) return false;
    if (context.importSpecAtOffset()) return false;
    const module = snapshot.moduleForPath(req.path) orelse return false;
    if (try appendStructuredTarget(allocator, out, snapshot, module.id, context, req.path)) return true;
    if (try appendVisibleVariable(allocator, out, snapshot, module.id, req, context.target, req.path)) return true;
    const qualifier = context.qualifiedCallableAlias();
    const primary_kind = definitionKind(context);
    if (try appendDefinitionOfKind(allocator, out, snapshot, module.id, context.target, qualifier, primary_kind, req.path)) return true;
    const alternate_kind: core.DefinitionKind = if (primary_kind == .function) .constant else .function;
    if (try appendDefinitionOfKind(allocator, out, snapshot, module.id, context.target, qualifier, alternate_kind, req.path)) return true;
    return appendTypeDefinitionTarget(allocator, out, snapshot, module.id, context.target, qualifier, req.path);
}

fn appendStructuredTarget(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(types.DefinitionTarget),
    snapshot: anytype,
    current_module_id: core.SourceModuleId,
    context: *const context_query.Context,
    request_path: []const u8,
) !bool {
    if (context.targetKindIs(.member_name)) {
        if (context.qualifier) |receiver| {
            if (try appendEnumCaseTarget(allocator, out, snapshot, current_module_id, receiver, context.target, request_path)) return true;
        }
        const parsed = context.module() orelse return false;
        const member = cursor.memberAt(parsed, context.offset) orelse return false;
        if (try appendMemberTarget(allocator, out, snapshot, current_module_id, context.offset, member, request_path)) return true;
        return false;
    }
    if (context.targetKindIs(.record_field_name)) {
        const record_name = context.qualifier orelse return false;
        return appendRecordFieldTarget(allocator, out, snapshot, current_module_id, record_name, context.target, request_path);
    }
    if (context.targetKindIs(.record_update_path_segment)) {
        const parsed = context.module() orelse return false;
        const path_target = cursor.recordUpdatePathAt(parsed, context.offset) orelse return false;
        return appendRecordUpdatePathTarget(allocator, out, snapshot, current_module_id, context.offset, path_target, request_path);
    }
    return false;
}

fn appendEnumCaseTarget(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(types.DefinitionTarget),
    snapshot: anytype,
    current_module_id: core.SourceModuleId,
    receiver: []const u8,
    case_name: []const u8,
    request_path: []const u8,
) !bool {
    const ty = resolve_query.resolvedTypeName(snapshot, current_module_id, receiver) orelse return false;
    if (ty.kind != .enum_type) return false;
    const id = ty.nominalId() orelse return false;
    return appendEnumCaseInModule(allocator, out, snapshot, id.module_id, id.name, case_name, request_path);
}

fn appendEnumCaseInModule(
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
        index -= 1;
        const item = snapshot.enum_cases[index];
        if (item.module_id != module_id) continue;
        if (!std.mem.eql(u8, item.enum_name, enum_name)) continue;
        if (!std.mem.eql(u8, item.name, case_name)) continue;
        return appendTargetFromSpan(allocator, out, snapshot, item.module_id, item.name_span, request_path);
    }
    return false;
}

fn appendRecordFieldTarget(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(types.DefinitionTarget),
    snapshot: anytype,
    current_module_id: core.SourceModuleId,
    receiver: []const u8,
    field_name: []const u8,
    request_path: []const u8,
) !bool {
    const id = resolve_query.recordIdForTypeName(snapshot, current_module_id, receiver) orelse return false;
    const field = resolve_query.recordField(snapshot, id, field_name) orelse return false;
    return appendTargetFromSpan(allocator, out, snapshot, field.module_id, field.name_span, request_path);
}

fn appendRecordUpdatePathTarget(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(types.DefinitionTarget),
    snapshot: anytype,
    current_module_id: core.SourceModuleId,
    offset: usize,
    target: cursor.RecordUpdatePathTarget,
    request_path: []const u8,
) !bool {
    const base_record_name = resolve_query.recordIdForExpr(snapshot, current_module_id, offset, target.target) orelse return false;
    const current_record_name = resolve_query.recordIdAfterPath(snapshot, base_record_name, target.path[0..target.segment_index]) orelse return false;
    const segment = target.path[target.segment_index];
    const field = resolve_query.recordField(snapshot, current_record_name, segment.name) orelse return false;
    return appendTargetFromSpan(allocator, out, snapshot, field.module_id, field.name_span, request_path);
}

fn appendMemberTarget(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(types.DefinitionTarget),
    snapshot: anytype,
    current_module_id: core.SourceModuleId,
    offset: usize,
    member: cursor.MemberTarget,
    request_path: []const u8,
) !bool {
    const ty = resolve_query.typeForExpr(snapshot, current_module_id, offset, member.target) orelse return false;
    const field = resolve_query.fieldForType(snapshot, ty, member.name) orelse return false;
    return appendTargetFromSpan(allocator, out, snapshot, field.module_id, field.name_span, request_path);
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
    allocator: std.mem.Allocator,
    out: *std.ArrayList(types.DefinitionTarget),
    snapshot: anytype,
    module_id: core.SourceModuleId,
    req: types.SourceRequest,
    target: []const u8,
    request_path: []const u8,
) !bool {
    const definition = resolve_query.visibleVariable(snapshot, module_id, req.offset, target) orelse return false;
    try out.append(allocator, definitionTarget(snapshot, definition, request_path));
    return true;
}

fn appendDefinitionOfKind(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(types.DefinitionTarget),
    snapshot: anytype,
    current_module_id: core.SourceModuleId,
    target: []const u8,
    qualifier: ?[]const u8,
    kind: core.DefinitionKind,
    request_path: []const u8,
) !bool {
    const definition = resolve_query.valueDefinition(snapshot, current_module_id, target, qualifier, kind) orelse return false;
    try out.append(allocator, definitionTarget(snapshot, definition, request_path));
    return true;
}

fn appendTypeDefinitionTarget(
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
    const definition = resolve_query.typeDefinition(snapshot, current_module_id, target_name, target_qualifier) orelse return false;
    try out.append(allocator, typeDefinitionTarget(snapshot, definition, request_path));
    return true;
}

fn definitionKind(context: *const context_query.Context) core.DefinitionKind {
    if (context.callableRoleIsName()) return .function;
    if (std.mem.endsWith(u8, context.target, "!")) return .function;
    return .constant;
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
