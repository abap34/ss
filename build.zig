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

    const core_mod = b.createModule(.{
        .root_source_file = b.path("src/core.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    core_mod.addImport("utils", utils_mod);
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
        .root_source_file = b.path("src/parser.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    parser_tests_mod.addImport("core", core_mod);
    parser_tests_mod.addImport("utils", utils_mod);
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
    const main_tests = b.addTest(.{
        .root_module = main_tests_mod,
    });

    const test_step = b.step("test", "Run ss test targets");
    test_step.dependOn(&b.addRunArtifact(core_tests).step);
    test_step.dependOn(&b.addRunArtifact(parser_tests).step);
    test_step.dependOn(&b.addRunArtifact(main_tests).step);
}
