const std = @import("std");
const ast = @import("ast");
const core = @import("core");

const language_names = @import("../../language/names.zig");
const type_resolution = @import("../../language/type_resolution.zig");
const resolve_query = @import("resolve.zig");
const cursor = @import("cursor.zig");
const source_query = @import("source.zig");
const fallback = @import("fallback.zig");
const types = @import("types.zig");
const utils = @import("utils");
const QueryBudget = types.QueryBudget;

const Candidate = types.CompletionCandidate;
const Result = types.CompletionResult;

const PropertyTarget = union(enum) {
    record: ast.Type,
    placement: ast.Type,
    settings: ast.Type,
};

pub fn at(
    allocator: std.mem.Allocator,
    snapshot: anytype,
    req: types.SourceRequest,
    opts: types.QueryOptions,
) !Result {
    const budget = types.QueryBudget.start(opts);
    var builder = CandidateBuilder.init(allocator, budget);
    defer builder.deinit();
    if (budget.expired()) return fallback.complete(allocator, snapshot, req, opts);
    var parsed = try source_query.ParsedSource.init(allocator, snapshot, req, budget);
    defer parsed.deinit(allocator);
    if (budget.expired()) return fallback.complete(allocator, snapshot, req, opts);
    complete(&builder, snapshot, req, parsed.module()) catch |err| switch (err) {
        error.QueryExpired => return fallback.complete(allocator, snapshot, req, opts),
        else => return err,
    };
    if (budget.expired()) return fallback.complete(allocator, snapshot, req, opts);
    return builder.finish(false);
}

fn complete(builder: *CandidateBuilder, snapshot: anytype, req: types.SourceRequest, parsed_module: ?*const ast.Module) !void {
    if (try completeRecordUpdateAt(builder, snapshot, req, parsed_module)) return;
    if (try completeRecordConstructionAt(builder, snapshot, req, parsed_module)) return;
    try builder.checkBudget();
    if (try completeModuleAccessAt(builder, snapshot, req, parsed_module)) return;
    try builder.checkBudget();
    if (try completeMemberAccessAt(builder, snapshot, req, parsed_module)) return;
    try builder.checkBudget();
    try completeRegular(builder, snapshot, req, parsed_module);
}

fn emptyResult(allocator: std.mem.Allocator) !Result {
    return .{ .items = try allocator.alloc(Candidate, 0) };
}

fn completeRegular(builder: *CandidateBuilder, snapshot: anytype, req: types.SourceRequest, program: ?*const ast.Module) !void {
    for (language_names.keywordLabels()) |keyword| try builder.add(.{ .label = keyword, .kind = .keyword, .detail = "keyword" });
    try appendImportAsCompletions(builder, req.source, req.offset);
    if (snapshot.moduleForPath(req.path)) |module| {
        try appendVisibleVariables(builder, snapshot, module.id, req.offset);
    }
    try appendVisibleDeclarations(builder, snapshot, req.path, .value);
    try appendTypeNameCompletions(builder, snapshot, program, req);
}

