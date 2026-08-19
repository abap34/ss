const std = @import("std");
const ast = @import("ast");
const core = @import("core");
const parser = @import("../syntax.zig");
const module_loader = @import("../modules/loader.zig");
const utils = @import("utils");

const error_report = utils.err;

pub fn parseSource(allocator: std.mem.Allocator, source: []const u8, path: []const u8, progress: ?*utils.progress.Progress) !parser.ParseResult {
    var failure: parser.ParseFailure = .{};
    return parser.parseRecoveringWithSourceNameAndFailure(allocator, source, path, &failure) catch |err| {
        if (progress) |p| p.abort();
        error_report.printParseError(path, source, err, failure.diagnostic);
        return err;
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
) void {
    const span = module_loader.importFailureSpan(allocator, io, import_base_dir, module, overlay, diagnostics) orelse return;
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
