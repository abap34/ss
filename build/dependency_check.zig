const std = @import("std");

const CommandStatus = enum {
    missing,
    succeeded,
    failed,
};

const CommandResult = struct {
    status: CommandStatus,
    stdout: []const u8 = "",
    stderr: []const u8 = "",
};

const PdfPackage = struct {
    name: []const u8,
    purpose: []const u8,
};

const pdf_packages = [_]PdfPackage{
    .{ .name = "pangocairo", .purpose = "text layout with Cairo" },
    .{ .name = "pangofc", .purpose = "font discovery for Pango" },
    .{ .name = "librsvg-2.0", .purpose = "SVG rendering" },
    .{ .name = "gdk-pixbuf-2.0", .purpose = "raster image decoding" },
    .{ .name = "fontconfig", .purpose = "font discovery" },
    .{ .name = "harfbuzz", .purpose = "text shaping" },
};

pub fn main(init: std.process.Init) void {
    const allocator = init.arena.allocator();
    const args = init.minimal.args.toSlice(allocator) catch |err| {
        var reason_buf: [256]u8 = undefined;
        fatal("unable to read dependency-check arguments: {s}", .{formatErrorReason(&reason_buf, err)});
    };
    if (args.len < 2) fatal("internal build error: dependency-check mode is missing", .{});

    if (std.mem.eql(u8, args[1], "native-pdf")) {
        if (args.len != 8) fatal("internal build error: native-pdf dependency-check arguments are incomplete", .{});
        checkNativePdfDependencies(allocator, init.io, args[2], args[3], args[4], args[5], args[6], args[7]);
        return;
    }
    if (std.mem.eql(u8, args[1], "node")) {
        if (args.len != 2) fatal("internal build error: node dependency-check arguments are invalid", .{});
        checkNode(allocator, init.io);
        return;
    }
    if (std.mem.eql(u8, args[1], "qpdf-cli")) {
        if (args.len != 2) fatal("internal build error: qpdf-cli dependency-check arguments are invalid", .{});
        checkQpdfCli(allocator, init.io);
        return;
    }
    if (std.mem.eql(u8, args[1], "node-modules")) {
        if (args.len < 4) fatal("internal build error: node-modules dependency-check arguments are incomplete", .{});
        checkNodeModules(allocator, init.io, args[2], args[3..]);
        return;
    }
    fatal("internal build error: unknown dependency-check mode '{s}'", .{args[1]});
}

fn checkNativePdfDependencies(
    allocator: std.mem.Allocator,
    io: std.Io,
    pkg_config: []const u8,
    cpp: []const u8,
    minimum_cairo_version: []const u8,
    maximum_exclusive_cairo_version: []const u8,
    minimum_qpdf_version: []const u8,
    maximum_exclusive_qpdf_version: []const u8,
) void {
    const pkg_config_version = run(allocator, io, &.{ pkg_config, "--version" });
    switch (pkg_config_version.status) {
        .missing => missingPkgConfig(pkg_config),
        .failed => commandFailure(pkg_config, pkg_config_version),
        .succeeded => {},
    }

    const cpp_version = run(allocator, io, &.{ cpp, "--version" });
    switch (cpp_version.status) {
        .missing => missingCpp(cpp),
        .failed => commandFailure(cpp, cpp_version),
        .succeeded => {},
    }

    checkCairoLibrary(
        allocator,
        io,
        pkg_config,
        minimum_cairo_version,
        maximum_exclusive_cairo_version,
    );
    checkQpdfLibrary(
        allocator,
        io,
        pkg_config,
        minimum_qpdf_version,
        maximum_exclusive_qpdf_version,
    );

    var missing: [pdf_packages.len]bool = @splat(false);
    var missing_count: usize = 0;
    for (pdf_packages, 0..) |package, index| {
        const result = run(allocator, io, &.{ pkg_config, "--exists", package.name });
        switch (result.status) {
            .missing => missingPkgConfig(pkg_config),
            .failed => {
                missing[index] = true;
                missing_count += 1;
            },
            .succeeded => {},
        }
    }
    if (missing_count != 0) missingPdfPackages(missing);
}

