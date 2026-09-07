const std = @import("std");
const syntax = @import("../syntax.zig");
const names = @import("../language/names.zig");
const utils = @import("utils");

const Stamp = struct {
    size: u64,
    mtime: i96,
    ctime: i96,
    inode: std.Io.File.INode,
    kind: std.Io.File.Kind,

    fn fromStat(stat: std.Io.Dir.Stat) Stamp {
        return .{ .size = stat.size, .mtime = stat.mtime.nanoseconds, .ctime = stat.ctime.nanoseconds, .inode = stat.inode, .kind = stat.kind };
    }
};

const Entry = struct {
    stamp: Stamp,
    imports: []const []const u8,
    visited: bool = true,
};

pub const Cache = struct {
    allocator: std.mem.Allocator,
    entries: std.StringHashMap(Entry),
    parsed_modules: usize = 0,

    pub fn init(allocator: std.mem.Allocator) Cache {
        return .{ .allocator = allocator, .entries = .init(allocator) };
    }

    pub fn deinit(self: *Cache) void {
        var iterator = self.entries.iterator();
        while (iterator.next()) |entry| {
            freeImports(self.allocator, entry.value_ptr.imports);
            self.allocator.free(entry.key_ptr.*);
        }
        self.entries.deinit();
    }

    pub fn beginInspection(self: *Cache) void {
        var entries = self.entries.valueIterator();
        while (entries.next()) |entry| entry.visited = false;
    }

    pub fn finishInspection(self: *Cache) void {
        var iterator = self.entries.iterator();
        while (iterator.next()) |entry| {
            if (entry.value_ptr.visited) continue;
            const path = entry.key_ptr.*;
            const imports = entry.value_ptr.imports;
            _ = self.entries.remove(path);
            freeImports(self.allocator, imports);
            self.allocator.free(path);
        }
    }

    pub fn read(
        self: *Cache,
        io: std.Io,
        scratch: std.mem.Allocator,
        path: []const u8,
        stat: std.Io.Dir.Stat,
    ) ![]const []const u8 {
        const stamp = Stamp.fromStat(stat);
        if (self.entries.getPtr(path)) |entry| {
            entry.visited = true;
            if (std.meta.eql(entry.stamp, stamp)) return entry.imports;
        }
        const source = try utils.fs.readFileAlloc(io, scratch, path);
        defer scratch.free(source);
        self.parsed_modules += 1;
        const new_imports = try self.parseImports(scratch, path, source);
        errdefer if (new_imports) |imports| freeImports(self.allocator, imports);
        if (self.entries.getPtr(path)) |entry| {
            entry.stamp = stamp;
            if (new_imports) |imports| {
                freeImports(self.allocator, entry.imports);
                entry.imports = imports;
            }
            return entry.imports;
        }
        const owned_path = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned_path);
        const imports = new_imports orelse &.{};
        try self.entries.put(owned_path, .{ .stamp = stamp, .imports = imports });
        return imports;
    }

    fn parseImports(self: *Cache, scratch: std.mem.Allocator, path: []const u8, source: []const u8) !?[]const []const u8 {
        var program = syntax.parseWithSourceName(scratch, source, path) catch |err| {
            if (err == error.OutOfMemory) return err;
            // Retain the last known edges while a source file is incomplete.
            return null;
        };
        defer program.deinit(scratch);
        var imports = std.ArrayList([]const u8).empty;
        errdefer {
            for (imports.items) |import| self.allocator.free(import);
            imports.deinit(self.allocator);
        }
        for (program.imports.items) |declaration| {
            if (std.mem.startsWith(u8, declaration.spec, "std:")) continue;
            const relative = try names.importPathWithDefaultExtension(scratch, declaration.spec);
            defer scratch.free(relative);
            const resolved = try std.fs.path.resolve(self.allocator, &.{ std.fs.path.dirname(path) orelse ".", relative });
            errdefer self.allocator.free(resolved);
            try imports.append(self.allocator, resolved);
        }
        return try imports.toOwnedSlice(self.allocator);
    }
};

fn freeImports(allocator: std.mem.Allocator, imports: []const []const u8) void {
    for (imports) |path| allocator.free(path);
    allocator.free(imports);
}
