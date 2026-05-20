const std = @import("std");
const app = @import("app.zig");
const utils = @import("utils");

pub const Mode = enum {
    check,
    render,
};

pub const Options = struct {
    input_path: []const u8,
    output_path: ?[]const u8 = null,
    asset_base_dir: []const u8,
    jobs: ?usize = null,
    interval_ms: u64 = 500,
};

pub fn run(io: std.Io, allocator: std.mem.Allocator, mode: Mode, options: Options) !void {
    const interval_ms = @max(options.interval_ms, 50);
    var last_fingerprint = try fingerprint(io, allocator, options);

    std.debug.print("watch: {s} {s} every {d}ms\n", .{ @tagName(mode), options.input_path, interval_ms });
    _ = runOnce(io, allocator, mode, options);

    while (true) {
        const sleep_ms: i64 = @intCast(@min(interval_ms, @as(u64, std.math.maxInt(i64))));
        try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(sleep_ms), .awake);
        const next_fingerprint = fingerprint(io, allocator, options) catch |err| {
            std.debug.print("watch: failed to inspect inputs: {s}\n", .{@errorName(err)});
            continue;
        };
        if (next_fingerprint == last_fingerprint) continue;
        last_fingerprint = next_fingerprint;
        std.debug.print("watch: change detected\n", .{});
        _ = runOnce(io, allocator, mode, options);
    }
}

fn runOnce(io: std.Io, allocator: std.mem.Allocator, mode: Mode, options: Options) bool {
    switch (mode) {
        .check => {
            app.checkFileWithAssetBase(io, allocator, options.input_path, options.asset_base_dir) catch |err| {
                reportRunError("check", err);
                return false;
            };
        },
        .render => {
            const output_path = options.output_path orelse {
                std.debug.print("watch: render requires an output path\n", .{});
                return false;
            };
            var progress = app.Progress.init(7);
            const render_options = app.RenderOptions{ .jobs = options.jobs };
            app.writePdfForFileWithAssetBaseAndOptions(
                io,
                allocator,
                options.input_path,
                options.asset_base_dir,
                output_path,
                render_options,
                &progress,
            ) catch |err| {
                reportRunError("render", err);
                return false;
            };
        },
    }
    return true;
}

fn reportRunError(label: []const u8, err: anyerror) void {
    if (!utils.err.isExpectedCliError(err)) {
        std.debug.print("watch: {s} failed: {s}\n", .{ label, @errorName(err) });
    }
}

fn fingerprint(io: std.Io, allocator: std.mem.Allocator, options: Options) !u64 {
    var hash: u64 = 14695981039346656037;
    mixBytes(&hash, options.input_path);
    try mixStatFile(io, &hash, options.input_path);

    var dir = std.Io.Dir.cwd().openDir(io, options.asset_base_dir, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) return hash;
        return err;
    };
    defer dir.close(io);

    var walker = try dir.walkSelectively(allocator);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind == .directory) {
            if (!skipDirectory(entry.basename)) {
                try walker.enter(io, entry);
            }
            continue;
        }
        if (isOutputFile(allocator, options, entry.path)) continue;
        if (!watchFile(entry.path)) continue;
        const stat = entry.dir.statFile(io, entry.basename, .{}) catch continue;
        mixBytes(&hash, entry.path);
        mixValue(u64, &hash, stat.size);
        mixValue(i96, &hash, stat.mtime.nanoseconds);
        mixValue(u8, &hash, @intFromEnum(stat.kind));
    }

    return hash;
}

fn mixStatFile(io: std.Io, hash: *u64, path: []const u8) !void {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };
    mixValue(u64, hash, stat.size);
    mixValue(i96, hash, stat.mtime.nanoseconds);
    mixValue(u8, hash, @intFromEnum(stat.kind));
}

fn skipDirectory(name: []const u8) bool {
    return std.mem.eql(u8, name, ".git") or
        std.mem.eql(u8, name, ".ss-cache") or
        std.mem.eql(u8, name, ".zig-cache") or
        std.mem.eql(u8, name, "zig-out") or
        std.mem.eql(u8, name, "node_modules");
}

fn watchFile(path: []const u8) bool {
    const ext = std.fs.path.extension(path);
    return std.mem.eql(u8, ext, ".ss") or
        std.mem.eql(u8, ext, ".svg") or
        std.mem.eql(u8, ext, ".pdf") or
        std.mem.eql(u8, ext, ".png") or
        std.mem.eql(u8, ext, ".jpg") or
        std.mem.eql(u8, ext, ".jpeg") or
        std.mem.eql(u8, ext, ".gif") or
        std.mem.eql(u8, ext, ".webp") or
        std.mem.eql(u8, ext, ".tex") or
        std.mem.eql(u8, ext, ".bib") or
        std.mem.eql(u8, ext, ".ttf") or
        std.mem.eql(u8, ext, ".otf") or
        std.mem.eql(u8, ext, ".woff") or
        std.mem.eql(u8, ext, ".woff2") or
        std.mem.eql(u8, ext, ".md");
}

fn isOutputFile(allocator: std.mem.Allocator, options: Options, relative_path: []const u8) bool {
    const output_path = options.output_path orelse return false;
    if (std.mem.eql(u8, output_path, relative_path)) return true;
    const joined = std.fs.path.join(allocator, &.{ options.asset_base_dir, relative_path }) catch return false;
    defer allocator.free(joined);
    return std.mem.eql(u8, output_path, joined);
}

fn mixValue(comptime T: type, hash: *u64, value: T) void {
    var copy = value;
    mixBytes(hash, std.mem.asBytes(&copy));
}

fn mixBytes(hash: *u64, bytes: []const u8) void {
    for (bytes) |byte| {
        hash.* ^= byte;
        hash.* *%= 1099511628211;
    }
}
