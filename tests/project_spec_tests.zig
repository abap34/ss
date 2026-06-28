const std = @import("std");
const project = @import("project");
const utils = @import("utils");

const testing = std.testing;

test "project spec: entry is required in the project table" {
    try testing.expectError(error.MissingProjectEntry, project.parseSource(testing.allocator, "/tmp/ss-project-spec/ss.toml",
        \\[project]
        \\asset_base_dir = "."
        \\
    ));
}

test "project spec: entry resolves relative to ss.toml and asset base defaults to entry parent" {
    var cfg = try project.parseSource(testing.allocator, "/tmp/ss-project-spec/deck/ss.toml",
        \\[project]
        \\entry = "slides/main.ss"
        \\
    );
    defer cfg.deinit(testing.allocator);

    try testing.expectEqualStrings("/tmp/ss-project-spec/deck/ss.toml", cfg.path);
    try testing.expectEqualStrings("/tmp/ss-project-spec/deck", cfg.dir);
    try testing.expectEqualStrings("/tmp/ss-project-spec/deck/slides/main.ss", cfg.entry);
    try testing.expectEqualStrings("/tmp/ss-project-spec/deck/slides", cfg.asset_base_dir);
}

test "project spec: explicit asset_base_dir resolves relative to ss.toml" {
    var cfg = try project.parseSource(testing.allocator, "/tmp/ss-project-spec/deck/ss.toml",
        \\[other]
        \\entry = "ignored.ss"
        \\
        \\[project]
        \\entry = "slides/main.ss"
        \\asset_base_dir = "assets"
        \\
    );
    defer cfg.deinit(testing.allocator);

    try testing.expectEqualStrings("/tmp/ss-project-spec/deck/slides/main.ss", cfg.entry);
    try testing.expectEqualStrings("/tmp/ss-project-spec/deck/assets", cfg.asset_base_dir);
}

test "project spec: editor settings parse from ss.toml" {
    var cfg = try project.parseSource(testing.allocator, "/tmp/ss-project-spec/deck/ss.toml",
        \\[project]
        \\entry = "slides/main.ss"
        \\
        \\[editor.lsp]
        \\debounce = 25
        \\diagnostics = false
        \\
        \\[editor.lsp.inlay_hints]
        \\enabled = true
        \\arguments = false
        \\positions = false
        \\
        \\[editor.preview]
        \\debounce = 50
        \\open = "external"
        \\
        \\[editor.preview.refresh]
        \\save = false
        \\
        \\[editor.page_guide]
        \\enabled = false
        \\gutter_icon = false
        \\
    );
    defer cfg.deinit(testing.allocator);

    try testing.expect(!cfg.lsp.diagnostics);
    try testing.expectEqual(@as(u64, 25), cfg.lsp.debounce_ms);
    try testing.expect(cfg.lsp.inlay_hints);
    try testing.expect(!cfg.lsp.inlay_hint_arguments);
    try testing.expect(!cfg.lsp.inlay_hint_positions);
    try testing.expectEqual(@as(u64, 50), cfg.preview.debounce_ms);
    try testing.expectEqual(project.PreviewOpenMode.external, cfg.preview.open_mode);
    try testing.expect(!cfg.preview.refresh_on_save);
    try testing.expect(!cfg.page_guide.enabled);
    try testing.expect(!cfg.page_guide.gutter_icon);
}

test "project spec: highlight languages parse from ss.toml" {
    var cfg = try project.parseSource(testing.allocator, "/tmp/ss-project-spec/deck/ss.toml",
        \\[project]
        \\entry = "slides/main.ss"
        \\
        \\[highlight.languages.python-snippet]
        \\parser = "python"
        \\query = "queries/python/highlights.scm"
        \\
    );
    defer cfg.deinit(testing.allocator);

    try testing.expect(cfg.highlight.languages.len >= utils.highlight.builtin_languages.len);
    const ss = findHighlightLanguage(cfg.highlight.languages, "ss").?;
    try testing.expectEqualStrings("ss", ss.parser);
    try testing.expectEqualStrings("builtin:ss", ss.query);
    const python_snippet = findHighlightLanguage(cfg.highlight.languages, "python-snippet").?;
    try testing.expectEqualStrings("python", python_snippet.parser);
    try testing.expectEqualStrings("/tmp/ss-project-spec/deck/queries/python/highlights.scm", python_snippet.query);
}

test "project spec: highlight config rejects bundled language redefinition" {
    try testing.expectError(error.BuiltinHighlightLanguageReserved, project.parseSource(testing.allocator, "/tmp/ss-project-spec/deck/ss.toml",
        \\[project]
        \\entry = "slides/main.ss"
        \\
        \\[highlight.languages.python]
        \\parser = "python"
        \\query = "builtin:python"
        \\
    ));
}

