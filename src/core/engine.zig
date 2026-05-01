const std = @import("std");
const model = @import("model.zig");
const layout = @import("layout.zig");
const dump = @import("dump.zig");

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
const DiagnosticSeverity = model.DiagnosticSeverity;
const ConstraintFailure = model.ConstraintFailure;
const ConstraintFailureKind = model.ConstraintFailureKind;
const GroupRole = model.GroupRole;
const roleEq = model.roleEq;
const nodeProperty = model.nodeProperty;

pub const Engine = struct {
    allocator: Allocator,
    asset_base_dir: []const u8,
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

    pub fn init(allocator: Allocator) !Engine {
        var engine = Engine{
            .allocator = allocator,
            .asset_base_dir = ".",
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

        const doc_id = try engine.freshId();
        try engine.nodes.append(allocator, .{
            .id = doc_id,
            .kind = .document,
            .name = "document",
            .attached = true,
        });
        engine.document_id = doc_id;

        return engine;
    }

    pub fn deinit(self: *Engine) void {
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
        self.diagnostics.deinit(self.allocator);
        self.constraint_failures.deinit(self.allocator);
        for (self.fragments.items) |fragment| {
            fragment.deinit(self.allocator);
            self.allocator.destroy(fragment);
        }
        self.fragments.deinit(self.allocator);
    }

    fn freshId(self: *Engine) !NodeId {
        const id = self.next_id;
        self.next_id += 1;
        return id;
    }

    fn addContainment(self: *Engine, parent: NodeId, child: NodeId) !void {
        const gop = try self.contains.getOrPut(parent);
        if (!gop.found_existing) {
            gop.value_ptr.* = .empty;
        }
        try gop.value_ptr.append(self.allocator, child);
    }

    pub fn addPage(self: *Engine, name: []const u8) !NodeId {
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
        self: *Engine,
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
        self: *Engine,
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
        self: *Engine,
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
        self: *Engine,
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

    pub fn setNodeProperty(self: *Engine, node_id: NodeId, key: []const u8, value: []const u8) !void {
        const node = self.getNode(node_id) orelse return error.UnknownNode;
        for (node.properties.items) |*property| {
            if (std.mem.eql(u8, property.key, key)) {
                property.value = value;
                return;
            }
        }
        try node.properties.append(self.allocator, .{ .key = key, .value = value });
    }

    pub fn getNodeProperty(self: *Engine, node_id: NodeId, key: []const u8) ?[]const u8 {
        const node = self.getNode(node_id) orelse return null;
        return nodeProperty(node, key);
    }

    fn copyNodeProperties(self: *Engine, from_id: NodeId, to_id: NodeId) !void {
        const from = self.getNode(from_id) orelse return error.UnknownNode;
        for (from.properties.items) |property| {
            try self.setNodeProperty(to_id, property.key, property.value);
        }
    }

    fn deriveObject(
        self: *Engine,
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
        self: *Engine,
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
        self: *Engine,
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

    pub fn materializeFragment(self: *Engine, fragment: *Fragment) !void {
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

    pub fn addConstraint(self: *Engine, expr: []const u8) !void {
        _ = self;
        _ = expr;
        return error.StringConstraintsRemoved;
    }

    pub fn addAnchorConstraint(
        self: *Engine,
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

    pub fn addConstraintSet(self: *Engine, constraints: ConstraintSet) !void {
        try self.constraints.appendSlice(self.allocator, constraints.items.items);
    }

    pub fn noteConstraintFailure(self: *Engine, page_id: NodeId, constraint: Constraint, existing_constraint: ?Constraint, kind: ConstraintFailureKind) void {
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

    pub fn hasConstraintFailures(self: *const Engine) bool {
        return self.constraint_failures.items.len > 0;
    }

    pub fn clearDiagnostics(self: *Engine) void {
        self.diagnostics.clearRetainingCapacity();
    }

    pub fn addDiagnostic(self: *Engine, diagnostic: Diagnostic) !void {
        try self.diagnostics.append(self.allocator, diagnostic);
    }

    fn addLayoutDiagnostic(self: *Engine, severity: DiagnosticSeverity, page_id: NodeId, node_id: ?NodeId, data: Diagnostic.Data) !void {
        try self.addDiagnostic(.{
            .phase = .layout,
            .severity = severity,
            .page_id = page_id,
            .node_id = node_id,
            .data = data,
        });
    }

    pub fn addLayoutWarning(self: *Engine, page_id: NodeId, node_id: ?NodeId, data: Diagnostic.Data) !void {
        try self.addLayoutDiagnostic(.warning, page_id, node_id, data);
    }

    pub fn addLayoutError(self: *Engine, page_id: NodeId, node_id: ?NodeId, data: Diagnostic.Data) !void {
        try self.addLayoutDiagnostic(.@"error", page_id, node_id, data);
    }

    pub fn getNode(self: *Engine, id: NodeId) ?*Node {
        for (self.nodes.items) |*node| {
            if (node.id == id) return node;
        }
        return null;
    }

    pub fn childrenOf(self: *Engine, parent: NodeId) ?[]const NodeId {
        const children = self.contains.get(parent) orelse return null;
        return children.items;
    }

    pub fn pageIndexOf(self: *Engine, page_id: NodeId) usize {
        const node = self.getNode(page_id) orelse unreachable;
        return node.page_index.?;
    }

    pub fn pageCount(self: *Engine) usize {
        return self.page_order.items.len;
    }

    fn pageNumberText(self: *Engine, allocator: Allocator, page_id: NodeId) ![]const u8 {
        return std.fmt.allocPrint(allocator, "{d}/{d}", .{ self.pageIndexOf(page_id), self.pageCount() });
    }

    pub fn parentPageOf(self: *Engine, child_id: NodeId) ?NodeId {
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

    fn previousPageOf(self: *Engine, page_id: NodeId) ?NodeId {
        for (self.page_order.items, 0..) |candidate, index| {
            if (candidate != page_id) continue;
            if (index == 0) return null;
            return self.page_order.items[index - 1];
        }
        return null;
    }

    fn ensureSort(self: *Engine, value: Value, expected: SemanticSort, context: []const u8) !void {
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
        self: *Engine,
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
        self: *Engine,
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
        self: *Engine,
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

    fn selectDocumentPages(self: *Engine, allocator: Allocator, provenance: []const u8) !Selection {
        var selection = Selection.init(.page, provenance);
        for (self.page_order.items) |page_id| {
            try selection.ids.append(allocator, page_id);
        }
        return selection;
    }

    pub fn select(self: *Engine, allocator: Allocator, base: Value, query: Query) !Value {
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

    fn rewriteText(self: *Engine, allocator: Allocator, from_id: NodeId, old: []const u8, new: []const u8) ![]const u8 {
        const from = self.getNode(from_id) orelse return error.UnknownNode;
        const source = from.content orelse return error.MissingContent;
        return std.mem.replaceOwned(u8, allocator, source, old, new);
    }

    pub fn derive(self: *Engine, page_id: NodeId, base: Value, transform: Transform) !NodeId {
        return self.deriveWithOrigin(page_id, base, transform, transform.name);
    }

    pub fn deriveWithOrigin(self: *Engine, page_id: NodeId, base: Value, transform: Transform, origin: []const u8) !NodeId {
        return self.deriveWithMode(page_id, true, base, transform, origin);
    }

    pub fn deriveDetachedWithOrigin(self: *Engine, page_id: NodeId, base: Value, transform: Transform, origin: []const u8) !NodeId {
        return self.deriveWithMode(page_id, false, base, transform, origin);
    }

    fn deriveWithMode(self: *Engine, page_id: NodeId, attached: bool, base: Value, transform: Transform, origin: []const u8) !NodeId {
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

    fn deriveToc(self: *Engine, page_id: NodeId, attached: bool, document_id: NodeId, origin: []const u8) !NodeId {
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

    fn buildTocText(self: *Engine, document_id: NodeId) ![]const u8 {
        var pages = try self.select(self.allocator, .{ .document = document_id }, Query.documentPages());
        defer pages.deinit(self.allocator);

        var text = std.ArrayList(u8).empty;
        defer text.deinit(self.allocator);
        try text.appendSlice(self.allocator, "目次\n");

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

    pub fn fragmentRootSort(self: *Engine, fragment: *const Fragment) SemanticSort {
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

    pub fn finalize(self: *Engine) !void {
        self.clearDiagnostics();
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

    fn refreshPageNumbers(self: *Engine) !void {
        for (self.nodes.items) |*node| {
            if (!roleEq(node.role, "page_number")) continue;
            const page_id = self.parentPageOf(node.id) orelse continue;
            node.content = try self.pageNumberText(self.allocator, page_id);
        }
    }

    fn refreshTocs(self: *Engine) !void {
        for (self.nodes.items) |*node| {
            if (!roleEq(node.role, "toc")) continue;
            const document_id = node.derived_from orelse self.document_id;
            node.content = try self.buildTocText(document_id);
        }
    }

    pub fn styleForNode(self: *Engine, node: *const Node) model.TextStyle {
        return layout.styleForNode(self, node);
    }

    pub fn intrinsicWidth(self: *Engine, node: *const Node) f32 {
        return layout.intrinsicWidth(self, node);
    }

    pub fn intrinsicHeight(self: *Engine, node: *const Node) f32 {
        return layout.intrinsicHeight(self, node);
    }

    pub fn shouldWrapNode(self: *Engine, node: *const Node) bool {
        return layout.shouldWrapNode(self, node);
    }

    pub fn dumpToString(self: *Engine, allocator: Allocator) ![]const u8 {
        return dump.dumpToString(self, allocator);
    }

    pub fn dumpJsonToString(self: *Engine, allocator: Allocator) ![]const u8 {
        return dump.dumpJsonToString(self, allocator);
    }
};

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
