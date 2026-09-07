const std = @import("std");
const ast = @import("ast");
const QueryBudget = @import("types.zig").QueryBudget;

const language_names = @import("../../language/names.zig");

pub const SourceNameKind = enum {
    import_spec,
    import_alias,
    callable_qualifier,
    callable_name,
    identifier,
    member_name,
    record_field_name,
    record_update_path_segment,
    enum_name,
    enum_case_name,
};

pub const SourceNameTarget = struct {
    text: []const u8,
    kind: SourceNameKind,
    qualifier: ?[]const u8 = null,
};

pub const RecordUpdatePathTarget = struct {
    target: ast.Expr,
    path: []const ast.RecordPathSegment,
    segment_index: usize,
};

pub const RecordUpdateCompletionTarget = struct {
    target: ast.Expr,
    path_prefix: []const ast.RecordPathSegment,
};

pub const MemberTarget = struct {
    target: ast.Expr,
    name: []const u8,
};

pub const LetBindingTarget = struct {
    expr: ast.Expr,
};

pub const QualifiedCallableRole = enum {
    qualifier,
    name,
};

pub const QualifiedCallableTarget = struct {
    qualifier: []const u8,
    name: []const u8,
    role: QualifiedCallableRole,
};

pub const CallableTarget = struct {
    callee: ast.CallableName,
    role: QualifiedCallableRole,
};

pub fn callableAt(budget: ?QueryBudget, program: *const ast.Module, offset: usize) ?CallableTarget {
    if (expired(budget)) return null;
    for (program.records.items) |record| {
        if (expired(budget)) return null;
        if (callableInFields(budget, record.fields.items, offset)) |target| return target;
    }
    for (program.objects.items) |object| {
        if (expired(budget)) return null;
        if (callableInFields(budget, object.fields.items, offset)) |target| return target;
    }
    for (program.object_extensions.items) |extension| {
        if (expired(budget)) return null;
        if (callableInFields(budget, extension.fields.items, offset)) |target| return target;
    }
    for (program.constants.items) |constant_decl| {
        if (expired(budget)) return null;
        if (callableInExpr(budget, constant_decl.value, offset)) |target| return target;
    }
    for (program.functions.items) |func| {
        if (expired(budget)) return null;
        if (callableInStatements(budget, func.statements.items, offset)) |target| return target;
    }
    if (callableInStatements(budget, program.document_statements.items, offset)) |target| return target;
    for (program.pages.items) |page| {
        if (expired(budget)) return null;
        if (callableInStatements(budget, page.statements.items, offset)) |target| return target;
    }
    return null;
}

pub fn sourceNameAt(budget: ?QueryBudget, program: *const ast.Module, offset: usize) ?SourceNameTarget {
    if (expired(budget)) return null;
    for (program.imports.items) |import_decl| {
        if (expired(budget)) return null;
        if (spanContainsOffset(import_decl.spec_span, offset)) return .{
            .text = import_decl.spec,
            .kind = .import_spec,
        };
        if (import_decl.alias_span) |alias_span| {
            if (spanContainsOffset(alias_span, offset)) return .{
                .text = import_decl.mode.alias orelse "",
                .kind = .import_alias,
            };
        }
    }
    for (program.records.items) |record| {
        if (expired(budget)) return null;
        if (sourceNameInFields(budget, record.fields.items, offset)) |target| return target;
    }
    for (program.objects.items) |object| {
        if (expired(budget)) return null;
        if (sourceNameInFields(budget, object.fields.items, offset)) |target| return target;
    }
    for (program.object_extensions.items) |extension| {
        if (expired(budget)) return null;
        if (sourceNameInFields(budget, extension.fields.items, offset)) |target| return target;
    }
    for (program.constants.items) |constant_decl| {
        if (expired(budget)) return null;
        if (sourceNameInType(budget, constant_decl.value_type, offset)) |target| return target;
        if (sourceNameInExpr(budget, constant_decl.value, offset)) |target| return target;
    }
    for (program.functions.items) |func| {
        if (expired(budget)) return null;
        for (func.params.items) |param| {
            if (expired(budget)) return null;
            if (spanContainsOptional(param.name_span, offset)) return .{
                .text = param.name,
                .kind = .identifier,
            };
            if (sourceNameInType(budget, param.ty, offset)) |target| return target;
        }
        if (sourceNameInType(budget, func.result_type, offset)) |target| return target;
        if (sourceNameInStatements(budget, func.statements.items, offset)) |target| return target;
    }
    if (sourceNameInStatements(budget, program.document_statements.items, offset)) |target| return target;
    for (program.pages.items) |page| {
        if (expired(budget)) return null;
        if (sourceNameInStatements(budget, page.statements.items, offset)) |target| return target;
    }
    return null;
}

