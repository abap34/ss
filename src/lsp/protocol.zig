const std = @import("std");
const project = @import("../project.zig");
const utils = @import("utils");

const source = utils.source;

pub const JsonValue = std.json.Value;
pub const JsonObject = std.json.ObjectMap;
pub const JsonArray = std.json.Array;

pub const Range = struct {
    start_line: usize,
    start_character: usize,
    end_line: usize,
    end_character: usize,
};

pub fn jsonLiteral(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    return allocator.dupe(u8, text);
}

pub fn readMessage(allocator: std.mem.Allocator) !?[]u8 {
    var header = std.ArrayList(u8).empty;
    defer header.deinit(allocator);
    var last4 = [_]u8{ 0, 0, 0, 0 };
    while (true) {
        var byte: [1]u8 = undefined;
        const n = std.c.read(0, &byte, 1);
        if (n == 0) return null;
        if (n < 0) return error.ReadFailed;
        try header.append(allocator, byte[0]);
        last4 = .{ last4[1], last4[2], last4[3], byte[0] };
        if (std.mem.eql(u8, &last4, "\r\n\r\n")) break;
    }
    const content_length = parseContentLength(header.items) orelse return error.InvalidHeader;
    const body = try allocator.alloc(u8, content_length);
    var offset: usize = 0;
    while (offset < body.len) {
        const n = std.c.read(0, body[offset..].ptr, body.len - offset);
        if (n <= 0) return error.ReadFailed;
        offset += @intCast(n);
    }
    return body;
}

fn parseContentLength(header: []const u8) ?usize {
    var lines = std.mem.splitSequence(u8, header, "\r\n");
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        if (!std.ascii.eqlIgnoreCase(name, "Content-Length")) continue;
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        return std.fmt.parseUnsigned(usize, value, 10) catch null;
    }
    return null;
}

fn sendRaw(payload: []const u8) !void {
    var header_buf: [64]u8 = undefined;
    const header = try std.fmt.bufPrint(&header_buf, "Content-Length: {d}\r\n\r\n", .{payload.len});
    try writeAll(header);
    try writeAll(payload);
}

fn writeAll(bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const n = std.c.write(1, bytes[offset..].ptr, bytes.len - offset);
        if (n <= 0) return error.WriteFailed;
        offset += @intCast(n);
    }
}

pub fn respond(allocator: std.mem.Allocator, id: ?JsonValue, result_json: []const u8) !void {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"jsonrpc\":\"2.0\",\"id\":");
    try appendJsonValue(allocator, &out, id orelse .null);
    try out.appendSlice(allocator, ",\"result\":");
    try out.appendSlice(allocator, result_json);
    try out.append(allocator, '}');
    try sendRaw(out.items);
}

pub fn respondError(allocator: std.mem.Allocator, id: ?JsonValue, code: i64, message: []const u8) !void {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"jsonrpc\":\"2.0\",\"id\":");
    try appendJsonValue(allocator, &out, id orelse .null);
    try out.appendSlice(allocator, ",\"error\":{\"code\":");
    try appendInt(allocator, &out, code);
    try out.appendSlice(allocator, ",\"message\":");
    try appendJsonString(allocator, &out, message);
    try out.appendSlice(allocator, "}}");
    try sendRaw(out.items);
}

pub fn sendNotification(allocator: std.mem.Allocator, method: []const u8, params_json: []const u8) !void {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"jsonrpc\":\"2.0\",\"method\":");
    try appendJsonString(allocator, &out, method);
    try out.appendSlice(allocator, ",\"params\":");
    try out.appendSlice(allocator, params_json);
    try out.append(allocator, '}');
    try sendRaw(out.items);
}

pub fn appendJsonValue(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: JsonValue) !void {
    const text = try std.json.Stringify.valueAlloc(allocator, value, .{});
    defer allocator.free(text);
    try out.appendSlice(allocator, text);
}

pub fn appendJsonString(allocator: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    const escaped = try std.json.Stringify.valueAlloc(allocator, text, .{});
    defer allocator.free(escaped);
    try out.appendSlice(allocator, escaped);
}

pub fn appendInt(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: anytype) !void {
    const text = try std.fmt.allocPrint(allocator, "{d}", .{value});
    defer allocator.free(text);
    try out.appendSlice(allocator, text);
}

pub fn appendBool(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: bool) !void {
    try out.appendSlice(allocator, if (value) "true" else "false");
}

pub fn appendFloat(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: f64) !void {
    const text = try std.fmt.allocPrint(allocator, "{d:.4}", .{value});
    defer allocator.free(text);
    try out.appendSlice(allocator, text);
}

pub fn stringField(object: *const JsonObject, key: []const u8) ?[]const u8 {
    const value = @constCast(object).getPtr(key) orelse return null;
    return if (value.* == .string) value.string else null;
}

pub fn intField(object: *const JsonObject, key: []const u8) ?i64 {
    const value = @constCast(object).getPtr(key) orelse return null;
    return switch (value.*) {
        .integer => |v| v,
        .float => |v| @intFromFloat(v),
        else => null,
    };
}

pub fn usizeField(object: *const JsonObject, key: []const u8) ?usize {
    const value = intField(object, key) orelse return null;
    if (value < 0) return null;
    return @intCast(value);
}

pub fn lspLine(object: *const JsonObject) usize {
    return @intCast(@max(0, intField(object, "line") orelse 0));
}

