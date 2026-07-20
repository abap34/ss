const std = @import("std");
const c = @import("pdf_ffi").c;
const render = @import("render");

const max_stable_read_attempts = 4;

const FileIdentity = struct {
    inode: std.Io.File.INode,
    size: u64,
    mtime_ns: i96,
    ctime_ns: i96,

    fn fromStat(stat: std.Io.File.Stat) FileIdentity {
        return .{
            .inode = stat.inode,
            .size = stat.size,
            .mtime_ns = stat.mtime.nanoseconds,
            .ctime_ns = stat.ctime.nanoseconds,
        };
    }

    fn matchesStat(self: FileIdentity, stat: std.Io.File.Stat) bool {
        return self.inode == stat.inode and self.size == stat.size and
            self.mtime_ns == stat.mtime.nanoseconds and self.ctime_ns == stat.ctime.nanoseconds;
    }
};

const CachedSource = struct {
    path: []u8,
    inode: std.Io.File.INode,
    size: u64,
    mtime_ns: i96,
    ctime_ns: i96,
    resource: render.Resource,
    byte_size: usize,
    last_used: u64 = 0,

    fn deinit(self: *CachedSource, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        self.resource.deinit(allocator);
    }

    fn cloneResource(self: *const CachedSource, allocator: std.mem.Allocator) !render.Resource {
        return try self.resource.clone(allocator);
    }

    fn identity(self: *const CachedSource) FileIdentity {
        return .{
            .inode = self.inode,
            .size = self.size,
            .mtime_ns = self.mtime_ns,
            .ctime_ns = self.ctime_ns,
        };
    }
};

pub const FileFingerprint = struct {
    present: bool,
    digest: u64,
};

const CachedFingerprint = struct {
    path: []u8,
    inode: std.Io.File.INode,
    size: u64,
    mtime_ns: i96,
    ctime_ns: i96,
    digest: u64,
};