pub fn recordUpdatePathAt(budget: ?QueryBudget, program: *const ast.Module, offset: usize) ?RecordUpdatePathTarget {
    if (expired(budget)) return null;
    for (program.records.items) |record| {
        if (expired(budget)) return null;
        if (recordUpdatePathInFields(budget, record.fields.items, offset)) |target| return target;
    }
    for (program.objects.items) |object| {
        if (expired(budget)) return null;
        if (recordUpdatePathInFields(budget, object.fields.items, offset)) |target| return target;
    }
    for (program.object_extensions.items) |extension| {
        if (expired(budget)) return null;
        if (recordUpdatePathInFields(budget, extension.fields.items, offset)) |target| return target;
    }
    for (program.constants.items) |constant_decl| {
        if (expired(budget)) return null;
        if (recordUpdatePathInExpr(budget, constant_decl.value, offset)) |target| return target;
    }
    for (program.functions.items) |func| {
        if (expired(budget)) return null;
        for (func.params.items) |param| {
            if (expired(budget)) return null;
            if (param.default_value) |default_value| {
                if (recordUpdatePathInExpr(budget, default_value.*, offset)) |target| return target;
            }
        }
        if (recordUpdatePathInStatements(budget, func.statements.items, offset)) |target| return target;
    }
    if (recordUpdatePathInStatements(budget, program.document_statements.items, offset)) |target| return target;
    for (program.pages.items) |page| {
        if (expired(budget)) return null;
        if (recordUpdatePathInStatements(budget, page.statements.items, offset)) |target| return target;
    }
    return null;
}

pub fn recordUpdateCompletionAt(budget: ?QueryBudget, program: *const ast.Module, offset: usize) ?RecordUpdateCompletionTarget {
    if (expired(budget)) return null;
    for (program.records.items) |record| {
        if (expired(budget)) return null;
        if (recordUpdateCompletionInFields(budget, record.fields.items, offset)) |target| return target;
    }
    for (program.objects.items) |object| {
        if (expired(budget)) return null;
        if (recordUpdateCompletionInFields(budget, object.fields.items, offset)) |target| return target;
    }
    for (program.object_extensions.items) |extension| {
        if (expired(budget)) return null;
        if (recordUpdateCompletionInFields(budget, extension.fields.items, offset)) |target| return target;
    }
    for (program.constants.items) |constant_decl| {
        if (expired(budget)) return null;
        if (recordUpdateCompletionInExpr(budget, constant_decl.value, offset)) |target| return target;
    }
    for (program.functions.items) |func| {
        if (expired(budget)) return null;
        for (func.params.items) |param| {
            if (expired(budget)) return null;
            if (param.default_value) |default_value| {
                if (recordUpdateCompletionInExpr(budget, default_value.*, offset)) |target| return target;
            }
        }
        if (recordUpdateCompletionInStatements(budget, func.statements.items, offset)) |target| return target;
    }
    if (recordUpdateCompletionInStatements(budget, program.document_statements.items, offset)) |target| return target;
    for (program.pages.items) |page| {
        if (expired(budget)) return null;
        if (recordUpdateCompletionInStatements(budget, page.statements.items, offset)) |target| return target;
    }
    return null;
}

pub fn memberAt(budget: ?QueryBudget, program: *const ast.Module, offset: usize) ?MemberTarget {
    if (expired(budget)) return null;
    for (program.records.items) |record| {
        if (expired(budget)) return null;
        if (memberInFields(budget, record.fields.items, offset)) |target| return target;
    }
    for (program.objects.items) |object| {
        if (expired(budget)) return null;
        if (memberInFields(budget, object.fields.items, offset)) |target| return target;
    }
    for (program.object_extensions.items) |extension| {
        if (expired(budget)) return null;
        if (memberInFields(budget, extension.fields.items, offset)) |target| return target;
    }
    for (program.constants.items) |constant_decl| {
        if (expired(budget)) return null;
        if (memberInExpr(budget, constant_decl.value, offset)) |target| return target;
    }
    for (program.functions.items) |func| {
        if (expired(budget)) return null;
        for (func.params.items) |param| {
            if (expired(budget)) return null;
            if (param.default_value) |default_value| {
                if (memberInExpr(budget, default_value.*, offset)) |target| return target;
            }
        }
        if (memberInStatements(budget, func.statements.items, offset)) |target| return target;
    }
    if (memberInStatements(budget, program.document_statements.items, offset)) |target| return target;
    for (program.pages.items) |page| {
        if (expired(budget)) return null;
        if (memberInStatements(budget, page.statements.items, offset)) |target| return target;
    }
    return null;
}

