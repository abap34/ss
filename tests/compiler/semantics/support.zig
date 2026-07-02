const std = @import("std");
const compiler = @import("compiler");
const utils = @import("utils");

const syntax = compiler.syntax;
const lowering = compiler.lowering;
const analysis = compiler.analysis;
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

pub const ObjectStateExpectation = struct {
    role: ?[]const u8 = null,
    content: ?[]const u8 = null,
    attached: ?bool = null,
    discarded: ?bool = null,
    count: usize = 1,
};

pub const OverlaySource = struct {
    path: []const u8,
    source: []const u8,
};

pub const VariableObjectClassExpectation = struct {
    name: []const u8,
    scope_kind: []const u8,
    scope_name: ?[]const u8 = null,
    object_class: ?[]const u8,
};

pub fn buildSource(io: std.Io, allocator: std.mem.Allocator, path: []const u8, source: []const u8) !void {
    const asset_base_dir = std.fs.path.dirname(path) orelse ".";
    var source_buf = try allocator.dupe(u8, source);
    var program = try syntax.parseWithSourceName(allocator, source_buf, path);
    var index = try analysis.loadProgramIndex(allocator, io, asset_base_dir, program);
    defer index.deinit();

    var ir = try analysis.buildIrWithOptions(allocator, path, asset_base_dir, &source_buf, &program, &index, .{
        .allow_diagnostics = true,
    });
    defer ir.deinit();

    try analysis.analyzeProgram(allocator, &ir);
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
    const overlays = [_]OverlaySource{
        .{ .path = overlay_path, .source = overlay_source },
    };
    try buildSourceWithOverlays(io, allocator, path, source, &overlays);
}

pub fn buildSourceWithOverlays(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    source: []const u8,
    overlays: []const OverlaySource,
) !void {
    const asset_base_dir = std.fs.path.dirname(path) orelse ".";
    var overlay = module_loader.SourceOverlay.init(allocator);
    defer overlay.deinit();
    for (overlays) |item| try overlay.put(item.path, item.source);

    var source_buf = try allocator.dupe(u8, source);
    var program = try syntax.parseWithSourceName(allocator, source_buf, path);
    var index = try analysis.loadProgramIndexWithOverlay(allocator, io, asset_base_dir, program, &overlay);
    defer index.deinit();

    var ir = try analysis.buildIrWithOptions(allocator, path, asset_base_dir, &source_buf, &program, &index, .{
        .allow_diagnostics = true,
    });
    defer ir.deinit();

    try analysis.analyzeProgram(allocator, &ir);
    if (utils.err.hasIrErrors(&ir)) return error.DiagnosticsFailed;
    try lowering.lowerToIr(&ir);
    if (utils.err.hasIrErrors(&ir)) return error.DiagnosticsFailed;
}

pub fn expectObjectContent(io: std.Io, allocator: std.mem.Allocator, path: []const u8, source: []const u8, expected: []const u8) !void {
    var ir = try buildLoweredIr(io, allocator, path, source);
    defer ir.deinit();

    for (ir.nodes.items) |node| {
        if (node.kind == .object) {
            if (std.mem.eql(u8, core.nodeDisplayContent(&node), expected)) return;
        }
    }
    return error.ExpectedObjectContentMissing;
}

pub fn expectObjectContentWithOverlays(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    source: []const u8,
    overlays: []const OverlaySource,
    expected: []const u8,
) !void {
    var ir = try buildLoweredIrWithOverlays(io, allocator, path, source, overlays);
    defer ir.deinit();

    for (ir.nodes.items) |node| {
        if (node.kind == .object) {
            if (std.mem.eql(u8, core.nodeDisplayContent(&node), expected)) return;
        }
    }
    return error.ExpectedObjectContentMissing;
}

pub fn expectObjectProperty(io: std.Io, allocator: std.mem.Allocator, path: []const u8, source: []const u8, key: []const u8, expected: []const u8) !void {
    var ir = try buildLoweredIr(io, allocator, path, source);
    defer ir.deinit();

    for (ir.nodes.items) |node| {
        if (node.kind != .object) continue;
        for (node.properties.items) |property| {
            if (std.mem.eql(u8, property.key, key) and std.mem.eql(u8, property.value, expected)) return;
        }
    }
    return error.ExpectedObjectPropertyMissing;
}

