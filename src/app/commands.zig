const std = @import("std");
const core = @import("core");
const lowering = @import("../lowering.zig");
const render_layout = @import("../render/layout.zig");
const render_pdf = @import("../render/pdf.zig");
const render_html = @import("../render/html.zig");
const dump = @import("../dump.zig");
const utils = @import("utils");

const app_output = @import("output.zig");
const app_progress = @import("progress.zig");
const pipeline = @import("pipeline.zig");
const types = @import("types.zig");

const error_report = utils.err;
const Progress = utils.progress.Progress;

pub fn buildFile(io: std.Io, allocator: std.mem.Allocator, request: types.SourceRequest, progress: ?*Progress) !core.DocumentState {
    return try pipeline.buildFile(io, allocator, request, progress);
}

pub fn buildTypedFile(io: std.Io, allocator: std.mem.Allocator, request: types.SourceRequest, progress: ?*Progress) !core.DocumentState {
    return try pipeline.buildTypedFile(io, allocator, request, progress);
}

pub fn checkFile(io: std.Io, allocator: std.mem.Allocator, request: types.SourceRequest, progress: ?*Progress) !void {
    var state = try buildFile(io, allocator, request, progress);
    defer state.deinit();
    std.debug.print("ok {s}\n", .{request.input_path});
}

pub fn printContextJson(io: std.Io, allocator: std.mem.Allocator, request: types.SourceRequest, progress: *Progress) !void {
    var state = try buildFile(io, allocator, request, progress);
    defer state.deinit();
    const text = try dump.toOwnedString(allocator, &state);
    defer allocator.free(text);
    try utils.io.writeStdoutAll(text);
    progress.step("Write JSON");
}

pub fn writeContextJson(io: std.Io, allocator: std.mem.Allocator, request: types.SourceRequest, output_path: []const u8, progress: *Progress) !void {
    var state = try buildFile(io, allocator, request, progress);
    defer state.deinit();
    const json = try dump.toOwnedString(allocator, &state);
    defer allocator.free(json);
    try utils.fs.writeFile(io, output_path, json);
    progress.step("Write JSON");
}