fn checkCairoLibrary(
    allocator: std.mem.Allocator,
    io: std.Io,
    pkg_config: []const u8,
    minimum_version: []const u8,
    maximum_exclusive_version: []const u8,
) void {
    const status = versionedPackageStatus(
        allocator,
        io,
        pkg_config,
        "cairo",
        minimum_version,
        maximum_exclusive_version,
    );
    switch (status.kind) {
        .compatible => return,
        .missing => missingCairo(minimum_version, maximum_exclusive_version),
        .too_old => oldCairo(status.version, minimum_version),
        .too_new => tooNewCairo(status.version, minimum_version, maximum_exclusive_version),
    }
}

const VersionedPackageStatus = struct {
    kind: Kind,
    version: []const u8 = "unknown",

    const Kind = enum { compatible, missing, too_old, too_new };
};

fn versionedPackageStatus(
    allocator: std.mem.Allocator,
    io: std.Io,
    pkg_config: []const u8,
    package: []const u8,
    minimum_version: []const u8,
    maximum_exclusive_version: []const u8,
) VersionedPackageStatus {
    const exists = run(allocator, io, &.{ pkg_config, "--exists", package });
    switch (exists.status) {
        .missing => missingPkgConfig(pkg_config),
        .failed => return .{ .kind = .missing },
        .succeeded => {},
    }

    const minimum_requirement = std.fmt.allocPrint(allocator, "{s} >= {s}", .{ package, minimum_version }) catch
        fatal("out of memory while checking {s}", .{package});
    const maximum_requirement = std.fmt.allocPrint(allocator, "{s} < {s}", .{ package, maximum_exclusive_version }) catch
        fatal("out of memory while checking {s}", .{package});
    const compatible = run(allocator, io, &.{ pkg_config, "--exists", minimum_requirement, maximum_requirement });
    switch (compatible.status) {
        .missing => missingPkgConfig(pkg_config),
        .succeeded => return .{ .kind = .compatible },
        .failed => {},
    }

    const version_result = run(allocator, io, &.{ pkg_config, "--modversion", package });
    if (version_result.status != .succeeded) commandFailure(pkg_config, version_result);
    const installed_version = std.mem.trim(u8, version_result.stdout, " \t\r\n");
    const reported_version = if (installed_version.len == 0) "unknown" else installed_version;

    const satisfies_minimum = run(allocator, io, &.{ pkg_config, "--exists", minimum_requirement });
    return switch (satisfies_minimum.status) {
        .missing => missingPkgConfig(pkg_config),
        .failed => .{ .kind = .too_old, .version = reported_version },
        .succeeded => .{ .kind = .too_new, .version = reported_version },
    };
}

fn checkQpdfLibrary(
    allocator: std.mem.Allocator,
    io: std.Io,
    pkg_config: []const u8,
    minimum_version: []const u8,
    maximum_exclusive_version: []const u8,
) void {
    const status = versionedPackageStatus(
        allocator,
        io,
        pkg_config,
        "libqpdf",
        minimum_version,
        maximum_exclusive_version,
    );
    switch (status.kind) {
        .compatible => return,
        .missing => missingQpdf(minimum_version, maximum_exclusive_version),
        .too_old => oldQpdf(status.version, minimum_version),
        .too_new => tooNewQpdf(status.version, minimum_version, maximum_exclusive_version),
    }
}

fn checkNode(allocator: std.mem.Allocator, io: std.Io) void {
    const result = run(allocator, io, &.{ "node", "--version" });
    switch (result.status) {
        .missing => {
            std.debug.print(
                \\error: Node.js was not found, but this test target runs JavaScript and editor tests.
                \\
                \\Install Node.js 22 or newer, then retry the same Zig build step.
                \\  Ubuntu/Debian: install Node.js 22 from your preferred Node.js package source
                \\  macOS/Homebrew: brew install node@22
                \\
            , .{});
            std.process.exit(1);
        },
        .failed => commandFailure("node", result),
        .succeeded => {},
    }
}

