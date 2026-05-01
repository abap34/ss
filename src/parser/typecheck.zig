const std = @import("std");
const core = @import("core");
const ast = @import("ast.zig");
const registry = @import("registry.zig");

pub const FunctionContract = struct {
    param_count: usize,
    returns_value: bool,
    result_sort: core.SemanticSort,
};

const SortEnv = std.StringHashMap(core.SemanticSort);

pub fn valueSort(value: core.Value) core.SemanticSort {
    return switch (value) {
        .document => .document,
        .page => .page,
        .object => .object,
        .selection => .selection,
        .anchor => .anchor,
        .function => .function,
        .style => .style,
        .string => .string,
        .number => .number,
        .constraints => .constraints,
        .fragment => .fragment,
    };
}

pub fn ensureValueSort(
    engine: *core.Engine,
    page_id: ?core.NodeId,
    value: core.Value,
    expected: core.SemanticSort,
    origin: []const u8,
) !void {
    return ensureValueSortWithCode(engine, page_id, value, expected, origin, .UnmatchedArgumentType);
}

pub fn ensureValueSortWithCode(
    engine: *core.Engine,
    page_id: ?core.NodeId,
    value: core.Value,
    expected: core.SemanticSort,
    origin: []const u8,
    code: core.TypeMismatchCode,
) !void {
    const actual = valueSort(value);
    if (actual != expected) {
        try engine.addValidationDiagnostic(.@"error", page_id, null, origin, .{
            .type_mismatch = .{ .code = code, .expected = expected, .actual = actual },
        });
        return error.InvalidSemanticSort;
    }
}

pub fn functionRefFor(allocator: std.mem.Allocator, func: ast.FunctionDecl) !core.FunctionRef {
    const contract = functionContract(func);
    const param_sorts = try allocator.alloc(core.SemanticSort, func.params.items.len);
    for (func.params.items, 0..) |param, index| {
        param_sorts[index] = param.sort;
    }
    return .{
        .name = func.name,
        .param_count = contract.param_count,
        .param_sorts = param_sorts,
        .returns_value = contract.returns_value,
        .result_sort = contract.result_sort,
        .effect = .unknown,
    };
}

pub fn functionContract(func: ast.FunctionDecl) FunctionContract {
    return .{
        .param_count = func.params.items.len,
        .returns_value = functionReturnsValue(func),
        .result_sort = func.result_sort,
    };
}

pub fn functionReturnsValue(func: ast.FunctionDecl) bool {
    return functionBodyReturns(func.statements.items);
}

pub fn functionBodyReturns(statements: []const ast.Statement) bool {
    for (statements) |stmt| {
        switch (stmt.kind) {
            .return_expr => return true,
            else => {},
        }
    }
    return false;
}

pub fn checkFunctionDefinitions(
    allocator: std.mem.Allocator,
    engine: *core.Engine,
    functions: *const std.StringHashMap(ast.FunctionDecl),
) !void {
    try checkFunctionCallGraph(allocator, engine, functions);

    var it = functions.iterator();
    while (it.next()) |entry| {
        try checkFunction(allocator, engine, functions, entry.value_ptr.*);
    }
}

fn checkFunctionCallGraph(
    allocator: std.mem.Allocator,
    engine: *core.Engine,
    functions: *const std.StringHashMap(ast.FunctionDecl),
) !void {
    var states = std.StringHashMap(u8).init(allocator);
    defer states.deinit();

    var it = functions.iterator();
    while (it.next()) |entry| {
        try visitFunction(allocator, engine, functions, &states, entry.key_ptr.*);
    }
}

