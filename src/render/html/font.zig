const std = @import("std");

pub const Face = struct {
    bytes: []u8,
    extension: []const u8,
};

pub fn extractFace(allocator: std.mem.Allocator, source: []const u8, face_index: u32) !Face {
    if (!std.mem.startsWith(u8, source, "ttcf")) {
        if (face_index != 0) return error.InvalidFontFaceIndex;
        try checkEmbeddingPermission(source, 0);
        return try extractDirectory(allocator, source, 0);
    }
    if (source.len < 12) return error.InvalidFontCollection;
    const count = try readU32(source, 8);
    if (face_index >= count) return error.InvalidFontFaceIndex;
    const directory_offset = try readU32(source, 12 + @as(usize, face_index) * 4);
    try checkEmbeddingPermission(source, directory_offset);
    return try extractDirectory(allocator, source, directory_offset);
}

fn extractDirectory(allocator: std.mem.Allocator, source: []const u8, directory_offset_u32: u32) !Face {
    const directory_offset: usize = directory_offset_u32;
    if (directory_offset + 12 > source.len) return error.InvalidFontCollection;
    const table_count = try readU16(source, directory_offset + 4);
    if (table_count == 0 or table_count > 4096) return error.InvalidFontCollection;
    const records_end = directory_offset + 12 + @as(usize, table_count) * 16;
    if (records_end > source.len) return error.InvalidFontCollection;

    var output_size = align4(12 + @as(usize, table_count) * 16);
    for (0..table_count) |index| {
        const record = directory_offset + 12 + index * 16;
        const offset = try readU32(source, record + 8);
        const length = try readU32(source, record + 12);
        if (@as(usize, offset) + @as(usize, length) > source.len) return error.InvalidFontCollection;
        output_size = std.math.add(usize, output_size, align4(length)) catch return error.FontTooLarge;
    }
    const output = try allocator.alloc(u8, output_size);
    errdefer allocator.free(output);
    @memset(output, 0);
    @memcpy(output[0..12], source[directory_offset .. directory_offset + 12]);

    var next_offset = align4(12 + @as(usize, table_count) * 16);
    var head_offset: ?usize = null;
    for (0..table_count) |index| {
        const source_record = directory_offset + 12 + index * 16;
        const output_record = 12 + index * 16;
        const source_offset = try readU32(source, source_record + 8);
        const length = try readU32(source, source_record + 12);
        @memcpy(output[output_record .. output_record + 4], source[source_record .. source_record + 4]);
        @memcpy(output[next_offset .. next_offset + length], source[source_offset .. source_offset + length]);
        const tag = output[output_record .. output_record + 4];
        if (std.mem.eql(u8, tag, "head")) {
            if (length < 12) return error.InvalidFontCollection;
            head_offset = next_offset;
            writeU32(output, next_offset + 8, 0);
        }
        writeU32(output, output_record + 4, checksum(output[next_offset .. next_offset + align4(length)]));
        writeU32(output, output_record + 8, @intCast(next_offset));
        writeU32(output, output_record + 12, length);
        next_offset += align4(length);
    }
    if (head_offset) |offset| {
        writeU32(output, offset + 8, 0xb1b0afba -% checksum(output));
    }
    return .{ .bytes = output, .extension = sfntExtension(output) };
}

fn checkEmbeddingPermission(source: []const u8, directory_offset_u32: u32) !void {
    const directory_offset: usize = directory_offset_u32;
    if (directory_offset + 12 > source.len) return error.InvalidFontCollection;
    const table_count = try readU16(source, directory_offset + 4);
    if (directory_offset + 12 + @as(usize, table_count) * 16 > source.len) return error.InvalidFontCollection;
    for (0..table_count) |index| {
        const record = directory_offset + 12 + index * 16;
        if (!std.mem.eql(u8, source[record .. record + 4], "OS/2")) continue;
        const offset = try readU32(source, record + 8);
        const length = try readU32(source, record + 12);
        if (length < 10 or @as(usize, offset) + @as(usize, length) > source.len) return error.InvalidFontCollection;
        const fs_type = try readU16(source, offset + 8);
        if ((fs_type & 0x0002) != 0 or (fs_type & 0x0200) != 0) return error.FontEmbeddingRestricted;
        return;
    }
}

fn sfntExtension(bytes: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, bytes, "OTTO")) "otf" else "ttf";
}

fn align4(value: anytype) usize {
    const converted: usize = @intCast(value);
    return (converted + 3) & ~@as(usize, 3);
}

fn checksum(bytes: []const u8) u32 {
    var result: u32 = 0;
    var offset: usize = 0;
    while (offset < bytes.len) : (offset += 4) {
        var word: [4]u8 = .{ 0, 0, 0, 0 };
        const length = @min(4, bytes.len - offset);
        @memcpy(word[0..length], bytes[offset .. offset + length]);
        result +%= std.mem.readInt(u32, &word, .big);
    }
    return result;
}

fn readU16(bytes: []const u8, offset: usize) !u16 {
    if (offset + 2 > bytes.len) return error.InvalidFontCollection;
    return std.mem.readInt(u16, bytes[offset..][0..2], .big);
}

fn readU32(bytes: []const u8, offset: usize) !u32 {
    if (offset + 4 > bytes.len) return error.InvalidFontCollection;
    return std.mem.readInt(u32, bytes[offset..][0..4], .big);
}

fn writeU32(bytes: []u8, offset: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[offset..][0..4], value, .big);
}
