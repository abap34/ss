const std = @import("std");
const c = @import("pdf_ffi").c;
const render = @import("render");
const page_backend = @import("pdf_backend");

const Allocator = std.mem.Allocator;
var temporary_counter: usize = 0;

pub const cache_version = "ss-pdf-render-ir-v1";
const output_manifest_version = "ss-pdf-output-manifest-v2";
const document_digest_version = "ss-pdf-document-pages-v2";
const cache_seal_version = "ss-pdf-cache-seal-v1";
const cache_checksum_size = std.crypto.hash.sha2.Sha256.digest_length;

const AssemblyKind = enum {
    full,
    delta,
    document_cache,
};

const CacheArtifactKind = enum(u8) {
    page = 1,
    document = 2,
};

const CacheIdentity = struct {
    kind: CacheArtifactKind,
    key: render.Fingerprint,
    page_count: usize,
};

const ManifestPage = struct {
    digest: render.Fingerprint,
    has_destinations: bool,
    has_destination_links: bool,
};

const OutputManifest = struct {
    document_digest: render.Fingerprint,
    assembly: AssemblyKind,
    pages: []ManifestPage,

    fn deinit(self: *OutputManifest, allocator: Allocator) void {
        allocator.free(self.pages);
        self.* = undefined;
    }
};

pub const Options = struct {
    jobs: ?usize = null,
    cache_dir: []const u8 = ".ss-cache/render",
};

pub const Progress = struct {
    context: *anyopaque,
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
    return try writeValidated(allocator, io, ir, output, options, progress);
}

pub fn writeValidated(
    allocator: Allocator,
    io: std.Io,
    ir: *const render.Ir,
    output: []const u8,
    options: Options,
    progress: ?Progress,
) !void {
    const cache_root = try std.fs.path.join(allocator, &.{ options.cache_dir, cache_version });
    defer allocator.free(cache_root);
    const page_cache = try std.fs.path.join(allocator, &.{ cache_root, "pages" });
    defer allocator.free(page_cache);
    const document_cache = try std.fs.path.join(allocator, &.{ cache_root, "documents" });
    defer allocator.free(document_cache);
    const manifest_cache = try std.fs.path.join(allocator, &.{ cache_root, "output-manifests" });
    defer allocator.free(manifest_cache);
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, page_cache);
    try cwd.createDirPath(io, document_cache);
    try cwd.createDirPath(io, manifest_cache);

    var current_manifest = try buildOutputManifest(allocator, ir, options.jobs);
    defer current_manifest.deinit(allocator);
    const document_digest = current_manifest.document_digest;
    const document_path = try digestPath(allocator, document_cache, document_digest);
    defer allocator.free(document_path);
    const manifest_path = try outputManifestPath(allocator, manifest_cache, output);
    defer allocator.free(manifest_path);
    const document_identity = CacheIdentity{
        .kind = .document,
        .key = document_digest,
        .page_count = ir.pages.len,
    };
    if (try cachedPdfAvailable(allocator, io, document_path, document_identity)) {
        current_manifest.assembly = .document_cache;
        if (progress) |value| {
            value.pageCompleted(value.context, ir.pages.len, ir.pages.len);
            value.assemblyCompleted(value.context, 1, 1);
        }
        try publishOutput(allocator, io, document_path, output);
        persistOutputManifest(allocator, io, manifest_path, &current_manifest);
        return;
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
    for (current_manifest.pages, 0..) |page, index| {
        page_paths[index] = try digestPath(allocator, page_cache, page.digest);
        initialized_paths += 1;
        missing[index] = !(try cachedPdfAvailable(
            allocator,
            io,
            page_paths[index],
            pageCacheIdentity(page),
        ));
        if (missing[index]) missing_count += 1;
    }
    if (progress) |value| value.pageCompleted(value.context, ir.pages.len - missing_count, ir.pages.len);
    if (missing_count != 0) {
        var resources = try page_backend.ResourceFiles.initCached(allocator, io, &ir.resources, cache_root);
        defer resources.deinit();
        try renderMissingPages(
            allocator,
            io,
            ir,
            current_manifest.pages,
            page_paths,
            missing,
            options.jobs,
            progress,
            &resources,
        );
    }

    const temporary_document = try temporaryPath(allocator, document_path, "pdf");
    defer allocator.free(temporary_document);
    errdefer deleteFile(io, temporary_document);
    if (progress) |value| value.assemblyCompleted(value.context, 0, 1);
    try mergePages(allocator, ir.pages.len, page_paths, temporary_document);
    current_manifest.assembly = .full;
    try publishCache(allocator, io, temporary_document, document_path, document_identity);
    if (progress) |value| value.assemblyCompleted(value.context, 1, 1);
    try publishOutput(allocator, io, document_path, output);
    persistOutputManifest(allocator, io, manifest_path, &current_manifest);
}

