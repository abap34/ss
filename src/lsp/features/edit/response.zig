const std = @import("std");
const protocol = @import("../../protocol.zig");
const utils = @import("utils");

pub const build_diagnostics_message = "The current source cannot be built. See the WYSIWYG build diagnostics.";

pub fn statusJson(allocator: std.mem.Allocator, status: []const u8, message: ?[]const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"schema\":1,\"status\":");
    try protocol.appendJsonString(allocator, &out, status);
    if (message) |text| {
        try out.appendSlice(allocator, ",\"message\":");
        try protocol.appendJsonString(allocator, &out, text);
    }
    try out.append(allocator, '}');
    return try out.toOwnedSlice(allocator);
}

pub fn workspaceEditJson(
    allocator: std.mem.Allocator,
    uri: []const u8,
    source: []const u8,
    edits: anytype,
    path: []const u8,
    page_id: u32,
    binding: []const u8,
) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try appendWorkspaceEdit(allocator, &out, uri, source, edits);
    try out.appendSlice(allocator, ",\"selection\":{\"path\":");
    try protocol.appendJsonString(allocator, &out, path);
    try out.appendSlice(allocator, ",\"pageId\":");
    try protocol.appendInt(allocator, &out, page_id);
    try out.appendSlice(allocator, ",\"binding\":");
    try protocol.appendJsonString(allocator, &out, binding);
    try out.appendSlice(allocator, "}}");
    return try out.toOwnedSlice(allocator);
}

pub fn workspaceEditOnlyJson(
    allocator: std.mem.Allocator,
    uri: []const u8,
    source: []const u8,
    edits: anytype,
) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try appendWorkspaceEdit(allocator, &out, uri, source, edits);
    try out.append(allocator, '}');
    return try out.toOwnedSlice(allocator);
}

fn appendWorkspaceEdit(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    uri: []const u8,
    source: []const u8,
    edits: anytype,
) !void {
    try out.appendSlice(allocator, "{\"schema\":1,\"status\":\"ok\",\"workspaceEdit\":{\"changes\":{");
    try protocol.appendJsonString(allocator, out, uri);
    try out.appendSlice(allocator, ":[");
    for (edits, 0..) |edit, index| {
        if (index != 0) try out.append(allocator, ',');
        try out.appendSlice(allocator, "{\"range\":");
        try appendEditRange(allocator, out, source, edit);
        try out.appendSlice(allocator, ",\"newText\":");
        try protocol.appendJsonString(allocator, out, edit.text);
        try out.append(allocator, '}');
    }
    try out.appendSlice(allocator, "]}}");
}

fn appendEditRange(allocator: std.mem.Allocator, out: *std.ArrayList(u8), source: []const u8, edit: anytype) !void {
    const start = utils.source.utf16PositionAt(source, edit.start);
    const end = utils.source.utf16PositionAt(source, edit.end);
    try out.appendSlice(allocator, "{\"start\":{\"line\":");
    try protocol.appendInt(allocator, out, start.line);
    try out.appendSlice(allocator, ",\"character\":");
    try protocol.appendInt(allocator, out, start.character);
    try out.appendSlice(allocator, "},\"end\":{\"line\":");
    try protocol.appendInt(allocator, out, end.line);
    try out.appendSlice(allocator, ",\"character\":");
    try protocol.appendInt(allocator, out, end.character);
    try out.appendSlice(allocator, "}}");
}