pub fn visibleLetBindingAt(budget: ?QueryBudget, program: *const ast.Module, offset: usize, name: []const u8) ?LetBindingTarget {
    if (expired(budget)) return null;
    for (program.functions.items) |func| {
        if (expired(budget)) return null;
        if (!spanContainsOffset(func.span, offset)) continue;
        return visibleLetBindingInStatements(budget, func.statements.items, offset, name);
    }
    for (program.document_blocks.items) |block| {
        if (expired(budget)) return null;
        if (!spanContainsOffset(block.span, offset)) continue;
        const statements = program.document_statements.items[block.statement_start .. block.statement_start + block.statement_count];
        return visibleLetBindingInStatements(budget, statements, offset, name);
    }
    for (program.pages.items) |page| {
        if (expired(budget)) return null;
        if (!spanContainsOffset(page.span, offset)) continue;
        return visibleLetBindingInStatements(budget, page.statements.items, offset, name);
    }
    return null;
}

pub fn qualifiedCallableAt(budget: ?QueryBudget, program: *const ast.Module, offset: usize) ?QualifiedCallableTarget {
    if (expired(budget)) return null;
    const target = callableAt(budget, program, offset) orelse return null;
    const qualifier = target.callee.qualifier orelse return null;
    return .{
        .qualifier = qualifier,
        .name = target.callee.name,
        .role = target.role,
    };
}

pub fn qualifiedCallableQualifierForName(budget: ?QueryBudget, program: *const ast.Module, offset: usize) ?[]const u8 {
    if (expired(budget)) return null;
    const target = qualifiedCallableAt(budget, program, offset) orelse return null;
    if (target.role != .name) return null;
    return target.qualifier;
}

pub fn isQualifiedCallableQualifierAt(budget: ?QueryBudget, program: *const ast.Module, offset: usize) bool {
    if (expired(budget)) return false;
    const target = qualifiedCallableAt(budget, program, offset) orelse return false;
    return target.role == .qualifier;
}

pub fn isImportAliasAt(budget: ?QueryBudget, program: *const ast.Module, offset: usize) bool {
    if (expired(budget)) return false;
    for (program.imports.items) |import_decl| {
        if (expired(budget)) return false;
        const alias_span = import_decl.alias_span orelse continue;
        if (spanContainsOffset(alias_span, offset)) return true;
    }
    return false;
}

pub fn importSpecAt(budget: ?QueryBudget, program: *const ast.Module, offset: usize) ?[]const u8 {
    if (expired(budget)) return null;
    for (program.imports.items) |import_decl| {
        if (expired(budget)) return null;
        if (spanContainsOffset(import_decl.spec_span, offset)) return import_decl.spec;
    }
    return null;
}

fn callableInFields(budget: ?QueryBudget, fields: []const ast.ObjectFieldDecl, offset: usize) ?CallableTarget {
    if (expired(budget)) return null;
    for (fields) |field| {
        if (expired(budget)) return null;
        const default_value = field.default_value orelse continue;
        if (callableInExpr(budget, default_value.*, offset)) |target| return target;
    }
    return null;
}

fn sourceNameInFields(budget: ?QueryBudget, fields: []const ast.ObjectFieldDecl, offset: usize) ?SourceNameTarget {
    if (expired(budget)) return null;
    for (fields) |field| {
        if (expired(budget)) return null;
        if (sourceNameInType(budget, field.value_type, offset)) |target| return target;
        const default_value = field.default_value orelse continue;
        if (sourceNameInExpr(budget, default_value.*, offset)) |target| return target;
    }
    return null;
}

fn recordUpdatePathInFields(budget: ?QueryBudget, fields: []const ast.ObjectFieldDecl, offset: usize) ?RecordUpdatePathTarget {
    if (expired(budget)) return null;
    for (fields) |field| {
        if (expired(budget)) return null;
        const default_value = field.default_value orelse continue;
        if (recordUpdatePathInExpr(budget, default_value.*, offset)) |target| return target;
    }
    return null;
}

fn recordUpdateCompletionInFields(budget: ?QueryBudget, fields: []const ast.ObjectFieldDecl, offset: usize) ?RecordUpdateCompletionTarget {
    if (expired(budget)) return null;
    for (fields) |field| {
        if (expired(budget)) return null;
        const default_value = field.default_value orelse continue;
        if (recordUpdateCompletionInExpr(budget, default_value.*, offset)) |target| return target;
    }
    return null;
}

fn memberInFields(budget: ?QueryBudget, fields: []const ast.ObjectFieldDecl, offset: usize) ?MemberTarget {
    if (expired(budget)) return null;
    for (fields) |field| {
        if (expired(budget)) return null;
        const default_value = field.default_value orelse continue;
        if (memberInExpr(budget, default_value.*, offset)) |target| return target;
    }
    return null;
}

fn callableInStatements(budget: ?QueryBudget, statements: []const ast.Statement, offset: usize) ?CallableTarget {
    if (expired(budget)) return null;
    for (statements) |stmt| {
        if (expired(budget)) return null;
        if (!spanContainsOffset(stmt.span, offset)) continue;
        if (callableInStatement(budget, stmt, offset)) |target| return target;
    }
    return null;
}

