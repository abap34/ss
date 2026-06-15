const std = @import("std");
const model = @import("model");
const class_fields = @import("../core/class_fields.zig");
const font_model = @import("../core/font.zig");
const markdown = @import("../core/markdown.zig");
const text_measure = @import("../render/text_measure.zig");
const wrap_layout = @import("../render/wrap.zig");
const style_defaults = @import("style.zig");

const Node = model.Node;
const PageLayout = model.PageLayout;
const TextStyle = model.TextStyle;

fn styleForNode(ir: anytype, node: *const Node) TextStyle {
    return style_defaults.styleForNode(ir, node);
}

fn maxWidthForStyle(style: TextStyle) f32 {
    return @min(PageLayout.max_visual_width, PageLayout.width - style.default_x - style.default_right_inset);
}

fn assetScale(ir: anytype, node: *const Node) f32 {
    return positiveNodeFloatProperty(ir, node, "asset_scale") orelse 1.0;
}

fn mathScale(ir: anytype, node: *const Node) f32 {
    return positiveNodeFloatProperty(ir, node, "math_scale") orelse 1.0;
}

pub fn chromePadX(ir: anytype, node: *const Node) f32 {
    return nonNegativeNodeFloatProperty(ir, node, "chrome_pad_x") orelse 0.0;
}

pub fn chromePadY(ir: anytype, node: *const Node) f32 {
    return nonNegativeNodeFloatProperty(ir, node, "chrome_pad_y") orelse 0.0;
}

pub fn contentFrame(ir: anytype, node: *const Node) model.Frame {
    const pad_x = chromePadX(ir, node);
    const pad_y = chromePadY(ir, node);
    return .{
        .x = node.frame.x + pad_x,
        .y = node.frame.y + pad_y,
        .width = @max(@as(f32, 1.0), node.frame.width - 2.0 * pad_x),
        .height = @max(@as(f32, 1.0), node.frame.height - 2.0 * pad_y),
        .x_set = node.frame.x_set,
        .y_set = node.frame.y_set,
    };
}

pub fn intrinsicWidth(ir: anytype, node: *const Node) f32 {
    const style = styleForNode(ir, node);
    const content = node.content orelse "";
    const chrome_width = 2.0 * chromePadX(ir, node);
    switch (node.payload_kind orelse .text) {
        .image_ref, .pdf_ref => {
            const base_width = positiveNodeFloatProperty(ir, node, "asset_width") orelse @min(maxWidthForStyle(style), PageLayout.default_asset_width);
            return base_width * assetScale(ir, node) + chrome_width;
        },
        .figure_text => return maxWidthForStyle(style) + chrome_width,
        .math_text, .math_tex => return maxWidthForStyle(style) + chrome_width,
        else => {},
    }

    if (shouldUseFullWrapWidth(ir, node, content)) {
        return maxWidthForStyle(style) + chrome_width;
    }

    var max_width: f32 = 0;
    const fonts = font_model.textFacesForNode(ir, node);
    const plain_font = plainTextFaceForNode(ir, node, fonts);
    const wrap = shouldWrapNode(ir, node);
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const line_width = if (wrap)
            measuredTextAdvance(ir.allocator, line, plain_font, style)
        else
            measuredTextDrawExtent(ir.allocator, line, plain_font, style);
        max_width = @max(max_width, line_width);
    }
    if (max_width <= 0) max_width = fallbackGlyphAdvance(style);
    return @min(maxWidthForStyle(style), max_width) + chrome_width;
}

