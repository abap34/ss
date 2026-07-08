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

pub const AnalyzedFile = struct {
    ir: core.Ir,
    program_analysis: analysis.ProgramAnalysis = .{},

    pub fn deinit(self: *AnalyzedFile) void {
        self.program_analysis.deinit();
        self.ir.deinit();
    }

    pub fn takeIr(self: *AnalyzedFile) core.Ir {
        self.program_analysis.deinit();
        const ir = self.ir;
        self.* = undefined;
        return ir;
    }

    pub fn scheduleGraph(self: *const AnalyzedFile) *const analysis.schedule.ScheduleGraph {
        return self.program_analysis.scheduleGraph();
    }
};

pub fn buildFile(io: std.Io, allocator: std.mem.Allocator, request: types.SourceRequest, progress: ?*Progress) !core.Ir {
    var analyzed = try analyzeFile(io, allocator, request, progress, .evaluation_schedule);
    errdefer analyzed.deinit();
    try evaluateDocument(&analyzed.ir, analyzed.scheduleGraph(), progress);
    var pages = try preparePages(&analyzed.ir, progress);
    const ir_allocator = analyzed.ir.allocator;
    defer pages.deinit(ir_allocator);
    var layouts = try solveLayouts(io, &analyzed.ir, &pages, progress, request.layout_jobs);
    defer layouts.deinit(ir_allocator);
    return analyzed.takeIr();
}

pub fn buildTypedFile(io: std.Io, allocator: std.mem.Allocator, request: types.SourceRequest, progress: ?*Progress) !core.Ir {
    var analyzed = try analyzeFile(io, allocator, request, progress, .diagnostics_only);
    errdefer analyzed.deinit();
    return analyzed.takeIr();
}

