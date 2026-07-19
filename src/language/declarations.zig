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

const MemberKey = struct {
    owner: []const u8,
    member: []const u8,
};

const MemberKeyContext = struct {
    pub fn hash(_: MemberKeyContext, key: MemberKey) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(key.owner);
        hasher.update(&.{0});
        hasher.update(key.member);
        return hasher.final();
    }

    pub fn eql(_: MemberKeyContext, left: MemberKey, right: MemberKey) bool {
        return std.mem.eql(u8, left.owner, right.owner) and std.mem.eql(u8, left.member, right.member);
    }
};

const MemberMap = std.HashMap(MemberKey, usize, MemberKeyContext, std.hash_map.default_max_load_percentage);

const ModuleNameKey = struct {
    module_id: core.SourceModuleId,
    name: []const u8,
};

const ModuleNameKeyContext = struct {
    pub fn hash(_: ModuleNameKeyContext, key: ModuleNameKey) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(std.mem.asBytes(&key.module_id));
        hasher.update(key.name);
        return hasher.final();
    }

    pub fn eql(_: ModuleNameKeyContext, left: ModuleNameKey, right: ModuleNameKey) bool {
        return left.module_id == right.module_id and std.mem.eql(u8, left.name, right.name);
    }
};

const ModuleNameMap = std.HashMap(ModuleNameKey, usize, ModuleNameKeyContext, std.hash_map.default_max_load_percentage);

pub const DeclarationIndex = struct {
    allocator: std.mem.Allocator,
    types: std.ArrayList(TypeDescriptor),
    records: std.ArrayList(RecordDescriptor),
    classes: std.ArrayList(ClassDescriptor),
    roles: std.ArrayList(RoleDescriptor),
    fields: std.ArrayList(FieldDescriptor),
    record_fields: std.ArrayList(RecordFieldDescriptor),
    type_by_name: std.StringHashMap(usize),
    type_by_module: ModuleNameMap,
    record_by_name: std.StringHashMap(usize),
    class_by_name: std.StringHashMap(usize),
    role_by_name: std.StringHashMap(usize),
    field_by_name: std.StringHashMap(usize),
    field_by_class: MemberMap,
    record_field_by_record: MemberMap,

    pub fn init(allocator: std.mem.Allocator) DeclarationIndex {
        return .{
            .allocator = allocator,
            .types = .empty,
            .records = .empty,
            .classes = .empty,
            .roles = .empty,
            .fields = .empty,
            .record_fields = .empty,
            .type_by_name = std.StringHashMap(usize).init(allocator),
            .type_by_module = ModuleNameMap.init(allocator),
            .record_by_name = std.StringHashMap(usize).init(allocator),
            .class_by_name = std.StringHashMap(usize).init(allocator),
            .role_by_name = std.StringHashMap(usize).init(allocator),
            .field_by_name = std.StringHashMap(usize).init(allocator),
            .field_by_class = MemberMap.init(allocator),
            .record_field_by_record = MemberMap.init(allocator),
        };
    }

    pub fn deinit(self: *DeclarationIndex) void {
        self.types.deinit(self.allocator);
        self.records.deinit(self.allocator);
        self.classes.deinit(self.allocator);
        self.roles.deinit(self.allocator);
        self.fields.deinit(self.allocator);
        self.record_fields.deinit(self.allocator);
        self.type_by_name.deinit();
        self.type_by_module.deinit();
        self.record_by_name.deinit();
        self.class_by_name.deinit();
        self.role_by_name.deinit();
        self.field_by_name.deinit();
        self.field_by_class.deinit();
        self.record_field_by_record.deinit();
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
        const index = self.type_by_name.get(name) orelse return null;
        return self.types.items[index];
    }

    pub fn typeInModule(self: *const DeclarationIndex, module_id: core.SourceModuleId, name: []const u8) ?TypeDescriptor {
        const index = self.type_by_module.get(.{ .module_id = module_id, .name = name }) orelse return null;
        return self.types.items[index];
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
        const index = self.field_by_name.get(field_name) orelse return null;
        return self.fields.items[index];
    }

    pub fn recordField(self: *const DeclarationIndex, record_name: []const u8, field_name: []const u8) ?RecordFieldDescriptor {
        const index = self.record_field_by_record.get(.{ .owner = record_name, .member = field_name }) orelse return null;
        return self.record_fields.items[index];
    }

    fn fieldInClass(self: *const DeclarationIndex, class_name: []const u8, field_name: []const u8) ?FieldDescriptor {
        const index = self.field_by_class.get(.{ .owner = class_name, .member = field_name }) orelse return null;
        return self.fields.items[index];
    }
};

pub fn build(allocator: std.mem.Allocator, state: *const core.DocumentState) !DeclarationIndex {
    var index = DeclarationIndex.init(allocator);
    errdefer index.deinit();

    for (state.module_order.items) |module_id| {
        const module = state.moduleById(module_id) orelse continue;
        try indexModule(&index, module);
    }
    return index;
}

fn indexModule(index: *DeclarationIndex, module: *const core.SourceModule) !void {
    for (module.syntax.types.items) |decl| {
        const type_index = index.types.items.len;
        try index.types.append(index.allocator, .{
            .name = decl.name,
            .cases = decl.cases.items,
            .module_id = module.id,
        });
        try index.type_by_name.put(decl.name, type_index);
        try index.type_by_module.put(.{ .module_id = module.id, .name = decl.name }, type_index);
    }

    for (module.syntax.records.items) |decl| {
        const record_index = index.records.items.len;
        try index.records.append(index.allocator, .{
            .name = decl.name,
            .module_id = module.id,
        });
        try index.record_by_name.put(decl.name, record_index);
        try appendRecordFields(index, module.id, decl.name, decl.fields.items);
    }

    for (module.syntax.objects.items) |decl| {
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

    for (module.syntax.object_extensions.items) |extension| {
        try appendRoles(index, module.id, extension.target, extension.roles.items);
        try appendFields(index, module.id, extension.target, extension.fields.items);
    }
}

fn appendRecordFields(index: *DeclarationIndex, module_id: core.SourceModuleId, record_name: []const u8, fields: []const ast.ObjectFieldDecl) !void {
    for (fields) |field| {
        const field_index = index.record_fields.items.len;
        try index.record_fields.append(index.allocator, .{
            .name = field.name,
            .name_span = field.name_span,
            .record_name = record_name,
            .value_type = field.value_type,
            .default_value = field.default_value,
            .default_property_value = field.default_property_value,
            .module_id = module_id,
        });
        try index.record_field_by_record.put(.{ .owner = record_name, .member = field.name }, field_index);
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
        const field_index = index.fields.items.len;
        try index.fields.append(index.allocator, .{
            .name = field.name,
            .name_span = field.name_span,
            .class_name = class_name,
            .value_type = field.value_type,
            .default_value = field.default_value,
            .default_property_value = field.default_property_value,
            .module_id = module_id,
        });
        try index.field_by_name.put(field.name, field_index);
        try index.field_by_class.put(.{ .owner = class_name, .member = field.name }, field_index);
    }
}
