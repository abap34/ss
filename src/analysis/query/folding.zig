const std = @import("std");
const ast = @import("ast");
const utils = @import("utils");

const source = utils.source;

pub const Range = struct {
    span: source.ByteSpan,
};

pub fn collect(allocator: std.mem.Allocator, text: []const u8, program: ast.Program) ![]Range {
    var out = std.ArrayList(Range).empty;
    errdefer out.deinit(allocator);

    for (program.functions.items) |decl| try appendFromSpan(allocator, &out, text, decl.span);
    for (program.pages.items) |decl| try appendFromSpan(allocator, &out, text, decl.span);
    for (program.document_blocks.items) |decl| try appendFromSpan(allocator, &out, text, decl.span);
    for (program.records.items) |decl| try appendFromSpan(allocator, &out, text, decl.span);
    for (program.objects.items) |decl| try appendFromSpan(allocator, &out, text, decl.span);
    for (program.object_extensions.items) |decl| try appendFromSpan(allocator, &out, text, decl.span);

    return out.toOwnedSlice(allocator);
}

fn appendFromSpan(allocator: std.mem.Allocator, out: *std.ArrayList(Range), text: []const u8, span: ast.Span) !void {
    const start_line = source.lineAt(text, @min(span.start, text.len)).number;
    const end_line = source.lineAt(text, @min(@max(span.end, span.start + 1), text.len)).number;
    if (end_line <= start_line) return;
    try out.append(allocator, .{ .span = .{ .start = span.start, .end = span.end } });
}
