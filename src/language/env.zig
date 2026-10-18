const std = @import("std");
const ast = @import("ast");
const core = @import("core");

const declarations = @import("declarations.zig");
const name_resolution = @import("name_resolution.zig");
const registry = @import("registry.zig");
const type_defs = @import("type_defs.zig");
const type_resolution = @import("type_resolution.zig");

pub const CallDescriptor = union(enum) {
    function: ResolvedFunction,
    primitive: registry.PrimitiveDescriptor,
};

pub const ResolvedFunction = struct {
    key: core.FunctionKey,
    module_id: core.SourceModuleId,
    decl: ast.FunctionDecl,
};

pub const ResolvedConst = struct {
    key: core.FunctionKey,
    module_id: core.SourceModuleId,
    decl: ast.ConstDecl,
};

pub const FunctionResolution = name_resolution.Resolution(ResolvedFunction);
pub const ConstResolution = name_resolution.Resolution(ResolvedConst);

pub const SemanticEnv = struct {
    state: ?*const core.DocumentState,
    declarations: ?*const declarations.DeclarationIndex,
    functions: *const core.FunctionMap,
    module_id: core.SourceModuleId = 0,
    type_parameters: []const ast.TypeParameter = &.{},
    record_source_facts: bool = true,
    type_parameter_declaration_start: usize = 0,

    pub fn init(
        state: ?*const core.DocumentState,
        declaration_index: ?*const declarations.DeclarationIndex,
        functions: *const core.FunctionMap,
    ) SemanticEnv {
        return .{
            .state = state,
            .declarations = declaration_index,
            .functions = functions,
        };
    }

    pub fn forModule(self: *const SemanticEnv, module_id: core.SourceModuleId) SemanticEnv {
        var next = self.*;
        next.module_id = module_id;
        next.type_parameters = &.{};
        return next;
    }

    pub fn forTypeParameters(self: *const SemanticEnv, module_id: core.SourceModuleId, parameters: []const ast.TypeParameter, declaration_start: usize) SemanticEnv {
        var next = self.forModule(module_id);
        next.type_parameters = parameters;
        next.type_parameter_declaration_start = declaration_start;
        return next;
    }

    pub fn function(self: *const SemanticEnv, name: []const u8) ?ast.FunctionDecl {
        return switch (self.resolveFunction(ast.CallableName.bare(name))) {
            .found => |resolved| resolved.decl,
            else => null,
        };
    }

    pub fn displayForType(self: *const SemanticEnv, input: ast.Type) ?ResolvedFunction {
        if (input.kind != .record) return null;
        const index = self.declarationIndex() orelse return null;
        const descriptor = index.display(input.nominalId() orelse return null) orelse return null;
        const key = core.functionDeclarationKey(descriptor.module_id, descriptor.decl.*);
        return .{ .key = key, .module_id = key.module_id, .decl = self.functions.get(key) orelse return null };
    }

    pub fn resolvedFunction(self: *const SemanticEnv, callee: ast.CallableName) ?ResolvedFunction {
        return switch (self.resolveFunction(callee)) {
            .found => |resolved| resolved,
            else => null,
        };
    }

    pub fn constant(self: *const SemanticEnv, name: []const u8) ?ast.ConstDecl {
        return switch (self.resolveConst(ast.CallableName.bare(name))) {
            .found => |resolved| resolved.decl,
            else => null,
        };
    }

    pub fn resolvedConst(self: *const SemanticEnv, callee: ast.CallableName) ?ResolvedConst {
        return switch (self.resolveConst(callee)) {
            .found => |resolved| resolved,
            else => null,
        };
    }

    pub fn instantiatedFunction(self: *const SemanticEnv, callee: ast.CallableName) ?ResolvedFunction {
        const state = self.state orelse return null;
        const key = state.instantiations.call_targets.get(callee.call_id orelse return null) orelse return null;
        return .{ .key = key, .module_id = key.module_id, .decl = self.functions.get(key) orelse return null };
    }

    pub fn resolveFunction(self: *const SemanticEnv, callee: ast.CallableName) FunctionResolution {
        if (callee.is_operator) return .unknown;
        if (self.instantiatedFunction(callee)) |resolved| return .{ .found = resolved };
        if (callee.name_hole != null) return .unknown;
        return name_resolution.resolve(ResolvedFunction, FunctionResolver{ .env = self }, self.module_id, .{
            .qualifier = callee.qualifier,
            .name = callee.name,
        });
    }

    pub fn resolveConst(self: *const SemanticEnv, callee: ast.CallableName) ConstResolution {
        if (callee.is_operator) return .unknown;
        if (callee.name_hole != null) return .unknown;
        return name_resolution.resolve(ResolvedConst, ConstResolver{ .env = self }, self.module_id, .{
            .qualifier = callee.qualifier,
            .name = callee.name,
        });
    }

    pub fn resolveValue(self: *const SemanticEnv, comptime Local: type, callee: ast.CallableName, local: ?Local) !name_resolution.ValueResolution(Local, ResolvedConst, ResolvedFunction) {
        return name_resolution.resolveValue(Local, ResolvedConst, ResolvedFunction, ValueResolver{ .env = self }, callee, local);
    }

    pub fn hasModuleExport(self: *const SemanticEnv, module_id: core.SourceModuleId, name: []const u8) bool {
        if (name_resolution.resolveExport(ResolvedFunction, FunctionResolver{ .env = self }, module_id, name) == .found) return true;
        if (name_resolution.resolveExport(ResolvedConst, ConstResolver{ .env = self }, module_id, name) == .found) return true;
        return name_resolution.resolveExport(type_resolution.Binding(void), TypeResolver{ .env = self }, module_id, name) == .found;
    }

    pub fn hasFunction(self: *const SemanticEnv, name: []const u8) bool {
        return self.function(name) != null;
    }

    pub fn hasConst(self: *const SemanticEnv, name: []const u8) bool {
        return self.constant(name) != null;
    }

    pub fn primitive(self: *const SemanticEnv, name: []const u8) ?registry.PrimitiveDescriptor {
        _ = self;
        return registry.lookupPrimitiveCall(name);
    }

    pub fn call(self: *const SemanticEnv, name: []const u8) ?CallDescriptor {
        return self.callCallee(ast.CallableName.bare(name));
    }

    pub fn callCallee(self: *const SemanticEnv, callee: ast.CallableName) ?CallDescriptor {
        return switch (self.resolveValue(void, callee, null) catch unreachable) {
            .function => |func| .{ .function = func },
            .primitive => |descriptor| .{ .primitive = descriptor },
            else => null,
        };
    }

    pub fn primitiveArgType(self: *const SemanticEnv, descriptor: registry.PrimitiveDescriptor, index: usize) ?ast.Type {
        const ty = registry.primitiveArgType(descriptor, index) orelse return null;
        const spec = descriptor.type_module orelse return ty;
        const state = self.state orelse return ty;
        const module = state.moduleByPathOrSpec(spec) orelse return ty;
        return ty.inModule(module.id);
    }

    pub fn query(self: *const SemanticEnv, name: []const u8) ?registry.QueryDescriptor {
        _ = self;
        return registry.lookupQueryOp(name);
    }

    pub fn class(self: *const SemanticEnv, module_id: ?core.SourceModuleId, name: []const u8) ?declarations.ClassDescriptor {
        const index = self.declarationIndex() orelse return null;
        if (module_id) |id| return index.classInModule(id, name);
        const ty = self.resolveTypeNameInContext(self.module_id, name) orelse return null;
        if (ty.kind != .object) return null;
        return index.classById(ty.nominalId() orelse return null);
    }

    pub fn builtinClass(self: *const SemanticEnv, name: []const u8) ?core.NominalId {
        const state = self.state orelse return null;
        return state.builtinClass(name);
    }

    pub fn record(self: *const SemanticEnv, module_id: ?core.SourceModuleId, name: []const u8) ?declarations.RecordDescriptor {
        const index = self.declarationIndex() orelse return null;
        if (module_id) |id| return index.record(.{ .module_id = id, .name = name });
        const ty = self.resolveTypeNameInContext(self.module_id, name) orelse return null;
        if (ty.kind != .record) return null;
        return index.record(ty.nominalId() orelse return null);
    }

    pub fn recordField(self: *const SemanticEnv, id: core.NominalId, field_name: []const u8) ?declarations.RecordFieldDescriptor {
        if (self.declarationIndex()) |index| return index.recordField(id, field_name);
        return null;
    }

    pub fn recordConstruction(self: *const SemanticEnv, expr: ast.RecordExpr) ?declarations.RecordDescriptor {
        if (self.state) |state| if (state.type_instances.construction(expr)) |instance| {
            return .{ .decl = &instance.declaration, .name = instance.declaration.name, .module_id = instance.ty.nominal_module_id.? };
        };
        return self.record(expr.module_id, expr.type_name);
    }

    /// Returns an owned field type with the receiver's type arguments substituted.
    pub fn recordFieldType(self: *const SemanticEnv, allocator: std.mem.Allocator, ty: ast.Type, field_name: []const u8) !?ast.Type {
        const id = ty.nominalId() orelse return null;
        const member = self.recordField(id, field_name) orelse return null;
        const decl = self.record(id.module_id, id.name) orelse return null;
        const bindings = try core.type_instances.substitutions(allocator, ty, decl.decl.*);
        defer allocator.free(bindings);
        return try member.value_type.substitute(allocator, bindings);
    }

    pub fn roleClass(self: *const SemanticEnv, role_name: []const u8) ?core.NominalId {
        if (self.declarationIndex()) |index| return index.roleClass(role_name);
        return null;
    }

    pub fn field(self: *const SemanticEnv, class_id: core.NominalId, field_name: []const u8) ?declarations.FieldDescriptor {
        if (self.declarationIndex()) |index| return index.field(class_id, field_name);
        return null;
    }

    pub fn fieldByName(self: *const SemanticEnv, field_name: []const u8) ?declarations.FieldDescriptor {
        if (self.declarationIndex()) |index| return index.fieldByName(field_name);
        return null;
    }

    pub fn enumHasCase(self: *const SemanticEnv, id: core.NominalId, case_name: []const u8) bool {
        const index = self.declarationIndex() orelse return false;
        const descriptor = index.typeInModule(id.module_id, id.name) orelse return false;
        return type_defs.enumCasesContain(descriptor.cases, case_name);
    }

    pub fn enumExists(self: *const SemanticEnv, module_id: ?core.SourceModuleId, name: []const u8) bool {
        if (module_id) |id| {
            const index = self.declarationIndex() orelse return false;
            return index.typeInModule(id, name) != null;
        }
        const ty = self.resolveTypeNameInContext(self.module_id, name) orelse return false;
        return ty.kind == .enum_type;
    }

    pub fn resolveTypeName(self: *const SemanticEnv, module_id: core.SourceModuleId, name: []const u8) ?ast.Type {
        return switch (type_resolution.resolveUnqualified(void, TypeResolver{ .env = self }, module_id, name)) {
            .found => |binding| binding.ty,
            else => null,
        };
    }

    pub fn resolveTypeNameInContext(self: *const SemanticEnv, module_id: core.SourceModuleId, name: []const u8) ?ast.Type {
        if (module_id == self.module_id) for (self.type_parameters, 0..) |parameter, index| {
            if (std.mem.eql(u8, parameter.name, name)) return ast.Type.parameter(.{
                .module_id = module_id,
                .declaration_start = self.type_parameter_declaration_start,
                .index = @intCast(index),
            }, parameter.name, parameter.span);
        };
        return switch (type_resolution.resolveText(void, TypeResolver{ .env = self }, module_id, name)) {
            .found => |binding| binding.ty,
            else => null,
        };
    }

    fn declarationIndex(self: *const SemanticEnv) ?*const declarations.DeclarationIndex {
        if (self.declarations) |index| return index;
        return if (self.state) |state| state.declaration_index else null;
    }

    pub fn callParamName(self: *const SemanticEnv, call_name: []const u8, index: usize) ?[]const u8 {
        if (self.function(call_name)) |func| {
            if (index < func.params.items.len) return func.params.items[index].name;
            return null;
        }
        if (self.primitive(call_name)) |descriptor| {
            if (descriptor.arg_names.len == 0) return null;
            return if (index < descriptor.arg_names.len) descriptor.arg_names[index] else descriptor.arg_names[descriptor.arg_names.len - 1];
        }
        return null;
    }

    pub fn callCalleeParamName(self: *const SemanticEnv, callee: ast.CallableName, index: usize) ?[]const u8 {
        if (self.resolvedFunction(callee)) |resolved| {
            if (index < resolved.decl.params.items.len) return resolved.decl.params.items[index].name;
            return null;
        }
        if (!callee.isQualified()) return self.callParamName(callee.name, index);
        return null;
    }

    fn resolveAliasInModule(self: *const SemanticEnv, module_id: core.SourceModuleId, alias: []const u8) ?core.SourceModuleId {
        const state = self.state orelse return null;
        const module = state.moduleById(module_id) orelse return null;
        var index = module.syntax.imports.items.len;
        while (index > 0) {
            index -= 1;
            const import_decl = module.syntax.imports.items[index];
            const alias_name = import_decl.mode.alias orelse continue;
            if (!std.mem.eql(u8, alias_name, alias)) continue;
            if (index >= module.resolved_import_ids.items.len) return null;
            return module.resolved_import_ids.items[index];
        }
        return null;
    }

    fn findFunctionInModule(self: *const SemanticEnv, module_id: core.SourceModuleId, name: []const u8) ?ResolvedFunction {
        const key = core.functionKey(module_id, name);
        const decl = self.functions.get(key) orelse return null;
        return .{ .key = key, .module_id = module_id, .decl = decl };
    }

    fn findConstInModule(self: *const SemanticEnv, module_id: core.SourceModuleId, name: []const u8) ?ResolvedConst {
        const state = self.state orelse return null;
        const key = core.constKey(module_id, name);
        const constant_decl = state.constants.declarations.get(key) orelse return null;
        return .{ .key = key, .module_id = module_id, .decl = constant_decl };
    }

    fn explicitImportCount(self: *const SemanticEnv, module_id: core.SourceModuleId) usize {
        const state = self.state orelse return 0;
        const module = state.moduleById(module_id) orelse return 0;
        return module.syntax.imports.items.len;
    }

    fn explicitImport(self: *const SemanticEnv, module_id: core.SourceModuleId, index: usize) ?name_resolution.OpenImport {
        const state = self.state orelse return null;
        const module = state.moduleById(module_id) orelse return null;
        if (index >= module.syntax.imports.items.len) return null;
        const import_decl = module.syntax.imports.items[index];
        return .{
            .unqualified = import_decl.mode.unqualified,
            .selected = import_decl.mode.selected,
            .module_id = if (index < module.resolved_import_ids.items.len) module.resolved_import_ids.items[index] else null,
        };
    }

    fn implicitImportCount(self: *const SemanticEnv, module_id: core.SourceModuleId) usize {
        const state = self.state orelse return 0;
        const module = state.moduleById(module_id) orelse return 0;
        return module.implicit_import_ids.items.len;
    }

    fn implicitImport(self: *const SemanticEnv, module_id: core.SourceModuleId, index: usize) ?core.SourceModuleId {
        const state = self.state orelse return null;
        const module = state.moduleById(module_id) orelse return null;
        if (index >= module.implicit_import_ids.items.len) return null;
        return module.implicit_import_ids.items[index];
    }
};

