const std = @import("std");
const ast = @import("ast");
const core = @import("core");

const declarations = @import("../language/declarations.zig");
const editor = @import("editor.zig");
const language_names = @import("../language/names.zig");
const registry = @import("../language/registry.zig");
const typecheck = @import("typecheck.zig");

const JsonObject = std.json.ObjectMap;

pub const CompletionKind = enum {
    keyword,
    function,
    variable,
    property,
    type_decl,
    class,
    role,
};

pub const Candidate = struct {
    label: []const u8,
    kind: CompletionKind,
    detail: ?[]const u8 = null,
    documentation: ?[]const u8 = null,
};

pub const Result = struct {
    items: []Candidate,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        allocator.free(self.items);
    }
};

pub const Request = struct {
    doc_path: []const u8,
    source: []const u8,
    offset: usize,
};

const builtin_type_names = [_][]const u8{
    "Document",
    "Page",
    "Object",
    "Metadata",
    "Anchor",
    "String",
    "Color",
    "Number",
    "Bool",
    "Constraints",
    "Void",
    "None",
    "Selection",
};

const ImportInfo = struct {
    alias: ?[]u8 = null,
    unqualified: bool = false,
    module_id: ?core.SourceModuleId = null,
};

const ScopeInfo = struct {
    name: []u8,
    start: usize,
    end: usize,
};

const ModuleInfo = struct {
    id: core.SourceModuleId,
    spec: []u8,
    path: ?[]u8,
    imports: []ImportInfo,
    implicit_import_ids: []core.SourceModuleId,
    functions: []ScopeInfo,
    pages: []ScopeInfo,
};

const FunctionInfo = struct {
    name: []u8,
    signature: []u8,
    result_type: []u8,
    documentation: []u8,
    module_id: ?core.SourceModuleId,
    primitive: bool = false,
};

const VariableInfo = struct {
    name: []u8,
    type_label: []u8,
    object_class: ?[]u8,
    module_id: core.SourceModuleId,
    scope_kind: core.DefinitionScopeKind,
    scope_name: ?[]u8,
    span_start: usize,
    span_end: usize,
    visible_start: usize,
    visible_end: usize,
};

const FieldInfo = struct {
    name: []u8,
    class_name: []u8,
    type_label: []u8,
};

const ClassInfo = struct {
    name: []u8,
    base: ?[]u8,
};

const DeclInfo = struct {
    name: []u8,
    type_label: []u8 = "",
};

pub const Index = struct {
    allocator: std.mem.Allocator,
    modules: []ModuleInfo = &.{},
    functions: []FunctionInfo = &.{},
    variables: []VariableInfo = &.{},
    fields: []FieldInfo = &.{},
    classes: []ClassInfo = &.{},
    types: []DeclInfo = &.{},
    roles: []DeclInfo = &.{},

    pub fn fromIr(allocator: std.mem.Allocator, ir: *core.Ir) !Index {
        var out = Index{ .allocator = allocator };
        errdefer out.deinit();

        out.modules = try buildModules(allocator, ir);
        out.functions = try buildFunctions(allocator, ir);
        out.variables = try buildVariables(allocator, ir);

        var decls = try declarations.build(allocator, ir);
        defer decls.deinit();
        out.fields = try buildFields(allocator, decls.fields.items);
        out.classes = try buildClasses(allocator, decls.classes.items);
        out.types = try buildTypes(allocator, decls.types.items);
        out.roles = try buildRoles(allocator, decls.roles.items);

        return out;
    }

    pub fn clone(self: *const Index, allocator: std.mem.Allocator) !Index {
        var out = Index{ .allocator = allocator };
        errdefer out.deinit();
        out.modules = try cloneModules(allocator, self.modules);
        out.functions = try cloneFunctions(allocator, self.functions);
        out.variables = try cloneVariables(allocator, self.variables);
        out.fields = try cloneFields(allocator, self.fields);
        out.classes = try cloneClasses(allocator, self.classes);
        out.types = try cloneDecls(allocator, self.types);
        out.roles = try cloneDecls(allocator, self.roles);
        return out;
    }

    pub fn deinit(self: *Index) void {
        for (self.modules) |*module| {
            self.allocator.free(module.spec);
            if (module.path) |path| self.allocator.free(path);
            for (module.imports) |*import_info| if (import_info.alias) |alias| self.allocator.free(alias);
            self.allocator.free(module.imports);
            self.allocator.free(module.implicit_import_ids);
            for (module.functions) |scope| self.allocator.free(scope.name);
            self.allocator.free(module.functions);
            for (module.pages) |scope| self.allocator.free(scope.name);
            self.allocator.free(module.pages);
        }
        self.allocator.free(self.modules);
        for (self.functions) |item| {
            self.allocator.free(item.name);
            self.allocator.free(item.signature);
            self.allocator.free(item.result_type);
            self.allocator.free(item.documentation);
        }
        self.allocator.free(self.functions);
        for (self.variables) |item| {
            self.allocator.free(item.name);
            self.allocator.free(item.type_label);
            if (item.object_class) |class_name| self.allocator.free(class_name);
            if (item.scope_name) |scope_name| self.allocator.free(scope_name);
        }
        self.allocator.free(self.variables);
        for (self.fields) |item| {
            self.allocator.free(item.name);
            self.allocator.free(item.class_name);
            self.allocator.free(item.type_label);
        }
        self.allocator.free(self.fields);
        for (self.classes) |item| {
            self.allocator.free(item.name);
            if (item.base) |base| self.allocator.free(base);
        }
        self.allocator.free(self.classes);
        deinitDecls(self.allocator, self.types);
        deinitDecls(self.allocator, self.roles);
        self.* = .{ .allocator = self.allocator };
    }

    pub fn containsDocument(self: *const Index, allocator: std.mem.Allocator, doc_path: []const u8) bool {
        return moduleForPath(self, allocator, doc_path) != null;
    }
};

pub const AccessSeparator = enum {
    dot,
    double_colon,
};

pub const AccessContext = struct {
    receiver: []const u8,
    separator: AccessSeparator,
    separator_offset: usize,
};

const PropertyTarget = union(enum) {
    class: []const u8,
    any_object,
};

