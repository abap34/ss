const std = @import("std");

const Module = std.Build.Module;
const Step = std.Build.Step;
const Import = Module.Import;

const BuildContext = struct {
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
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

const generated_tree_sitter_root = ".zig-cache/tree-sitter-languages";

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

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const ctx = BuildContext{ .b = b, .target = target, .optimize = optimize };

    const release_version = readReleaseVersion(b) catch @panic("release/VERSION must contain the release version.");
    const default_version = b.fmt("{s}-dev", .{release_version});
    const version = b.option([]const u8, "version", "Version string reported by `ss --version`") orelse default_version;
    const commit = b.option([]const u8, "commit", "Source commit reported by `ss --version`") orelse "unknown";
    const source_stdlib_dir = b.pathFromRoot("stdlib");
    const installed_stdlib_dir = b.pathJoin(&.{ b.install_path, "share", "ss", "stdlib" });
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", version);
    build_options.addOption([]const u8, "commit", commit);
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

    const modules = createProjectModules(ctx, md4c_src, b.path(md4c_src), build_options);
    const exe_mod = createCliModule(ctx, modules, build_options);
    const exe = b.addExecutable(.{
        .name = "ss",
        .root_module = exe_mod,
    });
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

    addTestStep(ctx, modules, build_options, exe);
}

