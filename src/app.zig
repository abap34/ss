const std = @import("std");
const core = @import("core");
const ast = @import("ast");
const parser = @import("syntax.zig");
const lowering = @import("lowering.zig");
const pdf = @import("render/pdf.zig");
const dump = @import("dump.zig");
const typecheck = @import("analysis/typecheck.zig");
const module_loader = @import("modules/loader.zig");
const utils = @import("utils");
const error_report = utils.err;

pub const RenderOptions = pdf.RenderOptions;
const Progress = utils.progress.Progress;

pub fn buildFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8, progress: ?*Progress) !core.Ir {
    const asset_base_dir = std.fs.path.dirname(path) orelse ".";
    return buildFileWithAssetBase(io, allocator, path, asset_base_dir, progress);
}

pub fn buildFileWithAssetBase(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    asset_base_dir: []const u8,
    progress: ?*Progress,
) !core.Ir {
    return buildFileWithAssetBaseAndOverlay(io, allocator, path, asset_base_dir, progress, null);
}

pub fn buildFileWithAssetBaseAndOverlay(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    asset_base_dir: []const u8,
    progress: ?*Progress,
    overlay: ?*const module_loader.SourceOverlay,
) !core.Ir {
    var source = if (overlay) |source_overlay|
        if (source_overlay.get(path)) |text|
            try allocator.dupe(u8, text)
        else
            try utils.fs.readFileAlloc(io, allocator, path)
    else
        try utils.fs.readFileAlloc(io, allocator, path);
    errdefer allocator.free(source);
    if (progress) |p| p.step("Read inputs");

    var program = try parseSource(allocator, source, path);
    errdefer program.deinit(allocator);
    if (progress) |p| p.step("Parse source");

    var index = typecheck.loadProgramIndexWithOverlay(allocator, io, asset_base_dir, program, overlay) catch |err| {
        if (err == error.UnknownImport) {
            var report = try module_loader.findUnknownImportReport(allocator, io, asset_base_dir, program, overlay) orelse return err;
            defer report.deinit(allocator);
            error_report.print(.{
                .path = path,
                .source = source,
                .severity = .@"error",
                .message = report.message,
                .span = .{
                    .start = report.span.start,
                    .end = report.span.end,
                },
            });
        } else if (err == error.ImportCycle) {
            const span = if (program.imports.items.len != 0) blk: {
                const import_span = program.imports.items[0].span;
                break :blk error_report.ByteSpan{ .start = import_span.start, .end = import_span.end };
            } else null;
            error_report.print(.{
                .path = path,
                .source = source,
                .severity = .@"error",
                .message = "ImportCycle: import graph contains a cycle",
                .span = span,
            });
            return error.DiagnosticsFailed;
        }
        return err;
    };
    if (progress) |p| p.step("Load modules");

    var ir = typecheck.buildIr(allocator, path, asset_base_dir, &source, &program, &index) catch |err| {
        if (err == error.UnknownImport) {
            var report = try module_loader.findUnknownImportReport(allocator, io, asset_base_dir, program, overlay) orelse return err;
            defer report.deinit(allocator);
            error_report.print(.{
                .path = path,
                .source = source,
                .severity = .@"error",
                .message = report.message,
                .span = .{
                    .start = report.span.start,
                    .end = report.span.end,
                },
            });
        } else if (err != error.DiagnosticsFailed) {
            std.debug.print("error: {s}\n", .{@errorName(err)});
        }
        return err;
    };
    defer index.deinit();
    errdefer ir.deinit();

    typecheck.typecheckProgram(allocator, &ir) catch |err| {
        error_report.printIrDiagnostics(ir.projectPath(), ir.projectSource(), &ir);
        return err;
    };
    if (progress) |p| p.step("Typecheck");

    if (error_report.hasIrErrors(&ir)) {
        error_report.printIrDiagnostics(ir.projectPath(), ir.projectSource(), &ir);
        return error.DiagnosticsFailed;
    }

    lowering.evaluateDocument(&ir) catch |err| {
        error_report.printIrDiagnostics(ir.projectPath(), ir.projectSource(), &ir);
        return err;
    };
    if (progress) |p| p.step("Evaluate document");

    lowering.solveLayout(&ir) catch |err| {
        switch (err) {
            error.ConstraintConflict, error.NegativeConstraintSize => error_report.printConstraintFailure(ir.projectPath(), ir.projectSource(), &ir, err, core.formatConstraint),
            else => error_report.printIrDiagnostics(ir.projectPath(), ir.projectSource(), &ir),
        }
        return err;
    };
    if (progress) |p| p.step("Solve layout");
    error_report.printIrDiagnostics(ir.projectPath(), ir.projectSource(), &ir);
    if (error_report.hasIrErrors(&ir)) return error.DiagnosticsFailed;
    return ir;
}

pub fn checkFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !void {
    var ir = try buildFile(io, allocator, path, null);
    defer ir.deinit();
    std.debug.print("ok {s}\n", .{path});
}