pub const SourceCache = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    sources: std.ArrayList(CachedSource) = .empty,
    fingerprints: std.ArrayList(CachedFingerprint) = .empty,
    source_bytes: usize = 0,
    access_clock: u64 = 0,

    const max_sources = 256;
    const max_source_bytes = 512 * 1024 * 1024;
    const max_fingerprints = 4096;

    pub fn init(allocator: std.mem.Allocator, io: std.Io) SourceCache {
        return .{ .allocator = allocator, .io = io };
    }

    pub fn deinit(self: *SourceCache) void {
        for (self.sources.items) |*source| source.deinit(self.allocator);
        self.sources.deinit(self.allocator);
        for (self.fingerprints.items) |fingerprint| self.allocator.free(fingerprint.path);
        self.fingerprints.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn fileFingerprint(self: *SourceCache, path: []const u8) !FileFingerprint {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        for (0..max_stable_read_attempts) |_| {
            const stat = statPath(self.io, path) catch |err| switch (err) {
                error.FileNotFound => return .{ .present = false, .digest = 0 },
                else => return err,
            };
            for (self.fingerprints.items) |fingerprint| {
                if (!std.mem.eql(u8, fingerprint.path, path)) continue;
                if (fingerprint.inode == stat.inode and fingerprint.size == stat.size and
                    fingerprint.mtime_ns == stat.mtime.nanoseconds and fingerprint.ctime_ns == stat.ctime.nanoseconds)
                {
                    return .{ .present = true, .digest = fingerprint.digest };
                }
                break;
            }

            const hashed = (try hashFileGeneration(self.io, path)) orelse continue;
            const confirmed = statPath(self.io, path) catch |err| switch (err) {
                error.FileNotFound => continue,
                else => return err,
            };
            if (!hashed.identity.matchesStat(confirmed)) continue;
            for (self.fingerprints.items) |*fingerprint| {
                if (!std.mem.eql(u8, fingerprint.path, path)) continue;
                fingerprint.size = hashed.identity.size;
                fingerprint.inode = hashed.identity.inode;
                fingerprint.mtime_ns = hashed.identity.mtime_ns;
                fingerprint.ctime_ns = hashed.identity.ctime_ns;
                fingerprint.digest = hashed.digest;
                return .{ .present = true, .digest = hashed.digest };
            }
            const owned_path = try self.allocator.dupe(u8, path);
            errdefer self.allocator.free(owned_path);
            if (self.fingerprints.items.len >= max_fingerprints) {
                for (self.fingerprints.items) |fingerprint| self.allocator.free(fingerprint.path);
                self.fingerprints.clearRetainingCapacity();
            }
            try self.fingerprints.append(self.allocator, .{
                .path = owned_path,
                .inode = hashed.identity.inode,
                .size = hashed.identity.size,
                .mtime_ns = hashed.identity.mtime_ns,
                .ctime_ns = hashed.identity.ctime_ns,
                .digest = hashed.digest,
            });
            return .{ .present = true, .digest = hashed.digest };
        }
        return error.ResourceChangedDuringRead;
    }

    fn resource(
        self: *SourceCache,
        allocator: std.mem.Allocator,
        kind: render.ResourceKind,
        path: []const u8,
        identity: *FileIdentity,
    ) !render.Resource {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const stat = try statPath(self.io, path);
        var existing_index: ?usize = null;
        for (self.sources.items, 0..) |*source, index| {
            if (source.resource.kind != kind or !std.mem.eql(u8, source.path, path)) continue;
            if (source.inode == stat.inode and source.size == stat.size and
                source.mtime_ns == stat.mtime.nanoseconds and source.ctime_ns == stat.ctime.nanoseconds)
            {
                source.last_used = self.nextAccess();
                identity.* = source.identity();
                return try source.cloneResource(allocator);
            }
            existing_index = index;
            break;
        }

        var replacement = try self.loadSource(kind, path);
        const replacement_bytes = replacement.byte_size;
        if (replacement_bytes > max_source_bytes) {
            identity.* = replacement.identity();
            self.allocator.free(replacement.path);
            const result = replacement.resource;
            if (existing_index) |index| {
                var removed = self.sources.swapRemove(index);
                self.source_bytes -= removed.byte_size;
                removed.deinit(self.allocator);
            }
            return result;
        }
        replacement.last_used = self.nextAccess();
        if (existing_index) |index| {
            const source = &self.sources.items[index];
            const previous_bytes = source.byte_size;
            source.deinit(self.allocator);
            source.* = replacement;
            self.source_bytes -= previous_bytes;
            self.source_bytes += replacement_bytes;
            var result = try source.cloneResource(allocator);
            errdefer result.deinit(allocator);
            identity.* = source.identity();
            self.trimSources();
            return result;
        }

        var replacement_owned = true;
        errdefer if (replacement_owned) replacement.deinit(self.allocator);
        try self.sources.append(self.allocator, replacement);
        replacement_owned = false;
        self.source_bytes += replacement_bytes;
        var result = try self.sources.items[self.sources.items.len - 1].cloneResource(allocator);
        errdefer result.deinit(allocator);
        identity.* = self.sources.items[self.sources.items.len - 1].identity();
        self.trimSources();
        return result;
    }

    fn loadSource(
        self: *SourceCache,
        kind: render.ResourceKind,
        path: []const u8,
    ) !CachedSource {
        const owned_path = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned_path);
        var identity: FileIdentity = undefined;
        var resource_value = try loadStableResource(self.allocator, self.io, kind, path, &identity);
        errdefer resource_value.deinit(self.allocator);
        try resource_value.share(self.allocator);
        const byte_size = @sizeOf(CachedSource) +| owned_path.len +| resource_value.retainedByteSize();
        return .{
            .path = owned_path,
            .inode = identity.inode,
            .size = identity.size,
            .mtime_ns = identity.mtime_ns,
            .ctime_ns = identity.ctime_ns,
            .resource = resource_value,
            .byte_size = byte_size,
        };
    }

    fn nextAccess(self: *SourceCache) u64 {
        self.access_clock +%= 1;
        if (self.access_clock == 0) self.access_clock = 1;
        return self.access_clock;
    }

    fn trimSources(self: *SourceCache) void {
        while (self.sources.items.len > 1 and
            (self.sources.items.len > max_sources or self.source_bytes > max_source_bytes))
        {
            var oldest_index: usize = 0;
            var oldest_access = self.sources.items[0].last_used;
            for (self.sources.items[1..], 1..) |source, index| {
                if (source.last_used >= oldest_access) continue;
                oldest_index = index;
                oldest_access = source.last_used;
            }
            var removed = self.sources.swapRemove(oldest_index);
            self.source_bytes -= removed.byte_size;
            removed.deinit(self.allocator);
        }
    }
};

