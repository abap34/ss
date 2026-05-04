const std = @import("std");
const core = @import("core");
const stage0 = @import("../stage0/eval.zig");
const doc = @import("../stage0/doc.zig");
const typecheck = @import("../analysis/typecheck.zig");

const NormalizeContext = struct {
    allocator: std.mem.Allocator,
    node_map: std.AutoHashMap(doc.HandleId, core.NodeId),

    fn init(allocator: std.mem.Allocator, document_handle: doc.HandleId, document_node: core.NodeId) !NormalizeContext {
        var ctx = NormalizeContext{
            .allocator = allocator,
            .node_map = std.AutoHashMap(doc.HandleId, core.NodeId).init(allocator),
        };
        errdefer ctx.deinit();
        try ctx.node_map.put(document_handle, document_node);
        return ctx;
    }

    fn deinit(self: *NormalizeContext) void {
        self.node_map.deinit();
    }

    fn put(self: *NormalizeContext, handle: doc.HandleId, node_id: core.NodeId) !void {
        try self.node_map.put(handle, node_id);
    }

    fn node(self: *NormalizeContext, handle: doc.HandleId) !core.NodeId {
        return self.node_map.get(handle) orelse error.UnknownNode;
    }

    fn maybeNode(self: *NormalizeContext, handle: ?doc.HandleId) !?core.NodeId {
        return if (handle) |id| try self.node(id) else null;
    }
};

pub fn lowerToIr(ir: *core.Ir) !void {
    var code = try stage0.elaborateProgram(
        ir.allocator,
        ir.asset_base_dir,
        ir.projectProgram(),
        ir.projectSource(),
        ir.projectPath(),
        &ir.functions,
    );
    defer code.deinit();

    try normalizeDocumentCode(ir, &code);
    try ir.finalize();
    try typecheck.refreshSolvedFrameHints(ir.allocator, ir);
}

pub fn normalizeDocumentCode(ir: *core.Ir, code: *doc.Document) !void {
    var ctx = try NormalizeContext.init(ir.allocator, code.document_id, ir.document_id);
    defer ctx.deinit();

    for (code.terms.items) |term| {
        switch (term) {
            .add_page => |page| {
                const node_id = try ir.addPage(page.name);
                try ctx.put(page.handle, node_id);
            },
            .make_node => |node| {
                const page_id = try ctx.node(node.page);
                const derived_from = try ctx.maybeNode(node.derived_from);
                const node_id = try ir.makeNodeFromStage(
                    page_id,
                    node.attached,
                    node.kind,
                    derived_from,
                    node.name,
                    node.role,
                    node.object_kind,
                    node.payload_kind,
                    node.content,
                    node.origin,
                );
                try ctx.put(node.handle, node_id);
            },
            .add_containment => |edge| {
                const parent = try ctx.node(edge.parent);
                const child = try ctx.node(edge.child);
                try ir.addContainmentFromStage(parent, child);
            },
            .set_property => |property| {
                try ir.setNodeProperty(try ctx.node(property.node), property.key, property.value);
            },
            .add_constraint => |constraint| {
                try ir.constraints.append(ir.allocator, try mapConstraint(&ctx, constraint));
            },
            .materialize_fragment => {},
        }
    }

    for (code.diagnostics.items) |diagnostic| {
        try ir.addDiagnostic(try mapDiagnostic(&ctx, diagnostic));
    }
    code.diagnostics.items.len = 0;
}

fn mapConstraint(ctx: *NormalizeContext, constraint: core.Constraint) !core.Constraint {
    return .{
        .target_node = try ctx.node(constraint.target_node),
        .target_anchor = constraint.target_anchor,
        .source = try mapConstraintSource(ctx, constraint.source),
        .offset = constraint.offset,
        .origin = constraint.origin,
    };
}

fn mapConstraintSource(ctx: *NormalizeContext, source: core.ConstraintSource) !core.ConstraintSource {
    return switch (source) {
        .page => |anchor| .{ .page = anchor },
        .node => |node| .{ .node = .{ .node_id = try ctx.node(node.node_id), .anchor = node.anchor } },
    };
}

fn mapDiagnostic(ctx: *NormalizeContext, diagnostic: core.Diagnostic) !core.Diagnostic {
    return .{
        .phase = diagnostic.phase,
        .severity = diagnostic.severity,
        .page_id = try ctx.maybeNode(diagnostic.page_id),
        .node_id = try ctx.maybeNode(diagnostic.node_id),
        .origin = diagnostic.origin,
        .data = diagnostic.data,
    };
}
