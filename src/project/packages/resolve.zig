const std = @import("std");
const utils = @import("utils");
const manifest = @import("manifest.zig");
const lock = @import("lock.zig");
const git = @import("git.zig");

// Resolution is read-only. Compiler, editor and watcher share these rules.
pub const Resolver = struct {
    arena: std.heap.ArenaAllocator,
    io: std.Io,
    start_dir: []const u8,
    inputs: ?*utils.FileInputs,
    root: ?[]const u8 = null,
    config_path: ?[]const u8 = null,
    data: lock.Data = .{},
    lock_file: ?lock.File = null,
    config: ?manifest.Manifest = null,

    pub fn init(a: std.mem.Allocator, io: std.Io, start_dir: []const u8, inputs: ?*utils.FileInputs) Resolver {
        return .{ .arena = std.heap.ArenaAllocator.init(a), .io = io, .start_dir = start_dir, .inputs = inputs };
    }

    pub fn deinit(self: *Resolver) void {
        if (self.lock_file) |*file| file.deinit();
        if (self.config) |*config| config.deinit();
        self.arena.deinit();
    }

    pub fn resolve(self: *Resolver, importer_dir: []const u8, spec: []const u8) ![]const u8 {
        if (!std.mem.startsWith(u8, spec, "pkg:")) return error.InvalidPackageImport;
        const relative = spec[4..];
        const slash = std.mem.indexOfScalar(u8, relative, '/') orelse relative.len;
        const name = relative[0..slash];
        if (!manifest.validName(name)) return error.InvalidPackageImport;
        const subpath = if (slash == relative.len) null else relative[slash + 1 ..];
        if (subpath) |value| {
            if (!manifest.validRelativePath(value) or std.fs.path.extension(value).len != 0) return error.InvalidPackageImport;
        }
        const source = try self.packageSource(importer_dir, name);
        const a = self.arena.allocator();
        const entry = if (subpath) |value| try std.fmt.allocPrint(a, "{s}.ss", .{value}) else source.entry;
        return std.fs.path.join(a, &.{ source.directory, entry });
    }

    // Borrowed results live until deinit. Names remain available before fetch;
    // managed sources use the consuming project's locked dependency scope.
    pub fn dependencyNames(self: *Resolver, importer_dir: []const u8) ![]const []const u8 {
        try self.loadConfig();
        const a = self.arena.allocator();
        const snapshot_root = try sourceProjectRoot(a, importer_dir);
        if (snapshot_root != null) {
            const edges = try self.dependencies(importer_dir);
            const names = try a.alloc([]const u8, edges.len);
            for (edges, names) |edge, *name| name.* = edge.name;
            return names;
        }
        const declared = self.config.?.data.dependencies;
        const names = try a.alloc([]const u8, declared.len);
        for (declared, names) |dependency, *name| name.* = dependency.name;
        return names;
    }

    pub const PackageSource = struct { directory: []const u8, entry: []const u8 };

    pub fn packageSource(self: *Resolver, importer_dir: []const u8, name: []const u8) !PackageSource {
        if (!manifest.validName(name)) return error.InvalidPackageImport;
        const edges = try self.dependencies(importer_dir);
        const edge = lock.findEdge(edges, name) orelse return error.UnknownPackage;
        const package = lock.findPackage(self.data, edge.package) orelse return error.InvalidPackageLock;
        const a = self.arena.allocator();
        const directory = try lock.sourcePath(a, self.root.?, package.id);
        if (!try git.ready(a, self.io, directory, package.commit, self.inputs)) return error.PackageNotFetched;
        return .{ .directory = directory, .entry = package.entry };
    }

    fn dependencies(self: *Resolver, importer_dir: []const u8) ![]const lock.Edge {
        try self.load();
        for (self.data.packages) |package| {
            const directory = try lock.sourcePath(self.arena.allocator(), self.root.?, package.id);
            if (within(directory, importer_dir)) return package.dependencies;
        }
        return self.data.dependencies;
    }

    fn load(self: *Resolver) !void {
        if (self.lock_file != null) return;
        try self.loadConfig();
        var parsed = try lock.readWithInputs(self.arena.allocator(), self.io, self.root.?, self.inputs);
        errdefer parsed.deinit();
        if (!lock.matches(parsed.value.dependencies, self.config.?.data.dependencies)) return error.StalePackageLock;
        self.data = parsed.value;
        self.lock_file = parsed;
    }

    fn loadConfig(self: *Resolver) !void {
        if (self.config != null) return;
        const a = self.arena.allocator();
        const snapshot_root = if (self.config_path) |path| try sourceProjectRoot(a, path) else null;
        const root = snapshot_root orelse if (self.config_path) |path| std.fs.path.dirname(path).? else try findRoot(a, self.io, self.start_dir, self.inputs);
        const config_path = if (snapshot_root != null) try std.fs.path.join(a, &.{ root, "ss.toml" }) else self.config_path orelse try std.fs.path.join(a, &.{ root, "ss.toml" });
        if (self.inputs) |inputs| try inputs.record(".", config_path, .file);
        const text = try utils.fs.readFileAlloc(self.io, a, config_path);
        if (self.inputs) |inputs| try inputs.recordContents(config_path, text);
        self.config = try manifest.Manifest.parse(a, text);
        self.root = root;
    }
};