pub fn intrinsicHeight(ir: anytype, node: *const Node) f32 {
    const style = styleForNode(ir, node);
    const chrome_height = 2.0 * chromePadY(ir, node);
    return switch (node.payload_kind orelse .text) {
        .image_ref, .pdf_ref => blk: {
            const base_height = positiveNodeFloatProperty(ir, node, "asset_height") orelse PageLayout.max_figure_height;
            break :blk base_height * assetScale(ir, node) + chrome_height;
        },
        .figure_text => PageLayout.max_figure_height + chrome_height,
        .math_text, .math_tex => blk: {
            const content = node.content orelse "";
            const lines = @max(lineCount(content), 1);
            const base = @as(f32, @floatFromInt(lines)) * 22.0 + 2.0;
            break :blk @min(PageLayout.max_math_height * mathScale(ir, node), @max(@as(f32, 30.0), base) * mathScale(ir, node)) + chrome_height;
        },
        else => blk: {
            const content = node.content orelse "";
            const width = if (node.frame.width > 0)
                @max(@as(f32, 1.0), node.frame.width - 2.0 * chromePadX(ir, node))
            else
                @max(@as(f32, 1.0), intrinsicWidth(ir, node) - 2.0 * chromePadX(ir, node));
            if (shouldWrapNode(ir, node) and markdown.shouldParseBlocksNode(ir, node)) {
                var doc = markdown.parseMarkdownDocumentForNode(
                    ir.allocator,
                    ir,
                    node,
                    content,
                ) catch break :blk fallbackTextHeight(ir, node, style, content, width);
                defer doc.deinit();
                break :blk markdownBlocksHeight(ir, node, style, doc.blocks.items, width, 0) + chrome_height;
            }
            const lines = if (shouldWrapNode(ir, node))
                wrappedLineCount(ir, node, style, content, width)
            else
                lineCount(content);
            break :blk @as(f32, @floatFromInt(lines)) * style.line_height + chrome_height;
        },
    };
}

fn fallbackTextHeight(ir: anytype, node: *const Node, style: TextStyle, content: []const u8, width: f32) f32 {
    const lines = if (shouldWrapNode(ir, node))
        wrappedLineCount(ir, node, style, content, width)
    else
        lineCount(content);
    return @as(f32, @floatFromInt(lines)) * style.line_height;
}

fn markdownBlockGap(ir: anytype, node: *const Node, style: TextStyle) f32 {
    return nonNegativeNodeFloatProperty(ir, node, "text_markdown_block_gap") orelse style.line_height * 0.15;
}

fn markdownGapBetweenBlocks(ir: anytype, node: *const Node, style: TextStyle, current: *const markdown.Block, next: *const markdown.Block) f32 {
    const base = markdownBlockGap(ir, node, style);
    if (current.kind == .code_block or next.kind == .code_block) {
        return @max(base, style.line_height);
    }
    return base;
}

fn markdownListIndent(ir: anytype, node: *const Node, style: TextStyle) f32 {
    return nonNegativeNodeFloatProperty(ir, node, "text_markdown_list_indent") orelse style.font_size * 1.3;
}

fn markdownListInset(ir: anytype, node: *const Node, style: TextStyle) f32 {
    return nonNegativeNodeFloatProperty(ir, node, "text_markdown_list_inset") orelse style.font_size * 0.4;
}

fn markdownCodeLineHeight(ir: anytype, node: *const Node) f32 {
    return positiveNodeFloatProperty(ir, node, "text_markdown_code_line_height") orelse 20.0;
}

fn markdownCodePadY(ir: anytype, node: *const Node) f32 {
    return nonNegativeNodeFloatProperty(ir, node, "text_markdown_code_pad_y") orelse 10.0;
}

fn displayMathHeightFactor(ir: anytype, node: *const Node) f32 {
    return positiveNodeFloatProperty(ir, node, "text_display_math_height_factor") orelse 2.0;
}

fn markdownBlocksHeight(ir: anytype, node: *const Node, style: TextStyle, blocks: []const *markdown.Block, max_width: f32, list_depth: usize) f32 {
    if (blocks.len == 0) return style.line_height;

    var total: f32 = 0;
    for (blocks, 0..) |block, index| {
        total += markdownBlockHeight(ir, node, style, block, max_width, list_depth);
        if (index != blocks.len - 1) total += markdownGapBetweenBlocks(ir, node, style, block, blocks[index + 1]);
    }
    return total;
}

fn markdownBlockHeight(ir: anytype, node: *const Node, style: TextStyle, block: *const markdown.Block, max_width: f32, list_depth: usize) f32 {
    return switch (block.kind) {
        .paragraph => markdownLinesHeight(ir, node, style, block.paragraph.?.lines.items, max_width),
        .code_block => blk: {
            const lines = markdown.codeBlockPhysicalLineCount(block);
            break :blk @as(f32, @floatFromInt(lines)) * markdownCodeLineHeight(ir, node) + 2.0 * markdownCodePadY(ir, node);
        },
        .bullet_list, .ordered_list => blk: {
            const list_inset = if (list_depth == 0) markdownListInset(ir, node, style) else 0;
            break :blk markdownListHeight(ir, node, style, block, @max(@as(f32, 1.0), max_width - list_inset), list_depth);
        },
        .table => markdownTableHeight(ir, node, style, block, max_width),
    };
}