fn sourceNameInStatements(budget: ?QueryBudget, statements: []const ast.Statement, offset: usize) ?SourceNameTarget {
    if (expired(budget)) return null;
    for (statements) |stmt| {
        if (expired(budget)) return null;
        if (!spanContainsOffset(stmt.span, offset)) continue;
        if (sourceNameInStatement(budget, stmt, offset)) |target| return target;
    }
    return null;
}

fn recordUpdatePathInStatements(budget: ?QueryBudget, statements: []const ast.Statement, offset: usize) ?RecordUpdatePathTarget {
    if (expired(budget)) return null;
    for (statements) |stmt| {
        if (expired(budget)) return null;
        if (!spanContainsOffset(stmt.span, offset)) continue;
        if (recordUpdatePathInStatement(budget, stmt, offset)) |target| return target;
    }
    return null;
}

fn recordUpdateCompletionInStatements(budget: ?QueryBudget, statements: []const ast.Statement, offset: usize) ?RecordUpdateCompletionTarget {
    if (expired(budget)) return null;
    for (statements) |stmt| {
        if (expired(budget)) return null;
        if (!spanContainsOffset(stmt.span, offset)) continue;
        if (recordUpdateCompletionInStatement(budget, stmt, offset)) |target| return target;
    }
    return null;
}

fn memberInStatements(budget: ?QueryBudget, statements: []const ast.Statement, offset: usize) ?MemberTarget {
    if (expired(budget)) return null;
    for (statements) |stmt| {
        if (expired(budget)) return null;
        if (!spanContainsOffset(stmt.span, offset)) continue;
        if (memberInStatement(budget, stmt, offset)) |target| return target;
    }
    return null;
}

fn visibleLetBindingInStatements(budget: ?QueryBudget, statements: []const ast.Statement, offset: usize, name: []const u8) ?LetBindingTarget {
    if (expired(budget)) return null;
    var best: ?LetBindingTarget = null;
    for (statements) |stmt| {
        if (expired(budget)) return null;
        if (stmt.span.start > offset) break;
        switch (stmt.kind) {
            .let_binding => |binding| {
                if (stmt.span.end <= offset and std.mem.eql(u8, binding.name, name)) {
                    best = .{ .expr = binding.expr };
                }
            },
            .if_stmt => |if_stmt| {
                if (spanContainsOffset(stmt.span, offset)) {
                    if (visibleLetBindingInStatements(budget, if_stmt.then_statements.items, offset, name)) |target| best = target;
                    if (visibleLetBindingInStatements(budget, if_stmt.else_statements.items, offset, name)) |target| best = target;
                }
            },
            else => {},
        }
    }
    return best;
}

fn callableInStatement(budget: ?QueryBudget, stmt: ast.Statement, offset: usize) ?CallableTarget {
    if (expired(budget)) return null;
    return switch (stmt.kind) {
        .hole => null,
        .let_binding => |binding| callableInExpr(budget, binding.expr, offset),
        .return_expr => |expr| callableInExpr(budget, expr, offset),
        .return_void => null,
        .constrain => |constraint| if (constraint.offset) |expr| callableInExpr(budget, expr, offset) else null,
        .property_set => |property_set| blk: {
            if (callableInExpr(budget, property_set.target, offset)) |target| break :blk target;
            break :blk callableInExpr(budget, property_set.value, offset);
        },
        .if_stmt => |if_stmt| blk: {
            if (callableInExpr(budget, if_stmt.condition, offset)) |target| break :blk target;
            if (callableInStatements(budget, if_stmt.then_statements.items, offset)) |target| break :blk target;
            break :blk callableInStatements(budget, if_stmt.else_statements.items, offset);
        },
        .expr_stmt => |expr| callableInExpr(budget, expr, offset),
    };
}

fn sourceNameInStatement(budget: ?QueryBudget, stmt: ast.Statement, offset: usize) ?SourceNameTarget {
    if (expired(budget)) return null;
    return switch (stmt.kind) {
        .hole => null,
        .let_binding => |binding| blk: {
            if (spanContainsOptional(binding.name_span, offset)) break :blk .{
                .text = binding.name,
                .kind = .identifier,
            };
            if (binding.type_annotation) |annotation| {
                if (sourceNameInType(budget, annotation, offset)) |target| break :blk target;
            }
            break :blk sourceNameInExpr(budget, binding.expr, offset);
        },
        .return_expr => |expr| sourceNameInExpr(budget, expr, offset),
        .return_void => null,
        .constrain => |constraint| if (constraint.offset) |expr| sourceNameInExpr(budget, expr, offset) else null,
        .property_set => |property_set| blk: {
            if (sourceNameInExpr(budget, property_set.target, offset)) |target| break :blk target;
            if (pathSegmentAt(budget, property_set.path.items, offset)) |target| break :blk .{
                .text = target.segment.name,
                .kind = .member_name,
            };
            break :blk sourceNameInExpr(budget, property_set.value, offset);
        },
        .if_stmt => |if_stmt| blk: {
            if (sourceNameInExpr(budget, if_stmt.condition, offset)) |target| break :blk target;
            if (sourceNameInStatements(budget, if_stmt.then_statements.items, offset)) |target| break :blk target;
            break :blk sourceNameInStatements(budget, if_stmt.else_statements.items, offset);
        },
        .expr_stmt => |expr| sourceNameInExpr(budget, expr, offset),
    };
}