pub fn findRoot(a: std.mem.Allocator, io: std.Io, start: []const u8, inputs: ?*utils.FileInputs) ![]const u8 {
    var directory: []const u8 = try utils.fs.absolutePath(io, a, start);
    errdefer a.free(directory);
    // A snapshot's manifest describes its dependencies; its lock belongs to
    // the importing project, outside the managed source tree.
    if (try sourceProjectRoot(a, directory)) |root| {
        a.free(directory);
        directory = root;
    }
    while (true) {
        const path = try std.fs.path.join(a, &.{ directory, "ss.toml" });
        defer a.free(path);
        if (inputs) |observed| try observed.record(".", path, .file);
        if (try utils.fs.fileExists(a, path)) return directory;
        const parent = std.fs.path.dirname(directory) orelse return error.PackageProjectNotFound;
        if (std.mem.eql(u8, parent, directory)) return error.PackageProjectNotFound;
        const next = try a.dupe(u8, parent);
        a.free(directory);
        directory = next;
    }
}

pub fn within(root: []const u8, path: []const u8) bool {
    return std.mem.eql(u8, root, path) or (std.mem.startsWith(u8, path, root) and path.len > root.len and std.fs.path.isSep(path[root.len]));
}

pub fn errorMessage(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.PackageProjectNotFound => "PackageProjectNotFound: add dependencies to ss.toml with 'ss add'",
        error.MissingPackageLock, error.StalePackageLock => "PackageLockRequired: run 'ss fetch' to resolve dependencies from ss.toml",
        error.InvalidPackageLock => "InvalidPackageLock: restore a valid ss.lock or remove it and run 'ss fetch'",
        error.PackageNotFetched => "PackageNotFetched: run 'ss fetch' to download the locked dependencies",
        error.UnknownPackage => "UnknownPackage: this package is not declared in the importing package's dependencies",
        error.InvalidPackageImport => "InvalidPackageImport: use pkg:name or pkg:name/module without an extension or parent path",
        else => null,
    };
}

fn sourceProjectRoot(a: std.mem.Allocator, path: []const u8) !?[]const u8 {
    const sources = try std.fs.path.join(a, &.{ ".ss-cache", "packages", "sources" });
    defer a.free(sources);
    const boundary = try std.fmt.allocPrint(a, "{c}{s}{c}", .{ std.fs.path.sep, sources, std.fs.path.sep });
    defer a.free(boundary);
    const index = std.mem.indexOf(u8, path, boundary) orelse return null;
    return try a.dupe(u8, path[0..index]);
}
