const std = @import("std");

const app = @import("../../app.zig");
const analysis_snapshot = @import("../../analysis/snapshot.zig");
const module_loader = @import("../../modules/loader.zig");
const protocol = @import("../protocol.zig");
const lsp_state = @import("../state.zig");

const ProjectFacts = analysis_snapshot.ProjectFacts;
const LayoutFacts = analysis_snapshot.LayoutFacts;

pub const Context = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    documents: *lsp_state.DocumentStore,
    provider: *lsp_state.SnapshotProvider,
    layout_snapshots: *lsp_state.LayoutStore,
};

pub fn result(ctx: *Context, params: ?protocol.JsonValue) ![]const u8 {
    var owned_snapshot: ?lsp_state.Snapshot = null;
    defer if (owned_snapshot) |*snapshot| snapshot.deinit();

    const doc_path = try protocol.docPathFromParams(ctx.allocator, params);
    defer if (doc_path) |path| ctx.allocator.free(path);

    const snapshot = blk: {
        if (doc_path) |path| break :blk try ctx.provider.forDocument(path, &owned_snapshot);
        break :blk ctx.provider.current;
    } orelse return try emptyJson(ctx.allocator);

    if (snapshot.generation == ctx.documents.generation) {
        if (snapshot.layout) |*layout| {
            const report = try conflictsJsonFromFacts(ctx.allocator, layout);
            errdefer ctx.allocator.free(report);
            try ctx.layout_snapshots.remember(ctx.allocator, snapshot, report);
            return report;
        }
    }

    var overlay = module_loader.SourceOverlay.init(ctx.allocator);
    defer overlay.deinit();
    try ctx.documents.fillOverlay(&overlay);

    const report = conflictsJson(
        ctx.io,
        ctx.allocator,
        &snapshot.project,
        &overlay,
    ) catch {
        if (try ctx.layout_snapshots.jsonForEntry(ctx.allocator, snapshot.project.entry_path)) |cached| return cached;
        return try emptyJson(ctx.allocator);
    };
    errdefer ctx.allocator.free(report);
    try ctx.layout_snapshots.remember(ctx.allocator, snapshot, report);
    return report;
}

pub fn conflictsJson(
    io: std.Io,
    allocator: std.mem.Allocator,
    project: *const ProjectFacts,
    overlay: *module_loader.SourceOverlay,
) ![]const u8 {
    return try app.layoutConflictReportJsonWithAssetBaseAndOverlay(
        io,
        allocator,
        project.entry_path,
        project.asset_base_dir,
        overlay,
        null,
    );
}

pub fn conflictsJsonFromFacts(allocator: std.mem.Allocator, layout: *const LayoutFacts) ![]const u8 {
    return try allocator.dupe(u8, layout.conflict_report_json);
}

pub fn emptyJson(allocator: std.mem.Allocator) ![]const u8 {
    return allocator.dupe(u8,
        \\{"schema":1,"kind":"ss-layout-conflicts","entry_path":"","pages":[],"objects":[],"anchors":[],"relations":[],"failures":[]}
        \\
    );
}
