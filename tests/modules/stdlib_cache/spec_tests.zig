const std = @import("std");
const compiler = @import("compiler");

const testing = std.testing;

test "embedded syntax cache returns independent module trees" {
    var cache = compiler.module_loader.EmbeddedSyntaxCache.init(testing.allocator);
    defer cache.deinit();

    var first = try loadGraph(&cache);
    defer first.deinit();
    const parsed_after_first = cache.parsedModuleCount();
    try testing.expect(parsed_after_first > 0);
    var second = try loadGraph(&cache);
    defer second.deinit();
    try testing.expectEqual(parsed_after_first, cache.parsedModuleCount());

    const first_prelude = moduleBySpec(&first, "std:core/prelude") orelse return error.MissingPrelude;
    const second_prelude = moduleBySpec(&second, "std:core/prelude") orelse return error.MissingPrelude;
    try testing.expect(first_prelude.syntax.functions.items.len != 0);
    try testing.expectEqual(first_prelude.syntax.functions.items.len, second_prelude.syntax.functions.items.len);

    const first_name = @constCast(first_prelude.syntax.functions.items[0].name);
    const second_name = second_prelude.syntax.functions.items[0].name;
    try testing.expect(first_name.ptr != second_name.ptr);
    const expected_first_byte = second_name[0];
    first_name[0] = if (expected_first_byte == 'x') 'y' else 'x';
    try testing.expectEqual(expected_first_byte, second_name[0]);

    var third = try loadGraph(&cache);
    defer third.deinit();
    try testing.expectEqual(parsed_after_first, cache.parsedModuleCount());
    const third_prelude = moduleBySpec(&third, "std:core/prelude") orelse return error.MissingPrelude;
    try testing.expectEqualStrings(second_name, third_prelude.syntax.functions.items[0].name);
}

fn loadGraph(cache: *compiler.module_loader.EmbeddedSyntaxCache) !compiler.module_loader.ModuleGraph {
    const source = "import std:themes/default as *\n";
    var program = try compiler.syntax.parseWithSourceName(testing.allocator, source, "cache-test.ss");
    defer program.deinit(testing.allocator);
    return try compiler.module_loader.loadGraphWithOptions(testing.allocator, testing.io, ".", program, .{
        .embedded_cache = cache,
    });
}

fn moduleBySpec(graph: *compiler.module_loader.ModuleGraph, spec: []const u8) ?*compiler.core.SourceModule {
    for (graph.modules.items) |*module| {
        if (std.mem.eql(u8, module.spec, spec)) return module;
    }
    return null;
}
