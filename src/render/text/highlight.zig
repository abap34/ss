const std = @import("std");
const core = @import("core");
const utils = @import("utils");
const build_options = @import("build_options");

const TSLanguage = opaque {};
const TSParser = opaque {};
const TSTree = opaque {};
const TSQuery = opaque {};
const TSQueryCursor = opaque {};

const TSQueryError = enum(c_int) {
    none = 0,
    syntax = 1,
    node_type = 2,
    field = 3,
    capture = 4,
    structure = 5,
    language = 6,
};

const TSNode = extern struct {
    context: [4]u32,
    id: ?*const anyopaque,
    tree: ?*const TSTree,
};

const TSQueryCapture = extern struct {
    node: TSNode,
    index: u32,
};

const TSQueryMatch = extern struct {
    id: u32,
    pattern_index: u16,
    capture_count: u16,
    captures: [*c]const TSQueryCapture,
};

extern fn tree_sitter_ss() *const TSLanguage;

const Allocator = std.mem.Allocator;

pub const CodePaint = core.render_policy.CodePaint;
pub const Color = core.render_policy.Color;

pub const Context = struct {
    io: std.Io,
    languages: []const utils.highlight.Language = &.{},
};

pub const Request = struct {
    context: Context,
    code: CodePaint,
};

pub const Span = struct {
    start: usize,
    end: usize,
    color: Color,
};

const HighlightLanguageHandle = struct {
    language: *const TSLanguage,
    library: ?std.DynLib = null,

    fn deinit(self: *HighlightLanguageHandle) void {
        if (self.library) |*library| library.close();
    }
};

const TreeSitterRuntime = struct {
    library: std.DynLib,
    parser_new: *const fn () callconv(.c) ?*TSParser,
    parser_delete: *const fn (*TSParser) callconv(.c) void,
    parser_set_language: *const fn (*TSParser, *const TSLanguage) callconv(.c) bool,
    parser_parse_string: *const fn (*TSParser, ?*const TSTree, [*c]const u8, u32) callconv(.c) ?*TSTree,
    tree_delete: *const fn (*TSTree) callconv(.c) void,
    tree_root_node: *const fn (*const TSTree) callconv(.c) TSNode,
    query_new: *const fn (*const TSLanguage, [*c]const u8, u32, *u32, *TSQueryError) callconv(.c) ?*TSQuery,
    query_delete: *const fn (*TSQuery) callconv(.c) void,
    query_capture_name_for_id: *const fn (*const TSQuery, u32, *u32) callconv(.c) ?[*]const u8,
    query_cursor_new: *const fn () callconv(.c) ?*TSQueryCursor,
    query_cursor_delete: *const fn (*TSQueryCursor) callconv(.c) void,
    query_cursor_exec: *const fn (*TSQueryCursor, *const TSQuery, TSNode) callconv(.c) void,
    query_cursor_next_capture: *const fn (*TSQueryCursor, *TSQueryMatch, *u32) callconv(.c) bool,
    node_start_byte: *const fn (TSNode) callconv(.c) u32,
    node_end_byte: *const fn (TSNode) callconv(.c) u32,

    fn deinit(self: *TreeSitterRuntime) void {
        self.library.close();
    }
};

const LoadedHighlightQuery = struct {
    text: []const u8,
    owned: bool = false,

    fn deinit(self: *LoadedHighlightQuery, allocator: Allocator) void {
        if (self.owned) allocator.free(self.text);
    }
};

