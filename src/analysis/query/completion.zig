const std = @import("std");
const ast = @import("ast");
const core = @import("core");

const language_names = @import("../../language/names.zig");
const type_resolution = @import("../../language/type_resolution.zig");
const resolve_query = @import("resolve.zig");
const cursor = @import("cursor.zig");
const syntax = @import("../../syntax.zig");
const types = @import("types.zig");
const utils = @import("utils");

const Candidate = types.CompletionCandidate;
const Result = types.CompletionResult;

const PropertyTarget = union(enum) {
    class: []const u8,
    any_object,
    record: []const u8,
};

pub fn at(
    allocator: std.mem.Allocator,
    snapshot: anytype,
    req: types.SourceRequest,
    opts: types.QueryOptions,
) !Result {
    const budget = types.QueryBudget.start(opts);
    if (budget.expired()) return emptyResult(allocator);
    var parsed = syntax.parseRecoveringWithSourceName(allocator, req.source, req.path) catch null;
    defer if (parsed) |*result| result.deinit(allocator);
    const parsed_program = if (parsed) |*result| &result.program else null;
    if (budget.expired()) return emptyResult(allocator);
    if (try completeRecordUpdateAt(allocator, snapshot, req, parsed_program)) |result| return result;
    if (try completeModuleAccessAt(allocator, snapshot, req, parsed_program)) |result| return result;
    if (try completeMemberAccessAt(allocator, snapshot, req, parsed_program)) |result| return result;
    return completeRegular(allocator, snapshot, req, parsed_program);
}

fn emptyResult(allocator: std.mem.Allocator) !Result {
    return .{ .items = try allocator.alloc(Candidate, 0) };
}

fn completeRegular(allocator: std.mem.Allocator, snapshot: anytype, req: types.SourceRequest, program: ?*const ast.Program) !Result {
    var builder = CandidateBuilder.init(allocator);
    defer builder.deinit();

    for (language_names.keywordLabels()) |keyword| try builder.add(.{ .label = keyword, .kind = .keyword, .detail = "keyword" });
    try appendImportAsCompletions(&builder, req.source, req.offset);
    try appendVisibleValues(&builder, snapshot, req.path);
    if (snapshot.moduleForPath(req.path)) |module| {
        try appendVisibleVariables(&builder, snapshot, module.id, req.offset);
    }
    try appendTypeNameCompletions(&builder, snapshot, program, req.source);
    for (snapshot.role_bindings) |role| {
        try builder.add(.{ .label = role.name, .kind = .role, .detail = role.type_label });
    }
    return builder.finish();
}

const CandidateBuilder = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(Candidate),
    seen: std.StringHashMap(void),

    fn init(allocator: std.mem.Allocator) CandidateBuilder {
        return .{
            .allocator = allocator,
            .items = .empty,
            .seen = std.StringHashMap(void).init(allocator),
        };
    }

    fn deinit(self: *CandidateBuilder) void {
        self.items.deinit(self.allocator);
        self.seen.deinit();
    }

    fn add(self: *CandidateBuilder, candidate: Candidate) !void {
        if (candidate.label.len == 0 or self.seen.contains(candidate.label)) return;
        try self.seen.put(candidate.label, {});
        try self.items.append(self.allocator, candidate);
    }

    fn finish(self: *CandidateBuilder) !Result {
        return .{ .items = try self.items.toOwnedSlice(self.allocator) };
    }
};

fn completeModuleAccessAt(allocator: std.mem.Allocator, snapshot: anytype, req: types.SourceRequest, program: ?*const ast.Program) !?Result {
    const parsed = program orelse return null;
    const callable = cursor.callableAt(parsed, req.offset) orelse return null;
    if (callable.role != .name) return null;
    const alias = callable.callee.qualifier orelse return null;
    var builder = CandidateBuilder.init(allocator);
    defer builder.deinit();

    const module = snapshot.moduleForPath(req.path) orelse return try builder.finish();
    const module_id = resolve_query.aliasTarget(snapshot, module.id, alias) orelse return try builder.finish();
    try appendModuleValues(&builder, snapshot, module_id);
    return try builder.finish();
}

