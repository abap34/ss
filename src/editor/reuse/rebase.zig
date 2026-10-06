const std = @import("std");
const ast = @import("ast");
const core = @import("core");
const utils = @import("utils");
const analysis = @import("../../analysis.zig");
const Edit = @import("../edit/generated.zig").Edit;

// The evaluated store keeps its owned declarations and runtime values. Relocate
// their source references without replacing the trees borrowed by those values.
pub fn stateSource(state: *core.DocumentState, pages: *core.prepared.PreparedPages, edit: *const Edit, syntax: *const ast.Module) !void {
    const module = @import("source.zig").stateModuleForPathMutable(state, edit.path) orelse return error.UnknownModule;
    const allocator = state.allocator;
    const text = try allocator.dupe(u8, edit.source);
    errdefer allocator.free(text);
    const lines = try utils.source.LineIndex.init(allocator, text);
    errdefer lines.deinit(allocator);
    var binding_types = @TypeOf(state.source_map.binding_types).init(allocator);
    errdefer binding_types.deinit();
    var bindings = state.source_map.binding_types.iterator();
    while (bindings.next()) |entry| {
        var key = entry.key_ptr.*;
        if (key.module_id == module.id) key.offset = edit.mapOffset(key.offset);
        try binding_types.put(key, entry.value_ptr.*);
    }

    relocateSpans(&module.syntax, edit);
    for (edit.replacements) |replacement| {
        const old_span = replacement.expected.origin.?.span.?;
        const span = edit.mapSpan(old_span);
        const target = findStatement(&module.syntax, span.start) orelse return error.InvalidConstraintOrigin;
        const updated = findStatement(syntax, span.start) orelse return error.InvalidConstraintOrigin;
        if (target.kind != .constrain or updated.kind != .constrain) return error.InvalidConstraintOrigin;
        const constraint = try updated.kind.constrain.clone(allocator);
        target.kind.constrain.deinit(allocator);
        target.kind.constrain = constraint;
        // An omitted numeric term can change how the parser consumes trailing
        // whitespace. Use the parsed statement boundary for future edits.
        target.span = updated.span;
    }
    state.source_map.binding_types.deinit();
    state.source_map.binding_types = binding_types;
    module.line_index.deinit(allocator);
    allocator.free(module.source);
    module.source = text;
    module.line_index = lines;

    for (state.source_map.pages.items) |*item| if (item.module_id == module.id) relocateRange(item, edit);
    for (state.source_map.objects.items) |*item| if (item.module_id == module.id) relocateRange(item, edit);
    for (state.source_map.definitions.items) |*item| if (item.module_id == module.id) relocateDefinition(item, edit, lines);
    var functions = state.functions.iterator();
    while (functions.next()) |entry| if (entry.key_ptr.module_id == module.id) {
        // Bodies and parameter arrays already moved with the owning AST.
        entry.value_ptr.span = edit.mapSpan(entry.value_ptr.span);
        if (entry.value_ptr.name_span) |*span| span.* = edit.mapSpan(span.*);
    };
    var constants = state.constants.declarations.iterator();
    while (constants.next()) |entry| if (entry.key_ptr.module_id == module.id) {
        entry.value_ptr.span = edit.mapSpan(entry.value_ptr.span);
        if (entry.value_ptr.name_span) |*span| span.* = edit.mapSpan(span.*);
    };
    for (state.declaration_index.classes.items) |*item| if (item.module_id == module.id) {
        item.span = edit.mapSpan(item.span);
    };
    for (state.declaration_index.fields.items) |*item| if (item.module_id == module.id) {
        if (item.name_span) |*span| span.* = edit.mapSpan(span.*);
    };
    for (state.declaration_index.record_fields.items) |*item| if (item.module_id == module.id) {
        if (item.name_span) |*span| span.* = edit.mapSpan(span.*);
    };

    for (state.graph.nodes.items) |*node| {
        relocateOrigin(&node.origin, edit, state.projectPath(), syntax);
        for (node.fields.items) |*field| relocateOrigin(&field.origin, edit, state.projectPath(), syntax);
        for (node.content_provenance.items) |*entry| relocateOriginValue(&entry.origin, edit, state.projectPath(), syntax);
        for (node.display_content_provenance.items) |*entry| relocateOriginValue(&entry.origin, edit, state.projectPath(), syntax);
    }
    var provenance = state.runtime.string_provenance.valueIterator();
    while (provenance.next()) |entries| for (entries.items) |*entry| relocateOriginValue(&entry.origin, edit, state.projectPath(), syntax);
    for (state.constraints.active.items) |*item| relocateOrigin(&item.origin, edit, state.projectPath(), syntax);
    for (state.constraints.fallback.items) |*item| relocateOrigin(&item.origin, edit, state.projectPath(), syntax);
    for (state.constraints.overridden.items) |*item| relocateOrigin(&item.origin, edit, state.projectPath(), syntax);
    for (state.constraints.updates.items) |*item| {
        relocateOrigin(&item.origin, edit, state.projectPath(), syntax);
        if (item.replacement) |*value| relocateOrigin(&value.origin, edit, state.projectPath(), syntax);
    }
    for (pages.pages) |*page| for (page.objects) |*object| {
        // Content provenance borrows the node's already relocated entries.
        relocateOrigin(&object.origin, edit, state.projectPath(), syntax);
    };
}

