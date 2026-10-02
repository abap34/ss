const std = @import("std");
const project = @import("modules.zig");
const dependencies = @import("dependencies.zig");
const steps = @import("steps.zig");

pub fn register(ctx: project.Context, exe: *std.Build.Step.Compile, checks: dependencies.Checks) void {
    const b = ctx.b;
    const render = steps.node(b, &checks.node.step, "tests/benchmark/render/spec.mjs", null);
    render.addArg(@tagName(ctx.optimize));
    render.addFileArg(exe.getEmittedBin());
    steps.focused(b, "benchmark-render", "Measure fixed-document PDF and HTML rendering with ReleaseSafe", &render.step);

    const wysiwyg = steps.node(b, &checks.node.step, "tests/benchmark/wysiwyg/spec.mjs", exe.getEmittedBin());
    wysiwyg.addArg(@tagName(ctx.optimize));
    steps.focused(b, "benchmark-wysiwyg", "Measure WYSIWYG initial and editing latency with ReleaseSafe", &wysiwyg.step);
}
