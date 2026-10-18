const std = @import("std");
const syntax = @import("syntax");
const ast = @import("ast");
const allocation_testing = @import("allocation_testing");
const testing = std.testing;

fn call(expr: ast.Expr, name: []const u8) !ast.CallExpr {
    try testing.expect(expr == .call);
    try testing.expectEqualStrings(name, expr.call.callee.name);
    try testing.expect(expr.call.callee.is_operator);
    return expr.call;
}

test "selection operators: arithmetic intersection and union retain fixed precedence" {
    var module = try syntax.parse(testing.allocator,
        \\page Main
        \\  let items = a|b&c-d
        \\  let grouped = (a|b)&c
        \\  let chained = a|b|c
        \\  a | b
        \\  let row = a || b
        \\  let split = a |=| b
        \\  let callback = (x: Number) |-> x - 1
        \\end
    );
    defer module.deinit(testing.allocator);
    const statements = module.pages.items[0].statements.items;
    const union_expr = try call(statements[0].kind.let_binding.expr, "selection_union");
    const intersection = try call(union_expr.args.items[1], "selection_intersection");
    _ = try call(intersection.args.items[1], "sub");
    const grouped = try call(statements[1].kind.let_binding.expr, "selection_intersection");
    _ = try call(grouped.args.items[0], "selection_union");
    const chained = try call(statements[2].kind.let_binding.expr, "selection_union");
    _ = try call(chained.args.items[0], "selection_union");
    _ = try call(statements[3].kind.expr_stmt, "selection_union");
    try testing.expectEqualStrings("hjoin", statements[4].kind.let_binding.expr.call.callee.name);
    try testing.expectEqualStrings("hsplit", statements[5].kind.let_binding.expr.call.callee.name);
    try testing.expect(statements[6].kind.let_binding.expr == .lambda);
}

test "selection operators: recovery preserves a missing operand and the next binding" {
    for ([_][]const u8{ "|", "&" }) |operator| {
        const source = try std.fmt.allocPrint(testing.allocator, "page Main\nlet items = a {s}\nlet next = 1\nend\n", .{operator});
        defer testing.allocator.free(source);
        var module = try syntax.parseRecoveringWithSourceName(testing.allocator, source, "selection.ss");
        defer module.deinit(testing.allocator);
        const statements = module.module.pages.items[0].statements.items;
        try testing.expectEqual(@as(usize, 2), statements.len);
        try testing.expect(statements[0].kind.let_binding.expr.call.args.items[1] == .hole);
        try testing.expectEqualStrings("next", statements[1].kind.let_binding.name);
    }
}

fn parseClone(allocator: std.mem.Allocator) !void {
    var module = try syntax.parse(allocator, "page Main\nlet items = (a | b) & c - d\nend\n");
    defer module.deinit(allocator);
    var cloned = try module.clone(allocator);
    defer cloned.deinit(allocator);
    _ = try call(cloned.pages.items[0].statements.items[0].kind.let_binding.expr, "selection_intersection");
}

test "selection operators: parsing and cloning release partial allocations" {
    try allocation_testing.checkAllAllocationFailures(testing.allocator, parseClone, .{});
}
