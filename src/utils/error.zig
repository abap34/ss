const std = @import("std");
const json = @import("json.zig");
const source = @import("source.zig");

pub const Severity = enum {
    note,
    warning,
    @"error",
};

pub const ColorMode = enum {
    auto,
    always,
    never,
};

var color_mode: ColorMode = .auto;

pub fn setColorMode(mode: ColorMode) void {
    color_mode = mode;
}

pub const LocatedOrigin = struct {
    path: ?[]const u8,
    span: source.ByteSpan,
};

pub const SourceReport = struct {
    path: []const u8 = "",
    source: []const u8,
    severity: Severity,
    message: []const u8,
    span: ?source.ByteSpan = null,
    context_lines: usize = 2,
};

pub fn parseByteOrigin(origin: []const u8) ?source.ByteSpan {
    if (!std.mem.startsWith(u8, origin, "bytes:")) return null;
    const payload = origin["bytes:".len..];
    const dash = std.mem.indexOfScalar(u8, payload, '-') orelse return null;
    const start = std.fmt.parseInt(usize, payload[0..dash], 10) catch return null;
    const end = std.fmt.parseInt(usize, payload[dash + 1 ..], 10) catch return null;
    return .{ .start = start, .end = end };
}

pub fn parseLocatedOrigin(origin: []const u8) ?LocatedOrigin {
    if (parseByteOrigin(origin)) |span| {
        return .{ .path = null, .span = span };
    }
    if (!std.mem.startsWith(u8, origin, "path:")) return null;
    const marker = std.mem.lastIndexOf(u8, origin, ":bytes:") orelse return null;
    const bytes_text = origin[marker + 1 ..];
    const span = parseByteOrigin(bytes_text) orelse return null;
    return .{
        .path = origin["path:".len..marker],
        .span = span,
    };
}

pub fn spanFromOrigin(origin: ?[]const u8) ?source.ByteSpan {
    const text = origin orelse return null;
    const located = parseLocatedOrigin(text) orelse return null;
    return located.span;
}

pub fn print(report: SourceReport) void {
    printSeverityPrefix(report.severity);
    const span = report.span;
    if (span) |s| {
        const loc = source.locationAt(report.source, s.start);
        printColor(report.severity);
        if (report.path.len != 0) {
            std.debug.print("{s}:{d}:{d}: {s}", .{ report.path, loc.line, loc.column, report.message });
        } else {
            std.debug.print("{s} at {d}:{d}", .{ report.message, loc.line, loc.column });
        }
        printReset();
        std.debug.print("\n", .{});
        printExcerpt(report.source, s, report.severity, report.message, report.context_lines);
    } else if (report.path.len != 0) {
        printColor(report.severity);
        std.debug.print("{s}: {s}", .{ report.path, report.message });
        printReset();
        std.debug.print("\n", .{});
    } else {
        printColor(report.severity);
        std.debug.print("{s}", .{report.message});
        printReset();
        std.debug.print("\n", .{});
    }
}

pub fn printNote(message: []const u8) void {
    std.debug.print("  note: {s}\n", .{message});
}

pub fn printLabeledOrigin(text: []const u8, label: []const u8, origin: ?[]const u8) void {
    const span = spanFromOrigin(origin) orelse return;
    const loc = source.locationAt(text, span.start);
    printDim();
    std.debug.print("  {s} from {d}:{d}", .{ label, loc.line, loc.column });
    printReset();
    std.debug.print("\n", .{});
    printExcerpt(text, span, .note, label, 0);
}

fn sourceForLocatedOrigin(
    default_path: []const u8,
    default_source: []const u8,
    ir: anytype,
    located: LocatedOrigin,
) struct { path: []const u8, source: []const u8 } {
    if (located.path) |origin_path| {
        if (ir.moduleByPathOrSpec(origin_path)) |module| {
            return .{
                .path = module.path orelse module.spec,
                .source = module.source,
            };
        }
        return .{ .path = origin_path, .source = default_source };
    }
    return .{ .path = default_path, .source = default_source };
}

fn printLocatedOrigin(
    default_path: []const u8,
    default_source: []const u8,
    ir: anytype,
    severity: Severity,
    message: []const u8,
    origin: []const u8,
) void {
    const located = parseLocatedOrigin(origin) orelse return;
    const resolved = sourceForLocatedOrigin(default_path, default_source, ir, located);
    print(.{
        .path = resolved.path,
        .source = resolved.source,
        .severity = severity,
        .message = message,
        .span = located.span,
    });
}

fn printLabeledLocatedOrigin(
    default_path: []const u8,
    default_source: []const u8,
    ir: anytype,
    label: []const u8,
    origin: ?[]const u8,
) void {
    const origin_text = origin orelse return;
    const located = parseLocatedOrigin(origin_text) orelse return;
    const resolved = sourceForLocatedOrigin(default_path, default_source, ir, located);
    const loc = source.locationAt(resolved.source, located.span.start);
    printDim();
    std.debug.print("  {s} from {s}:{d}:{d}", .{ label, resolved.path, loc.line, loc.column });
    printReset();
    std.debug.print("\n", .{});
    printExcerpt(resolved.source, located.span, .note, label, 0);
}

