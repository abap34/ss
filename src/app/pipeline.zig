const std = @import("std");
const ast = @import("ast");
const core = @import("core");
const lowering = @import("../lowering.zig");
const render_layout = @import("../render/layout.zig");
const analysis = @import("../analysis.zig");
const module_loader = @import("../modules/loader.zig");
const utils = @import("utils");

const app_diagnostics = @import("diagnostics.zig");
const app_progress = @import("progress.zig");
const types = @import("types.zig");

const error_report = utils.err;
const Progress = utils.progress.Progress;

pub const AnalyzedProject = struct {
    state: core.DocumentState,
    execution_graph: ?analysis.execution.ExecutionGraph = null,

    pub fn deinit(self: *AnalyzedProject) void {
        if (self.execution_graph) |*graph| graph.deinit();
        self.state.deinit();
    }

    pub fn takeState(self: *AnalyzedProject) core.DocumentState {
        if (self.execution_graph) |*graph| graph.deinit();
        const state = self.state;
        self.* = undefined;
        return state;
    }

    pub fn executionGraph(self: *const AnalyzedProject) *const analysis.execution.ExecutionGraph {
        return &self.execution_graph.?;
    }
};

pub fn buildFile(io: std.Io, allocator: std.mem.Allocator, request: types.SourceRequest, progress: ?*Progress) !core.DocumentState {
    var analyzed = try analyzeFile(io, allocator, request, progress, .evaluation);
    errdefer analyzed.deinit();
    try evaluateDocument(&analyzed.state, analyzed.executionGraph(), progress);
    var pages = try preparePages(&analyzed.state, progress);
    const state_allocator = analyzed.state.allocator;
    defer pages.deinit(state_allocator);
    var layouts = try solveLayouts(io, &analyzed.state, &pages, progress, request.layout_jobs, request.highlight_languages, null);
    defer layouts.deinit(state_allocator);
    return analyzed.takeState();
}

pub fn buildTypedFile(io: std.Io, allocator: std.mem.Allocator, request: types.SourceRequest, progress: ?*Progress) !core.DocumentState {
    var analyzed = try analyzeFile(io, allocator, request, progress, .diagnostics_only);
    errdefer analyzed.deinit();
    return analyzed.takeState();
}

pub fn analyzeFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    request: types.SourceRequest,
    progress: ?*Progress,
    mode: analysis.AnalysisMode,
) !AnalyzedProject {
    if (progress) |p| p.begin("Read inputs");
    errdefer if (progress) |p| p.abort();
    var source = readSource(io, allocator, request) catch |err| {
        if (!error_report.isFileSystemError(err)) return err;
        var message_buf: [8192]u8 = undefined;
        error_report.print(.{
            .path = request.input_path,
            .source = "",
            .severity = .@"error",
            .message = error_report.formatPathFailure(&message_buf, "InputReadFailed", "read input file", request.input_path, err),
            .span = null,
        });
        return error.DiagnosticsFailed;
    };
    errdefer allocator.free(source);
    if (progress) |p| p.complete();

    if (progress) |p| p.begin("Parse source");
    var parsed = try app_diagnostics.parseSource(allocator, source, request.input_path, progress);
    errdefer parsed.deinit(allocator);
    if (progress) |p| p.complete();

    if (progress) |p| p.begin("Analyze");
    const import_base_dir = std.fs.path.dirname(request.input_path) orelse ".";
    var load_diagnostics = module_loader.LoadDiagnostics.init(allocator);
    defer load_diagnostics.deinit();
    var index = analysis.loadModuleIndex(allocator, io, import_base_dir, parsed.module, .{
        .overlay = request.overlay,
        .diagnostics = &load_diagnostics,
        .print_diagnostics = false,
        .embedded_cache = request.embedded_cache,
    }) catch |err| {
        if (progress) |p| p.abort();
        if (load_diagnostics.items.items.len != 0) {
            app_diagnostics.printLoadDiagnostics(&load_diagnostics);
            app_diagnostics.printImportFailureDiagnostic(allocator, io, request.input_path, source, import_base_dir, &parsed.module, request.overlay, &load_diagnostics);
            return error.DiagnosticsFailed;
        } else if (err == error.UnknownImport) {
            try printUnknownImportDiagnostic(allocator, io, request, source, parsed.module);
            return error.DiagnosticsFailed;
        } else if (module_loader.isImportReadFailure(err)) {
            try printImportReadFailureDiagnostic(allocator, io, request, source, parsed.module, err);
            return error.DiagnosticsFailed;
        }
        return err;
    };
    defer index.deinit();
    var state = analysis.buildDocumentStateWithOptions(allocator, request.input_path, request.asset_base_dir, &source, &parsed.module, &index, .{
        .parse_holes = parsed.holes,
    }) catch |err| {
        if (progress) |p| p.abort();
        if (err == error.UnknownImport) {
            try printUnknownImportDiagnostic(allocator, io, request, source, parsed.module);
            return error.DiagnosticsFailed;
        }
        if (err == error.DiagnosticsFailed or err == error.Canceled) return err;
        var message_buf: [320]u8 = undefined;
        error_report.print(.{
            .path = request.input_path,
            .source = source,
            .severity = .@"error",
            .message = error_report.formatBuildFailure(&message_buf, err),
            .span = null,
        });
        return error.DiagnosticsFailed;
    };
    app_diagnostics.clearParseHoles(&parsed, allocator);
    errdefer state.deinit();

    var execution_graph = analysis.analyzeDocumentStateWithMode(allocator, &state, mode) catch |err| {
        if (progress) |p| p.abort();
        error_report.printDocumentStateDiagnostics(state.projectPath(), state.projectSource(), &state);
        if (error_report.hasDocumentStateErrors(&state)) return error.DiagnosticsFailed;
        if (err == error.Canceled) return err;
        var message_buf: [320]u8 = undefined;
        error_report.print(.{
            .path = state.projectPath(),
            .source = state.projectSource(),
            .severity = .@"error",
            .message = error_report.formatBuildFailure(&message_buf, err),
            .span = null,
        });
        return error.DiagnosticsFailed;
    };
    errdefer if (execution_graph) |*graph| graph.deinit();
    if (progress) |p| p.complete();

    if (error_report.hasDocumentStateErrors(&state)) {
        if (progress) |p| p.abort();
        error_report.printDocumentStateDiagnostics(state.projectPath(), state.projectSource(), &state);
        return error.DiagnosticsFailed;
    }
    return .{ .state = state, .execution_graph = execution_graph };
}

