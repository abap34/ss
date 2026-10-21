const document_testing = @import("document_testing");
const LayoutFixture = @import("layout_testing").Fixture;
const std = @import("std");
const allocation_testing = @import("allocation_testing");
const core = @import("core");
const ast = @import("ast");
const testing = std.testing;
const partition = core.layout.partition;

const CountedDocument = struct {
    allocator: std.mem.Allocator,
    graph: struct {
        page_order: std.ArrayList(core.NodeId) = .empty,
        nodes: std.ArrayList(core.NodeId) = .empty,
    } = .{},
    constraints: struct {
        active: std.ArrayList(core.Constraint) = .empty,
    } = .{},
    owner_queries: usize = 0,

    fn init(allocator: std.mem.Allocator, page_count: usize) !CountedDocument {
        var self = CountedDocument{ .allocator = allocator };
        errdefer self.deinit();
        for (0..page_count) |index| {
            try self.graph.page_order.append(allocator, @intCast(index + 1));
            const first: core.NodeId = @intCast(100000 + index * 2);
            try self.graph.nodes.appendSlice(allocator, &.{ first, first + 1 });
            for (0..4) |offset| {
                try self.constraints.active.append(allocator, .{
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
        self.graph.page_order.deinit(self.allocator);
        self.graph.nodes.deinit(self.allocator);
        self.constraints.active.deinit(self.allocator);
    }

    pub fn childrenOf(self: *CountedDocument, page_id: core.NodeId) ?[]const core.NodeId {
        if (page_id >= 100000) return null;
        const start = (page_id - 1) * 2;
        return self.graph.nodes.items[start .. start + 2];
    }

    pub fn layoutPageOf(self: *CountedDocument, node_id: core.NodeId) ?core.NodeId {
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
        try testing.expectEqualSlices(core.NodeId, state.graph.nodes.items[index * 2 .. index * 2 + 2], page.node_ids);
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
    try allocation_testing.checkAllAllocationFailures(testing.allocator, partitionCountedDocument, .{@as(usize, 4)});
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

test "layout partition: registered placement descendants remain in their owning page" {
    var state = try emptyState();
    defer state.deinit();
    const first_page = try state.addPage("First");
    const second_page = try state.addPage("Second");
    var input = core.RecordValue.init(ast.Type.recordType("Content").inModule(0));
    defer input.deinit(testing.allocator);
    const first = try state.registerPlacement(first_page, .{ .record = input }, null);
    const child = try state.registerPlacement(first, .{ .record = input }, null);
    const grandchild = try state.registerPlacement(child, .{ .record = input }, null);
    const second = try state.registerPlacement(second_page, .{ .record = input }, null);
    const other_child = try state.registerPlacement(second, .{ .record = input }, null);
    try state.constraints.addAnchor(state.allocator, grandchild, .left, .{ .node = .{ .node_id = first, .anchor = .left } }, 24, null);

    var result = try partition.Document.init(testing.allocator, &state);
    defer result.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), result.pages.len);
    try testing.expectEqualSlices(core.NodeId, &.{first}, state.childrenOf(first_page).?);
    try testing.expectEqual(@as(usize, 3), result.pages[0].node_ids.len);
    for ([_]core.NodeId{ first, child, grandchild }) |id| {
        try testing.expect(std.mem.indexOfScalar(core.NodeId, result.pages[0].node_ids, id) != null);
    }
    try testing.expectEqualSlices(core.NodeId, &.{ second, other_child }, result.pages[1].node_ids);
    try testing.expectEqualSlices(usize, &.{0}, result.pages[0].constraint_indexes);
    try testing.expectEqual(@as(usize, 0), result.pages[1].constraint_indexes.len);
}

test "prepared pages preserve nested child order regardless of constraint discovery" {
    var state = try emptyState();
    defer state.deinit();
    const page = try state.addPage("Paint order");
    var input = core.RecordValue.init(ast.Type.recordType("Content").inModule(0));
    defer input.deinit(testing.allocator);
    const first = try state.registerPlacement(page, .{ .record = input }, null);
    const second = try state.registerPlacement(page, .{ .record = input }, null);
    const second_child = try state.registerPlacement(second, .{ .record = input }, null);
    const background = try state.registerPlacement(first, .{ .record = input }, null);
    const foreground = try state.registerPlacement(first, .{ .record = input }, null);
    const expected = [_]core.NodeId{ first, background, foreground, second, second_child };
    for (expected) |id| state.getNode(id).?.placement.?.display = .group;
    try state.constraints.addAnchor(state.allocator, foreground, .left, .{ .node = .{ .node_id = background, .anchor = .left } }, 16, null);
    for (0..2) |_| {
        var prepared = try core.prepared.prepare(testing.allocator, &state);
        defer prepared.deinit(testing.allocator);
        try testing.expectEqual(expected.len, prepared.pages[0].objects.len);
        for (expected, prepared.pages[0].objects) |id, object| try testing.expectEqual(id, object.node_id);
        state.constraints.active.clearRetainingCapacity();
    }
}

const MeasuredPages = struct {
    mask: u8 = 0,

    fn measure(context: *anyopaque, area: *core.layout.Workspace, node: *const core.Node, _: f32, _: core.LayoutMeasurementMode) anyerror!?core.LayoutMeasurement {
        const self: *MeasuredPages = @ptrCast(@alignCast(context));
        const state = area.source;
        const page = state.layoutPageOf(node.id) orelse return error.UnknownNode;
        self.mask |= @as(u8, 1) << @as(u3, @intCast(state.pageIndexOf(page) - 1));
        return .{ .width = 100, .height = 40 };
    }
};

test "layout partition: solving one page preserves other frames and fallback ordering" {
    var state = try emptyState();
    defer state.deinit();
    var geometry = LayoutFixture.init(&state);
    defer geometry.deinit();
    var nodes: [3]core.NodeId = undefined;
    for (&nodes) |*node| {
        const page = try state.addPage("page");
        node.* = try document_testing.native(&state, page, "body", .text, "body");
        _ = try document_testing.native(&state, page, "next", .text, "next");
        try state.constraints.addAnchor(state.allocator, node.*, .left, .{ .page = .left }, 60, null);
    }
    var measured = MeasuredPages{};
    const options = core.layout.graph.SolveOptions{ .measurement_provider = .{
        .context = &measured,
        .measure = MeasuredPages.measure,
    } };
    var initial = try core.layout.solver.finalizeDocument(&state, null, options);
    defer initial.deinit(testing.allocator);
    try testing.expectError(error.InvalidPageLayoutInputs, initial.replacePages(testing.allocator, &initial));
    try testing.expectEqual(@as(u8, 7), measured.mask);
    const first = initial.nodeFrame(nodes[0]).?;
    const last = initial.nodeFrame(nodes[2]).?;
    var inputs = try partition.Document.init(testing.allocator, &state);
    defer inputs.deinit(testing.allocator);
    state.constraints.active.items[1].offset = 80;
    measured.mask = 0;
    var selected = try core.layout.solver.solvePage(&state, inputs.pages[1], 1, null, options);
    defer selected.deinit(testing.allocator);
    const selected_pages = try testing.allocator.alloc(core.layout.Page, 1);
    selected_pages[0] = selected;
    selected = .{ .page_id = 0, .index = 0, .object_frames = &.{} };
    var selected_document = core.layout.Document{ .pages = selected_pages };
    defer selected_document.deinit(testing.allocator);
    try initial.replacePages(testing.allocator, &selected_document);
    try testing.expectEqual(@as(u8, 2), measured.mask);
    try testing.expectEqualDeep(first, initial.nodeFrame(nodes[0]).?);
    try testing.expectEqualDeep(last, initial.nodeFrame(nodes[2]).?);
    try testing.expectApproxEqAbs(@as(f32, 80), initial.nodeFrame(nodes[1]).?.x, core.layout.graph.ConstraintTolerance);

    var full = try core.layout.solver.finalizeDocument(&state, null, options);
    defer full.deinit(testing.allocator);
    for (full.pages, initial.pages) |expected, actual| {
        try testing.expectEqualDeep(expected.object_frames, actual.object_frames);
        try testing.expectEqualDeep(expected.fallback_constraints, actual.fallback_constraints);
    }
    try testing.expectError(error.InvalidPageLayoutInputs, core.layout.solver.solvePage(&state, inputs.pages[1], 0, null, options));
}

test "layout partition: adopted groups retain page ownership and foreign endpoints stay external" {
    var state = try emptyState();
    defer state.deinit();
    var geometry = LayoutFixture.init(&state);
    defer geometry.deinit();
    const first = try state.addPage("first");
    const second = try state.addPage("second");
    const a = try document_testing.native(&state, first, "a", .text, "a");
    const b = try document_testing.native(&state, first, "b", .text, "b");
    const foreign = try document_testing.native(&state, second, "foreign", .text, "foreign");

    const group = try document_testing.group(&state, first, &.{ a, b }, null);
    try state.constraints.addAnchor(state.allocator, group, .left, .{ .page = .left }, 10, null);
    try state.constraints.addAnchor(state.allocator, a, .left, .{ .node = .{ .node_id = foreign, .anchor = .left } }, 20, null);
    var prepared = try core.prepared.prepare(testing.allocator, &state);
    defer prepared.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), prepared.layout.pages.len);
    try testing.expectEqualSlices(core.NodeId, &.{ group, a, b }, prepared.layout.pages[0].node_ids);
    try testing.expectEqualSlices(core.NodeId, &.{foreign}, prepared.layout.pages[1].node_ids);
    try testing.expectEqual(@as(usize, 2), prepared.layout.pages[0].constraint_indexes.len);
    try testing.expectEqual(@as(usize, 0), prepared.layout.pages[1].constraint_indexes.len);
    try testing.expectEqual(@as(usize, 3), prepared.pages[0].objects.len);
    var graph = try core.layout.graph.PageLayoutGraph.init(testing.allocator, try geometry.work(), prepared.layout.pages[0]);
    defer graph.deinit();
    try testing.expect(graph.indexOf(group) != null);
    try testing.expect(graph.indexOf(foreign) == null);
    try state.validatePageLocalLayout();
    var cross_page = false;
    for (state.diagnostics.entries.items) |diagnostic| switch (diagnostic.data) {
        .user_report => |report| {
            cross_page = cross_page or std.mem.eql(u8, report.code, "CrossPageConstraint");
        },
        else => {},
    };
    try testing.expect(cross_page);
}

test "layout partition: adopted groups retain their entire nested subtree" {
    var state = try emptyState();
    defer state.deinit();
    var geometry = LayoutFixture.init(&state);
    defer geometry.deinit();
    const page = try state.addPage("page");
    const first = try document_testing.native(&state, page, "first", .text, "First");
    const second = try document_testing.native(&state, page, "second", .text, "Second");
    const third = try document_testing.native(&state, page, "third", .text, "Third");
    const after = try document_testing.native(&state, page, "after", .text, "After");
    const inner = try document_testing.group(&state, page, &.{ first, second }, null);
    const outer = try document_testing.group(&state, page, &.{ inner, third }, null);
    try state.constraints.addAnchor(state.allocator, after, .left, .{ .node = .{ .node_id = outer, .anchor = .right } }, 16, null);

    var prepared = try core.prepared.prepare(testing.allocator, &state);
    defer prepared.deinit(testing.allocator);
    try testing.expectEqualSlices(core.NodeId, &.{ after, outer, inner, third, first, second }, prepared.layout.pages[0].node_ids);
    try testing.expectEqual(@as(usize, 1), prepared.layout.pages[0].constraint_indexes.len);
    try testing.expectEqual(@as(usize, 6), prepared.pages[0].objects.len);
    for (prepared.pages[0].objects) |object| try testing.expect(object.attached);
    var graph = try core.layout.graph.PageLayoutGraph.init(testing.allocator, try geometry.work(), prepared.layout.pages[0]);
    defer graph.deinit();
    try testing.expect(graph.indexOf(outer) != null);
    try testing.expect(graph.indexOf(inner) != null);
}

test "layout partition: prepared graphs read updated offsets without repeating partition work" {
    var state = try emptyState();
    defer state.deinit();
    var geometry = LayoutFixture.init(&state);
    defer geometry.deinit();
    const page = try state.addPage("page");
    const object = try document_testing.native(&state, page, "object", .text, "body");
    try state.constraints.addAnchor(state.allocator, object, .left, .{ .page = .left }, 10, null);
    var prepared = try core.prepared.prepare(testing.allocator, &state);
    defer prepared.deinit(testing.allocator);
    state.constraints.active.items[0].offset = 45;
    var graph = try core.layout.graph.PageLayoutGraph.init(testing.allocator, try geometry.work(), prepared.layout.pages[0]);
    defer graph.deinit();
    try testing.expectEqual(@as(f32, 45), graph.constraints[0].offset);
    var result = try core.layout.solver.finalizeDocument(&state, null, .{ .page_inputs = prepared.layout.pages });
    defer result.deinit(testing.allocator);
    try testing.expectApproxEqAbs(@as(f32, 45), result.nodeFrame(object).?.x, core.layout.graph.ConstraintTolerance);
}
