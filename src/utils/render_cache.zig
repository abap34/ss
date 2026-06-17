const std = @import("std");
const cache_gc = @import("cache").gc;

pub const path = ".ss-cache/render";
const artifacts_path = path ++ "/artifacts";
const leases_path = path ++ "/leases";

const cache_size_kib: u64 = 1024;
const cache_size_mib: u64 = cache_size_kib * 1024;
const cache_size_gib: u64 = cache_size_mib * 1024;
const default_cache_budget: u64 = 512 * cache_size_mib;

pub const Stats = cache_gc.Stats;

pub fn clear(io: std.Io, allocator: std.mem.Allocator) !void {
    try cache_gc.pruneStaleLeases(allocator, io, leases_path);
    if (try cache_gc.activeLeaseExists(allocator, io, leases_path)) return error.ActiveRenderCacheLease;
    std.Io.Dir.cwd().deleteTree(io, path) catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };
}

pub fn stats(io: std.Io, allocator: std.mem.Allocator) !Stats {
    return cache_gc.stats(allocator, io, path);
}

pub fn pruneFromEnv(io: std.Io, allocator: std.mem.Allocator) !void {
    const max_bytes = configuredMaxBytes() orelse return;
    try cache_gc.pruneBySize(allocator, io, artifacts_path, max_bytes);
}

fn configuredMaxBytes() ?u64 {
    const raw = std.c.getenv("SS_CACHE_MAX_BYTES") orelse return default_cache_budget;
    const text = std.mem.trim(u8, std.mem.span(raw), " \t\r\n");
    if (text.len == 0) return null;
    if (std.ascii.eqlIgnoreCase(text, "off")) return null;
    return parseByteBudget(text) catch null;
}

fn parseByteBudget(text: []const u8) !u64 {
    const suffix = text[text.len - 1];
    const multiplier: u64 = switch (suffix) {
        'k', 'K' => cache_size_kib,
        'm', 'M' => cache_size_mib,
        'g', 'G' => cache_size_gib,
        'b', 'B' => 1,
        else => 1,
    };
    const number_text = if (std.ascii.isAlphabetic(suffix)) text[0 .. text.len - 1] else text;
    const trimmed = std.mem.trim(u8, number_text, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidCacheBudget;
    const value = try std.fmt.parseUnsigned(u64, trimmed, 10);
    return std.math.mul(u64, value, multiplier) catch error.InvalidCacheBudget;
}
