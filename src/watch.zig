const std = @import("std");
const app = @import("app.zig");
const syntax = @import("syntax.zig");
const names = @import("language/names.zig");
const utils = @import("utils");

pub const Mode = enum {
    check,
    render,
};

pub const Options = struct {
    input_path: []const u8,
    output_path: ?[]const u8 = null,
    asset_base_dir: []const u8,
    project_file: ?[]const u8 = null,
    highlight_languages: []const utils.highlight.Language = &.{},
    jobs: ?usize = null,
    cache_id: ?[]const u8 = null,
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
            var progress = utils.progress.Progress.init(7);
            const render_options = app.RenderOptions{
                .jobs = options.jobs,
                .cache_id = options.cache_id,
                .highlight_languages = options.highlight_languages,
            };
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

pub fn fingerprint(io: std.Io, allocator: std.mem.Allocator, options: Options) !u64 {
    var hash: u64 = 14695981039346656037;
    mixBytes(&hash, options.input_path);
    try mixStatFile(io, &hash, options.input_path);
    if (options.project_file) |project_file| {
        mixBytes(&hash, project_file);
        try mixStatFile(io, &hash, project_file);
    }
    try mixHighlightLanguageStats(io, &hash, options.highlight_languages);
    try mixModuleDependencyStats(io, allocator, &hash, options);

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

fn mixHighlightLanguageStats(io: std.Io, hash: *u64, languages: []const utils.highlight.Language) !void {
    mixValue(usize, hash, languages.len);
    for (languages) |language| {
        mixBytes(hash, language.name);
        mixBytes(hash, language.parser);
        mixBytes(hash, language.query);
        mixOptionalBytes(hash, language.library);
        mixOptionalBytes(hash, language.symbol);
        if (!std.mem.startsWith(u8, language.query, "builtin:")) {
            try mixStatFile(io, hash, language.query);
        }
        if (language.library) |library| {
            try mixStatFile(io, hash, library);
        }
    }
}

fn mixModuleDependencyStats(io: std.Io, allocator: std.mem.Allocator, hash: *u64, options: Options) !void {
    var visited = std.StringHashMap(void).init(allocator);
    defer {
        var key_it = visited.keyIterator();
        while (key_it.next()) |key| allocator.free(key.*);
        visited.deinit();
    }
    try mixModuleImportGraph(io, allocator, hash, options.input_path, &visited);
}

fn mixModuleImportGraph(
    io: std.Io,
    allocator: std.mem.Allocator,
    hash: *u64,
    module_path: []const u8,
    visited: *std.StringHashMap(void),
) !void {
    const resolved_module_path = try std.fs.path.resolve(allocator, &.{module_path});
    defer allocator.free(resolved_module_path);
    if (visited.contains(resolved_module_path)) return;
    const owned_path = try allocator.dupe(u8, resolved_module_path);
    errdefer allocator.free(owned_path);
    try visited.put(owned_path, {});

    mixBytes(hash, resolved_module_path);
    try mixStatFile(io, hash, resolved_module_path);

    const source = utils.fs.readFileAlloc(io, allocator, resolved_module_path) catch return;
    defer allocator.free(source);

    var program = syntax.parseWithSourceName(allocator, source, resolved_module_path) catch return;
    defer program.deinit(allocator);

    const base_dir = std.fs.path.dirname(resolved_module_path) orelse ".";
    for (program.imports.items) |import_decl| {
        mixBytes(hash, import_decl.spec);
        if (std.mem.startsWith(u8, import_decl.spec, "std:")) continue;

        const import_path = try resolveExplicitImportPath(allocator, base_dir, import_decl.spec);
        defer allocator.free(import_path);
        mixBytes(hash, import_path);
        try mixStatFile(io, hash, import_path);
        try mixModuleImportGraph(io, allocator, hash, import_path, visited);
    }
}

fn resolveExplicitImportPath(allocator: std.mem.Allocator, base_dir: []const u8, spec: []const u8) ![]u8 {
    const path = try names.importPathWithDefaultExtension(allocator, spec);
    defer allocator.free(path);
    if (std.fs.path.isAbsolute(path)) return allocator.dupe(u8, path);
    return std.fs.path.resolve(allocator, &.{ base_dir, path });
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
        std.mem.eql(u8, ext, ".md") or
        std.mem.eql(u8, ext, ".toml");
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

fn mixOptionalBytes(hash: *u64, value: ?[]const u8) void {
    mixValue(bool, hash, value != null);
    if (value) |bytes| mixBytes(hash, bytes);
}
