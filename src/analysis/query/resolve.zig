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
    value_type: ast.Type,
    name: []const u8,
    kind: core.DefinitionKind,
    module_id: ?core.SourceModuleId,
    signature: []const u8,
    type_label: []const u8,
    documentation: []const u8,
    primitive: bool = false,
};

pub const VariableBinding = struct {
    value_type: ast.Type,
    name: []const u8,
    type_label: []const u8,
    object_class: ?core.NominalId = null,
    module_id: core.SourceModuleId,
};

pub const FieldRef = struct {
    value_type: ast.Type,
    name: []const u8,
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
                .value_type = binding.value_type,
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

pub fn recordField(snapshot: anytype, record_id: core.NominalId, field_name: []const u8) ?FieldRef {
    var index = snapshot.record_fields.len;
    while (index > 0) {
        index -= 1;
        const field = snapshot.record_fields[index];
        if (field.module_id != record_id.module_id or !std.mem.eql(u8, field.record_name, record_id.name)) continue;
        if (!std.mem.eql(u8, field.name, field_name)) continue;
        return .{
            .name = field.name,
            .value_type = field.value_type,
            .type_label = field.type_label,
            .module_id = field.module_id,
            .name_span = field.name_span,
        };
    }
    return null;
}

pub fn recordIdForType(ty: ast.Type) ?core.NominalId {
    return if (ty.kind == .record) ty.nominalId() else null;
}

pub fn recordIdForExpr(snapshot: anytype, module_id: core.SourceModuleId, offset: usize, expr: ast.Expr) ?core.NominalId {
    return recordIdForType(typeForExpr(snapshot, module_id, offset, expr) orelse return null);
}

pub fn typeForExpr(snapshot: anytype, module_id: core.SourceModuleId, offset: usize, expr: ast.Expr) ?ast.Type {
    return switch (expr) {
        .record => |record| if (record.module_id) |id| ast.Type.recordType(record.type_name).inModule(id) else resolvedTypeName(snapshot, module_id, record.type_name),
        .record_update => |update| typeForExpr(snapshot, module_id, offset, update.target.*),
        .ident => |ident| blk: {
            if (visibleVariableBinding(snapshot, module_id, offset, ident.name)) |binding| {
                if (binding.object_class) |id| {
                    break :blk if (binding.value_type.kind == .selection) ast.Type.selectionType(ast.Type.objectId(id)) else ast.Type.objectId(id);
                }
                break :blk binding.value_type;
            }
            if (valueBinding(snapshot, module_id, ident.name, null, .constant)) |binding| break :blk binding.value_type;
            break :blk null;
        },
        .call => |call| blk: {
            const binding = valueBinding(snapshot, module_id, call.callee.name, call.callee.qualifier, .function) orelse break :blk null;
            break :blk binding.value_type;
        },
        .member => |member| blk: {
            const target = typeForExpr(snapshot, module_id, offset, member.target.*) orelse break :blk null;
            const field = fieldForType(snapshot, target, member.name) orelse break :blk null;
            break :blk field.value_type;
        },
        else => null,
    };
}

pub fn fieldForType(snapshot: anytype, ty: ast.Type, name: []const u8) ?FieldRef {
    if (recordIdForType(ty)) |id| return recordField(snapshot, id, name);
    var current = objectClassForType(snapshot, ty);
    var remaining = snapshot.classes.len;
    while (current) |id| {
        var index = snapshot.fields.len;
        while (index > 0) {
            index -= 1;
            const field = snapshot.fields[index];
            if (field.class_module_id != id.module_id or !std.mem.eql(u8, field.class_name, id.name) or !std.mem.eql(u8, field.name, name)) continue;
            return .{ .name = field.name, .value_type = field.value_type, .type_label = field.type_label, .module_id = field.module_id, .name_span = field.name_span };
        }
        if (remaining == 0) return null;
        remaining -= 1;
        current = classBase(snapshot, id);
    }
    return null;
}

pub fn objectClassForType(snapshot: anytype, ty: ast.Type) ?core.NominalId {
    return switch (ty.kind) {
        .object => ty.nominalId(),
        .selection => ty.selectionItemId(),
        .document, .page => .{
            .module_id = snapshot.builtin_module_id orelse return null,
            .name = if (ty.kind == .document) "Doc" else "PageContext",
        },
        else => null,
    };
}

pub fn classBase(snapshot: anytype, class_id: core.NominalId) ?core.NominalId {
    for (snapshot.classes) |item| {
        if (item.module_id == class_id.module_id and std.mem.eql(u8, item.name, class_id.name)) return item.base;
    }
    return null;
}

pub fn recordIdAfterPath(snapshot: anytype, base_record_name: core.NominalId, path: []const ast.RecordPathSegment) ?core.NominalId {
    var current_record_name = base_record_name;
    for (path) |segment| {
        if (segment.name.len == 0) return null;
        const field = recordField(snapshot, current_record_name, segment.name) orelse return null;
        current_record_name = recordIdForType(field.value_type) orelse return null;
    }
    return current_record_name;
}

pub fn recordIdForTypeName(snapshot: anytype, current_module_id: core.SourceModuleId, name: []const u8) ?core.NominalId {
    return recordIdForType(resolvedTypeName(snapshot, current_module_id, name) orelse return null);
}

pub fn resolvedTypeName(snapshot: anytype, current_module_id: core.SourceModuleId, name: []const u8) ?ast.Type {
    const Resolver = TypeResolver(@TypeOf(snapshot));
    return switch (type_resolution.resolveText(TypeDefinition, Resolver{ .snapshot = snapshot }, current_module_id, name)) {
        .found => |binding| binding.ty,
        else => null,
    };
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
        .value_type = binding.value_type,
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

const SnapshotImports = struct {
    pub fn resolveAlias(resolver: anytype, module_id: core.SourceModuleId, alias: []const u8) ?core.SourceModuleId {
        return aliasTarget(resolver.snapshot, module_id, alias);
    }

    pub fn explicitImportCount(resolver: anytype, module_id: core.SourceModuleId) usize {
        const module = resolver.snapshot.moduleById(module_id) orelse return 0;
        return module.imports.len;
    }

    pub fn explicitImport(resolver: anytype, module_id: core.SourceModuleId, index: usize) ?name_resolution.OpenImport {
        const module = resolver.snapshot.moduleById(module_id) orelse return null;
        if (index >= module.imports.len) return null;
        const import_info = module.imports[index];
        return .{ .unqualified = import_info.unqualified, .module_id = import_info.module_id };
    }

    pub fn implicitImportCount(resolver: anytype, module_id: core.SourceModuleId) usize {
        const module = resolver.snapshot.moduleById(module_id) orelse return 0;
        return module.implicit_import_ids.len;
    }

    pub fn implicitImport(resolver: anytype, module_id: core.SourceModuleId, index: usize) ?core.SourceModuleId {
        const module = resolver.snapshot.moduleById(module_id) orelse return null;
        if (index >= module.implicit_import_ids.len) return null;
        return module.implicit_import_ids[index];
    }
};

fn DefinitionResolver(comptime SnapshotPtr: type) type {
    return struct {
        snapshot: SnapshotPtr,
        kind: core.DefinitionKind,

        pub const resolveAlias = SnapshotImports.resolveAlias;
        pub const explicitImportCount = SnapshotImports.explicitImportCount;
        pub const explicitImport = SnapshotImports.explicitImport;
        pub const implicitImportCount = SnapshotImports.implicitImportCount;
        pub const implicitImport = SnapshotImports.implicitImport;

        pub fn findInModule(self: @This(), module_id: core.SourceModuleId, name: []const u8) ?core.Definition {
            return definitionInModule(self.snapshot, module_id, name, self.kind);
        }
    };
}

fn ValueBindingResolver(comptime SnapshotPtr: type) type {
    return struct {
        snapshot: SnapshotPtr,
        kind: core.DefinitionKind,

        pub const resolveAlias = SnapshotImports.resolveAlias;
        pub const explicitImportCount = SnapshotImports.explicitImportCount;
        pub const explicitImport = SnapshotImports.explicitImport;
        pub const implicitImportCount = SnapshotImports.implicitImportCount;
        pub const implicitImport = SnapshotImports.implicitImport;

        pub fn findInModule(self: @This(), module_id: core.SourceModuleId, name: []const u8) ?ValueBinding {
            return valueBindingInModule(self.snapshot, module_id, name, self.kind);
        }
    };
}

fn TypeResolver(comptime SnapshotPtr: type) type {
    return struct {
        snapshot: SnapshotPtr,

        pub const resolveAlias = SnapshotImports.resolveAlias;
        pub const explicitImportCount = SnapshotImports.explicitImportCount;
        pub const explicitImport = SnapshotImports.explicitImport;
        pub const implicitImportCount = SnapshotImports.implicitImportCount;
        pub const implicitImport = SnapshotImports.implicitImport;

        pub fn findInModule(self: @This(), module_id: core.SourceModuleId, name: []const u8) ?type_resolution.Binding(TypeDefinition) {
            if (typeDefinitionInModule(self.snapshot, module_id, .record, name)) |target| return .{
                .kind = .record,
                .ty = ast.Type.recordType(target.name).inModule(module_id),
                .target = target,
            };
            if (typeDefinitionInModule(self.snapshot, module_id, .object, name)) |target| return .{
                .kind = .object,
                .ty = ast.Type.objectClass(target.name).inModule(module_id),
                .target = target,
            };
            if (typeDefinitionInModule(self.snapshot, module_id, .enum_type, name)) |target| return .{
                .kind = .enum_type,
                .ty = ast.Type.enumType(target.name).inModule(module_id),
                .target = target,
            };
            return null;
        }
    };
}
