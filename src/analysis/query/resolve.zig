const std = @import("std");
const ast = @import("ast");
const core = @import("core");

const name_resolution = @import("../../language/name_resolution.zig");
const type_resolution = @import("../../language/type_resolution.zig");
const generic_arguments = @import("../generic_arguments.zig");
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
    callable_type: ?ast.Type = null,
    type_parameter_count: usize = 0,
    declaration_start: usize = 0,
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
    module_id: ?core.SourceModuleId = null,
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
        if (!(offset >= item.span_start and offset < item.span_end) and (offset < item.visible_start or offset > item.visible_end)) continue;
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
        if (!(offset >= binding.span_start and offset < binding.span_end) and (offset < binding.visible_start or offset > binding.visible_end)) continue;
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
    if (ty.kind == .optional) return if (ty.optional_child) |child| recordIdForType(child.*) else null;
    return if (ty.kind == .record) ty.nominalId() else null;
}

/// Types and labels allocated here belong to a request-local arena. Queries never
/// modify the shared snapshot or its type storage.
pub fn typeForExpr(allocator: std.mem.Allocator, budget: ?QueryBudget, snapshot: anytype, module_id: core.SourceModuleId, offset: usize, expr: ast.Expr) anyerror!?ast.Type {
    if (expired(budget)) return null;
    return switch (expr) {
        .record => |record| try typeForConstruction(allocator, budget, snapshot, module_id, offset, record),
        .record_update => |update| try typeForExpr(allocator, budget, snapshot, module_id, offset, update.target.*),
        .ident => |ident| blk: {
            switch (try selectedValue(budget, snapshot, module_id, offset, ast.CallableName.bare(ident.name))) {
                .local => |binding| {
                    if (binding.object_class) |id| {
                        break :blk if (binding.value_type.kind == .selection) binding.value_type else ast.Type.objectId(id);
                    }
                    break :blk binding.value_type;
                },
                .constant => |binding| break :blk binding.value_type,
                .function => |binding| break :blk if (binding.type_parameter_count == 0) binding.callable_type else null,
                else => break :blk null,
            }
        },
        .call => |call| blk: {
            const binding = try selectedValue(budget, snapshot, module_id, offset, call.callee);
            break :blk switch (binding) {
                .local => |value| if (value.value_type.fn_result) |result| result.* else null,
                .constant => |value| if (value.value_type.fn_result) |result| result.* else null,
                .function => |value| try typeForCall(allocator, budget, snapshot, module_id, offset, value, call),
                .primitive => if (primitiveBinding(budget, snapshot, call.callee.name)) |value| value.value_type else null,
                .unknown => null,
            };
        },
        .apply => |apply| blk: {
            const callee = (try typeForExpr(allocator, budget, snapshot, module_id, offset, apply.callee.*)) orelse break :blk null;
            break :blk if (callee.fn_result) |result| result.* else null;
        },
        .member => |member| blk: {
            const target = (try typeForExpr(allocator, budget, snapshot, module_id, offset, member.target.*)) orelse break :blk null;
            const field = (try fieldForType(allocator, budget, snapshot, target, member.name)) orelse break :blk null;
            break :blk field.value_type;
        },
        .string => ast.Type.string,
        .color => ast.Type.color,
        .number => ast.Type.number,
        .boolean => ast.Type.boolean,
        .none => ast.Type.none,
        .enum_case => |case| if (case.module_id) |id| ast.Type.enumType(case.enum_name).inModule(id) else resolvedTypeName(budget, snapshot, module_id, case.enum_name),
        .coalesce => |coalesce| blk: {
            const target = (try typeForExpr(allocator, budget, snapshot, module_id, offset, coalesce.target.*)) orelse break :blk null;
            break :blk if (target.optional_child) |child| child.* else target;
        },
        else => null,
    };
}

fn substitutions(allocator: std.mem.Allocator, module_id: core.SourceModuleId, declaration_start: usize, count: usize) ![]ast.Type.Substitution {
    const bindings = try allocator.alloc(ast.Type.Substitution, count);
    for (bindings, 0..) |*binding, index| binding.* = .{
        .parameter = .{ .module_id = module_id, .declaration_start = declaration_start, .index = @intCast(index) },
        .replacement = ast.Type.any,
    };
    return bindings;
}

