const std = @import("std");
const utils = @import("utils");
const manifest = @import("manifest.zig");
const lock = @import("lock.zig");
const git = @import("git.zig");

pub const Update = union(enum) { none, all, named: []const u8 };
const Policy = union(enum) { preserve, all, source: manifest.Source };
const Node = struct { package: lock.Package, manifest: manifest.Manifest };

// Allocations for the resulting graph belong to the command's arena. Parsed
// manifests stay alive until deinit, including declarations queued for expansion.
pub const Fetcher = struct {
    allocator: std.mem.Allocator,
    client: git.Client,
    previous: lock.Data,
    previous_index: lock.Index,
    selections: manifest.SourceMap([]const u8),
    identities: std.StringHashMap(usize),
    nodes: std.ArrayList(Node) = .empty,

    pub fn init(a: std.mem.Allocator, client: git.Client, previous: lock.Data) !Fetcher {
        return .{
            .allocator = a,
            .client = client,
            .previous = previous,
            .previous_index = try lock.Index.init(a, previous),
            .selections = .init(a),
            .identities = .init(a),
        };
    }

    pub fn deinit(self: *Fetcher) void {
        for (self.nodes.items) |*node| node.manifest.deinit();
        self.nodes.deinit(self.allocator);
        self.previous_index.deinit();
        self.selections.deinit();
        self.identities.deinit();
    }

    pub fn discover(self: *Fetcher, source: manifest.Source) ![]const u8 {
        const i = try self.load(source, .preserve);
        return self.nodes.items[i].package.name;
    }

    pub fn fetch(self: *Fetcher, data: manifest.Data, update: Update) !lock.Data {
        // Choose refresh policy before visiting any edge. A named update affects
        // the source specification wherever it occurs in the graph.
        const policy: Policy = switch (update) {
            .none => .preserve,
            .all => .all,
            .named => |name| blk: {
                for (data.dependencies) |dependency| {
                    if (std.mem.eql(u8, dependency.name, name)) break :blk .{ .source = dependency.source };
                }
                return error.UnknownPackage;
            },
        };
        const edges = try self.dependencies(data.dependencies, policy);
        var i: usize = 0;
        while (i < self.nodes.items.len) : (i += 1) {
            const declarations = self.nodes.items[i].manifest.data.dependencies;
            const nested = try self.dependencies(declarations, policy);
            self.nodes.items[i].package.dependencies = nested;
        }
        const packages = try self.allocator.alloc(lock.Package, self.nodes.items.len);
        for (self.nodes.items, packages) |node, *package| package.* = node.package;
        std.mem.sort(lock.Package, packages, {}, struct {
            fn less(_: void, a: lock.Package, b: lock.Package) bool {
                return std.mem.lessThan(u8, a.id, b.id);
            }
        }.less);
        const result = lock.Data{ .dependencies = edges, .packages = packages };
        var index = try lock.Index.init(self.allocator, result);
        defer index.deinit();
        if (try lock.cycle(self.allocator, result, &index)) |path| {
            defer self.allocator.free(path);
            std.debug.print("Package dependency cycle: ", .{});
            for (path, 0..) |n, position| {
                const package = packages[n];
                std.debug.print("{s}{s}@{s}", .{ if (position == 0) "" else " -> ", package.name, package.commit[0..12] });
            }
            std.debug.print("\n", .{});
            return error.PackageDependencyCycle;
        }
        return result;
    }

    fn dependencies(self: *Fetcher, declarations: []const manifest.Dependency, policy: Policy) ![]const lock.Edge {
        const edges = try self.allocator.alloc(lock.Edge, declarations.len);
        for (declarations, edges) |declaration, *edge| {
            const i = try self.load(declaration.source, policy);
            const package = self.nodes.items[i].package;
            if (!std.mem.eql(u8, declaration.name, package.name)) {
                std.debug.print("Dependency '{s}' declares package.name = '{s}' ({s})\n", .{ declaration.name, package.name, declaration.source.git });
                return error.PackageNameMismatch;
            }
            edge.* = .{ .name = declaration.name, .source = declaration.source, .package = package.id };
        }
        return edges;
    }

    fn load(self: *Fetcher, source: manifest.Source, policy: Policy) !usize {
        const commit = try self.select(source, policy);
        var buffer: [64]u8 = undefined;
        const id = lock.identity(source.git, commit, &buffer);
        if (self.identities.get(id)) |i| return i;
        if (self.nodes.items.len >= lock.max_packages) return error.TooManyPackages;
        const directory = try self.client.ensure(source.git, commit);
        defer self.allocator.free(directory);
        var parsed = try readManifest(self.client, directory);
        errdefer parsed.deinit();
        const metadata = parsed.data.package.?;
        const package = lock.Package{
            .name = metadata.name,
            .id = try self.allocator.dupe(u8, id),
            .git = source.git,
            .commit = commit,
            .entry = metadata.entry,
            .dependencies = &.{},
        };
        const i = self.nodes.items.len;
        try self.identities.put(package.id, i);
        try self.nodes.append(self.allocator, .{ .package = package, .manifest = parsed });
        return i;
    }

    fn select(self: *Fetcher, source: manifest.Source, policy: Policy) ![]const u8 {
        if (self.selections.get(source)) |commit| return commit;
        const refresh = switch (policy) {
            .preserve => false,
            .all => true,
            .source => |selected| selected.eql(source),
        };
        const old = self.previous_index.sources.get(source);
        const commit = if (!refresh and old != null) self.previous.packages[old.?].commit else try self.client.resolve(source);
        try self.selections.put(source, commit);
        return commit;
    }
};

// Restore exact commits only. No branch/tag resolution and no lock writes.
pub fn restore(client: git.Client, data: lock.Data) !void {
    for (data.packages) |package| {
        const directory = try client.ensure(package.git, package.commit);
        defer client.allocator.free(directory);
        var parsed = try readManifest(client, directory);
        defer parsed.deinit();
        const metadata = parsed.data.package.?;
        if (!std.mem.eql(u8, metadata.name, package.name) or !std.mem.eql(u8, metadata.entry, package.entry) or
            !lock.matches(package.dependencies, parsed.data.dependencies)) return error.StalePackageLock;
    }
}

fn readManifest(client: git.Client, directory: []const u8) !manifest.Manifest {
    const path = try std.fs.path.join(client.allocator, &.{ directory, "ss.toml" });
    defer client.allocator.free(path);
    const text = utils.fs.readFileAllocLimited(client.io, client.allocator, path, .limited(256 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.MissingPackageManifest,
        else => return err,
    };
    defer client.allocator.free(text);
    var parsed = try manifest.Manifest.parse(client.allocator, text);
    errdefer parsed.deinit();
    const package = parsed.data.package orelse return error.MissingPackageManifest;
    const entry = try std.fs.path.join(client.allocator, &.{ directory, package.entry });
    defer client.allocator.free(entry);
    if (!try utils.fs.fileExists(client.allocator, entry)) return error.InvalidPackageEntry;
    return parsed;
}