fn completeMemberAccessAt(allocator: std.mem.Allocator, snapshot: anytype, req: types.SourceRequest, program: ?*const ast.Program) !?Result {
    const parsed = program orelse return null;
    const member = cursor.memberAt(parsed, req.offset) orelse return null;
    var builder = CandidateBuilder.init(allocator);
    defer builder.deinit();
    if (enumTypeForExpr(snapshot, req, member.target)) |enum_type| {
        try appendEnumCases(&builder, snapshot, enum_type);
    } else if (propertyTargetForExpr(snapshot, req, parsed, member.target, 0)) |target| {
        try appendProperties(&builder, snapshot, target);
    }
    return try builder.finish();
}

fn completeRecordUpdateAt(allocator: std.mem.Allocator, snapshot: anytype, req: types.SourceRequest, program: ?*const ast.Program) !?Result {
    const parsed = program orelse return null;
    const target = cursor.recordUpdateCompletionAt(parsed, req.offset) orelse return null;
    const base_record_name = recordNameForCompletionExpr(snapshot, req, parsed, target.target, 0) orelse return null;
    const record_name = resolve_query.recordNameAfterPath(snapshot, base_record_name, target.path_prefix) orelse return null;
    var builder = CandidateBuilder.init(allocator);
    defer builder.deinit();
    try appendProperties(&builder, snapshot, .{ .record = record_name });
    return try builder.finish();
}

fn appendVisibleValues(builder: *CandidateBuilder, snapshot: anytype, path: []const u8) !void {
    if (snapshot.moduleForPath(path)) |module| {
        var visiting = std.AutoHashMap(core.SourceModuleId, void).init(builder.allocator);
        defer visiting.deinit();
        try appendOpenValues(builder, snapshot, module.id, &visiting);

        var implicit_index = module.implicit_import_ids.len;
        while (implicit_index > 0) {
            implicit_index -= 1;
            try appendOpenValues(builder, snapshot, module.implicit_import_ids[implicit_index], &visiting);
        }
    } else {
        for (snapshot.value_bindings) |binding| {
            if (binding.module_id != null) continue;
            try appendValueBinding(builder, binding);
        }
        return;
    }

    for (snapshot.value_bindings) |binding| {
        if (!binding.primitive) continue;
        try appendValueBinding(builder, binding);
    }
}

fn appendOpenValues(
    builder: *CandidateBuilder,
    snapshot: anytype,
    module_id: core.SourceModuleId,
    visiting: *std.AutoHashMap(core.SourceModuleId, void),
) !void {
    if (visiting.contains(module_id)) return;
    try visiting.put(module_id, {});
    try appendModuleValues(builder, snapshot, module_id);
    const module = snapshot.moduleById(module_id) orelse return;
    var index = module.imports.len;
    while (index > 0) {
        index -= 1;
        const import_info = module.imports[index];
        if (!import_info.unqualified) continue;
        const imported_id = import_info.module_id orelse continue;
        try appendOpenValues(builder, snapshot, imported_id, visiting);
    }
}

fn appendModuleValues(builder: *CandidateBuilder, snapshot: anytype, module_id: core.SourceModuleId) !void {
    for (snapshot.value_bindings) |binding| {
        if ((binding.module_id orelse continue) != module_id) continue;
        try appendValueBinding(builder, binding);
    }
}

fn appendValueBinding(builder: *CandidateBuilder, binding: anytype) !void {
    switch (binding.kind) {
        .function => try builder.add(.{
            .label = binding.name,
            .kind = .function,
            .detail = binding.signature,
            .documentation = binding.documentation,
        }),
        .constant => try builder.add(.{
            .label = binding.name,
            .kind = .variable,
            .detail = binding.signature,
            .documentation = binding.documentation,
        }),
    }
}

