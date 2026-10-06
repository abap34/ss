const std = @import("std");
const compat = @import("compat.zig");
const metadata = @import("tree_sitter_manifest.zig");
const TreeSitterManifest = metadata.TreeSitterManifest;
const Step = std.Build.Step;
const Module = std.Build.Module;

pub const cache_subdir = ".ss/cache/tree-sitter";

pub const Bundle = struct {
    manifest_hash: []const u8,
    root: std.Build.LazyPath,
    step: *Step,
    c_sources: []const []const u8,
    languages: []const TreeSitterManifest.Language,
};

pub fn create(b: *std.Build) Bundle {
    const manifest_path = "third_party/tree-sitter-languages/manifest.json";
    const manifest_text = compat.readFile(b, manifest_path, .limited(512 * 1024)) catch
        @panic("third_party/tree-sitter-languages/manifest.json is missing.");
    const manifest = metadata.parse(b.allocator, manifest_text);
    const manifest_hash = metadata.hash(b.allocator, manifest_text);
    const cache_root = compat.pathFromRoot(b, b.option([]const u8, "tree-sitter-cache", "Shared tree-sitter source cache directory") orelse treeSitterCacheRoot(b));
    const sources = b.option([]const u8, "tree-sitter-sources", "Directory of pinned runtime and language source checkouts") orelse nixTreeSitterSourcesRoot(b);
    const module = b.createModule(.{
        .root_source_file = b.path("build/tree_sitter_prepare.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
        .link_libc = true,
    });
    module.addImport("tree_sitter_cache", b.createModule(.{
        .root_source_file = b.path("src/utils/tree_sitter_cache.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
        .link_libc = true,
    }));
    const executable = b.addExecutable(.{ .name = "ss-tree-sitter-prepare", .root_module = module });
    const prepare = b.addRunArtifact(executable);
    prepare.setName("prepare tree-sitter sources");
    prepare.addFileArg(b.path(manifest_path));
    prepare.addArg(cache_root);
    const output = prepare.addOutputDirectoryArg("tree-sitter");
    if (sources) |source| prepare.addDirectoryArg(.{ .cwd_relative = compat.pathFromRoot(b, source) });
    var c_sources: std.ArrayList([]const u8) = .empty;
    for (manifest.languages) |language| {
        for (language.files) |file| {
            const basename = std.fs.path.basename(file.to);
            if (std.mem.eql(u8, basename, "parser.c") or std.mem.eql(u8, basename, "scanner.c")) {
                c_sources.append(b.allocator, b.fmt("{s}/{s}", .{ language.name, file.to })) catch @panic("OOM");
            }
        }
    }
    return .{
        .manifest_hash = manifest_hash,
        .root = output,
        .step = &prepare.step,
        .c_sources = c_sources.toOwnedSlice(b.allocator) catch @panic("OOM"),
        .languages = manifest.languages,
    };
}

fn nixTreeSitterSourcesRoot(b: *std.Build) ?[]const u8 {
    const path = ".ss-cache/nix/tree-sitter-sources";
    compat.access(b, path) catch return null;
    return path;
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

pub fn addSources(ctx: CompileOptions, module: *Module, tree_sitter: Bundle) void {
    const b = ctx.b;
    addTreeSitterIncludePaths(b, module, tree_sitter);
    addTreeSitterRuntimeSource(ctx, module, tree_sitter);
    addTreeSitterCSourceFile(ctx, module, b.path("editor/tree-sitter-ss/src/parser.c"));
    addTreeSitterCSourceFile(ctx, module, b.path("editor/tree-sitter-ss/src/scanner.c"));
    for (tree_sitter.c_sources) |source| {
        addTreeSitterCSourceFile(ctx, module, tree_sitter.root.path(b, b.fmt("generated/{s}", .{source})));
    }
    module.addIncludePath(b.path("editor/tree-sitter-ss/src"));
}

fn addTreeSitterIncludePaths(b: *std.Build, module: *Module, tree_sitter: Bundle) void {
    module.addIncludePath(tree_sitter.root.path(b, "runtime/source/lib/include"));
    module.addIncludePath(tree_sitter.root.path(b, "runtime/source/lib/src"));
}

fn addTreeSitterRuntimeSource(ctx: CompileOptions, module: *Module, tree_sitter: Bundle) void {
    addTreeSitterCSourceFile(ctx, module, tree_sitter.root.path(ctx.b, "runtime/source/lib/src/lib.c"));
}

fn addTreeSitterCSourceFile(ctx: CompileOptions, module: *Module, file: std.Build.LazyPath) void {
    module.addCSourceFile(.{
        .file = file,
        .flags = if (ctx.ubsan) &.{} else &.{"-fno-sanitize=undefined"},
    });
}

pub fn addAbiCheck(ctx: CompileOptions, tree_sitter: Bundle) *Step {
    const b = ctx.b;
    const check_mod = b.createModule(.{
        .target = ctx.target,
        .optimize = ctx.optimize,
        .link_libc = true,
    });
    addTreeSitterIncludePaths(b, check_mod, tree_sitter);
    addTreeSitterRuntimeSource(ctx, check_mod, tree_sitter);
    check_mod.addCSourceFile(.{
        .file = b.path("src/tree_sitter/abi_check.c"),
    });
    for (tree_sitter.c_sources) |source| {
        addTreeSitterCSourceFile(ctx, check_mod, tree_sitter.root.path(b, b.fmt("generated/{s}", .{source})));
    }

    const check_exe = b.addExecutable(.{
        .name = "ss-tree-sitter-abi-check",
        .root_module = check_mod,
    });
    if (!ctx.target.query.isNative()) {
        return &check_exe.step;
    }

    const run_check = b.addRunArtifact(check_exe);
    run_check.setName("tree-sitter ABI and parser check");
    if (ctx.ubsan) {
        run_check.addArg("--trace");
    }
    return &run_check.step;
}

pub const CompileOptions = struct {
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: compat.Optimize,
    ubsan: bool,
};

pub fn addOptions(b: *std.Build, options: *Step.Options, bundle: Bundle) void {
    options.addOption([]const u8, "tree_sitter_cache_subdir", cache_subdir);
    options.addOption([]const u8, "tree_sitter_manifest_hash", bundle.manifest_hash);
    const ss_query = compat.readFile(b, "editor/tree-sitter-ss/queries/highlights.scm", .limited(64 * 1024)) catch
        @panic("editor/tree-sitter-ss/queries/highlights.scm is missing.");
    options.addOption([]const u8, "ss_highlight_query", ss_query);
    for (bundle.languages) |language| {
        const path = b.fmt("third_party/tree-sitter-languages/{s}/queries/highlights.scm", .{language.name});
        const query = compat.readFile(b, path, .limited(128 * 1024)) catch
            @panic("bundled tree-sitter highlight query is missing.");
        options.addOption([]const u8, b.fmt("{s}_highlight_query", .{language.name}), query);
    }
}
