const std = @import("std");
const core = @import("core");
const render = @import("render");
const pdf = @import("../render/pdf.zig");
const project = @import("../project.zig");
const utils = @import("utils");

const app_progress = @import("progress.zig");
const types = @import("types.zig");

const error_report = utils.err;
const Progress = utils.progress.Progress;

pub const OutputKind = enum {
    dump_json,
    schedule_trace,
    layout_trace,
    layout_conflict_report,
    html,
    pdf,
    diagnostics_json,
};

pub const OutputTarget = struct {
    path: []const u8,
    kind: OutputKind,
};

pub fn writeFileOrPrintDiagnostic(
    io: std.Io,
    path: []const u8,
    data: []const u8,
    kind: OutputKind,
) !void {
    utils.fs.writeFile(io, path, data) catch |err| {
        printOutputWriteFailure(kind, path, err);
        return error.DiagnosticsFailed;
    };
}

pub fn validateOutputPathAgainstSources(
    io: std.Io,
    allocator: std.mem.Allocator,
    state: *const core.DocumentState,
    path: []const u8,
    kind: OutputKind,
) !void {
    for (state.modules.items) |module| {
        const source_path = module.path orelse continue;
        if (!try project.pathsReferToSameFile(allocator, io, path, source_path)) continue;
        const absolute_output = try project.absolutePath(allocator, path);
        defer allocator.free(absolute_output);
        const message = try std.fmt.allocPrint(
            allocator,
            "OutputPathConflictsWithSource: {s} '{s}' resolves to source module '{s}'; choose a different output path",
            .{ outputKindLabel(kind), absolute_output, source_path },
        );
        defer allocator.free(message);
        error_report.print(.{
            .path = absolute_output,
            .source = "",
            .severity = .@"error",
            .message = message,
            .span = null,
        });
        return error.DiagnosticsFailed;
    }
}

pub fn validateDistinctOutputPaths(
    io: std.Io,
    allocator: std.mem.Allocator,
    targets: []const OutputTarget,
) !void {
    for (targets, 0..) |left, left_index| {
        for (targets[left_index + 1 ..]) |right| {
            if (!try project.pathsReferToSameFile(allocator, io, left.path, right.path)) continue;
            const absolute_path = try project.absolutePath(allocator, left.path);
            defer allocator.free(absolute_path);
            const message = try std.fmt.allocPrint(
                allocator,
                "OutputPathsConflict: {s} and {s} resolve to the same file '{s}'; choose different output paths",
                .{ outputKindLabel(left.kind), outputKindLabel(right.kind), absolute_path },
            );
            defer allocator.free(message);
            error_report.print(.{
                .path = absolute_path,
                .source = "",
                .severity = .@"error",
                .message = message,
                .span = null,
            });
            return error.DiagnosticsFailed;
        }
    }
}

pub fn outputWriteFailed(kind: OutputKind, path: []const u8, err: anyerror) error{DiagnosticsFailed} {
    printOutputWriteFailure(kind, path, err);
    return error.DiagnosticsFailed;
}

pub fn htmlMaterializationFailed(path: []const u8, operation: []const u8, err: anyerror) error{DiagnosticsFailed} {
    var message_buf: [8192]u8 = undefined;
    var reason_buf: [256]u8 = undefined;
    const message = std.fmt.bufPrint(
        &message_buf,
        "HtmlMaterializationFailed: could not {s} for '{s}': {s}; retry, and report this as an ss bug if the failure persists",
        .{ operation, path, outputFailureReason(&reason_buf, err) },
    ) catch "HtmlMaterializationFailed: HTML materialization failed and its diagnostic message was too long";
    error_report.print(.{
        .path = path,
        .source = "",
        .severity = .@"error",
        .message = message,
        .span = null,
    });
    return error.DiagnosticsFailed;
}

pub fn layoutTraceMaterializationFailed(path: []const u8, operation: []const u8, err: anyerror) error{DiagnosticsFailed} {
    var message_buf: [8192]u8 = undefined;
    var reason_buf: [256]u8 = undefined;
    const message = std.fmt.bufPrint(
        &message_buf,
        "LayoutTraceGenerationFailed: could not {s} for '{s}': {s}; retry, and report this as an ss bug if the failure persists",
        .{ operation, path, outputFailureReason(&reason_buf, err) },
    ) catch "LayoutTraceGenerationFailed: layout trace generation failed and its diagnostic message was too long";
    error_report.print(.{
        .path = path,
        .source = "",
        .severity = .@"error",
        .message = message,
        .span = null,
    });
    return error.DiagnosticsFailed;
}

