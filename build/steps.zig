const std = @import("std");
const Step = std.Build.Step;

pub fn focused(b: *std.Build, name: []const u8, description: []const u8, dependency: *Step) void {
    b.step(name, description).dependOn(dependency);
}

pub fn node(b: *std.Build, check: *Step, path: []const u8, executable: ?std.Build.LazyPath) *Step.Run {
    const run = b.addSystemCommand(&.{"node"});
    run.step.dependOn(check);
    run.setName(b.fmt("node {s}", .{path}));
    run.addFileArg(b.path(path));
    if (executable) |file| run.addFileArg(file);
    run.setCwd(b.path("."));
    run.stdio = .inherit;
    return run;
}

pub fn runExecutable(b: *std.Build, file: std.Build.LazyPath) *Step.Run {
    const run = Step.Run.create(b, "run ss");
    run.addFileArg(file);
    return run;
}