pub const SourceDependency = struct {
    kind: render.ResourceKind,
    resource: render.ResourceId,
    path: []u8,
    inode: std.Io.File.INode,
    size: u64,
    mtime_ns: i96,
    ctime_ns: i96,

    pub fn deinit(self: *SourceDependency, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        self.* = undefined;
    }

    pub fn clone(self: SourceDependency, allocator: std.mem.Allocator) !SourceDependency {
        var result = self;
        result.path = try allocator.dupe(u8, self.path);
        return result;
    }

    pub fn isCurrent(self: SourceDependency, io: std.Io) !bool {
        var file = std.Io.Dir.cwd().openFile(io, self.path, .{}) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        defer file.close(io);
        const stat = try file.stat(io);
        if (self.inode != stat.inode or self.size != stat.size or
            self.mtime_ns != stat.mtime.nanoseconds or self.ctime_ns != stat.ctime.nanoseconds)
        {
            return false;
        }
        const current = statPath(io, self.path) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        return sameFile(stat, current);
    }
};

pub fn deinitSourceDependencies(allocator: std.mem.Allocator, dependencies: []SourceDependency) void {
    for (dependencies) |*dependency| dependency.deinit(allocator);
    allocator.free(dependencies);
}

pub const Builder = struct {
    entries: std.ArrayList(render.Resource) = .empty,
    sources: std.ArrayList(Source) = .empty,
    mutex: std.Io.Mutex = .init,
    source_ready: std.Io.Condition = .init,
    cache: ?*SourceCache = null,

    pub fn deinit(self: *Builder, allocator: std.mem.Allocator) void {
        for (self.entries.items) |*entry| entry.deinit(allocator);
        self.entries.deinit(allocator);
        self.clearSources(allocator);
        self.* = .{};
    }

    pub fn addPath(
        self: *Builder,
        allocator: std.mem.Allocator,
        io: std.Io,
        kind: render.ResourceKind,
        path: []const u8,
    ) !render.ResourceId {
        if (try self.claimSource(allocator, io, kind, path)) |id| return id;
        return self.loadSource(allocator, io, kind, path) catch |err| {
            self.failSource(io, kind, path, err);
            return err;
        };
    }

    pub fn addResource(
        self: *Builder,
        allocator: std.mem.Allocator,
        io: std.Io,
        source: *const render.Resource,
    ) !render.ResourceId {
        self.mutex.lockUncancelable(io);
        for (self.entries.items) |entry| {
            if (!std.mem.eql(u8, &entry.id, &source.id)) continue;
            if (entry.kind != source.kind) {
                self.mutex.unlock(io);
                return error.RenderResourceKindConflict;
            }
            self.mutex.unlock(io);
            return source.id;
        }
        self.mutex.unlock(io);

        var resource = try source.clone(allocator);
        errdefer resource.deinit(allocator);
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        for (self.entries.items) |entry| {
            if (!std.mem.eql(u8, &entry.id, &resource.id)) continue;
            if (entry.kind != resource.kind) return error.RenderResourceKindConflict;
            const id = resource.id;
            resource.deinit(allocator);
            return id;
        }
        const id = resource.id;
        try self.entries.append(allocator, resource);
        return id;
    }

    fn claimSource(
        self: *Builder,
        allocator: std.mem.Allocator,
        io: std.Io,
        kind: render.ResourceKind,
        path: []const u8,
    ) !?render.ResourceId {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        while (true) {
            if (self.findSource(kind, path)) |source| switch (source.state) {
                .loading => {
                    self.source_ready.waitUncancelable(io, &self.mutex);
                    continue;
                },
                .ready => |ready| return ready.id,
                .failed => |err| return err,
            };
            const source_path = try allocator.dupe(u8, path);
            errdefer allocator.free(source_path);
            try self.sources.append(allocator, .{ .kind = kind, .path = source_path });
            return null;
        }
    }

    fn loadSource(
        self: *Builder,
        allocator: std.mem.Allocator,
        io: std.Io,
        kind: render.ResourceKind,
        path: []const u8,
    ) !render.ResourceId {
        var identity: FileIdentity = undefined;
        var resource = if (self.cache) |cache|
            try cache.resource(allocator, kind, path, &identity)
        else
            try loadStableResource(allocator, io, kind, path, &identity);
        errdefer resource.deinit(allocator);

        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const source = self.findSource(kind, path) orelse return error.MissingRenderResource;
        if (source.state != .loading) return error.InvalidRenderResourceState;
        for (self.entries.items) |entry| {
            if (!std.mem.eql(u8, &entry.id, &resource.id)) continue;
            if (entry.kind != kind) return error.RenderResourceKindConflict;
            const id = resource.id;
            resource.deinit(allocator);
            source.state = .{ .ready = .{ .id = id, .identity = identity } };
            self.source_ready.broadcast(io);
            return id;
        }
        const id = resource.id;
        try self.entries.append(allocator, resource);
        source.state = .{ .ready = .{ .id = id, .identity = identity } };
        self.source_ready.broadcast(io);
        return id;
    }

    fn failSource(self: *Builder, io: std.Io, kind: render.ResourceKind, path: []const u8, err: anyerror) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const source = self.findSource(kind, path) orelse return;
        if (source.state == .loading) source.state = .{ .failed = err };
        self.source_ready.broadcast(io);
    }

    pub fn take(self: *Builder, allocator: std.mem.Allocator) !render.ResourceGraph {
        std.mem.sort(render.Resource, self.entries.items, {}, lessThan);
        const entries = try self.entries.toOwnedSlice(allocator);
        self.clearSources(allocator);
        self.* = .{};
        return .{ .entries = entries };
    }

    pub fn sourceDependencies(
        self: *Builder,
        allocator: std.mem.Allocator,
        io: std.Io,
    ) ![]SourceDependency {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        var dependencies = std.ArrayList(SourceDependency).empty;
        errdefer {
            for (dependencies.items) |*dependency| dependency.deinit(allocator);
            dependencies.deinit(allocator);
        }
        try dependencies.ensureTotalCapacity(allocator, self.sources.items.len);
        for (self.sources.items) |source| {
            const ready = switch (source.state) {
                .ready => |value| value,
                .loading, .failed => continue,
            };
            dependencies.appendAssumeCapacity(.{
                .kind = source.kind,
                .resource = ready.id,
                .path = try allocator.dupe(u8, source.path),
                .inode = ready.identity.inode,
                .size = ready.identity.size,
                .mtime_ns = ready.identity.mtime_ns,
                .ctime_ns = ready.identity.ctime_ns,
            });
        }
        return try dependencies.toOwnedSlice(allocator);
    }

    fn find(self: *const Builder, id: render.ResourceId) ?*const render.Resource {
        for (self.entries.items) |*entry| {
            if (std.mem.eql(u8, &entry.id, &id)) return entry;
        }
        return null;
    }

    pub fn get(self: *Builder, io: std.Io, id: render.ResourceId) ?render.Resource {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const resource = self.find(id) orelse return null;
        return resource.*;
    }

    fn lessThan(_: void, lhs: render.Resource, rhs: render.Resource) bool {
        return std.mem.order(u8, &lhs.id, &rhs.id) == .lt;
    }

    fn clearSources(self: *Builder, allocator: std.mem.Allocator) void {
        for (self.sources.items) |source| allocator.free(source.path);
        self.sources.deinit(allocator);
        self.sources = .empty;
    }

    fn findSource(self: *Builder, kind: render.ResourceKind, path: []const u8) ?*Source {
        for (self.sources.items) |*source| {
            if (source.kind == kind and std.mem.eql(u8, source.path, path)) return source;
        }
        return null;
    }
};

