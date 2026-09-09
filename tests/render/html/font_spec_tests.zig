const std = @import("std");
const testing = std.testing;
const font = @import("render_html_font");

// Fontconfig/FreeType encode a variable font's selected named instance in the
// upper 16 bits of a face index (bit 16 and above hold instance + 1). A face
// index resolved through fontconfig (as the PDF backend does via Pango) can
// therefore be a large, non-zero value even for an ordinary single-face font,
// or even for the very first face of a real TTC. `extractFace` must ignore
// that instance selector and only look at the lower 16 bits when locating the
// sfnt/TTC directory.
const named_instance_bits: u32 = 7 << 16;

fn writeMinimalDirectory(buffer: []u8, offset: usize) void {
    // A single-table sfnt directory: a 12 byte header, one "head" table
    // record, and a 12 byte "head" table body (the minimum extractDirectory
    // requires).
    std.mem.writeInt(u32, buffer[offset..][0..4], 0x00010000, .big); // sfntVersion
    std.mem.writeInt(u16, buffer[offset + 4 ..][0..2], 1, .big); // numTables
    std.mem.writeInt(u16, buffer[offset + 6 ..][0..2], 0, .big); // searchRange
    std.mem.writeInt(u16, buffer[offset + 8 ..][0..2], 0, .big); // entrySelector
    std.mem.writeInt(u16, buffer[offset + 10 ..][0..2], 0, .big); // rangeShift

    const record = offset + 12;
    @memcpy(buffer[record..][0..4], "head");
    std.mem.writeInt(u32, buffer[record + 4 ..][0..4], 0, .big); // checksum (unused)
    std.mem.writeInt(u32, buffer[record + 8 ..][0..4], @intCast(offset + 28), .big); // table offset
    std.mem.writeInt(u32, buffer[record + 12 ..][0..4], 12, .big); // table length

    @memset(buffer[offset + 28 ..][0..12], 0);
}

const minimal_directory_size = 40;

fn buildSingleFaceFont(allocator: std.mem.Allocator) ![]u8 {
    const buffer = try allocator.alloc(u8, minimal_directory_size);
    writeMinimalDirectory(buffer, 0);
    return buffer;
}

fn buildTwoFaceCollection(allocator: std.mem.Allocator) ![]u8 {
    const face0_offset = 20;
    const face1_offset = face0_offset + minimal_directory_size;
    const buffer = try allocator.alloc(u8, face1_offset + minimal_directory_size);

    @memcpy(buffer[0..4], "ttcf");
    std.mem.writeInt(u32, buffer[4..8], 0x00010000, .big);
    std.mem.writeInt(u32, buffer[8..12], 2, .big); // numFonts
    std.mem.writeInt(u32, buffer[12..16], @intCast(face0_offset), .big);
    std.mem.writeInt(u32, buffer[16..20], @intCast(face1_offset), .big);

    writeMinimalDirectory(buffer, face0_offset);
    writeMinimalDirectory(buffer, face1_offset);
    return buffer;
}

test "extractFace ignores a named-instance selector packed into a plain font's face index" {
    const source = try buildSingleFaceFont(testing.allocator);
    defer testing.allocator.free(source);

    const face = try font.extractFace(testing.allocator, source, named_instance_bits);
    defer testing.allocator.free(face.bytes);
}

test "extractFace still rejects a genuinely out-of-range face index on a plain font" {
    const source = try buildSingleFaceFont(testing.allocator);
    defer testing.allocator.free(source);

    try testing.expectError(error.InvalidFontFaceIndex, font.extractFace(testing.allocator, source, named_instance_bits | 1));
}

test "extractFace ignores a named-instance selector packed into a TTC face index" {
    const source = try buildTwoFaceCollection(testing.allocator);
    defer testing.allocator.free(source);

    const face = try font.extractFace(testing.allocator, source, named_instance_bits | 1);
    defer testing.allocator.free(face.bytes);
}

test "extractFace still rejects a genuinely out-of-range face index on a TTC" {
    const source = try buildTwoFaceCollection(testing.allocator);
    defer testing.allocator.free(source);

    try testing.expectError(error.InvalidFontFaceIndex, font.extractFace(testing.allocator, source, named_instance_bits | 2));
}