fn recordUpdatePathInStatement(budget: ?QueryBudget, stmt: ast.Statement, offset: usize) ?RecordUpdatePathTarget {
    if (expired(budget)) return null;
    return switch (stmt.kind) {
        .hole, .return_void => null,
        .let_binding => |binding| recordUpdatePathInExpr(budget, binding.expr, offset),
        .return_expr => |expr| recordUpdatePathInExpr(budget, expr, offset),
        .constrain => |constraint| if (constraint.offset) |expr| recordUpdatePathInExpr(budget, expr, offset) else null,
        .property_set => |property_set| blk: {
            if (recordUpdatePathInExpr(budget, property_set.target, offset)) |target| break :blk target;
            break :blk recordUpdatePathInExpr(budget, property_set.value, offset);
        },
        .if_stmt => |if_stmt| blk: {
            if (recordUpdatePathInExpr(budget, if_stmt.condition, offset)) |target| break :blk target;
            if (recordUpdatePathInStatements(budget, if_stmt.then_statements.items, offset)) |target| break :blk target;
            break :blk recordUpdatePathInStatements(budget, if_stmt.else_statements.items, offset);
        },
        .expr_stmt => |expr| recordUpdatePathInExpr(budget, expr, offset),
    };
}

fn recordUpdateCompletionInStatement(budget: ?QueryBudget, stmt: ast.Statement, offset: usize) ?RecordUpdateCompletionTarget {
    if (expired(budget)) return null;
    return switch (stmt.kind) {
        .hole, .return_void => null,
        .let_binding => |binding| recordUpdateCompletionInExpr(budget, binding.expr, offset),
        .return_expr => |expr| recordUpdateCompletionInExpr(budget, expr, offset),
        .constrain => |constraint| if (constraint.offset) |expr| recordUpdateCompletionInExpr(budget, expr, offset) else null,
        .property_set => |property_set| blk: {
            if (recordUpdateCompletionInExpr(budget, property_set.target, offset)) |target| break :blk target;
            break :blk recordUpdateCompletionInExpr(budget, property_set.value, offset);
        },
        .if_stmt => |if_stmt| blk: {
            if (recordUpdateCompletionInExpr(budget, if_stmt.condition, offset)) |target| break :blk target;
            if (recordUpdateCompletionInStatements(budget, if_stmt.then_statements.items, offset)) |target| break :blk target;
            break :blk recordUpdateCompletionInStatements(budget, if_stmt.else_statements.items, offset);
        },
        .expr_stmt => |expr| recordUpdateCompletionInExpr(budget, expr, offset),
    };
}

fn memberInStatement(budget: ?QueryBudget, stmt: ast.Statement, offset: usize) ?MemberTarget {
    if (expired(budget)) return null;
    return switch (stmt.kind) {
        .hole, .return_void => null,
        .let_binding => |binding| memberInExpr(budget, binding.expr, offset),
        .return_expr => |expr| memberInExpr(budget, expr, offset),
        .constrain => |constraint| if (constraint.offset) |expr| memberInExpr(budget, expr, offset) else null,
        .property_set => |property_set| blk: {
            if (memberInExpr(budget, property_set.target, offset)) |target| break :blk target;
            const target = pathSegmentAt(budget, property_set.path.items, offset) orelse break :blk memberInExpr(budget, property_set.value, offset);
            if (target.index == 0) break :blk .{
                .target = property_set.target,
                .name = target.segment.name,
            };
            break :blk memberInExpr(budget, property_set.value, offset);
        },
        .if_stmt => |if_stmt| blk: {
            if (memberInExpr(budget, if_stmt.condition, offset)) |target| break :blk target;
            if (memberInStatements(budget, if_stmt.then_statements.items, offset)) |target| break :blk target;
            break :blk memberInStatements(budget, if_stmt.else_statements.items, offset);
        },
        .expr_stmt => |expr| memberInExpr(budget, expr, offset),
    };
}

