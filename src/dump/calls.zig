const std = @import("std");
const ast = @import("ast");
const core = @import("core");

const editor = @import("../analysis/editor.zig");
const registry = @import("../language/registry.zig");
const json = @import("utils").json;

pub fn writeFunctionsField(allocator: std.mem.Allocator, root: *json.Object, ir: *core.Ir) !void {
    var functions = try root.arrayField("functions");
    for (registry.primitiveDescriptors()) |descriptor| {
        if (userValueNameExists(ir, descriptor.name)) continue;
        try writePrimitiveFunction(allocator, &functions, descriptor);
    }
    var function_iterator = ir.functions.iterator();
    while (function_iterator.next()) |entry| {
        try writeUserFunction(allocator, &functions, ir, entry.value_ptr.name, entry.value_ptr.*, entry.key_ptr.module_id);
    }
    try functions.end();

    var constants = try root.arrayField("constants");
    var const_iterator = ir.constants.iterator();
    while (const_iterator.next()) |entry| {
        try writeUserConst(allocator, &constants, ir, entry.value_ptr.name, entry.value_ptr.*, entry.key_ptr.module_id);
    }
    try constants.end();
}

fn userValueNameExists(ir: *const core.Ir, name: []const u8) bool {
    var iterator = ir.functions.iterator();
    while (iterator.next()) |entry| {
        if (std.mem.eql(u8, entry.value_ptr.name, name)) return true;
    }
    var const_iterator = ir.constants.iterator();
    while (const_iterator.next()) |entry| {
        if (std.mem.eql(u8, entry.value_ptr.name, name)) return true;
    }
    return false;
}

pub fn writeQueryContractsField(allocator: std.mem.Allocator, root: *json.Object) !void {
    var queries = try root.arrayField("query_contracts");
    for (registry.queryDescriptors()) |descriptor| {
        var item = try queries.objectItem();
        try item.stringField("name", descriptor.name);
        try item.stringField("summary", descriptor.summary);
        try item.stringField("inputName", descriptor.input_name);
        const input_label = try registry.queryInputType(descriptor).formatAlloc(allocator);
        defer allocator.free(input_label);
        try item.stringField("inputType", input_label);
        const output_label = try registry.queryOutputType(descriptor).formatAlloc(allocator);
        defer allocator.free(output_label);
        try item.stringField("outputType", output_label);
        var args = try item.arrayField("extraArgs");
        for (descriptor.extra_arg_names, 0..) |name, index| {
            var arg = try args.objectItem();
            try arg.stringField("name", name);
            const label = try descriptor.extra_arg_types[index].formatAlloc(allocator);
            defer allocator.free(label);
            try arg.stringField("type", label);
            try arg.end();
        }
        try args.end();
        try item.end();
    }
    try queries.end();
}

fn writePrimitiveFunction(allocator: std.mem.Allocator, functions: *json.Array, descriptor: registry.PrimitiveDescriptor) !void {
    const signature = try editor.formatPrimitiveSignature(allocator, descriptor);
    defer allocator.free(signature);

    var item = try functions.objectItem();
    try item.stringField("name", descriptor.name);
    try item.stringField("signature", signature);
    if (registry.primitiveResultType(descriptor)) |result_type| {
        const result_label = try result_type.formatAlloc(allocator);
        defer allocator.free(result_label);
        try item.stringField("resultType", result_label);
    } else {
        try item.stringField("resultType", "dependent");
    }
    try item.stringField("source", "primitive");
    try item.stringField("summary", descriptor.summary);
    var params = try item.arrayField("params");
    for (descriptor.arg_names, 0..) |_, index| {
        const label = try editor.formatPrimitiveParam(allocator, descriptor, index);
        defer allocator.free(label);
        try params.stringItem(label);
    }
    try params.end();
    try item.end();
}

fn writeUserFunction(
    allocator: std.mem.Allocator,
    functions: *json.Array,
    ir: *core.Ir,
    name: []const u8,
    func: ast.FunctionDecl,
    module_id: core.SourceModuleId,
) !void {
    const signature = try editor.formatUserSignature(allocator, name, func);
    defer allocator.free(signature);

    var item = try functions.objectItem();
    try item.stringField("name", name);
    try item.stringField("kind", "function");
    try item.stringField("signature", signature);
    const result_label = try func.result_type.formatAlloc(allocator);
    defer allocator.free(result_label);
    try item.stringField("resultType", result_label);
    if (ir.moduleById(module_id)) |module| {
        try item.enumTagField("source", module.kind);
        try item.intField("moduleId", module.id);
        try item.stringField("moduleSpec", module.spec);
        try item.optionalStringField("file", module.path);
    } else {
        try item.stringField("source", "unknown");
        try item.intField("moduleId", module_id);
        try item.nullField("file");
    }
    try item.stringField("summary", "");
    var params = try item.arrayField("params");
    for (func.params.items) |param| {
        const label = try editor.formatUserParam(allocator, param);
        defer allocator.free(label);
        try params.stringItem(label);
    }
    try params.end();
    try item.end();
}

fn writeUserConst(
    allocator: std.mem.Allocator,
    constants: *json.Array,
    ir: *core.Ir,
    name: []const u8,
    constant_decl: ast.ConstDecl,
    module_id: core.SourceModuleId,
) !void {
    const signature = try editor.formatConstSignature(allocator, name, constant_decl);
    defer allocator.free(signature);

    var item = try constants.objectItem();
    try item.stringField("name", name);
    try item.stringField("kind", "constant");
    try item.stringField("signature", signature);
    const result_label = try constant_decl.value_type.formatAlloc(allocator);
    defer allocator.free(result_label);
    try item.stringField("resultType", result_label);
    if (ir.moduleById(module_id)) |module| {
        try item.enumTagField("source", module.kind);
        try item.intField("moduleId", module.id);
        try item.stringField("moduleSpec", module.spec);
        try item.optionalStringField("file", module.path);
    } else {
        try item.stringField("source", "unknown");
        try item.intField("moduleId", module_id);
        try item.nullField("file");
    }
    try item.stringField("summary", "");
    try item.end();
}
