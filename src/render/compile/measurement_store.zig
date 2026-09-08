const std = @import("std");
const core = @import("core");
const utils = @import("utils");
const record = @import("measurement_record.zig");
pub const version = "ss-native-layout-measure-v21";

const format = "ss-layout-measurements-v2";
const read_limit = 16 * 1024 * 1024;
pub const capacity = 4096;

/// Owns measurement records independently of a renderer or a page-solving invocation.
pub const Store = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    mutex: std.Io.Mutex = .init,
    persistent: std.AutoHashMap(u64, core.LayoutMeasurement),
    run: std.AutoHashMap(u64, Entry),
    oldest: ?u64 = null,
    newest: ?u64 = null,
    dirty: bool = false,

    const Entry = struct {
        value: core.LayoutMeasurement,
        previous: ?u64 = null,
        next: ?u64 = null,
    };

    pub fn init(allocator: std.mem.Allocator, io: std.Io, directory: []const u8) !Store {
        const path = try std.fs.path.join(allocator, &.{ directory, "measurements.tsv" });
        errdefer allocator.free(path);
        var self = Store{
            .allocator = allocator,
            .io = io,
            .path = path,
            .persistent = std.AutoHashMap(u64, core.LayoutMeasurement).init(allocator),
            .run = std.AutoHashMap(u64, Entry).init(allocator),
        };
        errdefer self.persistent.deinit();
        try self.read();
        return self;
    }

    pub fn deinit(self: *Store) void {
        self.persistent.deinit();
        self.run.deinit();
        self.allocator.free(self.path);
        self.* = undefined;
    }

    pub fn get(self: *Store, key: u64) !?core.LayoutMeasurement {
        const lock_start = utils.measure_profile.start();
        self.mutex.lockUncancelable(self.io);
        utils.measure_profile.recordLayoutMeasurementLockWait(lock_start);
        defer self.mutex.unlock(self.io);
        const memory_start = utils.measure_profile.start();
        if (self.run.get(key)) |value| {
            utils.measure_profile.recordLayoutMeasurementCache(.memory_hit, memory_start);
            self.touch(key);
            return value.value;
        }
        const file_start = utils.measure_profile.start();
        if (self.persistent.get(key)) |value| {
            utils.measure_profile.recordLayoutMeasurementCache(.file_hit, file_start);
            try self.insert(key, value);
            return value;
        }
        utils.measure_profile.recordLayoutMeasurementCache(.file_miss, file_start);
        return null;
    }

    pub fn put(self: *Store, key: u64, value: core.LayoutMeasurement) !void {
        const lock_start = utils.measure_profile.start();
        self.mutex.lockUncancelable(self.io);
        utils.measure_profile.recordLayoutMeasurementLockWait(lock_start);
        defer self.mutex.unlock(self.io);
        var normalized = value;
        normalized.cache_key = key;
        try self.insert(key, normalized);
        if (self.persistent.getPtr(key)) |persisted| persisted.* = normalized;
        self.dirty = true;
    }

    pub fn clearMemory(self: *Store) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.run.clearRetainingCapacity();
        self.oldest = null;
        self.newest = null;
    }

    fn touch(self: *Store, key: u64) void {
        if (self.newest == key) return;
        const entry = self.run.get(key).?;
        if (entry.previous) |previous| self.run.getPtr(previous).?.next = entry.next else self.oldest = entry.next;
        if (entry.next) |next| self.run.getPtr(next).?.previous = entry.previous;
        if (self.newest) |newest| self.run.getPtr(newest).?.next = key;
        const touched = self.run.getPtr(key).?;
        touched.previous = self.newest;
        touched.next = null;
        self.newest = key;
    }

    fn insert(self: *Store, key: u64, value: core.LayoutMeasurement) !void {
        if (self.run.getPtr(key)) |entry| {
            entry.value = value;
            self.touch(key);
            return;
        }
        if (self.run.count() == capacity) {
            const evicted = self.oldest.?;
            self.oldest = self.run.get(evicted).?.next;
            if (self.oldest) |oldest| self.run.getPtr(oldest).?.previous = null else self.newest = null;
            _ = self.run.remove(evicted);
        }
        try self.run.put(key, .{ .value = value, .previous = self.newest });
        if (self.newest) |newest| self.run.getPtr(newest).?.next = key else self.oldest = key;
        self.newest = key;
    }

    /// Called after all page workers have joined.
    pub fn flush(self: *Store) !void {
        if (!self.dirty or self.run.count() == 0) return;
        const write_start = utils.measure_profile.start();
        defer utils.measure_profile.recordLayoutMeasurementCache(.write, write_start);
        var output = std.ArrayList(u8).empty;
        defer output.deinit(self.allocator);
        try output.print(self.allocator, "{s}\t{s}\n", .{ format, version });
        var iterator = self.run.iterator();
        while (iterator.next()) |entry| {
            if (!entry.value_ptr.value.isValid()) continue;
            try record.append(self.allocator, &output, entry.key_ptr.*, entry.value_ptr.value);
        }
        try utils.fs.writeFile(self.io, self.path, output.items);
        self.dirty = false;
    }

    fn read(self: *Store) !void {
        const text = utils.fs.readFileAllocLimited(self.io, self.allocator, self.path, .limited(read_limit)) catch |err| switch (err) {
            error.Canceled, error.OutOfMemory => return err,
            else => return,
        };
        defer self.allocator.free(text);
        var lines = std.mem.splitScalar(u8, text, '\n');
        var header = std.mem.tokenizeAny(u8, lines.next() orelse return, " \t\r");
        if (!std.mem.eql(u8, header.next() orelse return, format)) return;
        if (!std.mem.eql(u8, header.next() orelse return, version) or header.next() != null) return;
        while (lines.next()) |raw| {
            if (self.persistent.count() == capacity) break;
            const value = record.parse(std.mem.trim(u8, raw, " \t\r")) orelse continue;
            try self.persistent.put(value.cache_key.?, value);
        }
    }
};
