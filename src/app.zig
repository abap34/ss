const std = @import("std");
const core = @import("core");
const ast = @import("ast");
const parser = @import("syntax.zig");
const lowering = @import("lowering.zig");
const pdf = @import("render/pdf.zig");
const dump = @import("dump.zig");
const typecheck = @import("analysis/typecheck.zig");
const module_loader = @import("modules/loader.zig");
const utils = @import("utils");
const error_report = utils.err;

pub const render_cache_path = ".ss-cache/render";
pub const RenderOptions = pdf.RenderOptions;

const cache_size_kib: u64 = 1024;
const cache_size_mib: u64 = cache_size_kib * 1024;
const cache_size_gib: u64 = cache_size_mib * 1024;

pub const CacheStats = struct {
    files: usize = 0,
    directories: usize = 0,
    bytes: u64 = 0,
};

const CacheFileEntry = struct {
    path: []u8,
    size: u64,
    mtime_ns: i96,
};

pub const Progress = struct {
    total: usize,
    current: usize = 0,
    started_at_ns: i128,
    last_step_at_ns: i128,
    detail_active: bool = false,

    pub fn init(total: usize) Progress {
        const now = monotonicNowNs();
        return .{
            .total = total,
            .started_at_ns = now,
            .last_step_at_ns = now,
        };
    }

    pub fn step(self: *Progress, label: []const u8) void {
        const now = monotonicNowNs();
        const stage_elapsed_ns = now - self.last_step_at_ns;
        const total_elapsed_ns = now - self.started_at_ns;
        self.current += 1;
        self.last_step_at_ns = now;
        const replace_detail = self.detail_active;
        if (replace_detail) {
            self.detail_active = false;
            std.debug.print("\r", .{});
        }
        printProgress(
            self.current,
            self.total,
            label,
            @intCast(@divTrunc(stage_elapsed_ns, std.time.ns_per_ms)),
            @intCast(@divTrunc(total_elapsed_ns, std.time.ns_per_ms)),
            replace_detail,
        );
    }

    pub fn detail(self: *Progress, label: []const u8, detail_current: usize, detail_total: usize) void {
        const now = monotonicNowNs();
        const stage_elapsed_ns = now - self.last_step_at_ns;
        const total_elapsed_ns = now - self.started_at_ns;
        self.detail_active = true;
        std.debug.print("\r", .{});
        printProgressDetail(
            @min(self.current + 1, self.total),
            self.total,
            label,
            detail_current,
            detail_total,
            @intCast(@divTrunc(stage_elapsed_ns, std.time.ns_per_ms)),
            @intCast(@divTrunc(total_elapsed_ns, std.time.ns_per_ms)),
        );
    }
};

pub fn buildFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8, progress: ?*Progress) !core.Ir {
    const asset_base_dir = std.fs.path.dirname(path) orelse ".";
    return buildFileWithAssetBase(io, allocator, path, asset_base_dir, progress);
}

pub fn buildFileWithAssetBase(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    asset_base_dir: []const u8,
    progress: ?*Progress,
) !core.Ir {
    return buildFileWithAssetBaseAndOverlay(io, allocator, path, asset_base_dir, progress, null);
}

