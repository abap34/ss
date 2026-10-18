const std = @import("std");
const model = @import("model");
const ast = @import("ast");
const value_text = @import("value_text.zig");
const declarations = @import("declarations.zig");
const utils = @import("utils");
const group_composition = @import("group_composition.zig");
const DocumentConstraints = @import("constraints.zig").DocumentConstraints;
const DocumentDiagnostics = @import("diagnostics.zig").DocumentDiagnostics;

const Allocator = model.Allocator;
const NodeId = model.NodeId;
const Node = model.Node;
const NodeKind = model.NodeKind;
const Role = model.Role;
const ObjectKind = model.ObjectKind;
const PayloadKind = model.PayloadKind;
const Constraint = model.Constraint;
const ContentProvenance = model.ContentProvenance;
const Selection = model.Selection;
const SelectionItemTag = model.SelectionItemTag;
const ValueTag = model.ValueTag;
const Value = model.Value;
const FunctionRef = model.FunctionRef;
const Query = model.Query;

const Diagnostic = model.Diagnostic;
const DiagnosticSeverity = model.DiagnosticSeverity;
const GroupRole = model.GroupRole;
const roleEq = model.roleEq;
const nodeField = model.nodeField;

pub const SourceModuleId = u32;

const DefaultValueKey = struct {
    pointer: usize,
    length: usize,
};

const DefaultValueCache = struct {
    allocator: Allocator,
    values: std.AutoHashMap(DefaultValueKey, Value),
    mutex: std.atomic.Mutex = .unlocked,

    fn create(allocator: Allocator) !*DefaultValueCache {
        const cache = try allocator.create(DefaultValueCache);
        cache.* = .{
            .allocator = allocator,
            .values = std.AutoHashMap(DefaultValueKey, Value).init(allocator),
        };
        return cache;
    }

    fn clear(self: *DefaultValueCache) void {
        var iterator = self.values.valueIterator();
        while (iterator.next()) |value| value_text.deinitParsedPropertyValue(self.allocator, value);
        self.values.clearRetainingCapacity();
    }

    fn destroy(self: *DefaultValueCache) void {
        self.clear();
        self.values.deinit();
        self.allocator.destroy(self);
    }

    fn getOrParse(self: *DefaultValueCache, text: []const u8, value_type: ast.Type) !Value {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
        defer self.mutex.unlock();

        const key = DefaultValueKey{
            .pointer = @intFromPtr(text.ptr),
            .length = text.len,
        };
        if (self.values.get(key)) |value| return value;

        var value = try value_text.typedPropertyValue(self.allocator, text, value_type);
        errdefer value_text.deinitParsedPropertyValue(self.allocator, &value);
        try self.values.put(key, value);
        return value;
    }
};

pub const FunctionKey = model.FunctionKey;
pub const FunctionKeyContext = model.FunctionKeyContext;

pub const FunctionMap = std.HashMap(FunctionKey, ast.FunctionDecl, FunctionKeyContext, std.hash_map.default_max_load_percentage);
pub const ConstMap = std.HashMap(FunctionKey, ast.ConstDecl, FunctionKeyContext, std.hash_map.default_max_load_percentage);
pub const ConstValueMap = std.HashMap(FunctionKey, Value, FunctionKeyContext, std.hash_map.default_max_load_percentage);
pub const ConstEvalStateMap = std.HashMap(FunctionKey, u8, FunctionKeyContext, std.hash_map.default_max_load_percentage);

pub fn functionKey(module_id: SourceModuleId, name: []const u8) FunctionKey {
    return .{ .module_id = module_id, .name = name };
}

/// Display entries share a source name but retain distinct declaration identities.
pub fn functionDeclarationKey(module_id: SourceModuleId, declaration: ast.FunctionDecl) FunctionKey {
    return .{
        .module_id = module_id,
        .name = declaration.name,
        .instance_id = declaration.instance_id,
        .declaration_start = if (declaration.isDisplay()) declaration.span.start else null,
    };
}

pub fn constKey(module_id: SourceModuleId, name: []const u8) FunctionKey {
    return .{ .module_id = module_id, .name = name };
}

pub const SourceModuleKind = enum {
    project,
    library,
};

pub const SourceModule = struct {
    id: SourceModuleId,
    kind: SourceModuleKind,
    spec: []u8,
    path: ?[]u8,
    source: []u8,
    line_index: utils.source.LineIndex,
    syntax: ast.Module,
    implicit_import_ids: std.ArrayList(SourceModuleId),
    resolved_import_ids: std.ArrayList(SourceModuleId),

    pub fn deinit(self: *SourceModule, allocator: Allocator) void {
        self.line_index.deinit(allocator);
        self.syntax.deinit(allocator);
        self.implicit_import_ids.deinit(allocator);
        self.resolved_import_ids.deinit(allocator);
        allocator.free(self.spec);
        allocator.free(self.source);
        if (self.path) |path| allocator.free(path);
    }
};

pub const ObjectSource = struct {
    node_id: NodeId,
    page_id: NodeId,
    module_id: SourceModuleId,
    path: []const u8,
    binding_base: ?[]const u8,
    span_start: usize,
    span_end: usize,
};

pub const PageSource = struct {
    page_id: NodeId,
    module_id: SourceModuleId,
    path: []const u8,
    span_start: usize,
    span_end: usize,
};

pub const DefinitionKind = enum {
    function,
    constant,
    variable,
};

pub const DefinitionScopeKind = enum {
    module,
    function,
    document,
    page,
};

const BindingLocation = struct {
    module_id: SourceModuleId,
    offset: usize,
};

// These types borrow the analyzed source generation, like function signatures.
pub const BindingType = struct {
    ty: ast.Type,
    object_class: ?model.NominalId = null,
};

pub const Definition = struct {
    name: []const u8,
    line: usize,
    column: usize,
    length: usize,
    span_start: usize,
    span_end: usize,
    visible_start: usize = 0,
    visible_end: usize = std.math.maxInt(usize),
    kind: DefinitionKind,
    module_id: SourceModuleId,
    file: ?[]const u8 = null,
    scope_kind: DefinitionScopeKind = .module,
    scope_name: ?[]const u8 = null,
};

const PageOwnershipInfo = struct {
    first: ?NodeId = null,
    count: usize = 0,
};

pub const DocumentModules = struct {
    entries: std.ArrayList(SourceModule) = .empty,
    order: std.ArrayList(SourceModuleId) = .empty,
    project_id: SourceModuleId = 0,

    fn deinit(self: *DocumentModules, allocator: Allocator) void {
        for (self.entries.items) |*module| module.deinit(allocator);
        self.entries.deinit(allocator);
        self.order.deinit(allocator);
    }
};

pub const DocumentConstants = struct {
    declarations: ConstMap,
    values: ConstValueMap,
    eval_states: ConstEvalStateMap,

    fn init(allocator: Allocator) DocumentConstants {
        return .{
            .declarations = ConstMap.init(allocator),
            .values = ConstValueMap.init(allocator),
            .eval_states = ConstEvalStateMap.init(allocator),
        };
    }

    fn deinit(self: *DocumentConstants, allocator: Allocator) void {
        self.declarations.deinit();
        var iterator = self.values.valueIterator();
        while (iterator.next()) |value| value.deinit(allocator);
        self.values.deinit();
        self.eval_states.deinit();
    }
};

