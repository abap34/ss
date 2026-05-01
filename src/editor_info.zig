const std = @import("std");
const core = @import("core");
const parser = @import("parser.zig");
const ast = @import("parser/ast.zig");
const registry = @import("parser/registry.zig");
const typecheck = @import("parser/typecheck.zig");
const utils = @import("utils");
const error_report = utils.err;
const json = utils.json;

const DefinitionKind = enum {
    function,
    variable,
};

const EditorDefinition = struct {
    line: usize,
    column: usize,
    length: usize,
    kind: DefinitionKind,
    file: ?[]const u8 = null,
};

const InlayHintKind = enum {
    parameter_names,
    solved_frame,
};

const InlayHintInfo = struct {
    line: usize,
    column: usize,
    label: []const u8,
    kind: InlayHintKind,
};

pub fn writeEditorInfoJson(
    allocator: std.mem.Allocator,
    io: std.Io,
    source_path: []const u8,
    source: []const u8,
    program: parser.Program,
    engine: *core.Engine,
) !void {
    const base_dir = std.fs.path.dirname(source_path) orelse ".";
    var index = try typecheck.loadProgramIndex(allocator, io, base_dir, program);
    defer index.deinit();

    var variables = try typecheck.collectVariableTypesFromProgram(allocator, &index.functions, program);
    defer variables.deinit();

    var definitions = std.StringHashMap(EditorDefinition).init(allocator);
    defer freeDefinitions(allocator, &definitions);
    if (index.base_program) |base_program| {
        try collectDefinitionsFromProgram(allocator, index.base_source.?, base_program, index.base_path.?, false, &definitions);
    }
    if (index.theme_program) |theme_program| {
        try collectDefinitionsFromProgram(allocator, index.theme_source.?, theme_program, index.theme_path.?, false, &definitions);
    }
    try collectDefinitionsFromProgram(allocator, source, program, null, true, &definitions);

    var hints = try collectProgramHints(allocator, source, program, &index.functions);
    defer {
        for (hints.items) |hint| allocator.free(hint.label);
        hints.deinit(allocator);
    }
    try collectSolvedSizeHints(allocator, source, engine, &hints);

    try writeJson(allocator, &index, &variables, &definitions, hints.items);
}

fn writeJson(
    allocator: std.mem.Allocator,
    index: *const typecheck.ProgramIndex,
    variables: *const std.StringHashMap(core.SemanticSort),
    definitions: *const std.StringHashMap(EditorDefinition),
    hints: []const InlayHintInfo,
) !void {
    var root = json.Object.begin(allocator);
    var hint_array = try root.arrayField("hints");
    for (hints) |hint| {
        var item = try hint_array.objectItem();
        try item.intField("line", hint.line);
        try item.intField("column", hint.column);
        try item.stringField("label", hint.label);
        try item.enumTagField("kind", hint.kind);
        item.end();
    }
    hint_array.end();

    var function_array = try root.arrayField("functions");
    for (registry.primitiveDescriptors()) |descriptor| {
        if (index.functions.contains(descriptor.name)) continue;
        try writePrimitiveFunctionJson(allocator, &function_array, descriptor);
    }
    var function_iterator = index.functions.iterator();
    while (function_iterator.next()) |entry| {
        const metadata = index.function_metadata.get(entry.key_ptr.*) orelse typecheck.FunctionMetadata{ .source = .project };
        try writeUserFunctionJson(allocator, &function_array, entry.key_ptr.*, entry.value_ptr.*, metadata);
    }
    function_array.end();

    var variable_array = try root.arrayField("variables");
    var variable_iterator = variables.iterator();
    while (variable_iterator.next()) |entry| {
        var item = try variable_array.objectItem();
        try item.stringField("name", entry.key_ptr.*);
        try item.enumTagField("type", entry.value_ptr.*);
        item.end();
    }
    variable_array.end();

    var definition_array = try root.arrayField("definitions");
    var definition_iterator = definitions.iterator();
    while (definition_iterator.next()) |entry| {
        try writeDefinitionJson(&definition_array, entry.key_ptr.*, entry.value_ptr.*);
    }
    definition_array.end();
    root.end();
    json.newline();
}

