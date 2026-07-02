const std = @import("std");
const model = @import("model");
const fields = @import("../core/fields.zig");
const font_model = @import("../core/font.zig");
const markdown = @import("../core/markdown.zig");
const text_measure = @import("../render/text_measure.zig");
const text_tokenize = @import("../core/text_tokenize.zig");
const wrap_layout = @import("../render/wrap.zig");
const style_defaults = @import("style.zig");
const source = @import("utils").source;

const Node = model.Node;
const PageLayout = model.PageLayout;
const TextStyle = model.TextStyle;

const MeasurementKind = enum {
    advance,
    visual,
};

const MeasurementKey = struct {
    kind: MeasurementKind,
    text: []const u8,
    family: []const u8,
    weight: u16,
    style: font_model.Style,
    stretch: font_model.Stretch,
    font_size_bits: u32,
};

const MeasurementKeyContext = struct {
    pub fn hash(_: MeasurementKeyContext, key: MeasurementKey) u64 {
        var hasher = std.hash.Wyhash.init(0);
        std.hash.autoHash(&hasher, @intFromEnum(key.kind));
        std.hash.autoHash(&hasher, key.weight);
        std.hash.autoHash(&hasher, @intFromEnum(key.style));
        std.hash.autoHash(&hasher, @intFromEnum(key.stretch));
        std.hash.autoHash(&hasher, key.font_size_bits);
        hasher.update(key.family);
        hasher.update(key.text);
        return hasher.final();
    }

    pub fn eql(_: MeasurementKeyContext, left: MeasurementKey, right: MeasurementKey) bool {
        return left.kind == right.kind and
            left.weight == right.weight and
            left.style == right.style and
            left.stretch == right.stretch and
            left.font_size_bits == right.font_size_bits and
            std.mem.eql(u8, left.family, right.family) and
            std.mem.eql(u8, left.text, right.text);
    }
};

const MeasurementMap = std.HashMap(MeasurementKey, f32, MeasurementKeyContext, std.hash_map.default_max_load_percentage);

pub const MeasurementCache = struct {
    allocator: std.mem.Allocator,
    values: MeasurementMap,
    render_provider: ?model.LayoutMeasurementProvider = null,

    pub fn init(allocator: std.mem.Allocator) MeasurementCache {
        return .{
            .allocator = allocator,
            .values = MeasurementMap.init(allocator),
        };
    }

    pub fn initWithRenderProvider(allocator: std.mem.Allocator, provider: ?model.LayoutMeasurementProvider) MeasurementCache {
        return .{
            .allocator = allocator,
            .values = MeasurementMap.init(allocator),
            .render_provider = provider,
        };
    }

    pub fn deinit(self: *MeasurementCache) void {
        var keys = self.values.keyIterator();
        while (keys.next()) |key| {
            self.allocator.free(key.text);
            self.allocator.free(key.family);
        }
        self.values.deinit();
    }

    fn advanceWidth(self: *MeasurementCache, text: []const u8, font: font_model.Face, font_size: f32) !f32 {
        return try self.measure(.advance, text, font, font_size);
    }

    fn visualWidth(self: *MeasurementCache, text: []const u8, font: font_model.Face, font_size: f32) !f32 {
        return try self.measure(.visual, text, font, font_size);
    }

    fn measure(self: *MeasurementCache, kind: MeasurementKind, text: []const u8, font: font_model.Face, font_size: f32) !f32 {
        if (text.len == 0) return 0;
        const lookup = measurementKey(kind, text, font, font_size);
        if (self.values.get(lookup)) |cached| return cached;

        const measured = switch (kind) {
            .advance => try text_measure.advanceWidth(self.allocator, text, font, font_size),
            .visual => try text_measure.visualWidth(self.allocator, text, font, font_size),
        };

        const owned_text = self.allocator.dupe(u8, text) catch return measured;
        const owned_family = self.allocator.dupe(u8, font.family) catch {
            self.allocator.free(owned_text);
            return measured;
        };
        const owned_key = MeasurementKey{
            .kind = kind,
            .text = owned_text,
            .family = owned_family,
            .weight = font.weight,
            .style = font.style,
            .stretch = font.stretch,
            .font_size_bits = @bitCast(font_size),
        };
        self.values.putNoClobber(owned_key, measured) catch {
            self.allocator.free(owned_text);
            self.allocator.free(owned_family);
            return measured;
        };
        return measured;
    }

    fn renderedMeasurement(self: *MeasurementCache, ir: anytype, node: *const Node, width: f32, mode: model.LayoutMeasurementMode) !?model.LayoutMeasurement {
        const provider = self.render_provider orelse return null;
        const ir_ptr: *anyopaque = @ptrCast(@alignCast(ir));
        return try provider.measure(provider.context, ir_ptr, node, width, mode);
    }
};

