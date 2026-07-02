const std = @import("std");
const core = @import("core");

const analysis_snapshot = @import("../../analysis/snapshot.zig");
const protocol = @import("../protocol.zig");
const query_budget = @import("../query_budget.zig");
const lsp_state = @import("../state.zig");

const ProjectFacts = analysis_snapshot.ProjectFacts;

pub const Context = struct {
    allocator: std.mem.Allocator,
    provider: *lsp_state.SnapshotProvider,
};

pub fn result(ctx: *Context, params: ?protocol.JsonValue) ![]const u8 {
    const doc_path = try protocol.docPathFromParams(ctx.allocator, params) orelse return try ctx.allocator.dupe(u8, "[]");
    defer ctx.allocator.free(doc_path);
    var owned_snapshot: ?lsp_state.Snapshot = null;
    defer if (owned_snapshot) |*snapshot| snapshot.deinit();
    const snapshot = try ctx.provider.forDocument(doc_path, &owned_snapshot) orelse return try ctx.allocator.dupe(u8, "[]");
    if (!lsp_state.featureEnabledForSnapshot(snapshot, .inlay_hints)) return try ctx.allocator.dupe(u8, "[]");
    const hints = analysis_snapshot.inlayHints(snapshot, doc_path, .{ .budget_ms = query_budget.inlay_ms });
    return json(ctx.allocator, &snapshot.project, doc_path, hints);
}

pub fn json(
    allocator: std.mem.Allocator,
    project: *const ProjectFacts,
    doc_path: []const u8,
    hints: []const core.InlayHint,
) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    try out.append(allocator, '[');
    var first = true;
    for (hints) |hint| {
        const file = hint.file orelse project.entry_path;
        if (!protocol.samePath(allocator, file, doc_path)) continue;
        const kind = @tagName(hint.kind);
        if (!kindEnabled(project, kind)) continue;
        if (!first) try out.append(allocator, ',');
        first = false;
        try out.appendSlice(allocator, "{\"position\":{\"line\":");
        try protocol.appendInt(allocator, &out, hint.line);
        try out.appendSlice(allocator, ",\"character\":");
        try protocol.appendInt(allocator, &out, hint.column);
        try out.appendSlice(allocator, "},\"label\":");
        try protocol.appendJsonString(allocator, &out, hint.label);
        try out.appendSlice(allocator, ",\"kind\":");
        const hint_kind: i64 = if (std.mem.eql(u8, kind, "parameter_names")) 2 else 1;
        try protocol.appendInt(allocator, &out, hint_kind);
        try out.appendSlice(allocator, ",\"paddingLeft\":true}");
    }
    try out.append(allocator, ']');
    return out.toOwnedSlice(allocator);
}

fn kindEnabled(project: *const ProjectFacts, kind: []const u8) bool {
    const cfg = project.lsp;
    if (std.mem.eql(u8, kind, "parameter_names")) return cfg.inlay_hint_arguments;
    if (std.mem.eql(u8, kind, "solved_frame")) return cfg.inlay_hint_positions;
    return true;
}