pub fn checkFileWithAssetBase(io: std.Io, allocator: std.mem.Allocator, path: []const u8, asset_base_dir: []const u8) !void {
    var ir = try buildFileWithAssetBase(io, allocator, path, asset_base_dir, null);
    defer ir.deinit();
    std.debug.print("ok {s}\n", .{path});
}

pub fn printIrJsonForFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8, progress: *Progress) !void {
    var ir = try buildFile(io, allocator, path, progress);
    defer ir.deinit();
    const text = try dump.toOwnedString(allocator, &ir);
    defer allocator.free(text);
    progress.step("Serialize JSON");
    try utils.io.writeStdoutAll(text);
    progress.step("Print dump");
}

pub fn printIrJsonForFileWithAssetBase(io: std.Io, allocator: std.mem.Allocator, path: []const u8, asset_base_dir: []const u8, progress: *Progress) !void {
    var ir = try buildFileWithAssetBase(io, allocator, path, asset_base_dir, progress);
    defer ir.deinit();
    const text = try dump.toOwnedString(allocator, &ir);
    defer allocator.free(text);
    progress.step("Serialize JSON");
    try utils.io.writeStdoutAll(text);
    progress.step("Print dump");
}

pub fn writeIrJsonFile(io: std.Io, allocator: std.mem.Allocator, input_path: []const u8, output_path: []const u8, progress: *Progress) !void {
    var ir = try buildFile(io, allocator, input_path, progress);
    defer ir.deinit();
    const json = try dump.toOwnedString(allocator, &ir);
    defer allocator.free(json);
    progress.step("Serialize JSON");
    try utils.fs.writeFile(io, output_path, json);
    progress.step("Write JSON");
}

pub fn writeIrJsonFileWithAssetBase(io: std.Io, allocator: std.mem.Allocator, input_path: []const u8, asset_base_dir: []const u8, output_path: []const u8, progress: *Progress) !void {
    var ir = try buildFileWithAssetBase(io, allocator, input_path, asset_base_dir, progress);
    defer ir.deinit();
    const json = try dump.toOwnedString(allocator, &ir);
    defer allocator.free(json);
    progress.step("Serialize JSON");
    try utils.fs.writeFile(io, output_path, json);
    progress.step("Write JSON");
}

pub fn writePdfForFile(io: std.Io, allocator: std.mem.Allocator, input_path: []const u8, output_path: []const u8, progress: *Progress) !void {
    return writePdfForFileWithOptions(io, allocator, input_path, output_path, .{}, progress);
}

pub fn writePdfForFileWithOptions(io: std.Io, allocator: std.mem.Allocator, input_path: []const u8, output_path: []const u8, options: RenderOptions, progress: *Progress) !void {
    var ir = try buildFile(io, allocator, input_path, progress);
    defer ir.deinit();
    const pdf_data = try renderPdfOrPrintDiagnostics(allocator, io, &ir, options, progress);
    defer allocator.free(pdf_data);
    try utils.render_cache.pruneFromEnv(io, allocator);
    progress.step("Render pages");
    try utils.fs.writeFile(io, output_path, pdf_data);
    progress.step("Write PDF");
}

pub fn writePdfForFileWithAssetBase(io: std.Io, allocator: std.mem.Allocator, input_path: []const u8, asset_base_dir: []const u8, output_path: []const u8, progress: *Progress) !void {
    return writePdfForFileWithAssetBaseAndOptions(io, allocator, input_path, asset_base_dir, output_path, .{}, progress);
}

pub fn writePdfForFileWithAssetBaseAndOptions(io: std.Io, allocator: std.mem.Allocator, input_path: []const u8, asset_base_dir: []const u8, output_path: []const u8, options: RenderOptions, progress: *Progress) !void {
    var ir = try buildFileWithAssetBase(io, allocator, input_path, asset_base_dir, progress);
    defer ir.deinit();
    const pdf_data = try renderPdfOrPrintDiagnostics(allocator, io, &ir, options, progress);
    defer allocator.free(pdf_data);
    try utils.render_cache.pruneFromEnv(io, allocator);
    progress.step("Render pages");
    try utils.fs.writeFile(io, output_path, pdf_data);
    progress.step("Write PDF");
}

fn renderPdfOrPrintDiagnostics(
    allocator: std.mem.Allocator,
    io: std.Io,
    ir: *core.Ir,
    options: RenderOptions,
    progress: *Progress,
) ![]const u8 {
    return pdf.renderDocumentToPdfWithOptions(allocator, io, ir, options, progressCallback(progress)) catch |err| {
        error_report.printIrDiagnostics(ir.projectPath(), ir.projectSource(), ir);
        if (error_report.hasIrErrors(ir)) return error.DiagnosticsFailed;
        return err;
    };
}

fn parseSource(allocator: std.mem.Allocator, source: []const u8, path: []const u8) !parser.Program {
    return parser.parseWithSourceName(allocator, source, path) catch |err| {
        error_report.printParseError(path, source, err, parser.lastParseDiagnostic());
        return err;
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
