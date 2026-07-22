const std = @import("std");
const assets = @import("fontawesome_assets");

pub const collection = assets.collection;
pub const version = assets.version;
pub const cache_namespace = collection ++ "-" ++ version;
pub const Category = assets.Category;
pub const categories: []const Category = assets.categories;

pub const Style = enum {
    solid,
    regular,
    brands,
};

pub const Spec = struct {
    style: Style,
    name: []const u8,
};

pub const Symbol = struct {
    style: Style,
    name: []const u8,
    view_box: []const u8,
    body: []const u8,
};

pub const Iterator = struct {
    style: Style,
    source: []const u8,
    cursor: usize = 0,

    pub fn init(style: Style) Iterator {
        return .{ .style = style, .source = sprite(style) };
    }

    pub fn next(self: *Iterator) ?Symbol {
        const symbol_marker = "<symbol id=\"";
        const symbol_start = std.mem.indexOfPos(u8, self.source, self.cursor, symbol_marker) orelse return null;
        const name_start = symbol_start + symbol_marker.len;
        const name_end = std.mem.indexOfScalarPos(u8, self.source, name_start, '"') orelse return null;
        const opening_end = std.mem.indexOfScalarPos(u8, self.source, name_end + 1, '>') orelse return null;
        const symbol_end_marker = "</symbol>";
        const symbol_end = std.mem.indexOfPos(u8, self.source, opening_end + 1, symbol_end_marker) orelse return null;
        self.cursor = symbol_end + symbol_end_marker.len;

        const opening = self.source[symbol_start .. opening_end + 1];
        const view_box_marker = "viewBox=\"";
        const view_box_start_rel = std.mem.indexOf(u8, opening, view_box_marker) orelse return self.next();
        const view_box_start = view_box_start_rel + view_box_marker.len;
        const view_box_end = std.mem.indexOfScalarPos(u8, opening, view_box_start, '"') orelse return self.next();
        const name = self.source[name_start..name_end];
        if (!validName(name)) return self.next();
        return .{
            .style = self.style,
            .name = name,
            .view_box = opening[view_box_start..view_box_end],
            .body = self.source[opening_end + 1 .. symbol_end],
        };
    }
};

pub fn parseSource(source: []const u8) ?Spec {
    const variants = [_]struct { prefix: []const u8, style: Style }{
        .{ .prefix = "fa:", .style = .solid },
        .{ .prefix = "fas:", .style = .solid },
        .{ .prefix = "far:", .style = .regular },
        .{ .prefix = "fab:", .style = .brands },
        .{ .prefix = "fa-solid:", .style = .solid },
        .{ .prefix = "fa-regular:", .style = .regular },
        .{ .prefix = "fa-brands:", .style = .brands },
    };
    for (variants) |variant| {
        if (!std.mem.startsWith(u8, source, variant.prefix)) continue;
        const name = source[variant.prefix.len..];
        if (!validName(name)) return null;
        return .{ .style = variant.style, .name = name };
    }
    return null;
}

pub fn canonicalSource(allocator: std.mem.Allocator, spec: Spec) ![]u8 {
    return std.fmt.allocPrint(allocator, "fa-{s}:{s}", .{ @tagName(spec.style), spec.name });
}

pub fn find(spec: Spec) ?Symbol {
    var iterator = Iterator.init(spec.style);
    while (iterator.next()) |symbol| {
        if (std.mem.eql(u8, symbol.name, spec.name)) return symbol;
    }
    return null;
}

pub fn contains(spec: Spec) bool {
    return find(spec) != null;
}

pub fn extractSvg(allocator: std.mem.Allocator, spec: Spec) ![]u8 {
    const symbol = find(spec) orelse return error.InvalidFontAwesomeIcon;
    return svgForSymbol(allocator, symbol);
}

pub fn svgForSymbol(allocator: std.mem.Allocator, symbol: Symbol) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"{s}\">{s}</svg>",
        .{ symbol.view_box, symbol.body },
    );
}

pub fn count(style: Style) usize {
    var total: usize = 0;
    var iterator = Iterator.init(style);
    while (iterator.next() != null) total += 1;
    return total;
}

pub fn totalCount() usize {
    return count(.solid) + count(.regular) + count(.brands);
}

fn sprite(style: Style) []const u8 {
    return switch (style) {
        .solid => assets.solid,
        .regular => assets.regular,
        .brands => assets.brands,
    };
}

fn validName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |byte| {
        if (!(std.ascii.isAlphanumeric(byte) or byte == '-')) return false;
    }
    return true;
}
