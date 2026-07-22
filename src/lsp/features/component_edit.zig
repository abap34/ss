const std = @import("std");
const ast = @import("ast");

const editor_edit = @import("../../editor/edit.zig");
const syntax = @import("../../syntax.zig");
const edit_response = @import("edit/response.zig");
const protocol = @import("../protocol.zig");
const lsp_state = @import("../state.zig");
const utils = @import("utils");

pub const Context = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    documents: *lsp_state.DocumentStore,
    active_editor_paths: *const std.StringHashMap(void),
    provider: *lsp_state.AnalysisProvider,
};

pub fn result(ctx: *Context, params: ?protocol.JsonValue) ![]const u8 {
    const request = params orelse return try status(ctx, "rejected", "Missing component deletion request.");
    if (request != .object) return try status(ctx, "rejected", "Invalid component deletion request.");
    const request_object = &request.object;
    const doc_path = try protocol.docPathFromParams(ctx.allocator, params) orelse
        return try status(ctx, "unsupported", "Missing source document.");
    defer ctx.allocator.free(doc_path);
    if (!ctx.active_editor_paths.contains(doc_path)) {
        return try status(ctx, "unsupported", "The WYSIWYG editor is not active for this document.");
    }

    var owned_snapshot: ?lsp_state.AnalysisSnapshot = null;
    defer if (owned_snapshot) |*snapshot| snapshot.deinit();
    const snapshot = try ctx.provider.forDocument(doc_path, &owned_snapshot) orelse
        return try status(ctx, "unsupported", "No compiler snapshot is available.");
    const layout = if (snapshot.layout_output) |*value| value else return try status(ctx, "stale", edit_response.build_diagnostics_message);
    const editor = if (layout.editor) |*value| value else return try status(ctx, "unsupported", "The WYSIWYG editor is not active.");
    const requested_snapshot = protocol.stringField(request_object, "snapshotId") orelse "";
    if (requested_snapshot.len == 0 or
        !std.mem.eql(u8, requested_snapshot, editor.model.snapshot_id) or
        snapshot.generation != ctx.documents.generation)
    {
        return try status(ctx, "stale", "The document changed before the component was deleted.");
    }

    const requested_node_id = protocol.intField(request_object, "nodeId") orelse -1;
    if (requested_node_id < 0 or requested_node_id > std.math.maxInt(u32)) {
        return try status(ctx, "unsupported", "Missing target component.");
    }
    const target = editor.model.editingTarget(@intCast(requested_node_id)) orelse
        return try status(ctx, "unsupported", "This component has no editable page-level source statement.");
    const requested_page_id = protocol.intField(request_object, "pageId") orelse -1;
    if (requested_page_id != target.page_id) {
        return try status(ctx, "stale", "The selected component no longer belongs to this page.");
    }
    if (std.mem.indexOfScalar(u8, target.binding, '.') != null) {
        return try status(ctx, "unsupported", "A component stored inside another value cannot be deleted independently.");
    }

    var owned_source: ?[]u8 = null;
    defer if (owned_source) |source| ctx.allocator.free(source);
    const source = ctx.documents.sourceForPath(target.path) orelse blk: {
        owned_source = utils.fs.readFileAlloc(ctx.io, ctx.allocator, target.path) catch
            return try status(ctx, "unsupported", "The target source document is unavailable.");
        const module_fact = snapshot.moduleForPath(target.path) orelse
            return try status(ctx, "stale", "The target source module changed.");
        if (!std.mem.eql(u8, owned_source.?, module_fact.source)) {
            return try status(ctx, "stale", "The target source document changed on disk.");
        }
        break :blk owned_source.?;
    };

    var module = syntax.parseWithSourceName(ctx.allocator, source, target.path) catch
        return try status(ctx, "stale", "The target source document can no longer be parsed.");
    defer module.deinit(ctx.allocator);
    const page = sourcePage(&module, target.page) orelse
        return try status(ctx, "stale", "The source page changed before the component was deleted.");
    const target_statement = sourceStatement(page, target.statement) orelse
        return try status(ctx, "stale", "The component source statement changed before it was deleted.");
    if (!isDeletableBinding(target_statement, target.binding, target.binding_required)) {
        return try status(ctx, "unsupported", "This component is not represented by an independently deletable page statement.");
    }

    var removed = std.ArrayList(editor_edit.ByteSpan).empty;
    defer removed.deinit(ctx.allocator);
    try removed.append(ctx.allocator, target.statement);
    for (page.statements.items) |*statement| {
        if (statement == target_statement) continue;
        switch (statement.kind) {
            .constrain => |constraint| {
                if (constraintReferences(constraint, target.binding)) {
                    try removed.append(ctx.allocator, .{
                        .start = statement.span.start,
                        .end = statement.span.end,
                    });
                }
            },
            else => if (statementReferences(statement.*, target.binding)) {
                return try status(
                    ctx,
                    "rejected",
                    "This component is referenced by a non-constraint page statement. Remove that reference before deleting it.",
                );
            },
        }
    }

    var deletion = editor_edit.component.removeStatements(
        ctx.allocator,
        source,
        target.page,
        removed.items,
    ) catch return try status(ctx, "rejected", "The component source statements could not be removed safely.");
    defer deletion.deinit(ctx.allocator);
    const uri = try protocol.uriFromPath(ctx.allocator, target.path);
    defer ctx.allocator.free(uri);
    return try edit_response.workspaceEditOnlyJson(ctx.allocator, uri, source, deletion.edits);
}

