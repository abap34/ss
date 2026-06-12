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
        \\inlay_hints = true
        \\
        \\[editor.lsp.inlay_hints]
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

    try testing.expectEqual(@as(u64, 25), cfg.lsp.change_debounce_ms);
    try testing.expect(!cfg.lsp.diagnostics);
    try testing.expect(cfg.lsp.inlay_hints);
    try testing.expect(!cfg.lsp.inlay_hint_arguments);
    try testing.expect(!cfg.lsp.inlay_hint_positions);
    try testing.expectEqual(@as(u64, 50), cfg.preview.debounce_ms);
    try testing.expectEqual(project.PreviewOpenMode.external, cfg.preview.open_mode);
    try testing.expect(!cfg.preview.refresh_on_edit);
    try testing.expect(!cfg.page_guide.enabled);
    try testing.expect(!cfg.page_guide.gutter_icon);
}
