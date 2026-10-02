const std = @import("std");
const project = @import("../modules.zig");
const dependencies = @import("../dependencies.zig");
const qpdf = @import("../qpdf.zig");
const steps = @import("../steps.zig");
const Module = std.Build.Module;
const Step = std.Build.Step;

pub const Suite = struct {
    ctx: project.Context,
    all: *Step,
    checks: dependencies.Checks,
    bridge: qpdf.Bridge,

    pub const Options = struct {
        name: ?[]const u8 = null,
        description: []const u8 = "",
        link_qpdf: bool = false,
    };

    pub fn add(self: Suite, module: *Module, options: Options) *Step.Run {
        const b = self.ctx.b;
        if (options.link_qpdf) qpdf.link(self.bridge, b, module, self.ctx.target, .build);
        const artifact = b.addTest(.{ .root_module = module });
        if (dependencies.requiresNativePdf(b, module)) artifact.step.dependOn(&self.checks.native_pdf.step);
        if (options.link_qpdf) artifact.step.dependOn(&self.bridge.install.step);
        const run = b.addRunArtifact(artifact);
        self.all.dependOn(&run.step);
        if (options.name) |name| steps.focused(b, name, options.description, &run.step);
        return run;
    }

    pub fn addFile(self: Suite, path: []const u8, imports: []const Module.Import, libc: ?bool) void {
        _ = self.add(project.createModule(self.ctx, path, imports, libc), .{});
    }
};
