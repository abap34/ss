const std = @import("std");
const build_options = @import("build_options");
const utils = @import("utils");

const Allocator = std.mem.Allocator;
const query_read_limit = 1024 * 1024;

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
extern fn tree_sitter_bash() *const TSLanguage;
extern fn tree_sitter_c() *const TSLanguage;
extern fn tree_sitter_cpp() *const TSLanguage;
extern fn tree_sitter_css() *const TSLanguage;
extern fn tree_sitter_go() *const TSLanguage;
extern fn tree_sitter_html() *const TSLanguage;
extern fn tree_sitter_java() *const TSLanguage;
extern fn tree_sitter_javascript() *const TSLanguage;
extern fn tree_sitter_json() *const TSLanguage;
extern fn tree_sitter_julia() *const TSLanguage;
extern fn tree_sitter_python() *const TSLanguage;
extern fn tree_sitter_rust() *const TSLanguage;
extern fn tree_sitter_toml() *const TSLanguage;
extern fn tree_sitter_typescript() *const TSLanguage;
extern fn tree_sitter_tsx() *const TSLanguage;
extern fn tree_sitter_yaml() *const TSLanguage;
extern fn tree_sitter_zig() *const TSLanguage;

extern fn ts_parser_new() ?*TSParser;
extern fn ts_parser_delete(*TSParser) void;
extern fn ts_parser_set_language(*TSParser, *const TSLanguage) bool;
extern fn ts_parser_parse_string(*TSParser, ?*const TSTree, [*c]const u8, u32) ?*TSTree;
extern fn ts_tree_delete(*TSTree) void;
extern fn ts_tree_root_node(*const TSTree) TSNode;
extern fn ts_query_new(*const TSLanguage, [*c]const u8, u32, *u32, *TSQueryError) ?*TSQuery;
extern fn ts_query_delete(*TSQuery) void;
extern fn ts_query_capture_name_for_id(*const TSQuery, u32, *u32) ?[*]const u8;
extern fn ts_query_cursor_new() ?*TSQueryCursor;
extern fn ts_query_cursor_delete(*TSQueryCursor) void;
extern fn ts_query_cursor_exec(*TSQueryCursor, *const TSQuery, TSNode) void;
extern fn ts_query_cursor_next_capture(*TSQueryCursor, *TSQueryMatch, *u32) bool;
extern fn ts_node_start_byte(TSNode) u32;
extern fn ts_node_end_byte(TSNode) u32;

const LanguageDefinition = struct {
    parser_name: []const u8,
    load: *const fn () callconv(.c) *const TSLanguage,
    query_name: []const u8,
    query_source: []const u8,
    health_sample: []const u8,
};

