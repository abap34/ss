const std = @import("std");
const core = @import("core");
const module_loader = @import("../modules/loader.zig");
const protocol = @import("protocol.zig");
const utils = @import("utils");

const source = utils.source;
const LspRange = protocol.Range;

pub const DiagnosticSet = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(LspDiagnostic),

    pub fn init(allocator: std.mem.Allocator) DiagnosticSet {
        return .{ .allocator = allocator, .items = .empty };
    }

    pub fn deinit(self: *DiagnosticSet) void {
        for (self.items.items) |*item| item.deinit(self.allocator);
        self.items.deinit(self.allocator);
    }

    pub fn hasErrors(self: *const DiagnosticSet) bool {
        for (self.items.items) |item| if (item.severity == .@"error") return true;
        return false;
    }

    pub fn add(
        self: *DiagnosticSet,
        path: []const u8,
        text: []const u8,
        severity: core.DiagnosticSeverity,
        code: []const u8,
        message: []const u8,
        span: ?source.ByteSpan,
    ) !void {
        try self.addWithRelated(path, text, severity, code, message, span, &.{});
    }

    fn addWithRelated(
        self: *DiagnosticSet,
        path: []const u8,
        text: []const u8,
        severity: core.DiagnosticSeverity,
        code: []const u8,
        message: []const u8,
        span: ?source.ByteSpan,
        related: []const LspRelatedInput,
    ) !void {
        const primary_span = span orelse return;
        const uri = try protocol.uriFromPath(self.allocator, path);
        const range = protocol.rangeFromSpan(text, primary_span);
        const code_copy = self.allocator.dupe(u8, code) catch |err| {
            self.allocator.free(uri);
            return err;
        };
        const message_copy = self.allocator.dupe(u8, message) catch |err| {
            self.allocator.free(uri);
            self.allocator.free(code_copy);
            return err;
        };
        var diagnostic = LspDiagnostic{
            .uri = uri,
            .range = range,
            .severity = severity,
            .code = code_copy,
            .message = message_copy,
        };
        errdefer diagnostic.deinit(self.allocator);
        for (related) |item| {
            const related_span = item.span orelse continue;
            const related_uri = try protocol.uriFromPath(self.allocator, item.path);
            const related_message = self.allocator.dupe(u8, item.message) catch |err| {
                self.allocator.free(related_uri);
                return err;
            };
            diagnostic.related_information.append(self.allocator, .{
                .uri = related_uri,
                .range = protocol.rangeFromSpan(item.source, related_span),
                .message = related_message,
            }) catch |err| {
                self.allocator.free(related_uri);
                self.allocator.free(related_message);
                return err;
            };
        }
        try self.items.append(self.allocator, diagnostic);
    }

    pub fn addLoadDiagnostics(self: *DiagnosticSet, load_diagnostics: *const module_loader.LoadDiagnostics) !void {
        for (load_diagnostics.items.items) |item| {
            try self.add(item.path, item.source, item.severity, item.code, item.message, item.span);
        }
    }

    pub fn addIr(self: *DiagnosticSet, ir: *core.Ir) !void {
        for (ir.diagnostics.items) |diagnostic| {
            const message = try utils.err.formatIrDiagnostic(ir.allocator, diagnostic);
            defer ir.allocator.free(message);
            var report_path = ir.projectPath();
            var report_source = ir.projectSource();
            const located = if (diagnostic.origin) |origin|
                utils.err.parseLocatedOrigin(origin)
            else if (diagnostic.node_id) |node_id| blk: {
                const node = ir.getNode(node_id) orelse break :blk null;
                break :blk if (node.origin) |origin| utils.err.parseLocatedOrigin(origin) else null;
            } else null;
            const span = if (located) |origin| blk: {
                if (origin.path) |origin_path| {
                    if (ir.moduleByPathOrSpec(origin_path)) |module| {
                        report_path = module.path orelse module.spec;
                        report_source = module.source;
                    } else {
                        report_path = origin_path;
                    }
                }
                break :blk origin.span;
            } else null;
            try self.add(report_path, report_source, diagnostic.severity, diagnosticCode(diagnostic), message, span);
        }
    }

    pub fn addConstraintFailure(self: *DiagnosticSet, ir: *core.Ir, err: anyerror) !void {
        if (ir.constraint_failures.items.len > 0) {
            try self.addConstraintFailureItem(ir, ir.constraint_failures.items[0]);
            return;
        }
        if (ir.last_constraint_failure) |failure| {
            try self.addConstraintFailureItem(ir, failure);
            return;
        }

        const message = try std.fmt.allocPrint(self.allocator, "BuildFailed: {s}", .{@errorName(err)});
        defer self.allocator.free(message);
        try self.add(ir.projectPath(), ir.projectSource(), .@"error", @errorName(err), message, null);
    }

    fn addConstraintFailureItem(self: *DiagnosticSet, ir: *core.Ir, failure: core.ConstraintFailure) !void {
        const kind_text = constraintFailureText(failure);
        const message = try formatConstraintFailureMessage(self.allocator, failure, kind_text);
        defer self.allocator.free(message);

        const primary = constraintFailureLocation(ir, constraintFailureOrigin(failure));
        var related = std.ArrayList(LspRelatedInput).empty;
        defer related.deinit(self.allocator);
        if (failure.existing_constraint) |constraint| {
            const location = constraintFailureLocation(ir, constraint.origin);
            if (location.span != null) {
                try related.append(self.allocator, .{
                    .path = location.path,
                    .source = location.source,
                    .span = location.span,
                    .message = "current value source",
                });
            }
        }
        if (failure.constraint.origin != null and failure.existing_constraint == null) {
            const location = constraintFailureLocation(ir, failure.constraint.origin);
            if (location.span != null and (primary.span == null or !spanEq(primary.span.?, location.span.?))) {
                try related.append(self.allocator, .{
                    .path = location.path,
                    .source = location.source,
                    .span = location.span,
                    .message = "propagating value source",
                });
            }
        }

        try self.addWithRelated(primary.path, primary.source, .@"error", constraintFailureCode(failure), message, primary.span, related.items);
    }
};

