const std = @import("std");
const ast = @import("ast");
const core = @import("core");
const parser = @import("../syntax.zig");
const module_loader = @import("../modules/loader.zig");
const utils = @import("utils");

const error_report = utils.err;

pub const ParsedSource = struct {
    program: parser.Program,
    holes: parser.HoleTable,

    pub fn deinit(self: *ParsedSource, allocator: std.mem.Allocator) void {
        self.program.deinit(allocator);
        self.holes.deinit(allocator);
    }

    pub fn clearHoles(self: *ParsedSource, allocator: std.mem.Allocator) void {
        self.holes.deinit(allocator);
        self.holes = .{ .holes = &.{}, .diagnostics = &.{} };
    }
};

pub fn parseSource(allocator: std.mem.Allocator, source: []const u8, path: []const u8, progress: ?*utils.progress.Progress) !ParsedSource {
    const result = parser.parseRecoveringWithSourceName(allocator, source, path) catch |err| {
        if (progress) |p| p.endStatusLine();
        error_report.printParseError(path, source, err, parser.lastParseDiagnostic());
        return err;
    };
    return .{ .program = result.program, .holes = result.holes };
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
