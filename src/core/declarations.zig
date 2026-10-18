const std = @import("std");
const ast = @import("ast");
const model = @import("model");

pub const ClassDescriptor = struct {
    name: []const u8,
    base: ?model.NominalId,
    module_id: u32,
    span: ast.Span = .{ .start = 0, .end = 0 },
};

pub const RoleDescriptor = struct {
    name: []const u8,
    class_name: []const u8,
    class_module_id: u32,
    module_id: u32,
};

pub const FieldDescriptor = struct {
    name: []const u8,
    name_span: ?ast.Span = null,
    class_name: []const u8,
    class_module_id: u32,
    value_type: ast.Type,
    default_value: ?*const ast.Expr,
    default_property_value: ?[]const u8,
    module_id: u32,
};

pub const RecordDescriptor = struct {
    decl: *const ast.RecordDecl,
    name: []const u8,
    module_id: u32,
};

pub const DisplayDescriptor = struct {
    decl: *const ast.FunctionDecl,
    module_id: u32,
};

pub const RecordFieldDescriptor = struct {
    name: []const u8,
    name_span: ?ast.Span = null,
    record_name: []const u8,
    value_type: ast.Type,
    default_value: ?*const ast.Expr,
    default_property_value: ?[]const u8,
    module_id: u32,
};

pub const TypeDescriptor = struct {
    name: []const u8,
    cases: []const ast.EnumCaseDecl,
    module_id: u32,
};

const MemberKey = struct {
    module_id: u32 = 0,
    owner: []const u8,
    member: []const u8,
};

const MemberKeyContext = struct {
    pub fn hash(_: MemberKeyContext, key: MemberKey) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(std.mem.asBytes(&key.module_id));
        hasher.update(key.owner);
        hasher.update(&.{0});
        hasher.update(key.member);
        return hasher.final();
    }

    pub fn eql(_: MemberKeyContext, left: MemberKey, right: MemberKey) bool {
        return left.module_id == right.module_id and std.mem.eql(u8, left.owner, right.owner) and std.mem.eql(u8, left.member, right.member);
    }
};

const MemberMap = std.HashMap(MemberKey, usize, MemberKeyContext, std.hash_map.default_max_load_percentage);

const ModuleNameKey = model.NominalId;

const ModuleNameKeyContext = struct {
    pub fn hash(_: ModuleNameKeyContext, key: ModuleNameKey) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(std.mem.asBytes(&key.module_id));
        hasher.update(key.name);
        return hasher.final();
    }

    pub fn eql(_: ModuleNameKeyContext, left: ModuleNameKey, right: ModuleNameKey) bool {
        return left.eql(right);
    }
};

const ModuleNameMap = std.HashMap(ModuleNameKey, usize, ModuleNameKeyContext, std.hash_map.default_max_load_percentage);
const DisplayMap = std.HashMap(ModuleNameKey, DisplayDescriptor, ModuleNameKeyContext, std.hash_map.default_max_load_percentage);