fn appendVisibleVariables(builder: *CandidateBuilder, snapshot: anytype, module_id: core.SourceModuleId, offset: usize) !void {
    for (snapshot.variable_bindings) |binding| {
        if (!resolve_query.variableBindingVisibleAt(snapshot, module_id, offset, binding)) continue;
        const visible = resolve_query.visibleVariableBinding(snapshot, module_id, offset, binding.name) orelse continue;
        try builder.add(.{
            .label = visible.name,
            .kind = .variable,
            .detail = visible.type_label,
        });
    }
}

fn appendTypeNameCompletions(builder: *CandidateBuilder, snapshot: anytype, program: ?*const ast.Program, source: []const u8) !void {
    for (type_resolution.builtinTypes()) |builtin| {
        try builder.add(.{ .label = builtin.name, .kind = .type_decl, .detail = "builtin type" });
    }
    try appendParsedTypeNameCompletions(builder, program, source);
    for (snapshot.type_definitions) |definition| {
        try builder.add(.{
            .label = definition.name,
            .kind = switch (definition.kind) {
                .object => .class,
                .record, .enum_type => .type_decl,
            },
            .detail = switch (definition.kind) {
                .record => "record",
                .object => null,
                .enum_type => "type",
            },
        });
    }
}

fn appendParsedTypeNameCompletions(builder: *CandidateBuilder, program: ?*const ast.Program, source: []const u8) !void {
    const parsed = program orelse return;
    for (parsed.types.items) |decl| {
        const label = spanText(source, decl.name_span) orelse continue;
        try builder.add(.{ .label = label, .kind = .type_decl, .detail = "type" });
    }
    for (parsed.records.items) |decl| {
        const label = spanText(source, decl.name_span) orelse continue;
        try builder.add(.{ .label = label, .kind = .type_decl, .detail = "record" });
    }
    for (parsed.objects.items) |decl| {
        const label = spanText(source, decl.name_span) orelse continue;
        try builder.add(.{ .label = label, .kind = .class });
    }
}

fn spanText(source: []const u8, maybe_span: ?ast.Span) ?[]const u8 {
    const span = maybe_span orelse return null;
    if (span.start > span.end or span.end > source.len) return null;
    return source[span.start..span.end];
}

fn appendProperties(builder: *CandidateBuilder, snapshot: anytype, target: PropertyTarget) !void {
    switch (target) {
        .record => |record_name| {
            try appendRecordFields(builder, snapshot, record_name);
            return;
        },
        else => {},
    }

    var index = snapshot.fields.len;
    while (index > 0) {
        index -= 1;
        const field = snapshot.fields[index];
        if (!fieldAppliesToTarget(snapshot, field, target)) continue;
        try builder.add(.{ .label = field.name, .kind = .property, .detail = field.type_label });
    }
    try builder.add(.{ .label = "content", .kind = .property, .detail = "String" });
}

fn appendRecordFields(builder: *CandidateBuilder, snapshot: anytype, record_name: []const u8) !void {
    var index = snapshot.record_fields.len;
    while (index > 0) {
        index -= 1;
        const field = snapshot.record_fields[index];
        if (!std.mem.eql(u8, field.record_name, record_name)) continue;
        try builder.add(.{ .label = field.name, .kind = .property, .detail = field.type_label });
    }
}

fn appendEnumCases(builder: *CandidateBuilder, snapshot: anytype, enum_type: TypeDefinitionRef) !void {
    var index = snapshot.enum_cases.len;
    while (index > 0) {
        index -= 1;
        const case = snapshot.enum_cases[index];
        if (case.module_id != enum_type.module_id) continue;
        if (!std.mem.eql(u8, case.enum_name, enum_type.name)) continue;
        try builder.add(.{ .label = case.name, .kind = .enum_case, .detail = case.enum_name });
    }
}

const TypeDefinitionRef = struct {
    name: []const u8,
    module_id: core.SourceModuleId,
};

