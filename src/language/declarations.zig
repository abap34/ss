const std = @import("std");
const ast = @import("ast");
const core = @import("core");

pub const ClassDescriptor = struct {
    name: []const u8,
    base: ?[]const u8,
    module_id: core.SourceModuleId,
};

pub const RoleDescriptor = struct {
    name: []const u8,
    class_name: []const u8,
    module_id: core.SourceModuleId,
};

pub const FieldDescriptor = struct {
    name: []const u8,
    name_span: ?ast.Span = null,
    class_name: []const u8,
    value_type: ast.Type,
    default_value: ?*const ast.Expr,
    default_property_value: ?[]const u8,
    module_id: core.SourceModuleId,
};

pub const RecordDescriptor = struct {
    name: []const u8,
    module_id: core.SourceModuleId,
};

pub const RecordFieldDescriptor = struct {
    name: []const u8,
    name_span: ?ast.Span = null,
    record_name: []const u8,
    value_type: ast.Type,
    default_value: ?*const ast.Expr,
    default_property_value: ?[]const u8,
    module_id: core.SourceModuleId,
};

pub const TypeDescriptor = struct {
    name: []const u8,
    cases: []const ast.EnumCaseDecl,
    module_id: core.SourceModuleId,
};

pub const DeclarationIndex = struct {
    allocator: std.mem.Allocator,
    types: std.ArrayList(TypeDescriptor),
    records: std.ArrayList(RecordDescriptor),
    classes: std.ArrayList(ClassDescriptor),
    roles: std.ArrayList(RoleDescriptor),
    fields: std.ArrayList(FieldDescriptor),
    record_fields: std.ArrayList(RecordFieldDescriptor),
    record_by_name: std.StringHashMap(usize),
    class_by_name: std.StringHashMap(usize),
    role_by_name: std.StringHashMap(usize),

    pub fn init(allocator: std.mem.Allocator) DeclarationIndex {
        return .{
            .allocator = allocator,
            .types = .empty,
            .records = .empty,
            .classes = .empty,
            .roles = .empty,
            .fields = .empty,
            .record_fields = .empty,
            .record_by_name = std.StringHashMap(usize).init(allocator),
            .class_by_name = std.StringHashMap(usize).init(allocator),
            .role_by_name = std.StringHashMap(usize).init(allocator),
        };
    }

    pub fn deinit(self: *DeclarationIndex) void {
        self.types.deinit(self.allocator);
        self.records.deinit(self.allocator);
        self.classes.deinit(self.allocator);
        self.roles.deinit(self.allocator);
        self.fields.deinit(self.allocator);
        self.record_fields.deinit(self.allocator);
        self.record_by_name.deinit();
        self.class_by_name.deinit();
        self.role_by_name.deinit();
    }

    pub fn recordByName(self: *const DeclarationIndex, name: []const u8) ?RecordDescriptor {
        const index = self.record_by_name.get(name) orelse return null;
        return self.records.items[index];
    }

    pub fn recordExists(self: *const DeclarationIndex, name: []const u8) bool {
        return self.record_by_name.contains(name);
    }

    pub fn classByName(self: *const DeclarationIndex, name: []const u8) ?ClassDescriptor {
        const index = self.class_by_name.get(name) orelse return null;
        return self.classes.items[index];
    }

    pub fn roleByName(self: *const DeclarationIndex, name: []const u8) ?RoleDescriptor {
        const index = self.role_by_name.get(name) orelse return null;
        return self.roles.items[index];
    }

    pub fn classExists(self: *const DeclarationIndex, name: []const u8) bool {
        return self.class_by_name.contains(name);
    }

    pub fn classBase(self: *const DeclarationIndex, name: []const u8) ?[]const u8 {
        const class = self.classByName(name) orelse return null;
        return class.base;
    }

    pub fn roleClass(self: *const DeclarationIndex, name: []const u8) ?[]const u8 {
        const role = self.roleByName(name) orelse return null;
        return role.class_name;
    }

    pub fn typeByName(self: *const DeclarationIndex, name: []const u8) ?TypeDescriptor {
        var index = self.types.items.len;
        while (index > 0) {
            index -= 1;
            const descriptor = self.types.items[index];
            if (std.mem.eql(u8, descriptor.name, name)) return descriptor;
        }
        return null;
    }

    pub fn field(self: *const DeclarationIndex, class_name: []const u8, field_name: []const u8) ?FieldDescriptor {
        var current: ?[]const u8 = class_name;
        while (current) |name| {
            if (self.fieldInClass(name, field_name)) |descriptor| return descriptor;
            current = self.classBase(name);
        }
        return null;
    }

    pub fn fieldByName(self: *const DeclarationIndex, field_name: []const u8) ?FieldDescriptor {
        var index = self.fields.items.len;
        while (index > 0) {
            index -= 1;
            const descriptor = self.fields.items[index];
            if (std.mem.eql(u8, descriptor.name, field_name)) return descriptor;
        }
        return null;
    }

    pub fn recordField(self: *const DeclarationIndex, record_name: []const u8, field_name: []const u8) ?RecordFieldDescriptor {
        var index = self.record_fields.items.len;
        while (index > 0) {
            index -= 1;
            const descriptor = self.record_fields.items[index];
            if (!std.mem.eql(u8, descriptor.record_name, record_name)) continue;
            if (std.mem.eql(u8, descriptor.name, field_name)) return descriptor;
        }
        return null;
    }

    fn fieldInClass(self: *const DeclarationIndex, class_name: []const u8, field_name: []const u8) ?FieldDescriptor {
        var index = self.fields.items.len;
        while (index > 0) {
            index -= 1;
            const descriptor = self.fields.items[index];
            if (!std.mem.eql(u8, descriptor.class_name, class_name)) continue;
            if (std.mem.eql(u8, descriptor.name, field_name)) return descriptor;
        }
        return null;
    }
};

