const std = @import("std");
const model = @import("model");

pub const Page = struct {
    page_id: model.NodeId,
    node_ids: []model.NodeId = &.{},
    // Constraint topology must remain unchanged while these indexes are retained.
    constraint_indexes: []usize = &.{},

    fn deinit(self: *Page, allocator: std.mem.Allocator) void {
        allocator.free(self.node_ids);
        allocator.free(self.constraint_indexes);
    }
};

pub const Document = struct {
    pages: []Page = &.{},

    pub fn init(allocator: std.mem.Allocator, state: anytype) !Document {
        const builders = try allocator.alloc(PageBuilder, state.page_order.items.len);
        defer allocator.free(builders);
        for (builders) |*builder| builder.* = .{ .seen = std.AutoHashMap(model.NodeId, void).init(allocator) };
        defer for (builders) |*builder| builder.deinit(allocator);
        var page_indexes = std.AutoHashMap(model.NodeId, usize).init(allocator);
        defer page_indexes.deinit();
        var owners = std.AutoHashMap(model.NodeId, ?usize).init(allocator);
        defer owners.deinit();

        for (state.page_order.items, builders, 0..) |page_id, *builder, index| {
            try page_indexes.put(page_id, index);
            if (state.childrenOf(page_id)) |children| {
                for (children) |child_id| try builder.addNode(allocator, child_id);
            }
        }
        for (state.constraints.items, 0..) |constraint, index| {
            if (try pageIndexForNode(state, &page_indexes, &owners, constraint.target_node)) |page_index| {
                try builders[page_index].addNode(allocator, constraint.target_node);
                try builders[page_index].constraint_indexes.append(allocator, index);
            }
            switch (constraint.source) {
                .page => {},
                .node => |source| if (try pageIndexForNode(state, &page_indexes, &owners, source.node_id)) |page_index| {
                    try builders[page_index].addNode(allocator, source.node_id);
                },
            }
        }

        var result = Document{ .pages = try allocator.alloc(Page, builders.len) };
        for (result.pages, state.page_order.items) |*page, page_id| page.* = .{ .page_id = page_id };
        errdefer result.deinit(allocator);
        for (result.pages, builders) |*page, *builder| {
            page.node_ids = try builder.node_ids.toOwnedSlice(allocator);
            page.constraint_indexes = try builder.constraint_indexes.toOwnedSlice(allocator);
        }
        return result;
    }

    pub fn deinit(self: *Document, allocator: std.mem.Allocator) void {
        for (self.pages) |*page| page.deinit(allocator);
        allocator.free(self.pages);
    }
};

const PageBuilder = struct {
    node_ids: std.ArrayList(model.NodeId) = .empty,
    constraint_indexes: std.ArrayList(usize) = .empty,
    seen: std.AutoHashMap(model.NodeId, void),

    fn addNode(self: *PageBuilder, allocator: std.mem.Allocator, node_id: model.NodeId) !void {
        const entry = try self.seen.getOrPut(node_id);
        if (!entry.found_existing) try self.node_ids.append(allocator, node_id);
    }

    fn deinit(self: *PageBuilder, allocator: std.mem.Allocator) void {
        self.node_ids.deinit(allocator);
        self.constraint_indexes.deinit(allocator);
        self.seen.deinit();
    }
};

fn pageIndexForNode(state: anytype, pages: *const std.AutoHashMap(model.NodeId, usize), owners: *std.AutoHashMap(model.NodeId, ?usize), node_id: model.NodeId) !?usize {
    const entry = try owners.getOrPut(node_id);
    if (!entry.found_existing) {
        entry.value_ptr.* = if (state.layoutPageOfConstraintEndpoint(node_id)) |page_id| pages.get(page_id) else null;
    }
    return entry.value_ptr.*;
}
