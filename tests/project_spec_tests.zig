const std = @import("std");
const project = @import("project");

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
        \\edit = false
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
    try testing.expect(!cfg.preview.refresh_on_edit);
    try testing.expect(!cfg.page_guide.enabled);
    try testing.expect(!cfg.page_guide.gutter_icon);
}

test "project spec: highlight languages parse from ss.toml" {
    var cfg = try project.parseSource(testing.allocator, "/tmp/ss-project-spec/deck/ss.toml",
        \\[project]
        \\entry = "slides/main.ss"
        \\
        \\[highlight.languages.ss]
        \\parser = "ss"
        \\query = "builtin:ss"
        \\
        \\[highlight.languages.julia]
        \\parser = "julia"
        \\query = "queries/julia/highlights.scm"
        \\library = "parsers/libtree-sitter-julia.dylib"
        \\symbol = "tree_sitter_julia"
        \\
    );
    defer cfg.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), cfg.highlight.languages.len);
    try testing.expectEqualStrings("ss", cfg.highlight.languages[0].name);
    try testing.expectEqualStrings("ss", cfg.highlight.languages[0].parser);
    try testing.expectEqualStrings("builtin:ss", cfg.highlight.languages[0].query);
    try testing.expect(cfg.highlight.languages[0].library == null);
    try testing.expectEqualStrings("julia", cfg.highlight.languages[1].name);
    try testing.expectEqualStrings("/tmp/ss-project-spec/deck/queries/julia/highlights.scm", cfg.highlight.languages[1].query);
    try testing.expectEqualStrings("/tmp/ss-project-spec/deck/parsers/libtree-sitter-julia.dylib", cfg.highlight.languages[1].library.?);
    try testing.expectEqualStrings("tree_sitter_julia", cfg.highlight.languages[1].symbol.?);
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
        \\[highlight.languages.ss]
        \\parser = "ss"
        \\query = "builtin:ss"
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
    try testing.expectEqual(@as(usize, 1), resolved.highlight.languages.len);
    try testing.expectEqualStrings("ss", resolved.highlight.languages[0].name);
    try testing.expectEqualStrings("builtin:ss", resolved.highlight.languages[0].query);
}
