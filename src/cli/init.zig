const std = @import("std");
const utils = @import("utils");
const project = @import("project");
const init_git = @import("init_git.zig");

pub const Options = struct {
    dir: []const u8 = ".",
    entry: ?[]const u8 = null,
    package: bool = false,
    force: bool = false,
    git: init_git.Options = .{},
};

const File = struct { path: []const u8, source: []const u8 };

pub fn run(io: std.Io, allocator: std.mem.Allocator, environ: std.process.Environ, options: Options) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const entry = options.entry orelse if (options.package) "lib.ss" else "slide.ss";
    if (std.fs.path.isAbsolute(entry) or relativePathEscapesRoot(entry)) {
        std.debug.print("init: --entry must stay inside the project directory\n", .{});
        return error.InitEntryMustBeRelative;
    }
    const directory = try utils.fs.absolutePath(io, a, options.dir);
    const files = if (options.package)
        try packageFiles(a, directory, entry)
    else
        try deckFiles(a, entry);

    // Validate the complete output plan before creating or replacing any files.
    for (files, 0..) |*file, i| {
        file.path = try std.fs.path.resolve(a, &.{ directory, file.path });
        for (files[0..i]) |other| {
            if (conflicts(file.path, other.path)) {
                std.debug.print("init: --entry conflicts with generated file: {s}\n", .{other.path});
                return error.InitEntryConflictsWithTemplate;
            }
        }
        if (utils.fs.statFile(io, file.path)) |stat| {
            if (!options.force or stat.kind != .file) {
                std.debug.print("init: {s} already exists; pass --force to overwrite files\n", .{file.path});
                return error.InitTargetExists;
            }
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }
    }
    var environment = try environ.createMap(a);
    defer environment.deinit();
    // Repository-selection variables must not redirect writes to a parent repository.
    for ([_][]const u8{ "GIT_DIR", "GIT_COMMON_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES" }) |key|
        _ = environment.swapRemove(key);
    const git = init_git.Git{ .allocator = a, .io = io, .environment = &environment };
    const setup = if (options.package) try git.prepare(directory, try packageName(directory), options.git) else null;
    if (setup) |value| {
        const quoted_url = try shellQuote(a, value.url);
        for (files) |*file| {
            if (std.mem.eql(u8, std.fs.path.basename(file.path), "README.md"))
                file.source = try std.mem.replaceOwned(u8, a, file.source, "REPOSITORY_URL", quoted_url);
        }
    }
    for (files) |file| {
        try std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(file.path).?);
        try utils.fs.writeFile(io, file.path, file.source);
    }
    if (setup) |value| try git.apply(directory, value);
    std.debug.print("created ss {s}: {s}\n", .{ if (options.package) "package" else "project", options.dir });
    for (files) |file| std.debug.print("  {s}\n", .{file.path});
    if (setup) |value| std.debug.print("  origin: {s}\n", .{value.url});
    const shell_dir = try shellQuote(a, options.dir);
    std.debug.print("\nnext:\n  ss render --project {s} --output {s}.pdf\n", .{ shell_dir, if (options.package) "example" else "deck" });
}

fn deckFiles(a: std.mem.Allocator, entry: []const u8) ![]File {
    const directory = std.fs.path.dirname(entry) orelse ".";
    const files = try a.alloc(File, 4);
    files[0..4].* = .{
        .{ .path = "ss.toml", .source = try std.fmt.allocPrint(a, @embedFile("templates/ss.toml"), .{try std.json.Stringify.valueAlloc(a, entry, .{})}) },
        .{ .path = entry, .source = @embedFile("templates/slide.ss") },
        .{ .path = try std.fs.path.join(a, &.{ directory, "components.ss" }), .source = @embedFile("templates/components.ss") },
        .{ .path = try std.fs.path.join(a, &.{ directory, "theme.ss" }), .source = @embedFile("templates/theme.ss") },
    };
    return files;
}

fn packageFiles(a: std.mem.Allocator, directory: []const u8, entry: []const u8) ![]File {
    const name = try packageName(directory);
    if (!project.packages.manifest.validRelativePath(entry) or !std.mem.endsWith(u8, entry, ".ss")) {
        std.debug.print("init: --entry must be a relative .ss file path\n", .{});
        return error.InvalidPackageEntry;
    }
    const stem = entry[0 .. entry.len - 3];
    if (std.mem.indexOfScalar(u8, stem, '"') != null or std.fs.path.extension(stem).len != 0) {
        std.debug.print("init: --entry must be importable: no quotes or additional file extensions\n", .{});
        return error.InvalidPackageEntry;
    }
    const import_path = try std.fmt.allocPrint(a, "../{s}", .{stem});
    const files = try a.alloc(File, 4);
    files[0..4].* = .{
        .{ .path = "ss.toml", .source = try std.fmt.allocPrint(a, @embedFile("templates/package/ss.toml"), .{ name, try std.json.Stringify.valueAlloc(a, entry, .{}) }) },
        .{ .path = entry, .source = @embedFile("templates/package/lib.ss") },
        .{ .path = "examples/slide.ss", .source = try std.fmt.allocPrint(a, @embedFile("templates/package/example.ss"), .{import_path}) },
        .{ .path = "README.md", .source = try std.fmt.allocPrint(a, @embedFile("templates/package/README.md"), .{ name, name }) },
    };
    return files;
}

fn packageName(directory: []const u8) ![]const u8 {
    var name = std.fs.path.basename(directory);
    if (std.mem.endsWith(u8, name, ".ss")) name = name[0 .. name.len - 3];
    if (!project.packages.manifest.validName(name)) {
        std.debug.print("init: directory name must be a valid package identifier (optionally followed by .ss): {s}\n", .{name});
        return error.InvalidPackageName;
    }
    return name;
}

fn conflicts(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b) or isParent(a, b) or isParent(b, a);
}

fn isParent(parent: []const u8, child: []const u8) bool {
    return child.len > parent.len and std.mem.startsWith(u8, child, parent) and child[parent.len] == std.fs.path.sep;
}

fn shellQuote(a: std.mem.Allocator, value: []const u8) ![]const u8 {
    if (value.len > 0 and std.mem.indexOfNone(u8, value, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_./-") == null) return value;
    const escaped = try std.mem.replaceOwned(u8, a, value, "'", "'\\''");
    return std.fmt.allocPrint(a, "'{s}'", .{escaped});
}

fn relativePathEscapesRoot(path: []const u8) bool {
    var depth: usize = 0;
    var parts = std.mem.tokenizeAny(u8, path, "/\\");
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) {
            if (depth == 0) return true;
            depth -= 1;
            continue;
        }
        depth += 1;
    }
    return false;
}
