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
    identity: FileIdentity,
    digest: u64,
    previous: ?usize = null,
    next: ?usize = null,
};

const SourceKey = struct {
    kind: ?render.ResourceKind,
    path: []const u8,
};

const SourceKeyContext = struct {
    pub fn hash(_: SourceKeyContext, key: SourceKey) u64 {
        var hasher = std.hash.Wyhash.init(if (key.kind) |kind| @intFromEnum(kind) + 1 else 0);
        hasher.update(key.path);
        return hasher.final();
    }

    pub fn eql(_: SourceKeyContext, a: SourceKey, b: SourceKey) bool {
        return a.kind == b.kind and std.mem.eql(u8, a.path, b.path);
    }
};

pub const SourceCache = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    ready: std.Io.Condition = .init,
    in_flight: std.HashMapUnmanaged(SourceKey, void, SourceKeyContext, std.hash_map.default_max_load_percentage) = .{},
    sources: std.ArrayList(CachedSource) = .empty,
    source_indexes: std.HashMapUnmanaged(SourceKey, usize, SourceKeyContext, std.hash_map.default_max_load_percentage) = .{},
    fingerprints: std.ArrayList(CachedFingerprint) = .empty,
    fingerprint_indexes: std.StringHashMapUnmanaged(usize) = .{},
    oldest_fingerprint: ?usize = null,
    newest_fingerprint: ?usize = null,
    source_bytes: usize = 0,
    access_clock: u64 = 0,

    const max_sources = 256;
    const max_source_bytes = 512 * 1024 * 1024;
    const max_fingerprints = 4096;

    // Concurrent callers must provide an allocator supporting concurrent use.
    pub fn init(allocator: std.mem.Allocator, io: std.Io) SourceCache {
        return .{ .allocator = allocator, .io = io };
    }

    pub fn deinit(self: *SourceCache) void {
        std.debug.assert(self.in_flight.count() == 0);
        self.in_flight.deinit(self.allocator);
        self.source_indexes.deinit(self.allocator);
        for (self.sources.items) |*source| source.deinit(self.allocator);
        self.sources.deinit(self.allocator);
        self.fingerprint_indexes.deinit(self.allocator);
        for (self.fingerprints.items) |fingerprint| self.allocator.free(fingerprint.path);
        self.fingerprints.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn fileFingerprint(self: *SourceCache, path: []const u8) !FileFingerprint {
        const key = SourceKey{ .kind = null, .path = path };
        try self.claim(key);
        defer self.release(key);
        for (0..max_stable_read_attempts) |_| {
            const stat = statPath(self.io, path) catch |err| switch (err) {
                error.FileNotFound => return .{ .present = false, .digest = 0 },
                else => return err,
            };
            {
                self.mutex.lockUncancelable(self.io);
                defer self.mutex.unlock(self.io);
                if (self.fingerprint_indexes.get(path)) |index| {
                    const fingerprint = self.fingerprints.items[index];
                    if (fingerprint.identity.matchesStat(stat)) {
                        self.touchFingerprint(index);
                        return .{ .present = true, .digest = fingerprint.digest };
                    }
                }
            }

            const hashed = (try hashFileGeneration(self.io, path)) orelse continue;
            const confirmed = statPath(self.io, path) catch |err| switch (err) {
                error.FileNotFound => continue,
                else => return err,
            };
            if (!hashed.identity.matchesStat(confirmed)) continue;
            try self.publishFingerprint(path, hashed);
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
        const key = SourceKey{ .kind = kind, .path = path };
        try self.claim(key);
        defer self.release(key);
        const stat = try statPath(self.io, path);
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            if (self.source_indexes.get(key)) |index| {
                const source = &self.sources.items[index];
                if (source.identity().matchesStat(stat)) {
                    source.last_used = self.nextAccess();
                    identity.* = source.identity();
                    return try source.cloneResource(allocator);
                }
            }
        }

        var replacement = try self.loadSource(kind, path);
        var replacement_owned = true;
        defer if (replacement_owned) replacement.deinit(self.allocator);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const existing_index = self.source_indexes.get(key);
        if (replacement.byte_size > max_source_bytes) {
            identity.* = replacement.identity();
            const result = try replacement.cloneResource(allocator);
            if (existing_index) |index| self.removeSource(index);
            return result;
        }
        replacement.last_used = self.nextAccess();
        const replacement_index = existing_index orelse self.sources.items.len;
        if (existing_index) |index| {
            const source = &self.sources.items[index];
            _ = self.source_indexes.remove(key);
            self.source_bytes -= source.byte_size;
            source.deinit(self.allocator);
            source.* = replacement;
        } else {
            try self.source_indexes.ensureUnusedCapacity(self.allocator, 1);
            try self.sources.ensureUnusedCapacity(self.allocator, 1);
            self.sources.appendAssumeCapacity(replacement);
        }
        self.source_indexes.putAssumeCapacity(.{ .kind = kind, .path = replacement.path }, replacement_index);
        replacement_owned = false;
        self.source_bytes += replacement.byte_size;
        identity.* = replacement.identity();
        const result = try replacement.cloneResource(allocator);
        self.trimSources();
        return result;
    }

    fn loadSource(self: *SourceCache, kind: render.ResourceKind, path: []const u8) !CachedSource {
        for (0..max_stable_read_attempts) |_| {
            var identity: FileIdentity = undefined;
            var value = try loadStableResource(self.allocator, self.io, kind, path, &identity);
            var value_owned = true;
            defer if (value_owned) value.deinit(self.allocator);
            // Decoding can outlast the stable byte read. Confirm the path again
            // before publishing while same-key callers remain behind this load.
            const confirmed = try statPath(self.io, path);
            if (!identity.matchesStat(confirmed)) continue;
            try value.share(self.allocator);
            const owned_path = try self.allocator.dupe(u8, path);
            value_owned = false;
            return .{
                .path = owned_path,
                .inode = identity.inode,
                .size = identity.size,
                .mtime_ns = identity.mtime_ns,
                .ctime_ns = identity.ctime_ns,
                .resource = value,
                .byte_size = @sizeOf(CachedSource) +| owned_path.len +| value.retainedByteSize(),
            };
        }
        return error.ResourceChangedDuringRead;
    }

    fn claim(self: *SourceCache, key: SourceKey) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        while (self.in_flight.contains(key)) try self.ready.wait(self.io, &self.mutex);
        // The caller retains the borrowed path until release, including errors.
        try self.in_flight.put(self.allocator, key, {});
    }

    fn release(self: *SourceCache, key: SourceKey) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const removed = self.in_flight.remove(key);
        std.debug.assert(removed);
        self.ready.broadcast(self.io);
    }

    fn publishFingerprint(self: *SourceCache, path: []const u8, hashed: HashedGeneration) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.fingerprint_indexes.get(path)) |index| {
            self.fingerprints.items[index].identity = hashed.identity;
            self.fingerprints.items[index].digest = hashed.digest;
            self.touchFingerprint(index);
            return;
        }
        const owned_path = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned_path);
        try self.fingerprint_indexes.ensureUnusedCapacity(self.allocator, 1);
        if (self.fingerprints.items.len < max_fingerprints) try self.fingerprints.ensureUnusedCapacity(self.allocator, 1);
        const replacement = CachedFingerprint{ .path = owned_path, .identity = hashed.identity, .digest = hashed.digest };
        const index = if (self.fingerprints.items.len == max_fingerprints) blk: {
            const oldest = self.oldest_fingerprint.?;
            self.unlinkFingerprint(oldest);
            const removed = &self.fingerprints.items[oldest];
            _ = self.fingerprint_indexes.remove(removed.path);
            self.allocator.free(removed.path);
            removed.* = replacement;
            break :blk oldest;
        } else blk: {
            const added = self.fingerprints.items.len;
            self.fingerprints.appendAssumeCapacity(replacement);
            break :blk added;
        };
        self.fingerprint_indexes.putAssumeCapacity(owned_path, index);
        self.appendFingerprint(index);
    }

    fn touchFingerprint(self: *SourceCache, index: usize) void {
        if (self.newest_fingerprint == index) return;
        self.unlinkFingerprint(index);
        self.appendFingerprint(index);
    }

    fn unlinkFingerprint(self: *SourceCache, index: usize) void {
        const entry = &self.fingerprints.items[index];
        if (entry.previous) |previous| self.fingerprints.items[previous].next = entry.next else self.oldest_fingerprint = entry.next;
        if (entry.next) |next| self.fingerprints.items[next].previous = entry.previous else self.newest_fingerprint = entry.previous;
    }

    fn appendFingerprint(self: *SourceCache, index: usize) void {
        const entry = &self.fingerprints.items[index];
        entry.previous = self.newest_fingerprint;
        entry.next = null;
        if (self.newest_fingerprint) |previous| self.fingerprints.items[previous].next = index else self.oldest_fingerprint = index;
        self.newest_fingerprint = index;
    }

    fn nextAccess(self: *SourceCache) u64 {
        self.access_clock +%= 1;
        if (self.access_clock == 0) self.access_clock = 1;
        return self.access_clock;
    }

    fn removeSource(self: *SourceCache, index: usize) void {
        var removed = self.sources.swapRemove(index);
        _ = self.source_indexes.remove(.{ .kind = removed.resource.kind, .path = removed.path });
        if (index < self.sources.items.len) {
            const moved = self.sources.items[index];
            self.source_indexes.getPtr(.{ .kind = moved.resource.kind, .path = moved.path }).?.* = index;
        }
        self.source_bytes -= removed.byte_size;
        removed.deinit(self.allocator);
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
            self.removeSource(oldest_index);
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
        .latex_pdf => .{ .latex_pdf = try pdfMetadata(allocator, bytes) },
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
