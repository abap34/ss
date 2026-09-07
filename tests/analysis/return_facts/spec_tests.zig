const std = @import("std");
const compiler = @import("compiler");
const ast = compiler.syntax;
const core = compiler.core;
const infer = compiler.analysis.infer;
const TypeEnv = compiler.analysis.types.TypeEnv;
const TypeInfo = compiler.analysis.types.TypeInfo;
const testing = std.testing;

const Analysis = struct {
    allocator: std.mem.Allocator,
    syntax: ast.Module,
    functions: core.FunctionMap,
    context: infer.Context,

    fn init(allocator: std.mem.Allocator, source: []const u8) !Analysis {
        var syntax = try compiler.syntax.parse(allocator, source);
        errdefer syntax.deinit(allocator);
        var functions = core.FunctionMap.init(allocator);
        errdefer functions.deinit();
        for (syntax.functions.items) |function| try functions.put(core.functionKey(0, function.name), function);
        return .{
            .allocator = allocator,
            .syntax = syntax,
            .functions = functions,
            .context = infer.Context.init(allocator),
        };
    }

    fn deinit(self: *Analysis) void {
        self.context.deinit();
        self.functions.deinit();
        self.syntax.deinit(self.allocator);
    }

    fn expression(self: *Analysis, index: usize) !TypeInfo {
        return self.expressionInModule(index, 0);
    }

    fn expressionInModule(self: *Analysis, index: usize, module_id: core.SourceModuleId) !TypeInfo {
        var env = TypeEnv.init(self.allocator);
        defer env.deinit();
        var sema = compiler.semantic_env.SemanticEnv.init(null, null, &self.functions);
        sema.module_id = module_id;
        const expr = self.syntax.document_statements.items[index].kind.let_binding.expr;
        return infer.exprInfoWithContext(&self.context, self.allocator, null, &sema, &env, expr, "");
    }
};

test "return facts: a shared call graph is analyzed once per function" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var source = std.ArrayList(u8).empty;
    try source.appendSlice(allocator, "fn f0() -> String\nreturn \"leaf\"\nend\n");
    for (1..25) |id| {
        try source.appendSlice(allocator, try std.fmt.allocPrint(
            allocator,
            "fn f{d}() -> String\nlet unused = f{d}()\nreturn f{d}()\nend\n",
            .{ id, id - 1, id - 1 },
        ));
    }
    try source.appendSlice(allocator, "document\nlet result = f24()\nend\n");
    var analysis = try Analysis.init(allocator, source.items);
    defer analysis.deinit();
    try testing.expectEqualStrings("leaf", (try analysis.expression(0)).string_literal.?);
    try testing.expectEqual(@as(usize, 25), analysis.context.body_analyses);
    try testing.expect(analysis.context.cache_hits >= 24);
    _ = try analysis.expression(0);
    try testing.expectEqual(@as(usize, 25), analysis.context.body_analyses);
}

test "return facts: literal arguments, defaults and nested calls retain distinct facts" {
    var analysis = try Analysis.init(testing.allocator,
        \\fn identity(value: String = "fallback") -> String
        \\  return value
        \\end
        \\document
        \\  let first = identity("first")
        \\  let second = identity("second")
        \\  let nested = identity(identity("nested"))
        \\  let defaulted = identity()
        \\  let explicit = identity("fallback")
        \\  let invalid = identity(42)
        \\end
    );
    defer analysis.deinit();
    for ([_][]const u8{ "first", "second", "nested", "fallback", "fallback" }, 0..) |expected, index| {
        try testing.expectEqualStrings(expected, (try analysis.expression(index)).string_literal.?);
    }
    try testing.expectEqual(@as(usize, 4), analysis.context.body_analyses);
    try testing.expectError(error.InvalidType, analysis.expression(5));
}

test "return facts: function arguments preserve their individual labels" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var analysis = try Analysis.init(arena.allocator(),
        \\fn first(value: String) -> String
        \\  return value
        \\end
        \\fn second(value: String) -> String
        \\  return value
        \\end
        \\fn keep(callback: String -> String) -> String -> String
        \\  return callback
        \\end
        \\document
        \\  let a = keep(first)
        \\  let b = keep(second)
        \\end
    );
    defer analysis.deinit();
    for ([_][]const u8{ "first", "second" }, 0..) |expected, index| {
        const result = try analysis.expression(index);
        try testing.expectEqual(@as(usize, 1), result.function_labels.len);
        try testing.expectEqualStrings(expected, result.function_labels[0]);
    }
    try testing.expectEqual(@as(usize, 2), analysis.context.body_analyses);
}

test "return facts: module identity participates in the cache key" {
    var analysis = try Analysis.init(testing.allocator,
        \\fn value() -> String
        \\  return "first module"
        \\end
        \\document
        \\  let result = value()
        \\end
    );
    defer analysis.deinit();
    var second = try compiler.syntax.parse(testing.allocator,
        \\fn value() -> String
        \\  return "second module"
        \\end
    );
    defer second.deinit(testing.allocator);
    try analysis.functions.put(core.functionKey(1, "value"), second.functions.items[0]);
    try testing.expectEqualStrings("first module", (try analysis.expressionInModule(0, 0)).string_literal.?);
    try testing.expectEqualStrings("second module", (try analysis.expressionInModule(0, 1)).string_literal.?);
    try testing.expectEqual(@as(usize, 2), analysis.context.body_analyses);
}

test "return facts: recursive fallbacks terminate without becoming reusable facts" {
    var analysis = try Analysis.init(testing.allocator,
        \\fn first() -> String
        \\  return second()
        \\end
        \\fn second() -> String
        \\  return first()
        \\end
        \\document
        \\  let result = first()
        \\end
    );
    defer analysis.deinit();
    try testing.expect((try analysis.expression(0)).string_literal == null);
    try testing.expectEqual(@as(usize, 1), analysis.context.recursive_calls);
    try testing.expectEqual(@as(usize, 0), analysis.context.results.count());
    _ = try analysis.expression(0);
    try testing.expectEqual(@as(usize, 4), analysis.context.body_analyses);
}
