const std = @import("std");
const ast = @import("ast");
const core = @import("core");

const declarations = @import("../language/declarations.zig");
const registry = @import("../language/registry.zig");
const semantic_env = @import("../language/env.zig");
const syntax_hole = @import("../syntax/hole.zig");

const SemanticEnv = semantic_env.SemanticEnv;

pub fn populateExpectedTypes(allocator: std.mem.Allocator, ir: *core.Ir, holes: *syntax_hole.Result) !void {
    var declaration_index = try declarations.build(allocator, ir);
    defer declaration_index.deinit();
    const sema = SemanticEnv.init(ir, &declaration_index, &ir.functions);
    for (ir.modules.items) |module| {
        var module_sema = sema.forModule(module.id);
        try moduleExpectedTypes(allocator, &module_sema, module.program, holes);
    }
}

fn moduleExpectedTypes(
    allocator: std.mem.Allocator,
    sema: *const SemanticEnv,
    program: ast.Program,
    holes: *syntax_hole.Result,
) !void {
    for (program.constants.items) |decl| {
        try expectExpr(allocator, holes, decl.value, decl.value_type);
        try exprExpectedTypes(allocator, sema, decl.value, holes);
    }
    for (program.functions.items) |func| {
        for (func.params.items) |param| {
            if (param.default_value) |default_value| {
                try expectExpr(allocator, holes, default_value.*, param.ty);
                try exprExpectedTypes(allocator, sema, default_value.*, holes);
            }
        }
        for (func.statements.items) |stmt| try statementExpectedTypes(allocator, sema, stmt, holes, func.result_type);
    }
    for (program.document_statements.items) |stmt| try statementExpectedTypes(allocator, sema, stmt, holes, null);
    for (program.pages.items) |page| {
        for (page.statements.items) |stmt| try statementExpectedTypes(allocator, sema, stmt, holes, null);
    }
    for (program.records.items) |decl| try objectFieldDefaultExpectedTypes(allocator, sema, decl.fields.items, holes);
    for (program.objects.items) |decl| try objectFieldDefaultExpectedTypes(allocator, sema, decl.fields.items, holes);
    for (program.object_extensions.items) |decl| try objectFieldDefaultExpectedTypes(allocator, sema, decl.fields.items, holes);
}

fn statementExpectedTypes(
    allocator: std.mem.Allocator,
    sema: *const SemanticEnv,
    stmt: ast.Statement,
    holes: *syntax_hole.Result,
    function_result: ?ast.Type,
) !void {
    switch (stmt.kind) {
        .hole, .return_void => {},
        .let_binding => |binding| {
            if (binding.type_annotation) |annotation| try expectExpr(allocator, holes, binding.expr, annotation);
            try exprExpectedTypes(allocator, sema, binding.expr, holes);
        },
        .return_expr => |expr| {
            if (function_result) |expected| try expectExpr(allocator, holes, expr, expected);
            try exprExpectedTypes(allocator, sema, expr, holes);
        },
        .property_set => |property_set| try exprExpectedTypes(allocator, sema, property_set.value, holes),
        .constrain => |constraint| {
            if (constraint.offset) |offset| try exprExpectedTypes(allocator, sema, offset, holes);
        },
        .expr_stmt => |expr| try exprExpectedTypes(allocator, sema, expr, holes),
        .if_stmt => |if_stmt| {
            try expectExpr(allocator, holes, if_stmt.condition, ast.Type.boolean);
            try exprExpectedTypes(allocator, sema, if_stmt.condition, holes);
            for (if_stmt.then_statements.items) |nested| try statementExpectedTypes(allocator, sema, nested, holes, function_result);
            for (if_stmt.else_statements.items) |nested| try statementExpectedTypes(allocator, sema, nested, holes, function_result);
        },
    }
}

