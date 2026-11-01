const std = @import("std");
const ast = @import("ast");

// Transfer operand ownership only after all allocations have succeeded.
pub fn call(allocator: std.mem.Allocator, name: []const u8, operands: []const ast.Expr, span: ?ast.Span) !ast.Expr {
    const owned_name = try allocator.dupe(u8, name);
    errdefer allocator.free(owned_name);
    var args = std.ArrayList(ast.Expr).empty;
    errdefer args.deinit(allocator);
    try args.appendSlice(allocator, operands);
    return .{ .call = .{
        .callee = .{ .name = owned_name, .resolution = .intrinsic, .span = span },
        .args = args,
    } };
}
