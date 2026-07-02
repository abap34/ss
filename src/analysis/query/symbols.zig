const std = @import("std");
const ast = @import("ast");
const utils = @import("utils");

const source = utils.source;

pub const Kind = enum {
    function,
    constant,
    page,
    enum_type,
    record,
    object_class,
};

pub const Symbol = struct {
    name: []u8,
    kind: Kind,
    span: source.ByteSpan,
    selection_span: source.ByteSpan,
};

pub fn collect(allocator: std.mem.Allocator, _: []const u8, program: ast.Program) ![]Symbol {
    var out = std.ArrayList(Symbol).empty;
    errdefer {
        for (out.items) |symbol| allocator.free(symbol.name);
        out.deinit(allocator);
    }

    for (program.functions.items) |decl| try appendFromSpan(allocator, &out, decl.name, .function, decl.span, decl.name_span);
    for (program.constants.items) |decl| try appendFromSpan(allocator, &out, decl.name, .constant, decl.span, decl.name_span);
    for (program.pages.items) |decl| try appendFromSpan(allocator, &out, decl.name, .page, decl.span, decl.name_span);
    for (program.types.items) |decl| try appendFromSpan(allocator, &out, decl.name, .enum_type, decl.span, decl.name_span);
    for (program.records.items) |decl| try appendFromSpan(allocator, &out, decl.name, .record, decl.span, decl.name_span);
    for (program.objects.items) |decl| try appendFromSpan(allocator, &out, decl.name, .object_class, decl.span, decl.name_span);

    return out.toOwnedSlice(allocator);
}

pub fn deinit(allocator: std.mem.Allocator, symbols: []Symbol) void {
    for (symbols) |symbol| allocator.free(symbol.name);
    allocator.free(symbols);
}

fn appendFromSpan(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(Symbol),
    name: []const u8,
    kind: Kind,
    span: ast.Span,
    name_span: ?ast.Span,
) !void {
    try out.append(allocator, .{
        .name = try allocator.dupe(u8, name),
        .kind = kind,
        .span = .{ .start = span.start, .end = span.end },
        .selection_span = selectionSpan(span, name_span),
    });
}

fn selectionSpan(span: ast.Span, name_span: ?ast.Span) source.ByteSpan {
    if (name_span) |value| return .{ .start = value.start, .end = value.end };
    return .{ .start = span.start, .end = span.start };
}
