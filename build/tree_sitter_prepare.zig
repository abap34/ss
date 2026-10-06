const std = @import("std");
const cache = @import("tree_sitter_cache");
const metadata = @import("tree_sitter_manifest.zig");
const TreeSitterManifest = metadata.TreeSitterManifest;
const tree_sitter_build_stdout_limit = 64 * 1024;
const tree_sitter_build_stderr_limit = 256 * 1024;

const Context = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *std.process.Environ.Map,

    fn fmt(self: *Context, comptime format: []const u8, args: anytype) []u8 {
        return std.fmt.allocPrint(self.allocator, format, args) catch @panic("OOM");
    }
    fn pathJoin(self: *Context, parts: []const []const u8) []u8 {
        return std.fs.path.join(self.allocator, parts) catch @panic("OOM");
    }
    fn fail(_: *Context, comptime format: []const u8, args: anytype) error{PreparationFailed} {
        std.debug.print(format ++ "\n", args);
        return error.PreparationFailed;
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len != 4 and args.len != 5) return error.InvalidArguments;
    var ctx = Context{ .allocator = allocator, .io = init.io, .environ_map = init.environ_map };
    const text = try std.Io.Dir.cwd().readFileAlloc(init.io, args[1], allocator, .limited(512 * 1024));
    const manifest = metadata.parse(allocator, text);
    const manifest_hash = metadata.hash(allocator, text);
    const bundle_root = ctx.pathJoin(&.{ args[2], "bundles", manifest_hash });
    const paths = Paths{
        .manifest_hash = manifest_hash,
        .cache_root = args[2],
        .bundle_root = bundle_root,
        .runtime_source_root = ctx.pathJoin(&.{ bundle_root, "runtime", "source" }),
        .generated_root = ctx.pathJoin(&.{ bundle_root, "generated" }),
    };
    var lease = try cache.Lease.acquire(init.io, allocator, paths.cache_root);
    defer lease.deinit();
    const lock_dir = ctx.pathJoin(&.{ paths.cache_root, "locks" });
    try std.Io.Dir.cwd().createDirPath(init.io, lock_dir);
    const lock = try std.Io.Dir.cwd().createFile(init.io, ctx.pathJoin(&.{ lock_dir, ctx.fmt("{s}.lock", .{manifest_hash}) }), .{
        .read = true,
        .truncate = false,
        .lock = .exclusive,
    });
    defer lock.close(init.io);
    if (!treeSitterBundleComplete(&ctx, manifest, paths)) {
        try buildTreeSitterBundle(&ctx, manifest, paths, if (args.len == 5) args[4] else null);
    }
    // The compiler owns this build output. Shared-cache pruning is safe after
    // the helper exits, including while dependent C compilers are still running.
    try copyTree(&ctx, bundle_root, args[3]);
}

const Paths = struct {
    manifest_hash: []const u8,
    cache_root: []const u8,
    bundle_root: []const u8,
    runtime_source_root: []const u8,
    generated_root: []const u8,
};

fn pinnedSource(ctx: *Context, root: ?[]const u8, name: []const u8) !?[]const u8 {
    const sources_root = root orelse return null;
    const path = ctx.pathJoin(&.{ sources_root, name });
    if (!pathExists(ctx, path)) return ctx.fail("pinned tree-sitter source is missing: {s}", .{path});
    return path;
}

