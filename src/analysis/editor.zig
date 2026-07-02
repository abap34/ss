const std = @import("std");
const ast = @import("ast");
const core = @import("core");

const language_names = @import("../language/names.zig");
const registry = @import("../language/registry.zig");
const semantic_env = @import("../language/env.zig");
const analysis_scope = @import("scope.zig");
const utils = @import("utils");

const SemanticEnv = semantic_env.SemanticEnv;

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
        .property_set => |property_set| callableInExpr(property_set.value, offset),
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
        .property_set => |property_set| sourceNameInExpr(property_set.value, offset),
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
        .property_set => |property_set| recordUpdatePathInExpr(property_set.value, offset),
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
        .property_set => |property_set| recordUpdateCompletionInExpr(property_set.value, offset),
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
        .property_set => |property_set| memberInExpr(property_set.value, offset),
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

pub fn populateIrAnalysis(allocator: std.mem.Allocator, ir: *core.Ir) !void {
    for (ir.modules.items) |module| {
        if (module.kind == .project) continue;
        try collectDefinitionsFromProgram(allocator, module.source, module.program, module.id, module.path, false, &ir.definitions);
        try collectProgramHints(allocator, ir, &ir.hints, module.source, module.path, module.program, module.id, &ir.functions);
    }
    try collectDefinitionsFromProgram(allocator, ir.projectSource(), ir.projectProgram(), ir.project_module_id, null, true, &ir.definitions);
    try collectProgramHints(allocator, ir, &ir.hints, ir.projectSource(), ir.projectPath(), ir.projectProgram(), ir.project_module_id, &ir.functions);
}

pub fn refreshSolvedFrameHints(allocator: std.mem.Allocator, ir: *core.Ir) !void {
    var write_index: usize = 0;
    for (ir.hints.items) |hint| {
        if (hint.kind == .solved_frame) {
            allocator.free(hint.label);
            continue;
        }
        ir.hints.items[write_index] = hint;
        write_index += 1;
    }
    ir.hints.items.len = write_index;
    try collectSolvedSizeHints(allocator, ir, &ir.hints);
}

pub fn formatPrimitiveSignature(
    allocator: std.mem.Allocator,
    descriptor: registry.PrimitiveDescriptor,
) ![]const u8 {
    var params = std.ArrayList(u8).empty;
    defer params.deinit(allocator);
    for (descriptor.arg_names, 0..) |_, index| {
        if (index != 0) try params.appendSlice(allocator, ", ");
        const label = try formatPrimitiveParam(allocator, descriptor, index);
        defer allocator.free(label);
        try params.appendSlice(allocator, label);
    }
    const result_label = if (registry.primitiveResultType(descriptor)) |result_type|
        try result_type.formatAlloc(allocator)
    else
        try allocator.dupe(u8, "dependent");
    defer allocator.free(result_label);
    return std.fmt.allocPrint(allocator, "{s}({s}) -> {s}", .{ descriptor.name, params.items, result_label });
}

pub fn formatPrimitiveParam(
    allocator: std.mem.Allocator,
    descriptor: registry.PrimitiveDescriptor,
    index: usize,
) ![]const u8 {
    const name = descriptor.arg_names[index];
    if (registry.primitiveArgType(descriptor, index)) |ty| {
        const label = try ty.formatAlloc(allocator);
        defer allocator.free(label);
        return std.fmt.allocPrint(allocator, "{s}: {s}", .{ name, label });
    }
    return allocator.dupe(u8, name);
}

pub fn formatUserSignature(
    allocator: std.mem.Allocator,
    name: []const u8,
    func: ast.FunctionDecl,
) ![]const u8 {
    const result_label = try func.result_type.formatAlloc(allocator);
    defer allocator.free(result_label);

    var params = std.ArrayList(u8).empty;
    defer params.deinit(allocator);
    for (func.params.items, 0..) |param, index| {
        if (index != 0) try params.appendSlice(allocator, ", ");
        const label = try formatUserParam(allocator, param);
        defer allocator.free(label);
        try params.appendSlice(allocator, label);
    }
    return std.fmt.allocPrint(allocator, "{s}({s}) -> {s}", .{ name, params.items, result_label });
}

