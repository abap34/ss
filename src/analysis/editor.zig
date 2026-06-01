const std = @import("std");
const ast = @import("ast");
const core = @import("core");

const registry = @import("../language/registry.zig");
const semantic_env = @import("../language/env.zig");
const utils = @import("utils");
const source_utils = utils.source;

const SemanticEnv = semantic_env.SemanticEnv;

fn isConst(func: ast.FunctionDecl) bool {
    return func.kind == .constant;
}

pub fn populateIrAnalysis(allocator: std.mem.Allocator, ir: *core.Ir) !void {
    for (ir.modules.items) |module| {
        if (module.kind == .project) continue;
        try collectDefinitionsFromProgram(allocator, module.source, module.program, module.id, module.path, false, &ir.definitions);
        try collectProgramHints(allocator, &ir.hints, module.source, module.path, module.program, module.id, &ir.functions);
    }
    try collectDefinitionsFromProgram(allocator, ir.projectSource(), ir.projectProgram(), ir.project_module_id, null, true, &ir.definitions);
    try collectProgramHints(allocator, &ir.hints, ir.projectSource(), ir.projectPath(), ir.projectProgram(), ir.project_module_id, &ir.functions);
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
    return std.fmt.allocPrint(allocator, "{s}({s}) -> {s}", .{ descriptor.name, params.items, resultText(descriptor.result_tag) });
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
    if (isConst(func)) return std.fmt.allocPrint(allocator, "const {s}: {s}", .{ name, result_label });

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
        .ident => |name| allocator.dupe(u8, name),
        .string => |text| std.fmt.allocPrint(allocator, "\"{s}\"", .{text}),
        .color => |text| std.fmt.allocPrint(allocator, "c\"{s}\"", .{text}),
        .number => |value| std.fmt.allocPrint(allocator, "{d}", .{value}),
        .boolean => |value| allocator.dupe(u8, if (value) "true" else "false"),
        .none => allocator.dupe(u8, "none"),
        .call => |call| blk: {
            var args = std.ArrayList(u8).empty;
            defer args.deinit(allocator);
            for (call.args.items, 0..) |arg, index| {
                if (index != 0) try args.appendSlice(allocator, ", ");
                const text = try formatExpr(allocator, arg);
                defer allocator.free(text);
                try args.appendSlice(allocator, text);
            }
            break :blk std.fmt.allocPrint(allocator, "{s}({s})", .{ call.name, args.items });
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

pub fn resultText(result_tag: ?core.ValueTag) []const u8 {
    return if (result_tag) |tag| @tagName(tag) else "unknown";
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
        const keyword = if (isConst(func)) "const" else "fn";
        const kind: core.DefinitionKind = if (isConst(func)) .constant else .function;
        if (findIdentifierOffsetAfterKeyword(source, func.span.start, keyword, func.name)) |location| {
            const loc = utils.err.computeLineColumn(source, location.offset);
            try putDefinition(allocator, definitions, func.name, loc.line, loc.column, location.offset, location.length, kind, module_id, file, .module, null);
        }
        if (include_variables) {
            for (func.statements.items) |stmt| {
                try collectDefinitionsFromStatement(allocator, source, module_id, stmt, definitions, .function, func.name);
            }
        }
    }
    if (include_variables) {
        for (program.document_statements.items) |stmt| {
            try collectDefinitionsFromStatement(allocator, source, module_id, stmt, definitions, .document, null);
        }
        for (program.pages.items) |page| {
            for (page.statements.items) |stmt| {
                try collectDefinitionsFromStatement(allocator, source, module_id, stmt, definitions, .page, page.name);
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
    scope_kind: core.DefinitionScopeKind,
    scope_name: ?[]const u8,
) !void {
    switch (stmt.kind) {
        .let_binding => |binding| try putStatementDefinition(allocator, source, module_id, stmt, "let", binding.name, definitions, scope_kind, scope_name),
        .if_stmt => |if_stmt| {
            for (if_stmt.then_statements.items) |nested| try collectDefinitionsFromStatement(allocator, source, module_id, nested, definitions, scope_kind, scope_name);
            for (if_stmt.else_statements.items) |nested| try collectDefinitionsFromStatement(allocator, source, module_id, nested, definitions, scope_kind, scope_name);
        },
        else => {},
    }
}

fn putStatementDefinition(
    allocator: std.mem.Allocator,
    source: []const u8,
    module_id: core.SourceModuleId,
    stmt: ast.Statement,
    keyword: []const u8,
    name: []const u8,
    definitions: *std.ArrayList(core.Definition),
    scope_kind: core.DefinitionScopeKind,
    scope_name: ?[]const u8,
) !void {
    if (findIdentifierOffsetAfterKeyword(source, stmt.span.start, keyword, name)) |location| {
        const loc = utils.err.computeLineColumn(source, location.offset);
        try putDefinition(allocator, definitions, name, loc.line, loc.column, location.offset, location.length, .variable, module_id, null, scope_kind, scope_name);
    }
}

fn putDefinition(
    allocator: std.mem.Allocator,
    definitions: *std.ArrayList(core.Definition),
    name: []const u8,
    line: usize,
    column: usize,
    span_start: usize,
    length: usize,
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
        .kind = kind,
        .module_id = module_id,
        .file = if (file) |path| try allocator.dupe(u8, path) else null,
        .scope_kind = scope_kind,
        .scope_name = if (scope_name) |scope| try allocator.dupe(u8, scope) else null,
    });
}

fn collectProgramHints(
    allocator: std.mem.Allocator,
    hints: *std.ArrayList(core.InlayHint),
    source: []const u8,
    source_path: ?[]const u8,
    program: ast.Program,
    module_id: core.SourceModuleId,
    functions: *const std.StringHashMap(ast.FunctionDecl),
) !void {
    for (program.functions.items) |func| {
        for (func.statements.items) |stmt| {
            try collectStatementHints(allocator, hints, functions, source, source_path, module_id, stmt);
        }
    }
    for (program.document_statements.items) |stmt| {
        try collectStatementHints(allocator, hints, functions, source, source_path, module_id, stmt);
    }
    for (program.pages.items) |page| {
        for (page.statements.items) |stmt| {
            try collectStatementHints(allocator, hints, functions, source, source_path, module_id, stmt);
        }
    }
}

fn collectStatementHints(
    allocator: std.mem.Allocator,
    hints: *std.ArrayList(core.InlayHint),
    functions: *const std.StringHashMap(ast.FunctionDecl),
    source: []const u8,
    source_path: ?[]const u8,
    module_id: core.SourceModuleId,
    stmt: ast.Statement,
) !void {
    switch (stmt.kind) {
        .let_binding => |binding| try collectExprHints(allocator, hints, functions, source, source_path, module_id, stmt.span, binding.expr),
        .return_expr => |expr| try collectExprHints(allocator, hints, functions, source, source_path, module_id, stmt.span, expr),
        .property_set => |property_set| try collectExprHints(allocator, hints, functions, source, source_path, module_id, stmt.span, property_set.value),
        .if_stmt => |if_stmt| {
            try collectExprHints(allocator, hints, functions, source, source_path, module_id, stmt.span, if_stmt.condition);
            for (if_stmt.then_statements.items) |nested| try collectStatementHints(allocator, hints, functions, source, source_path, module_id, nested);
            for (if_stmt.else_statements.items) |nested| try collectStatementHints(allocator, hints, functions, source, source_path, module_id, nested);
        },
        .expr_stmt => |expr| try collectExprHints(allocator, hints, functions, source, source_path, module_id, stmt.span, expr),
        else => {},
    }
}

fn collectExprHints(
    allocator: std.mem.Allocator,
    hints: *std.ArrayList(core.InlayHint),
    functions: *const std.StringHashMap(ast.FunctionDecl),
    source: []const u8,
    source_path: ?[]const u8,
    module_id: core.SourceModuleId,
    span: ast.Span,
    expr: ast.Expr,
) !void {
    switch (expr) {
        .call => |call| {
            try hintForCallExpr(allocator, hints, functions, source, source_path, module_id, span, call);
            for (call.args.items) |arg| try collectExprHints(allocator, hints, functions, source, source_path, module_id, span, arg);
        },
        .apply => |apply| {
            try collectExprHints(allocator, hints, functions, source, source_path, module_id, span, apply.callee.*);
            for (apply.args.items) |arg| try collectExprHints(allocator, hints, functions, source, source_path, module_id, span, arg);
        },
        .lambda => |lambda| try collectExprHints(allocator, hints, functions, source, source_path, module_id, span, lambda.body.*),
        .member => |member| try collectExprHints(allocator, hints, functions, source, source_path, module_id, span, member.target.*),
        .optional_check => |check| try collectExprHints(allocator, hints, functions, source, source_path, module_id, span, check.target.*),
        .coalesce => |coalesce| {
            try collectExprHints(allocator, hints, functions, source, source_path, module_id, span, coalesce.target.*);
            try collectExprHints(allocator, hints, functions, source, source_path, module_id, span, coalesce.fallback.*);
        },
        else => {},
    }
}

fn hintForCallExpr(
    allocator: std.mem.Allocator,
    hints: *std.ArrayList(core.InlayHint),
    functions: *const std.StringHashMap(ast.FunctionDecl),
    source: []const u8,
    source_path: ?[]const u8,
    module_id: core.SourceModuleId,
    span: ast.Span,
    call: ast.CallExpr,
) !void {
    if (call.args.items.len == 0) return;
    const slice = source[span.start..@min(span.end, source.len)];
    const arg_starts = try findCallArgStartOffsets(allocator, slice, call.name, call.args.items.len);
    defer allocator.free(arg_starts);
    const hint_count = @min(call.args.items.len, arg_starts.len);
    const sema = SemanticEnv.init(null, null, functions);
    for (0..hint_count) |index| {
        const param_name = sema.callParamName(call.name, index) orelse continue;
        const label = try std.fmt.allocPrint(allocator, "{s}:", .{param_name});
        try appendInlayHint(allocator, hints, source, source_path, module_id, span.start + arg_starts[index], label, .parameter_names);
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
        try appendInlayHint(allocator, hints, module.source, module.file, module.id, trimHintByteIndexToLineEnd(module.source, origin.span.end), label, .solved_frame);
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
    const loc = utils.err.computeLineColumn(source, @min(byte_index, source.len));
    try hints.append(allocator, .{
        .line = loc.line,
        .column = loc.column,
        .label = label,
        .kind = kind,
        .module_id = module_id,
        .file = source_path,
    });
}

fn trimHintByteIndexToLineEnd(source: []const u8, byte_index: usize) usize {
    var index = @min(byte_index, source.len);
    while (index < source.len and source[index] != '\n') : (index += 1) {}
    return index;
}

fn findCallArgStartOffsets(
    allocator: std.mem.Allocator,
    slice: []const u8,
    call_name: []const u8,
    arg_count: usize,
) ![]usize {
    var offsets = std.ArrayList(usize).empty;
    defer offsets.deinit(allocator);

    const name_pos = std.mem.indexOf(u8, slice, call_name) orelse return try allocator.alloc(usize, 0);
    var index: usize = name_pos + call_name.len;
    while (index < slice.len and std.ascii.isWhitespace(slice[index])) : (index += 1) {}
    if (index >= slice.len or slice[index] != '(') return try allocator.alloc(usize, 0);
    index += 1;

    while (index < slice.len and offsets.items.len < arg_count) {
        while (index < slice.len and (std.ascii.isWhitespace(slice[index]) or slice[index] == ',')) : (index += 1) {}
        if (index >= slice.len or slice[index] == ')') break;
        try offsets.append(allocator, index);
        index = skipExpr(slice, index);
    }
    return offsets.toOwnedSlice(allocator);
}

fn skipExpr(slice: []const u8, start: usize) usize {
    var index = start;
    var depth: usize = 0;
    while (index < slice.len) : (index += 1) {
        const ch = slice[index];
        switch (ch) {
            '"' => index = skipString(slice, index),
            '(' => depth += 1,
            ')' => {
                if (depth == 0) break;
                depth -= 1;
                if (depth == 0) return index + 1;
            },
            ',' => if (depth == 0) break,
            else => {},
        }
    }
    return index;
}

fn skipString(slice: []const u8, start: usize) usize {
    var index = start + 1;
    var escaped = false;
    while (index < slice.len) : (index += 1) {
        if (escaped) {
            escaped = false;
            continue;
        }
        if (slice[index] == '\\') {
            escaped = true;
            continue;
        }
        if (slice[index] == '"') return index;
    }
    return slice.len;
}

fn findIdentifierOffsetAfterKeyword(source: []const u8, start: usize, keyword: []const u8, expected_name: []const u8) ?struct { offset: usize, length: usize } {
    var index = start;
    while (index < source.len and std.ascii.isWhitespace(source[index])) : (index += 1) {}
    if (index + keyword.len > source.len or !std.mem.eql(u8, source[index .. index + keyword.len], keyword)) return null;
    index += keyword.len;
    while (index < source.len and std.ascii.isWhitespace(source[index])) : (index += 1) {}
    const ident_start = index;
    if (index >= source.len or !source_utils.isIdentifierStart(source[index])) return null;
    index += 1;
    while (index < source.len and source_utils.isIdentifierContinue(source[index])) : (index += 1) {}
    if (!std.mem.eql(u8, source[ident_start..index], expected_name)) return null;
    return .{ .offset = ident_start, .length = index - ident_start };
}