pub fn printParseError(path: []const u8, text: []const u8, err: anyerror, diagnostic: anytype) void {
    const parsed_diagnostic = diagnostic orelse {
        var message_buf: [128]u8 = undefined;
        print(.{
            .path = path,
            .source = text,
            .severity = .@"error",
            .message = formatParseFailureWithoutDiagnostic(&message_buf, err),
            .span = null,
        });
        return;
    };
    var message_buf: [256]u8 = undefined;
    const message = formatParseDiagnostic(&message_buf, parsed_diagnostic);
    print(.{
        .path = path,
        .source = text,
        .severity = .@"error",
        .message = message,
        .span = .{ .start = parsed_diagnostic.span.start, .end = parsed_diagnostic.span.end },
    });
}

pub fn printIrDiagnostics(path: []const u8, text: []const u8, ir: anytype) void {
    for (ir.diagnostics.items) |diagnostic| {
        var resolved = resolveIrDiagnostic(ir.allocator, path, text, ir, diagnostic) catch {
            var message_buf: [128]u8 = undefined;
            print(.{
                .path = path,
                .source = text,
                .severity = .@"error",
                .message = fallbackIrDiagnosticMessage(&message_buf, diagnostic),
                .span = null,
            });
            continue;
        };
        defer resolved.deinit(ir.allocator);
        print(.{
            .path = resolved.path,
            .source = resolved.source,
            .severity = resolved.report_severity,
            .message = resolved.message,
            .span = resolved.span,
        });
        printIrDiagnosticDetails(ir, diagnostic);
    }
}

fn printIrDiagnosticDetails(ir: anytype, diagnostic: anytype) void {
    switch (diagnostic.data) {
        .page_overflow => |data| printPageOverflowBox(ir, diagnostic, data),
        .content_overflow => |data| printContentOverflowBox(ir, diagnostic, data),
        else => {},
    }
}

pub fn irRenderDiagnosticsJson(allocator: std.mem.Allocator, default_path: []const u8, default_source: []const u8, ir: anytype) ![]u8 {
    return irDiagnosticsJson(allocator, default_path, default_source, ir, .{ .phase = "render" });
}

pub const DiagnosticsJsonOptions = struct {
    phase: ?[]const u8 = null,
};

pub fn irDiagnosticsJson(
    allocator: std.mem.Allocator,
    default_path: []const u8,
    default_source: []const u8,
    ir: anytype,
    options: DiagnosticsJsonOptions,
) ![]u8 {
    var buffer = std.ArrayList(u8).empty;
    errdefer buffer.deinit(allocator);

    var root = try json.Object.beginBuffer(allocator, &buffer);
    try root.intField("schema", 1);
    try root.stringField("kind", "ss-diagnostics");
    var diagnostics = try root.arrayField("diagnostics");
    for (ir.diagnostics.items) |diagnostic| {
        if (options.phase) |phase| {
            if (!std.mem.eql(u8, @tagName(diagnostic.phase), phase)) continue;
        }
        var resolved = try resolveIrDiagnostic(allocator, default_path, default_source, ir, diagnostic);
        defer resolved.deinit(allocator);
        try writeIrDiagnosticJson(&diagnostics, resolved, diagnostic);
    }
    try diagnostics.end();
    try root.end();
    try json.appendNewline(&buffer, allocator);
    return buffer.toOwnedSlice(allocator);
}

const ResolvedIrDiagnostic = struct {
    phase: []const u8,
    severity: []const u8,
    report_severity: Severity,
    code: []const u8,
    message: []const u8,
    path: []const u8,
    source: []const u8,
    span: ?source.ByteSpan,

    fn deinit(self: *ResolvedIrDiagnostic, allocator: std.mem.Allocator) void {
        allocator.free(self.message);
    }
};

fn resolveIrDiagnostic(
    allocator: std.mem.Allocator,
    default_path: []const u8,
    default_source: []const u8,
    ir: anytype,
    diagnostic: anytype,
) !ResolvedIrDiagnostic {
    const message = try formatIrDiagnostic(allocator, diagnostic);
    errdefer allocator.free(message);
    const location = resolveIrDiagnosticLocation(default_path, default_source, ir, diagnostic);
    return .{
        .phase = @tagName(diagnostic.phase),
        .severity = @tagName(diagnostic.severity),
        .report_severity = switch (diagnostic.severity) {
            .warning => .warning,
            .@"error" => .@"error",
        },
        .code = irDiagnosticCode(diagnostic),
        .message = message,
        .path = location.path,
        .source = location.source,
        .span = location.span,
    };
}

fn writeIrDiagnosticJson(
    diagnostics: *json.Array,
    resolved: ResolvedIrDiagnostic,
    diagnostic: anytype,
) !void {
    var item = try diagnostics.objectItem();
    try item.stringField("phase", resolved.phase);
    try item.stringField("severity", resolved.severity);
    try item.stringField("code", resolved.code);
    try item.stringField("message", resolved.message);
    try item.stringField("path", resolved.path);
    try item.optionalStringField("origin", diagnostic.origin);
    try item.optionalIntField("page_id", diagnostic.page_id);
    try item.optionalIntField("node_id", diagnostic.node_id);
    if (resolved.span) |span| {
        var range = try item.objectField("range");
        try writeJsonLocation(&range, "start", resolved.source, span.start);
        try writeJsonLocation(&range, "end", resolved.source, @max(span.end, span.start));
        try range.end();
    } else {
        try item.nullField("range");
    }
    try item.end();
}

