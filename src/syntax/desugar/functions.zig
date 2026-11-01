const std = @import("std");
const ast = @import("ast");
const build = @import("build.zig");

pub fn placement(allocator: std.mem.Allocator, func: ast.FunctionDecl) !ast.FunctionDecl {
    const placed_name = try std.fmt.allocPrint(allocator, "{s}!", .{func.name});
    defer allocator.free(placed_name);
    var placed = try func.cloneSignature(allocator, placed_name, func.span);
    errdefer placed.deinit(allocator);
    const reference = try ast.Type.placedOf(allocator, placed.result_type);
    placed.result_type.deinit(allocator);
    placed.result_type = reference;

    var input = ast.CallExpr{ .callee = .{ .name = try allocator.dupe(u8, func.name), .resolution = .function }, .args = .empty };
    errdefer input.deinit(allocator);
    try input.args.ensureTotalCapacity(allocator, func.params.items.len);
    for (func.params.items) |param| input.args.appendAssumeCapacity(.{ .ident = .{ .name = try allocator.dupe(u8, param.name) } });
    try input.type_args.ensureTotalCapacity(allocator, func.type_params.items.len);
    for (func.type_params.items) |parameter| input.type_args.appendAssumeCapacity(ast.Type.unresolvedNameAt(parameter.name, parameter.span));

    var page = try build.call(allocator, "pagectx", &.{}, func.span);
    defer page.deinit(allocator);
    var result = try build.call(allocator, "place_on!", &.{ page, .{ .call = input } }, func.span);
    page = .none;
    input = .{ .callee = .{ .name = &.{} }, .args = .empty };
    errdefer result.deinit(allocator);
    try placed.statements.append(allocator, .{ .span = func.span, .kind = .{ .return_expr = result } });
    return placed;
}
