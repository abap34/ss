const std = @import("std");
const scanner = @import("../../syntax/scanner.zig");
const utils = @import("utils");
const types = @import("types.zig");

pub const Import = struct {
    prefix: []const u8,
    span: utils.source.ByteSpan,
    quoted: bool,
    closed: bool,
};

pub const Position = union(enum) {
    ordinary,
    module: struct { alias: []const u8, span: utils.source.ByteSpan },
    import_path: Import,
};

// Read tokens, rather than matching source lines, so comments and multiline
// strings cannot introduce an import or a qualified name.
pub fn at(req: types.SourceRequest, budget: types.QueryBudget) error{QueryExpired}!Position {
    const offset = @min(req.offset, req.source.len);
    const line = utils.source.lineSpanAt(req.source, offset);
    const prefix = req.source[line.start..offset];
    // Ordinary member/field queries should retain their indexed syntax path.
    // This is only a fast exclusion; the lexer validates every matching context.
    if (!mayBeImport(req) and std.mem.indexOf(u8, prefix, "::") == null) return .ordinary;
    var tokens = scanner.tokens(req.source);
    var previous: ?scanner.Token = null;
    var qualifier: ?scanner.Token = null;
    while (true) {
        if (budget.expired()) return error.QueryExpired;
        const token = tokens.nextWithPunctuation() orelse break;
        if (token.span.start > offset) break;
        const word = req.source[token.span.start..token.span.end];
        if (token.kind == .identifier and std.mem.eql(u8, word, "import") and
            std.mem.trim(u8, req.source[token.line_start..token.span.start], " \t\r").len == 0)
        {
            if (importAt(req.source, token, offset)) |position| return .{ .import_path = position };
        }
        if (token.kind == .operator and std.mem.eql(u8, word, "::")) {
            qualifier = if (previous) |p| if (p.kind == .identifier and p.span.end == token.span.start) p else null else null;
        } else if (token.kind == .identifier and qualifier != null) {
            const separator = previous.?;
            if (separator.kind == .operator and offset <= token.span.end and
                std.mem.trim(u8, req.source[separator.span.end..token.span.start], " \t").len == 0)
                return .{ .module = .{ .alias = req.source[qualifier.?.span.start..qualifier.?.span.end], .span = token.span } };
            qualifier = null;
        } else qualifier = null;
        previous = token;
        if (token.span.end > offset) break;
    }
    if (qualifier) |alias| if (previous) |separator| {
        if (separator.span.end <= offset and std.mem.trim(u8, req.source[separator.span.end..offset], " \t").len == 0)
            return .{ .module = .{ .alias = req.source[alias.span.start..alias.span.end], .span = .{ .start = offset, .end = offset } } };
    };
    return .ordinary;
}

pub fn mayBeImport(req: types.SourceRequest) bool {
    const offset = @min(req.offset, req.source.len);
    const line = utils.source.lineSpanAt(req.source, offset);
    const prefix = std.mem.trimStart(u8, req.source[line.start..offset], " \t");
    return std.mem.startsWith(u8, prefix, "import") and prefix.len > 6 and utils.source.isInlineSpace(prefix[6]);
}

fn importAt(source: []const u8, keyword: scanner.Token, offset: usize) ?Import {
    if (offset <= keyword.span.end or offset > keyword.line_end) return null;
    var start = keyword.span.end;
    while (start < keyword.line_end and utils.source.isInlineSpace(source[start])) : (start += 1) {}
    const quoted = start < keyword.line_end and source[start] == '"';
    if (quoted) start += 1;
    if (offset < start) return null;
    var end = start;
    while (end < keyword.line_end) : (end += 1) {
        if (quoted) {
            if (source[end] == '"') break;
            if (source[end] == '\\' and end + 1 < keyword.line_end) end += 1;
        } else if (utils.source.isInlineSpace(source[end]) or utils.source.lineCommentMarkerLength(source, end) != null) break;
    }
    if (offset > end) return null;
    return .{ .prefix = source[start..offset], .span = .{ .start = start, .end = end }, .quoted = quoted, .closed = quoted and end < keyword.line_end and source[end] == '"' };
}