pub fn complete(allocator: std.mem.Allocator, index: *const Index, request: Request) !Result {
    var builder = CandidateBuilder.init(allocator);
    defer builder.deinit();

    if (accessBeforeOffset(request.source, request.offset)) |access| {
        switch (access.separator) {
            .double_colon => {
                if (resolveAliasModuleId(index, allocator, request.doc_path, access.receiver)) |module_id| {
                    try appendModuleFunctions(&builder, index, module_id);
                }
                return try builder.finish();
            },
            .dot => {
                if (propertyTargetForReceiver(allocator, index, request, access.receiver)) |target| {
                    try appendProperties(&builder, index, target);
                }
                return try builder.finish();
            },
        }
    }

    const keywords = [_][]const u8{ "import", "as", "const", "document", "page", "fn", "let", "return", "end", "type", "extend", "if", "then", "else" };
    for (keywords) |keyword| try builder.add(.{ .label = keyword, .kind = .keyword, .detail = "keyword" });
    try appendImportAsCompletions(&builder, request.source, request.offset);
    try appendVisibleFunctions(&builder, index, allocator, request.doc_path);
    for (index.variables) |variable| {
        if (!variableVisibleAt(index, allocator, variable, request)) continue;
        if (!isBestVisibleVariable(index, allocator, variable, request)) continue;
        try builder.add(.{ .label = variable.name, .kind = .variable, .detail = variable.type_label });
    }
    try appendTypeNameCompletions(&builder, index, request.source);
    for (index.roles) |item| try builder.add(.{ .label = item.name, .kind = .role, .detail = item.type_label });
    return try builder.finish();
}

pub fn accessBeforeOffset(source: []const u8, offset: usize) ?AccessContext {
    var cursor = @min(offset, source.len);
    const original_cursor = cursor;
    while (cursor > 0 and isAccessTrivia(source[cursor - 1])) cursor -= 1;
    if (cursor != original_cursor and !endsWithSeparator(source, cursor)) return null;
    while (cursor > 0 and isIdentChar(source[cursor - 1])) cursor -= 1;
    while (cursor > 0 and isAccessTrivia(source[cursor - 1])) cursor -= 1;

    const separator: AccessSeparator, const separator_offset: usize = if (cursor >= 2 and std.mem.eql(u8, source[cursor - 2 .. cursor], "::"))
        .{ .double_colon, cursor - 2 }
    else if (cursor >= 1 and source[cursor - 1] == '.')
        .{ .dot, cursor - 1 }
    else
        return null;

    var receiver_start = separator_offset;
    while (receiver_start > 0 and isReceiverChar(source[receiver_start - 1])) receiver_start -= 1;
    if (receiver_start == separator_offset) return null;

    return .{
        .receiver = source[receiver_start..separator_offset],
        .separator = separator,
        .separator_offset = separator_offset,
    };
}

fn buildModules(allocator: std.mem.Allocator, ir: *core.Ir) ![]ModuleInfo {
    var out = std.ArrayList(ModuleInfo).empty;
    errdefer {
        for (out.items) |*module| {
            allocator.free(module.spec);
            if (module.path) |path| allocator.free(path);
            for (module.imports) |*import_info| if (import_info.alias) |alias| allocator.free(alias);
            allocator.free(module.imports);
            allocator.free(module.implicit_import_ids);
            for (module.functions) |scope| allocator.free(scope.name);
            allocator.free(module.functions);
            for (module.pages) |scope| allocator.free(scope.name);
            allocator.free(module.pages);
        }
        out.deinit(allocator);
    }
    for (ir.modules.items) |module| {
        var imports = std.ArrayList(ImportInfo).empty;
        errdefer {
            for (imports.items) |*item| if (item.alias) |alias| allocator.free(alias);
            imports.deinit(allocator);
        }
        for (module.program.imports.items, 0..) |import_decl, import_index| {
            try imports.append(allocator, .{
                .alias = if (import_decl.mode.alias) |alias| try allocator.dupe(u8, alias) else null,
                .unqualified = import_decl.mode.unqualified,
                .module_id = if (import_index < module.resolved_import_ids.items.len) module.resolved_import_ids.items[import_index] else null,
            });
        }
        const implicit = try allocator.dupe(core.SourceModuleId, module.implicit_import_ids.items);
        errdefer allocator.free(implicit);
        var functions = std.ArrayList(ScopeInfo).empty;
        errdefer {
            for (functions.items) |scope| allocator.free(scope.name);
            functions.deinit(allocator);
        }
        for (module.program.functions.items) |func| {
            try functions.append(allocator, .{
                .name = try allocator.dupe(u8, func.name),
                .start = func.span.start,
                .end = func.span.end,
            });
        }
        var pages = std.ArrayList(ScopeInfo).empty;
        errdefer {
            for (pages.items) |scope| allocator.free(scope.name);
            pages.deinit(allocator);
        }
        for (module.program.pages.items) |page| {
            try pages.append(allocator, .{
                .name = try allocator.dupe(u8, page.name),
                .start = page.span.start,
                .end = page.span.end,
            });
        }
        try out.append(allocator, .{
            .id = module.id,
            .spec = try allocator.dupe(u8, module.spec),
            .path = if (module.path) |path| try allocator.dupe(u8, path) else null,
            .imports = try imports.toOwnedSlice(allocator),
            .implicit_import_ids = implicit,
            .functions = try functions.toOwnedSlice(allocator),
            .pages = try pages.toOwnedSlice(allocator),
        });
    }
    return out.toOwnedSlice(allocator);
}

fn buildFunctions(allocator: std.mem.Allocator, ir: *core.Ir) ![]FunctionInfo {
    var out = std.ArrayList(FunctionInfo).empty;
    errdefer {
        for (out.items) |item| {
            allocator.free(item.name);
            allocator.free(item.signature);
            allocator.free(item.result_type);
            allocator.free(item.documentation);
        }
        out.deinit(allocator);
    }
    for (registry.primitiveDescriptors()) |descriptor| {
        if (userFunctionNameExists(ir, descriptor.name)) continue;
        const signature: []u8 = @constCast(try editor.formatPrimitiveSignature(allocator, descriptor));
        errdefer allocator.free(signature);
        const result_type: []u8 = @constCast(if (registry.primitiveResultType(descriptor)) |ty|
            try ty.formatAlloc(allocator)
        else
            try allocator.dupe(u8, "dependent"));
        errdefer allocator.free(result_type);
        try out.append(allocator, .{
            .name = try allocator.dupe(u8, descriptor.name),
            .signature = signature,
            .result_type = result_type,
            .documentation = try allocator.dupe(u8, descriptor.summary),
            .module_id = null,
            .primitive = true,
        });
    }
    var iterator = ir.functions.iterator();
    while (iterator.next()) |entry| {
        const func = entry.value_ptr.*;
        const signature: []u8 = @constCast(try editor.formatUserSignature(allocator, func.name, func));
        errdefer allocator.free(signature);
        const result_type: []u8 = @constCast(try func.result_type.formatAlloc(allocator));
        errdefer allocator.free(result_type);
        try out.append(allocator, .{
            .name = try allocator.dupe(u8, func.name),
            .signature = signature,
            .result_type = result_type,
            .documentation = try allocator.dupe(u8, ""),
            .module_id = entry.key_ptr.module_id,
        });
    }
    return out.toOwnedSlice(allocator);
}