fn measurementKey(kind: MeasurementKind, text: []const u8, font: font_model.Face, font_size: f32) MeasurementKey {
    return .{
        .kind = kind,
        .text = text,
        .family = font.family,
        .weight = font.weight,
        .style = font.style,
        .stretch = font.stretch,
        .font_size_bits = @bitCast(font_size),
    };
}

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
    return nonNegativeRecordFloatProperty(ir, node, "chrome", "pad_x") orelse 0.0;
}

pub fn chromePadY(ir: anytype, node: *const Node) f32 {
    return nonNegativeRecordFloatProperty(ir, node, "chrome", "pad_y") orelse 0.0;
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
    return intrinsicWidthWithCache(ir, node, null) catch unreachable;
}

pub fn intrinsicWidthCached(ir: anytype, node: *const Node, cache: *MeasurementCache) !f32 {
    return try intrinsicWidthWithCache(ir, node, cache);
}

fn intrinsicWidthWithCache(ir: anytype, node: *const Node, cache: ?*MeasurementCache) !f32 {
    const style = styleForNode(ir, node);
    const content = model.nodeDisplayContent(node);
    const chrome_width = 2.0 * chromePadX(ir, node);
    if (cache) |measurements| {
        const available_width = maxWidthForStyle(style) + chrome_width;
        if (try measurements.renderedMeasurement(ir, node, available_width, .natural)) |measured| {
            if (measured.width > 0) return @min(available_width, measured.width);
        }
    }
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
    if (markdown.shouldParseBlocksNode(ir, node)) {
        var doc = markdown.parseMarkdownDocumentForNode(
            ir.allocator,
            ir,
            node,
            content,
        ) catch null;
        if (doc) |*parsed| {
            defer parsed.deinit();
            if (markdownBlocksNaturalWidth(ir, node, cache, style, parsed.blocks.items)) |width| {
                max_width = @max(max_width, width);
            }
        }
    }

    if (max_width <= 0) {
        const fonts = font_model.textFacesForNode(ir, node);
        const plain_font = plainTextFaceForNode(ir, node, fonts);
        var lines = source.lineIterator(content);
        while (lines.next()) |line_view| {
            const line = line_view.text(content);
            max_width = @max(max_width, measuredTextDrawExtent(cache, ir.allocator, line, plain_font, style, textEmojiSpacing(ir, node)));
        }
    }
    if (max_width <= 0) max_width = 1;
    return @min(maxWidthForStyle(style), max_width) + chrome_width;
}

pub fn intrinsicHeight(ir: anytype, node: *const Node) f32 {
    return intrinsicHeightWithCache(ir, node, null) catch unreachable;
}

pub fn intrinsicHeightCached(ir: anytype, node: *const Node, cache: *MeasurementCache) !f32 {
    return try intrinsicHeightWithCache(ir, node, cache);
}