fn visitFunction(
    allocator: std.mem.Allocator,
    engine: *core.Engine,
    functions: *const std.StringHashMap(ast.FunctionDecl),
    states: *std.StringHashMap(u8),
    name: []const u8,
) !void {
    if (states.get(name)) |state| {
        if (state == 1) {
            const func = functions.get(name).?;
            try reportRecursiveFunction(allocator, engine, func);
            return error.RecursiveFunction;
        }
        if (state == 2) return;
    }

    const func = functions.get(name) orelse return;
    try states.put(name, 1);

    var callees = std.ArrayList([]const u8).empty;
    defer callees.deinit(allocator);
    try collectFunctionCallees(allocator, functions, func, &callees);
    for (callees.items) |callee| {
        if (states.get(callee)) |state| {
            if (state == 1) {
                try reportRecursiveFunction(allocator, engine, func);
                return error.RecursiveFunction;
            }
        }
        try visitFunction(allocator, engine, functions, states, callee);
    }

    try states.put(name, 2);
}

fn reportRecursiveFunction(allocator: std.mem.Allocator, engine: *core.Engine, func: ast.FunctionDecl) !void {
    try engine.addValidationDiagnostic(.@"error", null, null, try statementOrigin(allocator, func.span), .{
        .recursive_function = .{ .function_name = func.name },
    });
}

fn collectFunctionCallees(
    allocator: std.mem.Allocator,
    functions: *const std.StringHashMap(ast.FunctionDecl),
    func: ast.FunctionDecl,
    callees: *std.ArrayList([]const u8),
) !void {
    for (func.statements.items) |stmt| {
        try collectStatementCallees(allocator, functions, stmt, callees);
    }
}

fn collectStatementCallees(
    allocator: std.mem.Allocator,
    functions: *const std.StringHashMap(ast.FunctionDecl),
    stmt: ast.Statement,
    callees: *std.ArrayList([]const u8),
) !void {
    switch (stmt.kind) {
        .let_binding => |binding| try collectExprCallees(allocator, functions, binding.expr, callees),
        .bind_binding => |binding| try collectExprCallees(allocator, functions, binding.expr, callees),
        .return_expr => |expr| try collectExprCallees(allocator, functions, expr, callees),
        .constrain => |decl| if (decl.offset) |expr| try collectExprCallees(allocator, functions, expr, callees),
        .expr_stmt => |expr| try collectExprCallees(allocator, functions, expr, callees),
        else => {},
    }
}

fn collectExprCallees(
    allocator: std.mem.Allocator,
    functions: *const std.StringHashMap(ast.FunctionDecl),
    expr: ast.Expr,
    callees: *std.ArrayList([]const u8),
) !void {
    switch (expr) {
        .call => |call| {
            if (functions.contains(call.name)) try appendUniqueCallee(allocator, callees, call.name);
            for (call.args.items) |arg| try collectExprCallees(allocator, functions, arg, callees);
        },
        else => {},
    }
}

fn appendUniqueCallee(allocator: std.mem.Allocator, callees: *std.ArrayList([]const u8), name: []const u8) !void {
    for (callees.items) |existing| {
        if (std.mem.eql(u8, existing, name)) return;
    }
    try callees.append(allocator, name);
}

fn checkFunction(
    allocator: std.mem.Allocator,
    engine: *core.Engine,
    functions: *const std.StringHashMap(ast.FunctionDecl),
    func: ast.FunctionDecl,
) !void {
    var env = SortEnv.init(allocator);
    defer env.deinit();

    for (func.params.items) |param| {
        try env.put(param.name, param.sort);
    }

    for (func.statements.items) |stmt| {
        try checkStatement(allocator, engine, functions, &env, func.result_sort, stmt);
    }
}

