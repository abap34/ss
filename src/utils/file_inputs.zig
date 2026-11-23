const std = @import("std");

pub const Kind = enum { file, directory };
pub const Input = struct {
    path: []const u8,
    kind: Kind,
    observation: ?u64 = null,
};

// Readers retain the first observation of each file used by an operation.
pub const FileInputs = struct {
    pub const Observer = struct {
        context: *anyopaque,
        capture: *const fn (*anyopaque, []const u8, Kind) anyerror!u64,
        contents: ?*const fn (*anyopaque, []const u8) u64 = null,
    };

    observer: ?Observer = null,
    observations_complete: bool = true,
    allocator: std.mem.Allocator,
    paths: std.StringHashMap(usize),
    ordered: std.ArrayList(Input) = .empty,
    sorted: bool = true,

    pub fn init(allocator: std.mem.Allocator) FileInputs {
        return .{ .allocator = allocator, .paths = .init(allocator) };
    }

    pub fn deinit(self: *FileInputs) void {
        self.clear();
        self.paths.deinit();
        self.ordered.deinit(self.allocator);
    }

    pub fn clear(self: *FileInputs) void {
        var keys = self.paths.keyIterator();
        while (keys.next()) |key| self.allocator.free(key.*);
        self.paths.clearRetainingCapacity();
        self.ordered.clearRetainingCapacity();
        self.sorted = true;
        self.observations_complete = true;
    }

    pub fn record(self: *FileInputs, base: []const u8, path: []const u8, kind: Kind) !void {
        if (std.fs.path.isAbsolute(path) and self.paths.contains(path)) return;
        const resolved = try std.fs.path.resolve(self.allocator, &.{ base, path });
        errdefer self.allocator.free(resolved);
        if (self.paths.contains(resolved)) {
            self.allocator.free(resolved);
            return;
        }
        const observation = if (self.observer) |observer| try observer.capture(observer.context, resolved, kind) else null;
        try self.ordered.ensureUnusedCapacity(self.allocator, 1);
        try self.paths.put(resolved, self.ordered.items.len);
        self.ordered.appendAssumeCapacity(.{ .path = resolved, .kind = kind, .observation = observation });
        self.sorted = false;
    }

    /// Validate the observation against the bytes actually consumed by a reader.
    pub fn recordContents(self: *FileInputs, path: []const u8, bytes: []const u8) !void {
        try self.record(".", path, .file);
        const observer = self.observer orelse return;
        const contents = observer.contents orelse return;
        const index = self.paths.get(path) orelse blk: {
            const resolved = try std.fs.path.resolve(self.allocator, &.{ ".", path });
            defer self.allocator.free(resolved);
            break :blk self.paths.get(resolved).?;
        };
        const expected = contents(observer.context, bytes);
        if (self.ordered.items[index].observation != expected) self.observations_complete = false;
    }

    /// Discard inputs appended since `length`, before the next call to items().
    pub fn truncate(self: *FileInputs, length: usize) void {
        for (self.ordered.items[length..]) |input| {
            const removed = self.paths.remove(input.path);
            std.debug.assert(removed);
            self.allocator.free(input.path);
        }
        self.ordered.shrinkRetainingCapacity(length);
    }

    pub fn items(self: *FileInputs) []const Input {
        if (!self.sorted) {
            std.sort.heap(Input, self.ordered.items, {}, lessThan);
            for (self.ordered.items, 0..) |input, i| self.paths.getPtr(input.path).?.* = i;
            self.sorted = true;
        }
        return self.ordered.items;
    }

    fn lessThan(_: void, lhs: Input, rhs: Input) bool {
        return std.mem.lessThan(u8, lhs.path, rhs.path);
    }
};