fn writeJsonLocation(object: *json.Object, key: []const u8, text: []const u8, byte_index: usize) !void {
    const location = source.locationAt(text, byte_index);
    var child = try object.objectField(key);
    try child.intField("line", if (location.line == 0) 0 else location.line - 1);
    try child.intField("character", if (location.column == 0) 0 else location.column - 1);
    try child.end();
}

fn resolveIrDiagnosticLocation(
    default_path: []const u8,
    default_source: []const u8,
    ir: anytype,
    diagnostic: anytype,
) struct { path: []const u8, source: []const u8, span: ?source.ByteSpan } {
    const located = if (diagnostic.origin) |origin|
        parseLocatedOrigin(origin)
    else if (diagnostic.node_id) |node_id| blk: {
        const node = ir.getNode(node_id) orelse break :blk null;
        break :blk if (node.origin) |origin| parseLocatedOrigin(origin) else null;
    } else null;
    if (located) |origin| {
        const resolved = sourceForLocatedOrigin(default_path, default_source, ir, origin);
        return .{ .path = resolved.path, .source = resolved.source, .span = origin.span };
    }
    return .{ .path = default_path, .source = default_source, .span = null };
}

fn irDiagnosticCode(diagnostic: anytype) []const u8 {
    return switch (diagnostic.data) {
        .user_report => |data| userReportDiagnosticCode(data.message),
        .asset_not_found => "AssetNotFound",
        .asset_invalid => "InvalidAsset",
        .render_failed => "RenderFailed",
        .type_mismatch => |data| @tagName(data.code),
        .recursive_function => "RecursiveFunction",
        .page_overflow => "PageOverflow",
        .content_overflow => "ContentOverflow",
    };
}

fn fallbackIrDiagnosticMessage(buf: []u8, diagnostic: anytype) []const u8 {
    return std.fmt.bufPrint(
        buf,
        "DiagnosticResolutionFailed: could not resolve {s} diagnostic",
        .{@tagName(diagnostic.phase)},
    ) catch "DiagnosticResolutionFailed: could not resolve diagnostic";
}

pub fn userReportDiagnosticCode(message: []const u8) []const u8 {
    const colon = std.mem.indexOfScalar(u8, message, ':') orelse return "UserReport";
    const code = message[0..colon];
    if (code.len == 0) return "UserReport";
    for (code) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '_') return "UserReport";
    }
    return code;
}

pub fn hasIrErrors(ir: anytype) bool {
    for (ir.diagnostics.items) |diagnostic| {
        if (diagnostic.severity == .@"error") return true;
    }
    return false;
}

pub fn printConstraintFailure(
    path: []const u8,
    text: []const u8,
    ir: anytype,
    err: anyerror,
) void {
    if (ir.constraint_failures.items.len == 0 and ir.last_constraint_failure == null) {
        var message_buf: [128]u8 = undefined;
        print(.{
            .path = path,
            .source = text,
            .severity = .@"error",
            .message = std.fmt.bufPrint(
                &message_buf,
                "LayoutFailed: {s}; no source constraint failure was recorded",
                .{@errorName(err)},
            ) catch "LayoutFailed: no source constraint failure was recorded",
            .span = null,
        });
        return;
    }

    const failures = ir.constraint_failures.items;
    const count = if (failures.len > 0) failures.len else 1;
    if (count > 1) {
        printColor(.@"error");
        std.debug.print("error: {d} layout constraint failures\n", .{count});
        printReset();
        printDim();
        std.debug.print("  = showing first {d}; use `ss debug layout conflicts` for the full report\n", .{@min(count, 3)});
        printReset();
    }

    if (failures.len > 0) {
        const limit = @min(failures.len, 3);
        for (failures[0..limit], 0..) |failure, index| {
            if (index != 0 or count > 1) std.debug.print("\n", .{});
            printConstraintFailureItem(path, text, ir, failure);
        }
        return;
    }

    printConstraintFailureItem(path, text, ir, ir.last_constraint_failure.?);
}

fn printConstraintFailureItem(path: []const u8, text: []const u8, ir: anytype, failure: anytype) void {
    const code = constraintFailureCode(failure);
    printColor(.@"error");
    std.debug.print("error: {s}: {s}\n", .{ code, constraintFailureReasonLabel(failure) });
    printReset();

    const located = printRustLocatedOrigin(path, text, ir, .@"error", constraintFailurePrimaryLabel(failure), failure.constraint.origin);
    if (!located and path.len != 0) {
        printDim();
        std.debug.print("  --> {s}\n", .{path});
        printReset();
    }

    printConstraintFailureBox(ir, failure);
}

fn printRustLocatedOrigin(
    default_path: []const u8,
    default_source: []const u8,
    ir: anytype,
    severity: Severity,
    label: []const u8,
    origin: ?[]const u8,
) bool {
    const origin_text = origin orelse return false;
    const located = parseLocatedOrigin(origin_text) orelse return false;
    const resolved = sourceForLocatedOrigin(default_path, default_source, ir, located);
    const loc = source.locationAt(resolved.source, located.span.start);
    printDim();
    std.debug.print("  --> {s}:{d}:{d}\n", .{ resolved.path, loc.line, loc.column });
    std.debug.print("   |\n", .{});
    printReset();
    printExcerpt(resolved.source, located.span, severity, label, 1);
    return true;
}

