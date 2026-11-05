const std = @import("std");
const ast = @import("ast");
const core = @import("core");
const parser = @import("../syntax.zig");
const module_loader = @import("../modules/loader.zig");
const utils = @import("utils");

const error_report = utils.err;

pub fn parseSource(io: std.Io, allocator: std.mem.Allocator, source: []const u8, path: []const u8, overlay: ?*const module_loader.SourceOverlay, inputs: ?*utils.FileInputs, progress: ?*utils.progress.Progress) !parser.ParseResult {
    var failure: parser.ParseFailure = .{};
    var diagnostics = module_loader.LoadDiagnostics.init(allocator);
    defer diagnostics.deinit();
    var loader = module_loader.IncludeLoader{ .io = io, .overlay = overlay, .diagnostics = &diagnostics, .file_inputs = inputs };
    return parser.parseRecoveringWithOptions(allocator, source, path, .{ .failure = &failure, .include_resolver = loader.resolver() }) catch |err| {
        if (progress) |p| p.abort();
        if (err == error.OutOfMemory or err == error.Canceled) return err;
        printLoadDiagnostics(&diagnostics);
        error_report.printParseError(path, source, err, failure.diagnostic);
        return error.DiagnosticsFailed;
    };
}

pub fn clearParseHoles(result: *parser.ParseResult, allocator: std.mem.Allocator) void {
    result.holes.deinit(allocator);
    result.holes = .{ .holes = &.{}, .diagnostics = &.{} };
}

pub fn printLoadDiagnostics(diagnostics: *const module_loader.LoadDiagnostics) void {
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

pub fn printImportFailureDiagnostic(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    source: []const u8,
    import_base_dir: []const u8,
    module: *const ast.Module,
    overlay: ?*const module_loader.SourceOverlay,
    diagnostics: *const module_loader.LoadDiagnostics,
) !void {
    const span = (try module_loader.importFailureSpan(allocator, io, import_base_dir, module, overlay, diagnostics)) orelse return;
    const location = ast.SourceFile.locate(module.source_files.items, path, source, span);
    error_report.print(.{
        .path = location.path,
        .source = location.source,
        .severity = .@"error",
        .message = "ImportFailed: imported module failed to load",
        .span = location.span,
    });
}

fn loadDiagnosticSeverity(severity: core.DiagnosticSeverity) error_report.Severity {
    return switch (severity) {
        .warning => .warning,
        .@"error" => .@"error",
    };
}
