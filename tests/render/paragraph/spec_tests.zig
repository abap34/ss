const std = @import("std");
const c = @import("pdf_ffi").c;
const render_text = @import("render_text");
const testing = std.testing;

fn defaults(width: f64) c.SsParagraphOptions {
    var options = std.mem.zeroes(c.SsParagraphOptions);
    options.font_family = "DejaVu Sans";
    options.font_weight = 400;
    options.font_stretch = 4;
    options.font_size = 24;
    options.width = width;
    options.wrap = 1;
    return options;
}

fn shape(source: [:0]const u8, options: *const c.SsParagraphOptions, positions: ?[*]c.SsInlinePosition) !c.SsTextShape {
    _ = try render_text.fontEnvironmentSnapshot();
    var result = std.mem.zeroes(c.SsTextShape);
    try testing.expectEqual(@as(c_int, 0), c.ss_text_shape_paragraph(source.ptr, options, &result, positions));
    return result;
}

test "paragraph shaping preserves contextual glyphs across equal font spans" {
    const source = "\u{633}\u{644}\u{627}\u{645}";
    var options = defaults(1000);
    var plain = try shape(source, &options, null);
    defer c.ss_text_shape_free(&plain);
    const styles = [_]c.SsParagraphStyle{
        .{ .source_start = 0, .source_end = 4, .font_family = options.font_family, .font_weight = 400, .font_style = 0, .font_stretch = 4, .letter_spacing = 0 },
        .{ .source_start = 4, .source_end = source.len, .font_family = options.font_family, .font_weight = 400, .font_style = 0, .font_stretch = 4, .letter_spacing = 0 },
    };
    options.styles = &styles;
    options.style_count = styles.len;
    var attributed = try shape(source, &options, null);
    defer c.ss_text_shape_free(&attributed);
    try testing.expectEqual(plain.glyph_count, attributed.glyph_count);
    try testing.expect(plain.glyph_count < 4);
    try testing.expectApproxEqAbs(plain.logical_bounds.width, attributed.logical_bounds.width, 0.001);
    for (plain.glyphs[0..plain.glyph_count], attributed.glyphs[0..attributed.glyph_count]) |first, second| {
        try testing.expectEqual(first.id, second.id);
        try testing.expectEqual(first.advance_x, second.advance_x);
        try testing.expectEqual(first.offset_x, second.offset_x);
        try testing.expectEqual(first.offset_y, second.offset_y);
    }
    for (attributed.runs[0..attributed.run_count]) |run| try testing.expect(run.bidi_level & 1 == 1);
}

test "paragraph wrapping respects nonbreaking spaces and grapheme boundaries" {
    const nonbreaking = "a\u{a0}b";
    var options = defaults(1);
    var no_break = try shape(nonbreaking, &options, null);
    defer c.ss_text_shape_free(&no_break);
    try testing.expectEqual(@as(usize, 1), no_break.line_count);
    try testing.expectEqual(nonbreaking.len, no_break.lines[0].source_end);

    for ([_][:0]const u8{ "e\u{301}", "\u{304b}\u{3099}", "\u{1f468}\u{200d}\u{1f469}\u{200d}\u{1f467}" }) |grapheme| {
        var result = try shape(grapheme, &options, null);
        defer c.ss_text_shape_free(&result);
        try testing.expectEqual(@as(usize, 1), result.line_count);
        try testing.expectEqual(grapheme.len, result.lines[0].source_end);
    }
    const punctuation = "\u{3042}\u{3044}\u{3001}\u{3046}";
    options.width = 48;
    var result = try shape(punctuation, &options, null);
    defer c.ss_text_shape_free(&result);
    for (result.lines[0..result.line_count]) |line| try testing.expect(line.source_start != 6);
}