pub fn build(allocator: std.mem.Allocator, ir: *const core.Ir) !DeclarationIndex {
    var index = DeclarationIndex.init(allocator);
    errdefer index.deinit();

    for (ir.module_order.items) |module_id| {
        const module = ir.moduleById(module_id) orelse continue;
        try indexModule(&index, module);
    }
    return index;
}

pub fn findRoleClass(ir: *const core.Ir, role_name: []const u8) ?[]const u8 {
    var index = ir.module_order.items.len;
    while (index > 0) {
        index -= 1;
        const module = ir.moduleById(ir.module_order.items[index]) orelse continue;
        for (module.program.objects.items) |decl| {
            for (decl.roles.items) |role| {
                if (std.mem.eql(u8, role, role_name)) return decl.name;
            }
        }
        for (module.program.object_extensions.items) |extension| {
            for (extension.roles.items) |role| {
                if (std.mem.eql(u8, role, role_name)) return extension.target;
            }
        }
    }
    return null;
}

pub fn findField(ir: *const core.Ir, class_name: []const u8, field_name: []const u8) ?FieldDescriptor {
    var current: ?[]const u8 = class_name;
    while (current) |name| {
        if (findFieldInClass(ir, name, field_name)) |field| return field;
        current = findClassBase(ir, name);
    }
    return null;
}

pub fn findFieldByName(ir: *const core.Ir, field_name: []const u8) ?FieldDescriptor {
    var index = ir.module_order.items.len;
    while (index > 0) {
        index -= 1;
        const module = ir.moduleById(ir.module_order.items[index]) orelse continue;
        for (module.program.object_extensions.items) |extension| {
            for (extension.fields.items) |field| {
                if (std.mem.eql(u8, field.name, field_name)) {
                    return .{ .name = field.name, .name_span = field.name_span, .class_name = extension.target, .value_type = field.value_type, .default_value = field.default_value, .default_property_value = field.default_property_value, .module_id = module.id };
                }
            }
        }
        for (module.program.objects.items) |decl| {
            for (decl.fields.items) |field| {
                if (std.mem.eql(u8, field.name, field_name)) {
                    return .{ .name = field.name, .name_span = field.name_span, .class_name = decl.name, .value_type = field.value_type, .default_value = field.default_value, .default_property_value = field.default_property_value, .module_id = module.id };
                }
            }
        }
    }
    return null;
}

pub fn classExists(ir: *const core.Ir, class_name: []const u8) bool {
    var index = ir.module_order.items.len;
    while (index > 0) {
        index -= 1;
        const module = ir.moduleById(ir.module_order.items[index]) orelse continue;
        for (module.program.objects.items) |decl| {
            if (std.mem.eql(u8, decl.name, class_name)) return true;
        }
    }
    return false;
}

pub fn recordExists(ir: *const core.Ir, record_name: []const u8) bool {
    var index = ir.module_order.items.len;
    while (index > 0) {
        index -= 1;
        const module = ir.moduleById(ir.module_order.items[index]) orelse continue;
        for (module.program.records.items) |decl| {
            if (std.mem.eql(u8, decl.name, record_name)) return true;
        }
    }
    return false;
}

pub fn findRecord(ir: *const core.Ir, record_name: []const u8) ?RecordDescriptor {
    var index = ir.module_order.items.len;
    while (index > 0) {
        index -= 1;
        const module = ir.moduleById(ir.module_order.items[index]) orelse continue;
        for (module.program.records.items) |decl| {
            if (std.mem.eql(u8, decl.name, record_name)) return .{ .name = decl.name, .module_id = module.id };
        }
    }
    return null;
}

