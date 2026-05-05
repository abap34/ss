const std = @import("std");

pub const Rgb = struct {
    r: f32,
    g: f32,
    b: f32,
};

const NamedColor = struct {
    name: []const u8,
    rgb: Rgb,
};

const named_colors = [_]NamedColor{
    .{ .name = "black", .rgb = .{ .r = 0, .g = 0, .b = 0 } },
    .{ .name = "white", .rgb = .{ .r = 1, .g = 1, .b = 1 } },
    .{ .name = "red", .rgb = .{ .r = 1, .g = 0, .b = 0 } },
    .{ .name = "green", .rgb = .{ .r = 0, .g = 128.0 / 255.0, .b = 0 } },
    .{ .name = "lime", .rgb = .{ .r = 0, .g = 1, .b = 0 } },
    .{ .name = "blue", .rgb = .{ .r = 0, .g = 0, .b = 1 } },
    .{ .name = "yellow", .rgb = .{ .r = 1, .g = 1, .b = 0 } },
    .{ .name = "cyan", .rgb = .{ .r = 0, .g = 1, .b = 1 } },
    .{ .name = "aqua", .rgb = .{ .r = 0, .g = 1, .b = 1 } },
    .{ .name = "magenta", .rgb = .{ .r = 1, .g = 0, .b = 1 } },
    .{ .name = "fuchsia", .rgb = .{ .r = 1, .g = 0, .b = 1 } },
    .{ .name = "gray", .rgb = .{ .r = 128.0 / 255.0, .g = 128.0 / 255.0, .b = 128.0 / 255.0 } },
    .{ .name = "grey", .rgb = .{ .r = 128.0 / 255.0, .g = 128.0 / 255.0, .b = 128.0 / 255.0 } },
    .{ .name = "silver", .rgb = .{ .r = 192.0 / 255.0, .g = 192.0 / 255.0, .b = 192.0 / 255.0 } },
    .{ .name = "maroon", .rgb = .{ .r = 128.0 / 255.0, .g = 0, .b = 0 } },
    .{ .name = "olive", .rgb = .{ .r = 128.0 / 255.0, .g = 128.0 / 255.0, .b = 0 } },
    .{ .name = "purple", .rgb = .{ .r = 128.0 / 255.0, .g = 0, .b = 128.0 / 255.0 } },
    .{ .name = "teal", .rgb = .{ .r = 0, .g = 128.0 / 255.0, .b = 128.0 / 255.0 } },
    .{ .name = "navy", .rgb = .{ .r = 0, .g = 0, .b = 128.0 / 255.0 } },
    .{ .name = "orange", .rgb = .{ .r = 1, .g = 165.0 / 255.0, .b = 0 } },
};

pub fn parse(raw: []const u8) ?Rgb {
    const text = trim(raw);
    if (text.len == 0) return null;
    if (colorLiteralPayload(text)) |payload| return parse(payload);
    if (text[0] == '#') return parseHex(text[1..]);
    if (std.mem.indexOfScalar(u8, text, ',') != null) return parseFloatList(text);
    return parseNamed(text);
}

pub fn normalizeAlloc(allocator: std.mem.Allocator, raw: []const u8) !?[]const u8 {
    const rgb = parse(raw) orelse return null;
    const normalized = try std.fmt.allocPrint(allocator, "{d},{d},{d}", .{ rgb.r, rgb.g, rgb.b });
    return normalized;
}

fn parseNamed(text: []const u8) ?Rgb {
    for (named_colors) |item| {
        if (std.ascii.eqlIgnoreCase(text, item.name)) return item.rgb;
    }
    return null;
}

fn parseFloatList(text: []const u8) ?Rgb {
    var parts = std.mem.splitScalar(u8, text, ',');
    const r_text = parts.next() orelse return null;
    const g_text = parts.next() orelse return null;
    const b_text = parts.next() orelse return null;
    if (parts.next() != null) return null;
    return .{
        .r = parseUnitFloat(r_text) orelse return null,
        .g = parseUnitFloat(g_text) orelse return null,
        .b = parseUnitFloat(b_text) orelse return null,
    };
}

fn parseUnitFloat(text: []const u8) ?f32 {
    const value = std.fmt.parseFloat(f32, trim(text)) catch return null;
    if (!std.math.isFinite(value)) return null;
    if (value < 0 or value > 1) return null;
    return value;
}

fn parseHex(text: []const u8) ?Rgb {
    return switch (text.len) {
        3, 4 => .{
            .r = @as(f32, @floatFromInt(hexNibble(text[0]) orelse return null)) / 15.0,
            .g = @as(f32, @floatFromInt(hexNibble(text[1]) orelse return null)) / 15.0,
            .b = @as(f32, @floatFromInt(hexNibble(text[2]) orelse return null)) / 15.0,
        },
        6, 8 => .{
            .r = @as(f32, @floatFromInt(hexByte(text[0], text[1]) orelse return null)) / 255.0,
            .g = @as(f32, @floatFromInt(hexByte(text[2], text[3]) orelse return null)) / 255.0,
            .b = @as(f32, @floatFromInt(hexByte(text[4], text[5]) orelse return null)) / 255.0,
        },
        else => null,
    };
}

fn hexByte(high: u8, low: u8) ?u8 {
    const hi = hexNibble(high) orelse return null;
    const lo = hexNibble(low) orelse return null;
    return hi * 16 + lo;
}

fn hexNibble(ch: u8) ?u8 {
    return switch (ch) {
        '0'...'9' => ch - '0',
        'a'...'f' => ch - 'a' + 10,
        'A'...'F' => ch - 'A' + 10,
        else => null,
    };
}

fn colorLiteralPayload(text: []const u8) ?[]const u8 {
    if (text.len < 3 or text[0] != 'c' or text[1] != '"' or text[text.len - 1] != '"') return null;
    return text[2 .. text.len - 1];
}

fn trim(text: []const u8) []const u8 {
    return std.mem.trim(u8, text, " \t\r\n");
}