const FunctionResolver = struct {
    env: *const SemanticEnv,

    pub fn resolveModuleSpec(self: FunctionResolver, spec: []const u8) ?core.SourceModuleId {
        const state = self.env.state orelse return null;
        const module = state.moduleByPathOrSpec(spec) orelse return null;
        return module.id;
    }

    pub fn resolveAlias(self: FunctionResolver, module_id: core.SourceModuleId, alias: []const u8) ?core.SourceModuleId {
        return self.env.resolveAliasInModule(module_id, alias);
    }

    pub fn findInModule(self: FunctionResolver, module_id: core.SourceModuleId, name: []const u8) ?ResolvedFunction {
        return self.env.findFunctionInModule(module_id, name);
    }

    pub fn explicitImportCount(self: FunctionResolver, module_id: core.SourceModuleId) usize {
        return self.env.explicitImportCount(module_id);
    }

    pub fn explicitImport(self: FunctionResolver, module_id: core.SourceModuleId, index: usize) ?name_resolution.OpenImport {
        return self.env.explicitImport(module_id, index);
    }

    pub fn implicitImportCount(self: FunctionResolver, module_id: core.SourceModuleId) usize {
        return self.env.implicitImportCount(module_id);
    }

    pub fn implicitImport(self: FunctionResolver, module_id: core.SourceModuleId, index: usize) ?core.SourceModuleId {
        return self.env.implicitImport(module_id, index);
    }
};

