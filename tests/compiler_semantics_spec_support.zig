const std = @import("std");
const compiler = @import("compiler");
const utils = @import("utils");

const syntax = compiler.syntax;
const lowering = compiler.lowering;
const typecheck = compiler.typecheck;
const module_loader = compiler.module_loader;
const core = compiler.core;
const declarations = compiler.declarations;
const semantic_env = compiler.semantic_env;

pub const BodyTextDefaults = struct {
    link_underline_width: f32,
    link_underline_offset: f32,
    inline_math_height_factor: f32,
    inline_math_spacing: f32,
    markdown_table_line_width: f32,
    cjk_bold_dx: f32,
};

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

pub fn buildSourceWithOverlay(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    source: []const u8,
    overlay_path: []const u8,
    overlay_source: []const u8,
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

pub fn expectObjectProperty(io: std.Io, allocator: std.mem.Allocator, path: []const u8, source: []const u8, key: []const u8, expected: []const u8) !void {
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
        if (node.kind != .object) continue;
        for (node.properties.items) |property| {
            if (std.mem.eql(u8, property.key, key) and std.mem.eql(u8, property.value, expected)) return;
        }
    }
    return error.ExpectedObjectPropertyMissing;
}

pub fn expectClassDefaultProperty(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    source: []const u8,
    role: []const u8,
    key: []const u8,
    expected: ?[]const u8,
) !void {
    var ir = try buildLoweredIr(io, allocator, path, source);
    defer ir.deinit();

    var declaration_index = try declarations.build(allocator, &ir);
    defer declaration_index.deinit();
    const sema = semantic_env.SemanticEnv.init(&ir, &declaration_index, &ir.functions);

    for (ir.nodes.items) |node| {
        if (node.kind != .object) continue;
        const node_role = node.role orelse continue;
        if (!std.mem.eql(u8, node_role, role)) continue;
        const actual = core.class_fields.propertyWithEnv(&node, key, &sema);
        if (expected) |value| {
            if (actual) |found| {
                if (std.mem.eql(u8, found, value)) return;
            }
            return error.ExpectedObjectPropertyMissing;
        }
        if (actual == null) return;
        return error.ExpectedObjectPropertyMissing;
    }
    return error.ExpectedObjectPropertyMissing;
}

pub fn expectBodyTextDefaults(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    source: []const u8,
    expected: BodyTextDefaults,
) !void {
    var ir = try buildLoweredIr(io, allocator, path, source);
    defer ir.deinit();

    var declaration_index = try declarations.build(allocator, &ir);
    defer declaration_index.deinit();
    const sema = semantic_env.SemanticEnv.init(&ir, &declaration_index, &ir.functions);

    for (ir.nodes.items) |node| {
        if (node.kind != .object) continue;
        const role = node.role orelse continue;
        if (!std.mem.eql(u8, role, "body")) continue;
        const render = core.render_policy.resolveWithEnv(&ir, &node, &sema);
        const text = render.text orelse continue;
        try std.testing.expectApproxEqAbs(expected.link_underline_width, text.link_underline_width, 0.0001);
        try std.testing.expectApproxEqAbs(expected.link_underline_offset, text.link_underline_offset, 0.0001);
        try std.testing.expectApproxEqAbs(expected.inline_math_height_factor, text.inline_math_height_factor, 0.0001);
        try std.testing.expectApproxEqAbs(expected.inline_math_spacing, text.inline_math_spacing, 0.0001);
        try std.testing.expectApproxEqAbs(expected.markdown_table_line_width, text.markdown_table_line_width, 0.0001);
        try std.testing.expectApproxEqAbs(expected.cjk_bold_dx, text.cjk_bold_dx, 0.0001);
        return;
    }
    return error.ExpectedObjectContentMissing;
}

pub fn expectDumpContains(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    source: []const u8,
    expected: []const []const u8,
) !void {
    var ir = try buildLoweredIr(io, allocator, path, source);
    defer ir.deinit();

    const text = try compiler.dump.toOwnedString(allocator, &ir);
    defer allocator.free(text);
    for (expected) |needle| {
        if (std.mem.indexOf(u8, text, needle) == null) return error.ExpectedDumpTextMissing;
    }
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

fn buildLoweredIr(io: std.Io, allocator: std.mem.Allocator, path: []const u8, source: []const u8) !core.Ir {
    const asset_base_dir = std.fs.path.dirname(path) orelse ".";
    var source_buf = try allocator.dupe(u8, source);
    var program = try syntax.parseWithSourceName(allocator, source_buf, path);
    var index = try typecheck.loadProgramIndex(allocator, io, asset_base_dir, program);
    defer index.deinit();

    var ir = try typecheck.buildIrWithOptions(allocator, path, asset_base_dir, &source_buf, &program, &index, .{
        .allow_diagnostics = true,
    });
    errdefer ir.deinit();

    try typecheck.typecheckProgram(allocator, &ir);
    if (utils.err.hasIrErrors(&ir)) return error.DiagnosticsFailed;
    try lowering.lowerToIr(&ir);
    if (utils.err.hasIrErrors(&ir)) return error.DiagnosticsFailed;
    return ir;
}

pub fn expectDiagnostic(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    source: []const u8,
    expected_origin: []const u8,
    expected_message: []const u8,
) !void {
    const asset_base_dir = std.fs.path.dirname(path) orelse ".";
    var source_buf = try allocator.dupe(u8, source);
    var program = try syntax.parseWithSourceName(allocator, source_buf, path);
    var index = try typecheck.loadProgramIndex(allocator, io, asset_base_dir, program);
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