fn printConstraintFailureBox(ir: anytype, failure: anytype) void {
    if (failure.propagation) |propagation| {
        printConstraintPropagationBox(failure, propagation);
        return;
    }

    const target_text = constraintTargetLabel(ir.allocator, ir, failure.constraint) catch "";
    defer if (target_text.len > 0) ir.allocator.free(target_text);

    printDim();
    std.debug.print("╭─ propagation\n", .{});
    printReset();
    printBoxField("target", target_text);
    printOptionalBoxField("axis", if (failure.axis) |axis| @tagName(axis) else null);
    printOptionalFloatBoxField("actual", failure.actual);
    printOptionalFloatBoxField("expected", failure.expected);
    printBoxField("reason", @tagName(failure.reason));
    printDim();
    std.debug.print("╰─\n", .{});
    printReset();
}

fn printPageOverflowBox(ir: anytype, diagnostic: anytype, data: anytype) void {
    printDim();
    std.debug.print("╭─ page overflow\n", .{});
    printReset();

    printDiagnosticPageField(ir, diagnostic.page_id);
    printDiagnosticNodeField(ir, diagnostic.node_id);
    printDiagnosticFrameField(ir, diagnostic.node_id);
    const directions = formatPageOverflowDirections(ir.allocator, data, false) catch null;
    defer if (directions) |text| ir.allocator.free(text);
    if (directions) |text| printBoxField("outside page", text);

    printDim();
    std.debug.print("╰─\n", .{});
    printReset();
}

fn printContentOverflowBox(ir: anytype, diagnostic: anytype, data: anytype) void {
    printDim();
    std.debug.print("╭─ content overflow\n", .{});
    printReset();

    printDiagnosticPageField(ir, diagnostic.page_id);
    printDiagnosticNodeField(ir, diagnostic.node_id);
    printDiagnosticContentField(ir, diagnostic.node_id);
    printDiagnosticFrameField(ir, diagnostic.node_id);
    printFloatTripleField("height", data.required_height, data.frame_height, data.overflow_height);

    printDim();
    std.debug.print("╰─\n", .{});
    printReset();
}

fn printDiagnosticPageField(ir: anytype, page_id: anytype) void {
    const id = page_id orelse return;
    const page = ir.getNode(id) orelse return;
    var buffer: [128]u8 = undefined;
    const label = if (page.page_index) |index|
        std.fmt.bufPrint(&buffer, "#{d} page {d}", .{ id, index + 1 }) catch return
    else
        std.fmt.bufPrint(&buffer, "#{d}", .{id}) catch return;
    printBoxField("page", label);
}

fn printDiagnosticNodeField(ir: anytype, node_id: anytype) void {
    const id = node_id orelse return;
    const node = ir.getNode(id) orelse return;
    var buffer: [192]u8 = undefined;
    const role = node.role orelse "-";
    const payload = if (node.payload_kind) |payload_kind| @tagName(payload_kind) else "-";
    const label = std.fmt.bufPrint(&buffer, "#{d} {s} role={s} payload={s}", .{ id, node.name, role, payload }) catch return;
    printBoxField("object", label);
}

fn printDiagnosticContentField(ir: anytype, node_id: anytype) void {
    const id = node_id orelse return;
    const node = ir.getNode(id) orelse return;
    const content = node.content orelse return;
    const preview = diagnosticContentPreview(ir.allocator, content, 96) catch return;
    defer ir.allocator.free(preview);
    printBoxField("content", preview);
}

fn printDiagnosticFrameField(ir: anytype, node_id: anytype) void {
    const id = node_id orelse return;
    const node = ir.getNode(id) orelse return;
    var buffer: [160]u8 = undefined;
    const label = std.fmt.bufPrint(&buffer, "x={d:.1} y={d:.1} w={d:.1} h={d:.1}", .{ node.frame.x, node.frame.y, node.frame.width, node.frame.height }) catch return;
    printBoxField("object frame", label);
}

fn printFloatTripleField(name: []const u8, required: f32, actual: f32, overflow: f32) void {
    var buffer: [160]u8 = undefined;
    const label = std.fmt.bufPrint(&buffer, "required={d:.1} frame={d:.1} overflow={d:.1}", .{ required, actual, overflow }) catch return;
    printBoxField(name, label);
}

const PageOverflowDirection = struct {
    short: []const u8,
    sentence: []const u8,
    amount: f32,
};

const page_overflow_display_epsilon: f32 = 0.05;

fn formatPageOverflowDiagnostic(allocator: std.mem.Allocator, data: anytype) ![]u8 {
    const directions = try formatPageOverflowDirections(allocator, data, true);
    defer allocator.free(directions);
    return std.fmt.allocPrint(allocator, "PageOverflow: object extends {s}", .{directions});
}

fn formatPageOverflowDirections(allocator: std.mem.Allocator, data: anytype, sentence: bool) ![]u8 {
    var directions: [4]PageOverflowDirection = undefined;
    var len: usize = 0;
    appendPageOverflowDirection(&directions, &len, data.overflow_left, "left", "left of page");
    appendPageOverflowDirection(&directions, &len, data.overflow_right, "right", "right of page");
    appendPageOverflowDirection(&directions, &len, data.overflow_top, "above", "above page");
    appendPageOverflowDirection(&directions, &len, data.overflow_bottom, "below", "below page");
    if (len == 0) return allocator.dupe(u8, "outside page");

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    if (sentence and len > 1) try out.appendSlice(allocator, "outside page: ");
    for (directions[0..len], 0..) |direction, index| {
        if (index != 0) try out.appendSlice(allocator, ", ");
        const name = if (sentence and len == 1) direction.sentence else direction.short;
        const text = try std.fmt.allocPrint(allocator, "{s} by {d:.1}", .{ name, direction.amount });
        defer allocator.free(text);
        try out.appendSlice(allocator, text);
    }
    return out.toOwnedSlice(allocator);
}

