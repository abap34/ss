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
    args: []const ast.AnnotationArg,
    module_id: core.SourceModuleId,
};

pub const HostCapabilityDescriptor = struct {
    function_name: []const u8,
    annotation_name: []const u8,
    args: []const ast.AnnotationArg,
    effects_text: ?[]const u8 = null,
    effects: ?core.EffectSet = null,
    cache: ?ast.AnnotationValue = null,
    module_id: core.SourceModuleId,
};

pub const RenderOpDescriptor = struct {
    function_name: []const u8,
    annotation_name: []const u8,
    args: []const ast.AnnotationArg,
    effects_text: ?[]const u8 = null,
    effects: ?core.EffectSet = null,
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
    host_capabilities: std.ArrayList(HostCapabilityDescriptor),
    render_ops: std.ArrayList(RenderOpDescriptor),
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
            .host_capabilities = .empty,
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
        self.host_capabilities.deinit(self.allocator);
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
                    return .{ .name = field.name, .class_name = extension.target, .value_type = field.value_type, .default_value = field.default_value, .module_id = module.id };
                }
            }
        }
        for (module.program.objects.items) |decl| {
            for (decl.fields.items) |field| {
                if (std.mem.eql(u8, field.name, field_name)) {
                    return .{ .name = field.name, .class_name = decl.name, .value_type = field.value_type, .default_value = field.default_value, .module_id = module.id };
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
                    return .{ .name = field.name, .class_name = class_name, .value_type = field.value_type, .default_value = field.default_value, .module_id = module.id };
                }
            }
        }
        for (module.program.objects.items) |decl| {
            if (!std.mem.eql(u8, decl.name, class_name)) continue;
            for (decl.fields.items) |field| {
                if (std.mem.eql(u8, field.name, field_name)) {
                    return .{ .name = field.name, .class_name = class_name, .value_type = field.value_type, .default_value = field.default_value, .module_id = module.id };
                }
            }
        }
    }
    return null;
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
                .args = annotation.args.items,
                .module_id = module.id,
            };
            try index.function_annotations.append(index.allocator, descriptor);
            if (std.mem.eql(u8, annotation.name, "host")) {
                const effects_text = func.effects orelse annotationArgValue(annotation.args.items, "effects");
                try index.host_capabilities.append(index.allocator, .{
                    .function_name = func.name,
                    .annotation_name = annotation.name,
                    .args = annotation.args.items,
                    .effects_text = effects_text,
                    .effects = parseEffectSetMaybe(effects_text),
                    .cache = annotationNamedValue(annotation.args.items, "cache"),
                    .module_id = module.id,
                });
            } else if (std.mem.eql(u8, annotation.name, "op")) {
                try index.render_ops.append(index.allocator, .{
                    .function_name = func.name,
                    .annotation_name = annotation.name,
                    .args = annotation.args.items,
                    .effects_text = func.effects,
                    .effects = parseEffectSetMaybe(func.effects),
                    .module_id = module.id,
                });
            }
        }
    }
}

fn annotationArgValue(args: []const ast.AnnotationArg, key: []const u8) ?[]const u8 {
    for (args) |arg| {
        switch (arg) {
            .named => |named| {
                if (std.mem.eql(u8, named.name, key)) return annotationValueScalar(named.value);
            },
            else => {},
        }
    }
    return null;
}

pub fn annotationPositionalArg(args: []const ast.AnnotationArg, ordinal: usize) ?[]const u8 {
    var position: usize = 0;
    for (args) |arg| {
        switch (arg) {
            .positional => |value| {
                if (position == ordinal) return annotationValueScalar(value);
                position += 1;
            },
            else => {},
        }
    }
    return null;
}

pub fn parseEffectSet(text: []const u8) !core.EffectSet {
    var set = core.EffectSet.empty();
    var index: usize = 0;
    while (index < text.len) {
        while (index < text.len and (std.ascii.isWhitespace(text[index]) or text[index] == '|' or text[index] == ',' or text[index] == '[' or text[index] == ']')) : (index += 1) {}
        const start = index;
        while (index < text.len and (std.ascii.isAlphanumeric(text[index]) or text[index] == '_')) : (index += 1) {}
        if (start == index) {
            if (index < text.len) index += 1;
            continue;
        }
        const effect = parseEffectName(text[start..index]) orelse return error.UnknownEffect;
        set.insert(effect);
    }
    if (set.isEmpty()) return error.UnknownEffect;
    return set;
}

fn parseEffectSetMaybe(text: ?[]const u8) ?core.EffectSet {
    const effect_text = text orelse return null;
    return parseEffectSet(effect_text) catch null;
}

pub fn parseEffectName(name: []const u8) ?core.Effect {
    inline for (@typeInfo(core.Effect).@"enum".fields) |field| {
        if (std.mem.eql(u8, name, field.name)) return @enumFromInt(field.value);
    }
    return null;
}

fn annotationNamedValue(args: []const ast.AnnotationArg, key: []const u8) ?ast.AnnotationValue {
    for (args) |arg| {
        switch (arg) {
            .named => |named| {
                if (std.mem.eql(u8, named.name, key)) return named.value;
            },
            else => {},
        }
    }
    return null;
}

fn annotationValueScalar(value: ast.AnnotationValue) ?[]const u8 {
    return switch (value) {
        .ident, .string => |text| text,
        .expr => null,
        .list => null,
    };
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
            .class_name = class_name,
            .value_type = field.value_type,
            .default_value = field.default_value,
            .module_id = module_id,
        });
    }
}