fn userFunctionNameExists(ir: *const core.Ir, name: []const u8) bool {
    var iterator = ir.functions.iterator();
    while (iterator.next()) |entry| {
        if (std.mem.eql(u8, entry.value_ptr.name, name)) return true;
    }
    return false;
}

fn buildVariables(allocator: std.mem.Allocator, ir: *core.Ir) ![]VariableInfo {
    var out = std.ArrayList(VariableInfo).empty;
    errdefer {
        for (out.items) |item| {
            allocator.free(item.name);
            allocator.free(item.type_label);
            if (item.object_class) |class_name| allocator.free(class_name);
            if (item.scope_name) |scope_name| allocator.free(scope_name);
        }
        out.deinit(allocator);
    }
    for (ir.modules.items) |module| {
        if (module.path == null) continue;
        var infos = try typecheck.collectScopedVariableInfoFromProgram(allocator, &ir.functions, module.program, module.id, module.source.len, ir);
        defer infos.deinit(allocator);
        for (infos.items) |entry| {
            const type_label: []u8 = @constCast(try entry.info.ty.formatAlloc(allocator));
            errdefer allocator.free(type_label);
            try out.append(allocator, .{
                .name = try allocator.dupe(u8, entry.name),
                .type_label = type_label,
                .object_class = if (entry.info.object_class) |class_name| try allocator.dupe(u8, class_name) else null,
                .module_id = entry.module_id,
                .scope_kind = entry.scope_kind,
                .scope_name = if (entry.scope_name) |scope_name| try allocator.dupe(u8, scope_name) else null,
                .span_start = entry.span_start,
                .span_end = entry.span_end,
                .visible_start = entry.visible_start,
                .visible_end = entry.visible_end,
            });
        }
    }
    return out.toOwnedSlice(allocator);
}

fn buildFields(allocator: std.mem.Allocator, fields: []const declarations.FieldDescriptor) ![]FieldInfo {
    var out = std.ArrayList(FieldInfo).empty;
    errdefer {
        for (out.items) |item| {
            allocator.free(item.name);
            allocator.free(item.class_name);
            allocator.free(item.type_label);
        }
        out.deinit(allocator);
    }
    for (fields) |field| {
        try out.append(allocator, .{
            .name = try allocator.dupe(u8, field.name),
            .class_name = try allocator.dupe(u8, field.class_name),
            .type_label = try allocator.dupe(u8, field.value_type),
        });
    }
    return out.toOwnedSlice(allocator);
}

fn buildClasses(allocator: std.mem.Allocator, classes: []const declarations.ClassDescriptor) ![]ClassInfo {
    var out = std.ArrayList(ClassInfo).empty;
    errdefer {
        for (out.items) |item| {
            allocator.free(item.name);
            if (item.base) |base| allocator.free(base);
        }
        out.deinit(allocator);
    }
    for (classes) |class| {
        try out.append(allocator, .{
            .name = try allocator.dupe(u8, class.name),
            .base = if (class.base) |base| try allocator.dupe(u8, base) else null,
        });
    }
    return out.toOwnedSlice(allocator);
}

fn buildTypes(allocator: std.mem.Allocator, types: []const declarations.TypeDescriptor) ![]DeclInfo {
    var out = std.ArrayList(DeclInfo).empty;
    errdefer deinitDecls(allocator, out.items);
    for (types) |item| {
        try out.append(allocator, .{
            .name = try allocator.dupe(u8, item.name),
            .type_label = try allocator.dupe(u8, "type"),
        });
    }
    return out.toOwnedSlice(allocator);
}

fn buildRoles(allocator: std.mem.Allocator, roles: []const declarations.RoleDescriptor) ![]DeclInfo {
    var out = std.ArrayList(DeclInfo).empty;
    errdefer deinitDecls(allocator, out.items);
    for (roles) |item| {
        try out.append(allocator, .{
            .name = try allocator.dupe(u8, item.name),
            .type_label = try allocator.dupe(u8, item.class_name),
        });
    }
    return out.toOwnedSlice(allocator);
}

fn cloneModules(allocator: std.mem.Allocator, modules: []const ModuleInfo) ![]ModuleInfo {
    var out = std.ArrayList(ModuleInfo).empty;
    errdefer {
        for (out.items) |*module| {
            allocator.free(module.spec);
            if (module.path) |path| allocator.free(path);
            for (module.imports) |*import_info| if (import_info.alias) |alias| allocator.free(alias);
            allocator.free(module.imports);
            allocator.free(module.implicit_import_ids);
            for (module.functions) |scope| allocator.free(scope.name);
            allocator.free(module.functions);
            for (module.pages) |scope| allocator.free(scope.name);
            allocator.free(module.pages);
        }
        out.deinit(allocator);
    }
    for (modules) |module| {
        var imports = try allocator.alloc(ImportInfo, module.imports.len);
        errdefer allocator.free(imports);
        for (module.imports, 0..) |item, i| {
            imports[i] = .{
                .alias = if (item.alias) |alias| try allocator.dupe(u8, alias) else null,
                .unqualified = item.unqualified,
                .module_id = item.module_id,
            };
        }
        var functions = try allocator.alloc(ScopeInfo, module.functions.len);
        errdefer allocator.free(functions);
        for (module.functions, 0..) |scope, i| functions[i] = .{ .name = try allocator.dupe(u8, scope.name), .start = scope.start, .end = scope.end };
        var pages = try allocator.alloc(ScopeInfo, module.pages.len);
        errdefer allocator.free(pages);
        for (module.pages, 0..) |scope, i| pages[i] = .{ .name = try allocator.dupe(u8, scope.name), .start = scope.start, .end = scope.end };
        try out.append(allocator, .{
            .id = module.id,
            .spec = try allocator.dupe(u8, module.spec),
            .path = if (module.path) |path| try allocator.dupe(u8, path) else null,
            .imports = imports,
            .implicit_import_ids = try allocator.dupe(core.SourceModuleId, module.implicit_import_ids),
            .functions = functions,
            .pages = pages,
        });
    }
    return out.toOwnedSlice(allocator);
}

