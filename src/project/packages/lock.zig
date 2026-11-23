const std = @import("std");
const utils = @import("utils");
const manifest = @import("manifest.zig");

pub const max_packages = 1024;
const max_file_bytes = 8 * 1024 * 1024;

pub const Edge = struct { name: []const u8, source: manifest.Source, package: []const u8 };
pub const Package = struct { name: []const u8, id: []const u8, git: []const u8, commit: []const u8, entry: []const u8, dependencies: []const Edge };
pub const Data = struct { version: u32 = 1, dependencies: []const Edge = &.{}, packages: []const Package = &.{} };
pub const File = std.json.Parsed(Data);

pub fn read(a: std.mem.Allocator, io: std.Io, root: []const u8) !File {
    return readWithInputs(a, io, root, null);
}

pub fn readWithInputs(a: std.mem.Allocator, io: std.Io, root: []const u8, inputs: ?*utils.FileInputs) !File {
    const path = try std.fs.path.join(a, &.{ root, "ss.lock" });
    defer a.free(path);
    if (inputs) |observed| try observed.record(".", path, .file);
    const bytes = utils.fs.readFileAllocLimited(io, a, path, .limited(max_file_bytes)) catch |err| switch (err) {
        error.FileNotFound => return error.MissingPackageLock,
        error.StreamTooLong => return error.InvalidPackageLock,
        else => return err,
    };
    defer a.free(bytes);
    if (inputs) |observed| try observed.recordContents(path, bytes);
    var parsed = std.json.parseFromSlice(Data, a, bytes, .{ .allocate = .alloc_always }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.InvalidPackageLock,
    };
    errdefer parsed.deinit();
    try validate(a, parsed.value);
    return parsed;
}

// Both fetching and read-only imports use the same identity and selection checks.
pub const Index = struct {
    packages: std.StringHashMap(usize),
    sources: manifest.SourceMap(usize),

    pub fn init(a: std.mem.Allocator, data: Data) !Index {
        var self = Index{ .packages = .init(a), .sources = .init(a) };
        errdefer self.deinit();
        if (data.version != 1 or data.packages.len > max_packages) return error.InvalidPackageLock;
        for (data.packages, 0..) |package, i| {
            if (!manifest.validName(package.name) or (!hexId(package.commit, 40) and !hexId(package.commit, 64))) return error.InvalidPackageLock;
            var buffer: [64]u8 = undefined;
            const expected = identity(package.git, package.commit, &buffer);
            if (!std.mem.eql(u8, expected, package.id) or !manifest.validRelativePath(package.entry) or !std.mem.endsWith(u8, package.entry, ".ss")) return error.InvalidPackageLock;
            const result = try self.packages.getOrPut(package.id);
            if (result.found_existing) return error.InvalidPackageLock;
            result.value_ptr.* = i;
        }
        try self.edges(data, data.dependencies);
        for (data.packages) |package| try self.edges(data, package.dependencies);
        return self;
    }

    pub fn deinit(self: *Index) void {
        self.packages.deinit();
        self.sources.deinit();
    }

    fn edges(self: *Index, data: Data, values: []const Edge) !void {
        var names = std.StringHashMap(void).init(self.packages.allocator);
        defer names.deinit();
        for (values) |edge| {
            if (!manifest.validName(edge.name)) return error.InvalidPackageLock;
            manifest.validateSource(edge.source) catch return error.InvalidPackageLock;
            const i = self.packages.get(edge.package) orelse return error.InvalidPackageLock;
            const package = data.packages[i];
            if (!std.mem.eql(u8, edge.name, package.name) or !std.mem.eql(u8, edge.source.git, package.git)) return error.InvalidPackageLock;
            const name = try names.getOrPut(edge.name);
            if (name.found_existing) return error.InvalidPackageLock;
            const source = try self.sources.getOrPut(edge.source);
            if (source.found_existing and source.value_ptr.* != i) return error.InvalidPackageLock;
            source.value_ptr.* = i;
        }
    }
};

