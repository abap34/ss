const std = @import("std");
const c = @import("pdf_ffi").c;
const render = @import("render");
const page_backend = @import("pdf_backend");

const Allocator = std.mem.Allocator;
var temporary_counter: usize = 0;

pub const Options = struct {
    jobs: ?usize = null,
    cache_dir: []const u8 = ".ss-cache/render",
};

pub const Progress = struct {
    context: *anyopaque,
    artifactCompleted: *const fn (context: *anyopaque, completed: usize, total: usize) void,
    pageCompleted: *const fn (context: *anyopaque, completed: usize, total: usize) void,
    assemblyCompleted: *const fn (context: *anyopaque, completed: usize, total: usize) void,
};

pub fn write(
    allocator: Allocator,
    io: std.Io,
    ir: *const render.Ir,
    output: []const u8,
    options: Options,
    progress: ?Progress,
) !void {
    try ir.validate();
    const cache_root = try std.fs.path.join(allocator, &.{ options.cache_dir, "render-ir-v1" });
    defer allocator.free(cache_root);
    const page_cache = try std.fs.path.join(allocator, &.{ cache_root, "pages" });
    defer allocator.free(page_cache);
    const document_cache = try std.fs.path.join(allocator, &.{ cache_root, "documents" });
    defer allocator.free(document_cache);
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, page_cache);
    try cwd.createDirPath(io, document_cache);

    const document_digest = ir.fingerprint();
    const document_path = try digestPath(allocator, document_cache, document_digest);
    defer allocator.free(document_path);
    if (try cachedPdfAvailable(allocator, io, document_path)) {
        if (progress) |value| {
            value.pageCompleted(value.context, ir.pages.len, ir.pages.len);
            value.assemblyCompleted(value.context, 1, 1);
        }
        return try publishOutput(allocator, io, document_path, output);
    }

    const page_paths = try allocator.alloc([]u8, ir.pages.len);
    var initialized_paths: usize = 0;
    defer {
        for (page_paths[0..initialized_paths]) |path| allocator.free(path);
        allocator.free(page_paths);
    }
    const missing = try allocator.alloc(bool, ir.pages.len);
    defer allocator.free(missing);
    var missing_count: usize = 0;
    for (ir.pages, 0..) |*page, index| {
        const digest = render.pageFingerprint(page);
        page_paths[index] = try digestPath(allocator, page_cache, digest);
        initialized_paths += 1;
        missing[index] = !(try cachedPdfAvailable(allocator, io, page_paths[index]));
        if (missing[index]) missing_count += 1;
    }
    if (progress) |value| value.pageCompleted(value.context, ir.pages.len - missing_count, ir.pages.len);
    if (missing_count != 0) try renderMissingPages(allocator, io, ir, page_paths, missing, options.jobs, progress);

    const temporary_document = try temporaryPath(allocator, document_path, "pdf");
    defer allocator.free(temporary_document);
    errdefer deleteFile(io, temporary_document);
    if (progress) |value| value.assemblyCompleted(value.context, 0, 1);
    try mergePages(allocator, ir.pages.len, page_paths, temporary_document);
    try validatePdf(allocator, io, temporary_document);
    try publishCache(io, temporary_document, document_path);
    if (progress) |value| value.assemblyCompleted(value.context, 1, 1);
    try publishOutput(allocator, io, document_path, output);
}

fn renderMissingPages(
    allocator: Allocator,
    io: std.Io,
    ir: *const render.Ir,
    page_paths: []const []const u8,
    missing: []const bool,
    requested_jobs: ?usize,
    progress: ?Progress,
) !void {
    const worker_count = configuredWorkerCount(requested_jobs, countMissing(missing));
    if (worker_count <= 1) {
        var completed = ir.pages.len - countMissing(missing);
        for (missing, 0..) |is_missing, index| {
            if (!is_missing) continue;
            try renderPageToCache(allocator, io, ir, index, page_paths[index]);
            completed += 1;
            if (progress) |value| value.pageCompleted(value.context, completed, ir.pages.len);
        }
        return;
    }

    var work = PageWork{
        .io = io,
        .ir = ir,
        .page_paths = page_paths,
        .missing = missing,
        .completed = .init(ir.pages.len - countMissing(missing)),
    };
    const threads = try allocator.alloc(std.Thread, worker_count);
    defer allocator.free(threads);
    var started: usize = 0;
    var joined = false;
    errdefer if (!joined) {
        work.failed.store(true, .seq_cst);
        for (threads[0..started]) |thread| thread.join();
    };
    while (started < worker_count) : (started += 1) threads[started] = try std.Thread.spawn(.{}, pageWorker, .{&work});

    var last_completed = work.completed.load(.acquire);
    while (!work.failed.load(.acquire) and last_completed < ir.pages.len) {
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(20), .awake) catch {};
        const completed = work.completed.load(.acquire);
        if (completed != last_completed) {
            if (progress) |value| value.pageCompleted(value.context, completed, ir.pages.len);
            last_completed = completed;
        }
    }
    for (threads[0..started]) |thread| thread.join();
    joined = true;
    const completed = work.completed.load(.acquire);
    if (completed != last_completed) if (progress) |value| value.pageCompleted(value.context, completed, ir.pages.len);
    if (work.failed.load(.acquire)) return error.PdfPageRenderFailed;
}

const PageWork = struct {
    io: std.Io,
    ir: *const render.Ir,
    page_paths: []const []const u8,
    missing: []const bool,
    next: std.atomic.Value(usize) = .init(0),
    completed: std.atomic.Value(usize),
    failed: std.atomic.Value(bool) = .init(false),
};