fn writePrimitiveFunctionJson(
    allocator: std.mem.Allocator,
    functions: *json.Array,
    descriptor: registry.PrimitiveDescriptor,
) !void {
    const signature = try formatPrimitiveSignature(allocator, descriptor);
    defer allocator.free(signature);

    var item = try functions.objectItem();
    try item.stringField("name", descriptor.name);
    try item.stringField("signature", signature);
    try item.stringField("resultSort", resultText(descriptor.result_sort));
    try item.stringField("source", "primitive");
    try item.stringField("summary", descriptor.summary);
    var params = try item.arrayField("params");
    for (descriptor.arg_names, 0..) |_, index| {
        const label = try formatPrimitiveParam(allocator, descriptor, index);
        defer allocator.free(label);
        try params.stringItem(label);
    }
    params.end();
    item.end();
}

fn writeUserFunctionJson(
    allocator: std.mem.Allocator,
    functions: *json.Array,
    name: []const u8,
    func: parser.FunctionDecl,
    metadata: typecheck.FunctionMetadata,
) !void {
    const signature = try formatUserSignature(allocator, name, func);
    defer allocator.free(signature);

    var item = try functions.objectItem();
    try item.stringField("name", name);
    try item.stringField("signature", signature);
    try item.enumTagField("resultSort", func.result_sort);
    try item.enumTagField("source", metadata.source);
    try item.stringField("summary", "");
    var params = try item.arrayField("params");
    for (func.params.items, 0..) |param, index| {
        _ = index;
        const label = try formatUserParam(allocator, param);
        defer allocator.free(label);
        try params.stringItem(label);
    }
    params.end();
    item.end();
}

fn writeDefinitionJson(definitions: *json.Array, name: []const u8, definition: EditorDefinition) !void {
    var item = try definitions.objectItem();
    try item.stringField("name", name);
    try item.enumTagField("kind", definition.kind);
    try item.intField("line", definition.line);
    try item.intField("column", definition.column);
    try item.intField("length", definition.length);
    try item.optionalStringField("file", definition.file);
    item.end();
}

fn formatPrimitiveSignature(allocator: std.mem.Allocator, descriptor: registry.PrimitiveDescriptor) ![]const u8 {
    var params = std.ArrayList(u8).empty;
    defer params.deinit(allocator);
    for (descriptor.arg_names, 0..) |_, index| {
        if (index != 0) try params.appendSlice(allocator, ", ");
        const label = try formatPrimitiveParam(allocator, descriptor, index);
        defer allocator.free(label);
        try params.appendSlice(allocator, label);
    }
    return std.fmt.allocPrint(allocator, "{s}({s}) -> {s}", .{ descriptor.name, params.items, resultText(descriptor.result_sort) });
}

fn formatUserSignature(allocator: std.mem.Allocator, name: []const u8, func: parser.FunctionDecl) ![]const u8 {
    var params = std.ArrayList(u8).empty;
    defer params.deinit(allocator);
    for (func.params.items, 0..) |param, index| {
        if (index != 0) try params.appendSlice(allocator, ", ");
        const label = try formatUserParam(allocator, param);
        defer allocator.free(label);
        try params.appendSlice(allocator, label);
    }
    return std.fmt.allocPrint(allocator, "{s}({s}) -> {s}", .{ name, params.items, @tagName(func.result_sort) });
}

fn formatUserParam(allocator: std.mem.Allocator, param: parser.ParamDecl) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}: {s}", .{ param.name, @tagName(param.sort) });
}

fn formatPrimitiveParam(allocator: std.mem.Allocator, descriptor: registry.PrimitiveDescriptor, index: usize) ![]const u8 {
    const name = descriptor.arg_names[index];
    if (typecheck.expectedPrimitiveArgSort(descriptor, index)) |sort| {
        return std.fmt.allocPrint(allocator, "{s}: {s}", .{ name, @tagName(sort) });
    }
    return allocator.dupe(u8, name);
}

