const std = @import("std");

pub const ImageDimensions = struct {
    width: f32,
    height: f32,
};

pub fn readFileAlloc(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited);
}

pub fn writeFile(io: std.Io, path: []const u8, bytes: []const u8) !void {
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = path,
        .data = bytes,
        .flags = .{ .truncate = true },
    });
}

pub fn siblingPathWithExtension(
    allocator: std.mem.Allocator,
    input_path: []const u8,
    ext: []const u8,
) ![]const u8 {
    const dir = std.fs.path.dirname(input_path) orelse ".";
    const stem = std.fs.path.stem(input_path);
    return std.fmt.allocPrint(allocator, "{s}/{s}.{s}", .{ dir, stem, ext });
}

pub fn fileExists(allocator: std.mem.Allocator, path: []const u8) bool {
    const zpath = allocator.dupeZ(u8, path) catch return false;
    defer allocator.free(zpath);
    return std.c.access(zpath.ptr, 0) == 0;
}

const HEADER_BUF_SIZE = 256 * 1024;

fn readHeaderBytes(
    allocator: std.mem.Allocator,
    path: []const u8,
    buf: *[HEADER_BUF_SIZE]u8,
    invalid_err: anyerror,
) ![]u8 {
    const zpath = try allocator.dupeZ(u8, path);
    defer allocator.free(zpath);

    const fd = std.c.open(zpath.ptr, .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    if (fd < 0) return error.FileNotFound;
    defer _ = std.c.close(fd);

    const read_len = std.c.read(fd, buf, buf.len);
    if (read_len <= 0) return invalid_err;
    return buf[0..@intCast(read_len)];
}

pub fn readImageDimensions(allocator: std.mem.Allocator, path: []const u8) !ImageDimensions {
    var buf: [HEADER_BUF_SIZE]u8 = undefined;
    const bytes = try readHeaderBytes(allocator, path, &buf, error.InvalidImageAsset);

    if (parsePngDimensions(bytes)) |dimensions| return dimensions;
    if (parseGifDimensions(bytes)) |dimensions| return dimensions;
    if (parseJpegDimensions(bytes)) |dimensions| return dimensions;
    return error.UnsupportedImageFormat;
}

pub fn readPdfDimensions(allocator: std.mem.Allocator, path: []const u8) !ImageDimensions {
    var buf: [HEADER_BUF_SIZE]u8 = undefined;
    const bytes = try readHeaderBytes(allocator, path, &buf, error.InvalidPdfAsset);
    return parsePdfDimensions(bytes) orelse error.UnsupportedPdfFormat;
}

fn parsePngDimensions(bytes: []const u8) ?ImageDimensions {
    if (bytes.len < 24) return null;
    const signature = [_]u8{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n' };
    if (!std.mem.eql(u8, bytes[0..8], &signature)) return null;
    const width = std.mem.readInt(u32, bytes[16..20], .big);
    const height = std.mem.readInt(u32, bytes[20..24], .big);
    if (width == 0 or height == 0) return null;
    return .{ .width = @floatFromInt(width), .height = @floatFromInt(height) };
}

fn parseGifDimensions(bytes: []const u8) ?ImageDimensions {
    if (bytes.len < 10) return null;
    if (!std.mem.eql(u8, bytes[0..6], "GIF87a") and !std.mem.eql(u8, bytes[0..6], "GIF89a")) return null;
    const width = std.mem.readInt(u16, bytes[6..8], .little);
    const height = std.mem.readInt(u16, bytes[8..10], .little);
    if (width == 0 or height == 0) return null;
    return .{ .width = @floatFromInt(width), .height = @floatFromInt(height) };
}

fn parseJpegDimensions(bytes: []const u8) ?ImageDimensions {
    if (bytes.len < 4) return null;
    if (bytes[0] != 0xff or bytes[1] != 0xd8) return null;

    var i: usize = 2;
    while (i + 8 < bytes.len) {
        if (bytes[i] != 0xff) {
            i += 1;
            continue;
        }
        while (i < bytes.len and bytes[i] == 0xff) : (i += 1) {}
        if (i >= bytes.len) break;
        const marker = bytes[i];
        i += 1;

        if (marker == 0xd8 or marker == 0xd9) continue;
        if (marker == 0x01 or (marker >= 0xd0 and marker <= 0xd7)) continue;
        if (i + 2 > bytes.len) break;

        const segment_len = std.mem.readInt(u16, bytes[i..][0..2], .big);
        if (segment_len < 2 or i + segment_len > bytes.len) break;

        const is_sof = switch (marker) {
            0xc0...0xc3, 0xc5...0xc7, 0xc9...0xcb, 0xcd...0xcf => true,
            else => false,
        };
        if (is_sof and segment_len >= 7) {
            const height = std.mem.readInt(u16, bytes[i + 3 ..][0..2], .big);
            const width = std.mem.readInt(u16, bytes[i + 5 ..][0..2], .big);
            if (width == 0 or height == 0) return null;
            return .{ .width = @floatFromInt(width), .height = @floatFromInt(height) };
        }

        i += segment_len;
    }

    return null;
}

fn parsePdfDimensions(bytes: []const u8) ?ImageDimensions {
    const needle = "/MediaBox";
    const start = std.mem.indexOf(u8, bytes, needle) orelse return null;
    var i = start + needle.len;
    while (i < bytes.len and std.ascii.isWhitespace(bytes[i])) : (i += 1) {}
    if (i >= bytes.len or bytes[i] != '[') return null;
    i += 1;

    var values: [4]f32 = undefined;
    var count: usize = 0;
    while (count < values.len and i < bytes.len) {
        while (i < bytes.len and (std.ascii.isWhitespace(bytes[i]) or bytes[i] == '[')) : (i += 1) {}
        if (i >= bytes.len or bytes[i] == ']') break;
        const token_start = i;
        while (i < bytes.len and !std.ascii.isWhitespace(bytes[i]) and bytes[i] != ']') : (i += 1) {}
        if (token_start == i) break;
        values[count] = std.fmt.parseFloat(f32, bytes[token_start..i]) catch return null;
        count += 1;
    }
    if (count != 4) return null;

    const width = @abs(values[2] - values[0]);
    const height = @abs(values[3] - values[1]);
    if (width <= 0 or height <= 0) return null;
    return .{ .width = width, .height = height };
}

