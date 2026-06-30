const std = @import("std");

const Module = std.Build.Module;
const Step = std.Build.Step;
const Import = Module.Import;

const BuildContext = struct {
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    tree_sitter_ubsan: bool,
    tree_sitter_c_flags: []const []const u8,
};

const ProjectModules = struct {
    utils: *Module,
    model: *Module,
    language_type: *Module,
    ast: *Module,
    stdlib_assets: *Module,
    project: *Module,
    core: *Module,
};

const BundledHighlightQuery = struct {
    option_name: []const u8,
    path: []const u8,
};

const TreeSitterBundle = struct {
    manifest_hash: []const u8,
    runtime_language_version: u32,
    runtime_min_compatible_language_version: u32,
    cache_root: []const u8,
    bundle_root: []const u8,
    runtime_source_root: []const u8,
    generated_root: []const u8,
};

const TreeSitterCheck = struct {
    compile: *Step.Compile,
    run: ?*Step.Run,
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

const bundled_highlight_queries = [_]BundledHighlightQuery{
    .{ .option_name = "bash_highlight_query", .path = "third_party/tree-sitter-languages/bash/queries/highlights.scm" },
    .{ .option_name = "c_highlight_query", .path = "third_party/tree-sitter-languages/c/queries/highlights.scm" },
    .{ .option_name = "cpp_highlight_query", .path = "third_party/tree-sitter-languages/cpp/queries/highlights.scm" },
    .{ .option_name = "css_highlight_query", .path = "third_party/tree-sitter-languages/css/queries/highlights.scm" },
    .{ .option_name = "go_highlight_query", .path = "third_party/tree-sitter-languages/go/queries/highlights.scm" },
    .{ .option_name = "html_highlight_query", .path = "third_party/tree-sitter-languages/html/queries/highlights.scm" },
    .{ .option_name = "java_highlight_query", .path = "third_party/tree-sitter-languages/java/queries/highlights.scm" },
    .{ .option_name = "javascript_highlight_query", .path = "third_party/tree-sitter-languages/javascript/queries/highlights.scm" },
    .{ .option_name = "json_highlight_query", .path = "third_party/tree-sitter-languages/json/queries/highlights.scm" },
    .{ .option_name = "julia_highlight_query", .path = "third_party/tree-sitter-languages/julia/queries/highlights.scm" },
    .{ .option_name = "python_highlight_query", .path = "third_party/tree-sitter-languages/python/queries/highlights.scm" },
    .{ .option_name = "rust_highlight_query", .path = "third_party/tree-sitter-languages/rust/queries/highlights.scm" },
    .{ .option_name = "toml_highlight_query", .path = "third_party/tree-sitter-languages/toml/queries/highlights.scm" },
    .{ .option_name = "typescript_highlight_query", .path = "third_party/tree-sitter-languages/typescript/queries/highlights.scm" },
    .{ .option_name = "yaml_highlight_query", .path = "third_party/tree-sitter-languages/yaml/queries/highlights.scm" },
    .{ .option_name = "zig_highlight_query", .path = "third_party/tree-sitter-languages/zig/queries/highlights.scm" },
};

const generated_tree_sitter_sources = [_][]const u8{
    "bash/src/parser.c",
    "bash/src/scanner.c",
    "c/src/parser.c",
    "cpp/src/parser.c",
    "cpp/src/scanner.c",
    "css/src/parser.c",
    "css/src/scanner.c",
    "go/src/parser.c",
    "html/src/parser.c",
    "html/src/scanner.c",
    "java/src/parser.c",
    "javascript/src/parser.c",
    "javascript/src/scanner.c",
    "json/src/parser.c",
    "julia/src/parser.c",
    "julia/src/scanner.c",
    "python/src/parser.c",
    "python/src/scanner.c",
    "rust/src/parser.c",
    "rust/src/scanner.c",
    "toml/src/parser.c",
    "toml/src/scanner.c",
    "typescript/typescript/src/parser.c",
    "typescript/typescript/src/scanner.c",
    "typescript/tsx/src/parser.c",
    "typescript/tsx/src/scanner.c",
    "yaml/src/parser.c",
    "yaml/src/scanner.c",
    "zig/src/parser.c",
};

const tree_sitter_manifest_read_limit = 512 * 1024;
const tree_sitter_manifest_hash_bytes = 12;
const tree_sitter_build_stdout_limit = 64 * 1024;
const tree_sitter_build_stderr_limit = 256 * 1024;

const tree_sitter_c_flags_without_ubsan = [_][]const u8{
    // Upstream tree-sitter runtime and generated grammar C sources are checked
    // by parser execution. Use -Dtree-sitter-ubsan=true for sanitizer diagnosis.
    "-fno-sanitize=undefined",
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const tree_sitter_ubsan = b.option(bool, "tree-sitter-ubsan", "Compile upstream tree-sitter C sources with UBSan instrumentation") orelse false;
    const tree_sitter_c_flags: []const []const u8 = if (tree_sitter_ubsan) &.{} else &tree_sitter_c_flags_without_ubsan;
    const ctx = BuildContext{
        .b = b,
        .target = target,
        .optimize = optimize,
        .tree_sitter_ubsan = tree_sitter_ubsan,
        .tree_sitter_c_flags = tree_sitter_c_flags,
    };

    const release_version = readReleaseVersion(b) catch @panic("release/VERSION must contain the release version.");
    const default_version = b.fmt("{s}-dev", .{release_version});
    const version = b.option([]const u8, "version", "Version string reported by `ss --version`") orelse default_version;
    const commit = b.option([]const u8, "commit", "Source commit reported by `ss --version`") orelse detectGitCommit(b) orelse "unknown";
    const uncommitted_changes = detectUncommittedChanges(b);
    const source_stdlib_dir = b.pathFromRoot("stdlib");
    const installed_stdlib_dir = b.pathJoin(&.{ b.install_path, "share", "ss", "stdlib" });
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", version);
    build_options.addOption([]const u8, "commit", commit);
    build_options.addOption([]const u8, "uncommitted_changes", uncommitted_changes);
    build_options.addOption([]const u8, "source_stdlib_dir", source_stdlib_dir);
    build_options.addOption([]const u8, "installed_stdlib_dir", installed_stdlib_dir);
    const ss_highlight_query = b.build_root.handle.readFileAlloc(b.graph.io, "editor/tree-sitter-ss/queries/highlights.scm", b.allocator, .limited(64 * 1024)) catch
        @panic("editor/tree-sitter-ss/queries/highlights.scm is missing.");
    build_options.addOption([]const u8, "ss_highlight_query", ss_highlight_query);
    for (bundled_highlight_queries) |query| {
        const source = b.build_root.handle.readFileAlloc(b.graph.io, query.path, b.allocator, .limited(128 * 1024)) catch
            @panic("bundled tree-sitter highlight query is missing.");
        build_options.addOption([]const u8, query.option_name, source);
    }

    const md4c_src = "third_party/md4c/src";
    b.build_root.handle.access(b.graph.io, md4c_src ++ "/md4c.c", .{}) catch
        @panic("MD4C sources are missing; run `scripts/setup-md4c.sh` before `zig build`.");
    addPdfPkgConfigPath(b);
    const tree_sitter = prepareTreeSitterBundle(b);
    build_options.addOption([]const u8, "tree_sitter_manifest_hash", tree_sitter.manifest_hash);
    build_options.addOption(u32, "tree_sitter_language_version", tree_sitter.runtime_language_version);
    build_options.addOption(u32, "tree_sitter_min_compatible_language_version", tree_sitter.runtime_min_compatible_language_version);
    build_options.addOption([]const u8, "tree_sitter_cache_root", tree_sitter.cache_root);
    build_options.addOption([]const u8, "tree_sitter_bundle_root", tree_sitter.bundle_root);

    const modules = createProjectModules(ctx, md4c_src, b.path(md4c_src), build_options, tree_sitter);
    const tree_sitter_abi_check = addTreeSitterAbiCheck(ctx, tree_sitter);
    const tree_sitter_check_step = b.step("tree-sitter-check", "Check bundled tree-sitter runtime and parsers");
    dependOnTreeSitterCheck(tree_sitter_check_step, tree_sitter_abi_check);
    const exe_mod = createCliModule(ctx, modules, build_options, tree_sitter);
    const exe = b.addExecutable(.{
        .name = "ss",
        .root_module = exe_mod,
    });
    dependOnTreeSitterCheck(&exe.step, tree_sitter_abi_check);
    b.installArtifact(exe);
    b.installDirectory(.{
        .source_dir = b.path("stdlib"),
        .install_dir = .prefix,
        .install_subdir = "share/ss/stdlib",
        .include_extensions = &.{".ss"},
    });

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the ss CLI");
    run_step.dependOn(&run_cmd.step);

    addTestStep(ctx, modules, build_options, exe, tree_sitter_abi_check, tree_sitter);
}

fn createProjectModules(ctx: BuildContext, md4c_src: []const u8, md4c_include: std.Build.LazyPath, build_options: *Step.Options, tree_sitter: TreeSitterBundle) ProjectModules {
    const utils_mod = createModule(ctx, "src/utils/root.zig", &.{}, null);
    const model_mod = createModule(ctx, "src/core/model.zig", &.{}, null);
    const language_type_mod = createModule(ctx, "src/language/type.zig", &.{
        import("model", model_mod),
    }, null);
    const ast_mod = createModule(ctx, "src/ast.zig", &.{
        import("model", model_mod),
        import("language_type", language_type_mod),
    }, null);
    const stdlib_assets_mod = createModule(ctx, "stdlib/embed.zig", &.{}, null);
    const project_mod = createModule(ctx, "src/project.zig", &.{
        import("utils", utils_mod),
    }, true);
    const core_mod = createModule(ctx, "src/core.zig", &.{
        import("utils", utils_mod),
        import("ast", ast_mod),
        import("model", model_mod),
        import("language_type", language_type_mod),
    }, true);
    core_mod.addOptions("build_options", build_options);
    core_mod.addIncludePath(md4c_include);
    core_mod.addCSourceFiles(.{
        .root = ctx.b.path(md4c_src),
        .files = &.{"md4c.c"},
    });
    addNativePdfBackend(ctx, core_mod, tree_sitter);

    return .{
        .utils = utils_mod,
        .model = model_mod,
        .language_type = language_type_mod,
        .ast = ast_mod,
        .stdlib_assets = stdlib_assets_mod,
        .project = project_mod,
        .core = core_mod,
    };
}

fn createCliModule(ctx: BuildContext, modules: ProjectModules, build_options: *Step.Options, tree_sitter: TreeSitterBundle) *Module {
    const module = createCommonModule(ctx, "src/main.zig", modules, true);
    module.addOptions("build_options", build_options);
    addNativePdfHeadersAndLibraries(ctx.b, module, tree_sitter);
    return module;
}

fn addTestStep(
    ctx: BuildContext,
    modules: ProjectModules,
    build_options: *Step.Options,
    exe: *Step.Compile,
    tree_sitter_abi_check: TreeSitterCheck,
    tree_sitter: TreeSitterBundle,
) void {
    const b = ctx.b;
    const test_step = b.step("test", "Run ss test targets");
    dependOnTreeSitterCheck(test_step, tree_sitter_abi_check);

    addTestModule(b, test_step, modules.core);

    const syntax_mod = createCommonTestModule(ctx, test_step, "src/syntax.zig", modules, true);
    const main_tests_mod = createCliModule(ctx, modules, build_options, tree_sitter);
    addTestModule(b, test_step, main_tests_mod);
    addModuleTest(ctx, test_step, "tests/syntax/parser/spec_tests.zig", &.{
        import("core", modules.core),
        import("utils", modules.utils),
        import("ast", modules.ast),
        import("model", modules.model),
        import("language_type", modules.language_type),
        import("syntax", syntax_mod),
    }, true);
    addModuleTest(ctx, test_step, "tests/language/type/spec_tests.zig", &.{
        import("model", modules.model),
        import("language_type", modules.language_type),
    }, null);
    const type_defs_mod = createModule(ctx, "src/language/type_defs.zig", &.{}, null);
    addModuleTest(ctx, test_step, "tests/language/type/defs_spec_tests.zig", &.{
        import("type_defs", type_defs_mod),
    }, null);

    const registry_mod = createModule(ctx, "src/language/registry.zig", &.{
        import("core", modules.core),
        import("language_type", modules.language_type),
    }, null);
    addModuleTest(ctx, test_step, "tests/language/registry/spec_tests.zig", &.{
        import("core", modules.core),
        import("model", modules.model),
        import("language_type", modules.language_type),
        import("registry", registry_mod),
    }, true);
    addModuleTest(ctx, test_step, "tests/core/ir/spec_tests.zig", &.{
        import("core", modules.core),
        import("utils", modules.utils),
        import("ast", modules.ast),
        import("model", modules.model),
        import("language_type", modules.language_type),
    }, true);
    addModuleTest(ctx, test_step, "tests/core/markdown/spec_tests.zig", &.{
        import("core", modules.core),
    }, true);
    addModuleTest(ctx, test_step, "tests/layout/graph/spec_tests.zig", &.{
        import("core", modules.core),
        import("utils", modules.utils),
        import("ast", modules.ast),
        import("model", modules.model),
        import("language_type", modules.language_type),
    }, true);
    addModuleTest(ctx, test_step, "tests/utils/fs/spec_tests.zig", &.{
        import("utils", modules.utils),
    }, true);
    addModuleTest(ctx, test_step, "tests/project/config/spec_tests.zig", &.{
        import("project", modules.project),
        import("utils", modules.utils),
    }, null);
    const compiler_mod = createCommonModule(ctx, "src/compiler.zig", modules, true);
    const lsp_scope_mod = createModule(ctx, "src/lsp/scope.zig", &.{
        import("utils", modules.utils),
    }, true);
    addModuleTest(ctx, test_step, "tests/lsp/scope/spec_tests.zig", &.{
        import("lsp_scope", lsp_scope_mod),
    }, true);
    addModuleTest(ctx, test_step, "tests/lsp/completion/spec_tests.zig", &.{
        import("compiler", compiler_mod),
    }, true);
    const watch_mod = createCommonModule(ctx, "src/watch.zig", modules, true);
    addNativePdfHeadersAndLibraries(b, watch_mod, tree_sitter);
    addModuleTest(ctx, test_step, "tests/watch/fingerprint/spec_tests.zig", &.{
        import("watch", watch_mod),
    }, true);
    const render_pdf_spec_mod = createModule(ctx, "tests/render/pdf/spec_tests.zig", &.{}, true);
    addNativePdfBackend(ctx, render_pdf_spec_mod, tree_sitter);
    addTestModule(b, test_step, render_pdf_spec_mod);
    const render_wrap_mod = createModule(ctx, "src/render/wrap.zig", &.{}, null);
    addModuleTest(ctx, test_step, "tests/render/pdf/native_wrap_spec_tests.zig", &.{
        import("render_wrap", render_wrap_mod),
    }, null);

    const compiler_semantics_support_mod = createModule(ctx, "tests/compiler/semantics/support.zig", &.{
        import("utils", modules.utils),
        import("compiler", compiler_mod),
    }, true);
    addModuleTest(ctx, test_step, "tests/compiler/semantics/spec_tests.zig", &.{
        import("compiler_semantics", compiler_semantics_support_mod),
    }, true);

    addNodeSpecTests(b, test_step, exe);
    addSmokeChecks(b, test_step, exe);
}

fn createModule(
    ctx: BuildContext,
    root_source_file: []const u8,
    imports: []const Import,
    link_libc: ?bool,
) *Module {
    return ctx.b.createModule(.{
        .root_source_file = ctx.b.path(root_source_file),
        .target = ctx.target,
        .optimize = ctx.optimize,
        .imports = imports,
        .link_libc = link_libc,
    });
}

fn createCommonModule(ctx: BuildContext, root_source_file: []const u8, modules: ProjectModules, link_libc: ?bool) *Module {
    return createModule(ctx, root_source_file, &.{
        import("core", modules.core),
        import("utils", modules.utils),
        import("ast", modules.ast),
        import("model", modules.model),
        import("language_type", modules.language_type),
        import("stdlib_assets", modules.stdlib_assets),
    }, link_libc);
}

fn import(name: []const u8, module: *Module) Import {
    return .{ .name = name, .module = module };
}

fn addModuleTest(
    ctx: BuildContext,
    test_step: *Step,
    root_source_file: []const u8,
    imports: []const Import,
    link_libc: ?bool,
) void {
    _ = createTestModule(ctx, test_step, root_source_file, imports, link_libc);
}

fn createCommonTestModule(
    ctx: BuildContext,
    test_step: *Step,
    root_source_file: []const u8,
    modules: ProjectModules,
    link_libc: ?bool,
) *Module {
    const test_mod = createCommonModule(ctx, root_source_file, modules, link_libc);
    addTestModule(ctx.b, test_step, test_mod);
    return test_mod;
}

fn createTestModule(
    ctx: BuildContext,
    test_step: *Step,
    root_source_file: []const u8,
    imports: []const Import,
    link_libc: ?bool,
) *Module {
    const test_mod = createModule(ctx, root_source_file, imports, link_libc);
    addTestModule(ctx.b, test_step, test_mod);
    return test_mod;
}

fn addTestModule(b: *std.Build, test_step: *Step, module: *Module) void {
    const test_artifact = b.addTest(.{ .root_module = module });
    test_step.dependOn(&b.addRunArtifact(test_artifact).step);
}

fn addNodeSpecTests(b: *std.Build, test_step: *Step, exe: *Step.Compile) void {
    const node_spec_files = [_][]const u8{
        "tests/runtime/cli_diagnostics_runtime_spec.mjs",
        "tests/runtime/debug_runtime_spec.mjs",
        "tests/runtime/doctor_runtime_spec.mjs",
        "tests/runtime/layout/measurement_spec.mjs",
        "tests/runtime/lsp_completion_runtime_spec.mjs",
        "tests/runtime/lsp_editor_runtime_spec.mjs",
        "tests/runtime/render_cache_runtime_spec.mjs",
        "tests/runtime/render_diagnostics_runtime_spec.mjs",
    };

    for (node_spec_files) |path| {
        const node_spec = b.addSystemCommand(&.{"node"});
        node_spec.setName(b.fmt("node {s}", .{path}));
        node_spec.addFileArg(b.path(path));
        node_spec.addFileArg(exe.getEmittedBin());
        node_spec.setCwd(b.path("."));
        node_spec.stdio = .inherit;
        test_step.dependOn(&node_spec.step);
    }
}

fn addSmokeChecks(b: *std.Build, test_step: *Step, exe: *Step.Compile) void {
    const smoke_check_files = [_][]const u8{
        "stdlib/core/classes.ss",
        "stdlib/core/components.ss",
        "stdlib/core/generated.ss",
        "stdlib/core/layout.ss",
        "stdlib/core/objects.ss",
        "stdlib/core/render.ss",
        "stdlib/core/selectors.ss",
        "stdlib/core/utils.ss",
        "stdlib/themes/academic.ss",
        "stdlib/themes/base.ss",
        "stdlib/themes/default.ss",
        "stdlib/themes/pop.ss",
    };

    for (smoke_check_files) |path| {
        const smoke_check = b.addRunArtifact(exe);
        smoke_check.addArgs(&.{ "check", path });
        test_step.dependOn(&smoke_check.step);
    }
}

fn addPdfPkgConfigPath(b: *std.Build) void {
    const pdf_pkg_config_path = b.path("src/render/pdf").getPath(b);
    const pkg_config_path = if (b.graph.environ_map.get("PKG_CONFIG_PATH")) |path|
        b.fmt("{s}{c}{s}", .{ pdf_pkg_config_path, std.fs.path.delimiter, path })
    else
        pdf_pkg_config_path;
    b.graph.environ_map.put("PKG_CONFIG_PATH", pkg_config_path) catch @panic("OOM");
}

fn addNativePdfBackend(ctx: BuildContext, module: *Module, tree_sitter: TreeSitterBundle) void {
    const b = ctx.b;
    addNativePdfHeadersAndLibraries(b, module, tree_sitter);
    addTreeSitterRuntimeSource(ctx, module, tree_sitter);
    module.addCSourceFile(.{
        .file = b.path("src/render/pdf/pdf.c"),
    });
    addTreeSitterCSourceFile(ctx, module, b.path("editor/tree-sitter-ss/src/parser.c"));
    for (generated_tree_sitter_sources) |source| {
        addTreeSitterCSourceFile(ctx, module, cwdPath(b, b.fmt("{s}/{s}", .{ tree_sitter.generated_root, source })));
    }
    module.addIncludePath(b.path("editor/tree-sitter-ss/src"));
}

fn prepareTreeSitterBundle(b: *std.Build) TreeSitterBundle {
    std.debug.print("preparing tree-sitter bundle...\n", .{});
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
    const cache_root = treeSitterCacheRoot(b);
    const bundle_root = b.pathJoin(&.{ cache_root, "bundles", manifest_hash });
    const runtime_source_root = b.pathJoin(&.{ bundle_root, "runtime", "source" });
    const generated_root = b.pathJoin(&.{ bundle_root, "generated" });
    const bundle = TreeSitterBundle{
        .manifest_hash = manifest_hash,
        .runtime_language_version = 0,
        .runtime_min_compatible_language_version = 0,
        .cache_root = cache_root,
        .bundle_root = bundle_root,
        .runtime_source_root = runtime_source_root,
        .generated_root = generated_root,
    };

    if (!treeSitterBundleComplete(b, manifest, bundle)) {
        buildTreeSitterBundle(b, manifest, bundle);
    }

    validateTreeSitterBundle(b, bundle);
    const runtime_language_version = readTreeSitterRuntimeDefine(
        b,
        bundle,
        "TREE_SITTER_LANGUAGE_VERSION",
    );
    const runtime_min_compatible_language_version = readTreeSitterRuntimeDefine(
        b,
        bundle,
        "TREE_SITTER_MIN_COMPATIBLE_LANGUAGE_VERSION",
    );
    if (runtime_min_compatible_language_version > runtime_language_version) {
        std.debug.panic(
            "tree-sitter runtime ABI range is invalid: {d}..{d}",
            .{ runtime_min_compatible_language_version, runtime_language_version },
        );
    }

    return .{
        .manifest_hash = bundle.manifest_hash,
        .runtime_language_version = runtime_language_version,
        .runtime_min_compatible_language_version = runtime_min_compatible_language_version,
        .cache_root = bundle.cache_root,
        .bundle_root = bundle.bundle_root,
        .runtime_source_root = bundle.runtime_source_root,
        .generated_root = bundle.generated_root,
    };
}

fn validateTreeSitterBundle(b: *std.Build, tree_sitter: TreeSitterBundle) void {
    const cwd = std.Io.Dir.cwd();
    cwd.access(b.graph.io, tree_sitter.runtime_source_root, .{}) catch
        std.debug.panic("tree-sitter runtime source directory is missing: {s}", .{tree_sitter.runtime_source_root});
    cwd.access(b.graph.io, b.fmt("{s}/lib/src/lib.c", .{tree_sitter.runtime_source_root}), .{}) catch
        std.debug.panic("tree-sitter runtime source is missing: {s}/lib/src/lib.c", .{tree_sitter.runtime_source_root});
    for (generated_tree_sitter_sources) |source| {
        cwd.access(b.graph.io, b.fmt("{s}/{s}", .{ tree_sitter.generated_root, source }), .{}) catch
            std.debug.panic("generated tree-sitter parser source is missing after preparation: {s}/{s}", .{ tree_sitter.generated_root, source });
    }
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
    const home = b.graph.environ_map.get("HOME") orelse
        b.graph.environ_map.get("USERPROFILE") orelse
        @panic("HOME is required to prepare the tree-sitter cache.");
    return b.pathJoin(&.{ home, ".ss", "cache", "tree-sitter" });
}

fn treeSitterBundleComplete(b: *std.Build, manifest: TreeSitterManifest, bundle: TreeSitterBundle) bool {
    const cwd = std.Io.Dir.cwd();
    cwd.access(b.graph.io, b.fmt("{s}/complete.json", .{bundle.bundle_root}), .{}) catch return false;
    cwd.access(b.graph.io, b.fmt("{s}/lib/src/lib.c", .{bundle.runtime_source_root}), .{}) catch return false;
    cwd.access(b.graph.io, b.fmt("{s}/lib/include/tree_sitter/api.h", .{bundle.runtime_source_root}), .{}) catch return false;
    if (pathExists(b, b.fmt("{s}/.git", .{bundle.runtime_source_root}))) return false;
    if (pathExists(b, b.fmt("{s}/sources", .{bundle.bundle_root}))) return false;
    for (manifest.languages) |language| {
        for (language.files) |file| {
            if (!isTreeSitterBundleSource(file.to)) continue;
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

fn buildTreeSitterBundle(b: *std.Build, manifest: TreeSitterManifest, bundle: TreeSitterBundle) void {
    const cwd = std.Io.Dir.cwd();
    const building_root = b.pathJoin(&.{ bundle.cache_root, "bundles", b.fmt(".building-{s}", .{bundle.manifest_hash}) });
    deleteTreeIfExists(b, building_root);
    cwd.createDirPath(b.graph.io, building_root) catch |err|
        std.debug.panic("failed to create tree-sitter build directory {s}: {}", .{ building_root, err });

    const runtime_checkout = b.pathJoin(&.{ building_root, "sources", "tree-sitter-runtime" });
    std.debug.print("sync tree-sitter runtime {s}\n", .{manifest.runtime.commit});
    checkoutCommit(b, manifest.runtime.repo, manifest.runtime.commit, runtime_checkout);
    copyTreeSitterRuntime(b, runtime_checkout, b.pathJoin(&.{ building_root, "runtime", "source" }));

    for (manifest.languages) |language| {
        std.debug.print("sync {s} {s}\n", .{ language.name, language.commit });
        const checkout = b.pathJoin(&.{ building_root, "sources", language.name });
        checkoutCommit(b, language.repo, language.commit, checkout);
        var first_support_dir: ?[]const u8 = null;
        for (language.files) |file| {
            if (!isTreeSitterBundleSource(file.to)) continue;
            const source = b.pathJoin(&.{ checkout, file.from });
            const dest = b.pathJoin(&.{ building_root, "generated", language.name, file.to });
            copyFile(b, source, dest);
            const source_dir = std.fs.path.dirname(file.from) orelse ".";
            const support_dir = b.pathJoin(&.{ checkout, source_dir, "tree_sitter" });
            if (pathExists(b, b.pathJoin(&.{ support_dir, "parser.h" }))) {
                if (first_support_dir == null) first_support_dir = support_dir;
                copyTreeSitterSupportHeaders(b, support_dir, b.pathJoin(&.{ building_root, "generated", language.name, std.fs.path.dirname(file.to) orelse "." }));
            }
        }
        if (first_support_dir) |support_dir| {
            for (language.files) |file| {
                if (!std.mem.startsWith(u8, file.to, "common/")) continue;
                copyTreeSitterSupportHeaders(b, support_dir, b.pathJoin(&.{ building_root, "generated", language.name, std.fs.path.dirname(file.to) orelse "." }));
            }
        }
    }

    deleteTreeIfExists(b, b.pathJoin(&.{ building_root, "sources" }));
    const marker = b.fmt(
        "{{\"schema\":1,\"manifest_hash\":\"{s}\",\"runtime_commit\":\"{s}\"}}\n",
        .{ bundle.manifest_hash, manifest.runtime.commit },
    );
    cwd.writeFile(b.graph.io, .{
        .sub_path = b.pathJoin(&.{ building_root, "complete.json" }),
        .data = marker,
        .flags = .{ .truncate = true },
    }) catch |err| std.debug.panic("failed to write tree-sitter bundle marker: {}", .{err});

    cwd.createDirPath(b.graph.io, b.pathJoin(&.{ bundle.cache_root, "bundles" })) catch |err|
        std.debug.panic("failed to create tree-sitter bundle directory: {}", .{err});
    if (!treeSitterBundleComplete(b, manifest, bundle)) {
        deleteTreeIfExists(b, bundle.bundle_root);
        cwd.rename(building_root, cwd, bundle.bundle_root, b.graph.io) catch |err|
            std.debug.panic("failed to publish tree-sitter bundle {s}: {}", .{ bundle.bundle_root, err });
    } else {
        deleteTreeIfExists(b, building_root);
    }
}

fn copyTreeSitterSupportHeaders(b: *std.Build, source_dir: []const u8, dest_dir: []const u8) void {
    for (tree_sitter_support_headers) |header| {
        copyFile(
            b,
            b.pathJoin(&.{ source_dir, header }),
            b.pathJoin(&.{ dest_dir, "tree_sitter", header }),
        );
    }
}

fn copyTreeSitterRuntime(b: *std.Build, checkout: []const u8, runtime_source_root: []const u8) void {
    copyTree(
        b,
        b.pathJoin(&.{ checkout, "lib", "src" }),
        b.pathJoin(&.{ runtime_source_root, "lib", "src" }),
    );
    copyTree(
        b,
        b.pathJoin(&.{ checkout, "lib", "include" }),
        b.pathJoin(&.{ runtime_source_root, "lib", "include" }),
    );
}

fn copyTree(b: *std.Build, source_dir: []const u8, dest_dir: []const u8) void {
    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(b.graph.io, dest_dir) catch |err|
        std.debug.panic("failed to create directory {s}: {}", .{ dest_dir, err });
    var dir = cwd.openDir(b.graph.io, source_dir, .{ .iterate = true }) catch |err|
        std.debug.panic("failed to open directory {s}: {}", .{ source_dir, err });
    defer dir.close(b.graph.io);

    var iterator = dir.iterate();
    while (iterator.next(b.graph.io) catch |err| std.debug.panic("failed to iterate directory {s}: {}", .{ source_dir, err })) |entry| {
        const source = b.pathJoin(&.{ source_dir, entry.name });
        const dest = b.pathJoin(&.{ dest_dir, entry.name });
        switch (entry.kind) {
            .directory => copyTree(b, source, dest),
            .file => copyFile(b, source, dest),
            else => {},
        }
    }
}

fn pathExists(b: *std.Build, path: []const u8) bool {
    std.Io.Dir.cwd().access(b.graph.io, path, .{}) catch return false;
    return true;
}

fn isTreeSitterBundleSource(path: []const u8) bool {
    return std.mem.startsWith(u8, path, "src/") or
        std.mem.startsWith(u8, path, "common/") or
        std.mem.indexOf(u8, path, "/src/") != null;
}

fn checkoutCommit(b: *std.Build, repo: []const u8, commit: []const u8, dest: []const u8) void {
    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(b.graph.io, dest) catch |err|
        std.debug.panic("failed to create git checkout directory {s}: {}", .{ dest, err });
    runBuildCommand(b, dest, &.{ "git", "init", "-q" });
    runBuildCommand(b, dest, &.{ "git", "remote", "add", "origin", repo });
    runBuildCommand(b, dest, &.{ "git", "fetch", "--depth=1", "origin", commit });
    runBuildCommand(b, dest, &.{ "git", "checkout", "-q", "--detach", "FETCH_HEAD" });
}

fn runBuildCommand(b: *std.Build, cwd_path: []const u8, argv: []const []const u8) void {
    const result = std.process.run(b.allocator, b.graph.io, .{
        .argv = argv,
        .cwd = .{ .path = cwd_path },
        .stdout_limit = .limited(tree_sitter_build_stdout_limit),
        .stderr_limit = .limited(tree_sitter_build_stderr_limit),
    }) catch |err| std.debug.panic("failed to run {s}: {}", .{ argv[0], err });
    defer b.allocator.free(result.stdout);
    defer b.allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| {
            if (code == 0) return;
            if (result.stdout.len != 0) std.debug.print("{s}", .{result.stdout});
            if (result.stderr.len != 0) std.debug.print("{s}", .{result.stderr});
            std.debug.panic("{s} failed with exit code {d}", .{ argv[0], code });
        },
        else => std.debug.panic("{s} ended unexpectedly: {}", .{ argv[0], result.term }),
    }
}

fn copyFile(b: *std.Build, source: []const u8, dest: []const u8) void {
    const cwd = std.Io.Dir.cwd();
    cwd.copyFile(source, cwd, dest, b.graph.io, .{ .make_path = true }) catch |err|
        std.debug.panic("failed to copy {s} to {s}: {}", .{ source, dest, err });
}

fn deleteTreeIfExists(b: *std.Build, path: []const u8) void {
    std.Io.Dir.cwd().deleteTree(b.graph.io, path) catch |err|
        std.debug.panic("failed to delete {s}: {}", .{ path, err });
}

fn readTreeSitterRuntimeDefine(b: *std.Build, bundle: TreeSitterBundle, name: []const u8) u32 {
    const api_path = b.fmt("{s}/lib/include/tree_sitter/api.h", .{bundle.runtime_source_root});
    const text = std.Io.Dir.cwd().readFileAlloc(b.graph.io, api_path, b.allocator, .limited(128 * 1024)) catch |err|
        std.debug.panic("failed to read tree-sitter runtime header {s}: {}", .{ api_path, err });
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (!std.mem.startsWith(u8, trimmed, "#define")) continue;
        var parts = std.mem.tokenizeAny(u8, trimmed, " \t");
        _ = parts.next() orelse continue;
        const key = parts.next() orelse continue;
        if (!std.mem.eql(u8, key, name)) continue;
        const value = parts.next() orelse break;
        return std.fmt.parseUnsigned(u32, value, 10) catch |err|
            std.debug.panic("invalid tree-sitter runtime define {s}: {}", .{ name, err });
    }
    std.debug.panic("tree-sitter runtime header does not define {s}", .{name});
}

fn addNativePdfHeadersAndLibraries(b: *std.Build, module: *Module, tree_sitter: TreeSitterBundle) void {
    module.addIncludePath(b.path("src/render/pdf"));
    addTreeSitterIncludePaths(b, module, tree_sitter);
    module.linkSystemLibrary("ss-pdf", .{ .use_pkg_config = .force });
}

fn addTreeSitterIncludePaths(b: *std.Build, module: *Module, tree_sitter: TreeSitterBundle) void {
    module.addIncludePath(cwdPath(b, b.fmt("{s}/lib/include", .{tree_sitter.runtime_source_root})));
    module.addIncludePath(cwdPath(b, b.fmt("{s}/lib/src", .{tree_sitter.runtime_source_root})));
}

fn addTreeSitterRuntimeSource(ctx: BuildContext, module: *Module, tree_sitter: TreeSitterBundle) void {
    addTreeSitterCSourceFile(ctx, module, cwdPath(ctx.b, ctx.b.fmt("{s}/lib/src/lib.c", .{tree_sitter.runtime_source_root})));
}

fn addTreeSitterCSourceFile(ctx: BuildContext, module: *Module, file: std.Build.LazyPath) void {
    module.addCSourceFile(.{
        .file = file,
        .flags = ctx.tree_sitter_c_flags,
    });
}

fn addTreeSitterAbiCheck(ctx: BuildContext, tree_sitter: TreeSitterBundle) TreeSitterCheck {
    const b = ctx.b;
    const check_mod = b.createModule(.{
        .target = ctx.target,
        .optimize = ctx.optimize,
        .link_libc = true,
    });
    addTreeSitterIncludePaths(b, check_mod, tree_sitter);
    addTreeSitterRuntimeSource(ctx, check_mod, tree_sitter);
    check_mod.addCSourceFile(.{
        .file = b.path("src/render/pdf/tree_sitter_abi_check.c"),
    });
    for (generated_tree_sitter_sources) |source| {
        addTreeSitterCSourceFile(ctx, check_mod, cwdPath(b, b.fmt("{s}/{s}", .{ tree_sitter.generated_root, source })));
    }

    const check_exe = b.addExecutable(.{
        .name = "ss-tree-sitter-abi-check",
        .root_module = check_mod,
    });
    if (!targetCanRunOnBuildHost(ctx)) {
        return .{ .compile = check_exe, .run = null };
    }

    const run_check = b.addRunArtifact(check_exe);
    run_check.setName("tree-sitter ABI and parser check");
    if (ctx.tree_sitter_ubsan) {
        run_check.setEnvironmentVariable("SS_TREE_SITTER_CHECK_TRACE", "1");
    }
    return .{ .compile = check_exe, .run = run_check };
}

fn dependOnTreeSitterCheck(step: *Step, check: TreeSitterCheck) void {
    if (check.run) |run| {
        step.dependOn(&run.step);
    } else {
        step.dependOn(&check.compile.step);
    }
}

fn targetCanRunOnBuildHost(ctx: BuildContext) bool {
    return ctx.target.query.isNative();
}

fn cwdPath(_: *std.Build, path: []const u8) std.Build.LazyPath {
    return .{ .cwd_relative = path };
}

fn detectGitCommit(b: *std.Build) ?[]const u8 {
    const result = std.process.run(b.allocator, b.graph.io, .{
        .argv = &.{ "git", "rev-parse", "--short", "HEAD" },
        .cwd = .{ .path = b.pathFromRoot(".") },
        .stdout_limit = .limited(128),
        .stderr_limit = .limited(1024),
    }) catch return null;
    defer b.allocator.free(result.stdout);
    defer b.allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return null,
        else => return null,
    }
    const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (trimmed.len == 0) return null;
    return b.allocator.dupe(u8, trimmed) catch null;
}

fn detectUncommittedChanges(b: *std.Build) []const u8 {
    const has_changes = detectGitUncommittedChanges(b) orelse return "unknown";
    return if (has_changes) "yes" else "no";
}

fn detectGitUncommittedChanges(b: *std.Build) ?bool {
    const result = std.process.run(b.allocator, b.graph.io, .{
        .argv = &.{ "git", "status", "--porcelain" },
        .cwd = .{ .path = b.pathFromRoot(".") },
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(1024),
    }) catch return null;
    defer b.allocator.free(result.stdout);
    defer b.allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return null,
        else => return null,
    }
    return std.mem.trim(u8, result.stdout, " \t\r\n").len != 0;
}

fn readReleaseVersion(b: *std.Build) ![]const u8 {
    const raw = try b.build_root.handle.readFileAlloc(b.graph.io, "release/VERSION", b.allocator, .limited(64));
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return error.EmptyVersion;
    return trimmed;
}
