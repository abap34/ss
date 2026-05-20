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
