const std = @import("std");
const source_text = @import("utils").source;
const toml = @import("../toml.zig");

pub const Source = struct {
    git: []const u8,
    tag: ?[]const u8 = null,
    branch: ?[]const u8 = null,
    rev: ?[]const u8 = null,

    pub fn eql(a: Source, b: Source) bool {
        return std.mem.eql(u8, a.git, b.git) and optionalEql(a.tag, b.tag) and
            optionalEql(a.branch, b.branch) and optionalEql(a.rev, b.rev);
    }

    pub const Context = struct {
        pub fn hash(_: Context, source: Source) u64 {
            var h = std.hash.Wyhash.init(0);
            h.update(source.git);
            for ([_]?[]const u8{ source.tag, source.branch, source.rev }) |selector| {
                h.update(&.{if (selector != null) 1 else 0});
                if (selector) |value| h.update(value);
            }
            return h.final();
        }

        pub fn eql(_: Context, a: Source, b: Source) bool {
            return a.eql(b);
        }
    };
};

pub fn SourceMap(comptime Value: type) type {
    return std.HashMap(Source, Value, Source.Context, std.hash_map.default_max_load_percentage);
}

pub const Dependency = struct { name: []const u8, source: Source };
pub const Package = struct { name: []const u8, entry: []const u8 = "lib.ss" };
pub const Data = struct { package: ?Package = null, dependencies: []const Dependency = &.{} };

pub const Manifest = struct {
    arena: std.heap.ArenaAllocator,
    data: Data,

    pub fn parse(allocator: std.mem.Allocator, text: []const u8) !Manifest {
        var document = try toml.Document.parse(text, null);
        defer document.deinit();
        return fromDocument(allocator, &document);
    }

    pub fn fromDocument(allocator: std.mem.Allocator, document: *const toml.Document) !Manifest {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        const root = document.root();
        try document.keys(root, &.{ "project", "package", "dependencies", "cli", "cache", "editor", "highlight" }, error.UnknownConfigKey);
        const package = try document.table(root, "package");
        try document.keys(package, &.{ "name", "entry" }, error.UnknownConfigKey);
        const metadata: ?Package = if (toml.isTable(package)) blk: {
            const name = try document.string(package, "name", error.InvalidPackageName) orelse
                return document.fail(package, error.MissingPackageName);
            if (!validName(name)) return document.fail(package, error.InvalidPackageName);
            const entry = try document.string(package, "entry", error.InvalidPackageEntry) orelse "lib.ss";
            if (!validRelativePath(entry) or !std.mem.endsWith(u8, entry, ".ss"))
                return document.fail(package, error.InvalidPackageEntry);
            break :blk .{ .name = try a.dupe(u8, name), .entry = try a.dupe(u8, entry) };
        } else null;
        const dependencies = try document.table(root, "dependencies");
        const parsed = try a.alloc(Dependency, toml.tableSize(dependencies));
        for (parsed, 0..) |*dependency, i| {
            const name = toml.keyAt(dependencies, i);
            if (!validName(name)) return document.fail(dependencies, error.InvalidDependencyName);
            const value = try document.table(dependencies, name);
            try document.keys(value, &.{ "git", "tag", "branch", "rev" }, error.UnknownConfigKey);
            const git = try document.string(value, "git", error.InvalidDependencySource) orelse
                return document.fail(value, error.InvalidDependencySource);
            const source = Source{
                .git = git,
                .tag = try document.string(value, "tag", error.InvalidDependencySource),
                .branch = try document.string(value, "branch", error.InvalidDependencySource),
                .rev = try document.string(value, "rev", error.InvalidDependencySource),
            };
            validateSource(source) catch |err| return document.fail(value, err);
            dependency.* = .{ .name = try a.dupe(u8, name), .source = try cloneSource(a, source) };
        }
        std.mem.sort(Dependency, parsed, {}, struct {
            fn less(_: void, a1: Dependency, b: Dependency) bool {
                return std.mem.lessThan(u8, a1.name, b.name);
            }
        }.less);
        return .{ .arena = arena, .data = .{ .package = metadata, .dependencies = parsed } };
    }

    pub fn deinit(self: *Manifest) void {
        self.arena.deinit();
    }
};

pub fn validName(name: []const u8) bool {
    return source_text.isValidIdentifier(name);
}

pub fn validRelativePath(path: []const u8) bool {
    if (path.len == 0 or std.fs.path.isAbsolute(path)) return false;
    var parts = std.mem.splitAny(u8, path, "/\\");
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, "..") or std.mem.eql(u8, part, ".")) return false;
        for (part) |ch| if (ch < 32 or ch == ':' or ch == 127) return false;
    }
    return true;
}

pub fn validateSource(source: Source) !void {
    if (source.git.len == 0 or source.git[0] == '-' or std.mem.startsWith(u8, source.git, "ext::")) return error.InvalidDependencySource;
    for (source.git) |ch| if (ch < 32 or ch == 127) return error.InvalidDependencySource;
    var selectors: usize = 0;
    for ([_]?[]const u8{ source.tag, source.branch, source.rev }) |selector| {
        if (selector) |value| {
            selectors += 1;
            if (value.len == 0 or value[0] == '-') return error.InvalidDependencySource;
            for (value) |ch| if (ch < 33 or ch == 127) return error.InvalidDependencySource;
        }
    }
    if (selectors > 1) return error.InvalidDependencySource;
}

pub fn cloneSource(a: std.mem.Allocator, source: Source) !Source {
    return .{ .git = try a.dupe(u8, source.git), .tag = if (source.tag) |v| try a.dupe(u8, v) else null, .branch = if (source.branch) |v| try a.dupe(u8, v) else null, .rev = if (source.rev) |v| try a.dupe(u8, v) else null };
}

fn optionalEql(a: ?[]const u8, b: ?[]const u8) bool {
    return if (a) |value| if (b) |other| std.mem.eql(u8, value, other) else false else b == null;
}
