const std = @import("std");
const cache = @import("../src/utils/tree_sitter_cache.zig");
const Step = std.Build.Step;

pub const cache_subdir = ".ss/cache/tree-sitter";
const nix_tree_sitter_sources_dir = ".ss-cache/nix/tree-sitter-sources";
const tree_sitter_manifest_read_limit = 512 * 1024;
const tree_sitter_manifest_hash_bytes = 12;
const tree_sitter_build_stdout_limit = 64 * 1024;
const tree_sitter_build_stderr_limit = 256 * 1024;

pub const Bundle = struct {
    manifest_hash: []const u8,
    root: std.Build.LazyPath,
    step: *Step,
};

const Paths = struct {
    manifest_hash: []const u8,
    cache_root: []const u8,
    bundle_root: []const u8,
    runtime_source_root: []const u8,
    generated_root: []const u8,
};

const TreeSitterManifest = struct {
    schema: u32,
    runtime: Runtime,
    languages: []const Language,

    const Runtime = struct {
        repo: []const u8,
        commit: []const u8,
    };

    const Language = struct {
        name: []const u8,
        display_name: []const u8,
        repo: []const u8,
        commit: []const u8,
        aliases: []const []const u8,
        files: []const File,
    };

    const File = struct {
        from: []const u8,
        to: []const u8,
    };
};

pub fn create(b: *std.Build) Bundle {
    const manifest_text = b.build_root.handle.readFileAlloc(
        b.graph.io,
        "third_party/tree-sitter-languages/manifest.json",
        b.allocator,
        .limited(tree_sitter_manifest_read_limit),
    ) catch @panic("third_party/tree-sitter-languages/manifest.json is missing.");
    const manifest = std.json.parseFromSliceLeaky(TreeSitterManifest, b.allocator, manifest_text, .{
        .ignore_unknown_fields = true,
    }) catch |err| std.debug.panic("failed to parse tree-sitter bundle metadata: {}", .{err});
    validateTreeSitterManifest(manifest);
    const manifest_hash = treeSitterManifestHash(b, manifest_text);
    const cache_root = b.pathFromRoot(b.option([]const u8, "tree-sitter-cache", "Shared tree-sitter source cache directory") orelse treeSitterCacheRoot(b));
    const bundle_root = b.pathJoin(&.{ cache_root, "bundles", manifest_hash });
    const sources = b.option([]const u8, "tree-sitter-sources", "Directory of pinned runtime and language source checkouts");
    const prepare = b.allocator.create(Prepare) catch @panic("OOM");
    prepare.* = .{
        .step = Step.init(.{ .id = .custom, .name = "prepare tree-sitter sources", .owner = b, .makeFn = Prepare.make }),
        .generated = undefined,
        .manifest = manifest,
        .paths = .{
            .manifest_hash = manifest_hash,
            .cache_root = cache_root,
            .bundle_root = bundle_root,
            .runtime_source_root = b.pathJoin(&.{ bundle_root, "runtime", "source" }),
            .generated_root = b.pathJoin(&.{ bundle_root, "generated" }),
        },
        .sources_root = if (sources) |root| b.pathFromRoot(root) else null,
    };
    prepare.generated = .{ .step = &prepare.step };
    return .{ .manifest_hash = manifest_hash, .root = .{ .generated = .{ .file = &prepare.generated } }, .step = &prepare.step };
}

const Prepare = struct {
    step: Step,
    generated: std.Build.GeneratedFile,
    manifest: TreeSitterManifest,
    paths: Paths,
    sources_root: ?[]const u8,
    // Compilation reads this shared output after preparation. The build runner
    // owns the lease until it exits, including while dependent C compilers run.
    lease: ?cache.Lease = null,

    fn make(step: *Step, _: Step.MakeOptions) !void {
        const self: *Prepare = @fieldParentPtr("step", step);
        const b = step.owner;
        if (self.lease == null) self.lease = try cache.Lease.acquire(b.graph.io, b.allocator, self.paths.cache_root);
        errdefer {
            if (self.lease) |*lease| lease.deinit();
            self.lease = null;
        }
        const lock_dir = b.pathJoin(&.{ self.paths.cache_root, "locks" });
        try std.Io.Dir.cwd().createDirPath(b.graph.io, lock_dir);
        const lock = try std.Io.Dir.cwd().createFile(b.graph.io, b.pathJoin(&.{ lock_dir, b.fmt("{s}.lock", .{self.paths.manifest_hash}) }), .{
            .read = true,
            .truncate = false,
            .lock = .exclusive,
        });
        defer lock.close(b.graph.io);
        if (!treeSitterBundleComplete(b, self.manifest, self.paths)) {
            try buildTreeSitterBundle(step, self.manifest, self.paths, self.sources_root orelse nixTreeSitterSourcesRoot(b));
        }
        self.generated.path = self.paths.bundle_root;
    }
};

