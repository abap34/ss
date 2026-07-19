const std = @import("std");
const font_model = @import("../../core/font.zig");

const c = @cImport({
    @cInclude("backend.h");
});

pub const Decoration = struct {
    strikethrough: bool = false,
    underline: bool = false,
    underline_opacity: f32 = 1,
    underline_width: ?f32 = null,
    underline_offset: f32 = 0,
};

pub const Bounds = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,

    fn unioned(self: Bounds, other: Bounds) Bounds {
        const left = @min(self.x, other.x);
        const top = @min(self.y, other.y);
        const right = @max(self.x + self.width, other.x + other.width);
        const bottom = @max(self.y + self.height, other.y + other.height);
        return .{ .x = left, .y = top, .width = right - left, .height = bottom - top };
    }
};

pub const LayoutMeasurement = struct {
    logical_bounds: Bounds,
    ink_bounds: Bounds,
    first_baseline: f32,
    decoration_bounds: ?Bounds = null,
};

pub const LineMetrics = struct {
    ascent: f32,
    descent: f32,
};

pub fn advanceWidth(allocator: std.mem.Allocator, text: []const u8, font: font_model.Face, font_size: f32) !f32 {
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

pub fn visualWidth(allocator: std.mem.Allocator, text: []const u8, font: font_model.Face, font_size: f32) !f32 {
    if (text.len == 0) return 0;
    const family_z = try allocator.dupeZ(u8, font.family);
    defer allocator.free(family_z);
    const text_z = try allocator.dupeZ(u8, text);
    defer allocator.free(text_z);
    return @floatCast(c.ss_text_measure_text_visual_width(
        text_z.ptr,
        family_z.ptr,
        @intCast(font.weight),
        font_model.styleCode(font.style),
        font_model.stretchCode(font.stretch),
        font_size,
    ));
}

pub fn layout(
    allocator: std.mem.Allocator,
    text: []const u8,
    font: font_model.Face,
    font_size: f32,
    width: f32,
    wrap: bool,
    decoration: Decoration,
) !LayoutMeasurement {
    const family_z = try allocator.dupeZ(u8, font.family);
    defer allocator.free(family_z);
    const text_z = try allocator.dupeZ(u8, text);
    defer allocator.free(text_z);
    if (!decoration.strikethrough and !decoration.underline) {
        var measurement = std.mem.zeroes(c.SsTextMeasurement);
        if (c.ss_text_measure_layout(
            text_z.ptr,
            family_z.ptr,
            @intCast(font.weight),
            font_model.styleCode(font.style),
            font_model.stretchCode(font.stretch),
            font_size,
            width,
            @intFromBool(wrap),
            &measurement,
        ) != 0) return error.PangoCreateFailed;
        return .{
            .logical_bounds = nativeBounds(measurement.logical_bounds),
            .ink_bounds = nativeBounds(measurement.ink_bounds),
            .first_baseline = @floatCast(measurement.first_baseline),
        };
    }

    var shape = std.mem.zeroes(c.SsTextShape);
    if (c.ss_text_shape(
        text_z.ptr,
        family_z.ptr,
        @intCast(font.weight),
        font_model.styleCode(font.style),
        font_model.stretchCode(font.stretch),
        font_size,
        width,
        @intFromBool(wrap),
        &shape,
    ) != 0) return error.PangoCreateFailed;
    defer c.ss_text_shape_free(&shape);

    var decoration_bounds: ?Bounds = null;
    for (shape.runs[0..shape.run_count]) |run| {
        if (decoration.strikethrough) appendDecorationBounds(
            &decoration_bounds,
            run.x,
            run.baseline_y,
            run.advance,
            run.strikethrough_position,
            run.strikethrough_thickness,
            null,
            0,
        );
        if (decoration.underline and decoration.underline_opacity > 0) appendDecorationBounds(
            &decoration_bounds,
            run.x,
            run.baseline_y,
            run.advance,
            run.underline_position,
            run.underline_thickness,
            decoration.underline_width,
            decoration.underline_offset,
        );
    }
    return .{
        .logical_bounds = nativeBounds(shape.logical_bounds),
        .ink_bounds = nativeBounds(shape.ink_bounds),
        .first_baseline = if (shape.line_count == 0) 0 else @floatCast(shape.lines[0].baseline_y),
        .decoration_bounds = decoration_bounds,
    };
}

pub fn lineMetrics(allocator: std.mem.Allocator, font: font_model.Face, font_size: f32) !LineMetrics {
    const measurement = try layout(allocator, "M", font, font_size, 0, false, .{});
    const logical_bottom = measurement.logical_bounds.y + measurement.logical_bounds.height;
    const ascent = measurement.first_baseline - measurement.logical_bounds.y;
    const descent = logical_bottom - measurement.first_baseline;
    if (!std.math.isFinite(ascent) or !std.math.isFinite(descent) or ascent <= 0 or descent < 0 or ascent + descent <= 0) {
        return error.PangoCreateFailed;
    }
    return .{ .ascent = ascent, .descent = descent };
}

fn appendDecorationBounds(
    current: *?Bounds,
    x: f64,
    baseline_y: f64,
    advance: f64,
    position: f64,
    native_thickness: f64,
    width: ?f32,
    offset: f32,
) void {
    const thickness = width orelse @as(f32, @floatCast(native_thickness));
    if (!(advance > 0) or !(thickness > 0)) return;
    const native_center_y = baseline_y - position + native_thickness / 2;
    const thickness_f64: f64 = thickness;
    const offset_f64: f64 = offset;
    const value = Bounds{
        .x = @floatCast(x),
        .y = @floatCast(native_center_y + offset_f64 - thickness_f64 / 2),
        .width = @floatCast(advance),
        .height = thickness,
    };
    current.* = if (current.*) |bounds| bounds.unioned(value) else value;
}

fn nativeBounds(value: c.SsPdfInkExtents) Bounds {
    return .{
        .x = @floatCast(value.x),
        .y = @floatCast(value.y),
        .width = @floatCast(value.width),
        .height = @floatCast(value.height),
    };
}
