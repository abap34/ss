const std = @import("std");
const ast = @import("ast");

/// Collects unique, concrete substitutions from the structural positions of a
/// parameter type. Ordinary argument compatibility is checked after substitution.
pub fn infer(pattern: ast.Type, actual: ast.Type, parameters: []ast.Type.Substitution, known: []bool) !void {
    if (pattern.parameter_id) |id| {
        for (parameters, known) |*binding, *is_known| {
            if (!std.meta.eql(binding.parameter, id)) continue;
            if (!isConcrete(actual)) return;
            if (is_known.* and !ast.Type.eql(binding.replacement, actual)) return error.ConflictingTypeArguments;
            binding.replacement = actual;
            is_known.* = true;
            return;
        }
        return;
    }
    if (pattern.optional_child) |child| {
        if (actual.kind == .none) return;
        return infer(child.*, if (actual.optional_child) |inner| inner.* else actual, parameters, known);
    }
    if (pattern.kind != actual.kind) return;
    if (pattern.fn_params.len == actual.fn_params.len) {
        for (pattern.fn_params, actual.fn_params) |left, right| try infer(left, right, parameters, known);
    }
    if (pattern.fn_result) |result| {
        if (actual.fn_result) |actual_result| try infer(result.*, actual_result.*, parameters, known);
    }
    if (pattern.arguments.len == actual.arguments.len) {
        for (pattern.arguments, actual.arguments) |left, right| try infer(left, right, parameters, known);
    }
}

pub fn isConcrete(ty: ast.Type) bool {
    switch (ty.kind) {
        .any, .hole, .parameter, .none, .void => return false,
        else => {},
    }
    for (ty.arguments) |argument| if (!isConcrete(argument)) return false;
    for (ty.fn_params) |parameter| if (!isConcrete(parameter)) return false;
    if (ty.fn_result) |result| if (result.kind != .void and !isConcrete(result.*)) return false;
    if (ty.optional_child) |child| if (!isConcrete(child.*)) return false;
    return true;
}