fn createProjectModules(ctx: BuildContext, md4c_src: []const u8, md4c_include: std.Build.LazyPath, build_options: *Step.Options) ProjectModules {
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
    addNativePdfBackend(ctx.b, core_mod);

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

fn createCliModule(ctx: BuildContext, modules: ProjectModules, build_options: *Step.Options) *Module {
    const module = createCommonModule(ctx, "src/main.zig", modules, true);
    module.addOptions("build_options", build_options);
    addNativePdfHeadersAndLibraries(ctx.b, module);
    return module;
}

fn addTestStep(
    ctx: BuildContext,
    modules: ProjectModules,
    build_options: *Step.Options,
    exe: *Step.Compile,
) void {
    const b = ctx.b;
    const test_step = b.step("test", "Run ss test targets");

    addTestModule(b, test_step, modules.core);

    const syntax_mod = createCommonTestModule(ctx, test_step, "src/syntax.zig", modules, true);
    const main_tests_mod = createCliModule(ctx, modules, build_options);
    addTestModule(b, test_step, main_tests_mod);
    addModuleTest(ctx, test_step, "tests/syntax_spec_tests.zig", &.{
        import("core", modules.core),
        import("utils", modules.utils),
        import("ast", modules.ast),
        import("model", modules.model),
        import("language_type", modules.language_type),
        import("syntax", syntax_mod),
    }, true);
    addModuleTest(ctx, test_step, "tests/language_type_spec_tests.zig", &.{
        import("model", modules.model),
        import("language_type", modules.language_type),
    }, null);
    const type_defs_mod = createModule(ctx, "src/language/type_defs.zig", &.{}, null);
    addModuleTest(ctx, test_step, "tests/language_type_defs_spec_tests.zig", &.{
        import("type_defs", type_defs_mod),
    }, null);

    const registry_mod = createModule(ctx, "src/language/registry.zig", &.{
        import("core", modules.core),
        import("language_type", modules.language_type),
    }, null);
    addModuleTest(ctx, test_step, "tests/language_registry_spec_tests.zig", &.{
        import("core", modules.core),
        import("model", modules.model),
        import("language_type", modules.language_type),
        import("registry", registry_mod),
    }, true);
    addModuleTest(ctx, test_step, "tests/core_ir_spec_tests.zig", &.{
        import("core", modules.core),
        import("utils", modules.utils),
        import("ast", modules.ast),
        import("model", modules.model),
        import("language_type", modules.language_type),
    }, true);
    addModuleTest(ctx, test_step, "tests/core_markdown_spec_tests.zig", &.{
        import("core", modules.core),
    }, true);
    addModuleTest(ctx, test_step, "tests/layout_graph_spec_tests.zig", &.{
        import("core", modules.core),
        import("utils", modules.utils),
        import("ast", modules.ast),
        import("model", modules.model),
        import("language_type", modules.language_type),
    }, true);
    addModuleTest(ctx, test_step, "tests/utils_fs_spec_tests.zig", &.{
        import("utils", modules.utils),
    }, true);
    addModuleTest(ctx, test_step, "tests/project_spec_tests.zig", &.{
        import("project", modules.project),
        import("utils", modules.utils),
    }, null);
    const compiler_mod = createCommonModule(ctx, "src/compiler.zig", modules, true);
    const lsp_scope_mod = createModule(ctx, "src/lsp/scope.zig", &.{
        import("utils", modules.utils),
    }, true);
    addModuleTest(ctx, test_step, "tests/lsp_scope_spec_tests.zig", &.{
        import("lsp_scope", lsp_scope_mod),
    }, true);
    addModuleTest(ctx, test_step, "tests/lsp_completion_spec_tests.zig", &.{
        import("compiler", compiler_mod),
    }, true);
    const watch_mod = createCommonModule(ctx, "src/watch.zig", modules, true);
    addNativePdfHeadersAndLibraries(b, watch_mod);
    addModuleTest(ctx, test_step, "tests/watch_spec_tests.zig", &.{
        import("watch", watch_mod),
    }, true);
    const render_pdf_spec_mod = createModule(ctx, "tests/render_pdf_spec_tests.zig", &.{}, true);
    addNativePdfBackend(b, render_pdf_spec_mod);
    addTestModule(b, test_step, render_pdf_spec_mod);
    const render_wrap_mod = createModule(ctx, "src/render/wrap.zig", &.{}, null);
    addModuleTest(ctx, test_step, "tests/render_pdf_native_wrap_spec_tests.zig", &.{
        import("render_wrap", render_wrap_mod),
    }, null);

    const compiler_semantics_support_mod = createModule(ctx, "tests/compiler_semantics_spec_support.zig", &.{
        import("utils", modules.utils),
        import("compiler", compiler_mod),
    }, true);
    addModuleTest(ctx, test_step, "tests/compiler_semantics_spec_tests.zig", &.{
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
        "tests/debug_runtime_spec.mjs",
        "tests/lsp_completion_runtime_spec.mjs",
        "tests/lsp_editor_runtime_spec.mjs",
        "tests/render_cache_runtime_spec.mjs",
        "tests/render_diagnostics_runtime_spec.mjs",
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

fn addNativePdfBackend(b: *std.Build, module: *Module) void {
    ensureGeneratedTreeSitterSources(b);
    addNativePdfHeadersAndLibraries(b, module);
    module.addCSourceFile(.{
        .file = b.path("src/render/pdf/pdf.c"),
    });
    module.addCSourceFile(.{
        .file = b.path("editor/tree-sitter-ss/src/parser.c"),
    });
    for (generated_tree_sitter_sources) |source| {
        module.addCSourceFile(.{
            .file = b.path(b.fmt("{s}/{s}", .{ generated_tree_sitter_root, source })),
        });
    }
    module.addIncludePath(b.path("editor/tree-sitter-ss/src"));
}

fn ensureGeneratedTreeSitterSources(b: *std.Build) void {
    for (generated_tree_sitter_sources) |source| {
        b.build_root.handle.access(b.graph.io, b.fmt("{s}/{s}", .{ generated_tree_sitter_root, source }), .{}) catch {
            runTreeSitterPrepareBuild(b);
            break;
        };
    }
    for (generated_tree_sitter_sources) |source| {
        b.build_root.handle.access(b.graph.io, b.fmt("{s}/{s}", .{ generated_tree_sitter_root, source }), .{}) catch
            std.debug.panic("generated tree-sitter parser source is missing after preparation: {s}/{s}", .{ generated_tree_sitter_root, source });
    }
}

fn runTreeSitterPrepareBuild(b: *std.Build) void {
    std.debug.print("preparing generated tree-sitter parser sources...\n", .{});
    const argv = [_][]const u8{ "node", "scripts/update-tree-sitter-languages.mjs", "--prepare-build" };
    const result = std.process.run(b.allocator, b.graph.io, .{
        .argv = &argv,
        .cwd = .{ .path = b.pathFromRoot(".") },
        .stdout_limit = .limited(256 * 1024),
        .stderr_limit = .limited(256 * 1024),
    }) catch |err| std.debug.panic("failed to prepare tree-sitter parser sources: {}", .{err});
    defer b.allocator.free(result.stdout);
    defer b.allocator.free(result.stderr);

    if (result.stdout.len != 0) std.debug.print("{s}", .{result.stdout});
    if (result.stderr.len != 0) std.debug.print("{s}", .{result.stderr});
    switch (result.term) {
        .exited => |code| {
            if (code != 0) std.debug.panic("tree-sitter parser preparation failed with exit code {}", .{code});
        },
        else => std.debug.panic("tree-sitter parser preparation ended unexpectedly: {}", .{result.term}),
    }
}

fn addNativePdfHeadersAndLibraries(b: *std.Build, module: *Module) void {
    module.addIncludePath(b.path("src/render/pdf"));
    module.linkSystemLibrary("ss-pdf", .{ .use_pkg_config = .force });
    module.linkSystemLibrary("tree-sitter", .{ .use_pkg_config = .force });
}

fn readReleaseVersion(b: *std.Build) ![]const u8 {
    const raw = try b.build_root.handle.readFileAlloc(b.graph.io, "release/VERSION", b.allocator, .limited(64));
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return error.EmptyVersion;
    return trimmed;
}