fn cloneFunctions(allocator: std.mem.Allocator, functions: []const FunctionInfo) ![]FunctionInfo {
    var out = std.ArrayList(FunctionInfo).empty;
    errdefer {
        for (out.items) |item| {
            allocator.free(item.name);
            allocator.free(item.signature);
            allocator.free(item.result_type);
            allocator.free(item.documentation);
        }
        out.deinit(allocator);
    }
    for (functions) |item| {
        try out.append(allocator, .{
            .name = try allocator.dupe(u8, item.name),
            .signature = try allocator.dupe(u8, item.signature),
            .result_type = try allocator.dupe(u8, item.result_type),
            .documentation = try allocator.dupe(u8, item.documentation),
            .module_id = item.module_id,
            .primitive = item.primitive,
        });
    }
    return out.toOwnedSlice(allocator);
}

fn cloneVariables(allocator: std.mem.Allocator, variables: []const VariableInfo) ![]VariableInfo {
    var out = std.ArrayList(VariableInfo).empty;
    errdefer {
        for (out.items) |item| {
            allocator.free(item.name);
            allocator.free(item.type_label);
            if (item.object_class) |class_name| allocator.free(class_name);
            if (item.scope_name) |scope_name| allocator.free(scope_name);
        }
        out.deinit(allocator);
    }
    for (variables) |item| {
        try out.append(allocator, .{
            .name = try allocator.dupe(u8, item.name),
            .type_label = try allocator.dupe(u8, item.type_label),
            .object_class = if (item.object_class) |class_name| try allocator.dupe(u8, class_name) else null,
            .module_id = item.module_id,
            .scope_kind = item.scope_kind,
            .scope_name = if (item.scope_name) |scope_name| try allocator.dupe(u8, scope_name) else null,
            .span_start = item.span_start,
            .span_end = item.span_end,
            .visible_start = item.visible_start,
            .visible_end = item.visible_end,
        });
    }
    return out.toOwnedSlice(allocator);
}

fn cloneFields(allocator: std.mem.Allocator, fields: []const FieldInfo) ![]FieldInfo {
    var out = std.ArrayList(FieldInfo).empty;
    errdefer {
        for (out.items) |item| {
            allocator.free(item.name);
            allocator.free(item.class_name);
            allocator.free(item.type_label);
        }
        out.deinit(allocator);
    }
    for (fields) |item| {
        try out.append(allocator, .{
            .name = try allocator.dupe(u8, item.name),
            .class_name = try allocator.dupe(u8, item.class_name),
            .type_label = try allocator.dupe(u8, item.type_label),
        });
    }
    return out.toOwnedSlice(allocator);
}

fn cloneClasses(allocator: std.mem.Allocator, classes: []const ClassInfo) ![]ClassInfo {
    var out = std.ArrayList(ClassInfo).empty;
    errdefer {
        for (out.items) |item| {
            allocator.free(item.name);
            if (item.base) |base| allocator.free(base);
        }
        out.deinit(allocator);
    }
    for (classes) |item| {
        try out.append(allocator, .{
            .name = try allocator.dupe(u8, item.name),
            .base = if (item.base) |base| try allocator.dupe(u8, base) else null,
        });
    }
    return out.toOwnedSlice(allocator);
}

fn cloneDecls(allocator: std.mem.Allocator, decls: []const DeclInfo) ![]DeclInfo {
    var out = std.ArrayList(DeclInfo).empty;
    errdefer deinitDecls(allocator, out.items);
    for (decls) |item| {
        try out.append(allocator, .{
            .name = try allocator.dupe(u8, item.name),
            .type_label = try allocator.dupe(u8, item.type_label),
        });
    }
    return out.toOwnedSlice(allocator);
}

