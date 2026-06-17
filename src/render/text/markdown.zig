const std = @import("std");
const core = @import("core");
const scene = @import("../scene.zig");
const text_layout = @import("layout.zig");
const measure = @import("measure.zig");
const highlight = @import("highlight.zig");

pub fn appendMarkdownText(
    allocator: std.mem.Allocator,
    page: *scene.Page,
    node_id: scene.NodeId,
    frame: scene.Frame,
    content: []const u8,
    text: core.render_policy.TextPaint,
    preamble: []const core.render_env.TexPreambleEntry,
    resolver: ?text_layout.ResourceResolver,
    highlighting: highlight.Context,
) !void {
    var doc = try core.markdown.parseMarkdownContent(allocator, content);
    defer doc.deinit();
    var cursor_y = frame.y;
    try appendBlocks(allocator, page, node_id, frame, doc.blocks.items, text, preamble, resolver, highlighting, 0, &cursor_y);
}

fn appendBlocks(
    allocator: std.mem.Allocator,
    page: *scene.Page,
    node_id: scene.NodeId,
    frame: scene.Frame,
    blocks: []const *core.markdown.Block,
    text: core.render_policy.TextPaint,
    preamble: []const core.render_env.TexPreambleEntry,
    resolver: ?text_layout.ResourceResolver,
    highlighting: highlight.Context,
    list_depth: usize,
    cursor_y: *f32,
) anyerror!void {
    for (blocks, 0..) |block, block_index| {
        switch (block.kind) {
            .paragraph => if (block.paragraph) |paragraph| {
                if (paragraphContainsDisplayMath(paragraph.lines.items)) {
                    try appendParagraphWithDisplayMath(allocator, page, node_id, frame, paragraph.lines.items, text, preamble, resolver, cursor_y);
                } else {
                    var item = try text_layout.textItemFromLines(allocator, node_id, .{
                        .x = frame.x,
                        .y = cursor_y.*,
                        .width = frame.width,
                        .height = frame.height,
                    }, paragraph.lines.items, text, true, preamble, resolver);
                    errdefer item.deinit(allocator);
                    cursor_y.* = nextCursorY(item, text);
                    try page.items.append(allocator, .{ .text = item });
                }
            },
            .code_block => if (block.paragraph) |paragraph| {
                const source = try codeBlockContent(allocator, paragraph.lines.items);
                defer allocator.free(source);
                const line_count = core.markdown.codeBlockPhysicalLineCount(block);
                const box_height = @as(f32, @floatFromInt(line_count)) * text.markdown_code_line_height + text.markdown_code_pad_y * 2;
                try page.items.append(allocator, .{ .shape = .{
                    .node_id = node_id,
                    .frame = .{ .x = frame.x, .y = cursor_y.*, .width = frame.width, .height = box_height },
                    .fill = text.markdown_code_fill,
                    .stroke = text.markdown_code_stroke,
                    .line_width = text.markdown_code_line_width,
                    .radius = text.markdown_code_radius,
                } });
                var item = try text_layout.plainTextItemWithOptions(allocator, node_id, .{
                    .x = frame.x + text.markdown_code_pad_x,
                    .y = cursor_y.* + text.markdown_code_pad_y,
                    .width = @max(frame.width - text.markdown_code_pad_x * 2, 1),
                    .height = box_height,
                }, source, text, .{
                    .font = text.code_font,
                    .color = text.markdown_code_plain_color orelse text.color,
                    .font_size = text.markdown_code_font_size,
                    .line_height = text.markdown_code_line_height,
                    .wrap = false,
                    .preserve_leading_space = true,
                    .trim_trailing_empty_line = true,
                    .highlighting = .{
                        .context = highlighting,
                        .code = markdownCodePaint(text, block.language),
                    },
                });
                errdefer item.deinit(allocator);
                try page.items.append(allocator, .{ .text = item });
                cursor_y.* += box_height;
            },
            .bullet_list, .ordered_list => try appendList(allocator, page, node_id, frame, block, text, preamble, resolver, highlighting, list_depth, cursor_y),
            .table => try appendTable(allocator, page, node_id, frame, block, text, preamble, resolver, cursor_y),
        }
        if (block_index + 1 < blocks.len and text.markdown_block_gap > 0) cursor_y.* += text.markdown_block_gap;
    }
}