fn intrinsicHeightWithCache(ir: anytype, node: *const Node, cache: ?*MeasurementCache) !f32 {
    const style = styleForNode(ir, node);
    const chrome_height = 2.0 * chromePadY(ir, node);
    const measured_outer_width = if (node.frame.width > 0)
        @max(@as(f32, 1.0), node.frame.width)
    else
        @max(@as(f32, 1.0), try intrinsicWidthWithCache(ir, node, cache));
    if (cache) |measurements| {
        if (try measurements.renderedMeasurement(ir, node, measured_outer_width, .width_constrained)) |measured| {
            if (measured.height > 0) return measured.height;
        }
    }
    return switch (node.payload_kind orelse .text) {
        .image_ref, .pdf_ref => blk: {
            const base_height = positiveNodeFloatProperty(ir, node, "asset_height") orelse PageLayout.max_figure_height;
            break :blk base_height * assetScale(ir, node) + chrome_height;
        },
        .figure_text => PageLayout.max_figure_height + chrome_height,
        .math_text, .math_tex => blk: {
            const content = model.nodeDisplayContent(node);
            const lines = @max(source.lineCount(content), 1);
            const base = @as(f32, @floatFromInt(lines)) * 22.0 + 2.0;
            break :blk @min(PageLayout.max_math_height * mathScale(ir, node), @max(@as(f32, 30.0), base) * mathScale(ir, node)) + chrome_height;
        },
        else => blk: {
            const content = model.nodeDisplayContent(node);
            const width = @max(@as(f32, 1.0), measured_outer_width - 2.0 * chromePadX(ir, node));
            if (shouldWrapNode(ir, node) and markdown.shouldParseBlocksNode(ir, node)) {
                var doc = markdown.parseMarkdownDocumentForNode(
                    ir.allocator,
                    ir,
                    node,
                    content,
                ) catch break :blk measuredPlainTextHeight(ir, node, cache, style, content, width);
                defer doc.deinit();
                break :blk markdownBlocksHeight(ir, node, cache, style, doc.blocks.items, width, 0) + chrome_height;
            }
            const lines = if (shouldWrapNode(ir, node))
                wrappedLineCount(ir, node, cache, style, content, width)
            else
                source.lineCount(content);
            break :blk @as(f32, @floatFromInt(lines)) * style.line_height + chrome_height;
        },
    };
}

fn measuredPlainTextHeight(ir: anytype, node: *const Node, cache: ?*MeasurementCache, style: TextStyle, content: []const u8, width: f32) f32 {
    const lines = if (shouldWrapNode(ir, node))
        wrappedLineCount(ir, node, cache, style, content, width)
    else
        source.lineCount(content);
    return @as(f32, @floatFromInt(lines)) * style.line_height;
}

fn markdownBlockGap(ir: anytype, node: *const Node, style: TextStyle) f32 {
    return nonNegativeRecordFloatProperty(ir, node, "text", "markdown_block_gap") orelse style.line_height * 0.15;
}

fn markdownGapBetweenBlocks(ir: anytype, node: *const Node, style: TextStyle, current: *const markdown.Block, next: *const markdown.Block) f32 {
    const base = markdownBlockGap(ir, node, style);
    if (current.kind == .code_block or next.kind == .code_block) {
        return @max(base, style.line_height);
    }
    return base;
}

fn markdownListIndent(ir: anytype, node: *const Node, style: TextStyle) f32 {
    return nonNegativeRecordFloatProperty(ir, node, "text", "markdown_list_indent") orelse style.font_size * 1.3;
}

fn markdownListInset(ir: anytype, node: *const Node, style: TextStyle) f32 {
    return nonNegativeRecordFloatProperty(ir, node, "text", "markdown_list_inset") orelse style.font_size * 0.4;
}

fn markdownCodeLineHeight(ir: anytype, node: *const Node) f32 {
    return positiveRecordFloatProperty(ir, node, "text", "markdown_code_line_height") orelse 20.0;
}

fn markdownCodePadY(ir: anytype, node: *const Node) f32 {
    return nonNegativeRecordFloatProperty(ir, node, "text", "markdown_code_pad_y") orelse 10.0;
}

fn displayMathHeightFactor(ir: anytype, node: *const Node) f32 {
    return positiveRecordFloatProperty(ir, node, "text", "display_math_height_factor") orelse 2.0;
}

fn markdownBlocksHeight(ir: anytype, node: *const Node, cache: ?*MeasurementCache, style: TextStyle, blocks: []const *markdown.Block, max_width: f32, list_depth: usize) f32 {
    if (blocks.len == 0) return style.line_height;

    var total: f32 = 0;
    for (blocks, 0..) |block, index| {
        total += markdownBlockHeight(ir, node, cache, style, block, max_width, list_depth);
        if (index != blocks.len - 1) total += markdownGapBetweenBlocks(ir, node, style, block, blocks[index + 1]);
    }
    return total;
}

