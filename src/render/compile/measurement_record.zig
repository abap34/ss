const std = @import("std");
const core = @import("core");

// Store float bits so cache hits preserve geometry at line-break boundaries exactly.
pub fn append(allocator: std.mem.Allocator, output: *std.ArrayList(u8), key: u64, value: core.LayoutMeasurement) !void {
    try output.print(allocator, "{x}\t{x}\t{x}", .{ key, @as(u32, @bitCast(value.width)), @as(u32, @bitCast(value.height)) });
    if (value.ink_bounds) |ink| {
        inline for (.{ ink.x, ink.y, ink.width, ink.height }) |field| try appendFloat(allocator, output, field);
    } else {
        try output.appendSlice(allocator, "\t-\t-\t-\t-");
    }
    try appendFloat(allocator, output, value.first_baseline);
    try appendFloat(allocator, output, value.measured_width);
    try output.append(allocator, '\n');
}

fn appendFloat(allocator: std.mem.Allocator, output: *std.ArrayList(u8), value: ?f32) !void {
    if (value) |number| {
        try output.print(allocator, "\t{x}", .{@as(u32, @bitCast(number))});
    } else {
        try output.appendSlice(allocator, "\t-");
    }
}

pub fn parse(line: []const u8) ?core.LayoutMeasurement {
    var fields = std.mem.splitScalar(u8, line, '\t');
    const key = std.fmt.parseUnsigned(u64, fields.next() orelse return null, 16) catch return null;
    var values: [8]?f32 = undefined;
    for (&values) |*value| {
        const field = fields.next() orelse return null;
        value.* = if (std.mem.eql(u8, field, "-")) null else @as(f32, @bitCast(std.fmt.parseUnsigned(u32, field, 16) catch return null));
    }
    if (fields.next() != null) return null;
    const ink: ?core.LayoutBounds = if (values[2]) |x| .{
        .x = x,
        .y = values[3] orelse return null,
        .width = values[4] orelse return null,
        .height = values[5] orelse return null,
    } else if (values[3] == null and values[4] == null and values[5] == null) null else return null;
    const value = core.LayoutMeasurement{
        .width = values[0] orelse return null,
        .height = values[1] orelse return null,
        .ink_bounds = ink,
        .first_baseline = values[6],
        .measured_width = values[7],
        .cache_key = key,
    };
    return if (value.isValid()) value else null;
}