fn deinitDecls(allocator: std.mem.Allocator, items: []DeclInfo) void {
    for (items) |item| {
        allocator.free(item.name);
        allocator.free(item.type_label);
    }
    allocator.free(items);
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

fn appendModuleFunctions(builder: *CandidateBuilder, index: *const Index, module_id: core.SourceModuleId) !void {
    for (index.functions) |function| {
        if (function.module_id != module_id) continue;
        try builder.add(.{
            .label = function.name,
            .kind = .function,
            .detail = function.signature,
            .documentation = function.documentation,
        });
    }
}

fn appendVisibleFunctions(builder: *CandidateBuilder, index: *const Index, allocator: std.mem.Allocator, doc_path: []const u8) !void {
    if (moduleForPath(index, allocator, doc_path)) |module| {
        var visiting = std.AutoHashMap(core.SourceModuleId, void).init(allocator);
        defer visiting.deinit();
        try appendOpenFunctions(builder, index, module, &visiting);

        var implicit_index = module.implicit_import_ids.len;
        while (implicit_index > 0) {
            implicit_index -= 1;
            if (moduleById(index, module.implicit_import_ids[implicit_index])) |implicit_module| {
                try appendOpenFunctions(builder, index, implicit_module, &visiting);
            }
        }
    } else {
        for (index.functions) |function| {
            if (function.module_id != null) continue;
            try appendFunctionCandidate(builder, function);
        }
        return;
    }

    for (index.functions) |function| {
        if (!function.primitive) continue;
        try appendFunctionCandidate(builder, function);
    }
}

fn appendOpenFunctions(
    builder: *CandidateBuilder,
    index: *const Index,
    module: ModuleInfo,
    visiting: *std.AutoHashMap(core.SourceModuleId, void),
) !void {
    if (visiting.contains(module.id)) return;
    try visiting.put(module.id, {});
    for (index.functions) |function| {
        if (function.module_id == module.id) try appendFunctionCandidate(builder, function);
    }
    var i = module.imports.len;
    while (i > 0) {
        i -= 1;
        const import_info = module.imports[i];
        if (!import_info.unqualified) continue;
        const imported_id = import_info.module_id orelse continue;
        const imported = moduleById(index, imported_id) orelse continue;
        try appendOpenFunctions(builder, index, imported, visiting);
    }
}

fn appendFunctionCandidate(builder: *CandidateBuilder, function: FunctionInfo) !void {
    try builder.add(.{
        .label = function.name,
        .kind = .function,
        .detail = function.signature,
        .documentation = function.documentation,
    });
}

fn appendTypeNameCompletions(builder: *CandidateBuilder, index: *const Index, source: []const u8) !void {
    for (builtin_type_names) |name| try builder.add(.{ .label = name, .kind = .type_decl, .detail = "builtin type" });
    try appendSourceTypeNameCompletions(builder, source);
    for (index.types) |item| try builder.add(.{ .label = item.name, .kind = .type_decl, .detail = item.type_label });
    for (index.classes) |item| try builder.add(.{ .label = item.name, .kind = .class });
}

fn appendSourceTypeNameCompletions(builder: *CandidateBuilder, source: []const u8) !void {
    var cursor: usize = 0;
    var in_chevron = false;
    while (cursor < source.len) {
        const line_start = cursor;
        while (cursor < source.len and source[cursor] != '\n') cursor += 1;
        const line = source[line_start..cursor];
        if (in_chevron) {
            if (std.mem.indexOf(u8, line, ">>") != null) in_chevron = false;
        } else {
            if (sourceTypeDeclOnLine(line)) |decl| try builder.add(.{
                .label = decl.name,
                .kind = decl.kind,
                .detail = decl.detail,
            });
            const stripped = stripLineComment(line);
            if (std.mem.indexOf(u8, stripped, "<<") != null and std.mem.indexOf(u8, stripped, ">>") == null) in_chevron = true;
        }
        if (cursor < source.len and source[cursor] == '\n') cursor += 1;
    }
}

const SourceTypeDecl = struct {
    name: []const u8,
    kind: CompletionKind,
    detail: ?[]const u8,
};

fn sourceTypeDeclOnLine(line: []const u8) ?SourceTypeDecl {
    const trimmed = std.mem.trim(u8, stripLineComment(line), " \t\r");
    if (!std.mem.startsWith(u8, trimmed, "type")) return null;
    if (trimmed.len <= "type".len or !std.ascii.isWhitespace(trimmed["type".len])) return null;
    var cursor: usize = "type".len;
    while (cursor < trimmed.len and std.ascii.isWhitespace(trimmed[cursor])) cursor += 1;
    const name_start = cursor;
    if (cursor >= trimmed.len or !isIdentifierStart(trimmed[cursor])) return null;
    cursor += 1;
    while (cursor < trimmed.len and isReceiverChar(trimmed[cursor])) cursor += 1;
    const name = trimmed[name_start..cursor];
    while (cursor < trimmed.len and std.ascii.isWhitespace(trimmed[cursor])) cursor += 1;
    if (cursor < trimmed.len and trimmed[cursor] == '=') {
        cursor += 1;
        while (cursor < trimmed.len and std.ascii.isWhitespace(trimmed[cursor])) cursor += 1;
        if (sourceStartsKeyword(trimmed[cursor..], "object") or sourceStartsKeyword(trimmed[cursor..], "protocol")) {
            return .{ .name = name, .kind = .class, .detail = null };
        }
    }
    return .{ .name = name, .kind = .type_decl, .detail = "type" };
}

fn sourceStartsKeyword(text: []const u8, keyword: []const u8) bool {
    if (!std.mem.startsWith(u8, text, keyword)) return false;
    return text.len == keyword.len or !isIdentChar(text[keyword.len]);
}

fn appendProperties(builder: *CandidateBuilder, index: *const Index, target: PropertyTarget) !void {
    var i = index.fields.len;
    while (i > 0) {
        i -= 1;
        const field = index.fields[i];
        if (!fieldAppliesToTarget(index, field, target)) continue;
        try builder.add(.{ .label = field.name, .kind = .property, .detail = field.type_label });
    }
    try builder.add(.{ .label = "content", .kind = .property, .detail = "String" });
}

fn fieldAppliesToTarget(index: *const Index, field: FieldInfo, target: PropertyTarget) bool {
    return switch (target) {
        .any_object => true,
        .class => |class_name| classContains(index, class_name, field.class_name),
    };
}

fn classContains(index: *const Index, class_name: []const u8, expected: []const u8) bool {
    var current: ?[]const u8 = class_name;
    while (current) |name| {
        if (std.mem.eql(u8, name, expected)) return true;
        current = classBase(index, name);
    }
    return false;
}

fn classBase(index: *const Index, class_name: []const u8) ?[]const u8 {
    var i = index.classes.len;
    while (i > 0) {
        i -= 1;
        const item = index.classes[i];
        if (std.mem.eql(u8, item.name, class_name)) return item.base;
    }
    return null;
}

fn propertyTargetForReceiver(allocator: std.mem.Allocator, index: *const Index, request: Request, receiver: []const u8) ?PropertyTarget {
    if (bestVisibleVariable(index, allocator, receiver, request)) |variable| {
        if (propertyTargetForVariable(variable)) |target| return target;
    }
    return sourcePropertyTarget(allocator, index, request, receiver);
}

fn propertyTargetForVariable(variable: VariableInfo) ?PropertyTarget {
    if (variable.object_class) |class_name| if (class_name.len != 0) return .{ .class = class_name };
    return propertyTargetForTypeLabel(variable.type_label);
}

fn propertyTargetForTypeLabel(type_label: []const u8) ?PropertyTarget {
    if (std.mem.eql(u8, type_label, "Document")) return .{ .class = "Doc" };
    if (std.mem.eql(u8, type_label, "Page")) return .{ .class = "PageContext" };
    if (std.mem.startsWith(u8, type_label, "Object<") and std.mem.endsWith(u8, type_label, ">")) {
        return .{ .class = type_label["Object<".len .. type_label.len - 1] };
    }
    if (std.mem.eql(u8, type_label, "Object") or std.mem.startsWith(u8, type_label, "Selection<Object")) return .any_object;
    return null;
}

fn bestVisibleVariable(index: *const Index, allocator: std.mem.Allocator, name: []const u8, request: Request) ?VariableInfo {
    var best: ?VariableInfo = null;
    var best_rank: usize = 0;
    for (index.variables) |variable| {
        if (!std.mem.eql(u8, variable.name, name)) continue;
        if (!variableVisibleAt(index, allocator, variable, request)) continue;
        const rank = variable.span_start;
        if (best == null or rank >= best_rank) {
            best = variable;
            best_rank = rank;
        }
    }
    return best;
}

fn isBestVisibleVariable(index: *const Index, allocator: std.mem.Allocator, variable: VariableInfo, request: Request) bool {
    const best = bestVisibleVariable(index, allocator, variable.name, request) orelse return false;
    return best.module_id == variable.module_id and
        best.span_start == variable.span_start and
        std.mem.eql(u8, best.name, variable.name);
}

fn variableVisibleAt(index: *const Index, allocator: std.mem.Allocator, variable: VariableInfo, request: Request) bool {
    if (request.offset < variable.visible_start or request.offset > variable.visible_end) return false;
    const module = moduleById(index, variable.module_id) orelse return false;
    const path = module.path orelse return false;
    if (!samePath(allocator, path, request.doc_path)) return false;
    const scope = requestScope(index, allocator, request) orelse return variable.scope_kind == .document and variable.scope_name == null;
    if (scope.kind != variable.scope_kind) return false;
    if (scope.name) |name| return std.mem.eql(u8, variable.scope_name orelse "", name);
    return variable.scope_name == null;
}

const RequestScope = struct {
    kind: core.DefinitionScopeKind,
    name: ?[]const u8,
};

fn requestScope(index: *const Index, allocator: std.mem.Allocator, request: Request) ?RequestScope {
    const module = moduleForPath(index, allocator, request.doc_path) orelse return null;
    for (module.functions) |func| {
        if (request.offset >= func.start and request.offset <= func.end) {
            return .{ .kind = .function, .name = func.name };
        }
    }
    for (module.pages) |page| {
        if (request.offset >= page.start and request.offset <= page.end) {
            return .{ .kind = .page, .name = page.name };
        }
    }
    return .{ .kind = .document, .name = null };
}

fn moduleForPath(index: *const Index, allocator: std.mem.Allocator, doc_path: []const u8) ?ModuleInfo {
    for (index.modules) |module| {
        const path = module.path orelse continue;
        if (samePath(allocator, path, doc_path)) return module;
    }
    return null;
}

fn moduleById(index: *const Index, module_id: core.SourceModuleId) ?ModuleInfo {
    for (index.modules) |module| {
        if (module.id == module_id) return module;
    }
    return null;
}

fn resolveAliasModuleId(index: *const Index, allocator: std.mem.Allocator, doc_path: []const u8, alias: []const u8) ?core.SourceModuleId {
    const module = moduleForPath(index, allocator, doc_path) orelse return null;
    var i = module.imports.len;
    while (i > 0) {
        i -= 1;
        const item = module.imports[i];
        if (!std.mem.eql(u8, item.alias orelse "", alias)) continue;
        return item.module_id;
    }
    return null;
}

fn resolveFunction(index: *const Index, allocator: std.mem.Allocator, doc_path: []const u8, call: CallExpressionName) ?FunctionInfo {
    if (call.qualifier) |qualifier| {
        const module_id = resolveAliasModuleId(index, allocator, doc_path, qualifier) orelse return null;
        return functionInModule(index, module_id, call.name);
    }
    if (moduleForPath(index, allocator, doc_path)) |module| {
        if (functionInModule(index, module.id, call.name)) |function| return function;
        var visiting = std.AutoHashMap(core.SourceModuleId, void).init(allocator);
        defer visiting.deinit();
        if (resolveOpenFunction(index, module, call.name, &visiting)) |function| return function;
        var implicit_index = module.implicit_import_ids.len;
        while (implicit_index > 0) {
            implicit_index -= 1;
            if (moduleById(index, module.implicit_import_ids[implicit_index])) |implicit_module| {
                if (resolveOpenFunction(index, implicit_module, call.name, &visiting)) |function| return function;
            }
        }
    }
    return primitiveFunction(index, call.name);
}

fn resolveOpenFunction(
    index: *const Index,
    module: ModuleInfo,
    name: []const u8,
    visiting: *std.AutoHashMap(core.SourceModuleId, void),
) ?FunctionInfo {
    if (visiting.contains(module.id)) return null;
    visiting.put(module.id, {}) catch return null;
    if (functionInModule(index, module.id, name)) |function| return function;
    var i = module.imports.len;
    while (i > 0) {
        i -= 1;
        const import_info = module.imports[i];
        if (!import_info.unqualified) continue;
        const imported_id = import_info.module_id orelse continue;
        const imported = moduleById(index, imported_id) orelse continue;
        if (resolveOpenFunction(index, imported, name, visiting)) |function| return function;
    }
    return null;
}

fn functionInModule(index: *const Index, module_id: core.SourceModuleId, name: []const u8) ?FunctionInfo {
    for (index.functions) |function| {
        if (function.module_id == null or function.module_id.? != module_id) continue;
        if (std.mem.eql(u8, function.name, name)) return function;
    }
    return null;
}

fn primitiveFunction(index: *const Index, name: []const u8) ?FunctionInfo {
    for (index.functions) |function| {
        if (!function.primitive) continue;
        if (std.mem.eql(u8, function.name, name)) return function;
    }
    return null;
}

const SourceBinding = struct {
    name: []const u8,
    expr: []const u8,
};

fn sourcePropertyTarget(allocator: std.mem.Allocator, index: *const Index, request: Request, receiver: []const u8) ?PropertyTarget {
    var bindings = sourceBindingsInScope(allocator, request.source, request.offset) catch return null;
    defer bindings.deinit(allocator);
    return propertyTargetForBindingName(allocator, index, request, bindings.items, receiver, 0);
}

fn propertyTargetForBindingName(
    allocator: std.mem.Allocator,
    index: *const Index,
    request: Request,
    bindings: []const SourceBinding,
    name: []const u8,
    depth: usize,
) ?PropertyTarget {
    if (depth > 16) return null;
    var i = bindings.len;
    while (i > 0) {
        i -= 1;
        const binding = bindings[i];
        if (!std.mem.eql(u8, binding.name, name)) continue;
        return propertyTargetForExpression(allocator, index, request, bindings, binding.expr, depth + 1);
    }
    return null;
}

fn propertyTargetForExpression(
    allocator: std.mem.Allocator,
    index: *const Index,
    request: Request,
    bindings: []const SourceBinding,
    expr: []const u8,
    depth: usize,
) ?PropertyTarget {
    const trimmed = std.mem.trim(u8, expr, " \t\r\n");
    if (singleIdentifier(trimmed)) |ident| {
        if (propertyTargetForBindingName(allocator, index, request, bindings, ident, depth + 1)) |target| return target;
        if (resolveFunction(index, allocator, request.doc_path, .{ .name = ident })) |function| {
            if (propertyTargetForTypeLabel(function.result_type)) |target| return target;
        }
        if (sourceFunctionResultType(request.source, ident)) |type_label| {
            if (propertyTargetForTypeLabel(type_label)) |target| return target;
        }
    }
    if (callExpressionName(trimmed)) |call| {
        if (resolveFunction(index, allocator, request.doc_path, call)) |function| {
            if (propertyTargetForTypeLabel(function.result_type)) |target| return target;
        }
        if (sourceFunctionResultType(request.source, call.name)) |type_label| {
            if (propertyTargetForTypeLabel(type_label)) |target| return target;
        }
        return null;
    }
    return null;
}

fn sourceBindingsInScope(allocator: std.mem.Allocator, source: []const u8, offset: usize) !std.ArrayList(SourceBinding) {
    const start = scopeStartBeforeOffset(source, offset);
    const end = scopeEndFromStart(source, start);
    var out = std.ArrayList(SourceBinding).empty;
    var cursor = start;
    var in_chevron = false;
    while (cursor < end and cursor < source.len) {
        const line_start = cursor;
        while (cursor < end and cursor < source.len and source[cursor] != '\n') cursor += 1;
        const line = source[line_start..cursor];
        if (in_chevron) {
            if (std.mem.indexOf(u8, line, ">>") != null) in_chevron = false;
        } else {
            if (letBindingOnLine(line)) |binding| try out.append(allocator, binding);
            if (std.mem.indexOf(u8, stripLineComment(line), "<<") != null and std.mem.indexOf(u8, stripLineComment(line), ">>") == null) {
                in_chevron = true;
            }
        }
        if (cursor < source.len and source[cursor] == '\n') cursor += 1;
    }
    return out;
}

fn scopeStartBeforeOffset(source: []const u8, offset: usize) usize {
    const safe_offset = @min(offset, source.len);
    var cursor: usize = 0;
    var stack = [_]struct { kind: BlockKind, start: usize }{.{ .kind = .other, .start = 0 }} ** 256;
    var depth: usize = 0;
    var in_chevron = false;
    while (cursor < safe_offset) {
        const line_start = cursor;
        while (cursor < safe_offset and cursor < source.len and source[cursor] != '\n') cursor += 1;
        const line = source[line_start..cursor];
        if (in_chevron) {
            if (std.mem.indexOf(u8, line, ">>") != null) in_chevron = false;
        } else {
            const trimmed = std.mem.trim(u8, stripLineComment(line), " \t\r");
            if (blockOpeningKind(trimmed)) |kind| {
                if (depth < stack.len) {
                    stack[depth] = .{ .kind = kind, .start = line_start };
                    depth += 1;
                }
            } else if (std.mem.eql(u8, trimmed, "end")) {
                if (depth > 0) depth -= 1;
            }
            if (std.mem.indexOf(u8, trimmed, "<<") != null and std.mem.indexOf(u8, trimmed, ">>") == null) in_chevron = true;
        }
        if (cursor < source.len and source[cursor] == '\n') cursor += 1;
    }
    var i = depth;
    while (i > 0) {
        i -= 1;
        switch (stack[i].kind) {
            .function, .page, .document => return stack[i].start,
            .other => {},
        }
    }
    return 0;
}

fn scopeEndFromStart(source: []const u8, start: usize) usize {
    var cursor = @min(start, source.len);
    var depth: usize = 0;
    var in_chevron = false;
    while (cursor < source.len) {
        const line_start = cursor;
        while (cursor < source.len and source[cursor] != '\n') cursor += 1;
        const line_end = cursor;
        const line = source[line_start..line_end];
        if (in_chevron) {
            if (std.mem.indexOf(u8, line, ">>") != null) in_chevron = false;
        } else {
            const trimmed = std.mem.trim(u8, stripLineComment(line), " \t\r");
            if (blockOpeningKind(trimmed) != null) {
                depth += 1;
            } else if (std.mem.eql(u8, trimmed, "end")) {
                if (depth == 0) return line_end;
                depth -= 1;
                if (depth == 0) return line_end;
            }
            if (std.mem.indexOf(u8, trimmed, "<<") != null and std.mem.indexOf(u8, trimmed, ">>") == null) in_chevron = true;
        }
        if (cursor < source.len and source[cursor] == '\n') cursor += 1;
    }
    return source.len;
}

const BlockKind = enum {
    document,
    page,
    function,
    other,
};

fn blockOpeningKind(line: []const u8) ?BlockKind {
    if (std.mem.eql(u8, line, "document")) return .document;
    if (std.mem.startsWith(u8, line, "page ")) return .page;
    if (std.mem.startsWith(u8, line, "fn ") or std.mem.startsWith(u8, line, "fn/")) return .function;
    if (std.mem.startsWith(u8, line, "if ")) return .other;
    return null;
}

fn letBindingOnLine(line: []const u8) ?SourceBinding {
    const trimmed = std.mem.trim(u8, stripLineComment(line), " \t\r");
    if (!std.mem.startsWith(u8, trimmed, "let ")) return null;
    var cursor: usize = "let ".len;
    while (cursor < trimmed.len and isAccessTrivia(trimmed[cursor])) cursor += 1;
    const name_start = cursor;
    if (cursor >= trimmed.len or !isIdentifierStart(trimmed[cursor])) return null;
    cursor += 1;
    while (cursor < trimmed.len and isIdentChar(trimmed[cursor])) cursor += 1;
    const name = trimmed[name_start..cursor];
    while (cursor < trimmed.len and isAccessTrivia(trimmed[cursor])) cursor += 1;
    if (cursor >= trimmed.len or trimmed[cursor] != '=') return null;
    cursor += 1;
    return .{
        .name = name,
        .expr = std.mem.trim(u8, trimmed[cursor..], " \t\r"),
    };
}

fn sourceFunctionResultType(source: []const u8, target: []const u8) ?[]const u8 {
    var cursor: usize = 0;
    var in_chevron = false;
    while (cursor < source.len) {
        const line_start = cursor;
        while (cursor < source.len and source[cursor] != '\n') cursor += 1;
        const line = source[line_start..cursor];
        if (in_chevron) {
            if (std.mem.indexOf(u8, line, ">>") != null) in_chevron = false;
        } else {
            const trimmed = std.mem.trim(u8, stripLineComment(line), " \t\r");
            if (functionLineResultType(trimmed, target)) |result_type| return result_type;
            if (constLineResultType(trimmed, target)) |result_type| return result_type;
            if (std.mem.indexOf(u8, trimmed, "<<") != null and std.mem.indexOf(u8, trimmed, ">>") == null) in_chevron = true;
        }
        if (cursor < source.len and source[cursor] == '\n') cursor += 1;
    }
    return null;
}

fn functionLineResultType(line: []const u8, target: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, "fn")) return null;
    var cursor: usize = "fn".len;
    var paired = false;
    if (cursor + 2 <= line.len and std.mem.eql(u8, line[cursor .. cursor + 2], "/!")) {
        paired = true;
        cursor += 2;
    }
    if (cursor >= line.len or !std.ascii.isWhitespace(line[cursor])) return null;
    while (cursor < line.len and std.ascii.isWhitespace(line[cursor])) cursor += 1;
    const name_start = cursor;
    if (cursor >= line.len or !isIdentifierStart(line[cursor])) return null;
    cursor += 1;
    while (cursor < line.len and isIdentChar(line[cursor])) cursor += 1;
    const name = line[name_start..cursor];
    if (!callableNameMatches(target, name, paired)) return null;
    const arrow = std.mem.indexOfPos(u8, line, cursor, "->") orelse return null;
    return std.mem.trim(u8, line[arrow + 2 ..], " \t\r");
}