fn markdownBlockHeight(ir: anytype, node: *const Node, cache: ?*MeasurementCache, style: TextStyle, block: *const markdown.Block, max_width: f32, list_depth: usize) f32 {
    return switch (block.kind) {
        .paragraph => markdownLinesHeight(ir, node, cache, style, block.paragraph.?.lines.items, max_width),
        .code_block => blk: {
            const lines = markdown.codeBlockPhysicalLineCount(block);
            break :blk @as(f32, @floatFromInt(lines)) * markdownCodeLineHeight(ir, node) + 2.0 * markdownCodePadY(ir, node);
        },
        .bullet_list, .ordered_list => blk: {
            const list_inset = if (list_depth == 0) markdownListInset(ir, node, style) else 0;
            break :blk markdownListHeight(ir, node, cache, style, block, @max(@as(f32, 1.0), max_width - list_inset), list_depth);
        },
        .table => markdownTableHeight(ir, node, cache, style, block, max_width),
    };
}

fn markdownListHeight(ir: anytype, node: *const Node, cache: ?*MeasurementCache, style: TextStyle, block: *const markdown.Block, max_width: f32, list_depth: usize) f32 {
    const list = block.list.?;
    if (list.items.items.len == 0) return style.line_height;

    var total: f32 = 0;
    for (list.items.items, 0..) |item, item_index| {
        total += markdownListItemHeight(ir, node, cache, style, block.kind, item, max_width, list_depth, list.start + item_index);
        if (item_index != list.items.items.len - 1) total += markdownBlockGap(ir, node, style);
    }
    return total;
}

fn markdownListItemHeight(ir: anytype, node: *const Node, cache: ?*MeasurementCache, style: TextStyle, kind: markdown.BlockKind, item: *const markdown.ListItem, max_width: f32, list_depth: usize, ordinal: usize) f32 {
    const marker_gap = @max(@as(f32, 8.0), style.font_size * 0.35);
    const marker_width = markdownListMarkerWidth(ir, node, cache, style, kind, list_depth, ordinal);
    const content_width = @max(@as(f32, 1.0), max_width - marker_width - marker_gap);
    if (item.blocks.items.len == 0) return style.line_height;

    var total: f32 = 0;
    for (item.blocks.items, 0..) |block, block_index| {
        const block_width = if (block.kind == .bullet_list or block.kind == .ordered_list)
            @max(@as(f32, 1.0), content_width - markdownListIndent(ir, node, style))
        else
            content_width;
        total += markdownBlockHeight(ir, node, cache, style, block, block_width, list_depth + 1);
        if (block_index != item.blocks.items.len - 1) total += markdownGapBetweenBlocks(ir, node, style, block, item.blocks.items[block_index + 1]);
    }
    return total;
}

fn markdownListMarkerWidth(ir: anytype, node: *const Node, cache: ?*MeasurementCache, style: TextStyle, kind: markdown.BlockKind, depth: usize, ordinal: usize) f32 {
    const fonts = font_model.textFacesForNode(ir, node);
    const font = plainTextFaceForNode(ir, node, fonts);
    return switch (kind) {
        .ordered_list => blk: {
            var buffer: [32]u8 = undefined;
            const marker = std.fmt.bufPrint(&buffer, "{d}.", .{ordinal}) catch return 0;
            break :blk measuredTextDrawExtent(cache, ir.allocator, marker, font, style, textEmojiSpacing(ir, node));
        },
        .bullet_list => measuredTextDrawExtent(cache, ir.allocator, if (depth == 0) "•" else "◦", font, style, textEmojiSpacing(ir, node)),
        else => 0,
    };
}

fn markdownTableCellPadX(ir: anytype, node: *const Node, style: TextStyle) f32 {
    return nonNegativeRecordFloatProperty(ir, node, "text", "markdown_table_cell_pad_x") orelse @max(@as(f32, 6.0), style.font_size * 0.55);
}

fn markdownTableCellPadY(ir: anytype, node: *const Node, style: TextStyle) f32 {
    return nonNegativeRecordFloatProperty(ir, node, "text", "markdown_table_cell_pad_y") orelse @max(@as(f32, 4.0), style.font_size * 0.32);
}

fn markdownTableLineWidth(ir: anytype, node: *const Node) f32 {
    return nonNegativeRecordFloatProperty(ir, node, "text", "markdown_table_line_width") orelse 0.8;
}

