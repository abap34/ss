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
    ir: ?*const core.Ir,
    declarations: ?*const declarations.DeclarationIndex,
    functions: *const core.FunctionMap,
    module_id: core.SourceModuleId = 0,

    pub fn init(
        ir: ?*const core.Ir,
        declaration_index: ?*const declarations.DeclarationIndex,
        functions: *const core.FunctionMap,
    ) SemanticEnv {
        return .{
            .ir = ir,
            .declarations = declaration_index,
            .functions = functions,
        };
    }

    pub fn forModule(self: *const SemanticEnv, module_id: core.SourceModuleId) SemanticEnv {
        var next = self.*;
        next.module_id = module_id;
        return next;
    }

    pub fn function(self: *const SemanticEnv, name: []const u8) ?ast.FunctionDecl {
        return switch (self.resolveFunction(ast.CallableName.bare(name))) {
            .found => |resolved| resolved.decl,
            else => null,
        };
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

    pub fn resolveFunction(self: *const SemanticEnv, callee: ast.CallableName) FunctionResolution {
        if (callee.name_hole != null) return .unknown;
        return name_resolution.resolve(ResolvedFunction, FunctionResolver{ .env = self }, self.module_id, .{
            .qualifier = callee.qualifier,
            .name = callee.name,
        });
    }

    pub fn resolveConst(self: *const SemanticEnv, callee: ast.CallableName) ConstResolution {
        if (callee.name_hole != null) return .unknown;
        return name_resolution.resolve(ResolvedConst, ConstResolver{ .env = self }, self.module_id, .{
            .qualifier = callee.qualifier,
            .name = callee.name,
        });
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
        if (self.resolvedFunction(ast.CallableName.bare(name))) |func| return .{ .function = func };
        if (self.primitive(name)) |descriptor| return .{ .primitive = descriptor };
        return null;
    }

    pub fn callCallee(self: *const SemanticEnv, callee: ast.CallableName) ?CallDescriptor {
        if (self.resolvedFunction(callee)) |func| return .{ .function = func };
        if (!callee.isQualified()) {
            if (self.primitive(callee.name)) |descriptor| return .{ .primitive = descriptor };
        }
        return null;
    }

    pub fn query(self: *const SemanticEnv, name: []const u8) ?registry.QueryDescriptor {
        _ = self;
        return registry.lookupQueryOp(name);
    }

    pub fn class(self: *const SemanticEnv, name: []const u8) ?declarations.ClassDescriptor {
        if (self.declarations) |index| return index.classByName(name);
        if (self.ir) |ir| {
            if (declarations.classExists(ir, name)) {
                return .{ .name = name, .base = declarations.findClassBase(ir, name), .module_id = 0 };
            }
        }
        return null;
    }

    pub fn classExists(self: *const SemanticEnv, name: []const u8) bool {
        if (self.declarations) |index| return index.classExists(name);
        if (self.ir) |ir| return declarations.classExists(ir, name);
        return false;
    }

    pub fn record(self: *const SemanticEnv, name: []const u8) ?declarations.RecordDescriptor {
        if (self.declarations) |index| return index.recordByName(name);
        if (self.ir) |ir| return declarations.findRecord(ir, name);
        return null;
    }

    pub fn recordExists(self: *const SemanticEnv, name: []const u8) bool {
        if (self.declarations) |index| return index.recordExists(name);
        if (self.ir) |ir| return declarations.recordExists(ir, name);
        return false;
    }

    pub fn recordField(self: *const SemanticEnv, record_name: []const u8, field_name: []const u8) ?declarations.RecordFieldDescriptor {
        if (self.declarations) |index| return index.recordField(record_name, field_name);
        if (self.ir) |ir| return declarations.findRecordField(ir, record_name, field_name);
        return null;
    }

    pub fn roleClass(self: *const SemanticEnv, role_name: []const u8) ?[]const u8 {
        if (self.declarations) |index| return index.roleClass(role_name);
        if (self.ir) |ir| return declarations.findRoleClass(ir, role_name);
        return null;
    }

    pub fn field(self: *const SemanticEnv, class_name: []const u8, field_name: []const u8) ?declarations.FieldDescriptor {
        if (self.declarations) |index| return index.field(class_name, field_name);
        if (self.ir) |ir| return declarations.findField(ir, class_name, field_name);
        return null;
    }

    pub fn fieldByName(self: *const SemanticEnv, field_name: []const u8) ?declarations.FieldDescriptor {
        if (self.declarations) |index| return index.fieldByName(field_name);
        if (self.ir) |ir| return declarations.findFieldByName(ir, field_name);
        return null;
    }

    pub fn typeDescriptor(
        self: *const SemanticEnv,
        module_id: core.SourceModuleId,
        name: []const u8,
    ) ?declarations.TypeDescriptor {
        if (self.declarations) |index| {
            if (resolveTypeInModule(index, module_id, name)) |descriptor| return descriptor;
            if (self.ir) |ir| {
                var order_index = ir.module_order.items.len;
                while (order_index > 0) {
                    order_index -= 1;
                    const current_id = ir.module_order.items[order_index];
                    if (current_id == module_id) continue;
                    if (resolveTypeInModule(index, current_id, name)) |descriptor| return descriptor;
                }
            } else {
                return index.typeByName(name);
            }
            return null;
        }

        if (self.ir) |ir| return findTypeDescriptor(ir, module_id, name);
        return null;
    }

    pub fn enumDescriptor(
        self: *const SemanticEnv,
        module_id: core.SourceModuleId,
        name: []const u8,
    ) ?declarations.TypeDescriptor {
        return self.typeDescriptor(module_id, name);
    }

    pub fn enumHasCase(
        self: *const SemanticEnv,
        module_id: core.SourceModuleId,
        name: []const u8,
        case_name: []const u8,
    ) bool {
        const descriptor = self.enumDescriptor(module_id, name) orelse return false;
        return type_defs.enumCasesContain(descriptor.cases, case_name);
    }

    pub fn enumHasCaseAny(self: *const SemanticEnv, name: []const u8, case_name: []const u8) bool {
        if (self.declarations) |index| {
            const descriptor = index.typeByName(name) orelse return false;
            return type_defs.enumCasesContain(descriptor.cases, case_name);
        }
        if (self.ir) |ir| {
            var index = ir.module_order.items.len;
            while (index > 0) {
                index -= 1;
                const module = ir.moduleById(ir.module_order.items[index]) orelse continue;
                for (module.program.types.items) |decl| {
                    if (!std.mem.eql(u8, decl.name, name)) continue;
                    return type_defs.enumCasesContain(decl.cases.items, case_name);
                }
            }
        }
        return false;
    }

    pub fn enumExistsAny(self: *const SemanticEnv, name: []const u8) bool {
        if (self.declarations) |index| {
            return index.typeByName(name) != null;
        }
        if (self.ir) |ir| {
            var index = ir.module_order.items.len;
            while (index > 0) {
                index -= 1;
                const module = ir.moduleById(ir.module_order.items[index]) orelse continue;
                for (module.program.types.items) |decl| {
                    if (std.mem.eql(u8, decl.name, name)) return true;
                }
            }
        }
        return false;
    }

    pub fn resolveTypeName(self: *const SemanticEnv, module_id: core.SourceModuleId, name: []const u8) ?ast.Type {
        return switch (type_resolution.resolveUnqualified(void, TypeResolver{ .env = self }, module_id, name)) {
            .found => |binding| binding.ty,
            else => null,
        };
    }

    pub fn resolveTypeNameInContext(self: *const SemanticEnv, module_id: core.SourceModuleId, name: []const u8) ?ast.Type {
        return switch (type_resolution.resolveText(void, TypeResolver{ .env = self }, module_id, name)) {
            .found => |binding| binding.ty,
            else => null,
        };
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
        const ir = self.ir orelse return null;
        const module = ir.moduleById(module_id) orelse return null;
        var index = module.program.imports.items.len;
        while (index > 0) {
            index -= 1;
            const import_decl = module.program.imports.items[index];
            const alias_name = import_decl.mode.alias orelse continue;
            if (!std.mem.eql(u8, alias_name, alias)) continue;
            if (index >= module.resolved_import_ids.items.len) return null;
            return module.resolved_import_ids.items[index];
        }
        return null;
    }

    fn findFunctionInModule(self: *const SemanticEnv, module_id: core.SourceModuleId, name: []const u8) ?ResolvedFunction {
        const ir = self.ir orelse return self.findFunctionByName(name);
        const module = ir.moduleById(module_id) orelse return null;
        for (module.program.functions.items) |func| {
            if (!std.mem.eql(u8, func.name, name)) continue;
            const key = self.findFunctionKey(module_id, name) orelse core.functionKey(module_id, func.name);
            return .{ .key = key, .module_id = module_id, .decl = func };
        }
        return null;
    }

    fn findConstInModule(self: *const SemanticEnv, module_id: core.SourceModuleId, name: []const u8) ?ResolvedConst {
        const ir = self.ir orelse return self.findConstByName(name);
        const module = ir.moduleById(module_id) orelse return null;
        for (module.program.constants.items) |constant_decl| {
            if (!std.mem.eql(u8, constant_decl.name, name)) continue;
            const key = self.findConstKey(module_id, name) orelse core.constKey(module_id, constant_decl.name);
            return .{ .key = key, .module_id = module_id, .decl = constant_decl };
        }
        return null;
    }

    fn explicitImportCount(self: *const SemanticEnv, module_id: core.SourceModuleId) usize {
        const ir = self.ir orelse return 0;
        const module = ir.moduleById(module_id) orelse return 0;
        return module.program.imports.items.len;
    }

    fn explicitImport(self: *const SemanticEnv, module_id: core.SourceModuleId, index: usize) ?name_resolution.OpenImport {
        const ir = self.ir orelse return null;
        const module = ir.moduleById(module_id) orelse return null;
        if (index >= module.program.imports.items.len) return null;
        const import_decl = module.program.imports.items[index];
        return .{
            .unqualified = import_decl.mode.unqualified,
            .module_id = if (index < module.resolved_import_ids.items.len) module.resolved_import_ids.items[index] else null,
        };
    }

    fn implicitImportCount(self: *const SemanticEnv, module_id: core.SourceModuleId) usize {
        const ir = self.ir orelse return 0;
        const module = ir.moduleById(module_id) orelse return 0;
        return module.implicit_import_ids.items.len;
    }

    fn implicitImport(self: *const SemanticEnv, module_id: core.SourceModuleId, index: usize) ?core.SourceModuleId {
        const ir = self.ir orelse return null;
        const module = ir.moduleById(module_id) orelse return null;
        if (index >= module.implicit_import_ids.items.len) return null;
        return module.implicit_import_ids.items[index];
    }

    fn findFunctionByName(self: *const SemanticEnv, name: []const u8) ?ResolvedFunction {
        var iterator = self.functions.iterator();
        while (iterator.next()) |entry| {
            if (!std.mem.eql(u8, entry.value_ptr.name, name)) continue;
            return .{
                .key = entry.key_ptr.*,
                .module_id = entry.key_ptr.module_id,
                .decl = entry.value_ptr.*,
            };
        }
        return null;
    }

    fn findConstByName(self: *const SemanticEnv, name: []const u8) ?ResolvedConst {
        const ir = self.ir orelse return null;
        var iterator = ir.constants.iterator();
        while (iterator.next()) |entry| {
            if (!std.mem.eql(u8, entry.value_ptr.name, name)) continue;
            return .{
                .key = entry.key_ptr.*,
                .module_id = entry.key_ptr.module_id,
                .decl = entry.value_ptr.*,
            };
        }
        return null;
    }

    fn findFunctionKey(self: *const SemanticEnv, module_id: core.SourceModuleId, name: []const u8) ?core.FunctionKey {
        const key = core.functionKey(module_id, name);
        if (self.functions.contains(key)) return key;
        return null;
    }

    fn findConstKey(self: *const SemanticEnv, module_id: core.SourceModuleId, name: []const u8) ?core.FunctionKey {
        const ir = self.ir orelse return null;
        const key = core.constKey(module_id, name);
        if (ir.constants.contains(key)) return key;
        return null;
    }
};