pub fn expectObjectPropertyMissing(io: std.Io, allocator: std.mem.Allocator, path: []const u8, source: []const u8, key: []const u8) !void {
    var ir = try buildLoweredIr(io, allocator, path, source);
    defer ir.deinit();

    for (ir.nodes.items) |node| {
        if (node.kind != .object) continue;
        for (node.properties.items) |property| {
            if (std.mem.eql(u8, property.key, key)) return error.ExpectedObjectPropertyAbsent;
        }
    }
}

pub fn expectObjectPropertyWithOverlays(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    source: []const u8,
    overlays: []const OverlaySource,
    key: []const u8,
    expected: []const u8,
) !void {
    var ir = try buildLoweredIrWithOverlays(io, allocator, path, source, overlays);
    defer ir.deinit();

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

pub fn expectResolvedCodePaintIsColorful(io: std.Io, allocator: std.mem.Allocator, path: []const u8, source: []const u8) !void {
    var ir = try buildLoweredIr(io, allocator, path, source);
    defer ir.deinit();

    var declaration_index = try declarations.build(allocator, &ir);
    defer declaration_index.deinit();
    const sema = semantic_env.SemanticEnv.init(&ir, &declaration_index, &ir.functions);

    for (ir.nodes.items) |node| {
        if (node.kind != .object) continue;
        const role = node.role orelse continue;
        if (!std.mem.eql(u8, role, "code")) continue;
        const render = core.render_policy.resolveWithEnv(&ir, &node, &sema);
        const code = render.code orelse continue;
        try expectColorDiffers(code.keyword, code.plain);
        try expectColorDiffers(code.function, code.plain);
        try expectColorDiffers(code.type, code.plain);
        try expectColorDiffers(code.constant, code.plain);
        try expectColorDiffers(code.number, code.plain);
        try expectColorDiffers(code.operator, code.plain);
        try expectColorDiffers(code.comment, code.plain);
        try expectColorDiffers(code.string, code.plain);
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

pub fn expectVariableObjectClasses(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    source: []const u8,
    expected: []const VariableObjectClassExpectation,
) !void {
    var ir = try buildLoweredIr(io, allocator, path, source);
    defer ir.deinit();

    const text = try compiler.dump.toOwnedString(allocator, &ir);
    defer allocator.free(text);
    var parsed = try utils.json.parseValue(allocator, text, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return error.ExpectedDumpTextMissing;
    const root = &parsed.value.object;
    const variables = utils.json.arrayFieldObject(root, "variables") orelse return error.ExpectedDumpTextMissing;

    for (expected) |item| {
        if (!dumpVariableObjectClassMatches(variables, item)) return error.ExpectedDumpTextMissing;
    }
}

fn dumpVariableObjectClassMatches(variables: *const utils.json.ValueArray, expected: VariableObjectClassExpectation) bool {
    for (variables.items) |value| {
        if (value != .object) continue;
        const object = &value.object;
        if (!std.mem.eql(u8, utils.json.stringField(object, "name") orelse "", expected.name)) continue;
        if (!std.mem.eql(u8, utils.json.stringField(object, "scopeKind") orelse "", expected.scope_kind)) continue;
        if (!optionalStringEql(utils.json.stringField(object, "scopeName"), expected.scope_name)) continue;
        if (!optionalStringEql(utils.json.stringField(object, "objectClass"), expected.object_class)) continue;
        return true;
    }
    return false;
}

fn optionalStringEql(left: ?[]const u8, right: ?[]const u8) bool {
    if (left == null and right == null) return true;
    if (left == null or right == null) return false;
    return std.mem.eql(u8, left.?, right.?);
}

fn expectColorDiffers(left: core.render_policy.Color, right: core.render_policy.Color) !void {
    try std.testing.expect(!colorsEqual(left, right));
}

fn colorsEqual(left: core.render_policy.Color, right: core.render_policy.Color) bool {
    const epsilon = 0.0001;
    return @abs(left.r - right.r) <= epsilon and
        @abs(left.g - right.g) <= epsilon and
        @abs(left.b - right.b) <= epsilon;
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
    var index = try analysis.loadProgramIndexWithOverlay(allocator, io, asset_base_dir, program, &overlay);
    defer index.deinit();

    var ir = try analysis.buildIrWithOptions(allocator, path, asset_base_dir, &source_buf, &program, &index, .{
        .allow_diagnostics = true,
    });
    defer ir.deinit();

    analysis.analyzeProgram(allocator, &ir) catch {};

    for (ir.diagnostics.items) |diagnostic| {
        const origin = diagnostic.origin orelse continue;
        if (std.mem.indexOf(u8, origin, expected_origin) == null) continue;
        const message = try utils.err.formatIrDiagnostic(allocator, diagnostic);
        defer allocator.free(message);
        if (std.mem.indexOf(u8, message, expected_message) != null) return;
    }
    return error.ExpectedDiagnosticMissing;
}

pub fn expectDiagnosticWithOverlays(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    source: []const u8,
    overlays: []const OverlaySource,
    expected_origin: []const u8,
    expected_message: []const u8,
) !void {
    const asset_base_dir = std.fs.path.dirname(path) orelse ".";
    var overlay = module_loader.SourceOverlay.init(allocator);
    defer overlay.deinit();
    for (overlays) |item| {
        try overlay.put(item.path, item.source);
    }

    var source_buf = try allocator.dupe(u8, source);
    var program = try syntax.parseWithSourceName(allocator, source_buf, path);
    var index = try analysis.loadProgramIndexWithOverlay(allocator, io, asset_base_dir, program, &overlay);
    defer index.deinit();

    var ir = try analysis.buildIrWithOptions(allocator, path, asset_base_dir, &source_buf, &program, &index, .{
        .allow_diagnostics = true,
    });
    defer ir.deinit();

    analysis.analyzeProgram(allocator, &ir) catch {};

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
    var index = try analysis.loadProgramIndex(allocator, io, asset_base_dir, program);
    defer index.deinit();

    var ir = try analysis.buildIrWithOptions(allocator, path, asset_base_dir, &source_buf, &program, &index, .{
        .allow_diagnostics = true,
    });
    errdefer ir.deinit();

    try analysis.analyzeProgram(allocator, &ir);
    if (utils.err.hasIrErrors(&ir)) return error.DiagnosticsFailed;
    try lowering.lowerToIr(&ir);
    if (utils.err.hasIrErrors(&ir)) return error.DiagnosticsFailed;
    return ir;
}

fn buildLoweredIrWithOverlays(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    source: []const u8,
    overlays: []const OverlaySource,
) !core.Ir {
    const asset_base_dir = std.fs.path.dirname(path) orelse ".";
    var overlay = module_loader.SourceOverlay.init(allocator);
    defer overlay.deinit();
    for (overlays) |item| {
        try overlay.put(item.path, item.source);
    }

    var source_buf = try allocator.dupe(u8, source);
    var program = try syntax.parseWithSourceName(allocator, source_buf, path);
    var index = try analysis.loadProgramIndexWithOverlay(allocator, io, asset_base_dir, program, &overlay);
    defer index.deinit();

    var ir = try analysis.buildIrWithOptions(allocator, path, asset_base_dir, &source_buf, &program, &index, .{
        .allow_diagnostics = true,
    });
    errdefer ir.deinit();

    try analysis.analyzeProgram(allocator, &ir);
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
    var index = try analysis.loadProgramIndex(allocator, io, asset_base_dir, program);
    defer index.deinit();

    var ir = try analysis.buildIrWithOptions(allocator, path, asset_base_dir, &source_buf, &program, &index, .{
        .allow_diagnostics = true,
    });
    defer ir.deinit();

    analysis.analyzeProgram(allocator, &ir) catch {};

    for (ir.diagnostics.items) |diagnostic| {
        const origin = diagnostic.origin orelse continue;
        if (std.mem.indexOf(u8, origin, expected_origin) == null) continue;
        const message = try utils.err.formatIrDiagnostic(allocator, diagnostic);
        defer allocator.free(message);
        if (std.mem.indexOf(u8, message, expected_message) != null) return;
    }
    return error.ExpectedDiagnosticMissing;
}

pub fn expectLoweringErrorDiagnostic(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    source: []const u8,
    expected_message: []const u8,
) !void {
    const asset_base_dir = std.fs.path.dirname(path) orelse ".";
    var source_buf = try allocator.dupe(u8, source);
    var program = try syntax.parseWithSourceName(allocator, source_buf, path);
    var index = try analysis.loadProgramIndex(allocator, io, asset_base_dir, program);
    defer index.deinit();

    var ir = try analysis.buildIrWithOptions(allocator, path, asset_base_dir, &source_buf, &program, &index, .{
        .allow_diagnostics = true,
    });
    defer ir.deinit();

    analysis.analyzeProgram(allocator, &ir) catch {};
    if (!utils.err.hasIrErrors(&ir)) {
        lowering.lowerToIr(&ir) catch {};
    }

    for (ir.diagnostics.items) |diagnostic| {
        const message = try utils.err.formatIrDiagnostic(allocator, diagnostic);
        defer allocator.free(message);
        if (std.mem.indexOf(u8, message, expected_message) != null) return;
    }
    return error.ExpectedDiagnosticMissing;
}

pub fn expectLoweredDiagnostic(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    source: []const u8,
    expected_message: []const u8,
) !void {
    var ir = try buildLoweredIr(io, allocator, path, source);
    defer ir.deinit();

    for (ir.diagnostics.items) |diagnostic| {
        const message = try utils.err.formatIrDiagnostic(allocator, diagnostic);
        defer allocator.free(message);
        if (std.mem.indexOf(u8, message, expected_message) != null) return;
    }
    return error.ExpectedDiagnosticMissing;
}

pub fn expectLoweredDiagnosticWithOrigin(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    source: []const u8,
    expected_origin: []const u8,
    expected_message: []const u8,
) !void {
    var ir = try buildLoweredIr(io, allocator, path, source);
    defer ir.deinit();

    for (ir.diagnostics.items) |diagnostic| {
        const origin = diagnostic.origin orelse continue;
        if (std.mem.indexOf(u8, origin, expected_origin) == null) continue;
        const message = try utils.err.formatIrDiagnostic(allocator, diagnostic);
        defer allocator.free(message);
        if (std.mem.indexOf(u8, message, expected_message) != null) return;
    }
    return error.ExpectedDiagnosticMissing;
}

pub fn expectNoLoweredDiagnostic(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    source: []const u8,
    unexpected_message: []const u8,
) !void {
    var ir = try buildLoweredIr(io, allocator, path, source);
    defer ir.deinit();

    for (ir.diagnostics.items) |diagnostic| {
        const message = try utils.err.formatIrDiagnostic(allocator, diagnostic);
        defer allocator.free(message);
        if (std.mem.indexOf(u8, message, unexpected_message) != null) {
            return error.UnexpectedDiagnosticPresent;
        }
    }
}

pub fn expectLoweredDiagnosticCount(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    source: []const u8,
    expected_message: []const u8,
    expected_count: usize,
) !void {
    var ir = try buildLoweredIr(io, allocator, path, source);
    defer ir.deinit();

    var count: usize = 0;
    for (ir.diagnostics.items) |diagnostic| {
        const message = try utils.err.formatIrDiagnostic(allocator, diagnostic);
        defer allocator.free(message);
        if (std.mem.indexOf(u8, message, expected_message) != null) count += 1;
    }
    try std.testing.expectEqual(expected_count, count);
}

pub fn expectObjectState(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    source: []const u8,
    expected: ObjectStateExpectation,
) !void {
    var ir = try buildLoweredIr(io, allocator, path, source);
    defer ir.deinit();

    var count: usize = 0;
    for (ir.nodes.items) |node| {
        if (node.kind != .object) continue;
        if (expected.role) |role| {
            const node_role = node.role orelse continue;
            if (!std.mem.eql(u8, node_role, role)) continue;
        }
        if (expected.content) |content| {
            const node_content = node.content orelse continue;
            if (!std.mem.eql(u8, node_content, content)) continue;
        }
        if (expected.attached) |attached| {
            if (node.attached != attached) continue;
        }
        if (expected.discarded) |discarded| {
            if (node.discarded != discarded) continue;
        }
        count += 1;
    }
    try std.testing.expectEqual(expected.count, count);
}
