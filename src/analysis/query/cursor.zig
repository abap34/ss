const std = @import("std");
const ast = @import("ast");

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

pub fn callableAt(program: *const ast.Program, offset: usize) ?CallableTarget {
    for (program.records.items) |record| {
        if (callableInFields(record.fields.items, offset)) |target| return target;
    }
    for (program.objects.items) |object| {
        if (callableInFields(object.fields.items, offset)) |target| return target;
    }
    for (program.object_extensions.items) |extension| {
        if (callableInFields(extension.fields.items, offset)) |target| return target;
    }
    for (program.constants.items) |constant_decl| {
        if (callableInExpr(constant_decl.value, offset)) |target| return target;
    }
    for (program.functions.items) |func| {
        if (callableInStatements(func.statements.items, offset)) |target| return target;
    }
    if (callableInStatements(program.document_statements.items, offset)) |target| return target;
    for (program.pages.items) |page| {
        if (callableInStatements(page.statements.items, offset)) |target| return target;
    }
    return null;
}

pub fn sourceNameAt(program: *const ast.Program, offset: usize) ?SourceNameTarget {
    for (program.imports.items) |import_decl| {
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
        if (sourceNameInFields(record.fields.items, offset)) |target| return target;
    }
    for (program.objects.items) |object| {
        if (sourceNameInFields(object.fields.items, offset)) |target| return target;
    }
    for (program.object_extensions.items) |extension| {
        if (sourceNameInFields(extension.fields.items, offset)) |target| return target;
    }
    for (program.constants.items) |constant_decl| {
        if (sourceNameInType(constant_decl.value_type, offset)) |target| return target;
        if (sourceNameInExpr(constant_decl.value, offset)) |target| return target;
    }
    for (program.functions.items) |func| {
        for (func.params.items) |param| {
            if (spanContainsOptional(param.name_span, offset)) return .{
                .text = param.name,
                .kind = .identifier,
            };
            if (sourceNameInType(param.ty, offset)) |target| return target;
        }
        if (sourceNameInType(func.result_type, offset)) |target| return target;
        if (sourceNameInStatements(func.statements.items, offset)) |target| return target;
    }
    if (sourceNameInStatements(program.document_statements.items, offset)) |target| return target;
    for (program.pages.items) |page| {
        if (sourceNameInStatements(page.statements.items, offset)) |target| return target;
    }
    return null;
}

pub fn recordUpdatePathAt(program: *const ast.Program, offset: usize) ?RecordUpdatePathTarget {
    for (program.records.items) |record| {
        if (recordUpdatePathInFields(record.fields.items, offset)) |target| return target;
    }
    for (program.objects.items) |object| {
        if (recordUpdatePathInFields(object.fields.items, offset)) |target| return target;
    }
    for (program.object_extensions.items) |extension| {
        if (recordUpdatePathInFields(extension.fields.items, offset)) |target| return target;
    }
    for (program.constants.items) |constant_decl| {
        if (recordUpdatePathInExpr(constant_decl.value, offset)) |target| return target;
    }
    for (program.functions.items) |func| {
        for (func.params.items) |param| {
            if (param.default_value) |default_value| {
                if (recordUpdatePathInExpr(default_value.*, offset)) |target| return target;
            }
        }
        if (recordUpdatePathInStatements(func.statements.items, offset)) |target| return target;
    }
    if (recordUpdatePathInStatements(program.document_statements.items, offset)) |target| return target;
    for (program.pages.items) |page| {
        if (recordUpdatePathInStatements(page.statements.items, offset)) |target| return target;
    }
    return null;
}

