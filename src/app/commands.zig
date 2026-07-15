const std = @import("std");
const core = @import("core");
const lowering = @import("../lowering.zig");
const render_layout = @import("../render/layout.zig");
const dump = @import("../dump.zig");
const utils = @import("utils");

const app_output = @import("output.zig");
const app_progress = @import("progress.zig");
const pipeline = @import("pipeline.zig");
const types = @import("types.zig");

const error_report = utils.err;
const Progress = utils.progress.Progress;

pub fn buildFile(io: std.Io, allocator: std.mem.Allocator, request: types.SourceRequest, progress: ?*Progress) !core.Context {
    return try pipeline.buildFile(io, allocator, request, progress);
}

pub fn buildTypedFile(io: std.Io, allocator: std.mem.Allocator, request: types.SourceRequest, progress: ?*Progress) !core.Context {
    return try pipeline.buildTypedFile(io, allocator, request, progress);
}

pub fn checkFile(io: std.Io, allocator: std.mem.Allocator, request: types.SourceRequest, progress: ?*Progress) !void {
    var ir = try buildFile(io, allocator, request, progress);
    defer ir.deinit();
    std.debug.print("ok {s}\n", .{request.input_path});
}

pub fn printContextJson(io: std.Io, allocator: std.mem.Allocator, request: types.SourceRequest, progress: *Progress) !void {
    var ir = try buildFile(io, allocator, request, progress);
    defer ir.deinit();
    const text = try dump.toOwnedString(allocator, &ir);
    defer allocator.free(text);
    try utils.io.writeStdoutAll(text);
    progress.step("Write JSON");
}

pub fn writeContextJson(io: std.Io, allocator: std.mem.Allocator, request: types.SourceRequest, output_path: []const u8, progress: *Progress) !void {
    var ir = try buildFile(io, allocator, request, progress);
    defer ir.deinit();
    const json = try dump.toOwnedString(allocator, &ir);
    defer allocator.free(json);
    try utils.fs.writeFile(io, output_path, json);
    progress.step("Write JSON");
}

pub fn writeScheduleTraceJson(io: std.Io, allocator: std.mem.Allocator, request: types.SourceRequest, output_path: []const u8, progress: *Progress) !void {
    var analyzed = try pipeline.analyzeFile(io, allocator, request, progress, .evaluation);
    defer analyzed.deinit();
    const json = lowering.scheduleTraceJsonFromGraph(allocator, &analyzed.context, analyzed.executionGraph()) catch |err| {
        error_report.printContextDiagnostics(analyzed.context.projectPath(), analyzed.context.projectSource(), &analyzed.context);
        return err;
    };
    defer allocator.free(json);
    progress.step("Serialize JSON");
    try utils.fs.writeFile(io, output_path, json);
    progress.step("Write JSON");
}

pub fn writeLayoutTraceJson(io: std.Io, allocator: std.mem.Allocator, request: types.SourceRequest, output_path: []const u8, progress: *Progress) !void {
    var analyzed = try pipeline.analyzeFile(io, allocator, request, progress, .evaluation);
    defer analyzed.deinit();
    try pipeline.evaluateDocument(&analyzed.context, analyzed.executionGraph(), progress);
    var pages = try pipeline.preparePages(&analyzed.context, progress);
    defer pages.deinit(analyzed.context.allocator);
    var layouts = try pipeline.solveLayoutsWithTracePath(io, &analyzed.context, &pages, output_path, progress, request.layout_jobs);
    defer layouts.deinit(analyzed.context.allocator);
}