fn checkQpdfCli(allocator: std.mem.Allocator, io: std.Io) void {
    const result = run(allocator, io, &.{ "qpdf", "--version" });
    switch (result.status) {
        .missing => {
            std.debug.print(
                \\error: the qpdf command was not found, but the native PDF tests inspect generated PDF files with it.
                \\
                \\Install the qpdf command, then retry the same test step.
                \\  Ubuntu/Debian: sudo apt-get install qpdf
                \\  macOS/Homebrew: brew install qpdf
                \\
            , .{});
            std.process.exit(1);
        },
        .failed => commandFailure("qpdf", result),
        .succeeded => {},
    }
}

fn checkNodeModules(
    allocator: std.mem.Allocator,
    io: std.Io,
    workspace: []const u8,
    packages: []const []const u8,
) void {
    var missing_count: usize = 0;
    for (packages) |package| {
        const package_path = std.fs.path.join(allocator, &.{ workspace, "node_modules", package }) catch
            fatal("out of memory while checking JavaScript packages", .{});
        std.Io.Dir.cwd().access(io, package_path, .{}) catch {
            missing_count += 1;
        };
    }
    if (missing_count == 0) return;

    std.debug.print(
        \\error: JavaScript dependencies are not installed for {s}.
        \\
        \\Missing files:
        \\
    , .{workspace});
    for (packages) |package| {
        const package_path = std.fs.path.join(allocator, &.{ workspace, "node_modules", package }) catch
            fatal("out of memory while reporting JavaScript packages", .{});
        std.Io.Dir.cwd().access(io, package_path, .{}) catch {
            std.debug.print("  - {s}\n", .{package_path});
        };
    }

    printPackageInstallCommands(allocator, io, workspace);
    std.process.exit(1);
}

fn printPackageInstallCommands(allocator: std.mem.Allocator, io: std.Io, workspace: []const u8) void {
    const managers = [_]struct {
        lockfile: []const u8,
        command: []const u8,
    }{
        .{ .lockfile = "pnpm-lock.yaml", .command = "pnpm install --frozen-lockfile" },
        .{ .lockfile = "yarn.lock", .command = "yarn install --immutable" },
        .{ .lockfile = "package-lock.json", .command = "npm ci" },
        .{ .lockfile = "npm-shrinkwrap.json", .command = "npm ci" },
        .{ .lockfile = "bun.lock", .command = "bun install --frozen-lockfile" },
        .{ .lockfile = "bun.lockb", .command = "bun install --frozen-lockfile" },
    };

    var detected: usize = 0;
    std.debug.print("\nInstall the workspace dependencies with its lockfile:\n", .{});
    for (managers) |manager| {
        const lock_path = std.fs.path.join(allocator, &.{ workspace, manager.lockfile }) catch
            fatal("out of memory while checking JavaScript lockfiles", .{});
        std.Io.Dir.cwd().access(io, lock_path, .{}) catch continue;
        std.debug.print("  detected {s}\n  (cd {s} && {s})\n", .{ manager.lockfile, workspace, manager.command });
        detected += 1;
    }
    if (detected == 0) {
        std.debug.print(
            \\  no supported lockfile was found in {s}
            \\  run the package manager selected by this workspace's package.json
            \\
        , .{workspace});
    } else if (detected > 1) {
        std.debug.print("\nMultiple lockfiles were found. Keep the intended lockfile and use its corresponding command.\n", .{});
    }
    std.debug.print("\nThe Zig build does not install JavaScript packages automatically.\n", .{});
}

fn run(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) CommandResult {
    const result = std.process.run(allocator, io, .{
        .argv = argv,
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    }) catch |err| switch (err) {
        error.FileNotFound => return .{ .status = .missing },
        else => {
            var reason_buf: [256]u8 = undefined;
            fatal("unable to start '{s}' while checking build dependencies: {s}", .{ argv[0], formatErrorReason(&reason_buf, err) });
        },
    };
    return switch (result.term) {
        .exited => |code| .{
            .status = if (code == 0) .succeeded else .failed,
            .stdout = result.stdout,
            .stderr = result.stderr,
        },
        else => fatal("'{s}' terminated unexpectedly while checking build dependencies: {}", .{ argv[0], result.term }),
    };
}