const language_definitions = [_]LanguageDefinition{
    .{
        .parser_name = "ss",
        .load = tree_sitter_ss,
        .query_name = "builtin:ss",
        .query_source = build_options.ss_highlight_query,
        .health_sample = "import std:themes/default as *\n\npage sample\ntext!(\"hello\")\nend\n",
    },
    .{
        .parser_name = "bash",
        .load = tree_sitter_bash,
        .query_name = "builtin:bash",
        .query_source = build_options.bash_highlight_query,
        .health_sample = "echo \"$HOME\"\n",
    },
    .{
        .parser_name = "c",
        .load = tree_sitter_c,
        .query_name = "builtin:c",
        .query_source = build_options.c_highlight_query,
        .health_sample = "#include <stdio.h>\nint main(void) { return 0; }\n",
    },
    .{
        .parser_name = "cpp",
        .load = tree_sitter_cpp,
        .query_name = "builtin:cpp",
        .query_source = build_options.cpp_highlight_query,
        .health_sample = "class Sample { public: auto method() { return nullptr; } };\n",
    },
    .{
        .parser_name = "css",
        .load = tree_sitter_css,
        .query_name = "builtin:css",
        .query_source = build_options.css_highlight_query,
        .health_sample = "body { color: red; }\n",
    },
    .{
        .parser_name = "go",
        .load = tree_sitter_go,
        .query_name = "builtin:go",
        .query_source = build_options.go_highlight_query,
        .health_sample = "package main\nfunc main() { println(\"hello\") }\n",
    },
    .{
        .parser_name = "html",
        .load = tree_sitter_html,
        .query_name = "builtin:html",
        .query_source = build_options.html_highlight_query,
        .health_sample = "<!doctype html><p class=\"sample\">hello</p>\n",
    },
    .{
        .parser_name = "java",
        .load = tree_sitter_java,
        .query_name = "builtin:java",
        .query_source = build_options.java_highlight_query,
        .health_sample = "class Main { public static void main(String[] args) { System.out.println(\"hello\"); } }\n",
    },
    .{
        .parser_name = "javascript",
        .load = tree_sitter_javascript,
        .query_name = "builtin:javascript",
        .query_source = build_options.javascript_highlight_query,
        .health_sample = "function main() { return 1; }\n",
    },
    .{
        .parser_name = "json",
        .load = tree_sitter_json,
        .query_name = "builtin:json",
        .query_source = build_options.json_highlight_query,
        .health_sample = "{\"name\": true, \"count\": 1}\n",
    },
    .{
        .parser_name = "julia",
        .load = tree_sitter_julia,
        .query_name = "builtin:julia",
        .query_source = build_options.julia_highlight_query,
        .health_sample = "function f(x)\n  x + 1\nend\n",
    },
    .{
        .parser_name = "python",
        .load = tree_sitter_python,
        .query_name = "builtin:python",
        .query_source = build_options.python_highlight_query,
        .health_sample = "def f(x):\n    return x + 1\n",
    },
    .{
        .parser_name = "rust",
        .load = tree_sitter_rust,
        .query_name = "builtin:rust",
        .query_source = build_options.rust_highlight_query,
        .health_sample = "fn main() { let value = 1; }\n",
    },
    .{
        .parser_name = "toml",
        .load = tree_sitter_toml,
        .query_name = "builtin:toml",
        .query_source = build_options.toml_highlight_query,
        .health_sample = "name = \"ss\"\ncount = 1\n",
    },
    .{
        .parser_name = "typescript",
        .load = tree_sitter_typescript,
        .query_name = "builtin:typescript",
        .query_source = build_options.typescript_highlight_query,
        .health_sample = "const value: number = 1;\n",
    },
    .{
        .parser_name = "tsx",
        .load = tree_sitter_tsx,
        .query_name = "builtin:typescript",
        .query_source = build_options.typescript_highlight_query,
        .health_sample = "const value = <div>{1}</div>;\n",
    },
    .{
        .parser_name = "yaml",
        .load = tree_sitter_yaml,
        .query_name = "builtin:yaml",
        .query_source = build_options.yaml_highlight_query,
        .health_sample = "name: ss\nitems:\n  - one\n",
    },
    .{
        .parser_name = "zig",
        .load = tree_sitter_zig,
        .query_name = "builtin:zig",
        .query_source = build_options.zig_highlight_query,
        .health_sample = "pub fn main() void { const value = 1; }\n",
    },
};

pub const tree_sitter_language_version: u32 = build_options.tree_sitter_language_version;
pub const tree_sitter_min_compatible_language_version: u32 = build_options.tree_sitter_min_compatible_language_version;

pub const Span = struct {
    start: usize,
    end: usize,
    role: utils.highlight.CaptureRole,
};

pub const Failure = union(enum) {
    none,
    query_read: struct {
        path: []const u8,
        cause: anyerror,
    },
    query_invalid: struct {
        path: []const u8,
        offset: u32,
        error_type: TSQueryError,
    },

    pub fn messageAlloc(self: Failure, allocator: Allocator) !?[]u8 {
        return switch (self) {
            .none => null,
            .query_read => |failure| blk: {
                var reason_buf: [256]u8 = undefined;
                break :blk try std.fmt.allocPrint(
                    allocator,
                    "highlight query '{s}' could not be read: {s}",
                    .{ failure.path, utils.err.formatErrorReason(&reason_buf, failure.cause) },
                );
            },
            .query_invalid => |failure| try std.fmt.allocPrint(
                allocator,
                "highlight query '{s}' is invalid at byte {d} ({s})",
                .{ failure.path, failure.offset, @tagName(failure.error_type) },
            ),
        };
    }
};

pub const TreeSitterHealthStatus = enum {
    ok,
    warning,
    fail,
};

pub const TreeSitterHealthItem = struct {
    name: []u8,
    parser: []u8,
    query: []u8,
    status: TreeSitterHealthStatus,
    detail: []u8,
    capture_count: usize = 0,
    mapped_capture_count: usize = 0,

    pub fn deinit(self: *TreeSitterHealthItem, allocator: Allocator) void {
        allocator.free(self.name);
        allocator.free(self.parser);
        allocator.free(self.query);
        allocator.free(self.detail);
    }
};

