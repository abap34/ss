const std = @import("std");
const core = @import("core");
const icons = @import("editor_icons");

test "bundled Font Awesome collection derives its styles and counts" {
    const solid_count = core.fontawesome.count(.solid);
    const regular_count = core.fontawesome.count(.regular);
    const brands_count = core.fontawesome.count(.brands);
    try std.testing.expect(solid_count > 0);
    try std.testing.expect(regular_count > 0);
    try std.testing.expect(brands_count > 0);
    try std.testing.expectEqual(
        solid_count + regular_count + brands_count,
        core.fontawesome.totalCount(),
    );
}

test "canonical and legacy identifiers resolve through the shared extractor" {
    const allocator = std.testing.allocator;
    const cases = [_]struct { source: []const u8, style: core.fontawesome.Style, name: []const u8 }{
        .{ .source = "fa-solid:star", .style = .solid, .name = "star" },
        .{ .source = "far:circle", .style = .regular, .name = "circle" },
        .{ .source = "fab:github", .style = .brands, .name = "github" },
    };
    for (cases) |case| {
        const spec = core.fontawesome.parseSource(case.source).?;
        try std.testing.expectEqual(case.style, spec.style);
        try std.testing.expectEqualStrings(case.name, spec.name);
        try std.testing.expect(core.fontawesome.contains(spec));
        const svg = try core.fontawesome.extractSvg(allocator, spec);
        defer allocator.free(svg);
        try std.testing.expect(std.mem.startsWith(u8, svg, "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\""));
        try std.testing.expect(std.mem.indexOf(u8, svg, "<path") != null);
    }
    try std.testing.expect(core.fontawesome.parseSource("fa-solid:../star") == null);
    try std.testing.expect(!core.fontawesome.contains(.{ .style = .solid, .name = "not-an-icon" }));
}

test "icon catalog searches names and filters styles" {
    const allocator = std.testing.allocator;
    const result = try icons.catalogJson(allocator, "github", .brands, "all", 0);
    defer allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"collection\":\"fontawesome-free\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"version\":\"7.2.0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"id\":\"fa-brands:github\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "fa-solid:github") == null);
    try std.testing.expect(std.mem.indexOf(u8, result, "&lt;svg") == null);
    try std.testing.expect(std.mem.indexOf(u8, result, "<svg") != null);
}

test "empty icon catalog is derived from every symbol in the selected style" {
    const allocator = std.testing.allocator;
    inline for (.{ icons.Filter.all, icons.Filter.solid, icons.Filter.regular, icons.Filter.brands }) |filter| {
        const result = try icons.catalogJson(allocator, "", filter, "all", 0);
        defer allocator.free(result);
        try std.testing.expect(std.mem.indexOf(u8, result, "\"offset\":0") != null);
        try std.testing.expect(std.mem.indexOf(u8, result, "\"has_more\":true") != null);
        try std.testing.expect(std.mem.indexOf(u8, result, "\"icons\":[{") != null);
        if (filter != .all) {
            const marker = try std.fmt.allocPrint(allocator, "\"style\":\"{s}\"", .{@tagName(filter)});
            defer allocator.free(marker);
            try std.testing.expect(std.mem.indexOf(u8, result, marker) != null);
        }
    }
}

test "icon catalog continues from the requested offset" {
    const allocator = std.testing.allocator;
    const result = try icons.catalogJson(allocator, "", .all, "all", 60);
    defer allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"offset\":60") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"has_more\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"icons\":[{") != null);
}

test "icon catalog derives semantic categories from official metadata" {
    const allocator = std.testing.allocator;
    const result = try icons.catalogJson(allocator, "", .solid, "animals", 0);
    defer allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"category\":\"animals\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"id\":\"animals\",\"label\":\"Animals\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"id\":\"fa-solid:cat\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"id\":\"fa-solid:dog\"") != null);
    try std.testing.expectError(
        error.InvalidCategory,
        icons.catalogJson(allocator, "", .all, "not-a-category", 0),
    );
}