pub fn layoutConflictReportJson(
    io: std.Io,
    allocator: std.mem.Allocator,
    request: types.SourceRequest,
    progress: ?*Progress,
) ![]u8 {
    var analyzed = try pipeline.analyzeFile(io, allocator, request, progress, .evaluation);
    defer analyzed.deinit();
    try pipeline.evaluateDocument(&analyzed.context, analyzed.executionGraph(), progress);
    var pages = try pipeline.preparePages(&analyzed.context, progress);
    defer pages.deinit(analyzed.context.allocator);
    const layout_progress = if (progress) |p| app_progress.layout(p) else null;
    const artifact_progress = if (progress) |p| app_progress.render(p) else null;
    if (progress) |p| p.begin("Solve layouts");
    render_layout.preloadPreparedPageArtifacts(io, &analyzed.context, &pages, artifact_progress, request.layout_jobs) catch |err| {
        if (progress) |p| p.endStatusLine();
        error_report.printContextDiagnostics(analyzed.context.projectPath(), analyzed.context.projectSource(), &analyzed.context);
        if (error_report.hasContextErrors(&analyzed.context)) return error.DiagnosticsFailed;
        return err;
    };
    var maybe_layouts: ?core.layout.Document = render_layout.solvePreparedPages(io, &analyzed.context, &pages, layout_progress, request.layout_jobs) catch |err| switch (err) {
        error.ConstraintConflict,
        error.NegativeFrameSize,
        => null,
        else => {
            if (progress) |p| p.endStatusLine();
            error_report.printContextDiagnostics(analyzed.context.projectPath(), analyzed.context.projectSource(), &analyzed.context);
            return err;
        },
    };
    defer if (maybe_layouts) |*layouts| layouts.deinit(analyzed.context.allocator);
    if (progress) |p| p.step("Solve layouts");
    const data = try core.layout.conflicts.toJson(allocator, &analyzed.context);
    if (progress) |p| p.step("Serialize report");
    return data;
}

pub fn writeLayoutConflictReportFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    request: types.SourceRequest,
    output_path: []const u8,
    progress: *Progress,
) !void {
    const data = try layoutConflictReportJson(io, allocator, request, progress);
    defer allocator.free(data);
    try utils.fs.writeFile(io, output_path, data);
    progress.step("Write report");
}

pub fn writePdf(io: std.Io, allocator: std.mem.Allocator, request: types.PdfWriteRequest, progress: *Progress) !void {
    var analyzed = try pipeline.analyzeFile(io, allocator, request.source, progress, .evaluation);
    var analyzed_active = true;
    errdefer if (analyzed_active) analyzed.deinit();
    try pipeline.evaluateDocument(&analyzed.context, analyzed.executionGraph(), progress);
    var pages = try pipeline.preparePages(&analyzed.context, progress);
    const prepared_allocator = analyzed.context.allocator;
    var pages_errdefer_active = true;
    errdefer if (pages_errdefer_active) pages.deinit(prepared_allocator);
    var layouts = pipeline.solveLayouts(io, &analyzed.context, &pages, progress, request.source.layout_jobs) catch |err| {
        try app_output.writeDiagnosticsJsonIfRequested(io, allocator, &analyzed.context, request.options.diagnostics_json_path);
        return err;
    };
    var layouts_errdefer_active = true;
    errdefer if (layouts_errdefer_active) layouts.deinit(prepared_allocator);
    var ir = analyzed.takeContext();
    analyzed_active = false;
    defer ir.deinit();
    defer layouts.deinit(ir.allocator);
    layouts_errdefer_active = false;
    defer pages.deinit(ir.allocator);
    pages_errdefer_active = false;
    progress.begin("Render PDF");
    const pdf_data = try app_output.renderPdfOrPrintDiagnostics(allocator, io, &ir, &pages, &layouts, request.options.render, progress, request.options.diagnostics_json_path);
    defer allocator.free(pdf_data);
    try app_output.writeDiagnosticsJsonIfRequested(io, allocator, &ir, request.options.diagnostics_json_path);
    try utils.render_cache.pruneFromEnv(io, allocator);
    progress.step("Render PDF");
    try utils.fs.writeFile(io, request.output_path, pdf_data);
    progress.step("Write output");
}
