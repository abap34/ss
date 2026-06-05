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
    unset_property: struct {
        node: HandleId,
        key: []const u8,
    },
    extend_render_env: struct {
        node: HandleId,
        op: []const u8,
        key: []const u8,
        value: []const u8,
    },
    set_content: struct {
        node: HandleId,
        value: []const u8,
    },
    add_metadata: struct {
        kind: []const u8,
        value: []const u8,
        page: ?HandleId,
        origin: ?[]const u8,
    },
    add_constraint: core.Constraint,
};

pub const Document = struct {
    allocator: Allocator,
    asset_base_dir: []const u8,
    document_id: HandleId,
    next_id: HandleId,
    nodes: std.ArrayList(core.Node),
    metadata: std.ArrayList(core.Metadata),
    page_order: std.ArrayList(HandleId),
    contains: std.AutoHashMap(HandleId, std.ArrayList(HandleId)),
    constraints: std.ArrayList(core.Constraint),
    diagnostics: std.ArrayList(core.Diagnostic),
    terms: std.ArrayList(Term),
    runtime_strings: std.ArrayList([]u8),
    next_metadata_id: core.MetadataId,
    type_source: ?*const core.Ir,

    pub fn init(allocator: Allocator, asset_base_dir: []const u8) !Document {
        const document_id: HandleId = 1;
        var doc = Document{
            .allocator = allocator,
            .asset_base_dir = asset_base_dir,
            .document_id = document_id,
            .next_id = document_id + 1,
            .nodes = .empty,
            .metadata = .empty,
            .page_order = .empty,
            .contains = std.AutoHashMap(HandleId, std.ArrayList(HandleId)).init(allocator),
            .constraints = .empty,
            .diagnostics = .empty,
            .terms = .empty,
            .runtime_strings = .empty,
            .next_metadata_id = 1,
            .type_source = null,
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
        for (self.runtime_strings.items) |text| self.allocator.free(text);
        self.runtime_strings.deinit(self.allocator);
        for (self.diagnostics.items) |*diagnostic| diagnostic.deinit(self.allocator);
        self.diagnostics.deinit(self.allocator);
        self.constraints.deinit(self.allocator);
        var it = self.contains.iterator();
        while (it.next()) |entry| entry.value_ptr.deinit(self.allocator);
        self.contains.deinit();
        self.page_order.deinit(self.allocator);
        for (self.nodes.items) |*node| node.deinit(self.allocator);
        self.nodes.deinit(self.allocator);
        for (self.metadata.items) |*metadata| metadata.deinit(self.allocator);
        self.metadata.deinit(self.allocator);
    }

    pub fn ownString(self: *Document, text: []u8) ![]const u8 {
        errdefer self.allocator.free(text);
        try self.runtime_strings.append(self.allocator, text);
        return text;
    }

    fn deinitTerm(term: *Term, allocator: Allocator) void {
        switch (term.*) {
            .set_property => |property| {
                allocator.free(property.key);
                allocator.free(property.value);
            },
            .unset_property => |property| allocator.free(property.key),
            .extend_render_env => |entry| {
                allocator.free(entry.op);
                allocator.free(entry.key);
                allocator.free(entry.value);
            },
            .set_content => |content| allocator.free(content.value),
            .add_metadata => |metadata| {
                allocator.free(metadata.kind);
                allocator.free(metadata.value);
                if (metadata.origin) |origin| allocator.free(origin);
            },
            else => {},
        }
    }

    fn freshId(self: *Document) HandleId {
        const id = self.next_id;
        self.next_id += 1;
        return id;
    }

    fn freshMetadataId(self: *Document) core.MetadataId {
        const id = self.next_metadata_id;
        self.next_metadata_id += 1;
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
        return self.makeNodeWithOrigin(page_id, true, .object, name, role, object_kind, payload_kind, content, origin);
    }

    pub fn makeGroupWithOrigin(
        self: *Document,
        page_id: HandleId,
        attached: bool,
        children: []const HandleId,
        origin: ?[]const u8,
    ) !HandleId {
        const group_id = try self.makeNodeWithOrigin(page_id, attached, .object, "group", core.GroupRole, .overlay, .text, "", origin);
        for (children) |child_id| try self.addContainment(group_id, child_id);
        return group_id;
    }

    fn makeNodeWithOrigin(
        self: *Document,
        page_id: HandleId,
        attached: bool,
        kind: core.NodeKind,
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
            .origin = origin,
        });
        try self.terms.append(self.allocator, .{ .make_node = .{
            .handle = id,
            .page = page_id,
            .attached = attached,
            .kind = kind,
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

    pub fn unsetNodeProperty(self: *Document, node_id: HandleId, key: []const u8) !void {
        const node = self.getNode(node_id) orelse return error.UnknownNode;
        for (node.properties.items, 0..) |property, index| {
            if (std.mem.eql(u8, property.key, key)) {
                self.allocator.free(property.key);
                self.allocator.free(property.value);
                _ = node.properties.orderedRemove(index);
                break;
            }
        }
        try self.terms.append(self.allocator, .{ .unset_property = .{
            .node = node_id,
            .key = try self.allocator.dupe(u8, key),
        } });
    }

    pub fn extendRenderEnv(self: *Document, node_id: HandleId, op: []const u8, key: []const u8, value: []const u8) !void {
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
        try self.terms.append(self.allocator, .{ .extend_render_env = .{
            .node = node_id,
            .op = try self.allocator.dupe(u8, op),
            .key = try self.allocator.dupe(u8, key),
            .value = try self.allocator.dupe(u8, value),
        } });
    }

    fn appendSetPropertyTerm(self: *Document, node_id: HandleId, key: []const u8, value: []const u8) !void {
        try self.terms.append(self.allocator, .{ .set_property = .{
            .node = node_id,
            .key = try self.allocator.dupe(u8, key),
            .value = try self.allocator.dupe(u8, value),
        } });
    }

    pub fn getNodeProperty(self: *Document, node_id: HandleId, key: []const u8) ?[]const u8 {
        const node = self.getNode(node_id) orelse return null;
        return core.nodeProperty(node, key);
    }

    pub fn setNodeContent(self: *Document, node_id: HandleId, value: []const u8) !void {
        const node = self.getNode(node_id) orelse return error.UnknownNode;
        const owned_value = try self.allocator.dupe(u8, value);
        if (node.content_owned) {
            if (node.content) |content| self.allocator.free(content);
        }
        node.content = owned_value;
        node.content_owned = true;
        try self.terms.append(self.allocator, .{ .set_content = .{
            .node = node_id,
            .value = try self.allocator.dupe(u8, value),
        } });
    }

    pub fn appendNodeContent(self: *Document, node_id: HandleId, value: []const u8) !void {
        const node = self.getNode(node_id) orelse return error.UnknownNode;
        const current = node.content orelse "";
        const updated = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ current, value });
        defer self.allocator.free(updated);
        try self.setNodeContent(node_id, updated);
    }

    pub fn emitMetadata(self: *Document, target: core.Value, kind: []const u8, value: []const u8, origin: ?[]const u8) !core.MetadataId {
        const page_id: ?HandleId = switch (target) {
            .document => null,
            .page => |id| id,
            .object => |id| self.parentPageOf(id) orelse return error.MissingParentPage,
            else => return error.InvalidValueTag,
        };
        return try self.addMetadata(kind, value, page_id, origin);
    }

    pub fn addMetadata(self: *Document, kind: []const u8, value: []const u8, page_id: ?HandleId, origin: ?[]const u8) !core.MetadataId {
        const id = self.freshMetadataId();
        try self.metadata.append(self.allocator, .{
            .id = id,
            .kind = try self.allocator.dupe(u8, kind),
            .value = try self.allocator.dupe(u8, value),
            .page_id = page_id,
            .origin = if (origin) |text| try self.allocator.dupe(u8, text) else null,
        });
        try self.terms.append(self.allocator, .{ .add_metadata = .{
            .kind = try self.allocator.dupe(u8, kind),
            .value = try self.allocator.dupe(u8, value),
            .page = page_id,
            .origin = if (origin) |text| try self.allocator.dupe(u8, text) else null,
        } });
        return id;
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
        var diagnostic = core.Diagnostic{
            .phase = .validation,
            .severity = severity,
            .page_id = page_id,
            .node_id = node_id,
            .origin = if (origin) |value| try self.allocator.dupe(u8, value) else null,
            .data = data,
        };
        errdefer diagnostic.deinit(self.allocator);
        try self.diagnostics.append(self.allocator, diagnostic);
    }

    pub fn getNode(self: *Document, id: HandleId) ?*core.Node {
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

    fn ensureValueTag(self: *Document, value: core.Value, expected: core.ValueTag, context: []const u8) !void {
        _ = self;
        const actual = runtimeKind(value);
        if (actual != expected) {
            std.debug.print("value type mismatch in {s}: expected {s}, got {s}\n", .{ context, @tagName(expected), @tagName(actual) });
            return error.InvalidValueTag;
        }
    }

    fn runtimeKind(value: core.Value) core.ValueTag {
        return switch (value) {
            .none => .none,
            .document => .document,
            .page => .page,
            .object => .object,
            .metadata => .metadata,
            .selection => .selection,
            .anchor => .anchor,
            .function => .function,
            .string => .string,
            .enum_case => .enum_case,
            .number => .number,
            .boolean => .boolean,
            .constraints => .constraints,
            .void => .void,
        };
    }

    fn singletonSelection(self: *Document, allocator: Allocator, item_tag: core.SelectionItemTag, provenance: []const u8, id: HandleId) !core.Selection {
        _ = self;
        var selection = core.Selection.init(item_tag, provenance);
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

    pub fn selectDocumentMetadataByKind(self: *Document, allocator: Allocator, kind: []const u8, provenance: []const u8) !core.Selection {
        var selection = core.Selection.init(.metadata, provenance);
        for (self.metadata.items) |item| {
            if (std.mem.eql(u8, item.kind, kind)) try selection.ids.append(allocator, item.id);
        }
        return selection;
    }

    pub fn selectPageMetadataByKind(self: *Document, allocator: Allocator, page_id: HandleId, kind: []const u8, provenance: []const u8) !core.Selection {
        var selection = core.Selection.init(.metadata, provenance);
        for (self.metadata.items) |item| {
            if (item.page_id != null and item.page_id.? == page_id and std.mem.eql(u8, item.kind, kind)) {
                try selection.ids.append(allocator, item.id);
            }
        }
        return selection;
    }

    pub fn metadataById(self: *Document, id: core.MetadataId) ?*core.Metadata {
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

    pub fn metadataContent(self: *Document, id: core.MetadataId) ![]const u8 {
        return (self.metadataById(id) orelse return error.UnknownMetadata).value;
    }

    pub fn metadataKind(self: *Document, id: core.MetadataId) ![]const u8 {
        return (self.metadataById(id) orelse return error.UnknownMetadata).kind;
    }

    pub fn metadataPage(self: *Document, id: core.MetadataId) !HandleId {
        return (self.metadataById(id) orelse return error.UnknownMetadata).page_id orelse return error.MissingParentPage;
    }

    fn selectChildren(self: *Document, allocator: Allocator, parent_id: HandleId, provenance: []const u8) !core.Selection {
        var selection = core.Selection.init(.object, provenance);
        const children = self.contains.get(parent_id) orelse return selection;
        for (children.items) |child_id| {
            const child = self.getNode(child_id) orelse continue;
            if (child.kind == .object) try selection.ids.append(allocator, child_id);
        }
        return selection;
    }

    fn appendDescendants(self: *Document, allocator: Allocator, parent_id: HandleId, selection: *core.Selection) !void {
        const children = self.contains.get(parent_id) orelse return;
        for (children.items) |child_id| {
            const child = self.getNode(child_id) orelse continue;
            if (child.kind == .object) try selection.ids.append(allocator, child_id);
            try self.appendDescendants(allocator, child_id, selection);
        }
    }

    fn selectDescendants(self: *Document, allocator: Allocator, parent_id: HandleId, provenance: []const u8) !core.Selection {
        var selection = core.Selection.init(.object, provenance);
        try self.appendDescendants(allocator, parent_id, &selection);
        return selection;
    }

    pub fn select(self: *Document, allocator: Allocator, base: core.Value, query: core.Query) !core.Value {
        try self.ensureValueTag(base, query.input, query.name);
        return switch (query.op) {
            .self_object => .{ .selection = try self.singletonSelection(allocator, .object, query.name, base.object) },
            .previous_page => .{ .page = self.previousPageOf(base.page) orelse return error.NoPreviousPage },
            .parent_page => .{ .page = self.parentPageOf(base.object) orelse return error.MissingParentPage },
            .children => .{ .selection = try self.selectChildren(allocator, base.object, query.name) },
            .descendants => .{ .selection = try self.selectDescendants(allocator, base.object, query.name) },
            .page_objects_by_role => |role| .{ .selection = try self.selectPageObjectsByRole(allocator, base.page, role, query.name) },
            .document_objects_by_role => |role| .{ .selection = try self.selectDocumentObjectsByRole(allocator, role, query.name) },
            .document_pages => .{ .selection = try self.selectDocumentPages(allocator, query.name) },
        };
    }
};
