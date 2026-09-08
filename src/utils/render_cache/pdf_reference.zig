const std = @import("std");

pub const version = "ss-pdf-output-manifest-v3";
pub const read_limit = 2 * 1024 * 1024;

/// Reads the document dependency while leaving page records to the PDF backend.
pub fn document(lines: *std.mem.SplitIterator(u8, .scalar)) ![32]u8 {
    if (!std.mem.eql(u8, lines.next() orelse return error.InvalidOutputManifest, version)) return error.InvalidOutputManifest;
    const line = lines.next() orelse return error.InvalidOutputManifest;
    if (!std.mem.startsWith(u8, line, "document\t")) return error.InvalidOutputManifest;
    const hex = line["document\t".len..];
    if (hex.len != 64) return error.InvalidOutputManifest;
    var digest: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&digest, hex) catch return error.InvalidOutputManifest;
    return digest;
}
