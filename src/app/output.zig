const std = @import("std");
const core = @import("core");
const render = @import("render");
const pdf = @import("../render/pdf.zig");
const utils = @import("utils");

const app_progress = @import("progress.zig");
const types = @import("types.zig");

const error_report = utils.err;
const Progress = utils.progress.Progress;

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
    return pdf.write(allocator, io, ir, output_path, .{
        .jobs = options.jobs,
        .cache_dir = options.cache_dir,
    }, app_progress.pdfWrite(progress)) catch |err| {
        progress.endStatusLine();
        error_report.printDocumentStateDiagnostics(state.projectPath(), state.projectSource(), state);
        try writeDiagnosticsJsonIfRequested(io, allocator, state, diagnostics_json_path);
        if (error_report.hasDocumentStateErrors(state)) return error.DiagnosticsFailed;
        return err;
    };
}

pub fn writeDiagnosticsJsonIfRequested(
    io: std.Io,
    allocator: std.mem.Allocator,
    state: *core.DocumentState,
    diagnostics_json_path: ?[]const u8,
) !void {
    const path = diagnostics_json_path orelse return;
    const data = try error_report.irDiagnosticsJson(allocator, state.projectPath(), state.projectSource(), state, .{});
    defer allocator.free(data);
    try utils.fs.writeFile(io, path, data);
}