pub const DeclarationIndex = struct {
    settings_module_id: ?u32 = null,
    allocator: std.mem.Allocator,
    types: std.ArrayList(TypeDescriptor),
    records: std.ArrayList(RecordDescriptor),
    classes: std.ArrayList(ClassDescriptor),
    roles: std.ArrayList(RoleDescriptor),
    fields: std.ArrayList(FieldDescriptor),
    record_fields: std.ArrayList(RecordFieldDescriptor),
    type_by_module: ModuleNameMap,
    record_by_module: ModuleNameMap,
    display_by_type: DisplayMap,
    class_by_module: ModuleNameMap,
    role_by_name: std.StringHashMap(usize),
    field_by_name: std.StringHashMap(?usize),
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
            .type_by_module = ModuleNameMap.init(allocator),
            .record_by_module = ModuleNameMap.init(allocator),
            .display_by_type = DisplayMap.init(allocator),
            .class_by_module = ModuleNameMap.init(allocator),
            .role_by_name = std.StringHashMap(usize).init(allocator),
            .field_by_name = std.StringHashMap(?usize).init(allocator),
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
        self.type_by_module.deinit();
        self.record_by_module.deinit();
        self.display_by_type.deinit();
        self.class_by_module.deinit();
        self.role_by_name.deinit();
        self.field_by_name.deinit();
        self.field_by_class.deinit();
        self.record_field_by_record.deinit();
    }

    pub fn record(self: *const DeclarationIndex, id: model.NominalId) ?RecordDescriptor {
        const index = self.record_by_module.get(.{ .module_id = id.module_id, .name = id.name }) orelse return null;
        return self.records.items[index];
    }

    pub fn display(self: *const DeclarationIndex, id: model.NominalId) ?DisplayDescriptor {
        return self.display_by_type.get(id);
    }

    pub fn classInModule(self: *const DeclarationIndex, module_id: u32, name: []const u8) ?ClassDescriptor {
        const index = self.class_by_module.get(.{ .module_id = module_id, .name = name }) orelse return null;
        return self.classes.items[index];
    }

    pub fn classById(self: *const DeclarationIndex, id: model.NominalId) ?ClassDescriptor {
        const index = self.class_by_module.get(id) orelse return null;
        return self.classes.items[index];
    }

    pub fn roleByName(self: *const DeclarationIndex, name: []const u8) ?RoleDescriptor {
        const index = self.role_by_name.get(name) orelse return null;
        return self.roles.items[index];
    }

    pub fn classBase(self: *const DeclarationIndex, id: model.NominalId) ?model.NominalId {
        const class = self.classById(id) orelse return null;
        return class.base;
    }

    pub fn roleClass(self: *const DeclarationIndex, name: []const u8) ?model.NominalId {
        const role = self.roleByName(name) orelse return null;
        return .{ .module_id = role.class_module_id, .name = role.class_name };
    }

    pub fn typeInModule(self: *const DeclarationIndex, module_id: u32, name: []const u8) ?TypeDescriptor {
        const index = self.type_by_module.get(.{ .module_id = module_id, .name = name }) orelse return null;
        return self.types.items[index];
    }

    pub fn field(self: *const DeclarationIndex, class_id: model.NominalId, field_name: []const u8) ?FieldDescriptor {
        var current: ?model.NominalId = class_id;
        var remaining_bases = self.classes.items.len;
        while (current) |name| {
            if (self.fieldInClass(name, field_name)) |descriptor| return descriptor;
            if (remaining_bases == 0) return null;
            remaining_bases -= 1;
            current = self.classBase(name);
        }
        return null;
    }

    pub fn fieldByName(self: *const DeclarationIndex, field_name: []const u8) ?FieldDescriptor {
        const index = (self.field_by_name.get(field_name) orelse return null) orelse return null;
        return self.fields.items[index];
    }

    pub fn recordField(self: *const DeclarationIndex, id: model.NominalId, field_name: []const u8) ?RecordFieldDescriptor {
        const index = self.record_field_by_record.get(.{ .module_id = id.module_id, .owner = id.name, .member = field_name }) orelse return null;
        return self.record_fields.items[index];
    }

    pub fn settingsField(self: *const DeclarationIndex, field_name: []const u8) ?RecordFieldDescriptor {
        const module_id = self.settings_module_id orelse return null;
        return self.recordField(.{ .module_id = module_id, .name = "PageSettings" }, field_name);
    }

    fn fieldInClass(self: *const DeclarationIndex, class_id: model.NominalId, field_name: []const u8) ?FieldDescriptor {
        const index = self.field_by_class.get(.{ .module_id = class_id.module_id, .owner = class_id.name, .member = field_name }) orelse return null;
        return self.fields.items[index];
    }
};

