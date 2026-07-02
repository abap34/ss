const std = @import("std");
const ast = @import("ast");
const core = @import("core");

const name_resolution = @import("../../language/name_resolution.zig");
const type_resolution = @import("../../language/type_resolution.zig");
const utils = @import("utils");

pub const TypeNameReceiver = struct {
    qualifier: ?[]const u8 = null,
    name: []const u8,
};

pub fn typeNameReceiver(receiver: []const u8) ?TypeNameReceiver {
    if (receiver.len == 0 or std.mem.indexOfScalar(u8, receiver, '.') != null) return null;
    if (std.mem.lastIndexOf(u8, receiver, "::")) |separator| {
        const qualifier = receiver[0..separator];
        const name = receiver[separator + 2 ..];
        if (!isIdentifier(qualifier) or !isIdentifier(name)) return null;
        return .{ .qualifier = qualifier, .name = name };
    }
    if (std.mem.indexOfScalar(u8, receiver, ':') != null) return null;
    if (!isIdentifier(receiver)) return null;
    return .{ .name = receiver };
}

fn isIdentifier(name: []const u8) bool {
    if (name.len == 0 or !utils.source.isIdentifierStart(name[0])) return false;
    for (name[1..]) |byte| if (!utils.source.isIdentifierContinue(byte)) return false;
    return true;
}

pub const TypeDefinition = struct {
    name: []const u8,
    module_id: core.SourceModuleId,
    line: usize,
    column: usize,
    length: usize,
};

pub const ValueBinding = struct {
    name: []const u8,
    kind: core.DefinitionKind,
    module_id: ?core.SourceModuleId,
    signature: []const u8,
    type_label: []const u8,
    documentation: []const u8,
    primitive: bool = false,
};

pub const VariableBinding = struct {
    name: []const u8,
    type_label: []const u8,
    object_class: ?[]const u8 = null,
    module_id: core.SourceModuleId,
};

pub const RecordFieldRef = struct {
    name: []const u8,
    record_name: []const u8,
    type_label: []const u8,
    module_id: core.SourceModuleId,
    name_span: ?ast.Span = null,
};

pub fn visibleVariable(snapshot: anytype, module_id: core.SourceModuleId, offset: usize, name: []const u8) ?core.Definition {
    const scope = requestScope(snapshot, module_id, offset);
    var best: ?core.Definition = null;
    var best_start: usize = 0;
    for (snapshot.definitions) |item| {
        if (item.kind != .variable) continue;
        if (item.module_id != module_id) continue;
        if (!std.mem.eql(u8, item.name, name)) continue;
        if (offset < item.visible_start or offset > item.visible_end) continue;
        if (!scopeMatches(item.scope_kind, item.scope_name, scope)) continue;
        if (best == null or item.span_start >= best_start) {
            best = item;
            best_start = item.span_start;
        }
    }
    return best;
}

pub fn visibleVariableBinding(snapshot: anytype, module_id: core.SourceModuleId, offset: usize, name: []const u8) ?VariableBinding {
    const scope = requestScope(snapshot, module_id, offset);
    var best: ?VariableBinding = null;
    var best_start: usize = 0;
    for (snapshot.variable_bindings) |binding| {
        if (binding.module_id != module_id) continue;
        if (!std.mem.eql(u8, binding.name, name)) continue;
        if (offset < binding.visible_start or offset > binding.visible_end) continue;
        if (!scopeMatches(binding.scope_kind, binding.scope_name, scope)) continue;
        if (best == null or binding.span_start >= best_start) {
            best = .{
                .name = binding.name,
                .type_label = binding.type_label,
                .object_class = binding.object_class,
                .module_id = binding.module_id,
            };
            best_start = binding.span_start;
        }
    }
    return best;
}

pub fn variableBindingVisibleAt(snapshot: anytype, module_id: core.SourceModuleId, offset: usize, binding: anytype) bool {
    if (binding.module_id != module_id) return false;
    if (offset < binding.visible_start or offset > binding.visible_end) return false;
    return scopeMatches(binding.scope_kind, binding.scope_name, requestScope(snapshot, module_id, offset));
}

