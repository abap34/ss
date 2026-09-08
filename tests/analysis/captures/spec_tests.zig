const std = @import("std");
const compiler = @import("compiler");
const Index = compiler.analysis.captures.Index;
const testing = std.testing;

fn expectNames(expected: []const []const u8, actual: []const []const u8) !void {
    try testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |left, right| try testing.expectEqualStrings(left, right);
}

test "captures: nested lambdas retain free references and exclude each parameter scope" {
    var module = try compiler.syntax.parse(testing.allocator,
        \\document
        \\let factory = (outer: Number) |-> (inner: Number) |-> combine(outer, inner, value.field, value.field)
        \\end
    );
    defer module.deinit(testing.allocator);
    var index = Index.init(testing.allocator);
    defer index.deinit();
    try index.collectModule(module);
    const outer = module.document_statements.items[0].kind.let_binding.expr.lambda;
    const inner = outer.body.lambda;
    try expectNames(&.{ "combine", "value" }, index.names(outer).?);
    try expectNames(&.{ "combine", "outer", "value" }, index.names(inner).?);
    const existing = index.names(outer).?.ptr;
    try index.collectModule(module);
    try testing.expectEqual(existing, index.names(outer).?.ptr);
    try testing.expectEqual(@as(usize, 2), index.lambdas.count());
}

test "captures: qualified calls and fields do not capture unrelated local names" {
    var module = try compiler.syntax.parse(testing.allocator,
        \\document
        \\let transform = (input: Number) |-> helpers::apply(saved_record with { field = callback(input), other = fallback ?? saved.value })
        \\end
    );
    defer module.deinit(testing.allocator);
    var index = Index.init(testing.allocator);
    defer index.deinit();
    try index.collectModule(module);
    const lambda = module.document_statements.items[0].kind.let_binding.expr.lambda;
    try expectNames(&.{ "saved_record", "callback", "fallback", "saved" }, index.names(lambda).?);
}

fn collectWithAllocationFailures(allocator: std.mem.Allocator, module: compiler.syntax.Module) !void {
    var index = Index.init(allocator);
    defer index.deinit();
    try index.collectModule(module);
}

test "captures: every declaration and statement boundary collects lambdas with allocation cleanup" {
    var module = try compiler.syntax.parse(testing.allocator,
        \\record Config {
        \\  callback: Number -> Number = (x: Number) |-> x
        \\}
        \\type Item = object {
        \\  callback: Number -> Number = (x: Number) |-> x
        \\}
        \\extend Item {
        \\  extra: Number -> Number = (x: Number) |-> x
        \\}
        \\const function: Number -> Number = (x: Number) |-> x
        \\fn build(callback: Number -> Number = (x: Number) |-> x) -> Number -> Number
        \\  if true
        \\    return (x: Number) |-> callback(x)
        \\  else
        \\    return (x: Number) |-> x
        \\  end
        \\end
        \\page test
        \\  let callback = (x: Number) |-> x
        \\end
    );
    defer module.deinit(testing.allocator);
    var index = Index.init(testing.allocator);
    defer index.deinit();
    try index.collectModule(module);
    try testing.expectEqual(@as(usize, 8), index.lambdas.count());
    try testing.checkAllAllocationFailures(testing.allocator, collectWithAllocationFailures, .{module});
}