fn renderMissingPages(
    allocator: Allocator,
    io: std.Io,
    ir: *const render.Ir,
    manifest_pages: []const ManifestPage,
    page_paths: []const []const u8,
    missing: []const bool,
    requested_jobs: ?usize,
    progress: ?Progress,
    resources: *const page_backend.ResourceFiles,
) !void {
    const worker_count = configuredWorkerCount(requested_jobs, countMissing(missing));
    if (worker_count <= 1) {
        var completed = ir.pages.len - countMissing(missing);
        for (missing, 0..) |is_missing, index| {
            if (!is_missing) continue;
            try renderPageToCache(
                allocator,
                io,
                ir,
                index,
                page_paths[index],
                pageCacheIdentity(manifest_pages[index]),
                resources,
            );
            completed += 1;
            if (progress) |value| value.pageCompleted(value.context, completed, ir.pages.len);
        }
        return;
    }

    var work = PageWork{
        .io = io,
        .ir = ir,
        .manifest_pages = manifest_pages,
        .page_paths = page_paths,
        .missing = missing,
        .resources = resources,
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
    if (work.failed.load(.acquire)) {
        const error_code = work.error_code.load(.acquire);
        if (error_code != 0) return @errorFromInt(error_code);
        return error.PdfPageRenderFailed;
    }
}

const PageWork = struct {
    io: std.Io,
    ir: *const render.Ir,
    manifest_pages: []const ManifestPage,
    page_paths: []const []const u8,
    missing: []const bool,
    resources: *const page_backend.ResourceFiles,
    next: std.atomic.Value(usize) = .init(0),
    completed: std.atomic.Value(usize),
    failed: std.atomic.Value(bool) = .init(false),
    error_code: std.atomic.Value(u16) = .init(0),
};

fn pageWorker(work: *PageWork) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();
    while (!work.failed.load(.acquire)) {
        const index = work.next.fetchAdd(1, .monotonic);
        if (index >= work.ir.pages.len) return;
        if (!work.missing[index]) continue;
        renderPageToCache(
            arena.allocator(),
            work.io,
            work.ir,
            index,
            work.page_paths[index],
            pageCacheIdentity(work.manifest_pages[index]),
            work.resources,
        ) catch |err| {
            _ = work.error_code.cmpxchgStrong(0, @intFromError(err), .seq_cst, .monotonic);
            work.failed.store(true, .seq_cst);
            return;
        };
        _ = work.completed.fetchAdd(1, .release);
        _ = arena.reset(.retain_capacity);
    }
}

