const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
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
    test_step.dependOn(&b.addRunArtifact(core_ir_spec_tests).step);
    test_step.dependOn(&b.addRunArtifact(layout_graph_spec_tests).step);
    for (smoke_check_files) |path| {
        const smoke_check = b.addRunArtifact(exe);
        smoke_check.addArgs(&.{ "check", path });
        test_step.dependOn(&smoke_check.step);
    }
}