pub fn recordUpdateCompletionAt(program: *const ast.Program, offset: usize) ?RecordUpdateCompletionTarget {
    for (program.records.items) |record| {
        if (recordUpdateCompletionInFields(record.fields.items, offset)) |target| return target;
    }
    for (program.objects.items) |object| {
        if (recordUpdateCompletionInFields(object.fields.items, offset)) |target| return target;
    }
    for (program.object_extensions.items) |extension| {
        if (recordUpdateCompletionInFields(extension.fields.items, offset)) |target| return target;
    }
    for (program.constants.items) |constant_decl| {
        if (recordUpdateCompletionInExpr(constant_decl.value, offset)) |target| return target;
    }
    for (program.functions.items) |func| {
        for (func.params.items) |param| {
            if (param.default_value) |default_value| {
                if (recordUpdateCompletionInExpr(default_value.*, offset)) |target| return target;
            }
        }
        if (recordUpdateCompletionInStatements(func.statements.items, offset)) |target| return target;
    }
    if (recordUpdateCompletionInStatements(program.document_statements.items, offset)) |target| return target;
    for (program.pages.items) |page| {
        if (recordUpdateCompletionInStatements(page.statements.items, offset)) |target| return target;
    }
    return null;
}

pub fn memberAt(program: *const ast.Program, offset: usize) ?MemberTarget {
    for (program.records.items) |record| {
        if (memberInFields(record.fields.items, offset)) |target| return target;
    }
    for (program.objects.items) |object| {
        if (memberInFields(object.fields.items, offset)) |target| return target;
    }
    for (program.object_extensions.items) |extension| {
        if (memberInFields(extension.fields.items, offset)) |target| return target;
    }
    for (program.constants.items) |constant_decl| {
        if (memberInExpr(constant_decl.value, offset)) |target| return target;
    }
    for (program.functions.items) |func| {
        for (func.params.items) |param| {
            if (param.default_value) |default_value| {
                if (memberInExpr(default_value.*, offset)) |target| return target;
            }
        }
        if (memberInStatements(func.statements.items, offset)) |target| return target;
    }
    if (memberInStatements(program.document_statements.items, offset)) |target| return target;
    for (program.pages.items) |page| {
        if (memberInStatements(page.statements.items, offset)) |target| return target;
    }
    return null;
}

pub fn visibleLetBindingAt(program: *const ast.Program, offset: usize, name: []const u8) ?LetBindingTarget {
    for (program.functions.items) |func| {
        if (!spanContainsOffset(func.span, offset)) continue;
        return visibleLetBindingInStatements(func.statements.items, offset, name);
    }
    for (program.document_blocks.items) |block| {
        if (!spanContainsOffset(block.span, offset)) continue;
        const statements = program.document_statements.items[block.statement_start .. block.statement_start + block.statement_count];
        return visibleLetBindingInStatements(statements, offset, name);
    }
    for (program.pages.items) |page| {
        if (!spanContainsOffset(page.span, offset)) continue;
        return visibleLetBindingInStatements(page.statements.items, offset, name);
    }
    return null;
}

pub fn qualifiedCallableAt(program: *const ast.Program, offset: usize) ?QualifiedCallableTarget {
    const target = callableAt(program, offset) orelse return null;
    const qualifier = target.callee.qualifier orelse return null;
    return .{
        .qualifier = qualifier,
        .name = target.callee.name,
        .role = target.role,
    };
}

pub fn qualifiedCallableQualifierForName(program: *const ast.Program, offset: usize) ?[]const u8 {
    const target = qualifiedCallableAt(program, offset) orelse return null;
    if (target.role != .name) return null;
    return target.qualifier;
}

pub fn isQualifiedCallableQualifierAt(program: *const ast.Program, offset: usize) bool {
    const target = qualifiedCallableAt(program, offset) orelse return false;
    return target.role == .qualifier;
}

pub fn isImportAliasAt(program: *const ast.Program, offset: usize) bool {
    for (program.imports.items) |import_decl| {
        const alias_span = import_decl.alias_span orelse continue;
        if (spanContainsOffset(alias_span, offset)) return true;
    }
    return false;
}

pub fn importSpecAt(program: *const ast.Program, offset: usize) ?[]const u8 {
    for (program.imports.items) |import_decl| {
        if (spanContainsOffset(import_decl.spec_span, offset)) return import_decl.spec;
    }
    return null;
}

fn callableInFields(fields: []const ast.ObjectFieldDecl, offset: usize) ?CallableTarget {
    for (fields) |field| {
        const default_value = field.default_value orelse continue;
        if (callableInExpr(default_value.*, offset)) |target| return target;
    }
    return null;
}