fn constLineResultType(line: []const u8, target: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, "const ")) return null;
    var cursor: usize = "const ".len;
    while (cursor < line.len and std.ascii.isWhitespace(line[cursor])) cursor += 1;
    const name_start = cursor;
    if (cursor >= line.len or !isIdentifierStart(line[cursor])) return null;
    cursor += 1;
    while (cursor < line.len and isReceiverChar(line[cursor])) cursor += 1;
    const name = line[name_start..cursor];
    if (!std.mem.eql(u8, name, target)) return null;
    while (cursor < line.len and std.ascii.isWhitespace(line[cursor])) cursor += 1;
    if (cursor >= line.len or line[cursor] != ':') return null;
    cursor += 1;
    const type_start = cursor;
    while (cursor < line.len and line[cursor] != '=') cursor += 1;
    return std.mem.trim(u8, line[type_start..cursor], " \t\r");
}

fn callableNameMatches(target: []const u8, source_name: []const u8, paired: bool) bool {
    if (std.mem.eql(u8, target, source_name)) return true;
    if (!paired) return false;
    return target.len == source_name.len + 1 and
        target[target.len - 1] == '!' and
        std.mem.eql(u8, target[0 .. target.len - 1], source_name);
}

const CallExpressionName = struct {
    qualifier: ?[]const u8 = null,
    name: []const u8,
};

