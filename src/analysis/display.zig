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
    var current = input;
    var current_origin = origin;
    while (true) {
        try state.checkAnalysisCanceled();
        if (current.nominalId()) |id| {
            // There are finitely many nominal declarations. Repeated visits to
            // each declaration must strictly decrease a natural-number measure.
            // This admits Wrapper<Wrapper<Text>> -> Wrapper<Text> -> Text while
            // rejecting exact cycles and growing generic display instantiations.
            var index = plan.steps.items.len;
            while (index > 0) {
                index -= 1;
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
        var owned = try current.clone(allocator);
        plan.steps.append(allocator, .{ .input = owned, .target = target }) catch |err| {
            owned.deinit(allocator);
            return err;
        };
        switch (target) {
            .native => return plan,
            .function => |key| {
                const declaration = state.functions.get(key).?;
                current = declaration.result_type;
                current_origin = state.sourceOrigin(key.module_id, declaration.span);
            },
        }
    }
}

fn typeSize(ty: ast.Type) usize {
    var size: usize = 1;
    for (ty.arguments) |argument| size +|= typeSize(argument);
    if (ty.optional_child) |child| size +|= typeSize(child.*);
    for (ty.fn_params) |parameter| size +|= typeSize(parameter);
    if (ty.fn_result) |result| size +|= typeSize(result.*);
    return size;
}