pub fn evaluateDocument(state: *core.DocumentState, graph: *const analysis.execution.ExecutionGraph, progress: ?*Progress) !void {
    if (progress) |p| p.begin("Evaluate document");
    errdefer if (progress) |p| p.abort();
    lowering.evaluateDocument(state, graph, .{}) catch |err| {
        if (progress) |p| p.abort();
        error_report.printDocumentStateDiagnostics(state.projectPath(), state.projectSource(), state);
        if (error_report.hasDocumentStateErrors(state)) return error.DiagnosticsFailed;
        if (err == error.Canceled) return err;
        var message_buf: [320]u8 = undefined;
        error_report.print(.{
            .path = state.projectPath(),
            .source = state.projectSource(),
            .severity = .@"error",
            .message = error_report.formatBuildFailure(&message_buf, err),
            .span = null,
        });
        return error.DiagnosticsFailed;
    };
    if (progress) |p| p.complete();
    if (error_report.hasDocumentStateErrors(state)) {
        if (progress) |p| p.abort();
        error_report.printDocumentStateDiagnostics(state.projectPath(), state.projectSource(), state);
        return error.DiagnosticsFailed;
    }
}

pub fn preparePages(state: *core.DocumentState, progress: ?*Progress) !core.prepared.PreparedPages {
    if (progress) |p| p.begin("Prepare pages");
    errdefer if (progress) |p| p.abort();
    var pages = core.prepared.prepare(state.allocator, state) catch |err| {
        if (progress) |p| p.abort();
        error_report.printDocumentStateDiagnostics(state.projectPath(), state.projectSource(), state);
        if (error_report.hasDocumentStateErrors(state)) return error.DiagnosticsFailed;
        if (err == error.Canceled) return err;
        var message_buf: [320]u8 = undefined;
        error_report.print(.{
            .path = state.projectPath(),
            .source = state.projectSource(),
            .severity = .@"error",
            .message = error_report.formatBuildFailure(&message_buf, err),
            .span = null,
        });
        return error.DiagnosticsFailed;
    };
    errdefer pages.deinit(state.allocator);
    if (progress) |p| {
        p.detail("pages", pages.pages.len, pages.pages.len);
        p.complete();
    }
    return pages;
}

pub fn solveLayouts(
    io: std.Io,
    state: *core.DocumentState,
    pages: *const core.prepared.PreparedPages,
    progress: ?*Progress,
    jobs: ?usize,
    highlight_languages: []const utils.highlight.Language,
    font_environment: ?render_layout.FontEnvironmentToken,
) !core.layout.Document {
    const layout_progress = if (progress) |p| app_progress.layout(p) else null;
    if (progress) |p| p.begin("Solve layouts");
    errdefer if (progress) |p| p.abort();
    try preloadLayoutArtifacts(io, state, pages, progress, jobs, highlight_languages);
    var layouts = render_layout.solvePreparedPages(io, state, pages, .{
        .progress = layout_progress,
        .jobs = jobs,
        .highlight_languages = highlight_languages,
        .font_environment = font_environment,
    }) catch |err| {
        if (progress) |p| p.abort();
        try reportLayoutFailure(state, err);
        return err;
    };
    errdefer layouts.deinit(state.allocator);
    if (progress) |p| p.complete();
    error_report.printDocumentStateDiagnostics(state.projectPath(), state.projectSource(), state);
    if (error_report.hasDocumentStateErrors(state)) return error.DiagnosticsFailed;
    return layouts;
}

