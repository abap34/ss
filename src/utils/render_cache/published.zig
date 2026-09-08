const std = @import("std");
const fs = @import("../fs.zig");
const guard = @import("guard.zig");

pub const directory = guard.path ++ "/leases";
const read_limit = 16 * 1024 * 1024;
var counter: usize = 0;

const Manifest = struct {
    version: u32 = 1,
    paths: []const []const u8,
};

/// Keeps immutable resources alive independently of an analysis generation.
/// Closing the last owner releases the OS lock, including after a process exits.
pub const Lease = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    references: std.atomic.Value(usize) = .init(1),
    file: std.Io.File,
    manifest_path: []u8,

    pub fn create(allocator: std.mem.Allocator, io: std.Io, paths: []const []const u8) !?*Lease {
        if (paths.len == 0) return null;
        for (paths) |path| if (!validPath(path)) return error.InvalidPublishedResourcePath;
        const contents = try std.json.Stringify.valueAlloc(allocator, Manifest{ .paths = paths }, .{});
        defer allocator.free(contents);
        if (contents.len >= read_limit) return error.PublishedResourceManifestTooLarge;
        const cache_guard = try guard.open(io, .shared, false);
        defer cache_guard.close(io);
        const cwd = std.Io.Dir.cwd();
        try cwd.createDirPath(io, directory);
        const serial = @atomicRmw(usize, &counter, .Add, 1, .monotonic);
        const manifest_path = try std.fmt.allocPrint(allocator, directory ++ "/published-{d}-{d}-{d}.json", .{
            std.c.getpid(), std.Io.Timestamp.now(io, .real).nanoseconds, serial,
        });
        errdefer allocator.free(manifest_path);
        const lease = try allocator.create(Lease);
        errdefer allocator.destroy(lease);
        const file = try cwd.createFile(io, manifest_path, .{ .read = true, .exclusive = true, .lock = .shared });
        errdefer {
            cwd.deleteFile(io, manifest_path) catch {};
            file.close(io);
        }
        try file.writeStreamingAll(io, contents);
        lease.* = .{ .allocator = allocator, .io = io, .file = file, .manifest_path = manifest_path };
        return lease;
    }

    pub fn retain(self: *Lease) *Lease {
        const previous = self.references.fetchAdd(1, .monotonic);
        std.debug.assert(previous != 0 and previous != std.math.maxInt(usize));
        return self;
    }

    pub fn deinit(self: *Lease) void {
        if (self.references.fetchSub(1, .acq_rel) != 1) return;
        std.Io.Dir.cwd().deleteFile(self.io, self.manifest_path) catch {};
        self.file.close(self.io);
        const allocator = self.allocator;
        allocator.free(self.manifest_path);
        allocator.destroy(self);
    }
};

pub const Protection = struct {
    paths: std.StringHashMap(void),
    active: bool = false,

    pub fn deinit(self: *Protection) void {
        var keys = self.paths.keyIterator();
        while (keys.next()) |key| self.paths.allocator.free(key.*);
        self.paths.deinit();
    }
};

/// Called under the exclusive cache guard. New manifests cannot appear here.
pub fn collect(io: std.Io, allocator: std.mem.Allocator) !Protection {
    var protection = Protection{ .paths = std.StringHashMap(void).init(allocator) };
    errdefer protection.deinit();
    var collector = Collector{ .io = io, .allocator = allocator, .protection = &protection };
    _ = try fs.walkFiles(io, allocator, directory, &collector);
    return protection;
}

const Collector = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    protection: *Protection,

    pub fn visit(self: *Collector, relative_path: []const u8, stat: std.Io.File.Stat) !void {
        if (stat.kind != .file) return;
        const path = try std.fs.path.join(self.allocator, &.{ directory, relative_path });
        defer self.allocator.free(path);
        const file = std.Io.Dir.cwd().openFile(self.io, path, .{ .mode = .read_write }) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer file.close(self.io);
        if (try file.tryLock(self.io, .exclusive)) {
            std.Io.Dir.cwd().deleteFile(self.io, path) catch |err| switch (err) {
                error.FileNotFound => {},
                else => return err,
            };
            return;
        }
        self.protection.active = true;
        const contents = fs.readFileAllocLimited(self.io, self.allocator, path, .limited(read_limit)) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer self.allocator.free(contents);
        const parsed = try std.json.parseFromSlice(Manifest, self.allocator, contents, .{});
        defer parsed.deinit();
        if (parsed.value.version != 1) return error.InvalidPublishedResourceManifest;
        for (parsed.value.paths) |resource_path| {
            if (!validPath(resource_path)) return error.InvalidPublishedResourcePath;
            if (self.protection.paths.contains(resource_path)) continue;
            const owned = try self.allocator.dupe(u8, resource_path);
            errdefer self.allocator.free(owned);
            try self.protection.paths.putNoClobber(owned, {});
        }
    }
};

fn validPath(path: []const u8) bool {
    if (path.len == 0 or std.fs.path.isAbsolute(path)) return false;
    var components = std.mem.splitAny(u8, path, "/\\");
    while (components.next()) |component| {
        if (component.len == 0 or std.mem.eql(u8, component, "..") or std.mem.eql(u8, component, ".")) return false;
    }
    return true;
}
