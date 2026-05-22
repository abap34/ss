const std = @import("std");
const core = @import("core");
const stage0 = @import("stage0.zig");
const dump_calls = @import("dump/calls.zig");
const dump_core_graph = @import("dump/core_graph.zig");
const dump_declarations = @import("dump/declarations.zig");
const dump_editor = @import("dump/editor.zig");
const dump_layout = @import("dump/layout.zig");
const dump_render_doc = @import("dump/render_doc.zig");
const dump_source = @import("dump/source.zig");
const dump_stage0 = @import("dump/stage0.zig");
const json = @import("utils").json;

pub fn toOwnedString(allocator: std.mem.Allocator, ir: *core.Ir) ![]u8 {
    var buffer = std.ArrayList(u8).empty;
    errdefer buffer.deinit(allocator);

    var root = try json.Object.beginBuffer(allocator, &buffer);
    try root.intField("ir_version", 1);
    try root.stringField("stage", "finalized_ir");
    try root.stringField("project_path", ir.projectPath());
    try root.intField("projectModuleId", ir.project_module_id);
    try root.stringField("asset_base_dir", ir.asset_base_dir);

    try dump_source.writeModulesField(allocator, &root, ir.modules.items);

    var document_code = try stage0.elaborateIr(allocator, ir);
    defer document_code.deinit();
    try root.intField("stage0_document_handle", document_code.document_id);
    try dump_stage0.writeDocTermsField(&root, document_code.terms.items);

    try dump_calls.writeFunctionsField(allocator, &root, ir);
    try dump_editor.writeVariablesField(allocator, &root, ir);
    try dump_declarations.writeField(&root, allocator, ir);
    try dump_calls.writeQueryContractsField(allocator, &root);
    try dump_editor.writeDefinitionsField(&root, ir);
    try dump_editor.writeHintsField(&root, ir.hints.items);

    try root.intField("document_id", ir.document_id);
    try dump_layout.writePageOrderField(&root, ir.page_order.items);
    try dump_core_graph.writeNodesField(allocator, &root, ir);
    try dump_core_graph.writeMetadataField(&root, ir.metadata.items);
    try dump_render_doc.writeField(allocator, &root, ir);
    try dump_layout.writeContainsField(&root, &ir.contains);
    try dump_layout.writeConstraintsField(&root, ir.constraints.items);
    try writeDiagnosticsField(&root, ir.diagnostics.items);

    try root.end();
    try json.appendNewline(&buffer, allocator);
    return buffer.toOwnedSlice(allocator);
}

fn writeDiagnosticsField(root: *json.Object, diagnostics: []const core.Diagnostic) !void {
    var array = try root.arrayField("diagnostics");
    for (diagnostics) |diagnostic| try writeDiagnostic(&array, diagnostic);
    try array.end();
}

fn writeDiagnostic(diagnostics: *json.Array, diagnostic: core.Diagnostic) !void {
    var item = try diagnostics.objectItem();
    try item.enumTagField("phase", diagnostic.phase);
    try item.enumTagField("severity", diagnostic.severity);
    try item.optionalIntField("page_id", diagnostic.page_id);
    try item.optionalIntField("node_id", diagnostic.node_id);
    try item.optionalStringField("origin", diagnostic.origin);
    switch (diagnostic.data) {
        .user_report => |data| {
            try item.stringField("code", "user_report");
            try item.stringField("message", data.message);
        },
        .asset_not_found => |data| {
            try item.stringField("code", "asset_not_found");
            try item.stringField("requested_path", data.requested_path);
            try item.stringField("resolved_path", data.resolved_path);
            try item.optionalEnumTagField("payload_kind", data.payload_kind);
        },
        .asset_invalid => |data| {
            try item.stringField("code", "asset_invalid");
            try item.stringField("reason", data.reason);
            try item.optionalEnumTagField("payload_kind", data.payload_kind);
        },
        .type_mismatch => |data| {
            try item.stringField("code", @tagName(data.code));
            try item.stringField("expected", @tagName(data.expected));
            try item.stringField("actual", @tagName(data.actual));
        },
        .recursive_function => |data| {
            try item.stringField("code", "RecursiveFunction");
            try item.stringField("function_name", data.function_name);
        },
        .unresolved_frame => |data| {
            try item.stringField("code", "unresolved_frame");
            try item.boolField("missing_horizontal", data.missing_horizontal);
            try item.boolField("missing_vertical", data.missing_vertical);
        },
        .page_overflow => |data| {
            try item.stringField("code", "page_overflow");
            try item.floatField("overflow_left", data.overflow_left, "{d:.1}");
            try item.floatField("overflow_right", data.overflow_right, "{d:.1}");
            try item.floatField("overflow_top", data.overflow_top, "{d:.1}");
            try item.floatField("overflow_bottom", data.overflow_bottom, "{d:.1}");
        },
        .content_overflow => |data| {
            try item.stringField("code", "content_overflow");
            try item.floatField("required_height", data.required_height, "{d:.1}");
            try item.floatField("frame_height", data.frame_height, "{d:.1}");
            try item.floatField("overflow_height", data.overflow_height, "{d:.1}");
        },
    }
    try item.end();
}
