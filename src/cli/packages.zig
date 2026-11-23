const std = @import("std");
const project = @import("project");
const packages = project.packages;
const utils = @import("utils");

const Options = struct {
    name: ?[]const u8 = null,
    locked: bool = false,
    git: ?[]const u8 = null,
    tag: ?[]const u8 = null,
    branch: ?[]const u8 = null,
    rev: ?[]const u8 = null,
    project: ?[]const u8 = null,
};

fn parse(command: []const u8, args: []const []const u8) !Options {
    var options = Options{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--locked")) {
            if (!std.mem.eql(u8, command, "fetch") or options.locked) return error.InvalidUsage;
            options.locked = true;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            if (i + 1 == args.len) return error.InvalidUsage;
            const field = inline for (.{ "git", "tag", "branch", "rev", "project" }) |name| {
                if (std.mem.eql(u8, arg, "--" ++ name)) break name;
            } else return error.InvalidUsage;
            if (!std.mem.eql(u8, command, "add") and !std.mem.eql(u8, field, "project")) return error.InvalidUsage;
            inline for (.{ "git", "tag", "branch", "rev", "project" }) |name| {
                if (std.mem.eql(u8, field, name)) {
                    if (@field(options, name) != null) return error.InvalidUsage;
                    @field(options, name) = args[i + 1];
                }
            }
            i += 1;
        } else {
            if (options.name != null or !std.mem.eql(u8, command, "update")) return error.InvalidUsage;
            options.name = arg;
        }
    }
    if (std.mem.eql(u8, command, "add") and options.git == null) return error.InvalidUsage;
    if (options.name) |name| if (!packages.manifest.validName(name)) return error.InvalidDependencyName;
    return options;
}

pub fn run(a: std.mem.Allocator, io: std.Io, environ: std.process.Environ, command: []const u8, args: []const []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const temporary = arena.allocator();
    const options = try parse(command, args);
    const config_path = if (options.project) |arg| try project.projectArgumentPath(temporary, arg) else blk: {
        const directory = try packages.resolve.findRoot(temporary, io, ".", null);
        break :blk try std.fs.path.join(temporary, &.{ directory, "ss.toml" });
    };
    const root = std.fs.path.dirname(config_path).?;
    var environment = try environ.createMap(temporary);
    defer environment.deinit();
    try environment.put("GIT_TERMINAL_PROMPT", "0");
    const client = packages.git.Client{ .allocator = temporary, .io = io, .root = root, .environment = &environment };
    var guard = try client.acquire();
    defer guard.close(io);
    const original = try utils.fs.readFileAlloc(io, temporary, config_path);
    var manifest = try packages.manifest.Manifest.parse(temporary, original);
    defer manifest.deinit();
    var old_lock = packages.lock.read(temporary, io, root) catch |err| switch (err) {
        error.MissingPackageLock => if (options.locked) return err else null,
        else => return err,
    };
    defer if (old_lock) |*file| file.deinit();
    const previous: packages.lock.Data = if (old_lock) |file| file.value else .{};
    if (options.locked) {
        if (!packages.lock.matches(previous.dependencies, manifest.data.dependencies)) return error.StalePackageLock;
        try packages.fetch.restore(client, previous);
        const current = try utils.fs.readFileAlloc(io, temporary, config_path);
        if (!std.mem.eql(u8, current, original)) return error.PackageManifestChanged;
        std.debug.print("{d} locked package(s) ready\n", .{previous.packages.len});
        return;
    }
    var fetcher = try packages.fetch.Fetcher.init(temporary, client, previous);
    defer fetcher.deinit();
    var next_source: ?[]const u8 = null;
    var next_manifest: ?packages.manifest.Manifest = null;
    defer if (next_manifest) |*edited| edited.deinit();
    if (std.mem.eql(u8, command, "add")) {
        const source = packages.manifest.Source{ .git = options.git.?, .tag = options.tag, .branch = options.branch, .rev = options.rev };
        try packages.manifest.validateSource(source);
        const name = try fetcher.discover(source);
        for (manifest.data.dependencies) |dependency| if (std.mem.eql(u8, dependency.name, name)) return error.DependencyAlreadyExists;
        next_source = try addDeclaration(temporary, original, name, source);
        next_manifest = try packages.manifest.Manifest.parse(temporary, next_source.?);
    }
    const update: packages.fetch.Update = if (std.mem.eql(u8, command, "update"))
        if (options.name) |name| .{ .named = name } else .all
    else
        .none;
    const resolved = try fetcher.fetch(if (next_manifest) |edited| edited.data else manifest.data, update);
    const current = try utils.fs.readFileAlloc(io, temporary, config_path);
    if (!std.mem.eql(u8, current, original)) return error.PackageManifestChanged;
    if (next_source) |bytes| try utils.fs.writeFile(io, config_path, bytes);
    packages.lock.write(temporary, io, root, resolved) catch |err| {
        if (next_source != null) try utils.fs.writeFile(io, config_path, original);
        return err;
    };
    for (resolved.packages) |package| {
        if (fetcher.previous_index.packages.contains(package.id)) continue;
        std.debug.print("  {s}@{s} ({s})\n    used by ", .{ package.name, package.commit[0..12], package.git });
        var first = true;
        if (usesPackage(resolved.dependencies, package.id)) {
            std.debug.print("project", .{});
            first = false;
        }
        for (resolved.packages) |parent| {
            if (usesPackage(parent.dependencies, package.id)) {
                std.debug.print("{s}{s}", .{ if (first) "" else ", ", parent.name });
                first = false;
            }
        }
        std.debug.print("\n", .{});
    }
    std.debug.print("{d} package(s) ready\n", .{resolved.packages.len});
}