pub fn collectSpans(allocator: Allocator, request: Request, content: []const u8) !std.ArrayList(Span) {
    var spans = std.ArrayList(Span).empty;
    errdefer spans.deinit(allocator);

    const language_name = request.code.language orelse return spans;
    const configured = languageFor(request.context.languages, language_name) orelse return spans;
    if (content.len > std.math.maxInt(u32)) return spans;

    var runtime = try loadTreeSitterRuntime();
    defer runtime.deinit();

    var handle = try loadTreeSitterLanguage(allocator, configured);
    defer handle.deinit();

    var query_source = try loadHighlightQuerySource(allocator, request.context.io, configured);
    defer query_source.deinit(allocator);

    const parser = runtime.parser_new() orelse return error.TreeSitterParserCreateFailed;
    defer runtime.parser_delete(parser);
    if (!runtime.parser_set_language(parser, handle.language)) return error.TreeSitterLanguageRejected;

    const tree = runtime.parser_parse_string(parser, null, @ptrCast(content.ptr), @intCast(content.len)) orelse return error.TreeSitterParseFailed;
    defer runtime.tree_delete(tree);

    var query_error_offset: u32 = 0;
    var query_error_type: TSQueryError = .none;
    const query = runtime.query_new(handle.language, @ptrCast(query_source.text.ptr), @intCast(query_source.text.len), &query_error_offset, &query_error_type) orelse return error.TreeSitterQueryFailed;
    defer runtime.query_delete(query);

    const cursor = runtime.query_cursor_new() orelse return error.TreeSitterQueryCursorCreateFailed;
    defer runtime.query_cursor_delete(cursor);
    runtime.query_cursor_exec(cursor, query, runtime.tree_root_node(tree));

    var match: TSQueryMatch = undefined;
    var capture_index: u32 = 0;
    while (runtime.query_cursor_next_capture(cursor, &match, &capture_index)) {
        if (capture_index >= match.capture_count) continue;
        const capture = match.captures[capture_index];
        var capture_name_len: u32 = 0;
        const capture_name_ptr = runtime.query_capture_name_for_id(query, capture.index, &capture_name_len) orelse continue;
        const capture_name = @as([*]const u8, @ptrCast(capture_name_ptr))[0..capture_name_len];
        const color = colorForCapture(request.code, capture_name) orelse continue;
        const start: usize = runtime.node_start_byte(capture.node);
        const end: usize = runtime.node_end_byte(capture.node);
        if (start >= end or end > content.len) continue;
        try spans.append(allocator, .{ .start = start, .end = end, .color = color });
    }

    std.mem.sort(Span, spans.items, {}, spanLessThan);
    return spans;
}

pub fn nextBoundary(spans: []const Span, pos: usize, line_end: usize) usize {
    var next = line_end;
    for (spans) |span| {
        if (span.end <= pos or span.start >= line_end) continue;
        if (span.start > pos) next = @min(next, span.start);
        if (span.start <= pos and span.end > pos) next = @min(next, span.end);
    }
    return next;
}

pub fn colorAt(spans: []const Span, start: usize, end: usize) ?Color {
    var best: ?Span = null;
    for (spans) |span| {
        if (span.start > start or span.end < end) continue;
        if (best == null or spanMoreSpecific(span, best.?)) best = span;
    }
    return if (best) |span| span.color else null;
}

fn languageFor(languages: []const utils.highlight.Language, language: []const u8) ?*const utils.highlight.Language {
    for (languages) |*configured| {
        if (std.ascii.eqlIgnoreCase(configured.name, language)) return configured;
    }
    return null;
}

fn loadHighlightQuerySource(allocator: Allocator, io: std.Io, configured: *const utils.highlight.Language) !LoadedHighlightQuery {
    if (std.mem.eql(u8, configured.query, "builtin:ss")) {
        return .{ .text = build_options.ss_highlight_query };
    }
    return .{
        .text = try std.Io.Dir.cwd().readFileAlloc(io, configured.query, allocator, .limited(1024 * 1024)),
        .owned = true,
    };
}

fn loadTreeSitterLanguage(allocator: Allocator, configured: *const utils.highlight.Language) !HighlightLanguageHandle {
    if (configured.library == null and std.ascii.eqlIgnoreCase(configured.parser, "ss")) {
        return .{ .language = tree_sitter_ss() };
    }

    const library_path = configured.library orelse return error.TreeSitterLibraryRequired;
    var library = try std.DynLib.open(library_path);
    errdefer library.close();

    const symbol_name = if (configured.symbol) |symbol|
        try allocator.dupeZ(u8, symbol)
    else
        try defaultTreeSitterSymbol(allocator, configured.parser);
    defer allocator.free(symbol_name);

    const LanguageFn = *const fn () callconv(.c) *const TSLanguage;
    const language_fn = library.lookup(LanguageFn, symbol_name) orelse return error.TreeSitterSymbolNotFound;
    return .{
        .language = language_fn(),
        .library = library,
    };
}

