const std = @import("std");
const core = @import("core");
const ast = @import("ast");
const parser = @import("syntax.zig");
const lowering = @import("lowering.zig");
const pdf = @import("render/pdf.zig");
const render_layout = @import("render/layout.zig");
const dump = @import("dump.zig");
const analysis = @import("analysis.zig");
const module_loader = @import("modules/loader.zig");
const utils = @import("utils");
const error_report = utils.err;

pub const RenderOptions = pdf.RenderOptions;
const Progress = utils.progress.Progress;

pub const PdfWriteOptions = struct {
    render: RenderOptions = .{},
    diagnostics_json_path: ?[]const u8 = null,
};

pub const SourceRequest = struct {
    input_path: []const u8,
    asset_base_dir: []const u8,
    overlay: ?*const module_loader.SourceOverlay = null,
};

pub const PdfWriteRequest = struct {
    source: SourceRequest,
    output_path: []const u8,
    options: PdfWriteOptions = .{},
};

const AnalyzedFile = struct {
    ir: core.Ir,
    program_analysis: analysis.ProgramAnalysis = .{},

    fn deinit(self: *AnalyzedFile) void {
        self.program_analysis.deinit();
        self.ir.deinit();
    }

    fn takeIr(self: *AnalyzedFile) core.Ir {
        self.program_analysis.deinit();
        const ir = self.ir;
        self.* = undefined;
        return ir;
    }

    fn scheduleGraph(self: *const AnalyzedFile) *const analysis.schedule.ScheduleGraph {
        return self.program_analysis.scheduleGraph();
    }
};

const ParsedSource = struct {
    program: parser.Program,
    holes: parser.HoleTable,

    fn deinit(self: *ParsedSource, allocator: std.mem.Allocator) void {
        self.program.deinit(allocator);
        self.holes.deinit(allocator);
    }

    fn clearHoles(self: *ParsedSource, allocator: std.mem.Allocator) void {
        self.holes.deinit(allocator);
        self.holes = .{ .holes = &.{}, .diagnostics = &.{} };
    }
};

pub fn buildFile(io: std.Io, allocator: std.mem.Allocator, request: SourceRequest, progress: ?*Progress) !core.Ir {
    var analyzed = try buildAnalyzedFile(io, allocator, request, progress, .evaluation_schedule);
    errdefer analyzed.deinit();
    try evaluateDocumentOrReportWithSchedule(&analyzed.ir, analyzed.scheduleGraph(), progress);
    try solveLayoutOrReport(io, &analyzed.ir, progress);
    return analyzed.takeIr();
}

pub fn buildTypedFile(io: std.Io, allocator: std.mem.Allocator, request: SourceRequest, progress: ?*Progress) !core.Ir {
    var analyzed = try buildAnalyzedFile(io, allocator, request, progress, .diagnostics_only);
    errdefer analyzed.deinit();
    return analyzed.takeIr();
}

