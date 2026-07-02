const std = @import("std");
const ast = @import("ast");

const registry = @import("../../language/registry.zig");

pub fn formatPrimitiveSignature(
    allocator: std.mem.Allocator,
    descriptor: registry.PrimitiveDescriptor,
) ![]const u8 {
    var params = std.ArrayList(u8).empty;
    defer params.deinit(allocator);
    for (descriptor.arg_names, 0..) |_, index| {
        if (index != 0) try params.appendSlice(allocator, ", ");
        const label = try formatPrimitiveParam(allocator, descriptor, index);
        defer allocator.free(label);
        try params.appendSlice(allocator, label);
    }
    const result_label = if (registry.primitiveResultType(descriptor)) |result_type|
        try result_type.formatAlloc(allocator)
    else
        try allocator.dupe(u8, "dependent");
    defer allocator.free(result_label);
    return std.fmt.allocPrint(allocator, "{s}({s}) -> {s}", .{ descriptor.name, params.items, result_label });
}

pub fn formatPrimitiveParam(
    allocator: std.mem.Allocator,
    descriptor: registry.PrimitiveDescriptor,
    index: usize,
) ![]const u8 {
    const name = descriptor.arg_names[index];
    if (registry.primitiveArgType(descriptor, index)) |ty| {
        const label = try ty.formatAlloc(allocator);
        defer allocator.free(label);
        return std.fmt.allocPrint(allocator, "{s}: {s}", .{ name, label });
    }
    return allocator.dupe(u8, name);
}

pub fn formatUserSignature(
    allocator: std.mem.Allocator,
    name: []const u8,
    func: ast.FunctionDecl,
) ![]const u8 {
    const result_label = try func.result_type.formatAlloc(allocator);
    defer allocator.free(result_label);

    var params = std.ArrayList(u8).empty;
    defer params.deinit(allocator);
    for (func.params.items, 0..) |param, index| {
        if (index != 0) try params.appendSlice(allocator, ", ");
        const label = try formatUserParam(allocator, param);
        defer allocator.free(label);
        try params.appendSlice(allocator, label);
    }
    return std.fmt.allocPrint(allocator, "{s}({s}) -> {s}", .{ name, params.items, result_label });
}

pub fn formatConstSignature(
    allocator: std.mem.Allocator,
    name: []const u8,
    constant_decl: ast.ConstDecl,
) ![]const u8 {
    const result_label = try constant_decl.value_type.formatAlloc(allocator);
    defer allocator.free(result_label);
    return std.fmt.allocPrint(allocator, "const {s}: {s}", .{ name, result_label });
}

pub fn formatUserParam(allocator: std.mem.Allocator, param: ast.ParamDecl) ![]const u8 {
    const label = try param.ty.formatAlloc(allocator);
    defer allocator.free(label);
    if (param.default_value) |default_value| {
        const text = try formatExpr(allocator, default_value.*);
        defer allocator.free(text);
        return std.fmt.allocPrint(allocator, "{s}: {s} = {s}", .{ param.name, label, text });
    }
    return std.fmt.allocPrint(allocator, "{s}: {s}", .{ param.name, label });
}

fn formatExpr(allocator: std.mem.Allocator, expr: ast.Expr) ![]const u8 {
    return switch (expr) {
        .hole => allocator.dupe(u8, "<hole>"),
        .ident => |ident| allocator.dupe(u8, ident.name),
        .string => |literal| std.fmt.allocPrint(allocator, "\"{s}\"", .{literal.text}),
        .color => |text| std.fmt.allocPrint(allocator, "c\"{s}\"", .{text}),
        .number => |value| std.fmt.allocPrint(allocator, "{d}", .{value}),
        .boolean => |value| allocator.dupe(u8, if (value) "true" else "false"),
        .none => allocator.dupe(u8, "none"),
        .enum_case => |case| std.fmt.allocPrint(allocator, "{s}.{s}", .{ case.enum_name, case.case_name }),
        .record => |record| blk: {
            var fields = std.ArrayList(u8).empty;
            defer fields.deinit(allocator);
            for (record.fields.items, 0..) |field, index| {
                if (index != 0) try fields.appendSlice(allocator, ", ");
                const text = try formatExpr(allocator, field.value);
                defer allocator.free(text);
                try fields.appendSlice(allocator, field.name);
                try fields.appendSlice(allocator, " = ");
                try fields.appendSlice(allocator, text);
            }
            break :blk std.fmt.allocPrint(allocator, "{s} {{ {s} }}", .{ record.type_name, fields.items });
        },
        .record_update => |update| blk: {
            const target = try formatExpr(allocator, update.target.*);
            defer allocator.free(target);
            var fields = std.ArrayList(u8).empty;
            defer fields.deinit(allocator);
            for (update.fields.items, 0..) |field, index| {
                if (index != 0) try fields.appendSlice(allocator, ", ");
                for (field.path.items, 0..) |segment, segment_index| {
                    if (segment_index != 0) try fields.append(allocator, '.');
                    try fields.appendSlice(allocator, segment.name);
                }
                const text = try formatExpr(allocator, field.value);
                defer allocator.free(text);
                try fields.appendSlice(allocator, " = ");
                try fields.appendSlice(allocator, text);
            }
            break :blk std.fmt.allocPrint(allocator, "{s} with {{ {s} }}", .{ target, fields.items });
        },
        .call => |call| blk: {
            const callee = try call.callee.displayAlloc(allocator);
            defer allocator.free(callee);
            var args = std.ArrayList(u8).empty;
            defer args.deinit(allocator);
            for (call.args.items, 0..) |arg, index| {
                if (index != 0) try args.appendSlice(allocator, ", ");
                const text = try formatExpr(allocator, arg);
                defer allocator.free(text);
                try args.appendSlice(allocator, text);
            }
            break :blk std.fmt.allocPrint(allocator, "{s}({s})", .{ callee, args.items });
        },
        .apply => |apply| blk: {
            const callee = try formatExpr(allocator, apply.callee.*);
            defer allocator.free(callee);
            var args = std.ArrayList(u8).empty;
            defer args.deinit(allocator);
            for (apply.args.items, 0..) |arg, index| {
                if (index != 0) try args.appendSlice(allocator, ", ");
                const text = try formatExpr(allocator, arg);
                defer allocator.free(text);
                try args.appendSlice(allocator, text);
            }
            break :blk std.fmt.allocPrint(allocator, "{s}({s})", .{ callee, args.items });
        },
        .lambda => allocator.dupe(u8, "<lambda>"),
        .member => |member| blk: {
            const target = try formatExpr(allocator, member.target.*);
            defer allocator.free(target);
            break :blk std.fmt.allocPrint(allocator, "{s}.{s}", .{ target, member.name });
        },
        .optional_check => |check| blk: {
            const target = try formatExpr(allocator, check.target.*);
            defer allocator.free(target);
            break :blk std.fmt.allocPrint(allocator, "{s}?", .{target});
        },
        .coalesce => |coalesce| blk: {
            const target = try formatExpr(allocator, coalesce.target.*);
            defer allocator.free(target);
            const fallback = try formatExpr(allocator, coalesce.fallback.*);
            defer allocator.free(fallback);
            break :blk std.fmt.allocPrint(allocator, "{s} ?? {s}", .{ target, fallback });
        },
    };
}
