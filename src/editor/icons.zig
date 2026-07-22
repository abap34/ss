const std = @import("std");
const core = @import("core");
const utils = @import("utils");

const json = utils.json;
const query_length_limit = 128;
const category_length_limit = 64;
const catalog_page_size = 60;

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

pub fn parseFilter(text: []const u8) ?Filter {
    return std.meta.stringToEnum(Filter, text);
}

pub fn catalogJson(
    allocator: std.mem.Allocator,
    query_text: []const u8,
    filter: Filter,
    category_text: []const u8,
    offset: usize,
) ![]u8 {
    if (query_text.len > query_length_limit) return error.QueryTooLong;
    if (category_text.len > category_length_limit) return error.InvalidCategory;
    const query = try lowercase(allocator, std.mem.trim(u8, query_text, " \t\r\n"));
    defer allocator.free(query);
    const selected_category = if (std.mem.eql(u8, category_text, "all"))
        null
    else
        categoryById(category_text) orelse return error.InvalidCategory;

    var matches = std.ArrayList(Match).empty;
    defer matches.deinit(allocator);
    for (std.meta.tags(core.fontawesome.Style)) |style| {
        if (!includes(filter, style)) continue;
        var iterator = core.fontawesome.Iterator.init(style);
        while (iterator.next()) |symbol| {
            if (selected_category) |category| {
                if (!categoryContains(category, symbol.name)) continue;
            }
            const rank = if (query.len == 0) 0 else matchRank(symbol.name, query) orelse continue;
            try matches.append(allocator, .{ .symbol = symbol, .rank = rank });
        }
    }
    std.sort.heap(Match, matches.items, {}, lessThan);

    const start = @min(offset, matches.items.len);
    const end = @min(matches.items.len, start + catalog_page_size);
    var buffer = std.ArrayList(u8).empty;
    errdefer buffer.deinit(allocator);
    var root = try json.Object.beginBuffer(allocator, &buffer);
    try root.intField("schema", 1);
    try root.stringField("collection", core.fontawesome.collection);
    try root.stringField("version", core.fontawesome.version);
    try root.stringField("query", query_text);
    try root.stringField("style", @tagName(filter));
    try root.stringField("category", category_text);
    try root.intField("offset", start);
    try root.intField("total_available", core.fontawesome.totalCount());
    try root.intField("total_matches", matches.items.len);
    try root.boolField("has_more", end < matches.items.len);
    var category_items = try root.arrayField("categories");
    for (core.fontawesome.categories) |category| {
        var item = try category_items.objectItem();
        try item.stringField("id", category.id);
        try item.stringField("label", category.label);
        try item.end();
    }
    try category_items.end();
    var icons = try root.arrayField("icons");
    for (matches.items[start..end]) |match| {
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

fn categoryById(id: []const u8) ?*const core.fontawesome.Category {
    for (core.fontawesome.categories) |*category| {
        if (std.mem.eql(u8, category.id, id)) return category;
    }
    return null;
}

fn categoryContains(category: *const core.fontawesome.Category, name: []const u8) bool {
    for (category.icons) |icon_name| {
        if (std.mem.eql(u8, icon_name, name)) return true;
    }
    return false;
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
