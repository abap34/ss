const std = @import("std");
const core = @import("core");

/// Test fixtures may seed geometry independently of evaluated source objects.
/// Full solves replace result; graph and measurement unit tests use work().
pub const Fixture = struct {
    source: *core.DocumentState,
    result: core.layout.Document = .{},
    area: core.layout.Workspace,

    pub fn init(source: *core.DocumentState) Fixture {
        return .{ .source = source, .area = .{
            .allocator = source.allocator,
            .source = source,
            .geometry = std.AutoHashMap(core.NodeId, core.layout.ObjectFrame).init(source.allocator),
        } };
    }

    pub fn deinit(self: *Fixture) void {
        self.result.deinit(self.source.allocator);
        self.area.deinit();
    }

    pub fn work(self: *Fixture) !*core.layout.Workspace {
        for (self.source.graph.nodes.items) |node| {
            const entry = try self.area.geometry.getOrPut(node.id);
            if (!entry.found_existing) entry.value_ptr.* = .{ .node_id = node.id, .frame = if (node.kind == .page) core.layout.document.pageFrame else .{} };
        }
        return &self.area;
    }

    pub fn frame(self: *Fixture, node_id: core.NodeId) !*core.Frame {
        for (self.result.pages) |*page| {
            if (page.page_id == node_id) return &page.frame;
            for (page.object_frames) |*entry| if (entry.node_id == node_id) return &entry.frame;
        }
        return (try self.work()).frame(node_id);
    }

    /// Build an owned layout input from explicitly seeded test geometry.
    pub fn document(self: *Fixture) !*const core.layout.Document {
        if (self.result.pages.len != 0) return &self.result;
        var partition = try core.layout.partition.Document.init(self.source.allocator, self.source);
        defer partition.deinit(self.source.allocator);
        _ = try self.work();
        const pages = try self.source.allocator.alloc(core.layout.Page, partition.pages.len);
        for (pages) |*page| page.* = .{ .page_id = 0, .index = 0, .object_frames = &.{} };
        self.result = .{ .pages = pages };
        for (pages, partition.pages, 0..) |*page, inputs, index| {
            page.page_id = inputs.page_id;
            page.index = index;
            page.frame = self.area.frame(inputs.page_id).*;
            page.object_frames = try self.source.allocator.alloc(core.layout.ObjectFrame, inputs.node_ids.len);
            for (page.object_frames, inputs.node_ids) |*entry, id| entry.* = self.area.geometry.get(id).?;
        }
        return &self.result;
    }

    pub fn solve(self: *Fixture, trace_path: ?[]const u8, options: core.layout.graph.SolveOptions, detailed: bool) !void {
        self.result.deinit(self.source.allocator);
        self.result = if (detailed)
            try core.layout.solver.finalizeDocument(self.source, trace_path, options)
        else
            try core.layout.solver.solveDocument(self.source, trace_path, options);
        // Warnings and fit-policy errors are asserted separately by these tests.
        for (self.result.pages) |page| {
            if (page.constraint_failures.len > 0 and detailed) return page.validate();
            if (!page.converged) return error.LayoutDidNotConverge;
        }
    }
};