pub const TreeSitterHealthReport = struct {
    configured_languages: usize,
    failures: usize,
    warnings: usize,
    items: []TreeSitterHealthItem,

    pub fn deinit(self: *TreeSitterHealthReport, allocator: Allocator) void {
        for (self.items) |*item| item.deinit(allocator);
        allocator.free(self.items);
    }
};

const HighlightLanguageHandle = struct {
    language: *const TSLanguage,

    fn deinit(_: *HighlightLanguageHandle) void {}
};

const TreeSitterRuntime = struct {
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
        _ = self;
    }
};

pub fn collectSpans(
    allocator: Allocator,
    io: std.Io,
    languages: []const utils.highlight.Language,
    language_name: []const u8,
    content: []const u8,
    failure: *Failure,
) !std.ArrayList(Span) {
    failure.* = .none;
    var spans = std.ArrayList(Span).empty;
    errdefer spans.deinit(allocator);
    const configured = utils.highlight.findLanguage(languages, language_name) orelse return spans;
    if (content.len > std.math.maxInt(u32)) return spans;

    var runtime = try loadTreeSitterRuntime();
    defer runtime.deinit();

    var handle = try loadTreeSitterLanguage(configured);
    defer handle.deinit();

    var query_source = loadHighlightQuerySource(allocator, io, configured) catch |err| {
        failure.* = .{ .query_read = .{ .path = configured.query, .cause = err } };
        return err;
    };
    defer query_source.deinit(allocator);

    const parser = runtime.parser_new() orelse return error.TreeSitterParserCreateFailed;
    defer runtime.parser_delete(parser);
    if (!runtime.parser_set_language(parser, handle.language)) return error.TreeSitterLanguageRejected;
    const tree = runtime.parser_parse_string(parser, null, @ptrCast(content.ptr), @intCast(content.len)) orelse return error.TreeSitterParseFailed;
    defer runtime.tree_delete(tree);

    var query_error_offset: u32 = 0;
    var query_error_type: TSQueryError = .none;
    const query = runtime.query_new(handle.language, @ptrCast(query_source.text.ptr), @intCast(query_source.text.len), &query_error_offset, &query_error_type) orelse {
        failure.* = .{ .query_invalid = .{
            .path = configured.query,
            .offset = query_error_offset,
            .error_type = query_error_type,
        } };
        return error.TreeSitterQueryFailed;
    };
    defer runtime.query_delete(query);

    const cursor = runtime.query_cursor_new() orelse return error.TreeSitterQueryCursorCreateFailed;
    defer runtime.query_cursor_delete(cursor);
    runtime.query_cursor_exec(cursor, query, runtime.tree_root_node(tree));

    var match = std.mem.zeroes(TSQueryMatch);
    var capture_index: u32 = 0;
    while (runtime.query_cursor_next_capture(cursor, &match, &capture_index)) {
        if (capture_index >= match.capture_count) continue;
        const capture = match.captures[capture_index];
        var capture_name_len: u32 = 0;
        const capture_name_ptr = runtime.query_capture_name_for_id(query, capture.index, &capture_name_len) orelse continue;
        const capture_name = @as([*]const u8, @ptrCast(capture_name_ptr))[0..capture_name_len];
        const role = utils.highlight.roleForCapture(capture_name) orelse continue;
        const start: usize = runtime.node_start_byte(capture.node);
        const end: usize = runtime.node_end_byte(capture.node);
        if (start >= end or end > content.len) continue;
        try spans.append(allocator, .{ .start = start, .end = end, .role = role });
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

pub fn roleAt(spans: []const Span, start: usize, end: usize) ?utils.highlight.CaptureRole {
    var best: ?Span = null;
    for (spans) |span| {
        if (span.start > start or span.end < end) continue;
        if (best == null or spanMoreSpecific(span, best.?)) best = span;
    }
    return if (best) |span| span.role else null;
}

pub fn treeSitterHealthReport(
    allocator: Allocator,
    io: std.Io,
    languages: []const utils.highlight.Language,
) !TreeSitterHealthReport {
    var items = std.ArrayList(TreeSitterHealthItem).empty;
    errdefer {
        for (items.items) |*item| item.deinit(allocator);
        items.deinit(allocator);
    }

    var failures: usize = 0;
    var warnings: usize = 0;
    for (languages) |language| {
        var item = try checkTreeSitterLanguageHealth(allocator, io, language);
        const status = item.status;
        items.append(allocator, item) catch |err| {
            item.deinit(allocator);
            return err;
        };
        switch (status) {
            .ok => {},
            .warning => warnings += 1,
            .fail => failures += 1,
        }
    }

    return .{
        .configured_languages = languages.len,
        .failures = failures,
        .warnings = warnings,
        .items = try items.toOwnedSlice(allocator),
    };
}

fn checkTreeSitterLanguageHealth(
    allocator: Allocator,
    io: std.Io,
    language: utils.highlight.Language,
) !TreeSitterHealthItem {
    var runtime = loadTreeSitterRuntime() catch |err| {
        var reason_buf: [256]u8 = undefined;
        return makeTreeSitterHealthItem(allocator, language, .fail, 0, 0, "runtime unavailable: {s}", .{utils.err.formatErrorReason(&reason_buf, err)});
    };
    defer runtime.deinit();

    var handle = loadTreeSitterLanguage(&language) catch |err| {
        var reason_buf: [256]u8 = undefined;
        return makeTreeSitterHealthItem(allocator, language, .fail, 0, 0, "language load failed: {s}", .{utils.err.formatErrorReason(&reason_buf, err)});
    };
    defer handle.deinit();

    var query_source = loadHighlightQuerySource(allocator, io, &language) catch |err| {
        var reason_buf: [256]u8 = undefined;
        return makeTreeSitterHealthItem(allocator, language, .fail, 0, 0, "query load failed: {s}", .{utils.err.formatErrorReason(&reason_buf, err)});
    };
    defer query_source.deinit(allocator);
    if (query_source.text.len == 0) {
        return makeTreeSitterHealthItem(allocator, language, .fail, 0, 0, "query source is empty", .{});
    }

    const parser = runtime.parser_new() orelse {
        return makeTreeSitterHealthItem(allocator, language, .fail, 0, 0, "parser creation failed", .{});
    };
    defer runtime.parser_delete(parser);
    if (!runtime.parser_set_language(parser, handle.language)) {
        return makeTreeSitterLanguageRejectedHealthItem(allocator, language);
    }

    const sample = treeSitterHealthSample(language.parser);
    const tree = runtime.parser_parse_string(parser, null, @ptrCast(sample.ptr), @intCast(sample.len)) orelse {
        return makeTreeSitterHealthItem(allocator, language, .fail, 0, 0, "sample parse failed", .{});
    };
    defer runtime.tree_delete(tree);

    var query_error_offset: u32 = 0;
    var query_error_type: TSQueryError = .none;
    const query = runtime.query_new(handle.language, @ptrCast(query_source.text.ptr), @intCast(query_source.text.len), &query_error_offset, &query_error_type) orelse {
        return makeTreeSitterHealthItem(
            allocator,
            language,
            .fail,
            0,
            0,
            "query compile failed at byte {d}: {s}",
            .{ query_error_offset, @tagName(query_error_type) },
        );
    };
    defer runtime.query_delete(query);

    const cursor = runtime.query_cursor_new() orelse {
        return makeTreeSitterHealthItem(allocator, language, .fail, 0, 0, "query cursor creation failed", .{});
    };
    defer runtime.query_cursor_delete(cursor);
    runtime.query_cursor_exec(cursor, query, runtime.tree_root_node(tree));

    var capture_count: usize = 0;
    var mapped_capture_count: usize = 0;
    var match = std.mem.zeroes(TSQueryMatch);
    var capture_index: u32 = 0;
    while (runtime.query_cursor_next_capture(cursor, &match, &capture_index)) {
        if (capture_index >= match.capture_count) continue;
        const capture = match.captures[capture_index];
        var capture_name_len: u32 = 0;
        const capture_name_ptr = runtime.query_capture_name_for_id(query, capture.index, &capture_name_len) orelse continue;
        const capture_name = @as([*]const u8, @ptrCast(capture_name_ptr))[0..capture_name_len];
        capture_count += 1;
        if (utils.highlight.roleForCapture(capture_name) != null) mapped_capture_count += 1;
    }

    if (capture_count == 0) {
        return makeTreeSitterHealthItem(allocator, language, .warning, capture_count, mapped_capture_count, "query compiled but sample produced no captures", .{});
    }
    if (mapped_capture_count == 0) {
        return makeTreeSitterHealthItem(allocator, language, .warning, capture_count, mapped_capture_count, "query captures do not map to ss highlight roles", .{});
    }
    return makeTreeSitterHealthItem(
        allocator,
        language,
        .ok,
        capture_count,
        mapped_capture_count,
        "parser/query ok; captures={d}, mapped={d}",
        .{ capture_count, mapped_capture_count },
    );
}

fn makeTreeSitterLanguageRejectedHealthItem(
    allocator: Allocator,
    language: utils.highlight.Language,
) !TreeSitterHealthItem {
    if (builtinTreeSitterLanguage(language.parser) != null) {
        return makeTreeSitterHealthItem(
            allocator,
            language,
            .fail,
            0,
            0,
            "parser rejected language; tree-sitter runtime accepts ABI range {d}..{d}",
            .{ tree_sitter_min_compatible_language_version, tree_sitter_language_version },
        );
    }
    return makeTreeSitterHealthItem(
        allocator,
        language,
        .fail,
        0,
        0,
        "parser rejected language",
        .{},
    );
}

fn makeTreeSitterHealthItem(
    allocator: Allocator,
    language: utils.highlight.Language,
    status: TreeSitterHealthStatus,
    capture_count: usize,
    mapped_capture_count: usize,
    comptime fmt: []const u8,
    args: anytype,
) !TreeSitterHealthItem {
    const name = try allocator.dupe(u8, language.name);
    errdefer allocator.free(name);
    const parser = try allocator.dupe(u8, language.parser);
    errdefer allocator.free(parser);
    const query = try allocator.dupe(u8, language.query);
    errdefer allocator.free(query);
    const detail = try std.fmt.allocPrint(allocator, fmt, args);
    return .{
        .name = name,
        .parser = parser,
        .query = query,
        .status = status,
        .detail = detail,
        .capture_count = capture_count,
        .mapped_capture_count = mapped_capture_count,
    };
}

fn treeSitterHealthSample(parser: []const u8) []const u8 {
    const definition = findLanguageDefinition(parser) orelse return "value\n";
    return definition.health_sample;
}

const LoadedHighlightQuery = struct {
    text: []const u8,
    owned: bool = false,

    fn deinit(self: *LoadedHighlightQuery, allocator: Allocator) void {
        if (self.owned) allocator.free(self.text);
    }
};

fn loadHighlightQuerySource(allocator: Allocator, io: std.Io, configured: *const utils.highlight.Language) !LoadedHighlightQuery {
    if (builtinHighlightQuery(configured.query)) |query| return .{ .text = query };
    return .{
        .text = try std.Io.Dir.cwd().readFileAlloc(io, configured.query, allocator, .limited(query_read_limit)),
        .owned = true,
    };
}

fn builtinHighlightQuery(query: []const u8) ?[]const u8 {
    for (language_definitions) |definition| {
        if (std.mem.eql(u8, query, definition.query_name)) return definition.query_source;
    }
    return null;
}

fn loadTreeSitterLanguage(configured: *const utils.highlight.Language) !HighlightLanguageHandle {
    if (builtinTreeSitterLanguage(configured.parser)) |language| {
        return .{ .language = language };
    }
    return error.UnknownTreeSitterLanguage;
}

fn builtinTreeSitterLanguage(parser: []const u8) ?*const TSLanguage {
    const definition = findLanguageDefinition(parser) orelse return null;
    return definition.load();
}

fn findLanguageDefinition(parser: []const u8) ?*const LanguageDefinition {
    const canonical = utils.highlight.canonicalParserName(parser) orelse return null;
    for (&language_definitions) |*definition| {
        if (std.mem.eql(u8, canonical, definition.parser_name)) return definition;
    }
    return null;
}

fn loadTreeSitterRuntime() !TreeSitterRuntime {
    return .{
        .parser_new = ts_parser_new,
        .parser_delete = ts_parser_delete,
        .parser_set_language = ts_parser_set_language,
        .parser_parse_string = ts_parser_parse_string,
        .tree_delete = ts_tree_delete,
        .tree_root_node = ts_tree_root_node,
        .query_new = ts_query_new,
        .query_delete = ts_query_delete,
        .query_capture_name_for_id = ts_query_capture_name_for_id,
        .query_cursor_new = ts_query_cursor_new,
        .query_cursor_delete = ts_query_cursor_delete,
        .query_cursor_exec = ts_query_cursor_exec,
        .query_cursor_next_capture = ts_query_cursor_next_capture,
        .node_start_byte = ts_node_start_byte,
        .node_end_byte = ts_node_end_byte,
    };
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