fn callExpressionName(expr: []const u8) ?CallExpressionName {
    var cursor: usize = 0;
    while (cursor < expr.len and std.ascii.isWhitespace(expr[cursor])) cursor += 1;
    const first_start = cursor;
    if (cursor >= expr.len or !isIdentifierStart(expr[cursor])) return null;
    cursor += 1;
    while (cursor < expr.len and isIdentChar(expr[cursor])) cursor += 1;
    const first = expr[first_start..cursor];
    if (cursor + 2 <= expr.len and std.mem.eql(u8, expr[cursor .. cursor + 2], "::")) {
        cursor += 2;
        const second_start = cursor;
        if (cursor >= expr.len or !isIdentifierStart(expr[cursor])) return null;
        cursor += 1;
        while (cursor < expr.len and isIdentChar(expr[cursor])) cursor += 1;
        return .{ .qualifier = first, .name = expr[second_start..cursor] };
    }
    return .{ .name = first };
}

fn singleIdentifier(expr: []const u8) ?[]const u8 {
    var cursor: usize = 0;
    if (cursor >= expr.len or !isIdentifierStart(expr[cursor])) return null;
    cursor += 1;
    while (cursor < expr.len and isIdentChar(expr[cursor])) cursor += 1;
    const ident = expr[0..cursor];
    while (cursor < expr.len and std.ascii.isWhitespace(expr[cursor])) cursor += 1;
    return if (cursor == expr.len) ident else null;
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
    var line_start = safe_offset;
    while (line_start > 0 and source[line_start - 1] != '\n') line_start -= 1;
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
    if (!isValidAlias(base) or isKeyword(base)) return null;
    return base;
}

