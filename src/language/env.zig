const std = @import("std");
const ast = @import("ast");
const core = @import("core");

const declarations = @import("declarations.zig");
const registry = @import("registry.zig");
const value_domains = @import("value_domains.zig");

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

    pub fn hostCapabilities(self: *const SemanticEnv) []const declarations.HostCapabilityDescriptor {
        const index = self.declarations orelse return &.{};
        return index.host_capabilities.items;
    }

    pub fn renderOps(self: *const SemanticEnv) []const declarations.RenderOpDescriptor {
        const index = self.declarations orelse return &.{};
        return index.render_ops.items;
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

    pub fn valueDomain(
        self: *const SemanticEnv,
        module_id: core.SourceModuleId,
        name: []const u8,
    ) ?value_domains.ValueType {
        if (value_domains.parse(name)) |value_type| return value_type;
        if (value_domains.resolveDeclaration("", name)) |value_type| return value_type;
        return self.declaredValueDomain(module_id, name);
    }

    pub fn declaredValueDomain(
        self: *const SemanticEnv,
        module_id: core.SourceModuleId,
        name: []const u8,
    ) ?value_domains.ValueType {
        if (self.declarations) |index| {
            if (resolveValueDomainInModule(index, module_id, name)) |value_type| return value_type;
            if (self.ir) |ir| {
                var order_index = ir.module_order.items.len;
                while (order_index > 0) {
                    order_index -= 1;
                    const current_id = ir.module_order.items[order_index];
                    if (current_id == module_id) continue;
                    if (resolveValueDomainInModule(index, current_id, name)) |value_type| return value_type;
                }
            } else {
                var descriptor_index = index.value_domains.items.len;
                while (descriptor_index > 0) {
                    descriptor_index -= 1;
                    const descriptor = index.value_domains.items[descriptor_index];
                    if (!std.mem.eql(u8, descriptor.name, name)) continue;
                    if (value_domains.resolveDeclaration(descriptor.name, descriptor.body)) |value_type| return value_type;
                }
            }
            return null;
        }

        if (self.ir) |ir| return value_domains.resolveDeclared(ir, module_id, name);
        return null;
    }

    pub fn valueMatches(
        self: *const SemanticEnv,
        module_id: core.SourceModuleId,
        name: []const u8,
        string_literal: ?[]const u8,
        value_tag: core.ValueTag,
    ) bool {
        const value_type = self.valueDomain(module_id, name) orelse return false;
        return value_domains.matches(value_type, string_literal, value_tag);
    }

    pub fn valueLabel(self: *const SemanticEnv, module_id: core.SourceModuleId, name: []const u8) []const u8 {
        const value_type = self.valueDomain(module_id, name) orelse return "known value type";
        return value_domains.label(value_type);
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

fn resolveValueDomainInModule(
    index: *const declarations.DeclarationIndex,
    module_id: core.SourceModuleId,
    name: []const u8,
) ?value_domains.ValueType {
    for (index.value_domains.items) |descriptor| {
        if (descriptor.module_id != module_id) continue;
        if (!std.mem.eql(u8, descriptor.name, name)) continue;
        return value_domains.resolveDeclaration(descriptor.name, descriptor.body);
    }
    return null;
}
