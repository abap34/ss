const std = @import("std");
const core = @import("core");
const elaboration = @import("../elaboration/eval.zig");
const doc = @import("../elaboration/document.zig");
const editor = @import("../analysis/editor.zig");

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
    var code = try doc.Document.init(ir.allocator, ir.asset_base_dir);
    elaboration.elaborateIrInto(ir.allocator, ir, &code) catch |err| {
        try appendDocumentDiagnosticsWithoutHandles(ir, &code);
        code.deinit();
        return err;
    };
    defer code.deinit();

    try normalizeDocumentCode(ir, &code);
    try ir.finalize();
    try editor.refreshSolvedFrameHints(ir.allocator, ir);
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
                const node_id = try ir.makeNodeFromStage(
                    page_id,
                    node.attached,
                    node.kind,
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
            .unset_property => |property| {
                try ir.unsetNodeProperty(try ctx.node(property.node), property.key);
            },
            .extend_render_env => |entry| {
                try ir.extendRenderEnv(try ctx.node(entry.node), entry.op, entry.key, entry.value);
            },
            .set_content => |content| {
                try ir.setNodeContent(try ctx.node(content.node), content.value);
            },
            .add_metadata => |metadata| {
                _ = try ir.addMetadata(
                    metadata.kind,
                    metadata.value,
                    try ctx.maybeNode(metadata.page),
                    metadata.origin,
                );
            },
            .add_constraint => |constraint| {
                try ir.constraints.append(ir.allocator, try mapConstraint(ir, &ctx, constraint));
            },
        }
    }

    for (code.diagnostics.items) |diagnostic| {
        var mapped = try mapDiagnostic(ir, &ctx, diagnostic);
        var owns_mapped = true;
        errdefer if (owns_mapped) mapped.deinit(ir.allocator);
        try ir.addDiagnostic(mapped);
        owns_mapped = false;
    }
}

fn appendDocumentDiagnosticsWithoutHandles(ir: *core.Ir, code: *const doc.Document) !void {
    for (code.diagnostics.items) |diagnostic| {
        const data = try cloneDiagnosticData(ir, diagnostic.data);
        var copied = core.Diagnostic{
            .phase = diagnostic.phase,
            .severity = diagnostic.severity,
            .page_id = null,
            .node_id = null,
            .origin = if (diagnostic.origin) |origin| try ir.allocator.dupe(u8, origin) else null,
            .data = data,
        };
        var owns_copied = true;
        errdefer if (owns_copied) copied.deinit(ir.allocator);
        try ir.addDiagnostic(copied);
        owns_copied = false;
    }
}

fn mapConstraint(ir: *core.Ir, ctx: *NormalizeContext, constraint: core.Constraint) !core.Constraint {
    return .{
        .target_node = try ctx.node(constraint.target_node),
        .target_anchor = constraint.target_anchor,
        .source = try mapConstraintSource(ctx, constraint.source),
        .offset = constraint.offset,
        .origin = if (constraint.origin) |origin| try ir.copyString(origin) else null,
    };
}

fn mapConstraintSource(ctx: *NormalizeContext, source: core.ConstraintSource) !core.ConstraintSource {
    return switch (source) {
        .page => |anchor| .{ .page = anchor },
        .node => |node| .{ .node = .{ .node_id = try ctx.node(node.node_id), .anchor = node.anchor } },
    };
}

fn mapDiagnostic(ir: *core.Ir, ctx: *NormalizeContext, diagnostic: core.Diagnostic) !core.Diagnostic {
    const page_id = try ctx.maybeNode(diagnostic.page_id);
    const node_id = try ctx.maybeNode(diagnostic.node_id);
    const data = try cloneDiagnosticData(ir, diagnostic.data);
    var mapped = core.Diagnostic{
        .phase = diagnostic.phase,
        .severity = diagnostic.severity,
        .page_id = page_id,
        .node_id = node_id,
        .origin = null,
        .data = data,
    };
    errdefer mapped.deinit(ir.allocator);
    mapped.origin = if (diagnostic.origin) |origin| try ir.allocator.dupe(u8, origin) else null;
    return mapped;
}

fn cloneDiagnosticData(ir: *core.Ir, data: core.Diagnostic.Data) !core.Diagnostic.Data {
    return switch (data) {
        .user_report => |value| .{ .user_report = .{
            .message = try ir.allocator.dupe(u8, value.message),
        } },
        .asset_not_found => |value| blk: {
            const requested_path = try ir.allocator.dupe(u8, value.requested_path);
            errdefer ir.allocator.free(requested_path);
            const resolved_path = try ir.allocator.dupe(u8, value.resolved_path);
            errdefer ir.allocator.free(resolved_path);
            break :blk .{ .asset_not_found = .{
                .requested_path = requested_path,
                .resolved_path = resolved_path,
                .payload_kind = value.payload_kind,
            } };
        },
        .asset_invalid => |value| .{ .asset_invalid = .{
            .reason = try ir.allocator.dupe(u8, value.reason),
            .payload_kind = value.payload_kind,
        } },
        .type_mismatch => |value| .{ .type_mismatch = value },
        .recursive_function => |value| .{ .recursive_function = .{
            .function_name = try ir.copyString(value.function_name),
        } },
        .unresolved_frame => |value| .{ .unresolved_frame = value },
        .page_overflow => |value| .{ .page_overflow = value },
        .content_overflow => |value| .{ .content_overflow = value },
    };
}