fn enumTypeForExpr(snapshot: anytype, req: types.SourceRequest, expr: ast.Expr) ?TypeDefinitionRef {
    const receiver = switch (expr) {
        .ident => |ident| ident.name,
        else => return null,
    };
    const type_name = resolve_query.typeNameReceiver(receiver) orelse return null;
    const module = snapshot.moduleForPath(req.path) orelse {
        if (type_name.qualifier != null) return null;
        return enumTypeByName(snapshot, type_name.name);
    };
    if (type_name.qualifier) |alias| {
        const module_id = resolve_query.aliasTarget(snapshot, module.id, alias) orelse return null;
        return enumTypeInModule(snapshot, module_id, type_name.name);
    }
    if (enumTypeInModule(snapshot, module.id, type_name.name)) |resolved| return resolved;
    return enumTypeByName(snapshot, type_name.name);
}

fn enumTypeByName(snapshot: anytype, name: []const u8) ?TypeDefinitionRef {
    var index = snapshot.enum_cases.len;
    while (index > 0) {
        index -= 1;
        const item = snapshot.enum_cases[index];
        if (std.mem.eql(u8, item.enum_name, name)) return .{ .name = item.enum_name, .module_id = item.module_id };
    }
    return null;
}

fn enumTypeInModule(snapshot: anytype, module_id: core.SourceModuleId, name: []const u8) ?TypeDefinitionRef {
    var index = snapshot.enum_cases.len;
    while (index > 0) {
        index -= 1;
        const item = snapshot.enum_cases[index];
        if (item.module_id != module_id) continue;
        if (std.mem.eql(u8, item.enum_name, name)) return .{ .name = item.enum_name, .module_id = item.module_id };
    }
    return null;
}

fn propertyTargetForExpr(snapshot: anytype, req: types.SourceRequest, program: *const ast.Program, expr: ast.Expr, depth: usize) ?PropertyTarget {
    const module = snapshot.moduleForPath(req.path) orelse return null;
    if (recordNameForCompletionExpr(snapshot, req, program, expr, depth)) |record_name| return .{ .record = record_name };
    if (depth > 16) return null;
    return switch (expr) {
        .ident => |ident| blk: {
            if (resolve_query.visibleVariableBinding(snapshot, module.id, req.offset, ident.name)) |variable| {
                if (propertyTargetForVariable(snapshot, variable)) |target| break :blk target;
            }
            if (cursor.visibleLetBindingAt(program, req.offset, ident.name)) |binding| {
                if (propertyTargetForExpr(snapshot, req, program, binding.expr, depth + 1)) |target| break :blk target;
            }
            if (resolve_query.valueBinding(snapshot, module.id, ident.name, null, .constant)) |constant| {
                if (propertyTargetForTypeLabel(snapshot, constant.type_label)) |target| break :blk target;
            }
            if (resolve_query.valueBinding(snapshot, module.id, ident.name, null, .function)) |function| {
                if (propertyTargetForTypeLabel(snapshot, function.type_label)) |target| break :blk target;
            }
            break :blk null;
        },
        .call => |call| blk: {
            const function = resolve_query.valueBinding(snapshot, module.id, call.callee.name, call.callee.qualifier, .function) orelse break :blk null;
            break :blk propertyTargetForTypeLabel(snapshot, function.type_label);
        },
        else => null,
    };
}

fn recordNameForCompletionExpr(snapshot: anytype, req: types.SourceRequest, program: *const ast.Program, expr: ast.Expr, depth: usize) ?[]const u8 {
    const module = snapshot.moduleForPath(req.path) orelse return null;
    if (resolve_query.recordNameForExpr(snapshot, module.id, req.offset, expr)) |record_name| return record_name;
    if (depth > 16) return null;
    return switch (expr) {
        .ident => |ident| blk: {
            const binding = cursor.visibleLetBindingAt(program, req.offset, ident.name) orelse break :blk null;
            break :blk recordNameForCompletionExpr(snapshot, req, program, binding.expr, depth + 1);
        },
        else => null,
    };
}

