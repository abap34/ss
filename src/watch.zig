const std = @import("std");
const app = @import("app.zig");
const syntax = @import("syntax.zig");
const names = @import("language/names.zig");
const module_loader = @import("modules/loader.zig");
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
    format: app.RenderFormat = .pdf,
    jobs: ?usize = null,
    interval_ms: u64 = 500,
    quiet: bool = false,
};

pub const FingerprintTarget = enum {
    input_file,
    project_configuration,
    highlight_query,
    imported_source,
    asset_base,
    asset_path,
};

pub const FingerprintFailure = struct {
    target: FingerprintTarget,
    path: []u8,
    cause: anyerror,

    pub fn deinit(self: *FingerprintFailure, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        self.* = undefined;
    }
};

pub const FingerprintInspection = union(enum) {
    value: u64,
    failure: FingerprintFailure,

    pub fn deinit(self: *FingerprintInspection, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .value => {},
            .failure => |*failure| failure.deinit(allocator),
        }
        self.* = undefined;
    }
};

const FingerprintContext = struct {
    allocator: std.mem.Allocator,
    failure: ?FingerprintFailure = null,

    fn deinit(self: *FingerprintContext) void {
        if (self.failure) |*failure| failure.deinit(self.allocator);
        self.* = undefined;
    }

    fn record(self: *FingerprintContext, target: FingerprintTarget, path: []const u8, cause: anyerror) !void {
        std.debug.assert(self.failure == null);
        self.failure = .{
            .target = target,
            .path = try self.allocator.dupe(u8, path),
            .cause = cause,
        };
    }

    fn take(self: *FingerprintContext) ?FingerprintFailure {
        const failure = self.failure;
        self.failure = null;
        return failure;
    }
};

pub fn run(io: std.Io, allocator: std.mem.Allocator, mode: Mode, options: Options) !void {
    const interval_ms = @max(options.interval_ms, 50);
    var initial_inspection = inspectFingerprint(io, allocator, options) catch |err| {
        printUnlocatedFingerprintFailure(options, err);
        return error.DiagnosticsFailed;
    };
    var last_fingerprint = switch (initial_inspection) {
        .value => |value| value,
        .failure => |failure| {
            printFingerprintFailure(failure);
            initial_inspection.deinit(allocator);
            return error.DiagnosticsFailed;
        },
    };
    initial_inspection.deinit(allocator);

    var last_failure: ?FingerprintFailure = null;
    defer if (last_failure) |*failure| failure.deinit(allocator);
    var last_unlocated_error: ?anyerror = null;
    var embedded_cache = module_loader.EmbeddedSyntaxCache.init(allocator);
    defer embedded_cache.deinit();

    std.debug.print("watch: {s} {s} every {d}ms\n", .{ @tagName(mode), options.input_path, interval_ms });
    _ = runOnce(io, allocator, mode, options, &embedded_cache);

    while (true) {
        const sleep_ms: i64 = @intCast(@min(interval_ms, @as(u64, std.math.maxInt(i64))));
        try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(sleep_ms), .awake);
        var inspection = inspectFingerprint(io, allocator, options) catch |err| {
            clearFingerprintFailure(allocator, &last_failure);
            if (last_unlocated_error == null or last_unlocated_error.? != err) {
                printUnlocatedFingerprintFailure(options, err);
            }
            last_unlocated_error = err;
            continue;
        };
        defer inspection.deinit(allocator);
        const next_fingerprint = switch (inspection) {
            .value => |value| blk: {
                if (last_failure) |failure| printFingerprintRecovery(failure);
                if (last_unlocated_error != null) {
                    std.debug.print("watch: input inspection recovered\n", .{});
                }
                clearFingerprintFailure(allocator, &last_failure);
                last_unlocated_error = null;
                break :blk value;
            },
            .failure => |failure| {
                last_unlocated_error = null;
                if (!sameFingerprintFailure(last_failure, failure)) {
                    printFingerprintFailure(failure);
                    try replaceFingerprintFailure(allocator, &last_failure, failure);
                }
                continue;
            },
        };
        if (next_fingerprint == last_fingerprint) continue;
        last_fingerprint = next_fingerprint;
        std.debug.print("watch: change detected\n", .{});
        _ = runOnce(io, allocator, mode, options, &embedded_cache);
    }
}

fn sameFingerprintFailure(previous: ?FingerprintFailure, current: FingerprintFailure) bool {
    const prior = previous orelse return false;
    return prior.target == current.target and
        prior.cause == current.cause and
        std.mem.eql(u8, prior.path, current.path);
}

fn replaceFingerprintFailure(
    allocator: std.mem.Allocator,
    destination: *?FingerprintFailure,
    source: FingerprintFailure,
) !void {
    const path = try allocator.dupe(u8, source.path);
    clearFingerprintFailure(allocator, destination);
    destination.* = .{
        .target = source.target,
        .path = path,
        .cause = source.cause,
    };
}