fn sourceNameInFields(fields: []const ast.ObjectFieldDecl, offset: usize) ?SourceNameTarget {
    for (fields) |field| {
        if (sourceNameInType(field.value_type, offset)) |target| return target;
        const default_value = field.default_value orelse continue;
        if (sourceNameInExpr(default_value.*, offset)) |target| return target;
    }
    return null;
}

fn recordUpdatePathInFields(fields: []const ast.ObjectFieldDecl, offset: usize) ?RecordUpdatePathTarget {
    for (fields) |field| {
        const default_value = field.default_value orelse continue;
        if (recordUpdatePathInExpr(default_value.*, offset)) |target| return target;
    }
    return null;
}

fn recordUpdateCompletionInFields(fields: []const ast.ObjectFieldDecl, offset: usize) ?RecordUpdateCompletionTarget {
    for (fields) |field| {
        const default_value = field.default_value orelse continue;
        if (recordUpdateCompletionInExpr(default_value.*, offset)) |target| return target;
    }
    return null;
}

fn memberInFields(fields: []const ast.ObjectFieldDecl, offset: usize) ?MemberTarget {
    for (fields) |field| {
        const default_value = field.default_value orelse continue;
        if (memberInExpr(default_value.*, offset)) |target| return target;
    }
    return null;
}

fn callableInStatements(statements: []const ast.Statement, offset: usize) ?CallableTarget {
    for (statements) |stmt| {
        if (callableInStatement(stmt, offset)) |target| return target;
    }
    return null;
}

fn sourceNameInStatements(statements: []const ast.Statement, offset: usize) ?SourceNameTarget {
    for (statements) |stmt| {
        if (sourceNameInStatement(stmt, offset)) |target| return target;
    }
    return null;
}

fn recordUpdatePathInStatements(statements: []const ast.Statement, offset: usize) ?RecordUpdatePathTarget {
    for (statements) |stmt| {
        if (recordUpdatePathInStatement(stmt, offset)) |target| return target;
    }
    return null;
}

fn recordUpdateCompletionInStatements(statements: []const ast.Statement, offset: usize) ?RecordUpdateCompletionTarget {
    for (statements) |stmt| {
        if (recordUpdateCompletionInStatement(stmt, offset)) |target| return target;
    }
    return null;
}

fn memberInStatements(statements: []const ast.Statement, offset: usize) ?MemberTarget {
    for (statements) |stmt| {
        if (memberInStatement(stmt, offset)) |target| return target;
    }
    return null;
}

fn visibleLetBindingInStatements(statements: []const ast.Statement, offset: usize, name: []const u8) ?LetBindingTarget {
    var best: ?LetBindingTarget = null;
    for (statements) |stmt| {
        if (stmt.span.start > offset) break;
        switch (stmt.kind) {
            .let_binding => |binding| {
                if (stmt.span.end <= offset and std.mem.eql(u8, binding.name, name)) {
                    best = .{ .expr = binding.expr };
                }
            },
            .if_stmt => |if_stmt| {
                if (spanContainsOffset(stmt.span, offset)) {
                    if (visibleLetBindingInStatements(if_stmt.then_statements.items, offset, name)) |target| best = target;
                    if (visibleLetBindingInStatements(if_stmt.else_statements.items, offset, name)) |target| best = target;
                }
            },
            else => {},
        }
    }
    return best;
}

fn callableInStatement(stmt: ast.Statement, offset: usize) ?CallableTarget {
    return switch (stmt.kind) {
        .hole => null,
        .let_binding => |binding| callableInExpr(binding.expr, offset),
        .return_expr => |expr| callableInExpr(expr, offset),
        .return_void => null,
        .constrain => |constraint| if (constraint.offset) |expr| callableInExpr(expr, offset) else null,
        .property_set => |property_set| blk: {
            if (callableInExpr(property_set.target, offset)) |target| break :blk target;
            break :blk callableInExpr(property_set.value, offset);
        },
        .if_stmt => |if_stmt| blk: {
            if (callableInExpr(if_stmt.condition, offset)) |target| break :blk target;
            if (callableInStatements(if_stmt.then_statements.items, offset)) |target| break :blk target;
            break :blk callableInStatements(if_stmt.else_statements.items, offset);
        },
        .expr_stmt => |expr| callableInExpr(expr, offset),
    };
}