test "project spec: highlight config rejects unknown language fields" {
    const source =
        \\[project]
        \\entry = "slides/main.ss"
        \\
        \\[highlight.languages.python-snippet]
        \\parser = "python"
        \\query = "builtin:python"
        \\library = "parsers/libtree-sitter-python.dylib"
        \\
    ;
    try testing.expectError(error.UnknownHighlightLanguageField, project.parseSource(testing.allocator, "/tmp/ss-project-spec/deck/ss.toml", source));
    try expectConfigSpanText(source, error.UnknownHighlightLanguageField, "library = \"parsers/libtree-sitter-python.dylib\"");
}

test "project spec: config error spans locate highlight section failures" {
    const unknown_parser =
        \\[project]
        \\entry = "slides/main.ss"
        \\
        \\[highlight.languages.python-snippet]
        \\parser = "python3"
        \\query = "builtin:python"
        \\
    ;
    try testing.expectError(error.UnknownHighlightParser, project.parseSource(testing.allocator, "/tmp/ss-project-spec/deck/ss.toml", unknown_parser));
    try expectConfigSpanText(unknown_parser, error.UnknownHighlightParser, "parser = \"python3\"");

    const missing_query =
        \\[project]
        \\entry = "slides/main.ss"
        \\
        \\[highlight.languages.python-snippet]
        \\parser = "python"
        \\
    ;
    try testing.expectError(error.MissingHighlightQuery, project.parseSource(testing.allocator, "/tmp/ss-project-spec/deck/ss.toml", missing_query));
    try expectConfigSpanText(missing_query, error.MissingHighlightQuery, "[highlight.languages.python-snippet]");

    const duplicate =
        \\[project]
        \\entry = "slides/main.ss"
        \\
        \\[highlight.languages.python-snippet]
        \\parser = "python"
        \\query = "builtin:python"
        \\
        \\[highlight.languages.PYTHON-SNIPPET]
        \\parser = "python"
        \\query = "builtin:python"
        \\
    ;
    try testing.expectError(error.DuplicateHighlightLanguage, project.parseSource(testing.allocator, "/tmp/ss-project-spec/deck/ss.toml", duplicate));
    try expectConfigSpanText(duplicate, error.DuplicateHighlightLanguage, "[highlight.languages.PYTHON-SNIPPET]");
}

test "project spec: tree-sitter capture names map to code paint roles" {
    const cases = [_]struct {
        capture: []const u8,
        role: utils.highlight.CaptureRole,
    }{
        .{ .capture = "keyword", .role = .keyword },
        .{ .capture = "keyword.operator", .role = .operator },
        .{ .capture = "keyword.import", .role = .keyword },
        .{ .capture = "cImport", .role = .function },
        .{ .capture = "function.call", .role = .function },
        .{ .capture = "function.method", .role = .function },
        .{ .capture = "function.macro", .role = .function },
        .{ .capture = "constructor", .role = .type },
        .{ .capture = "type.builtin", .role = .type },
        .{ .capture = "namespace", .role = .type },
        .{ .capture = "module", .role = .type },
        .{ .capture = "tag", .role = .type },
        .{ .capture = "constant.builtin", .role = .constant },
        .{ .capture = "boolean", .role = .constant },
        .{ .capture = "attribute", .role = .constant },
        .{ .capture = "label", .role = .constant },
        .{ .capture = "number.float", .role = .number },
        .{ .capture = "variable.parameter", .role = .variable },
        .{ .capture = "variable.member", .role = .variable },
        .{ .capture = "property", .role = .variable },
        .{ .capture = "punctuation.bracket", .role = .operator },
        .{ .capture = "punctuation.delimiter", .role = .operator },
        .{ .capture = "delimiter", .role = .operator },
        .{ .capture = "_pipe", .role = .operator },
        .{ .capture = "comment.documentation", .role = .comment },
        .{ .capture = "string.special", .role = .string },
        .{ .capture = "string.escape", .role = .string },
        .{ .capture = "escape", .role = .string },
        .{ .capture = "character", .role = .string },
    };
    for (cases) |case| {
        try testing.expectEqual(case.role, utils.highlight.roleForCapture(case.capture).?);
    }
}

test "project spec: bundled highlight queries use mapped capture names" {
    const query_paths = [_][]const u8{
        "editor/tree-sitter-ss/queries/highlights.scm",
        "third_party/tree-sitter-languages/bash/queries/highlights.scm",
        "third_party/tree-sitter-languages/c/queries/highlights.scm",
        "third_party/tree-sitter-languages/cpp/queries/highlights.scm",
        "third_party/tree-sitter-languages/css/queries/highlights.scm",
        "third_party/tree-sitter-languages/go/queries/highlights.scm",
        "third_party/tree-sitter-languages/html/queries/highlights.scm",
        "third_party/tree-sitter-languages/java/queries/highlights.scm",
        "third_party/tree-sitter-languages/javascript/queries/highlights.scm",
        "third_party/tree-sitter-languages/json/queries/highlights.scm",
        "third_party/tree-sitter-languages/julia/queries/highlights.scm",
        "third_party/tree-sitter-languages/python/queries/highlights.scm",
        "third_party/tree-sitter-languages/rust/queries/highlights.scm",
        "third_party/tree-sitter-languages/toml/queries/highlights.scm",
        "third_party/tree-sitter-languages/typescript/queries/highlights.scm",
        "third_party/tree-sitter-languages/yaml/queries/highlights.scm",
        "third_party/tree-sitter-languages/zig/queries/highlights.scm",
    };
    for (query_paths) |path| {
        try expectMappedHighlightCaptures(path);
    }
}

