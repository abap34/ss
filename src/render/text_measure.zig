const std = @import("std");

const c = @cImport({
    @cInclude("pdf.h");
});

pub fn width(allocator: std.mem.Allocator, text: []const u8, font_name: []const u8, font_size: f32) !f32 {
    if (text.len == 0) return 0;
    const font_spec = try fontSpec(allocator, font_name, font_size);
    defer allocator.free(font_spec);
    const text_z = try allocator.dupeZ(u8, text);
    defer allocator.free(text_z);
    return @floatCast(c.ss_text_measure_text(text_z.ptr, font_spec.ptr, font_size));
}

pub fn fontSpec(allocator: std.mem.Allocator, font_name: []const u8, font_size: f32) ![:0]u8 {
    const trimmed = std.mem.trim(u8, font_name, " \t\r\n");
    const family = if (trimmed.len == 0) "sans-serif" else trimmed;
    const text = try std.fmt.allocPrint(allocator, "{s} {d}", .{ family, font_size });
    defer allocator.free(text);
    return try allocator.dupeZ(u8, text);
}