pub fn recordField(snapshot: anytype, record_name: []const u8, field_name: []const u8) ?RecordFieldRef {
    var index = snapshot.record_fields.len;
    while (index > 0) {
        index -= 1;
        const field = snapshot.record_fields[index];
        if (!std.mem.eql(u8, field.record_name, record_name)) continue;
        if (!std.mem.eql(u8, field.name, field_name)) continue;
        return .{
            .name = field.name,
            .record_name = field.record_name,
            .type_label = field.type_label,
            .module_id = field.module_id,
            .name_span = field.name_span,
        };
    }
    return null;
}

pub fn recordFieldTypeLabel(snapshot: anytype, record_name: []const u8, field_name: []const u8) ?[]const u8 {
    const field = recordField(snapshot, record_name, field_name) orelse return null;
    return field.type_label;
}

pub fn recordNameForTypeLabel(snapshot: anytype, type_label: []const u8) ?[]const u8 {
    const name = bareTypeName(type_label) orelse return null;
    var index = snapshot.records.len;
    while (index > 0) {
        index -= 1;
        const record = snapshot.records[index];
        if (std.mem.eql(u8, record.name, name)) return record.name;
    }
    return null;
}

pub fn recordNameForExpr(
    snapshot: anytype,
    current_module_id: core.SourceModuleId,
    offset: usize,
    expr: ast.Expr,
) ?[]const u8 {
    return switch (expr) {
        .record => |record| recordNameForTypeName(snapshot, current_module_id, record.type_name),
        .record_update => |update| recordNameForExpr(snapshot, current_module_id, offset, update.target.*),
        .ident => |ident| blk: {
            if (visibleVariableBinding(snapshot, current_module_id, offset, ident.name)) |binding| {
                if (recordNameForTypeLabel(snapshot, binding.type_label)) |record_name| break :blk record_name;
            }
            if (valueBinding(snapshot, current_module_id, ident.name, null, .constant)) |binding| {
                if (recordNameForTypeLabel(snapshot, binding.type_label)) |record_name| break :blk record_name;
            }
            if (valueBinding(snapshot, current_module_id, ident.name, null, .function)) |binding| {
                if (recordNameForTypeLabel(snapshot, binding.type_label)) |record_name| break :blk record_name;
            }
            break :blk null;
        },
        .call => |call| blk: {
            const binding = valueBinding(snapshot, current_module_id, call.callee.name, call.callee.qualifier, .function) orelse break :blk null;
            break :blk recordNameForTypeLabel(snapshot, binding.type_label);
        },
        .member => |member| blk: {
            const target_record = recordNameForExpr(snapshot, current_module_id, offset, member.target.*) orelse break :blk null;
            const field = recordField(snapshot, target_record, member.name) orelse break :blk null;
            break :blk recordNameForTypeLabel(snapshot, field.type_label);
        },
        else => null,
    };
}

pub fn recordNameAfterPath(snapshot: anytype, base_record_name: []const u8, path: []const ast.RecordPathSegment) ?[]const u8 {
    var current_record_name = base_record_name;
    for (path) |segment| {
        if (segment.name.len == 0) return null;
        const field = recordField(snapshot, current_record_name, segment.name) orelse return null;
        current_record_name = recordNameForTypeLabel(snapshot, field.type_label) orelse return null;
    }
    return current_record_name;
}

pub fn recordNameForTypeName(snapshot: anytype, current_module_id: core.SourceModuleId, type_name: []const u8) ?[]const u8 {
    const parsed = typeNameReceiver(type_name) orelse return null;
    if (parsed.qualifier) |alias| {
        const module_id = aliasTarget(snapshot, current_module_id, alias) orelse return null;
        return recordNameInModule(snapshot, module_id, parsed.name);
    }
    if (recordNameInModule(snapshot, current_module_id, parsed.name)) |record_name| return record_name;
    var index = snapshot.records.len;
    while (index > 0) {
        index -= 1;
        const record = snapshot.records[index];
        if (std.mem.eql(u8, record.name, parsed.name)) return record.name;
    }
    return null;
}

