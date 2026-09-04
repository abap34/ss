const std = @import("std");
const core = @import("core");
const render = @import("render");
const lowering = @import("../lowering.zig");
const render_layout = @import("../render/layout.zig");
const render_compile = @import("../render/compile.zig");
const render_html = @import("../render/html.zig");
const render_text = @import("render_text");
const dump = @import("../dump.zig");
const utils = @import("utils");

const app_output = @import("output.zig");
const app_progress = @import("progress.zig");
const pipeline = @import("pipeline.zig");
const types = @import("types.zig");

const error_report = utils.err;
const Progress = utils.progress.Progress;

pub const render_progress_steps = 8;
pub const pdf_and_html_progress_steps = 9;

const CompiledRendering = struct {
    state: core.DocumentState,
    pages: core.prepared.PreparedPages,
    layouts: core.layout.Document,
    ir: render.Ir,
    ir_allocator: std.mem.Allocator,

    fn deinit(self: *CompiledRendering) void {
        const allocator = self.state.allocator;
        self.ir.deinit(self.ir_allocator);
        self.layouts.deinit(allocator);
        self.pages.deinit(allocator);
        self.state.deinit();
    }
};

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
    try app_output.validateOutputPathAgainstSources(io, allocator, &state, output_path, .dump_json);
    const json = try dump.toOwnedString(allocator, &state);
    defer allocator.free(json);
    try app_output.writeFileOrPrintDiagnostic(io, output_path, json, .dump_json);
    progress.step("Write JSON");
}

pub fn writeScheduleTraceJson(io: std.Io, allocator: std.mem.Allocator, request: types.SourceRequest, output_path: []const u8, progress: *Progress) !void {
    var analyzed = try pipeline.analyzeFile(io, allocator, request, progress, .evaluation);
    defer analyzed.deinit();
    try app_output.validateOutputPathAgainstSources(io, allocator, &analyzed.state, output_path, .schedule_trace);
    const json = lowering.scheduleTraceJsonFromGraph(allocator, &analyzed.state, analyzed.executionGraph()) catch |err| {
        error_report.printDocumentStateDiagnostics(analyzed.state.projectPath(), analyzed.state.projectSource(), &analyzed.state);
        return err;
    };
    defer allocator.free(json);
    progress.step("Serialize JSON");
    try app_output.writeFileOrPrintDiagnostic(io, output_path, json, .schedule_trace);
    progress.step("Write JSON");
}

pub fn writeLayoutTraceJson(io: std.Io, allocator: std.mem.Allocator, request: types.SourceRequest, output_path: []const u8, progress: *Progress) !void {
    var render_cache_lease = try app_output.acquireRenderCacheLeaseOrPrintDiagnostic(io);
    defer render_cache_lease.deinit();
    var analyzed = try pipeline.analyzeFile(io, allocator, request, progress, .evaluation);
    defer analyzed.deinit();
    try app_output.validateOutputPathAgainstSources(io, allocator, &analyzed.state, output_path, .layout_trace);
    try pipeline.evaluateDocument(&analyzed.state, analyzed.executionGraph(), progress);
    var pages = try pipeline.preparePages(&analyzed.state, progress);
    defer pages.deinit(analyzed.state.allocator);
    var trace_failure = core.layout.graph.TraceFailure{};
    var layouts = pipeline.solveLayoutsWithTracePath(io, &analyzed.state, &pages, output_path, &trace_failure, progress, request.layout_jobs, request.highlight_languages) catch |err| {
        if (err != error.LayoutTraceFailed or trace_failure.cause == null) return err;
        const cause = trace_failure.cause.?;
        return switch (trace_failure.kind) {
            .output => app_output.outputWriteFailed(.layout_trace, output_path, cause),
            .materialization => app_output.layoutTraceMaterializationFailed(output_path, trace_failure.operation, cause),
        };
    };
    defer layouts.deinit(analyzed.state.allocator);
}

pub fn layoutConflictReportJson(
    io: std.Io,
    allocator: std.mem.Allocator,
    request: types.SourceRequest,
    progress: ?*Progress,
) ![]u8 {
    return layoutConflictReportJsonWithProtectedOutput(io, allocator, request, progress, null);
}

