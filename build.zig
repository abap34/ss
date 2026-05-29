const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
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
    const md4c_include = b.path(md4c_src);

    const utils_mod = b.createModule(.{
        .root_source_file = b.path("src/utils/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const model_mod = b.createModule(.{
        .root_source_file = b.path("src/core/model.zig"),
        .target = target,
        .optimize = optimize,
    });

    const language_type_mod = b.createModule(.{
        .root_source_file = b.path("src/language/type.zig"),
        .target = target,
        .optimize = optimize,
    });
    language_type_mod.addImport("model", model_mod);

    const ast_mod = b.createModule(.{
        .root_source_file = b.path("src/ast.zig"),
        .target = target,
        .optimize = optimize,
    });
    ast_mod.addImport("model", model_mod);
    ast_mod.addImport("language_type", language_type_mod);

    const stdlib_assets_mod = b.createModule(.{
        .root_source_file = b.path("stdlib/embed.zig"),
        .target = target,
        .optimize = optimize,
    });

    const project_mod = b.createModule(.{
        .root_source_file = b.path("src/project.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    project_mod.addImport("utils", utils_mod);

    const core_mod = b.createModule(.{
        .root_source_file = b.path("src/core.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    core_mod.addImport("utils", utils_mod);
    core_mod.addImport("ast", ast_mod);
    core_mod.addImport("model", model_mod);
    core_mod.addImport("language_type", language_type_mod);
    core_mod.addIncludePath(md4c_include);
    core_mod.addCSourceFiles(.{
        .root = b.path(md4c_src),
        .files = &.{"md4c.c"},
    });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    exe_mod.addImport("core", core_mod);
    exe_mod.addImport("utils", utils_mod);
    exe_mod.addImport("ast", ast_mod);
    exe_mod.addImport("model", model_mod);
    exe_mod.addImport("language_type", language_type_mod);
    exe_mod.addImport("stdlib_assets", stdlib_assets_mod);
    exe_mod.addOptions("build_options", build_options);
    addNativePdfBackend(b, exe_mod);

    const exe = b.addExecutable(.{
        .name = "ss",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the ss CLI");
    run_step.dependOn(&run_cmd.step);

    const core_tests = b.addTest(.{
        .root_module = core_mod,
    });

    const parser_tests_mod = b.createModule(.{
        .root_source_file = b.path("src/syntax.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    parser_tests_mod.addImport("core", core_mod);
    parser_tests_mod.addImport("utils", utils_mod);
    parser_tests_mod.addImport("ast", ast_mod);
    parser_tests_mod.addImport("model", model_mod);
    parser_tests_mod.addImport("language_type", language_type_mod);
    parser_tests_mod.addImport("stdlib_assets", stdlib_assets_mod);
    const parser_tests = b.addTest(.{
        .root_module = parser_tests_mod,
    });

    const main_tests_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    main_tests_mod.addImport("core", core_mod);
    main_tests_mod.addImport("utils", utils_mod);
    main_tests_mod.addImport("ast", ast_mod);
    main_tests_mod.addImport("model", model_mod);
    main_tests_mod.addImport("language_type", language_type_mod);
    main_tests_mod.addImport("stdlib_assets", stdlib_assets_mod);
    main_tests_mod.addOptions("build_options", build_options);
    addNativePdfBackend(b, main_tests_mod);
    const main_tests = b.addTest(.{
        .root_module = main_tests_mod,
    });

    const syntax_spec_tests_mod = b.createModule(.{
        .root_source_file = b.path("tests/syntax_spec_tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    syntax_spec_tests_mod.addImport("core", core_mod);
    syntax_spec_tests_mod.addImport("utils", utils_mod);
    syntax_spec_tests_mod.addImport("ast", ast_mod);
    syntax_spec_tests_mod.addImport("model", model_mod);
    syntax_spec_tests_mod.addImport("language_type", language_type_mod);
    syntax_spec_tests_mod.addImport("syntax", parser_tests_mod);
    const syntax_spec_tests = b.addTest(.{
        .root_module = syntax_spec_tests_mod,
    });

    const language_type_spec_tests_mod = b.createModule(.{
        .root_source_file = b.path("tests/language_type_spec_tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    language_type_spec_tests_mod.addImport("model", model_mod);
    language_type_spec_tests_mod.addImport("language_type", language_type_mod);
    const language_type_spec_tests = b.addTest(.{
        .root_module = language_type_spec_tests_mod,
    });

    const language_registry_mod = b.createModule(.{
        .root_source_file = b.path("src/language/registry.zig"),
        .target = target,
        .optimize = optimize,
    });
    language_registry_mod.addImport("core", core_mod);
    language_registry_mod.addImport("language_type", language_type_mod);

    const language_registry_spec_tests_mod = b.createModule(.{
        .root_source_file = b.path("tests/language_registry_spec_tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    language_registry_spec_tests_mod.addImport("core", core_mod);
    language_registry_spec_tests_mod.addImport("model", model_mod);
    language_registry_spec_tests_mod.addImport("language_type", language_type_mod);
    language_registry_spec_tests_mod.addImport("registry", language_registry_mod);
    const language_registry_spec_tests = b.addTest(.{
        .root_module = language_registry_spec_tests_mod,
    });

    const core_ir_spec_tests_mod = b.createModule(.{
        .root_source_file = b.path("tests/core_ir_spec_tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    core_ir_spec_tests_mod.addImport("core", core_mod);
    core_ir_spec_tests_mod.addImport("utils", utils_mod);
    core_ir_spec_tests_mod.addImport("ast", ast_mod);
    core_ir_spec_tests_mod.addImport("model", model_mod);
    core_ir_spec_tests_mod.addImport("language_type", language_type_mod);
    const core_ir_spec_tests = b.addTest(.{
        .root_module = core_ir_spec_tests_mod,
    });

    const layout_graph_spec_tests_mod = b.createModule(.{
        .root_source_file = b.path("tests/layout_graph_spec_tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    layout_graph_spec_tests_mod.addImport("core", core_mod);
    layout_graph_spec_tests_mod.addImport("utils", utils_mod);
    layout_graph_spec_tests_mod.addImport("ast", ast_mod);
    layout_graph_spec_tests_mod.addImport("model", model_mod);
    layout_graph_spec_tests_mod.addImport("language_type", language_type_mod);
    const layout_graph_spec_tests = b.addTest(.{
        .root_module = layout_graph_spec_tests_mod,
    });

    const project_spec_tests_mod = b.createModule(.{
        .root_source_file = b.path("tests/project_spec_tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    project_spec_tests_mod.addImport("project", project_mod);
    const project_spec_tests = b.addTest(.{
        .root_module = project_spec_tests_mod,
    });

    const compiler_semantics_support_mod = b.createModule(.{
        .root_source_file = b.path("tests/compiler_semantics_spec_support.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const compiler_mod = b.createModule(.{
        .root_source_file = b.path("src/compiler.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    compiler_mod.addImport("core", core_mod);
    compiler_mod.addImport("utils", utils_mod);
    compiler_mod.addImport("ast", ast_mod);
    compiler_mod.addImport("model", model_mod);
    compiler_mod.addImport("language_type", language_type_mod);
    compiler_mod.addImport("stdlib_assets", stdlib_assets_mod);
    compiler_semantics_support_mod.addImport("utils", utils_mod);
    compiler_semantics_support_mod.addImport("compiler", compiler_mod);

    const compiler_semantics_spec_tests_mod = b.createModule(.{
        .root_source_file = b.path("tests/compiler_semantics_spec_tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    compiler_semantics_spec_tests_mod.addImport("compiler_semantics", compiler_semantics_support_mod);
    const compiler_semantics_spec_tests = b.addTest(.{
        .root_module = compiler_semantics_spec_tests_mod,
    });

    const smoke_check_files = [_][]const u8{
        "stdlib/core/classes.ss",
        "stdlib/core/components.ss",
        "stdlib/core/generated.ss",
        "stdlib/core/layout.ss",
        "stdlib/core/objects.ss",
        "stdlib/core/render.ss",
        "stdlib/core/selectors.ss",
        "stdlib/themes/academic.ss",
        "stdlib/themes/base.ss",
        "stdlib/themes/default.ss",
        "stdlib/themes/pop.ss",
    };

    const test_step = b.step("test", "Run ss test targets");
    test_step.dependOn(&b.addRunArtifact(core_tests).step);
    test_step.dependOn(&b.addRunArtifact(parser_tests).step);
    test_step.dependOn(&b.addRunArtifact(main_tests).step);
    test_step.dependOn(&b.addRunArtifact(syntax_spec_tests).step);
    test_step.dependOn(&b.addRunArtifact(language_type_spec_tests).step);
    test_step.dependOn(&b.addRunArtifact(language_registry_spec_tests).step);
    test_step.dependOn(&b.addRunArtifact(core_ir_spec_tests).step);
    test_step.dependOn(&b.addRunArtifact(layout_graph_spec_tests).step);
    test_step.dependOn(&b.addRunArtifact(project_spec_tests).step);
    test_step.dependOn(&b.addRunArtifact(compiler_semantics_spec_tests).step);
    for (smoke_check_files) |path| {
        const smoke_check = b.addRunArtifact(exe);
        smoke_check.addArgs(&.{ "check", path });
        test_step.dependOn(&smoke_check.step);
    }
}

fn addNativePdfBackend(b: *std.Build, module: *std.Build.Module) void {
    module.addIncludePath(b.path("src/render"));
    addLinuxPangoIncludePaths(module);
    module.addCSourceFile(.{ .file = b.path("src/render/pdf_native_c.c") });
    module.linkSystemLibrary("librsvg-2.0", .{ .use_pkg_config = .force });
    module.linkSystemLibrary("pangocairo-1.0", .{ .use_pkg_config = .no });
    module.linkSystemLibrary("pango-1.0", .{ .use_pkg_config = .no });
}

fn addLinuxPangoIncludePaths(module: *std.Build.Module) void {
    module.addSystemIncludePath(.{ .cwd_relative = "/usr/include/pango-1.0" });
    module.addSystemIncludePath(.{ .cwd_relative = "/usr/include/harfbuzz" });
    module.addSystemIncludePath(.{ .cwd_relative = "/usr/include/fribidi" });
    module.addSystemIncludePath(.{ .cwd_relative = "/usr/include/libthai" });
    module.addSystemIncludePath(.{ .cwd_relative = "/usr/include/libdatrie" });
}

fn readReleaseVersion(b: *std.Build) ![]const u8 {
    const raw = try b.build_root.handle.readFileAlloc(b.graph.io, "release/VERSION", b.allocator, .limited(64));
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return error.EmptyVersion;
    return trimmed;
}
