const std = @import("std");
const Module = std.Build.Module;

pub fn configurePkgConfig(b: *std.Build) void {
    const pdf_pkg_config_path = b.path("src/render/pdf").getPath(b);
    const pkg_config_path = if (b.graph.environ_map.get("PKG_CONFIG_PATH")) |path|
        b.fmt("{s}{c}{s}", .{ pdf_pkg_config_path, std.fs.path.delimiter, path })
    else
        pdf_pkg_config_path;
    b.graph.environ_map.put("PKG_CONFIG_PATH", pkg_config_path) catch @panic("OOM");
}

pub fn addSources(b: *std.Build, module: *Module) void {
    addHeaders(b, module);
    module.addCSourceFiles(.{
        .root = b.path("src/render/pdf"),
        .files = &.{ "cairo.c", "assets.c" },
    });
}

pub fn addHeaders(b: *std.Build, module: *Module) void {
    module.addIncludePath(b.path("src/render/pdf"));
    module.linkSystemLibrary("ss-pdf", .{ .use_pkg_config = .force });
}