fn sourceNameInStatement(stmt: ast.Statement, offset: usize) ?SourceNameTarget {
    return switch (stmt.kind) {
        .hole => null,
        .let_binding => |binding| blk: {
            if (spanContainsOptional(binding.name_span, offset)) break :blk .{
                .text = binding.name,
                .kind = .identifier,
            };
            if (binding.type_annotation) |annotation| {
                if (sourceNameInType(annotation, offset)) |target| break :blk target;
            }
            break :blk sourceNameInExpr(binding.expr, offset);
        },
        .return_expr => |expr| sourceNameInExpr(expr, offset),
        .return_void => null,
        .constrain => |constraint| if (constraint.offset) |expr| sourceNameInExpr(expr, offset) else null,
        .property_set => |property_set| blk: {
            if (sourceNameInExpr(property_set.target, offset)) |target| break :blk target;
            if (pathSegmentAt(property_set.path.items, offset)) |target| break :blk .{
                .text = target.segment.name,
                .kind = .member_name,
            };
            break :blk sourceNameInExpr(property_set.value, offset);
        },
        .if_stmt => |if_stmt| blk: {
            if (sourceNameInExpr(if_stmt.condition, offset)) |target| break :blk target;
            if (sourceNameInStatements(if_stmt.then_statements.items, offset)) |target| break :blk target;
            break :blk sourceNameInStatements(if_stmt.else_statements.items, offset);
        },
        .expr_stmt => |expr| sourceNameInExpr(expr, offset),
    };
}

fn recordUpdatePathInStatement(stmt: ast.Statement, offset: usize) ?RecordUpdatePathTarget {
    return switch (stmt.kind) {
        .hole, .return_void => null,
        .let_binding => |binding| recordUpdatePathInExpr(binding.expr, offset),
        .return_expr => |expr| recordUpdatePathInExpr(expr, offset),
        .constrain => |constraint| if (constraint.offset) |expr| recordUpdatePathInExpr(expr, offset) else null,
        .property_set => |property_set| blk: {
            if (recordUpdatePathInExpr(property_set.target, offset)) |target| break :blk target;
            break :blk recordUpdatePathInExpr(property_set.value, offset);
        },
        .if_stmt => |if_stmt| blk: {
            if (recordUpdatePathInExpr(if_stmt.condition, offset)) |target| break :blk target;
            if (recordUpdatePathInStatements(if_stmt.then_statements.items, offset)) |target| break :blk target;
            break :blk recordUpdatePathInStatements(if_stmt.else_statements.items, offset);
        },
        .expr_stmt => |expr| recordUpdatePathInExpr(expr, offset),
    };
}

fn recordUpdateCompletionInStatement(stmt: ast.Statement, offset: usize) ?RecordUpdateCompletionTarget {
    return switch (stmt.kind) {
        .hole, .return_void => null,
        .let_binding => |binding| recordUpdateCompletionInExpr(binding.expr, offset),
        .return_expr => |expr| recordUpdateCompletionInExpr(expr, offset),
        .constrain => |constraint| if (constraint.offset) |expr| recordUpdateCompletionInExpr(expr, offset) else null,
        .property_set => |property_set| blk: {
            if (recordUpdateCompletionInExpr(property_set.target, offset)) |target| break :blk target;
            break :blk recordUpdateCompletionInExpr(property_set.value, offset);
        },
        .if_stmt => |if_stmt| blk: {
            if (recordUpdateCompletionInExpr(if_stmt.condition, offset)) |target| break :blk target;
            if (recordUpdateCompletionInStatements(if_stmt.then_statements.items, offset)) |target| break :blk target;
            break :blk recordUpdateCompletionInStatements(if_stmt.else_statements.items, offset);
        },
        .expr_stmt => |expr| recordUpdateCompletionInExpr(expr, offset),
    };
}

