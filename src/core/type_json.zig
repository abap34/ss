const std = @import("std");
const Type = @import("language_type").Type;
const json = @import("utils").json;

/// Serializes semantic type structure, excluding source locations and ownership.
pub fn append(allocator: std.mem.Allocator, out: *std.ArrayList(u8), ty: Type) anyerror!void {
    var object = try json.Object.beginBuffer(allocator, out);
    try write(&object, ty);
    try object.end();
}

/// Writes into an existing JSON object so diagnostics can reuse the type format.
pub fn write(object: *json.Object, ty: Type) anyerror!void {
    if (ty.kind == .parameter or ty.kind == .hole) return error.InvalidValueTag;
    try object.enumTagField("kind", ty.kind);
    if (ty.class_name orelse ty.enum_name) |name| try object.stringField("name", name);
    if (ty.nominal_module_id) |id| try object.intField("module", id);
    if (ty.arguments.len != 0) try writeTypes(object, "arguments", ty.arguments);
    if (ty.optional_child) |child| try writeField(object, "child", child.*);
    if (ty.kind == .function) {
        try writeTypes(object, "parameters", ty.fn_params);
        try writeField(object, "result", (ty.fn_result orelse return error.InvalidValueTag).*);
    }
}

pub fn writeField(object: *json.Object, key: []const u8, ty: Type) !void {
    var field = try object.objectField(key);
    try write(&field, ty);
    try field.end();
}

fn writeTypes(object: *json.Object, key: []const u8, types: []const Type) !void {
    var array = try object.arrayField(key);
    for (types) |ty| {
        var item = try array.objectItem();
        try write(&item, ty);
        try item.end();
    }
    try array.end();
}

/// The returned type owns both its structure and all nominal-name strings.
pub fn parse(allocator: std.mem.Allocator, value: json.Value) anyerror!Type {
    if (value != .object) return error.InvalidValueTag;
    const object = &value.object;
    const tag = json.stringField(object, "kind") orelse return error.InvalidValueTag;
    const kind = std.meta.stringToEnum(Type.Kind, tag) orelse return error.InvalidValueTag;
    if (kind == .parameter or kind == .hole) return error.InvalidValueTag;
    var ty = Type{ .kind = kind };
    errdefer deinit(allocator, &ty);
    if (json.fieldValue(object, "name")) |name_value| {
        if (name_value.* != .string or name_value.string.len == 0) return error.InvalidValueTag;
        const name = name_value.string;
        switch (kind) {
            .record, .object => ty.class_name = try allocator.dupe(u8, name),
            .enum_type => ty.enum_name = try allocator.dupe(u8, name),
            else => return error.InvalidValueTag,
        }
    } else if (kind == .record or kind == .enum_type) return error.InvalidValueTag;
    if (json.fieldValue(object, "module")) |module| {
        if (module.* != .integer or module.integer < 0 or module.integer > std.math.maxInt(u32)) return error.InvalidValueTag;
        if (ty.class_name == null and ty.enum_name == null) return error.InvalidValueTag;
        ty.nominal_module_id = @intCast(module.integer);
    }
    if (json.fieldValue(object, "arguments")) |arguments| {
        if (kind != .record and kind != .group and kind != .selection and kind != .placed and kind != .object) return error.InvalidValueTag;
        ty.arguments = try parseTypes(allocator, arguments.*);
        ty.owns_arguments = true;
    }
    if ((kind == .selection or kind == .placed) and ty.arguments.len != 1) return error.InvalidValueTag;
    if (json.fieldValue(object, "child")) |child| {
        if (kind != .optional) return error.InvalidValueTag;
        ty.optional_child = try parseChild(allocator, child.*);
    } else if (kind == .optional) return error.InvalidValueTag;
    if (json.fieldValue(object, "parameters")) |parameters| {
        if (kind != .function) return error.InvalidValueTag;
        ty.fn_params = try parseTypes(allocator, parameters.*);
    } else if (kind == .function) return error.InvalidValueTag;
    if (json.fieldValue(object, "result")) |result| {
        if (kind != .function) return error.InvalidValueTag;
        ty.fn_result = try parseChild(allocator, result.*);
    } else if (kind == .function) return error.InvalidValueTag;
    return ty;
}

fn parseChild(allocator: std.mem.Allocator, value: json.Value) !*Type {
    const child = try allocator.create(Type);
    errdefer allocator.destroy(child);
    child.* = try parse(allocator, value);
    return child;
}

fn parseTypes(allocator: std.mem.Allocator, value: json.Value) ![]Type {
    if (value != .array) return error.InvalidValueTag;
    const types = try allocator.alloc(Type, value.array.items.len);
    errdefer allocator.free(types);
    var initialized: usize = 0;
    errdefer for (types[0..initialized]) |*ty| deinit(allocator, ty);
    for (types, value.array.items) |*ty, item| {
        ty.* = try parse(allocator, item);
        initialized += 1;
    }
    return types;
}

pub fn deinit(allocator: std.mem.Allocator, ty: *Type) void {
    freeNames(allocator, ty.*);
    ty.deinit(allocator);
}

fn freeNames(allocator: std.mem.Allocator, ty: Type) void {
    if (ty.class_name) |name| allocator.free(name);
    if (ty.enum_name) |name| allocator.free(name);
    for (ty.arguments) |argument| freeNames(allocator, argument);
    for (ty.fn_params) |parameter| freeNames(allocator, parameter);
    if (ty.fn_result) |result| freeNames(allocator, result.*);
    if (ty.optional_child) |child| freeNames(allocator, child.*);
}