fn buildAnalyzedFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    request: SourceRequest,
    progress: ?*Progress,
    mode: analysis.AnalysisMode,
) !AnalyzedFile {
    var source = if (request.overlay) |source_overlay|
        if (source_overlay.get(request.input_path)) |text|
            try allocator.dupe(u8, text)
        else
            try utils.fs.readFileAlloc(io, allocator, request.input_path)
    else
        try utils.fs.readFileAlloc(io, allocator, request.input_path);
    errdefer allocator.free(source);
    if (progress) |p| p.step("Read inputs");

    var parsed = try parseSource(allocator, source, request.input_path);
    errdefer parsed.deinit(allocator);
    if (progress) |p| p.step("Parse source");

    var load_diagnostics = module_loader.LoadDiagnostics.init(allocator);
    defer load_diagnostics.deinit();
    var index = analysis.loadProgramIndexWithOptions(allocator, io, request.asset_base_dir, parsed.program, .{
        .overlay = request.overlay,
        .diagnostics = &load_diagnostics,
        .print_diagnostics = false,
    }) catch |err| {
        if (load_diagnostics.items.items.len != 0) {
            printLoadDiagnostics(&load_diagnostics);
            printImportFailureDiagnostic(allocator, io, request.input_path, source, request.asset_base_dir, &parsed.program, request.overlay, &load_diagnostics);
            return error.DiagnosticsFailed;
        } else if (err == error.UnknownImport) {
            var report = try module_loader.findUnknownImportReport(allocator, io, request.asset_base_dir, parsed.program, request.overlay) orelse return err;
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
            return error.DiagnosticsFailed;
        }
        return err;
    };
    if (progress) |p| p.step("Load modules");

    var ir = analysis.buildIrWithOptions(allocator, request.input_path, request.asset_base_dir, &source, &parsed.program, &index, .{
        .parse_holes = parsed.holes,
    }) catch |err| {
        if (err == error.UnknownImport) {
            var report = try module_loader.findUnknownImportReport(allocator, io, request.asset_base_dir, parsed.program, request.overlay) orelse return err;
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
        } else if (err != error.DiagnosticsFailed) {
            const message = try std.fmt.allocPrint(allocator, "BuildFailed: {s}", .{@errorName(err)});
            defer allocator.free(message);
            error_report.print(.{
                .path = request.input_path,
                .source = source,
                .severity = .@"error",
                .message = message,
                .span = null,
            });
        }
        return err;
    };
    parsed.clearHoles(allocator);
    defer index.deinit();
    errdefer ir.deinit();

    var program_analysis = analysis.analyzeProgramWithMode(allocator, &ir, mode) catch |err| {
        error_report.printIrDiagnostics(ir.projectPath(), ir.projectSource(), &ir);
        return err;
    };
    errdefer program_analysis.deinit();
    if (progress) |p| p.step("Analyze");

    if (error_report.hasIrErrors(&ir)) {
        error_report.printIrDiagnostics(ir.projectPath(), ir.projectSource(), &ir);
        return error.DiagnosticsFailed;
    }
    return .{ .ir = ir, .program_analysis = program_analysis };
}

fn evaluateDocumentOrReportWithSchedule(ir: *core.Ir, graph: *const analysis.schedule.ScheduleGraph, progress: ?*Progress) !void {
    lowering.evaluateDocumentWithSchedule(ir, graph) catch |err| {
        error_report.printIrDiagnostics(ir.projectPath(), ir.projectSource(), ir);
        return err;
    };
    if (progress) |p| p.step("Evaluate document");
}

fn solveLayoutOrReport(io: std.Io, ir: *core.Ir, progress: ?*Progress) !void {
    render_layout.solveWithPdfMeasurements(io, ir) catch |err| {
        switch (err) {
            error.ConstraintConflict, error.NegativeFrameSize => error_report.printConstraintFailure(ir.projectPath(), ir.projectSource(), ir, err),
            else => {
                error_report.printIrDiagnostics(ir.projectPath(), ir.projectSource(), ir);
                if (error_report.hasIrErrors(ir)) return error.DiagnosticsFailed;
            },
        }
        return err;
    };
    if (progress) |p| p.step("Solve layout");
    error_report.printIrDiagnostics(ir.projectPath(), ir.projectSource(), ir);
    if (error_report.hasIrErrors(ir)) return error.DiagnosticsFailed;
}

fn solveLayoutWithTracePathOrReport(io: std.Io, ir: *core.Ir, trace_path: []const u8, progress: ?*Progress) !void {
    render_layout.solveWithPdfMeasurementsAndTracePath(io, ir, trace_path) catch |err| {
        switch (err) {
            error.ConstraintConflict, error.NegativeFrameSize => error_report.printConstraintFailure(ir.projectPath(), ir.projectSource(), ir, err),
            else => {
                error_report.printIrDiagnostics(ir.projectPath(), ir.projectSource(), ir);
                if (error_report.hasIrErrors(ir)) return error.DiagnosticsFailed;
            },
        }
        return err;
    };
    if (progress) |p| p.step("Solve layout");
    error_report.printIrDiagnostics(ir.projectPath(), ir.projectSource(), ir);
    if (error_report.hasIrErrors(ir)) return error.DiagnosticsFailed;
}

