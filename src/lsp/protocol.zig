const std = @import("std");
const project = @import("../project.zig");
const utils = @import("utils");

const source = utils.source;
const json = utils.json;

pub const JsonValue = json.Value;
pub const JsonObject = json.ObjectMap;
pub const JsonArray = json.ValueArray;
pub const appendJsonValue = json.appendValue;
pub const appendJsonString = json.appendString;
pub const appendInt = json.appendInt;
pub const appendBool = json.appendBool;
pub const appendFloat = json.appendFloat4;
pub const stringField = json.stringField;
pub const intField = json.intField;
pub const usizeField = json.usizeField;
pub const numberField = json.numberField;
pub const boolField = json.boolField;
pub const objectField = json.objectField;
pub const objectFieldObject = json.objectFieldObject;
pub const arrayField = json.arrayField;
pub const arrayFieldObject = json.arrayFieldObject;

const max_header_bytes = 16 * 1024;
const max_content_length = 64 * 1024 * 1024;

pub fn requiredIntField(object: *const JsonObject, key: []const u8) !i64 {
    return intField(object, key) orelse error.InvalidParams;
}

pub fn requiredUsizeField(object: *const JsonObject, key: []const u8) !usize {
    const value = try requiredIntField(object, key);
    return std.math.cast(usize, value) orelse error.InvalidParams;
}

pub fn requiredU32Field(object: *const JsonObject, key: []const u8) !u32 {
    const value = try requiredIntField(object, key);
    return std.math.cast(u32, value) orelse error.InvalidParams;
}

pub const Range = struct {
    start_line: usize,
    start_character: usize,
    end_line: usize,
    end_character: usize,
};

pub fn readMessage(allocator: std.mem.Allocator) !?[]u8 {
    var header = std.ArrayList(u8).empty;
    defer header.deinit(allocator);
    var last4 = [_]u8{ 0, 0, 0, 0 };
    while (true) {
        var byte: [1]u8 = undefined;
        const n = std.c.read(0, &byte, 1);
        switch (std.posix.errno(n)) {
            .SUCCESS => {},
            .INTR => continue,
            .IO => return error.InputOutput,
            else => |err| return std.posix.unexpectedErrno(err),
        }
        if (n == 0) return if (header.items.len == 0) null else error.UnexpectedEndOfStream;
        if (header.items.len == max_header_bytes) return error.HeaderTooLarge;
        try header.append(allocator, byte[0]);
        last4 = .{ last4[1], last4[2], last4[3], byte[0] };
        if (std.mem.eql(u8, &last4, "\r\n\r\n")) break;
    }
    const content_length = try parseContentLength(header.items);
    if (content_length > max_content_length) return error.MessageTooLarge;
    const body = try allocator.alloc(u8, content_length);
    errdefer allocator.free(body);
    var offset: usize = 0;
    while (offset < body.len) {
        const n = std.c.read(0, body[offset..].ptr, body.len - offset);
        switch (std.posix.errno(n)) {
            .SUCCESS => {},
            .INTR => continue,
            .IO => return error.InputOutput,
            else => |err| return std.posix.unexpectedErrno(err),
        }
        if (n == 0) return error.UnexpectedEndOfStream;
        offset += std.math.cast(usize, n) orelse return error.InputOutput;
    }
    return body;
}

fn parseContentLength(header: []const u8) !usize {
    var content_length: ?usize = null;
    var lines = std.mem.splitSequence(u8, header, "\r\n");
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        if (!std.ascii.eqlIgnoreCase(name, "Content-Length")) continue;
        if (content_length != null) return error.InvalidHeader;
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (value.len == 0) return error.InvalidHeader;
        for (value) |byte| if (!std.ascii.isDigit(byte)) return error.InvalidHeader;
        content_length = std.fmt.parseUnsigned(usize, value, 10) catch return error.InvalidHeader;
    }
    return content_length orelse error.InvalidHeader;
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
        switch (std.posix.errno(n)) {
            .SUCCESS => {
                if (n == 0) return error.WriteFailed;
                offset += std.math.cast(usize, n) orelse return error.WriteFailed;
            },
            .INTR => continue,
            else => return error.WriteFailed,
        }
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
    var id_json = std.ArrayList(u8).empty;
    defer id_json.deinit(allocator);
    try appendJsonValue(allocator, &id_json, id orelse .null);
    try respondErrorId(allocator, id_json.items, code, message);
}

pub fn respondErrorId(allocator: std.mem.Allocator, id_json: []const u8, code: i64, message: []const u8) !void {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"jsonrpc\":\"2.0\",\"id\":");
    try out.appendSlice(allocator, id_json);
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

pub fn lspLine(object: *const JsonObject) !usize {
    return try requiredUsizeField(object, "line");
}

pub fn lspCharacter(object: *const JsonObject) !usize {
    return try requiredUsizeField(object, "character");
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
