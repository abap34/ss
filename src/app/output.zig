const std = @import("std");
const core = @import("core");
const pdf = @import("../render/pdf.zig");
const utils = @import("utils");

const app_progress = @import("progress.zig");
const types = @import("types.zig");

const error_report = utils.err;
const Progress = utils.progress.Progress;

pub fn renderPdfOrPrintDiagnostics(
    allocator: std.mem.Allocator,
    io: std.Io,
    ir: *core.Ir,
    pages: *const core.page_unit.PreparedPages,
    layouts: *const core.LayoutResults,
    options: types.RenderOptions,
    progress: *Progress,
    diagnostics_json_path: ?[]const u8,
) ![]const u8 {
    return pdf.renderDocumentToPdfWithPreparedPagesAndLayoutsAndOptions(allocator, io, ir, pages, layouts, options, app_progress.render(progress)) catch |err| {
        progress.endStatusLine();
        error_report.printIrDiagnostics(ir.projectPath(), ir.projectSource(), ir);
        try writeDiagnosticsJsonIfRequested(io, allocator, ir, diagnostics_json_path);
        if (error_report.hasIrErrors(ir)) return error.DiagnosticsFailed;
        return err;
    };
}

pub fn writeDiagnosticsJsonIfRequested(
    io: std.Io,
    allocator: std.mem.Allocator,
    ir: *core.Ir,
    diagnostics_json_path: ?[]const u8,
) !void {
    const path = diagnostics_json_path orelse return;
    const data = try error_report.irRenderDiagnosticsJson(allocator, ir.projectPath(), ir.projectSource(), ir);
    defer allocator.free(data);
    try utils.fs.writeFile(io, path, data);
}
