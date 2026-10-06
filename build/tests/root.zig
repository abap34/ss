const std = @import("std");
const compat = @import("../compat.zig");
const project = @import("../modules.zig");
const dependencies = @import("../dependencies.zig");
const qpdf = @import("../qpdf.zig");
const steps = @import("../steps.zig");
const Suite = @import("support.zig").Suite;
const Step = std.Build.Step;

pub fn register(ctx: project.Context, modules: project.ProjectModules, build_options: *Step.Options, exe: std.Build.LazyPath, parser_check: *Step, checks: dependencies.Checks, bridge: qpdf.Bridge) void {
    const b = ctx.b;
    const all = b.step("test", "Run ss test targets");
    all.dependOn(parser_check);
    const suite = Suite{ .ctx = ctx, .all = all, .checks = checks, .bridge = bridge };
    _ = suite.add(project.createCliModule(ctx, modules, build_options), .{ .link_qpdf = true });
    const compiler = project.createCompilerModule(ctx, modules);
    @import("language.zig").register(suite, modules);
    @import("layout.zig").register(suite, modules);
    @import("compiler.zig").register(suite, modules, compiler);
    @import("render.zig").register(suite, modules, build_options);
    @import("editor.zig").register(suite, modules, compiler);
    @import("system.zig").register(suite, modules, build_options, exe);
    @import("runtime.zig").register(suite, exe);

    const diagnostics = steps.node(b, &checks.node.step, "tests/build/dependencies/spec.mjs", checks.executable.getEmittedBin());
    compat.addZigArg(b, diagnostics);
    steps.focused(b, "test-build-dependencies", "Check friendly build dependency diagnostics", &diagnostics.step);
}