pub fn solveLayoutsWithTracePath(
    io: std.Io,
    state: *core.DocumentState,
    pages: *const core.prepared.PreparedPages,
    trace_path: []const u8,
    trace_failure: *core.layout.graph.TraceFailure,
    progress: ?*Progress,
    jobs: ?usize,
    highlight_languages: []const utils.highlight.Language,
) !core.layout.Document {
    const layout_progress = if (progress) |p| app_progress.layout(p) else null;
    if (progress) |p| p.begin("Solve layouts");
    errdefer if (progress) |p| p.abort();
    try preloadLayoutArtifacts(io, state, pages, progress, jobs, highlight_languages);
    var layouts = render_layout.solvePreparedPages(io, state, pages, .{
        .trace_path = trace_path,
        .trace_failure = trace_failure,
        .progress = layout_progress,
        .jobs = jobs,
        .highlight_languages = highlight_languages,
    }) catch |err| {
        if (progress) |p| p.abort();
        try reportLayoutFailure(state, err);
        return err;
    };
    errdefer layouts.deinit(state.allocator);
    if (progress) |p| p.complete();
    error_report.printDocumentStateDiagnostics(state.projectPath(), state.projectSource(), state);
    if (error_report.hasDocumentStateErrors(state)) return error.DiagnosticsFailed;
    return layouts;
}

fn preloadLayoutArtifacts(
    io: std.Io,
    state: *core.DocumentState,
    pages: *const core.prepared.PreparedPages,
    progress: ?*Progress,
    jobs: ?usize,
    highlight_languages: []const utils.highlight.Language,
) !void {
    const artifact_progress = if (progress) |p| app_progress.render(p) else null;
    render_layout.preloadPreparedPageArtifacts(io, state, pages, artifact_progress, jobs, highlight_languages) catch |err| {
        if (progress) |p| p.abort();
        error_report.printDocumentStateDiagnostics(state.projectPath(), state.projectSource(), state);
        if (error_report.hasDocumentStateErrors(state)) return error.DiagnosticsFailed;
        return err;
    };
}

fn readSource(io: std.Io, allocator: std.mem.Allocator, request: types.SourceRequest) ![]u8 {
    if (request.overlay) |source_overlay| {
        if (source_overlay.get(request.input_path)) |text| return try allocator.dupe(u8, text);
    }
    return try utils.fs.readFileAlloc(io, allocator, request.input_path);
}

fn printUnknownImportDiagnostic(
    allocator: std.mem.Allocator,
    io: std.Io,
    request: types.SourceRequest,
    source: []const u8,
    program: ast.Module,
) !void {
    const import_base_dir = std.fs.path.dirname(request.input_path) orelse ".";
    var report = try module_loader.findUnknownImportReport(allocator, io, import_base_dir, program, request.overlay) orelse return error.UnknownImport;
    defer report.deinit(allocator);
    error_report.print(.{
        .path = request.input_path,
        .source = source,
        .severity = .@"error",
        .message = report.message,
        .span = .{
            .start = report.span.start,
            .end = report.span.end,
        },
    });
}

fn printImportReadFailureDiagnostic(
    allocator: std.mem.Allocator,
    io: std.Io,
    request: types.SourceRequest,
    source: []const u8,
    program: ast.Module,
    err: anyerror,
) !void {
    const import_base_dir = std.fs.path.dirname(request.input_path) orelse ".";
    var report = try module_loader.findImportReadFailureReport(allocator, io, import_base_dir, program, request.overlay, err) orelse return err;
    defer report.deinit(allocator);
    error_report.print(.{
        .path = request.input_path,
        .source = source,
        .severity = .@"error",
        .message = report.message,
        .span = .{
            .start = report.span.start,
            .end = report.span.end,
        },
    });
}

fn reportLayoutFailure(state: *core.DocumentState, err: anyerror) !void {
    switch (err) {
        error.ConstraintConflict, error.NegativeFrameSize => error_report.printConstraintFailure(state.projectPath(), state.projectSource(), state, err),
        else => {
            error_report.printDocumentStateDiagnostics(state.projectPath(), state.projectSource(), state);
            if (error_report.hasDocumentStateErrors(state)) return error.DiagnosticsFailed;
        },
    }
}
