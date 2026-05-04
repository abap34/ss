const std = @import("std");
const core = @import("core");

const Allocator = std.mem.Allocator;

pub const HandleId = core.NodeId;

pub const Term = union(enum) {
    add_page: struct {
        handle: HandleId,
        name: []const u8,
    },
    make_node: struct {
        handle: HandleId,
        page: HandleId,
        attached: bool,
        kind: core.NodeKind,
        derived_from: ?HandleId,
        name: []const u8,
        role: ?core.Role,
        object_kind: core.ObjectKind,
        payload_kind: core.PayloadKind,
        content: ?[]const u8,
        origin: ?[]const u8,
    },
    add_containment: struct {
        parent: HandleId,
        child: HandleId,
    },
    set_property: struct {
        node: HandleId,
        key: []const u8,
        value: []const u8,
    },
    add_constraint: core.Constraint,
    materialize_fragment: *core.Fragment,
};

pub const Document = struct {
    allocator: Allocator,
    asset_base_dir: []const u8,
    document_id: HandleId,
    next_id: HandleId,
    nodes: std.ArrayList(core.Node),
    page_order: std.ArrayList(HandleId),
    contains: std.AutoHashMap(HandleId, std.ArrayList(HandleId)),
    constraints: std.ArrayList(core.Constraint),
    diagnostics: std.ArrayList(core.Diagnostic),
    fragments: std.ArrayList(*core.Fragment),
    terms: std.ArrayList(Term),

    pub fn init(allocator: Allocator, asset_base_dir: []const u8) !Document {
        const document_id: HandleId = 1;
        var doc = Document{
            .allocator = allocator,
            .asset_base_dir = asset_base_dir,
            .document_id = document_id,
            .next_id = document_id + 1,
            .nodes = .empty,
            .page_order = .empty,
            .contains = std.AutoHashMap(HandleId, std.ArrayList(HandleId)).init(allocator),
            .constraints = .empty,
            .diagnostics = .empty,
            .fragments = .empty,
            .terms = .empty,
        };
        errdefer doc.deinit();
        try doc.nodes.append(allocator, .{
            .id = document_id,
            .kind = .document,
            .name = "document",
            .attached = true,
        });
        return doc;
    }

    pub fn deinit(self: *Document) void {
        for (self.terms.items) |*term| deinitTerm(term, self.allocator);
        self.terms.deinit(self.allocator);
        for (self.fragments.items) |fragment| {
            fragment.deinit(self.allocator);
            self.allocator.destroy(fragment);
        }
        self.fragments.deinit(self.allocator);
        for (self.diagnostics.items) |*diagnostic| diagnostic.deinit(self.allocator);
        self.diagnostics.deinit(self.allocator);
        self.constraints.deinit(self.allocator);
        var it = self.contains.iterator();
        while (it.next()) |entry| entry.value_ptr.deinit(self.allocator);
        self.contains.deinit();
        self.page_order.deinit(self.allocator);
        for (self.nodes.items) |*node| node.deinit(self.allocator);
        self.nodes.deinit(self.allocator);
    }

    fn deinitTerm(term: *Term, allocator: Allocator) void {
        switch (term.*) {
            .set_property => |property| {
                allocator.free(property.key);
                allocator.free(property.value);
            },
            else => {},
        }
    }

    fn freshId(self: *Document) HandleId {
        const id = self.next_id;
        self.next_id += 1;
        return id;
    }

    fn addContainment(self: *Document, parent: HandleId, child: HandleId) !void {
        const gop = try self.contains.getOrPut(parent);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        for (gop.value_ptr.items) |existing| {
            if (existing == child) return;
        }
        try gop.value_ptr.append(self.allocator, child);
        try self.terms.append(self.allocator, .{ .add_containment = .{ .parent = parent, .child = child } });
    }

    pub fn addPage(self: *Document, name: []const u8) !HandleId {
        const page_id = self.freshId();
        const index = self.page_order.items.len + 1;
        try self.nodes.append(self.allocator, .{
            .id = page_id,
            .kind = .page,
            .name = name,
            .attached = true,
            .page_index = index,
        });
        try self.page_order.append(self.allocator, page_id);
        try self.terms.append(self.allocator, .{ .add_page = .{ .handle = page_id, .name = name } });
        try self.addContainment(self.document_id, page_id);
        return page_id;
    }

    pub fn makeObjectWithOrigin(
        self: *Document,
        page_id: HandleId,
        name: []const u8,
        role: ?core.Role,
        object_kind: core.ObjectKind,
        payload_kind: core.PayloadKind,
        content: ?[]const u8,
        origin: ?[]const u8,
    ) !HandleId {
        return self.makeNodeWithOrigin(page_id, true, .object, null, name, role, object_kind, payload_kind, content, origin);
    }

    pub fn makeDetachedObjectWithOrigin(
        self: *Document,
        page_id: HandleId,
        name: []const u8,
        role: ?core.Role,
        object_kind: core.ObjectKind,
        payload_kind: core.PayloadKind,
        content: ?[]const u8,
        origin: ?[]const u8,
    ) !HandleId {
        return self.makeNodeWithOrigin(page_id, false, .object, null, name, role, object_kind, payload_kind, content, origin);
    }

    pub fn makeGroupWithOrigin(
        self: *Document,
        page_id: HandleId,
        attached: bool,
        children: []const HandleId,
        origin: ?[]const u8,
    ) !HandleId {
        const group_id = try self.makeNodeWithOrigin(page_id, attached, .object, null, "group", core.GroupRole, .overlay, .text, "", origin);
        for (children) |child_id| try self.addContainment(group_id, child_id);
        return group_id;
    }

    fn makeNodeWithOrigin(
        self: *Document,
        page_id: HandleId,
        attached: bool,
        kind: core.NodeKind,
        derived_from: ?HandleId,
        name: []const u8,
        role: ?core.Role,
        object_kind: core.ObjectKind,
        payload_kind: core.PayloadKind,
        content: ?[]const u8,
        origin: ?[]const u8,
    ) !HandleId {
        const id = self.freshId();
        try self.nodes.append(self.allocator, .{
            .id = id,
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
        try self.terms.append(self.allocator, .{ .make_node = .{
            .handle = id,
            .page = page_id,
            .attached = attached,
            .kind = kind,
            .derived_from = derived_from,
            .name = name,
            .role = role,
            .object_kind = object_kind,
            .payload_kind = payload_kind,
            .content = content,
            .origin = origin,
        } });
        if (attached) try self.addContainment(page_id, id);
        return id;
    }

    pub fn setNodeProperty(self: *Document, node_id: HandleId, key: []const u8, value: []const u8) !void {
        const node = self.getNode(node_id) orelse return error.UnknownNode;
        for (node.properties.items) |*property| {
            if (std.mem.eql(u8, property.key, key)) {
                const owned_value = try self.allocator.dupe(u8, value);
                self.allocator.free(property.value);
                property.value = owned_value;
                try self.appendSetPropertyTerm(node_id, key, value);
                return;
            }
        }
        try node.properties.append(self.allocator, .{
            .key = try self.allocator.dupe(u8, key),
            .value = try self.allocator.dupe(u8, value),
        });
        try self.appendSetPropertyTerm(node_id, key, value);
    }

    fn appendSetPropertyTerm(self: *Document, node_id: HandleId, key: []const u8, value: []const u8) !void {
        try self.terms.append(self.allocator, .{ .set_property = .{
            .node = node_id,
            .key = try self.allocator.dupe(u8, key),
            .value = try self.allocator.dupe(u8, value),
        } });
    }

    pub fn setAllPageProperty(self: *Document, key: []const u8, value: []const u8) !void {
        try self.setNodeProperty(self.document_id, key, value);
        for (self.page_order.items) |page_id| try self.setNodeProperty(page_id, key, value);
    }

    pub fn getNodeProperty(self: *Document, node_id: HandleId, key: []const u8) ?[]const u8 {
        const node = self.getNode(node_id) orelse return null;
        return core.nodeProperty(node, key);
    }

    pub fn addAnchorConstraint(
        self: *Document,
        target_node: HandleId,
        target_anchor: core.Anchor,
        source: core.ConstraintSource,
        offset: f32,
        origin: ?[]const u8,
    ) !void {
        const constraint: core.Constraint = .{
            .target_node = target_node,
            .target_anchor = target_anchor,
            .source = source,
            .offset = offset,
            .origin = origin,
        };
        try self.constraints.append(self.allocator, constraint);
        try self.terms.append(self.allocator, .{ .add_constraint = constraint });
    }

    pub fn addConstraintSet(self: *Document, constraints: core.ConstraintSet) !void {
        for (constraints.items.items) |constraint| {
            try self.constraints.append(self.allocator, constraint);
            try self.terms.append(self.allocator, .{ .add_constraint = constraint });
        }
    }

    pub fn addValidationDiagnostic(
        self: *Document,
        severity: core.DiagnosticSeverity,
        page_id: ?HandleId,
        node_id: ?HandleId,
        origin: ?[]const u8,
        data: core.Diagnostic.Data,
    ) !void {
        try self.diagnostics.append(self.allocator, .{
            .phase = .validation,
            .severity = severity,
            .page_id = page_id,
            .node_id = node_id,
            .origin = origin,
            .data = data,
        });
    }

    pub fn getNode(self: *Document, id: HandleId) ?*core.Node {
        for (self.nodes.items) |*node| {
            if (node.id == id) return node;
        }
        return null;
    }

    pub fn childrenOf(self: *Document, parent: HandleId) ?[]const HandleId {
        const children = self.contains.get(parent) orelse return null;
        return children.items;
    }

    pub fn pageIndexOf(self: *Document, page_id: HandleId) usize {
        const node = self.getNode(page_id) orelse unreachable;
        return node.page_index.?;
    }

    pub fn pageCount(self: *Document) usize {
        return self.page_order.items.len;
    }

    pub fn parentPageOf(self: *Document, child_id: HandleId) ?HandleId {
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

    fn previousPageOf(self: *Document, page_id: HandleId) ?HandleId {
        for (self.page_order.items, 0..) |candidate, index| {
            if (candidate != page_id) continue;
            if (index == 0) return null;
            return self.page_order.items[index - 1];
        }
        return null;
    }

    fn ensureSort(self: *Document, value: core.Value, expected: core.SemanticSort, context: []const u8) !void {
        _ = self;
        const actual = valueSort(value);
        if (actual != expected) {
            std.debug.print("sort mismatch in {s}: expected {s}, got {s}\n", .{ context, @tagName(expected), @tagName(actual) });
            return error.InvalidSemanticSort;
        }
    }

    fn valueSort(value: core.Value) core.SemanticSort {
        return switch (value) {
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
    }

    fn singletonSelection(self: *Document, allocator: Allocator, item_sort: core.SelectionItemSort, provenance: []const u8, id: HandleId) !core.Selection {
        _ = self;
        var selection = core.Selection.init(item_sort, provenance);
        try selection.ids.append(allocator, id);
        return selection;
    }

    fn selectPageObjectsByRole(self: *Document, allocator: Allocator, page_id: HandleId, role: core.Role, provenance: []const u8) !core.Selection {
        var selection = core.Selection.init(.object, provenance);
        const children = self.contains.get(page_id) orelse return selection;
        for (children.items) |child_id| {
            const node = self.getNode(child_id) orelse continue;
            if (core.roleEq(node.role, role)) try selection.ids.append(allocator, child_id);
        }
        return selection;
    }

    fn selectDocumentObjectsByRole(self: *Document, allocator: Allocator, role: core.Role, provenance: []const u8) !core.Selection {
        var selection = core.Selection.init(.object, provenance);
        for (self.page_order.items) |page_id| {
            var page_selection = try self.selectPageObjectsByRole(allocator, page_id, role, provenance);
            defer page_selection.deinit(allocator);
            for (page_selection.ids.items) |id| try selection.ids.append(allocator, id);
        }
        return selection;
    }

    fn selectDocumentPages(self: *Document, allocator: Allocator, provenance: []const u8) !core.Selection {
        var selection = core.Selection.init(.page, provenance);
        for (self.page_order.items) |page_id| try selection.ids.append(allocator, page_id);
        return selection;
    }

    pub fn select(self: *Document, allocator: Allocator, base: core.Value, query: core.Query) !core.Value {
        try self.ensureSort(base, query.input, query.name);
        return switch (query.op) {
            .self_object => .{ .selection = try self.singletonSelection(allocator, .object, query.name, base.object) },
            .previous_page => .{ .page = self.previousPageOf(base.page) orelse return error.NoPreviousPage },
            .parent_page => .{ .page = self.parentPageOf(base.object) orelse return error.MissingParentPage },
            .page_objects_by_role => |role| .{ .selection = try self.selectPageObjectsByRole(allocator, base.page, role, query.name) },
            .document_objects_by_role => |role| .{ .selection = try self.selectDocumentObjectsByRole(allocator, role, query.name) },
            .document_pages => .{ .selection = try self.selectDocumentPages(allocator, query.name) },
        };
    }

    fn rewriteText(self: *Document, allocator: Allocator, from_id: HandleId, old: []const u8, new: []const u8) ![]const u8 {
        const from = self.getNode(from_id) orelse return error.UnknownNode;
        const source = from.content orelse return error.MissingContent;
        return std.mem.replaceOwned(u8, allocator, source, old, new);
    }

    fn copyNodeProperties(self: *Document, from_id: HandleId, to_id: HandleId) !void {
        const from = self.getNode(from_id) orelse return error.UnknownNode;
        for (from.properties.items) |property| try self.setNodeProperty(to_id, property.key, property.value);
    }

    pub fn deriveWithOrigin(self: *Document, page_id: HandleId, base: core.Value, transform: core.Transform, origin: []const u8) !HandleId {
        return self.deriveWithMode(page_id, true, base, transform, origin);
    }

    pub fn deriveDetachedWithOrigin(self: *Document, page_id: HandleId, base: core.Value, transform: core.Transform, origin: []const u8) !HandleId {
        return self.deriveWithMode(page_id, false, base, transform, origin);
    }

    fn deriveWithMode(self: *Document, page_id: HandleId, attached: bool, base: core.Value, transform: core.Transform, origin: []const u8) !HandleId {
        try self.ensureSort(base, transform.input, transform.name);
        return switch (transform.op) {
            .rewrite_text => |rewrite| blk: {
                const updated = try self.rewriteText(self.allocator, base.object, rewrite.old, rewrite.new);
                const id = try self.makeNodeWithOrigin(page_id, attached, .derived, base.object, "rewritten-copy", "code", .source, .code, updated, origin);
                try self.copyNodeProperties(base.object, id);
                break :blk id;
            },
            .highlight => |highlight| blk: {
                if (base.selection.item_sort != .object) return error.InvalidSelectionSort;
                const source_id = base.selection.first() orelse return error.EmptySelection;
                break :blk try self.makeNodeWithOrigin(page_id, attached, .derived, source_id, "highlight", "highlight", .overlay, .text, highlight.note, origin);
            },
            .page_number => blk: {
                const id = try self.makeNodeWithOrigin(page_id, attached, .derived, base.page, "page-number", "page_number", .text, .text, "", origin);
                if (attached) {
                    try self.addAnchorConstraint(id, .right, .{ .page = .right }, -core.PageLayout.page_number_right_inset, origin);
                    try self.addAnchorConstraint(id, .bottom, .{ .page = .bottom }, core.PageLayout.page_number_bottom_inset, origin);
                }
                break :blk id;
            },
            .toc => try self.deriveToc(page_id, attached, base.document, origin),
        };
    }

    fn deriveToc(self: *Document, page_id: HandleId, attached: bool, document_id: HandleId, origin: []const u8) !HandleId {
        const owned = try self.buildTocText(document_id);
        return self.makeNodeWithOrigin(page_id, attached, .derived, document_id, "toc", "toc", .text, .text, owned, origin);
    }

    fn buildTocText(self: *Document, document_id: HandleId) ![]const u8 {
        var pages = try self.select(self.allocator, .{ .document = document_id }, core.Query.documentPages());
        defer pages.deinit(self.allocator);
        var text = std.ArrayList(u8).empty;
        defer text.deinit(self.allocator);
        try text.appendSlice(self.allocator, "Table of Contents\n");
        for (pages.selection.ids.items) |member_page_id| {
            var titles = try self.select(self.allocator, .{ .page = member_page_id }, core.Query.pageObjectsByRole("title"));
            defer titles.deinit(self.allocator);
            const title_id = titles.firstId() orelse continue;
            const title = self.getNode(title_id) orelse continue;
            const line = try std.fmt.allocPrint(self.allocator, "- {s} .... {d}\n", .{ title.content.?, self.pageIndexOf(member_page_id) });
            try text.appendSlice(self.allocator, line);
        }
        return text.toOwnedSlice(self.allocator);
    }

    pub fn createFragment(
        self: *Document,
        page_id: HandleId,
        root: core.FragmentRoot,
        node_ids: std.ArrayList(HandleId),
        constraints: core.ConstraintSet,
        deps: std.ArrayList(*core.Fragment),
    ) !*core.Fragment {
        const fragment = try self.allocator.create(core.Fragment);
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

    pub fn materializeFragment(self: *Document, fragment: *core.Fragment) !void {
        if (fragment.materialized) return;
        for (fragment.deps.items) |dep| try self.materializeFragment(dep);
        for (fragment.node_ids.items) |node_id| {
            const node = self.getNode(node_id) orelse return error.UnknownNode;
            if (!node.attached) {
                node.attached = true;
                try self.addContainment(fragment.page_id, node_id);
            }
        }
        try self.addConstraintSet(fragment.constraints);
        if (fragment.root) |root| switch (root) {
            .constraints => |constraints| try self.addConstraintSet(constraints),
            else => {},
        };
        fragment.materialized = true;
        try self.terms.append(self.allocator, .{ .materialize_fragment = fragment });
    }
};