const CandidateBuilder = struct {
    allocator: std.mem.Allocator,
    budget: QueryBudget,
    items: std.ArrayList(Candidate),
    seen: std.StringHashMap(void),
    scratch: std.heap.ArenaAllocator,
    owned_details: std.ArrayList([]const u8) = .empty,

    fn init(allocator: std.mem.Allocator, budget: QueryBudget) CandidateBuilder {
        return .{
            .allocator = allocator,
            .budget = budget,
            .items = .empty,
            .seen = std.StringHashMap(void).init(allocator),
            .scratch = .init(allocator),
        };
    }

    fn deinit(self: *CandidateBuilder) void {
        self.items.deinit(self.allocator);
        self.seen.deinit();
        self.scratch.deinit();
        for (self.owned_details.items) |detail| self.allocator.free(detail);
        self.owned_details.deinit(self.allocator);
    }

    fn checkBudget(self: *const CandidateBuilder) !void {
        if (self.budget.expired()) return error.QueryExpired;
    }

    fn add(self: *CandidateBuilder, candidate: Candidate) !void {
        try self.checkBudget();
        if (candidate.label.len == 0 or self.seen.contains(candidate.label)) return;
        try self.seen.put(candidate.label, {});
        try self.items.append(self.allocator, candidate);
    }

    fn retainDetail(self: *CandidateBuilder, detail: []const u8) ![]const u8 {
        const owned = try self.allocator.dupe(u8, detail);
        errdefer self.allocator.free(owned);
        try self.owned_details.append(self.allocator, owned);
        return owned;
    }

    fn finish(self: *CandidateBuilder, is_incomplete: bool) !Result {
        if (self.budget.canceled()) return emptyResult(self.allocator);
        const items = try self.items.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(items);
        return .{
            .items = items,
            .owned_details = try self.owned_details.toOwnedSlice(self.allocator),
            .is_incomplete = is_incomplete,
        };
    }
};

fn completeModuleAccessAt(builder: *CandidateBuilder, snapshot: anytype, req: types.SourceRequest, program: ?*const ast.Module) !bool {
    const budget = builder.budget;
    const parsed = program orelse return false;
    const callable = cursor.callableAt(budget, parsed, req.offset) orelse return false;
    if (callable.role != .name) return false;
    const alias = callable.callee.qualifier orelse return false;

    const module = snapshot.moduleForPath(req.path) orelse return true;
    const module_id = resolve_query.aliasTarget(budget, snapshot, module.id, alias) orelse return true;
    try appendModuleDeclarations(builder, snapshot, module_id, .value);
    try appendModuleDeclarations(builder, snapshot, module_id, .type);
    return true;
}

fn completeMemberAccessAt(builder: *CandidateBuilder, snapshot: anytype, req: types.SourceRequest, program: ?*const ast.Module) !bool {
    const budget = builder.budget;
    const parsed = program orelse return false;
    const member = cursor.memberAt(budget, parsed, req.offset) orelse return false;
    if (enumTypeForExpr(budget, snapshot, req, member.target)) |enum_type| {
        try appendEnumCases(builder, snapshot, enum_type);
    } else if (try propertyTargetForExpr(builder.scratch.allocator(), budget, snapshot, req, parsed, member.target, 0)) |target| {
        try appendProperties(builder, snapshot, target);
    }
    return true;
}

fn completeRecordUpdateAt(builder: *CandidateBuilder, snapshot: anytype, req: types.SourceRequest, program: ?*const ast.Module) !bool {
    const budget = builder.budget;
    const parsed = program orelse return false;
    const target = cursor.recordUpdateCompletionAt(budget, parsed, req.offset) orelse return false;
    const scratch = builder.scratch.allocator();
    const base = (try recordTypeForCompletionExpr(scratch, budget, snapshot, req, parsed, target.target, 0)) orelse return false;
    const ty = (try resolve_query.typeAfterPath(scratch, budget, snapshot, base, target.path_prefix)) orelse return false;
    if (ty.kind != .group and resolve_query.recordIdForType(ty) == null) return false;
    try appendProperties(builder, snapshot, .{ .record = ty });
    return true;
}

fn completeRecordConstructionAt(builder: *CandidateBuilder, snapshot: anytype, req: types.SourceRequest, program: ?*const ast.Module) !bool {
    const parsed = program orelse return false;
    const target = cursor.sourceNameAt(builder.budget, parsed, req.offset) orelse return false;
    const record = target.construction orelse return false;
    const module = snapshot.moduleForPath(req.path) orelse return false;
    const ty = (try resolve_query.typeForConstruction(builder.scratch.allocator(), builder.budget, snapshot, module.id, req.offset, record)) orelse return false;
    try appendProperties(builder, snapshot, .{ .record = ty });
    return true;
}

