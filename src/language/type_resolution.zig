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

fn builtinType(name: []const u8) ?ast.Type {
    if (std.mem.eql(u8, name, "Document")) return ast.Type.document;
    if (std.mem.eql(u8, name, "Page")) return ast.Type.page;
    if (std.mem.eql(u8, name, "Object")) return ast.Type.object;
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
