const std = @import("std");
const model = @import("model");
const markdown = @import("../core/markdown.zig");
const style_defaults = @import("style.zig");

const Node = model.Node;
const Role = model.Role;
const PageLayout = model.PageLayout;
const TextStyle = model.TextStyle;

pub fn styleForNode(ir: anytype, node: *const Node) TextStyle {
    return style_defaults.styleForNode(ir, node);
}

fn maxWidthForStyle(style: TextStyle) f32 {
    return @min(PageLayout.max_visual_width, PageLayout.width - style.default_x - style.default_right_inset);
}

fn assetScale(node: *const Node) f32 {
    return parseNodeFloatProperty(node, "asset_scale") orelse 1.0;
}

fn mathScale(node: *const Node) f32 {
    return parseNodeFloatProperty(node, "math_scale") orelse 1.0;
}

pub fn intrinsicWidth(ir: anytype, node: *const Node) f32 {
    const style = styleForNode(ir, node);
    const content = node.content orelse "";
    switch (node.payload_kind orelse .text) {
        .image_ref, .pdf_ref => {
            const base_width = parseNodeFloatProperty(node, "asset_width") orelse @min(maxWidthForStyle(style), PageLayout.default_asset_width);
            return base_width * assetScale(node);
        },
        .figure_text => return maxWidthForStyle(style),
        .math_tex => return maxWidthForStyle(style),
        else => {},
    }

    if (shouldUseFullWrapWidth(ir, node, content)) {
        return maxWidthForStyle(style);
    }

    var max_len: usize = 0;
    var wide = false;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const line_len = codepointCount(line);
        if (line_len > max_len) max_len = line_len;
        if (!wide and containsNonAscii(line)) wide = true;
    }
    if (max_len == 0) max_len = 1;
    const advance = if (wide) style.font_size * 1.02 else style.font_size * 0.58;
    return @min(maxWidthForStyle(style), @as(f32, @floatFromInt(max_len)) * advance);
}

pub fn intrinsicHeight(ir: anytype, node: *const Node) f32 {
    const style = styleForNode(ir, node);
    return switch (node.payload_kind orelse .text) {
        .image_ref, .pdf_ref => blk: {
            const base_height = parseNodeFloatProperty(node, "asset_height") orelse PageLayout.max_figure_height;
            break :blk base_height * assetScale(node);
        },
        .figure_text => PageLayout.max_figure_height,
        .math_tex => blk: {
            const content = node.content orelse "";
            const lines = @max(lineCount(content), 1);
            const base = @as(f32, @floatFromInt(lines)) * 22.0 + 2.0;
            break :blk @min(PageLayout.max_math_height * mathScale(node), @max(@as(f32, 30.0), base) * mathScale(node));
        },
        else => blk: {
            const content = node.content orelse "";
            const width = if (node.frame.width > 0) node.frame.width else intrinsicWidth(ir, node);
            if (shouldWrapNode(ir, node) and markdown.shouldParseBlocks(node.role, if (node.payload_kind) |kind| @tagName(kind) else null)) {
                var doc = markdown.parseMarkdownDocument(
                    ir.allocator,
                    node.role,
                    if (node.payload_kind) |kind| @tagName(kind) else null,
                    content,
                ) catch break :blk fallbackTextHeight(ir, node, style, content, width);
                defer doc.deinit();
                break :blk markdownBlocksHeight(ir, node, style, doc.blocks.items, width, 0);
            }
            const lines = if (shouldWrapNode(ir, node))
                wrappedLineCount(content, style, width, node.role)
            else
                lineCount(content);
            break :blk @as(f32, @floatFromInt(lines)) * style.line_height;
        },
    };
}

fn fallbackTextHeight(ir: anytype, node: *const Node, style: TextStyle, content: []const u8, width: f32) f32 {
    const lines = if (shouldWrapNode(ir, node))
        wrappedLineCount(content, style, width, node.role)
    else
        lineCount(content);
    return @as(f32, @floatFromInt(lines)) * style.line_height;
}