fn pageWorker(work: *PageWork) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();
    while (!work.failed.load(.acquire)) {
        const index = work.next.fetchAdd(1, .monotonic);
        if (index >= work.ir.pages.len) return;
        if (!work.missing[index]) continue;
        renderPageToCache(arena.allocator(), work.io, work.ir, index, work.page_paths[index]) catch {
            work.failed.store(true, .seq_cst);
            return;
        };
        _ = work.completed.fetchAdd(1, .release);
        _ = arena.reset(.retain_capacity);
    }
}

fn renderPageToCache(allocator: Allocator, io: std.Io, ir: *const render.Ir, page_index: usize, destination: []const u8) !void {
    if (try cachedPdfAvailable(allocator, io, destination)) return;
    const temporary = try temporaryPath(allocator, destination, "pdf");
    defer allocator.free(temporary);
    errdefer deleteFile(io, temporary);
    try page_backend.render(allocator, io, ir, page_index, temporary);
    try validatePdf(allocator, io, temporary);
    try publishCache(io, temporary, destination);
}

fn mergePages(allocator: Allocator, page_count: usize, inputs: []const []u8, output: []const u8) !void {
    const output_z = try allocator.dupeZ(u8, output);
    defer allocator.free(output_z);
    if (page_count == 0) {
        if (c.ss_qpdf_empty(output_z.ptr) != 0) return error.PdfAssemblyFailed;
        return;
    }
    const paths = try allocator.alloc([:0]u8, inputs.len);
    var initialized: usize = 0;
    defer {
        for (paths[0..initialized]) |path| allocator.free(path);
        allocator.free(paths);
    }
    const pointers = try allocator.alloc([*c]const u8, inputs.len);
    defer allocator.free(pointers);
    for (inputs, 0..) |input, index| {
        paths[index] = try allocator.dupeZ(u8, input);
        initialized += 1;
        pointers[index] = paths[index].ptr;
    }
    if (c.ss_qpdf_merge(output_z.ptr, pointers.ptr, pointers.len, 1) != 0) return error.PdfAssemblyFailed;
}

fn digestPath(allocator: Allocator, directory: []const u8, digest: render.Fingerprint) ![]u8 {
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.allocPrint(allocator, "{s}/{s}.pdf", .{ directory, &hex });
}

fn temporaryPath(allocator: Allocator, path: []const u8, extension: []const u8) ![]u8 {
    const serial = @atomicRmw(usize, &temporary_counter, .Add, 1, .monotonic);
    return std.fmt.allocPrint(allocator, "{s}.tmp-{d}-{d}.{s}", .{ path, std.c.getpid(), serial, extension });
}

fn publishCache(io: std.Io, temporary: []const u8, destination: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    cwd.rename(temporary, cwd, destination, io) catch |err| {
        if (try cachedPdfAvailable(std.heap.smp_allocator, io, destination)) {
            deleteFile(io, temporary);
            return;
        }
        return err;
    };
}

fn publishOutput(allocator: Allocator, io: std.Io, source: []const u8, output: []const u8) !void {
    if (std.fs.path.dirname(output)) |parent| try std.Io.Dir.cwd().createDirPath(io, parent);
    const temporary = try temporaryPath(allocator, output, "pdf");
    defer allocator.free(temporary);
    errdefer deleteFile(io, temporary);
    const cwd = std.Io.Dir.cwd();
    try cwd.copyFile(source, cwd, temporary, io, .{ .make_path = true, .replace = true });
    try validatePdf(allocator, io, temporary);
    try cwd.rename(temporary, cwd, output, io);
}

fn cachedPdfAvailable(allocator: Allocator, io: std.Io, path: []const u8) !bool {
    validatePdf(allocator, io, path) catch {
        deleteFile(io, path);
        return false;
    };
    return true;
}

fn validatePdf(allocator: Allocator, io: std.Io, path: []const u8) !void {
    var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return error.InvalidPdfCache;
    defer file.close(io);
    const stat = file.stat(io) catch return error.InvalidPdfCache;
    if (stat.kind != .file or stat.size < 8) return error.InvalidPdfCache;
    var header: [5]u8 = undefined;
    var header_vectors = [_][]u8{header[0..]};
    if ((file.readPositional(io, &header_vectors, 0) catch return error.InvalidPdfCache) != header.len or !std.mem.eql(u8, &header, "%PDF-")) {
        return error.InvalidPdfCache;
    }
    const tail_length: usize = @intCast(@min(stat.size, 4096));
    const tail = try allocator.alloc(u8, tail_length);
    defer allocator.free(tail);
    var tail_vectors = [_][]u8{tail};
    const read = file.readPositional(io, &tail_vectors, stat.size - tail_length) catch return error.InvalidPdfCache;
    if (std.mem.indexOf(u8, tail[0..read], "%%EOF") == null) return error.InvalidPdfCache;
}

fn configuredWorkerCount(requested: ?usize, task_count: usize) usize {
    if (task_count == 0) return 0;
    if (requested) |jobs| return @min(@max(jobs, 1), task_count);
    if (std.c.getenv("SS_RENDER_JOBS")) |raw| {
        const value = std.mem.span(raw);
        if (std.ascii.eqlIgnoreCase(value, "off")) return 1;
        if (std.fmt.parseUnsigned(usize, value, 10)) |jobs| return @min(@max(jobs, 1), task_count) else |_| {}
    }
    return @min(@max(std.Thread.getCpuCount() catch 1, 1), @min(task_count, 4));
}

fn countMissing(missing: []const bool) usize {
    var count: usize = 0;
    for (missing) |value| if (value) {
        count += 1;
    };
    return count;
}

fn deleteFile(io: std.Io, path: []const u8) void {
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
}