pub fn typeForConstruction(allocator: std.mem.Allocator, budget: ?QueryBudget, snapshot: anytype, module_id: core.SourceModuleId, offset: usize, record: ast.RecordExpr) anyerror!?ast.Type {
    const base = if (record.module_id) |id| ast.Type.recordType(record.type_name).inModule(id) else resolvedTypeName(budget, snapshot, module_id, record.type_name) orelse return null;
    const id = base.nominalId() orelse return null;
    for (snapshot.records) |definition| {
        if (expired(budget)) return null;
        if (definition.module_id != id.module_id or !std.mem.eql(u8, definition.name, id.name)) continue;
        if (definition.type_parameter_count == 0) return if (record.type_args.items.len == 0) base else null;
        const bindings = try substitutions(allocator, id.module_id, definition.declaration_start, definition.type_parameter_count);
        const known = try allocator.alloc(bool, bindings.len);
        @memset(known, false);
        if (record.type_args.items.len != 0) {
            if (record.type_args.items.len != bindings.len) return null;
            for (bindings, record.type_args.items, known) |*binding, argument, *found| {
                binding.replacement = (try resolveType(allocator, budget, snapshot, module_id, offset, argument)) orelse return null;
                found.* = true;
            }
        } else {
            for (record.fields.items) |field| {
                if (expired(budget)) return null;
                const pattern = recordField(budget, snapshot, id, field.name) orelse continue;
                const actual = (try typeForExpr(allocator, budget, snapshot, module_id, offset, field.value)) orelse continue;
                generic_arguments.infer(pattern.value_type, actual, bindings, known) catch return null;
            }
        }
        // A partially written constructor still has useful declaration fields.
        for (known) |found| if (!found) return base;
        const arguments = try allocator.alloc(ast.Type, bindings.len);
        for (arguments, bindings) |*argument, binding| argument.* = binding.replacement;
        return try base.withArguments(allocator, arguments);
    }
    return null;
}

fn typeForCall(allocator: std.mem.Allocator, budget: ?QueryBudget, snapshot: anytype, module_id: core.SourceModuleId, offset: usize, function: ValueBinding, call: ast.CallExpr) anyerror!?ast.Type {
    if (function.type_parameter_count == 0) return function.value_type;
    const bindings = try substitutions(allocator, function.module_id orelse return null, function.declaration_start, function.type_parameter_count);
    const known = try allocator.alloc(bool, bindings.len);
    @memset(known, false);
    if (call.type_args.items.len != 0) {
        if (call.type_args.items.len != bindings.len) return null;
        for (bindings, call.type_args.items, known) |*binding, argument, *found| {
            binding.replacement = (try resolveType(allocator, budget, snapshot, module_id, offset, argument)) orelse return null;
            found.* = true;
        }
    } else {
        const signature = function.callable_type orelse return null;
        const count = @min(call.args.items.len, signature.fn_params.len);
        for (signature.fn_params[0..count], call.args.items[0..count]) |pattern, argument| {
            if (expired(budget)) return null;
            const actual = (try typeForExpr(allocator, budget, snapshot, module_id, offset, argument)) orelse continue;
            generic_arguments.infer(pattern, actual, bindings, known) catch return null;
        }
    }
    for (known) |found| if (!found) return null;
    return try function.value_type.substitute(allocator, bindings);
}

fn resolveType(allocator: std.mem.Allocator, budget: ?QueryBudget, snapshot: anytype, module_id: core.SourceModuleId, offset: usize, ty: ast.Type) anyerror!?ast.Type {
    if (expired(budget)) return null;
    if (ty.optional_child) |child| return try ast.Type.optional(allocator, (try resolveType(allocator, budget, snapshot, module_id, offset, child.*)) orelse return null);
    if (ty.fn_result) |result| {
        const parameters = try allocator.alloc(ast.Type, ty.fn_params.len);
        for (parameters, ty.fn_params) |*parameter, original| parameter.* = (try resolveType(allocator, budget, snapshot, module_id, offset, original)) orelse return null;
        return try ast.Type.functionType(allocator, parameters, (try resolveType(allocator, budget, snapshot, module_id, offset, result.*)) orelse return null);
    }
    var base = ty;
    if (ty.parameter_id == null and ty.nominal_module_id == null) {
        if (ty.class_name orelse ty.enum_name) |name| {
            var parameter: ?ast.Type = null;
            if (snapshot.moduleById(module_id)) |module| {
                if (snapshot.syntaxForSource(module.path orelse module.spec, module.source)) |program| {
                    inline for (.{ program.records.items, program.functions.items }) |declarations| {
                        for (declarations) |declaration| {
                            if (expired(budget)) return null;
                            if (offset < declaration.span.start or offset > declaration.span.end) continue;
                            for (declaration.type_params.items, 0..) |item, index| {
                                if (!std.mem.eql(u8, item.name, name)) continue;
                                parameter = .{ .kind = .parameter, .class_name = item.name, .parameter_id = .{ .module_id = module_id, .declaration_start = declaration.span.start, .index = @intCast(index) } };
                            }
                        }
                    }
                }
            }
            base = parameter orelse resolvedTypeName(budget, snapshot, module_id, name) orelse return null;
        }
    }
    if (ty.arguments.len == 0) return base;
    const arguments = try allocator.alloc(ast.Type, ty.arguments.len);
    for (arguments, ty.arguments) |*argument, original| argument.* = (try resolveType(allocator, budget, snapshot, module_id, offset, original)) orelse return null;
    return try base.withArguments(allocator, arguments);
}