fn resultText(result_sort: ?core.SemanticSort) []const u8 {
    return if (result_sort) |sort| @tagName(sort) else "unknown";
}

fn collectDefinitionsFromProgram(
    allocator: std.mem.Allocator,
    source: []const u8,
    program: parser.Program,
    file: ?[]const u8,
    include_variables: bool,
    definitions: *std.StringHashMap(EditorDefinition),
) !void {
    for (program.functions.items) |func| {
        if (findIdentifierOffsetAfterKeyword(source, func.span.start, "fn", func.name)) |location| {
            const loc = error_report.computeLineColumn(source, location.offset);
            try putDefinition(allocator, definitions, func.name, loc.line, loc.column, location.length, .function, file);
        }
        if (include_variables) {
            for (func.statements.items) |stmt| {
                try collectDefinitionsFromStatement(allocator, source, stmt, definitions);
            }
        }
    }
    if (include_variables) {
        for (program.pages.items) |page| {
            for (page.statements.items) |stmt| {
                try collectDefinitionsFromStatement(allocator, source, stmt, definitions);
            }
        }
    }
}

fn collectDefinitionsFromStatement(
    allocator: std.mem.Allocator,
    source: []const u8,
    stmt: parser.Statement,
    definitions: *std.StringHashMap(EditorDefinition),
) !void {
    switch (stmt.kind) {
        .let_binding => |binding| try putStatementDefinition(allocator, source, stmt, "let", binding.name, definitions),
        .bind_binding => |binding| try putStatementDefinition(allocator, source, stmt, "bind", binding.name, definitions),
        else => {},
    }
}

fn putStatementDefinition(
    allocator: std.mem.Allocator,
    source: []const u8,
    stmt: parser.Statement,
    keyword: []const u8,
    name: []const u8,
    definitions: *std.StringHashMap(EditorDefinition),
) !void {
    if (findIdentifierOffsetAfterKeyword(source, stmt.span.start, keyword, name)) |location| {
        const loc = error_report.computeLineColumn(source, location.offset);
        try putDefinition(allocator, definitions, name, loc.line, loc.column, location.length, .variable, null);
    }
}

fn putDefinition(
    allocator: std.mem.Allocator,
    definitions: *std.StringHashMap(EditorDefinition),
    name: []const u8,
    line: usize,
    column: usize,
    length: usize,
    kind: DefinitionKind,
    file: ?[]const u8,
) !void {
    if (definitions.fetchRemove(name)) |entry| {
        allocator.free(entry.key);
        if (entry.value.file) |old_file| allocator.free(old_file);
    }
    try definitions.put(
        try allocator.dupe(u8, name),
        .{
            .line = line,
            .column = column,
            .length = length,
            .kind = kind,
            .file = if (file) |path| try allocator.dupe(u8, path) else null,
        },
    );
}

fn freeDefinitions(allocator: std.mem.Allocator, definitions: *std.StringHashMap(EditorDefinition)) void {
    var iterator = definitions.iterator();
    while (iterator.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        if (entry.value_ptr.file) |file| allocator.free(file);
    }
    definitions.deinit();
}

fn collectProgramHints(
    allocator: std.mem.Allocator,
    source: []const u8,
    program: parser.Program,
    functions: *const std.StringHashMap(parser.FunctionDecl),
) !std.ArrayList(InlayHintInfo) {
    var hints = std.ArrayList(InlayHintInfo).empty;
    errdefer {
        for (hints.items) |hint| allocator.free(hint.label);
        hints.deinit(allocator);
    }

    for (program.functions.items) |func| {
        for (func.statements.items) |stmt| {
            try collectStatementHints(allocator, &hints, functions, source, stmt);
        }
    }
    for (program.pages.items) |page| {
        for (page.statements.items) |stmt| {
            try collectStatementHints(allocator, &hints, functions, source, stmt);
        }
    }
    return hints;
}