fn layoutConflictReportJsonWithProtectedOutput(
    io: std.Io,
    allocator: std.mem.Allocator,
    request: types.SourceRequest,
    progress: ?*Progress,
    protected_output_path: ?[]const u8,
) ![]u8 {
    var render_cache_lease = try app_output.acquireRenderCacheLeaseOrPrintDiagnostic(io);
    defer render_cache_lease.deinit();
    var analyzed = try pipeline.analyzeFile(io, allocator, request, progress, .evaluation);
    defer analyzed.deinit();
    if (protected_output_path) |path| {
        try app_output.validateOutputPathAgainstSources(io, allocator, &analyzed.state, path, .layout_conflict_report);
    }
    try pipeline.evaluateDocument(&analyzed.state, analyzed.executionGraph(), progress);
    var pages = try pipeline.preparePages(&analyzed.state, progress);
    defer pages.deinit(analyzed.state.allocator);
    const layout_progress = if (progress) |p| app_progress.layout(p) else null;
    const artifact_progress = if (progress) |p| app_progress.render(p) else null;
    if (progress) |p| p.begin("Solve layouts");
    errdefer if (progress) |p| p.abort();
    render_layout.preloadPreparedPageArtifacts(io, &analyzed.state, &pages, artifact_progress, request.layout_jobs, request.highlight_languages) catch |err| {
        if (progress) |p| p.abort();
        error_report.printDocumentStateDiagnostics(analyzed.state.projectPath(), analyzed.state.projectSource(), &analyzed.state);
        if (error_report.hasDocumentStateErrors(&analyzed.state)) return error.DiagnosticsFailed;
        return err;
    };
    var maybe_layouts: ?core.layout.Document = render_layout.solvePreparedPages(io, &analyzed.state, &pages, .{
        .progress = layout_progress,
        .jobs = request.layout_jobs,
        .highlight_languages = request.highlight_languages,
    }) catch |err| switch (err) {
        error.ConstraintConflict,
        error.NegativeFrameSize,
        => null,
        else => {
            if (progress) |p| p.abort();
            error_report.printDocumentStateDiagnostics(analyzed.state.projectPath(), analyzed.state.projectSource(), &analyzed.state);
            if (error_report.hasDocumentStateErrors(&analyzed.state)) return error.DiagnosticsFailed;
            return err;
        },
    };
    defer if (maybe_layouts) |*layouts| layouts.deinit(analyzed.state.allocator);
    if (progress) |p| p.complete();
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
    const data = try layoutConflictReportJsonWithProtectedOutput(io, allocator, request, progress, output_path);
    defer allocator.free(data);
    try app_output.writeFileOrPrintDiagnostic(io, output_path, data, .layout_conflict_report);
    progress.step("Write report");
}

pub fn writePdf(io: std.Io, allocator: std.mem.Allocator, request: types.PdfWriteRequest, progress: *Progress) !void {
    var render_cache_lease = try app_output.acquireRenderCacheLeaseOrPrintDiagnostic(io);
    defer render_cache_lease.deinit();
    var output_targets = [_]app_output.OutputTarget{
        .{ .path = request.output_path, .kind = .pdf },
        .{ .path = request.options.diagnostics_json_path orelse request.output_path, .kind = .diagnostics_json },
    };
    const output_target_count: usize = if (request.options.diagnostics_json_path == null) 1 else 2;
    try app_output.validateDistinctOutputPaths(io, allocator, output_targets[0..output_target_count]);
    var compiled = try compileRendering(io, allocator, request.source, request.options.render, request.options.diagnostics_json_path, progress);
    defer compiled.deinit();
    try app_output.validateOutputPathAgainstSources(io, allocator, &compiled.state, request.output_path, .pdf);
    progress.begin("Render PDF");
    errdefer progress.abort();
    try app_output.writePdfOrPrintDiagnostics(allocator, io, &compiled.state, &compiled.ir, request.output_path, request.options.render, progress, request.options.diagnostics_json_path);
    try app_output.writeDiagnosticsJsonIfRequested(io, allocator, &compiled.state, request.options.diagnostics_json_path);
    app_output.pruneRenderCacheOrPrintWarning(io, allocator, request.options.render.cache);
    progress.complete();
}

