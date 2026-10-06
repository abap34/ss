const std = @import("std");
const compat = @import("compat.zig");
const project = @import("modules.zig");
const dependencies = @import("dependencies.zig");
const steps = @import("steps.zig");

pub fn register(ctx: project.Context, exe: std.Build.LazyPath, checks: dependencies.Checks) void {
    const b = ctx.b;
    const render = steps.node(b, &checks.node.step, "tests/benchmark/render/spec.mjs", null);
    render.addArg(compat.optimizeName(ctx.optimize));
    render.addFileArg(exe);
    steps.focused(b, "benchmark-render", "Measure fixed-document PDF and HTML rendering with ReleaseSafe", &render.step);

    const wysiwyg = steps.node(b, &checks.node.step, "tests/benchmark/wysiwyg/spec.mjs", exe);
    wysiwyg.addArg(compat.optimizeName(ctx.optimize));
    steps.focused(b, "benchmark-wysiwyg", "Measure WYSIWYG initial and editing latency with ReleaseSafe", &wysiwyg.step);
}
