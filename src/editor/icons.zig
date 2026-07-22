const std = @import("std");
const core = @import("core");
const utils = @import("utils");

const json = utils.json;
const result_limit = 60;

pub const Filter = enum {
    all,
    solid,
    regular,
    brands,
};

const Match = struct {
    symbol: core.fontawesome.Symbol,
    rank: u8,
};

pub const featured_sources = [_][]const u8{
    "fa-solid:house",
    "fa-solid:user",
    "fa-solid:users",
    "fa-solid:star",
    "fa-solid:heart",
    "fa-solid:check",
    "fa-solid:xmark",
    "fa-solid:plus",
    "fa-solid:minus",
    "fa-solid:arrow-right",
    "fa-solid:arrow-left",
    "fa-solid:circle-info",
    "fa-solid:triangle-exclamation",
    "fa-solid:gear",
    "fa-solid:magnifying-glass",
    "fa-solid:envelope",
    "fa-solid:calendar",
    "fa-solid:clock",
    "fa-solid:location-dot",
    "fa-solid:phone",
    "fa-solid:download",
    "fa-solid:upload",
    "fa-solid:play",
    "fa-solid:pause",
    "fa-solid:trash",
    "fa-solid:pen",
    "fa-solid:image",
    "fa-solid:chart-bar",
    "fa-solid:table",
    "fa-solid:lightbulb",
    "fa-regular:star",
    "fa-regular:heart",
    "fa-regular:user",
    "fa-regular:clock",
    "fa-regular:calendar",
    "fa-regular:envelope",
    "fa-brands:github",
    "fa-brands:gitlab",
    "fa-brands:apple",
    "fa-brands:windows",
    "fa-brands:linux",
    "fa-brands:chrome",
    "fa-brands:firefox-browser",
    "fa-brands:python",
    "fa-brands:js",
    "fa-brands:react",
    "fa-brands:npm",
    "fa-brands:node-js",
    "fa-brands:linkedin",
    "fa-brands:x-twitter",
    "fa-brands:youtube",
    "fa-brands:instagram",
};

pub fn parseFilter(text: []const u8) ?Filter {
    return std.meta.stringToEnum(Filter, text);
}

pub fn catalogJson(
    allocator: std.mem.Allocator,
    query_text: []const u8,
    filter: Filter,
) ![]u8 {
    if (query_text.len > 128) return error.QueryTooLong;
    const query = try lowercase(allocator, std.mem.trim(u8, query_text, " \t\r\n"));
    defer allocator.free(query);

    var matches = std.ArrayList(Match).empty;
    defer matches.deinit(allocator);
    if (query.len == 0) {
        try appendFeatured(allocator, &matches, filter);
    } else {
        const styles = [_]core.fontawesome.Style{ .solid, .regular, .brands };
        for (styles) |style| {
            if (!includes(filter, style)) continue;
            var iterator = core.fontawesome.Iterator.init(style);
            while (iterator.next()) |symbol| {
                const rank = matchRank(symbol.name, query) orelse continue;
                try matches.append(allocator, .{ .symbol = symbol, .rank = rank });
            }
        }
        std.sort.heap(Match, matches.items, {}, lessThan);
    }

    const returned = @min(matches.items.len, result_limit);
    var buffer = std.ArrayList(u8).empty;
    errdefer buffer.deinit(allocator);
    var root = try json.Object.beginBuffer(allocator, &buffer);
    try root.intField("schema", 1);
    try root.stringField("collection", core.fontawesome.collection);
    try root.stringField("version", core.fontawesome.version);
    try root.stringField("query", query_text);
    try root.stringField("style", @tagName(filter));
    try root.intField("total_available", core.fontawesome.total_count);
    try root.intField("total_matches", matches.items.len);
    try root.boolField("has_more", matches.items.len > returned);
    var icons = try root.arrayField("icons");
    for (matches.items[0..returned]) |match| {
        const source = try core.fontawesome.canonicalSource(allocator, .{
            .style = match.symbol.style,
            .name = match.symbol.name,
        });
        defer allocator.free(source);
        const svg = try core.fontawesome.svgForSymbol(allocator, match.symbol);
        defer allocator.free(svg);
        var icon = try icons.objectItem();
        try icon.stringField("id", source);
        try icon.stringField("name", match.symbol.name);
        try icon.stringField("style", @tagName(match.symbol.style));
        try icon.stringField("svg", svg);
        try icon.end();
    }
    try icons.end();
    try root.end();
    return try buffer.toOwnedSlice(allocator);
}

fn appendFeatured(
    allocator: std.mem.Allocator,
    matches: *std.ArrayList(Match),
    filter: Filter,
) !void {
    for (featured_sources) |source| {
        const spec = core.fontawesome.parseSource(source) orelse continue;
        if (!includes(filter, spec.style)) continue;
        const symbol = core.fontawesome.find(spec) orelse continue;
        try matches.append(allocator, .{ .symbol = symbol, .rank = 0 });
    }
}

fn includes(filter: Filter, style: core.fontawesome.Style) bool {
    return filter == .all or std.mem.eql(u8, @tagName(filter), @tagName(style));
}

fn matchRank(name: []const u8, query: []const u8) ?u8 {
    var tokens = std.mem.tokenizeAny(u8, query, " \t\r\n-_:");
    var found_token = false;
    while (tokens.next()) |token| {
        found_token = true;
        if (std.mem.indexOf(u8, name, token) == null) return null;
    }
    if (!found_token) return null;
    if (std.mem.eql(u8, name, query)) return 0;
    if (std.mem.startsWith(u8, name, query)) return 1;
    return 2;
}

fn lessThan(_: void, left: Match, right: Match) bool {
    if (left.rank != right.rank) return left.rank < right.rank;
    const name_order = std.mem.order(u8, left.symbol.name, right.symbol.name);
    if (name_order != .eq) return name_order == .lt;
    return @intFromEnum(left.symbol.style) < @intFromEnum(right.symbol.style);
}

fn lowercase(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    const result = try allocator.alloc(u8, text.len);
    for (text, 0..) |byte, index| result[index] = std.ascii.toLower(byte);
    return result;
}