fn renderPageToCache(
    allocator: Allocator,
    io: std.Io,
    ir: *const render.Ir,
    page_index: usize,
    destination: []const u8,
    identity: CacheIdentity,
    resources: *const page_backend.ResourceFiles,
) !void {
    if (try cachedPdfAvailable(allocator, io, destination, identity)) return;
    const temporary = try temporaryPath(allocator, destination, "pdf");
    defer allocator.free(temporary);
    errdefer deleteFile(io, temporary);
    try page_backend.render(allocator, io, ir, page_index, temporary, resources);
    try validateGeneratedPdf(allocator, io, temporary, 1, false);
    try publishCache(allocator, io, temporary, destination, identity);
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

fn buildOutputManifest(
    allocator: Allocator,
    ir: *const render.Ir,
    requested_jobs: ?usize,
) !OutputManifest {
    const pages = try allocator.alloc(ManifestPage, ir.pages.len);
    errdefer allocator.free(pages);
    const worker_count = configuredWorkerCount(requested_jobs, ir.pages.len);
    if (worker_count <= 1) {
        for (ir.pages, pages) |*page, *manifest_page| {
            manifest_page.* = manifestPage(page);
        }
    } else {
        var work = ManifestWork{
            .ir = ir,
            .pages = pages,
        };
        const threads = try allocator.alloc(std.Thread, worker_count);
        defer allocator.free(threads);
        var started: usize = 0;
        var joined = false;
        errdefer if (!joined) {
            for (threads[0..started]) |thread| thread.join();
        };
        while (started < worker_count) : (started += 1) {
            threads[started] = try std.Thread.spawn(.{}, manifestWorker, .{&work});
        }
        for (threads[0..started]) |thread| thread.join();
        joined = true;
    }
    return .{
        .document_digest = documentDigest(pages),
        .assembly = .full,
        .pages = pages,
    };
}

const ManifestWork = struct {
    ir: *const render.Ir,
    pages: []ManifestPage,
    next: std.atomic.Value(usize) = .init(0),
};

fn manifestWorker(work: *ManifestWork) void {
    while (true) {
        const index = work.next.fetchAdd(1, .monotonic);
        if (index >= work.pages.len) return;
        work.pages[index] = manifestPage(&work.ir.pages[index]);
    }
}

fn manifestPage(page: *const render.Page) ManifestPage {
    return .{
        .digest = render.pageFingerprint(page),
        .has_destinations = page.destinations.items.len != 0,
        .has_destination_links = hasDestinationLinks(page),
    };
}

fn documentDigest(pages: []const ManifestPage) render.Fingerprint {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(document_digest_version);
    var count_bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &count_bytes, @intCast(pages.len), .little);
    hasher.update(&count_bytes);
    for (pages) |page| {
        hasher.update(&page.digest);
        hasher.update(&.{
            @as(u8, @intFromBool(page.has_destinations)),
            @as(u8, @intFromBool(page.has_destination_links)),
        });
    }
    var digest: render.Fingerprint = undefined;
    hasher.final(&digest);
    return digest;
}

fn hasDestinationLinks(page: *const render.Page) bool {
    for (page.links.items) |link| if (link.kind == .destination) return true;
    return false;
}

fn pageCacheIdentity(page: ManifestPage) CacheIdentity {
    return .{
        .kind = .page,
        .key = page.digest,
        .page_count = 1,
    };
}