fn markdownBlockGap(node: *const Node, style: TextStyle) f32 {
    return parseNodeFloatProperty(node, "text_markdown_block_gap") orelse style.line_height * 0.15;
}

fn markdownGapBetweenBlocks(node: *const Node, style: TextStyle, current: *const markdown.Block, next: *const markdown.Block) f32 {
    const base = markdownBlockGap(node, style);
    if (current.kind == .code_block or next.kind == .code_block) {
        return @max(base, style.line_height);
    }
    return base;
}

fn markdownListIndent(node: *const Node, style: TextStyle) f32 {
    return parseNodeFloatProperty(node, "text_markdown_list_indent") orelse style.font_size * 1.3;
}

fn markdownCodeLineHeight(node: *const Node) f32 {
    return parseNodeFloatProperty(node, "text_markdown_code_line_height") orelse 20.0;
}

fn markdownCodePadY(node: *const Node) f32 {
    return parseNodeFloatProperty(node, "text_markdown_code_pad_y") orelse 10.0;
}

fn markdownBlocksHeight(ir: anytype, node: *const Node, style: TextStyle, blocks: []const *markdown.Block, max_width: f32, list_depth: usize) f32 {
    _ = ir;
    if (blocks.len == 0) return style.line_height;

    var total: f32 = 0;
    for (blocks, 0..) |block, index| {
        total += markdownBlockHeight(node, style, block, max_width, list_depth);
        if (index != blocks.len - 1) total += markdownGapBetweenBlocks(node, style, block, blocks[index + 1]);
    }
    return total;
}

fn markdownBlockHeight(node: *const Node, style: TextStyle, block: *const markdown.Block, max_width: f32, list_depth: usize) f32 {
    return switch (block.kind) {
        .paragraph => markdownLinesHeight(style, block.paragraph.?.lines.items, max_width),
        .code_block => blk: {
            const lines = markdownCodeBlockLineCount(block);
            break :blk @as(f32, @floatFromInt(lines)) * markdownCodeLineHeight(node) + 2.0 * markdownCodePadY(node);
        },
        .bullet_list, .ordered_list => markdownListHeight(node, style, block, max_width, list_depth),
    };
}

fn markdownCodeBlockLineCount(block: *const markdown.Block) usize {
    const paragraph = block.paragraph orelse return 1;
    var total: usize = 0;
    for (paragraph.lines.items) |line| {
        if (line.runs.items.len == 0) {
            total += 1;
            continue;
        }

        var newlines: usize = 0;
        var ends_with_newline = false;
        var saw_text = false;
        for (line.runs.items) |run| {
            if (run.text.len == 0) continue;
            saw_text = true;
            for (run.text) |ch| {
                if (ch == '\n') newlines += 1;
            }
            ends_with_newline = run.text[run.text.len - 1] == '\n';
        }
        if (!saw_text) {
            total += 1;
            continue;
        }

        var count = newlines + 1;
        if (ends_with_newline and count > 1) count -= 1;
        total += @max(@as(usize, 1), count);
    }
    return @max(@as(usize, 1), total);
}

fn markdownListHeight(node: *const Node, style: TextStyle, block: *const markdown.Block, max_width: f32, list_depth: usize) f32 {
    const list = block.list.?;
    if (list.items.items.len == 0) return style.line_height;

    var total: f32 = 0;
    for (list.items.items, 0..) |item, item_index| {
        total += markdownListItemHeight(node, style, block.kind, item, max_width, list_depth);
        if (item_index != list.items.items.len - 1) total += markdownBlockGap(node, style);
    }
    return total;
}

fn markdownListItemHeight(node: *const Node, style: TextStyle, kind: markdown.BlockKind, item: *const markdown.ListItem, max_width: f32, list_depth: usize) f32 {
    _ = kind;
    const marker_gap = @max(@as(f32, 8.0), style.font_size * 0.35);
    const marker_width = style.font_size * 0.58;
    const content_width = @max(@as(f32, 1.0), max_width - marker_width - marker_gap);
    if (item.blocks.items.len == 0) return style.line_height;

    var total: f32 = 0;
    for (item.blocks.items, 0..) |block, block_index| {
        const block_width = if (block.kind == .bullet_list or block.kind == .ordered_list)
            @max(@as(f32, 1.0), content_width - markdownListIndent(node, style))
        else
            content_width;
        total += markdownBlockHeight(node, style, block, block_width, list_depth + 1);
        if (block_index != item.blocks.items.len - 1) total += markdownGapBetweenBlocks(node, style, block, item.blocks.items[block_index + 1]);
    }
    return total;
}

