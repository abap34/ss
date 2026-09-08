const std = @import("std");
const cairo = @import("build/cairo.zig");
const dependencies = @import("build/dependencies.zig");
const qpdf = @import("build/qpdf.zig");
const tree_sitter_build = @import("build/tree_sitter.zig");

const Module = std.Build.Module;
const Step = std.Build.Step;
const Import = Module.Import;

const installed_stdlib_subdir = "share/ss/stdlib";

const BuildContext = struct {
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    tree_sitter_ubsan: bool,
    tree_sitter_c_flags: []const []const u8,
    dependency_checks: dependencies.Checks,
    qpdf_bridge: qpdf.Bridge,
};

const ProjectModules = struct {
    utils: *Module,
    model: *Module,
    language_type: *Module,
    ast: *Module,
    stdlib_assets: *Module,
    fontawesome_assets: *Module,
    pdfjs_assets: *Module,
    html_embeds: *Module,
    project: *Module,
    core: *Module,
    render: *Module,
    render_resources: *Module,
    render_measurements: *Module,
    pdf_ffi: *Module,
    render_text: *Module,
    render_emitter: *Module,
    pdf_backend: *Module,
};

const BundledHighlightQuery = struct {
    option_name: []const u8,
    path: []const u8,
};

const TreeSitterBundle = tree_sitter_build.Bundle;

const TreeSitterCheck = struct {
    compile: *Step.Compile,
    run: ?*Step.Run,
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
    const release_version = readReleaseVersion(b) catch @panic("release/VERSION must contain the release version.");
    const default_version = b.fmt("{s}-dev", .{release_version});
    const version = b.option([]const u8, "version", "Version string reported by `ss --version`") orelse default_version;
    const commit = b.option([]const u8, "commit", "Source commit reported by `ss --version`") orelse detectGitCommit(b) orelse "unknown";
    const uncommitted_changes = detectUncommittedChanges(b);
    const source_stdlib_dir = b.pathFromRoot("stdlib");
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", version);
    build_options.addOption([]const u8, "commit", commit);
    build_options.addOption([]const u8, "uncommitted_changes", uncommitted_changes);
    build_options.addOption([]const u8, "source_stdlib_dir", source_stdlib_dir);
    build_options.addOption([]const u8, "installed_stdlib_subdir", installed_stdlib_subdir);
    build_options.addOption([]const u8, "tree_sitter_cache_subdir", tree_sitter_build.cache_subdir);
    const ss_highlight_query = b.build_root.handle.readFileAlloc(b.graph.io, "editor/tree-sitter-ss/queries/highlights.scm", b.allocator, .limited(64 * 1024)) catch
        @panic("editor/tree-sitter-ss/queries/highlights.scm is missing.");
    build_options.addOption([]const u8, "ss_highlight_query", ss_highlight_query);
    for (bundled_highlight_queries) |query| {
        const source = b.build_root.handle.readFileAlloc(b.graph.io, query.path, b.allocator, .limited(128 * 1024)) catch
            @panic("bundled tree-sitter highlight query is missing.");
        build_options.addOption([]const u8, query.option_name, source);
    }

    const md4c_src = "third_party/md4c/src";
    for ([_][]const u8{ md4c_src ++ "/md4c.c", md4c_src ++ "/md4c.h" }) |path| {
        b.build_root.handle.access(b.graph.io, path, .{}) catch
            @panic(
                \\Bundled MD4C sources are missing from third_party/md4c/src.
                \\Restore the tracked third_party/md4c files and retry the build.
            );
    }
    addPdfPkgConfigPath(b);
    const qpdf_config = qpdf.config(b);
    const dependency_checks = dependencies.create(b, .{
        .pkg_config = qpdf_config.pkg_config,
        .cpp = qpdf_config.cpp,
        .minimum_cairo_version = cairo.minimum_version,
        .maximum_exclusive_cairo_version = cairo.maximum_exclusive_version,
        .minimum_qpdf_version = qpdf.minimum_version,
        .maximum_exclusive_qpdf_version = qpdf.maximum_exclusive_version,
    });
    const ctx = BuildContext{
        .b = b,
        .target = target,
        .optimize = optimize,
        .tree_sitter_ubsan = tree_sitter_ubsan,
        .tree_sitter_c_flags = tree_sitter_c_flags,
        .dependency_checks = dependency_checks,
        .qpdf_bridge = qpdf.create(b, target, optimize, qpdf_config, &dependency_checks.native_pdf.step),
    };
    const tree_sitter = tree_sitter_build.create(b);
    b.step("tree-sitter-prepare", "Prepare the pinned tree-sitter runtime and parser sources").dependOn(tree_sitter.step);
    build_options.addOption([]const u8, "tree_sitter_manifest_hash", tree_sitter.manifest_hash);

    const modules = createProjectModules(ctx, md4c_src, b.path(md4c_src), build_options, tree_sitter);
    const tree_sitter_abi_check = addTreeSitterAbiCheck(ctx, tree_sitter);
    const tree_sitter_check_step = b.step("tree-sitter-check", "Check bundled tree-sitter runtime and parsers");
    dependOnTreeSitterCheck(tree_sitter_check_step, tree_sitter_abi_check);
    const exe_mod = createCliModule(ctx, modules, build_options);
    qpdf.link(ctx.qpdf_bridge, b, exe_mod, ctx.target, .build);
    const exe = b.addExecutable(.{
        .name = "ss",
        .root_module = exe_mod,
    });
    exe.step.dependOn(&ctx.qpdf_bridge.install.step);
    dependOnTreeSitterCheck(&exe.step, tree_sitter_abi_check);

    const installed_exe_mod = createCliModule(ctx, modules, build_options);
    qpdf.link(ctx.qpdf_bridge, b, installed_exe_mod, ctx.target, .installed);
    const installed_exe = b.addExecutable(.{
        .name = "ss",
        .root_module = installed_exe_mod,
    });
    dependOnTreeSitterCheck(&installed_exe.step, tree_sitter_abi_check);
    b.installArtifact(installed_exe);
    b.getInstallStep().dependOn(&ctx.qpdf_bridge.install.step);
    b.installDirectory(.{
        .source_dir = b.path("stdlib"),
        .install_dir = .prefix,
        .install_subdir = installed_stdlib_subdir,
        .include_extensions = &.{".ss"},
    });
    b.installDirectory(.{
        .source_dir = b.path("third_party/fontawesome-free"),
        .install_dir = .prefix,
        .install_subdir = "share/licenses/ss/fontawesome-free",
        .include_extensions = &.{".txt"},
    });

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the ss CLI");
    run_step.dependOn(&run_cmd.step);

    addTestStep(ctx, modules, build_options, exe, tree_sitter_abi_check);
    addVisualTestSteps(ctx, modules, build_options, exe);
    addBuildDependencyDiagnosticTest(ctx);
}