/// Nix places its pinned source checkouts under a private build directory.
/// Other builds leave the directory absent and fetch the manifest commits.
fn nixTreeSitterSourcesRoot(b: *std.Build) ?[]const u8 {
    const root = b.pathFromRoot(nix_tree_sitter_sources_dir);
    return if (pathExists(b, root)) root else null;
}

fn pinnedSource(step: *Step, root: ?[]const u8, name: []const u8) !?[]const u8 {
    const sources_root = root orelse return null;
    const b = step.owner;
    const path = b.pathJoin(&.{ sources_root, name });
    if (!pathExists(b, path)) return step.fail("pinned tree-sitter source is missing: {s}", .{path});
    return path;
}

fn validateTreeSitterManifest(manifest: TreeSitterManifest) void {
    if (manifest.schema != 1) @panic("unsupported tree-sitter language manifest schema.");
    if (!isCommitHash(manifest.runtime.commit)) @panic("tree-sitter runtime commit must be a 40-character hash.");
    if (manifest.languages.len == 0) @panic("tree-sitter language manifest must list at least one language.");
    for (manifest.languages) |language| {
        if (language.name.len == 0 or language.display_name.len == 0) {
            @panic("tree-sitter language manifest has an empty language name.");
        }
        if (language.repo.len == 0 or !isCommitHash(language.commit)) {
            std.debug.panic("tree-sitter language manifest has an invalid commit: {s}", .{language.name});
        }
        if (language.aliases.len == 0 or language.files.len == 0) {
            std.debug.panic("tree-sitter language manifest entry is incomplete: {s}", .{language.name});
        }
        for (language.files) |file| {
            rejectUnsafeManifestPath(file.from, "tree-sitter source path");
            rejectUnsafeManifestPath(file.to, "tree-sitter destination path");
        }
    }
}

fn isCommitHash(value: []const u8) bool {
    if (value.len != 40) return false;
    for (value) |byte| {
        if (!std.ascii.isHex(byte)) return false;
    }
    return true;
}

fn rejectUnsafeManifestPath(value: []const u8, label: []const u8) void {
    if (value.len == 0 or std.fs.path.isAbsolute(value)) {
        std.debug.panic("{s} must be relative and non-empty: {s}", .{ label, value });
    }
    var parts = std.mem.tokenizeAny(u8, value, "/\\");
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, "..")) {
            std.debug.panic("{s} must stay inside its root: {s}", .{ label, value });
        }
    }
}

fn treeSitterManifestHash(b: *std.Build, manifest_text: []const u8) []const u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(manifest_text, &digest, .{});
    var out = b.allocator.alloc(u8, tree_sitter_manifest_hash_bytes * 2) catch @panic("OOM");
    for (digest[0..tree_sitter_manifest_hash_bytes], 0..) |byte, index| {
        out[index * 2] = hexDigit(byte >> 4);
        out[index * 2 + 1] = hexDigit(byte & 0x0f);
    }
    return out;
}

fn hexDigit(value: u8) u8 {
    return if (value < 10) '0' + value else 'a' + (value - 10);
}

fn treeSitterCacheRoot(b: *std.Build) []const u8 {
    const home = nonEmptyEnv(b, "HOME") orelse nonEmptyEnv(b, "USERPROFILE") orelse
        @panic("HOME is required to prepare the tree-sitter cache.");
    return b.pathJoin(&.{ home, cache_subdir });
}

fn nonEmptyEnv(b: *std.Build, name: []const u8) ?[]const u8 {
    const value = b.graph.environ_map.get(name) orelse return null;
    return if (value.len == 0) null else value;
}