pub const DocumentGraph = struct {
    nodes: std.ArrayList(Node) = .empty,
    page_order: std.ArrayList(NodeId) = .empty,
    composition_cursor: ?model.CompositionOrder = null,
    contains: std.AutoHashMap(NodeId, std.ArrayList(NodeId)),
    page_placement_roots: std.AutoHashMap(NodeId, std.ArrayList(NodeId)),
    direct_page_ownership: std.ArrayList(PageOwnershipInfo) = .empty,
    next_id: NodeId = 1,
    document_id: NodeId = 0,

    fn init(allocator: Allocator) DocumentGraph {
        return .{
            .contains = .init(allocator),
            .page_placement_roots = .init(allocator),
        };
    }

    fn deinit(self: *DocumentGraph, allocator: Allocator) void {
        var children = self.contains.valueIterator();
        while (children.next()) |ids| ids.deinit(allocator);
        self.contains.deinit();
        var roots = self.page_placement_roots.valueIterator();
        while (roots.next()) |ids| ids.deinit(allocator);
        self.page_placement_roots.deinit();
        self.direct_page_ownership.deinit(allocator);
        for (self.nodes.items) |*node| node.deinit(allocator);
        self.nodes.deinit(allocator);
        self.page_order.deinit(allocator);
    }
};

pub const DocumentSourceMap = struct {
    objects: std.ArrayList(ObjectSource) = .empty,
    pages: std.ArrayList(PageSource) = .empty,
    definitions: std.ArrayList(Definition) = .empty,
    binding_types: std.AutoHashMap(BindingLocation, BindingType),
    inferred_values: std.heap.ArenaAllocator,

    fn init(allocator: Allocator) DocumentSourceMap {
        return .{ .binding_types = .init(allocator), .inferred_values = .init(allocator) };
    }

    fn deinit(self: *DocumentSourceMap, allocator: Allocator) void {
        self.objects.deinit(allocator);
        self.pages.deinit(allocator);
        for (self.definitions.items) |definition| {
            allocator.free(definition.name);
            if (definition.file) |file| allocator.free(file);
            if (definition.scope_name) |scope_name| allocator.free(scope_name);
        }
        self.definitions.deinit(allocator);
        self.binding_types.deinit();
        self.inferred_values.deinit();
    }
};

pub const DocumentRuntime = struct {
    analysis_cancellation: ?utils.Cancellation = null,
    strings: std.ArrayList([]u8) = .empty,
    string_provenance: std.AutoHashMap(usize, std.ArrayList(ContentProvenance)),
    default_values: *DefaultValueCache,

    fn init(allocator: Allocator) !DocumentRuntime {
        return .{
            .string_provenance = .init(allocator),
            .default_values = try DefaultValueCache.create(allocator),
        };
    }

    fn deinit(self: *DocumentRuntime, allocator: Allocator) void {
        var iterator = self.string_provenance.valueIterator();
        while (iterator.next()) |entries| {
            for (entries.items) |*entry| entry.deinit(allocator);
            entries.deinit(allocator);
        }
        self.string_provenance.deinit();
        self.default_values.destroy();
        for (self.strings.items) |text| allocator.free(text);
        self.strings.deinit(allocator);
    }
};