fn clearFingerprintFailure(allocator: std.mem.Allocator, failure: *?FingerprintFailure) void {
    if (failure.*) |*value| value.deinit(allocator);
    failure.* = null;
}

fn printFingerprintRecovery(failure: FingerprintFailure) void {
    std.debug.print(
        "watch: recovered access to {s} '{s}'\n",
        .{ fingerprintTargetLabel(failure.target), failure.path },
    );
}

fn printUnlocatedFingerprintFailure(options: Options, err: anyerror) void {
    var reason_buf: [256]u8 = undefined;
    std.debug.print(
        "watch: could not inspect inputs for '{s}' with asset base '{s}': {s}\n",
        .{ options.input_path, options.asset_base_dir, utils.err.formatErrorReason(&reason_buf, err) },
    );
}

fn printFingerprintFailure(failure: FingerprintFailure) void {
    var reason_buf: [256]u8 = undefined;
    std.debug.print(
        "watch: could not inspect {s} '{s}': {s}\n",
        .{ fingerprintTargetLabel(failure.target), failure.path, utils.err.formatErrorReason(&reason_buf, failure.cause) },
    );
}

fn fingerprintTargetLabel(target: FingerprintTarget) []const u8 {
    return switch (target) {
        .input_file => "input file",
        .project_configuration => "project configuration",
        .highlight_query => "highlight query",
        .imported_source => "imported source",
        .asset_base => "asset base directory",
        .asset_path => "asset path",
    };
}

fn runOnce(io: std.Io, allocator: std.mem.Allocator, mode: Mode, options: Options, embedded_cache: *module_loader.EmbeddedSyntaxCache) bool {
    switch (mode) {
        .check => {
            app.checkFile(io, allocator, .{
                .input_path = options.input_path,
                .asset_base_dir = options.asset_base_dir,
                .highlight_languages = options.highlight_languages,
                .embedded_cache = embedded_cache,
            }, null) catch |err| {
                reportRunError("check", err);
                return false;
            };
        },
        .render => {
            const output_path = options.output_path orelse {
                std.debug.print("watch: render requires an output path\n", .{});
                return false;
            };
            var progress = if (options.quiet)
                utils.progress.Progress.disabled(app.render_progress_steps)
            else
                utils.progress.Progress.init(app.render_progress_steps);
            const render_options = app.RenderOptions{
                .jobs = options.jobs,
                .highlight_languages = options.highlight_languages,
            };
            const source = app.SourceRequest{
                .input_path = options.input_path,
                .asset_base_dir = options.asset_base_dir,
                .layout_jobs = options.jobs,
                .highlight_languages = options.highlight_languages,
                .embedded_cache = embedded_cache,
            };
            (switch (options.format) {
                .pdf => app.writePdf(io, allocator, .{
                    .source = source,
                    .output_path = output_path,
                    .options = .{ .render = render_options },
                }, &progress),
                .html => app.writeHtml(io, allocator, .{
                    .source = source,
                    .output_path = output_path,
                    .options = .{ .render = render_options },
                }, &progress),
            }) catch |err| {
                reportRunError("render", err);
                return false;
            };
        },
    }
    return true;
}

fn reportRunError(label: []const u8, err: anyerror) void {
    if (!utils.err.isExpectedCliError(err)) {
        var reason_buf: [256]u8 = undefined;
        std.debug.print("watch: {s} failed: {s}\n", .{ label, utils.err.formatErrorReason(&reason_buf, err) });
    }
}

pub fn fingerprint(io: std.Io, allocator: std.mem.Allocator, options: Options) !u64 {
    var inspection = try inspectFingerprint(io, allocator, options);
    defer inspection.deinit(allocator);
    switch (inspection) {
        .value => |value| return value,
        .failure => |failure| return failure.cause,
    }
}

pub fn inspectFingerprint(io: std.Io, allocator: std.mem.Allocator, options: Options) !FingerprintInspection {
    var context = FingerprintContext{ .allocator = allocator };
    defer context.deinit();
    const value = fingerprintImpl(io, allocator, options, &context) catch |err| {
        if (context.take()) |failure| return .{ .failure = failure };
        return err;
    };
    return .{ .value = value };
}