fn treeSitterBundleComplete(b: *std.Build, manifest: TreeSitterManifest, bundle: Paths) bool {
    const cwd = std.Io.Dir.cwd();
    const marker_text = cwd.readFileAlloc(b.graph.io, b.fmt("{s}/complete.json", .{bundle.bundle_root}), b.allocator, .limited(4096)) catch return false;
    defer b.allocator.free(marker_text);
    const marker = std.json.parseFromSlice(struct {
        schema: u32,
        manifest_hash: []const u8,
        runtime_commit: []const u8,
    }, b.allocator, marker_text, .{}) catch return false;
    defer marker.deinit();
    if (marker.value.schema != 1 or
        !std.mem.eql(u8, marker.value.manifest_hash, bundle.manifest_hash) or
        !std.mem.eql(u8, marker.value.runtime_commit, manifest.runtime.commit)) return false;
    cwd.access(b.graph.io, b.fmt("{s}/lib/src/lib.c", .{bundle.runtime_source_root}), .{}) catch return false;
    cwd.access(b.graph.io, b.fmt("{s}/lib/include/tree_sitter/api.h", .{bundle.runtime_source_root}), .{}) catch return false;
    if (pathExists(b, b.fmt("{s}/.git", .{bundle.runtime_source_root}))) return false;
    if (pathExists(b, b.fmt("{s}/sources", .{bundle.bundle_root}))) return false;
    for (manifest.languages) |language| {
        for (language.files) |file| {
            if (!isBundleSource(file.to)) continue;
            cwd.access(b.graph.io, b.fmt("{s}/{s}/{s}", .{ bundle.generated_root, language.name, file.to }), .{}) catch return false;
            for (tree_sitter_support_headers) |header| {
                const dest_dir = std.fs.path.dirname(file.to) orelse ".";
                cwd.access(
                    b.graph.io,
                    b.fmt("{s}/{s}/{s}/tree_sitter/{s}", .{ bundle.generated_root, language.name, dest_dir, header }),
                    .{},
                ) catch return false;
            }
        }
    }
    return true;
}

const tree_sitter_support_headers = [_][]const u8{ "parser.h", "alloc.h", "array.h" };

fn buildTreeSitterBundle(step: *Step, manifest: TreeSitterManifest, bundle: Paths, sources_root: ?[]const u8) !void {
    const b = step.owner;
    const io = b.graph.io;
    const cwd = std.Io.Dir.cwd();
    const bundles_root = b.pathJoin(&.{ bundle.cache_root, "bundles" });
    try cwd.createDirPath(io, bundles_root);
    var random: [16]u8 = undefined;
    io.random(&random);
    const building_root = b.pathJoin(&.{ bundles_root, b.fmt(".building-{s}-{s}", .{ bundle.manifest_hash, std.fmt.bytesToHex(random, .lower) }) });
    try cwd.createDir(io, building_root, .default_dir);
    defer cwd.deleteTree(io, building_root) catch |err| {
        std.debug.print("failed to remove tree-sitter working directory {s}: {}\n", .{ building_root, err });
    };

    const runtime_checkout = (try pinnedSource(step, sources_root, "runtime")) orelse blk: {
        const checkout = b.pathJoin(&.{ building_root, "sources", "tree-sitter-runtime" });
        try checkoutCommit(step, manifest.runtime.repo, manifest.runtime.commit, checkout);
        break :blk checkout;
    };
    try copyTree(step, b.pathJoin(&.{ runtime_checkout, "lib", "src" }), b.pathJoin(&.{ building_root, "runtime", "source", "lib", "src" }));
    try copyTree(step, b.pathJoin(&.{ runtime_checkout, "lib", "include" }), b.pathJoin(&.{ building_root, "runtime", "source", "lib", "include" }));

    for (manifest.languages) |language| {
        const checkout = (try pinnedSource(step, sources_root, language.name)) orelse blk: {
            const destination = b.pathJoin(&.{ building_root, "sources", language.name });
            try checkoutCommit(step, language.repo, language.commit, destination);
            break :blk destination;
        };
        var first_support_dir: ?[]const u8 = null;
        for (language.files) |file| {
            if (!isBundleSource(file.to)) continue;
            const source = b.pathJoin(&.{ checkout, file.from });
            const dest = b.pathJoin(&.{ building_root, "generated", language.name, file.to });
            try copyFile(step, source, dest);
            const source_dir = std.fs.path.dirname(file.from) orelse ".";
            const support_dir = b.pathJoin(&.{ checkout, source_dir, "tree_sitter" });
            if (pathExists(b, b.pathJoin(&.{ support_dir, "parser.h" }))) {
                if (first_support_dir == null) first_support_dir = support_dir;
                try copySupportHeaders(step, support_dir, b.pathJoin(&.{ building_root, "generated", language.name, std.fs.path.dirname(file.to) orelse "." }));
            }
        }
        if (first_support_dir) |support_dir| {
            for (language.files) |file| {
                if (!std.mem.startsWith(u8, file.to, "common/")) continue;
                try copySupportHeaders(step, support_dir, b.pathJoin(&.{ building_root, "generated", language.name, std.fs.path.dirname(file.to) orelse "." }));
            }
        }
    }
    try cwd.deleteTree(io, b.pathJoin(&.{ building_root, "sources" }));
    try cwd.writeFile(io, .{
        .sub_path = b.pathJoin(&.{ building_root, "complete.json" }),
        .data = b.fmt("{{\"schema\":1,\"manifest_hash\":\"{s}\",\"runtime_commit\":\"{s}\"}}\n", .{ bundle.manifest_hash, manifest.runtime.commit }),
    });
    const staged = Paths{
        .manifest_hash = bundle.manifest_hash,
        .cache_root = bundle.cache_root,
        .bundle_root = building_root,
        .runtime_source_root = b.pathJoin(&.{ building_root, "runtime", "source" }),
        .generated_root = b.pathJoin(&.{ building_root, "generated" }),
    };
    if (!treeSitterBundleComplete(b, manifest, staged)) return step.fail("prepared tree-sitter bundle is incomplete: {s}", .{building_root});
    // The manifest lock covers validation and publication. Readers receive only
    // a complete directory and keep the cache lease while compiling its files.
    try cwd.deleteTree(io, bundle.bundle_root);
    try cwd.rename(building_root, cwd, bundle.bundle_root, io);
}

