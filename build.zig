const std = @import("std");
const options = @import("build/options.zig");
const project = @import("build/modules.zig");
const dependencies = @import("build/dependencies.zig");
const native_pdf = @import("build/native_pdf.zig");
const cairo = @import("build/cairo.zig");
const qpdf = @import("build/qpdf.zig");
const tree_sitter = @import("build/tree_sitter.zig");
const steps = @import("build/steps.zig");
const tests = @import("build/tests/root.zig");
const visual = @import("build/tests/visual.zig");
const benchmarks = @import("build/benchmarks.zig");

pub fn build(b: *std.Build) void {
    const ctx = project.Context{
        .b = b,
        .target = b.standardTargetOptions(.{}),
        .optimize = b.standardOptimizeOption(.{}),
    };
    const tree_options = tree_sitter.CompileOptions{
        .b = b,
        .target = ctx.target,
        .optimize = ctx.optimize,
        .ubsan = b.option(bool, "tree-sitter-ubsan", "Compile upstream tree-sitter C sources with UBSan instrumentation") orelse false,
    };
    const build_options = options.create(b);
    native_pdf.configurePkgConfig(b);
    const qpdf_config = qpdf.config(b);
    const checks = dependencies.create(b, .{
        .pkg_config = qpdf_config.pkg_config,
        .cpp = qpdf_config.cpp,
        .minimum_cairo_version = cairo.minimum_version,
        .maximum_exclusive_cairo_version = cairo.maximum_exclusive_version,
        .minimum_qpdf_version = qpdf.minimum_version,
        .maximum_exclusive_qpdf_version = qpdf.maximum_exclusive_version,
    });
    const bridge = qpdf.create(b, ctx.target, ctx.optimize, qpdf_config, &checks.native_pdf.step);
    const parsers = tree_sitter.create(b);
    b.step("tree-sitter-prepare", "Prepare the pinned tree-sitter runtime and parser sources").dependOn(parsers.step);
    tree_sitter.addOptions(b, build_options, parsers);
    const modules = project.create(ctx, build_options, parsers, tree_options);
    const parser_check = tree_sitter.addAbiCheck(tree_options, parsers);
    b.step("tree-sitter-check", "Check bundled tree-sitter runtime and parsers").dependOn(parser_check);

    const installed_mod = project.createCliModule(ctx, modules, build_options);
    qpdf.link(bridge, b, installed_mod, ctx.target, .installed);
    const installed_exe = b.addExecutable(.{ .name = "ss", .root_module = installed_mod });
    installed_exe.step.dependOn(parser_check);
    b.installArtifact(installed_exe);
    b.getInstallStep().dependOn(&bridge.install.step);
    b.installDirectory(.{
        .source_dir = b.path("stdlib"),
        .install_dir = .prefix,
        .install_subdir = options.installed_stdlib_subdir,
        .include_extensions = &.{".ss"},
    });
    b.installDirectory(.{
        .source_dir = b.path("third_party/fontawesome-free"),
        .install_dir = .prefix,
        .install_subdir = "share/licenses/ss/fontawesome-free",
        .include_extensions = &.{".txt"},
    });
    const exe = qpdf.runnable(b, bridge, installed_exe);
    const run = steps.runExecutable(b, exe);
    if (@hasDecl(std.Build.Step.Run, "addPassthruArgs")) {
        run.addPassthruArgs();
    } else if (b.args) |args| run.addArgs(args);
    b.step("run", "Run the ss CLI").dependOn(&run.step);

    tests.register(ctx, modules, build_options, exe, parser_check, checks, bridge);
    visual.register(ctx, modules, build_options, exe, checks, bridge);
    benchmarks.register(ctx, exe, checks);
}