fn memberInStatement(stmt: ast.Statement, offset: usize) ?MemberTarget {
    return switch (stmt.kind) {
        .hole, .return_void => null,
        .let_binding => |binding| memberInExpr(binding.expr, offset),
        .return_expr => |expr| memberInExpr(expr, offset),
        .constrain => |constraint| if (constraint.offset) |expr| memberInExpr(expr, offset) else null,
        .property_set => |property_set| blk: {
            if (memberInExpr(property_set.target, offset)) |target| break :blk target;
            const target = pathSegmentAt(property_set.path.items, offset) orelse break :blk memberInExpr(property_set.value, offset);
            if (target.index == 0) break :blk .{
                .target = property_set.target,
                .name = target.segment.name,
            };
            break :blk memberInExpr(property_set.value, offset);
        },
        .if_stmt => |if_stmt| blk: {
            if (memberInExpr(if_stmt.condition, offset)) |target| break :blk target;
            if (memberInStatements(if_stmt.then_statements.items, offset)) |target| break :blk target;
            break :blk memberInStatements(if_stmt.else_statements.items, offset);
        },
        .expr_stmt => |expr| memberInExpr(expr, offset),
    };
}

fn callableInExpr(expr: ast.Expr, offset: usize) ?CallableTarget {
    return switch (expr) {
        .call => |call| blk: {
            if (callableNameAt(call.callee, offset)) |target| break :blk target;
            for (call.args.items) |arg| {
                if (callableInExpr(arg, offset)) |target| break :blk target;
            }
            break :blk null;
        },
        .apply => |apply| blk: {
            if (callableInExpr(apply.callee.*, offset)) |target| break :blk target;
            for (apply.args.items) |arg| {
                if (callableInExpr(arg, offset)) |target| break :blk target;
            }
            break :blk null;
        },
        .lambda => |lambda| callableInExpr(lambda.body.*, offset),
        .record => |record| blk: {
            for (record.fields.items) |field| {
                if (callableInExpr(field.value, offset)) |target| break :blk target;
            }
            break :blk null;
        },
        .record_update => |update| blk: {
            if (callableInExpr(update.target.*, offset)) |target| break :blk target;
            for (update.fields.items) |field| {
                if (callableInExpr(field.value, offset)) |target| break :blk target;
            }
            break :blk null;
        },
        .member => |member| callableInExpr(member.target.*, offset),
        .optional_check => |check| callableInExpr(check.target.*, offset),
        .coalesce => |coalesce| blk: {
            if (callableInExpr(coalesce.target.*, offset)) |target| break :blk target;
            break :blk callableInExpr(coalesce.fallback.*, offset);
        },
        else => null,
    };
}

fn sourceNameInType(ty: ast.Type, offset: usize) ?SourceNameTarget {
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
                if (sourceNameInType(param, offset)) |target| break :blk target;
            }
            if (ty.fn_result) |result| break :blk sourceNameInType(result.*, offset);
            break :blk null;
        },
        .optional => if (ty.optional_child) |child| sourceNameInType(child.*, offset) else null,
        else => null,
    };
}