fn collectStatementHints(
    allocator: std.mem.Allocator,
    hints: *std.ArrayList(InlayHintInfo),
    functions: *const std.StringHashMap(parser.FunctionDecl),
    source: []const u8,
    stmt: parser.Statement,
) !void {
    switch (stmt.kind) {
        .let_binding => |binding| try collectExprHints(allocator, hints, functions, source, stmt.span, binding.expr),
        .bind_binding => |binding| try collectExprHints(allocator, hints, functions, source, stmt.span, binding.expr),
        .return_expr => |expr| try collectExprHints(allocator, hints, functions, source, stmt.span, expr),
        .expr_stmt => |expr| try collectExprHints(allocator, hints, functions, source, stmt.span, expr),
        else => {},
    }
}

fn collectExprHints(
    allocator: std.mem.Allocator,
    hints: *std.ArrayList(InlayHintInfo),
    functions: *const std.StringHashMap(parser.FunctionDecl),
    source: []const u8,
    span: ast.Span,
    expr: parser.Expr,
) !void {
    switch (expr) {
        .call => |call| {
            try hintForCallExpr(allocator, hints, functions, source, span, call);
            for (call.args.items) |arg| try collectExprHints(allocator, hints, functions, source, span, arg);
        },
        else => {},
    }
}

fn hintForCallExpr(
    allocator: std.mem.Allocator,
    hints: *std.ArrayList(InlayHintInfo),
    functions: *const std.StringHashMap(parser.FunctionDecl),
    source: []const u8,
    span: ast.Span,
    call: parser.CallExpr,
) !void {
    if (call.args.items.len == 0) return;
    const slice = source[span.start..@min(span.end, source.len)];
    const arg_starts = try findCallArgStartOffsets(allocator, slice, call.name, call.args.items.len);
    defer allocator.free(arg_starts);
    const hint_count = @min(call.args.items.len, arg_starts.len);
    for (0..hint_count) |index| {
        const param_name = callParamName(functions, call.name, index) orelse continue;
        const label = try std.fmt.allocPrint(allocator, "{s}:", .{param_name});
        try appendInlayHint(allocator, hints, source, span.start + arg_starts[index], label, .parameter_names);
    }
}

fn callParamName(functions: *const std.StringHashMap(parser.FunctionDecl), call_name: []const u8, index: usize) ?[]const u8 {
    if (functions.get(call_name)) |func| {
        if (index < func.params.items.len) return func.params.items[index].name;
        return null;
    }
    if (registry.lookupPrimitiveCall(call_name)) |descriptor| {
        if (descriptor.arg_names.len == 0) return null;
        return if (index < descriptor.arg_names.len)
            descriptor.arg_names[index]
        else
            descriptor.arg_names[descriptor.arg_names.len - 1];
    }
    return null;
}

fn collectSolvedSizeHints(
    allocator: std.mem.Allocator,
    source: []const u8,
    engine: *core.Engine,
    hints: *std.ArrayList(InlayHintInfo),
) !void {
    var best_by_origin = std.StringHashMap(core.NodeId).init(allocator);
    defer best_by_origin.deinit();

    for (engine.nodes.items) |node| {
        if ((node.kind != .object and node.kind != .derived) or !node.attached) continue;
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
        const span = error_report.parseByteOrigin(entry.key_ptr.*) orelse continue;
        const node = engine.getNode(entry.value_ptr.*) orelse continue;
        const label = try std.fmt.allocPrint(
            allocator,
            " x={d:.0} y={d:.0} w={d:.0} h={d:.0}",
            .{ node.frame.x, node.frame.y, node.frame.width, node.frame.height },
        );
        try appendInlayHint(allocator, hints, source, trimHintByteIndexToLineEnd(source, span.end), label, .solved_frame);
    }
}

fn appendInlayHint(
    allocator: std.mem.Allocator,
    hints: *std.ArrayList(InlayHintInfo),
    source: []const u8,
    byte_index: usize,
    label: []const u8,
    kind: InlayHintKind,
) !void {
    const loc = error_report.computeLineColumn(source, byte_index);
    try hints.append(allocator, .{
        .line = loc.line,
        .column = loc.column,
        .label = label,
        .kind = kind,
    });
}

