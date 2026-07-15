const std = @import("std");
const core = @import("core");
const c = @import("pdf_ffi").c;
const render = @import("render");

const Allocator = std.mem.Allocator;

pub fn shape(
    allocator: Allocator,
    io: std.Io,
    resources: *render.ResourceBuilder,
    fonts: *render.FontBuilder,
    source: []const u8,
    requested_font: core.font.Face,
    font_size: f64,
    width: f64,
    wrap: bool,
) !render.TextLayout {
    const family_z = try allocator.dupeZ(u8, requested_font.family);
    defer allocator.free(family_z);
    const source_z = try allocator.dupeZ(u8, source);
    defer allocator.free(source_z);
    var native = std.mem.zeroes(c.SsTextShape);
    if (c.ss_text_shape(
        source_z.ptr,
        family_z.ptr,
        @intCast(requested_font.weight),
        core.font.styleCode(requested_font.style),
        core.font.stretchCode(requested_font.stretch),
        font_size,
        width,
        @intFromBool(wrap),
        &native,
    ) != 0) return error.PangoCreateFailed;
    defer c.ss_text_shape_free(&native);
    return try copy(allocator, io, resources, fonts, source, requested_font, font_size, native);
}

fn copy(
    allocator: Allocator,
    io: std.Io,
    resources: *render.ResourceBuilder,
    fonts: *render.FontBuilder,
    source: []const u8,
    requested_font: core.font.Face,
    font_size: f64,
    native: c.SsTextShape,
) !render.TextLayout {
    const owned_source = try allocator.dupeZ(u8, source);
    errdefer allocator.free(owned_source);
    const lines = try allocator.alloc(render.TextLine, native.line_count);
    errdefer allocator.free(lines);
    const runs = try allocator.alloc(render.TextRun, native.run_count);
    var initialized_runs: usize = 0;
    errdefer {
        for (runs[0..initialized_runs]) |*run| allocator.free(run.language);
        allocator.free(runs);
    }
    const glyphs = try allocator.alloc(render.Glyph, native.glyph_count);
    errdefer allocator.free(glyphs);
    const clusters = try allocator.alloc(render.TextCluster, native.cluster_count);
    errdefer allocator.free(clusters);

    for (native.lines[0..native.line_count], 0..) |line, index| lines[index] = .{
        .source = .{ .start = @intCast(line.source_start), .end = @intCast(line.source_end) },
        .run_range = .{ .start = @intCast(line.run_start), .end = @intCast(line.run_start + line.run_count) },
        .baseline_y = line.baseline_y,
        .logical_bounds = nativeRect(line.logical_bounds),
        .ink_bounds = nativeRect(line.ink_bounds),
    };
    for (native.runs[0..native.run_count], 0..) |run, index| {
        const family = std.mem.span(run.font_family);
        const postscript_name = std.mem.span(run.font_postscript_name);
        const font_path = std.mem.span(run.font_path);
        if (font_path.len == 0) return error.MissingFontResource;
        if (run.synthetic_bold != 0 or run.synthetic_italic != 0) return error.UnsupportedSyntheticFont;
        const font_resource = try resources.addPath(allocator, io, .font, font_path);
        const font_instance = try fonts.add(allocator, .{
            .resource = font_resource,
            .face_index = @intCast(run.font_index),
            .family = family,
            .postscript_name = postscript_name,
            .weight = @intCast(std.math.clamp(run.font_weight, 1, 1000)),
            .style = fontStyle(run.font_style),
            .stretch = fontStretch(run.font_stretch),
            .ascent_ratio = run.ascent / font_size,
            .descent_ratio = run.descent / font_size,
            .line_gap_ratio = run.line_gap / font_size,
            .synthetic_bold = false,
            .synthetic_italic = false,
            .family_substitution = !std.ascii.eqlIgnoreCase(std.mem.trim(u8, requested_font.family, " \t"), family),
        });
        const language = try allocator.dupeZ(u8, std.mem.span(run.language));
        errdefer allocator.free(language);
        runs[index] = .{
            .source = .{ .start = @intCast(run.source_start), .end = @intCast(run.source_end) },
            .glyph_range = .{ .start = @intCast(run.glyph_start), .end = @intCast(run.glyph_start + run.glyph_count) },
            .cluster_range = .{ .start = @intCast(run.cluster_start), .end = @intCast(run.cluster_start + run.cluster_count) },
            .x = run.x,
            .baseline_y = run.baseline_y,
            .advance = run.advance,
            .font_instance = font_instance,
            .language = language,
            .direction = if (run.bidi_level & 1 == 0) .left_to_right else .right_to_left,
            .bidi_level = run.bidi_level,
        };
        initialized_runs += 1;
    }
    for (native.glyphs[0..native.glyph_count], 0..) |glyph, index| glyphs[index] = .{
        .id = glyph.id,
        .offset_x = glyph.offset_x,
        .offset_y = glyph.offset_y,
        .advance_x = glyph.advance_x,
        .advance_y = glyph.advance_y,
    };
    for (native.clusters[0..native.cluster_count], 0..) |cluster, index| clusters[index] = .{
        .source = .{ .start = @intCast(cluster.source_start), .end = @intCast(cluster.source_end) },
        .glyph_range = .{ .start = @intCast(cluster.glyph_start), .end = @intCast(cluster.glyph_start + cluster.glyph_count) },
        .x = cluster.x,
        .baseline_y = cluster.baseline_y,
        .advance_x = cluster.advance_x,
        .advance_y = cluster.advance_y,
        .logical_bounds = nativeRect(cluster.logical_bounds),
        .ink_bounds = nativeRect(cluster.ink_bounds),
    };
    return .{
        .source_text = owned_source,
        .lines = lines,
        .runs = runs,
        .clusters = clusters,
        .glyphs = glyphs,
        .logical_bounds = nativeRect(native.logical_bounds),
        .ink_bounds = nativeRect(native.ink_bounds),
    };
}

fn fontStyle(value: c_int) core.font.Style {
    return switch (value) {
        1 => .oblique,
        2 => .italic,
        else => .normal,
    };
}

fn fontStretch(value: c_int) core.font.Stretch {
    return switch (value) {
        0 => .ultra_condensed,
        1 => .extra_condensed,
        2 => .condensed,
        3 => .semi_condensed,
        5 => .semi_expanded,
        6 => .expanded,
        7 => .extra_expanded,
        8 => .ultra_expanded,
        else => .normal,
    };
}

fn nativeRect(value: c.SsPdfInkExtents) render.Rect {
    return .{ .x = value.x, .y = value.y, .width = value.width, .height = value.height };
}
