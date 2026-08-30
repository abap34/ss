const std = @import("std");
const c = @import("pdf_ffi").c;
const render = @import("render");
const page_backend = @import("pdf_backend");
const utils = @import("utils");

const Allocator = std.mem.Allocator;
var temporary_counter: usize = 0;

pub const cache_version = "ss-pdf-render-ir-v1";
const output_manifest_version = "ss-pdf-output-manifest-v3";
const document_digest_version = "ss-pdf-document-pages-v3";
const cache_seal_version = "ss-pdf-cache-seal-v1";
const output_manifest_read_limit = 2 * 1024 * 1024;
const max_replacement_pages = 8;
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
    has_annotations: bool,
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

const ReplacementPlan = struct {
    previous: OutputManifest,
    changed: []usize,
    base_path: []u8,

    fn deinit(self: *ReplacementPlan, allocator: Allocator) void {
        self.previous.deinit(allocator);
        allocator.free(self.changed);
        allocator.free(self.base_path);
        self.* = undefined;
    }

    fn requiresPage(self: *const ReplacementPlan, index: usize) bool {
        for (self.changed) |changed_index| if (changed_index == index) return true;
        return false;
    }
};

pub const Options = struct {
    jobs: ?usize = null,
    cache_dir: []const u8 = ".ss-cache/render",
    failure: ?*WriteFailure = null,
};

pub const WriteFailureKind = enum {
    preparation,
    cache,
    page_render,
    assembly,
    output,
};

