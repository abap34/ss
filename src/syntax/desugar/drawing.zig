const std = @import("std");
const ast = @import("ast");
const build = @import("build.zig");

// A show block introduces no lexical scope. Only expression evaluation is
// decorated; bindings, branches, and returns remain ordinary statements.
pub fn expand(
    allocator: std.mem.Allocator,
    condition: *ast.Expr,
    condition_span: ast.Span,
    body: *std.ArrayList(ast.Statement),
) !std.ArrayList(ast.Statement) {
    var result = std.ArrayList(ast.Statement).empty;
    errdefer {
        for (result.items) |*statement| statement.deinit(allocator);
        result.deinit(allocator);
    }
    try result.ensureTotalCapacity(allocator, body.items.len + 2);
    const name = try std.fmt.allocPrint(allocator, "#drawing-{d}", .{condition_span.start});
    var name_owned = true;
    errdefer if (name_owned) allocator.free(name);
    const predicate = try allocator.create(ast.Expr);
    predicate.* = condition.*;
    condition.* = .none;
    result.appendAssumeCapacity(.{ .span = condition_span, .kind = .{ .let_binding = .{
        .name = name,
        .expr = .{ .lambda = .{ .params = .empty, .body = predicate, .span = condition_span } },
    } } });
    name_owned = false;

    // Validate even an empty block and preserve its placement effect. The
    // predicate is deferred by the same primitive used for nonempty operands.
    var empty: ast.Expr = .{ .number = 0 };
    try wrap(allocator, &empty, name, condition_span);
    result.appendAssumeCapacity(.{ .span = condition_span, .kind = .{ .expr_stmt = empty } });
    for (body.items) |*statement| try decorate(allocator, statement, name, condition_span);
    result.appendSliceAssumeCapacity(body.items);
    body.clearRetainingCapacity();
    return result;
}

fn decorate(allocator: std.mem.Allocator, statement: *ast.Statement, name: []const u8, condition_span: ast.Span) anyerror!void {
    switch (statement.kind) {
        .hole, .return_void => {},
        .let_binding => |*binding| try wrap(allocator, &binding.expr, name, condition_span),
        .expr_stmt, .return_expr => |*expr| try wrap(allocator, expr, name, condition_span),
        .property_set => |*property| {
            try wrap(allocator, &property.target, name, condition_span);
            try wrap(allocator, &property.value, name, condition_span);
        },
        .constrain => |*constraint| if (constraint.offset) |*offset| try wrap(allocator, offset, name, condition_span),
        .if_stmt => |*branch| {
            try wrap(allocator, &branch.condition, name, condition_span);
            for (branch.then_statements.items) |*nested| try decorate(allocator, nested, name, condition_span);
            for (branch.else_statements.items) |*nested| try decorate(allocator, nested, name, condition_span);
        },
    }
}

fn wrap(allocator: std.mem.Allocator, expr: *ast.Expr, name: []const u8, condition_span: ast.Span) !void {
    var reference: ast.Expr = .{ .ident = .{ .name = try allocator.dupe(u8, name) } };
    errdefer reference.deinit(allocator);
    expr.* = try build.call(allocator, "draw_when!", &.{ expr.*, reference }, condition_span);
}
