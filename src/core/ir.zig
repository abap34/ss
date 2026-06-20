const std = @import("std");
const model = @import("model");
const layout = @import("layout.zig");
const ast = @import("ast");

const Allocator = model.Allocator;
const NodeId = model.NodeId;
const Node = model.Node;
const NodeKind = model.NodeKind;
const Role = model.Role;
const ObjectKind = model.ObjectKind;
const PayloadKind = model.PayloadKind;
const Anchor = model.Anchor;
const Constraint = model.Constraint;
const ConstraintSet = model.ConstraintSet;
const ContentProvenance = model.ContentProvenance;
const ConstraintSource = model.ConstraintSource;
const Selection = model.Selection;
const SelectionItemTag = model.SelectionItemTag;
const ValueTag = model.ValueTag;
const Value = model.Value;
const Query = model.Query;
const PageLayout = model.PageLayout;
const Diagnostic = model.Diagnostic;
const DiagnosticPhase = model.DiagnosticPhase;
const DiagnosticSeverity = model.DiagnosticSeverity;
const ConstraintFailure = model.ConstraintFailure;
const ConstraintFailureKind = model.ConstraintFailureKind;
const GroupRole = model.GroupRole;
const roleEq = model.roleEq;
const nodeProperty = model.nodeProperty;

pub const SourceModuleId = u32;

pub const FunctionKey = struct {
    module_id: SourceModuleId,
    name: []const u8,

    pub fn eql(left: FunctionKey, right: FunctionKey) bool {
        return left.module_id == right.module_id and std.mem.eql(u8, left.name, right.name);
    }
};

pub const FunctionKeyContext = struct {
    pub fn hash(_: FunctionKeyContext, key: FunctionKey) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(std.mem.asBytes(&key.module_id));
        hasher.update(key.name);
        return hasher.final();
    }

    pub fn eql(_: FunctionKeyContext, left: FunctionKey, right: FunctionKey) bool {
        return left.eql(right);
    }
};

pub const FunctionMap = std.HashMap(FunctionKey, ast.FunctionDecl, FunctionKeyContext, std.hash_map.default_max_load_percentage);
pub const ConstMap = std.HashMap(FunctionKey, ast.ConstDecl, FunctionKeyContext, std.hash_map.default_max_load_percentage);
pub const ConstValueMap = std.HashMap(FunctionKey, Value, FunctionKeyContext, std.hash_map.default_max_load_percentage);
pub const ConstEvalStateMap = std.HashMap(FunctionKey, u8, FunctionKeyContext, std.hash_map.default_max_load_percentage);

