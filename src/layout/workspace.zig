const std = @import("std");
const model = @import("model");
const document_state = @import("../core/document_state.zig");
const diagnostics = @import("../core/diagnostics.zig");
const document = @import("document.zig");
const partition = @import("partition.zig");

/// Mutable geometry and diagnostics for one page. The source generation is borrowed
/// and must outlive this workspace and every result derived from its constraints.
pub const Workspace = struct {
    allocator: std.mem.Allocator,
    source: *document_state.DocumentState,
    geometry: std.AutoHashMap(model.NodeId, document.ObjectFrame),
    diagnostics: diagnostics.DocumentDiagnostics = .{},

    pub fn init(allocator: std.mem.Allocator, source: *document_state.DocumentState, page: partition.Page) !Workspace {
        var self = Workspace{ .allocator = allocator, .source = source, .geometry = std.AutoHashMap(model.NodeId, document.ObjectFrame).init(allocator) };
        errdefer self.deinit();
        try self.geometry.put(page.page_id, .{ .node_id = page.page_id, .frame = document.pageFrame });
        for (page.node_ids) |id| try self.geometry.put(id, .{ .node_id = id, .frame = .{} });
        return self;
    }

    pub fn deinit(self: *Workspace) void {
        self.geometry.deinit();
        self.diagnostics.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn frame(self: *Workspace, id: model.NodeId) *model.Frame {
        return &self.geometry.getPtr(id).?.frame;
    }

    pub fn measurement(self: *Workspace, id: model.NodeId) *?model.LayoutMeasurement {
        return &self.geometry.getPtr(id).?.measurement;
    }

    fn addLayoutDiagnostic(self: *Workspace, severity: model.DiagnosticSeverity, page_id: model.NodeId, node_id: ?model.NodeId, data: model.Diagnostic.Data) !void {
        var diagnostic = model.Diagnostic{ .phase = .layout, .severity = severity, .page_id = page_id, .node_id = node_id, .origin = null, .data = data };
        errdefer diagnostic.deinit(self.allocator);
        if (node_id) |id| if (self.source.getNode(id)) |node| {
            if (node.origin) |origin| diagnostic.origin = try origin.clone(self.allocator);
        };
        try self.diagnostics.addDiagnostic(self.allocator, diagnostic);
    }

    pub fn addRenderDiagnostic(self: *Workspace, severity: model.DiagnosticSeverity, page_id: ?model.NodeId, node_id: ?model.NodeId, origin: ?model.SourceOrigin, data: model.Diagnostic.Data) !void {
        var diagnostic = model.Diagnostic{ .phase = .render, .severity = severity, .page_id = page_id, .node_id = node_id, .origin = null, .data = data };
        errdefer diagnostic.deinit(self.allocator);
        if (origin) |value| diagnostic.origin = try value.clone(self.allocator);
        try self.diagnostics.addDiagnostic(self.allocator, diagnostic);
    }

    pub fn addLayoutWarning(self: *Workspace, page_id: model.NodeId, node_id: ?model.NodeId, data: model.Diagnostic.Data) !void {
        try self.addLayoutDiagnostic(.warning, page_id, node_id, data);
    }

    pub fn addLayoutError(self: *Workspace, page_id: model.NodeId, node_id: ?model.NodeId, data: model.Diagnostic.Data) !void {
        try self.addLayoutDiagnostic(.@"error", page_id, node_id, data);
    }
};

/// Measurement callbacks may read source properties and write only this page's
/// diagnostics and geometry. Their resource caches must support concurrent jobs.
pub const MeasurementProvider = struct {
    context: *anyopaque,
    measure: *const fn (context: *anyopaque, workspace: *Workspace, node: *const model.Node, width: f32, mode: model.LayoutMeasurementMode) anyerror!?model.LayoutMeasurement,
};