pub fn findRecordField(ir: *const core.Ir, record_name: []const u8, field_name: []const u8) ?RecordFieldDescriptor {
    var index = ir.module_order.items.len;
    while (index > 0) {
        index -= 1;
        const module = ir.moduleById(ir.module_order.items[index]) orelse continue;
        for (module.program.records.items) |decl| {
            if (!std.mem.eql(u8, decl.name, record_name)) continue;
            for (decl.fields.items) |field| {
                if (std.mem.eql(u8, field.name, field_name)) {
                    return .{
                        .name = field.name,
                        .name_span = field.name_span,
                        .record_name = record_name,
                        .value_type = field.value_type,
                        .default_value = field.default_value,
                        .default_property_value = field.default_property_value,
                        .module_id = module.id,
                    };
                }
            }
        }
    }
    return null;
}

pub fn findClassBase(ir: *const core.Ir, class_name: []const u8) ?[]const u8 {
    var index = ir.module_order.items.len;
    while (index > 0) {
        index -= 1;
        const module = ir.moduleById(ir.module_order.items[index]) orelse continue;
        for (module.program.objects.items) |decl| {
            if (std.mem.eql(u8, decl.name, class_name)) return decl.base;
        }
    }
    return null;
}

fn findFieldInClass(ir: *const core.Ir, class_name: []const u8, field_name: []const u8) ?FieldDescriptor {
    var index = ir.module_order.items.len;
    while (index > 0) {
        index -= 1;
        const module = ir.moduleById(ir.module_order.items[index]) orelse continue;
        for (module.program.object_extensions.items) |extension| {
            if (!std.mem.eql(u8, extension.target, class_name)) continue;
            for (extension.fields.items) |field| {
                if (std.mem.eql(u8, field.name, field_name)) {
                    return .{ .name = field.name, .name_span = field.name_span, .class_name = class_name, .value_type = field.value_type, .default_value = field.default_value, .default_property_value = field.default_property_value, .module_id = module.id };
                }
            }
        }
        for (module.program.objects.items) |decl| {
            if (!std.mem.eql(u8, decl.name, class_name)) continue;
            for (decl.fields.items) |field| {
                if (std.mem.eql(u8, field.name, field_name)) {
                    return .{ .name = field.name, .name_span = field.name_span, .class_name = class_name, .value_type = field.value_type, .default_value = field.default_value, .default_property_value = field.default_property_value, .module_id = module.id };
                }
            }
        }
    }
    return null;
}

fn indexModule(index: *DeclarationIndex, module: *const core.SourceModule) !void {
    for (module.program.types.items) |decl| {
        try index.types.append(index.allocator, .{
            .name = decl.name,
            .cases = decl.cases.items,
            .module_id = module.id,
        });
    }

    for (module.program.records.items) |decl| {
        const record_index = index.records.items.len;
        try index.records.append(index.allocator, .{
            .name = decl.name,
            .module_id = module.id,
        });
        try index.record_by_name.put(decl.name, record_index);
        try appendRecordFields(index, module.id, decl.name, decl.fields.items);
    }

    for (module.program.objects.items) |decl| {
        const class_index = index.classes.items.len;
        try index.classes.append(index.allocator, .{
            .name = decl.name,
            .base = decl.base,
            .module_id = module.id,
        });
        try index.class_by_name.put(decl.name, class_index);
        try appendRoles(index, module.id, decl.name, decl.roles.items);
        try appendFields(index, module.id, decl.name, decl.fields.items);
    }

    for (module.program.object_extensions.items) |extension| {
        try appendRoles(index, module.id, extension.target, extension.roles.items);
        try appendFields(index, module.id, extension.target, extension.fields.items);
    }
}

fn appendRecordFields(index: *DeclarationIndex, module_id: core.SourceModuleId, record_name: []const u8, fields: []const ast.ObjectFieldDecl) !void {
    for (fields) |field| {
        try index.record_fields.append(index.allocator, .{
            .name = field.name,
            .name_span = field.name_span,
            .record_name = record_name,
            .value_type = field.value_type,
            .default_value = field.default_value,
            .default_property_value = field.default_property_value,
            .module_id = module_id,
        });
    }
}

fn appendRoles(index: *DeclarationIndex, module_id: core.SourceModuleId, class_name: []const u8, roles: []const []const u8) !void {
    for (roles) |role| {
        const role_index = index.roles.items.len;
        try index.roles.append(index.allocator, .{
            .name = role,
            .class_name = class_name,
            .module_id = module_id,
        });
        try index.role_by_name.put(role, role_index);
    }
}

fn appendFields(index: *DeclarationIndex, module_id: core.SourceModuleId, class_name: []const u8, fields: []const ast.ObjectFieldDecl) !void {
    for (fields) |field| {
        try index.fields.append(index.allocator, .{
            .name = field.name,
            .name_span = field.name_span,
            .class_name = class_name,
            .value_type = field.value_type,
            .default_value = field.default_value,
            .default_property_value = field.default_property_value,
            .module_id = module_id,
        });
    }
}
