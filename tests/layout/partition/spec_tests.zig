const std = @import("std");
const core = @import("core");
const ast = @import("ast");
const testing = std.testing;
const partition = core.layout.partition;

const CountedDocument = struct {
    allocator: std.mem.Allocator,
    page_order: std.ArrayList(core.NodeId) = .empty,
    nodes: std.ArrayList(core.NodeId) = .empty,
    constraints: std.ArrayList(core.Constraint) = .empty,
    owner_queries: usize = 0,

    fn init(allocator: std.mem.Allocator, page_count: usize) !CountedDocument {
        var self = CountedDocument{ .allocator = allocator };
        errdefer self.deinit();
        for (0..page_count) |index| {
            try self.page_order.append(allocator, @intCast(index + 1));
            const first: core.NodeId = @intCast(100000 + index * 2);
            try self.nodes.appendSlice(allocator, &.{ first, first + 1 });
            for (0..4) |offset| {
                try self.constraints.append(allocator, .{
                    .target_node = first,
                    .target_anchor = .left,
                    .source = .{ .node = .{ .node_id = first + 1, .anchor = .right } },
                    .offset = @floatFromInt(offset),
                });
            }
        }
        return self;
    }

    fn deinit(self: *CountedDocument) void {
        self.page_order.deinit(self.allocator);
        self.nodes.deinit(self.allocator);
        self.constraints.deinit(self.allocator);
    }

    pub fn childrenOf(self: *CountedDocument, page_id: core.NodeId) ?[]const core.NodeId {
        const start = (page_id - 1) * 2;
        return self.nodes.items[start .. start + 2];
    }

    pub fn layoutPageOfConstraintEndpoint(self: *CountedDocument, node_id: core.NodeId) ?core.NodeId {
        self.owner_queries += 1;
        return (node_id - 100000) / 2 + 1;
    }
};

fn partitionCountedDocument(allocator: std.mem.Allocator, page_count: usize) !void {
    var state = try CountedDocument.init(allocator, page_count);
    defer state.deinit();
    var result = try partition.Document.init(allocator, &state);
    defer result.deinit(allocator);
    try testing.expectEqual(page_count, result.pages.len);
    try testing.expectEqual(page_count * 2, state.owner_queries);
    for (result.pages, 0..) |page, index| {
        try testing.expectEqualSlices(core.NodeId, state.nodes.items[index * 2 .. index * 2 + 2], page.node_ids);
        try testing.expectEqual(@as(usize, 4), page.constraint_indexes.len);
        for (page.constraint_indexes, 0..) |constraint_index, position| {
            try testing.expectEqual(index * 4 + position, constraint_index);
        }
    }
}

test "layout partition: increasing page counts visits each constraint endpoint once" {
    for ([_]usize{ 0, 1, 32, 64, 128, 256 }) |count| try partitionCountedDocument(testing.allocator, count);
}

test "layout partition: allocation failures release builders and transferred pages" {
    try testing.checkAllAllocationFailures(testing.allocator, partitionCountedDocument, .{@as(usize, 4)});
}

fn emptyState() !core.DocumentState {
    const base = try testing.allocator.dupe(u8, ".");
    errdefer testing.allocator.free(base);
    const path = try testing.allocator.dupe(u8, "partition.ss");
    errdefer testing.allocator.free(path);
    const source = try testing.allocator.dupe(u8, "");
    errdefer testing.allocator.free(source);
    return core.DocumentState.init(testing.allocator, base, path, source, ast.Module.init());
}

test "layout partition: implicit groups retain page ownership and foreign endpoints stay external" {
    var state = try emptyState();
    defer state.deinit();
    const first = try state.addPage("first");
    const second = try state.addPage("second");
    const a = try state.makeObject(first, "a", null, .text, .text, "a");
    const b = try state.makeObject(first, "b", null, .text, .text, "b");
    const foreign = try state.makeObject(second, "foreign", null, .text, .text, "foreign");
    const unused = try state.createObjectWithOrigin("unused", null, .text, .text, "unused", null);
    const group = try state.createGroupWithOrigin(&.{ a, b }, null);
    try state.addAnchorConstraint(group, .left, .{ .page = .left }, 10, null);
    try state.addAnchorConstraint(a, .left, .{ .node = .{ .node_id = foreign, .anchor = .left } }, 20, null);
    try state.addAnchorConstraint(b, .left, .{ .node = .{ .node_id = unused, .anchor = .left } }, 30, null);
    var prepared = try core.prepared.prepare(testing.allocator, &state);
    defer prepared.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), prepared.layout.pages.len);
    try testing.expectEqualSlices(core.NodeId, &.{ a, b, group }, prepared.layout.pages[0].node_ids);
    try testing.expectEqualSlices(core.NodeId, &.{foreign}, prepared.layout.pages[1].node_ids);
    try testing.expectEqual(@as(usize, 3), prepared.layout.pages[0].constraint_indexes.len);
    try testing.expectEqual(@as(usize, 0), prepared.layout.pages[1].constraint_indexes.len);
    try testing.expectEqual(@as(usize, 3), prepared.pages[0].objects.len);
    var graph = try core.layout.graph.PageLayoutGraph.init(testing.allocator, &state, prepared.layout.pages[0]);
    defer graph.deinit();
    try testing.expect(graph.indexOf(group) != null);
    try testing.expect(graph.indexOf(foreign) == null);
    try testing.expect(graph.indexOf(unused) == null);
    try state.validatePageLocalLayout();
    var cross_page = false;
    var unowned = false;
    for (state.diagnostics.items) |diagnostic| switch (diagnostic.data) {
        .user_report => |report| {
            cross_page = cross_page or std.mem.startsWith(u8, report.message, "CrossPageConstraint:");
            unowned = unowned or std.mem.startsWith(u8, report.message, "UnownedLayoutObject:");
        },
        else => {},
    };
    try testing.expect(cross_page);
    try testing.expect(unowned);
}

test "layout partition: prepared graphs read updated offsets without repeating partition work" {
    var state = try emptyState();
    defer state.deinit();
    const page = try state.addPage("page");
    const object = try state.makeObject(page, "object", null, .text, .text, "body");
    try state.addAnchorConstraint(object, .left, .{ .page = .left }, 10, null);
    var prepared = try core.prepared.prepare(testing.allocator, &state);
    defer prepared.deinit(testing.allocator);
    state.constraints.items[0].offset = 45;
    var graph = try core.layout.graph.PageLayoutGraph.init(testing.allocator, &state, prepared.layout.pages[0]);
    defer graph.deinit();
    try testing.expectEqual(@as(f32, 45), graph.constraints[0].offset);
    var result = try state.finalizeDocument(null, .{ .page_inputs = prepared.layout.pages });
    defer result.deinit(testing.allocator);
    try testing.expectApproxEqAbs(@as(f32, 45), state.getNode(object).?.frame.x, core.layout.graph.ConstraintTolerance);
}