pub fn buildFileWithAssetBaseAndOverlay(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    asset_base_dir: []const u8,
    progress: ?*Progress,
    overlay: ?*const module_loader.SourceOverlay,
) !core.Ir {
    var source = if (overlay) |source_overlay|
        if (source_overlay.get(path)) |text|
            try allocator.dupe(u8, text)
        else
            try utils.fs.readFileAlloc(io, allocator, path)
    else
        try utils.fs.readFileAlloc(io, allocator, path);
    errdefer allocator.free(source);
    if (progress) |p| p.step("Read source");

    var program = try parseSource(allocator, source, path);
    errdefer program.deinit(allocator);
    if (progress) |p| p.step("Parse");

    var index = typecheck.loadProgramIndexWithOverlay(allocator, io, asset_base_dir, program, overlay) catch |err| {
        if (err == error.UnknownImport) {
            var report = try module_loader.findUnknownImportReport(allocator, io, asset_base_dir, program, overlay) orelse return err;
            defer report.deinit(allocator);
            error_report.print(.{
                .path = path,
                .source = source,
                .severity = .@"error",
                .message = report.message,
                .span = .{
                    .start = report.span.start,
                    .end = report.span.end,
                },
            });
        } else if (err == error.ImportCycle) {
            error_report.print(.{
                .path = path,
                .source = source,
                .severity = .@"error",
                .message = "ImportCycle: import graph contains a cycle",
                .span = null,
            });
            return error.DiagnosticsFailed;
        }
        return err;
    };
    if (progress) |p| p.step("Load index");

    var ir = typecheck.buildIr(allocator, path, asset_base_dir, &source, &program, &index) catch |err| {
        if (err == error.UnknownImport) {
            var report = try module_loader.findUnknownImportReport(allocator, io, asset_base_dir, program, overlay) orelse return err;
            defer report.deinit(allocator);
            error_report.print(.{
                .path = path,
                .source = source,
                .severity = .@"error",
                .message = report.message,
                .span = .{
                    .start = report.span.start,
                    .end = report.span.end,
                },
            });
        } else if (err != error.DiagnosticsFailed) {
            std.debug.print("error: {s}\n", .{@errorName(err)});
        }
        return err;
    };
    defer index.deinit();
    errdefer ir.deinit();

    typecheck.typecheckProgram(allocator, &ir) catch |err| {
        error_report.printIrDiagnostics(ir.projectPath(), ir.projectSource(), &ir);
        return err;
    };
    if (progress) |p| p.step("Typecheck");

    if (error_report.hasIrErrors(&ir)) {
        error_report.printIrDiagnostics(ir.projectPath(), ir.projectSource(), &ir);
        return error.DiagnosticsFailed;
    }

    lowering.lowerToIr(&ir) catch |err| {
        switch (err) {
            error.ConstraintConflict, error.NegativeConstraintSize => error_report.printConstraintFailure(ir.projectPath(), ir.projectSource(), &ir, err, core.formatConstraint),
            else => error_report.printIrDiagnostics(ir.projectPath(), ir.projectSource(), &ir),
        }
        return err;
    };
    if (progress) |p| p.step("Lower and solve");
    error_report.printIrDiagnostics(ir.projectPath(), ir.projectSource(), &ir);
    if (error_report.hasIrErrors(&ir)) return error.DiagnosticsFailed;
    return ir;
}

pub fn checkFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !void {
    var ir = try buildFile(io, allocator, path, null);
    defer ir.deinit();
    std.debug.print("ok {s}\n", .{path});
}

pub fn checkFileWithAssetBase(io: std.Io, allocator: std.mem.Allocator, path: []const u8, asset_base_dir: []const u8) !void {
    var ir = try buildFileWithAssetBase(io, allocator, path, asset_base_dir, null);
    defer ir.deinit();
    std.debug.print("ok {s}\n", .{path});
}

pub fn clearRenderCache(io: std.Io) !void {
    std.Io.Dir.cwd().deleteTree(io, render_cache_path) catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };
}

pub fn renderCacheStats(io: std.Io, allocator: std.mem.Allocator) !CacheStats {
    var dir = std.Io.Dir.cwd().openDir(io, render_cache_path, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) return .{};
        return err;
    };
    defer dir.close(io);

    var stats = CacheStats{};
    var walker = try dir.walkSelectively(allocator);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind == .directory) {
            stats.directories += 1;
            try walker.enter(io, entry);
            continue;
        }

        const file_stat = entry.dir.statFile(io, entry.basename, .{}) catch continue;
        if (file_stat.kind == .directory) continue;
        stats.files += 1;
        stats.bytes += file_stat.size;
    }

    return stats;
}

pub fn pruneRenderCacheFromEnv(io: std.Io, allocator: std.mem.Allocator) !void {
    const max_bytes = configuredRenderCacheMaxBytes() orelse return;
    try pruneRenderCache(io, allocator, max_bytes);
}

fn configuredRenderCacheMaxBytes() ?u64 {
    const raw = std.c.getenv("SS_CACHE_MAX_BYTES") orelse return null;
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

fn pruneRenderCache(io: std.Io, allocator: std.mem.Allocator, max_bytes: u64) !void {
    var files = std.ArrayList(CacheFileEntry).empty;
    defer {
        for (files.items) |entry| allocator.free(entry.path);
        files.deinit(allocator);
    }

    const stats = try collectRenderCacheFiles(io, allocator, &files);
    if (stats.bytes <= max_bytes) return;

    std.sort.heap(CacheFileEntry, files.items, {}, cacheFileOlderThan);
    var remaining = stats.bytes;
    for (files.items) |entry| {
        if (remaining <= max_bytes) break;
        const full_path = try std.fs.path.join(allocator, &.{ render_cache_path, entry.path });
        defer allocator.free(full_path);
        std.Io.Dir.cwd().deleteFile(io, full_path) catch continue;
        remaining -|= entry.size;
    }
}

fn collectRenderCacheFiles(io: std.Io, allocator: std.mem.Allocator, files: *std.ArrayList(CacheFileEntry)) !CacheStats {
    var dir = std.Io.Dir.cwd().openDir(io, render_cache_path, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) return .{};
        return err;
    };
    defer dir.close(io);

    var stats = CacheStats{};
    var walker = try dir.walkSelectively(allocator);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind == .directory) {
            stats.directories += 1;
            try walker.enter(io, entry);
            continue;
        }

        const file_stat = entry.dir.statFile(io, entry.basename, .{}) catch continue;
        if (file_stat.kind == .directory) continue;
        stats.files += 1;
        stats.bytes += file_stat.size;
        try files.append(allocator, .{
            .path = try allocator.dupe(u8, entry.path),
            .size = file_stat.size,
            .mtime_ns = file_stat.mtime.nanoseconds,
        });
    }

    return stats;
}