const FunctionResolver = struct {
    env: *const SemanticEnv,

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

    pub fn findRecord(self: TypeResolver, name: []const u8) ?void {
        if (self.env.recordExists(name)) return {};
        return null;
    }

    pub fn findObject(self: TypeResolver, name: []const u8) ?void {
        if (self.env.classExists(name)) return {};
        return null;
    }

    pub fn findEnum(self: TypeResolver, module_id: core.SourceModuleId, name: []const u8) ?void {
        if (self.env.enumDescriptor(module_id, name) != null) return {};
        return null;
    }
};

fn resolveTypeInModule(
    index: *const declarations.DeclarationIndex,
    module_id: core.SourceModuleId,
    name: []const u8,
) ?declarations.TypeDescriptor {
    for (index.types.items) |descriptor| {
        if (descriptor.module_id != module_id) continue;
        if (!std.mem.eql(u8, descriptor.name, name)) continue;
        return descriptor;
    }
    return null;
}

fn findTypeDescriptor(ir: *const core.Ir, module_id: core.SourceModuleId, name: []const u8) ?declarations.TypeDescriptor {
    if (findTypeInModule(ir, module_id, name)) |descriptor| return descriptor;
    var index = ir.module_order.items.len;
    while (index > 0) {
        index -= 1;
        const current_id = ir.module_order.items[index];
        if (current_id == module_id) continue;
        if (findTypeInModule(ir, current_id, name)) |descriptor| return descriptor;
    }
    return null;
}

fn findTypeInModule(ir: *const core.Ir, module_id: core.SourceModuleId, name: []const u8) ?declarations.TypeDescriptor {
    const module = ir.moduleById(module_id) orelse return null;
    for (module.program.types.items) |decl| {
        if (!std.mem.eql(u8, decl.name, name)) continue;
        return .{ .name = decl.name, .cases = decl.cases.items, .module_id = module.id };
    }
    return null;
}

pub fn isBuiltinTypeName(name: []const u8) bool {
    return type_resolution.isBuiltinTypeName(name);
}
