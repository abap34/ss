const std = @import("std");

const Module = std.Build.Module;
const Step = std.Build.Step;

pub const minimum_version = "11.2.0";
pub const maximum_exclusive_version = "13.0.0";

pub const Config = struct {
    cpp: []const u8,
    pkg_config: []const u8,
};

pub const Bridge = struct {
    file: std.Build.LazyPath,
    install: *Step.InstallFile,
};

pub const RuntimeLocation = enum {
    build,
    installed,
};

pub fn config(b: *std.Build) Config {
    return .{
        .cpp = b.option([]const u8, "qpdf-cxx", "C++20 compiler used for the system libqpdf bridge") orelse "c++",
        .pkg_config = b.option([]const u8, "qpdf-pkg-config", "pkg-config command used to locate native PDF dependencies") orelse "pkg-config",
    };
}

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
    build_config: Config,
    dependency_check: *Step,
) Bridge {
    const filename = b.fmt("{s}ss-qpdf{s}", .{
        target.result.libPrefix(),
        target.result.dynamicLibSuffix(),
    });
    if (!usesHostSystemLibraries(b, target)) return unsupportedTarget(b, target, filename);

    const cpp = build_config.cpp;
    const pkg_config = build_config.pkg_config;

    const cflags = pkgConfigOutput(b, pkg_config, "--cflags", "qpdf-cflags.rsp", dependency_check);
    const libraries = pkgConfigOutput(b, pkg_config, "--libs", "qpdf-libraries.rsp", dependency_check);
    const qpdf_version = pkgConfigOutput(b, pkg_config, "--modversion", "qpdf-version.txt", dependency_check);
    const compiler_version = commandOutput(b, cpp, &.{"--version"}, "qpdf-cxx-version.txt", dependency_check);

    const compile = b.addSystemCommand(&.{
        cpp,
        "-std=c++20",
        "-fPIC",
        "-fvisibility=hidden",
        "-fvisibility-inlines-hidden",
        optimizationFlag(optimize),
    });
    compile.setName("build qpdf C ABI bridge");
    compile.step.dependOn(dependency_check);
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
    dependency_check: *Step,
) std.Build.LazyPath {
    return commandOutput(b, command, &.{ option, "libqpdf" }, basename, dependency_check);
}

fn commandOutput(
    b: *std.Build,
    command: []const u8,
    args: []const []const u8,
    basename: []const u8,
    dependency_check: *Step,
) std.Build.LazyPath {
    const run = b.addSystemCommand(&.{command});
    run.addArgs(args);
    run.has_side_effects = true;
    run.step.dependOn(dependency_check);
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
        \\ss cannot cross-compile its native PDF backend with host system libraries.
        \\requested target: {s}-{s}-{s}
        \\build host:       {s}-{s}-{s}
        \\
        \\Build ss on the target operating system and architecture. The PDF backend currently needs
        \\target-native Cairo, Pango, librsvg, GdkPixbuf, and libqpdf libraries discovered by pkg-config.
        \\
    ,
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
