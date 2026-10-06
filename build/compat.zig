const std = @import("std");

pub const Optimize = if (@hasDecl(std.builtin, "Optimize")) std.builtin.Optimize else std.builtin.OptimizeMode;

pub fn pathFromRoot(b: *std.Build, path: []const u8) []const u8 {
    if (std.fs.path.isAbsolute(path)) return path;
    if (@hasDecl(std.Build, "pathFromRoot")) return b.pathFromRoot(path);
    return b.root.joinString(b.allocator, path) catch @panic("OOM");
}

pub fn readFile(b: *std.Build, path: []const u8, limit: std.Io.Limit) ![]u8 {
    if (@hasDecl(std.Build, "dependOnFileContents")) b.dependOnFileContents(b.path(path));
    return std.Io.Dir.cwd().readFileAlloc(b.graph.io, pathFromRoot(b, path), b.allocator, limit);
}

pub fn access(b: *std.Build, path: []const u8) !void {
    if (@hasDecl(std.Build.Graph, "poisonCache")) b.graph.poisonCache();
    return std.Io.Dir.cwd().access(b.graph.io, pathFromRoot(b, path), .{});
}

/// Git status is an external configure input that cannot be tracked as one file.
pub fn externalConfigureInput(b: *std.Build) void {
    if (@hasDecl(std.Build.Graph, "poisonCache")) b.graph.poisonCache();
}

/// Nested build tests must use the same compiler as the parent build.
pub fn addZigArg(b: *std.Build, run: *std.Build.Step.Run) void {
    if (@hasDecl(std.Build.LazyPath, "zig_exe")) {
        run.addFileArg(.zig_exe);
    } else {
        run.addArg(b.graph.zig_exe);
    }
}

pub fn optimizeName(optimize: Optimize) []const u8 {
    return switch (optimize) {
        .Debug => "Debug",
        .ReleaseSafe => "ReleaseSafe",
        .ReleaseFast => "ReleaseFast",
        .ReleaseSmall => "ReleaseSmall",
    };
}