pub const WriteFailure = struct {
    kind: WriteFailureKind = .output,
    operation: []const u8 = "write PDF output",
    path: ?[]u8 = null,
    detail: ?[]u8 = null,
    cause: ?anyerror = null,

    pub fn deinit(self: *WriteFailure, allocator: Allocator) void {
        if (self.path) |path| allocator.free(path);
        if (self.detail) |detail| allocator.free(detail);
        self.* = .{};
    }

    pub fn pathOr(self: *const WriteFailure, fallback: []const u8) []const u8 {
        return self.path orelse fallback;
    }

    fn record(
        self: *WriteFailure,
        allocator: Allocator,
        kind: WriteFailureKind,
        operation: []const u8,
        path: []const u8,
        cause: anyerror,
        detail: ?[]const u8,
    ) void {
        if (self.cause != null) return;
        self.kind = kind;
        self.operation = operation;
        self.cause = cause;
        self.path = allocator.dupe(u8, path) catch null;
        if (detail) |value| self.detail = allocator.dupe(u8, value) catch null;
    }
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
    ir.validate() catch |err| {
        recordWriteFailure(allocator, options, .preparation, "validate PDF render input", output, err);
        return err;
    };
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
    const cache_root = std.fs.path.join(allocator, &.{ options.cache_dir, cache_version }) catch |err| {
        recordWriteFailure(allocator, options, .preparation, "prepare PDF cache-root path", options.cache_dir, err);
        return err;
    };
    defer allocator.free(cache_root);
    const page_cache = std.fs.path.join(allocator, &.{ cache_root, "pages" }) catch |err| {
        recordWriteFailure(allocator, options, .preparation, "prepare PDF page-cache path", cache_root, err);
        return err;
    };
    defer allocator.free(page_cache);
    const document_cache = std.fs.path.join(allocator, &.{ cache_root, "documents" }) catch |err| {
        recordWriteFailure(allocator, options, .preparation, "prepare PDF document-cache path", cache_root, err);
        return err;
    };
    defer allocator.free(document_cache);
    const manifest_cache = std.fs.path.join(allocator, &.{ cache_root, "output-manifests" }) catch |err| {
        recordWriteFailure(allocator, options, .preparation, "prepare PDF manifest-cache path", cache_root, err);
        return err;
    };
    defer allocator.free(manifest_cache);
    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, page_cache) catch |err| {
        recordWriteFailure(allocator, options, .cache, "create PDF page-cache directory", page_cache, err);
        return err;
    };
    cwd.createDirPath(io, document_cache) catch |err| {
        recordWriteFailure(allocator, options, .cache, "create PDF document-cache directory", document_cache, err);
        return err;
    };
    cwd.createDirPath(io, manifest_cache) catch |err| {
        recordWriteFailure(allocator, options, .cache, "create PDF manifest-cache directory", manifest_cache, err);
        return err;
    };

    var current_manifest = buildOutputManifest(allocator, ir, options.jobs) catch |err| {
        recordWriteFailure(allocator, options, .preparation, "fingerprint PDF document", output, err);
        return err;
    };
    defer current_manifest.deinit(allocator);
    const document_digest = current_manifest.document_digest;
    const document_path = digestPath(allocator, document_cache, document_digest) catch |err| {
        recordWriteFailure(allocator, options, .preparation, "prepare cached PDF document path", document_cache, err);
        return err;
    };
    defer allocator.free(document_path);
    const manifest_path = outputManifestPath(allocator, manifest_cache, output) catch |err| {
        recordWriteFailure(allocator, options, .preparation, "prepare PDF output-manifest path", manifest_cache, err);
        return err;
    };
    defer allocator.free(manifest_path);
    const document_identity = CacheIdentity{
        .kind = .document,
        .key = document_digest,
        .page_count = ir.pages.len,
    };
    const document_cached = cachedPdfAvailable(allocator, io, document_path, document_identity) catch |err| {
        recordCacheOperationFailure(allocator, options, "read cached PDF document", document_path, err);
        return err;
    };
    if (document_cached) {
        current_manifest.assembly = .document_cache;
        if (progress) |value| {
            value.pageCompleted(value.context, ir.pages.len, ir.pages.len);
            value.assemblyCompleted(value.context, 1, 1);
        }
        var publish_failure = PublishFailure{ .path = output };
        publishOutput(allocator, io, document_path, output, &publish_failure) catch |err| {
            recordWriteFailure(allocator, options, publish_failure.kind, publish_failure.operation, publish_failure.path, err);
            return err;
        };
        persistOutputManifest(allocator, io, manifest_path, &current_manifest) catch |err| {
            recordCacheOperationFailure(allocator, options, "write PDF output manifest", manifest_path, err);
            return err;
        };
        return;
    }

    var replacement_plan = prepareReplacementPlan(
        allocator,
        io,
        manifest_path,
        document_cache,
        &current_manifest,
        options,
    ) catch |err| {
        recordWriteFailure(allocator, options, .preparation, "prepare PDF replacement plan", manifest_path, err);
        return err;
    };
    defer if (replacement_plan) |*plan| plan.deinit(allocator);

    const page_paths = allocator.alloc([]u8, ir.pages.len) catch |err| {
        recordWriteFailure(allocator, options, .preparation, "allocate PDF page-cache paths", page_cache, err);
        return err;
    };
    var initialized_paths: usize = 0;
    defer {
        for (page_paths[0..initialized_paths]) |path| allocator.free(path);
        allocator.free(page_paths);
    }
    const missing = allocator.alloc(bool, ir.pages.len) catch |err| {
        recordWriteFailure(allocator, options, .preparation, "allocate PDF page-cache state", page_cache, err);
        return err;
    };
    defer allocator.free(missing);
    var missing_count: usize = 0;
    for (current_manifest.pages, 0..) |page, index| {
        page_paths[index] = digestPath(allocator, page_cache, page.digest) catch |err| {
            recordWriteFailure(allocator, options, .preparation, "prepare cached PDF page path", page_cache, err);
            return err;
        };
        initialized_paths += 1;
        if (replacement_plan) |*plan| {
            if (!plan.requiresPage(index)) {
                missing[index] = false;
                continue;
            }
        }
        missing[index] = !(cachedPdfAvailable(
            allocator,
            io,
            page_paths[index],
            pageCacheIdentity(page),
        ) catch |err| {
            recordCacheOperationFailure(allocator, options, "read cached PDF page", page_paths[index], err);
            return err;
        });
        if (missing[index]) missing_count += 1;
    }
    if (progress) |value| value.pageCompleted(value.context, ir.pages.len - missing_count, ir.pages.len);
    if (missing_count != 0) {
        const resource_cache = std.fs.path.join(allocator, &.{ cache_root, "resources" }) catch |err| {
            recordWriteFailure(allocator, options, .preparation, "prepare PDF resource-cache path", cache_root, err);
            return err;
        };
        defer allocator.free(resource_cache);
        var resources = page_backend.ResourceFiles.initCached(allocator, io, &ir.resources, cache_root) catch |err| {
            if (utils.err.isFileSystemError(err))
                recordWriteFailure(allocator, options, .cache, "materialize PDF resources", resource_cache, err)
            else
                recordWriteFailure(allocator, options, .preparation, "prepare PDF resources", resource_cache, err);
            return err;
        };
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
            options,
        );
    }

    const temporary_document = temporaryPath(allocator, document_path, "pdf") catch |err| {
        recordWriteFailure(allocator, options, .preparation, "prepare temporary PDF document path", document_path, err);
        return err;
    };
    defer allocator.free(temporary_document);
    errdefer deleteFile(io, temporary_document);
    if (progress) |value| value.assemblyCompleted(value.context, 0, 1);
    const replaced = if (replacement_plan) |*plan|
        replaceCachedDocument(
            allocator,
            io,
            plan,
            page_paths,
            temporary_document,
        ) catch |err| {
            recordWriteFailure(
                allocator,
                options,
                if (err == error.OutOfMemory) .preparation else .assembly,
                if (err == error.OutOfMemory) "prepare replacement PDF assembly" else "assemble replacement PDF document",
                temporary_document,
                err,
            );
            return err;
        }
    else
        false;
    if (replaced) {
        current_manifest.assembly = .delta;
    } else {
        if (replacement_plan != null) {
            @memset(missing, false);
            missing_count = 0;
            for (current_manifest.pages, 0..) |page, index| {
                if (replacement_plan.?.requiresPage(index)) continue;
                missing[index] = !(cachedPdfAvailable(
                    allocator,
                    io,
                    page_paths[index],
                    pageCacheIdentity(page),
                ) catch |err| {
                    recordCacheOperationFailure(allocator, options, "read cached PDF page", page_paths[index], err);
                    return err;
                });
                if (missing[index]) missing_count += 1;
            }
            if (missing_count != 0) {
                const resource_cache = std.fs.path.join(allocator, &.{ cache_root, "resources" }) catch |err| {
                    recordWriteFailure(allocator, options, .preparation, "prepare PDF resource-cache path", cache_root, err);
                    return err;
                };
                defer allocator.free(resource_cache);
                var resources = page_backend.ResourceFiles.initCached(allocator, io, &ir.resources, cache_root) catch |err| {
                    if (utils.err.isFileSystemError(err))
                        recordWriteFailure(allocator, options, .cache, "materialize PDF resources", resource_cache, err)
                    else
                        recordWriteFailure(allocator, options, .preparation, "prepare PDF resources", resource_cache, err);
                    return err;
                };
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
                    options,
                );
            }
        }
        mergePages(allocator, ir, page_paths, temporary_document) catch |err| {
            recordWriteFailureWithDetail(
                allocator,
                options,
                if (err == error.OutOfMemory) .preparation else .assembly,
                if (err == error.OutOfMemory) "prepare PDF assembly" else "assemble PDF document",
                temporary_document,
                err,
                if (err == error.PdfAssemblyFailed) qpdfLastError() else null,
            );
            return err;
        };
        current_manifest.assembly = .full;
    }
    publishCache(allocator, io, temporary_document, document_path, document_identity) catch |err| {
        recordCacheOperationFailure(allocator, options, "publish cached PDF document", document_path, err);
        return err;
    };
    if (progress) |value| value.assemblyCompleted(value.context, 1, 1);
    var publish_failure = PublishFailure{ .path = output };
    publishOutput(allocator, io, document_path, output, &publish_failure) catch |err| {
        recordWriteFailure(allocator, options, publish_failure.kind, publish_failure.operation, publish_failure.path, err);
        return err;
    };
    persistOutputManifest(allocator, io, manifest_path, &current_manifest) catch |err| {
        recordCacheOperationFailure(allocator, options, "write PDF output manifest", manifest_path, err);
        return err;
    };
}

