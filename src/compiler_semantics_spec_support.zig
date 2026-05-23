const std = @import("std");
const syntax = @import("syntax.zig");
const lowering = @import("lowering.zig");
const typecheck = @import("analysis/typecheck.zig");
const utils = @import("utils");

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
