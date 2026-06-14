const std = @import("std");
const font_model = @import("../core/font.zig");

const c = @cImport({
    @cInclude("pdf.h");
});

pub fn width(allocator: std.mem.Allocator, text: []const u8, font: font_model.Face, font_size: f32) !f32 {
    if (text.len == 0) return 0;
    const family_z = try allocator.dupeZ(u8, font.family);
    defer allocator.free(family_z);
    const text_z = try allocator.dupeZ(u8, text);
    defer allocator.free(text_z);
    return @floatCast(c.ss_text_measure_text(
        text_z.ptr,
        family_z.ptr,
        @intCast(font.weight),
        font_model.styleCode(font.style),
        font_model.stretchCode(font.stretch),
        font_size,
    ));
}
