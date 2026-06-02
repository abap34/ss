const std = @import("std");
const model = @import("model");
const layout = @import("layout.zig");
const ast = @import("ast");

const Allocator = model.Allocator;
const NodeId = model.NodeId;
const MetadataId = model.MetadataId;
const Node = model.Node;
const Metadata = model.Metadata;
const NodeKind = model.NodeKind;
const Role = model.Role;
const ObjectKind = model.ObjectKind;
const PayloadKind = model.PayloadKind;
const Anchor = model.Anchor;
const Constraint = model.Constraint;
const ConstraintSet = model.ConstraintSet;
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
    resolved_import_ids: std.ArrayList(SourceModuleId),

    pub fn deinit(self: *SourceModule, allocator: Allocator) void {
        self.program.deinit(allocator);
        self.resolved_import_ids.deinit(allocator);
        allocator.free(self.spec);
        allocator.free(self.source);
        if (self.path) |path| allocator.free(path);
    }
};

pub const FunctionMetadata = struct {
    module_id: SourceModuleId,
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
    functions: std.StringHashMap(ast.FunctionDecl),
    function_metadata: std.StringHashMap(FunctionMetadata),
    definitions: std.ArrayList(Definition),
    hints: std.ArrayList(InlayHint),
    nodes: std.ArrayList(Node),
    metadata: std.ArrayList(Metadata),
    page_order: std.ArrayList(NodeId),
    contains: std.AutoHashMap(NodeId, std.ArrayList(NodeId)),
    constraints: std.ArrayList(Constraint),
    diagnostics: std.ArrayList(Diagnostic),
    last_constraint_failure: ?ConstraintFailure,
    constraint_failures: std.ArrayList(ConstraintFailure),
    runtime_strings: std.ArrayList([]u8),
    next_id: NodeId,
    next_metadata_id: MetadataId,
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
            .functions = std.StringHashMap(ast.FunctionDecl).init(allocator),
            .function_metadata = std.StringHashMap(FunctionMetadata).init(allocator),
            .definitions = .empty,
            .hints = std.ArrayList(InlayHint).empty,
            .nodes = .empty,
            .metadata = .empty,
            .page_order = .empty,
            .contains = std.AutoHashMap(NodeId, std.ArrayList(NodeId)).init(allocator),
            .constraints = .empty,
            .diagnostics = .empty,
            .last_constraint_failure = null,
            .constraint_failures = .empty,
            .runtime_strings = .empty,
            .next_id = 1,
            .next_metadata_id = 1,
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
            .resolved_import_ids = .empty,
        });

        return ir;
    }

    fn deinitPartial(self: *Ir) void {
        self.modules.deinit(self.allocator);
        self.module_order.deinit(self.allocator);
        self.functions.deinit();
        self.function_metadata.deinit();
        self.definitions.deinit(self.allocator);
        self.hints.deinit(self.allocator);
        self.contains.deinit();
        for (self.nodes.items) |*node| node.deinit(self.allocator);
        self.nodes.deinit(self.allocator);
        for (self.metadata.items) |*metadata| metadata.deinit(self.allocator);
        self.metadata.deinit(self.allocator);
        self.page_order.deinit(self.allocator);
        self.constraints.deinit(self.allocator);
        self.diagnostics.deinit(self.allocator);
        self.constraint_failures.deinit(self.allocator);
        self.runtime_strings.deinit(self.allocator);
    }

    pub fn deinit(self: *Ir) void {
        for (self.modules.items) |*module| module.deinit(self.allocator);
        self.modules.deinit(self.allocator);
        self.module_order.deinit(self.allocator);
        self.functions.deinit();
        self.function_metadata.deinit();
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
        for (self.metadata.items) |*metadata| {
            metadata.deinit(self.allocator);
        }
        self.metadata.deinit(self.allocator);
        self.page_order.deinit(self.allocator);
        self.constraints.deinit(self.allocator);
        self.clearDiagnostics();
        self.diagnostics.deinit(self.allocator);
        self.constraint_failures.deinit(self.allocator);
        for (self.runtime_strings.items) |text| self.allocator.free(text);
        self.runtime_strings.deinit(self.allocator);
    }

    pub fn ownString(self: *Ir, text: []u8) ![]const u8 {
        errdefer self.allocator.free(text);
        try self.runtime_strings.append(self.allocator, text);
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

    fn freshMetadataId(self: *Ir) MetadataId {
        const id = self.next_metadata_id;
        self.next_metadata_id += 1;
        return id;
    }

    fn addContainment(self: *Ir, parent: NodeId, child: NodeId) !void {
        const gop = try self.contains.getOrPut(parent);
        if (!gop.found_existing) {
            gop.value_ptr.* = .empty;
        }
        for (gop.value_ptr.items) |existing| {
            if (existing == child) return;
        }
        try gop.value_ptr.append(self.allocator, child);
    }

    pub fn addContainmentFromStage(self: *Ir, parent: NodeId, child: NodeId) !void {
        try self.addContainment(parent, child);
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

    pub fn setNodeContent(self: *Ir, node_id: NodeId, value: []const u8) !void {
        const node = self.getNode(node_id) orelse return error.UnknownNode;
        const owned_value = try self.allocator.dupe(u8, value);
        if (node.content_owned) {
            if (node.content) |content| self.allocator.free(content);
        }
        node.content = owned_value;
        node.content_owned = true;
    }

    pub fn appendNodeContent(self: *Ir, node_id: NodeId, value: []const u8) !void {
        const node = self.getNode(node_id) orelse return error.UnknownNode;
        const current = node.content orelse "";
        node.content = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ current, value });
        if (node.content_owned) self.allocator.free(current);
        node.content_owned = true;
    }

    pub fn emitMetadata(self: *Ir, target: Value, kind: []const u8, value: []const u8, origin: ?[]const u8) !MetadataId {
        const page_id: ?NodeId = switch (target) {
            .document => null,
            .page => |id| id,
            .object => |id| self.parentPageOf(id) orelse return error.MissingParentPage,
            else => return error.InvalidValueTag,
        };
        return try self.addMetadata(kind, value, page_id, origin);
    }

    pub fn addMetadata(self: *Ir, kind: []const u8, value: []const u8, page_id: ?NodeId, origin: ?[]const u8) !MetadataId {
        const id = self.freshMetadataId();
        try self.metadata.append(self.allocator, .{
            .id = id,
            .kind = try self.copyString(kind),
            .value = try self.copyString(value),
            .page_id = page_id,
            .origin = try self.copyOptionalString(origin),
        });
        return id;
    }

    pub fn metadataById(self: *Ir, id: MetadataId) ?*Metadata {
        if (id != 0) {
            const index: usize = @intCast(id - 1);
            if (index < self.metadata.items.len and self.metadata.items[index].id == id) {
                return &self.metadata.items[index];
            }
        }
        for (self.metadata.items) |*item| {
            if (item.id == id) return item;
        }
        return null;
    }

    pub fn metadataContent(self: *Ir, id: MetadataId) ![]const u8 {
        return (self.metadataById(id) orelse return error.UnknownMetadata).value;
    }

    pub fn metadataKind(self: *Ir, id: MetadataId) ![]const u8 {
        return (self.metadataById(id) orelse return error.UnknownMetadata).kind;
    }

    pub fn metadataPage(self: *Ir, id: MetadataId) !NodeId {
        return (self.metadataById(id) orelse return error.UnknownMetadata).page_id orelse return error.MissingParentPage;
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
        });
        if (attached) try self.addContainment(page_id, obj_id);
        return obj_id;
    }

    pub fn makeNodeFromStage(
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
        return self.makeNodeWithOrigin(page_id, attached, kind, name, role, object_kind, payload_kind, content, origin);
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
            .metadata => .metadata,
            .selection => .selection,
            .anchor => .anchor,
            .function => .function,
            .style => .style,
            .string => .string,
            .number => .number,
            .boolean => .boolean,
            .constraints => .constraints,
            .void => .void,
        };
        if (actual != expected) {
            std.debug.print("value type mismatch in {s}: expected {s}, got {s}\n", .{
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

    pub fn selectDocumentMetadataByKind(self: *Ir, allocator: Allocator, kind: []const u8, provenance: []const u8) !Selection {
        var selection = Selection.init(.metadata, provenance);
        for (self.metadata.items) |item| {
            if (std.mem.eql(u8, item.kind, kind)) {
                try selection.ids.append(allocator, item.id);
            }
        }
        return selection;
    }

    pub fn selectPageMetadataByKind(self: *Ir, allocator: Allocator, page_id: NodeId, kind: []const u8, provenance: []const u8) !Selection {
        var selection = Selection.init(.metadata, provenance);
        for (self.metadata.items) |item| {
            if (item.page_id != null and item.page_id.? == page_id and std.mem.eql(u8, item.kind, kind)) {
                try selection.ids.append(allocator, item.id);
            }
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