pub fn lspCharacter(object: *const JsonObject) usize {
    return @intCast(@max(0, intField(object, "character") orelse 0));
}

pub fn numberField(object: *const JsonObject, key: []const u8) ?f64 {
    const value = @constCast(object).getPtr(key) orelse return null;
    return switch (value.*) {
        .integer => |v| @floatFromInt(v),
        .float => |v| v,
        else => null,
    };
}

pub fn objectField(value: JsonValue, key: []const u8) ?*const JsonObject {
    if (value != .object) return null;
    const child = @constCast(&value.object).getPtr(key) orelse return null;
    if (child.* != .object) return null;
    return &child.object;
}

pub fn objectFieldObject(object: *const JsonObject, key: []const u8) ?*const JsonObject {
    const child = @constCast(object).getPtr(key) orelse return null;
    if (child.* != .object) return null;
    return &child.object;
}

pub fn arrayField(value: JsonValue, key: []const u8) ?*const JsonArray {
    if (value != .object) return null;
    const child = @constCast(&value.object).getPtr(key) orelse return null;
    if (child.* != .array) return null;
    return &child.array;
}

pub fn arrayFieldObject(object: *const JsonObject, key: []const u8) ?*const JsonArray {
    const child = @constCast(object).getPtr(key) orelse return null;
    if (child.* != .array) return null;
    return &child.array;
}

pub fn docPathFromParams(allocator: std.mem.Allocator, params: ?JsonValue) !?[]u8 {
    const p = params orelse return null;
    const doc = objectField(p, "textDocument") orelse return null;
    const uri = stringField(doc, "uri") orelse return null;
    return try pathFromUri(allocator, uri);
}

pub fn pathFromUri(allocator: std.mem.Allocator, uri: []const u8) ![]u8 {
    if (!std.mem.startsWith(u8, uri, "file://")) return allocator.dupe(u8, uri);
    const raw = uri["file://".len..];
    return percentDecode(allocator, raw);
}

pub fn uriFromPath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const absolute = try project.absolutePath(allocator, path);
    defer allocator.free(absolute);
    var out = std.ArrayList(u8).empty;
    try out.appendSlice(allocator, "file://");
    for (absolute) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '/' or byte == '_' or byte == '-' or byte == '.') {
            try out.append(allocator, byte);
        } else {
            try out.print(allocator, "%{X:0>2}", .{byte});
        }
    }
    return out.toOwnedSlice(allocator);
}

fn percentDecode(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] == '%' and i + 2 < text.len) {
            const value = std.fmt.parseUnsigned(u8, text[i + 1 .. i + 3], 16) catch {
                try out.append(allocator, text[i]);
                continue;
            };
            try out.append(allocator, value);
            i += 2;
        } else {
            try out.append(allocator, text[i]);
        }
    }
    return out.toOwnedSlice(allocator);
}

pub fn rangeFromSpan(text: []const u8, span: source.ByteSpan) Range {
    const start = source.utf16PositionAt(text, @min(span.start, text.len));
    const end = source.utf16PositionAt(text, @min(@max(span.end, span.start + 1), text.len));
    return .{
        .start_line = start.line,
        .start_character = start.character,
        .end_line = end.line,
        .end_character = end.character,
    };
}

pub fn appendRange(allocator: std.mem.Allocator, out: *std.ArrayList(u8), range: Range) !void {
    try out.appendSlice(allocator, "{\"start\":{\"line\":");
    try appendInt(allocator, out, range.start_line);
    try out.appendSlice(allocator, ",\"character\":");
    try appendInt(allocator, out, range.start_character);
    try out.appendSlice(allocator, "},\"end\":{\"line\":");
    try appendInt(allocator, out, range.end_line);
    try out.appendSlice(allocator, ",\"character\":");
    try appendInt(allocator, out, range.end_character);
    try out.appendSlice(allocator, "}}");
}

pub fn locationJson(allocator: std.mem.Allocator, uri: []const u8, sl: usize, sc: usize, el: usize, ec: usize) ![]u8 {
    var out = std.ArrayList(u8).empty;
    try appendLocationObject(allocator, &out, uri, sl, sc, el, ec);
    return out.toOwnedSlice(allocator);
}

pub fn appendLocationObject(allocator: std.mem.Allocator, out: *std.ArrayList(u8), uri: []const u8, sl: usize, sc: usize, el: usize, ec: usize) !void {
    try out.appendSlice(allocator, "{\"uri\":");
    try appendJsonString(allocator, out, uri);
    try out.appendSlice(allocator, ",\"range\":{\"start\":{\"line\":");
    try appendInt(allocator, out, sl);
    try out.appendSlice(allocator, ",\"character\":");
    try appendInt(allocator, out, sc);
    try out.appendSlice(allocator, "},\"end\":{\"line\":");
    try appendInt(allocator, out, el);
    try out.appendSlice(allocator, ",\"character\":");
    try appendInt(allocator, out, ec);
    try out.appendSlice(allocator, "}}}");
}

pub fn samePath(allocator: std.mem.Allocator, left: []const u8, right: []const u8) bool {
    const a = project.absolutePath(allocator, left) catch return false;
    defer allocator.free(a);
    const b = project.absolutePath(allocator, right) catch return false;
    defer allocator.free(b);
    return std.mem.eql(u8, a, b);
}