fn treeSitterBundleComplete(ctx: *Context, manifest: TreeSitterManifest, bundle: Paths) bool {
    const cwd = std.Io.Dir.cwd();
    const marker_text = cwd.readFileAlloc(ctx.io, ctx.fmt("{s}/complete.json", .{bundle.bundle_root}), ctx.allocator, .limited(4096)) catch return false;
    defer ctx.allocator.free(marker_text);
    const marker = std.json.parseFromSlice(struct {
        schema: u32,
        manifest_hash: []const u8,
        runtime_commit: []const u8,
    }, ctx.allocator, marker_text, .{}) catch return false;
    defer marker.deinit();
    if (marker.value.schema != 1 or
        !std.mem.eql(u8, marker.value.manifest_hash, bundle.manifest_hash) or
        !std.mem.eql(u8, marker.value.runtime_commit, manifest.runtime.commit)) return false;
    cwd.access(ctx.io, ctx.fmt("{s}/lib/src/lib.c", .{bundle.runtime_source_root}), .{}) catch return false;
    cwd.access(ctx.io, ctx.fmt("{s}/lib/include/tree_sitter/api.h", .{bundle.runtime_source_root}), .{}) catch return false;
    if (pathExists(ctx, ctx.fmt("{s}/.git", .{bundle.runtime_source_root}))) return false;
    if (pathExists(ctx, ctx.fmt("{s}/sources", .{bundle.bundle_root}))) return false;
    for (manifest.languages) |language| {
        for (language.files) |file| {
            if (!isBundleSource(file.to)) continue;
            cwd.access(ctx.io, ctx.fmt("{s}/{s}/{s}", .{ bundle.generated_root, language.name, file.to }), .{}) catch return false;
            for (tree_sitter_support_headers) |header| {
                const dest_dir = std.fs.path.dirname(file.to) orelse ".";
                cwd.access(
                    ctx.io,
                    ctx.fmt("{s}/{s}/{s}/tree_sitter/{s}", .{ bundle.generated_root, language.name, dest_dir, header }),
                    .{},
                ) catch return false;
            }
        }
    }
    return true;
}

const tree_sitter_support_headers = [_][]const u8{ "parser.h", "alloc.h", "array.h" };

fn buildTreeSitterBundle(ctx: *Context, manifest: TreeSitterManifest, bundle: Paths, sources_root: ?[]const u8) !void {
    const io = ctx.io;
    const cwd = std.Io.Dir.cwd();
    const bundles_root = ctx.pathJoin(&.{ bundle.cache_root, "bundles" });
    try cwd.createDirPath(io, bundles_root);
    var random: [16]u8 = undefined;
    io.random(&random);
    const building_root = ctx.pathJoin(&.{ bundles_root, ctx.fmt(".building-{s}-{s}", .{ bundle.manifest_hash, std.fmt.bytesToHex(random, .lower) }) });
    try cwd.createDir(io, building_root, .default_dir);
    defer cwd.deleteTree(io, building_root) catch |err| {
        std.debug.print("failed to remove tree-sitter working directory {s}: {}\n", .{ building_root, err });
    };

    const runtime_checkout = (try pinnedSource(ctx, sources_root, "runtime")) orelse blk: {
        const checkout = ctx.pathJoin(&.{ building_root, "sources", "tree-sitter-runtime" });
        try checkoutCommit(ctx, manifest.runtime.repo, manifest.runtime.commit, checkout);
        break :blk checkout;
    };
    try copyTree(ctx, ctx.pathJoin(&.{ runtime_checkout, "lib", "src" }), ctx.pathJoin(&.{ building_root, "runtime", "source", "lib", "src" }));
    try copyTree(ctx, ctx.pathJoin(&.{ runtime_checkout, "lib", "include" }), ctx.pathJoin(&.{ building_root, "runtime", "source", "lib", "include" }));

    for (manifest.languages) |language| {
        const checkout = (try pinnedSource(ctx, sources_root, language.name)) orelse blk: {
            const destination = ctx.pathJoin(&.{ building_root, "sources", language.name });
            try checkoutCommit(ctx, language.repo, language.commit, destination);
            break :blk destination;
        };
        var first_support_dir: ?[]const u8 = null;
        for (language.files) |file| {
            if (!isBundleSource(file.to)) continue;
            const source = ctx.pathJoin(&.{ checkout, file.from });
            const dest = ctx.pathJoin(&.{ building_root, "generated", language.name, file.to });
            try copyFile(ctx, source, dest);
            const source_dir = std.fs.path.dirname(file.from) orelse ".";
            const support_dir = ctx.pathJoin(&.{ checkout, source_dir, "tree_sitter" });
            if (pathExists(ctx, ctx.pathJoin(&.{ support_dir, "parser.h" }))) {
                if (first_support_dir == null) first_support_dir = support_dir;
                try copySupportHeaders(ctx, support_dir, ctx.pathJoin(&.{ building_root, "generated", language.name, std.fs.path.dirname(file.to) orelse "." }));
            }
        }
        if (first_support_dir) |support_dir| {
            for (language.files) |file| {
                if (!std.mem.startsWith(u8, file.to, "common/")) continue;
                try copySupportHeaders(ctx, support_dir, ctx.pathJoin(&.{ building_root, "generated", language.name, std.fs.path.dirname(file.to) orelse "." }));
            }
        }
    }
    try cwd.deleteTree(io, ctx.pathJoin(&.{ building_root, "sources" }));
    try cwd.writeFile(io, .{
        .sub_path = ctx.pathJoin(&.{ building_root, "complete.json" }),
        .data = ctx.fmt("{{\"schema\":1,\"manifest_hash\":\"{s}\",\"runtime_commit\":\"{s}\"}}\n", .{ bundle.manifest_hash, manifest.runtime.commit }),
    });
    const staged = Paths{
        .manifest_hash = bundle.manifest_hash,
        .cache_root = bundle.cache_root,
        .bundle_root = building_root,
        .runtime_source_root = ctx.pathJoin(&.{ building_root, "runtime", "source" }),
        .generated_root = ctx.pathJoin(&.{ building_root, "generated" }),
    };
    if (!treeSitterBundleComplete(ctx, manifest, staged)) return ctx.fail("prepared tree-sitter bundle is incomplete: {s}", .{building_root});
    // The manifest lock covers validation and publication. Readers receive only
    // a complete directory and keep the cache lease while copying its files.
    try cwd.deleteTree(io, bundle.bundle_root);
    try cwd.rename(building_root, cwd, bundle.bundle_root, io);
}