fn usesPackage(edges: []const packages.lock.Edge, id: []const u8) bool {
    for (edges) |edge| if (std.mem.eql(u8, edge.package, id)) return true;
    return false;
}

fn addDeclaration(a: std.mem.Allocator, original: []const u8, name: []const u8, source: packages.manifest.Source) ![]const u8 {
    var out = std.Io.Writer.Allocating.init(a);
    defer out.deinit();
    const writer = &out.writer;
    if (try inlineDependencies(original)) |position| {
        try writer.writeAll(original[0..position.close]);
        try writer.writeAll(if (position.comma) ",\n" else "\n");
        try writer.print("{s} = {{ git = {s}", .{ name, try quoted(a, source.git) });
        inline for (.{ "tag", "branch", "rev" }) |field| {
            if (@field(source, field)) |value| try writer.print(", {s} = {s}", .{ field, try quoted(a, value) });
        }
        try writer.writeAll(" }\n");
        try writer.writeAll(original[position.close..]);
        return out.toOwnedSlice();
    }
    try writer.writeAll(original);
    try writer.print("\n[dependencies.{s}]\ngit = {s}\n", .{ name, try quoted(a, source.git) });
    inline for (.{ "tag", "branch", "rev" }) |field| {
        if (@field(source, field)) |value| try writer.print("{s} = {s}\n", .{ field, try quoted(a, value) });
    }
    return out.toOwnedSlice();
}

fn quoted(a: std.mem.Allocator, value: []const u8) ![]const u8 {
    return std.json.Stringify.valueAlloc(a, value, .{});
}

pub fn errorMessage(err: anyerror) ?[]const u8 {
    if (packages.resolve.errorMessage(err)) |message| return message;
    return switch (err) {
        error.InvalidUsage => "usage: ss add --git URL [--tag TAG | --branch BRANCH | --rev COMMIT] [--project FILE_OR_DIR]; ss fetch [--locked] [--project FILE_OR_DIR]; ss update [NAME] [--project FILE_OR_DIR]",
        error.InvalidDependencyName => "InvalidDependencyName: use an identifier containing letters, digits and underscores",
        error.InvalidDependencySource => "InvalidDependencySource: specify a Git URL and at most one tag, branch or revision",
        error.DependencyAlreadyExists => "DependencyAlreadyExists: edit its source in ss.toml or use 'ss update NAME'",
        error.PackageNameMismatch => "PackageNameMismatch: dependency keys must match the target package.name",
        error.TooManyPackages => "TooManyPackages: the dependency graph exceeds 1024 packages",
        error.GitNotFound => "GitNotFound: install Git to fetch packages",
        error.GitCommandFailed => "GitCommandFailed: verify the repository URL, revision and Git credentials",
        error.MissingPackageManifest => "MissingPackageManifest: the repository must contain ss.toml with [package] and an entry file",
        error.InvalidPackageEntry => "InvalidPackageEntry: package.entry must identify an existing .ss file inside the repository",
        error.PackageDependencyCycle => "PackageDependencyCycle: package dependencies must not form a cycle",
        error.PackageSubmodulesUnsupported => "PackageSubmodulesUnsupported: package assets and sources must be stored in the repository itself",
        error.PackageManifestChanged => "PackageManifestChanged: ss.toml changed during fetching; run the command again",
        else => project.configErrorMessage(err),
    };
}

const InlinePosition = struct { close: usize, comma: bool };

// Locate the closing brace without rewriting existing TOML or its comments.
fn inlineDependencies(text: []const u8) !?InlinePosition {
    var document = try project.toml.Document.parse(text, null);
    defer document.deinit();
    const table = project.toml.get(document.root(), "dependencies");
    const span = document.span(table) orelse return null;
    const line = text[span.start..span.end];
    const equal = std.mem.indexOfScalar(u8, line, '=') orelse return null;
    var index = span.start + equal + 1;
    while (index < text.len and std.ascii.isWhitespace(text[index])) : (index += 1) {}
    if (index == text.len or text[index] != '{') return null;
    var depth: usize = 0;
    var last: u8 = '{';
    while (index < text.len) {
        const ch = text[index];
        if (ch == '#') {
            while (index < text.len and text[index] != '\n') : (index += 1) {}
            continue;
        }
        if (ch == '"' or ch == '\'') {
            const triple = index + 2 < text.len and text[index + 1] == ch and text[index + 2] == ch;
            index += if (triple) @as(usize, 3) else 1;
            while (index < text.len) {
                if (ch == '"' and text[index] == '\\') {
                    index += 2;
                } else if (text[index] == ch and (!triple or (index + 2 < text.len and text[index + 1] == ch and text[index + 2] == ch))) {
                    index += if (triple) @as(usize, 3) else 1;
                    if (triple) while (index < text.len and text[index] == ch) : (index += 1) {};
                    break;
                } else index += 1;
            }
            last = ch;
            continue;
        }
        if (ch == '{') depth += 1;
        if (ch == '}') {
            depth -= 1;
            if (depth == 0) return .{ .close = index, .comma = last != '{' and last != ',' };
        }
        if (!std.ascii.isWhitespace(ch)) last = ch;
        index += 1;
    }
    return error.InvalidToml;
}