fn sourceNameInExpr(expr: ast.Expr, offset: usize) ?SourceNameTarget {
    return switch (expr) {
        .ident => |ident| if (spanContainsOptional(ident.name_span, offset)) .{
            .text = ident.name,
            .kind = .identifier,
        } else null,
        .call => |call| blk: {
            if (sourceNameInCallable(call.callee, offset)) |target| break :blk target;
            for (call.args.items) |arg| {
                if (sourceNameInExpr(arg, offset)) |target| break :blk target;
            }
            break :blk null;
        },
        .apply => |apply| blk: {
            if (sourceNameInExpr(apply.callee.*, offset)) |target| break :blk target;
            for (apply.args.items) |arg| {
                if (sourceNameInExpr(arg, offset)) |target| break :blk target;
            }
            break :blk null;
        },
        .lambda => |lambda| blk: {
            for (lambda.params.items) |param| {
                if (spanContainsOptional(param.name_span, offset)) break :blk .{
                    .text = param.name,
                    .kind = .identifier,
                };
            }
            break :blk sourceNameInExpr(lambda.body.*, offset);
        },
        .member => |member| blk: {
            if (spanContainsOptional(member.name_span, offset)) break :blk .{
                .text = member.name,
                .kind = .member_name,
                .qualifier = simpleIdentifierName(member.target.*),
            };
            break :blk sourceNameInExpr(member.target.*, offset);
        },
        .record => |record| blk: {
            if (spanContainsOptional(record.type_name_span, offset)) break :blk .{
                .text = record.type_name,
                .kind = .identifier,
            };
            for (record.fields.items) |field| {
                if (spanContainsOptional(field.name_span, offset)) break :blk .{
                    .text = field.name,
                    .kind = .record_field_name,
                    .qualifier = record.type_name,
                };
                if (sourceNameInExpr(field.value, offset)) |target| break :blk target;
            }
            break :blk null;
        },
        .record_update => |update| blk: {
            if (sourceNameInExpr(update.target.*, offset)) |target| break :blk target;
            for (update.fields.items) |field| {
                for (field.path.items) |segment| {
                    if (spanContainsOffset(segment.span, offset)) break :blk .{
                        .text = segment.name,
                        .kind = .record_update_path_segment,
                    };
                }
                if (sourceNameInExpr(field.value, offset)) |target| break :blk target;
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
        .optional_check => |check| sourceNameInExpr(check.target.*, offset),
        .coalesce => |coalesce| blk: {
            if (sourceNameInExpr(coalesce.target.*, offset)) |target| break :blk target;
            break :blk sourceNameInExpr(coalesce.fallback.*, offset);
        },
        else => null,
    };
}

fn recordUpdatePathInExpr(expr: ast.Expr, offset: usize) ?RecordUpdatePathTarget {
    return switch (expr) {
        .call => |call| blk: {
            for (call.args.items) |arg| {
                if (recordUpdatePathInExpr(arg, offset)) |target| break :blk target;
            }
            break :blk null;
        },
        .apply => |apply| blk: {
            if (recordUpdatePathInExpr(apply.callee.*, offset)) |target| break :blk target;
            for (apply.args.items) |arg| {
                if (recordUpdatePathInExpr(arg, offset)) |target| break :blk target;
            }
            break :blk null;
        },
        .lambda => |lambda| recordUpdatePathInExpr(lambda.body.*, offset),
        .member => |member| recordUpdatePathInExpr(member.target.*, offset),
        .record => |record| blk: {
            for (record.fields.items) |field| {
                if (recordUpdatePathInExpr(field.value, offset)) |target| break :blk target;
            }
            break :blk null;
        },
        .record_update => |update| blk: {
            if (recordUpdatePathInExpr(update.target.*, offset)) |target| break :blk target;
            for (update.fields.items) |field| {
                for (field.path.items, 0..) |segment, segment_index| {
                    if (spanContainsOffset(segment.span, offset)) break :blk .{
                        .target = update.target.*,
                        .path = field.path.items,
                        .segment_index = segment_index,
                    };
                }
                if (recordUpdatePathInExpr(field.value, offset)) |target| break :blk target;
            }
            break :blk null;
        },
        .optional_check => |check| recordUpdatePathInExpr(check.target.*, offset),
        .coalesce => |coalesce| blk: {
            if (recordUpdatePathInExpr(coalesce.target.*, offset)) |target| break :blk target;
            break :blk recordUpdatePathInExpr(coalesce.fallback.*, offset);
        },
        else => null,
    };
}

fn recordUpdateCompletionInExpr(expr: ast.Expr, offset: usize) ?RecordUpdateCompletionTarget {
    return switch (expr) {
        .call => |call| blk: {
            for (call.args.items) |arg| {
                if (recordUpdateCompletionInExpr(arg, offset)) |target| break :blk target;
            }
            break :blk null;
        },
        .apply => |apply| blk: {
            if (recordUpdateCompletionInExpr(apply.callee.*, offset)) |target| break :blk target;
            for (apply.args.items) |arg| {
                if (recordUpdateCompletionInExpr(arg, offset)) |target| break :blk target;
            }
            break :blk null;
        },
        .lambda => |lambda| recordUpdateCompletionInExpr(lambda.body.*, offset),
        .member => |member| recordUpdateCompletionInExpr(member.target.*, offset),
        .record => |record| blk: {
            for (record.fields.items) |field| {
                if (recordUpdateCompletionInExpr(field.value, offset)) |target| break :blk target;
            }
            break :blk null;
        },
        .record_update => |update| blk: {
            if (recordUpdateCompletionInExpr(update.target.*, offset)) |target| break :blk target;
            for (update.fields.items) |field| {
                for (field.path.items, 0..) |segment, segment_index| {
                    if (spanContainsOffset(segment.span, offset)) break :blk .{
                        .target = update.target.*,
                        .path_prefix = field.path.items[0..segment_index],
                    };
                }
                if (spanContainsOffset(field.path_span, offset)) break :blk .{
                    .target = update.target.*,
                    .path_prefix = field.path.items[0..pathPrefixLengthAt(field.path.items, offset)],
                };
                if (spanContainsOffset(field.value_span, offset)) {
                    if (recordUpdateCompletionInExpr(field.value, offset)) |target| break :blk target;
                    break :blk null;
                }
            }
            if (spanContainsOffset(update.body_span, offset)) break :blk .{
                .target = update.target.*,
                .path_prefix = &.{},
            };
            break :blk null;
        },
        .optional_check => |check| recordUpdateCompletionInExpr(check.target.*, offset),
        .coalesce => |coalesce| blk: {
            if (recordUpdateCompletionInExpr(coalesce.target.*, offset)) |target| break :blk target;
            break :blk recordUpdateCompletionInExpr(coalesce.fallback.*, offset);
        },
        else => null,
    };
}

fn pathPrefixLengthAt(path: []const ast.RecordPathSegment, offset: usize) usize {
    for (path, 0..) |segment, index| {
        if (offset <= segment.span.end) return index;
    }
    return path.len;
}

const PathSegmentTarget = struct {
    segment: ast.RecordPathSegment,
    index: usize,
};

fn pathSegmentAt(path: []const ast.RecordPathSegment, offset: usize) ?PathSegmentTarget {
    for (path, 0..) |segment, index| {
        if (spanContainsOffset(segment.span, offset)) return .{
            .segment = segment,
            .index = index,
        };
    }
    return null;
}

fn memberInExpr(expr: ast.Expr, offset: usize) ?MemberTarget {
    return switch (expr) {
        .call => |call| blk: {
            for (call.args.items) |arg| {
                if (memberInExpr(arg, offset)) |target| break :blk target;
            }
            break :blk null;
        },
        .apply => |apply| blk: {
            if (memberInExpr(apply.callee.*, offset)) |target| break :blk target;
            for (apply.args.items) |arg| {
                if (memberInExpr(arg, offset)) |target| break :blk target;
            }
            break :blk null;
        },
        .lambda => |lambda| memberInExpr(lambda.body.*, offset),
        .member => |member| blk: {
            if (spanContainsOptional(member.name_span, offset)) break :blk .{
                .target = member.target.*,
                .name = member.name,
            };
            break :blk memberInExpr(member.target.*, offset);
        },
        .record => |record| blk: {
            for (record.fields.items) |field| {
                if (memberInExpr(field.value, offset)) |target| break :blk target;
            }
            break :blk null;
        },
        .record_update => |update| blk: {
            if (memberInExpr(update.target.*, offset)) |target| break :blk target;
            for (update.fields.items) |field| {
                if (memberInExpr(field.value, offset)) |target| break :blk target;
            }
            break :blk null;
        },
        .optional_check => |check| memberInExpr(check.target.*, offset),
        .coalesce => |coalesce| blk: {
            if (memberInExpr(coalesce.target.*, offset)) |target| break :blk target;
            break :blk memberInExpr(coalesce.fallback.*, offset);
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