fn markdownTableHeight(ir: anytype, node: *const Node, cache: ?*MeasurementCache, style: TextStyle, block: *const markdown.Block, max_width: f32) f32 {
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
            row_content_height = @max(row_content_height, markdownLinesHeight(ir, node, cache, style, cell.lines.items, content_width));
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

fn markdownLinesHeight(ir: anytype, node: *const Node, cache: ?*MeasurementCache, style: TextStyle, lines: []const markdown.Line, max_width: f32) f32 {
    const count = markdownWrappedLineCount(ir, node, cache, style, lines, max_width);
    return @as(f32, @floatFromInt(count)) * style.line_height;
}

fn markdownWrappedLineCount(ir: anytype, node: *const Node, cache: ?*MeasurementCache, style: TextStyle, lines: []const markdown.Line, max_width: f32) usize {
    if (lines.len == 0) return 1;
    var total: usize = 0;
    for (lines) |line| {
        total += markdownLineVisualLineCount(ir, node, cache, style, line, max_width);
    }
    return total;
}

fn markdownLineVisualLineCount(ir: anytype, node: *const Node, cache: ?*MeasurementCache, style: TextStyle, line: markdown.Line, max_width: f32) usize {
    if (!markdownLineContainsDisplayMath(line)) {
        return @max(markdownRunSliceVisualLineCount(ir, node, cache, style, line.runs.items, max_width), 1);
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

        total += markdownRunSliceVisualLineCount(ir, node, cache, style, runs[segment_start..index], max_width);

        const display_start = index;
        while (index < runs.len and runs[index].kind == .display_math) : (index += 1) {}
        const visual_lines = displayMathRunLineCount(runs[display_start..index]);
        if (visual_lines > 0) {
            const block_height = displayMathBlockHeightForLines(style, visual_lines, displayMathHeightFactor(ir, node));
            total += @max(@as(usize, 1), @as(usize, @intFromFloat(@ceil(block_height / @max(style.line_height, 1)))));
        }
        segment_start = index;
    }

    total += markdownRunSliceVisualLineCount(ir, node, cache, style, runs[segment_start..], max_width);
    return @max(total, 1);
}

fn markdownBlocksNaturalWidth(ir: anytype, node: *const Node, cache: ?*MeasurementCache, style: TextStyle, blocks: []const *markdown.Block) ?f32 {
    if (blocks.len != 1) return null;
    const block = blocks[0];
    return switch (block.kind) {
        .paragraph => markdownParagraphNaturalWidth(ir, node, cache, style, block.paragraph.?.lines.items),
        else => null,
    };
}

fn markdownParagraphNaturalWidth(ir: anytype, node: *const Node, cache: ?*MeasurementCache, style: TextStyle, lines: []const markdown.Line) ?f32 {
    if (lines.len == 0) return 0;
    var max_width: f32 = 0;
    for (lines) |line| {
        if (markdownLineContainsMeasuredRenderArtifact(line)) return null;
        max_width = @max(max_width, markdownRunSliceDrawExtent(ir, node, cache, style, line.runs.items) orelse return null);
    }
    return max_width;
}

fn markdownLineContainsDisplayMath(line: markdown.Line) bool {
    for (line.runs.items) |run| {
        if (run.kind == .display_math) return true;
    }
    return false;
}

fn markdownBlocksContainMeasuredRenderArtifact(blocks: []const *markdown.Block) bool {
    for (blocks) |block| {
        switch (block.kind) {
            .paragraph, .code_block => if (block.paragraph) |paragraph| {
                for (paragraph.lines.items) |line| {
                    if (markdownLineContainsMeasuredRenderArtifact(line)) return true;
                }
            },
            .bullet_list, .ordered_list => if (block.list) |list| {
                for (list.items.items) |item| {
                    if (markdownBlocksContainMeasuredRenderArtifact(item.blocks.items)) return true;
                }
            },
            .table => if (block.table) |table| {
                for (table.rows.items) |row| {
                    for (row.cells.items) |cell| {
                        for (cell.lines.items) |line| {
                            if (markdownLineContainsMeasuredRenderArtifact(line)) return true;
                        }
                    }
                }
            },
        }
    }
    return false;
}

fn markdownLineContainsMeasuredRenderArtifact(line: markdown.Line) bool {
    for (line.runs.items) |run| {
        switch (run.kind) {
            .icon, .math, .display_math => return true,
            else => {},
        }
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
    if (source.lineCount(content) > 1) return true;
    if (!markdown.shouldParseBlocksNode(ir, node)) return false;

    var doc = markdown.parseMarkdownDocumentForNode(
        ir.allocator,
        ir,
        node,
        content,
    ) catch return false;
    defer doc.deinit();

    if (doc.blocks.items.len > 1) return true;
    if (markdownBlocksContainMeasuredRenderArtifact(doc.blocks.items)) return true;
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

fn recordFloatProperty(ir: anytype, node: *const Node, record_key: []const u8, field_name: []const u8) ?f32 {
    return fields.read(ir.allocator, ir, node, record_key, &.{field_name}, .number);
}

fn positiveRecordFloatProperty(ir: anytype, node: *const Node, record_key: []const u8, field_name: []const u8) ?f32 {
    const value = recordFloatProperty(ir, node, record_key, field_name) orelse return null;
    return if (value > 0) value else null;
}

fn nonNegativeRecordFloatProperty(ir: anytype, node: *const Node, record_key: []const u8, field_name: []const u8) ?f32 {
    const value = recordFloatProperty(ir, node, record_key, field_name) orelse return null;
    return if (value >= 0) value else null;
}

fn wrappedLineCount(ir: anytype, node: *const Node, cache: ?*MeasurementCache, style: TextStyle, text: []const u8, max_width: f32) usize {
    const fonts = font_model.textFacesForNode(ir, node);
    const plain_font = plainTextFaceForNode(ir, node, fonts);
    var total: usize = 0;
    var lines = source.lineIterator(text);
    while (lines.next()) |line_view| {
        const line = line_view.text(text);
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0) {
            total += 1;
            continue;
        }

        total += measuredWrappedTextLineCount(cache, ir.allocator, trimmed, plain_font, style, max_width, textEmojiSpacing(ir, node));
    }
    return total;
}

fn plainTextFaceForNode(ir: anytype, node: *const Node, faces: font_model.TextFaces) font_model.Face {
    if ((node.payload_kind orelse .text) == .code) return faces.code;
    if (fields.read(ir.allocator, ir, node, "render_kind", &.{}, .text)) |kind| {
        if (std.mem.eql(u8, kind, "code")) return faces.code;
    }
    return faces.normal;
}

fn markdownRunSliceVisualLineCount(ir: anytype, node: *const Node, cache: ?*MeasurementCache, style: TextStyle, runs: []const markdown.Run, max_width: f32) usize {
    if (runs.len == 0) return 0;
    var atoms = std.ArrayList(MeasuredAtom).empty;
    defer atoms.deinit(ir.allocator);
    appendMarkdownRunSliceMeasuredAtoms(ir, node, cache, style, runs, &atoms) catch return 1;
    return measuredAtomVisualLineCount(atoms.items, max_width, textEmojiSpacing(ir, node));
}

fn markdownRunSliceDrawExtent(ir: anytype, node: *const Node, cache: ?*MeasurementCache, style: TextStyle, runs: []const markdown.Run) ?f32 {
    var atoms = std.ArrayList(MeasuredAtom).empty;
    defer atoms.deinit(ir.allocator);
    appendMarkdownRunSliceMeasuredAtoms(ir, node, cache, style, runs, &atoms) catch return null;
    return measuredAtomLineExtent(atoms.items, textEmojiSpacing(ir, node));
}

fn appendMarkdownRunSliceMeasuredAtoms(ir: anytype, node: *const Node, cache: ?*MeasurementCache, style: TextStyle, runs: []const markdown.Run, atoms: *std.ArrayList(MeasuredAtom)) !void {
    const fonts = font_model.textFacesForNode(ir, node);
    for (runs) |run| {
        switch (run.kind) {
            .icon, .math, .display_math => return error.RenderArtifactMeasuredAtDraw,
            else => {
                const font = fontForRun(fonts, run.kind);
                try appendMeasuredTextAtoms(cache, ir.allocator, atoms, run.text, font, style);
            },
        }
    }
}

fn measuredWrappedTextLineCount(cache: ?*MeasurementCache, allocator: std.mem.Allocator, text: []const u8, font: font_model.Face, style: TextStyle, max_width: f32, emoji_spacing: f32) usize {
    var atoms = std.ArrayList(MeasuredAtom).empty;
    defer atoms.deinit(allocator);
    appendMeasuredTextAtoms(cache, allocator, &atoms, text, font, style) catch return 1;
    return measuredAtomVisualLineCount(atoms.items, max_width, emoji_spacing);
}

fn measuredAtomVisualLineCount(atoms: []const MeasuredAtom, max_width: f32, emoji_spacing: f32) usize {
    if (atoms.len == 0) return 1;
    var lines: usize = 1;
    var cursor = wrap_layout.Cursor{};
    var saw_atom = false;
    for (atoms, 0..) |measured_atom, index| {
        const width = measured_atom.width;
        const wrap_atom = wrap_layout.Atom{
            .width = width,
            .advance = width + measuredAtomSpacingAfter(atoms, index, emoji_spacing),
            .is_space = measured_atom.is_space,
        };
        applyMeasuredAtom(&cursor, wrap_atom, max_width, &lines, &saw_atom);
    }
    return if (saw_atom) lines else 1;
}

const MeasuredAtom = struct {
    width: f32,
    is_space: bool,
    is_emoji: bool,
};

fn appendMeasuredTextAtoms(cache: ?*MeasurementCache, allocator: std.mem.Allocator, atoms: *std.ArrayList(MeasuredAtom), text: []const u8, font: font_model.Face, style: TextStyle) !void {
    var tokenizer = text_tokenize.Tokenizer.init(text);
    while (tokenizer.next()) |token| {
        const is_emoji = text_tokenize.isEmojiToken(token);
        const measured_width = if (is_emoji)
            measuredTextVisualWidth(cache, allocator, token, font, style)
        else
            measuredTextWidth(cache, allocator, token, font, style);
        const width = measured_width;
        try atoms.append(allocator, .{
            .width = width,
            .is_space = text_tokenize.isWhitespace(token),
            .is_emoji = is_emoji,
        });
    }
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

fn measuredTextWidth(cache: ?*MeasurementCache, allocator: std.mem.Allocator, text: []const u8, font: font_model.Face, style: TextStyle) f32 {
    const measured = if (cache) |measurements|
        measurements.advanceWidth(text, font, style.font_size) catch 0
    else
        text_measure.advanceWidth(allocator, text, font, style.font_size) catch 0;
    return if (measured > 0) measured else 0;
}

fn measuredTextVisualWidth(cache: ?*MeasurementCache, allocator: std.mem.Allocator, text: []const u8, font: font_model.Face, style: TextStyle) f32 {
    const measured = if (cache) |measurements|
        measurements.visualWidth(text, font, style.font_size) catch 0
    else
        text_measure.visualWidth(allocator, text, font, style.font_size) catch 0;
    return if (measured > 0) measured else 0;
}

fn measuredTextDrawExtent(cache: ?*MeasurementCache, allocator: std.mem.Allocator, text: []const u8, font: font_model.Face, style: TextStyle, emoji_spacing: f32) f32 {
    var atoms = std.ArrayList(MeasuredAtom).empty;
    defer atoms.deinit(allocator);
    appendMeasuredTextAtoms(cache, allocator, &atoms, text, font, style) catch return 0;
    return measuredAtomLineExtent(atoms.items, emoji_spacing);
}

fn measuredAtomLineExtent(atoms: []const MeasuredAtom, emoji_spacing: f32) f32 {
    var advance: f32 = 0;
    var extent: f32 = 0;
    for (atoms, 0..) |atom, index| {
        extent = @max(extent, advance + atom.width);
        advance += atom.width + measuredAtomSpacingAfter(atoms, index, emoji_spacing);
    }
    return extent;
}

fn measuredAtomSpacingAfter(atoms: []const MeasuredAtom, index: usize, emoji_spacing: f32) f32 {
    if (index + 1 >= atoms.len) return 0;
    if (!atoms[index].is_emoji or atoms[index + 1].is_space) return 0;
    return emoji_spacing;
}

fn textEmojiSpacing(ir: anytype, node: *const Node) f32 {
    return styleForNode(ir, node).font_size * (nonNegativeRecordFloatProperty(ir, node, "text", "emoji_spacing") orelse 0);
}
