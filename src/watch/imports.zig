const std = @import("std");
const syntax = @import("../syntax.zig");
const names = @import("../language/names.zig");
const utils = @import("utils");
const packages = @import("project").packages;

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

const ObservedFile = struct { path: []const u8, fingerprint: u64 };

const Entry = struct {
    configuration: ?[]const u8 = null,
    observed: []const ObservedFile = &.{},
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
            freeEntry(self.allocator, entry.value_ptr.*);
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
            const cached = entry.value_ptr.*;
            _ = self.entries.remove(path);
            freeEntry(self.allocator, cached);
            self.allocator.free(path);
        }
    }

    pub fn read(
        self: *Cache,
        io: std.Io,
        scratch: std.mem.Allocator,
        path: []const u8,
        stat: std.Io.Dir.Stat,
        project_file: ?[]const u8,
    ) ![]const []const u8 {
        const stamp = Stamp.fromStat(stat);
        if (self.entries.getPtr(path)) |entry| {
            entry.visited = true;
            if (std.meta.eql(entry.stamp, stamp) and optionalPathEql(entry.configuration, project_file) and try observationsMatch(io, entry.observed)) return entry.imports;
        }
        const source = try utils.fs.readFileAlloc(io, scratch, path);
        defer scratch.free(source);
        self.parsed_modules += 1;
        var inputs = utils.FileInputs.init(scratch);
        defer inputs.deinit();
        var input_io = io;
        inputs.observer = .{ .context = &input_io, .capture = observeFile };
        const new_imports = try self.parseImports(io, scratch, path, source, &inputs, project_file);
        errdefer if (new_imports) |imports| freeImports(self.allocator, imports);
        const observed = try cloneObservations(self.allocator, inputs.items());
        errdefer freeObservations(self.allocator, observed);
        const configuration = if (project_file) |file| try self.allocator.dupe(u8, file) else null;
        errdefer if (configuration) |file| self.allocator.free(file);
        if (self.entries.getPtr(path)) |entry| {
            entry.stamp = stamp;
            if (new_imports) |imports| {
                freeEntry(self.allocator, entry.*);
                entry.imports = imports;
                entry.observed = observed;
                entry.configuration = configuration;
            } else {
                freeObservations(self.allocator, observed);
                if (configuration) |file| self.allocator.free(file);
            }
            return entry.imports;
        }
        const owned_path = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned_path);
        const imports = new_imports orelse &.{};
        try self.entries.put(owned_path, .{ .stamp = stamp, .imports = imports, .observed = observed, .configuration = configuration });
        return imports;
    }

    fn parseImports(self: *Cache, io: std.Io, scratch: std.mem.Allocator, path: []const u8, source: []const u8, inputs: *utils.FileInputs, project_file: ?[]const u8) !?[]const []const u8 {
        var program = syntax.parseSurface(scratch, source) catch |err| {
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
            if (std.mem.startsWith(u8, declaration.spec, "pkg:")) {
                var resolver = packages.resolve.Resolver.init(scratch, io, std.fs.path.dirname(path) orelse ".", inputs);
                defer resolver.deinit();
                resolver.config_path = project_file;
                const package_path = resolver.resolve(std.fs.path.dirname(path) orelse ".", declaration.spec) catch |err| {
                    if (err == error.OutOfMemory or err == error.Canceled) return err;
                    continue;
                };
                const resolved = try self.allocator.dupe(u8, package_path);
                errdefer self.allocator.free(resolved);
                try imports.append(self.allocator, resolved);
                continue;
            }
            const relative = try names.importPathWithDefaultExtension(scratch, declaration.spec);
            defer scratch.free(relative);
            const resolved = try std.fs.path.resolve(self.allocator, &.{ std.fs.path.dirname(path) orelse ".", relative });
            errdefer self.allocator.free(resolved);
            try imports.append(self.allocator, resolved);
        }
        for (program.includes.items) |declaration| {
            const resolved = try std.fs.path.resolve(self.allocator, &.{ std.fs.path.dirname(path) orelse ".", declaration.path });
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

fn optionalPathEql(a: ?[]const u8, b: ?[]const u8) bool {
    return if (a) |value| if (b) |other| std.mem.eql(u8, value, other) else false else b == null;
}

fn observeFile(context: *anyopaque, path: []const u8, _: utils.file_inputs.Kind) !u64 {
    const io: *std.Io = @ptrCast(@alignCast(context));
    return fileFingerprint(io.*, path);
}

fn fileFingerprint(io: std.Io, path: []const u8) !u64 {
    const stamp = utils.fs.statFile(io, path) catch |err| switch (err) {
        error.FileNotFound => return 0,
        else => return err,
    };
    var hash = std.hash.Wyhash.init(1);
    std.hash.autoHash(&hash, Stamp.fromStat(stamp));
    return hash.final();
}

fn observationsMatch(io: std.Io, observed: []const ObservedFile) !bool {
    for (observed) |file| if (try fileFingerprint(io, file.path) != file.fingerprint) return false;
    return true;
}

fn cloneObservations(a: std.mem.Allocator, inputs: []const utils.file_inputs.Input) ![]const ObservedFile {
    var result = std.ArrayList(ObservedFile).empty;
    errdefer {
        for (result.items) |file| a.free(file.path);
        result.deinit(a);
    }
    for (inputs) |input| {
        const path = try a.dupe(u8, input.path);
        errdefer a.free(path);
        try result.append(a, .{ .path = path, .fingerprint = input.observation.? });
    }
    return result.toOwnedSlice(a);
}

fn freeObservations(a: std.mem.Allocator, observed: []const ObservedFile) void {
    for (observed) |file| a.free(file.path);
    a.free(observed);
}

fn freeEntry(a: std.mem.Allocator, entry: Entry) void {
    freeImports(a, entry.imports);
    freeObservations(a, entry.observed);
    if (entry.configuration) |path| a.free(path);
}