fn markdownListHeight(ir: anytype, node: *const Node, style: TextStyle, block: *const markdown.Block, max_width: f32, list_depth: usize) f32 {
    const list = block.list.?;
    if (list.items.items.len == 0) return style.line_height;

    var total: f32 = 0;
    for (list.items.items, 0..) |item, item_index| {
        total += markdownListItemHeight(ir, node, style, block.kind, item, max_width, list_depth);
        if (item_index != list.items.items.len - 1) total += markdownBlockGap(ir, node, style);
    }
    return total;
}

fn markdownListItemHeight(ir: anytype, node: *const Node, style: TextStyle, kind: markdown.BlockKind, item: *const markdown.ListItem, max_width: f32, list_depth: usize) f32 {
    _ = kind;
    const marker_gap = @max(@as(f32, 8.0), style.font_size * 0.35);
    const marker_width = style.font_size * 0.58;
    const content_width = @max(@as(f32, 1.0), max_width - marker_width - marker_gap);
    if (item.blocks.items.len == 0) return style.line_height;

    var total: f32 = 0;
    for (item.blocks.items, 0..) |block, block_index| {
        const block_width = if (block.kind == .bullet_list or block.kind == .ordered_list)
            @max(@as(f32, 1.0), content_width - markdownListIndent(ir, node, style))
        else
            content_width;
        total += markdownBlockHeight(ir, node, style, block, block_width, list_depth + 1);
        if (block_index != item.blocks.items.len - 1) total += markdownGapBetweenBlocks(ir, node, style, block, item.blocks.items[block_index + 1]);
    }
    return total;
}

fn markdownTableCellPadX(ir: anytype, node: *const Node, style: TextStyle) f32 {
    return nonNegativeNodeFloatProperty(ir, node, "text_markdown_table_cell_pad_x") orelse @max(@as(f32, 6.0), style.font_size * 0.55);
}

fn markdownTableCellPadY(ir: anytype, node: *const Node, style: TextStyle) f32 {
    return nonNegativeNodeFloatProperty(ir, node, "text_markdown_table_cell_pad_y") orelse @max(@as(f32, 4.0), style.font_size * 0.32);
}

fn markdownTableLineWidth(ir: anytype, node: *const Node) f32 {
    return nonNegativeNodeFloatProperty(ir, node, "text_markdown_table_line_width") orelse 0.8;
}

fn markdownTableHeight(ir: anytype, node: *const Node, style: TextStyle, block: *const markdown.Block, max_width: f32) f32 {
    const table = block.table.?;
    if (table.rows.items.len == 0) return style.line_height;

    const columns = markdownTableColumnCount(table);
    const pad_x = markdownTableCellPadX(ir, node, style);
    const pad_y = markdownTableCellPadY(ir, node, style);
    const line_width = markdownTableLineWidth(ir, node);
    const cell_width = @max(@as(f32, 1.0), max_width / @as(f32, @floatFromInt(columns)));
    const content_width = @max(@as(f32, 1.0), cell_width - 2.0 * pad_x);

    var total: f32 = line_width;
    for (table.rows.items) |row| {
        var row_content_height = style.line_height;
        for (row.cells.items) |cell| {
            row_content_height = @max(row_content_height, markdownLinesHeight(ir, node, style, cell.lines.items, content_width));
        }
        total += row_content_height + 2.0 * pad_y + line_width;
    }
    return total;
}

fn markdownTableColumnCount(table: markdown.TableData) usize {
    var columns = table.columns;
    for (table.rows.items) |row| {
        columns = @max(columns, row.cells.items.len);
    }
    return @max(@as(usize, 1), columns);
}

fn markdownLinesHeight(ir: anytype, node: *const Node, style: TextStyle, lines: []const markdown.Line, max_width: f32) f32 {
    const count = markdownWrappedLineCount(ir, node, style, lines, max_width);
    return @as(f32, @floatFromInt(count)) * style.line_height;
}