pub fn checkFile(io: std.Io, allocator: std.mem.Allocator, request: SourceRequest) !void {
    var ir = try buildFile(io, allocator, request, null);
    defer ir.deinit();
    std.debug.print("ok {s}\n", .{request.input_path});
}

pub fn printIrJson(io: std.Io, allocator: std.mem.Allocator, request: SourceRequest, progress: *Progress) !void {
    var ir = try buildFile(io, allocator, request, progress);
    defer ir.deinit();
    const text = try dump.toOwnedString(allocator, &ir);
    defer allocator.free(text);
    progress.step("Serialize JSON");
    try utils.io.writeStdoutAll(text);
    progress.step("Print dump");
}

pub fn writeIrJson(io: std.Io, allocator: std.mem.Allocator, request: SourceRequest, output_path: []const u8, progress: *Progress) !void {
    var ir = try buildFile(io, allocator, request, progress);
    defer ir.deinit();
    const json = try dump.toOwnedString(allocator, &ir);
    defer allocator.free(json);
    progress.step("Serialize JSON");
    try utils.fs.writeFile(io, output_path, json);
    progress.step("Write JSON");
}

pub fn writeScheduleTraceJson(io: std.Io, allocator: std.mem.Allocator, request: SourceRequest, output_path: []const u8, progress: *Progress) !void {
    var analyzed = try buildAnalyzedFile(io, allocator, request, progress, .evaluation_schedule);
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

pub fn writeLayoutTraceJson(io: std.Io, allocator: std.mem.Allocator, request: SourceRequest, output_path: []const u8, progress: *Progress) !void {
    var analyzed = try buildAnalyzedFile(io, allocator, request, progress, .evaluation_schedule);
    defer analyzed.deinit();
    try evaluateDocumentOrReportWithSchedule(&analyzed.ir, analyzed.scheduleGraph(), progress);
    try solveLayoutWithTracePathOrReport(io, &analyzed.ir, output_path, progress);
}

pub fn layoutConflictReportJson(
    io: std.Io,
    allocator: std.mem.Allocator,
    request: SourceRequest,
    progress: ?*Progress,
) ![]u8 {
    var analyzed = try buildAnalyzedFile(io, allocator, request, progress, .evaluation_schedule);
    defer analyzed.deinit();
    try evaluateDocumentOrReportWithSchedule(&analyzed.ir, analyzed.scheduleGraph(), progress);
    render_layout.solveWithPdfMeasurements(io, &analyzed.ir) catch |err| switch (err) {
        error.ConstraintConflict,
        error.NegativeFrameSize,
        => {},
        else => {
            error_report.printIrDiagnostics(analyzed.ir.projectPath(), analyzed.ir.projectSource(), &analyzed.ir);
            return err;
        },
    };
    if (progress) |p| p.step("Solve layout");
    const data = try core.layout.conflicts.toJson(allocator, &analyzed.ir);
    if (progress) |p| p.step("Serialize report");
    return data;
}

pub fn writeLayoutConflictReportFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    request: SourceRequest,
    output_path: []const u8,
    progress: *Progress,
) !void {
    const data = try layoutConflictReportJson(io, allocator, request, progress);
    defer allocator.free(data);
    try utils.fs.writeFile(io, output_path, data);
    progress.step("Write report");
}

pub fn writePdf(io: std.Io, allocator: std.mem.Allocator, request: PdfWriteRequest, progress: *Progress) !void {
    var analyzed = try buildAnalyzedFile(io, allocator, request.source, progress, .evaluation_schedule);
    var analyzed_active = true;
    errdefer if (analyzed_active) analyzed.deinit();
    try evaluateDocumentOrReportWithSchedule(&analyzed.ir, analyzed.scheduleGraph(), progress);
    solveLayoutOrReport(io, &analyzed.ir, progress) catch |err| {
        try writeDiagnosticsJsonIfRequested(io, allocator, &analyzed.ir, request.options.diagnostics_json_path);
        return err;
    };
    var ir = analyzed.takeIr();
    analyzed_active = false;
    defer ir.deinit();
    const pdf_data = try renderPdfOrPrintDiagnostics(allocator, io, &ir, request.options.render, progress, request.options.diagnostics_json_path);
    defer allocator.free(pdf_data);
    try writeDiagnosticsJsonIfRequested(io, allocator, &ir, request.options.diagnostics_json_path);
    try utils.render_cache.pruneFromEnv(io, allocator);
    progress.step("Render pages");
    try utils.fs.writeFile(io, request.output_path, pdf_data);
    progress.step("Write PDF");
}

