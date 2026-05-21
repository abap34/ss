const std = @import("std");
const ast = @import("ast");
const core = @import("core");

const semantic_env = @import("../language/env.zig");

const SemanticEnv = semantic_env.SemanticEnv;

fn isConst(func: ast.FunctionDecl) bool {
    return func.kind == .constant;
}

pub fn checkFunctionCallGraph(
    allocator: std.mem.Allocator,
    ir: *core.Ir,
    sema: *const SemanticEnv,
) !void {
    var states = std.StringHashMap(u8).init(allocator);
    defer states.deinit();

    var it = sema.functions.iterator();
    while (it.next()) |entry| {
        try visitFunction(allocator, ir, sema, &states, entry.key_ptr.*);
    }
}

fn visitFunction(
    allocator: std.mem.Allocator,
    ir: *core.Ir,
    sema: *const SemanticEnv,
    states: *std.StringHashMap(u8),
    name: []const u8,
) !void {
    if (states.get(name)) |state| {
        if (state == 1) {
            const func = sema.function(name).?;
            try reportRecursiveFunction(allocator, ir, func);
            return error.RecursiveFunction;
        }
        if (state == 2) return;
    }

    const func = sema.function(name) orelse return;
    try states.put(name, 1);

    var callees = std.ArrayList([]const u8).empty;
    defer callees.deinit(allocator);
    try collectFunctionCallees(allocator, sema, func, &callees);
    for (callees.items) |callee| {
        if (states.get(callee)) |state| {
            if (state == 1) {
                try reportRecursiveFunction(allocator, ir, func);
                return error.RecursiveFunction;
            }
        }
        try visitFunction(allocator, ir, sema, states, callee);
    }

    try states.put(name, 2);
}

fn reportRecursiveFunction(allocator: std.mem.Allocator, ir: *core.Ir, func: ast.FunctionDecl) !void {
    try ir.addValidationDiagnostic(.@"error", null, null, try functionOrigin(allocator, ir, func), .{
        .recursive_function = .{ .function_name = func.name },
    });
}

fn collectFunctionCallees(
    allocator: std.mem.Allocator,
    sema: *const SemanticEnv,
    func: ast.FunctionDecl,
    callees: *std.ArrayList([]const u8),
) !void {
    for (func.params.items) |param| {
        if (param.default_value) |default_value| {
            try collectExprCallees(allocator, sema, default_value.*, callees);
        }
    }
    for (func.statements.items) |stmt| {
        try collectStatementCallees(allocator, sema, stmt, callees);
    }
}

fn collectStatementCallees(
    allocator: std.mem.Allocator,
    sema: *const SemanticEnv,
    stmt: ast.Statement,
    callees: *std.ArrayList([]const u8),
) !void {
    switch (stmt.kind) {
        .let_binding => |binding| try collectExprCallees(allocator, sema, binding.expr, callees),
        .return_expr => |expr| try collectExprCallees(allocator, sema, expr, callees),
        .property_set => |property_set| try collectExprCallees(allocator, sema, property_set.value, callees),
        .if_stmt => |if_stmt| {
            try collectExprCallees(allocator, sema, if_stmt.condition, callees);
            for (if_stmt.then_statements.items) |nested| try collectStatementCallees(allocator, sema, nested, callees);
            for (if_stmt.else_statements.items) |nested| try collectStatementCallees(allocator, sema, nested, callees);
        },
        .constrain => |decl| if (decl.offset) |expr| try collectExprCallees(allocator, sema, expr, callees),
        .expr_stmt => |expr| try collectExprCallees(allocator, sema, expr, callees),
    }
}

fn collectExprCallees(
    allocator: std.mem.Allocator,
    sema: *const SemanticEnv,
    expr: ast.Expr,
    callees: *std.ArrayList([]const u8),
) !void {
    switch (expr) {
        .ident => |name| {
            if (sema.function(name)) |func| {
                if (isConst(func)) try appendUniqueCallee(allocator, callees, name);
            }
        },
        .call => |call| {
            if (sema.call(call.name)) |descriptor| {
                switch (descriptor) {
                    .function => |func| {
                        if (!isConst(func)) try appendUniqueCallee(allocator, callees, call.name);
                    },
                    .primitive => |primitive| {
                        if (primitive.op == .foreach or primitive.op == .fold or primitive.op == .join) {
                            const callback_index: usize = if (primitive.op == .foreach) 1 else 2;
                            if (call.args.items.len > callback_index) {
                                switch (call.args.items[callback_index]) {
                                    .ident => |name| if (sema.hasFunction(name)) try appendUniqueCallee(allocator, callees, name),
                                    else => {},
                                }
                            }
                        }
                    },
                }
            }
            for (call.args.items) |arg| try collectExprCallees(allocator, sema, arg, callees);
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

fn functionOrigin(allocator: std.mem.Allocator, ir: *const core.Ir, func: ast.FunctionDecl) ![]const u8 {
    if (ir.function_metadata.get(func.name)) |metadata| {
        if (ir.moduleById(metadata.module_id)) |module| {
            const path = module.path orelse module.spec;
            if (path.len != 0) return std.fmt.allocPrint(allocator, "path:{s}:bytes:{d}-{d}", .{ path, func.span.start, func.span.end });
        }
    }
    return std.fmt.allocPrint(allocator, "bytes:{d}-{d}", .{ func.span.start, func.span.end });
}
