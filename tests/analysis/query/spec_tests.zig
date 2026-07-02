const std = @import("std");
const analysis = @import("analysis");
const testing = std.testing;

test "analysis query spec: zero millisecond budget is already expired" {
    const budget = analysis.query.types.QueryBudget.start(.{ .budget_ms = 0 });
    try testing.expect(budget.expired());
}

test "analysis query spec: positive budget is available at query start" {
    const budget = analysis.query.types.QueryBudget.start(.{ .budget_ms = 1000 });
    try testing.expect(!budget.expired());
}

test "analysis query spec: expired structural parse budget keeps callable target" {
    const source =
        \\page title
        \\  let t1 = ultra_big! "Title"
        \\end
        \\
    ;
    const offset = (std.mem.indexOf(u8, source, "ultra_big!") orelse return error.TestUnexpectedResult) + 1;

    var context = try analysis.query.context.Context.initWithBudget(testing.allocator, .{
        .path = "unit.ss",
        .source = source,
        .offset = offset,
    }, .{
        .start_ns = 0,
        .budget_ns = 0,
    });
    defer context.deinit(testing.allocator);

    try testing.expect(context.program() == null);
    try testing.expectEqualStrings("ultra_big!", context.target);
}

test "analysis query spec: expired structural parse budget keeps local target" {
    const source =
        \\page title
        \\  let t1 = ultra_big! "Title"
        \\  ~ t1.left == page.left
        \\end
        \\
    ;
    const offset = (std.mem.indexOf(u8, source, "t1.left") orelse return error.TestUnexpectedResult) + 1;

    var context = try analysis.query.context.Context.initWithBudget(testing.allocator, .{
        .path = "unit.ss",
        .source = source,
        .offset = offset,
    }, .{
        .start_ns = 0,
        .budget_ns = 0,
    });
    defer context.deinit(testing.allocator);

    try testing.expect(context.program() == null);
    try testing.expectEqualStrings("t1", context.target);
}
