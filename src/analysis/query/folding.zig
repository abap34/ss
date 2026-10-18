const std = @import("std");
const ast = @import("ast");
const utils = @import("utils");

const source = utils.source;

pub const Range = struct {
    span: source.ByteSpan,
};

pub fn collect(allocator: std.mem.Allocator, text: source.LineIndex, program: ast.Module) ![]Range {
    var out = std.ArrayList(Range).empty;
    errdefer out.deinit(allocator);

    for (program.functions.items) |decl| try appendFromSpan(allocator, &out, text, decl.span);
    for (program.pages.items) |decl| try appendFromSpan(allocator, &out, text, decl.span);
    for (program.document_blocks.items) |decl| try appendFromSpan(allocator, &out, text, decl.span);
    for (program.records.items) |decl| try appendFromSpan(allocator, &out, text, decl.span);

    return out.toOwnedSlice(allocator);
}

fn appendFromSpan(allocator: std.mem.Allocator, out: *std.ArrayList(Range), text: source.LineIndex, span: ast.Span) !void {
    const start = @min(span.start, text.text.len);
    var end = @min(span.end, text.text.len);
    while (end > start and (text.text[end - 1] == '\n' or text.text[end - 1] == '\r')) end -= 1;
    const start_line = text.lineAt(start).number;
    const end_line = text.lineAt(end).number;
    if (end_line <= start_line) return;
    try out.append(allocator, .{ .span = .{ .start = start, .end = end } });
}