fn appendPageOverflowDirection(
    directions: *[4]PageOverflowDirection,
    len: *usize,
    amount: f32,
    short: []const u8,
    sentence: []const u8,
) void {
    if (amount <= page_overflow_display_epsilon) return;
    directions[len.*] = .{
        .short = short,
        .sentence = sentence,
        .amount = amount,
    };
    len.* += 1;
}

fn diagnosticContentPreview(allocator: std.mem.Allocator, text: []const u8, max_chars: usize) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var iter = std.unicode.Utf8View.init(text) catch {
        return diagnosticBytePreview(allocator, text, max_chars);
    };
    var codepoints = iter.iterator();
    var count: usize = 0;
    while (codepoints.nextCodepointSlice()) |slice| {
        if (count >= max_chars) {
            try out.appendSlice(allocator, "...");
            break;
        }
        if (std.mem.eql(u8, slice, "\n")) {
            try out.appendSlice(allocator, "\\n");
        } else if (std.mem.eql(u8, slice, "\t")) {
            try out.appendSlice(allocator, "\\t");
        } else {
            try out.appendSlice(allocator, slice);
        }
        count += 1;
    }
    return out.toOwnedSlice(allocator);
}

fn diagnosticBytePreview(allocator: std.mem.Allocator, text: []const u8, max_bytes: usize) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var count: usize = 0;
    for (text) |byte| {
        if (count >= max_bytes) {
            try out.appendSlice(allocator, "...");
            break;
        }
        switch (byte) {
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            else => try out.append(allocator, byte),
        }
        count += 1;
    }
    return out.toOwnedSlice(allocator);
}

fn printConstraintPropagationBox(failure: anytype, propagation: anytype) void {
    printDim();
    std.debug.print("╭─ propagation\n", .{});
    printReset();
    printOptionalBoxField("target", propagation.target);
    printOptionalBoxField("axis", if (failure.axis) |axis| @tagName(axis) else null);
    for (propagation.paths) |path| {
        printBoxBlankLine();
        printBoxHeading(path.title);
        for (path.lines, 0..) |line, index| {
            const origin_source = if (index < path.line_sources.len) path.line_sources[index] else null;
            printBoxIndentedLineWithSource(line, origin_source);
        }
    }
    if (propagation.result.len > 0) {
        printBoxBlankLine();
        printBoxHeading("result");
        for (propagation.result) |line| printBoxIndentedLine(line);
    }
    printDim();
    std.debug.print("╰─\n", .{});
    printReset();
}

fn printBoxField(name: []const u8, value: []const u8) void {
    if (value.len == 0) return;
    printDim();
    std.debug.print("│ ", .{});
    printReset();
    std.debug.print("{s}", .{name});
    if (name.len < 16) {
        printSpaces(16 - name.len);
    } else {
        printSpaces(2);
    }
    std.debug.print("{s}\n", .{value});
}

fn printOptionalBoxField(name: []const u8, value: ?[]const u8) void {
    if (value) |text| printBoxField(name, text);
}

fn printOptionalFloatBoxField(name: []const u8, value: ?f32) void {
    const number = value orelse return;
    var buffer: [64]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "{d:.1}", .{number}) catch return;
    printBoxField(name, text);
}

fn printBoxBlankLine() void {
    printDim();
    std.debug.print("│\n", .{});
    printReset();
}

fn printBoxHeading(text: []const u8) void {
    printDim();
    std.debug.print("│ ", .{});
    printReset();
    std.debug.print("{s}\n", .{text});
}

fn printBoxIndentedLine(text: []const u8) void {
    printBoxIndentedLineWithSource(text, null);
}

fn printBoxIndentedLineWithSource(text: []const u8, origin_source: ?[]const u8) void {
    printDim();
    std.debug.print("│   ", .{});
    printReset();
    std.debug.print("{s}", .{text});
    if (origin_source) |origin| {
        if (origin.len > 0) {
            printDim();
            std.debug.print("  {s}", .{origin});
            printReset();
        }
    }
    std.debug.print("\n", .{});
}

fn constraintFailureCode(failure: anytype) []const u8 {
    return switch (failure.kind) {
        .conflict => "ConstraintConflict",
        .negative_frame_size => "NegativeFrameSize",
    };
}

fn constraintFailurePrimaryLabel(failure: anytype) []const u8 {
    return switch (failure.kind) {
        .conflict => "propagates a conflicting value",
        .negative_frame_size => "propagates a negative frame size",
    };
}

fn constraintFailureReasonLabel(failure: anytype) []const u8 {
    return switch (failure.reason) {
        .anchor_value_conflict => "constraint conflict",
        .overconstrained_frame => "overconstrained frame",
        .negative_frame_size => "negative frame size",
        .constraint_cycle => "constraint cycle has no solution",
        .group_size_conflict => "group size conflict",
    };
}

