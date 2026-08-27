const std = @import("std");
const model = @import("model");

pub const Defaults = struct {
    pub const width: f32 = 1280;
    pub const height: f32 = 720;
    pub const flow_margin_x: f32 = 60;
    pub const flow_top: f32 = 660;
    pub const content_indent: f32 = 18;
    pub const max_visual_width: f32 = 1160;
    pub const default_asset_width: f32 = 220;
    pub const max_figure_height: f32 = 220;
    pub const max_math_height: f32 = 80;
};

pub const ObjectFrame = struct {
    node_id: model.NodeId,
    frame: model.Frame,
};

pub const Page = struct {
    page_id: model.NodeId,
    index: usize,
    object_frames: []ObjectFrame,
    fallback_constraints: []model.Constraint = &.{},
    diagnostics: []model.Diagnostic = &.{},
    constraint_failures: []model.ConstraintFailure = &.{},

    pub fn deinit(self: *Page, allocator: std.mem.Allocator) void {
        allocator.free(self.object_frames);
        allocator.free(self.fallback_constraints);
        for (self.diagnostics) |*diagnostic| diagnostic.deinit(allocator);
        allocator.free(self.diagnostics);
        for (self.constraint_failures) |*failure| failure.deinit(allocator);
        allocator.free(self.constraint_failures);
        self.* = .{
            .page_id = 0,
            .index = 0,
            .object_frames = &.{},
        };
    }

    pub fn frameOf(self: *const Page, node_id: model.NodeId) ?model.Frame {
        for (self.object_frames) |entry| {
            if (entry.node_id == node_id) return entry.frame;
        }
        return null;
    }
};

pub const Document = struct {
    pages: []Page = &.{},

    pub fn deinit(self: *Document, allocator: std.mem.Allocator) void {
        for (self.pages) |*page| page.deinit(allocator);
        allocator.free(self.pages);
        self.* = .{};
    }

    pub fn pageById(self: *const Document, page_id: model.NodeId) ?*const Page {
        for (self.pages) |*page| {
            if (page.page_id == page_id) return page;
        }
        return null;
    }

    pub fn frameOf(self: *const Document, page_id: model.NodeId, node_id: model.NodeId) ?model.Frame {
        const page = self.pageById(page_id) orelse return null;
        return page.frameOf(node_id);
    }
};
