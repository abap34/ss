const std = @import("std");
const core = @import("core");
const icons = @import("editor_icons");

test "bundled Font Awesome collection has the declared styles and counts" {
    try std.testing.expectEqual(core.fontawesome.solid_count, core.fontawesome.count(.solid));
    try std.testing.expectEqual(core.fontawesome.regular_count, core.fontawesome.count(.regular));
    try std.testing.expectEqual(core.fontawesome.brands_count, core.fontawesome.count(.brands));
    try std.testing.expectEqual(@as(usize, 2141), core.fontawesome.total_count);
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
    const result = try icons.catalogJson(allocator, "github", .brands);
    defer allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"collection\":\"fontawesome-free\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"version\":\"7.2.0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"id\":\"fa-brands:github\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "fa-solid:github") == null);
    try std.testing.expect(std.mem.indexOf(u8, result, "&lt;svg") == null);
    try std.testing.expect(std.mem.indexOf(u8, result, "<svg") != null);
}

test "featured icon catalog entries all exist in the selected style" {
    const allocator = std.testing.allocator;
    for (icons.featured_sources) |source| {
        const spec = core.fontawesome.parseSource(source) orelse return error.InvalidFeaturedIcon;
        try std.testing.expect(core.fontawesome.contains(spec));
    }
    inline for (.{ icons.Filter.all, icons.Filter.solid, icons.Filter.regular, icons.Filter.brands }) |filter| {
        const result = try icons.catalogJson(allocator, "", filter);
        defer allocator.free(result);
        try std.testing.expect(std.mem.indexOf(u8, result, "\"has_more\":false") != null);
        try std.testing.expect(std.mem.indexOf(u8, result, "\"icons\":[{") != null);
        if (filter != .all) {
            const marker = try std.fmt.allocPrint(allocator, "\"style\":\"{s}\"", .{@tagName(filter)});
            defer allocator.free(marker);
            try std.testing.expect(std.mem.indexOf(u8, result, marker) != null);
        }
    }
}
