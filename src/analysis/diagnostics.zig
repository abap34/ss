const std = @import("std");
const core = @import("core");
const utils = @import("utils");
const shared = @import("diagnostic");
const syntax = @import("../syntax.zig");
const source = utils.source;

pub const Severity = core.DiagnosticSeverity;
pub const Diagnostic = shared.Diagnostic;
pub const SourceId = shared.SourceId;
pub const DiagnosticBag = shared.Bag;

pub fn addSyntaxHoles(bag: *DiagnosticBag, path: []const u8, text: []const u8, holes: syntax.HoleTable) !void {
    if (holes.diagnostics.len == 0) return;
    const source_id = try bag.registerSource(path, text);
    for (holes.diagnostics) |diagnostic| {
        var message_buf: [256]u8 = undefined;
        const message = utils.err.formatParseDiagnostic(&message_buf, diagnostic);
        try bag.addAt(source_id, .@"error", utils.err.parseDiagnosticCode(diagnostic.err), message, .{
            .start = diagnostic.span.start,
            .end = diagnostic.span.end,
        }, diagnostic.caused_by);
    }
}

pub fn addDocumentStateFrom(bag: *DiagnosticBag, state: *core.DocumentState, start_index: usize) !void {
    std.debug.assert(start_index <= state.diagnostics.items.len);
    var source_ids = std.StringHashMap(shared.SourceId).init(bag.allocator);
    defer source_ids.deinit();
    for (state.diagnostics.items[start_index..]) |diagnostic| {
        const message = try utils.err.formatContextDiagnostic(bag.allocator, diagnostic);
        defer bag.allocator.free(message);
        const location = diagnosticLocation(state, diagnostic);
        const entry = try source_ids.getOrPut(location.path);
        if (!entry.found_existing) entry.value_ptr.* = try bag.registerSource(location.path, location.source);
        try bag.addAt(entry.value_ptr.*, diagnostic.severity, diagnostic.code(), message, location.span, null);
    }
}

const DiagnosticLocation = struct {
    path: []const u8,
    source: []const u8,
    span: ?source.ByteSpan,
};

fn diagnosticLocation(state: *core.DocumentState, diagnostic: core.Diagnostic) DiagnosticLocation {
    var report_path = state.projectPath();
    var report_source = state.projectSource();
    const located = if (diagnostic.origin) |origin|
        utils.err.parseLocatedOrigin(origin)
    else if (diagnostic.node_id) |node_id| blk: {
        const node = state.getNode(node_id) orelse break :blk null;
        break :blk if (node.origin) |origin| utils.err.parseLocatedOrigin(origin) else null;
    } else null;
    const span = if (located) |origin| blk: {
        if (origin.path) |origin_path| {
            if (state.moduleByPathOrSpec(origin_path)) |module| {
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