pub fn writeScheduleTraceJson(io: std.Io, allocator: std.mem.Allocator, request: types.SourceRequest, output_path: []const u8, progress: *Progress) !void {
    var analyzed = try pipeline.analyzeFile(io, allocator, request, progress, .evaluation);
    defer analyzed.deinit();
    const json = lowering.scheduleTraceJsonFromGraph(allocator, &analyzed.state, analyzed.executionGraph()) catch |err| {
        error_report.printDocumentStateDiagnostics(analyzed.state.projectPath(), analyzed.state.projectSource(), &analyzed.state);
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
    try pipeline.evaluateDocument(&analyzed.state, analyzed.executionGraph(), progress);
    var pages = try pipeline.preparePages(&analyzed.state, progress);
    defer pages.deinit(analyzed.state.allocator);
    var layouts = try pipeline.solveLayoutsWithTracePath(io, &analyzed.state, &pages, output_path, progress, request.layout_jobs);
    defer layouts.deinit(analyzed.state.allocator);
}

pub fn layoutConflictReportJson(
    io: std.Io,
    allocator: std.mem.Allocator,
    request: types.SourceRequest,
    progress: ?*Progress,
) ![]u8 {
    var analyzed = try pipeline.analyzeFile(io, allocator, request, progress, .evaluation);
    defer analyzed.deinit();
    try pipeline.evaluateDocument(&analyzed.state, analyzed.executionGraph(), progress);
    var pages = try pipeline.preparePages(&analyzed.state, progress);
    defer pages.deinit(analyzed.state.allocator);
    const layout_progress = if (progress) |p| app_progress.layout(p) else null;
    const artifact_progress = if (progress) |p| app_progress.render(p) else null;
    if (progress) |p| p.begin("Solve layouts");
    render_layout.preloadPreparedPageArtifacts(io, &analyzed.state, &pages, artifact_progress, request.layout_jobs) catch |err| {
        if (progress) |p| p.endStatusLine();
        error_report.printDocumentStateDiagnostics(analyzed.state.projectPath(), analyzed.state.projectSource(), &analyzed.state);
        if (error_report.hasDocumentStateErrors(&analyzed.state)) return error.DiagnosticsFailed;
        return err;
    };
    var maybe_layouts: ?core.layout.Document = render_layout.solvePreparedPages(io, &analyzed.state, &pages, layout_progress, request.layout_jobs) catch |err| switch (err) {
        error.ConstraintConflict,
        error.NegativeFrameSize,
        => null,
        else => {
            if (progress) |p| p.endStatusLine();
            error_report.printDocumentStateDiagnostics(analyzed.state.projectPath(), analyzed.state.projectSource(), &analyzed.state);
            return err;
        },
    };
    defer if (maybe_layouts) |*layouts| layouts.deinit(analyzed.state.allocator);
    if (progress) |p| p.step("Solve layouts");
    const data = try core.layout.conflicts.toJson(allocator, &analyzed.state);
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
    try pipeline.evaluateDocument(&analyzed.state, analyzed.executionGraph(), progress);
    var pages = try pipeline.preparePages(&analyzed.state, progress);
    const prepared_allocator = analyzed.state.allocator;
    var pages_errdefer_active = true;
    errdefer if (pages_errdefer_active) pages.deinit(prepared_allocator);
    var layouts = pipeline.solveLayouts(io, &analyzed.state, &pages, progress, request.source.layout_jobs) catch |err| {
        try app_output.writeDiagnosticsJsonIfRequested(io, allocator, &analyzed.state, request.options.diagnostics_json_path);
        return err;
    };
    var layouts_errdefer_active = true;
    errdefer if (layouts_errdefer_active) layouts.deinit(prepared_allocator);
    var state = analyzed.takeState();
    analyzed_active = false;
    defer state.deinit();
    defer layouts.deinit(state.allocator);
    layouts_errdefer_active = false;
    defer pages.deinit(state.allocator);
    pages_errdefer_active = false;
    progress.begin("Render PDF");
    var ir = render_pdf.compileRenderIr(state.allocator, io, &state, &pages, .{
        .cache_dir = request.options.render.cache_dir,
        .highlight_languages = request.options.render.highlight_languages,
    }) catch |err| {
        progress.endStatusLine();
        error_report.printDocumentStateDiagnostics(state.projectPath(), state.projectSource(), &state);
        try app_output.writeDiagnosticsJsonIfRequested(io, allocator, &state, request.options.diagnostics_json_path);
        if (error_report.hasDocumentStateErrors(&state)) return error.DiagnosticsFailed;
        return err;
    };
    defer ir.deinit(state.allocator);
    progress.step("Compile rendering IR");
    try app_output.writePdfOrPrintDiagnostics(allocator, io, &state, &ir, request.output_path, request.options.render, progress, request.options.diagnostics_json_path);
    try app_output.writeDiagnosticsJsonIfRequested(io, allocator, &state, request.options.diagnostics_json_path);
    try utils.render_cache.pruneFromEnv(io, allocator);
    progress.step("Render PDF");
}

pub fn writeHtml(io: std.Io, allocator: std.mem.Allocator, request: types.HtmlWriteRequest, progress: *Progress) !void {
    var analyzed = try pipeline.analyzeFile(io, allocator, request.source, progress, .evaluation);
    var analyzed_active = true;
    errdefer if (analyzed_active) analyzed.deinit();
    try pipeline.evaluateDocument(&analyzed.state, analyzed.executionGraph(), progress);
    var pages = try pipeline.preparePages(&analyzed.state, progress);
    const prepared_allocator = analyzed.state.allocator;
    var pages_errdefer_active = true;
    errdefer if (pages_errdefer_active) pages.deinit(prepared_allocator);
    var layouts = pipeline.solveLayouts(io, &analyzed.state, &pages, progress, request.source.layout_jobs) catch |err| {
        try app_output.writeDiagnosticsJsonIfRequested(io, allocator, &analyzed.state, request.options.diagnostics_json_path);
        return err;
    };
    var layouts_errdefer_active = true;
    errdefer if (layouts_errdefer_active) layouts.deinit(prepared_allocator);
    var state = analyzed.takeState();
    analyzed_active = false;
    defer state.deinit();
    defer layouts.deinit(state.allocator);
    layouts_errdefer_active = false;
    defer pages.deinit(state.allocator);
    pages_errdefer_active = false;

    progress.begin("Render HTML");
    var ir = render_pdf.compileRenderIr(state.allocator, io, &state, &pages, .{
        .cache_dir = request.options.render.cache_dir,
        .highlight_languages = request.options.render.highlight_languages,
    }) catch |err| {
        progress.endStatusLine();
        error_report.printDocumentStateDiagnostics(state.projectPath(), state.projectSource(), &state);
        try app_output.writeDiagnosticsJsonIfRequested(io, allocator, &state, request.options.diagnostics_json_path);
        if (error_report.hasDocumentStateErrors(&state)) return error.DiagnosticsFailed;
        return err;
    };
    defer ir.deinit(state.allocator);
    progress.step("Compile rendering IR");
    try render_html.write(allocator, io, &ir, request.output_directory, request.options.html);
    progress.step("Write HTML bundle");
    try app_output.writeDiagnosticsJsonIfRequested(io, allocator, &state, request.options.diagnostics_json_path);
    try utils.render_cache.pruneFromEnv(io, allocator);
}