fn markdownWrappedLineCount(ir: anytype, node: *const Node, style: TextStyle, lines: []const markdown.Line, max_width: f32) usize {
    if (lines.len == 0) return 1;
    var total: usize = 0;
    for (lines) |line| {
        total += markdownLineVisualLineCount(ir, node, style, line, max_width);
    }
    return total;
}

fn markdownLineVisualLineCount(ir: anytype, node: *const Node, style: TextStyle, line: markdown.Line, max_width: f32) usize {
    if (!markdownLineContainsDisplayMath(line)) {
        return @max(markdownRunSliceVisualLineCount(ir, node, style, line.runs.items, max_width), 1);
    }

    const runs = line.runs.items;
    var total: usize = 0;
    var segment_start: usize = 0;
    var index: usize = 0;
    while (index < runs.len) {
        if (runs[index].kind != .display_math) {
            index += 1;
            continue;
        }

        total += markdownRunSliceVisualLineCount(ir, node, style, runs[segment_start..index], max_width);

        const display_start = index;
        while (index < runs.len and runs[index].kind == .display_math) : (index += 1) {}
        const visual_lines = displayMathRunLineCount(runs[display_start..index]);
        if (visual_lines > 0) {
            const block_height = displayMathBlockHeightForLines(style, visual_lines, displayMathHeightFactor(ir, node));
            total += @max(@as(usize, 1), @as(usize, @intFromFloat(@ceil(block_height / @max(style.line_height, 1)))));
        }
        segment_start = index;
    }

    total += markdownRunSliceVisualLineCount(ir, node, style, runs[segment_start..], max_width);
    return @max(total, 1);
}

fn wrappedAdvanceLineCount(width: f32, max_width: f32) usize {
    if (width <= 0) return 0;
    const available = @max(@as(f32, 1.0), max_width);
    return @max(@as(usize, 1), @as(usize, @intFromFloat(@ceil(width / available))));
}

fn markdownRunAdvance(style: TextStyle, run: markdown.Run) f32 {
    return switch (run.kind) {
        .icon, .math, .display_math => style.font_size * 1.05,
        else => blk: {
            break :blk fallbackTextAdvance(style, run.text);
        },
    };
}

fn markdownLineContainsDisplayMath(line: markdown.Line) bool {
    for (line.runs.items) |run| {
        if (run.kind == .display_math) return true;
    }
    return false;
}

fn displayMathRunLineCount(runs: []const markdown.Run) usize {
    var count: usize = 0;
    var line_has_content = false;
    for (runs) |run| {
        var index: usize = 0;
        while (index < run.text.len) {
            const byte = run.text[index];
            if (byte == '\n') {
                if (line_has_content) {
                    count += 1;
                    line_has_content = false;
                }
                index += 1;
                continue;
            }
            if (byte == '\\' and index + 1 < run.text.len and run.text[index + 1] == '\\') {
                count += 1;
                line_has_content = false;
                index += 2;
                continue;
            }
            if (!(byte == ' ' or byte == '\t' or byte == '\r')) {
                line_has_content = true;
            }
            index += 1;
        }
    }
    if (line_has_content) count += 1;
    return count;
}

fn displayMathBlockHeightForLines(style: TextStyle, visual_lines: usize, height_factor: f32) f32 {
    const line_count = @as(f32, @floatFromInt(@max(visual_lines, 1)));
    const target_height = line_count * @max(style.line_height, style.font_size * height_factor);
    return target_height + @max(style.line_height * 0.2, 2.0) * 2.0;
}

fn shouldUseFullWrapWidth(ir: anytype, node: *const Node, content: []const u8) bool {
    if (!shouldWrapNode(ir, node)) return false;
    if (lineCount(content) > 1) return true;
    if (!markdown.shouldParseBlocksNode(ir, node)) return false;

    var doc = markdown.parseMarkdownDocumentForNode(
        ir.allocator,
        ir,
        node,
        content,
    ) catch return false;
    defer doc.deinit();

    if (doc.blocks.items.len > 1) return true;
    for (doc.blocks.items) |block| {
        switch (block.kind) {
            .bullet_list, .ordered_list, .code_block, .table => return true,
            else => {},
        }
    }
    return false;
}

