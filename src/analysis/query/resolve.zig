const std = @import("std");
const ast = @import("ast");
const core = @import("core");

const name_resolution = @import("../../language/name_resolution.zig");
const type_resolution = @import("../../language/type_resolution.zig");
const utils = @import("utils");
const QueryBudget = @import("types.zig").QueryBudget;

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
    kind: type_resolution.BindingKind,
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

pub fn visibleVariable(budget: ?QueryBudget, snapshot: anytype, module_id: core.SourceModuleId, offset: usize, name: []const u8) ?core.Definition {
    if (expired(budget)) return null;
    const scope = requestScope(budget, snapshot, module_id, offset);
    var best: ?core.Definition = null;
    var best_start: usize = 0;
    for (snapshot.definitions) |item| {
        if (expired(budget)) return null;
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

pub fn visibleVariableBinding(budget: ?QueryBudget, snapshot: anytype, module_id: core.SourceModuleId, offset: usize, name: []const u8) ?VariableBinding {
    if (expired(budget)) return null;
    const scope = requestScope(budget, snapshot, module_id, offset);
    var best: ?VariableBinding = null;
    var best_start: usize = 0;
    for (snapshot.variable_bindings) |binding| {
        if (expired(budget)) return null;
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

pub fn variableBindingVisibleAt(budget: ?QueryBudget, snapshot: anytype, module_id: core.SourceModuleId, offset: usize, binding: anytype) bool {
    if (expired(budget)) return false;
    if (binding.module_id != module_id) return false;
    if (offset < binding.visible_start or offset > binding.visible_end) return false;
    return scopeMatches(binding.scope_kind, binding.scope_name, requestScope(budget, snapshot, module_id, offset));
}

pub fn recordField(budget: ?QueryBudget, snapshot: anytype, record_id: core.NominalId, field_name: []const u8) ?FieldRef {
    if (expired(budget)) return null;
    var index = snapshot.record_fields.len;
    while (index > 0) {
        if (expired(budget)) return null;
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

pub fn recordIdForExpr(budget: ?QueryBudget, snapshot: anytype, module_id: core.SourceModuleId, offset: usize, expr: ast.Expr) ?core.NominalId {
    if (expired(budget)) return null;
    return recordIdForType(typeForExpr(budget, snapshot, module_id, offset, expr) orelse return null);
}

pub fn typeForExpr(budget: ?QueryBudget, snapshot: anytype, module_id: core.SourceModuleId, offset: usize, expr: ast.Expr) ?ast.Type {
    if (expired(budget)) return null;
    return switch (expr) {
        .record => |record| if (record.module_id) |id| ast.Type.recordType(record.type_name).inModule(id) else resolvedTypeName(budget, snapshot, module_id, record.type_name),
        .record_update => |update| typeForExpr(budget, snapshot, module_id, offset, update.target.*),
        .ident => |ident| blk: {
            if (visibleVariableBinding(budget, snapshot, module_id, offset, ident.name)) |binding| {
                if (binding.object_class) |id| {
                    break :blk if (binding.value_type.kind == .selection) ast.Type.selectionType(ast.Type.objectId(id)) else ast.Type.objectId(id);
                }
                break :blk binding.value_type;
            }
            if (valueBinding(budget, snapshot, module_id, ident.name, null, .constant)) |binding| break :blk binding.value_type;
            break :blk null;
        },
        .call => |call| blk: {
            const binding = valueBinding(budget, snapshot, module_id, call.callee.name, call.callee.qualifier, .function) orelse break :blk null;
            break :blk binding.value_type;
        },
        .member => |member| blk: {
            const target = typeForExpr(budget, snapshot, module_id, offset, member.target.*) orelse break :blk null;
            const field = fieldForType(budget, snapshot, target, member.name) orelse break :blk null;
            break :blk field.value_type;
        },
        else => null,
    };
}

pub fn fieldForType(budget: ?QueryBudget, snapshot: anytype, ty: ast.Type, name: []const u8) ?FieldRef {
    if (expired(budget)) return null;
    if (recordIdForType(ty)) |id| return recordField(budget, snapshot, id, name);
    var current = objectClassForType(snapshot, ty);
    var remaining = snapshot.classes.len;
    while (current) |id| {
        if (expired(budget)) return null;
        var index = snapshot.fields.len;
        while (index > 0) {
            if (expired(budget)) return null;
            index -= 1;
            const field = snapshot.fields[index];
            if (field.class_module_id != id.module_id or !std.mem.eql(u8, field.class_name, id.name) or !std.mem.eql(u8, field.name, name)) continue;
            return .{ .name = field.name, .value_type = field.value_type, .type_label = field.type_label, .module_id = field.module_id, .name_span = field.name_span };
        }
        if (remaining == 0) return null;
        remaining -= 1;
        current = classBase(budget, snapshot, id);
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

pub fn classBase(budget: ?QueryBudget, snapshot: anytype, class_id: core.NominalId) ?core.NominalId {
    if (expired(budget)) return null;
    for (snapshot.classes) |item| {
        if (expired(budget)) return null;
        if (item.module_id == class_id.module_id and std.mem.eql(u8, item.name, class_id.name)) return item.base;
    }
    return null;
}

pub fn recordIdAfterPath(budget: ?QueryBudget, snapshot: anytype, base_record_name: core.NominalId, path: []const ast.RecordPathSegment) ?core.NominalId {
    if (expired(budget)) return null;
    var current_record_name = base_record_name;
    for (path) |segment| {
        if (expired(budget)) return null;
        if (segment.name.len == 0) return null;
        const field = recordField(budget, snapshot, current_record_name, segment.name) orelse return null;
        current_record_name = recordIdForType(field.value_type) orelse return null;
    }
    return current_record_name;
}

pub fn recordIdForTypeName(budget: ?QueryBudget, snapshot: anytype, current_module_id: core.SourceModuleId, name: []const u8) ?core.NominalId {
    if (expired(budget)) return null;
    return recordIdForType(resolvedTypeName(budget, snapshot, current_module_id, name) orelse return null);
}

pub fn resolvedTypeName(budget: ?QueryBudget, snapshot: anytype, current_module_id: core.SourceModuleId, name: []const u8) ?ast.Type {
    if (expired(budget)) return null;
    const Resolver = TypeResolver(@TypeOf(snapshot));
    return switch (type_resolution.resolveText(TypeDefinition, Resolver{ .budget = budget, .snapshot = snapshot }, current_module_id, name)) {
        .found => |binding| binding.ty,
        else => null,
    };
}

const RequestScope = struct {
    kind: core.DefinitionScopeKind,
    name: ?[]const u8 = null,
};

fn requestScope(budget: ?QueryBudget, snapshot: anytype, module_id: core.SourceModuleId, offset: usize) RequestScope {
    if (expired(budget)) return .{ .kind = .document };
    const module = snapshot.moduleById(module_id) orelse return .{ .kind = .document };
    for (module.function_scopes) |scope| {
        if (expired(budget)) return .{ .kind = .document };
        if (offset >= scope.start and offset <= scope.end) return .{ .kind = .function, .name = scope.name };
    }
    for (module.page_scopes) |scope| {
        if (expired(budget)) return .{ .kind = .document };
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
    budget: ?QueryBudget,
    snapshot: anytype,
    current_module_id: core.SourceModuleId,
    name: []const u8,
    qualifier: ?[]const u8,
    kind: core.DefinitionKind,
) ?core.Definition {
    if (expired(budget)) return null;
    const Resolver = DefinitionResolver(@TypeOf(snapshot));
    const resolved = name_resolution.resolve(core.Definition, Resolver{ .budget = budget, .snapshot = snapshot, .kind = kind }, current_module_id, .{
        .qualifier = qualifier,
        .name = name,
    });
    return switch (resolved) {
        .found => |item| item,
        else => null,
    };
}

pub fn valueBinding(
    budget: ?QueryBudget,
    snapshot: anytype,
    current_module_id: core.SourceModuleId,
    name: []const u8,
    qualifier: ?[]const u8,
    kind: core.DefinitionKind,
) ?ValueBinding {
    if (expired(budget)) return null;
    const Resolver = ValueBindingResolver(@TypeOf(snapshot));
    const resolved = name_resolution.resolve(ValueBinding, Resolver{ .budget = budget, .snapshot = snapshot, .kind = kind }, current_module_id, .{
        .qualifier = qualifier,
        .name = name,
    });
    return switch (resolved) {
        .found => |item| item,
        .unknown, .unknown_alias => if (kind == .function and qualifier == null) primitiveBinding(budget, snapshot, name) else null,
    };
}

pub fn typeDefinition(
    budget: ?QueryBudget,
    snapshot: anytype,
    current_module_id: core.SourceModuleId,
    name: []const u8,
    qualifier: ?[]const u8,
) ?TypeDefinition {
    if (expired(budget)) return null;
    const Resolver = TypeResolver(@TypeOf(snapshot));
    const resolved = type_resolution.resolve(TypeDefinition, Resolver{ .budget = budget, .snapshot = snapshot }, current_module_id, .{
        .qualifier = qualifier,
        .name = name,
    });
    return switch (resolved) {
        .found => |binding| binding.target orelse null,
        else => null,
    };
}

fn primitiveBinding(budget: ?QueryBudget, snapshot: anytype, name: []const u8) ?ValueBinding {
    if (expired(budget)) return null;
    for (snapshot.value_bindings) |binding| {
        if (expired(budget)) return null;
        if (!binding.primitive) continue;
        if (!std.mem.eql(u8, binding.name, name)) continue;
        return valueBindingFromSnapshot(binding);
    }
    return null;
}

pub fn aliasTarget(budget: ?QueryBudget, snapshot: anytype, module_id: core.SourceModuleId, alias: []const u8) ?core.SourceModuleId {
    if (expired(budget)) return null;
    const module = snapshot.moduleById(module_id) orelse return null;
    var index = module.imports.len;
    while (index > 0) {
        if (expired(budget)) return null;
        index -= 1;
        const import_info = module.imports[index];
        if (!std.mem.eql(u8, import_info.alias orelse "", alias)) continue;
        return import_info.module_id;
    }
    return null;
}

fn valueBindingInModule(budget: ?QueryBudget, snapshot: anytype, module_id: core.SourceModuleId, name: []const u8, kind: core.DefinitionKind) ?ValueBinding {
    if (expired(budget)) return null;
    const binding = snapshot.valueBindingInModule(module_id, name) orelse return null;
    switch (kind) {
        .function => if (binding.kind != .function) return null,
        .constant => if (binding.kind != .constant) return null,
        .variable => return null,
    }
    return valueBindingFromSnapshot(binding);
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

fn definitionInModule(budget: ?QueryBudget, snapshot: anytype, module_id: core.SourceModuleId, name: []const u8, kind: core.DefinitionKind) ?core.Definition {
    if (expired(budget)) return null;
    const definition = snapshot.valueDefinitionInModule(module_id, name) orelse return null;
    return if (definition.kind == kind) definition else null;
}

fn typeDefinitionInModule(budget: ?QueryBudget, snapshot: anytype, module_id: core.SourceModuleId, kind: anytype, name: []const u8) ?TypeDefinition {
    if (expired(budget)) return null;
    const definition = snapshot.typeDefinitionInModule(module_id, name) orelse return null;
    return if (definition.kind == kind) resolvedTypeDefinition(definition) else null;
}

fn resolvedTypeDefinition(item: anytype) TypeDefinition {
    return .{
        .name = item.name,
        .kind = switch (item.kind) {
            .record => .record,
            .object => .object,
            .enum_type => .enum_type,
        },
        .module_id = item.module_id,
        .line = item.line,
        .column = item.column,
        .length = item.length,
    };
}

pub fn exportedDefinition(budget: ?QueryBudget, snapshot: anytype, module_id: core.SourceModuleId, name: []const u8, kind: core.DefinitionKind) ?core.Definition {
    const Resolver = DefinitionResolver(@TypeOf(snapshot));
    return switch (name_resolution.resolveExport(core.Definition, Resolver{ .budget = budget, .snapshot = snapshot, .kind = kind }, module_id, name)) {
        .found => |item| item,
        else => null,
    };
}

pub fn exportedTypeDefinition(budget: ?QueryBudget, snapshot: anytype, module_id: core.SourceModuleId, name: []const u8) ?TypeDefinition {
    const Resolver = TypeResolver(@TypeOf(snapshot));
    return switch (name_resolution.resolveExport(type_resolution.Binding(TypeDefinition), Resolver{ .budget = budget, .snapshot = snapshot }, module_id, name)) {
        .found => |item| item.target,
        else => null,
    };
}

pub fn exportedValueBinding(budget: ?QueryBudget, snapshot: anytype, module_id: core.SourceModuleId, name: []const u8, kind: core.DefinitionKind) ?ValueBinding {
    const Resolver = ValueBindingResolver(@TypeOf(snapshot));
    return switch (name_resolution.resolveExport(ValueBinding, Resolver{ .budget = budget, .snapshot = snapshot, .kind = kind }, module_id, name)) {
        .found => |item| item,
        else => null,
    };
}

const SnapshotImports = struct {
    pub fn shouldContinue(resolver: anytype) bool {
        return !expired(resolver.budget);
    }

    pub fn resolveAlias(resolver: anytype, module_id: core.SourceModuleId, alias: []const u8) ?core.SourceModuleId {
        return aliasTarget(resolver.budget, resolver.snapshot, module_id, alias);
    }

    pub fn explicitImportCount(resolver: anytype, module_id: core.SourceModuleId) usize {
        const module = resolver.snapshot.moduleById(module_id) orelse return 0;
        return module.imports.len;
    }

    pub fn explicitImport(resolver: anytype, module_id: core.SourceModuleId, index: usize) ?name_resolution.OpenImport {
        const module = resolver.snapshot.moduleById(module_id) orelse return null;
        if (index >= module.imports.len) return null;
        const import_info = module.imports[index];
        return .{ .unqualified = import_info.unqualified, .selected = import_info.selected, .module_id = import_info.module_id };
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
        budget: ?QueryBudget,
        snapshot: SnapshotPtr,
        kind: core.DefinitionKind,

        pub const shouldContinue = SnapshotImports.shouldContinue;
        pub const resolveAlias = SnapshotImports.resolveAlias;
        pub const explicitImportCount = SnapshotImports.explicitImportCount;
        pub const explicitImport = SnapshotImports.explicitImport;
        pub const implicitImportCount = SnapshotImports.implicitImportCount;
        pub const implicitImport = SnapshotImports.implicitImport;

        pub fn findInModule(self: @This(), module_id: core.SourceModuleId, name: []const u8) ?core.Definition {
            return definitionInModule(self.budget, self.snapshot, module_id, name, self.kind);
        }
    };
}

fn ValueBindingResolver(comptime SnapshotPtr: type) type {
    return struct {
        budget: ?QueryBudget,
        snapshot: SnapshotPtr,
        kind: core.DefinitionKind,

        pub const shouldContinue = SnapshotImports.shouldContinue;
        pub const resolveAlias = SnapshotImports.resolveAlias;
        pub const explicitImportCount = SnapshotImports.explicitImportCount;
        pub const explicitImport = SnapshotImports.explicitImport;
        pub const implicitImportCount = SnapshotImports.implicitImportCount;
        pub const implicitImport = SnapshotImports.implicitImport;

        pub fn findInModule(self: @This(), module_id: core.SourceModuleId, name: []const u8) ?ValueBinding {
            return valueBindingInModule(self.budget, self.snapshot, module_id, name, self.kind);
        }
    };
}

fn TypeResolver(comptime SnapshotPtr: type) type {
    return struct {
        budget: ?QueryBudget,
        snapshot: SnapshotPtr,

        pub const shouldContinue = SnapshotImports.shouldContinue;
        pub const resolveAlias = SnapshotImports.resolveAlias;
        pub const explicitImportCount = SnapshotImports.explicitImportCount;
        pub const explicitImport = SnapshotImports.explicitImport;
        pub const implicitImportCount = SnapshotImports.implicitImportCount;
        pub const implicitImport = SnapshotImports.implicitImport;

        pub fn findInModule(self: @This(), module_id: core.SourceModuleId, name: []const u8) ?type_resolution.Binding(TypeDefinition) {
            if (typeDefinitionInModule(self.budget, self.snapshot, module_id, .record, name)) |target| return .{
                .kind = .record,
                .ty = ast.Type.recordType(target.name).inModule(module_id),
                .target = target,
            };
            if (typeDefinitionInModule(self.budget, self.snapshot, module_id, .object, name)) |target| return .{
                .kind = .object,
                .ty = ast.Type.objectClass(target.name).inModule(module_id),
                .target = target,
            };
            if (typeDefinitionInModule(self.budget, self.snapshot, module_id, .enum_type, name)) |target| return .{
                .kind = .enum_type,
                .ty = ast.Type.enumType(target.name).inModule(module_id),
                .target = target,
            };
            return null;
        }
    };
}

fn expired(budget: ?QueryBudget) bool {
    return if (budget) |value| value.expired() else false;
}