fn cacheFileOlderThan(_: void, lhs: CacheFileEntry, rhs: CacheFileEntry) bool {
    if (lhs.mtime_ns == rhs.mtime_ns) return std.mem.lessThan(u8, lhs.path, rhs.path);
    return lhs.mtime_ns < rhs.mtime_ns;
}

pub fn printIrJsonForFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8, progress: *Progress) !void {
    var ir = try buildFile(io, allocator, path, progress);
    defer ir.deinit();
    const text = try dump.toOwnedString(allocator, &ir);
    defer allocator.free(text);
    progress.step("Serialize JSON");
    try stdoutWriteAll(text);
    progress.step("Print dump");
}

pub fn printIrJsonForFileWithAssetBase(io: std.Io, allocator: std.mem.Allocator, path: []const u8, asset_base_dir: []const u8, progress: *Progress) !void {
    var ir = try buildFileWithAssetBase(io, allocator, path, asset_base_dir, progress);
    defer ir.deinit();
    const text = try dump.toOwnedString(allocator, &ir);
    defer allocator.free(text);
    progress.step("Serialize JSON");
    try stdoutWriteAll(text);
    progress.step("Print dump");
}

pub fn writeIrJsonFile(io: std.Io, allocator: std.mem.Allocator, input_path: []const u8, output_path: []const u8, progress: *Progress) !void {
    var ir = try buildFile(io, allocator, input_path, progress);
    defer ir.deinit();
    const json = try dump.toOwnedString(allocator, &ir);
    defer allocator.free(json);
    progress.step("Serialize JSON");
    try utils.fs.writeFile(io, output_path, json);
    progress.step("Write JSON");
}

pub fn writeIrJsonFileWithAssetBase(io: std.Io, allocator: std.mem.Allocator, input_path: []const u8, asset_base_dir: []const u8, output_path: []const u8, progress: *Progress) !void {
    var ir = try buildFileWithAssetBase(io, allocator, input_path, asset_base_dir, progress);
    defer ir.deinit();
    const json = try dump.toOwnedString(allocator, &ir);
    defer allocator.free(json);
    progress.step("Serialize JSON");
    try utils.fs.writeFile(io, output_path, json);
    progress.step("Write JSON");
}

pub fn writePdfForFile(io: std.Io, allocator: std.mem.Allocator, input_path: []const u8, output_path: []const u8, progress: *Progress) !void {
    return writePdfForFileWithOptions(io, allocator, input_path, output_path, .{}, progress);
}

pub fn writePdfForFileWithOptions(io: std.Io, allocator: std.mem.Allocator, input_path: []const u8, output_path: []const u8, options: RenderOptions, progress: *Progress) !void {
    var ir = try buildFile(io, allocator, input_path, progress);
    defer ir.deinit();
    const pdf_data = try pdf.renderDocumentToPdfWithOptions(allocator, io, &ir, options, progressCallback(progress));
    defer allocator.free(pdf_data);
    try pruneRenderCacheFromEnv(io, allocator);
    progress.step("Render PDF");
    try utils.fs.writeFile(io, output_path, pdf_data);
    progress.step("Write PDF");
}

pub fn writePdfForFileWithAssetBase(io: std.Io, allocator: std.mem.Allocator, input_path: []const u8, asset_base_dir: []const u8, output_path: []const u8, progress: *Progress) !void {
    return writePdfForFileWithAssetBaseAndOptions(io, allocator, input_path, asset_base_dir, output_path, .{}, progress);
}

pub fn writePdfForFileWithAssetBaseAndOptions(io: std.Io, allocator: std.mem.Allocator, input_path: []const u8, asset_base_dir: []const u8, output_path: []const u8, options: RenderOptions, progress: *Progress) !void {
    var ir = try buildFileWithAssetBase(io, allocator, input_path, asset_base_dir, progress);
    defer ir.deinit();
    const pdf_data = try pdf.renderDocumentToPdfWithOptions(allocator, io, &ir, options, progressCallback(progress));
    defer allocator.free(pdf_data);
    try pruneRenderCacheFromEnv(io, allocator);
    progress.step("Render PDF");
    try utils.fs.writeFile(io, output_path, pdf_data);
    progress.step("Write PDF");
}