fn copySupportHeaders(ctx: *Context, source_dir: []const u8, dest_dir: []const u8) !void {
    for (tree_sitter_support_headers) |header| {
        try copyFile(ctx, ctx.pathJoin(&.{ source_dir, header }), ctx.pathJoin(&.{ dest_dir, "tree_sitter", header }));
    }
}

fn copyTree(ctx: *Context, source_dir: []const u8, dest_dir: []const u8) anyerror!void {
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(ctx.io, dest_dir);
    var dir = cwd.openDir(ctx.io, source_dir, .{ .iterate = true }) catch |err|
        return ctx.fail("failed to open tree-sitter source directory {s}: {}", .{ source_dir, err });
    defer dir.close(ctx.io);
    var iterator = dir.iterate();
    while (try iterator.next(ctx.io)) |entry| {
        const source = ctx.pathJoin(&.{ source_dir, entry.name });
        const dest = ctx.pathJoin(&.{ dest_dir, entry.name });
        switch (entry.kind) {
            .directory => try copyTree(ctx, source, dest),
            .file => try copyFile(ctx, source, dest),
            else => {},
        }
    }
}

fn pathExists(ctx: *Context, path: []const u8) bool {
    std.Io.Dir.cwd().access(ctx.io, path, .{}) catch return false;
    return true;
}

fn isBundleSource(path: []const u8) bool {
    return std.mem.startsWith(u8, path, "src/") or
        std.mem.startsWith(u8, path, "common/") or
        std.mem.indexOf(u8, path, "/src/") != null;
}

fn checkoutCommit(ctx: *Context, repo: []const u8, commit: []const u8, dest: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(ctx.io, dest);
    try runCommand(ctx, dest, &.{ "git", "init", "-q" });
    try runCommand(ctx, dest, &.{ "git", "remote", "add", "origin", repo });
    try runCommand(ctx, dest, &.{ "git", "fetch", "--depth=1", "origin", commit });
    try runCommand(ctx, dest, &.{ "git", "checkout", "-q", "--detach", "FETCH_HEAD" });
}

fn runCommand(ctx: *Context, cwd_path: []const u8, argv: []const []const u8) !void {
    const result = try std.process.run(ctx.allocator, ctx.io, .{
        .argv = argv,
        .cwd = .{ .path = cwd_path },
        .environ_map = ctx.environ_map,
        .stdout_limit = .limited(tree_sitter_build_stdout_limit),
        .stderr_limit = .limited(tree_sitter_build_stderr_limit),
    });
    defer ctx.allocator.free(result.stdout);
    defer ctx.allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return ctx.fail("{s} failed in {s} (exit {d}):\n{s}{s}", .{ argv[0], cwd_path, code, result.stdout, result.stderr }),
        else => return ctx.fail("{s} ended unexpectedly: {}\n{s}{s}", .{ argv[0], result.term, result.stdout, result.stderr }),
    }
}

fn copyFile(ctx: *Context, source: []const u8, dest: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    cwd.copyFile(source, cwd, dest, ctx.io, .{ .make_path = true }) catch |err|
        return ctx.fail("failed to copy tree-sitter source {s} to {s}: {}", .{ source, dest, err });
}