fn nextCursorY(item: scene.TextItem, text: core.render_policy.TextPaint) f32 {
    if (item.lines.items.len == 0) return item.frame.y + text.line_height;
    return item.lines.items[item.lines.items.len - 1].baseline_y - text.font_size + text.line_height;
}

fn appendParagraphWithDisplayMath(
    allocator: std.mem.Allocator,
    page: *scene.Page,
    node_id: scene.NodeId,
    frame: scene.Frame,
    lines: []const core.markdown.Line,
    text: core.render_policy.TextPaint,
    preamble: []const core.render_env.TexPreambleEntry,
    resolver: ?text_layout.ResourceResolver,
    cursor_y: *f32,
) !void {
    for (lines) |line| {
        try appendLineWithDisplayMath(allocator, page, node_id, frame, line.runs.items, text, preamble, resolver, cursor_y);
    }
    if (lines.len == 0) cursor_y.* += text.line_height;
}

fn appendLineWithDisplayMath(
    allocator: std.mem.Allocator,
    page: *scene.Page,
    node_id: scene.NodeId,
    frame: scene.Frame,
    runs: []const core.markdown.Run,
    text: core.render_policy.TextPaint,
    preamble: []const core.render_env.TexPreambleEntry,
    resolver: ?text_layout.ResourceResolver,
    cursor_y: *f32,
) !void {
    var segment_start: usize = 0;
    var index: usize = 0;
    while (index < runs.len) {
        if (runs[index].kind != .display_math) {
            index += 1;
            continue;
        }

        if (segment_start < index) {
            try appendRunSliceText(allocator, page, node_id, frame, runs[segment_start..index], text, preamble, resolver, cursor_y);
        }

        const display_start = index;
        while (index < runs.len and runs[index].kind == .display_math) : (index += 1) {}
        const source = try displayMathSource(allocator, runs[display_start..index]);
        defer allocator.free(source);
        if (source.len > 0) {
            const block_height = displayMathBlockHeight(source, text);
            const block_frame = scene.Frame{
                .x = frame.x,
                .y = cursor_y.*,
                .width = frame.width,
                .height = block_height,
            };
            if (resolver) |r| {
                try r.appendDisplayMathBlock(r.context, allocator, page, node_id, block_frame, source, preamble, text);
            } else {
                var fallback = try text_layout.plainTextItem(allocator, node_id, block_frame, source, text, text.code_font, text.color, text.font_size, true);
                errdefer fallback.deinit(allocator);
                try page.items.append(allocator, .{ .text = fallback });
            }
            cursor_y.* += block_height;
        }
        segment_start = index;
    }

    if (segment_start < runs.len) {
        try appendRunSliceText(allocator, page, node_id, frame, runs[segment_start..], text, preamble, resolver, cursor_y);
    }
}

fn appendRunSliceText(
    allocator: std.mem.Allocator,
    page: *scene.Page,
    node_id: scene.NodeId,
    frame: scene.Frame,
    runs: []const core.markdown.Run,
    text: core.render_policy.TextPaint,
    preamble: []const core.render_env.TexPreambleEntry,
    resolver: ?text_layout.ResourceResolver,
    cursor_y: *f32,
) !void {
    if (runs.len == 0) return;
    var item = try text_layout.textItemFromRunSlice(allocator, node_id, .{
        .x = frame.x,
        .y = cursor_y.*,
        .width = frame.width,
        .height = frame.height,
    }, runs, text, true, preamble, resolver);
    errdefer item.deinit(allocator);
    cursor_y.* = nextCursorY(item, text);
    try page.items.append(allocator, .{ .text = item });
}