pub const DocumentState = struct {
    allocator: Allocator,
    asset_base_dir: []u8,
    modules: DocumentModules,
    declaration_index: *declarations.DeclarationIndex,
    constants: DocumentConstants,
    functions: FunctionMap,
    instantiations: @import("function_instances.zig").Store,
    type_instances: @import("type_instances.zig").Store,
    displays: @import("native_display.zig").Store,
    next_expression_id: u64 = 0,
    graph: DocumentGraph,
    constraints: DocumentConstraints,
    source_map: DocumentSourceMap,
    diagnostics: DocumentDiagnostics,
    runtime: DocumentRuntime,

    // Borrowed observer owned by the host build request.
    file_inputs: ?*utils.FileInputs = null,

    pub fn checkAnalysisCanceled(self: *const DocumentState) !void {
        if (self.runtime.analysis_cancellation) |token| try token.check();
    }

    pub fn init(
        allocator: Allocator,
        asset_base_dir: []u8,
        project_path: []u8,
        project_source: []u8,
        project_syntax: ast.Module,
    ) !DocumentState {
        const declaration_index = try allocator.create(declarations.DeclarationIndex);
        const runtime = DocumentRuntime.init(allocator) catch |err| {
            allocator.destroy(declaration_index);
            return err;
        };
        declaration_index.* = declarations.DeclarationIndex.init(allocator);
        var state = DocumentState{
            .allocator = allocator,
            .asset_base_dir = asset_base_dir,
            .modules = .{},
            .declaration_index = declaration_index,
            .constants = .init(allocator),
            .functions = FunctionMap.init(allocator),
            .instantiations = .init(allocator),
            .type_instances = .init(allocator),
            .displays = .init(allocator),
            .graph = .init(allocator),
            .constraints = .{},
            .source_map = .init(allocator),
            .diagnostics = .{},
            .runtime = runtime,
        };
        errdefer state.deinitPartial();

        const project_spec = try allocator.dupe(u8, project_path);
        errdefer allocator.free(project_spec);

        const doc_id = try state.freshId();
        try state.graph.nodes.append(allocator, .{
            .id = doc_id,
            .kind = .document,
            .name = "document",
            .attached = true,
        });
        state.graph.document_id = doc_id;

        const line_index = try utils.source.LineIndex.init(allocator, project_source);
        errdefer line_index.deinit(allocator);
        try state.modules.entries.append(allocator, .{
            .id = 0,
            .kind = .project,
            .spec = project_spec,
            .path = project_path,
            .source = project_source,
            .line_index = line_index,
            .syntax = project_syntax,
            .implicit_import_ids = .empty,
            .resolved_import_ids = .empty,
        });

        try state.rebuildDeclarationIndex();
        return state;
    }

    pub fn recordBindingType(self: *DocumentState, module_id: SourceModuleId, span: ?ast.Span, value: BindingType) !void {
        const location = span orelse return;
        const module = self.moduleById(module_id) orelse return;
        if (module.path == null) return;
        try self.source_map.binding_types.put(.{ .module_id = module_id, .offset = location.start }, value);
    }

    pub fn bindingTypeAt(self: *const DocumentState, module_id: SourceModuleId, offset: usize) ?BindingType {
        return self.source_map.binding_types.get(.{ .module_id = module_id, .offset = offset });
    }

    // Inferred types and facts are shared by environments, caches, and bindings.
    // Their storage follows the state, including retained evaluation inputs.
    // Callers must obtain this allocator again after moving DocumentState.
    pub fn inferenceAllocator(self: *DocumentState) Allocator {
        return self.source_map.inferred_values.allocator();
    }

    pub fn builtinClass(self: *const DocumentState, name: []const u8) ?model.NominalId {
        return self.declaration_index.builtinClass(name);
    }

    pub fn rebuildDeclarationIndex(self: *DocumentState) !void {
        const next = try declarations.build(self.allocator, self);
        self.declaration_index.deinit();
        self.declaration_index.* = next;
        self.runtime.default_values.clear();
    }

    const InputOwnership = enum { borrowed, owned };

    fn deinitPartial(self: *DocumentState) void {
        self.deinitWithInputOwnership(.borrowed);
    }

    pub fn deinit(self: *DocumentState) void {
        self.deinitWithInputOwnership(.owned);
    }

    // init transfers its inputs only on success; partial cleanup owns storage only.
    fn deinitWithInputOwnership(self: *DocumentState, inputs: InputOwnership) void {
        self.declaration_index.deinit();
        self.allocator.destroy(self.declaration_index);
        self.instantiations.deinit();
        self.type_instances.deinit();
        self.displays.deinit();
        switch (inputs) {
            .borrowed => {
                self.modules.entries.deinit(self.allocator);
                self.modules.order.deinit(self.allocator);
            },
            .owned => self.modules.deinit(self.allocator),
        }
        self.constants.deinit(self.allocator);
        self.functions.deinit();
        self.graph.deinit(self.allocator);
        self.constraints.deinit(self.allocator);
        self.source_map.deinit(self.allocator);
        self.diagnostics.deinit(self.allocator);
        self.runtime.deinit(self.allocator);
        if (inputs == .owned) self.allocator.free(self.asset_base_dir);
    }

    pub fn cachedFieldDefault(self: *DocumentState, text: []const u8, value_type: ast.Type) !Value {
        std.debug.assert(value_text.typedPropertyValueOwnsTaggedText(value_type));
        return self.runtime.default_values.getOrParse(text, value_type);
    }

    fn stringKey(text: []const u8) usize {
        return @intFromPtr(text.ptr);
    }

    fn deinitProvenanceList(self: *DocumentState, entries: *std.ArrayList(ContentProvenance)) void {
        for (entries.items) |*entry| entry.deinit(self.allocator);
        entries.deinit(self.allocator);
    }

    fn cloneProvenanceList(self: *DocumentState, entries: []const ContentProvenance) !std.ArrayList(ContentProvenance) {
        var cloned = std.ArrayList(ContentProvenance).empty;
        errdefer self.deinitProvenanceList(&cloned);
        for (entries) |entry| {
            try cloned.append(self.allocator, try entry.clone(self.allocator));
        }
        return cloned;
    }

    pub fn setStringProvenance(self: *DocumentState, text: []const u8, entries: []const ContentProvenance) !void {
        if (text.len == 0 or entries.len == 0) return;
        var cloned = try self.cloneProvenanceList(entries);
        errdefer self.deinitProvenanceList(&cloned);
        const gop = try self.runtime.string_provenance.getOrPut(stringKey(text));
        if (gop.found_existing) self.deinitProvenanceList(gop.value_ptr);
        gop.value_ptr.* = cloned;
    }

    pub fn stringProvenance(self: *const DocumentState, text: []const u8) []const ContentProvenance {
        if (text.len == 0) return &.{};
        const entries = self.runtime.string_provenance.get(stringKey(text)) orelse return &.{};
        return entries.items;
    }

    pub fn ownString(self: *DocumentState, text: []u8) ![]const u8 {
        errdefer self.allocator.free(text);
        try self.runtime.strings.append(self.allocator, text);
        return text;
    }

    pub fn ownStringWithProvenance(self: *DocumentState, text: []u8, entries: []const ContentProvenance) ![]const u8 {
        errdefer self.allocator.free(text);
        try self.runtime.strings.append(self.allocator, text);
        var appended = true;
        errdefer {
            if (appended) _ = self.runtime.strings.pop();
        }
        try self.setStringProvenance(text, entries);
        appended = false;
        return text;
    }

    pub fn copyString(self: *DocumentState, text: []const u8) ![]const u8 {
        return self.ownString(try self.allocator.dupe(u8, text));
    }

    fn copyOptionalString(self: *DocumentState, text: ?[]const u8) !?[]const u8 {
        return if (text) |value| try self.copyString(value) else null;
    }

    pub fn projectPath(self: *const DocumentState) []const u8 {
        return self.projectModule().path orelse "";
    }

    pub fn sourceOrigin(self: *const DocumentState, module_id: SourceModuleId, span: model.SourceSpan) model.SourceOrigin {
        const module = self.moduleById(module_id);
        const path = if (module) |value| value.path orelse value.spec else "";
        return model.SourceOrigin.at(path, span);
    }

    fn copyOrigin(self: *DocumentState, origin: model.SourceOrigin) !model.SourceOrigin {
        return .{
            .path = try self.copyOptionalString(origin.path),
            .span = origin.span,
            .label = try self.copyOptionalString(origin.label),
        };
    }

    pub fn projectSource(self: *const DocumentState) []const u8 {
        return self.projectModule().source;
    }

    pub fn projectSyntax(self: *const DocumentState) ast.Module {
        return self.projectModule().syntax;
    }

    pub fn projectModule(self: *const DocumentState) *const SourceModule {
        return self.moduleById(self.modules.project_id).?;
    }

    pub fn moduleById(self: *const DocumentState, id: SourceModuleId) ?*const SourceModule {
        const index: usize = @intCast(id);
        if (index < self.modules.entries.items.len and self.modules.entries.items[index].id == id) {
            return &self.modules.entries.items[index];
        }
        for (self.modules.entries.items) |*module| {
            if (module.id == id) return module;
        }
        return null;
    }

    pub fn moduleByPathOrSpec(self: *const DocumentState, key: []const u8) ?*const SourceModule {
        for (self.modules.entries.items) |*module| {
            if (module.path) |module_path| {
                if (std.mem.eql(u8, module_path, key)) return module;
            }
            if (std.mem.eql(u8, module.spec, key)) return module;
        }
        return null;
    }

    pub fn projectModuleMutable(self: *DocumentState) *SourceModule {
        return self.moduleByIdMutable(self.modules.project_id).?;
    }

    pub fn moduleByIdMutable(self: *DocumentState, id: SourceModuleId) ?*SourceModule {
        const index: usize = @intCast(id);
        if (index < self.modules.entries.items.len and self.modules.entries.items[index].id == id) {
            return &self.modules.entries.items[index];
        }
        for (self.modules.entries.items) |*module| {
            if (module.id == id) return module;
        }
        return null;
    }

    fn freshId(self: *DocumentState) !NodeId {
        const id = self.graph.next_id;
        try self.graph.direct_page_ownership.append(self.allocator, .{});
        self.graph.next_id += 1;
        return id;
    }

    pub fn nodeCount(self: *const DocumentState) usize {
        return self.graph.nodes.items.len;
    }

    fn nextCompositionOrder(self: *DocumentState) ?model.CompositionOrder {
        const order = self.graph.composition_cursor orelse return null;
        self.graph.composition_cursor.?.sequence += 1;
        return order;
    }

    fn insertComposition(self: *DocumentState, ids: *std.ArrayList(NodeId), id: NodeId) !usize {
        const index = self.compositionInsertionIndex(ids.items, id);
        try ids.insert(self.allocator, index, id);
        return index;
    }

    fn compositionInsertionIndex(self: *DocumentState, ids: []const NodeId, id: NodeId) usize {
        var index = ids.len;
        if (self.getNode(id).?.composition_order) |order| {
            while (index > 0) {
                const previous = self.getNode(ids[index - 1]).?.composition_order orelse break;
                if (!order.lessThan(previous)) break;
                index -= 1;
            }
        }
        return index;
    }

    pub fn addContainment(self: *DocumentState, parent: NodeId, child: NodeId) !void {
        if (self.getNode(child)) |node| {
            if (node.placement) |placement| {
                if (parent != placement.parent_id) return error.DuplicateObjectParent;
                // Registration publishes this edge together with the input.
                return;
            }
        }
        if (self.getNode(parent)) |node| {
            if (node.placement != null) return error.InvalidPlacementParent;
        }
        const parent_is_page = if (self.getNode(parent)) |node| node.kind == .page else false;
        const gop = try self.graph.contains.getOrPut(parent);
        if (!gop.found_existing) {
            gop.value_ptr.* = .empty;
        }
        for (gop.value_ptr.items) |existing| {
            if (existing == child) return;
        }
        if (parent_is_page or parent == self.graph.document_id) {
            _ = try self.insertComposition(gop.value_ptr, child);
        } else {
            // Group child order is the explicit argument order.
            try gop.value_ptr.append(self.allocator, child);
        }
        if (!parent_is_page or child == 0) return;
        const child_index: usize = @intCast(child - 1);
        if (child_index >= self.graph.direct_page_ownership.items.len) return;
        const ownership = &self.graph.direct_page_ownership.items[child_index];
        if (ownership.first == null) ownership.first = parent;
        ownership.count += 1;
    }

    fn addPagePlacementRoot(self: *DocumentState, page_id: NodeId, object_id: NodeId) !void {
        const gop = try self.graph.page_placement_roots.getOrPut(page_id);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        for (gop.value_ptr.items) |existing| {
            if (existing == object_id) return;
        }
        _ = try self.insertComposition(gop.value_ptr, object_id);
    }

    pub fn addPage(self: *DocumentState, name: []const u8) !NodeId {
        const page_id = try self.freshId();
        const owned_name = try self.copyString(name);
        try self.graph.nodes.append(self.allocator, .{
            .id = page_id,
            .kind = .page,
            .name = owned_name,
            .attached = true,
            .composition_order = self.nextCompositionOrder(),
        });
        const index = try self.insertComposition(&self.graph.page_order, page_id);
        for (self.graph.page_order.items[index..], index + 1..) |id, page_index| {
            self.getNode(id).?.page_index = page_index;
        }
        try self.addContainment(self.graph.document_id, page_id);
        return page_id;
    }

    pub fn makeObject(
        self: *DocumentState,
        page_id: NodeId,
        name: []const u8,
        role: ?Role,
        object_kind: ObjectKind,
        payload_kind: PayloadKind,
        content: ?[]const u8,
    ) !NodeId {
        return self.makeNodeWithOrigin(page_id, true, .object, name, role, object_kind, payload_kind, content, null);
    }

    /// Register a fresh placement without evaluating its display. The caller
    /// has checked the input's display contract and keeps borrowed Value data
    /// alive for the document. No rendering kind or legacy role is inferred.
    pub fn registerPlacement(
        self: *DocumentState,
        parent_id: NodeId,
        input: Value,
        origin: ?model.SourceOrigin,
    ) !NodeId {
        if (input == .void) return error.InvalidValueTag;
        const parent = self.getNode(parent_id) orelse return error.UnknownNode;
        if (parent.discarded) return error.InvalidPlacementParent;
        const is_root = parent.kind == .page;
        const page_id = if (is_root) parent_id else if (parent.placement) |placement|
            placement.page_id
        else
            return error.InvalidPlacementParent;

        var value = try input.clone(self.allocator);
        errdefer value.deinit(self.allocator);
        const owned_origin = if (origin) |source| try self.copyOrigin(source) else null;
        try self.graph.nodes.ensureUnusedCapacity(self.allocator, 1);
        try self.graph.direct_page_ownership.ensureUnusedCapacity(self.allocator, 1);

        const children = try self.graph.contains.getOrPut(parent_id);
        if (!children.found_existing) children.value_ptr.* = .empty;
        errdefer if (!children.found_existing) {
            children.value_ptr.deinit(self.allocator);
            _ = self.graph.contains.remove(parent_id);
        };
        try children.value_ptr.ensureUnusedCapacity(self.allocator, 1);

        const roots: ?*std.ArrayList(NodeId) = if (is_root) blk: {
            const entry = try self.graph.page_placement_roots.getOrPut(page_id);
            if (!entry.found_existing) entry.value_ptr.* = .empty;
            errdefer if (!entry.found_existing) {
                entry.value_ptr.deinit(self.allocator);
                _ = self.graph.page_placement_roots.remove(page_id);
            };
            try entry.value_ptr.ensureUnusedCapacity(self.allocator, 1);
            break :blk entry.value_ptr;
        } else null;

        // All fallible work precedes publication. Failed registrations neither
        // consume an identity/order position nor leave a partially attached node.
        const id = self.graph.next_id;
        self.graph.next_id += 1;
        self.graph.direct_page_ownership.appendAssumeCapacity(.{ .first = page_id, .count = 1 });
        self.graph.nodes.appendAssumeCapacity(.{
            .id = id,
            .kind = .object,
            .name = "placement",
            .attached = true,
            .placement = .{ .value = value, .parent_id = parent_id, .page_id = page_id },
            .composition_order = if (is_root) self.nextCompositionOrder() else null,
            .origin = owned_origin,
        });
        if (is_root) {
            const position = self.compositionInsertionIndex(children.value_ptr.items, id);
            children.value_ptr.insertAssumeCapacity(position, id);
            const root_position = self.compositionInsertionIndex(roots.?.items, id);
            roots.?.insertAssumeCapacity(root_position, id);
        } else {
            // A display's children retain its output order, independently of
            // the execution unit that happened to expand their parent.
            children.value_ptr.appendAssumeCapacity(id);
        }
        return id;
    }

    /// Publish all direct children of a display together. Allocation failure
    /// leaves its child collection and the node identity sequence unchanged.
    pub fn registerPlacementChildren(self: *DocumentState, parent_id: NodeId, inputs: []const Value, origin: ?model.SourceOrigin) ![]const NodeId {
        const parent = self.getNode(parent_id) orelse return error.UnknownNode;
        if (parent.discarded) return error.InvalidPlacementParent;
        const page_id = (parent.placement orelse return error.InvalidPlacementParent).page_id;
        if (self.childrenOf(parent_id)) |existing| if (existing.len != 0) return error.InvalidPlacementParent;
        var nodes = std.ArrayList(Node).empty;
        defer nodes.deinit(self.allocator);
        errdefer for (nodes.items) |*node| node.deinit(self.allocator);
        try nodes.ensureTotalCapacity(self.allocator, inputs.len);
        const owned_origin = if (origin) |source| try self.copyOrigin(source) else null;
        for (inputs, 0..) |input, offset| {
            if (input.presentationType() == null) return error.InvalidValueTag;
            const value = try input.clone(self.allocator);
            nodes.appendAssumeCapacity(.{
                .id = self.graph.next_id + @as(NodeId, @intCast(offset)),
                .kind = .object,
                .name = "placement",
                .attached = true,
                .placement = .{ .value = value, .parent_id = parent_id, .page_id = page_id },
                .origin = owned_origin,
            });
        }
        try self.graph.nodes.ensureUnusedCapacity(self.allocator, nodes.items.len);
        try self.graph.direct_page_ownership.ensureUnusedCapacity(self.allocator, nodes.items.len);
        const children = try self.graph.contains.getOrPut(parent_id);
        if (!children.found_existing) children.value_ptr.* = .empty;
        errdefer if (!children.found_existing) {
            children.value_ptr.deinit(self.allocator);
            _ = self.graph.contains.remove(parent_id);
        };
        try children.value_ptr.ensureUnusedCapacity(self.allocator, nodes.items.len);
        for (nodes.items) |node| {
            children.value_ptr.appendAssumeCapacity(node.id);
            self.graph.direct_page_ownership.appendAssumeCapacity(.{ .first = page_id, .count = 1 });
            self.graph.nodes.appendAssumeCapacity(node);
        }
        self.graph.next_id += @intCast(nodes.items.len);
        return children.value_ptr.items;
    }

    pub fn createObjectWithOrigin(
        self: *DocumentState,
        name: []const u8,
        role: ?Role,
        object_kind: ObjectKind,
        payload_kind: PayloadKind,
        content: ?[]const u8,
        origin: ?model.SourceOrigin,
    ) !NodeId {
        return self.makeNodeWithOrigin(self.graph.document_id, false, .object, name, role, object_kind, payload_kind, content, origin);
    }

    pub fn makeGroupWithOrigin(
        self: *DocumentState,
        page_id: NodeId,
        attached: bool,
        children: []const NodeId,
        origin: ?model.SourceOrigin,
    ) !NodeId {
        const group_id = try self.makeNodeWithOrigin(
            page_id,
            attached,
            .object,
            "group",
            GroupRole,
            .overlay,
            .text,
            "",
            origin,
        );
        for (children) |child_id| {
            try self.addContainment(group_id, child_id);
        }
        return group_id;
    }

    pub fn createGroupWithOrigin(
        self: *DocumentState,
        children: []const NodeId,
        origin: ?model.SourceOrigin,
    ) !NodeId {
        return try self.makeGroupWithOrigin(self.graph.document_id, false, children, origin);
    }

    pub fn placeObjectOnPage(self: *DocumentState, page_id: NodeId, object_id: NodeId) !void {
        const page = self.getNode(page_id) orelse return error.UnknownNode;
        if (page.kind != .page) return error.InvalidValueTag;
        // Validate the whole composition before publishing any membership.
        var seen = std.AutoHashMap(NodeId, void).init(self.allocator);
        defer seen.deinit();
        var pending = std.ArrayList(NodeId).empty;
        defer pending.deinit(self.allocator);
        try pending.append(self.allocator, object_id);
        var index: usize = 0;
        while (index < pending.items.len) : (index += 1) {
            const id = pending.items[index];
            const entry = try seen.getOrPut(id);
            if (entry.found_existing) return error.DuplicateObjectParent;
            const node = self.getNode(id) orelse return error.UnknownNode;
            if (node.kind != .object) return error.InvalidValueTag;
            if (node.attached) return error.DuplicatePlacement;
            if (self.childrenOf(id)) |children| try pending.appendSlice(self.allocator, children);
        }
        try self.attachObjectSubtreeToPage(page_id, object_id);
        try self.addPagePlacementRoot(page_id, object_id);
    }

    fn attachObjectSubtreeToPage(self: *DocumentState, page_id: NodeId, object_id: NodeId) !void {
        var visited = std.AutoHashMap(NodeId, void).init(self.allocator);
        defer visited.deinit();
        try self.placeObjectSubtree(page_id, object_id, &visited);
    }

    fn placeObjectSubtree(self: *DocumentState, page_id: NodeId, object_id: NodeId, visited: *std.AutoHashMap(NodeId, void)) !void {
        if (visited.contains(object_id)) return;
        try visited.put(object_id, {});
        const node = self.getNode(object_id) orelse return error.UnknownNode;
        if (node.kind != .object) return error.InvalidValueTag;
        node.attached = true;
        node.discarded = false;
        node.composition_order = self.nextCompositionOrder();
        try self.addContainment(page_id, object_id);
        const children = self.childrenOf(object_id) orelse return;
        for (children) |child_id| try self.placeObjectSubtree(page_id, child_id, visited);
    }

    pub fn discardObjectSubtree(self: *DocumentState, object_id: NodeId) !void {
        var visited = std.AutoHashMap(NodeId, void).init(self.allocator);
        defer visited.deinit();
        try self.discardObjectSubtreeInner(object_id, &visited);
    }

    fn discardObjectSubtreeInner(self: *DocumentState, object_id: NodeId, visited: *std.AutoHashMap(NodeId, void)) !void {
        if (visited.contains(object_id)) return;
        try visited.put(object_id, {});
        const node = self.getNode(object_id) orelse return error.UnknownNode;
        if (node.kind != .object) return error.InvalidValueTag;
        node.discarded = true;
        const children = self.childrenOf(object_id) orelse return;
        for (children) |child_id| try self.discardObjectSubtreeInner(child_id, visited);
    }

    pub fn markReturnedObjectOrigins(self: *DocumentState, return_id: NodeId, start_index: usize, origin: ?model.SourceOrigin) !void {
        const value = origin orelse return;
        var seen = std.AutoHashMap(NodeId, void).init(self.allocator);
        defer seen.deinit();
        var queue = std.ArrayList(NodeId).empty;
        defer queue.deinit(self.allocator);
        try queue.append(self.allocator, return_id);
        var index: usize = 0;
        while (index < queue.items.len) : (index += 1) {
            const id = queue.items[index];
            const entry = try seen.getOrPut(id);
            if (entry.found_existing) continue;
            try self.setGeneratedNodeOrigin(id, start_index, value);
            if (self.childrenOf(id)) |children| try queue.appendSlice(self.allocator, children);
        }
    }

    fn setGeneratedNodeOrigin(self: *DocumentState, node_id: NodeId, start_index: usize, origin: model.SourceOrigin) !void {
        if (node_id == 0) return;
        const node_index: usize = @intCast(node_id - 1);
        if (node_index < start_index or node_index >= self.graph.nodes.items.len) return;
        const node = &self.graph.nodes.items[node_index];
        if (node.id != node_id) return;
        node.origin = try self.copyOrigin(origin);
    }

    pub fn setNodeFieldValue(self: *DocumentState, node_id: NodeId, key: []const u8, value: Value) !void {
        return self.setNodeFieldValueWithOrigin(node_id, key, value, 0, null);
    }

    pub fn setNodeFieldValueWithOrigin(
        self: *DocumentState,
        node_id: NodeId,
        key: []const u8,
        value: Value,
        scope_depth: u32,
        origin: ?model.SourceOrigin,
    ) !void {
        try self.defineNodeFieldPath(node_id, key, key, value, scope_depth, origin);
    }

    pub fn conflictingPropertyDefinition(self: *DocumentState, node_id: NodeId, path: []const u8) ?model.PropertyDefinition {
        const node = self.getNode(node_id) orelse return null;
        for (node.property_definitions.items) |definition| {
            if (model.PropertyPath.intersects(definition.path, path)) return definition;
        }
        return null;
    }

    // The field is a materialized value. Definitions retain the exact paths
    // that supplied it, independently of defaults and sibling definitions.
    pub fn defineNodeFieldPath(
        self: *DocumentState,
        node_id: NodeId,
        key: []const u8,
        path: []const u8,
        value: Value,
        scope_depth: u32,
        origin: ?model.SourceOrigin,
    ) !void {
        const node = self.getNode(node_id) orelse return error.UnknownNode;
        if (self.conflictingPropertyDefinition(node_id, path) != null) return error.DuplicatePropertyDefinition;
        const owned_path = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned_path);
        var owned_value = try value.clone(self.allocator);
        errdefer owned_value.deinit(self.allocator);
        try node.property_definitions.ensureUnusedCapacity(self.allocator, 1);
        for (node.fields.items) |*field| {
            if (!std.mem.eql(u8, field.key, key)) continue;
            field.value.deinit(self.allocator);
            field.value = owned_value;
            node.property_definitions.appendAssumeCapacity(.{ .path = owned_path, .origin = origin });
            return;
        }
        const owned_key = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(owned_key);
        try node.fields.append(self.allocator, .{
            .key = owned_key,
            .value = owned_value,
            .scope_depth = scope_depth,
            .origin = origin,
        });
        node.property_definitions.appendAssumeCapacity(.{ .path = owned_path, .origin = origin });
    }

    /// Materialize final group fields once, after evaluation and before
    /// constraint-update normalization. Repeated calls do not recreate masked
    /// candidates. Anchor selection is deferred to the page layout policy.
    pub fn collectDefaultAlignments(self: *DocumentState) !void {
        if (self.constraints.default_alignments_collected) return;
        var candidates = std.ArrayList(Constraint).empty;
        defer candidates.deinit(self.allocator);
        for (self.graph.nodes.items) |node| {
            if (node.kind != .object or node.discarded or !model.isGroupNode(&node)) continue;
            group_composition.collect(self, &node, &candidates) catch |err| {
                if (err != error.InvalidGroupSplit) return err;
                try self.addValidationDiagnostic(.@"error", null, node.id, node.origin, .{
                    .user_report = .{
                        .code = "InvalidGroupSplit",
                        .message = try self.allocator.dupe(u8, "a split group requires at least two distinct live objects, a horizontal or vertical axis, and finite non-negative spacing and padding"),
                    },
                });
                return err;
            };
        }
        try self.constraints.active.appendSlice(self.allocator, candidates.items);
        self.constraints.default_alignments_collected = true;
    }

    pub fn extendRenderEnv(self: *DocumentState, node_id: NodeId, op: []const u8, key: []const u8, value: []const u8) !void {
        const node = self.getNode(node_id) orelse return error.UnknownNode;
        for (node.render_env.items) |entry| {
            if (std.mem.eql(u8, entry.op, op) and
                std.mem.eql(u8, entry.key, key) and
                std.mem.eql(u8, entry.value, value))
            {
                return;
            }
        }
        try node.render_env.append(self.allocator, .{
            .op = try self.allocator.dupe(u8, op),
            .key = try self.allocator.dupe(u8, key),
            .value = try self.allocator.dupe(u8, value),
        });
    }

    pub fn getNodeField(self: *DocumentState, node_id: NodeId, key: []const u8) ?Value {
        const node = self.getNode(node_id) orelse return null;
        return nodeField(node, key);
    }

    fn clearNodeContentProvenance(self: *DocumentState, node: *Node) void {
        for (node.content_provenance.items) |*entry| entry.deinit(self.allocator);
        node.content_provenance.clearRetainingCapacity();
    }

    pub fn setNodeContent(self: *DocumentState, node_id: NodeId, value: []const u8) !void {
        const node = self.getNode(node_id) orelse return error.UnknownNode;
        if (node.content != null) return error.DuplicateContentDefinition;
        const owned_value = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(owned_value);
        const provenance = self.stringProvenance(value);
        var owned_provenance = try self.cloneProvenanceList(provenance);
        errdefer self.deinitProvenanceList(&owned_provenance);
        try self.setStringProvenance(owned_value, owned_provenance.items);
        if (node.content_owned) {
            if (node.content) |content| self.allocator.free(content);
        }
        self.clearNodeContentProvenance(node);
        node.content = owned_value;
        node.content_owned = true;
        node.content_provenance = owned_provenance;
    }

    pub fn setNodeDisplayContent(self: *DocumentState, node_id: NodeId, value: []const u8) !void {
        const node = self.getNode(node_id) orelse return error.UnknownNode;
        const owned_value = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(owned_value);
        const provenance = self.stringProvenance(value);
        var owned_provenance = try self.cloneProvenanceList(provenance);
        errdefer self.deinitProvenanceList(&owned_provenance);
        try self.setStringProvenance(owned_value, owned_provenance.items);
        if (node.display_content_owned) {
            if (node.display_content) |content| self.allocator.free(content);
        }
        for (node.display_content_provenance.items) |*entry| entry.deinit(self.allocator);
        node.display_content_provenance.clearRetainingCapacity();
        node.display_content = owned_value;
        node.display_content_owned = true;
        node.display_content_provenance = owned_provenance;
    }

    pub fn setNodeReprFunction(self: *DocumentState, node_id: NodeId, function: FunctionRef) !void {
        const node = self.getNode(node_id) orelse return error.UnknownNode;
        if (node.repr_function != null) return error.DuplicateReprDefinition;
        node.repr_function = function;
    }

    fn makeNodeWithOrigin(
        self: *DocumentState,
        page_id: NodeId,
        attached: bool,
        kind: NodeKind,
        name: []const u8,
        role: ?Role,
        object_kind: ObjectKind,
        payload_kind: PayloadKind,
        content: ?[]const u8,
        origin: ?model.SourceOrigin,
    ) !NodeId {
        const obj_id = try self.freshId();
        const owned_name = try self.copyString(name);
        const owned_role = try self.copyOptionalString(role);
        const owned_content = try self.copyOptionalString(content);
        const owned_origin = if (origin) |value| try self.copyOrigin(value) else null;
        var content_provenance = if (content) |value|
            try self.cloneProvenanceList(self.stringProvenance(value))
        else
            std.ArrayList(ContentProvenance).empty;
        var content_provenance_transferred = false;
        errdefer {
            if (!content_provenance_transferred) self.deinitProvenanceList(&content_provenance);
        }
        if (owned_content) |value| try self.setStringProvenance(value, content_provenance.items);
        try self.graph.nodes.append(self.allocator, .{
            .id = obj_id,
            .kind = kind,
            .name = owned_name,
            .attached = attached,
            .role = owned_role,
            .object_kind = object_kind,
            .payload_kind = payload_kind,
            .content = owned_content,
            .origin = owned_origin,
            .content_provenance = content_provenance,
        });
        content_provenance_transferred = true;
        if (attached) {
            self.getNode(obj_id).?.composition_order = self.nextCompositionOrder();
            try self.addContainment(page_id, obj_id);
            if (kind == .object) try self.addPagePlacementRoot(page_id, obj_id);
        }
        return obj_id;
    }

    pub fn addObjectSource(
        self: *DocumentState,
        node_id: NodeId,
        page_id: NodeId,
        module_id: SourceModuleId,
        path: []const u8,
        binding_base: ?[]const u8,
        span: ast.Span,
    ) !void {
        try self.source_map.objects.append(self.allocator, .{
            .node_id = node_id,
            .page_id = page_id,
            .module_id = module_id,
            .path = try self.copyString(path),
            .binding_base = if (binding_base) |base| try self.copyString(base) else null,
            .span_start = span.start,
            .span_end = span.end,
        });
    }

    pub fn addPageSource(
        self: *DocumentState,
        page_id: NodeId,
        module_id: SourceModuleId,
        path: []const u8,
        span: ast.Span,
    ) !void {
        try self.source_map.pages.append(self.allocator, .{
            .page_id = page_id,
            .module_id = module_id,
            .path = try self.copyString(path),
            .span_start = span.start,
            .span_end = span.end,
        });
    }

    fn addLayoutDiagnostic(self: *DocumentState, severity: DiagnosticSeverity, page_id: NodeId, node_id: ?NodeId, data: Diagnostic.Data) !void {
        const origin = if (node_id) |id| blk: {
            const node = self.getNode(id) orelse break :blk null;
            break :blk node.origin;
        } else null;
        var diagnostic = Diagnostic{
            .phase = .layout,
            .severity = severity,
            .page_id = page_id,
            .node_id = node_id,
            .origin = null,
            .data = data,
        };
        errdefer diagnostic.deinit(self.allocator);
        if (origin) |value| diagnostic.origin = try value.clone(self.allocator);
        try self.diagnostics.addDiagnostic(self.allocator, diagnostic);
    }

    pub fn addLayoutWarning(self: *DocumentState, page_id: NodeId, node_id: ?NodeId, data: Diagnostic.Data) !void {
        try self.addLayoutDiagnostic(.warning, page_id, node_id, data);
    }

    pub fn addLayoutError(self: *DocumentState, page_id: NodeId, node_id: ?NodeId, data: Diagnostic.Data) !void {
        try self.addLayoutDiagnostic(.@"error", page_id, node_id, data);
    }

    pub fn addValidationDiagnostic(
        self: *DocumentState,
        severity: DiagnosticSeverity,
        page_id: ?NodeId,
        node_id: ?NodeId,
        origin: ?model.SourceOrigin,
        data: Diagnostic.Data,
    ) !void {
        var diagnostic = Diagnostic{
            .phase = .validation,
            .severity = severity,
            .page_id = page_id,
            .node_id = node_id,
            .origin = null,
            .data = data,
        };
        errdefer diagnostic.deinit(self.allocator);
        if (origin) |value| diagnostic.origin = try value.clone(self.allocator);
        try self.diagnostics.addDiagnostic(self.allocator, diagnostic);
    }

    pub fn addRenderDiagnostic(
        self: *DocumentState,
        severity: DiagnosticSeverity,
        page_id: ?NodeId,
        node_id: ?NodeId,
        origin: ?model.SourceOrigin,
        data: Diagnostic.Data,
    ) !void {
        var diagnostic = Diagnostic{
            .phase = .render,
            .severity = severity,
            .page_id = page_id,
            .node_id = node_id,
            .origin = null,
            .data = data,
        };
        errdefer diagnostic.deinit(self.allocator);
        if (origin) |value| diagnostic.origin = try value.clone(self.allocator);
        try self.diagnostics.addDiagnostic(self.allocator, diagnostic);
    }

    pub fn validatePageLocalLayout(self: *DocumentState) !void {
        try self.addPageOwnershipDiagnostics();
        for (self.constraints.active.items) |constraint| {
            try self.addConstraintEndpointOwnershipDiagnostics(constraint);
            try self.addCrossPageConstraintDiagnosticIfKnown(constraint);
        }
    }

    fn addPageOwnershipDiagnostics(self: *DocumentState) !void {
        for (self.graph.nodes.items) |node| {
            if (node.kind != .object or node.discarded) continue;
            const ownership = self.directPageOwnershipInfo(node.id);
            if (ownership.count > 1) {
                const role = node.role orelse node.name;
                const message = try std.fmt.allocPrint(self.allocator, "object '{s}' belongs to multiple pages", .{role});
                try self.addValidationDiagnostic(.@"error", null, node.id, node.origin, .{
                    .user_report = .{ .code = "PageOwnershipConflict", .message = message },
                });
            } else if (node.attached and ownership.count == 0) {
                const role = node.role orelse node.name;
                const message = try std.fmt.allocPrint(self.allocator, "attached object '{s}' is not contained by a page", .{role});
                try self.addValidationDiagnostic(.@"error", null, node.id, node.origin, .{
                    .user_report = .{ .code = "PageOwnershipConflict", .message = message },
                });
            }
        }
    }

    fn directPageOwnershipInfo(self: *DocumentState, child_id: NodeId) PageOwnershipInfo {
        if (child_id == 0) return .{};
        const child_index: usize = @intCast(child_id - 1);
        if (child_index >= self.graph.direct_page_ownership.items.len) return .{};
        return self.graph.direct_page_ownership.items[child_index];
    }

    pub fn layoutPageOf(self: *DocumentState, node_id: NodeId) ?NodeId {
        return self.layoutPageOfReference(node_id, self.graph.nodes.items.len);
    }

    fn layoutPageOfReference(self: *DocumentState, node_id: NodeId, remaining_nodes: usize) ?NodeId {
        if (remaining_nodes == 0) return null;
        const direct = self.directPageOwnershipInfo(node_id);
        if (direct.count == 1) return direct.first;
        if (direct.count > 1) return null;
        const node = self.getNode(node_id) orelse return null;
        if (!roleEq(node.role, GroupRole)) return null;
        // A group can describe the bounds of already placed children without
        // itself becoming a drawing object or a page placement root.
        return self.uniqueAttachedDescendantPage(node_id, remaining_nodes - 1);
    }

    fn uniqueAttachedDescendantPage(self: *DocumentState, node_id: NodeId, remaining_nodes: usize) ?NodeId {
        var result: ?NodeId = null;
        const children = self.childrenOf(node_id) orelse return null;
        for (children) |child_id| {
            const child = self.getNode(child_id) orelse continue;
            if (child.kind != .object or child.discarded) continue;
            // Unknown ownership must propagate: a partially placed or
            // cross-page subtree cannot acquire a page from another sibling.
            const page_id = self.layoutPageOfReference(child_id, remaining_nodes) orelse return null;
            if (result) |existing| {
                if (existing != page_id) return null;
            } else {
                result = page_id;
            }
        }
        return result;
    }

    fn addCrossPageConstraintDiagnosticIfKnown(self: *DocumentState, constraint: Constraint) !void {
        const target_page = self.layoutPageOf(constraint.target_node) orelse return;
        const source_page = switch (constraint.source) {
            .page => constraint.page_id orelse target_page,
            .node => |source| self.layoutPageOf(source.node_id) orelse return,
        };
        const registered_page = constraint.page_id orelse target_page;
        if (target_page == source_page and target_page == registered_page) return;
        if (self.hasCrossPageConstraintDiagnostic(constraint)) return;

        const target_node = self.getNode(constraint.target_node);
        const target_role = if (target_node) |node| node.role orelse node.name else "unknown";
        const message = try std.fmt.allocPrint(
            self.allocator,
            "constraint target object '{s}' belongs to page {d}, source belongs to page {d}, and registration belongs to page {d}",
            .{ target_role, self.pageIndexOf(target_page), self.pageIndexOf(source_page), self.pageIndexOf(registered_page) },
        );
        try self.addValidationDiagnostic(.@"error", target_page, constraint.target_node, constraint.origin, .{
            .user_report = .{ .code = "CrossPageConstraint", .message = message },
        });
    }

    fn addConstraintEndpointOwnershipDiagnostics(self: *DocumentState, constraint: Constraint) !void {
        try self.addConstraintEndpointOwnershipDiagnostic(constraint.target_node, "target", constraint.origin);
        switch (constraint.source) {
            .page => {},
            .node => |source| try self.addConstraintEndpointOwnershipDiagnostic(source.node_id, "source", constraint.origin),
        }
    }

    fn addConstraintEndpointOwnershipDiagnostic(self: *DocumentState, node_id: NodeId, role: []const u8, origin: ?model.SourceOrigin) !void {
        if (self.layoutPageOf(node_id) != null) return;
        const ownership = self.directPageOwnershipInfo(node_id);
        if (ownership.count > 1) return;
        const node = self.getNode(node_id) orelse return;
        if (node.kind != .object or node.discarded) return;
        if (self.hasUnownedLayoutObjectDiagnostic(node_id, origin)) return;
        const node_role = node.role orelse node.name;
        const message = try std.fmt.allocPrint(
            self.allocator,
            "constraint {s} object '{s}' does not belong to a page",
            .{ role, node_role },
        );
        try self.addValidationDiagnostic(.@"error", null, node_id, origin orelse node.origin, .{
            .user_report = .{ .code = "UnownedLayoutObject", .message = message },
        });
    }

    fn hasUnownedLayoutObjectDiagnostic(self: *DocumentState, node_id: NodeId, origin: ?model.SourceOrigin) bool {
        for (self.diagnostics.entries.items) |diagnostic| {
            if (diagnostic.phase != .validation or diagnostic.node_id != node_id) continue;
            switch (diagnostic.data) {
                .user_report => |data| {
                    if (!std.mem.eql(u8, data.code, "UnownedLayoutObject")) continue;
                    if (origin == null) return true;
                    if (diagnostic.origin == null) continue;
                    if (origin.?.eql(diagnostic.origin.?)) return true;
                },
                else => {},
            }
        }
        return false;
    }

    fn hasCrossPageConstraintDiagnostic(self: *DocumentState, constraint: Constraint) bool {
        for (self.diagnostics.entries.items) |diagnostic| {
            if (diagnostic.phase != .validation or diagnostic.node_id != constraint.target_node) continue;
            switch (diagnostic.data) {
                .user_report => |data| {
                    if (!std.mem.eql(u8, data.code, "CrossPageConstraint")) continue;
                    if (constraint.origin == null and diagnostic.origin == null) return true;
                    if (constraint.origin == null or diagnostic.origin == null) continue;
                    if (constraint.origin.?.eql(diagnostic.origin.?)) return true;
                },
                else => {},
            }
        }
        return false;
    }

    pub fn getNode(self: *DocumentState, id: NodeId) ?*Node {
        if (id != 0) {
            const index: usize = @intCast(id - 1);
            if (index < self.graph.nodes.items.len and self.graph.nodes.items[index].id == id) {
                return &self.graph.nodes.items[index];
            }
        }
        for (self.graph.nodes.items) |*node| {
            if (node.id == id) return node;
        }
        return null;
    }

    pub fn childrenOf(self: *DocumentState, parent: NodeId) ?[]const NodeId {
        const children = self.graph.contains.get(parent) orelse return null;
        return children.items;
    }

    pub fn placementRootsOf(self: *DocumentState, page_id: NodeId) []const NodeId {
        const roots = self.graph.page_placement_roots.get(page_id) orelse return &.{};
        return roots.items;
    }

    pub fn pageIndexOf(self: *DocumentState, page_id: NodeId) usize {
        const node = self.getNode(page_id) orelse unreachable;
        return node.page_index.?;
    }

    pub fn pageCount(self: *DocumentState) usize {
        return self.graph.page_order.items.len;
    }

    pub fn parentPageOf(self: *DocumentState, child_id: NodeId) ?NodeId {
        return self.directPageOwnershipInfo(child_id).first;
    }

    fn previousPageOf(self: *DocumentState, page_id: NodeId) ?NodeId {
        for (self.graph.page_order.items, 0..) |candidate, index| {
            if (candidate != page_id) continue;
            if (index == 0) return null;
            return self.graph.page_order.items[index - 1];
        }
        return null;
    }

    fn ensureValueTag(self: *DocumentState, value: Value, expected: ValueTag, context: []const u8) !void {
        _ = self;
        const actual: ValueTag = switch (value) {
            .none => .none,
            .document => .document,
            .page => .page,
            .object => .object,
            .selection => .selection,
            .anchor => .anchor,
            .function => .function,
            .string => .string,
            .enum_case => .enum_case,
            .record => .record,
            .group => .group,
            .path => .path,
            .number => .number,
            .boolean => .boolean,
            .constraints => .constraints,
            .void => .void,
        };
        if (actual != expected) {
            std.debug.print("runtime value type mismatch in {s}: expected {s}, got {s}\n", .{
                context,
                @tagName(expected),
                @tagName(actual),
            });
            return error.InvalidValueTag;
        }
    }

    fn singletonSelection(
        self: *DocumentState,
        allocator: Allocator,
        item_tag: SelectionItemTag,
        provenance: []const u8,
        id: NodeId,
    ) !Selection {
        _ = self;
        var selection = Selection.init(item_tag, provenance);
        try selection.ids.append(allocator, id);
        return selection;
    }

    fn selectPageObjectsByRole(
        self: *DocumentState,
        allocator: Allocator,
        page_id: NodeId,
        role: Role,
        provenance: []const u8,
    ) !Selection {
        var selection = Selection.init(.object, provenance);
        const children = self.graph.contains.get(page_id) orelse return selection;
        for (children.items) |child_id| {
            const node = self.getNode(child_id) orelse continue;
            if (roleEq(node.role, role)) {
                try selection.ids.append(allocator, child_id);
            }
        }
        return selection;
    }

    fn selectDocumentObjectsByRole(
        self: *DocumentState,
        allocator: Allocator,
        role: Role,
        provenance: []const u8,
    ) !Selection {
        var selection = Selection.init(.object, provenance);
        for (self.graph.page_order.items) |page_id| {
            var page_selection = try self.selectPageObjectsByRole(allocator, page_id, role, provenance);
            defer page_selection.deinit(allocator);
            for (page_selection.ids.items) |id| {
                try selection.ids.append(allocator, id);
            }
        }
        return selection;
    }

    fn selectDocumentPages(self: *DocumentState, allocator: Allocator, provenance: []const u8) !Selection {
        var selection = Selection.init(.page, provenance);
        for (self.graph.page_order.items) |page_id| {
            try selection.ids.append(allocator, page_id);
        }
        return selection;
    }

    fn selectChildren(self: *DocumentState, allocator: Allocator, parent_id: NodeId, provenance: []const u8) !Selection {
        var selection = Selection.init(.object, provenance);
        errdefer selection.deinit(allocator);
        for (self.childrenOf(parent_id) orelse &.{}) |child_id| {
            const child = self.getNode(child_id) orelse return error.UnknownNode;
            if (child.placement == null) return error.InvalidSelectionScope;
            if (!child.discarded) try selection.ids.append(allocator, child_id);
        }
        return selection;
    }

    fn selectDescendants(self: *DocumentState, allocator: Allocator, parent_id: NodeId, provenance: []const u8) !Selection {
        var selection = Selection.init(.object, provenance);
        errdefer selection.deinit(allocator);
        try self.appendMatchingPlacements(allocator, self.childrenOf(parent_id) orelse &.{}, null, null, &selection.ids);
        return selection;
    }

    pub fn select(self: *DocumentState, allocator: Allocator, base: Value, query: Query) !Value {
        try self.ensureValueTag(base, query.input, query.name);
        switch (query.op) {
            .self_placement, .children, .descendants => {
                const node = self.getNode(base.object) orelse return error.UnknownNode;
                if (node.placement == null or node.discarded) return error.InvalidSelectionScope;
            },
            else => {},
        }

        return switch (query.op) {
            .self_object, .self_placement => .{
                .selection = try self.singletonSelection(allocator, .object, query.name, base.object),
            },
            .previous_page => if (self.previousPageOf(base.page)) |page_id| .{ .page = page_id } else .none,
            .parent_page => if (self.parentPageOf(base.object)) |page_id| .{ .page = page_id } else .none,
            .children => .{
                .selection = try self.selectChildren(allocator, base.object, query.name),
            },
            .descendants => .{
                .selection = try self.selectDescendants(allocator, base.object, query.name),
            },
            .page_objects_by_role => |role| .{
                .selection = try self.selectPageObjectsByRole(allocator, base.page, role, query.name),
            },
            .document_objects_by_role => |role| .{
                .selection = try self.selectDocumentObjectsByRole(allocator, role, query.name),
            },
            .document_pages => .{
                .selection = try self.selectDocumentPages(allocator, query.name),
            },
        };
    }

    /// Search registered input values in document construction order. The
    /// execution graph has already waited for every relevant producer.
    pub fn selectTypedPlacements(self: *DocumentState, allocator: Allocator, scope: Value, input: ast.Type) !Selection {
        if (input.kind != .record and input.kind != .group) return error.InvalidSelectionType;
        var result = Selection.init(.object, "typed placements");
        errdefer result.deinit(allocator);
        switch (scope) {
            .document => |id| {
                if (id != self.graph.document_id) return error.InvalidSelectionScope;
                for (self.graph.page_order.items) |page| {
                    try self.appendMatchingPlacements(allocator, self.placementRootsOf(page), input, null, &result.ids);
                }
            },
            .page => |id| {
                const node = self.getNode(id) orelse return error.UnknownNode;
                if (node.kind != .page) return error.InvalidSelectionScope;
                try self.appendMatchingPlacements(allocator, self.placementRootsOf(id), input, null, &result.ids);
            },
            .object => |id| {
                const node = self.getNode(id) orelse return error.UnknownNode;
                if (node.placement == null) return error.InvalidSelectionScope;
                try self.appendMatchingPlacements(allocator, self.childrenOf(id) orelse &.{}, input, null, &result.ids);
            },
            else => return error.InvalidSelectionScope,
        }
        return result;
    }

    /// Set algebra must not make operand order determine numbering order.
    /// Legacy unattached objects retain their old ordering during migration.
    pub fn orderSelection(self: *DocumentState, allocator: Allocator, selection: *Selection) !void {
        if (selection.ids.items.len < 2) return;
        for (selection.ids.items) |id| {
            const node = self.getNode(id) orelse return error.UnknownNode;
            if (selection.item_tag == .object and node.placement == null) return;
            if (selection.item_tag == .page and node.kind != .page) return error.InvalidSelectionScope;
        }
        var wanted = std.AutoHashMap(NodeId, void).init(allocator);
        defer wanted.deinit();
        for (selection.ids.items) |id| try wanted.put(id, {});
        var ordered = std.ArrayList(NodeId).empty;
        errdefer ordered.deinit(allocator);
        try ordered.ensureTotalCapacity(allocator, wanted.count());
        for (self.graph.page_order.items) |page| {
            if (selection.item_tag == .page) {
                if (wanted.contains(page)) try ordered.append(allocator, page);
            } else try self.appendMatchingPlacements(allocator, self.placementRootsOf(page), null, &wanted, &ordered);
        }
        if (ordered.items.len != wanted.count()) return error.InvalidSelectionScope;
        selection.ids.deinit(allocator);
        selection.ids = ordered;
    }

    fn appendMatchingPlacements(
        self: *DocumentState,
        allocator: Allocator,
        roots: []const NodeId,
        input: ?ast.Type,
        wanted: ?*const std.AutoHashMap(NodeId, void),
        result: *std.ArrayList(NodeId),
    ) !void {
        var pending = std.ArrayList(NodeId).empty;
        defer pending.deinit(allocator);
        try pending.appendSlice(allocator, roots);
        std.mem.reverse(NodeId, pending.items);
        while (pending.pop()) |id| {
            const node = self.getNode(id) orelse return error.UnknownNode;
            const placement = node.placement orelse return error.InvalidSelectionScope;
            if (node.discarded) continue;
            const matches = if (input) |ty|
                if (placement.value.presentationType()) |actual| ast.Type.eql(actual, ty) else false
            else if (wanted) |ids| ids.contains(id) else true;
            if (matches) try result.append(allocator, id);
            const children = self.childrenOf(id) orelse continue;
            const start = pending.items.len;
            try pending.appendSlice(allocator, children);
            std.mem.reverse(NodeId, pending.items[start..]);
        }
    }
};