fn callableInExpr(budget: ?QueryBudget, expr: ast.Expr, offset: usize) ?CallableTarget {
    if (expired(budget)) return null;
    return switch (expr) {
        .call => |call| blk: {
            if (callableNameAt(call.callee, offset)) |target| break :blk target;
            for (call.args.items) |arg| {
                if (expired(budget)) return null;
                if (callableInExpr(budget, arg, offset)) |target| break :blk target;
            }
            break :blk null;
        },
        .apply => |apply| blk: {
            if (callableInExpr(budget, apply.callee.*, offset)) |target| break :blk target;
            for (apply.args.items) |arg| {
                if (expired(budget)) return null;
                if (callableInExpr(budget, arg, offset)) |target| break :blk target;
            }
            break :blk null;
        },
        .lambda => |lambda| callableInExpr(budget, lambda.body.*, offset),
        .record => |record| blk: {
            for (record.fields.items) |field| {
                if (expired(budget)) return null;
                if (callableInExpr(budget, field.value, offset)) |target| break :blk target;
            }
            break :blk null;
        },
        .record_update => |update| blk: {
            if (callableInExpr(budget, update.target.*, offset)) |target| break :blk target;
            for (update.fields.items) |field| {
                if (expired(budget)) return null;
                if (callableInExpr(budget, field.value, offset)) |target| break :blk target;
            }
            break :blk null;
        },
        .member => |member| callableInExpr(budget, member.target.*, offset),
        .optional_check => |check| callableInExpr(budget, check.target.*, offset),
        .coalesce => |coalesce| blk: {
            if (callableInExpr(budget, coalesce.target.*, offset)) |target| break :blk target;
            break :blk callableInExpr(budget, coalesce.fallback.*, offset);
        },
        else => null,
    };
}

fn sourceNameInType(budget: ?QueryBudget, ty: ast.Type, offset: usize) ?SourceNameTarget {
    if (expired(budget)) return null;
    return switch (ty.kind) {
        .object, .record => if (spanContainsOptional(ty.class_name_span, offset)) .{
            .text = ty.class_name orelse "",
            .kind = .identifier,
        } else null,
        .enum_type => if (spanContainsOptional(ty.enum_name_span, offset)) .{
            .text = ty.enum_name orelse "",
            .kind = .identifier,
        } else null,
        .selection => if (spanContainsOptional(ty.param_class_name_span, offset)) .{
            .text = ty.param_class_name orelse "",
            .kind = .identifier,
        } else null,
        .function => blk: {
            for (ty.fn_params) |param| {
                if (expired(budget)) return null;
                if (sourceNameInType(budget, param, offset)) |target| break :blk target;
            }
            if (ty.fn_result) |result| break :blk sourceNameInType(budget, result.*, offset);
            break :blk null;
        },
        .optional => if (ty.optional_child) |child| sourceNameInType(budget, child.*, offset) else null,
        else => null,
    };
}

fn sourceNameInExpr(budget: ?QueryBudget, expr: ast.Expr, offset: usize) ?SourceNameTarget {
    if (expired(budget)) return null;
    return switch (expr) {
        .ident => |ident| if (spanContainsOptional(ident.name_span, offset)) .{
            .text = ident.name,
            .kind = .identifier,
        } else null,
        .call => |call| blk: {
            if (sourceNameInCallable(call.callee, offset)) |target| break :blk target;
            for (call.args.items) |arg| {
                if (expired(budget)) return null;
                if (sourceNameInExpr(budget, arg, offset)) |target| break :blk target;
            }
            break :blk null;
        },
        .apply => |apply| blk: {
            if (sourceNameInExpr(budget, apply.callee.*, offset)) |target| break :blk target;
            for (apply.args.items) |arg| {
                if (expired(budget)) return null;
                if (sourceNameInExpr(budget, arg, offset)) |target| break :blk target;
            }
            break :blk null;
        },
        .lambda => |lambda| blk: {
            for (lambda.params.items) |param| {
                if (expired(budget)) return null;
                if (spanContainsOptional(param.name_span, offset)) break :blk .{
                    .text = param.name,
                    .kind = .identifier,
                };
            }
            break :blk sourceNameInExpr(budget, lambda.body.*, offset);
        },
        .member => |member| blk: {
            if (spanContainsOptional(member.name_span, offset)) break :blk .{
                .text = member.name,
                .kind = .member_name,
                .qualifier = simpleIdentifierName(member.target.*),
            };
            break :blk sourceNameInExpr(budget, member.target.*, offset);
        },
        .record => |record| blk: {
            if (spanContainsOptional(record.type_name_span, offset)) break :blk .{
                .text = record.type_name,
                .kind = .identifier,
            };
            for (record.fields.items) |field| {
                if (expired(budget)) return null;
                if (spanContainsOptional(field.name_span, offset)) break :blk .{
                    .text = field.name,
                    .kind = .record_field_name,
                    .qualifier = record.type_name,
                };
                if (sourceNameInExpr(budget, field.value, offset)) |target| break :blk target;
            }
            break :blk null;
        },
        .record_update => |update| blk: {
            if (sourceNameInExpr(budget, update.target.*, offset)) |target| break :blk target;
            for (update.fields.items) |field| {
                if (expired(budget)) return null;
                for (field.path.items) |segment| {
                    if (expired(budget)) return null;
                    if (spanContainsOffset(segment.span, offset)) break :blk .{
                        .text = segment.name,
                        .kind = .record_update_path_segment,
                    };
                }
                if (sourceNameInExpr(budget, field.value, offset)) |target| break :blk target;
            }
            break :blk null;
        },
        .enum_case => |case| blk: {
            if (spanContainsOptional(case.enum_name_span, offset)) break :blk .{
                .text = case.enum_name,
                .kind = .enum_name,
            };
            if (spanContainsOptional(case.case_name_span, offset)) break :blk .{
                .text = case.case_name,
                .kind = .enum_case_name,
            };
            break :blk null;
        },
        .optional_check => |check| sourceNameInExpr(budget, check.target.*, offset),
        .coalesce => |coalesce| blk: {
            if (sourceNameInExpr(budget, coalesce.target.*, offset)) |target| break :blk target;
            break :blk sourceNameInExpr(budget, coalesce.fallback.*, offset);
        },
        else => null,
    };
}