test "project spec: explicit input discovers ss.toml from input directory" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const allocator = testing.allocator;
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    defer allocator.free(root);
    const project_dir = try std.fs.path.join(allocator, &.{ root, "deck" });
    defer allocator.free(project_dir);
    const slide_dir = try std.fs.path.join(allocator, &.{ project_dir, "slides" });
    defer allocator.free(slide_dir);
    try std.Io.Dir.cwd().createDirPath(testing.io, slide_dir);

    const project_path = try std.fs.path.join(allocator, &.{ project_dir, "ss.toml" });
    defer allocator.free(project_path);
    try std.Io.Dir.cwd().writeFile(testing.io, .{
        .sub_path = project_path,
        .data =
        \\[project]
        \\entry = "ignored.ss"
        \\asset_base_dir = "assets"
        \\
        ,
        .flags = .{ .truncate = true },
    });

    const input_path = try std.fs.path.join(allocator, &.{ slide_dir, "main.ss" });
    defer allocator.free(input_path);
    try std.Io.Dir.cwd().writeFile(testing.io, .{
        .sub_path = input_path,
        .data = "page main\nend\n",
        .flags = .{ .truncate = true },
    });

    var resolved = try project.resolve(allocator, testing.io, input_path, null, null);
    defer resolved.deinit(allocator);

    const expected_input = try project.absolutePath(allocator, input_path);
    defer allocator.free(expected_input);
    const expected_project = try project.absolutePath(allocator, project_path);
    defer allocator.free(expected_project);
    const asset_base_path = try std.fs.path.join(allocator, &.{ project_dir, "assets" });
    defer allocator.free(asset_base_path);
    const expected_asset_base = try project.absolutePath(allocator, asset_base_path);
    defer allocator.free(expected_asset_base);

    try testing.expectEqualStrings(expected_input, resolved.entry_path);
    try testing.expectEqualStrings(expected_project, resolved.project_file.?);
    try testing.expectEqualStrings(expected_asset_base, resolved.asset_base_dir);
    try testing.expect(resolved.highlight.languages.len >= utils.highlight.builtin_languages.len);
    const ss = findHighlightLanguage(resolved.highlight.languages, "ss").?;
    try testing.expectEqualStrings("ss", ss.parser);
    try testing.expectEqualStrings("builtin:ss", ss.query);
    const julia = findHighlightLanguage(resolved.highlight.languages, "julia").?;
    try testing.expectEqualStrings("julia", julia.parser);
    try testing.expectEqualStrings("builtin:julia", julia.query);
    const jl = findHighlightLanguage(resolved.highlight.languages, "jl").?;
    try testing.expectEqualStrings("julia", jl.parser);
    try testing.expectEqualStrings("builtin:julia", jl.query);
}

fn findHighlightLanguage(languages: []const utils.highlight.Language, name: []const u8) ?*const utils.highlight.Language {
    for (languages) |*language| {
        if (std.ascii.eqlIgnoreCase(language.name, name)) return language;
    }
    return null;
}

fn expectConfigSpanText(source: []const u8, err: anyerror, expected: []const u8) !void {
    const span = project.configErrorSpan(source, err) orelse return error.MissingConfigErrorSpan;
    try testing.expectEqualStrings(expected, source[span.start..span.end]);
}

fn expectMappedHighlightCaptures(path: []const u8) !void {
    const source = try std.Io.Dir.cwd().readFileAlloc(testing.io, path, testing.allocator, .limited(256 * 1024));
    defer testing.allocator.free(source);

    var index: usize = 0;
    while (std.mem.indexOfScalarPos(u8, source, index, '@')) |at| {
        const start = at + 1;
        var end = start;
        while (end < source.len and isCaptureNameByte(source[end])) {
            end += 1;
        }
        index = end;
        if (start == end) continue;
        const capture = source[start..end];
        if (isIgnoredHighlightCapture(capture)) continue;
        if (utils.highlight.roleForCapture(capture) != null) continue;
        std.debug.print("unmapped tree-sitter highlight capture '{s}' in {s}\n", .{ capture, path });
        return error.UnmappedTreeSitterHighlightCapture;
    }
}

fn isCaptureNameByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '.';
}

fn isIgnoredHighlightCapture(capture: []const u8) bool {
    return std.mem.eql(u8, capture, "embedded") or std.mem.eql(u8, capture, "spell");
}
