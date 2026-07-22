const std = @import("std");
const category_metadata = @import("metadata/categories.zig");

pub const collection = "fontawesome-free";
pub const solid = @embedFile("sprites/solid.svg");
pub const regular = @embedFile("sprites/regular.svg");
pub const brands = @embedFile("sprites/brands.svg");
pub const Category = category_metadata.Category;
pub const categories = category_metadata.categories;

pub const version = spriteVersion(solid);

comptime {
    if (!std.mem.eql(u8, version, spriteVersion(regular)) or
        !std.mem.eql(u8, version, spriteVersion(brands)))
    {
        @compileError("Font Awesome sprites must have the same version");
    }
    if (!std.mem.eql(u8, version, category_metadata.upstream_version)) {
        @compileError("Font Awesome sprites and category metadata must have the same version");
    }
}

fn spriteVersion(sprite: []const u8) []const u8 {
    const marker = "Font Awesome Free ";
    const start = (std.mem.indexOf(u8, sprite, marker) orelse
        @compileError("Font Awesome sprite version is missing")) + marker.len;
    const end = std.mem.indexOfScalarPos(u8, sprite, start, ' ') orelse
        @compileError("Font Awesome sprite version is malformed");
    return sprite[start..end];
}