fn renderPdfOrPrintDiagnostics(
    allocator: std.mem.Allocator,
    io: std.Io,
    ir: *core.Ir,
    options: RenderOptions,
    progress: *Progress,
    diagnostics_json_path: ?[]const u8,
) ![]const u8 {
    return pdf.renderDocumentToPdfWithOptions(allocator, io, ir, options, progressCallback(progress)) catch |err| {
        error_report.printIrDiagnostics(ir.projectPath(), ir.projectSource(), ir);
        try writeDiagnosticsJsonIfRequested(io, allocator, ir, diagnostics_json_path);
        if (error_report.hasIrErrors(ir)) return error.DiagnosticsFailed;
        return err;
    };
}

fn writeDiagnosticsJsonIfRequested(io: std.Io, allocator: std.mem.Allocator, ir: *core.Ir, diagnostics_json_path: ?[]const u8) !void {
    const path = diagnostics_json_path orelse return;
    const data = try error_report.irRenderDiagnosticsJson(allocator, ir.projectPath(), ir.projectSource(), ir);
    defer allocator.free(data);
    try utils.fs.writeFile(io, path, data);
}

fn parseSource(allocator: std.mem.Allocator, source: []const u8, path: []const u8) !ParsedSource {
    const result = parser.parseRecoveringWithSourceName(allocator, source, path) catch |err| {
        error_report.printParseError(path, source, err, parser.lastParseDiagnostic());
        return err;
    };
    return .{ .program = result.program, .holes = result.holes };
}

fn printLoadDiagnostics(diagnostics: *const module_loader.LoadDiagnostics) void {
    for (diagnostics.items.items) |item| {
        error_report.print(.{
            .path = item.path,
            .source = item.source,
            .severity = loadDiagnosticSeverity(item.severity),
            .message = item.message,
            .span = item.span,
        });
    }
}

fn printImportFailureDiagnostic(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    source: []const u8,
    asset_base_dir: []const u8,
    program: *const ast.Program,
    overlay: ?*const module_loader.SourceOverlay,
    diagnostics: *const module_loader.LoadDiagnostics,
) void {
    const span = module_loader.importFailureSpan(allocator, io, asset_base_dir, program, overlay, diagnostics) orelse return;
    error_report.print(.{
        .path = path,
        .source = source,
        .severity = .@"error",
        .message = "ImportFailed: imported module failed to load",
        .span = span,
    });
}

fn loadDiagnosticSeverity(severity: core.DiagnosticSeverity) error_report.Severity {
    return switch (severity) {
        .warning => .warning,
        .@"error" => .@"error",
    };
}

fn progressCallback(progress: *Progress) pdf.RenderProgress {
    return .{
        .context = progress,
        .artifactCompleted = onRenderArtifact,
        .pageCompleted = onRenderPage,
        .assemblyCompleted = onRenderAssembly,
    };
}

fn onRenderArtifact(context: *anyopaque, completed: usize, total: usize) void {
    const progress: *Progress = @ptrCast(@alignCast(context));
    progress.detail("Artifacts", completed, total);
}

fn onRenderPage(context: *anyopaque, completed: usize, total: usize) void {
    const progress: *Progress = @ptrCast(@alignCast(context));
    progress.detail("Pages", completed, total);
}

fn onRenderAssembly(context: *anyopaque, completed: usize, total: usize) void {
    const progress: *Progress = @ptrCast(@alignCast(context));
    progress.detail("Assemble", completed, total);
}