fn constraintTargetLabel(allocator: std.mem.Allocator, ir: anytype, constraint: anytype) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}.{s}", .{ nodeLabel(ir, constraint.target_node), @tagName(constraint.target_anchor) });
}

fn nodeLabel(ir: anytype, node_id: anytype) []const u8 {
    const node = ir.getNode(node_id) orelse return "unknown";
    return node.role orelse node.name;
}

pub fn isExpectedCliError(err: anyerror) bool {
    return switch (err) {
        error.UnknownFunction,
        error.UnknownQuery,
        error.UnknownIdentifier,
        error.UnknownType,
        error.ExpectedString,
        error.ExpectedIdentifier,
        error.InvalidImportSpec,
        error.ExpectedKeyword,
        error.ExpectedChar,
        error.ExpectedLineBreak,
        error.ExpectedEnd,
        error.ExpectedNumber,
        error.ExpectedTypeAnnotation,
        error.InvalidTypeAnnotation,
        error.AssignmentRequiresLet,
        error.BindRemoved,
        error.ZeroArgCallRequiresParens,
        error.ExpectedReturn,
        error.UnterminatedString,
        error.UnknownAnchor,
        error.ReturnOutsideFunction,
        error.NoCurrentPage,
        error.InvalidLibraryModule,
        error.UnknownProperty,
        error.FunctionDoesNotReturnValue,
        error.InvalidArity,
        error.InvalidValueTag,
        error.EmptySelection,
        error.InvalidSelectionItemType,
        error.UnknownImport,
        error.RecursiveFunction,
        error.ExpectedSelection,
        error.ExpectedConstraintSet,
        error.ExpectedStringArgument,
        error.ExpectedNumberArgument,
        error.ExpectedAnchor,
        error.ExpectedObject,
        error.UnknownRole,
        error.UnknownPayloadKind,
        error.PageCannotBeConstraintTarget,
        error.UnsupportedScheduledPrimitive,
        error.FunctionDidNotReturnValue,
        error.InvalidSelectionMutation,
        error.LayoutDependencyCycle,
        error.PostLayoutComputationUnsupported,
        error.ScheduledDependencyCycle,
        error.DuplicateContentDefinition,
        error.DuplicatePropertyDefinition,
        error.DuplicateReprDefinition,
        error.ConstraintConflict,
        error.NegativeFrameSize,
        error.DiagnosticsFailed,
        error.DoctorIssues,
        error.InitEntryMustBeRelative,
        error.InitTargetExists,
        error.InvalidUsage,
        => true,
        else => false,
    };
}

pub fn formatParseDiagnostic(buf: []u8, diagnostic: anytype) []const u8 {
    return switch (diagnostic.err) {
        error.UnterminatedString => "UnterminatedString: unterminated string",
        error.UnknownAnchor => "UnknownAnchor: unknown anchor name",
        error.AssignmentRequiresLet => "AssignmentRequiresLet: plain assignment statements are not supported; use 'let name = expr'",
        error.BindRemoved => "BindRemoved: 'bind' has been removed; use lexical 'let' bindings and ordinary expression statements",
        error.ZeroArgCallRequiresParens => "ZeroArgCallRequiresParens: a bare name is not a statement; use parentheses for a zero-argument call, or pass the value to a placing function such as 'text!(name)'",
        else => blk: {
            const expected = diagnostic.expected orelse @errorName(diagnostic.err);
            const found = diagnostic.found orelse "unknown token";
            break :blk std.fmt.bufPrint(buf, "{s}: expected {s}, found {s}", .{ parseDiagnosticCode(diagnostic.err), expected, found }) catch @errorName(diagnostic.err);
        },
    };
}

pub fn formatParseFailureWithoutDiagnostic(buf: []u8, err: anyerror) []const u8 {
    return std.fmt.bufPrint(
        buf,
        "ParseFailed: parser returned {s} without a source diagnostic",
        .{@errorName(err)},
    ) catch "ParseFailed: parser failed without a source diagnostic";
}

fn parseDiagnosticCode(err: anyerror) []const u8 {
    return switch (err) {
        error.ExpectedString => "ExpectedString",
        error.ExpectedIdentifier => "ExpectedIdentifier",
        error.InvalidImportSpec => "InvalidImportSpec",
        error.ExpectedKeyword => "ExpectedKeyword",
        error.ExpectedChar => "ExpectedPunctuation",
        error.ExpectedLineBreak => "ExpectedLineBreak",
        error.ExpectedEnd => "ExpectedEnd",
        error.ExpectedNumber => "ExpectedNumber",
        error.ExpectedTypeAnnotation => "ExpectedTypeAnnotation",
        error.AssignmentRequiresLet => "AssignmentRequiresLet",
        error.BindRemoved => "BindRemoved",
        error.ZeroArgCallRequiresParens => "ZeroArgCallRequiresParens",
        error.ExpectedReturn => "ExpectedReturn",
        error.InvalidTypeAnnotation => "InvalidTypeAnnotation",
        error.InvalidValueTag => "InvalidValueTag",
        else => @errorName(err),
    };
}