pub fn shouldWrapNode(ir: anytype, node: *const Node) bool {
    return style_defaults.shouldWrapNode(ir, node);
}

fn parseNodeFloatProperty(ir: anytype, node: *const Node, key: []const u8) ?f32 {
    return style_defaults.parseNodeFloatProperty(ir, node, key);
}

fn positiveNodeFloatProperty(ir: anytype, node: *const Node, key: []const u8) ?f32 {
    const value = parseNodeFloatProperty(ir, node, key) orelse return null;
    return if (value > 0) value else null;
}

fn nonNegativeNodeFloatProperty(ir: anytype, node: *const Node, key: []const u8) ?f32 {
    const value = parseNodeFloatProperty(ir, node, key) orelse return null;
    return if (value >= 0) value else null;
}

pub fn lineCount(text: []const u8) usize {
    if (text.len == 0) return 1;
    var count: usize = 1;
    for (text) |ch| {
        if (ch == '\n') count += 1;
    }
    return count;
}

fn wrappedLineCount(ir: anytype, node: *const Node, style: TextStyle, text: []const u8, max_width: f32) usize {
    const fonts = font_model.textFacesForNode(ir, node);
    const plain_font = plainTextFaceForNode(ir, node, fonts);
    var total: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0) {
            total += 1;
            continue;
        }

        total += measuredWrappedTextLineCount(ir.allocator, trimmed, plain_font, style, max_width);
    }
    return total;
}

fn plainTextFaceForNode(ir: anytype, node: *const Node, faces: font_model.TextFaces) font_model.Face {
    if ((node.payload_kind orelse .text) == .code) return faces.code;
    if (class_fields.property(ir, node, "render_kind")) |kind| {
        if (std.mem.eql(u8, kind, "code")) return faces.code;
    }
    return faces.normal;
}

fn markdownRunSliceVisualLineCount(ir: anytype, node: *const Node, style: TextStyle, runs: []const markdown.Run, max_width: f32) usize {
    if (runs.len == 0) return 0;
    const fonts = font_model.textFacesForNode(ir, node);
    var lines: usize = 1;
    var cursor = wrap_layout.Cursor{};
    var saw_atom = false;

    for (runs) |run| {
        switch (run.kind) {
            .icon, .math, .display_math => {
                const atom = wrap_layout.Atom{
                    .width = markdownRunAdvance(style, run),
                    .advance = markdownRunAdvance(style, run),
                    .is_space = false,
                };
                applyMeasuredAtom(&cursor, atom, max_width, &lines, &saw_atom);
            },
            else => {
                const font = fontForRun(fonts, run.kind);
                var tokenizer = MeasureTokenizer.init(run.text);
                while (tokenizer.next()) |token| {
                    const width = measuredTextWidth(ir.allocator, token, font, style);
                    const atom = wrap_layout.Atom{
                        .width = width,
                        .advance = width,
                        .is_space = isWhitespace(token),
                    };
                    applyMeasuredAtom(&cursor, atom, max_width, &lines, &saw_atom);
                }
            },
        }
    }

    return if (saw_atom) lines else 0;
}

fn measuredWrappedTextLineCount(allocator: std.mem.Allocator, text: []const u8, font: font_model.Face, style: TextStyle, max_width: f32) usize {
    var lines: usize = 1;
    var cursor = wrap_layout.Cursor{};
    var saw_atom = false;
    var tokenizer = MeasureTokenizer.init(text);
    while (tokenizer.next()) |token| {
        const width = measuredTextWidth(allocator, token, font, style);
        const atom = wrap_layout.Atom{
            .width = width,
            .advance = width,
            .is_space = isWhitespace(token),
        };
        applyMeasuredAtom(&cursor, atom, max_width, &lines, &saw_atom);
    }
    return if (saw_atom) lines else 1;
}

fn applyMeasuredAtom(cursor: *wrap_layout.Cursor, atom: wrap_layout.Atom, max_width: f32, lines: *usize, saw_atom: *bool) void {
    switch (cursor.next(atom, max_width, true)) {
        .skip => return,
        .break_then_draw => lines.* += 1,
        .draw => {},
    }
    cursor.advance(atom.advance);
    saw_atom.* = true;
}

