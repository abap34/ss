const std = @import("std");
const core = @import("core");

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
    var context = context_query.Context.initFromSnapshot(allocator, snapshot, req, budget) catch |err| switch (err) {
        error.NoQueryTarget => return null,
        else => return err,
    };
    defer context.deinit(allocator);
    if (context.expired()) return null;
    var result = try resolveHover(allocator, snapshot, req, &context, budget);
    if (context.expired()) {
        if (result) |*item| item.deinit(allocator);
        return null;
    }
    return result;
}

fn resolveHover(allocator: std.mem.Allocator, snapshot: anytype, req: types.SourceRequest, context: *const context_query.Context, budget: types.QueryBudget) !?types.HoverInfo {
    if (try importHoverMarkdown(allocator, snapshot, context, req.path)) |markdown| {
        return .{ .markdown = markdown };
    }

    if (import_query.selectedBindingAt(snapshot, context, req.path)) |selected| {
        inline for (.{ core.DefinitionKind.function, core.DefinitionKind.constant }) |kind| {
            if (resolve_query.exportedValueBinding(budget, snapshot, selected.module_id, selected.name, kind)) |binding| return .{
                .markdown = try std.fmt.allocPrint(allocator, "```ss\n{s}\n```\n{s}", .{ binding.signature, binding.documentation }),
            };
        }
        if (resolve_query.exportedTypeDefinition(budget, snapshot, selected.module_id, selected.name) != null) return .{
            .markdown = try std.fmt.allocPrint(allocator, "```ss\ntype {s}\n```", .{selected.name}),
        };
        return null;
    }

    if (context.expired()) return null;
    const module = snapshot.moduleForPath(req.path) orelse return null;
    if (resolve_query.visibleVariableBinding(budget, snapshot, module.id, req.offset, context.target)) |variable| {
        return .{
            .markdown = try std.fmt.allocPrint(allocator, "```ss\n({s}: {s})\n```", .{ variable.name, variable.type_label }),
        };
    }
    const qualifier = context.qualifiedCallableAlias();
    if (context.expired()) return null;
    if (resolve_query.valueBinding(budget, snapshot, module.id, context.target, qualifier, .function)) |binding| {
        return .{
            .markdown = try std.fmt.allocPrint(allocator, "```ss\n{s}\n```\n{s}", .{ binding.signature, binding.documentation }),
        };
    }
    if (resolve_query.valueBinding(budget, snapshot, module.id, context.target, qualifier, .constant)) |binding| {
        return .{
            .markdown = try std.fmt.allocPrint(allocator, "```ss\n{s}\n```\n{s}", .{ binding.signature, binding.documentation }),
        };
    }
    if (resolve_query.typeDefinition(budget, snapshot, module.id, context.target, context.qualifiedCallableAlias())) |type_definition| {
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
