const std = @import("std");
const utils = @import("utils");

const scanner = @import("../../syntax/scanner.zig");
const protocol = @import("../protocol.zig");
const lsp_state = @import("../state.zig");

const source = utils.source;
const color_utils = utils.color;

pub const Context = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    documents: *lsp_state.DocumentStore,
    current_snapshot: ?*const lsp_state.Snapshot,
};

pub fn documentColorsResult(ctx: *Context, params: ?protocol.JsonValue) ![]const u8 {
    if (!lsp_state.featureEnabledForCurrent(ctx.current_snapshot, .colors)) return try ctx.allocator.dupe(u8, "[]");
    var doc = try lsp_state.documentTextFromParams(ctx.io, ctx.allocator, ctx.documents, params) orelse return try ctx.allocator.dupe(u8, "[]");
    defer doc.deinit(ctx.allocator);
    return documentColorsJson(ctx.allocator, doc.source);
}

pub fn colorPresentationResult(ctx: *Context, params: ?protocol.JsonValue) ![]const u8 {
    if (!lsp_state.featureEnabledForCurrent(ctx.current_snapshot, .colors)) return try ctx.allocator.dupe(u8, "[]");
    const color = if (params) |p| protocol.objectField(p, "color") else null;
    const red = if (color) |c| protocol.numberField(c, "red") orelse 0 else 0;
    const green = if (color) |c| protocol.numberField(c, "green") orelse 0 else 0;
    const blue = if (color) |c| protocol.numberField(c, "blue") orelse 0 else 0;
    return colorPresentationsJson(ctx.allocator, red, green, blue);
}

const Color = struct {
    span: source.ByteSpan,
    red: f64,
    green: f64,
    blue: f64,
};

pub fn documentColorsJson(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    const colors = try scan(allocator, text);
    defer allocator.free(colors);

    var out = std.ArrayList(u8).empty;
    try out.append(allocator, '[');
    for (colors, 0..) |color, index| {
        if (index != 0) try out.append(allocator, ',');
        try out.appendSlice(allocator, "{\"range\":");
        try protocol.appendRange(allocator, &out, protocol.rangeFromSpan(text, color.span));
        try out.appendSlice(allocator, ",\"color\":{\"red\":");
        try protocol.appendFloat(allocator, &out, color.red);
        try out.appendSlice(allocator, ",\"green\":");
        try protocol.appendFloat(allocator, &out, color.green);
        try out.appendSlice(allocator, ",\"blue\":");
        try protocol.appendFloat(allocator, &out, color.blue);
        try out.appendSlice(allocator, ",\"alpha\":1}}");
    }
    try out.append(allocator, ']');
    return out.toOwnedSlice(allocator);
}

pub fn colorPresentationsJson(allocator: std.mem.Allocator, red: f64, green: f64, blue: f64) ![]const u8 {
    const label = try std.fmt.allocPrint(allocator, "c\"#{x:0>2}{x:0>2}{x:0>2}\"", .{ toByte(red), toByte(green), toByte(blue) });
    defer allocator.free(label);
    var out = std.ArrayList(u8).empty;
    try out.appendSlice(allocator, "[{\"label\":");
    try protocol.appendJsonString(allocator, &out, label);
    try out.appendSlice(allocator, "}]");
    return out.toOwnedSlice(allocator);
}

fn scan(allocator: std.mem.Allocator, text: []const u8) ![]Color {
    var out = std.ArrayList(Color).empty;
    errdefer out.deinit(allocator);

    var tokens = scanner.tokens(text);
    while (tokens.next()) |token| {
        if (token.kind != .color_string) continue;
        if (color_utils.parse(text[token.span.start..token.span.end])) |rgb| {
            try out.append(allocator, .{
                .span = token.span,
                .red = rgb.r,
                .green = rgb.g,
                .blue = rgb.b,
            });
        }
    }

    return out.toOwnedSlice(allocator);
}

fn toByte(value: f64) u8 {
    return @intFromFloat(@max(0, @min(255, std.math.round(value * 255.0))));
}