test "paragraph inline objects participate in line geometry and bidirectional placement" {
    for ([_]struct { source: [:0]const u8, offset: usize }{
        .{ .source = "A \u{fffc} B", .offset = 2 },
        .{ .source = "\u{633} \u{fffc} \u{645}", .offset = 3 },
    }) |example| {
        var options = defaults(1000);
        const objects = [_]c.SsParagraphObject{.{ .source_start = example.offset, .width = 40, .height = 50, .baseline_from_bottom = 6, .spacing = 4 }};
        options.objects = &objects;
        options.object_count = objects.len;
        var positions: [1]c.SsInlinePosition = undefined;
        var result = try shape(example.source, &options, &positions);
        defer c.ss_text_shape_free(&result);
        try testing.expectEqual(@as(usize, 1), result.line_count);
        try testing.expect(result.logical_bounds.height >= 50);
        try testing.expectEqual(@as(usize, 0), positions[0].line_index);
        try testing.expectEqual(result.lines[0].baseline_y, positions[0].baseline_y);
        try testing.expect(positions[0].x >= 0);
        try testing.expect(positions[0].x + 40 <= result.logical_bounds.width);
        for (result.runs[0..result.run_count]) |run| {
            try testing.expect(run.source_end <= example.offset or run.source_start >= example.offset + 3);
            try testing.expect(run.x + run.advance <= positions[0].x + 0.001 or run.x >= positions[0].x + 40 - 0.001);
        }
    }
}

test "paragraph attributes select fonts and reject invalid byte ranges" {
    var options = defaults(1000);
    var styles = [_]c.SsParagraphStyle{.{ .source_start = 6, .source_end = 10, .font_family = options.font_family, .font_weight = 700, .font_style = 0, .font_stretch = 4, .letter_spacing = 0 }};
    options.styles = &styles;
    options.style_count = styles.len;
    var result = try shape("plain bold", &options, null);
    defer c.ss_text_shape_free(&result);
    var bold = false;
    for (result.runs[0..result.run_count]) |run| if (run.source_start >= 6 and run.font_weight >= 600) {
        bold = true;
    };
    try testing.expect(bold);
    var invalid = std.mem.zeroes(c.SsTextShape);
    styles[0].source_end = 11;
    try testing.expectEqual(@as(c_int, 1), c.ss_text_shape_paragraph("plain bold", &options, &invalid, null));
    styles[0].source_start = 1;
    styles[0].source_end = 2;
    try testing.expectEqual(@as(c_int, 1), c.ss_text_shape_paragraph("\u{633}", &options, &invalid, null));
    options.styles = null;
    options.style_count = 0;
    const objects = [_]c.SsParagraphObject{.{ .source_start = 0, .width = 40, .height = 50, .baseline_from_bottom = 6, .spacing = 4 }};
    options.objects = &objects;
    options.object_count = 1;
    var positions: [1]c.SsInlinePosition = undefined;
    try testing.expectEqual(@as(c_int, 1), c.ss_text_shape_paragraph("text", &options, &invalid, &positions));
    try testing.expectEqual(@as(c_int, 1), c.ss_text_shape_paragraph("\u{fffc}", &options, &invalid, null));
}

test "retained paragraphs share geometry across output owners and evict unused layouts" {
    var cache = render_text.paragraph.Cache.init(testing.allocator, testing.io);
    defer cache.deinit();
    cache.max_entries = 1;
    const environment = try render_text.fontEnvironmentSnapshot();
    var request = render_text.paragraph.Request{ .source = "one two three", .font = .{ .family = "DejaVu Sans", .weight = 400, .style = .normal, .stretch = .normal }, .font_size = 24, .line_height = 36, .width = 100, .wrap = true };
    const first = try cache.get(request, environment);
    defer first.release();
    const same = try cache.get(request, environment);
    defer same.release();
    try testing.expect(first == same);
    try testing.expect(first.native.line_count > 1);
    request.width = 300;
    const wider = try cache.get(request, environment);
    defer wider.release();
    try testing.expect(first != wider);
    try testing.expectEqual(@as(usize, 1), wider.native.line_count);
    try testing.expectEqualStrings(request.source, first.source);
    try testing.expectEqual(@as(usize, 1), cache.entries.count());
}