const Source = struct {
    kind: render.ResourceKind,
    path: []const u8,
    state: State = .loading,

    const State = union(enum) {
        loading,
        ready: struct {
            id: render.ResourceId,
            identity: FileIdentity,
        },
        failed: anyerror,
    };
};

fn statPath(io: std.Io, path: []const u8) !std.Io.File.Stat {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    return try file.stat(io);
}

fn sameFile(left: std.Io.File.Stat, right: std.Io.File.Stat) bool {
    return left.inode == right.inode and left.size == right.size and
        left.mtime.nanoseconds == right.mtime.nanoseconds and
        left.ctime.nanoseconds == right.ctime.nanoseconds;
}

fn loadStableResource(
    allocator: std.mem.Allocator,
    io: std.Io,
    kind: render.ResourceKind,
    path: []const u8,
    identity: *FileIdentity,
) !render.Resource {
    const bytes = try readStableBytes(allocator, io, path, identity);
    return try resourceFromBytes(allocator, kind, path, bytes);
}

const StableBytes = struct {
    bytes: []u8,
    identity: FileIdentity,
};

const HashedGeneration = struct {
    digest: u64,
    identity: FileIdentity,
};

fn hashFileGeneration(io: std.Io, path: []const u8) !?HashedGeneration {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const before = try file.stat(io);
    var file_buffer: [16 * 1024]u8 = undefined;
    var reader = std.Io.File.Reader.init(file, io, file_buffer[0..]);
    var chunk: [16 * 1024]u8 = undefined;
    var hasher = std.hash.Wyhash.init(0);
    var byte_count: u64 = 0;
    while (true) {
        const read_len = try reader.interface.readSliceShort(chunk[0..]);
        if (read_len == 0) break;
        hasher.update(chunk[0..read_len]);
        byte_count += read_len;
    }
    const after = try file.stat(io);
    if (!sameFile(before, after) or after.size != byte_count) return null;
    return .{ .digest = hasher.final(), .identity = FileIdentity.fromStat(after) };
}