pub fn formatConstSignature(
    allocator: std.mem.Allocator,
    name: []const u8,
    constant_decl: ast.ConstDecl,
) ![]const u8 {
    const result_label = try constant_decl.value_type.formatAlloc(allocator);
    defer allocator.free(result_label);
    return std.fmt.allocPrint(allocator, "const {s}: {s}", .{ name, result_label });
}

pub fn formatUserParam(allocator: std.mem.Allocator, param: ast.ParamDecl) ![]const u8 {
    const label = try param.ty.formatAlloc(allocator);
    defer allocator.free(label);
    if (param.default_value) |default_value| {
        const text = try formatExpr(allocator, default_value.*);
        defer allocator.free(text);
        return std.fmt.allocPrint(allocator, "{s}: {s} = {s}", .{ param.name, label, text });
    }
    return std.fmt.allocPrint(allocator, "{s}: {s}", .{ param.name, label });
}

fn formatExpr(allocator: std.mem.Allocator, expr: ast.Expr) ![]const u8 {
    return switch (expr) {
        .hole => allocator.dupe(u8, "<hole>"),
        .ident => |ident| allocator.dupe(u8, ident.name),
        .string => |literal| std.fmt.allocPrint(allocator, "\"{s}\"", .{literal.text}),
        .color => |text| std.fmt.allocPrint(allocator, "c\"{s}\"", .{text}),
        .number => |value| std.fmt.allocPrint(allocator, "{d}", .{value}),
        .boolean => |value| allocator.dupe(u8, if (value) "true" else "false"),
        .none => allocator.dupe(u8, "none"),
        .enum_case => |case| std.fmt.allocPrint(allocator, "{s}.{s}", .{ case.enum_name, case.case_name }),
        .record => |record| blk: {
            var fields = std.ArrayList(u8).empty;
            defer fields.deinit(allocator);
            for (record.fields.items, 0..) |field, index| {
                if (index != 0) try fields.appendSlice(allocator, ", ");
                const text = try formatExpr(allocator, field.value);
                defer allocator.free(text);
                try fields.appendSlice(allocator, field.name);
                try fields.appendSlice(allocator, " = ");
                try fields.appendSlice(allocator, text);
            }
            break :blk std.fmt.allocPrint(allocator, "{s} {{ {s} }}", .{ record.type_name, fields.items });
        },
        .record_update => |update| blk: {
            const target = try formatExpr(allocator, update.target.*);
            defer allocator.free(target);
            var fields = std.ArrayList(u8).empty;
            defer fields.deinit(allocator);
            for (update.fields.items, 0..) |field, index| {
                if (index != 0) try fields.appendSlice(allocator, ", ");
                for (field.path.items, 0..) |segment, segment_index| {
                    if (segment_index != 0) try fields.append(allocator, '.');
                    try fields.appendSlice(allocator, segment.name);
                }
                const text = try formatExpr(allocator, field.value);
                defer allocator.free(text);
                try fields.appendSlice(allocator, " = ");
                try fields.appendSlice(allocator, text);
            }
            break :blk std.fmt.allocPrint(allocator, "{s} with {{ {s} }}", .{ target, fields.items });
        },
        .call => |call| blk: {
            const callee = try call.callee.displayAlloc(allocator);
            defer allocator.free(callee);
            var args = std.ArrayList(u8).empty;
            defer args.deinit(allocator);
            for (call.args.items, 0..) |arg, index| {
                if (index != 0) try args.appendSlice(allocator, ", ");
                const text = try formatExpr(allocator, arg);
                defer allocator.free(text);
                try args.appendSlice(allocator, text);
            }
            break :blk std.fmt.allocPrint(allocator, "{s}({s})", .{ callee, args.items });
        },
        .apply => |apply| blk: {
            const callee = try formatExpr(allocator, apply.callee.*);
            defer allocator.free(callee);
            var args = std.ArrayList(u8).empty;
            defer args.deinit(allocator);
            for (apply.args.items, 0..) |arg, index| {
                if (index != 0) try args.appendSlice(allocator, ", ");
                const text = try formatExpr(allocator, arg);
                defer allocator.free(text);
                try args.appendSlice(allocator, text);
            }
            break :blk std.fmt.allocPrint(allocator, "{s}({s})", .{ callee, args.items });
        },
        .lambda => allocator.dupe(u8, "<lambda>"),
        .member => |member| blk: {
            const target = try formatExpr(allocator, member.target.*);
            defer allocator.free(target);
            break :blk std.fmt.allocPrint(allocator, "{s}.{s}", .{ target, member.name });
        },
        .optional_check => |check| blk: {
            const target = try formatExpr(allocator, check.target.*);
            defer allocator.free(target);
            break :blk std.fmt.allocPrint(allocator, "{s}?", .{target});
        },
        .coalesce => |coalesce| blk: {
            const target = try formatExpr(allocator, coalesce.target.*);
            defer allocator.free(target);
            const fallback = try formatExpr(allocator, coalesce.fallback.*);
            defer allocator.free(fallback);
            break :blk std.fmt.allocPrint(allocator, "{s} ?? {s}", .{ target, fallback });
        },
    };
}

