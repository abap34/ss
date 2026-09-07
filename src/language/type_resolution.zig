const std = @import("std");
const ast = @import("ast");
const core = @import("core");
const name_resolution = @import("name_resolution.zig");

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
    .{ .name = "Path", .ty = ast.Type.path },
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
    if (name.qualifier == null) {
        if (builtinType(name.name)) |ty| return .{ .found = .{ .kind = .builtin, .ty = ty, .target = null } };
    }
    return switch (name_resolution.resolve(Binding(Target), resolver, current_module_id, .{
        .qualifier = name.qualifier,
        .name = name.name,
    })) {
        .found => |binding| .{ .found = binding },
        .unknown => .unknown,
        .unknown_alias => |alias| .{ .unknown_alias = alias },
    };
}

pub fn resolveUnqualified(
    comptime Target: type,
    resolver: anytype,
    module_id: core.SourceModuleId,
    name: []const u8,
) Resolution(Target) {
    return resolve(Target, resolver, module_id, .{ .name = name });
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
