const std = @import("std");
const ast = @import("ast");
const core = @import("core");

const declarations = @import("declarations.zig");
const registry = @import("registry.zig");
const type_defs = @import("type_defs.zig");

pub const CallDescriptor = union(enum) {
    function: ast.FunctionDecl,
    primitive: registry.PrimitiveDescriptor,
};

pub const SemanticEnv = struct {
    ir: ?*const core.Ir,
    declarations: ?*const declarations.DeclarationIndex,
    functions: *const std.StringHashMap(ast.FunctionDecl),

    pub fn init(
        ir: ?*const core.Ir,
        declaration_index: ?*const declarations.DeclarationIndex,
        functions: *const std.StringHashMap(ast.FunctionDecl),
    ) SemanticEnv {
        return .{
            .ir = ir,
            .declarations = declaration_index,
            .functions = functions,
        };
    }

    pub fn function(self: *const SemanticEnv, name: []const u8) ?ast.FunctionDecl {
        return self.functions.get(name);
    }

    pub fn hasFunction(self: *const SemanticEnv, name: []const u8) bool {
        return self.functions.contains(name);
    }

    pub fn primitive(self: *const SemanticEnv, name: []const u8) ?registry.PrimitiveDescriptor {
        _ = self;
        return registry.lookupPrimitiveCall(name);
    }

    pub fn call(self: *const SemanticEnv, name: []const u8) ?CallDescriptor {
        if (self.function(name)) |func| return .{ .function = func };
        if (self.primitive(name)) |descriptor| return .{ .primitive = descriptor };
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
        const descriptor = self.typeDescriptor(module_id, name) orelse return null;
        return if (type_defs.isEnumBody(descriptor.body)) descriptor else null;
    }

    pub fn enumHasCase(
        self: *const SemanticEnv,
        module_id: core.SourceModuleId,
        name: []const u8,
        case_name: []const u8,
    ) bool {
        const descriptor = self.enumDescriptor(module_id, name) orelse return false;
        return type_defs.enumContains(descriptor.body, case_name);
    }

    pub fn enumHasCaseAny(self: *const SemanticEnv, name: []const u8, case_name: []const u8) bool {
        if (self.declarations) |index| {
            const descriptor = index.typeByName(name) orelse return false;
            return type_defs.isEnumBody(descriptor.body) and type_defs.enumContains(descriptor.body, case_name);
        }
        if (self.ir) |ir| {
            var index = ir.module_order.items.len;
            while (index > 0) {
                index -= 1;
                const module = ir.moduleById(ir.module_order.items[index]) orelse continue;
                for (module.program.types.items) |decl| {
                    if (!std.mem.eql(u8, decl.name, name)) continue;
                    return type_defs.isEnumBody(decl.body) and type_defs.enumContains(decl.body, case_name);
                }
            }
        }
        return false;
    }

    pub fn enumExistsAny(self: *const SemanticEnv, name: []const u8) bool {
        if (self.declarations) |index| {
            const descriptor = index.typeByName(name) orelse return false;
            return type_defs.isEnumBody(descriptor.body);
        }
        if (self.ir) |ir| {
            var index = ir.module_order.items.len;
            while (index > 0) {
                index -= 1;
                const module = ir.moduleById(ir.module_order.items[index]) orelse continue;
                for (module.program.types.items) |decl| {
                    if (std.mem.eql(u8, decl.name, name) and type_defs.isEnumBody(decl.body)) return true;
                }
            }
        }
        return false;
    }

    pub fn resolveTypeName(self: *const SemanticEnv, module_id: core.SourceModuleId, name: []const u8) ?ast.Type {
        if (builtinType(name)) |ty| return ty;
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
        return .{ .name = decl.name, .body = decl.body, .module_id = module.id };
    }
    return null;
}

fn builtinType(name: []const u8) ?ast.Type {
    if (std.mem.eql(u8, name, "Document")) return ast.Type.document;
    if (std.mem.eql(u8, name, "Page")) return ast.Type.page;
    if (std.mem.eql(u8, name, "Object")) return ast.Type.object;
    if (std.mem.eql(u8, name, "Metadata")) return ast.Type.metadata;
    if (std.mem.eql(u8, name, "Anchor")) return ast.Type.anchor;
    if (std.mem.eql(u8, name, "Style")) return ast.Type.style;
    if (std.mem.eql(u8, name, "String")) return ast.Type.string;
    if (std.mem.eql(u8, name, "Color")) return ast.Type.color;
    if (std.mem.eql(u8, name, "Number")) return ast.Type.number;
    if (std.mem.eql(u8, name, "Bool")) return ast.Type.boolean;
    if (std.mem.eql(u8, name, "Constraints")) return ast.Type.constraints;
    if (std.mem.eql(u8, name, "Void")) return .{ .kind = .void };
    if (std.mem.eql(u8, name, "None")) return ast.Type.none;
    return null;
}

fn parseTypeConstructorArg(text: []const u8, constructor: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, text, constructor)) return null;
    var pos = constructor.len;
    while (pos < text.len and std.ascii.isWhitespace(text[pos])) : (pos += 1) {}
    if (pos >= text.len or text[pos] != '<') return null;
    if (text[text.len - 1] != '>') return null;
    return text[pos + 1 .. text.len - 1];
}
