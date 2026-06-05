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

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const ctx = BuildContext{ .b = b, .target = target, .optimize = optimize };

    const release_version = readReleaseVersion(b) catch @panic("release/VERSION must contain the release version.");
    const default_version = b.fmt("{s}-dev", .{release_version});
    const version = b.option([]const u8, "version", "Version string reported by `ss --version`") orelse default_version;
    const commit = b.option([]const u8, "commit", "Source commit reported by `ss --version`") orelse "unknown";
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", version);
    build_options.addOption([]const u8, "commit", commit);

    const md4c_src = "third_party/md4c/src";
    b.build_root.handle.access(b.graph.io, md4c_src ++ "/md4c.c", .{}) catch
        @panic("MD4C sources are missing; run `scripts/setup-md4c.sh` before `zig build`.");
    addPdfPkgConfigPath(b);

    const modules = createProjectModules(ctx, md4c_src, b.path(md4c_src));
    const exe_mod = createCliModule(ctx, modules, build_options);
    const exe = b.addExecutable(.{
        .name = "ss",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the ss CLI");
    run_step.dependOn(&run_cmd.step);

    addTestStep(ctx, modules, build_options, exe);
}

fn createProjectModules(ctx: BuildContext, md4c_src: []const u8, md4c_include: std.Build.LazyPath) ProjectModules {
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
    core_mod.addIncludePath(md4c_include);
    core_mod.addCSourceFiles(.{
        .root = ctx.b.path(md4c_src),
        .files = &.{"md4c.c"},
    });

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
    addNativePdfBackend(ctx.b, module);
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
    addModuleTest(ctx, test_step, "tests/layout_graph_spec_tests.zig", &.{
        import("core", modules.core),
        import("utils", modules.utils),
        import("ast", modules.ast),
        import("model", modules.model),
        import("language_type", modules.language_type),
    }, true);
    addModuleTest(ctx, test_step, "tests/project_spec_tests.zig", &.{
        import("project", modules.project),
    }, null);
    const lsp_scope_mod = createModule(ctx, "src/lsp/scope.zig", &.{
        import("utils", modules.utils),
    }, true);
    addModuleTest(ctx, test_step, "tests/lsp_scope_spec_tests.zig", &.{
        import("lsp_scope", lsp_scope_mod),
    }, true);

    const compiler_mod = createCommonModule(ctx, "src/compiler.zig", modules, true);
    const compiler_semantics_support_mod = createModule(ctx, "tests/compiler_semantics_spec_support.zig", &.{
        import("utils", modules.utils),
        import("compiler", compiler_mod),
    }, true);
    addModuleTest(ctx, test_step, "tests/compiler_semantics_spec_tests.zig", &.{
        import("compiler_semantics", compiler_semantics_support_mod),
    }, true);

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
    module.addIncludePath(b.path("src/render/pdf"));
    module.addCSourceFile(.{
        .file = b.path("src/render/pdf/pdf.c"),
    });
    module.linkSystemLibrary("ss-pdf", .{ .use_pkg_config = .force });
}

fn readReleaseVersion(b: *std.Build) ![]const u8 {
    const raw = try b.build_root.handle.readFileAlloc(b.graph.io, "release/VERSION", b.allocator, .limited(64));
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return error.EmptyVersion;
    return trimmed;
}