pub fn bareTypeName(type_label: []const u8) ?[]const u8 {
    var trimmed = std.mem.trim(u8, type_label, " \t\r\n");
    if (trimmed.len == 0) return null;
    if (trimmed[trimmed.len - 1] == '?') return null;
    if (std.mem.indexOfAny(u8, trimmed, "<>|")) |_| return null;
    if (std.mem.lastIndexOf(u8, trimmed, "::")) |separator| trimmed = trimmed[separator + 2 ..];
    if (!isIdentifier(trimmed)) return null;
    return trimmed;
}

fn recordNameInModule(snapshot: anytype, module_id: core.SourceModuleId, name: []const u8) ?[]const u8 {
    var index = snapshot.records.len;
    while (index > 0) {
        index -= 1;
        const record = snapshot.records[index];
        if (record.module_id != module_id) continue;
        if (std.mem.eql(u8, record.name, name)) return record.name;
    }
    return null;
}

const RequestScope = struct {
    kind: core.DefinitionScopeKind,
    name: ?[]const u8 = null,
};

fn requestScope(snapshot: anytype, module_id: core.SourceModuleId, offset: usize) RequestScope {
    const module = snapshot.moduleById(module_id) orelse return .{ .kind = .document };
    for (module.function_scopes) |scope| {
        if (offset >= scope.start and offset <= scope.end) return .{ .kind = .function, .name = scope.name };
    }
    for (module.page_scopes) |scope| {
        if (offset >= scope.start and offset <= scope.end) return .{ .kind = .page, .name = scope.name };
    }
    return .{ .kind = .document };
}

fn scopeMatches(kind: core.DefinitionScopeKind, name: ?[]const u8, request_scope: RequestScope) bool {
    if (kind != request_scope.kind) return false;
    if (request_scope.name) |scope_name| return std.mem.eql(u8, name orelse "", scope_name);
    return name == null;
}

pub fn valueDefinition(
    snapshot: anytype,
    current_module_id: core.SourceModuleId,
    name: []const u8,
    qualifier: ?[]const u8,
    kind: core.DefinitionKind,
) ?core.Definition {
    const Resolver = DefinitionResolver(@TypeOf(snapshot));
    const resolved = name_resolution.resolve(core.Definition, Resolver{ .snapshot = snapshot, .kind = kind }, current_module_id, .{
        .qualifier = qualifier,
        .name = name,
    });
    return switch (resolved) {
        .found => |item| item,
        else => null,
    };
}

pub fn valueBinding(
    snapshot: anytype,
    current_module_id: core.SourceModuleId,
    name: []const u8,
    qualifier: ?[]const u8,
    kind: core.DefinitionKind,
) ?ValueBinding {
    const Resolver = ValueBindingResolver(@TypeOf(snapshot));
    const resolved = name_resolution.resolve(ValueBinding, Resolver{ .snapshot = snapshot, .kind = kind }, current_module_id, .{
        .qualifier = qualifier,
        .name = name,
    });
    return switch (resolved) {
        .found => |item| item,
        .unknown, .unknown_alias => if (kind == .function and qualifier == null) primitiveBinding(snapshot, name) else null,
    };
}

pub fn typeDefinition(
    snapshot: anytype,
    current_module_id: core.SourceModuleId,
    name: []const u8,
    qualifier: ?[]const u8,
) ?TypeDefinition {
    const Resolver = TypeResolver(@TypeOf(snapshot));
    const resolved = type_resolution.resolve(TypeDefinition, Resolver{ .snapshot = snapshot }, current_module_id, .{
        .qualifier = qualifier,
        .name = name,
    });
    return switch (resolved) {
        .found => |binding| binding.target orelse null,
        else => null,
    };
}