fn copySupportHeaders(step: *Step, source_dir: []const u8, dest_dir: []const u8) !void {
    const b = step.owner;
    for (tree_sitter_support_headers) |header| {
        try copyFile(step, b.pathJoin(&.{ source_dir, header }), b.pathJoin(&.{ dest_dir, "tree_sitter", header }));
    }
}

fn copyTree(step: *Step, source_dir: []const u8, dest_dir: []const u8) anyerror!void {
    const b = step.owner;
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(b.graph.io, dest_dir);
    var dir = cwd.openDir(b.graph.io, source_dir, .{ .iterate = true }) catch |err|
        return step.fail("failed to open tree-sitter source directory {s}: {}", .{ source_dir, err });
    defer dir.close(b.graph.io);
    var iterator = dir.iterate();
    while (try iterator.next(b.graph.io)) |entry| {
        const source = b.pathJoin(&.{ source_dir, entry.name });
        const dest = b.pathJoin(&.{ dest_dir, entry.name });
        switch (entry.kind) {
            .directory => try copyTree(step, source, dest),
            .file => try copyFile(step, source, dest),
            else => {},
        }
    }
}

fn pathExists(b: *std.Build, path: []const u8) bool {
    std.Io.Dir.cwd().access(b.graph.io, path, .{}) catch return false;
    return true;
}

fn isBundleSource(path: []const u8) bool {
    return std.mem.startsWith(u8, path, "src/") or
        std.mem.startsWith(u8, path, "common/") or
        std.mem.indexOf(u8, path, "/src/") != null;
}

fn checkoutCommit(step: *Step, repo: []const u8, commit: []const u8, dest: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(step.owner.graph.io, dest);
    try runCommand(step, dest, &.{ "git", "init", "-q" });
    try runCommand(step, dest, &.{ "git", "remote", "add", "origin", repo });
    try runCommand(step, dest, &.{ "git", "fetch", "--depth=1", "origin", commit });
    try runCommand(step, dest, &.{ "git", "checkout", "-q", "--detach", "FETCH_HEAD" });
}

fn runCommand(step: *Step, cwd_path: []const u8, argv: []const []const u8) !void {
    const b = step.owner;
    const result = try std.process.run(b.allocator, b.graph.io, .{
        .argv = argv,
        .cwd = .{ .path = cwd_path },
        .environ_map = &b.graph.environ_map,
        .stdout_limit = .limited(tree_sitter_build_stdout_limit),
        .stderr_limit = .limited(tree_sitter_build_stderr_limit),
    });
    defer b.allocator.free(result.stdout);
    defer b.allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return step.fail("{s} failed in {s} (exit {d}):\n{s}{s}", .{ argv[0], cwd_path, code, result.stdout, result.stderr }),
        else => return step.fail("{s} ended unexpectedly: {}\n{s}{s}", .{ argv[0], result.term, result.stdout, result.stderr }),
    }
}

fn copyFile(step: *Step, source: []const u8, dest: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    cwd.copyFile(source, cwd, dest, step.owner.graph.io, .{ .make_path = true }) catch |err|
        return step.fail("failed to copy tree-sitter source {s} to {s}: {}", .{ source, dest, err });
}