fn exprExpectedTypes(
    allocator: std.mem.Allocator,
    sema: *const SemanticEnv,
    expr: ast.Expr,
    holes: *syntax_hole.Result,
) !void {
    switch (expr) {
        .hole, .ident, .string, .color, .number, .boolean, .none, .enum_case => {},
        .call => |call| {
            try callArgExpectedTypes(allocator, sema, call, holes);
            for (call.args.items) |arg| try exprExpectedTypes(allocator, sema, arg, holes);
        },
        .apply => |apply| {
            try exprExpectedTypes(allocator, sema, apply.callee.*, holes);
            for (apply.args.items) |arg| try exprExpectedTypes(allocator, sema, arg, holes);
        },
        .lambda => |lambda| try exprExpectedTypes(allocator, sema, lambda.body.*, holes),
        .member => |member| try exprExpectedTypes(allocator, sema, member.target.*, holes),
        .record => |record| {
            try recordFieldExpectedTypes(allocator, sema, record, holes);
            for (record.fields.items) |field| try exprExpectedTypes(allocator, sema, field.value, holes);
        },
        .record_update => |update| {
            try exprExpectedTypes(allocator, sema, update.target.*, holes);
            for (update.fields.items) |field| try exprExpectedTypes(allocator, sema, field.value, holes);
        },
        .optional_check => |check| try exprExpectedTypes(allocator, sema, check.target.*, holes),
        .coalesce => |coalesce| {
            try exprExpectedTypes(allocator, sema, coalesce.target.*, holes);
            try exprExpectedTypes(allocator, sema, coalesce.fallback.*, holes);
        },
    }
}

fn callArgExpectedTypes(
    allocator: std.mem.Allocator,
    sema: *const SemanticEnv,
    call: ast.CallExpr,
    holes: *syntax_hole.Result,
) !void {
    if (call.callee.name_hole != null) return;
    if (sema.callCallee(call.callee)) |descriptor| switch (descriptor) {
        .function => |resolved| {
            const count = @min(call.args.items.len, resolved.decl.params.items.len);
            for (call.args.items[0..count], resolved.decl.params.items[0..count]) |arg, param| {
                try expectExpr(allocator, holes, arg, param.ty);
            }
        },
        .primitive => |primitive| {
            const count = @min(call.args.items.len, primitive.arg_types.len);
            for (call.args.items[0..count], 0..) |arg, index| {
                if (registry.primitiveArgType(primitive, index)) |expected| try expectExpr(allocator, holes, arg, expected);
            }
        },
    };
}

fn recordFieldExpectedTypes(
    allocator: std.mem.Allocator,
    sema: *const SemanticEnv,
    record: ast.RecordExpr,
    holes: *syntax_hole.Result,
) !void {
    for (record.fields.items) |field_expr| {
        const field = sema.recordField(record.type_name, field_expr.name) orelse continue;
        try expectExpr(allocator, holes, field_expr.value, field.value_type);
    }
}

fn objectFieldDefaultExpectedTypes(
    allocator: std.mem.Allocator,
    sema: *const SemanticEnv,
    fields: []const ast.ObjectFieldDecl,
    holes: *syntax_hole.Result,
) !void {
    for (fields) |field| {
        const default_value = field.default_value orelse continue;
        try expectExpr(allocator, holes, default_value.*, field.value_type);
        try exprExpectedTypes(allocator, sema, default_value.*, holes);
    }
}

fn expectExpr(allocator: std.mem.Allocator, holes: *syntax_hole.Result, expr: ast.Expr, expected: ast.Type) !void {
    switch (expr) {
        .hole => |id| try holes.setExpectedType(allocator, id, expected),
        .call => |call| {
            if (call.callee.name_hole) |id| try holes.setExpectedType(allocator, id, expected);
            for (call.args.items) |arg| try expectExpr(allocator, holes, arg, expected);
        },
        .apply => |apply| {
            try expectExpr(allocator, holes, apply.callee.*, expected);
            for (apply.args.items) |arg| try expectExpr(allocator, holes, arg, expected);
        },
        .lambda => |lambda| try expectExpr(allocator, holes, lambda.body.*, expected),
        .member => |member| {
            if (member.name_hole) |id| try holes.setExpectedType(allocator, id, expected);
            try expectExpr(allocator, holes, member.target.*, expected);
        },
        .record => |record| for (record.fields.items) |field| try expectExpr(allocator, holes, field.value, expected),
        .record_update => |update| {
            try expectExpr(allocator, holes, update.target.*, expected);
            for (update.fields.items) |field| try expectExpr(allocator, holes, field.value, expected);
        },
        .optional_check => |check| try expectExpr(allocator, holes, check.target.*, expected),
        .coalesce => |coalesce| {
            try expectExpr(allocator, holes, coalesce.target.*, expected);
            try expectExpr(allocator, holes, coalesce.fallback.*, expected);
        },
        .ident, .string, .color, .number, .boolean, .none, .enum_case => {},
    }
}