fn collectDefinitionsFromProgram(
    allocator: std.mem.Allocator,
    source: []const u8,
    program: ast.Program,
    module_id: core.SourceModuleId,
    file: ?[]const u8,
    include_variables: bool,
    definitions: *std.ArrayList(core.Definition),
) !void {
    for (program.functions.items) |func| {
        try putDefinitionAtSpan(allocator, definitions, source, func.name, func.name_span, 0, source.len, .function, module_id, file, .module, null);
        if (include_variables) {
            const scope = analysis_scope.functionScope(func);
            for (func.params.items) |param| {
                try putDefinitionAtSpan(allocator, definitions, source, param.name, param.name_span, func.span.start, func.span.end, .variable, module_id, null, scope.kind, scope.name);
            }
            for (func.statements.items) |stmt| {
                try collectDefinitionsFromStatement(allocator, source, module_id, stmt, definitions, scope, func.span.end);
            }
        }
    }
    for (program.constants.items) |constant_decl| {
        try putDefinitionAtSpan(allocator, definitions, source, constant_decl.name, constant_decl.name_span, 0, source.len, .constant, module_id, file, .module, null);
    }
    if (include_variables) {
        const document_scope = analysis_scope.documentScope(source.len);
        for (program.document_statements.items) |stmt| {
            try collectDefinitionsFromStatement(allocator, source, module_id, stmt, definitions, document_scope, source.len);
        }
        for (program.pages.items) |page| {
            const scope = analysis_scope.pageScope(page);
            for (page.statements.items) |stmt| {
                try collectDefinitionsFromStatement(allocator, source, module_id, stmt, definitions, scope, page.span.end);
            }
        }
    }
}

fn collectDefinitionsFromStatement(
    allocator: std.mem.Allocator,
    source: []const u8,
    module_id: core.SourceModuleId,
    stmt: ast.Statement,
    definitions: *std.ArrayList(core.Definition),
    scope: analysis_scope.SourceScope,
    visible_end: usize,
) !void {
    switch (stmt.kind) {
        .let_binding => |binding| {
            if (!language_names.isDiscardBindingName(binding.name)) {
                try putDefinitionAtSpan(allocator, definitions, source, binding.name, binding.name_span, stmt.span.start, visible_end, .variable, module_id, null, scope.kind, scope.name);
            }
        },
        .if_stmt => |if_stmt| {
            const then_end = analysis_scope.statementsVisibleEnd(if_stmt.then_statements.items, stmt.span.end);
            for (if_stmt.then_statements.items) |nested| try collectDefinitionsFromStatement(allocator, source, module_id, nested, definitions, scope, then_end);
            const else_end = analysis_scope.statementsVisibleEnd(if_stmt.else_statements.items, stmt.span.end);
            for (if_stmt.else_statements.items) |nested| try collectDefinitionsFromStatement(allocator, source, module_id, nested, definitions, scope, else_end);
        },
        else => {},
    }
}

fn putDefinitionAtSpan(
    allocator: std.mem.Allocator,
    definitions: *std.ArrayList(core.Definition),
    source: []const u8,
    name: []const u8,
    name_span: ?ast.Span,
    visible_start: usize,
    visible_end: usize,
    kind: core.DefinitionKind,
    module_id: core.SourceModuleId,
    file: ?[]const u8,
    scope_kind: core.DefinitionScopeKind,
    scope_name: ?[]const u8,
) !void {
    const span = name_span orelse return;
    const loc = utils.source.locationAt(source, span.start);
    try putDefinition(allocator, definitions, name, loc.line, loc.column, span.start, @max(span.end, span.start) - span.start, visible_start, visible_end, kind, module_id, file, scope_kind, scope_name);
}