const DeclarationNamespace = enum { value, type };

fn appendVisibleDeclarations(builder: *CandidateBuilder, snapshot: anytype, path: []const u8, namespace: DeclarationNamespace) !void {
    try builder.checkBudget();
    if (snapshot.moduleForPath(path)) |module| {
        var visiting = std.AutoHashMap(core.SourceModuleId, void).init(builder.allocator);
        defer visiting.deinit();
        try appendOpenDeclarations(builder, snapshot, module.id, &visiting, namespace);
        var implicit_index = module.implicit_import_ids.len;
        while (implicit_index > 0) {
            try builder.checkBudget();
            implicit_index -= 1;
            try appendOpenDeclarations(builder, snapshot, module.implicit_import_ids[implicit_index], &visiting, namespace);
        }
    }
    if (namespace == .value) {
        for (snapshot.value_bindings) |binding| {
            try builder.checkBudget();
            if (!binding.primitive) continue;
            try appendValueBinding(builder, binding);
        }
    }
}

fn appendOpenDeclarations(
    builder: *CandidateBuilder,
    snapshot: anytype,
    module_id: core.SourceModuleId,
    visiting: *std.AutoHashMap(core.SourceModuleId, void),
    namespace: DeclarationNamespace,
) !void {
    try builder.checkBudget();
    if (visiting.contains(module_id)) return;
    try visiting.put(module_id, {});
    try appendModuleDeclarations(builder, snapshot, module_id, namespace);
    const module = snapshot.moduleById(module_id) orelse return;
    var index = module.imports.len;
    while (index > 0) {
        try builder.checkBudget();
        index -= 1;
        const import_info = module.imports[index];
        if (!import_info.unqualified) continue;
        const imported_id = import_info.module_id orelse continue;
        try appendOpenDeclarations(builder, snapshot, imported_id, visiting, namespace);
    }
}

fn appendModuleDeclarations(builder: *CandidateBuilder, snapshot: anytype, module_id: core.SourceModuleId, namespace: DeclarationNamespace) !void {
    try builder.checkBudget();
    switch (namespace) {
        .value => for (snapshot.value_bindings) |binding| {
            try builder.checkBudget();
            if ((binding.module_id orelse continue) != module_id) continue;
            try appendValueBinding(builder, binding);
        },
        .type => for (snapshot.type_definitions) |definition| {
            try builder.checkBudget();
            if (definition.module_id != module_id) continue;
            try appendTypeDefinition(builder, definition);
        },
    }
    const module = snapshot.moduleById(module_id) orelse return;
    var index = module.imports.len;
    while (index > 0) {
        try builder.checkBudget();
        index -= 1;
        const import_info = module.imports[index];
        const imported_id = import_info.module_id orelse continue;
        for (import_info.selected) |item| {
            try builder.checkBudget();
            switch (namespace) {
                .value => inline for (.{ core.DefinitionKind.function, core.DefinitionKind.constant }) |kind| {
                    if (resolve_query.exportedValueBinding(builder.budget, snapshot, imported_id, item.name, kind)) |binding| try appendValueBinding(builder, binding);
                },
                .type => if (resolve_query.exportedTypeDefinition(builder.budget, snapshot, imported_id, item.name)) |definition| {
                    try appendTypeDefinition(builder, definition);
                },
            }
        }
    }
}

fn appendTypeDefinition(builder: *CandidateBuilder, definition: anytype) !void {
    try builder.add(.{
        .label = definition.name,
        .kind = .type_decl,
        .detail = if (definition.kind == .record) "type" else "enum",
    });
}

fn appendValueBinding(builder: *CandidateBuilder, binding: anytype) !void {
    try builder.checkBudget();
    try builder.add(.{
        .label = binding.name,
        .kind = if (binding.kind == .function) .function else .variable,
        .detail = binding.signature,
        .documentation = binding.documentation,
    });
}

