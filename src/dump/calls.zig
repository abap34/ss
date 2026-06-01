const std = @import("std");
const ast = @import("ast");
const core = @import("core");

const editor = @import("../analysis/editor.zig");
const registry = @import("../language/registry.zig");
const json = @import("utils").json;

pub fn writeFunctionsField(allocator: std.mem.Allocator, root: *json.Object, ir: *core.Ir) !void {
    var functions = try root.arrayField("functions");
    for (registry.primitiveDescriptors()) |descriptor| {
        if (ir.functions.contains(descriptor.name)) continue;
        try writePrimitiveFunction(allocator, &functions, descriptor);
    }
    var function_iterator = ir.functions.iterator();
    while (function_iterator.next()) |entry| {
        const metadata = ir.function_metadata.get(entry.key_ptr.*) orelse core.FunctionMetadata{ .module_id = ir.project_module_id };
        try writeUserFunction(allocator, &functions, ir, entry.key_ptr.*, entry.value_ptr.*, metadata);
    }
    try functions.end();
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
            if (registry.argType(descriptor.extra_arg_tags[index])) |ty| {
                const label = try ty.formatAlloc(allocator);
                defer allocator.free(label);
                try arg.stringField("type", label);
            } else {
                try arg.stringField("type", "any");
            }
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
    try item.stringField("resultValueType", editor.resultText(descriptor.result_tag));
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
    metadata: core.FunctionMetadata,
) !void {
    const signature = try editor.formatUserSignature(allocator, name, func);
    defer allocator.free(signature);

    var item = try functions.objectItem();
    try item.stringField("name", name);
    try item.enumTagField("kind", func.kind);
    try item.stringField("signature", signature);
    const result_label = try func.result_type.formatAlloc(allocator);
    defer allocator.free(result_label);
    try item.stringField("resultType", result_label);
    try item.enumTagField("resultValueType", func.result_tag);
    if (ir.moduleById(metadata.module_id)) |module| {
        try item.enumTagField("source", module.kind);
        try item.intField("moduleId", module.id);
        try item.stringField("moduleSpec", module.spec);
        try item.optionalStringField("file", module.path);
    } else {
        try item.stringField("source", "unknown");
        try item.intField("moduleId", metadata.module_id);
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
