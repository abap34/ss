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

pub fn buildFile(io: std.Io, allocator: std.mem.Allocator, request: types.SourceRequest, progress: ?*Progress) !core.Ir {
    return try pipeline.buildFile(io, allocator, request, progress);
}

pub fn buildTypedFile(io: std.Io, allocator: std.mem.Allocator, request: types.SourceRequest, progress: ?*Progress) !core.Ir {
    return try pipeline.buildTypedFile(io, allocator, request, progress);
}

pub fn checkFile(io: std.Io, allocator: std.mem.Allocator, request: types.SourceRequest, progress: ?*Progress) !void {
    var ir = try buildFile(io, allocator, request, progress);
    defer ir.deinit();
    std.debug.print("ok {s}\n", .{request.input_path});
}

pub fn printIrJson(io: std.Io, allocator: std.mem.Allocator, request: types.SourceRequest, progress: *Progress) !void {
    var ir = try buildFile(io, allocator, request, progress);
    defer ir.deinit();
    const text = try dump.toOwnedString(allocator, &ir);
    defer allocator.free(text);
    try utils.io.writeStdoutAll(text);
    progress.step("Write JSON");
}

pub fn writeIrJson(io: std.Io, allocator: std.mem.Allocator, request: types.SourceRequest, output_path: []const u8, progress: *Progress) !void {
    var ir = try buildFile(io, allocator, request, progress);
    defer ir.deinit();
    const json = try dump.toOwnedString(allocator, &ir);
    defer allocator.free(json);
    try utils.fs.writeFile(io, output_path, json);
    progress.step("Write JSON");
}

pub fn writeScheduleTraceJson(io: std.Io, allocator: std.mem.Allocator, request: types.SourceRequest, output_path: []const u8, progress: *Progress) !void {
    var analyzed = try pipeline.analyzeFile(io, allocator, request, progress, .evaluation_schedule);
    defer analyzed.deinit();
    const json = lowering.scheduleTraceJsonFromGraph(allocator, &analyzed.ir, analyzed.scheduleGraph()) catch |err| {
        error_report.printIrDiagnostics(analyzed.ir.projectPath(), analyzed.ir.projectSource(), &analyzed.ir);
        return err;
    };
    defer allocator.free(json);
    progress.step("Serialize JSON");
    try utils.fs.writeFile(io, output_path, json);
    progress.step("Write JSON");
}

pub fn writeLayoutTraceJson(io: std.Io, allocator: std.mem.Allocator, request: types.SourceRequest, output_path: []const u8, progress: *Progress) !void {
    var analyzed = try pipeline.analyzeFile(io, allocator, request, progress, .evaluation_schedule);
    defer analyzed.deinit();
    try pipeline.evaluateDocument(&analyzed.ir, analyzed.scheduleGraph(), progress);
    var pages = try pipeline.preparePages(&analyzed.ir, progress);
    defer pages.deinit(analyzed.ir.allocator);
    var layouts = try pipeline.solveLayoutsWithTracePath(io, &analyzed.ir, &pages, output_path, progress, request.layout_jobs);
    defer layouts.deinit(analyzed.ir.allocator);
}

pub fn layoutConflictReportJson(
    io: std.Io,
    allocator: std.mem.Allocator,
    request: types.SourceRequest,
    progress: ?*Progress,
) ![]u8 {
    var analyzed = try pipeline.analyzeFile(io, allocator, request, progress, .evaluation_schedule);
    defer analyzed.deinit();
    try pipeline.evaluateDocument(&analyzed.ir, analyzed.scheduleGraph(), progress);
    var pages = try pipeline.preparePages(&analyzed.ir, progress);
    defer pages.deinit(analyzed.ir.allocator);
    const layout_progress = if (progress) |p| app_progress.layout(p) else null;
    const artifact_progress = if (progress) |p| app_progress.render(p) else null;
    if (progress) |p| p.begin("Solve layouts");
    render_layout.preloadPreparedPageArtifacts(io, &analyzed.ir, &pages, artifact_progress, request.layout_jobs) catch |err| {
        if (progress) |p| p.endStatusLine();
        error_report.printIrDiagnostics(analyzed.ir.projectPath(), analyzed.ir.projectSource(), &analyzed.ir);
        if (error_report.hasIrErrors(&analyzed.ir)) return error.DiagnosticsFailed;
        return err;
    };
    var maybe_layouts: ?core.LayoutResults = render_layout.solveWithPdfMeasurementsAndPreparedPagesProgress(io, &analyzed.ir, &pages, layout_progress, request.layout_jobs) catch |err| switch (err) {
        error.ConstraintConflict,
        error.NegativeFrameSize,
        => null,
        else => {
            if (progress) |p| p.endStatusLine();
            error_report.printIrDiagnostics(analyzed.ir.projectPath(), analyzed.ir.projectSource(), &analyzed.ir);
            return err;
        },
    };
    defer if (maybe_layouts) |*layouts| layouts.deinit(analyzed.ir.allocator);
    if (progress) |p| p.step("Solve layouts");
    const data = try core.layout.conflicts.toJson(allocator, &analyzed.ir);
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
    var analyzed = try pipeline.analyzeFile(io, allocator, request.source, progress, .evaluation_schedule);
    var analyzed_active = true;
    errdefer if (analyzed_active) analyzed.deinit();
    try pipeline.evaluateDocument(&analyzed.ir, analyzed.scheduleGraph(), progress);
    var pages = try pipeline.preparePages(&analyzed.ir, progress);
    const prepared_allocator = analyzed.ir.allocator;
    var pages_errdefer_active = true;
    errdefer if (pages_errdefer_active) pages.deinit(prepared_allocator);
    var layouts = pipeline.solveLayouts(io, &analyzed.ir, &pages, progress, request.source.layout_jobs) catch |err| {
        try app_output.writeDiagnosticsJsonIfRequested(io, allocator, &analyzed.ir, request.options.diagnostics_json_path);
        return err;
    };
    var layouts_errdefer_active = true;
    errdefer if (layouts_errdefer_active) layouts.deinit(prepared_allocator);
    var ir = analyzed.takeIr();
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