pub fn formatIrDiagnostic(allocator: std.mem.Allocator, diagnostic: anytype) ![]const u8 {
    return switch (diagnostic.data) {
        .user_report => |data| allocator.dupe(u8, data.message),
        .asset_not_found => |data| std.fmt.allocPrint(
            allocator,
            "AssetNotFound: {s} (resolved to {s})",
            .{ data.requested_path, data.resolved_path },
        ),
        .asset_invalid => |data| std.fmt.allocPrint(allocator, "InvalidAsset: {s}", .{data.reason}),
        .render_failed => |data| std.fmt.allocPrint(allocator, "RenderFailed: {s}", .{data.reason}),
        .type_mismatch => |data| std.fmt.allocPrint(
            allocator,
            "{s}: expected {s}, got {s}",
            .{ @tagName(data.code), @tagName(data.expected), @tagName(data.actual) },
        ),
        .recursive_function => |data| std.fmt.allocPrint(
            allocator,
            "RecursiveFunction: recursive function cycle involving {s}",
            .{data.function_name},
        ),
        .page_overflow => |data| formatPageOverflowDiagnostic(allocator, data),
        .content_overflow => |data| std.fmt.allocPrint(
            allocator,
            "ContentOverflow: content requires height={d:.1}, frame height={d:.1}, overflow={d:.1}",
            .{ data.required_height, data.frame_height, data.overflow_height },
        ),
    };
}

fn printExcerpt(text: []const u8, span: source.ByteSpan, severity: Severity, label: []const u8, context: usize) void {
    const target = source.lineAt(text, span.start);
    const first_line = if (target.number > context) target.number - context else 1;
    const last_line = @min(source.lineCount(text), target.number + context);
    const width = decimalWidth(last_line);

    var line = first_line;
    while (line <= last_line) : (line += 1) {
        const current = source.lineByNumber(text, line) orelse break;
        printDim();
        std.debug.print(" ", .{});
        printSpaces(width - decimalWidth(line));
        std.debug.print("{d} | ", .{line});
        printReset();
        printHighlightedSlice(current.text(text));
        std.debug.print("\n", .{});
        if (line == target.number) {
            printDim();
            std.debug.print(" ", .{});
            printSpaces(width);
            std.debug.print(" | ", .{});
            printReset();
            printSpaces(displayWidthBetween(text, current.span.start, span.start));
            printColor(severity);
            printRule(caretWidthOnLine(text, span, current));
            if (label.len != 0) {
                std.debug.print(" {s}", .{label});
            }
            printReset();
            std.debug.print("\n", .{});
        }
    }
}

fn caretWidthOnLine(text: []const u8, span: source.ByteSpan, line: source.Line) usize {
    const start = @max(span.start, line.span.start);
    const end = @min(@max(span.end, span.start + 1), line.span.end);
    if (end <= start) return 1;
    return @max(1, displayWidthSlice(text[start..end]));
}

fn decimalWidth(value: usize) usize {
    var width: usize = 1;
    var n = value;
    while (n >= 10) : (n /= 10) width += 1;
    return width;
}

fn printSpaces(count: usize) void {
    var i: usize = 0;
    while (i < count) : (i += 1) std.debug.print(" ", .{});
}

fn printRule(count: usize) void {
    var i: usize = 0;
    while (i < count) : (i += 1) std.debug.print("▔", .{});
}

fn printHighlightedSlice(slice: []const u8) void {
    var index: usize = 0;
    while (index < slice.len) {
        if (slice[index] == '\t') {
            printSpaces(4);
            index += 1;
            continue;
        }

        if (source.lineCommentMarkerLength(slice, index) != null) {
            printAnsi("90");
            printDisplayRaw(slice[index..]);
            printReset();
            return;
        }

        if (slice[index] == '"') {
            const end = source.skipDoubleQuotedString(slice, index, slice.len);
            printAnsi("32");
            printDisplayRaw(slice[index..end]);
            printReset();
            index = end;
            continue;
        }

        if (std.ascii.isDigit(slice[index]) or (slice[index] == '-' and index + 1 < slice.len and std.ascii.isDigit(slice[index + 1]))) {
            const end = numberEnd(slice, index);
            printAnsi("35");
            std.debug.print("{s}", .{slice[index..end]});
            printReset();
            index = end;
            continue;
        }

        if (source.isIdentifierStart(slice[index])) {
            const end = source.wordSpanAt(slice, index, source.isIdentifierContinue).?.end;
            const token = slice[index..end];
            if (isKeyword(token)) {
                printAnsi("34;1");
                std.debug.print("{s}", .{token});
                printReset();
            } else {
                printAnsi("36");
                std.debug.print("{s}", .{token});
                printReset();
            }
            index = end;
            continue;
        }

        const len = std.unicode.utf8ByteSequenceLength(slice[index]) catch 1;
        printDisplayRaw(slice[index..@min(index + len, slice.len)]);
        index += len;
    }
}

fn printDisplayRaw(slice: []const u8) void {
    var view = std.unicode.Utf8View.init(slice) catch {
        std.debug.print("{s}", .{slice});
        return;
    };
    var it = view.iterator();
    while (it.nextCodepointSlice()) |cp_slice| {
        if (cp_slice.len == 1 and cp_slice[0] == '\t') {
            printSpaces(4);
        } else {
            std.debug.print("{s}", .{cp_slice});
        }
    }
}

