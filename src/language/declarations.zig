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
    class_name: []const u8,
    value_type: []const u8,
    default_value: ?[]const u8,
    module_id: core.SourceModuleId,
};

pub const FunctionAnnotationDescriptor = struct {
    function_name: []const u8,
    annotation_name: []const u8,
    args: ?[]const u8,
    module_id: core.SourceModuleId,
};

pub const CapabilityDescriptor = struct {
    function_name: []const u8,
    annotation_name: []const u8,
    args: ?[]const u8,
    module_id: core.SourceModuleId,
};

pub const ValueDomainDescriptor = struct {
    name: []const u8,
    body: []const u8,
    refinement: ?[]const u8,
    module_id: core.SourceModuleId,
};

pub const DeclarationIndex = struct {
    allocator: std.mem.Allocator,
    value_domains: std.ArrayList(ValueDomainDescriptor),
    classes: std.ArrayList(ClassDescriptor),
    roles: std.ArrayList(RoleDescriptor),
    fields: std.ArrayList(FieldDescriptor),
    function_annotations: std.ArrayList(FunctionAnnotationDescriptor),
    capabilities: std.ArrayList(CapabilityDescriptor),
    render_ops: std.ArrayList(CapabilityDescriptor),
    class_by_name: std.StringHashMap(usize),
    role_by_name: std.StringHashMap(usize),

    pub fn init(allocator: std.mem.Allocator) DeclarationIndex {
        return .{
            .allocator = allocator,
            .value_domains = .empty,
            .classes = .empty,
            .roles = .empty,
            .fields = .empty,
            .function_annotations = .empty,
            .capabilities = .empty,
            .render_ops = .empty,
            .class_by_name = std.StringHashMap(usize).init(allocator),
            .role_by_name = std.StringHashMap(usize).init(allocator),
        };
    }

    pub fn deinit(self: *DeclarationIndex) void {
        self.value_domains.deinit(self.allocator);
        self.classes.deinit(self.allocator);
        self.roles.deinit(self.allocator);
        self.fields.deinit(self.allocator);
        self.function_annotations.deinit(self.allocator);
        self.capabilities.deinit(self.allocator);
        self.render_ops.deinit(self.allocator);
        self.class_by_name.deinit();
        self.role_by_name.deinit();
    }

    pub fn classByName(self: *const DeclarationIndex, name: []const u8) ?ClassDescriptor {
        const index = self.class_by_name.get(name) orelse return null;
        return self.classes.items[index];
    }

    pub fn roleByName(self: *const DeclarationIndex, name: []const u8) ?RoleDescriptor {
        const index = self.role_by_name.get(name) orelse return null;
        return self.roles.items[index];
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

fn indexModule(index: *DeclarationIndex, module: *const core.SourceModule) !void {
    for (module.program.types.items) |decl| {
        try index.value_domains.append(index.allocator, .{
            .name = decl.name,
            .body = decl.body,
            .refinement = decl.refinement,
            .module_id = module.id,
        });
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

    for (module.program.functions.items) |func| {
        for (func.annotations.items) |annotation| {
            const descriptor = FunctionAnnotationDescriptor{
                .function_name = func.name,
                .annotation_name = annotation.name,
                .args = annotation.args,
                .module_id = module.id,
            };
            try index.function_annotations.append(index.allocator, descriptor);
            if (std.mem.eql(u8, annotation.name, "host")) {
                try index.capabilities.append(index.allocator, .{
                    .function_name = func.name,
                    .annotation_name = annotation.name,
                    .args = annotation.args,
                    .module_id = module.id,
                });
            } else if (std.mem.eql(u8, annotation.name, "op")) {
                try index.render_ops.append(index.allocator, .{
                    .function_name = func.name,
                    .annotation_name = annotation.name,
                    .args = annotation.args,
                    .module_id = module.id,
                });
            }
        }
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
        if (!index.role_by_name.contains(role)) try index.role_by_name.put(role, role_index);
    }
}

fn appendFields(index: *DeclarationIndex, module_id: core.SourceModuleId, class_name: []const u8, fields: []const ast.ObjectFieldDecl) !void {
    for (fields) |field| {
        try index.fields.append(index.allocator, .{
            .name = field.name,
            .class_name = class_name,
            .value_type = field.value_type,
            .default_value = field.default_value,
            .module_id = module_id,
        });
    }
}
