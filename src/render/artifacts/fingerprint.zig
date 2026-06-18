const std = @import("std");
const core = @import("core");

pub const FileFingerprint = struct {
    present: bool,
    digest: u64,
};

pub fn resolveAssetPath(allocator: std.mem.Allocator, asset_base_dir: []const u8, rel_path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(rel_path)) return allocator.dupe(u8, rel_path);
    return std.fs.path.join(allocator, &.{ asset_base_dir, rel_path });
}

pub fn streamFileFingerprint(allocator: std.mem.Allocator, io: std.Io, source: []const u8) !FileFingerprint {
    var file = std.Io.Dir.cwd().openFile(io, source, .{}) catch |err| switch (err) {
        error.FileNotFound => return .{ .present = false, .digest = 0 },
        else => return err,
    };
    defer file.close(io);

    var file_buffer: [16 * 1024]u8 = undefined;
    var reader = std.Io.File.Reader.init(file, io, file_buffer[0..]);
    var chunk: [16 * 1024]u8 = undefined;
    var digest_hasher = std.hash.Wyhash.init(0);
    while (true) {
        const read_len = reader.interface.readSliceShort(chunk[0..]) catch return error.ArtifactReadFailed;
        if (read_len == 0) break;
        digest_hasher.update(chunk[0..read_len]);
    }
    _ = allocator;
    return .{ .present = true, .digest = digest_hasher.final() };
}

pub fn hashLogicalAssetPath(hasher: *std.hash.Wyhash, asset_base_dir: []const u8, source: []const u8) void {
    if (asset_base_dir.len > 0 and !std.mem.eql(u8, asset_base_dir, ".")) {
        if (std.mem.eql(u8, source, asset_base_dir)) {
            hashString(hasher, ".");
            return;
        }
        if (source.len > asset_base_dir.len and source[asset_base_dir.len] == std.fs.path.sep and std.mem.eql(u8, source[0..asset_base_dir.len], asset_base_dir)) {
            hashString(hasher, source[asset_base_dir.len + 1 ..]);
            return;
        }
    }
    if (std.mem.startsWith(u8, source, "./")) {
        hashString(hasher, source[2..]);
        return;
    }
    hashString(hasher, source);
}

pub fn hashFile(hasher: *std.hash.Wyhash, fingerprint: FileFingerprint) void {
    hashBool(hasher, fingerprint.present);
    hashU64(hasher, fingerprint.digest);
}

pub fn hashTexPreambleEntries(
    allocator: std.mem.Allocator,
    io: std.Io,
    asset_base_dir: []const u8,
    hasher: *std.hash.Wyhash,
    preamble: []const core.render_env.TexPreambleEntry,
) !void {
    hashUsize(hasher, preamble.len);
    for (preamble) |entry| {
        hashString(hasher, @tagName(entry.source));
        hashString(hasher, entry.value);
        if (entry.source == .file) {
            const source = try resolveAssetPath(allocator, asset_base_dir, entry.value);
            defer allocator.free(source);
            hashLogicalAssetPath(hasher, asset_base_dir, source);
            hashFile(hasher, try streamFileFingerprint(allocator, io, source));
        }
    }
}

pub fn hashString(hasher: *std.hash.Wyhash, value: []const u8) void {
    hashUsize(hasher, value.len);
    hasher.update(value);
}

pub fn hashBool(hasher: *std.hash.Wyhash, value: bool) void {
    const byte: u8 = if (value) 1 else 0;
    hasher.update(&.{byte});
}

pub fn hashUsize(hasher: *std.hash.Wyhash, value: usize) void {
    hashU64(hasher, @intCast(value));
}

pub fn hashU64(hasher: *std.hash.Wyhash, value: u64) void {
    hasher.update(std.mem.asBytes(&value));
}

pub fn hashU32(hasher: *std.hash.Wyhash, value: u32) void {
    hasher.update(std.mem.asBytes(&value));
}

pub fn hashF32(hasher: *std.hash.Wyhash, value: f32) void {
    hasher.update(std.mem.asBytes(&value));
}