fn findIdentifierOffsetAfterKeyword(source: []const u8, start: usize, keyword: []const u8, expected_name: []const u8) ?struct { offset: usize, length: usize } {
    if (start >= source.len or start + keyword.len >= source.len) return null;
    if (!std.mem.startsWith(u8, source[start..@min(source.len, start + keyword.len)], keyword)) return null;

    var pos = start + keyword.len;
    skipTriviaFrom(source, &pos);
    const name_start = pos;
    if (pos >= source.len or !isIdentifierStart(source[pos])) return null;
    while (pos < source.len and isIdentifierContinue(source[pos])) pos += 1;
    if (!std.mem.eql(u8, source[name_start..pos], expected_name)) return null;
    return .{ .offset = name_start, .length = pos - name_start };
}

fn findCallArgStartOffsets(
    allocator: std.mem.Allocator,
    slice: []const u8,
    call_name: []const u8,
    arg_count: usize,
) ![]usize {
    var starts = std.ArrayList(usize).empty;
    errdefer starts.deinit(allocator);
    if (arg_count == 0) return starts.toOwnedSlice(allocator);

    const name_index = std.mem.indexOf(u8, slice, call_name) orelse return starts.toOwnedSlice(allocator);
    var index = skipHorizontalSpace(slice, name_index + call_name.len);
    if (index >= slice.len) return starts.toOwnedSlice(allocator);

    if (slice[index] != '(') {
        const arg_start = skipHorizontalSpace(slice, index);
        if (arg_start < slice.len) try starts.append(allocator, arg_start);
        return starts.toOwnedSlice(allocator);
    }

    index += 1;
    var depth: usize = 0;
    var in_string = false;
    var escaped = false;
    var want_arg_start = true;

    while (index < slice.len) : (index += 1) {
        const ch = slice[index];
        if (in_string) {
            if (escaped) {
                escaped = false;
                continue;
            }
            if (ch == '\\') {
                escaped = true;
                continue;
            }
            if (ch == '"') in_string = false;
            continue;
        }

        if (ch == '"') {
            if (want_arg_start) {
                try starts.append(allocator, index);
                want_arg_start = false;
            }
            in_string = true;
            continue;
        }

        if (want_arg_start and !std.ascii.isWhitespace(ch)) {
            try starts.append(allocator, index);
            want_arg_start = false;
        }

        switch (ch) {
            '(' => depth += 1,
            ')' => {
                if (depth == 0) break;
                depth -= 1;
            },
            ',' => {
                if (depth == 0) want_arg_start = true;
            },
            else => {},
        }
    }

    return starts.toOwnedSlice(allocator);
}

fn trimHintByteIndexToLineEnd(source: []const u8, byte_index: usize) usize {
    var index = @min(byte_index, source.len);
    while (index > 0) {
        const ch = source[index - 1];
        if (ch == '\n' or ch == '\r' or ch == ' ' or ch == '\t') {
            index -= 1;
            continue;
        }
        break;
    }
    return index;
}

fn skipHorizontalSpace(slice: []const u8, start: usize) usize {
    var index = start;
    while (index < slice.len and (slice[index] == ' ' or slice[index] == '\t' or slice[index] == '\r' or slice[index] == '\n')) : (index += 1) {}
    return index;
}

fn isIdentifierStart(ch: u8) bool {
    return std.ascii.isAlphabetic(ch) or ch == '_';
}

fn isIdentifierContinue(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_';
}

fn skipTriviaFrom(source: []const u8, pos: *usize) void {
    while (pos.* < source.len) {
        switch (source[pos.*]) {
            ' ', '\t', '\r', '\n' => pos.* += 1,
            '/' => {
                if (pos.* + 1 < source.len and source[pos.* + 1] == '/') {
                    pos.* += 2;
                    while (pos.* < source.len and source[pos.*] != '\n') pos.* += 1;
                } else return;
            },
            ';' => {
                if (pos.* + 1 < source.len and source[pos.* + 1] == ';') {
                    pos.* += 2;
                    while (pos.* < source.len and source[pos.*] != '\n') pos.* += 1;
                } else return;
            },
            '#' => {
                while (pos.* < source.len and source[pos.*] != '\n') pos.* += 1;
            },
            else => return,
        }
    }
}