fn outputManifestPath(allocator: Allocator, directory: []const u8, output: []const u8) ![]u8 {
    const absolute = try std.fs.path.resolve(allocator, &.{output});
    defer allocator.free(absolute);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(absolute, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.allocPrint(allocator, "{s}/{s}.manifest", .{ directory, &hex });
}

fn writeOutputManifest(
    allocator: Allocator,
    io: std.Io,
    path: []const u8,
    manifest: *const OutputManifest,
) !void {
    var text = std.ArrayList(u8).empty;
    defer text.deinit(allocator);
    try text.print(allocator, "{s}\n", .{output_manifest_version});
    const document_hex = std.fmt.bytesToHex(manifest.document_digest, .lower);
    try text.print(
        allocator,
        "document\t{s}\nassembly\t{s}\npages\t{d}\n",
        .{ &document_hex, assemblyName(manifest.assembly), manifest.pages.len },
    );
    for (manifest.pages) |page| {
        const page_hex = std.fmt.bytesToHex(page.digest, .lower);
        try text.print(
            allocator,
            "page\t{s}\t{d}\t{d}\n",
            .{
                &page_hex,
                @intFromBool(page.has_destinations),
                @intFromBool(page.has_destination_links),
            },
        );
    }
    const temporary = try temporaryPath(allocator, path, "manifest");
    defer allocator.free(temporary);
    errdefer deleteFile(io, temporary);
    const cwd = std.Io.Dir.cwd();
    try cwd.writeFile(io, .{ .sub_path = temporary, .data = text.items, .flags = .{ .truncate = true } });
    try cwd.rename(temporary, cwd, path, io);
}

fn persistOutputManifest(
    allocator: Allocator,
    io: std.Io,
    path: []const u8,
    manifest: *const OutputManifest,
) void {
    writeOutputManifest(allocator, io, path, manifest) catch {};
}

fn assemblyName(assembly: AssemblyKind) []const u8 {
    return switch (assembly) {
        .full => "full",
        .delta => "delta",
        .document_cache => "document-cache",
    };
}

fn digestPath(allocator: Allocator, directory: []const u8, digest: render.Fingerprint) ![]u8 {
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.allocPrint(allocator, "{s}/{s}.pdf", .{ directory, &hex });
}

fn temporaryPath(allocator: Allocator, path: []const u8, extension: []const u8) ![]u8 {
    const serial = @atomicRmw(usize, &temporary_counter, .Add, 1, .monotonic);
    return std.fmt.allocPrint(allocator, "{s}.tmp-{d}-{d}.{s}", .{ path, std.c.getpid(), serial, extension });
}

fn publishCache(
    allocator: Allocator,
    io: std.Io,
    temporary: []const u8,
    destination: []const u8,
    identity: CacheIdentity,
) !void {
    const checksum = try hashFile(io, temporary);
    const seal = cacheSeal(identity, checksum);
    const lock_path = try std.fmt.allocPrint(allocator, "{s}.lock", .{destination});
    defer allocator.free(lock_path);
    const cwd = std.Io.Dir.cwd();
    var lock = try cwd.createFile(io, lock_path, .{
        .read = true,
        .truncate = false,
        .lock = .exclusive,
    });
    defer lock.close(io);
    if (try cachedPdfAvailable(allocator, io, destination, identity)) {
        deleteFile(io, temporary);
        return;
    }
    try cwd.rename(temporary, cwd, destination, io);
    try writeCacheSeal(allocator, io, destination, seal);
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

fn cachedPdfAvailable(
    allocator: Allocator,
    io: std.Io,
    path: []const u8,
    identity: CacheIdentity,
) !bool {
    const expected = try readCacheSeal(allocator, io, path) orelse return false;
    const checksum = hashFile(io, path) catch return false;
    const actual = cacheSeal(identity, checksum);
    return std.mem.eql(u8, &actual, &expected);
}

fn validateGeneratedPdf(
    allocator: Allocator,
    io: std.Io,
    path: []const u8,
    expected_page_count: usize,
    strict: bool,
) !void {
    try validatePdf(allocator, io, path);
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    if (c.ss_qpdf_validate(path_z.ptr, expected_page_count, @intFromBool(strict)) != 0) {
        return error.InvalidPdfCache;
    }
}

fn hashFile(io: std.Io, path: []const u8) ![cache_checksum_size]u8 {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.kind != .file) return error.InvalidPdfCache;

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buffer: [64 * 1024]u8 = undefined;
    var offset: u64 = 0;
    while (offset < stat.size) {
        const length: usize = @intCast(@min(@as(u64, buffer.len), stat.size - offset));
        var vectors = [_][]u8{buffer[0..length]};
        const read = try file.readPositional(io, &vectors, offset);
        if (read != length) return error.InvalidPdfCache;
        hasher.update(buffer[0..read]);
        offset += read;
    }
    var checksum: [cache_checksum_size]u8 = undefined;
    hasher.final(&checksum);
    return checksum;
}

fn cacheSeal(identity: CacheIdentity, checksum: [cache_checksum_size]u8) [cache_checksum_size]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(cache_seal_version);
    hasher.update(&.{@intFromEnum(identity.kind)});
    hasher.update(&identity.key);
    var page_count: [8]u8 = undefined;
    std.mem.writeInt(u64, &page_count, @intCast(identity.page_count), .little);
    hasher.update(&page_count);
    hasher.update(&checksum);
    var seal: [cache_checksum_size]u8 = undefined;
    hasher.final(&seal);
    return seal;
}

fn cacheSealPath(allocator: Allocator, path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}.sha256", .{path});
}

fn readCacheSeal(
    allocator: Allocator,
    io: std.Io,
    path: []const u8,
) !?[cache_checksum_size]u8 {
    const seal_path = try cacheSealPath(allocator, path);
    defer allocator.free(seal_path);
    const source = std.Io.Dir.cwd().readFileAlloc(
        io,
        seal_path,
        allocator,
        .limited(cache_checksum_size + 1),
    ) catch |err| switch (err) {
        error.FileNotFound, error.StreamTooLong => return null,
        else => return err,
    };
    defer allocator.free(source);
    if (source.len != cache_checksum_size) return null;
    var checksum: [cache_checksum_size]u8 = undefined;
    @memcpy(&checksum, source);
    return checksum;
}

fn writeCacheSeal(
    allocator: Allocator,
    io: std.Io,
    path: []const u8,
    seal: [cache_checksum_size]u8,
) !void {
    const seal_path = try cacheSealPath(allocator, path);
    defer allocator.free(seal_path);
    const temporary = try temporaryPath(allocator, seal_path, "sha256");
    defer allocator.free(temporary);
    errdefer deleteFile(io, temporary);
    const cwd = std.Io.Dir.cwd();
    try cwd.writeFile(io, .{
        .sub_path = temporary,
        .data = &seal,
        .flags = .{ .truncate = true },
    });
    try cwd.rename(temporary, cwd, seal_path, io);
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