pub fn fieldForType(allocator: std.mem.Allocator, budget: ?QueryBudget, snapshot: anytype, ty: ast.Type, name: []const u8) anyerror!?FieldRef {
    if (expired(budget)) return null;
    if (ty.optional_child) |child| return fieldForType(allocator, budget, snapshot, child.*, name);
    if (ty.kind == .placed or ty.kind == .placement) {
        const field_type = @import("../../language/placement.zig").memberType(ty, name) orelse return null;
        return .{ .name = name, .value_type = field_type, .type_label = try field_type.formatAlloc(allocator) };
    }
    if (recordIdForType(ty)) |id| {
        var field = recordField(budget, snapshot, id, name) orelse return null;
        if (ty.arguments.len == 0) return field;
        for (snapshot.records) |definition| {
            if (expired(budget)) return null;
            if (definition.module_id != id.module_id or !std.mem.eql(u8, definition.name, id.name)) continue;
            if (definition.type_parameter_count != ty.arguments.len) return null;
            const bindings = try substitutions(allocator, id.module_id, definition.declaration_start, ty.arguments.len);
            for (bindings, ty.arguments) |*binding, argument| binding.replacement = argument;
            field.value_type = try field.value_type.substitute(allocator, bindings);
            field.type_label = try field.value_type.formatAlloc(allocator);
            return field;
        }
        return null;
    }
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
    if (ty.kind == .optional) return if (ty.optional_child) |child| objectClassForType(snapshot, child.*) else null;
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

pub fn typeAfterPath(allocator: std.mem.Allocator, budget: ?QueryBudget, snapshot: anytype, base: ast.Type, path: []const ast.RecordPathSegment) !?ast.Type {
    if (expired(budget)) return null;
    var current = base;
    for (path) |segment| {
        if (expired(budget) or segment.name.len == 0) return null;
        const field = (try fieldForType(allocator, budget, snapshot, current, segment.name)) orelse return null;
        current = field.value_type;
    }
    return current;
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

pub fn selectedValue(budget: ?QueryBudget, snapshot: anytype, module_id: core.SourceModuleId, offset: usize, callee: ast.CallableName) !name_resolution.ValueResolution(VariableBinding, ValueBinding, ValueBinding) {
    const Resolver = struct {
        snapshot: @TypeOf(snapshot),
        budget: ?QueryBudget,
        module_id: core.SourceModuleId,

        pub fn constant(self: @This(), name: ast.CallableName) !?ValueBinding {
            return valueBinding(self.budget, self.snapshot, self.module_id, name.name, name.qualifier, .constant);
        }

        pub fn function(self: @This(), name: ast.CallableName) !?ValueBinding {
            const binding = valueBinding(self.budget, self.snapshot, self.module_id, name.name, name.qualifier, .function) orelse return null;
            return if (binding.primitive) null else binding;
        }
    };
    return name_resolution.resolveValue(VariableBinding, ValueBinding, ValueBinding, Resolver{ .snapshot = snapshot, .budget = budget, .module_id = module_id }, callee, visibleVariableBinding(budget, snapshot, module_id, offset, callee.name));
}

pub fn structuredField(allocator: std.mem.Allocator, budget: ?QueryBudget, snapshot: anytype, module_id: core.SourceModuleId, context: anytype) !?FieldRef {
    const cursor = @import("cursor.zig");
    if (context.targetKindIs(.member_name)) {
        const parsed = context.module() orelse return null;
        const member = cursor.memberAt(budget, parsed, context.offset) orelse return null;
        const ty = (try typeForExpr(allocator, budget, snapshot, module_id, context.offset, member.target)) orelse return null;
        return fieldForType(allocator, budget, snapshot, ty, member.name);
    }
    if (context.targetKindIs(.record_field_name)) {
        const construction = context.construction orelse return null;
        const ty = (try typeForConstruction(allocator, budget, snapshot, module_id, context.offset, construction)) orelse return null;
        return fieldForType(allocator, budget, snapshot, ty, context.target);
    }
    if (context.targetKindIs(.record_update_path_segment)) {
        const parsed = context.module() orelse return null;
        const target = cursor.recordUpdatePathAt(budget, parsed, context.offset) orelse return null;
        const base = (try typeForExpr(allocator, budget, snapshot, module_id, context.offset, target.target)) orelse return null;
        const ty = (try typeAfterPath(allocator, budget, snapshot, base, target.path[0..target.segment_index])) orelse return null;
        return fieldForType(allocator, budget, snapshot, ty, target.path[target.segment_index].name);
    }
    return null;
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
        .callable_type = binding.callable_type,
        .type_parameter_count = binding.type_parameter_count,
        .declaration_start = binding.declaration_start,
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

    pub fn resolveModuleSpec(resolver: anytype, spec: []const u8) ?core.SourceModuleId {
        if (resolver.kind != .function) return null;
        const Snapshot = switch (@typeInfo(@TypeOf(resolver.snapshot))) {
            .pointer => |pointer| pointer.child,
            else => @TypeOf(resolver.snapshot),
        };
        if (@hasField(Snapshot, "modules")) {
            for (resolver.snapshot.modules) |module| {
                if (expired(resolver.budget)) return null;
                if (std.mem.eql(u8, module.spec, spec)) return module.id;
            }
        }
        return null;
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
        pub const resolveModuleSpec = SnapshotImports.resolveModuleSpec;
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
        pub const resolveModuleSpec = SnapshotImports.resolveModuleSpec;
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
