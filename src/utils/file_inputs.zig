const std = @import("std");

pub const Kind = enum { file, directory };
pub const Input = struct { path: []const u8, kind: Kind };

// Evaluation and page preparation record inputs before parallel rendering starts.
pub const FileInputs = struct {
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
    }

    pub fn record(self: *FileInputs, base: []const u8, path: []const u8, kind: Kind) !void {
        const resolved = try std.fs.path.resolve(self.allocator, &.{ base, path });
        errdefer self.allocator.free(resolved);
        if (self.paths.contains(resolved)) {
            self.allocator.free(resolved);
            return;
        }
        try self.ordered.ensureUnusedCapacity(self.allocator, 1);
        try self.paths.put(resolved, kind);
        self.ordered.appendAssumeCapacity(.{ .path = resolved, .kind = kind });
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