fn fingerprintImpl(
    io: std.Io,
    allocator: std.mem.Allocator,
    options: Options,
    context: *FingerprintContext,
) !u64 {
    var hash: u64 = 14695981039346656037;
    mixBytes(&hash, options.input_path);
    try mixStatFile(io, &hash, options.input_path, .input_file, context);
    if (options.project_file) |project_file| {
        mixBytes(&hash, project_file);
        try mixStatFile(io, &hash, project_file, .project_configuration, context);
    }
    try mixHighlightLanguageStats(io, &hash, options.highlight_languages, context);
    try mixModuleDependencyStats(io, allocator, &hash, options, context);

    var dir = std.Io.Dir.cwd().openDir(io, options.asset_base_dir, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) return hash;
        try context.record(.asset_base, options.asset_base_dir, err);
        return err;
    };
    defer dir.close(io);

    var walker = try dir.walkSelectively(allocator);
    defer walker.deinit();

    while (walker.next(io) catch |err| {
        try context.record(.asset_base, options.asset_base_dir, err);
        return err;
    }) |entry| {
        if (entry.kind == .directory) {
            if (!skipDirectory(entry.basename) and !isOutputPath(allocator, options, entry.path)) {
                walker.enter(io, entry) catch |err| {
                    try recordAssetFailure(allocator, context, options.asset_base_dir, entry.path, err);
                    return err;
                };
            }
            continue;
        }
        if (isOutputPath(allocator, options, entry.path)) continue;
        if (!watchFile(entry.path)) continue;
        const stat = entry.dir.statFile(io, entry.basename, .{}) catch |err| {
            if (err == error.FileNotFound) continue;
            try recordAssetFailure(allocator, context, options.asset_base_dir, entry.path, err);
            return err;
        };
        mixBytes(&hash, entry.path);
        mixValue(u64, &hash, stat.size);
        mixValue(i96, &hash, stat.mtime.nanoseconds);
        mixValue(u8, &hash, @intFromEnum(stat.kind));
    }

    return hash;
}

fn recordAssetFailure(
    allocator: std.mem.Allocator,
    context: *FingerprintContext,
    asset_base_dir: []const u8,
    relative_path: []const u8,
    cause: anyerror,
) !void {
    const full_path = try std.fs.path.join(allocator, &.{ asset_base_dir, relative_path });
    defer allocator.free(full_path);
    try context.record(.asset_path, full_path, cause);
}

fn mixHighlightLanguageStats(
    io: std.Io,
    hash: *u64,
    languages: []const utils.highlight.Language,
    context: *FingerprintContext,
) !void {
    mixValue(usize, hash, languages.len);
    for (languages) |language| {
        mixBytes(hash, language.name);
        mixBytes(hash, language.parser);
        mixBytes(hash, language.query);
        if (!std.mem.startsWith(u8, language.query, "builtin:")) {
            try mixStatFile(io, hash, language.query, .highlight_query, context);
        }
    }
}

fn mixModuleDependencyStats(
    io: std.Io,
    allocator: std.mem.Allocator,
    hash: *u64,
    options: Options,
    context: *FingerprintContext,
) !void {
    var visited = std.StringHashMap(void).init(allocator);
    defer {
        var key_it = visited.keyIterator();
        while (key_it.next()) |key| allocator.free(key.*);
        visited.deinit();
    }
    try mixModuleImportGraph(io, allocator, hash, options.input_path, .input_file, &visited, context);
}

fn mixModuleImportGraph(
    io: std.Io,
    allocator: std.mem.Allocator,
    hash: *u64,
    module_path: []const u8,
    target: FingerprintTarget,
    visited: *std.StringHashMap(void),
    context: *FingerprintContext,
) !void {
    const resolved_module_path = try std.fs.path.resolve(allocator, &.{module_path});
    defer allocator.free(resolved_module_path);
    if (visited.contains(resolved_module_path)) return;
    const owned_path = try allocator.dupe(u8, resolved_module_path);
    visited.put(owned_path, {}) catch |err| {
        allocator.free(owned_path);
        return err;
    };

    mixBytes(hash, resolved_module_path);
    try mixStatFile(io, hash, resolved_module_path, target, context);

    const source = utils.fs.readFileAlloc(io, allocator, resolved_module_path) catch |err| {
        if (err == error.FileNotFound) return;
        try context.record(target, resolved_module_path, err);
        return err;
    };
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
        try mixStatFile(io, hash, import_path, .imported_source, context);
        try mixModuleImportGraph(io, allocator, hash, import_path, .imported_source, visited, context);
    }
}

fn resolveExplicitImportPath(allocator: std.mem.Allocator, base_dir: []const u8, spec: []const u8) ![]u8 {
    const path = try names.importPathWithDefaultExtension(allocator, spec);
    defer allocator.free(path);
    if (std.fs.path.isAbsolute(path)) return allocator.dupe(u8, path);
    return std.fs.path.resolve(allocator, &.{ base_dir, path });
}

fn mixStatFile(
    io: std.Io,
    hash: *u64,
    path: []const u8,
    target: FingerprintTarget,
    context: *FingerprintContext,
) !void {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch |err| {
        if (err == error.FileNotFound) return;
        try context.record(target, path, err);
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

fn isOutputPath(allocator: std.mem.Allocator, options: Options, relative_path: []const u8) bool {
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