fn appendList(
    allocator: std.mem.Allocator,
    page: *scene.Page,
    node_id: scene.NodeId,
    frame: scene.Frame,
    block: *const core.markdown.Block,
    text: core.render_policy.TextPaint,
    preamble: []const core.render_env.TexPreambleEntry,
    resolver: ?text_layout.ResourceResolver,
    highlighting: highlight.Context,
    list_depth: usize,
    cursor_y: *f32,
) !void {
    const list = block.list orelse return;
    const list_inset: f32 = if (list_depth == 0) @max(text.markdown_list_inset, 0) else @max(text.markdown_list_indent, 0);
    const item_x = frame.x + list_inset;
    const item_width = @max(frame.width - list_inset, 1);
    for (list.items.items, 0..) |item, item_index| {
        const marker = try listMarker(allocator, block.kind, list_depth, list.start + item_index);
        defer allocator.free(marker);
        const marker_width = try measure.width(allocator, marker, text.font, text.font_size);
        var marker_item = try text_layout.plainTextItem(allocator, node_id, .{
            .x = item_x,
            .y = cursor_y.*,
            .width = marker_width + text.font_size * 0.5,
            .height = text.line_height,
        }, marker, text, text.font, text.color, text.font_size, false);
        errdefer marker_item.deinit(allocator);
        try page.items.append(allocator, .{ .text = marker_item });

        const gap = @max(@as(f32, 8.0), text.font_size * 0.35);
        const content_x = item_x + marker_width + gap;
        const content_frame = scene.Frame{
            .x = content_x,
            .y = cursor_y.*,
            .width = @max(item_width - marker_width - gap, 1),
            .height = frame.height,
        };
        try appendBlocks(allocator, page, node_id, content_frame, item.blocks.items, text, preamble, resolver, highlighting, list_depth + 1, cursor_y);
        if (item_index + 1 < list.items.items.len) cursor_y.* += text.markdown_block_gap;
    }
}

fn appendTable(
    allocator: std.mem.Allocator,
    page: *scene.Page,
    node_id: scene.NodeId,
    frame: scene.Frame,
    block: *const core.markdown.Block,
    text: core.render_policy.TextPaint,
    preamble: []const core.render_env.TexPreambleEntry,
    resolver: ?text_layout.ResourceResolver,
    cursor_y: *f32,
) !void {
    const table = block.table orelse return;
    const columns = @max(table.columns, 1);
    const column_width = frame.width / @as(f32, @floatFromInt(columns));
    var body_row_index: usize = 0;
    for (table.rows.items) |row| {
        var row_lines: usize = 1;
        const content_width = @max(column_width - text.markdown_table_cell_pad_x * 2, 1);
        for (row.cells.items) |cell| {
            var cell_text = text;
            cell_text.font = if (row.header) text.bold_font else text.font;
            row_lines = @max(row_lines, try text_layout.visualLineCountFromLines(allocator, cell.lines.items, cell_text, content_width, preamble, resolver));
        }
        const row_height = @as(f32, @floatFromInt(row_lines)) * text.line_height + text.markdown_table_cell_pad_y * 2;
        const fill = if (row.header)
            text.markdown_table_header_fill
        else if (text.markdown_table_alt_row_fill != null and body_row_index % 2 == 1)
            text.markdown_table_alt_row_fill
        else
            null;
        if (!row.header) body_row_index += 1;

        for (0..columns) |column_index| {
            const cell_x = frame.x + @as(f32, @floatFromInt(column_index)) * column_width;
            const cell_frame = scene.Frame{ .x = cell_x, .y = cursor_y.*, .width = column_width, .height = row_height };
            try page.items.append(allocator, .{ .shape = .{
                .node_id = node_id,
                .frame = cell_frame,
                .fill = fill,
                .stroke = text.markdown_table_border,
                .line_width = text.markdown_table_line_width,
            } });
            if (column_index >= row.cells.items.len) continue;
            const cell = row.cells.items[column_index];
            var cell_text = text;
            cell_text.font = if (row.header) text.bold_font else text.font;
            var item = try text_layout.textItemFromLines(allocator, node_id, .{
                .x = cell_x + text.markdown_table_cell_pad_x,
                .y = cursor_y.* + text.markdown_table_cell_pad_y,
                .width = @max(column_width - text.markdown_table_cell_pad_x * 2, 1),
                .height = @max(row_height - text.markdown_table_cell_pad_y * 2, 1),
            }, cell.lines.items, cell_text, true, preamble, resolver);
            errdefer item.deinit(allocator);
            try page.items.append(allocator, .{ .text = item });
        }
        cursor_y.* += row_height;
    }
}

