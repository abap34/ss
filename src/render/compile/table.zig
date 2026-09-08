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
    column_width: f32,
    content_width: f32,
    border_width: f32,
    height: f32,
    logical_width: f32,

    pub fn deinit(self: *Layout, allocator: std.mem.Allocator) void {
        for (self.rows) |*row| row.deinit(allocator);
        allocator.free(self.rows);
        self.* = undefined;
    }
};

pub fn prepare(ctx: Context, table: core.markdown.TableData, text: core.render_policy.TextPaint, width: f32) !Layout {
    const allocator = ctx.assets.allocator;
    const columns = core.markdown.tableColumnCount(table);
    const border_width = if (text.markdown_table_border != null and text.markdown_table_line_width > 0) text.markdown_table_line_width else 0;
    const column_width = @max(width - border_width, 1) / @as(f32, @floatFromInt(columns));
    const content_width = @max(column_width - text.markdown_table_cell_pad_x * 2, 1);
    var rows = std.ArrayList(Row).empty;
    errdefer {
        for (rows.items) |*row| row.deinit(allocator);
        rows.deinit(allocator);
    }
    var top: f32 = 0;
    var required_column_width = column_width;
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
        for (row.cells.items) |cell| {
            var content = try inline_layout.prepareBlock(ctx, cell.lines.items, cell_text, content_width);
            errdefer content.deinit(allocator);
            required_column_width = @max(required_column_width, content.logical_width + text.markdown_table_cell_pad_x * 2);
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
    return .{ .rows = try rows.toOwnedSlice(allocator), .columns = columns, .column_width = column_width, .content_width = content_width, .border_width = border_width, .height = top, .logical_width = required_column_width * @as(f32, @floatFromInt(columns)) + border_width };
}