const LspRelatedInput = struct {
    path: []const u8,
    source: []const u8,
    span: ?source.ByteSpan,
    message: []const u8,
};

fn diagnosticCode(diagnostic: core.Diagnostic) []const u8 {
    return switch (diagnostic.data) {
        .user_report => |data| utils.err.userReportDiagnosticCode(data.message),
        .asset_not_found => "AssetNotFound",
        .asset_invalid => "InvalidAsset",
        .render_failed => "RenderFailed",
        .type_mismatch => |data| @tagName(data.code),
        .recursive_function => "RecursiveFunction",
        .page_overflow => "PageOverflow",
        .content_overflow => "ContentOverflow",
    };
}

fn constraintFailureCode(failure: core.ConstraintFailure) []const u8 {
    return switch (failure.kind) {
        .conflict => "ConstraintConflict",
        .negative_frame_size => "NegativeFrameSize",
    };
}

fn constraintFailureText(failure: core.ConstraintFailure) []const u8 {
    return switch (failure.kind) {
        .conflict => "ConstraintConflict: constraint conflict",
        .negative_frame_size => "NegativeFrameSize: negative frame size from constraints",
    };
}

fn constraintFailureOrigin(failure: core.ConstraintFailure) ?[]const u8 {
    if (failure.constraint.origin) |origin| return origin;
    if (failure.existing_constraint) |constraint| return constraint.origin;
    return null;
}

const ConstraintFailureLocation = struct {
    path: []const u8,
    source: []const u8,
    span: ?source.ByteSpan,
};

fn constraintFailureLocation(ir: *core.Ir, origin: ?[]const u8) ConstraintFailureLocation {
    var report_path = ir.projectPath();
    var report_source = ir.projectSource();
    var span: ?source.ByteSpan = null;
    if (origin) |origin_text| {
        if (utils.err.parseLocatedOrigin(origin_text)) |located| {
            span = located.span;
            if (located.path) |origin_path| {
                if (ir.moduleByPathOrSpec(origin_path)) |module| {
                    report_path = module.path orelse module.spec;
                    report_source = module.source;
                } else {
                    report_path = origin_path;
                }
            }
        }
    }
    return .{ .path = report_path, .source = report_source, .span = span };
}

fn spanEq(left: source.ByteSpan, right: source.ByteSpan) bool {
    return left.start == right.start and left.end == right.end;
}