pub fn functionKey(module_id: SourceModuleId, name: []const u8) FunctionKey {
    return .{ .module_id = module_id, .name = name };
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
    program: ast.Program,
    implicit_import_ids: std.ArrayList(SourceModuleId),
    resolved_import_ids: std.ArrayList(SourceModuleId),

    pub fn deinit(self: *SourceModule, allocator: Allocator) void {
        self.program.deinit(allocator);
        self.implicit_import_ids.deinit(allocator);
        self.resolved_import_ids.deinit(allocator);
        allocator.free(self.spec);
        allocator.free(self.source);
        if (self.path) |path| allocator.free(path);
    }
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

pub const InlayHintKind = enum {
    parameter_names,
    solved_frame,
};

pub const InlayHint = struct {
    line: usize,
    column: usize,
    label: []const u8,
    kind: InlayHintKind,
    module_id: SourceModuleId,
    file: ?[]const u8 = null,
};

pub const Ir = struct {
    allocator: Allocator,
    asset_base_dir: []u8,
    modules: std.ArrayList(SourceModule),
    module_order: std.ArrayList(SourceModuleId),
    project_module_id: SourceModuleId,
    constants: ConstMap,
    const_values: ConstValueMap,
    const_eval_states: ConstEvalStateMap,
    functions: FunctionMap,
    definitions: std.ArrayList(Definition),
    hints: std.ArrayList(InlayHint),
    nodes: std.ArrayList(Node),
    page_order: std.ArrayList(NodeId),
    contains: std.AutoHashMap(NodeId, std.ArrayList(NodeId)),
    constraints: std.ArrayList(Constraint),
    diagnostics: std.ArrayList(Diagnostic),
    last_constraint_failure: ?ConstraintFailure,
    constraint_failures: std.ArrayList(ConstraintFailure),
    runtime_strings: std.ArrayList([]u8),
    string_provenance: std.AutoHashMap(usize, std.ArrayList(ContentProvenance)),
    next_id: NodeId,
    document_id: NodeId,

    pub fn init(
        allocator: Allocator,
        asset_base_dir: []u8,
        project_path: []u8,
        project_source: []u8,
        project_program: ast.Program,
    ) !Ir {
        var ir = Ir{
            .allocator = allocator,
            .asset_base_dir = asset_base_dir,
            .modules = .empty,
            .module_order = .empty,
            .project_module_id = 0,
            .constants = ConstMap.init(allocator),
            .const_values = ConstValueMap.init(allocator),
            .const_eval_states = ConstEvalStateMap.init(allocator),
            .functions = FunctionMap.init(allocator),
            .definitions = .empty,
            .hints = std.ArrayList(InlayHint).empty,
            .nodes = .empty,
            .page_order = .empty,
            .contains = std.AutoHashMap(NodeId, std.ArrayList(NodeId)).init(allocator),
            .constraints = .empty,
            .diagnostics = .empty,
            .last_constraint_failure = null,
            .constraint_failures = .empty,
            .runtime_strings = .empty,
            .string_provenance = std.AutoHashMap(usize, std.ArrayList(ContentProvenance)).init(allocator),
            .next_id = 1,
            .document_id = 0,
        };
        errdefer ir.deinitPartial();

        const project_spec = try allocator.dupe(u8, project_path);
        errdefer allocator.free(project_spec);

        const doc_id = try ir.freshId();
        try ir.nodes.append(allocator, .{
            .id = doc_id,
            .kind = .document,
            .name = "document",
            .attached = true,
        });
        ir.document_id = doc_id;

        try ir.modules.append(allocator, .{
            .id = 0,
            .kind = .project,
            .spec = project_spec,
            .path = project_path,
            .source = project_source,
            .program = project_program,
            .implicit_import_ids = .empty,
            .resolved_import_ids = .empty,
        });

        return ir;
    }

    fn deinitPartial(self: *Ir) void {
        self.modules.deinit(self.allocator);
        self.module_order.deinit(self.allocator);
        self.constants.deinit();
        {
            var iterator = self.const_values.valueIterator();
            while (iterator.next()) |value| value.deinit(self.allocator);
        }
        self.const_values.deinit();
        self.const_eval_states.deinit();
        self.functions.deinit();
        self.definitions.deinit(self.allocator);
        self.hints.deinit(self.allocator);
        self.contains.deinit();
        for (self.nodes.items) |*node| node.deinit(self.allocator);
        self.nodes.deinit(self.allocator);
        self.page_order.deinit(self.allocator);
        self.constraints.deinit(self.allocator);
        self.diagnostics.deinit(self.allocator);
        self.constraint_failures.deinit(self.allocator);
        self.deinitStringProvenance();
        self.runtime_strings.deinit(self.allocator);
    }

    pub fn deinit(self: *Ir) void {
        for (self.modules.items) |*module| module.deinit(self.allocator);
        self.modules.deinit(self.allocator);
        self.module_order.deinit(self.allocator);
        self.constants.deinit();
        {
            var iterator = self.const_values.valueIterator();
            while (iterator.next()) |value| value.deinit(self.allocator);
        }
        self.const_values.deinit();
        self.const_eval_states.deinit();
        self.functions.deinit();
        for (self.definitions.items) |definition| {
            self.allocator.free(definition.name);
            if (definition.file) |file| self.allocator.free(file);
            if (definition.scope_name) |scope_name| self.allocator.free(scope_name);
        }
        self.definitions.deinit(self.allocator);
        for (self.hints.items) |hint| self.allocator.free(hint.label);
        self.hints.deinit(self.allocator);
        self.allocator.free(self.asset_base_dir);
        var it = self.contains.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.contains.deinit();
        for (self.nodes.items) |*node| {
            node.deinit(self.allocator);
        }
        self.nodes.deinit(self.allocator);
        self.page_order.deinit(self.allocator);
        self.constraints.deinit(self.allocator);
        self.clearDiagnostics();
        self.diagnostics.deinit(self.allocator);
        self.constraint_failures.deinit(self.allocator);
        self.deinitStringProvenance();
        for (self.runtime_strings.items) |text| self.allocator.free(text);
        self.runtime_strings.deinit(self.allocator);
    }

    fn deinitStringProvenance(self: *Ir) void {
        var iterator = self.string_provenance.valueIterator();
        while (iterator.next()) |entries| self.deinitProvenanceList(entries);
        self.string_provenance.deinit();
    }

    fn stringKey(text: []const u8) usize {
        return @intFromPtr(text.ptr);
    }

    fn deinitProvenanceList(self: *Ir, entries: *std.ArrayList(ContentProvenance)) void {
        for (entries.items) |*entry| entry.deinit(self.allocator);
        entries.deinit(self.allocator);
    }

    fn cloneProvenanceList(self: *Ir, entries: []const ContentProvenance) !std.ArrayList(ContentProvenance) {
        var cloned = std.ArrayList(ContentProvenance).empty;
        errdefer self.deinitProvenanceList(&cloned);
        for (entries) |entry| {
            try cloned.append(self.allocator, try entry.clone(self.allocator));
        }
        return cloned;
    }

    pub fn setStringProvenance(self: *Ir, text: []const u8, entries: []const ContentProvenance) !void {
        if (text.len == 0 or entries.len == 0) return;
        var cloned = try self.cloneProvenanceList(entries);
        errdefer self.deinitProvenanceList(&cloned);
        const gop = try self.string_provenance.getOrPut(stringKey(text));
        if (gop.found_existing) self.deinitProvenanceList(gop.value_ptr);
        gop.value_ptr.* = cloned;
    }

    pub fn stringProvenance(self: *const Ir, text: []const u8) []const ContentProvenance {
        if (text.len == 0) return &.{};
        const entries = self.string_provenance.get(stringKey(text)) orelse return &.{};
        return entries.items;
    }

    pub fn ownString(self: *Ir, text: []u8) ![]const u8 {
        errdefer self.allocator.free(text);
        try self.runtime_strings.append(self.allocator, text);
        return text;
    }

    pub fn ownStringWithProvenance(self: *Ir, text: []u8, entries: []const ContentProvenance) ![]const u8 {
        errdefer self.allocator.free(text);
        try self.runtime_strings.append(self.allocator, text);
        var appended = true;
        errdefer {
            if (appended) _ = self.runtime_strings.pop();
        }
        try self.setStringProvenance(text, entries);
        appended = false;
        return text;
    }

    pub fn copyString(self: *Ir, text: []const u8) ![]const u8 {
        return self.ownString(try self.allocator.dupe(u8, text));
    }

    fn copyOptionalString(self: *Ir, text: ?[]const u8) !?[]const u8 {
        return if (text) |value| try self.copyString(value) else null;
    }

    pub fn projectPath(self: *const Ir) []const u8 {
        return self.projectModule().path orelse "";
    }

    pub fn projectSource(self: *const Ir) []const u8 {
        return self.projectModule().source;
    }

    pub fn projectProgram(self: *const Ir) ast.Program {
        return self.projectModule().program;
    }

    pub fn projectModule(self: *const Ir) *const SourceModule {
        return self.moduleById(self.project_module_id).?;
    }

    pub fn moduleById(self: *const Ir, id: SourceModuleId) ?*const SourceModule {
        for (self.modules.items) |*module| {
            if (module.id == id) return module;
        }
        return null;
    }

    pub fn moduleByPathOrSpec(self: *const Ir, key: []const u8) ?*const SourceModule {
        for (self.modules.items) |*module| {
            if (module.path) |module_path| {
                if (std.mem.eql(u8, module_path, key)) return module;
            }
            if (std.mem.eql(u8, module.spec, key)) return module;
        }
        return null;
    }

    pub fn projectModuleMutable(self: *Ir) *SourceModule {
        return self.moduleByIdMutable(self.project_module_id).?;
    }

    pub fn moduleByIdMutable(self: *Ir, id: SourceModuleId) ?*SourceModule {
        for (self.modules.items) |*module| {
            if (module.id == id) return module;
        }
        return null;
    }

    pub fn modulePath(self: *const Ir, id: SourceModuleId) ?[]const u8 {
        const module = self.moduleById(id) orelse return null;
        return module.path;
    }

    fn freshId(self: *Ir) !NodeId {
        const id = self.next_id;
        self.next_id += 1;
        return id;
    }

    pub fn nodeCount(self: *const Ir) usize {
        return self.nodes.items.len;
    }

    pub fn addContainment(self: *Ir, parent: NodeId, child: NodeId) !void {
        const gop = try self.contains.getOrPut(parent);
        if (!gop.found_existing) {
            gop.value_ptr.* = .empty;
        }
        for (gop.value_ptr.items) |existing| {
            if (existing == child) return;
        }
        try gop.value_ptr.append(self.allocator, child);
    }

    pub fn addPage(self: *Ir, name: []const u8) !NodeId {
        const page_id = try self.freshId();
        const index = self.page_order.items.len + 1;
        const owned_name = try self.copyString(name);
        try self.nodes.append(self.allocator, .{
            .id = page_id,
            .kind = .page,
            .name = owned_name,
            .attached = true,
            .page_index = index,
        });
        try self.page_order.append(self.allocator, page_id);
        try self.addContainment(self.document_id, page_id);
        return page_id;
    }

    pub fn makeObject(
        self: *Ir,
        page_id: NodeId,
        name: []const u8,
        role: ?Role,
        object_kind: ObjectKind,
        payload_kind: PayloadKind,
        content: ?[]const u8,
    ) !NodeId {
        return self.makeObjectWithOrigin(page_id, name, role, object_kind, payload_kind, content, null);
    }

    pub fn makeObjectWithOrigin(
        self: *Ir,
        page_id: NodeId,
        name: []const u8,
        role: ?Role,
        object_kind: ObjectKind,
        payload_kind: PayloadKind,
        content: ?[]const u8,
        origin: ?[]const u8,
    ) !NodeId {
        return self.makeNodeWithOrigin(page_id, true, .object, name, role, object_kind, payload_kind, content, origin);
    }

    pub fn createObjectWithOrigin(
        self: *Ir,
        name: []const u8,
        role: ?Role,
        object_kind: ObjectKind,
        payload_kind: PayloadKind,
        content: ?[]const u8,
        origin: ?[]const u8,
    ) !NodeId {
        return self.makeNodeWithOrigin(self.document_id, false, .object, name, role, object_kind, payload_kind, content, origin);
    }

    pub fn makeGroupWithOrigin(
        self: *Ir,
        page_id: NodeId,
        attached: bool,
        children: []const NodeId,
        origin: ?[]const u8,
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
        self: *Ir,
        children: []const NodeId,
        origin: ?[]const u8,
    ) !NodeId {
        return try self.makeGroupWithOrigin(self.document_id, false, children, origin);
    }

    pub fn placeObjectOnPage(self: *Ir, page_id: NodeId, object_id: NodeId) !void {
        var visited = std.AutoHashMap(NodeId, void).init(self.allocator);
        defer visited.deinit();
        try self.placeObjectSubtree(page_id, object_id, &visited);
    }

    fn placeObjectSubtree(self: *Ir, page_id: NodeId, object_id: NodeId, visited: *std.AutoHashMap(NodeId, void)) !void {
        if (visited.contains(object_id)) return;
        try visited.put(object_id, {});
        const node = self.getNode(object_id) orelse return error.UnknownNode;
        if (node.kind != .object) return error.InvalidValueTag;
        node.attached = true;
        node.discarded = false;
        try self.addContainment(page_id, object_id);
        const children = self.childrenOf(object_id) orelse return;
        for (children) |child_id| try self.placeObjectSubtree(page_id, child_id, visited);
    }

    pub fn discardObjectSubtree(self: *Ir, object_id: NodeId) !void {
        var visited = std.AutoHashMap(NodeId, void).init(self.allocator);
        defer visited.deinit();
        try self.discardObjectSubtreeInner(object_id, &visited);
    }

    fn discardObjectSubtreeInner(self: *Ir, object_id: NodeId, visited: *std.AutoHashMap(NodeId, void)) !void {
        if (visited.contains(object_id)) return;
        try visited.put(object_id, {});
        const node = self.getNode(object_id) orelse return error.UnknownNode;
        if (node.kind != .object) return error.InvalidValueTag;
        node.discarded = true;
        const children = self.childrenOf(object_id) orelse return;
        for (children) |child_id| try self.discardObjectSubtreeInner(child_id, visited);
    }

    pub fn connectGeneratedReturnObjects(self: *Ir, return_id: NodeId, start_index: usize) !void {
        const return_node = self.getNode(return_id) orelse return error.UnknownNode;
        if (return_node.kind != .object) return;

        var candidates = std.AutoHashMap(NodeId, void).init(self.allocator);
        defer candidates.deinit();
        try candidates.put(return_id, {});
        if (start_index < self.nodes.items.len) {
            for (self.nodes.items[start_index..]) |node| {
                if (node.kind != .object or node.attached or node.discarded) continue;
                try candidates.put(node.id, {});
            }
        }

        var seen = std.AutoHashMap(NodeId, void).init(self.allocator);
        defer seen.deinit();
        var queue = std.ArrayList(NodeId).empty;
        defer queue.deinit(self.allocator);
        try seen.put(return_id, {});
        try queue.append(self.allocator, return_id);

        var index: usize = 0;
        while (index < queue.items.len) : (index += 1) {
            try self.appendConnectedCandidates(candidates, &seen, &queue, queue.items[index]);
        }

        const page_id = if (return_node.attached) self.parentPageOf(return_id) else null;
        for (queue.items) |candidate_id| {
            if (candidate_id == return_id) continue;
            if (try self.containsDescendant(candidate_id, return_id)) continue;
            try self.addContainment(return_id, candidate_id);
        }
        if (page_id) |page| try self.placeObjectOnPage(page, return_id);
    }

    fn appendConnectedCandidates(
        self: *Ir,
        candidates: std.AutoHashMap(NodeId, void),
        seen: *std.AutoHashMap(NodeId, void),
        queue: *std.ArrayList(NodeId),
        current: NodeId,
    ) !void {
        var containment = self.contains.iterator();
        while (containment.next()) |entry| {
            const parent_id = entry.key_ptr.*;
            for (entry.value_ptr.items) |child_id| {
                if (parent_id == current) try self.appendCandidate(candidates, seen, queue, child_id);
                if (child_id == current) try self.appendCandidate(candidates, seen, queue, parent_id);
            }
        }
        for (self.constraints.items) |constraint| {
            if (constraint.target_node == current) {
                switch (constraint.source) {
                    .page => {},
                    .node => |source| try self.appendCandidate(candidates, seen, queue, source.node_id),
                }
            }
            switch (constraint.source) {
                .page => {},
                .node => |source| if (source.node_id == current) try self.appendCandidate(candidates, seen, queue, constraint.target_node),
            }
        }
    }

    fn appendCandidate(
        self: *Ir,
        candidates: std.AutoHashMap(NodeId, void),
        seen: *std.AutoHashMap(NodeId, void),
        queue: *std.ArrayList(NodeId),
        candidate: NodeId,
    ) !void {
        if (!candidates.contains(candidate) or seen.contains(candidate)) return;
        try seen.put(candidate, {});
        try queue.append(self.allocator, candidate);
    }

    fn containsDescendant(self: *Ir, parent_id: NodeId, child_id: NodeId) !bool {
        var visited = std.AutoHashMap(NodeId, void).init(self.allocator);
        defer visited.deinit();
        return try self.containsDescendantInner(parent_id, child_id, &visited);
    }

    fn containsDescendantInner(self: *Ir, parent_id: NodeId, child_id: NodeId, visited: *std.AutoHashMap(NodeId, void)) !bool {
        if (visited.contains(parent_id)) return false;
        try visited.put(parent_id, {});
        const children = self.childrenOf(parent_id) orelse return false;
        for (children) |candidate| {
            if (candidate == child_id) return true;
            if (try self.containsDescendantInner(candidate, child_id, visited)) return true;
        }
        return false;
    }

    pub fn setNodeProperty(self: *Ir, node_id: NodeId, key: []const u8, value: []const u8) !void {
        const node = self.getNode(node_id) orelse return error.UnknownNode;
        for (node.properties.items) |*property| {
            if (std.mem.eql(u8, property.key, key)) {
                const owned_value = try self.allocator.dupe(u8, value);
                self.allocator.free(property.value);
                property.value = owned_value;
                return;
            }
        }
        try node.properties.append(self.allocator, .{
            .key = try self.allocator.dupe(u8, key),
            .value = try self.allocator.dupe(u8, value),
        });
    }

    pub fn unsetNodeProperty(self: *Ir, node_id: NodeId, key: []const u8) !void {
        const node = self.getNode(node_id) orelse return error.UnknownNode;
        for (node.properties.items, 0..) |property, index| {
            if (std.mem.eql(u8, property.key, key)) {
                self.allocator.free(property.key);
                self.allocator.free(property.value);
                _ = node.properties.orderedRemove(index);
                return;
            }
        }
    }

    pub fn extendRenderEnv(self: *Ir, node_id: NodeId, op: []const u8, key: []const u8, value: []const u8) !void {
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

    pub fn getNodeProperty(self: *Ir, node_id: NodeId, key: []const u8) ?[]const u8 {
        const node = self.getNode(node_id) orelse return null;
        return nodeProperty(node, key);
    }

    fn clearNodeContentProvenance(self: *Ir, node: *Node) void {
        for (node.content_provenance.items) |*entry| entry.deinit(self.allocator);
        node.content_provenance.clearRetainingCapacity();
    }

    fn appendNodeContentProvenance(self: *Ir, out: *std.ArrayList(ContentProvenance), entries: []const ContentProvenance, offset: usize) !void {
        for (entries) |entry| {
            try out.append(self.allocator, try entry.cloneWithOffset(self.allocator, offset));
        }
    }

    pub fn setNodeContent(self: *Ir, node_id: NodeId, value: []const u8) !void {
        const node = self.getNode(node_id) orelse return error.UnknownNode;
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

    pub fn appendNodeContent(self: *Ir, node_id: NodeId, value: []const u8) !void {
        const node = self.getNode(node_id) orelse return error.UnknownNode;
        const current = node.content orelse "";
        var next_provenance = std.ArrayList(ContentProvenance).empty;
        errdefer self.deinitProvenanceList(&next_provenance);
        try self.appendNodeContentProvenance(&next_provenance, node.content_provenance.items, 0);
        try self.appendNodeContentProvenance(&next_provenance, self.stringProvenance(value), current.len);
        const next_content = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ current, value });
        errdefer self.allocator.free(next_content);
        try self.setStringProvenance(next_content, next_provenance.items);
        if (node.content_owned) self.allocator.free(current);
        self.clearNodeContentProvenance(node);
        node.content = next_content;
        node.content_owned = true;
        node.content_provenance = next_provenance;
    }

    fn makeNodeWithOrigin(
        self: *Ir,
        page_id: NodeId,
        attached: bool,
        kind: NodeKind,
        name: []const u8,
        role: ?Role,
        object_kind: ObjectKind,
        payload_kind: PayloadKind,
        content: ?[]const u8,
        origin: ?[]const u8,
    ) !NodeId {
        const obj_id = try self.freshId();
        const owned_name = try self.copyString(name);
        const owned_role = try self.copyOptionalString(role);
        const owned_content = try self.copyOptionalString(content);
        const owned_origin = try self.copyOptionalString(origin);
        var content_provenance = if (content) |value|
            try self.cloneProvenanceList(self.stringProvenance(value))
        else
            std.ArrayList(ContentProvenance).empty;
        var content_provenance_transferred = false;
        errdefer {
            if (!content_provenance_transferred) self.deinitProvenanceList(&content_provenance);
        }
        if (owned_content) |value| try self.setStringProvenance(value, content_provenance.items);
        try self.nodes.append(self.allocator, .{
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
        if (attached) try self.addContainment(page_id, obj_id);
        return obj_id;
    }

    pub fn addConstraint(self: *Ir, expr: []const u8) !void {
        _ = self;
        _ = expr;
        return error.StringConstraintsRemoved;
    }

    pub fn addAnchorConstraint(
        self: *Ir,
        target_node: NodeId,
        target_anchor: Anchor,
        source: ConstraintSource,
        offset: f32,
        origin: ?[]const u8,
    ) !void {
        try self.constraints.append(self.allocator, .{
            .target_node = target_node,
            .target_anchor = target_anchor,
            .source = source,
            .offset = offset,
            .origin = origin,
        });
    }

    pub fn addConstraintSet(self: *Ir, constraints: ConstraintSet) !void {
        try self.constraints.appendSlice(self.allocator, constraints.items.items);
    }

    pub fn noteConstraintFailure(self: *Ir, page_id: NodeId, constraint: Constraint, existing_constraint: ?Constraint, kind: ConstraintFailureKind) void {
        const failure: ConstraintFailure = .{
            .kind = kind,
            .page_id = page_id,
            .constraint = constraint,
            .existing_constraint = existing_constraint,
        };
        self.last_constraint_failure = failure;
        for (self.constraint_failures.items) |existing| {
            if (constraintFailureSame(existing, failure)) return;
        }
        self.constraint_failures.append(self.allocator, failure) catch {};
    }

    pub fn hasConstraintFailures(self: *const Ir) bool {
        return self.constraint_failures.items.len > 0;
    }

    pub fn clearDiagnostics(self: *Ir) void {
        for (self.diagnostics.items) |*diagnostic| diagnostic.deinit(self.allocator);
        self.diagnostics.clearRetainingCapacity();
    }

    pub fn clearDiagnosticsForPhase(self: *Ir, phase: DiagnosticPhase) void {
        var write_index: usize = 0;
        for (self.diagnostics.items) |*diagnostic| {
            if (diagnostic.phase == phase) {
                diagnostic.deinit(self.allocator);
                continue;
            }
            self.diagnostics.items[write_index] = diagnostic.*;
            write_index += 1;
        }
        self.diagnostics.items.len = write_index;
    }

    pub fn addDiagnostic(self: *Ir, diagnostic: Diagnostic) !void {
        try self.diagnostics.append(self.allocator, diagnostic);
    }

    fn addLayoutDiagnostic(self: *Ir, severity: DiagnosticSeverity, page_id: NodeId, node_id: ?NodeId, data: Diagnostic.Data) !void {
        try self.addDiagnostic(.{
            .phase = .layout,
            .severity = severity,
            .page_id = page_id,
            .node_id = node_id,
            .data = data,
        });
    }

    pub fn addLayoutWarning(self: *Ir, page_id: NodeId, node_id: ?NodeId, data: Diagnostic.Data) !void {
        try self.addLayoutDiagnostic(.warning, page_id, node_id, data);
    }

    pub fn addLayoutError(self: *Ir, page_id: NodeId, node_id: ?NodeId, data: Diagnostic.Data) !void {
        try self.addLayoutDiagnostic(.@"error", page_id, node_id, data);
    }

    pub fn addValidationDiagnostic(
        self: *Ir,
        severity: DiagnosticSeverity,
        page_id: ?NodeId,
        node_id: ?NodeId,
        origin: ?[]const u8,
        data: Diagnostic.Data,
    ) !void {
        var diagnostic = Diagnostic{
            .phase = .validation,
            .severity = severity,
            .page_id = page_id,
            .node_id = node_id,
            .origin = if (origin) |value| try self.allocator.dupe(u8, value) else null,
            .data = data,
        };
        errdefer diagnostic.deinit(self.allocator);
        try self.addDiagnostic(diagnostic);
    }

    pub fn addRenderDiagnostic(
        self: *Ir,
        severity: DiagnosticSeverity,
        page_id: ?NodeId,
        node_id: ?NodeId,
        origin: ?[]const u8,
        data: Diagnostic.Data,
    ) !void {
        var diagnostic = Diagnostic{
            .phase = .render,
            .severity = severity,
            .page_id = page_id,
            .node_id = node_id,
            .origin = if (origin) |value| try self.allocator.dupe(u8, value) else null,
            .data = data,
        };
        errdefer diagnostic.deinit(self.allocator);
        try self.addDiagnostic(diagnostic);
    }

    pub fn addUnplacedObjectWarnings(self: *Ir) !void {
        for (self.nodes.items) |node| {
            if (node.kind != .object or node.attached or node.discarded) continue;
            if (try self.hasUnplacedObjectParent(node.id)) continue;
            if (self.isConstraintReferencedGroupWithAttachedDescendant(node.id)) continue;
            const role = node.role orelse node.name;
            const message = try std.fmt.allocPrint(self.allocator, "UnplacedObject: object '{s}' was generated but not placed", .{role});
            try self.addValidationDiagnostic(.warning, null, node.id, node.origin, .{
                .user_report = .{ .message = message },
            });
        }
    }

    fn hasUnplacedObjectParent(self: *Ir, child_id: NodeId) !bool {
        var it = self.contains.iterator();
        while (it.next()) |entry| {
            for (entry.value_ptr.items) |candidate| {
                if (candidate != child_id) continue;
                const parent = self.getNode(entry.key_ptr.*) orelse continue;
                if (parent.kind == .object and !parent.attached and !parent.discarded) return true;
            }
        }
        return false;
    }

    fn isConstraintReferencedGroupWithAttachedDescendant(self: *Ir, node_id: NodeId) bool {
        const node = self.getNode(node_id) orelse return false;
        if (!roleEq(node.role, GroupRole)) return false;
        if (!self.constraintReferencesNode(node_id)) return false;
        return self.hasAttachedDescendant(node_id);
    }

    fn constraintReferencesNode(self: *Ir, node_id: NodeId) bool {
        for (self.constraints.items) |constraint| {
            if (constraint.target_node == node_id) return true;
            switch (constraint.source) {
                .page => {},
                .node => |source| if (source.node_id == node_id) return true,
            }
        }
        return false;
    }

    fn hasAttachedDescendant(self: *Ir, node_id: NodeId) bool {
        const children = self.childrenOf(node_id) orelse return false;
        for (children) |child_id| {
            const child = self.getNode(child_id) orelse continue;
            if (child.attached) return true;
            if (self.hasAttachedDescendant(child_id)) return true;
        }
        return false;
    }

    pub fn getNode(self: *Ir, id: NodeId) ?*Node {
        if (id != 0) {
            const index: usize = @intCast(id - 1);
            if (index < self.nodes.items.len and self.nodes.items[index].id == id) {
                return &self.nodes.items[index];
            }
        }
        for (self.nodes.items) |*node| {
            if (node.id == id) return node;
        }
        return null;
    }

    pub fn childrenOf(self: *Ir, parent: NodeId) ?[]const NodeId {
        const children = self.contains.get(parent) orelse return null;
        return children.items;
    }

    pub fn pageIndexOf(self: *Ir, page_id: NodeId) usize {
        const node = self.getNode(page_id) orelse unreachable;
        return node.page_index.?;
    }

    pub fn pageCount(self: *Ir) usize {
        return self.page_order.items.len;
    }

    pub fn parentPageOf(self: *Ir, child_id: NodeId) ?NodeId {
        var it = self.contains.iterator();
        while (it.next()) |entry| {
            const parent_id = entry.key_ptr.*;
            const parent = self.getNode(parent_id) orelse continue;
            if (parent.kind != .page) continue;
            for (entry.value_ptr.items) |candidate| {
                if (candidate == child_id) return parent_id;
            }
        }
        return null;
    }

    fn previousPageOf(self: *Ir, page_id: NodeId) ?NodeId {
        for (self.page_order.items, 0..) |candidate, index| {
            if (candidate != page_id) continue;
            if (index == 0) return null;
            return self.page_order.items[index - 1];
        }
        return null;
    }

    fn ensureValueTag(self: *Ir, value: Value, expected: ValueTag, context: []const u8) !void {
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
        self: *Ir,
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
        self: *Ir,
        allocator: Allocator,
        page_id: NodeId,
        role: Role,
        provenance: []const u8,
    ) !Selection {
        var selection = Selection.init(.object, provenance);
        const children = self.contains.get(page_id) orelse return selection;
        for (children.items) |child_id| {
            const node = self.getNode(child_id) orelse continue;
            if (roleEq(node.role, role)) {
                try selection.ids.append(allocator, child_id);
            }
        }
        return selection;
    }

    fn selectDocumentObjectsByRole(
        self: *Ir,
        allocator: Allocator,
        role: Role,
        provenance: []const u8,
    ) !Selection {
        var selection = Selection.init(.object, provenance);
        for (self.page_order.items) |page_id| {
            var page_selection = try self.selectPageObjectsByRole(allocator, page_id, role, provenance);
            defer page_selection.deinit(allocator);
            for (page_selection.ids.items) |id| {
                try selection.ids.append(allocator, id);
            }
        }
        return selection;
    }

    fn selectDocumentPages(self: *Ir, allocator: Allocator, provenance: []const u8) !Selection {
        var selection = Selection.init(.page, provenance);
        for (self.page_order.items) |page_id| {
            try selection.ids.append(allocator, page_id);
        }
        return selection;
    }

    fn selectChildren(self: *Ir, allocator: Allocator, parent_id: NodeId, provenance: []const u8) !Selection {
        var selection = Selection.init(.object, provenance);
        const children = self.contains.get(parent_id) orelse return selection;
        for (children.items) |child_id| {
            const child = self.getNode(child_id) orelse continue;
            if (child.kind == .object) try selection.ids.append(allocator, child_id);
        }
        return selection;
    }

    fn appendDescendants(self: *Ir, allocator: Allocator, parent_id: NodeId, selection: *Selection) !void {
        const children = self.contains.get(parent_id) orelse return;
        for (children.items) |child_id| {
            const child = self.getNode(child_id) orelse continue;
            if (child.kind == .object) try selection.ids.append(allocator, child_id);
            try self.appendDescendants(allocator, child_id, selection);
        }
    }

    fn selectDescendants(self: *Ir, allocator: Allocator, parent_id: NodeId, provenance: []const u8) !Selection {
        var selection = Selection.init(.object, provenance);
        try self.appendDescendants(allocator, parent_id, &selection);
        return selection;
    }

    pub fn select(self: *Ir, allocator: Allocator, base: Value, query: Query) !Value {
        try self.ensureValueTag(base, query.input, query.name);

        return switch (query.op) {
            .self_object => .{
                .selection = try self.singletonSelection(allocator, .object, query.name, base.object),
            },
            .previous_page => .{
                .page = self.previousPageOf(base.page) orelse return error.NoPreviousPage,
            },
            .parent_page => .{
                .page = self.parentPageOf(base.object) orelse return error.MissingParentPage,
            },
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

    pub fn finalize(self: *Ir) !void {
        self.clearDiagnosticsForPhase(.layout);
        self.last_constraint_failure = null;
        self.constraint_failures.clearRetainingCapacity();
        try layout.solveLayout(self);
        if (self.constraint_failures.items.len > 0) {
            switch (self.constraint_failures.items[0].kind) {
                .conflict => return error.ConstraintConflict,
                .negative_size => return error.NegativeConstraintSize,
            }
        }
    }

    pub fn styleForNode(self: *Ir, node: *const Node) model.TextStyle {
        return layout.styleForNode(self, node);
    }

    pub fn intrinsicWidth(self: *Ir, node: *const Node) f32 {
        return layout.intrinsicWidth(self, node);
    }

    pub fn intrinsicHeight(self: *Ir, node: *const Node) f32 {
        return layout.intrinsicHeight(self, node);
    }

    pub fn shouldWrapNode(self: *Ir, node: *const Node) bool {
        return layout.shouldWrapNode(self, node);
    }
};

pub fn formatConstraint(allocator: Allocator, constraint: Constraint) ![]const u8 {
    const source_text = switch (constraint.source) {
        .page => |anchor| try std.fmt.allocPrint(allocator, "page.{s}", .{@tagName(anchor)}),
        .node => |source| try std.fmt.allocPrint(allocator, "#{d}.{s}", .{ source.node_id, @tagName(source.anchor) }),
    };
    defer allocator.free(source_text);
    return std.fmt.allocPrint(
        allocator,
        "  - #{d}.{s} = {s} {s} {d:.1}",
        .{
            constraint.target_node,
            @tagName(constraint.target_anchor),
            source_text,
            if (constraint.offset < 0) "-" else "+",
            @abs(constraint.offset),
        },
    );
}

fn constraintFailureSame(a: ConstraintFailure, b: ConstraintFailure) bool {
    if (a.kind != b.kind) return false;
    if (a.page_id != b.page_id) return false;
    if (!constraintEq(a.constraint, b.constraint)) return false;
    if ((a.existing_constraint == null) != (b.existing_constraint == null)) return false;
    if (a.existing_constraint) |existing_a| {
        if (!constraintEq(existing_a, b.existing_constraint.?)) return false;
    }
    return true;
}

fn constraintEq(a: Constraint, b: Constraint) bool {
    if (a.target_node != b.target_node) return false;
    if (a.target_anchor != b.target_anchor) return false;
    if (a.offset != b.offset) return false;
    if (!constraintSourceEq(a.source, b.source)) return false;
    const a_origin = a.origin orelse "";
    const b_origin = b.origin orelse "";
    return std.mem.eql(u8, a_origin, b_origin);
}

fn constraintSourceEq(a: ConstraintSource, b: ConstraintSource) bool {
    return switch (a) {
        .page => |a_anchor| switch (b) {
            .page => |b_anchor| a_anchor == b_anchor,
            .node => false,
        },
        .node => |a_node| switch (b) {
            .page => false,
            .node => |b_node| a_node.node_id == b_node.node_id and a_node.anchor == b_node.anchor,
        },
    };
}
