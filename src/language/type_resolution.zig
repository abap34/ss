const std = @import("std");
const ast = @import("ast");
const core = @import("core");

pub const TypeName = struct {
    qualifier: ?[]const u8 = null,
    name: []const u8,
};

pub const BindingKind = enum {
    builtin,
    record,
    object,
    enum_type,
};

pub const BuiltinType = struct {
    name: []const u8,
    ty: ast.Type,
};

const builtin_types = [_]BuiltinType{
    .{ .name = "Document", .ty = ast.Type.document },
    .{ .name = "Page", .ty = ast.Type.page },
    .{ .name = "Object", .ty = ast.Type.object },
    .{ .name = "Anchor", .ty = ast.Type.anchor },
    .{ .name = "String", .ty = ast.Type.string },
    .{ .name = "Color", .ty = ast.Type.color },
    .{ .name = "Number", .ty = ast.Type.number },
    .{ .name = "Bool", .ty = ast.Type.boolean },
    .{ .name = "Constraints", .ty = ast.Type.constraints },
    .{ .name = "Void", .ty = .{ .kind = .void } },
    .{ .name = "None", .ty = ast.Type.none },
    .{ .name = "Selection", .ty = ast.Type.selection(.any) },
};

pub fn Binding(comptime Target: type) type {
    return struct {
        kind: BindingKind,
        ty: ast.Type,
        target: ?Target,
    };
}

pub fn Resolution(comptime Target: type) type {
    return union(enum) {
        found: Binding(Target),
        unknown,
        unknown_alias: []const u8,
    };
}

pub fn resolveText(
    comptime Target: type,
    resolver: anytype,
    current_module_id: core.SourceModuleId,
    text: []const u8,
) Resolution(Target) {
    return resolve(Target, resolver, current_module_id, parse(text));
}

pub fn resolve(
    comptime Target: type,
    resolver: anytype,
    current_module_id: core.SourceModuleId,
    name: TypeName,
) Resolution(Target) {
    if (name.qualifier) |alias| {
        const module_id = resolver.resolveAlias(current_module_id, alias) orelse return .{ .unknown_alias = alias };
        return resolveUnqualified(Target, resolver, module_id, name.name);
    }
    return resolveUnqualified(Target, resolver, current_module_id, name.name);
}

pub fn resolveUnqualified(
    comptime Target: type,
    resolver: anytype,
    module_id: core.SourceModuleId,
    name: []const u8,
) Resolution(Target) {
    if (builtinType(name)) |ty| return .{ .found = .{
        .kind = .builtin,
        .ty = ty,
        .target = null,
    } };
    if (resolver.findRecord(name)) |target| return .{ .found = .{
        .kind = .record,
        .ty = ast.Type.recordType(name),
        .target = target,
    } };
    if (resolver.findObject(name)) |target| return .{ .found = .{
        .kind = .object,
        .ty = ast.Type.objectClass(name),
        .target = target,
    } };
    if (resolver.findEnum(module_id, name)) |target| return .{ .found = .{
        .kind = .enum_type,
        .ty = ast.Type.enumType(name),
        .target = target,
    } };
    return .unknown;
}

pub fn parse(text: []const u8) TypeName {
    const delimiter = std.mem.indexOf(u8, text, "::") orelse return .{ .name = text };
    return .{
        .qualifier = text[0..delimiter],
        .name = text[delimiter + 2 ..],
    };
}

pub fn isBuiltinTypeName(name: []const u8) bool {
    return builtinType(name) != null;
}

pub fn builtinTypes() []const BuiltinType {
    return builtin_types[0..];
}

fn builtinType(name: []const u8) ?ast.Type {
    for (builtinTypes()) |builtin| {
        if (std.mem.eql(u8, name, builtin.name)) return builtin.ty;
    }
    return null;
}
