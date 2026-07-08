const core = @import("core");
const pdf = @import("../render/pdf.zig");
const utils = @import("utils");

const Progress = utils.progress.Progress;

pub fn render(progress: *Progress) pdf.RenderProgress {
    return .{
        .context = progress,
        .artifactCompleted = onRenderArtifact,
        .pageCompleted = onRenderPage,
        .assemblyCompleted = onRenderAssembly,
    };
}

pub fn layout(progress: *Progress) core.layout.graph.LayoutProgress {
    return .{
        .context = progress,
        .pageStarted = onLayoutPage,
        .pageCompleted = onLayoutPage,
    };
}

fn onLayoutPage(context: *anyopaque, completed: usize, total: usize) void {
    const progress: *Progress = @ptrCast(@alignCast(context));
    progress.detail("pages", completed, total);
}

fn onRenderArtifact(context: *anyopaque, completed: usize, total: usize) void {
    const progress: *Progress = @ptrCast(@alignCast(context));
    progress.detail("artifacts", completed, total);
}

fn onRenderPage(context: *anyopaque, completed: usize, total: usize) void {
    const progress: *Progress = @ptrCast(@alignCast(context));
    progress.detail("pages", completed, total);
}

fn onRenderAssembly(context: *anyopaque, completed: usize, total: usize) void {
    const progress: *Progress = @ptrCast(@alignCast(context));
    progress.detail("assemble", completed, total);
}
