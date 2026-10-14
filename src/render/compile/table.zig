const std = @import("std");
const core = @import("core");
const inline_layout = @import("inline.zig");

pub const Context = inline_layout.Context;

pub const Cell = struct {
    content: inline_layout.PreparedBlock,
    alignment: core.render_policy.HorizontalAlign,
};

pub const Row = struct {
    cells: []Cell,
    header: bool,
    top: f32,
    height: f32,
    content_top: f32,

    fn deinit(self: *Row, allocator: std.mem.Allocator) void {
        for (self.cells) |*cell| cell.content.deinit(allocator);
        allocator.free(self.cells);
    }
};

/// Owns cell layouts and positions independently of measurement and IR sinks.
pub const Layout = struct {
    rows: []Row,
    columns: usize,
    column_widths: []f32,
    cell_pad_x: f32,
    border_width: f32,
    height: f32,
    logical_width: f32,

    pub fn deinit(self: *Layout, allocator: std.mem.Allocator) void {
        for (self.rows) |*row| row.deinit(allocator);
        allocator.free(self.rows);
        allocator.free(self.column_widths);
        self.* = undefined;
    }

    pub fn contentWidth(self: Layout, column: usize) f32 {
        return @max(self.column_widths[column] - self.cell_pad_x * 2, 1);
    }
};

pub fn prepare(ctx: Context, table: core.markdown.TableData, text: core.render_policy.TextPaint, width: f32) !Layout {
    const allocator = ctx.assets.allocator;
    const columns = core.markdown.tableColumnCount(table);
    const border_width = if (text.markdown_table_border != null and text.markdown_table_line_width > 0) text.markdown_table_line_width else 0;
    const column_widths = try allocator.alloc(f32, columns);
    errdefer allocator.free(column_widths);
    const natural_widths = try allocator.alloc(f32, columns);
    defer allocator.free(natural_widths);
    @memset(natural_widths, 0);
    for (table.rows.items) |row| {
        var cell_text = text;
        cell_text.font = if (row.header) text.bold_font else text.font;
        for (row.cells.items, 0..) |cell, index| {
            if (table.columnWidth(index) != .auto) continue;
            const natural = try inline_layout.naturalBlockWidth(ctx, cell.lines.items, cell_text);
            natural_widths[index] = @max(natural_widths[index], natural + text.markdown_table_cell_pad_x * 2);
        }
    }
    core.markdown.resolveTableColumnWidths(table, @max(width - border_width, 1), natural_widths, column_widths);
    var rows = std.ArrayList(Row).empty;
    errdefer {
        for (rows.items) |*row| row.deinit(allocator);
        rows.deinit(allocator);
    }
    var top: f32 = 0;
    var logical_width = border_width;
    for (column_widths) |column_width| logical_width += column_width;
    for (table.rows.items) |row| {
        try std.Io.checkCancel(ctx.assets.io);
        var cells = std.ArrayList(Cell).empty;
        errdefer {
            for (cells.items) |*cell| cell.content.deinit(allocator);
            cells.deinit(allocator);
        }
        var cell_text = text;
        cell_text.font = if (row.header) text.bold_font else text.font;
        var top_overhang: f32 = 0;
        var bottom_depth = text.line_height;
        var left: f32 = 0;
        for (row.cells.items, 0..) |cell, index| {
            const content_width = @max(column_widths[index] - text.markdown_table_cell_pad_x * 2, 1);
            var content = try inline_layout.prepareBlock(ctx, cell.lines.items, cell_text, content_width);
            errdefer content.deinit(allocator);
            logical_width = @max(logical_width, border_width + left + @max(column_widths[index], content.logical_width + text.markdown_table_cell_pad_x * 2));
            left += column_widths[index];
            bottom_depth = @max(bottom_depth, content.height);
            if (content.ink_bounds) |ink| {
                top_overhang = @max(top_overhang, @as(f32, @floatCast(-ink.y)));
                bottom_depth = @max(bottom_depth, @as(f32, @floatCast(ink.y + ink.height)));
            }
            try cells.append(allocator, .{ .content = content, .alignment = switch (cell.alignment) {
                .default, .left => .left,
                .center => .center,
                .right => .right,
            } });
        }
        const height = top_overhang + bottom_depth + text.markdown_table_cell_pad_y * 2;
        try rows.ensureUnusedCapacity(allocator, 1);
        rows.appendAssumeCapacity(.{ .cells = try cells.toOwnedSlice(allocator), .header = row.header, .top = top, .height = height, .content_top = top + text.markdown_table_cell_pad_y + top_overhang });
        top += height;
    }
    return .{ .rows = try rows.toOwnedSlice(allocator), .columns = columns, .column_widths = column_widths, .cell_pad_x = text.markdown_table_cell_pad_x, .border_width = border_width, .height = top, .logical_width = logical_width };
}