fn fontForRun(fonts: font_model.TextFaces, kind: markdown.RunKind) font_model.Face {
    return switch (kind) {
        .bold => fonts.bold,
        .italic => fonts.italic,
        .code => fonts.code,
        else => fonts.normal,
    };
}

fn measuredTextWidth(allocator: std.mem.Allocator, text: []const u8, font: font_model.Face, style: TextStyle) f32 {
    const measured = text_measure.advanceWidth(allocator, text, font, style.font_size) catch 0;
    return if (measured > 0) measured else fallbackTextAdvance(style, text);
}

fn measuredTextVisualWidth(allocator: std.mem.Allocator, text: []const u8, font: font_model.Face, style: TextStyle) f32 {
    const measured = text_measure.visualWidth(allocator, text, font, style.font_size) catch 0;
    return if (measured > 0) measured else fallbackTextAdvance(style, text);
}

fn measuredTextDrawExtent(allocator: std.mem.Allocator, text: []const u8, font: font_model.Face, style: TextStyle) f32 {
    var advance: f32 = 0;
    var extent: f32 = 0;
    var saw_token = false;
    var tokenizer = MeasureTokenizer.init(text);
    while (tokenizer.next()) |token| {
        const token_advance = measuredTextWidth(allocator, token, font, style);
        const token_visual_width = measuredTextVisualWidth(allocator, token, font, style);
        extent = @max(extent, advance + @max(token_advance, token_visual_width));
        advance += token_advance;
        saw_token = true;
    }
    return if (saw_token) extent else 0;
}

fn measuredTextAdvance(allocator: std.mem.Allocator, text: []const u8, font: font_model.Face, style: TextStyle) f32 {
    var total: f32 = 0;
    var saw_token = false;
    var tokenizer = MeasureTokenizer.init(text);
    while (tokenizer.next()) |token| {
        total += measuredTextWidth(allocator, token, font, style);
        saw_token = true;
    }
    return if (saw_token) total else 0;
}

fn fallbackTextAdvance(style: TextStyle, text: []const u8) f32 {
    const advance = if (containsNonAscii(text)) style.font_size * 1.02 else fallbackGlyphAdvance(style);
    return @as(f32, @floatFromInt(codepointCount(text))) * advance;
}

fn fallbackGlyphAdvance(style: TextStyle) f32 {
    return style.font_size * 0.58;
}

const MeasureTokenizer = struct {
    text: []const u8,
    index: usize = 0,

    fn init(text: []const u8) MeasureTokenizer {
        return .{ .text = text };
    }

    fn next(self: *MeasureTokenizer) ?[]const u8 {
        if (self.index >= self.text.len) return null;
        const start = self.index;
        const first_len = utf8ByteSequenceLength(self.text[self.index]);
        const first_end = @min(self.text.len, self.index + first_len);
        const first = self.text[start..first_end];
        self.index = first_end;

        if (isWhitespace(first)) {
            while (self.index < self.text.len) {
                const len = utf8ByteSequenceLength(self.text[self.index]);
                const end = @min(self.text.len, self.index + len);
                if (!isWhitespace(self.text[self.index..end])) break;
                self.index = end;
            }
            return self.text[start..self.index];
        }

        if (isAsciiWordByte(first[0])) {
            while (self.index < self.text.len and isAsciiWordByte(self.text[self.index])) self.index += 1;
            return self.text[start..self.index];
        }

        return first;
    }
};

fn utf8ByteSequenceLength(first: u8) usize {
    if (first < 0x80) return 1;
    if ((first & 0xe0) == 0xc0) return 2;
    if ((first & 0xf0) == 0xe0) return 3;
    if ((first & 0xf8) == 0xf0) return 4;
    return 1;
}

fn isAsciiWordByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '.' or byte == '/' or byte == ':' or byte == '+' or byte == '-';
}

fn isWhitespace(text: []const u8) bool {
    for (text) |byte| {
        if (byte != ' ' and byte != '\t' and byte != '\r' and byte != '\n') return false;
    }
    return text.len > 0;
}

fn codepointCount(text: []const u8) usize {
    return std.unicode.utf8CountCodepoints(text) catch text.len;
}

fn containsNonAscii(text: []const u8) bool {
    for (text) |ch| {
        if (ch >= 0x80) return true;
    }
    return false;
}
