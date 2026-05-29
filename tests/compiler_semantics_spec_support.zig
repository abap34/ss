const std = @import("std");
const compiler = @import("compiler");
const utils = @import("utils");

const syntax = compiler.syntax;
const lowering = compiler.lowering;
const typecheck = compiler.typecheck;
const module_loader = compiler.module_loader;

pub fn buildSource(io: std.Io, allocator: std.mem.Allocator, path: []const u8, source: []const u8) !void {
    const asset_base_dir = std.fs.path.dirname(path) orelse ".";
    var source_buf = try allocator.dupe(u8, source);
    var program = try syntax.parseWithSourceName(allocator, source_buf, path);
    var index = try typecheck.loadProgramIndex(allocator, io, asset_base_dir, program);
    defer index.deinit();

    var ir = try typecheck.buildIrWithOptions(allocator, path, asset_base_dir, &source_buf, &program, &index, .{
        .allow_diagnostics = true,
    });
    defer ir.deinit();

    try typecheck.typecheckProgram(allocator, &ir);
    if (utils.err.hasIrErrors(&ir)) return error.DiagnosticsFailed;
    try lowering.lowerToIr(&ir);
    if (utils.err.hasIrErrors(&ir)) return error.DiagnosticsFailed;
}

pub fn expectObjectContent(io: std.Io, allocator: std.mem.Allocator, path: []const u8, source: []const u8, expected: []const u8) !void {
    const asset_base_dir = std.fs.path.dirname(path) orelse ".";
    var source_buf = try allocator.dupe(u8, source);
    var program = try syntax.parseWithSourceName(allocator, source_buf, path);
    var index = try typecheck.loadProgramIndex(allocator, io, asset_base_dir, program);
    defer index.deinit();

    var ir = try typecheck.buildIrWithOptions(allocator, path, asset_base_dir, &source_buf, &program, &index, .{
        .allow_diagnostics = true,
    });
    defer ir.deinit();

    try typecheck.typecheckProgram(allocator, &ir);
    if (utils.err.hasIrErrors(&ir)) return error.DiagnosticsFailed;
    try lowering.lowerToIr(&ir);
    if (utils.err.hasIrErrors(&ir)) return error.DiagnosticsFailed;

    for (ir.nodes.items) |node| {
        if (node.kind == .object) {
            if (node.content) |content| {
                if (std.mem.eql(u8, content, expected)) return;
            }
        }
    }
    return error.ExpectedObjectContentMissing;
}

pub fn expectOverlayDiagnostic(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    source: []const u8,
    overlay_path: []const u8,
    overlay_source: []const u8,
    expected_origin: []const u8,
    expected_message: []const u8,
) !void {
    const asset_base_dir = std.fs.path.dirname(path) orelse ".";
    var overlay = module_loader.SourceOverlay.init(allocator);
    defer overlay.deinit();
    try overlay.put(overlay_path, overlay_source);

    var source_buf = try allocator.dupe(u8, source);
    var program = try syntax.parseWithSourceName(allocator, source_buf, path);
    var index = try typecheck.loadProgramIndexWithOverlay(allocator, io, asset_base_dir, program, &overlay);
    defer index.deinit();

    var ir = try typecheck.buildIrWithOptions(allocator, path, asset_base_dir, &source_buf, &program, &index, .{
        .allow_diagnostics = true,
    });
    defer ir.deinit();

    typecheck.typecheckProgram(allocator, &ir) catch {};

    for (ir.diagnostics.items) |diagnostic| {
        const origin = diagnostic.origin orelse continue;
        if (std.mem.indexOf(u8, origin, expected_origin) == null) continue;
        const message = try utils.err.formatIrDiagnostic(allocator, diagnostic);
        defer allocator.free(message);
        if (std.mem.indexOf(u8, message, expected_message) != null) return;
    }
    return error.ExpectedDiagnosticMissing;
}
