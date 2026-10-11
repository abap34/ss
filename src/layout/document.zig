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

pub const pageFrame: model.Frame = .{ .width = Defaults.width, .height = Defaults.height, .x_set = true, .y_set = true };

pub const ObjectFrame = struct {
    node_id: model.NodeId,
    frame: model.Frame,
    measurement: ?model.LayoutMeasurement = null,
};

/// Owns geometry and diagnostics; constraint origins borrow the evaluated source generation.
pub const Page = struct {
    page_id: model.NodeId,
    index: usize,
    converged: bool = true,
    failure: ?anyerror = null,
    frame: model.Frame = pageFrame,
    object_frames: []ObjectFrame,
    fallback_constraints: []model.Constraint = &.{},
    diagnostics: []model.Diagnostic = &.{},
    constraint_failures: []model.ConstraintFailure = &.{},

    pub fn validate(self: *const Page) !void {
        if (self.failure) |err| return err;
        if (self.constraint_failures.len > 0) return switch (self.constraint_failures[0].kind) {
            .conflict => error.ConstraintConflict,
            .negative_frame_size => error.NegativeFrameSize,
        };
        if (!self.converged) return error.LayoutDidNotConverge;
        for (self.diagnostics) |diagnostic| if (diagnostic.severity == .@"error") return error.DiagnosticsFailed;
    }

    pub fn measurementOf(self: *const Page, node_id: model.NodeId) ?model.LayoutMeasurement {
        for (self.object_frames) |entry| if (entry.node_id == node_id) return entry.measurement;
        return null;
    }

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
        if (node_id == self.page_id) return self.frame;
        for (self.object_frames) |entry| {
            if (entry.node_id == node_id) return entry.frame;
        }
        return null;
    }
};

pub const Document = struct {
    pages: []Page = &.{},

    pub fn failureCount(self: *const Document) usize {
        var count: usize = 0;
        for (self.pages) |page| count += page.constraint_failures.len;
        return count;
    }

    pub fn measurementOf(self: *const Document, node_id: model.NodeId) ?model.LayoutMeasurement {
        for (self.pages) |*page| if (page.measurementOf(node_id)) |measurement| return measurement;
        return null;
    }

    /// Transfer selected results into this generation, preserving all other pages.
    pub fn replacePages(self: *Document, allocator: std.mem.Allocator, incoming: *Document) !void {
        if (self == incoming) return error.InvalidPageLayoutInputs;
        for (incoming.pages) |page| {
            const previous = self.pageById(page.page_id) orelse return error.InvalidPageLayoutInputs;
            if (previous.index != page.index) return error.InvalidPageLayoutInputs;
        }
        for (incoming.pages) |*page| {
            for (self.pages) |*existing| if (existing.page_id == page.page_id) {
                existing.deinit(allocator);
                existing.* = page.*;
                page.* = .{ .page_id = 0, .index = 0, .object_frames = &.{} };
                break;
            };
        }
    }

    pub fn validate(self: *const Document) !void {
        for (self.pages) |*page| try page.validate();
    }

    pub fn nodeFrame(self: *const Document, node_id: model.NodeId) ?model.Frame {
        for (self.pages) |*page| if (page.frameOf(node_id)) |frame| return frame;
        return null;
    }

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
