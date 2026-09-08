const std = @import("std");

pub const Kind = enum { file, directory };
pub const Input = struct {
    path: []const u8,
    kind: Kind,
    observation: ?u64 = null,
};

// Evaluation and page preparation record inputs before parallel rendering starts.
pub const FileInputs = struct {
    pub const Observer = struct {
        context: *anyopaque,
        capture: *const fn (*anyopaque, []const u8, Kind) anyerror!u64,
    };

    observer: ?Observer = null,
    observations_complete: bool = true,
    allocator: std.mem.Allocator,
    paths: std.StringHashMap(Kind),
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
        const resolved = try std.fs.path.resolve(self.allocator, &.{ base, path });
        errdefer self.allocator.free(resolved);
        if (self.paths.contains(resolved)) {
            self.allocator.free(resolved);
            return;
        }
        const observation = if (self.observer) |observer| try observer.capture(observer.context, resolved, kind) else null;
        try self.ordered.ensureUnusedCapacity(self.allocator, 1);
        try self.paths.put(resolved, kind);
        self.ordered.appendAssumeCapacity(.{ .path = resolved, .kind = kind, .observation = observation });
        self.sorted = false;
    }

    pub fn items(self: *FileInputs) []const Input {
        if (!self.sorted) {
            std.sort.heap(Input, self.ordered.items, {}, lessThan);
            self.sorted = true;
        }
        return self.ordered.items;
    }

    fn lessThan(_: void, lhs: Input, rhs: Input) bool {
        return std.mem.lessThan(u8, lhs.path, rhs.path);
    }
};
