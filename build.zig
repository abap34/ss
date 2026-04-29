const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const md4c_include = b.path("third_party/md4c/src");

    const core_mod = b.createModule(.{
        .root_source_file = b.path("src/core.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    core_mod.addIncludePath(md4c_include);
    core_mod.addCSourceFiles(.{
        .root = b.path("third_party/md4c/src"),
        .files = &.{"md4c.c"},
    });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    exe_mod.addImport("core", core_mod);

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
    const main_tests = b.addTest(.{
        .root_module = main_tests_mod,
    });

    const test_step = b.step("test", "Run ss test targets");
    test_step.dependOn(&b.addRunArtifact(core_tests).step);
    test_step.dependOn(&b.addRunArtifact(parser_tests).step);
    test_step.dependOn(&b.addRunArtifact(main_tests).step);
}
