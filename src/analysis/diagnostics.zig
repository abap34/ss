const std = @import("std");
const core = @import("core");
const utils = @import("utils");

const syntax = @import("../syntax.zig");

const source = utils.source;

pub const Severity = core.DiagnosticSeverity;

pub const Diagnostic = struct {
    path: []u8,
    source: []u8,
    severity: Severity,
    code: []u8,
    message: []u8,
    span: ?source.ByteSpan = null,
    caused_by: ?syntax.HoleId = null,

    fn deinit(self: *Diagnostic, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.source);
        allocator.free(self.code);
        allocator.free(self.message);
    }
};

pub const DiagnosticBag = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(Diagnostic),

    pub fn init(allocator: std.mem.Allocator) DiagnosticBag {
        return .{ .allocator = allocator, .items = .empty };
    }

    pub fn deinit(self: *DiagnosticBag) void {
        for (self.items.items) |*item| item.deinit(self.allocator);
        self.items.deinit(self.allocator);
    }

    pub fn hasErrors(self: *const DiagnosticBag) bool {
        for (self.items.items) |item| if (item.severity == .@"error") return true;
        return false;
    }

    pub fn sortByPath(self: *DiagnosticBag) void {
        std.mem.sort(Diagnostic, self.items.items, {}, diagnosticLessThan);
    }

    pub fn itemsForPath(self: *const DiagnosticBag, path: []const u8) []const Diagnostic {
        var start: ?usize = null;
        var end: usize = 0;
        for (self.items.items, 0..) |item, index| {
            if (std.mem.eql(u8, item.path, path)) {
                if (start == null) start = index;
                end = index + 1;
                continue;
            }
            if (start != null) break;
        }
        const first = start orelse return &.{};
        return self.items.items[first..end];
    }

    pub fn add(
        self: *DiagnosticBag,
        path: []const u8,
        text: []const u8,
        severity: Severity,
        code: []const u8,
        message: []const u8,
        span: ?source.ByteSpan,
        caused_by: ?syntax.HoleId,
    ) !void {
        if (caused_by) |hole_id| {
            for (self.items.items) |item| {
                if (item.caused_by == hole_id) return;
            }
        }
        const path_copy = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(path_copy);
        const source_copy = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(source_copy);
        const code_copy = try self.allocator.dupe(u8, code);
        errdefer self.allocator.free(code_copy);
        const message_copy = try self.allocator.dupe(u8, message);
        errdefer self.allocator.free(message_copy);
        var diagnostic = Diagnostic{
            .path = path_copy,
            .source = source_copy,
            .severity = severity,
            .code = code_copy,
            .message = message_copy,
            .span = span,
            .caused_by = caused_by,
        };
        errdefer diagnostic.deinit(self.allocator);
        try self.items.append(self.allocator, diagnostic);
    }

    pub fn addSyntaxHoles(
        self: *DiagnosticBag,
        path: []const u8,
        text: []const u8,
        holes: syntax.HoleTable,
    ) !void {
        for (holes.diagnostics) |diagnostic| {
            var message_buf: [256]u8 = undefined;
            const message = utils.err.formatParseDiagnostic(&message_buf, diagnostic);
            try self.add(path, text, .@"error", @errorName(diagnostic.err), message, .{
                .start = diagnostic.span.start,
                .end = diagnostic.span.end,
            }, diagnostic.caused_by);
        }
    }

    pub fn addIr(self: *DiagnosticBag, ir: *core.Ir) !void {
        for (ir.diagnostics.items) |diagnostic| {
            const message = try utils.err.formatIrDiagnostic(self.allocator, diagnostic);
            defer self.allocator.free(message);
            const location = diagnosticLocation(ir, diagnostic);
            try self.add(location.path, location.source, diagnostic.severity, diagnosticCode(diagnostic), message, location.span, null);
        }
    }
};

fn diagnosticLessThan(_: void, left: Diagnostic, right: Diagnostic) bool {
    const path_order = std.mem.order(u8, left.path, right.path);
    if (path_order != .eq) return path_order == .lt;
    const left_start = if (left.span) |span| span.start else 0;
    const right_start = if (right.span) |span| span.start else 0;
    if (left_start != right_start) return left_start < right_start;
    return std.mem.lessThan(u8, left.code, right.code);
}

const DiagnosticLocation = struct {
    path: []const u8,
    source: []const u8,
    span: ?source.ByteSpan,
};

fn diagnosticLocation(ir: *core.Ir, diagnostic: core.Diagnostic) DiagnosticLocation {
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
    return .{ .path = report_path, .source = report_source, .span = span };
}

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
