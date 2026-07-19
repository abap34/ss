const std = @import("std");

const Module = std.Build.Module;
const Step = std.Build.Step;

pub const Bridge = struct {
    file: std.Build.LazyPath,
    install: *Step.InstallFile,
};

pub const RuntimeLocation = enum {
    build,
    installed,
};

pub fn link(
    bridge: Bridge,
    b: *std.Build,
    module: *Module,
    target: std.Build.ResolvedTarget,
    location: RuntimeLocation,
) void {
    module.addObjectFile(bridge.file);
    switch (location) {
        .build => module.addRPath(.{ .cwd_relative = b.getInstallPath(.lib, "ss") }),
        .installed => switch (target.result.os.tag) {
            .linux => module.addRPathSpecial("$ORIGIN/../lib/ss"),
            .macos => module.addRPathSpecial("@loader_path/../lib/ss"),
            else => unreachable,
        },
    }
}

pub fn create(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) Bridge {
    const filename = b.fmt("{s}ss-qpdf{s}", .{
        target.result.libPrefix(),
        target.result.dynamicLibSuffix(),
    });
    if (!usesHostSystemLibraries(b, target)) return unsupportedTarget(b, target, filename);

    const cpp = b.option([]const u8, "qpdf-cxx", "C++ compiler used for the system libqpdf bridge") orelse "c++";
    const pkg_config = b.option([]const u8, "qpdf-pkg-config", "pkg-config command used to locate system libqpdf") orelse "pkg-config";

    const cflags = pkgConfigOutput(b, pkg_config, "--cflags", "qpdf-cflags.rsp");
    const libraries = pkgConfigOutput(b, pkg_config, "--libs", "qpdf-libraries.rsp");
    const qpdf_version = pkgConfigOutput(b, pkg_config, "--modversion", "qpdf-version.txt");
    const compiler_version = commandOutput(b, cpp, &.{"--version"}, "qpdf-cxx-version.txt");

    const compile = b.addSystemCommand(&.{
        cpp,
        "-std=c++20",
        "-fPIC",
        "-fvisibility=hidden",
        "-fvisibility-inlines-hidden",
        optimizationFlag(optimize),
    });
    compile.setName("build qpdf C ABI bridge");
    switch (target.result.os.tag) {
        .linux => compile.addArgs(&.{
            "-shared",
            "-Wl,-z,defs",
            b.fmt("-Wl,-soname,{s}", .{filename}),
        }),
        .macos => compile.addArgs(&.{
            "-dynamiclib",
            b.fmt("-Wl,-install_name,@rpath/{s}", .{filename}),
        }),
        else => unreachable,
    }
    compile.addPrefixedFileArg("@", cflags);
    compile.addArgs(&.{ "-MMD", "-MF" });
    _ = compile.addDepFileOutputArg("ss-qpdf.d");
    compile.addFileArg(b.path("src/render/pdf/qpdf.cpp"));
    compile.addPrefixedFileArg("@", libraries);
    compile.addFileInput(qpdf_version);
    compile.addFileInput(compiler_version);
    compile.addArg("-o");
    const file = compile.addOutputFileArg(filename);

    return .{
        .file = file,
        .install = b.addInstallLibFile(file, b.fmt("ss/{s}", .{filename})),
    };
}

fn pkgConfigOutput(
    b: *std.Build,
    command: []const u8,
    option: []const u8,
    basename: []const u8,
) std.Build.LazyPath {
    return commandOutput(b, command, &.{ option, "libqpdf" }, basename);
}

fn commandOutput(
    b: *std.Build,
    command: []const u8,
    args: []const []const u8,
    basename: []const u8,
) std.Build.LazyPath {
    const run = b.addSystemCommand(&.{command});
    run.addArgs(args);
    run.has_side_effects = true;
    return run.captureStdOut(.{ .basename = basename, .trim_whitespace = .trailing });
}

fn usesHostSystemLibraries(b: *std.Build, target: std.Build.ResolvedTarget) bool {
    const host = b.graph.host.result;
    return target.result.cpu.arch == host.cpu.arch and
        target.result.os.tag == host.os.tag and
        target.result.abi == host.abi and
        (target.result.os.tag == .linux or target.result.os.tag == .macos);
}

fn unsupportedTarget(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    filename: []const u8,
) Bridge {
    const host = b.graph.host.result;
    const failure = b.addFail(b.fmt(
        "the system libqpdf bridge requires the build host target; requested {s}-{s}-{s}, host is {s}-{s}-{s}",
        .{
            @tagName(target.result.cpu.arch),
            @tagName(target.result.os.tag),
            @tagName(target.result.abi),
            @tagName(host.cpu.arch),
            @tagName(host.os.tag),
            @tagName(host.abi),
        },
    ));
    const placeholder = b.addWriteFiles();
    placeholder.step.dependOn(&failure.step);
    const file = placeholder.add(filename, "");
    return .{
        .file = file,
        .install = b.addInstallLibFile(file, b.fmt("ss/{s}", .{filename})),
    };
}

fn optimizationFlag(optimize: std.builtin.OptimizeMode) []const u8 {
    return switch (optimize) {
        .Debug => "-O0",
        .ReleaseSafe => "-O2",
        .ReleaseFast => "-O3",
        .ReleaseSmall => "-Os",
    };
}