fn primitiveBinding(snapshot: anytype, name: []const u8) ?ValueBinding {
    for (snapshot.value_bindings) |binding| {
        if (!binding.primitive) continue;
        if (!std.mem.eql(u8, binding.name, name)) continue;
        return valueBindingFromSnapshot(binding);
    }
    return null;
}

pub fn aliasTarget(snapshot: anytype, module_id: core.SourceModuleId, alias: []const u8) ?core.SourceModuleId {
    const module = snapshot.moduleById(module_id) orelse return null;
    var index = module.imports.len;
    while (index > 0) {
        index -= 1;
        const import_info = module.imports[index];
        if (!std.mem.eql(u8, import_info.alias orelse "", alias)) continue;
        return import_info.module_id;
    }
    return null;
}

fn valueBindingInModule(snapshot: anytype, module_id: core.SourceModuleId, name: []const u8, kind: core.DefinitionKind) ?ValueBinding {
    for (snapshot.value_bindings) |binding| {
        switch (kind) {
            .function => if (binding.kind != .function) continue,
            .constant => if (binding.kind != .constant) continue,
            .variable => return null,
        }
        if ((binding.module_id orelse continue) != module_id) continue;
        if (!std.mem.eql(u8, binding.name, name)) continue;
        return valueBindingFromSnapshot(binding);
    }
    return null;
}

fn valueBindingFromSnapshot(binding: anytype) ValueBinding {
    return .{
        .name = binding.name,
        .kind = switch (binding.kind) {
            .function => .function,
            .constant => .constant,
        },
        .module_id = binding.module_id,
        .signature = binding.signature,
        .type_label = binding.type_label,
        .documentation = binding.documentation,
        .primitive = binding.primitive,
    };
}

fn definitionInModule(snapshot: anytype, module_id: core.SourceModuleId, name: []const u8, kind: core.DefinitionKind) ?core.Definition {
    for (snapshot.definitions) |definition_item| {
        if (definition_item.kind != kind) continue;
        if (definition_item.module_id != module_id) continue;
        if (!std.mem.eql(u8, definition_item.name, name)) continue;
        return definition_item;
    }
    return null;
}

fn typeDefinitionByKindAndName(snapshot: anytype, kind: anytype, name: []const u8) ?TypeDefinition {
    var index = snapshot.type_definitions.len;
    while (index > 0) {
        index -= 1;
        const item = snapshot.type_definitions[index];
        if (item.kind != kind) continue;
        if (!std.mem.eql(u8, item.name, name)) continue;
        return resolvedTypeDefinition(item);
    }
    return null;
}

fn typeDefinitionInContext(snapshot: anytype, module_id: core.SourceModuleId, kind: anytype, name: []const u8) ?TypeDefinition {
    if (typeDefinitionInModule(snapshot, module_id, kind, name)) |item| return item;
    var index = snapshot.module_order.len;
    while (index > 0) {
        index -= 1;
        const current_id = snapshot.module_order[index];
        if (current_id == module_id) continue;
        if (typeDefinitionInModule(snapshot, current_id, kind, name)) |item| return item;
    }
    return null;
}

fn typeDefinitionInModule(snapshot: anytype, module_id: core.SourceModuleId, kind: anytype, name: []const u8) ?TypeDefinition {
    for (snapshot.type_definitions) |item| {
        if (item.kind != kind) continue;
        if (item.module_id != module_id) continue;
        if (!std.mem.eql(u8, item.name, name)) continue;
        return resolvedTypeDefinition(item);
    }
    return null;
}

fn resolvedTypeDefinition(item: anytype) TypeDefinition {
    return .{
        .name = item.name,
        .module_id = item.module_id,
        .line = item.line,
        .column = item.column,
        .length = item.length,
    };
}