fn parseSource(allocator: std.mem.Allocator, source: []const u8, path: []const u8) !parser.Program {
    return parser.parseWithSourceName(allocator, source, path) catch |err| {
        error_report.printParseError(path, source, err, parser.lastParseDiagnostic());
        return err;
    };
}

fn monotonicNowNs() i128 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    return @as(i128, ts.sec) * std.time.ns_per_s + @as(i128, ts.nsec);
}

fn printProgress(current: usize, total: usize, label: []const u8, stage_elapsed_ms: i64, total_elapsed_ms: i64, clear_eol: bool) void {
    const width: usize = 18;
    const filled = if (total == 0) width else @min(width, (current * width) / total);
    var stage_buf: [32]u8 = undefined;
    var total_buf: [32]u8 = undefined;
    const stage_text = formatDurationMsText(stage_elapsed_ms, &stage_buf) catch "<?>";
    const total_text = formatDurationMsText(total_elapsed_ms, &total_buf) catch "<?>";
    std.debug.print("[", .{});
    var i: usize = 0;
    while (i < width) : (i += 1) {
        if (i < filled) {
            if (i + 1 == filled and filled < width) {
                std.debug.print(">", .{});
            } else {
                std.debug.print("=", .{});
            }
        } else {
            std.debug.print(" ", .{});
        }
    }
    std.debug.print("] {d}/{d} {s:<19}  ({s:>8}, total {s:>8})", .{
        current,
        total,
        label,
        stage_text,
        total_text,
    });
    if (clear_eol) std.debug.print("\x1b[K", .{});
    std.debug.print("\n", .{});
}

fn printProgressDetail(current: usize, total: usize, label: []const u8, detail_current: usize, detail_total: usize, stage_elapsed_ms: i64, total_elapsed_ms: i64) void {
    const width: usize = 18;
    const filled = if (total == 0) width else @min(width, (current * width) / total);
    var stage_buf: [32]u8 = undefined;
    var total_buf: [32]u8 = undefined;
    const stage_text = formatDurationMsText(stage_elapsed_ms, &stage_buf) catch "<?>";
    const total_text = formatDurationMsText(total_elapsed_ms, &total_buf) catch "<?>";
    std.debug.print("[", .{});
    var i: usize = 0;
    while (i < width) : (i += 1) {
        if (i < filled) {
            if (i + 1 == filled and filled < width) {
                std.debug.print(">", .{});
            } else {
                std.debug.print("=", .{});
            }
        } else {
            std.debug.print(" ", .{});
        }
    }
    std.debug.print("] {d}/{d} {s:<11} {d}/{d:<5}  ({s:>8}, total {s:>8})\x1b[K", .{
        current,
        total,
        label,
        detail_current,
        detail_total,
        stage_text,
        total_text,
    });
}

fn stdoutWriteAll(bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const n = std.c.write(1, bytes[offset..].ptr, bytes.len - offset);
        if (n <= 0) return error.WriteFailed;
        offset += @intCast(n);
    }
}

fn progressCallback(progress: *Progress) pdf.RenderProgress {
    return .{
        .context = progress,
        .artifactCompleted = onRenderArtifact,
        .pageCompleted = onRenderPage,
        .assemblyCompleted = onRenderAssembly,
    };
}

fn onRenderArtifact(context: *anyopaque, completed: usize, total: usize) void {
    const progress: *Progress = @ptrCast(@alignCast(context));
    progress.detail("Artifacts", completed, total);
}

fn onRenderPage(context: *anyopaque, completed: usize, total: usize) void {
    const progress: *Progress = @ptrCast(@alignCast(context));
    progress.detail("Pages", completed, total);
}

fn onRenderAssembly(context: *anyopaque, completed: usize, total: usize) void {
    const progress: *Progress = @ptrCast(@alignCast(context));
    progress.detail("Assemble", completed, total);
}

fn formatDurationMsText(value: i64, buf: []u8) ![]const u8 {
    if (value < 1000) {
        return std.fmt.bufPrint(buf, "{d}ms", .{value});
    }

    const seconds = @as(f64, @floatFromInt(value)) / 1000.0;
    if (seconds < 10.0) {
        return std.fmt.bufPrint(buf, "{d:.2}s", .{seconds});
    } else if (seconds < 100.0) {
        return std.fmt.bufPrint(buf, "{d:.1}s", .{seconds});
    } else {
        return std.fmt.bufPrint(buf, "{d:.0}s", .{seconds});
    }
}
