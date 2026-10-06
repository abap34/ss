const std = @import("std");
const Module = std.Build.Module;
const compat = @import("compat.zig");

var pkg_config_flags: ?[]const u8 = null;

pub fn configurePkgConfig(b: *std.Build) void {
    // Query the aggregate package once so transitive libraries are deduplicated.
    // Configure-time environment changes do not reach Zig 0.17's make process.
    compat.externalConfigureInput(b);
    pkg_config_flags = null;
    const result = std.process.run(b.allocator, b.graph.io, .{
        .argv = &.{
            b.graph.environ_map.get("PKG_CONFIG") orelse "pkg-config",
            "--cflags",
            "--libs",
            compat.pathFromRoot(b, "src/render/pdf/ss-pdf.pc"),
        },
        .environ_map = &b.graph.environ_map,
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(4096),
    }) catch return;
    // Missing dependencies are reported by the execution-time dependency check.
    // Independent targets and --help must remain available without them.
    switch (result.term) {
        .exited => |code| if (code == 0) {
            pkg_config_flags = result.stdout;
        },
        else => {},
    }
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
    const flags = pkg_config_flags orelse {
        for ([_][]const u8{ "librsvg-2.0", "pangocairo", "pangofc", "gdk-pixbuf-2.0", "fontconfig", "harfbuzz" }) |package| {
            module.linkSystemLibrary(package, .{ .use_pkg_config = .force });
        }
        return;
    };
    var args = std.mem.tokenizeAny(u8, flags, " \r\n\t");
    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "-I")) {
            module.addSystemIncludePath(.{ .cwd_relative = flagValue(arg, &args) });
        } else if (std.mem.startsWith(u8, arg, "-L")) {
            module.addLibraryPath(.{ .cwd_relative = flagValue(arg, &args) });
        } else if (std.mem.startsWith(u8, arg, "-l")) {
            module.linkSystemLibrary(flagValue(arg, &args), .{ .use_pkg_config = .no });
        } else if (std.mem.startsWith(u8, arg, "-D")) {
            const macro = flagValue(arg, &args);
            const equals = std.mem.indexOfScalar(u8, macro, '=') orelse macro.len;
            module.addCMacro(macro[0..equals], if (equals < macro.len) macro[equals + 1 ..] else "1");
        } else if (std.mem.startsWith(u8, arg, "-Wl,-rpath,")) {
            module.addRPath(.{ .cwd_relative = arg["-Wl,-rpath,".len..] });
        } else if (std.mem.eql(u8, arg, "-framework")) {
            module.linkFramework(args.next() orelse @panic("missing pkg-config framework"), .{});
        }
    }
}

fn flagValue(arg: []const u8, args: anytype) []const u8 {
    return if (arg.len > 2) arg[2..] else args.next() orelse @panic("missing pkg-config flag argument");
}