fn recordUpdatePathInExpr(budget: ?QueryBudget, expr: ast.Expr, offset: usize) ?RecordUpdatePathTarget {
    if (expired(budget)) return null;
    return switch (expr) {
        .call => |call| blk: {
            for (call.args.items) |arg| {
                if (expired(budget)) return null;
                if (recordUpdatePathInExpr(budget, arg, offset)) |target| break :blk target;
            }
            break :blk null;
        },
        .apply => |apply| blk: {
            if (recordUpdatePathInExpr(budget, apply.callee.*, offset)) |target| break :blk target;
            for (apply.args.items) |arg| {
                if (expired(budget)) return null;
                if (recordUpdatePathInExpr(budget, arg, offset)) |target| break :blk target;
            }
            break :blk null;
        },
        .lambda => |lambda| recordUpdatePathInExpr(budget, lambda.body.*, offset),
        .member => |member| recordUpdatePathInExpr(budget, member.target.*, offset),
        .record => |record| blk: {
            for (record.fields.items) |field| {
                if (expired(budget)) return null;
                if (recordUpdatePathInExpr(budget, field.value, offset)) |target| break :blk target;
            }
            break :blk null;
        },
        .record_update => |update| blk: {
            if (recordUpdatePathInExpr(budget, update.target.*, offset)) |target| break :blk target;
            for (update.fields.items) |field| {
                if (expired(budget)) return null;
                for (field.path.items, 0..) |segment, segment_index| {
                    if (expired(budget)) return null;
                    if (spanContainsOffset(segment.span, offset)) break :blk .{
                        .target = update.target.*,
                        .path = field.path.items,
                        .segment_index = segment_index,
                    };
                }
                if (recordUpdatePathInExpr(budget, field.value, offset)) |target| break :blk target;
            }
            break :blk null;
        },
        .optional_check => |check| recordUpdatePathInExpr(budget, check.target.*, offset),
        .coalesce => |coalesce| blk: {
            if (recordUpdatePathInExpr(budget, coalesce.target.*, offset)) |target| break :blk target;
            break :blk recordUpdatePathInExpr(budget, coalesce.fallback.*, offset);
        },
        else => null,
    };
}

fn recordUpdateCompletionInExpr(budget: ?QueryBudget, expr: ast.Expr, offset: usize) ?RecordUpdateCompletionTarget {
    if (expired(budget)) return null;
    return switch (expr) {
        .call => |call| blk: {
            for (call.args.items) |arg| {
                if (expired(budget)) return null;
                if (recordUpdateCompletionInExpr(budget, arg, offset)) |target| break :blk target;
            }
            break :blk null;
        },
        .apply => |apply| blk: {
            if (recordUpdateCompletionInExpr(budget, apply.callee.*, offset)) |target| break :blk target;
            for (apply.args.items) |arg| {
                if (expired(budget)) return null;
                if (recordUpdateCompletionInExpr(budget, arg, offset)) |target| break :blk target;
            }
            break :blk null;
        },
        .lambda => |lambda| recordUpdateCompletionInExpr(budget, lambda.body.*, offset),
        .member => |member| recordUpdateCompletionInExpr(budget, member.target.*, offset),
        .record => |record| blk: {
            for (record.fields.items) |field| {
                if (expired(budget)) return null;
                if (recordUpdateCompletionInExpr(budget, field.value, offset)) |target| break :blk target;
            }
            break :blk null;
        },
        .record_update => |update| blk: {
            if (recordUpdateCompletionInExpr(budget, update.target.*, offset)) |target| break :blk target;
            for (update.fields.items) |field| {
                if (expired(budget)) return null;
                for (field.path.items, 0..) |segment, segment_index| {
                    if (expired(budget)) return null;
                    if (spanContainsOffset(segment.span, offset)) break :blk .{
                        .target = update.target.*,
                        .path_prefix = field.path.items[0..segment_index],
                    };
                }
                if (spanContainsOffset(field.path_span, offset)) break :blk .{
                    .target = update.target.*,
                    .path_prefix = field.path.items[0..(pathPrefixLengthAt(budget, field.path.items, offset) orelse return null)],
                };
                if (spanContainsOffset(field.value_span, offset)) {
                    if (recordUpdateCompletionInExpr(budget, field.value, offset)) |target| break :blk target;
                    break :blk null;
                }
            }
            if (spanContainsOffset(update.body_span, offset)) break :blk .{
                .target = update.target.*,
                .path_prefix = &.{},
            };
            break :blk null;
        },
        .optional_check => |check| recordUpdateCompletionInExpr(budget, check.target.*, offset),
        .coalesce => |coalesce| blk: {
            if (recordUpdateCompletionInExpr(budget, coalesce.target.*, offset)) |target| break :blk target;
            break :blk recordUpdateCompletionInExpr(budget, coalesce.fallback.*, offset);
        },
        else => null,
    };
}