fn formatErrorReason(buf: []u8, err: anyerror) []const u8 {
    return switch (err) {
        error.AccessDenied, error.PermissionDenied => "permission denied; check that the executable and its parent directories are accessible",
        error.InvalidExe => "the selected file is not a valid executable for this system",
        error.SystemResources => "the operating system does not have enough resources to start the command",
        error.ProcessFdQuotaExceeded => "the build process has too many open files; close unused files and retry",
        error.SystemFdQuotaExceeded => "the system has too many open files; close unused files and retry",
        error.CurrentWorkingDirectoryUnavailable => "the current working directory is no longer accessible",
        error.OutOfMemory => "the build process ran out of memory",
        else => std.fmt.bufPrint(
            buf,
            "an unexpected operating-system failure occurred (diagnostic code: {s})",
            .{@errorName(err)},
        ) catch "an unexpected operating-system failure occurred",
    };
}

fn missingPkgConfig(command: []const u8) noreturn {
    std.debug.print(
        \\error: pkg-config command '{s}' was not found.
        \\
        \\ss uses pkg-config to locate Cairo, Pango, librsvg, GdkPixbuf, Fontconfig, HarfBuzz, and libqpdf.
        \\Install it and retry:
        \\  Ubuntu/Debian: sudo apt-get install pkg-config
        \\  macOS/Homebrew: brew install pkgconf
        \\
        \\For a non-standard executable, pass -Dqpdf-pkg-config=/absolute/path/to/pkg-config.
        \\
    , .{command});
    std.process.exit(1);
}

fn missingCpp(command: []const u8) noreturn {
    std.debug.print(
        \\error: C++ compiler '{s}' was not found.
        \\
        \\ss needs a C++20 compiler to build its small libqpdf bridge.
        \\GCC and Clang are both supported. Install or select either one and retry.
        \\
        \\The default compiler command is `c++`. Select another command explicitly, for example:
        \\  zig build -Dqpdf-cxx=clang++
        \\  zig build -Dqpdf-cxx=/absolute/path/to/c++
        \\
    , .{command});
    std.process.exit(1);
}

fn missingQpdf(minimum_version: []const u8, maximum_exclusive_version: []const u8) noreturn {
    std.debug.print(
        \\error: pkg-config could not find libqpdf.
        \\
        \\ss supports libqpdf {s} or newer and earlier than {s}, including its C++ headers and pkg-config metadata.
        \\Install it and retry:
        \\  Ubuntu/Debian: sudo apt-get install qpdf libqpdf-dev
        \\  macOS/Homebrew: brew install qpdf
        \\
        \\Ubuntu 22.04 provides an older libqpdf. The qpdf upstream PPA provides a compatible release:
        \\  sudo add-apt-repository -y ppa:qpdf/qpdf
        \\  sudo apt-get update
        \\  sudo apt-get install -y qpdf libqpdf-dev
        \\Older Debian releases may require a compatible package from Debian backports or an upstream build.
        \\
        \\If libqpdf is installed in a custom prefix, add its pkgconfig directory to PKG_CONFIG_PATH.
        \\
    , .{ minimum_version, maximum_exclusive_version });
    std.process.exit(1);
}

fn missingCairo(minimum_version: []const u8, maximum_exclusive_version: []const u8) noreturn {
    std.debug.print(
        \\error: pkg-config could not find Cairo.
        \\
        \\ss supports Cairo {s} or newer and earlier than {s}, including its development headers and pkg-config metadata.
        \\Install it and retry:
        \\  Ubuntu/Debian: sudo apt-get install libcairo2-dev
        \\  macOS/Homebrew: brew install cairo
        \\
        \\If Cairo is installed in a custom prefix, add its pkgconfig directory to PKG_CONFIG_PATH.
        \\
    , .{ minimum_version, maximum_exclusive_version });
    std.process.exit(1);
}

fn oldCairo(installed_version: []const u8, minimum_version: []const u8) noreturn {
    std.debug.print(
        \\error: Cairo {s} is too old; ss requires Cairo {s} or newer.
        \\
        \\Verify the selected version with:
        \\  pkg-config --modversion cairo
        \\
        \\If a compatible version is already installed elsewhere, place its pkgconfig directory first in PKG_CONFIG_PATH.
        \\
    , .{ installed_version, minimum_version });
    std.process.exit(1);
}