fn formatConstraintFailureMessage(
    allocator: std.mem.Allocator,
    failure: core.ConstraintFailure,
    kind_text: []const u8,
) ![]u8 {
    var message = std.ArrayList(u8).empty;
    errdefer message.deinit(allocator);
    try message.appendSlice(allocator, kind_text);
    try message.appendSlice(allocator, "\nreason: ");
    try message.appendSlice(allocator, @tagName(failure.reason));
    if (failure.axis) |axis| {
        try message.appendSlice(allocator, "\naxis: ");
        try message.appendSlice(allocator, @tagName(axis));
    }
    if (failure.actual) |actual| {
        const value = try std.fmt.allocPrint(allocator, "\nactual: {d:.1}", .{actual});
        defer allocator.free(value);
        try message.appendSlice(allocator, value);
    }
    if (failure.expected) |expected| {
        const value = try std.fmt.allocPrint(allocator, "\nexpected: {d:.1}", .{expected});
        defer allocator.free(value);
        try message.appendSlice(allocator, value);
    }
    if (failure.propagation) |propagation| {
        try appendConstraintPropagationMessage(allocator, &message, propagation);
    }

    return try message.toOwnedSlice(allocator);
}

fn appendConstraintPropagationMessage(
    allocator: std.mem.Allocator,
    message: *std.ArrayList(u8),
    propagation: core.ConstraintPropagation,
) !void {
    if (propagation.target) |target| {
        try message.appendSlice(allocator, "\ntarget: ");
        try message.appendSlice(allocator, target);
    }
    for (propagation.paths) |path| {
        try message.appendSlice(allocator, "\n\n");
        try message.appendSlice(allocator, path.title);
        try message.appendSlice(allocator, ":");
        for (path.lines, 0..) |line, index| {
            try message.appendSlice(allocator, "\n  ");
            try message.appendSlice(allocator, line);
            const origin_source = if (index < path.line_sources.len) path.line_sources[index] else null;
            if (origin_source) |origin| {
                try message.appendSlice(allocator, "  ");
                try message.appendSlice(allocator, origin);
            }
        }
    }
    if (propagation.result.len > 0) {
        try message.appendSlice(allocator, "\n\nresult:");
        for (propagation.result) |line| {
            try message.appendSlice(allocator, "\n  ");
            try message.appendSlice(allocator, line);
        }
    }
}

const LspDiagnostic = struct {
    uri: []u8,
    range: LspRange,
    severity: core.DiagnosticSeverity,
    code: []u8,
    message: []u8,
    related_information: std.ArrayList(LspRelatedInformation) = .empty,

    fn deinit(self: *LspDiagnostic, allocator: std.mem.Allocator) void {
        allocator.free(self.uri);
        allocator.free(self.code);
        allocator.free(self.message);
        for (self.related_information.items) |*item| item.deinit(allocator);
        self.related_information.deinit(allocator);
    }

    pub fn appendJson(self: *const LspDiagnostic, allocator: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
        try out.appendSlice(allocator, "{\"range\":{\"start\":{\"line\":");
        try protocol.appendInt(allocator, out, self.range.start_line);
        try out.appendSlice(allocator, ",\"character\":");
        try protocol.appendInt(allocator, out, self.range.start_character);
        try out.appendSlice(allocator, "},\"end\":{\"line\":");
        try protocol.appendInt(allocator, out, self.range.end_line);
        try out.appendSlice(allocator, ",\"character\":");
        try protocol.appendInt(allocator, out, self.range.end_character);
        try out.appendSlice(allocator, "}},\"severity\":");
        const lsp_severity: i64 = if (self.severity == .@"error") 1 else 2;
        try protocol.appendInt(allocator, out, lsp_severity);
        try out.appendSlice(allocator, ",\"source\":\"ss\",\"code\":");
        try protocol.appendJsonString(allocator, out, self.code);
        try out.appendSlice(allocator, ",\"message\":");
        try protocol.appendJsonString(allocator, out, self.message);
        if (self.related_information.items.len != 0) {
            try out.appendSlice(allocator, ",\"relatedInformation\":[");
            for (self.related_information.items, 0..) |item, index| {
                if (index != 0) try out.append(allocator, ',');
                try item.appendJson(allocator, out);
            }
            try out.append(allocator, ']');
        }
        try out.append(allocator, '}');
    }
};

const LspRelatedInformation = struct {
    uri: []u8,
    range: LspRange,
    message: []u8,

    fn deinit(self: *LspRelatedInformation, allocator: std.mem.Allocator) void {
        allocator.free(self.uri);
        allocator.free(self.message);
    }

    fn appendJson(self: *const LspRelatedInformation, allocator: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
        try out.appendSlice(allocator, "{\"location\":{\"uri\":");
        try protocol.appendJsonString(allocator, out, self.uri);
        try out.appendSlice(allocator, ",\"range\":");
        try protocol.appendRange(allocator, out, self.range);
        try out.appendSlice(allocator, "},\"message\":");
        try protocol.appendJsonString(allocator, out, self.message);
        try out.append(allocator, '}');
    }
};