fn paragraphAllocationFailures(allocator: std.mem.Allocator) !void {
    var cache = render_text.paragraph.Cache.init(allocator, testing.io);
    defer cache.deinit();
    const environment = try render_text.fontEnvironmentSnapshot();
    const styles = [_]render_text.paragraph.Style{.{ .start = 0, .end = 3, .font = .{ .family = "DejaVu Sans", .weight = 700, .style = .normal, .stretch = .normal } }};
    const objects = [_]render_text.paragraph.Object{.{ .source_start = 4, .width = 20, .height = 30, .baseline_from_bottom = 5, .spacing = 2 }};
    const result = try cache.get(.{ .source = "one \u{fffc} two", .font = .{ .family = "DejaVu Sans", .weight = 400, .style = .normal, .stretch = .normal }, .font_size = 24, .line_height = 36, .width = 100, .wrap = true, .styles = &styles, .objects = &objects }, environment);
    defer result.release();
    try testing.expect(result.native.line_count > 0);
}

test "retained paragraph ownership survives every allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, paragraphAllocationFailures, .{});
}

test "paragraph wrapping consumes separators without adding empty visual lines" {
    var options = defaults(1000);
    var word = try shape("word", &options, null);
    defer c.ss_text_shape_free(&word);
    options.width = word.logical_bounds.width;
    var trailing = try shape("word   ", &options, null);
    defer c.ss_text_shape_free(&trailing);
    try testing.expectEqual(@as(usize, 1), trailing.line_count);
    var following = try shape("word   next", &options, null);
    defer c.ss_text_shape_free(&following);
    try testing.expectEqual(@as(usize, 2), following.line_count);
}

test "symbol spacing preserves joined emoji graphemes" {
    const source = "\u{1f468}\u{200d}\u{1f469}\u{200d}\u{1f467}X";
    var options = defaults(1000);
    var plain = try shape(source, &options, null);
    defer c.ss_text_shape_free(&plain);
    options.emoji_spacing = 6;
    var spaced = try shape(source, &options, null);
    defer c.ss_text_shape_free(&spaced);
    try testing.expectEqual(plain.glyph_count, spaced.glyph_count);
    try testing.expect(spaced.logical_bounds.width > plain.logical_bounds.width);
    for (plain.glyphs[0..plain.glyph_count], spaced.glyphs[0..spaced.glyph_count]) |before, after| try testing.expectEqual(before.id, after.id);
    options.width = 1;
    var narrow = try shape(source, &options, null);
    defer c.ss_text_shape_free(&narrow);
    for (narrow.lines[0..narrow.line_count]) |line| {
        try testing.expect(line.source_start == 0 or line.source_start == source.len - 1);
    }
}

test "paragraph shaping retains thousands of alternating font spans" {
    const count = 4096;
    const source = try testing.allocator.allocSentinel(u8, count * 3, 0);
    defer testing.allocator.free(source);
    const styles = try testing.allocator.alloc(c.SsParagraphStyle, count);
    defer testing.allocator.free(styles);
    var options = defaults(900);
    for (styles, 0..) |*style, index| {
        @memcpy(source[index * 3 ..][0..3], "ab ");
        style.* = .{ .source_start = index * 3, .source_end = index * 3 + 3, .font_family = options.font_family, .font_weight = if (index % 2 == 0) 400 else 700, .font_style = 0, .font_stretch = 4, .letter_spacing = 0 };
    }
    options.styles = styles.ptr;
    options.style_count = styles.len;
    var result = try shape(source, &options, null);
    defer c.ss_text_shape_free(&result);
    var covered: usize = 0;
    for (result.runs[0..result.run_count]) |run| {
        covered += run.source_end - run.source_start;
        try testing.expectEqual(@as(c_int, if ((run.source_start / 3) % 2 == 0) 400 else 700), run.font_weight);
    }
    try testing.expectEqual(source.len, covered);
    try testing.expect(result.line_count > 1);
}