fn appendVisibleVariables(builder: *CandidateBuilder, snapshot: anytype, module_id: core.SourceModuleId, offset: usize) !void {
    try builder.checkBudget();
    for (snapshot.variable_bindings) |binding| {
        try builder.checkBudget();
        if (!resolve_query.variableBindingVisibleAt(builder.budget, snapshot, module_id, offset, binding)) continue;
        const visible = resolve_query.visibleVariableBinding(builder.budget, snapshot, module_id, offset, binding.name) orelse continue;
        try builder.add(.{
            .label = visible.name,
            .kind = .variable,
            .detail = visible.type_label,
        });
    }
}

fn appendTypeNameCompletions(builder: *CandidateBuilder, snapshot: anytype, program: ?*const ast.Module, req: types.SourceRequest) !void {
    try builder.checkBudget();
    for (type_resolution.builtinTypes()) |builtin| {
        try builder.checkBudget();
        try builder.add(.{ .label = builtin.name, .kind = .type_decl, .detail = "builtin type" });
    }
    if (program) |parsed| {
        inline for (.{ parsed.records.items, parsed.functions.items }) |declarations| {
            for (declarations) |declaration| {
                try builder.checkBudget();
                if (req.offset < declaration.span.start or req.offset > declaration.span.end) continue;
                for (declaration.type_params.items) |parameter| {
                    const label = spanText(req.source, parameter.span) orelse continue;
                    try builder.add(.{ .label = label, .kind = .type_decl, .detail = "type parameter" });
                }
            }
        }
    }
    try appendParsedTypeNameCompletions(builder, program, req.source);
    try appendVisibleDeclarations(builder, snapshot, req.path, .type);
}

fn appendParsedTypeNameCompletions(builder: *CandidateBuilder, program: ?*const ast.Module, source: []const u8) !void {
    try builder.checkBudget();
    const parsed = program orelse return;
    for (parsed.types.items) |decl| {
        try builder.checkBudget();
        const label = spanText(source, decl.name_span) orelse continue;
        try builder.add(.{ .label = label, .kind = .type_decl, .detail = "enum" });
    }
    for (parsed.records.items) |decl| {
        try builder.checkBudget();
        const label = spanText(source, decl.name_span) orelse continue;
        try builder.add(.{ .label = label, .kind = .type_decl, .detail = "type" });
    }
}

fn spanText(source: []const u8, maybe_span: ?ast.Span) ?[]const u8 {
    const span = maybe_span orelse return null;
    if (span.start > span.end or span.end > source.len) return null;
    return source[span.start..span.end];
}

fn appendProperties(builder: *CandidateBuilder, snapshot: anytype, target: PropertyTarget) !void {
    try builder.checkBudget();
    switch (target) {
        .settings => |ty| {
            if (resolve_query.settingsId(snapshot)) |id| try appendRecordFields(builder, snapshot, ast.Type.recordType(id.name).inModule(id.module_id));
            if (ty.kind == .page) {
                for (comptime std.meta.fieldNames(core.Anchor)) |name| try builder.add(.{ .label = name, .kind = .property, .detail = "Anchor" });
            }
            return;
        },
        .record => |record_name| {
            try appendRecordFields(builder, snapshot, record_name);
            return;
        },
        .placement => |ty| {
            const placement = @import("../../language/placement.zig");
            if (resolve_query.groupLayoutType(builder.budget, snapshot, ty)) |layout_type| {
                const detail = try layout_type.formatAlloc(builder.scratch.allocator());
                try builder.add(.{ .label = "layout", .kind = .property, .detail = try builder.retainDetail(detail) });
            }
            for (placement.input_members) |name| {
                const field_type = placement.memberType(ty, name) orelse continue;
                const detail = try field_type.formatAlloc(builder.scratch.allocator());
                try builder.add(.{ .label = name, .kind = .property, .detail = try builder.retainDetail(detail) });
            }
            for (comptime std.meta.fieldNames(core.Anchor)) |name| {
                try builder.add(.{ .label = name, .kind = .property, .detail = "Anchor" });
            }
            return;
        },
    }
}