pub fn analyzeFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    request: types.SourceRequest,
    progress: ?*Progress,
    mode: analysis.AnalysisMode,
) !AnalyzedFile {
    if (progress) |p| p.begin("Read inputs");
    var source = try readSource(io, allocator, request);
    errdefer allocator.free(source);
    if (progress) |p| p.step("Read inputs");

    if (progress) |p| p.begin("Parse source");
    var parsed = try app_diagnostics.parseSource(allocator, source, request.input_path, progress);
    errdefer parsed.deinit(allocator);
    if (progress) |p| p.step("Parse source");

    if (progress) |p| p.begin("Analyze");
    var load_diagnostics = module_loader.LoadDiagnostics.init(allocator);
    defer load_diagnostics.deinit();
    var index = analysis.loadProgramIndexWithOptions(allocator, io, request.asset_base_dir, parsed.program, .{
        .overlay = request.overlay,
        .diagnostics = &load_diagnostics,
        .print_diagnostics = false,
    }) catch |err| {
        if (progress) |p| p.endStatusLine();
        if (load_diagnostics.items.items.len != 0) {
            app_diagnostics.printLoadDiagnostics(&load_diagnostics);
            app_diagnostics.printImportFailureDiagnostic(allocator, io, request.input_path, source, request.asset_base_dir, &parsed.program, request.overlay, &load_diagnostics);
            return error.DiagnosticsFailed;
        } else if (err == error.UnknownImport) {
            try printUnknownImportDiagnostic(allocator, io, request, source, parsed.program);
            return error.DiagnosticsFailed;
        }
        return err;
    };
    defer index.deinit();
    var ir = analysis.buildIrWithOptions(allocator, request.input_path, request.asset_base_dir, &source, &parsed.program, &index, .{
        .parse_holes = parsed.holes,
    }) catch |err| {
        if (progress) |p| p.endStatusLine();
        if (err == error.UnknownImport) {
            try printUnknownImportDiagnostic(allocator, io, request, source, parsed.program);
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
    errdefer ir.deinit();

    var program_analysis = analysis.analyzeProgramWithMode(allocator, &ir, mode) catch |err| {
        if (progress) |p| p.endStatusLine();
        error_report.printIrDiagnostics(ir.projectPath(), ir.projectSource(), &ir);
        return err;
    };
    errdefer program_analysis.deinit();
    if (progress) |p| p.step("Analyze");

    if (error_report.hasIrErrors(&ir)) {
        if (progress) |p| p.endStatusLine();
        error_report.printIrDiagnostics(ir.projectPath(), ir.projectSource(), &ir);
        return error.DiagnosticsFailed;
    }
    return .{ .ir = ir, .program_analysis = program_analysis };
}

pub fn evaluateDocument(ir: *core.Ir, graph: *const analysis.schedule.ScheduleGraph, progress: ?*Progress) !void {
    if (progress) |p| p.begin("Evaluate document");
    lowering.evaluateDocumentWithSchedule(ir, graph) catch |err| {
        if (progress) |p| p.endStatusLine();
        error_report.printIrDiagnostics(ir.projectPath(), ir.projectSource(), ir);
        return err;
    };
    if (progress) |p| p.step("Evaluate document");
    if (error_report.hasIrErrors(ir)) {
        if (progress) |p| p.endStatusLine();
        error_report.printIrDiagnostics(ir.projectPath(), ir.projectSource(), ir);
        return error.DiagnosticsFailed;
    }
}

pub fn preparePages(ir: *core.Ir, progress: ?*Progress) !core.page_unit.PreparedPages {
    if (progress) |p| p.begin("Prepare pages");
    var pages = core.page_unit.prepare(ir.allocator, ir) catch |err| {
        if (progress) |p| p.endStatusLine();
        error_report.printIrDiagnostics(ir.projectPath(), ir.projectSource(), ir);
        return err;
    };
    errdefer pages.deinit(ir.allocator);
    if (progress) |p| {
        p.detail("pages", pages.pages.len, pages.pages.len);
        p.step("Prepare pages");
    }
    return pages;
}

pub fn solveLayouts(
    io: std.Io,
    ir: *core.Ir,
    pages: *const core.page_unit.PreparedPages,
    progress: ?*Progress,
    jobs: ?usize,
) !core.LayoutResults {
    const layout_progress = if (progress) |p| app_progress.layout(p) else null;
    if (progress) |p| p.begin("Solve layouts");
    try preloadLayoutArtifacts(io, ir, pages, progress, jobs);
    var layouts = render_layout.solveWithPdfMeasurementsAndPreparedPagesProgress(io, ir, pages, layout_progress, jobs) catch |err| {
        if (progress) |p| p.endStatusLine();
        try reportLayoutFailure(ir, err);
        return err;
    };
    errdefer layouts.deinit(ir.allocator);
    if (progress) |p| p.step("Solve layouts");
    error_report.printIrDiagnostics(ir.projectPath(), ir.projectSource(), ir);
    if (error_report.hasIrErrors(ir)) return error.DiagnosticsFailed;
    return layouts;
}

pub fn solveLayoutsWithTracePath(
    io: std.Io,
    ir: *core.Ir,
    pages: *const core.page_unit.PreparedPages,
    trace_path: []const u8,
    progress: ?*Progress,
    jobs: ?usize,
) !core.LayoutResults {
    const layout_progress = if (progress) |p| app_progress.layout(p) else null;
    if (progress) |p| p.begin("Solve layouts");
    try preloadLayoutArtifacts(io, ir, pages, progress, jobs);
    var layouts = render_layout.solveWithPdfMeasurementsPreparedAndTracePathProgress(io, ir, pages, trace_path, layout_progress, jobs) catch |err| {
        if (progress) |p| p.endStatusLine();
        try reportLayoutFailure(ir, err);
        return err;
    };
    errdefer layouts.deinit(ir.allocator);
    if (progress) |p| p.step("Solve layouts");
    error_report.printIrDiagnostics(ir.projectPath(), ir.projectSource(), ir);
    if (error_report.hasIrErrors(ir)) return error.DiagnosticsFailed;
    return layouts;
}

fn preloadLayoutArtifacts(
    io: std.Io,
    ir: *core.Ir,
    pages: *const core.page_unit.PreparedPages,
    progress: ?*Progress,
    jobs: ?usize,
) !void {
    const artifact_progress = if (progress) |p| app_progress.render(p) else null;
    render_layout.preloadPreparedPageArtifacts(io, ir, pages, artifact_progress, jobs) catch |err| {
        if (progress) |p| p.endStatusLine();
        error_report.printIrDiagnostics(ir.projectPath(), ir.projectSource(), ir);
        if (error_report.hasIrErrors(ir)) return error.DiagnosticsFailed;
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
    program: ast.Program,
) !void {
    var report = try module_loader.findUnknownImportReport(allocator, io, request.asset_base_dir, program, request.overlay) orelse return error.UnknownImport;
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

fn reportLayoutFailure(ir: *core.Ir, err: anyerror) !void {
    switch (err) {
        error.ConstraintConflict, error.NegativeFrameSize => error_report.printConstraintFailure(ir.projectPath(), ir.projectSource(), ir, err),
        else => {
            error_report.printIrDiagnostics(ir.projectPath(), ir.projectSource(), ir);
            if (error_report.hasIrErrors(ir)) return error.DiagnosticsFailed;
        },
    }
}