fn readStableBytes(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    identity: *FileIdentity,
) ![]u8 {
    for (0..max_stable_read_attempts) |_| {
        const candidate = (try readFileGeneration(allocator, io, path)) orelse continue;
        const confirmed = statPath(io, path) catch |err| {
            allocator.free(candidate.bytes);
            return err;
        };
        if (!candidate.identity.matchesStat(confirmed)) {
            allocator.free(candidate.bytes);
            continue;
        }
        identity.* = candidate.identity;
        return candidate.bytes;
    }
    return error.ResourceChangedDuringRead;
}

fn readFileGeneration(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !?StableBytes {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const before = try file.stat(io);
    var file_buffer: [16 * 1024]u8 = undefined;
    var reader = std.Io.File.Reader.init(file, io, file_buffer[0..]);
    const bytes = try reader.interface.allocRemaining(allocator, .unlimited);
    errdefer allocator.free(bytes);
    const after = try file.stat(io);
    if (!sameFile(before, after) or after.size != bytes.len) {
        allocator.free(bytes);
        return null;
    }
    return .{ .bytes = bytes, .identity = FileIdentity.fromStat(after) };
}

fn resourceFromBytes(
    allocator: std.mem.Allocator,
    kind: render.ResourceKind,
    path: []const u8,
    bytes: []u8,
) !render.Resource {
    errdefer allocator.free(bytes);
    const name = try allocator.dupe(u8, std.fs.path.basename(path));
    errdefer allocator.free(name);
    var metadata = try probeMetadata(allocator, kind, bytes);
    errdefer metadata.deinit(allocator);
    return .{
        .id = render.identifyResource(kind, bytes),
        .kind = kind,
        .name = name,
        .bytes = bytes,
        .metadata = metadata,
        .identity_verified = true,
    };
}

fn probeMetadata(
    allocator: std.mem.Allocator,
    kind: render.ResourceKind,
    bytes: []const u8,
) !render.ResourceMetadata {
    return switch (kind) {
        .font => .{ .font = .{ .collection = std.mem.startsWith(u8, bytes, "ttcf") } },
        .raster => .{ .raster = try rasterMetadata(bytes) },
        .svg => .{ .svg = try svgMetadata(bytes) },
        .pdf => .{ .pdf = try pdfMetadata(allocator, bytes) },
        .math_pdf => .{ .math_pdf = try pdfMetadata(allocator, bytes) },
    };
}

fn rasterMetadata(bytes: []const u8) !render.RasterMetadata {
    var value: c.SsRasterMetadata = undefined;
    if (c.ss_raster_metadata_bytes(bytes.ptr, bytes.len, &value) != 0) return error.InvalidRasterResource;
    if (value.orientation < 1 or value.orientation > 8) return error.InvalidRasterResource;
    const orientation: render.RasterOrientation = @enumFromInt(@as(u8, @intCast(value.orientation)));
    return .{
        .pixel_width = value.pixel_width,
        .pixel_height = value.pixel_height,
        .oriented_width = value.oriented_width,
        .oriented_height = value.oriented_height,
        .orientation = orientation,
        .color_space = switch (value.color_space) {
            1 => .srgb,
            2 => .icc,
            else => .unknown,
        },
        .has_alpha = value.has_alpha != 0,
    };
}

fn svgMetadata(bytes: []const u8) !render.SvgMetadata {
    var value: c.SsSvgMetadata = undefined;
    if (c.ss_svg_metadata_bytes(bytes.ptr, bytes.len, &value) != 0) return error.InvalidSvgResource;
    const aspect = preserveAspectRatio(bytes);
    return .{
        .width = value.width,
        .height = value.height,
        .view_box = if (value.has_view_box != 0) .{
            .x = value.view_box_x,
            .y = value.view_box_y,
            .width = value.view_box_width,
            .height = value.view_box_height,
        } else null,
        .alignment = aspect.alignment,
        .scale = aspect.scale,
    };
}

fn pdfMetadata(allocator: std.mem.Allocator, bytes: []const u8) !render.PdfResourceMetadata {
    var document: c.SsPdfDocumentMetadata = undefined;
    if (c.ss_qpdf_metadata_bytes(bytes.ptr, bytes.len, &document, null, 0) != 0 or document.page_count == 0) return error.InvalidPdfResource;
    const native_pages = try allocator.alloc(c.SsPdfPageMetadata, document.page_count);
    defer allocator.free(native_pages);
    if (c.ss_qpdf_metadata_bytes(bytes.ptr, bytes.len, &document, native_pages.ptr, native_pages.len) != 0) return error.InvalidPdfResource;
    const pages = try allocator.alloc(render.PdfPageMetadata, native_pages.len);
    errdefer allocator.free(pages);
    for (native_pages, 0..) |native, index| {
        pages[index] = .{
            .media = pdfBox(native.boxes[0]),
            .crop = pdfBox(native.boxes[1]),
            .bleed = pdfBox(native.boxes[2]),
            .trim = pdfBox(native.boxes[3]),
            .art = pdfBox(native.boxes[4]),
            .user_unit = native.user_unit,
            .rotation = @intCast(native.rotation),
            .annotation_count = native.annotation_count,
            .has_unsafe_annotations = native.has_unsafe_annotations != 0,
        };
    }
    return .{
        .pages = pages,
        .encrypted = document.encrypted != 0,
        .has_javascript = document.has_javascript != 0,
    };
}

fn pdfBox(values: [4]f64) render.PdfBox {
    return .{ .left = values[0], .bottom = values[1], .right = values[2], .top = values[3] };
}

fn preserveAspectRatio(bytes: []const u8) struct { alignment: render.SvgAlign, scale: render.SvgScale } {
    const value = svgAttribute(bytes, "preserveAspectRatio") orelse return .{ .alignment = .x_mid_y_mid, .scale = .meet };
    var tokens = std.mem.tokenizeAny(u8, value, " \t\r\n");
    var first = tokens.next() orelse return .{ .alignment = .x_mid_y_mid, .scale = .meet };
    if (std.mem.eql(u8, first, "defer")) first = tokens.next() orelse return .{ .alignment = .x_mid_y_mid, .scale = .meet };
    const alignment: render.SvgAlign = if (std.mem.eql(u8, first, "none"))
        .none
    else if (std.mem.eql(u8, first, "xMinYMin"))
        .x_min_y_min
    else if (std.mem.eql(u8, first, "xMidYMin"))
        .x_mid_y_min
    else if (std.mem.eql(u8, first, "xMaxYMin"))
        .x_max_y_min
    else if (std.mem.eql(u8, first, "xMinYMid"))
        .x_min_y_mid
    else if (std.mem.eql(u8, first, "xMidYMid"))
        .x_mid_y_mid
    else if (std.mem.eql(u8, first, "xMaxYMid"))
        .x_max_y_mid
    else if (std.mem.eql(u8, first, "xMinYMax"))
        .x_min_y_max
    else if (std.mem.eql(u8, first, "xMidYMax"))
        .x_mid_y_max
    else if (std.mem.eql(u8, first, "xMaxYMax"))
        .x_max_y_max
    else
        .x_mid_y_mid;
    const scale: render.SvgScale = if (tokens.next()) |token|
        if (std.mem.eql(u8, token, "slice")) .slice else .meet
    else
        .meet;
    return .{ .alignment = alignment, .scale = scale };
}

fn svgAttribute(bytes: []const u8, name: []const u8) ?[]const u8 {
    const svg_start = std.mem.indexOf(u8, bytes, "<svg") orelse return null;
    const tag_end_relative = std.mem.indexOfScalar(u8, bytes[svg_start..], '>') orelse return null;
    const tag = bytes[svg_start .. svg_start + tag_end_relative];
    var offset: usize = 0;
    while (std.mem.indexOfPos(u8, tag, offset, name)) |start| {
        const before_valid = start == 0 or std.ascii.isWhitespace(tag[start - 1]);
        var cursor = start + name.len;
        const after_valid = cursor == tag.len or std.ascii.isWhitespace(tag[cursor]) or tag[cursor] == '=';
        if (!before_valid or !after_valid) {
            offset = cursor;
            continue;
        }
        while (cursor < tag.len and std.ascii.isWhitespace(tag[cursor])) cursor += 1;
        if (cursor >= tag.len or tag[cursor] != '=') return null;
        cursor += 1;
        while (cursor < tag.len and std.ascii.isWhitespace(tag[cursor])) cursor += 1;
        if (cursor >= tag.len or (tag[cursor] != '"' and tag[cursor] != '\'')) return null;
        const quote = tag[cursor];
        cursor += 1;
        const end = std.mem.indexOfScalarPos(u8, tag, cursor, quote) orelse return null;
        return tag[cursor..end];
    }
    return null;
}
