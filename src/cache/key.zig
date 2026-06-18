const std = @import("std");

pub const Digest = u64;

pub const Builder = struct {
    hasher: std.hash.Wyhash = std.hash.Wyhash.init(0),

    pub fn string(self: *Builder, value: []const u8) void {
        self.putUsize(value.len);
        self.hasher.update(value);
    }

    pub fn optionalString(self: *Builder, value: ?[]const u8) void {
        self.putBool(value != null);
        if (value) |text| self.string(text);
    }

    pub fn putBool(self: *Builder, value: bool) void {
        const byte: u8 = if (value) 1 else 0;
        self.hasher.update(&.{byte});
    }

    pub fn putUsize(self: *Builder, value: usize) void {
        self.putU64(@intCast(value));
    }

    pub fn putU64(self: *Builder, value: u64) void {
        self.hasher.update(std.mem.asBytes(&value));
    }

    pub fn putU32(self: *Builder, value: u32) void {
        self.hasher.update(std.mem.asBytes(&value));
    }

    pub fn putF32(self: *Builder, value: f32) void {
        self.hasher.update(std.mem.asBytes(&value));
    }

    pub fn finish(self: *Builder) Digest {
        return self.hasher.final();
    }
};

pub fn name(allocator: std.mem.Allocator, prefix: []const u8, digest: Digest, extension: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}-{x}.{s}", .{ prefix, digest, extension });
}

pub fn directoryName(allocator: std.mem.Allocator, prefix: []const u8, digest: Digest) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}-{x}", .{ prefix, digest });
}

pub fn safeName(value: []const u8) bool {
    if (value.len == 0 or value.len > 160) return false;
    for (value) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.') continue;
        return false;
    }
    return true;
}
