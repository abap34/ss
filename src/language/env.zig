const std = @import("std");
const ast = @import("ast");
const core = @import("core");

const declarations = @import("declarations.zig");
const registry = @import("registry.zig");
const type_defs = @import("type_defs.zig");

pub const CallDescriptor = union(enum) {
    function: ResolvedFunction,
    primitive: registry.PrimitiveDescriptor,
};

pub const ResolvedFunction = struct {
    key: core.FunctionKey,
    module_id: core.SourceModuleId,
    decl: ast.FunctionDecl,
};

pub const FunctionResolution = union(enum) {
    found: ResolvedFunction,
    unknown,
    unknown_alias: []const u8,
};

const ModuleVisitStack = struct {
    items: [256]core.SourceModuleId = undefined,
    len: usize = 0,

    fn contains(self: *const ModuleVisitStack, module_id: core.SourceModuleId) bool {
        for (self.items[0..self.len]) |item| {
            if (item == module_id) return true;
        }
        return false;
    }

    fn push(self: *ModuleVisitStack, module_id: core.SourceModuleId) bool {
        if (self.contains(module_id) or self.len >= self.items.len) return false;
        self.items[self.len] = module_id;
        self.len += 1;
        return true;
    }

    fn pop(self: *ModuleVisitStack) void {
        if (self.len > 0) self.len -= 1;
    }
};

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

    pub fn resolveFunction(self: *const SemanticEnv, callee: ast.CallableName) FunctionResolution {
        if (callee.qualifier) |alias| {
            const module_id = self.resolveAlias(alias) orelse return .{ .unknown_alias = alias };
            return if (self.findFunctionInModule(module_id, callee.name)) |resolved|
                .{ .found = resolved }
            else
                .unknown;
        }

        if (self.findFunctionInModule(self.module_id, callee.name)) |resolved| return .{ .found = resolved };
        if (self.ir) |ir| {
            const module = ir.moduleById(self.module_id) orelse return .unknown;
            switch (self.resolveExplicitOpenFunction(module, callee.name)) {
                .found => |resolved| return .{ .found = resolved },
                else => {},
            }
            switch (self.resolveImplicitOpenFunction(module, callee.name)) {
                .found => |resolved| return .{ .found = resolved },
                else => return .unknown,
            }
        } else if (self.findFunctionByName(callee.name)) |resolved| {
            return .{ .found = resolved };
        }
        return .unknown;
    }

    pub fn hasFunction(self: *const SemanticEnv, name: []const u8) bool {
        return self.function(name) != null;
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
        if (builtinType(name)) |ty| return ty;
        if (self.recordExists(name)) return ast.Type.recordType(name);
        if (self.classExists(name)) return ast.Type.objectClass(name);
        if (self.enumDescriptor(module_id, name) != null) return ast.Type.enumType(name);
        return null;
    }

    pub fn resolveTypeText(self: *const SemanticEnv, allocator: std.mem.Allocator, module_id: core.SourceModuleId, text: []const u8) !?ast.Type {
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        if (trimmed.len == 0) return null;
        if (trimmed[trimmed.len - 1] == '?') {
            const inner = (try self.resolveTypeText(allocator, module_id, trimmed[0 .. trimmed.len - 1])) orelse return null;
            const optional_ty = try ast.Type.optional(allocator, inner);
            var owned_inner = inner;
            owned_inner.deinit(allocator);
            return optional_ty;
        }
        if (parseTypeConstructorArg(trimmed, "Selection")) |inner_text| {
            const inner = (try self.resolveTypeText(allocator, module_id, inner_text)) orelse return null;
            return ast.Type.selectionType(inner);
        }
        if (parseTypeConstructorArg(trimmed, "Object")) |inner_text| {
            const class_name = std.mem.trim(u8, inner_text, " \t\r\n");
            return if (self.classExists(class_name)) ast.Type.objectClass(class_name) else null;
        }
        return self.resolveTypeName(module_id, trimmed);
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

    fn resolveAlias(self: *const SemanticEnv, alias: []const u8) ?core.SourceModuleId {
        const ir = self.ir orelse return null;
        const module = ir.moduleById(self.module_id) orelse return null;
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

    fn resolveExplicitOpenFunction(self: *const SemanticEnv, module: *const core.SourceModule, name: []const u8) FunctionResolution {
        var index = module.program.imports.items.len;
        while (index > 0) {
            index -= 1;
            const import_decl = module.program.imports.items[index];
            if (!import_decl.mode.unqualified) continue;
            if (index >= module.resolved_import_ids.items.len) continue;
            const imported_id = module.resolved_import_ids.items[index];
            var stack = ModuleVisitStack{};
            switch (self.resolveOpenFunctionInModule(imported_id, name, &stack)) {
                .found => |resolved| return .{ .found = resolved },
                else => {},
            }
        }
        return .unknown;
    }

    fn resolveImplicitOpenFunction(self: *const SemanticEnv, module: *const core.SourceModule, name: []const u8) FunctionResolution {
        var index = module.implicit_import_ids.items.len;
        while (index > 0) {
            index -= 1;
            const imported_id = module.implicit_import_ids.items[index];
            var stack = ModuleVisitStack{};
            switch (self.resolveOpenFunctionInModule(imported_id, name, &stack)) {
                .found => |resolved| return .{ .found = resolved },
                else => {},
            }
        }
        return .unknown;
    }

    fn resolveOpenFunctionInModule(
        self: *const SemanticEnv,
        module_id: core.SourceModuleId,
        name: []const u8,
        stack: *ModuleVisitStack,
    ) FunctionResolution {
        const ir = self.ir orelse return if (self.findFunctionByName(name)) |resolved| .{ .found = resolved } else .unknown;
        if (!stack.push(module_id)) return .unknown;
        defer stack.pop();

        if (self.findFunctionInModule(module_id, name)) |resolved| return .{ .found = resolved };

        const module = ir.moduleById(module_id) orelse return .unknown;
        var index = module.program.imports.items.len;
        while (index > 0) {
            index -= 1;
            const import_decl = module.program.imports.items[index];
            if (!import_decl.mode.unqualified) continue;
            if (index >= module.resolved_import_ids.items.len) continue;
            const imported_id = module.resolved_import_ids.items[index];
            switch (self.resolveOpenFunctionInModule(imported_id, name, stack)) {
                .found => |resolved| return .{ .found = resolved },
                else => {},
            }
        }
        return .unknown;
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

    fn findFunctionKey(self: *const SemanticEnv, module_id: core.SourceModuleId, name: []const u8) ?core.FunctionKey {
        const key = core.functionKey(module_id, name);
        if (self.functions.contains(key)) return key;
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

fn builtinType(name: []const u8) ?ast.Type {
    if (std.mem.eql(u8, name, "Document")) return ast.Type.document;
    if (std.mem.eql(u8, name, "Page")) return ast.Type.page;
    if (std.mem.eql(u8, name, "Object")) return ast.Type.object;
    if (std.mem.eql(u8, name, "Metadata")) return ast.Type.metadata;
    if (std.mem.eql(u8, name, "Anchor")) return ast.Type.anchor;
    if (std.mem.eql(u8, name, "String")) return ast.Type.string;
    if (std.mem.eql(u8, name, "Color")) return ast.Type.color;
    if (std.mem.eql(u8, name, "Number")) return ast.Type.number;
    if (std.mem.eql(u8, name, "Bool")) return ast.Type.boolean;
    if (std.mem.eql(u8, name, "Constraints")) return ast.Type.constraints;
    if (std.mem.eql(u8, name, "Void")) return .{ .kind = .void };
    if (std.mem.eql(u8, name, "None")) return ast.Type.none;
    return null;
}

pub fn isBuiltinTypeName(name: []const u8) bool {
    return builtinType(name) != null;
}

fn parseTypeConstructorArg(text: []const u8, constructor: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, text, constructor)) return null;
    var pos = constructor.len;
    while (pos < text.len and std.ascii.isWhitespace(text[pos])) : (pos += 1) {}
    if (pos >= text.len or text[pos] != '<') return null;
    if (text[text.len - 1] != '>') return null;
    return text[pos + 1 .. text.len - 1];
}
