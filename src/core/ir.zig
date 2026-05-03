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
const FragmentRoot = model.FragmentRoot;
const Fragment = model.Fragment;
const ConstraintSource = model.ConstraintSource;
const Selection = model.Selection;
const SelectionItemSort = model.SelectionItemSort;
const SemanticSort = model.SemanticSort;
const Value = model.Value;
const Query = model.Query;
const Transform = model.Transform;
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
    variable,
};

pub const Definition = struct {
    line: usize,
    column: usize,
    length: usize,
    kind: DefinitionKind,
    file: ?[]const u8 = null,
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
};

pub const Ir = struct {
    allocator: Allocator,
    asset_base_dir: []u8,
    modules: std.ArrayList(SourceModule),
    module_order: std.ArrayList(SourceModuleId),
    project_module_id: SourceModuleId,
    functions: std.StringHashMap(ast.FunctionDecl),
    function_metadata: std.StringHashMap(FunctionMetadata),
    variable_types: std.StringHashMap(SemanticSort),
    definitions: std.StringHashMap(Definition),
    hints: std.ArrayList(InlayHint),
    nodes: std.ArrayList(Node),
    page_order: std.ArrayList(NodeId),
    contains: std.AutoHashMap(NodeId, std.ArrayList(NodeId)),
    constraints: std.ArrayList(Constraint),
    diagnostics: std.ArrayList(Diagnostic),
    last_constraint_failure: ?ConstraintFailure,
    constraint_failures: std.ArrayList(ConstraintFailure),
    fragments: std.ArrayList(*Fragment),
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
            .functions = std.StringHashMap(ast.FunctionDecl).init(allocator),
            .function_metadata = std.StringHashMap(FunctionMetadata).init(allocator),
            .variable_types = std.StringHashMap(SemanticSort).init(allocator),
            .definitions = std.StringHashMap(Definition).init(allocator),
            .hints = std.ArrayList(InlayHint).empty,
            .nodes = .empty,
            .page_order = .empty,
            .contains = std.AutoHashMap(NodeId, std.ArrayList(NodeId)).init(allocator),
            .constraints = .empty,
            .diagnostics = .empty,
            .last_constraint_failure = null,
            .constraint_failures = .empty,
            .fragments = .empty,
            .next_id = 1,
            .document_id = 0,
        };

        try ir.modules.append(allocator, .{
            .id = 0,
            .kind = .project,
            .spec = try allocator.dupe(u8, project_path),
            .path = project_path,
            .source = project_source,
            .program = project_program,
            .resolved_import_ids = .empty,
        });

        const doc_id = try ir.freshId();
        try ir.nodes.append(allocator, .{
            .id = doc_id,
            .kind = .document,
            .name = "document",
            .attached = true,
        });
        ir.document_id = doc_id;

        return ir;
    }

    pub fn deinit(self: *Ir) void {
        for (self.modules.items) |*module| module.deinit(self.allocator);
        self.modules.deinit(self.allocator);
        self.module_order.deinit(self.allocator);
        self.functions.deinit();
        self.function_metadata.deinit();
        self.variable_types.deinit();
        var definition_iterator = self.definitions.iterator();
        while (definition_iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            if (entry.value_ptr.file) |file| self.allocator.free(file);
        }
        self.definitions.deinit();
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
        for (self.fragments.items) |fragment| {
            fragment.deinit(self.allocator);
            self.allocator.destroy(fragment);
        }
        self.fragments.deinit(self.allocator);
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

    fn addContainment(self: *Ir, parent: NodeId, child: NodeId) !void {
        const gop = try self.contains.getOrPut(parent);
        if (!gop.found_existing) {
            gop.value_ptr.* = .empty;
        }
        try gop.value_ptr.append(self.allocator, child);
    }

    pub fn addPage(self: *Ir, name: []const u8) !NodeId {
        const page_id = try self.freshId();
        const index = self.page_order.items.len + 1;
        try self.nodes.append(self.allocator, .{
            .id = page_id,
            .kind = .page,
            .name = name,
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
        return self.makeNodeWithOrigin(page_id, true, .object, null, name, role, object_kind, payload_kind, content, origin);
    }

    pub fn makeDetachedObjectWithOrigin(
        self: *Ir,
        page_id: NodeId,
        name: []const u8,
        role: ?Role,
        object_kind: ObjectKind,
        payload_kind: PayloadKind,
        content: ?[]const u8,
        origin: ?[]const u8,
    ) !NodeId {
        return self.makeNodeWithOrigin(page_id, false, .object, null, name, role, object_kind, payload_kind, content, origin);
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
            null,
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

    pub fn setAllPageProperty(self: *Ir, key: []const u8, value: []const u8) !void {
        try self.setNodeProperty(self.document_id, key, value);
        for (self.page_order.items) |page_id| {
            try self.setNodeProperty(page_id, key, value);
        }
    }

    pub fn getNodeProperty(self: *Ir, node_id: NodeId, key: []const u8) ?[]const u8 {
        const node = self.getNode(node_id) orelse return null;
        return nodeProperty(node, key);
    }

    fn copyNodeProperties(self: *Ir, from_id: NodeId, to_id: NodeId) !void {
        const from = self.getNode(from_id) orelse return error.UnknownNode;
        for (from.properties.items) |property| {
            try self.setNodeProperty(to_id, property.key, property.value);
        }
    }

    fn deriveObject(
        self: *Ir,
        page_id: NodeId,
        attached: bool,
        from_id: NodeId,
        name: []const u8,
        role: ?Role,
        object_kind: ObjectKind,
        payload_kind: PayloadKind,
        content: ?[]const u8,
        origin: []const u8,
    ) !NodeId {
        return self.makeNodeWithOrigin(page_id, attached, .derived, from_id, name, role, object_kind, payload_kind, content, origin);
    }

    fn makeNodeWithOrigin(
        self: *Ir,
        page_id: NodeId,
        attached: bool,
        kind: NodeKind,
        derived_from: ?NodeId,
        name: []const u8,
        role: ?Role,
        object_kind: ObjectKind,
        payload_kind: PayloadKind,
        content: ?[]const u8,
        origin: ?[]const u8,
    ) !NodeId {
        const obj_id = try self.freshId();
        try self.nodes.append(self.allocator, .{
            .id = obj_id,
            .kind = kind,
            .name = name,
            .attached = attached,
            .role = role,
            .object_kind = object_kind,
            .payload_kind = payload_kind,
            .content = content,
            .derived_from = derived_from,
            .origin = origin,
        });
        if (attached) try self.addContainment(page_id, obj_id);
        return obj_id;
    }

    pub fn createFragment(
        self: *Ir,
        page_id: NodeId,
        root: FragmentRoot,
        node_ids: std.ArrayList(NodeId),
        constraints: ConstraintSet,
        deps: std.ArrayList(*Fragment),
    ) !*Fragment {
        const fragment = try self.allocator.create(Fragment);
        fragment.* = .{
            .page_id = page_id,
            .root = root,
            .node_ids = node_ids,
            .constraints = constraints,
            .deps = deps,
            .materialized = false,
        };
        try self.fragments.append(self.allocator, fragment);
        return fragment;
    }

    pub fn materializeFragment(self: *Ir, fragment: *Fragment) !void {
        if (fragment.materialized) return;

        for (fragment.deps.items) |dep| {
            try self.materializeFragment(dep);
        }
        for (fragment.node_ids.items) |node_id| {
            const node = self.getNode(node_id) orelse return error.UnknownNode;
            if (!node.attached) {
                node.attached = true;
                try self.addContainment(fragment.page_id, node_id);
            }
        }
        try self.constraints.appendSlice(self.allocator, fragment.constraints.items.items);
        if (fragment.root) |root| switch (root) {
            .constraints => |constraints| try self.constraints.appendSlice(self.allocator, constraints.items.items),
            else => {},
        };
        fragment.materialized = true;
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
        try self.addDiagnostic(.{
            .phase = .validation,
            .severity = severity,
            .page_id = page_id,
            .node_id = node_id,
            .origin = origin,
            .data = data,
        });
    }

    pub fn getNode(self: *Ir, id: NodeId) ?*Node {
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

    fn pageNumberText(self: *Ir, allocator: Allocator, page_id: NodeId) ![]const u8 {
        return std.fmt.allocPrint(allocator, "{d}/{d}", .{ self.pageIndexOf(page_id), self.pageCount() });
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

    fn ensureSort(self: *Ir, value: Value, expected: SemanticSort, context: []const u8) !void {
        _ = self;
        const actual: SemanticSort = switch (value) {
            .document => .document,
            .page => .page,
            .object => .object,
            .selection => .selection,
            .anchor => .anchor,
            .function => .function,
            .style => .style,
            .string => .string,
            .number => .number,
            .constraints => .constraints,
            .fragment => .fragment,
        };
        if (actual != expected) {
            std.debug.print("sort mismatch in {s}: expected {s}, got {s}\n", .{
                context,
                @tagName(expected),
                @tagName(actual),
            });
            return error.InvalidSemanticSort;
        }
    }

    fn singletonSelection(
        self: *Ir,
        allocator: Allocator,
        item_sort: SelectionItemSort,
        provenance: []const u8,
        id: NodeId,
    ) !Selection {
        _ = self;
        var selection = Selection.init(item_sort, provenance);
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

    pub fn select(self: *Ir, allocator: Allocator, base: Value, query: Query) !Value {
        try self.ensureSort(base, query.input, query.name);

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

    fn rewriteText(self: *Ir, allocator: Allocator, from_id: NodeId, old: []const u8, new: []const u8) ![]const u8 {
        const from = self.getNode(from_id) orelse return error.UnknownNode;
        const source = from.content orelse return error.MissingContent;
        return std.mem.replaceOwned(u8, allocator, source, old, new);
    }

    pub fn derive(self: *Ir, page_id: NodeId, base: Value, transform: Transform) !NodeId {
        return self.deriveWithOrigin(page_id, base, transform, transform.name);
    }

    pub fn deriveWithOrigin(self: *Ir, page_id: NodeId, base: Value, transform: Transform, origin: []const u8) !NodeId {
        return self.deriveWithMode(page_id, true, base, transform, origin);
    }

    pub fn deriveDetachedWithOrigin(self: *Ir, page_id: NodeId, base: Value, transform: Transform, origin: []const u8) !NodeId {
        return self.deriveWithMode(page_id, false, base, transform, origin);
    }

    fn deriveWithMode(self: *Ir, page_id: NodeId, attached: bool, base: Value, transform: Transform, origin: []const u8) !NodeId {
        try self.ensureSort(base, transform.input, transform.name);

        return switch (transform.op) {
            .rewrite_text => |rewrite| blk: {
                const updated = try self.rewriteText(self.allocator, base.object, rewrite.old, rewrite.new);
                const id = try self.deriveObject(
                    page_id,
                    attached,
                    base.object,
                    "rewritten-copy",
                    "code",
                    .source,
                    .code,
                    updated,
                    origin,
                );
                try self.copyNodeProperties(base.object, id);
                break :blk id;
            },
            .highlight => |highlight| blk: {
                if (base.selection.item_sort != .object) return error.InvalidSelectionSort;
                const source_id = base.selection.first() orelse return error.EmptySelection;
                break :blk try self.deriveObject(
                    page_id,
                    attached,
                    source_id,
                    "highlight",
                    "highlight",
                    .overlay,
                    .text,
                    highlight.note,
                    origin,
                );
            },
            .page_number => blk: {
                const id = try self.deriveObject(
                    page_id,
                    attached,
                    base.page,
                    "page-number",
                    "page_number",
                    .text,
                    .text,
                    "",
                    origin,
                );
                if (attached) {
                    try self.addAnchorConstraint(id, .right, .{ .page = .right }, -PageLayout.page_number_right_inset, origin);
                    try self.addAnchorConstraint(id, .bottom, .{ .page = .bottom }, PageLayout.page_number_bottom_inset, origin);
                }
                break :blk id;
            },
            .toc => blk: {
                break :blk try self.deriveToc(page_id, attached, base.document, origin);
            },
        };
    }

    fn deriveToc(self: *Ir, page_id: NodeId, attached: bool, document_id: NodeId, origin: []const u8) !NodeId {
        const owned = try self.buildTocText(document_id);
        return self.deriveObject(
            page_id,
            attached,
            document_id,
            "toc",
            "toc",
            .text,
            .text,
            owned,
            origin,
        );
    }

    fn buildTocText(self: *Ir, document_id: NodeId) ![]const u8 {
        var pages = try self.select(self.allocator, .{ .document = document_id }, Query.documentPages());
        defer pages.deinit(self.allocator);

        var text = std.ArrayList(u8).empty;
        defer text.deinit(self.allocator);
        try text.appendSlice(self.allocator, "Table of Contents\n");

        for (pages.selection.ids.items) |member_page_id| {
            var titles = try self.select(
                self.allocator,
                .{ .page = member_page_id },
                Query.pageObjectsByRole("title"),
            );
            defer titles.deinit(self.allocator);

            const title_id = titles.firstId() orelse continue;
            const title = self.getNode(title_id) orelse continue;
            const line = try std.fmt.allocPrint(
                self.allocator,
                "- {s} .... {d}\n",
                .{ title.content.?, self.pageIndexOf(member_page_id) },
            );
            try text.appendSlice(self.allocator, line);
        }

        return text.toOwnedSlice(self.allocator);
    }

    pub fn fragmentRootSort(self: *Ir, fragment: *const Fragment) SemanticSort {
        _ = self;
        const root = fragment.root orelse unreachable;
        return switch (root) {
            .document => .document,
            .page => .page,
            .object => .object,
            .selection => .selection,
            .anchor => .anchor,
            .function => .function,
            .style => .style,
            .string => .string,
            .number => .number,
            .constraints => .constraints,
        };
    }

    pub fn finalize(self: *Ir) !void {
        self.clearDiagnosticsForPhase(.layout);
        self.last_constraint_failure = null;
        self.constraint_failures.clearRetainingCapacity();
        try self.refreshPageNumbers();
        try self.refreshTocs();
        try layout.solveLayout(self);
        if (self.constraint_failures.items.len > 0) {
            switch (self.constraint_failures.items[0].kind) {
                .conflict => return error.ConstraintConflict,
                .negative_size => return error.NegativeConstraintSize,
            }
        }
    }

    fn refreshPageNumbers(self: *Ir) !void {
        for (self.nodes.items) |*node| {
            if (!roleEq(node.role, "page_number")) continue;
            const page_id = self.parentPageOf(node.id) orelse continue;
            node.content = try self.pageNumberText(self.allocator, page_id);
        }
    }

    fn refreshTocs(self: *Ir) !void {
        for (self.nodes.items) |*node| {
            if (!roleEq(node.role, "toc")) continue;
            const document_id = node.derived_from orelse self.document_id;
            node.content = try self.buildTocText(document_id);
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