pub fn validate(a: std.mem.Allocator, data: Data) !void {
    var index = try Index.init(a, data);
    defer index.deinit();
    if (try cycle(a, data, &index)) |path| {
        a.free(path);
        return error.InvalidPackageLock;
    }
}

// Return the exact identity cycle, including its repeated final vertex.
// Explicit frames bound stack use independently of dependency depth.
pub fn cycle(a: std.mem.Allocator, data: Data, index: *const Index) !?[]usize {
    const colors = try a.alloc(enum { unseen, active, done }, data.packages.len);
    defer a.free(colors);
    @memset(colors, .unseen);
    const Frame = struct { package: usize, next: usize = 0 };
    var stack = std.ArrayList(Frame).empty;
    defer stack.deinit(a);
    for (data.dependencies) |root| {
        const root_index = index.packages.get(root.package).?;
        if (colors[root_index] == .done) continue;
        colors[root_index] = .active;
        try stack.append(a, .{ .package = root_index });
        while (stack.items.len != 0) {
            const frame = &stack.items[stack.items.len - 1];
            const edges = data.packages[frame.package].dependencies;
            if (frame.next == edges.len) {
                colors[frame.package] = .done;
                _ = stack.pop();
                continue;
            }
            const child = index.packages.get(edges[frame.next].package).?;
            frame.next += 1;
            switch (colors[child]) {
                .done => {},
                .unseen => {
                    colors[child] = .active;
                    try stack.append(a, .{ .package = child });
                },
                .active => {
                    var start: usize = 0;
                    while (stack.items[start].package != child) : (start += 1) {}
                    const path = try a.alloc(usize, stack.items.len - start + 1);
                    for (stack.items[start..], path[0 .. path.len - 1]) |item, *value| value.* = item.package;
                    path[path.len - 1] = child;
                    return path;
                },
            }
        }
    }
    for (colors) |color| if (color == .unseen) return error.InvalidPackageLock;
    return null;
}

pub fn matches(edges: []const Edge, dependencies: []const manifest.Dependency) bool {
    if (edges.len != dependencies.len) return false;
    for (dependencies) |dependency| {
        const edge = findEdge(edges, dependency.name) orelse return false;
        if (!edge.source.eql(dependency.source)) return false;
    }
    return true;
}

pub fn findEdge(edges: []const Edge, name: []const u8) ?Edge {
    for (edges) |edge| if (std.mem.eql(u8, edge.name, name)) return edge;
    return null;
}

pub fn findPackage(data: Data, id: []const u8) ?Package {
    for (data.packages) |package| if (std.mem.eql(u8, package.id, id)) return package;
    return null;
}

pub fn identity(git: []const u8, commit: []const u8, buffer: *[64]u8) []const u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(git);
    hash.update(&.{0});
    hash.update(commit);
    const digest = hash.finalResult();
    buffer.* = std.fmt.bytesToHex(digest, .lower);
    return buffer;
}

fn hexId(value: []const u8, size: usize) bool {
    if (value.len != size) return false;
    for (value) |ch| if (!std.ascii.isHex(ch) or std.ascii.isUpper(ch)) return false;
    return true;
}

pub fn sourcePath(a: std.mem.Allocator, root: []const u8, id: []const u8) ![]u8 {
    return std.fs.path.join(a, &.{ root, ".ss-cache", "packages", "sources", id });
}

pub fn write(a: std.mem.Allocator, io: std.Io, root: []const u8, data: Data) !void {
    const bytes = try std.json.Stringify.valueAlloc(a, data, .{ .whitespace = .indent_2 });
    defer a.free(bytes);
    if (bytes.len > max_file_bytes) return error.PackageLockTooLarge;
    const path = try std.fs.path.join(a, &.{ root, "ss.lock" });
    defer a.free(path);
    const previous = utils.fs.readFileAllocLimited(io, a, path, .limited(max_file_bytes)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    defer if (previous) |old| a.free(old);
    if (previous) |old| if (std.mem.eql(u8, bytes, old)) return;
    try utils.fs.writeFile(io, path, bytes);
}