const ConstResolver = struct {
    env: *const SemanticEnv,

    pub fn resolveAlias(self: ConstResolver, module_id: core.SourceModuleId, alias: []const u8) ?core.SourceModuleId {
        return self.env.resolveAliasInModule(module_id, alias);
    }

    pub fn findInModule(self: ConstResolver, module_id: core.SourceModuleId, name: []const u8) ?ResolvedConst {
        return self.env.findConstInModule(module_id, name);
    }

    pub fn explicitImportCount(self: ConstResolver, module_id: core.SourceModuleId) usize {
        return self.env.explicitImportCount(module_id);
    }

    pub fn explicitImport(self: ConstResolver, module_id: core.SourceModuleId, index: usize) ?name_resolution.OpenImport {
        return self.env.explicitImport(module_id, index);
    }

    pub fn implicitImportCount(self: ConstResolver, module_id: core.SourceModuleId) usize {
        return self.env.implicitImportCount(module_id);
    }

    pub fn implicitImport(self: ConstResolver, module_id: core.SourceModuleId, index: usize) ?core.SourceModuleId {
        return self.env.implicitImport(module_id, index);
    }
};

const TypeResolver = struct {
    env: *const SemanticEnv,

    pub fn resolveAlias(self: TypeResolver, module_id: core.SourceModuleId, alias: []const u8) ?core.SourceModuleId {
        return self.env.resolveAliasInModule(module_id, alias);
    }

    pub fn findInModule(self: TypeResolver, module_id: core.SourceModuleId, name: []const u8) ?type_resolution.Binding(void) {
        const index = self.env.declarationIndex() orelse return null;
        if (index.record(.{ .module_id = module_id, .name = name })) |decl| return .{
            .kind = .record,
            .ty = ast.Type.recordType(decl.name).inModule(module_id),
            .target = {},
        };
        if (index.classInModule(module_id, name)) |decl| return .{
            .kind = .object,
            .ty = ast.Type.objectClass(decl.name).inModule(module_id),
            .target = {},
        };
        if (index.typeInModule(module_id, name)) |decl| return .{
            .kind = .enum_type,
            .ty = ast.Type.enumType(decl.name).inModule(module_id),
            .target = {},
        };
        return null;
    }

    pub fn explicitImportCount(self: TypeResolver, module_id: core.SourceModuleId) usize {
        return self.env.explicitImportCount(module_id);
    }

    pub fn explicitImport(self: TypeResolver, module_id: core.SourceModuleId, index: usize) ?name_resolution.OpenImport {
        return self.env.explicitImport(module_id, index);
    }

    pub fn implicitImportCount(self: TypeResolver, module_id: core.SourceModuleId) usize {
        return self.env.implicitImportCount(module_id);
    }

    pub fn implicitImport(self: TypeResolver, module_id: core.SourceModuleId, index: usize) ?core.SourceModuleId {
        return self.env.implicitImport(module_id, index);
    }
};

pub const isBuiltinTypeName = type_resolution.isBuiltinTypeName;

const ValueResolver = struct {
    env: *const SemanticEnv,

    pub fn constant(self: ValueResolver, callee: ast.CallableName) !?ResolvedConst {
        return self.env.resolvedConst(callee);
    }

    pub fn function(self: ValueResolver, callee: ast.CallableName) !?ResolvedFunction {
        return self.env.resolvedFunction(callee);
    }
};