fn addVisualTestSteps(ctx: BuildContext, modules: ProjectModules, build_options: *Step.Options, exe: *Step.Compile) void {
    const b = ctx.b;
    const app_mod = createCommonModule(ctx, "src/app.zig", modules, true);
    app_mod.addOptions("build_options", build_options);
    const driver_mod = createModule(ctx, "tests/visual/render/driver.zig", &.{
        import("app", app_mod),
        import("utils", modules.utils),
    }, true);
    addNativePdfHeadersAndLibraries(b, driver_mod);
    qpdf.link(ctx.qpdf_bridge, b, driver_mod, ctx.target, .build);
    const driver = b.addExecutable(.{ .name = "ss-render-parity-driver", .root_module = driver_mod });
    driver.step.dependOn(&ctx.qpdf_bridge.install.step);

    const parity = b.addSystemCommand(&.{ "node", "tests/visual/render/spec.mjs" });
    parity.step.dependOn(&ctx.dependency_checks.node.step);
    parity.step.dependOn(&ctx.dependency_checks.visual_test_packages.step);
    parity.addFileArg(driver.getEmittedBin());
    parity.setCwd(b.path("."));
    parity.stdio = .inherit;
    const parity_step = b.step("test-render-parity", "Compare PDF and HTML pixels locally");
    parity_step.dependOn(&parity.step);

    const navigation = b.addSystemCommand(&.{ "node", "tests/visual/render/navigation/spec.mjs" });
    navigation.step.dependOn(&ctx.dependency_checks.node.step);
    navigation.step.dependOn(&ctx.dependency_checks.visual_test_packages.step);
    navigation.addFileArg(driver.getEmittedBin());
    navigation.setCwd(b.path("."));
    navigation.stdio = .inherit;
    const navigation_step = b.step("test-render-html-navigation", "Inspect standalone HTML page navigation locally");
    navigation_step.dependOn(&navigation.step);

    const pdf_runtime = b.addSystemCommand(&.{ "node", "tests/visual/render/pdf/runtime_spec.mjs" });
    pdf_runtime.step.dependOn(&ctx.dependency_checks.node.step);
    pdf_runtime.step.dependOn(&ctx.dependency_checks.visual_test_packages.step);
    pdf_runtime.setCwd(b.path("."));
    pdf_runtime.stdio = .inherit;
    const pdf_runtime_step = b.step("test-render-pdf-runtime", "Inspect PDF image loading and cancellation locally");
    pdf_runtime_step.dependOn(&pdf_runtime.step);

    const full = b.addSystemCommand(&.{ "node", "tests/visual/render/spec.mjs", "--full" });
    full.step.dependOn(&ctx.dependency_checks.node.step);
    full.step.dependOn(&ctx.dependency_checks.visual_test_packages.step);
    full.addFileArg(driver.getEmittedBin());
    full.setCwd(b.path("."));
    full.stdio = .inherit;
    const full_step = b.step("test-render-parity-full", "Compare the extended PDF and HTML fixture set locally");
    full_step.dependOn(&full.step);

    const behavior = b.addSystemCommand(&.{ "node", "tests/visual/render/behavior/spec.mjs" });
    behavior.step.dependOn(&ctx.dependency_checks.node.step);
    behavior.step.dependOn(&ctx.dependency_checks.visual_test_packages.step);
    behavior.addFileArg(exe.getEmittedBin());
    behavior.setCwd(b.path("."));
    behavior.stdio = .inherit;
    const behavior_step = b.step("test-render-behavior", "Inspect rendered PDF behavior locally with Chromium");
    behavior_step.dependOn(&behavior.step);

    const editor_ui = b.addSystemCommand(&.{ "node", "tests/visual/editor/spec.mjs" });
    editor_ui.step.dependOn(&ctx.dependency_checks.node.step);
    editor_ui.step.dependOn(&ctx.dependency_checks.visual_test_packages.step);
    editor_ui.step.dependOn(&ctx.dependency_checks.vscode_packages.step);
    editor_ui.setCwd(b.path("."));
    editor_ui.stdio = .inherit;
    const editor_ui_step = b.step("test-editor-ui", "Exercise VS Code editor webview interactions locally with Chromium");
    editor_ui_step.dependOn(&editor_ui.step);

    const benchmark = b.addSystemCommand(&.{ "node", "tests/benchmark/render/spec.mjs", @tagName(ctx.optimize) });
    benchmark.step.dependOn(&ctx.dependency_checks.node.step);
    benchmark.addFileArg(exe.getEmittedBin());
    benchmark.setCwd(b.path("."));
    benchmark.stdio = .inherit;
    const benchmark_step = b.step("benchmark-render", "Measure fixed-document PDF and HTML rendering with ReleaseSafe");
    benchmark_step.dependOn(&benchmark.step);

    const wysiwyg_benchmark = b.addSystemCommand(&.{ "node", "tests/benchmark/wysiwyg/spec.mjs" });
    wysiwyg_benchmark.step.dependOn(&ctx.dependency_checks.node.step);
    // tests/runtime/harness.mjs resolves argv[2] as SS_BIN, so pass the
    // executable before the optimization mode.
    wysiwyg_benchmark.addFileArg(exe.getEmittedBin());
    wysiwyg_benchmark.addArg(@tagName(ctx.optimize));
    wysiwyg_benchmark.setCwd(b.path("."));
    wysiwyg_benchmark.stdio = .inherit;
    const wysiwyg_benchmark_step = b.step(
        "benchmark-wysiwyg",
        "Measure WYSIWYG initial and editing latency with ReleaseSafe",
    );
    wysiwyg_benchmark_step.dependOn(&wysiwyg_benchmark.step);
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
    const fontawesome_assets_mod = createModule(ctx, "third_party/fontawesome-free/embed.zig", &.{}, null);
    const pdfjs_assets_mod = createModule(ctx, "third_party/pdfjs/embed.zig", &.{}, null);
    const html_embeds_mod = createHtmlEmbedsModule(ctx);
    const project_mod = createModule(ctx, "src/project.zig", &.{
        import("utils", utils_mod),
    }, true);
    project_mod.addIncludePath(ctx.b.path("third_party/tomlc17"));
    project_mod.addCSourceFile(.{
        .file = ctx.b.path("third_party/tomlc17/tomlc17.c"),
        .flags = &.{"-std=c17"},
    });
    const core_mod = createModule(ctx, "src/core.zig", &.{
        import("utils", utils_mod),
        import("ast", ast_mod),
        import("model", model_mod),
        import("language_type", language_type_mod),
        import("fontawesome_assets", fontawesome_assets_mod),
    }, true);
    core_mod.addOptions("build_options", build_options);
    const tree_sitter_abi = ctx.b.addTranslateC(.{
        .root_source_file = tree_sitter.root.path(ctx.b, "runtime/source/lib/include/tree_sitter/api.h"),
        .target = ctx.target,
        .optimize = ctx.optimize,
    });
    core_mod.addImport("tree_sitter_abi", tree_sitter_abi.createModule());
    core_mod.addIncludePath(md4c_include);
    core_mod.addCSourceFiles(.{
        .root = ctx.b.path(md4c_src),
        .files = &.{"md4c.c"},
    });
    addNativePdfBackend(ctx.b, core_mod);
    addTreeSitterSources(ctx, core_mod, tree_sitter);

    const render_mod = createModule(ctx, "src/render/ir.zig", &.{
        import("core", core_mod),
    }, null);
    const render_measurements_mod = createModule(ctx, "src/render/compile/measurement_store.zig", &.{
        import("core", core_mod),
        import("utils", utils_mod),
    }, null);
    const pdf_ffi_mod = createModule(ctx, "src/render/pdf/ffi.zig", &.{}, true);
    addNativePdfHeadersAndLibraries(ctx.b, pdf_ffi_mod);
    const render_resources_mod = createModule(ctx, "src/render/compile/resources.zig", &.{
        import("pdf_ffi", pdf_ffi_mod),
        import("render", render_mod),
    }, true);
    const render_text_mod = createModule(ctx, "src/render/compile/text.zig", &.{
        import("core", core_mod),
        import("pdf_ffi", pdf_ffi_mod),
        import("render", render_mod),
        import("render_resources", render_resources_mod),
        import("utils", utils_mod),
    }, true);
    const render_emitter_mod = createModule(ctx, "src/render/compile/emitter.zig", &.{
        import("core", core_mod),
        import("render", render_mod),
        import("render_resources", render_resources_mod),
        import("render_text", render_text_mod),
    }, true);
    const pdf_backend_mod = createModule(ctx, "src/render/pdf/backend.zig", &.{
        import("core", core_mod),
        import("pdf_ffi", pdf_ffi_mod),
        import("render", render_mod),
    }, true);

    return .{
        .utils = utils_mod,
        .model = model_mod,
        .language_type = language_type_mod,
        .ast = ast_mod,
        .stdlib_assets = stdlib_assets_mod,
        .fontawesome_assets = fontawesome_assets_mod,
        .pdfjs_assets = pdfjs_assets_mod,
        .html_embeds = html_embeds_mod,
        .project = project_mod,
        .core = core_mod,
        .render = render_mod,
        .render_resources = render_resources_mod,
        .render_measurements = render_measurements_mod,
        .pdf_ffi = pdf_ffi_mod,
        .render_text = render_text_mod,
        .render_emitter = render_emitter_mod,
        .pdf_backend = pdf_backend_mod,
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
    tree_sitter_abi_check: TreeSitterCheck,
) void {
    const b = ctx.b;
    const test_step = b.step("test", "Run ss test targets");
    dependOnTreeSitterCheck(test_step, tree_sitter_abi_check);

    const syntax_mod = createCommonTestModule(ctx, test_step, "src/syntax.zig", modules, true);
    const main_tests_mod = createCliModule(ctx, modules, build_options);
    addQpdfTestModule(ctx, test_step, main_tests_mod);
    const parser_spec_mod = createModule(ctx, "tests/syntax/parser/spec_tests.zig", &.{
        import("core", modules.core),
        import("utils", modules.utils),
        import("ast", modules.ast),
        import("model", modules.model),
        import("language_type", modules.language_type),
        import("syntax", syntax_mod),
    }, true);
    const parser_spec_tests = addTestArtifact(ctx, parser_spec_mod);
    const run_parser_spec_tests = b.addRunArtifact(parser_spec_tests);
    test_step.dependOn(&run_parser_spec_tests.step);
    addFocusedTestStep(b, "test-parser", "Run focused syntax parser tests", &run_parser_spec_tests.step);
    const scanner_mod = createModule(ctx, "src/syntax/scanner.zig", &.{
        import("utils", modules.utils),
    }, null);
    addModuleTest(ctx, test_step, "tests/syntax/scanner/spec_tests.zig", &.{
        import("scanner", scanner_mod),
    }, null);
    const language_type_spec_mod = createModule(ctx, "tests/language/type/spec_tests.zig", &.{
        import("model", modules.model),
        import("language_type", modules.language_type),
    }, null);
    const language_type_spec_tests = addTestArtifact(ctx, language_type_spec_mod);
    const run_language_type_spec_tests = b.addRunArtifact(language_type_spec_tests);
    test_step.dependOn(&run_language_type_spec_tests.step);
    addFocusedTestStep(b, "test-language-type", "Run focused language type tests", &run_language_type_spec_tests.step);
    const analysis_mod = createCommonTestModule(ctx, test_step, "src/analysis.zig", modules, true);
    addModuleTest(ctx, test_step, "tests/analysis/types/spec_tests.zig", &.{
        import("core", modules.core),
        import("language_type", modules.language_type),
        import("analysis", analysis_mod),
    }, true);
    const analysis_query_spec_mod = createModule(ctx, "tests/analysis/query/spec_tests.zig", &.{
        import("analysis", analysis_mod),
    }, true);
    const analysis_query_spec_tests = addTestArtifact(ctx, analysis_query_spec_mod);
    const run_analysis_query_spec_tests = b.addRunArtifact(analysis_query_spec_tests);
    test_step.dependOn(&run_analysis_query_spec_tests.step);
    addFocusedTestStep(b, "test-analysis-query", "Run focused analysis query tests", &run_analysis_query_spec_tests.step);
    const analysis_snapshot_spec_mod = createModule(ctx, "tests/analysis/snapshot/spec_tests.zig", &.{
        import("analysis", analysis_mod),
        import("ast", modules.ast),
        import("core", modules.core),
        import("render_text", modules.render_text),
    }, true);
    const analysis_snapshot_spec_tests = addTestArtifact(ctx, analysis_snapshot_spec_mod);
    const run_analysis_snapshot_spec_tests = b.addRunArtifact(analysis_snapshot_spec_tests);
    test_step.dependOn(&run_analysis_snapshot_spec_tests.step);
    addFocusedTestStep(
        b,
        "test-analysis-snapshot",
        "Run focused analysis snapshot tests",
        &run_analysis_snapshot_spec_tests.step,
    );
    const analysis_diagnostics_spec_mod = createModule(ctx, "tests/analysis/diagnostics/spec_tests.zig", &.{
        import("analysis", analysis_mod),
    }, true);
    const analysis_diagnostics_spec_tests = addTestArtifact(ctx, analysis_diagnostics_spec_mod);
    const run_analysis_diagnostics_spec_tests = b.addRunArtifact(analysis_diagnostics_spec_tests);
    test_step.dependOn(&run_analysis_diagnostics_spec_tests.step);
    addFocusedTestStep(
        b,
        "test-analysis-diagnostics",
        "Run focused analysis diagnostic ownership tests",
        &run_analysis_diagnostics_spec_tests.step,
    );
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
    const document_state_spec_mod = createModule(ctx, "tests/core/document_state/spec_tests.zig", &.{
        import("core", modules.core),
        import("utils", modules.utils),
        import("ast", modules.ast),
        import("model", modules.model),
        import("language_type", modules.language_type),
    }, true);
    const document_state_spec_tests = addTestArtifact(ctx, document_state_spec_mod);
    const run_document_state_spec_tests = b.addRunArtifact(document_state_spec_tests);
    test_step.dependOn(&run_document_state_spec_tests.step);
    addFocusedTestStep(
        b,
        "test-document-state",
        "Run focused document state tests",
        &run_document_state_spec_tests.step,
    );
    addModuleTest(ctx, test_step, "tests/core/markdown/spec_tests.zig", &.{
        import("core", modules.core),
    }, true);
    const value_text_spec_mod = createModule(ctx, "tests/core/value_text/spec_tests.zig", &.{
        import("core", modules.core),
        import("ast", modules.ast),
        import("language_type", modules.language_type),
    }, true);
    const value_text_spec_tests = addTestArtifact(ctx, value_text_spec_mod);
    const run_value_text_spec_tests = b.addRunArtifact(value_text_spec_tests);
    test_step.dependOn(&run_value_text_spec_tests.step);
    addFocusedTestStep(b, "test-value-text", "Run focused tagged property value tests", &run_value_text_spec_tests.step);
    const layout_partition_spec_mod = createModule(ctx, "tests/layout/partition/spec_tests.zig", &.{
        import("core", modules.core),
        import("ast", modules.ast),
    }, true);
    const layout_partition_spec_tests = addTestArtifact(ctx, layout_partition_spec_mod);
    const run_layout_partition_spec_tests = b.addRunArtifact(layout_partition_spec_tests);
    test_step.dependOn(&run_layout_partition_spec_tests.step);
    addFocusedTestStep(b, "test-layout-partition", "Run focused page partition tests", &run_layout_partition_spec_tests.step);
    const layout_graph_spec_mod = createModule(ctx, "tests/layout/graph/spec_tests.zig", &.{
        import("core", modules.core),
        import("utils", modules.utils),
        import("ast", modules.ast),
        import("model", modules.model),
        import("language_type", modules.language_type),
    }, true);
    const layout_graph_spec_tests = addTestArtifact(ctx, layout_graph_spec_mod);
    const run_layout_graph_spec_tests = b.addRunArtifact(layout_graph_spec_tests);
    test_step.dependOn(&run_layout_graph_spec_tests.step);
    addFocusedTestStep(b, "test-layout", "Run focused layout graph and solver tests", &run_layout_graph_spec_tests.step);
    const layout_conflicts_spec_mod = createModule(ctx, "tests/layout/conflicts/spec_tests.zig", &.{
        import("core", modules.core),
        import("ast", modules.ast),
    }, true);
    const layout_conflicts_spec_tests = addTestArtifact(ctx, layout_conflicts_spec_mod);
    const run_layout_conflicts_spec_tests = b.addRunArtifact(layout_conflicts_spec_tests);
    test_step.dependOn(&run_layout_conflicts_spec_tests.step);
    addFocusedTestStep(
        b,
        "test-layout-conflicts",
        "Run focused layout conflict report tests",
        &run_layout_conflicts_spec_tests.step,
    );
    const highlight_spans_mod = createModule(ctx, "src/render/compile/highlight_spans.zig", &.{
        import("utils", modules.utils),
    }, null);
    const highlight_spans_spec_mod = createModule(ctx, "tests/render/highlight/spans/spec_tests.zig", &.{
        import("highlight_spans", highlight_spans_mod),
        import("utils", modules.utils),
    }, null);
    const highlight_spans_spec_tests = addTestArtifact(ctx, highlight_spans_spec_mod);
    const run_highlight_spans_spec_tests = b.addRunArtifact(highlight_spans_spec_tests);
    test_step.dependOn(&run_highlight_spans_spec_tests.step);
    addFocusedTestStep(b, "test-highlight-spans", "Run focused highlight boundary traversal tests", &run_highlight_spans_spec_tests.step);
    const fs_spec_mod = createModule(ctx, "tests/utils/fs/spec_tests.zig", &.{
        import("utils", modules.utils),
    }, true);
    const fs_spec_tests = addTestArtifact(ctx, fs_spec_mod);
    const run_fs_spec_tests = b.addRunArtifact(fs_spec_tests);
    test_step.dependOn(&run_fs_spec_tests.step);
    addFocusedTestStep(b, "test-fs", "Run focused filesystem I/O tests", &run_fs_spec_tests.step);
    const tree_cache_spec_mod = createModule(ctx, "tests/utils/tree_sitter_cache/spec_tests.zig", &.{
        import("utils", modules.utils),
    }, true);
    const tree_cache_tests = addTestArtifact(ctx, tree_cache_spec_mod);
    const run_tree_cache_tests = b.addRunArtifact(tree_cache_tests);
    test_step.dependOn(&run_tree_cache_tests.step);
    addFocusedTestStep(b, "test-tree-sitter-cache", "Run focused tree-sitter cache lease tests", &run_tree_cache_tests.step);
    const tree_cache_worker = b.addExecutable(.{
        .name = "ss-tree-sitter-cache-worker",
        .root_module = createModule(ctx, "tests/build/tree_sitter/cache_worker.zig", &.{import("utils", modules.utils)}, true),
    });
    const tree_build_tests = b.addSystemCommand(&.{"node"});
    tree_build_tests.addFileArg(b.path("tests/build/tree_sitter/spec.mjs"));
    tree_build_tests.addFileArg(tree_cache_worker.getEmittedBin());
    tree_build_tests.setCwd(b.path("."));
    tree_build_tests.step.dependOn(&ctx.dependency_checks.node.step);
    test_step.dependOn(&tree_build_tests.step);
    addFocusedTestStep(b, "test-tree-sitter-build", "Run isolated and concurrent tree-sitter preparation tests", &tree_build_tests.step);
    addModuleTest(ctx, test_step, "tests/utils/json/spec_tests.zig", &.{
        import("utils", modules.utils),
    }, true);
    const cache_reference_mod = createModule(ctx, "tests/utils/render_cache/reference_spec_tests.zig", &.{
        import("utils", modules.utils),
    }, true);
    const cache_reference_tests = addTestArtifact(ctx, cache_reference_mod);
    const run_cache_reference_tests = b.addRunArtifact(cache_reference_tests);
    const cache_pruning_spec = b.addSystemCommand(&.{"node"});
    cache_pruning_spec.step.dependOn(&ctx.dependency_checks.node.step);
    cache_pruning_spec.addFileArg(b.path("tests/runtime/cache/pruning/spec.mjs"));
    cache_pruning_spec.addFileArg(exe.getEmittedBin());
    cache_pruning_spec.setCwd(b.path("."));
    cache_pruning_spec.stdio = .inherit;
    const cache_test_step = b.step("test-render-cache", "Run focused render cache reference and pruning tests");
    cache_test_step.dependOn(&run_cache_reference_tests.step);
    cache_test_step.dependOn(&cache_pruning_spec.step);
    test_step.dependOn(cache_test_step);
    const progress_spec_mod = createModule(ctx, "tests/utils/progress/spec_tests.zig", &.{
        import("utils", modules.utils),
    }, true);
    const progress_spec_tests = addTestArtifact(ctx, progress_spec_mod);
    const run_progress_spec_tests = b.addRunArtifact(progress_spec_tests);
    test_step.dependOn(&run_progress_spec_tests.step);
    const progress_runtime_spec = b.addSystemCommand(&.{"node"});
    progress_runtime_spec.step.dependOn(&ctx.dependency_checks.node.step);
    progress_runtime_spec.setName("node tests/runtime/progress/spec.mjs");
    progress_runtime_spec.addFileArg(b.path("tests/runtime/progress/spec.mjs"));
    progress_runtime_spec.addFileArg(exe.getEmittedBin());
    progress_runtime_spec.setCwd(b.path("."));
    progress_runtime_spec.stdio = .inherit;
    test_step.dependOn(&progress_runtime_spec.step);
    const progress_test_step = b.step("test-progress", "Run focused progress display tests");
    progress_test_step.dependOn(&run_progress_spec_tests.step);
    progress_test_step.dependOn(&progress_runtime_spec.step);
    const project_spec_mod = createModule(ctx, "tests/project/config/spec_tests.zig", &.{
        import("project", modules.project),
        import("utils", modules.utils),
    }, null);
    const project_spec_tests = addTestArtifact(ctx, project_spec_mod);
    const run_project_spec_tests = b.addRunArtifact(project_spec_tests);
    test_step.dependOn(&run_project_spec_tests.step);
    addFocusedTestStep(b, "test-project", "Run focused project configuration tests", &run_project_spec_tests.step);
    const project_settings_spec = b.addSystemCommand(&.{"node"});
    project_settings_spec.step.dependOn(&ctx.dependency_checks.node.step);
    project_settings_spec.addFileArg(b.path("tests/runtime/lsp/project_settings/spec.mjs"));
    project_settings_spec.addFileArg(exe.getEmittedBin());
    project_settings_spec.setCwd(b.path("."));
    project_settings_spec.stdio = .inherit;
    test_step.dependOn(&project_settings_spec.step);
    addFocusedTestStep(b, "test-project-settings", "Run normalized project settings protocol tests", &project_settings_spec.step);
    const app_output_app_mod = createCommonModule(ctx, "src/app.zig", modules, true);
    app_output_app_mod.addOptions("build_options", build_options);
    const app_output_spec_mod = createModule(ctx, "tests/app/output/spec_tests.zig", &.{
        import("app", app_output_app_mod),
        import("utils", modules.utils),
    }, true);
    addNativePdfHeadersAndLibraries(b, app_output_spec_mod);
    const app_output_spec_tests = addQpdfTestArtifact(ctx, app_output_spec_mod);
    const run_app_output_spec_tests = b.addRunArtifact(app_output_spec_tests);
    test_step.dependOn(&run_app_output_spec_tests.step);
    addFocusedTestStep(b, "test-app-output", "Run focused application output safety tests", &run_app_output_spec_tests.step);
    const compiler_mod = createCommonModule(ctx, "src/compiler.zig", modules, true);
    const eval_cancellation_spec_mod = createModule(ctx, "tests/eval/cancellation/spec_tests.zig", &.{
        import("compiler", compiler_mod),
    }, true);
    const eval_cancellation_spec_tests = addTestArtifact(ctx, eval_cancellation_spec_mod);
    const run_eval_cancellation_spec_tests = b.addRunArtifact(eval_cancellation_spec_tests);
    test_step.dependOn(&run_eval_cancellation_spec_tests.step);
    addFocusedTestStep(b, "test-eval-cancellation", "Run focused document evaluation cancellation tests", &run_eval_cancellation_spec_tests.step);
    const stdlib_cache_spec_mod = createModule(ctx, "tests/modules/stdlib_cache/spec_tests.zig", &.{
        import("compiler", compiler_mod),
    }, true);
    const stdlib_cache_spec_tests = addTestArtifact(ctx, stdlib_cache_spec_mod);
    const run_stdlib_cache_spec_tests = b.addRunArtifact(stdlib_cache_spec_tests);
    test_step.dependOn(&run_stdlib_cache_spec_tests.step);
    addFocusedTestStep(b, "test-stdlib-cache", "Run focused standard-library cache tests", &run_stdlib_cache_spec_tests.step);
    const module_exports_spec_mod = createModule(ctx, "tests/modules/exports/spec_tests.zig", &.{
        import("compiler", compiler_mod),
    }, true);
    const module_exports_spec_tests = addTestArtifact(ctx, module_exports_spec_mod);
    const run_module_exports_spec_tests = b.addRunArtifact(module_exports_spec_tests);
    test_step.dependOn(&run_module_exports_spec_tests.step);
    addFocusedTestStep(b, "test-module-exports", "Run focused selected import and re-export tests", &run_module_exports_spec_tests.step);
    const module_loader_spec_mod = createModule(ctx, "tests/modules/loader/spec_tests.zig", &.{
        import("compiler", compiler_mod),
        import("utils", modules.utils),
    }, true);
    const module_loader_spec_tests = addTestArtifact(ctx, module_loader_spec_mod);
    const run_module_loader_spec_tests = b.addRunArtifact(module_loader_spec_tests);
    test_step.dependOn(&run_module_loader_spec_tests.step);
    addFocusedTestStep(b, "test-module-loader", "Run focused module loader tests", &run_module_loader_spec_tests.step);
    const declaration_spec_mod = createModule(ctx, "tests/compiler/declarations/spec_tests.zig", &.{
        import("compiler", compiler_mod),
    }, true);
    const declaration_spec_tests = addTestArtifact(ctx, declaration_spec_mod);
    const run_declaration_spec_tests = b.addRunArtifact(declaration_spec_tests);
    test_step.dependOn(&run_declaration_spec_tests.step);
    addFocusedTestStep(b, "test-declarations", "Run focused shared declaration index tests", &run_declaration_spec_tests.step);

    const nominal_spec_mod = createModule(ctx, "tests/compiler/nominal/spec_tests.zig", &.{
        import("compiler", compiler_mod),
    }, true);
    const nominal_spec_tests = addTestArtifact(ctx, nominal_spec_mod);
    const run_nominal_spec_tests = b.addRunArtifact(nominal_spec_tests);
    test_step.dependOn(&run_nominal_spec_tests.step);
    addFocusedTestStep(b, "test-nominal-types", "Run focused nominal type identity tests", &run_nominal_spec_tests.step);

    const inheritance_spec_mod = createModule(ctx, "tests/compiler/inheritance/spec_tests.zig", &.{
        import("compiler", compiler_mod),
    }, true);
    const inheritance_spec_tests = addTestArtifact(ctx, inheritance_spec_mod);
    const run_inheritance_spec_tests = b.addRunArtifact(inheritance_spec_tests);
    test_step.dependOn(&run_inheritance_spec_tests.step);
    addFocusedTestStep(b, "test-inheritance", "Run focused object inheritance tests", &run_inheritance_spec_tests.step);
    const return_facts_mod = createModule(ctx, "tests/analysis/return_facts/spec_tests.zig", &.{
        import("compiler", compiler_mod),
    }, true);
    const return_facts_tests = addTestArtifact(ctx, return_facts_mod);
    const run_return_facts_tests = b.addRunArtifact(return_facts_tests);
    test_step.dependOn(&run_return_facts_tests.step);
    addFocusedTestStep(b, "test-return-facts", "Run focused argument-sensitive return inference tests", &run_return_facts_tests.step);
    const captures_spec_mod = createModule(ctx, "tests/analysis/captures/spec_tests.zig", &.{
        import("compiler", compiler_mod),
    }, true);
    const captures_spec_tests = addTestArtifact(ctx, captures_spec_mod);
    const run_captures_spec_tests = b.addRunArtifact(captures_spec_tests);
    test_step.dependOn(&run_captures_spec_tests.step);
    addFocusedTestStep(b, "test-captures", "Run focused lambda capture analysis tests", &run_captures_spec_tests.step);
    const environment_spec_mod = createModule(ctx, "tests/eval/environment/spec_tests.zig", &.{
        import("compiler", compiler_mod),
    }, true);
    const environment_spec_tests = addTestArtifact(ctx, environment_spec_mod);
    const run_environment_spec_tests = b.addRunArtifact(environment_spec_tests);
    test_step.dependOn(&run_environment_spec_tests.step);
    addFocusedTestStep(b, "test-eval-environment", "Run focused evaluation environment tests", &run_environment_spec_tests.step);
    const resources_spec_mod = createModule(ctx, "tests/analysis/resources/spec_tests.zig", &.{
        import("compiler", compiler_mod),
    }, true);
    const resources_spec_tests = addTestArtifact(ctx, resources_spec_mod);
    const run_resources_spec_tests = b.addRunArtifact(resources_spec_tests);
    test_step.dependOn(&run_resources_spec_tests.step);
    addFocusedTestStep(b, "test-resource-index", "Run focused dependency resource index tests", &run_resources_spec_tests.step);
    const completion_spec_mod = createModule(ctx, "tests/lsp/completion/spec_tests.zig", &.{
        import("compiler", compiler_mod),
    }, true);
    const completion_spec_tests = addTestArtifact(ctx, completion_spec_mod);
    const run_completion_spec_tests = b.addRunArtifact(completion_spec_tests);
    test_step.dependOn(&run_completion_spec_tests.step);
    addFocusedTestStep(b, "test-completion", "Run focused analysis completion tests", &run_completion_spec_tests.step);
    const source_index_mod = createModule(ctx, "tests/utils/source/index_spec_tests.zig", &.{
        import("utils", modules.utils),
    }, null);
    const source_index_tests = addTestArtifact(ctx, source_index_mod);
    const run_source_index_tests = b.addRunArtifact(source_index_tests);
    test_step.dependOn(&run_source_index_tests.step);
    const lsp_positions_api = createCommonModule(ctx, "src/lsp.zig", modules, true);
    const lsp_positions_mod = createModule(ctx, "tests/lsp/source_positions/spec_tests.zig", &.{
        import("lsp", lsp_positions_api),
    }, true);
    const lsp_positions_tests = addTestArtifact(ctx, lsp_positions_mod);
    const run_lsp_positions_tests = b.addRunArtifact(lsp_positions_tests);
    test_step.dependOn(&run_lsp_positions_tests.step);
    const source_positions_step = b.step("test-source-positions", "Run focused source position and document update tests");
    source_positions_step.dependOn(&run_source_index_tests.step);
    source_positions_step.dependOn(&run_lsp_positions_tests.step);
    const editor_edit_mod = createModule(ctx, "src/editor/edit.zig", &.{
        import("model", modules.model),
        import("utils", modules.utils),
    }, null);
    const editor_edit_spec_mod = createModule(ctx, "tests/editor/edit/spec_tests.zig", &.{
        import("editor_edit", editor_edit_mod),
    }, null);
    const editor_edit_spec_tests = addTestArtifact(ctx, editor_edit_spec_mod);
    const run_editor_edit_spec_tests = b.addRunArtifact(editor_edit_spec_tests);
    test_step.dependOn(&run_editor_edit_spec_tests.step);
    addFocusedTestStep(b, "test-editor-edit", "Run focused WYSIWYG source edit tests", &run_editor_edit_spec_tests.step);
    const generated_edit_spec_mod = createModule(ctx, "tests/editor/edit/generated/spec_tests.zig", &.{
        import("editor_edit", editor_edit_mod),
    }, null);
    const generated_edit_spec_tests = addTestArtifact(ctx, generated_edit_spec_mod);
    const run_generated_edit_spec_tests = b.addRunArtifact(generated_edit_spec_tests);
    test_step.dependOn(&run_generated_edit_spec_tests.step);
    addFocusedTestStep(b, "test-editor-generated", "Run focused generated edit validation and ownership tests", &run_generated_edit_spec_tests.step);
    const editor_icons_mod = createModule(ctx, "src/editor/icons.zig", &.{
        import("core", modules.core),
        import("utils", modules.utils),
    }, true);
    const editor_icons_spec_mod = createModule(ctx, "tests/editor/icons/catalog_spec_tests.zig", &.{
        import("core", modules.core),
        import("editor_icons", editor_icons_mod),
    }, true);
    const editor_icons_spec_tests = addTestArtifact(ctx, editor_icons_spec_mod);
    const run_editor_icons_spec_tests = b.addRunArtifact(editor_icons_spec_tests);
    test_step.dependOn(&run_editor_icons_spec_tests.step);
    addFocusedTestStep(b, "test-icons", "Run focused bundled icon catalog tests", &run_editor_icons_spec_tests.step);
    const watch_mod = createCommonModule(ctx, "src/watch.zig", modules, true);
    addNativePdfHeadersAndLibraries(b, watch_mod);
    const watch_spec_mod = createModule(ctx, "tests/watch/fingerprint/spec_tests.zig", &.{
        import("watch", watch_mod),
        import("utils", modules.utils),
    }, true);
    const watch_spec_tests = addTestArtifact(ctx, watch_spec_mod);
    const run_watch_spec_tests = b.addRunArtifact(watch_spec_tests);
    test_step.dependOn(&run_watch_spec_tests.step);
    addFocusedTestStep(b, "test-watch", "Run focused watch dependency tests", &run_watch_spec_tests.step);
    const watch_inputs_spec = b.addSystemCommand(&.{"node"});
    watch_inputs_spec.step.dependOn(&ctx.dependency_checks.node.step);
    watch_inputs_spec.addFileArg(b.path("tests/runtime/watch/inputs/spec.mjs"));
    watch_inputs_spec.addFileArg(exe.getEmittedBin());
    watch_inputs_spec.setCwd(b.path("."));
    watch_inputs_spec.stdio = .inherit;
    test_step.dependOn(&watch_inputs_spec.step);
    addFocusedTestStep(b, "test-watch-inputs", "Run focused observed watch input tests", &watch_inputs_spec.step);
    const watch_latex_spec = b.addSystemCommand(&.{"node"});
    watch_latex_spec.step.dependOn(&ctx.dependency_checks.node.step);
    watch_latex_spec.addFileArg(b.path("tests/runtime/watch/latex/spec.mjs"));
    watch_latex_spec.addFileArg(exe.getEmittedBin());
    watch_latex_spec.setCwd(b.path("."));
    watch_latex_spec.stdio = .inherit;
    test_step.dependOn(&watch_latex_spec.step);
    addFocusedTestStep(b, "test-watch-latex", "Run focused TeX dependency and watch recovery tests", &watch_latex_spec.step);
    const watch_configuration_spec = b.addSystemCommand(&.{"node"});
    watch_configuration_spec.step.dependOn(&ctx.dependency_checks.node.step);
    watch_configuration_spec.addFileArg(b.path("tests/runtime/watch/configuration/spec.mjs"));
    watch_configuration_spec.addFileArg(exe.getEmittedBin());
    watch_configuration_spec.setCwd(b.path("."));
    watch_configuration_spec.stdio = .inherit;
    test_step.dependOn(&watch_configuration_spec.step);
    addFocusedTestStep(b, "test-watch-configuration", "Run focused watch configuration reload tests", &watch_configuration_spec.step);
    const file_inputs_mod = createModule(ctx, "tests/utils/file_inputs/spec_tests.zig", &.{
        import("utils", modules.utils),
    }, true);
    const file_inputs_tests = addTestArtifact(ctx, file_inputs_mod);
    const run_file_inputs_tests = b.addRunArtifact(file_inputs_tests);
    test_step.dependOn(&run_file_inputs_tests.step);
    addFocusedTestStep(b, "test-file-inputs", "Run focused filesystem input ownership tests", &run_file_inputs_tests.step);
    addRenderTests(ctx, modules, build_options, test_step);
    const render_wrap_mod = createModule(ctx, "src/render/text/wrap.zig", &.{}, null);
    addModuleTest(ctx, test_step, "tests/render/wrap/spec_tests.zig", &.{
        import("render_wrap", render_wrap_mod),
    }, null);

    const binding_types_mod = createModule(ctx, "tests/compiler/bindings/spec_tests.zig", &.{
        import("compiler", compiler_mod),
    }, true);
    const binding_types_tests = addTestArtifact(ctx, binding_types_mod);
    const run_binding_types_tests = b.addRunArtifact(binding_types_tests);
    test_step.dependOn(&run_binding_types_tests.step);
    addFocusedTestStep(b, "test-binding-types", "Run focused checked binding type tests", &run_binding_types_tests.step);

    const compiler_semantics_support_mod = createModule(ctx, "tests/compiler/semantics/support.zig", &.{
        import("utils", modules.utils),
        import("compiler", compiler_mod),
    }, true);
    const compiler_semantics_mod = createModule(ctx, "tests/compiler/semantics/spec_tests.zig", &.{
        import("compiler_semantics", compiler_semantics_support_mod),
    }, true);
    const compiler_semantics_tests = addTestArtifact(ctx, compiler_semantics_mod);
    const run_compiler_semantics_tests = b.addRunArtifact(compiler_semantics_tests);
    test_step.dependOn(&run_compiler_semantics_tests.step);
    addFocusedTestStep(b, "test-compiler-semantics", "Run focused compiler semantic tests", &run_compiler_semantics_tests.step);

    addNodeSpecTests(ctx, test_step, exe);
    addSmokeChecks(b, test_step, exe);
}

fn addRenderTests(
    ctx: BuildContext,
    modules: ProjectModules,
    build_options: *Step.Options,
    test_step: *Step,
) void {
    const b = ctx.b;
    const render_latex_mod = createModule(ctx, "src/render/compile/latex.zig", &.{}, null);
    const render_latex_spec_mod = createModule(ctx, "tests/render/latex/spec_tests.zig", &.{
        import("render_latex", render_latex_mod),
    }, null);
    const render_latex_spec_tests = addTestArtifact(ctx, render_latex_spec_mod);
    const run_render_latex_spec_tests = b.addRunArtifact(render_latex_spec_tests);
    test_step.dependOn(&run_render_latex_spec_tests.step);
    addFocusedTestStep(b, "test-render-latex", "Run focused LaTeX document tests", &run_render_latex_spec_tests.step);
    const latex_inputs_mod = createModule(ctx, "src/render/compile/latex_inputs.zig", &.{
        import("utils", modules.utils),
        import("render_resources", modules.render_resources),
    }, null);
    const latex_inputs_spec_mod = createModule(ctx, "tests/render/latex/inputs/spec_tests.zig", &.{
        import("latex_inputs", latex_inputs_mod),
        import("utils", modules.utils),
        import("render_resources", modules.render_resources),
    }, null);
    const latex_inputs_tests = addTestArtifact(ctx, latex_inputs_spec_mod);
    const run_latex_inputs_tests = b.addRunArtifact(latex_inputs_tests);
    test_step.dependOn(&run_latex_inputs_tests.step);
    addFocusedTestStep(b, "test-latex-inputs", "Run focused TeX recorder and dependency manifest tests", &run_latex_inputs_tests.step);
    const render_pdf_document_mod = createModule(ctx, "src/render/pdf.zig", &.{
        import("pdf_backend", modules.pdf_backend),
        import("pdf_ffi", modules.pdf_ffi),
        import("render", modules.render),
        import("render_resources", modules.render_resources),
        import("utils", modules.utils),
    }, true);
    const render_test_support_mod = createModule(ctx, "tests/render/support.zig", &.{
        import("core", modules.core),
        import("render", modules.render),
        import("render_resources", modules.render_resources),
        import("render_text", modules.render_text),
    }, true);
    const render_pdf_spec_mod = createModule(ctx, "tests/render/pdf/spec_tests.zig", &.{
        import("pdf_backend", modules.pdf_backend),
        import("pdf_document", render_pdf_document_mod),
        import("render", modules.render),
        import("render_resources", modules.render_resources),
        import("render_test_support", render_test_support_mod),
    }, true);
    addNativePdfHeadersAndLibraries(b, render_pdf_spec_mod);
    const render_pdf_spec_tests = addQpdfTestArtifact(ctx, render_pdf_spec_mod);
    const run_render_pdf_spec_tests = b.addRunArtifact(render_pdf_spec_tests);
    run_render_pdf_spec_tests.step.dependOn(&ctx.dependency_checks.qpdf_cli.step);
    test_step.dependOn(&run_render_pdf_spec_tests.step);
    addFocusedTestStep(b, "test-render-pdf", "Run focused native PDF renderer tests", &run_render_pdf_spec_tests.step);
    const render_spec_mod = createModule(ctx, "tests/render/ir/spec_tests.zig", &.{
        import("render", modules.render),
        import("render_resources", modules.render_resources),
        import("render_test_support", render_test_support_mod),
    }, null);
    const render_spec_tests = addQpdfTestArtifact(ctx, render_spec_mod);
    const run_render_spec_tests = b.addRunArtifact(render_spec_tests);
    test_step.dependOn(&run_render_spec_tests.step);
    addFocusedTestStep(b, "test-render-ir", "Run focused render IR tests", &run_render_spec_tests.step);
    const render_html_mod = createModule(ctx, "src/render/html.zig", &.{
        import("core", modules.core),
        import("html_embeds", modules.html_embeds),
        import("render", modules.render),
        import("pdfjs_assets", modules.pdfjs_assets),
        import("utils", modules.utils),
    }, null);
    const render_html_spec_mod = createModule(ctx, "tests/render/html/spec_tests.zig", &.{
        import("pdf_ffi", modules.pdf_ffi),
        import("render", modules.render),
        import("render_html", render_html_mod),
        import("render_resources", modules.render_resources),
        import("render_test_support", render_test_support_mod),
    }, null);
    const render_html_spec_tests = addQpdfTestArtifact(ctx, render_html_spec_mod);
    const run_render_html_spec_tests = b.addRunArtifact(render_html_spec_tests);
    test_step.dependOn(&run_render_html_spec_tests.step);
    addFocusedTestStep(b, "test-render-html", "Run focused HTML renderer tests", &run_render_html_spec_tests.step);
    const render_html_font_mod = createModule(ctx, "src/render/html/font.zig", &.{}, null);
    const render_html_font_spec_mod = createModule(ctx, "tests/render/html/font_spec_tests.zig", &.{
        import("render_html_font", render_html_font_mod),
    }, null);
    const render_html_font_spec_tests = addTestArtifact(ctx, render_html_font_spec_mod);
    const run_render_html_font_spec_tests = b.addRunArtifact(render_html_font_spec_tests);
    test_step.dependOn(&run_render_html_font_spec_tests.step);
    addFocusedTestStep(b, "test-render-html-font", "Run focused HTML font extraction tests", &run_render_html_font_spec_tests.step);
    const render_compile_mod = createModule(ctx, "src/render/compile.zig", &.{
        import("core", modules.core),
        import("pdf_ffi", modules.pdf_ffi),
        import("render", modules.render),
        import("render_emitter", modules.render_emitter),
        import("render_resources", modules.render_resources),
        import("render_measurements", modules.render_measurements),
        import("render_text", modules.render_text),
        import("utils", modules.utils),
    }, null);
    render_compile_mod.addOptions("build_options", build_options);
    const render_compile_spec_mod = createModule(ctx, "tests/render/compile/spec_tests.zig", &.{
        import("ast", modules.ast),
        import("core", modules.core),
        import("pdf_ffi", modules.pdf_ffi),
        import("render", modules.render),
        import("render_compile", render_compile_mod),
        import("render_emitter", modules.render_emitter),
        import("render_resources", modules.render_resources),
        import("render_text", modules.render_text),
    }, null);
    const render_compile_spec_tests = addQpdfTestArtifact(ctx, render_compile_spec_mod);
    const run_render_compile_spec_tests = b.addRunArtifact(render_compile_spec_tests);
    test_step.dependOn(&run_render_compile_spec_tests.step);
    addFocusedTestStep(b, "test-render-compile", "Run focused render compiler tests", &run_render_compile_spec_tests.step);
    const measurement_store_spec_mod = createModule(ctx, "tests/render/measurement_store/spec_tests.zig", &.{
        import("core", modules.core),
        import("render_measurements", modules.render_measurements),
    }, null);
    const measurement_store_tests = addTestArtifact(ctx, measurement_store_spec_mod);
    const run_measurement_store_tests = b.addRunArtifact(measurement_store_tests);
    test_step.dependOn(&run_measurement_store_tests.step);
    addFocusedTestStep(b, "test-render-measurements", "Run focused measurement storage tests", &run_measurement_store_tests.step);
    const font_environment_spec_mod = createModule(ctx, "tests/render/font_environment/spec_tests.zig", &.{
        import("pdf_ffi", modules.pdf_ffi),
        import("render_text", modules.render_text),
    }, true);
    addNativePdfHeadersAndLibraries(b, font_environment_spec_mod);
    const font_environment_spec_tests = addTestArtifact(ctx, font_environment_spec_mod);
    const run_font_environment_spec_tests = b.addRunArtifact(font_environment_spec_tests);
    test_step.dependOn(&run_font_environment_spec_tests.step);
    addFocusedTestStep(b, "test-font-environment", "Run isolated font environment invalidation tests", &run_font_environment_spec_tests.step);
    const highlight_cache_spec_mod = createModule(ctx, "tests/render/highlight/cache/spec_tests.zig", &.{
        import("render_compile", render_compile_mod),
        import("utils", modules.utils),
    }, null);
    const highlight_cache_spec_tests = addTestArtifact(ctx, highlight_cache_spec_mod);
    const run_highlight_cache_spec_tests = b.addRunArtifact(highlight_cache_spec_tests);
    test_step.dependOn(&run_highlight_cache_spec_tests.step);
    addFocusedTestStep(b, "test-highlight-cache", "Run focused highlight query and content cache tests", &run_highlight_cache_spec_tests.step);
}

fn addFocusedTestStep(b: *std.Build, name: []const u8, description: []const u8, dependency: *Step) void {
    b.step(name, description).dependOn(dependency);
}

fn createHtmlEmbedsModule(ctx: BuildContext) *Module {
    const b = ctx.b;
    const files = b.addWriteFiles();
    const resource_module = javascriptDataUrl(b, "src/render/html/resources.js", 256 * 1024);
    const navigation_module = javascriptDataUrl(b, "src/render/html/navigation.js", 256 * 1024);
    const text_module = javascriptDataUrl(b, "src/render/html/text.js", 256 * 1024);
    const pdf_controller_module = javascriptDataUrl(b, "src/render/html/pdf/controller.js", 256 * 1024);
    const pdf_geometry_module = javascriptDataUrl(b, "src/render/html/pdf/geometry.js", 256 * 1024);
    const pdf_placement_module = javascriptDataUrl(b, "src/render/html/pdf/placement.js", 256 * 1024);
    const pdf_queue_module = javascriptDataUrl(b, "src/render/html/pdf/queue.js", 256 * 1024);
    const pdf_renderer_module = javascriptDataUrl(b, "src/render/html/pdf/index.js", 256 * 1024);
    const pdf_service_module = javascriptDataUrl(b, "src/render/html/pdf/service.js", 256 * 1024);
    const pdfjs_module = javascriptDataUrl(b, "third_party/pdfjs/pdf.mjs", 2 * 1024 * 1024);
    const pdf_worker_module = javascriptDataUrl(b, "third_party/pdfjs/pdf.worker.mjs", 4 * 1024 * 1024);
    const pdf_import_map = b.fmt(
        "{{\"imports\":{{\"@ss/pdf/controller\":\"{s}\",\"@ss/pdf/geometry\":\"{s}\",\"@ss/pdf/placement\":\"{s}\",\"@ss/pdf/queue\":\"{s}\",\"@ss/pdf/service\":\"{s}\"}}}}",
        .{ pdf_controller_module, pdf_geometry_module, pdf_placement_module, pdf_queue_module, pdf_service_module },
    );

    _ = files.add("resource-module.txt", resource_module);
    _ = files.add("navigation-module.txt", navigation_module);
    _ = files.add("text-module.txt", text_module);
    _ = files.add("pdf-import-map.json", pdf_import_map);
    _ = files.add("pdf-renderer-module.txt", pdf_renderer_module);
    _ = files.add("pdfjs-module.txt", pdfjs_module);
    _ = files.add("pdf-worker-module.txt", pdf_worker_module);
    const root = files.add("root.zig",
        \\pub const resource_module = @embedFile("resource-module.txt");
        \\pub const navigation_module = @embedFile("navigation-module.txt");
        \\pub const text_module = @embedFile("text-module.txt");
        \\pub const pdf_import_map = @embedFile("pdf-import-map.json");
        \\pub const pdf_renderer_module = @embedFile("pdf-renderer-module.txt");
        \\pub const pdfjs_module = @embedFile("pdfjs-module.txt");
        \\pub const pdf_worker_module = @embedFile("pdf-worker-module.txt");
    );
    return b.createModule(.{
        .root_source_file = root,
        .target = ctx.target,
        .optimize = ctx.optimize,
    });
}

fn javascriptDataUrl(b: *std.Build, path: []const u8, max_bytes: usize) []const u8 {
    const source = b.build_root.handle.readFileAlloc(b.graph.io, path, b.allocator, .limited(max_bytes)) catch
        std.debug.panic("HTML runtime source is missing: {s}", .{path});
    const prefix = "data:text/javascript;charset=utf-8;base64,";
    const result = b.allocator.alloc(u8, prefix.len + std.base64.standard.Encoder.calcSize(source.len)) catch @panic("OOM");
    @memcpy(result[0..prefix.len], prefix);
    _ = std.base64.standard.Encoder.encode(result[prefix.len..], source);
    return result;
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
        import("project", modules.project),
        import("ast", modules.ast),
        import("model", modules.model),
        import("language_type", modules.language_type),
        import("stdlib_assets", modules.stdlib_assets),
        import("fontawesome_assets", modules.fontawesome_assets),
        import("pdfjs_assets", modules.pdfjs_assets),
        import("html_embeds", modules.html_embeds),
        import("render", modules.render),
        import("render_resources", modules.render_resources),
        import("render_measurements", modules.render_measurements),
        import("pdf_ffi", modules.pdf_ffi),
        import("render_text", modules.render_text),
        import("render_emitter", modules.render_emitter),
        import("pdf_backend", modules.pdf_backend),
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
    addTestModule(ctx, test_step, test_mod);
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
    addTestModule(ctx, test_step, test_mod);
    return test_mod;
}

fn addTestModule(ctx: BuildContext, test_step: *Step, module: *Module) void {
    const test_artifact = addTestArtifact(ctx, module);
    test_step.dependOn(&ctx.b.addRunArtifact(test_artifact).step);
}

fn addTestArtifact(ctx: BuildContext, module: *Module) *Step.Compile {
    const artifact = ctx.b.addTest(.{ .root_module = module });
    if (dependencies.requiresNativePdf(ctx.b, module)) {
        artifact.step.dependOn(&ctx.dependency_checks.native_pdf.step);
    }
    return artifact;
}

fn addQpdfTestModule(ctx: BuildContext, test_step: *Step, module: *Module) void {
    const test_artifact = addQpdfTestArtifact(ctx, module);
    test_step.dependOn(&ctx.b.addRunArtifact(test_artifact).step);
}

fn addQpdfTestArtifact(ctx: BuildContext, module: *Module) *Step.Compile {
    qpdf.link(ctx.qpdf_bridge, ctx.b, module, ctx.target, .build);
    const artifact = addTestArtifact(ctx, module);
    artifact.step.dependOn(&ctx.qpdf_bridge.install.step);
    return artifact;
}

fn addNodeSpecTests(ctx: BuildContext, test_step: *Step, exe: *Step.Compile) void {
    const b = ctx.b;
    const node_spec_files = [_][]const u8{
        "tests/editor/build-status/spec.mjs",
        "tests/editor/component-width/spec.mjs",
        "tests/editor/deletion/spec.mjs",
        "tests/editor/locks/spec.mjs",
        "tests/editor/navigation/spec.mjs",
        "tests/editor/shapes/spec.mjs",
        "tests/editor/icons/webview_spec.mjs",
        "tests/editor/edit_queue/spec.mjs",
        "tests/editor/translation/spec.mjs",
        "tests/runtime/cli_diagnostics_runtime_spec.mjs",
        "tests/runtime/completion_runtime_spec.mjs",
        "tests/runtime/debug_runtime_spec.mjs",
        "tests/runtime/doctor_runtime_spec.mjs",
        "tests/runtime/editor/diagnostics/spec.mjs",
        "tests/runtime/editor/deletion/spec.mjs",
        "tests/runtime/editor/empty/spec.mjs",
        "tests/runtime/editor/icons/spec.mjs",
        "tests/runtime/editor/names/spec.mjs",
        "tests/runtime/editor/relations/spec.mjs",
        "tests/runtime/editor/shapes/spec.mjs",
        "tests/runtime/editor/spec.mjs",
        "tests/runtime/layout/frame_too_small_spec.mjs",
        "tests/runtime/layout/measurement_spec.mjs",
        "tests/runtime/layout/vflow/policy_spec.mjs",
        "tests/runtime/lsp/cancellation/spec.mjs",
        "tests/runtime/lsp/diagnostics/spec.mjs",
        "tests/runtime/lsp/generated_edit/spec.mjs",
        "tests/runtime/lsp/manual_wysiwyg/spec.mjs",
        "tests/runtime/lsp/protocol/spec.mjs",
        "tests/runtime/lsp/render_cancellation/spec.mjs",
        "tests/runtime/lsp_completion_runtime_spec.mjs",
        "tests/runtime/lsp_editor_runtime_spec.mjs",
        "tests/runtime/markdown_table_alignment_runtime_spec.mjs",
        "tests/runtime/math_pdf_runtime_spec.mjs",
        "tests/runtime/math_scaling_runtime_spec.mjs",
        "tests/runtime/render_page_bounds_runtime_spec.mjs",
        "tests/runtime/render_cache_runtime_spec.mjs",
        "tests/runtime/render_diagnostics_runtime_spec.mjs",
        "tests/runtime/render/html/spec.mjs",
        "tests/runtime/render/markdown_underline/spec.mjs",
        "tests/runtime/render/vector_shapes/spec.mjs",
        "tests/runtime/stdlib_wrappers_runtime_spec.mjs",
        "tests/runtime/theme/spec.mjs",
    };

    for (node_spec_files) |path| {
        const node_spec = b.addSystemCommand(&.{"node"});
        node_spec.step.dependOn(&ctx.dependency_checks.node.step);
        node_spec.setName(b.fmt("node {s}", .{path}));
        node_spec.addFileArg(b.path(path));
        node_spec.addFileArg(exe.getEmittedBin());
        node_spec.setCwd(b.path("."));
        node_spec.stdio = .inherit;
        test_step.dependOn(&node_spec.step);
    }

    const vscode_tests = b.addSystemCommand(&.{ "npm", "test" });
    vscode_tests.setName("npm test (editor/vscode)");
    vscode_tests.setCwd(b.path("editor/vscode"));
    vscode_tests.stdio = .inherit;
    vscode_tests.step.dependOn(&ctx.dependency_checks.vscode_packages.step);
    test_step.dependOn(&vscode_tests.step);

    const project_settings_tests = b.addSystemCommand(&.{ "node", "tests/editor/vscode/project_config/spec.mjs" });
    project_settings_tests.setCwd(b.path("."));
    project_settings_tests.stdio = .inherit;
    project_settings_tests.step.dependOn(&ctx.dependency_checks.vscode_packages.step);
    addFocusedTestStep(b, "test-editor-project-settings", "Run focused editor project settings cache tests", &project_settings_tests.step);

    const editor_view_tests = b.addSystemCommand(&.{ "node", "tests/editor/vscode/view/spec.mjs" });
    editor_view_tests.setCwd(b.path("."));
    editor_view_tests.stdio = .inherit;
    editor_view_tests.step.dependOn(&ctx.dependency_checks.vscode_packages.step);
    addFocusedTestStep(b, "test-editor-view", "Run focused editor view resource tests", &editor_view_tests.step);
}

fn addBuildDependencyDiagnosticTest(ctx: BuildContext) void {
    const b = ctx.b;
    const spec = b.addSystemCommand(&.{"node"});
    spec.setName("node tests/build/dependencies/spec.mjs");
    spec.addFileArg(b.path("tests/build/dependencies/spec.mjs"));
    spec.addFileArg(ctx.dependency_checks.executable.getEmittedBin());
    spec.setCwd(b.path("."));
    spec.stdio = .inherit;
    spec.step.dependOn(&ctx.dependency_checks.node.step);
    const step = b.step("test-build-dependencies", "Check friendly build dependency diagnostics");
    step.dependOn(&spec.step);
}

fn addSmokeChecks(b: *std.Build, test_step: *Step, exe: *Step.Compile) void {
    const smoke_check_files = [_][]const u8{
        "stdlib/core/classes.ss",
        "stdlib/core/components.ss",
        "stdlib/core/generated.ss",
        "stdlib/core/layout.ss",
        "stdlib/core/objects.ss",
        "stdlib/core/paths.ss",
        "stdlib/core/fills.ss",
        "stdlib/core/shapes.ss",
        "stdlib/core/connectors.ss",
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
    addNativePdfHeadersAndLibraries(b, module);
    module.addCSourceFiles(.{
        .root = b.path("src/render/pdf"),
        .files = &.{ "cairo.c", "assets.c" },
    });
}

fn addTreeSitterSources(ctx: BuildContext, module: *Module, tree_sitter: TreeSitterBundle) void {
    const b = ctx.b;
    addTreeSitterIncludePaths(b, module, tree_sitter);
    addTreeSitterRuntimeSource(ctx, module, tree_sitter);
    addTreeSitterCSourceFile(ctx, module, b.path("editor/tree-sitter-ss/src/parser.c"));
    for (generated_tree_sitter_sources) |source| {
        addTreeSitterCSourceFile(ctx, module, tree_sitter.root.path(b, b.fmt("generated/{s}", .{source})));
    }
    module.addIncludePath(b.path("editor/tree-sitter-ss/src"));
}

fn addNativePdfHeadersAndLibraries(b: *std.Build, module: *Module) void {
    module.addIncludePath(b.path("src/render/pdf"));
    module.linkSystemLibrary("ss-pdf", .{ .use_pkg_config = .force });
}

fn addTreeSitterIncludePaths(b: *std.Build, module: *Module, tree_sitter: TreeSitterBundle) void {
    module.addIncludePath(tree_sitter.root.path(b, "runtime/source/lib/include"));
    module.addIncludePath(tree_sitter.root.path(b, "runtime/source/lib/src"));
}

fn addTreeSitterRuntimeSource(ctx: BuildContext, module: *Module, tree_sitter: TreeSitterBundle) void {
    addTreeSitterCSourceFile(ctx, module, tree_sitter.root.path(ctx.b, "runtime/source/lib/src/lib.c"));
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
        .file = b.path("src/tree_sitter/abi_check.c"),
    });
    for (generated_tree_sitter_sources) |source| {
        addTreeSitterCSourceFile(ctx, check_mod, tree_sitter.root.path(b, b.fmt("generated/{s}", .{source})));
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
        run_check.addArg("--trace");
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