fn loadTreeSitterRuntime() !TreeSitterRuntime {
    const candidates = [_][]const u8{
        "libtree-sitter.dylib",
        "/opt/homebrew/lib/libtree-sitter.dylib",
        "/usr/local/lib/libtree-sitter.dylib",
        "libtree-sitter.so",
        "libtree-sitter.so.0",
        "tree-sitter.dll",
    };

    for (candidates) |candidate| {
        var library = std.DynLib.open(candidate) catch continue;
        errdefer library.close();
        return .{
            .library = library,
            .parser_new = try lookupTreeSitterSymbol(&library, *const fn () callconv(.c) ?*TSParser, "ts_parser_new"),
            .parser_delete = try lookupTreeSitterSymbol(&library, *const fn (*TSParser) callconv(.c) void, "ts_parser_delete"),
            .parser_set_language = try lookupTreeSitterSymbol(&library, *const fn (*TSParser, *const TSLanguage) callconv(.c) bool, "ts_parser_set_language"),
            .parser_parse_string = try lookupTreeSitterSymbol(&library, *const fn (*TSParser, ?*const TSTree, [*c]const u8, u32) callconv(.c) ?*TSTree, "ts_parser_parse_string"),
            .tree_delete = try lookupTreeSitterSymbol(&library, *const fn (*TSTree) callconv(.c) void, "ts_tree_delete"),
            .tree_root_node = try lookupTreeSitterSymbol(&library, *const fn (*const TSTree) callconv(.c) TSNode, "ts_tree_root_node"),
            .query_new = try lookupTreeSitterSymbol(&library, *const fn (*const TSLanguage, [*c]const u8, u32, *u32, *TSQueryError) callconv(.c) ?*TSQuery, "ts_query_new"),
            .query_delete = try lookupTreeSitterSymbol(&library, *const fn (*TSQuery) callconv(.c) void, "ts_query_delete"),
            .query_capture_name_for_id = try lookupTreeSitterSymbol(&library, *const fn (*const TSQuery, u32, *u32) callconv(.c) ?[*]const u8, "ts_query_capture_name_for_id"),
            .query_cursor_new = try lookupTreeSitterSymbol(&library, *const fn () callconv(.c) ?*TSQueryCursor, "ts_query_cursor_new"),
            .query_cursor_delete = try lookupTreeSitterSymbol(&library, *const fn (*TSQueryCursor) callconv(.c) void, "ts_query_cursor_delete"),
            .query_cursor_exec = try lookupTreeSitterSymbol(&library, *const fn (*TSQueryCursor, *const TSQuery, TSNode) callconv(.c) void, "ts_query_cursor_exec"),
            .query_cursor_next_capture = try lookupTreeSitterSymbol(&library, *const fn (*TSQueryCursor, *TSQueryMatch, *u32) callconv(.c) bool, "ts_query_cursor_next_capture"),
            .node_start_byte = try lookupTreeSitterSymbol(&library, *const fn (TSNode) callconv(.c) u32, "ts_node_start_byte"),
            .node_end_byte = try lookupTreeSitterSymbol(&library, *const fn (TSNode) callconv(.c) u32, "ts_node_end_byte"),
        };
    }

    return error.TreeSitterRuntimeUnavailable;
}

fn lookupTreeSitterSymbol(library: *std.DynLib, comptime T: type, name: [:0]const u8) !T {
    return library.lookup(T, name) orelse error.TreeSitterRuntimeSymbolNotFound;
}

fn defaultTreeSitterSymbol(allocator: Allocator, parser_name: []const u8) ![:0]u8 {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    try out.appendSlice(allocator, "tree_sitter_");
    for (parser_name) |byte| {
        try out.append(allocator, if (std.ascii.isAlphanumeric(byte)) byte else '_');
    }
    return allocator.dupeZ(u8, out.items);
}

fn colorForCapture(code: CodePaint, capture_name: []const u8) ?Color {
    const base = captureBaseName(capture_name);
    if (std.mem.eql(u8, base, "comment")) return code.comment;
    if (std.mem.eql(u8, base, "string")) return code.string;
    if (std.mem.eql(u8, base, "keyword")) return code.keyword;
    if (std.mem.eql(u8, base, "function") or std.mem.eql(u8, base, "method")) return code.function;
    if (std.mem.eql(u8, base, "type")) return code.type;
    if (std.mem.eql(u8, base, "constant") or std.mem.eql(u8, base, "attribute")) return code.constant;
    if (std.mem.eql(u8, base, "number")) return code.number;
    if (std.mem.eql(u8, base, "variable") or
        std.mem.eql(u8, base, "property") or
        std.mem.eql(u8, base, "namespace"))
    {
        return code.variable;
    }
    if (std.mem.eql(u8, base, "operator") or std.mem.eql(u8, base, "punctuation")) return code.operator;
    return null;
}

fn captureBaseName(capture_name: []const u8) []const u8 {
    const dot = std.mem.indexOfScalar(u8, capture_name, '.') orelse return capture_name;
    return capture_name[0..dot];
}

fn spanLessThan(_: void, lhs: Span, rhs: Span) bool {
    if (lhs.start != rhs.start) return lhs.start < rhs.start;
    const lhs_len = lhs.end - lhs.start;
    const rhs_len = rhs.end - rhs.start;
    return lhs_len < rhs_len;
}

fn spanMoreSpecific(candidate: Span, current: Span) bool {
    const candidate_len = candidate.end - candidate.start;
    const current_len = current.end - current.start;
    if (candidate_len != current_len) return candidate_len < current_len;
    return candidate.start >= current.start;
}