pub fn build(allocator: std.mem.Allocator, state: anytype) !DeclarationIndex {
    var index = DeclarationIndex.init(allocator);
    errdefer index.deinit();

    if (state.modules.order.items.len == 0) {
        for (state.modules.entries.items) |*module| try indexModule(&index, module);
    } else {
        for (state.modules.order.items) |module_id| {
            const module = state.moduleById(module_id) orelse continue;
            try indexModule(&index, module);
        }
    }
    var fields = index.field_by_class.valueIterator();
    while (fields.next()) |field_index| {
        const field = index.fields.items[field_index.*];
        const entry = try index.field_by_name.getOrPut(field.name);
        if (!entry.found_existing) {
            entry.value_ptr.* = field_index.*;
        } else if (entry.value_ptr.*) |previous| {
            if (!ast.Type.eql(index.fields.items[previous].value_type, field.value_type)) entry.value_ptr.* = null;
        }
    }
    return index;
}

fn indexModule(index: *DeclarationIndex, module: anytype) !void {
    if (std.mem.eql(u8, module.spec, "std:document/settings")) index.settings_module_id = module.id;
    for (module.syntax.functions.items) |*function| {
        if (!function.isDisplay() or function.params.items.len != 1) continue;
        const input = function.params.items[0].ty.placedInput() orelse continue;
        if (input.kind != .record) continue;
        const id = input.nominalId() orelse continue;
        if (id.module_id != module.id) continue;
        // Invalid or duplicate signatures are diagnosed by static semantics.
        // Keep the first declaration deterministic even in an invalid snapshot.
        const entry = try index.display_by_type.getOrPut(id);
        if (!entry.found_existing) entry.value_ptr.* = .{ .decl = function, .module_id = module.id };
    }
    for (module.syntax.types.items) |decl| {
        const type_index = index.types.items.len;
        try index.types.append(index.allocator, .{
            .name = decl.name,
            .cases = decl.cases.items,
            .module_id = module.id,
        });
        try index.type_by_module.put(.{ .module_id = module.id, .name = decl.name }, type_index);
    }

    for (module.syntax.records.items) |*decl| {
        const record_index = index.records.items.len;
        try index.records.append(index.allocator, .{
            .decl = decl,
            .name = decl.name,
            .module_id = module.id,
        });
        try index.record_by_module.put(.{ .module_id = module.id, .name = decl.name }, record_index);
        try appendRecordFields(index, module.id, decl.name, decl.fields.items);
    }
}

fn appendRecordFields(index: *DeclarationIndex, module_id: u32, record_name: []const u8, fields: []const ast.FieldDecl) !void {
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
        try index.record_field_by_record.put(.{ .module_id = module_id, .owner = record_name, .member = field.name }, field_index);
    }
}

fn appendRoles(index: *DeclarationIndex, module_id: u32, class_id: model.NominalId, roles: []const []const u8) !void {
    for (roles) |role| {
        const role_index = index.roles.items.len;
        try index.roles.append(index.allocator, .{
            .name = role,
            .class_name = class_id.name,
            .class_module_id = class_id.module_id,
            .module_id = module_id,
        });
        try index.role_by_name.put(role, role_index);
    }
}

fn appendFields(index: *DeclarationIndex, module_id: u32, class_id: model.NominalId, fields: []const ast.FieldDecl) !void {
    for (fields) |field| {
        const field_index = index.fields.items.len;
        try index.fields.append(index.allocator, .{
            .name = field.name,
            .name_span = field.name_span,
            .class_name = class_id.name,
            .class_module_id = class_id.module_id,
            .value_type = field.value_type,
            .default_value = field.default_value,
            .default_property_value = field.default_property_value,
            .module_id = module_id,
        });
        try index.field_by_class.put(.{ .module_id = class_id.module_id, .owner = class_id.name, .member = field.name }, field_index);
    }
}

fn localName(name: []const u8) []const u8 {
    const separator = std.mem.lastIndexOf(u8, name, "::") orelse return name;
    return name[separator + 2 ..];
}