pub fn writeHtml(io: std.Io, allocator: std.mem.Allocator, request: types.HtmlWriteRequest, progress: *Progress) !void {
    var render_cache_lease = try app_output.acquireRenderCacheLeaseOrPrintDiagnostic(io);
    defer render_cache_lease.deinit();
    var output_targets = [_]app_output.OutputTarget{
        .{ .path = request.output_path, .kind = .html },
        .{ .path = request.options.diagnostics_json_path orelse request.output_path, .kind = .diagnostics_json },
    };
    const output_target_count: usize = if (request.options.diagnostics_json_path == null) 1 else 2;
    try app_output.validateDistinctOutputPaths(io, allocator, output_targets[0..output_target_count]);
    var compiled = try compileRendering(io, allocator, request.source, request.options.render, request.options.diagnostics_json_path, progress);
    defer compiled.deinit();
    try app_output.validateOutputPathAgainstSources(io, allocator, &compiled.state, request.output_path, .html);
    progress.begin("Write HTML");
    errdefer progress.abort();
    var html_failure = render_html.WriteFailure{};
    render_html.writeWithFailure(allocator, io, &compiled.ir, request.output_path, &html_failure) catch |err| {
        const cause = html_failure.cause orelse err;
        const failure = switch (html_failure.kind) {
            .output => app_output.outputWriteFailed(.html, request.output_path, cause),
            .materialization => app_output.htmlMaterializationFailed(request.output_path, html_failure.operation, cause),
        };
        app_output.writeDiagnosticsJsonIfRequested(io, allocator, &compiled.state, request.options.diagnostics_json_path) catch {};
        return failure;
    };
    try app_output.writeDiagnosticsJsonIfRequested(io, allocator, &compiled.state, request.options.diagnostics_json_path);
    app_output.pruneRenderCacheOrPrintWarning(io, allocator, request.options.render.cache);
    progress.complete();
}

pub fn writePdfAndHtml(io: std.Io, allocator: std.mem.Allocator, request: types.PdfAndHtmlWriteRequest, progress: *Progress) !void {
    var render_cache_lease = try app_output.acquireRenderCacheLeaseOrPrintDiagnostic(io);
    defer render_cache_lease.deinit();
    var output_targets = [_]app_output.OutputTarget{
        .{ .path = request.pdf_output_path, .kind = .pdf },
        .{ .path = request.html_output_path, .kind = .html },
        .{ .path = request.options.diagnostics_json_path orelse request.pdf_output_path, .kind = .diagnostics_json },
    };
    const output_target_count: usize = if (request.options.diagnostics_json_path == null) 2 else 3;
    try app_output.validateDistinctOutputPaths(io, allocator, output_targets[0..output_target_count]);
    var compiled = try compileRendering(io, allocator, request.source, request.options.render, request.options.diagnostics_json_path, progress);
    defer compiled.deinit();
    try app_output.validateOutputPathAgainstSources(io, allocator, &compiled.state, request.pdf_output_path, .pdf);
    try app_output.validateOutputPathAgainstSources(io, allocator, &compiled.state, request.html_output_path, .html);
    progress.begin("Render PDF");
    errdefer progress.abort();
    try app_output.writePdfOrPrintDiagnostics(
        allocator,
        io,
        &compiled.state,
        &compiled.ir,
        request.pdf_output_path,
        request.options.render,
        progress,
        request.options.diagnostics_json_path,
    );
    progress.complete();
    progress.begin("Write HTML");
    var html_failure = render_html.WriteFailure{};
    render_html.writeWithFailure(allocator, io, &compiled.ir, request.html_output_path, &html_failure) catch |err| {
        const cause = html_failure.cause orelse err;
        const failure = switch (html_failure.kind) {
            .output => app_output.outputWriteFailed(.html, request.html_output_path, cause),
            .materialization => app_output.htmlMaterializationFailed(request.html_output_path, html_failure.operation, cause),
        };
        app_output.writeDiagnosticsJsonIfRequested(io, allocator, &compiled.state, request.options.diagnostics_json_path) catch {};
        return failure;
    };
    try app_output.writeDiagnosticsJsonIfRequested(io, allocator, &compiled.state, request.options.diagnostics_json_path);
    app_output.pruneRenderCacheOrPrintWarning(io, allocator, request.options.render.cache);
    progress.complete();
}