fn propertyTargetForVariable(snapshot: anytype, variable: anytype) ?PropertyTarget {
    if (variable.object_class) |class_name| if (class_name.len != 0) return .{ .class = class_name };
    return propertyTargetForTypeLabel(snapshot, variable.type_label);
}

fn propertyTargetForTypeLabel(snapshot: anytype, type_label: []const u8) ?PropertyTarget {
    if (std.mem.eql(u8, type_label, "Document")) return .{ .class = "Doc" };
    if (std.mem.eql(u8, type_label, "Page")) return .{ .class = "PageContext" };
    if (std.mem.startsWith(u8, type_label, "Object<") and std.mem.endsWith(u8, type_label, ">")) {
        return .{ .class = type_label["Object<".len .. type_label.len - 1] };
    }
    if (std.mem.eql(u8, type_label, "Object") or std.mem.startsWith(u8, type_label, "Selection<Object")) return .any_object;
    if (resolve_query.recordNameForTypeLabel(snapshot, type_label)) |record_name| return .{ .record = record_name };
    return null;
}

fn fieldAppliesToTarget(snapshot: anytype, field: anytype, target: PropertyTarget) bool {
    return switch (target) {
        .any_object => true,
        .class => |class_name| classContains(snapshot, class_name, field.class_name),
        .record => false,
    };
}

fn classContains(snapshot: anytype, class_name: []const u8, expected: []const u8) bool {
    var current: ?[]const u8 = class_name;
    while (current) |name| {
        if (std.mem.eql(u8, name, expected)) return true;
        current = classBase(snapshot, name);
    }
    return false;
}

fn classBase(snapshot: anytype, class_name: []const u8) ?[]const u8 {
    var index = snapshot.classes.len;
    while (index > 0) {
        index -= 1;
        const item = snapshot.classes[index];
        if (std.mem.eql(u8, item.name, class_name)) return item.base;
    }
    return null;
}

fn appendImportAsCompletions(builder: *CandidateBuilder, source: []const u8, offset: usize) !void {
    const spec = importAsSpecBeforeCursor(source, offset) orelse return;
    try builder.add(.{ .label = "*", .kind = .keyword, .detail = "bare names" });
    if (defaultAliasCandidate(spec)) |alias| {
        try builder.add(.{ .label = alias, .kind = .variable, .detail = "module alias" });
    }
}

fn importAsSpecBeforeCursor(source: []const u8, offset: usize) ?[]const u8 {
    const safe_offset = @min(offset, source.len);
    const line_start = utils.source.lineAt(source, safe_offset).span.start;
    const before = std.mem.trim(u8, source[line_start..safe_offset], " \t\r");
    if (!std.mem.startsWith(u8, before, "import ")) return null;
    const as_index = std.mem.lastIndexOf(u8, before, " as") orelse return null;
    const spec = std.mem.trim(u8, before["import ".len..as_index], " \t");
    if (spec.len == 0) return null;
    return unquoteImportSpec(spec);
}

fn unquoteImportSpec(spec: []const u8) []const u8 {
    if (spec.len >= 2 and spec[0] == '"' and spec[spec.len - 1] == '"') return spec[1 .. spec.len - 1];
    return spec;
}

fn defaultAliasCandidate(spec: []const u8) ?[]const u8 {
    if (language_names.importSpecHasFileExtension(spec)) return null;
    const base = language_names.defaultImportAlias(spec);
    if (!isValidAlias(base) or language_names.isKeyword(base)) return null;
    return base;
}

fn isValidAlias(alias: []const u8) bool {
    if (alias.len == 0 or !utils.source.isIdentifierStart(alias[0])) return false;
    for (alias[1..]) |byte| {
        if (!utils.source.isIdentifierContinue(byte)) return false;
    }
    return true;
}