fn appendRecordFields(builder: *CandidateBuilder, snapshot: anytype, ty: ast.Type) !void {
    try builder.checkBudget();
    if (ty.kind == .group) {
        try builder.add(.{ .label = "gap", .kind = .property, .detail = "Number" });
        return;
    }
    const record_id = resolve_query.recordIdForType(ty) orelse return;
    var index = snapshot.record_fields.len;
    while (index > 0) {
        try builder.checkBudget();
        index -= 1;
        const field = snapshot.record_fields[index];
        if (field.module_id != record_id.module_id or !std.mem.eql(u8, field.record_name, record_id.name)) continue;
        const applied = (try resolve_query.fieldForType(builder.scratch.allocator(), builder.budget, snapshot, ty, field.name)) orelse continue;
        const detail = try builder.retainDetail(applied.type_label);
        try builder.add(.{ .label = field.name, .kind = .property, .detail = detail });
    }
}

fn appendEnumCases(builder: *CandidateBuilder, snapshot: anytype, enum_type: TypeDefinitionRef) !void {
    try builder.checkBudget();
    var index = snapshot.enum_cases.len;
    while (index > 0) {
        try builder.checkBudget();
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

fn enumTypeForExpr(budget: QueryBudget, snapshot: anytype, req: types.SourceRequest, expr: ast.Expr) ?TypeDefinitionRef {
    if (budget.expired()) return null;
    const receiver = switch (expr) {
        .ident => |ident| ident.name,
        else => return null,
    };
    const module = snapshot.moduleForPath(req.path) orelse return null;
    const ty = resolve_query.resolvedTypeName(budget, snapshot, module.id, receiver) orelse return null;
    if (ty.kind != .enum_type) return null;
    const id = ty.nominalId() orelse return null;
    return .{ .name = id.name, .module_id = id.module_id };
}

fn propertyTargetForExpr(allocator: std.mem.Allocator, budget: QueryBudget, snapshot: anytype, req: types.SourceRequest, program: *const ast.Module, expr: ast.Expr, depth: usize) anyerror!?PropertyTarget {
    if (budget.expired()) return null;
    const module = snapshot.moduleForPath(req.path) orelse return null;
    if (try resolve_query.typeForExpr(allocator, budget, snapshot, module.id, req.offset, expr)) |ty| {
        if (propertyTargetForType(snapshot, ty)) |target| return target;
    }
    if (depth > 16) return null;
    return switch (expr) {
        .ident => |ident| blk: {
            if (resolve_query.visibleVariableBinding(budget, snapshot, module.id, req.offset, ident.name)) |variable| {
                if (propertyTargetForVariable(snapshot, variable)) |target| break :blk target;
            }
            if (cursor.visibleLetBindingAt(budget, program, req.offset, ident.name)) |binding| {
                if (try propertyTargetForExpr(allocator, budget, snapshot, req, program, binding.expr, depth + 1)) |target| break :blk target;
            }
            if (resolve_query.valueBinding(budget, snapshot, module.id, ident.name, null, .constant)) |constant| {
                if (propertyTargetForType(snapshot, constant.value_type)) |target| break :blk target;
            }
            if (resolve_query.valueBinding(budget, snapshot, module.id, ident.name, null, .function)) |function| {
                if (propertyTargetForType(snapshot, function.value_type)) |target| break :blk target;
            }
            break :blk null;
        },
        .call => |call| blk: {
            const function = resolve_query.valueBinding(budget, snapshot, module.id, call.callee.name, call.callee.qualifier, .function) orelse break :blk null;
            break :blk propertyTargetForType(snapshot, function.value_type);
        },
        else => null,
    };
}

fn recordTypeForCompletionExpr(allocator: std.mem.Allocator, budget: QueryBudget, snapshot: anytype, req: types.SourceRequest, program: *const ast.Module, expr: ast.Expr, depth: usize) anyerror!?ast.Type {
    if (budget.expired()) return null;
    const module = snapshot.moduleForPath(req.path) orelse return null;
    if (try resolve_query.typeForExpr(allocator, budget, snapshot, module.id, req.offset, expr)) |ty| {
        if (ty.kind == .group or resolve_query.recordIdForType(ty) != null) return ty;
    }
    if (depth > 16) return null;
    return switch (expr) {
        .ident => |ident| blk: {
            const binding = cursor.visibleLetBindingAt(budget, program, req.offset, ident.name) orelse break :blk null;
            break :blk try recordTypeForCompletionExpr(allocator, budget, snapshot, req, program, binding.expr, depth + 1);
        },
        else => null,
    };
}

fn propertyTargetForVariable(snapshot: anytype, variable: anytype) ?PropertyTarget {
    return propertyTargetForType(snapshot, variable.value_type);
}

fn propertyTargetForType(snapshot: anytype, ty: ast.Type) ?PropertyTarget {
    if (ty.kind == .optional) return if (ty.optional_child) |child| propertyTargetForType(snapshot, child.*) else null;
    return switch (ty.kind) {
        .document, .page => .{ .settings = ty },
        .record => if (ty.nominalId() != null) .{ .record = ty } else null,
        .group => .{ .record = ty },
        .placed, .placement => .{ .placement = ty },
        else => null,
    };
}

fn appendImportAsCompletions(builder: *CandidateBuilder, source: []const u8, offset: usize) !void {
    try builder.checkBudget();
    const spec = importAsSpecBeforeCursor(source, offset) orelse return;
    try builder.add(.{ .label = "*", .kind = .keyword, .detail = "bare names" });
    if (defaultAliasCandidate(spec)) |alias| {
        try builder.add(.{ .label = alias, .kind = .variable, .detail = "module alias" });
    }
}

fn importAsSpecBeforeCursor(source: []const u8, offset: usize) ?[]const u8 {
    const safe_offset = @min(offset, source.len);
    const line_start = utils.source.lineSpanAt(source, safe_offset).start;
    const before = std.mem.trim(u8, source[line_start..safe_offset], " \t\r");
    if (!std.mem.startsWith(u8, before, "import")) return null;
    var pos: usize = "import".len;
    if (pos == before.len or !utils.source.isInlineSpace(before[pos])) return null;
    pos = utils.source.skipInlineSpacesUntil(before, pos, before.len);
    const spec_start = pos;
    if (pos == before.len) return null;
    if (before[pos] == '"') {
        pos = utils.source.skipDoubleQuotedString(before, pos, before.len);
    } else {
        while (pos < before.len and !utils.source.isInlineSpace(before[pos])) : (pos += 1) {
            if (utils.source.lineCommentMarkerLength(before, pos) != null) return null;
        }
    }
    const spec_end = pos;
    if (spec_start == spec_end or pos == before.len or !utils.source.isInlineSpace(before[pos])) return null;
    pos = utils.source.skipInlineSpacesUntil(before, pos, before.len);
    if (!std.mem.startsWith(u8, before[pos..], "as")) return null;
    pos += "as".len;
    if (pos < before.len and !utils.source.isInlineSpace(before[pos])) return null;
    pos = utils.source.skipInlineSpacesUntil(before, pos, before.len);
    // Only a partial alias may follow the keyword, never another import mode
    // or a comment. Quoted paths and path components are not keyword tokens.
    for (before[pos..], 0..) |ch, i| {
        if (i == 0 and !utils.source.isIdentifierStart(ch)) return null;
        if (!utils.source.isIdentifierContinue(ch)) return null;
    }
    const spec = before[spec_start..spec_end];
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