fn putDefinition(
    allocator: std.mem.Allocator,
    definitions: *std.ArrayList(core.Definition),
    name: []const u8,
    line: usize,
    column: usize,
    span_start: usize,
    length: usize,
    visible_start: usize,
    visible_end: usize,
    kind: core.DefinitionKind,
    module_id: core.SourceModuleId,
    file: ?[]const u8,
    scope_kind: core.DefinitionScopeKind,
    scope_name: ?[]const u8,
) !void {
    try definitions.append(allocator, .{
        .name = try allocator.dupe(u8, name),
        .line = line,
        .column = column,
        .length = length,
        .span_start = span_start,
        .span_end = span_start + length,
        .visible_start = visible_start,
        .visible_end = visible_end,
        .kind = kind,
        .module_id = module_id,
        .file = if (file) |path| try allocator.dupe(u8, path) else null,
        .scope_kind = scope_kind,
        .scope_name = if (scope_name) |scope| try allocator.dupe(u8, scope) else null,
    });
}

fn collectProgramHints(
    allocator: std.mem.Allocator,
    ir: *const core.Ir,
    hints: *std.ArrayList(core.InlayHint),
    source: []const u8,
    source_path: ?[]const u8,
    program: ast.Program,
    module_id: core.SourceModuleId,
    functions: *const core.FunctionMap,
) !void {
    for (program.functions.items) |func| {
        for (func.statements.items) |stmt| {
            try collectStatementHints(allocator, ir, hints, functions, source, source_path, module_id, stmt);
        }
    }
    for (program.constants.items) |constant_decl| {
        try collectExprHints(allocator, ir, hints, functions, source, source_path, module_id, constant_decl.span, constant_decl.value);
    }
    for (program.document_statements.items) |stmt| {
        try collectStatementHints(allocator, ir, hints, functions, source, source_path, module_id, stmt);
    }
    for (program.pages.items) |page| {
        for (page.statements.items) |stmt| {
            try collectStatementHints(allocator, ir, hints, functions, source, source_path, module_id, stmt);
        }
    }
}

fn collectStatementHints(
    allocator: std.mem.Allocator,
    ir: *const core.Ir,
    hints: *std.ArrayList(core.InlayHint),
    functions: *const core.FunctionMap,
    source: []const u8,
    source_path: ?[]const u8,
    module_id: core.SourceModuleId,
    stmt: ast.Statement,
) !void {
    switch (stmt.kind) {
        .let_binding => |binding| try collectExprHints(allocator, ir, hints, functions, source, source_path, module_id, stmt.span, binding.expr),
        .return_expr => |expr| try collectExprHints(allocator, ir, hints, functions, source, source_path, module_id, stmt.span, expr),
        .property_set => |property_set| try collectExprHints(allocator, ir, hints, functions, source, source_path, module_id, stmt.span, property_set.value),
        .if_stmt => |if_stmt| {
            try collectExprHints(allocator, ir, hints, functions, source, source_path, module_id, stmt.span, if_stmt.condition);
            for (if_stmt.then_statements.items) |nested| try collectStatementHints(allocator, ir, hints, functions, source, source_path, module_id, nested);
            for (if_stmt.else_statements.items) |nested| try collectStatementHints(allocator, ir, hints, functions, source, source_path, module_id, nested);
        },
        .expr_stmt => |expr| try collectExprHints(allocator, ir, hints, functions, source, source_path, module_id, stmt.span, expr),
        else => {},
    }
}