fn DefinitionResolver(comptime SnapshotPtr: type) type {
    return struct {
        snapshot: SnapshotPtr,
        kind: core.DefinitionKind,

        pub fn resolveAlias(self: @This(), module_id: core.SourceModuleId, alias: []const u8) ?core.SourceModuleId {
            return aliasTarget(self.snapshot, module_id, alias);
        }

        pub fn findInModule(self: @This(), module_id: core.SourceModuleId, name: []const u8) ?core.Definition {
            return definitionInModule(self.snapshot, module_id, name, self.kind);
        }

        pub fn explicitImportCount(self: @This(), module_id: core.SourceModuleId) usize {
            const module = self.snapshot.moduleById(module_id) orelse return 0;
            return module.imports.len;
        }

        pub fn explicitImport(self: @This(), module_id: core.SourceModuleId, index: usize) ?name_resolution.OpenImport {
            const module = self.snapshot.moduleById(module_id) orelse return null;
            if (index >= module.imports.len) return null;
            const import_info = module.imports[index];
            return .{
                .unqualified = import_info.unqualified,
                .module_id = import_info.module_id,
            };
        }

        pub fn implicitImportCount(self: @This(), module_id: core.SourceModuleId) usize {
            const module = self.snapshot.moduleById(module_id) orelse return 0;
            return module.implicit_import_ids.len;
        }

        pub fn implicitImport(self: @This(), module_id: core.SourceModuleId, index: usize) ?core.SourceModuleId {
            const module = self.snapshot.moduleById(module_id) orelse return null;
            if (index >= module.implicit_import_ids.len) return null;
            return module.implicit_import_ids[index];
        }
    };
}

fn ValueBindingResolver(comptime SnapshotPtr: type) type {
    return struct {
        snapshot: SnapshotPtr,
        kind: core.DefinitionKind,

        pub fn resolveAlias(self: @This(), module_id: core.SourceModuleId, alias: []const u8) ?core.SourceModuleId {
            return aliasTarget(self.snapshot, module_id, alias);
        }

        pub fn findInModule(self: @This(), module_id: core.SourceModuleId, name: []const u8) ?ValueBinding {
            return valueBindingInModule(self.snapshot, module_id, name, self.kind);
        }

        pub fn explicitImportCount(self: @This(), module_id: core.SourceModuleId) usize {
            const module = self.snapshot.moduleById(module_id) orelse return 0;
            return module.imports.len;
        }

        pub fn explicitImport(self: @This(), module_id: core.SourceModuleId, index: usize) ?name_resolution.OpenImport {
            const module = self.snapshot.moduleById(module_id) orelse return null;
            if (index >= module.imports.len) return null;
            const import_info = module.imports[index];
            return .{
                .unqualified = import_info.unqualified,
                .module_id = import_info.module_id,
            };
        }

        pub fn implicitImportCount(self: @This(), module_id: core.SourceModuleId) usize {
            const module = self.snapshot.moduleById(module_id) orelse return 0;
            return module.implicit_import_ids.len;
        }

        pub fn implicitImport(self: @This(), module_id: core.SourceModuleId, index: usize) ?core.SourceModuleId {
            const module = self.snapshot.moduleById(module_id) orelse return null;
            if (index >= module.implicit_import_ids.len) return null;
            return module.implicit_import_ids[index];
        }
    };
}

fn TypeResolver(comptime SnapshotPtr: type) type {
    return struct {
        snapshot: SnapshotPtr,

        pub fn resolveAlias(self: @This(), module_id: core.SourceModuleId, alias: []const u8) ?core.SourceModuleId {
            return aliasTarget(self.snapshot, module_id, alias);
        }

        pub fn findRecord(self: @This(), name: []const u8) ?TypeDefinition {
            return typeDefinitionByKindAndName(self.snapshot, .record, name);
        }

        pub fn findObject(self: @This(), name: []const u8) ?TypeDefinition {
            return typeDefinitionByKindAndName(self.snapshot, .object, name);
        }

        pub fn findEnum(self: @This(), module_id: core.SourceModuleId, name: []const u8) ?TypeDefinition {
            return typeDefinitionInContext(self.snapshot, module_id, .enum_type, name);
        }
    };
}