fn numberEnd(slice: []const u8, start: usize) usize {
    var index = start;
    if (slice[index] == '-') index += 1;
    var saw_dot = false;
    while (index < slice.len) : (index += 1) {
        if (std.ascii.isDigit(slice[index])) continue;
        if (slice[index] == '.' and !saw_dot) {
            saw_dot = true;
            continue;
        }
        break;
    }
    return index;
}

fn isKeyword(token: []const u8) bool {
    const keywords = [_][]const u8{ "import", "as", "const", "page", "fn", "let", "return", "end" };
    for (keywords) |keyword| {
        if (std.mem.eql(u8, token, keyword)) return true;
    }
    return false;
}

fn printAnsi(code: []const u8) void {
    if (!useColor()) return;
    std.debug.print("\x1b[{s}m", .{code});
}

fn printDim() void {
    printAnsi("2;37");
}

fn printSeverityPrefix(severity: Severity) void {
    switch (severity) {
        .@"error" => if (useColor()) std.debug.print("\x1b[1;31mERROR:\x1b[0m ", .{}) else std.debug.print("ERROR: ", .{}),
        .warning => if (useColor()) std.debug.print("\x1b[1;38;5;208mWARNING:\x1b[0m ", .{}) else std.debug.print("WARNING: ", .{}),
        .note => {},
    }
}

fn displayWidthBetween(text: []const u8, start: usize, end: usize) usize {
    return displayWidthSlice(text[@min(start, text.len)..@min(end, text.len)]);
}

fn displayWidthSlice(slice: []const u8) usize {
    var view = std.unicode.Utf8View.init(slice) catch return slice.len;
    var it = view.iterator();
    var width: usize = 0;
    var after_zwj = false;
    var regional_indicator_count: usize = 0;

    while (it.nextCodepoint()) |cp| {
        if (cp == '\t') {
            width += 4;
            after_zwj = false;
            regional_indicator_count = 0;
            continue;
        }

        if (cp == 0x200D) {
            after_zwj = true;
            continue;
        }

        const cp_width = codepointDisplayWidth(cp, after_zwj, regional_indicator_count);
        width += cp_width;
        after_zwj = false;
        if (isRegionalIndicator(cp)) {
            regional_indicator_count += 1;
        } else {
            regional_indicator_count = 0;
        }
    }
    return width;
}

fn codepointDisplayWidth(cp: u21, after_zwj: bool, regional_indicator_count: usize) usize {
    if (cp == 0) return 0;
    if (cp < 32 or (cp >= 0x7F and cp < 0xA0)) return 0;
    if (isCombiningMark(cp) or isVariationSelector(cp) or isEmojiModifier(cp)) return 0;
    if (after_zwj and isEmojiWide(cp)) return 0;
    if (isRegionalIndicator(cp)) return if (regional_indicator_count % 2 == 0) 2 else 0;
    return if (isWideCodepoint(cp)) 2 else 1;
}

fn isCombiningMark(cp: u21) bool {
    return (cp >= 0x0300 and cp <= 0x036F) or
        (cp >= 0x1AB0 and cp <= 0x1AFF) or
        (cp >= 0x1DC0 and cp <= 0x1DFF) or
        (cp >= 0x20D0 and cp <= 0x20FF) or
        (cp >= 0xFE20 and cp <= 0xFE2F);
}

fn isVariationSelector(cp: u21) bool {
    return (cp >= 0xFE00 and cp <= 0xFE0F) or
        (cp >= 0xE0100 and cp <= 0xE01EF);
}

fn isEmojiModifier(cp: u21) bool {
    return cp >= 0x1F3FB and cp <= 0x1F3FF;
}

fn isRegionalIndicator(cp: u21) bool {
    return cp >= 0x1F1E6 and cp <= 0x1F1FF;
}

fn isEmojiWide(cp: u21) bool {
    return (cp >= 0x1F000 and cp <= 0x1FAFF) or
        (cp >= 0x2600 and cp <= 0x27BF);
}

fn isWideCodepoint(cp: u21) bool {
    return (cp >= 0x1100 and cp <= 0x115F) or
        cp == 0x2329 or cp == 0x232A or
        (cp >= 0x2E80 and cp <= 0xA4CF and cp != 0x303F) or
        (cp >= 0xAC00 and cp <= 0xD7A3) or
        (cp >= 0xF900 and cp <= 0xFAFF) or
        (cp >= 0xFE10 and cp <= 0xFE19) or
        (cp >= 0xFE30 and cp <= 0xFE6F) or
        (cp >= 0xFF00 and cp <= 0xFF60) or
        (cp >= 0xFFE0 and cp <= 0xFFE6) or
        isEmojiWide(cp);
}

fn printColor(severity: Severity) void {
    if (!useColor()) return;
    switch (severity) {
        .@"error" => std.debug.print("\x1b[31m", .{}),
        .warning => std.debug.print("\x1b[33m", .{}),
        .note => std.debug.print("\x1b[36m", .{}),
    }
}

fn printReset() void {
    if (!useColor()) return;
    std.debug.print("\x1b[0m", .{});
}

fn useColor() bool {
    return switch (color_mode) {
        .auto => std.c.getenv("NO_COLOR") == null and !envEquals("CLICOLOR", "0"),
        .always => true,
        .never => false,
    };
}

fn envEquals(name: [:0]const u8, expected: []const u8) bool {
    const value = std.c.getenv(name) orelse return false;
    return std.mem.eql(u8, std.mem.span(value), expected);
}