fn tooNewCairo(
    installed_version: []const u8,
    minimum_version: []const u8,
    maximum_exclusive_version: []const u8,
) noreturn {
    std.debug.print(
        \\error: Cairo {s} is newer than the supported range.
        \\
        \\ss supports Cairo {s} or newer and earlier than {s}.
        \\Install a supported Cairo release and retry.
        \\
        \\Verify the selected version with:
        \\  pkg-config --modversion cairo
        \\
        \\If a supported version is already installed elsewhere, place its pkgconfig directory first in PKG_CONFIG_PATH.
        \\
    , .{ installed_version, minimum_version, maximum_exclusive_version });
    std.process.exit(1);
}

fn oldQpdf(installed_version: []const u8, minimum_version: []const u8) noreturn {
    std.debug.print(
        \\error: libqpdf {s} is too old; ss requires libqpdf {s} or newer.
        \\
        \\The older API does not provide all page-box and stream construction operations used by ss.
        \\Ubuntu 22.04 ships libqpdf 10.6.3. Upgrade through the qpdf upstream PPA:
        \\  sudo add-apt-repository -y ppa:qpdf/qpdf
        \\  sudo apt-get update
        \\  sudo apt-get install -y qpdf libqpdf-dev
        \\Older Debian releases may require a compatible package from Debian backports or an upstream build.
        \\
        \\Verify the selected version with:
        \\  pkg-config --modversion libqpdf
        \\
        \\If a compatible version is already installed elsewhere, place its pkgconfig directory first in PKG_CONFIG_PATH.
        \\
    , .{ installed_version, minimum_version });
    std.process.exit(1);
}

fn tooNewQpdf(
    installed_version: []const u8,
    minimum_version: []const u8,
    maximum_exclusive_version: []const u8,
) noreturn {
    std.debug.print(
        \\error: libqpdf {s} is newer than the supported range.
        \\
        \\ss supports libqpdf {s} or newer and earlier than {s}.
        \\Install a supported qpdf release and retry.
        \\
        \\Verify the selected version with:
        \\  pkg-config --modversion libqpdf
        \\
        \\If a supported version is already installed elsewhere, place its pkgconfig directory first in PKG_CONFIG_PATH.
        \\
    , .{ installed_version, minimum_version, maximum_exclusive_version });
    std.process.exit(1);
}

fn missingPdfPackages(missing: [pdf_packages.len]bool) noreturn {
    std.debug.print(
        \\error: native PDF build dependencies are incomplete.
        \\
        \\pkg-config could not find:
        \\
    , .{});
    for (pdf_packages, missing) |package, is_missing| {
        if (is_missing) std.debug.print("  - {s}: {s}\n", .{ package.name, package.purpose });
    }
    std.debug.print(
        \\
        \\Install the development packages and retry:
        \\  Ubuntu/Debian:
        \\    sudo apt-get install libcairo2-dev libgdk-pixbuf-2.0-dev libpango1.0-dev librsvg2-dev
        \\  macOS/Homebrew:
        \\    brew install cairo pango librsvg
        \\
        \\If the libraries are installed in a custom prefix, add their pkgconfig directories to PKG_CONFIG_PATH.
        \\
    , .{});
    std.process.exit(1);
}

fn commandFailure(command: []const u8, result: CommandResult) noreturn {
    const stderr = std.mem.trim(u8, result.stderr, " \t\r\n");
    const stdout = std.mem.trim(u8, result.stdout, " \t\r\n");
    std.debug.print("error: '{s}' failed while checking build dependencies.\n", .{command});
    if (stderr.len != 0) {
        std.debug.print("\n{s}\n", .{stderr});
    } else if (stdout.len != 0) {
        std.debug.print("\n{s}\n", .{stdout});
    }
    std.debug.print("\nRun the command above directly to inspect the environment, then retry the Zig build.\n", .{});
    std.process.exit(1);
}

fn fatal(comptime format: []const u8, args: anytype) noreturn {
    std.debug.print("error: " ++ format ++ "\n", args);
    std.process.exit(1);
}
