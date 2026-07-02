const std = @import("std");

const context_query = @import("context.zig");
const import_query = @import("imports.zig");
const resolve_query = @import("resolve.zig");
const types = @import("types.zig");

pub fn at(
    allocator: std.mem.Allocator,
    snapshot: anytype,
    req: types.SourceRequest,
    opts: types.QueryOptions,
) !?types.HoverInfo {
    const budget = types.QueryBudget.start(opts);
    if (budget.expired()) return null;
    var context = context_query.Context.initWithBudget(allocator, req, budget) catch |err| switch (err) {
        error.NoQueryTarget => return null,
        else => return err,
    };
    defer context.deinit(allocator);

    if (try importHoverMarkdown(allocator, snapshot, &context, req.path)) |markdown| {
        return .{ .markdown = markdown };
    }

    const module = snapshot.moduleForPath(req.path) orelse return null;
    if (resolve_query.visibleVariableBinding(snapshot, module.id, req.offset, context.target)) |variable| {
        return .{
            .markdown = try std.fmt.allocPrint(allocator, "```ss\n({s}: {s})\n```", .{ variable.name, variable.type_label }),
        };
    }
    const qualifier = context.qualifiedCallableAlias();
    if (resolve_query.valueBinding(snapshot, module.id, context.target, qualifier, .function)) |binding| {
        return .{
            .markdown = try std.fmt.allocPrint(allocator, "```ss\n{s}\n```\n{s}", .{ binding.signature, binding.documentation }),
        };
    }
    if (resolve_query.valueBinding(snapshot, module.id, context.target, qualifier, .constant)) |binding| {
        return .{
            .markdown = try std.fmt.allocPrint(allocator, "```ss\n{s}\n```\n{s}", .{ binding.signature, binding.documentation }),
        };
    }
    if (resolve_query.typeDefinition(snapshot, module.id, context.target, context.qualifiedCallableAlias())) |type_definition| {
        _ = type_definition;
        return .{
            .markdown = try std.fmt.allocPrint(allocator, "```ss\ntype {s}\n```", .{context.target}),
        };
    }
    return null;
}

fn importHoverMarkdown(
    allocator: std.mem.Allocator,
    snapshot: anytype,
    context: *const context_query.Context,
    request_path: []const u8,
) !?[]u8 {
    const module_id = import_query.moduleIdForContext(snapshot, context, request_path) orelse return null;
    const module = snapshot.moduleById(module_id) orelse return null;
    return try std.fmt.allocPrint(allocator, "```ss\nimport {s}\n```", .{module.spec});
}
