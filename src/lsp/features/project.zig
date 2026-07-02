const std = @import("std");

const analysis_snapshot = @import("../../analysis/snapshot.zig");
const protocol = @import("../protocol.zig");
const lsp_state = @import("../state.zig");

const ProjectFacts = analysis_snapshot.ProjectFacts;

pub const Context = struct {
    allocator: std.mem.Allocator,
    provider: *lsp_state.SnapshotProvider,
};

pub fn result(ctx: *Context, params: ?protocol.JsonValue) ![]const u8 {
    if (try protocol.docPathFromParams(ctx.allocator, params)) |doc_path| {
        defer ctx.allocator.free(doc_path);
        var owned_snapshot: ?lsp_state.Snapshot = null;
        defer if (owned_snapshot) |*snapshot| snapshot.deinit();
        const snapshot = try ctx.provider.forDocument(doc_path, &owned_snapshot) orelse return try json(ctx.allocator, null);
        return try json(ctx.allocator, &snapshot.project);
    }
    return try json(ctx.allocator, if (ctx.provider.current) |snapshot| &snapshot.project else null);
}

pub fn json(allocator: std.mem.Allocator, project: ?*const ProjectFacts) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    try out.append(allocator, '{');
    if (project) |facts| {
        try out.appendSlice(allocator, "\"entryPath\":");
        try protocol.appendJsonString(allocator, &out, facts.entry_path);
        try out.appendSlice(allocator, ",\"assetBaseDir\":");
        try protocol.appendJsonString(allocator, &out, facts.asset_base_dir);
        try out.appendSlice(allocator, ",\"localModules\":[");
        for (facts.module_paths, 0..) |path, i| {
            if (i != 0) try out.append(allocator, ',');
            try protocol.appendJsonString(allocator, &out, path);
        }
        try out.append(allocator, ']');
        try appendSettings(allocator, &out, facts);
    }
    try out.append(allocator, '}');
    return out.toOwnedSlice(allocator);
}

fn appendSettings(allocator: std.mem.Allocator, out: *std.ArrayList(u8), facts: *const ProjectFacts) !void {
    try out.appendSlice(allocator, ",\"lsp\":{");
    try appendBoolField(allocator, out, "enabled", facts.lsp.enabled, true);
    try appendIntField(allocator, out, "debounce", facts.lsp.debounce_ms, false);
    try appendBoolField(allocator, out, "diagnostics", facts.lsp.diagnostics, false);
    try appendBoolField(allocator, out, "completion", facts.lsp.completion, false);
    try appendBoolField(allocator, out, "hover", facts.lsp.hover, false);
    try appendBoolField(allocator, out, "definition", facts.lsp.definition, false);
    try appendBoolField(allocator, out, "inlayHints", facts.lsp.inlay_hints, false);
    try appendBoolField(allocator, out, "inlayHintArguments", facts.lsp.inlay_hint_arguments, false);
    try appendBoolField(allocator, out, "inlayHintPositions", facts.lsp.inlay_hint_positions, false);
    try appendBoolField(allocator, out, "documentSymbols", facts.lsp.document_symbols, false);
    try appendBoolField(allocator, out, "foldingRanges", facts.lsp.folding_ranges, false);
    try appendBoolField(allocator, out, "semanticTokens", facts.lsp.semantic_tokens, false);
    try appendBoolField(allocator, out, "colors", facts.lsp.colors, false);
    try out.append(allocator, '}');

    try out.appendSlice(allocator, ",\"preview\":{");
    try appendBoolField(allocator, out, "enabled", facts.preview.enabled, true);
    try appendIntField(allocator, out, "debounce", facts.preview.debounce_ms, false);
    try appendBoolField(allocator, out, "refreshOnSave", facts.preview.refresh_on_save, false);
    try appendBoolField(allocator, out, "refreshOnDependencyChange", facts.preview.refresh_on_dependency_change, false);
    try out.appendSlice(allocator, ",\"open\":");
    try protocol.appendJsonString(allocator, out, if (facts.preview.open_mode == .external) "external" else "vscode");
    try appendBoolField(allocator, out, "reveal", facts.preview.reveal_after_render, false);
    try appendIntField(allocator, out, "timeout", facts.preview.render_timeout_ms, false);
    try out.append(allocator, '}');

    try out.appendSlice(allocator, ",\"pageGuide\":{");
    try appendBoolField(allocator, out, "enabled", facts.page_guide.enabled, true);
    try appendBoolField(allocator, out, "bodyBackground", facts.page_guide.body_background, false);
    try appendBoolField(allocator, out, "boundary", facts.page_guide.boundary, false);
    try appendBoolField(allocator, out, "boundaryBackground", facts.page_guide.boundary_background, false);
    try appendBoolField(allocator, out, "gutterIcon", facts.page_guide.gutter_icon, false);
    try appendBoolField(allocator, out, "overviewRuler", facts.page_guide.overview_ruler, false);
    try out.append(allocator, '}');
}

fn appendBoolField(allocator: std.mem.Allocator, out: *std.ArrayList(u8), name: []const u8, value: bool, first: bool) !void {
    if (!first) try out.append(allocator, ',');
    try protocol.appendJsonString(allocator, out, name);
    try out.append(allocator, ':');
    try protocol.appendBool(allocator, out, value);
}

fn appendIntField(allocator: std.mem.Allocator, out: *std.ArrayList(u8), name: []const u8, value: anytype, first: bool) !void {
    if (!first) try out.append(allocator, ',');
    try protocol.appendJsonString(allocator, out, name);
    try out.append(allocator, ':');
    try protocol.appendInt(allocator, out, value);
}