fn collectExprHints(
    allocator: std.mem.Allocator,
    ir: *const core.Ir,
    hints: *std.ArrayList(core.InlayHint),
    functions: *const core.FunctionMap,
    source: []const u8,
    source_path: ?[]const u8,
    module_id: core.SourceModuleId,
    span: ast.Span,
    expr: ast.Expr,
) !void {
    switch (expr) {
        .call => |call| {
            try hintForCallExpr(allocator, ir, hints, functions, source, source_path, module_id, call);
            for (call.args.items) |arg| try collectExprHints(allocator, ir, hints, functions, source, source_path, module_id, span, arg);
        },
        .apply => |apply| {
            try collectExprHints(allocator, ir, hints, functions, source, source_path, module_id, span, apply.callee.*);
            for (apply.args.items) |arg| try collectExprHints(allocator, ir, hints, functions, source, source_path, module_id, span, arg);
        },
        .lambda => |lambda| try collectExprHints(allocator, ir, hints, functions, source, source_path, module_id, span, lambda.body.*),
        .record_update => |update| {
            try collectExprHints(allocator, ir, hints, functions, source, source_path, module_id, span, update.target.*);
            for (update.fields.items) |field| try collectExprHints(allocator, ir, hints, functions, source, source_path, module_id, span, field.value);
        },
        .member => |member| try collectExprHints(allocator, ir, hints, functions, source, source_path, module_id, span, member.target.*),
        .optional_check => |check| try collectExprHints(allocator, ir, hints, functions, source, source_path, module_id, span, check.target.*),
        .coalesce => |coalesce| {
            try collectExprHints(allocator, ir, hints, functions, source, source_path, module_id, span, coalesce.target.*);
            try collectExprHints(allocator, ir, hints, functions, source, source_path, module_id, span, coalesce.fallback.*);
        },
        else => {},
    }
}

fn hintForCallExpr(
    allocator: std.mem.Allocator,
    ir: *const core.Ir,
    hints: *std.ArrayList(core.InlayHint),
    functions: *const core.FunctionMap,
    source: []const u8,
    source_path: ?[]const u8,
    module_id: core.SourceModuleId,
    call: ast.CallExpr,
) !void {
    if (call.args.items.len == 0) return;
    const hint_count = @min(call.args.items.len, call.arg_spans.items.len);
    const sema = SemanticEnv.init(ir, null, functions).forModule(module_id);
    for (0..hint_count) |index| {
        const param_name = sema.callCalleeParamName(call.callee, index) orelse continue;
        const label = try std.fmt.allocPrint(allocator, "{s}:", .{param_name});
        try appendInlayHint(allocator, hints, source, source_path, module_id, call.arg_spans.items[index].start, label, .parameter_names);
    }
}

fn collectSolvedSizeHints(
    allocator: std.mem.Allocator,
    ir: *core.Ir,
    hints: *std.ArrayList(core.InlayHint),
) !void {
    var best_by_origin = std.StringHashMap(core.NodeId).init(allocator);
    defer best_by_origin.deinit();

    for (ir.nodes.items) |node| {
        if (node.kind != .object or !node.attached) continue;
        const origin = node.origin orelse continue;
        if (node.role != null and std.mem.eql(u8, node.role.?, "panel")) continue;
        if (best_by_origin.get(origin)) |existing| {
            if (node.id > existing) try best_by_origin.put(origin, node.id);
        } else {
            try best_by_origin.put(origin, node.id);
        }
    }

    var iterator = best_by_origin.iterator();
    while (iterator.next()) |entry| {
        const origin = utils.err.parseLocatedOrigin(entry.key_ptr.*) orelse continue;
        const module = moduleForHintOrigin(ir, origin.path);
        const node = ir.getNode(entry.value_ptr.*) orelse continue;
        const label = try std.fmt.allocPrint(
            allocator,
            " x={d:.0} y={d:.0} w={d:.0} h={d:.0}",
            .{ node.frame.x, node.frame.y, node.frame.width, node.frame.height },
        );
        try appendInlayHint(allocator, hints, module.source, module.file, module.id, utils.source.lineAt(module.source, origin.span.end).span.end, label, .solved_frame);
    }
}

fn moduleForHintOrigin(ir: *const core.Ir, file: ?[]const u8) struct { id: core.SourceModuleId, source: []const u8, file: ?[]const u8 } {
    if (file) |origin_path| {
        if (ir.moduleByPathOrSpec(origin_path)) |module| {
            return .{ .id = module.id, .source = module.source, .file = module.path orelse origin_path };
        }
    }
    return .{ .id = ir.project_module_id, .source = ir.projectSource(), .file = ir.projectPath() };
}

fn appendInlayHint(
    allocator: std.mem.Allocator,
    hints: *std.ArrayList(core.InlayHint),
    source: []const u8,
    source_path: ?[]const u8,
    module_id: core.SourceModuleId,
    byte_index: usize,
    label: []const u8,
    kind: core.InlayHintKind,
) !void {
    const loc = utils.source.locationAt(source, @min(byte_index, source.len));
    try hints.append(allocator, .{
        .line = loc.line,
        .column = loc.column,
        .label = label,
        .kind = kind,
        .module_id = module_id,
        .file = source_path,
    });
}
