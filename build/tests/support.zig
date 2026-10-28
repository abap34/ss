const std = @import("std");
const project = @import("../modules.zig");
const compat = @import("../compat.zig");
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
    document_testing: *Module,
    allocation_testing: *Module,
    layout_testing: *Module,

    pub const Options = struct {
        name: ?[]const u8 = null,
        description: []const u8 = "",
        working_directory: ?[]const u8 = null,
        link_qpdf: bool = false,
        layout_fixture: bool = false,
        document_fixture: bool = false,
    };

    pub fn add(self: Suite, module: *Module, options: Options) *Step.Run {
        const b = self.ctx.b;
        if (options.document_fixture) module.addImport("document_testing", self.document_testing);
        module.addImport("allocation_testing", self.allocation_testing);
        if (options.layout_fixture) module.addImport("layout_testing", self.layout_testing);
        if (options.link_qpdf) qpdf.link(self.bridge, b, module, self.ctx.target, .installed);
        const artifact = b.addTest(.{ .root_module = module });
        if (dependencies.requiresNativePdf(b, module)) artifact.step.dependOn(&self.checks.native_pdf.step);
        const run = if (options.link_qpdf) blk: {
            const run = steps.runExecutable(b, qpdf.runnable(b, self.bridge, artifact));
            run.step.dependOn(&artifact.step);
            run.producer = artifact;
            run.enableTestRunnerMode();
            break :blk run;
        } else b.addRunArtifact(artifact);
        if (options.working_directory) |directory| {
            const prepare = b.addSystemCommand(&.{ "mkdir", "-p" });
            prepare.addArg(compat.pathFromRoot(b, directory));
            run.step.dependOn(&prepare.step);
            run.setCwd(b.path(directory));
        }
        self.all.dependOn(&run.step);
        if (options.name) |name| steps.focused(b, name, options.description, &run.step);
        return run;
    }

    pub fn addFile(self: Suite, path: []const u8, imports: []const Module.Import, libc: ?bool) void {
        _ = self.add(project.createModule(self.ctx, path, imports, libc), .{});
    }
};