fn compileRendering(
    io: std.Io,
    allocator: std.mem.Allocator,
    source: types.SourceRequest,
    options: types.RenderOptions,
    diagnostics_json_path: ?[]const u8,
    progress: *Progress,
) !CompiledRendering {
    var analyzed = try pipeline.analyzeFile(io, allocator, source, progress, .evaluation);
    var analyzed_active = true;
    errdefer if (analyzed_active) analyzed.deinit();
    if (diagnostics_json_path) |path| {
        try app_output.validateOutputPathAgainstSources(io, allocator, &analyzed.state, path, .diagnostics_json);
    }
    try pipeline.evaluateDocument(&analyzed.state, analyzed.executionGraph(), progress);
    var pages = try pipeline.preparePages(&analyzed.state, progress);
    const prepared_allocator = analyzed.state.allocator;
    var pages_errdefer_active = true;
    errdefer if (pages_errdefer_active) pages.deinit(prepared_allocator);
    const font_environment = render_compile.acquireFontEnvironment(prepared_allocator, io, &analyzed.state, &pages) catch |err| {
        _ = try render_compile.addFontEnvironmentDiagnostic(&analyzed.state, err);
        if (error_report.hasDocumentStateErrors(&analyzed.state)) {
            error_report.printDocumentStateDiagnostics(analyzed.state.projectPath(), analyzed.state.projectSource(), &analyzed.state);
            app_output.writeDiagnosticsJsonIfRequested(io, allocator, &analyzed.state, diagnostics_json_path) catch {};
            return error.DiagnosticsFailed;
        }
        return err;
    };
    var layouts = pipeline.solveLayouts(io, &analyzed.state, &pages, progress, source.layout_jobs, options.highlight_languages, font_environment) catch |err| {
        app_output.writeDiagnosticsJsonIfRequested(io, allocator, &analyzed.state, diagnostics_json_path) catch {};
        return err;
    };
    var layouts_errdefer_active = true;
    errdefer if (layouts_errdefer_active) layouts.deinit(prepared_allocator);
    var state = analyzed.takeState();
    analyzed_active = false;
    errdefer state.deinit();
    errdefer layouts.deinit(state.allocator);
    layouts_errdefer_active = false;
    errdefer pages.deinit(state.allocator);
    pages_errdefer_active = false;

    progress.begin("Compile rendering");
    errdefer progress.abort();
    const diagnostic_start = state.diagnostics.items.len;
    var text_cache = render_text.Cache.init(std.heap.smp_allocator, io);
    defer text_cache.deinit();
    text_cache.restore(options.cache_dir);
    const ir_allocator = std.heap.smp_allocator;
    var ir = render_compile.compilePrepared(ir_allocator, io, &state, &pages, .{
        .jobs = options.jobs,
        .cache_dir = options.cache_dir,
        .highlight_languages = options.highlight_languages,
        .text_cache = &text_cache,
        .font_environment = font_environment,
        .thread_safe_allocator = true,
    }) catch |err| {
        progress.abort();
        error_report.printDocumentStateDiagnostics(state.projectPath(), state.projectSource(), &state);
        app_output.writeDiagnosticsJsonIfRequested(io, allocator, &state, diagnostics_json_path) catch {};
        if (error_report.hasDocumentStateErrors(&state)) return error.DiagnosticsFailed;
        return err;
    };
    errdefer ir.deinit(ir_allocator);
    text_cache.persist(options.cache_dir);
    progress.complete();
    error_report.printDocumentStateDiagnosticsFrom(state.projectPath(), state.projectSource(), &state, diagnostic_start);
    return .{
        .state = state,
        .pages = pages,
        .layouts = layouts,
        .ir = ir,
        .ir_allocator = ir_allocator,
    };
}