fn listMarker(allocator: std.mem.Allocator, kind: core.markdown.BlockKind, depth: usize, ordinal: usize) ![]u8 {
    if (kind == .ordered_list) return std.fmt.allocPrint(allocator, "{d}.", .{ordinal});
    return allocator.dupe(u8, if (depth == 0) "•" else "◦");
}

fn codeBlockContent(allocator: std.mem.Allocator, lines: []const core.markdown.Line) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    for (lines, 0..) |line, line_index| {
        for (line.runs.items) |run| try out.appendSlice(allocator, run.text);
        if (line_index + 1 < lines.len) try out.append(allocator, '\n');
    }
    return out.toOwnedSlice(allocator);
}

fn paragraphContainsDisplayMath(lines: []const core.markdown.Line) bool {
    for (lines) |line| {
        for (line.runs.items) |run| {
            if (run.kind == .display_math) return true;
        }
    }
    return false;
}

fn displayMathSource(allocator: std.mem.Allocator, runs: []const core.markdown.Run) ![]const u8 {
    var joined = std.ArrayList(u8).empty;
    defer joined.deinit(allocator);
    for (runs) |run| try joined.appendSlice(allocator, run.text);
    const trimmed = std.mem.trim(u8, joined.items, " \t\r\n");
    return allocator.dupe(u8, trimmed);
}

fn displayMathTargetHeight(source: []const u8, text: core.render_policy.TextPaint) f32 {
    const visual_lines = @as(f32, @floatFromInt(@max(mathVisualLineCount(source), 1)));
    const line_height = @max(text.line_height, text.font_size * text.display_math_height_factor);
    return visual_lines * line_height;
}

fn displayMathBlockHeight(source: []const u8, text: core.render_policy.TextPaint) f32 {
    return displayMathTargetHeight(source, text) + @max(text.line_height * 0.2, 2.0) * 2.0;
}

fn mathVisualLineCount(source: []const u8) usize {
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        if (std.mem.trim(u8, line, " \t\r\n").len == 0) continue;
        count += 1;
        var cursor: usize = 0;
        while (std.mem.indexOfPos(u8, line, cursor, "\\\\")) |break_index| {
            count += 1;
            cursor = break_index + 2;
        }
    }
    return @max(count, 1);
}

fn markdownCodePaint(text: core.render_policy.TextPaint, language: ?[]const u8) core.render_policy.CodePaint {
    const plain = text.markdown_code_plain_color orelse text.color;
    return .{
        .language = language,
        .plain = plain,
        .keyword = text.markdown_code_keyword_color orelse text.link_color,
        .function = text.markdown_code_function_color orelse text.markdown_code_keyword_color orelse text.link_color,
        .type = text.markdown_code_type_color orelse text.markdown_code_keyword_color orelse text.link_color,
        .constant = text.markdown_code_constant_color orelse text.markdown_code_keyword_color orelse text.link_color,
        .number = text.markdown_code_number_color orelse text.markdown_code_constant_color orelse text.link_color,
        .variable = text.markdown_code_variable_color orelse text.markdown_code_plain_color orelse text.color,
        .operator = text.markdown_code_operator_color orelse text.markdown_code_keyword_color orelse text.link_color,
        .comment = text.markdown_code_comment_color orelse .{ .r = 0.38, .g = 0.42, .b = 0.48 },
        .string = text.markdown_code_string_color orelse text.markdown_bold_color orelse text.link_color,
    };
}
