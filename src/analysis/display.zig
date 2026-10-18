const std = @import("std");
const ast = @import("ast");
const core = @import("core");
const infer = @import("infer.zig");
const SemanticEnv = @import("../language/env.zig").SemanticEnv;

/// Each step describes a separate execution unit, not an eager recursive call.
/// Input types predict the collections produced by expansion before evaluation.
pub const Plan = core.native_display.Plan;

pub fn prepare(
    allocator: std.mem.Allocator,
    state: *core.DocumentState,
    sema: *const SemanticEnv,
    input: ast.Type,
    origin: core.SourceOrigin,
    context: *infer.Context,
) !Plan {
    var plan = Plan{ .allocator = allocator };
    errdefer plan.deinit();
    const Pending = struct { input: ast.Type, origin: core.SourceOrigin, parent: ?usize };
    var pending = std.ArrayList(Pending).empty;
    defer pending.deinit(allocator);
    try pending.append(allocator, .{ .input = input, .origin = origin, .parent = null });
    while (pending.pop()) |entry| {
        try state.checkAnalysisCanceled();
        const current = entry.input;
        const current_origin = entry.origin;
        const parent = entry.parent;
        if (current.nominalId()) |id| {
            // There are finitely many nominal declarations. Repeated visits to
            // each declaration must strictly decrease a natural-number measure.
            // This admits Wrapper<Wrapper<Text>> -> Wrapper<Text> -> Text while
            // rejecting exact cycles and growing generic display instantiations.
            var ancestor = parent;
            while (ancestor) |index| {
                ancestor = plan.steps.items[index].parent;
                const earlier = plan.steps.items[index].input;
                const earlier_id = earlier.nominalId() orelse continue;
                if (!id.eql(earlier_id)) continue;
                if (typeSize(current) >= typeSize(earlier)) {
                    const from = try earlier.formatAlloc(allocator);
                    defer allocator.free(from);
                    const to = try current.formatAlloc(allocator);
                    defer allocator.free(to);
                    try state.addValidationDiagnostic(.@"error", null, null, current_origin, .{
                        .user_report = .{
                            .code = "NonTerminatingDisplay",
                            .message = try std.fmt.allocPrint(state.allocator, "display expansion revisits '{s}' after '{s}' without decreasing its type structure", .{ to, from }),
                        },
                    });
                    return error.NonTerminatingDisplay;
                }
                break;
            }
        }
        const target = try infer.prepareDisplay(allocator, state, sema, current, current_origin, context);
        const index = try plan.append(current, target, parent);
        switch (target) {
            .native => {},
            .group => {
                var child = current.arguments.len;
                while (child > 0) {
                    child -= 1;
                    try pending.append(allocator, .{ .input = current.arguments[child], .origin = current_origin, .parent = index });
                }
            },
            .function => |key| {
                const declaration = state.functions.get(key).?;
                try pending.append(allocator, .{
                    .input = declaration.result_type,
                    .origin = state.sourceOrigin(key.module_id, declaration.span),
                    .parent = index,
                });
            },
        }
    }
    return plan;
}

fn typeSize(ty: ast.Type) usize {
    var size: usize = 1;
    for (ty.arguments) |argument| size +|= typeSize(argument);
    if (ty.optional_child) |child| size +|= typeSize(child.*);
    for (ty.fn_params) |parameter| size +|= typeSize(parameter);
    if (ty.fn_result) |result| size +|= typeSize(result.*);
    return size;
}
