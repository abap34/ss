const std = @import("std");

pub fn layout(ir: anytype, value: anytype) !void {
    if (!value.logical_bounds.isValid() or !value.ink_bounds.isValid() or !std.unicode.utf8ValidateSlice(value.source_text)) {
        return error.InvalidItemGeometry;
    }
    var next_run: usize = 0;
    for (value.lines) |line| {
        if (!line.logical_bounds.isValid() or !line.ink_bounds.isValid() or !std.math.isFinite(line.baseline_y)) return error.InvalidItemGeometry;
        if (line.source.start > line.source.end or line.source.end > value.source_text.len) return error.InvalidItemGeometry;
        if (line.run_range.start > line.run_range.end or line.run_range.end > value.runs.len) return error.InvalidItemGeometry;
        if (line.run_range.start != next_run) return error.InvalidItemGeometry;
        next_run = line.run_range.end;
    }
    if (next_run != value.runs.len) return error.InvalidItemGeometry;
    var next_cluster: usize = 0;
    var next_glyph: usize = 0;
    for (value.runs) |run| {
        if (!std.math.isFinite(run.x) or !std.math.isFinite(run.baseline_y) or !std.math.isFinite(run.advance)) return error.InvalidItemGeometry;
        if (run.source.start > run.source.end or run.source.end > value.source_text.len) return error.InvalidItemGeometry;
        if (run.glyph_range.start > run.glyph_range.end or run.glyph_range.end > value.glyphs.len) return error.InvalidItemGeometry;
        if (run.cluster_range.start > run.cluster_range.end or run.cluster_range.end > value.clusters.len) return error.InvalidItemGeometry;
        if (run.cluster_range.start != next_cluster or run.glyph_range.start != next_glyph) return error.InvalidItemGeometry;
        next_cluster = run.cluster_range.end;
        next_glyph = run.glyph_range.end;
        if (ir.fonts.find(run.font_instance) == null) return error.MissingFont;
        if (!std.unicode.utf8ValidateSlice(run.language)) return error.InvalidItemGeometry;
        if ((run.direction == .right_to_left) != (run.bidi_level & 1 == 1)) return error.InvalidItemGeometry;
        var source_boundary = if (run.direction == .left_to_right) run.source.start else run.source.end;
        var glyph_boundary = run.glyph_range.start;
        const run_clusters = value.clusters[run.cluster_range.start..run.cluster_range.end];
        for (run_clusters) |cluster| {
            if (cluster.source.start < run.source.start or cluster.source.end > run.source.end) return error.InvalidItemGeometry;
            if (cluster.source.start > cluster.source.end or cluster.glyph_range.start > cluster.glyph_range.end) return error.InvalidItemGeometry;
            if (cluster.glyph_range.start != glyph_boundary or cluster.glyph_range.end > run.glyph_range.end) return error.InvalidItemGeometry;
            glyph_boundary = cluster.glyph_range.end;
            if (run.direction == .left_to_right) {
                if (cluster.source.start != source_boundary) return error.InvalidItemGeometry;
                source_boundary = cluster.source.end;
            } else {
                if (cluster.source.end != source_boundary) return error.InvalidItemGeometry;
                source_boundary = cluster.source.start;
            }
        }
        const source_end = if (run.direction == .left_to_right) run.source.end else run.source.start;
        if (source_boundary != source_end or glyph_boundary != run.glyph_range.end) {
            return error.InvalidItemGeometry;
        }
    }
    if (next_cluster != value.clusters.len or next_glyph != value.glyphs.len) return error.InvalidItemGeometry;
    for (value.clusters) |cluster| {
        if (cluster.source.start > cluster.source.end or cluster.source.end > value.source_text.len) return error.InvalidItemGeometry;
        if (cluster.glyph_range.start > cluster.glyph_range.end or cluster.glyph_range.end > value.glyphs.len) return error.InvalidItemGeometry;
        if (!std.math.isFinite(cluster.x) or !std.math.isFinite(cluster.baseline_y) or
            !std.math.isFinite(cluster.advance_x) or !std.math.isFinite(cluster.advance_y) or
            !cluster.logical_bounds.isValid() or !cluster.ink_bounds.isValid()) return error.InvalidItemGeometry;
    }
    for (value.glyphs) |glyph| {
        if (!std.math.isFinite(glyph.offset_x) or !std.math.isFinite(glyph.offset_y) or
            !std.math.isFinite(glyph.advance_x) or !std.math.isFinite(glyph.advance_y)) return error.InvalidItemGeometry;
    }
}