pub fn pruneRenderCacheOrPrintWarning(io: std.Io, allocator: std.mem.Allocator) void {
    utils.render_cache.pruneFromEnv(io, allocator) catch |err| {
        var message_buf: [8192]u8 = undefined;
        var reason_buf: [256]u8 = undefined;
        const message = std.fmt.bufPrint(
            &message_buf,
            "RenderCachePruneFailed: could not prune render cache '{s}': {s}; rendered output was written successfully",
            .{ utils.render_cache.path, error_report.formatErrorReason(&reason_buf, err) },
        ) catch "RenderCachePruneFailed: rendered output was written, but the render cache could not be pruned";
        error_report.print(.{
            .path = utils.render_cache.path,
            .source = "",
            .severity = .warning,
            .message = message,
            .span = null,
        });
    };
}

pub fn writePdfOrPrintDiagnostics(
    allocator: std.mem.Allocator,
    io: std.Io,
    state: *core.DocumentState,
    ir: *const render.Ir,
    output_path: []const u8,
    options: types.RenderOptions,
    progress: *Progress,
    diagnostics_json_path: ?[]const u8,
) !void {
    var write_failure = pdf.WriteFailure{};
    defer write_failure.deinit(allocator);
    return pdf.writeValidated(allocator, io, ir, output_path, .{
        .jobs = options.jobs,
        .cache_dir = options.cache_dir,
        .failure = &write_failure,
    }, app_progress.pdfWrite(progress)) catch |err| {
        progress.abort();
        error_report.printDocumentStateDiagnostics(state.projectPath(), state.projectSource(), state);
        if (!error_report.hasDocumentStateErrors(state)) {
            if (write_failure.cause != null) {
                printPdfWriteFailure(&write_failure, output_path);
            } else {
                printUnclassifiedPdfFailure(output_path, err);
            }
        }
        writeDiagnosticsJsonIfRequested(io, allocator, state, diagnostics_json_path) catch {};
        return error.DiagnosticsFailed;
    };
}

pub fn writeDiagnosticsJsonIfRequested(
    io: std.Io,
    allocator: std.mem.Allocator,
    state: *core.DocumentState,
    diagnostics_json_path: ?[]const u8,
) !void {
    const path = diagnostics_json_path orelse return;
    try validateOutputPathAgainstSources(io, allocator, state, path, .diagnostics_json);
    const data = error_report.irDiagnosticsJson(allocator, state.projectPath(), state.projectSource(), state, .{}) catch |err| {
        printDiagnosticsSerializationFailure(path, err);
        return error.DiagnosticsFailed;
    };
    defer allocator.free(data);
    try writeFileOrPrintDiagnostic(io, path, data, .diagnostics_json);
}

fn printOutputWriteFailure(kind: OutputKind, path: []const u8, err: anyerror) void {
    var message_buf: [8192]u8 = undefined;
    var reason_buf: [256]u8 = undefined;
    const message = std.fmt.bufPrint(
        &message_buf,
        "{s}: could not write {s} '{s}': {s}",
        .{ outputFailureCode(kind), outputKindLabel(kind), path, outputFailureReason(&reason_buf, err) },
    ) catch "OutputWriteFailed: the output operation failed and its diagnostic message was too long";
    error_report.print(.{
        .path = path,
        .source = "",
        .severity = .@"error",
        .message = message,
        .span = null,
    });
}

fn printPdfWriteFailure(failure: *const pdf.WriteFailure, fallback_output_path: []const u8) void {
    const cause = failure.cause orelse return;
    const path = failure.pathOr(fallback_output_path);
    var message_buf: [8192]u8 = undefined;
    var reason_buf: [256]u8 = undefined;
    const detail = failure.detail orelse outputFailureReason(&reason_buf, cause);
    const message = switch (failure.kind) {
        .preparation => std.fmt.bufPrint(
            &message_buf,
            "PdfPreparationFailed: could not {s} for '{s}': {s}; retry, and report this as an ss bug if the failure persists",
            .{ failure.operation, path, detail },
        ) catch "PdfPreparationFailed: PDF preparation failed and its diagnostic message was too long",
        .output => std.fmt.bufPrint(
            &message_buf,
            "PdfOutputWriteFailed: could not {s} '{s}': {s}",
            .{ failure.operation, path, detail },
        ) catch "PdfOutputWriteFailed: the PDF output operation failed and its diagnostic message was too long",
        .cache => std.fmt.bufPrint(
            &message_buf,
            "PdfCacheAccessFailed: could not {s} '{s}': {s}; fix the conflicting path or its permissions, or run 'ss cache project clear' if the cache is stale",
            .{ failure.operation, path, detail },
        ) catch "PdfCacheAccessFailed: the PDF cache operation failed and its diagnostic message was too long",
        .page_render => std.fmt.bufPrint(
            &message_buf,
            "PdfPageRenderFailed: could not {s} '{s}': {s}",
            .{ failure.operation, path, detail },
        ) catch "PdfPageRenderFailed: a PDF page could not be rendered and its diagnostic message was too long",
        .assembly => std.fmt.bufPrint(
            &message_buf,
            "PdfAssemblyFailed: could not {s} '{s}': {s}; run 'ss cache project clear' and retry",
            .{ failure.operation, path, detail },
        ) catch "PdfAssemblyFailed: the PDF document could not be assembled and its diagnostic message was too long",
    };
    error_report.print(.{
        .path = path,
        .source = "",
        .severity = .@"error",
        .message = message,
        .span = null,
    });
}