fn status(ctx: *Context, value: []const u8, message: []const u8) ![]u8 {
    return edit_response.statusJson(ctx.allocator, value, message);
}

fn sourcePage(module: *const ast.Module, span: editor_edit.ByteSpan) ?*const ast.PageDecl {
    for (module.pages.items) |*page| {
        if (page.span.start == span.start and page.span.end == span.end) return page;
    }
    return null;
}

fn sourceStatement(page: *const ast.PageDecl, span: editor_edit.ByteSpan) ?*const ast.Statement {
    for (page.statements.items) |*statement| {
        if (statement.span.start == span.start and statement.span.end == span.end) return statement;
    }
    return null;
}

fn isDeletableBinding(statement: *const ast.Statement, binding: []const u8, binding_required: bool) bool {
    if (binding_required) return statement.kind == .expr_stmt;
    return switch (statement.kind) {
        .let_binding => |value| std.mem.eql(u8, value.name, binding),
        else => false,
    };
}

fn constraintReferences(constraint: ast.ConstraintDecl, binding: []const u8) bool {
    if (anchorReferences(constraint.target, binding)) return true;
    if (constraint.source) |source| if (anchorReferences(source, binding)) return true;
    if (constraint.offset) |offset| if (exprReferences(offset, binding)) return true;
    return false;
}

fn anchorReferences(anchor: ast.AnchorRef, binding: []const u8) bool {
    return anchor.kind == .node and
        std.mem.eql(u8, anchor.node_name orelse return false, binding);
}

fn statementReferences(statement: ast.Statement, binding: []const u8) bool {
    return switch (statement.kind) {
        .hole, .return_void => false,
        .let_binding => |value| exprReferences(value.expr, binding),
        .return_expr => |expr| exprReferences(expr, binding),
        .constrain => |constraint| constraintReferences(constraint, binding),
        .property_set => |property_set| exprReferences(property_set.target, binding) or
            exprReferences(property_set.value, binding),
        .if_stmt => |conditional| blk: {
            if (exprReferences(conditional.condition, binding)) break :blk true;
            for (conditional.then_statements.items) |nested| {
                if (statementReferences(nested, binding)) break :blk true;
            }
            for (conditional.else_statements.items) |nested| {
                if (statementReferences(nested, binding)) break :blk true;
            }
            break :blk false;
        },
        .expr_stmt => |expr| exprReferences(expr, binding),
    };
}

fn exprReferences(expr: ast.Expr, binding: []const u8) bool {
    return switch (expr) {
        .ident => |ident| std.mem.eql(u8, ident.name, binding),
        .call => |call| blk: {
            for (call.args.items) |arg| if (exprReferences(arg, binding)) break :blk true;
            break :blk false;
        },
        .apply => |apply| blk: {
            if (exprReferences(apply.callee.*, binding)) break :blk true;
            for (apply.args.items) |arg| if (exprReferences(arg, binding)) break :blk true;
            break :blk false;
        },
        .lambda => |lambda| blk: {
            var shadowed = false;
            for (lambda.params.items) |param| {
                if (param.default_value) |value| {
                    if (exprReferences(value.*, binding)) break :blk true;
                }
                if (std.mem.eql(u8, param.name, binding)) shadowed = true;
            }
            break :blk !shadowed and exprReferences(lambda.body.*, binding);
        },
        .member => |member| exprReferences(member.target.*, binding),
        .record => |record| blk: {
            for (record.fields.items) |field| if (exprReferences(field.value, binding)) break :blk true;
            break :blk false;
        },
        .record_update => |update| blk: {
            if (exprReferences(update.target.*, binding)) break :blk true;
            for (update.fields.items) |field| if (exprReferences(field.value, binding)) break :blk true;
            break :blk false;
        },
        .optional_check => |check| exprReferences(check.target.*, binding),
        .coalesce => |coalesce| exprReferences(coalesce.target.*, binding) or
            exprReferences(coalesce.fallback.*, binding),
        .hole, .string, .color, .number, .boolean, .none, .enum_case => false,
    };
}