fn pathPrefixLengthAt(budget: ?QueryBudget, path: []const ast.RecordPathSegment, offset: usize) ?usize {
    if (expired(budget)) return null;
    for (path, 0..) |segment, index| {
        if (expired(budget)) return null;
        if (offset <= segment.span.end) return index;
    }
    return path.len;
}

const PathSegmentTarget = struct {
    segment: ast.RecordPathSegment,
    index: usize,
};

fn pathSegmentAt(budget: ?QueryBudget, path: []const ast.RecordPathSegment, offset: usize) ?PathSegmentTarget {
    if (expired(budget)) return null;
    for (path, 0..) |segment, index| {
        if (expired(budget)) return null;
        if (spanContainsOffset(segment.span, offset)) return .{
            .segment = segment,
            .index = index,
        };
    }
    return null;
}

fn memberInExpr(budget: ?QueryBudget, expr: ast.Expr, offset: usize) ?MemberTarget {
    if (expired(budget)) return null;
    return switch (expr) {
        .call => |call| blk: {
            for (call.args.items) |arg| {
                if (expired(budget)) return null;
                if (memberInExpr(budget, arg, offset)) |target| break :blk target;
            }
            break :blk null;
        },
        .apply => |apply| blk: {
            if (memberInExpr(budget, apply.callee.*, offset)) |target| break :blk target;
            for (apply.args.items) |arg| {
                if (expired(budget)) return null;
                if (memberInExpr(budget, arg, offset)) |target| break :blk target;
            }
            break :blk null;
        },
        .lambda => |lambda| memberInExpr(budget, lambda.body.*, offset),
        .member => |member| blk: {
            if (spanContainsOptional(member.name_span, offset)) break :blk .{
                .target = member.target.*,
                .name = member.name,
            };
            break :blk memberInExpr(budget, member.target.*, offset);
        },
        .record => |record| blk: {
            for (record.fields.items) |field| {
                if (expired(budget)) return null;
                if (memberInExpr(budget, field.value, offset)) |target| break :blk target;
            }
            break :blk null;
        },
        .record_update => |update| blk: {
            if (memberInExpr(budget, update.target.*, offset)) |target| break :blk target;
            for (update.fields.items) |field| {
                if (expired(budget)) return null;
                if (memberInExpr(budget, field.value, offset)) |target| break :blk target;
            }
            break :blk null;
        },
        .optional_check => |check| memberInExpr(budget, check.target.*, offset),
        .coalesce => |coalesce| blk: {
            if (memberInExpr(budget, coalesce.target.*, offset)) |target| break :blk target;
            break :blk memberInExpr(budget, coalesce.fallback.*, offset);
        },
        else => null,
    };
}

fn sourceNameInCallable(name: ast.CallableName, offset: usize) ?SourceNameTarget {
    if (name.qualifier_span) |qualifier_span| {
        if (spanContainsOffset(qualifier_span, offset)) return .{
            .text = name.qualifier orelse "",
            .kind = .callable_qualifier,
        };
    }
    const name_span = name.name_span orelse return null;
    if (spanContainsOffset(name_span, offset)) return .{
        .text = name.name,
        .kind = .callable_name,
        .qualifier = name.qualifier,
    };
    return null;
}

fn simpleIdentifierName(expr: ast.Expr) ?[]const u8 {
    return switch (expr) {
        .ident => |ident| ident.name,
        else => null,
    };
}

fn callableNameAt(name: ast.CallableName, offset: usize) ?CallableTarget {
    if (name.qualifier_span) |qualifier_span| {
        if (spanContainsOffset(qualifier_span, offset)) {
            return .{
                .callee = name,
                .role = .qualifier,
            };
        }
    }
    const name_span = name.name_span orelse return null;
    if (spanContainsOffset(name_span, offset)) {
        return .{
            .callee = name,
            .role = .name,
        };
    }
    return null;
}

fn spanContainsOffset(span: ast.Span, offset: usize) bool {
    return offset >= span.start and offset <= span.end;
}

fn spanContainsOptional(span: ?ast.Span, offset: usize) bool {
    return if (span) |value| spanContainsOffset(value, offset) else false;
}

fn expired(budget: ?QueryBudget) bool {
    return if (budget) |value| value.expired() else false;
}
