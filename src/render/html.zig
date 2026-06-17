const std = @import("std");
const scene = @import("scene.zig");
const html_json = @import("html/json.zig");

pub fn appendDisplayFromScene(allocator: std.mem.Allocator, out: *std.ArrayList(u8), document: *const scene.Document) !void {
    try html_json.appendDisplay(allocator, out, document);
}

pub fn appendEmptyDisplay(allocator: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
    try html_json.appendEmptyDisplay(allocator, out);
}