fn markdownLinesHeight(style: TextStyle, lines: []const markdown.Line, max_width: f32) f32 {
    const count = markdownWrappedLineCount(style, lines, max_width);
    return @as(f32, @floatFromInt(count)) * style.line_height;
}

fn markdownWrappedLineCount(style: TextStyle, lines: []const markdown.Line, max_width: f32) usize {
    if (lines.len == 0) return 1;
    var total: usize = 0;
    for (lines) |line| {
        const width = markdownLineAdvance(style, line);
        if (width <= 0) {
            total += 1;
            continue;
        }
        const available = @max(@as(f32, 1.0), max_width);
        total += @max(@as(usize, 1), @as(usize, @intFromFloat(@ceil(width / available))));
    }
    return total;
}

fn markdownLineAdvance(style: TextStyle, line: markdown.Line) f32 {
    var width: f32 = 0;
    for (line.runs.items) |run| {
        width += markdownRunAdvance(style, run);
    }
    return width;
}

fn markdownRunAdvance(style: TextStyle, run: markdown.Run) f32 {
    return switch (run.kind) {
        .icon, .math, .display_math => style.font_size * 1.05,
        else => blk: {
            const advance = if (containsNonAscii(run.text)) style.font_size * 1.02 else style.font_size * 0.58;
            break :blk @as(f32, @floatFromInt(codepointCount(run.text))) * advance;
        },
    };
}

fn shouldUseFullWrapWidth(ir: anytype, node: *const Node, content: []const u8) bool {
    if (!shouldWrapNode(ir, node)) return false;
    if (lineCount(content) > 1) return true;
    if (!markdown.shouldParseBlocks(node.role, if (node.payload_kind) |kind| @tagName(kind) else null)) return false;

    var doc = markdown.parseMarkdownDocument(
        ir.allocator,
        node.role,
        if (node.payload_kind) |kind| @tagName(kind) else null,
        content,
    ) catch return false;
    defer doc.deinit();

    if (doc.blocks.items.len > 1) return true;
    for (doc.blocks.items) |block| {
        switch (block.kind) {
            .bullet_list, .ordered_list, .code_block => return true,
            else => {},
        }
    }
    return false;
}

pub fn shouldWrapNode(ir: anytype, node: *const Node) bool {
    if (model.nodeProperty(node, "wrap")) |wrap_mode| {
        if (std.mem.eql(u8, wrap_mode, "on")) return true;
        if (std.mem.eql(u8, wrap_mode, "off")) return false;
    }
    return style_defaults.shouldWrapNode(ir, node);
}

fn parseNodeFloatProperty(node: *const Node, key: []const u8) ?f32 {
    return style_defaults.parseNodeFloatProperty(node, key);
}

pub fn lineCount(text: []const u8) usize {
    if (text.len == 0) return 1;
    var count: usize = 1;
    for (text) |ch| {
        if (ch == '\n') count += 1;
    }
    return count;
}

fn wrappedLineCount(text: []const u8, style: TextStyle, max_width: f32, role: ?Role) usize {
    _ = role;
    var total: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0) {
            total += 1;
            continue;
        }

        const wide = containsNonAscii(trimmed);
        const advance = if (wide) style.font_size * 1.02 else style.font_size * 0.58;
        const available = @max(advance, max_width);
        const chars_per_line = @max(@as(usize, 1), @as(usize, @intFromFloat(@floor(available / advance))));
        const needed = std.math.divCeil(usize, codepointCount(trimmed), chars_per_line) catch codepointCount(trimmed);
        total += @max(@as(usize, 1), needed);
    }
    return total;
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
