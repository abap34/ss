const std = @import("std");
const ast = @import("ast");
const syntax = @import("../../syntax.zig");
const types = @import("types.zig");

pub const ParsedSource = struct {
    borrowed: ?*const ast.Module = null,
    owned: ?syntax.ParseResult = null,

    pub fn init(allocator: std.mem.Allocator, snapshot: anytype, req: types.SourceRequest, budget: ?types.QueryBudget) !ParsedSource {
        if (budget) |value| if (value.expired()) return .{};
        if (snapshot.syntaxForSource(req.path, req.source)) |tree| return .{ .borrowed = tree };
        return parse(allocator, req, budget);
    }

    pub fn parse(allocator: std.mem.Allocator, req: types.SourceRequest, budget: ?types.QueryBudget) !ParsedSource {
        if (budget) |value| if (value.expired()) return .{};
        var parsed = syntax.parseRecoveringWithOptions(allocator, req.source, req.path, .{
            .cancellation = if (budget) |*value| .{ .context = value, .is_canceled = budgetExpired } else null,
        }) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return .{},
        };
        if (budget) |value| if (value.expired()) {
            parsed.deinit(allocator);
            return .{};
        };
        return .{ .owned = parsed };
    }

    pub fn deinit(self: *ParsedSource, allocator: std.mem.Allocator) void {
        if (self.owned) |*value| value.deinit(allocator);
    }

    pub fn module(self: *const ParsedSource) ?*const ast.Module {
        return self.borrowed orelse if (self.owned) |*value| &value.module else null;
    }
};

fn budgetExpired(context: *const anyopaque) bool {
    const budget: *const types.QueryBudget = @ptrCast(@alignCast(context));
    return budget.expired();
}