fn printUnclassifiedPdfFailure(path: []const u8, err: anyerror) void {
    var message_buf: [8192]u8 = undefined;
    var reason_buf: [256]u8 = undefined;
    const message = std.fmt.bufPrint(
        &message_buf,
        "PdfPreparationFailed: PDF generation stopped before ss could record the failing operation for '{s}': {s}; report this as an ss bug",
        .{ path, outputFailureReason(&reason_buf, err) },
    ) catch "PdfPreparationFailed: PDF generation failed before ss could record the failing operation; report this as an ss bug";
    error_report.print(.{
        .path = path,
        .source = "",
        .severity = .@"error",
        .message = message,
        .span = null,
    });
}

fn printDiagnosticsSerializationFailure(path: []const u8, err: anyerror) void {
    var message_buf: [8192]u8 = undefined;
    var reason_buf: [256]u8 = undefined;
    const message = std.fmt.bufPrint(
        &message_buf,
        "DiagnosticsOutputFailed: could not serialize diagnostics for '{s}': {s}",
        .{ path, error_report.formatErrorReason(&reason_buf, err) },
    ) catch "DiagnosticsOutputFailed: diagnostics serialization failed and its diagnostic message was too long";
    error_report.print(.{
        .path = path,
        .source = "",
        .severity = .@"error",
        .message = message,
        .span = null,
    });
}

fn outputFailureCode(kind: OutputKind) []const u8 {
    return switch (kind) {
        .dump_json => "DumpOutputWriteFailed",
        .schedule_trace => "ScheduleTraceWriteFailed",
        .layout_trace => "LayoutTraceWriteFailed",
        .layout_conflict_report => "LayoutConflictReportWriteFailed",
        .html => "HtmlOutputWriteFailed",
        .pdf => "PdfOutputWriteFailed",
        .diagnostics_json => "DiagnosticsOutputWriteFailed",
    };
}

fn outputKindLabel(kind: OutputKind) []const u8 {
    return switch (kind) {
        .dump_json => "dump JSON",
        .schedule_trace => "schedule trace JSON",
        .layout_trace => "layout trace JSON",
        .layout_conflict_report => "layout conflict report",
        .html => "HTML output",
        .pdf => "PDF output",
        .diagnostics_json => "diagnostics JSON",
    };
}

fn outputFailureReason(buf: []u8, err: anyerror) []const u8 {
    return switch (err) {
        error.OutputPathNotFile => "the destination cannot be replaced with a regular file",
        error.PdfPageRenderFailed => "one or more pages could not be rendered as PDF",
        error.PdfAssemblyFailed => "the rendered PDF pages could not be assembled into the destination file",
        error.CairoCreateFailed => "the native PDF backend could not create the destination file",
        error.CairoFailed => "the native PDF backend reported a drawing failure",
        error.ImageDecodeFailed => "an image could not be decoded while writing the output; verify that its contents match its file format",
        error.AssetConversionFailed => "an asset could not be converted while writing the output; verify the asset and required external tools",
        error.UnsupportedAssetType => "an object refers to an unsupported asset type; use image! for images and pdf! for PDF files",
        error.InvalidFontCollection => "a font resource is not a valid OpenType font or collection",
        error.InvalidFontFaceIndex => "a font resource refers to a face index outside the font collection",
        error.FontTooLarge => "a font resource exceeds the HTML embedding size limit",
        error.FontEmbeddingRestricted => "a font license forbids embedding this font in HTML output",
        error.MissingRenderFont => "the compiled document refers to a font that is unavailable during output",
        error.MissingRenderResource => "the compiled document refers to an asset that is unavailable during output",
        error.InvalidTextLayout => "the compiled document contains an invalid text layout",
        else => error_report.formatErrorReason(buf, err),
    };
}