fn recordWriteFailure(
    allocator: Allocator,
    options: Options,
    kind: WriteFailureKind,
    operation: []const u8,
    path: []const u8,
    cause: anyerror,
) void {
    recordWriteFailureWithDetail(allocator, options, kind, operation, path, cause, null);
}

fn recordCacheOperationFailure(
    allocator: Allocator,
    options: Options,
    operation: []const u8,
    path: []const u8,
    cause: anyerror,
) void {
    recordWriteFailure(
        allocator,
        options,
        if (utils.err.isFileSystemError(cause)) .cache else .preparation,
        operation,
        path,
        cause,
    );
}

fn recordWriteFailureWithDetail(
    allocator: Allocator,
    options: Options,
    kind: WriteFailureKind,
    operation: []const u8,
    path: []const u8,
    cause: anyerror,
    detail: ?[]const u8,
) void {
    if (options.failure) |failure| failure.record(allocator, kind, operation, path, cause, detail);
}

fn qpdfLastError() ?[]const u8 {
    const pointer = c.ss_qpdf_last_error();
    if (pointer == null) return null;
    const detail = std.mem.span(pointer);
    return if (detail.len == 0) null else detail;
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
    options: Options,
) !void {
    const worker_count = configuredWorkerCount(requested_jobs, countMissing(missing));
    if (worker_count <= 1) {
        var completed = ir.pages.len - countMissing(missing);
        for (missing, 0..) |is_missing, index| {
            if (!is_missing) continue;
            var failure = PageFailure{};
            renderPageToCache(
                allocator,
                io,
                ir,
                index,
                page_paths[index],
                pageCacheIdentity(manifest_pages[index]),
                resources,
                &failure,
            ) catch |err| {
                recordWriteFailureWithDetail(
                    allocator,
                    options,
                    failure.kind,
                    failure.operation,
                    page_paths[index],
                    err,
                    failure.detail,
                );
                return err;
            };
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
    const threads = allocator.alloc(std.Thread, worker_count) catch |err| {
        recordWriteFailure(allocator, options, .preparation, "prepare parallel PDF page rendering", options.cache_dir, err);
        return err;
    };
    defer allocator.free(threads);
    var started: usize = 0;
    var joined = false;
    errdefer if (!joined) {
        work.failure_state.store(2, .release);
        for (threads[0..started]) |thread| thread.join();
    };
    while (started < worker_count) : (started += 1) {
        threads[started] = std.Thread.spawn(.{}, pageWorker, .{&work}) catch |err| {
            recordWriteFailure(allocator, options, .preparation, "start parallel PDF page renderer", options.cache_dir, err);
            return err;
        };
    }

    var last_completed = work.completed.load(.acquire);
    while (work.failure_state.load(.acquire) == 0 and last_completed < ir.pages.len) {
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
    if (work.failure_state.load(.acquire) != 0) {
        const failed_index = work.failed_index;
        const err = if (work.error_code != 0) @errorFromInt(work.error_code) else error.PdfPageRenderFailed;
        const path = if (failed_index < page_paths.len) page_paths[failed_index] else options.cache_dir;
        recordWriteFailureWithDetail(
            allocator,
            options,
            work.failure_kind,
            work.failure_operation,
            path,
            err,
            if (work.failure_detail_len == 0) null else work.failure_detail[0..work.failure_detail_len],
        );
        return err;
    }
}

const PageFailure = struct {
    kind: WriteFailureKind = .page_render,
    operation: []const u8 = "render PDF page",
    detail: ?[]const u8 = null,
};

const max_page_failure_detail_bytes = 2048;

const PageWork = struct {
    io: std.Io,
    ir: *const render.Ir,
    manifest_pages: []const ManifestPage,
    page_paths: []const []const u8,
    missing: []const bool,
    resources: *const page_backend.ResourceFiles,
    next: std.atomic.Value(usize) = .init(0),
    completed: std.atomic.Value(usize),
    failure_state: std.atomic.Value(u8) = .init(0),
    failed_index: usize = std.math.maxInt(usize),
    error_code: u16 = 0,
    failure_kind: WriteFailureKind = .page_render,
    failure_operation: []const u8 = "render PDF page",
    failure_detail: [max_page_failure_detail_bytes]u8 = undefined,
    failure_detail_len: usize = 0,

    fn recordFailure(self: *PageWork, index: usize, err: anyerror, failure: PageFailure) void {
        if (self.failure_state.cmpxchgStrong(0, 1, .acq_rel, .acquire) != null) return;
        self.failed_index = index;
        self.error_code = @intFromError(err);
        self.failure_kind = failure.kind;
        self.failure_operation = failure.operation;
        if (failure.detail) |detail| {
            self.failure_detail_len = @min(detail.len, self.failure_detail.len);
            @memcpy(self.failure_detail[0..self.failure_detail_len], detail[0..self.failure_detail_len]);
        }
        self.failure_state.store(2, .release);
    }
};

fn pageWorker(work: *PageWork) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();
    while (work.failure_state.load(.acquire) == 0) {
        const index = work.next.fetchAdd(1, .monotonic);
        if (index >= work.ir.pages.len) return;
        if (!work.missing[index]) continue;
        var failure = PageFailure{};
        renderPageToCache(
            arena.allocator(),
            work.io,
            work.ir,
            index,
            work.page_paths[index],
            pageCacheIdentity(work.manifest_pages[index]),
            work.resources,
            &failure,
        ) catch |err| {
            work.recordFailure(index, err, failure);
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
    failure: *PageFailure,
) !void {
    const cached = cachedPdfAvailable(allocator, io, destination, identity) catch |err| {
        failure.* = .{
            .kind = if (utils.err.isFileSystemError(err)) .cache else .preparation,
            .operation = "read PDF page cache",
        };
        return err;
    };
    if (cached) return;
    const temporary = temporaryPath(allocator, destination, "pdf") catch |err| {
        failure.* = .{ .kind = .preparation, .operation = "prepare temporary PDF page path" };
        return err;
    };
    defer allocator.free(temporary);
    errdefer deleteFile(io, temporary);
    failure.* = .{};
    page_backend.render(allocator, io, ir, page_index, temporary, resources) catch |err| {
        failure.kind = if (err == error.CairoWriteFailed or utils.err.isFileSystemError(err)) .cache else .page_render;
        failure.operation = if (failure.kind == .cache) "write PDF page cache" else "render PDF page";
        failure.detail = switch (err) {
            error.AssetConversionFailed => qpdfLastError(),
            error.CairoCreateFailed,
            error.CairoWriteFailed,
            error.CairoFailed,
            error.ImageDecodeFailed,
            => page_backend.lastFailureDetail(),
            else => null,
        };
        return err;
    };
    validateGeneratedPdf(allocator, io, temporary, 1, false, &failure.detail) catch |err| {
        if (err == error.OutOfMemory) {
            failure.* = .{ .kind = .preparation, .operation = "prepare PDF page validation" };
        } else if (utils.err.isFileSystemError(err)) {
            failure.* = .{ .kind = .cache, .operation = "validate PDF page cache" };
        }
        return err;
    };
    publishCache(allocator, io, temporary, destination, identity) catch |err| {
        failure.* = .{
            .kind = if (utils.err.isFileSystemError(err)) .cache else .preparation,
            .operation = "write PDF page cache",
        };
        return err;
    };
}

fn mergePages(allocator: Allocator, ir: *const render.Ir, inputs: []const []u8, output: []const u8) !void {
    const output_z = try allocator.dupeZ(u8, output);
    defer allocator.free(output_z);
    if (ir.pages.len == 0) {
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
    var links = std.ArrayList(c.SsQpdfLink).empty;
    defer links.deinit(allocator);
    var destinations = std.ArrayList(c.SsQpdfDestination).empty;
    defer destinations.deinit(allocator);
    for (ir.pages, 0..) |page, page_index| {
        for (page.links.items) |link| try links.append(allocator, .{
            .page_index = page_index,
            .kind = switch (link.kind) {
                .uri => c.SS_QPDF_LINK_URI,
                .destination => c.SS_QPDF_LINK_DESTINATION,
            },
            .target = link.target.ptr,
            .x = link.rect.x,
            .y = link.rect.y,
            .width = link.rect.width,
            .height = link.rect.height,
        });
        for (page.destinations.items) |destination| try destinations.append(allocator, .{
            .page_index = page_index,
            .name = destination.name.ptr,
            .x = destination.point.x,
            .y = destination.point.y,
        });
    }
    if (c.ss_qpdf_merge(
        output_z.ptr,
        pointers.ptr,
        pointers.len,
        1,
        if (links.items.len == 0) null else links.items.ptr,
        links.items.len,
        if (destinations.items.len == 0) null else destinations.items.ptr,
        destinations.items.len,
    ) != 0) return error.PdfAssemblyFailed;
}

fn prepareReplacementPlan(
    allocator: Allocator,
    io: std.Io,
    manifest_path: []const u8,
    document_cache: []const u8,
    current: *const OutputManifest,
    options: Options,
) !?ReplacementPlan {
    var previous = (readOutputManifest(allocator, io, manifest_path) catch |err| switch (err) {
        error.InvalidOutputManifest, error.InvalidCharacter, error.Overflow, error.StreamTooLong => return null,
        else => {
            recordCacheOperationFailure(allocator, options, "read prior PDF output manifest", manifest_path, err);
            return err;
        },
    }) orelse return null;
    var previous_active = true;
    defer if (previous_active) previous.deinit(allocator);
    if (previous.pages.len != current.pages.len) return null;

    var changed = std.ArrayList(usize).empty;
    var changed_active = true;
    defer if (changed_active) changed.deinit(allocator);
    for (previous.pages, current.pages, 0..) |old_page, new_page, index| {
        if (std.mem.eql(u8, &old_page.digest, &new_page.digest)) continue;
        if (old_page.has_annotations or new_page.has_annotations) return null;
        changed.append(allocator, index) catch |err| {
            recordWriteFailure(allocator, options, .preparation, "compare prior PDF page fingerprints", manifest_path, err);
            return err;
        };
    }
    if (changed.items.len == 0 or changed.items.len >= current.pages.len) return null;
    const replacement_limit = @min(max_replacement_pages, @max(@as(usize, 1), current.pages.len / 4));
    if (changed.items.len > replacement_limit) return null;

    const base_path = digestPath(allocator, document_cache, previous.document_digest) catch |err| {
        recordWriteFailure(allocator, options, .preparation, "prepare prior cached PDF document path", document_cache, err);
        return err;
    };
    errdefer allocator.free(base_path);
    const base_available = cachedPdfAvailable(allocator, io, base_path, .{
        .kind = .document,
        .key = previous.document_digest,
        .page_count = previous.pages.len,
    }) catch |err| {
        recordCacheOperationFailure(allocator, options, "read prior cached PDF document", base_path, err);
        return err;
    };
    if (!base_available) {
        allocator.free(base_path);
        return null;
    }
    const changed_pages = changed.toOwnedSlice(allocator) catch |err| {
        recordWriteFailure(allocator, options, .preparation, "store PDF replacement-page plan", manifest_path, err);
        return err;
    };
    changed_active = false;
    previous_active = false;
    return .{
        .previous = previous,
        .changed = changed_pages,
        .base_path = base_path,
    };
}

fn replaceCachedDocument(
    allocator: Allocator,
    io: std.Io,
    plan: *const ReplacementPlan,
    page_paths: []const []u8,
    output: []const u8,
) !bool {
    const output_z = try allocator.dupeZ(u8, output);
    defer allocator.free(output_z);
    const base_z = try allocator.dupeZ(u8, plan.base_path);
    defer allocator.free(base_z);
    const replacements = try allocator.alloc([:0]u8, plan.changed.len);
    var initialized: usize = 0;
    defer {
        for (replacements[0..initialized]) |path| allocator.free(path);
        allocator.free(replacements);
    }
    const replacement_pointers = try allocator.alloc([*c]const u8, plan.changed.len);
    defer allocator.free(replacement_pointers);
    for (plan.changed, 0..) |page_index, replacement_index| {
        replacements[replacement_index] = try allocator.dupeZ(u8, page_paths[page_index]);
        initialized += 1;
        replacement_pointers[replacement_index] = replacements[replacement_index].ptr;
    }
    if (c.ss_qpdf_replace_pages(
        output_z.ptr,
        base_z.ptr,
        replacement_pointers.ptr,
        plan.changed.ptr,
        plan.changed.len,
    ) != 0) {
        deleteFile(io, output);
        return false;
    }
    return true;
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
        .has_annotations = page.links.items.len != 0 or page.destinations.items.len != 0,
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
        hasher.update(&.{@as(u8, @intFromBool(page.has_annotations))});
    }
    var digest: render.Fingerprint = undefined;
    hasher.final(&digest);
    return digest;
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
            "page\t{s}\t{d}\n",
            .{
                &page_hex,
                @intFromBool(page.has_annotations),
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
) !void {
    try writeOutputManifest(allocator, io, path, manifest);
}

fn readOutputManifest(allocator: Allocator, io: std.Io, path: []const u8) !?OutputManifest {
    const text = utils.fs.readFileAllocLimited(io, allocator, path, .limited(output_manifest_read_limit)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(text);
    var lines = std.mem.splitScalar(u8, text, '\n');
    if (!std.mem.eql(u8, lines.next() orelse return error.InvalidOutputManifest, output_manifest_version)) {
        return error.InvalidOutputManifest;
    }
    const document_line = lines.next() orelse return error.InvalidOutputManifest;
    if (!std.mem.startsWith(u8, document_line, "document\t")) return error.InvalidOutputManifest;
    const document_digest = try parseDigest(document_line["document\t".len..]);
    const assembly_line = lines.next() orelse return error.InvalidOutputManifest;
    if (!std.mem.startsWith(u8, assembly_line, "assembly\t")) return error.InvalidOutputManifest;
    const assembly = try parseAssembly(assembly_line["assembly\t".len..]);
    const pages_line = lines.next() orelse return error.InvalidOutputManifest;
    if (!std.mem.startsWith(u8, pages_line, "pages\t")) return error.InvalidOutputManifest;
    const page_count = try std.fmt.parseUnsigned(usize, pages_line["pages\t".len..], 10);
    if (page_count > output_manifest_read_limit / 16) return error.InvalidOutputManifest;
    const pages = try allocator.alloc(ManifestPage, page_count);
    errdefer allocator.free(pages);
    for (pages) |*page| {
        const line = lines.next() orelse return error.InvalidOutputManifest;
        var fields = std.mem.splitScalar(u8, line, '\t');
        if (!std.mem.eql(u8, fields.next() orelse return error.InvalidOutputManifest, "page")) {
            return error.InvalidOutputManifest;
        }
        const digest = try parseDigest(fields.next() orelse return error.InvalidOutputManifest);
        const annotations = fields.next() orelse return error.InvalidOutputManifest;
        if (fields.next() != null or
            !validManifestBoolean(annotations))
        {
            return error.InvalidOutputManifest;
        }
        page.* = .{
            .digest = digest,
            .has_annotations = annotations[0] == '1',
        };
    }
    while (lines.next()) |line| if (line.len != 0) return error.InvalidOutputManifest;
    const actual_document_digest = documentDigest(pages);
    if (!std.mem.eql(u8, &actual_document_digest, &document_digest)) return error.InvalidOutputManifest;
    return .{
        .document_digest = document_digest,
        .assembly = assembly,
        .pages = pages,
    };
}

fn assemblyName(assembly: AssemblyKind) []const u8 {
    return switch (assembly) {
        .full => "full",
        .delta => "delta",
        .document_cache => "document-cache",
    };
}

fn parseAssembly(text: []const u8) !AssemblyKind {
    if (std.mem.eql(u8, text, "full")) return .full;
    if (std.mem.eql(u8, text, "delta")) return .delta;
    if (std.mem.eql(u8, text, "document-cache")) return .document_cache;
    return error.InvalidOutputManifest;
}

fn validManifestBoolean(text: []const u8) bool {
    return text.len == 1 and (text[0] == '0' or text[0] == '1');
}

fn parseDigest(text: []const u8) !render.Fingerprint {
    var digest: render.Fingerprint = undefined;
    if (text.len != digest.len * 2) return error.InvalidOutputManifest;
    for (&digest, 0..) |*byte, index| {
        const high = std.fmt.charToDigit(text[index * 2], 16) catch return error.InvalidOutputManifest;
        const low = std.fmt.charToDigit(text[index * 2 + 1], 16) catch return error.InvalidOutputManifest;
        byte.* = @intCast(high * 16 + low);
    }
    return digest;
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

const PublishFailure = struct {
    kind: WriteFailureKind = .output,
    operation: []const u8 = "publish PDF output",
    path: []const u8,
};

fn publishOutput(
    allocator: Allocator,
    io: std.Io,
    source: []const u8,
    output: []const u8,
    failure: *PublishFailure,
) !void {
    const cwd = std.Io.Dir.cwd();
    if (std.fs.path.dirname(output)) |parent| {
        failure.* = .{ .operation = "create PDF output directory", .path = parent };
        cwd.createDirPath(io, parent) catch |err| {
            if (!utils.err.isFileSystemError(err)) failure.kind = .preparation;
            return err;
        };
    }
    failure.* = .{ .kind = .preparation, .operation = "prepare temporary PDF output path", .path = output };
    const temporary = try temporaryPath(allocator, output, "pdf");
    defer allocator.free(temporary);
    errdefer deleteFile(io, temporary);
    failure.* = .{ .operation = "copy cached PDF document to output", .path = output };
    cwd.copyFile(source, cwd, temporary, io, .{ .make_path = true, .replace = true }) catch |err| {
        var source_file = cwd.openFile(io, source, .{}) catch |source_err| {
            failure.* = .{
                .kind = if (utils.err.isFileSystemError(source_err)) .cache else .preparation,
                .operation = "read cached PDF document for publication",
                .path = source,
            };
            return source_err;
        };
        source_file.close(io);
        if (!utils.err.isFileSystemError(err)) failure.kind = .preparation;
        return err;
    };
    validatePdf(allocator, io, temporary) catch |err| {
        failure.* = switch (err) {
            error.InvalidPdfCache => .{ .kind = .cache, .operation = "validate cached PDF document for publication", .path = source },
            else => if (utils.err.isFileSystemError(err))
                .{ .operation = "validate copied PDF output", .path = output }
            else
                .{ .kind = .preparation, .operation = "validate copied PDF output", .path = output },
        };
        return err;
    };
    failure.* = .{ .operation = "publish PDF output", .path = output };
    cwd.rename(temporary, cwd, output, io) catch |err| {
        if (!utils.err.isFileSystemError(err)) failure.kind = .preparation;
        return err;
    };
}

fn cachedPdfAvailable(
    allocator: Allocator,
    io: std.Io,
    path: []const u8,
    identity: CacheIdentity,
) !bool {
    const expected = try readCacheSeal(allocator, io, path) orelse return false;
    const checksum = hashFile(io, path) catch |err| switch (err) {
        error.FileNotFound, error.NotDir, error.InvalidPdfCache => return false,
        else => return err,
    };
    const actual = cacheSeal(identity, checksum);
    return std.mem.eql(u8, &actual, &expected);
}

fn validateGeneratedPdf(
    allocator: Allocator,
    io: std.Io,
    path: []const u8,
    expected_page_count: usize,
    strict: bool,
    qpdf_detail: *?[]const u8,
) !void {
    try validatePdf(allocator, io, path);
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    if (c.ss_qpdf_validate(path_z.ptr, expected_page_count, @intFromBool(strict)) != 0) {
        qpdf_detail.* = qpdfLastError();
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
    const source = utils.fs.readFileAllocLimited(
        io,
        allocator,
        seal_path,
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
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.kind != .file or stat.size < 8) return error.InvalidPdfCache;
    var header: [5]u8 = undefined;
    var header_vectors = [_][]u8{header[0..]};
    if (try file.readPositional(io, &header_vectors, 0) != header.len or !std.mem.eql(u8, &header, "%PDF-")) {
        return error.InvalidPdfCache;
    }
    const tail_length: usize = @intCast(@min(stat.size, 4096));
    const tail = try allocator.alloc(u8, tail_length);
    defer allocator.free(tail);
    var tail_vectors = [_][]u8{tail};
    const read = try file.readPositional(io, &tail_vectors, stat.size - tail_length);
    if (std.mem.indexOf(u8, tail[0..read], "%%EOF") == null) return error.InvalidPdfCache;
}

fn configuredWorkerCount(requested: ?usize, task_count: usize) usize {
    if (task_count == 0) return 0;
    if (requested) |jobs| return @min(@max(jobs, 1), task_count);
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