fn isValidAlias(alias: []const u8) bool {
    if (alias.len == 0 or !isIdentifierStart(alias[0])) return false;
    for (alias[1..]) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '_') return false;
    }
    return true;
}

fn isKeyword(text: []const u8) bool {
    const keywords = [_][]const u8{ "import", "as", "const", "document", "page", "fn", "let", "return", "end", "type", "extend", "if", "then", "else" };
    for (keywords) |keyword| if (std.mem.eql(u8, text, keyword)) return true;
    return false;
}

fn stripLineComment(line: []const u8) []const u8 {
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        if (line[i] == '#') return line[0..i];
        if (i + 1 < line.len and std.mem.eql(u8, line[i .. i + 2], "//")) return line[0..i];
        if (i + 1 < line.len and std.mem.eql(u8, line[i .. i + 2], ";;")) return line[0..i];
    }
    return line;
}

fn samePath(allocator: std.mem.Allocator, left: []const u8, right: []const u8) bool {
    const a = absolutePath(allocator, left) catch return false;
    defer allocator.free(a);
    const b = absolutePath(allocator, right) catch return false;
    defer allocator.free(b);
    return std.mem.eql(u8, a, b);
}

fn absolutePath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) return allocator.dupe(u8, path);
    const cwd = try cwdAlloc(allocator);
    defer allocator.free(cwd);
    return std.fs.path.resolve(allocator, &.{ cwd, path });
}

fn cwdAlloc(allocator: std.mem.Allocator) ![]u8 {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    if (std.c.getcwd(&buffer, buffer.len) == null) return error.CurrentWorkingDirectoryUnavailable;
    const len = std.mem.indexOfScalar(u8, &buffer, 0) orelse return error.NameTooLong;
    return allocator.dupe(u8, buffer[0..len]);
}

fn isIdentifierStart(byte: u8) bool {
    return std.ascii.isAlphabetic(byte) or byte == '_';
}

fn isIdentChar(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '!';
}

fn isReceiverChar(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}

fn isAccessTrivia(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\r';
}

fn endsWithSeparator(source: []const u8, cursor: usize) bool {
    return (cursor >= 1 and source[cursor - 1] == '.') or
        (cursor >= 2 and std.mem.eql(u8, source[cursor - 2 .. cursor], "::"));
}