fn checkStatement(
    allocator: std.mem.Allocator,
    engine: *core.Engine,
    functions: *const std.StringHashMap(ast.FunctionDecl),
    env: *SortEnv,
    result_sort: core.SemanticSort,
    stmt: ast.Statement,
) !void {
    const origin = try statementOrigin(allocator, stmt.span);
    switch (stmt.kind) {
        .let_binding => |binding| {
            const sort = try inferExprSort(allocator, engine, functions, env, binding.expr, origin);
            try env.put(binding.name, sort);
        },
        .bind_binding => |binding| {
            _ = try inferExprSort(allocator, engine, functions, env, binding.expr, origin);
            try env.put(binding.name, .fragment);
        },
        .return_expr => |expr| {
            const actual = try inferExprSort(allocator, engine, functions, env, expr, origin);
            try ensureSort(engine, actual, result_sort, origin, .UnmatchedReturnType);
        },
        .expr_stmt => |expr| {
            _ = try inferExprSort(allocator, engine, functions, env, expr, origin);
        },
        .constrain => |decl| {
            if (decl.offset) |expr| {
                const actual = try inferExprSort(allocator, engine, functions, env, expr, origin);
                try ensureSort(engine, actual, .number, origin, .UnmatchedArgumentType);
            }
        },
        .title, .subtitle, .math, .mathtex, .figure, .image, .pdf_ref, .code, .page_number, .toc, .highlight => {},
    }
}

fn inferExprSort(
    allocator: std.mem.Allocator,
    engine: *core.Engine,
    functions: *const std.StringHashMap(ast.FunctionDecl),
    env: *const SortEnv,
    expr: ast.Expr,
    origin: []const u8,
) anyerror!core.SemanticSort {
    return switch (expr) {
        .string => .string,
        .number => .number,
        .ident => |name| blk: {
            if (env.get(name)) |sort| break :blk sort;
            if (functions.contains(name)) break :blk .function;
            return error.UnknownIdentifier;
        },
        .call => |call| try inferCallSort(allocator, engine, functions, env, call, origin),
    };
}

fn inferCallSort(
    allocator: std.mem.Allocator,
    engine: *core.Engine,
    functions: *const std.StringHashMap(ast.FunctionDecl),
    env: *const SortEnv,
    call: ast.CallExpr,
    origin: []const u8,
) anyerror!core.SemanticSort {
    if (functions.get(call.name)) |func| {
        if (call.args.items.len != func.params.items.len) return error.InvalidArity;
        for (func.params.items, call.args.items) |param, arg| {
            const actual = try inferExprSort(allocator, engine, functions, env, arg, origin);
            try ensureSort(engine, actual, param.sort, origin, .UnmatchedArgumentType);
        }
        return func.result_sort;
    }

    if (registry.lookupPrimitiveCall(call.name)) |descriptor| {
        if (call.args.items.len < descriptor.min_arity or call.args.items.len > descriptor.max_arity) return error.InvalidArity;
        for (call.args.items, 0..) |arg, index| {
            const actual = try inferExprSort(allocator, engine, functions, env, arg, origin);
            if (expectedPrimitiveArgSort(descriptor, index)) |expected| {
                try ensureSort(engine, actual, expected, origin, .UnmatchedArgumentType);
            }
        }
        return descriptor.result_sort orelse .object;
    }

    return error.UnknownFunction;
}

fn expectedPrimitiveArgSort(descriptor: registry.PrimitiveDescriptor, index: usize) ?core.SemanticSort {
    const arg_sort = if (descriptor.arg_sorts.len == 0)
        return null
    else if (index < descriptor.arg_sorts.len)
        descriptor.arg_sorts[index]
    else
        descriptor.arg_sorts[descriptor.arg_sorts.len - 1];

    return switch (arg_sort) {
        .any => null,
        .document => .document,
        .page => .page,
        .object => .object,
        .selection => .selection,
        .anchor => .anchor,
        .function => .function,
        .style => .style,
        .string => .string,
        .number => .number,
        .constraints => .constraints,
    };
}

fn ensureSort(
    engine: *core.Engine,
    actual: core.SemanticSort,
    expected: core.SemanticSort,
    origin: []const u8,
    code: core.TypeMismatchCode,
) !void {
    if (actual != expected) {
        try engine.addValidationDiagnostic(.@"error", null, null, origin, .{
            .type_mismatch = .{ .code = code, .expected = expected, .actual = actual },
        });
        return error.InvalidSemanticSort;
    }
}

fn statementOrigin(allocator: std.mem.Allocator, span: ast.Span) ![]const u8 {
    return std.fmt.allocPrint(allocator, "bytes:{d}-{d}", .{ span.start, span.end });
}