pub fn snapshotSource(snapshot: *analysis.snapshot.AnalysisSnapshot, edit: *const Edit) !void {
    for (snapshot.modules) |*module| {
        if (!std.mem.eql(u8, module.path orelse continue, edit.path)) continue;
        const text = try snapshot.allocator.dupe(u8, edit.source);
        errdefer snapshot.allocator.free(text);
        const lines = try utils.source.LineIndex.init(snapshot.allocator, text);
        for (module.imports) |*item| relocateSpans(item, edit);
        for (module.function_scopes) |*item| {
            item.start = edit.mapOffset(item.start);
            item.end = edit.mapOffset(item.end);
        }
        for (module.page_scopes) |*item| {
            item.start = edit.mapOffset(item.start);
            item.end = edit.mapOffset(item.end);
        }
        for (module.symbols) |*item| relocateSpans(item, edit);
        for (module.folding_ranges) |*item| relocateSpans(item, edit);
        for (snapshot.definitions) |*item| if (item.module_id == module.id) relocateDefinition(item, edit, lines);
        for (snapshot.variable_bindings) |*item| if (item.module_id == module.id) {
            relocateRange(item, edit);
            item.visible_start = edit.mapOffset(item.visible_start);
            item.visible_end = edit.mapOffset(item.visible_end);
        };
        for (snapshot.type_definitions) |*item| if (item.module_id == module.id) {
            const old_offset = offsetAtLocation(module.line_index, item.line, item.column);
            const location = lines.locationAt(edit.mapOffset(old_offset));
            item.line = location.line;
            item.column = location.column;
        };
        for (snapshot.fields) |*item| if (item.module_id == module.id) {
            if (item.name_span) |*span| span.* = edit.mapSpan(span.*);
        };
        for (snapshot.record_fields) |*item| if (item.module_id == module.id) {
            if (item.name_span) |*span| span.* = edit.mapSpan(span.*);
        };
        for (snapshot.enum_cases) |*item| if (item.module_id == module.id) {
            if (item.name_span) |*span| span.* = edit.mapSpan(span.*);
        };
        module.line_index.deinit(snapshot.allocator);
        snapshot.allocator.free(module.source);
        module.source = text;
        module.line_index = lines;
        break;
    }
    // Reuse is restricted to snapshots with no diagnostics.
    std.debug.assert(snapshot.diagnostics.items.items.len == 0);
    for (snapshot.diagnostics.sources.items) |*entry| {
        if (!std.mem.eql(u8, entry.path, edit.path)) continue;
        const text = try snapshot.allocator.dupe(u8, edit.source);
        snapshot.allocator.free(entry.text);
        entry.text = text;
    }
}

fn relocateDefinition(item: *core.Definition, edit: *const Edit, lines: utils.source.LineIndex) void {
    relocateRange(item, edit);
    item.visible_start = edit.mapOffset(item.visible_start);
    item.visible_end = edit.mapOffset(item.visible_end);
    const location = lines.locationAt(item.span_start);
    item.line = location.line;
    item.column = location.column;
}

fn relocateRange(item: anytype, edit: *const Edit) void {
    item.span_start = edit.mapOffset(item.span_start);
    item.span_end = edit.mapOffset(item.span_end);
}

fn relocateOrigin(origin: *?core.SourceOrigin, edit: *const Edit, project_path: []const u8, syntax: *const ast.Module) void {
    if (origin.*) |*value| relocateOriginValue(value, edit, project_path, syntax);
}

fn relocateOriginValue(origin: *core.SourceOrigin, edit: *const Edit, project_path: []const u8, syntax: *const ast.Module) void {
    if (!std.mem.eql(u8, origin.path orelse project_path, edit.path)) return;
    if (origin.span) |*span| {
        const previous = span.*;
        span.* = edit.mapSpan(previous);
        for (edit.replacements) |replacement| {
            const expected = replacement.expected.origin.?.span.?;
            if (previous.start == expected.start and previous.end == expected.end) {
                if (findStatement(syntax, span.start)) |statement| span.* = statement.span;
                break;
            }
        }
    }
}

fn offsetAtLocation(lines: utils.source.LineIndex, line: usize, column: usize) usize {
    const selected = lines.lineByNumber(line) orelse return 0;
    var offset = selected.span.start;
    var remaining = column -| 1;
    while (remaining > 0 and offset < selected.span.end) : (remaining -= 1) {
        offset += std.unicode.utf8ByteSequenceLength(lines.text[offset]) catch 1;
    }
    return offset;
}

// AST storage is an owned tree. Skip strings and semantic types, whose names
// and type storage can be shared with declarations from other modules.
fn relocateSpans(value: anytype, edit: *const Edit) void {
    const T = @TypeOf(value.*);
    if (T == ast.Span) {
        value.* = edit.mapSpan(value.*);
        return;
    }
    if (T == ast.Type) return;
    switch (@typeInfo(T)) {
        .@"struct" => inline for (comptime std.meta.fieldNames(T)) |field_name| relocateSpans(&@field(value.*, field_name), edit),
        .@"union" => switch (value.*) {
            inline else => |*item| relocateSpans(item, edit),
        },
        .optional => if (value.*) |*item| relocateSpans(item, edit),
        .pointer => |info| switch (info.size) {
            .one => relocateSpans(@constCast(value.*), edit),
            .slice => if (info.child != u8) {
                for (@constCast(value.*)) |*item| relocateSpans(item, edit);
            },
            else => {},
        },
        else => {},
    }
}

fn findStatement(module: *const ast.Module, start: usize) ?*ast.Statement {
    for (module.pages.items) |*page| if (findInStatements(page.statements.items, start)) |statement| return statement;
    return null;
}

fn findInStatements(statements: []ast.Statement, start: usize) ?*ast.Statement {
    for (statements) |*statement| {
        if (statement.span.start == start) return statement;
        if (statement.kind == .if_stmt) {
            if (findInStatements(statement.kind.if_stmt.then_statements.items, start)) |value| return value;
            if (findInStatements(statement.kind.if_stmt.else_statements.items, start)) |value| return value;
        }
    }
    return null;
}
