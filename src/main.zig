const std = @import("std");
const app = @import("app.zig");
const build_options = @import("build_options");
const utils = @import("utils");
const watcher = @import("watch.zig");
const project = @import("project.zig");
const lsp = @import("lsp.zig");
const pdf = @import("render/pdf.zig");
const render_compiler = @import("render/compile.zig");
const cli_help = @import("cli/help.zig");
const cli_completion = @import("cli/completion.zig");
const error_report = utils.err;

fn failUsage(comptime fmt: []const u8, args: anytype) error{InvalidUsage} {
    std.debug.print(fmt ++ "\n\n", args);
    cli_help.general(.stderr);
    return error.InvalidUsage;
}

fn failCli(comptime fmt: []const u8, args: anytype) error{InvalidUsage} {
    std.debug.print(fmt ++ "\n", args);
    return error.InvalidUsage;
}

fn version() void {
    const native = render_compiler.nativeRuntimeVersions();
    var buffer: [2048]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer,
        \\ss {s}
        \\commit: {s}
        \\uncommitted changes: {s}
        \\tree-sitter manifest: {s}
        \\tree-sitter ABI: {d}..{d}
        \\native PDF:
        \\  Cairo: {s}
        \\  Pango: {s}
        \\  librsvg: {s}
        \\  GdkPixbuf: {s}
        \\  Fontconfig: {d}
        \\  HarfBuzz: {s}
        \\  qpdf: {s}
        \\render cache schema:
        \\  PDF: {s}
        \\  Native artifacts: {s}
        \\
    , .{
        build_options.version,
        build_options.commit,
        build_options.uncommitted_changes,
        build_options.tree_sitter_manifest_hash,
        render_compiler.tree_sitter_min_compatible_language_version,
        render_compiler.tree_sitter_language_version,
        native.cairo,
        native.pango,
        native.librsvg,
        native.gdk_pixbuf,
        native.fontconfig,
        native.harfbuzz,
        native.qpdf,
        pdf.cache_version,
        render_compiler.native_artifact_cache_version,
    }) catch return;
    utils.io.writeStdoutAll(text) catch {};
}

fn printCacheStats(stats: utils.render_cache.Stats) void {
    std.debug.print("render cache: {s}\n", .{utils.render_cache.path});
    printCacheTotals(stats.files, stats.directories, stats.bytes);
}

fn printCacheTotals(files: usize, directories: usize, bytes: u64) void {
    std.debug.print("files: {d}\n", .{files});
    std.debug.print("directories: {d}\n", .{directories});
    std.debug.print("size: ", .{});
    printByteSize(bytes);
    std.debug.print("\n", .{});
}

fn printByteSize(bytes: u64) void {
    const units = [_][]const u8{ "B", "KiB", "MiB", "GiB", "TiB" };
    var unit_index: usize = 0;
    var divisor: u64 = 1;
    while (unit_index + 1 < units.len and bytes >= divisor * 1024) {
        unit_index += 1;
        divisor *= 1024;
    }

    if (unit_index == 0) {
        std.debug.print("{d} {s}", .{ bytes, units[unit_index] });
        return;
    }

    const scaled_tenths = (bytes / divisor) * 10 + ((bytes % divisor) * 10 + divisor / 2) / divisor;
    std.debug.print("{d}.{d} {s}", .{
        scaled_tenths / 10,
        scaled_tenths % 10,
        units[unit_index],
    });
}

const CommandOptions = struct {
    input_path: ?[]const u8 = null,
    output_path: ?[]const u8 = null,
    asset_base_dir: ?[]const u8 = null,
    project_path: ?[]const u8 = null,
    jobs: ?usize = null,
    diagnostics_json_path: ?[]const u8 = null,
    diagnostic_level: ?error_report.DiagnosticLevel = null,
    quiet: bool = false,
    interval_ms: u64 = 500,
    format: RenderFormat = .pdf,
};

const RenderFormat = app.RenderFormat;

const InitOptions = struct {
    dir: []const u8 = ".",
    entry: []const u8 = "slide.ss",
    force: bool = false,
};

const DoctorOptions = struct {
    input_path: ?[]const u8 = null,
    asset_base_dir: ?[]const u8 = null,
    project_path: ?[]const u8 = null,
    strict: bool = false,
};

fn parseCompletionOptions(args: []const []const u8) !cli_completion.Options {
    var shell: ?cli_completion.Shell = null;
    var options = cli_completion.Options{ .shell = .bash };
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--print")) {
            options.print = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--yes") or std.mem.eql(u8, arg, "-y")) {
            options.yes = true;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-")) return failUsage("unknown completion option: {s}", .{arg});
        if (shell != null) return failUsage("unexpected completion argument: {s}", .{arg});
        shell = cli_completion.Shell.parse(arg) orelse return failUsage("unknown completion shell: {s}", .{arg});
    }
    options.shell = shell orelse return failUsage("usage: ss completion bash|zsh|fish [--yes|--print]", .{});
    return options;
}

fn parseCommandOptions(args: []const []const u8) !CommandOptions {
    var options = CommandOptions{};
    var positional_index: usize = 0;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--asset-base-dir")) {
            if (i + 1 >= args.len) return failUsage("missing value for --asset-base-dir", .{});
            options.asset_base_dir = args[i + 1];
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--project")) {
            if (i + 1 >= args.len) return failUsage("missing value for --project", .{});
            options.project_path = args[i + 1];
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--output")) {
            if (i + 1 >= args.len) return failUsage("missing value for --output", .{});
            if (options.output_path != null) return failUsage("output path specified more than once", .{});
            options.output_path = args[i + 1];
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--format")) {
            if (i + 1 >= args.len) return failUsage("missing value for --format", .{});
            const value = args[i + 1];
            options.format = if (std.mem.eql(u8, value, "pdf"))
                .pdf
            else if (std.mem.eql(u8, value, "html"))
                .html
            else
                return failUsage("invalid --format value: {s}", .{value});
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--jobs")) {
            if (i + 1 >= args.len) return failUsage("missing value for --jobs", .{});
            options.jobs = std.fmt.parseUnsigned(usize, args[i + 1], 10) catch {
                return failUsage("invalid --jobs value: {s}", .{args[i + 1]});
            };
            if (options.jobs.? == 0) return failUsage("--jobs must be greater than zero", .{});
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--diagnostics-json")) {
            if (i + 1 >= args.len) return failUsage("missing value for --diagnostics-json", .{});
            options.diagnostics_json_path = args[i + 1];
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--diagnostic-level")) {
            if (i + 1 >= args.len) return failUsage("missing value for --diagnostic-level", .{});
            const value = args[i + 1];
            options.diagnostic_level = error_report.parseDiagnosticLevel(value) orelse {
                return failUsage("invalid --diagnostic-level value: {s}", .{value});
            };
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--warnings")) {
            if (i + 1 >= args.len) return failUsage("missing value for --warnings", .{});
            const value = args[i + 1];
            if (!std.mem.eql(u8, value, "off")) return failUsage("invalid --warnings value: {s}", .{value});
            options.diagnostic_level = .@"error";
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--quiet")) {
            options.quiet = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--color")) {
            if (i + 1 >= args.len) return failUsage("missing value for --color", .{});
            const value = args[i + 1];
            if (!std.mem.eql(u8, value, "auto") and !std.mem.eql(u8, value, "always") and !std.mem.eql(u8, value, "never")) {
                return failUsage("invalid --color value: {s}", .{value});
            }
            setColorMode(parseColorMode(value));
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--interval-ms")) {
            if (i + 1 >= args.len) return failUsage("missing value for --interval-ms", .{});
            options.interval_ms = std.fmt.parseUnsigned(u64, args[i + 1], 10) catch {
                return failUsage("invalid --interval-ms value: {s}", .{args[i + 1]});
            };
            if (options.interval_ms == 0) return failUsage("--interval-ms must be greater than zero", .{});
            i += 1;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--")) return failUsage("unknown flag: {s}", .{arg});
        switch (positional_index) {
            0 => options.input_path = arg,
            1 => {
                if (options.output_path != null) return failUsage("output path specified more than once", .{});
                options.output_path = arg;
            },
            else => return failUsage("too many arguments: {s}", .{arg}),
        }
        positional_index += 1;
    }
    return options;
}

fn parseColorMode(value: []const u8) error_report.ColorMode {
    return std.meta.stringToEnum(error_report.ColorMode, value) orelse unreachable;
}

fn setColorMode(mode: error_report.ColorMode) void {
    error_report.setColorMode(mode);
    cli_help.setColorMode(mode);
}

fn applyDiagnosticOptions(options: CommandOptions, resolved: ?*const project.Resolved) void {
    error_report.setDiagnosticLevel(effectiveDiagnosticLevel(options, resolved));
}

fn effectiveDiagnosticLevel(options: CommandOptions, resolved: ?*const project.Resolved) error_report.DiagnosticLevel {
    if (options.quiet) return .@"error";
    if (options.diagnostic_level) |level| return level;
    if (resolved) |project_resolved| {
        if (project_resolved.cli.diagnostic_level) |level| return level;
    }
    return .warning;
}

fn commandProgress(total: usize, options: CommandOptions) utils.progress.Progress {
    return if (options.quiet)
        utils.progress.Progress.disabled(total)
    else
        utils.progress.Progress.init(total);
}

fn applyColorArgs(args: []const []const u8) !void {
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (!std.mem.eql(u8, args[i], "--color")) continue;
        if (i + 1 >= args.len) return failUsage("missing value for --color", .{});
        const value = args[i + 1];
        if (!std.mem.eql(u8, value, "auto") and !std.mem.eql(u8, value, "always") and !std.mem.eql(u8, value, "never")) {
            return failUsage("invalid --color value: {s}", .{value});
        }
        setColorMode(parseColorMode(value));
        i += 1;
    }
}

fn isHelpArg(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "help") or std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h");
}

fn wantsCommandHelp(args: []const []const u8) bool {
    var saw_help = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (isHelpArg(arg)) {
            if (saw_help) return false;
            saw_help = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--color")) {
            if (i + 1 >= args.len) return false;
            i += 1;
            continue;
        }
        return false;
    }
    return saw_help;
}

fn helpTopic(args: []const []const u8) ?[]const u8 {
    var topic: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (isHelpArg(arg)) continue;
        if (std.mem.eql(u8, arg, "--color")) {
            if (i + 1 >= args.len) return null;
            i += 1;
            continue;
        }
        if (topic != null) return null;
        topic = arg;
    }
    return topic;
}

fn parseInitOptions(args: []const []const u8) !InitOptions {
    var options = InitOptions{};
    var saw_dir = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--entry")) {
            if (i + 1 >= args.len) return failUsage("missing value for --entry", .{});
            options.entry = args[i + 1];
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--force")) {
            options.force = true;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--")) return failUsage("unknown flag: {s}", .{arg});
        if (saw_dir) return failUsage("too many arguments: {s}", .{arg});
        options.dir = arg;
        saw_dir = true;
    }
    return options;
}

fn parseDoctorOptions(args: []const []const u8) !DoctorOptions {
    var options = DoctorOptions{};
    var positional_index: usize = 0;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--asset-base-dir")) {
            if (i + 1 >= args.len) return failUsage("missing value for --asset-base-dir", .{});
            options.asset_base_dir = args[i + 1];
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--project")) {
            if (i + 1 >= args.len) return failUsage("missing value for --project", .{});
            options.project_path = args[i + 1];
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--strict")) {
            options.strict = true;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--")) return failUsage("unknown flag: {s}", .{arg});
        switch (positional_index) {
            0 => options.input_path = arg,
            else => return failUsage("too many arguments: {s}", .{arg}),
        }
        positional_index += 1;
    }
    return options;
}

fn projectTemplate(allocator: std.mem.Allocator, entry: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\[project]
        \\entry = "{s}"
        \\asset_base_dir = "."
        \\
    , .{entry});
}

fn starterSlideTemplate() []const u8 {
    return
    \\import std:themes/default as *
    \\
    \\page title
    \\cover!(
    \\  "Hello, ss",
    \\  "Write slides as programs.",
    \\  "ss init"
    \\)
    \\end
    \\
    \\page body
    \\let title = head! "First slide"
    \\let body = text! <<
    \\- Edit slide.ss.
    \\- Run `ss render --project . --output deck.pdf`.
    \\>>
    \\
    \\~ body.top == title.bottom - 32
    \\pageno!()
    \\end
    \\
    ;
}

fn initProject(io: std.Io, allocator: std.mem.Allocator, options: InitOptions) !void {
    if (std.fs.path.isAbsolute(options.entry) or relativePathEscapesRoot(options.entry)) {
        std.debug.print("init: --entry must stay inside the project directory\n", .{});
        return error.InitEntryMustBeRelative;
    }

    try std.Io.Dir.cwd().createDirPath(io, options.dir);

    const project_path = try std.fs.path.join(allocator, &.{ options.dir, "ss.toml" });
    defer allocator.free(project_path);
    const entry_path = try std.fs.path.join(allocator, &.{ options.dir, options.entry });
    defer allocator.free(entry_path);

    if (!options.force) {
        var failed = false;
        if (try utils.fs.fileExists(allocator, project_path)) {
            std.debug.print("init: {s} already exists; pass --force to overwrite it\n", .{project_path});
            failed = true;
        }
        if (try utils.fs.fileExists(allocator, entry_path)) {
            std.debug.print("init: {s} already exists; pass --force to overwrite it\n", .{entry_path});
            failed = true;
        }
        if (failed) return error.InitTargetExists;
    }

    if (std.fs.path.dirname(entry_path)) |entry_dir| {
        try std.Io.Dir.cwd().createDirPath(io, entry_dir);
    }

    const project_source = try projectTemplate(allocator, options.entry);
    defer allocator.free(project_source);
    try utils.fs.writeFile(io, project_path, project_source);
    try utils.fs.writeFile(io, entry_path, starterSlideTemplate());

    std.debug.print("created ss project: {s}\n", .{options.dir});
    std.debug.print("  {s}\n", .{project_path});
    std.debug.print("  {s}\n", .{entry_path});
    std.debug.print("\nnext:\n  ss render --project {s} --output deck.pdf\n", .{options.dir});
}

fn relativePathEscapesRoot(path: []const u8) bool {
    var depth: usize = 0;
    var parts = std.mem.tokenizeAny(u8, path, "/\\");
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) {
            if (depth == 0) return true;
            depth -= 1;
            continue;
        }
        depth += 1;
    }
    return false;
}

const DoctorTool = struct {
    name: []const u8,
    purpose: []const u8,
};

const doctor_tools = [_]DoctorTool{
    .{ .name = "pdflatex", .purpose = "LaTeX math rendering" },
    .{ .name = "lualatex", .purpose = "LuaLaTeX math rendering" },
};

fn runDoctor(
    io: std.Io,
    allocator: std.mem.Allocator,
    environ: std.process.Environ,
    options: DoctorOptions,
) !void {
    std.debug.print("ss doctor\n", .{});
    std.debug.print("version: {s} ({s})\n\n", .{ build_options.version, build_options.commit });

    var highlight_config: ?utils.highlight.Config = null;
    defer if (highlight_config) |*cfg| cfg.deinit(allocator);

    var issues: usize = 0;
    issues += try doctorProject(io, allocator, options, &highlight_config);
    issues += try doctorTools(allocator, environ);
    issues += try doctorTreeSitter(io, allocator, if (highlight_config) |*cfg| cfg.languages else null);

    if (issues == 0) {
        std.debug.print("\ndoctor: ok\n", .{});
        return;
    }

    std.debug.print("\ndoctor: {d} issue(s) found", .{issues});
    if (!options.strict) std.debug.print(" (use --strict to fail on issues)", .{});
    std.debug.print("\n", .{});
    if (options.strict) return error.DoctorIssues;
}

fn doctorProject(
    io: std.Io,
    allocator: std.mem.Allocator,
    options: DoctorOptions,
    highlight_config: *?utils.highlight.Config,
) !usize {
    std.debug.print("project:\n", .{});
    if (options.input_path == null and options.project_path == null and options.asset_base_dir == null) {
        const discovered_path = try project.discoverPath(allocator, ".");
        if (discovered_path == null) {
            std.debug.print("  warn project configuration: not found from current directory\n", .{});
            return 1;
        }
        defer allocator.free(discovered_path.?);
        var config = project.loadFile(allocator, io, discovered_path.?) catch |err| {
            var reason_buf: [256]u8 = undefined;
            std.debug.print("  fail project configuration {s}: {s}\n", .{
                discovered_path.?,
                project.configErrorMessage(err) orelse error_report.formatErrorReason(&reason_buf, err),
            });
            return 1;
        };
        defer config.deinit(allocator);
        highlight_config.* = try config.highlight.clone(allocator);
        return doctorResolvedProject(io, config.path, config.entry, config.asset_base_dir);
    }

    const project_config_path = try projectConfigPathForOptions(allocator, .{
        .input_path = options.input_path,
        .project_path = options.project_path,
    });
    defer if (project_config_path) |path| allocator.free(path);
    var resolved = project.resolve(allocator, io, options.input_path, options.project_path, options.asset_base_dir) catch |err| {
        var reason_buf: [256]u8 = undefined;
        const reason = project.configErrorMessage(err) orelse error_report.formatErrorReason(&reason_buf, err);
        if (project_config_path) |path| {
            std.debug.print("  fail resolve {s}: {s}\n", .{ path, reason });
        } else {
            std.debug.print("  fail resolve: {s}\n", .{reason});
        }
        return 1;
    };
    defer resolved.deinit(allocator);
    highlight_config.* = try resolved.highlight.clone(allocator);
    return doctorResolvedProject(
        io,
        resolved.project_file orelse "(explicit input)",
        resolved.entry_path,
        resolved.asset_base_dir,
    );
}

fn doctorResolvedProject(
    io: std.Io,
    project_file: []const u8,
    entry_path: []const u8,
    asset_base_dir: []const u8,
) usize {
    var issues: usize = 0;
    if (std.mem.eql(u8, project_file, "(explicit input)")) {
        std.debug.print("  ok project: explicit input\n", .{});
    } else {
        std.debug.print("  ok ss.toml: {s}\n", .{project_file});
    }
    const cwd = std.Io.Dir.cwd();
    const entry_stat = cwd.statFile(io, entry_path, .{}) catch |err| blk: {
        var reason_buf: [256]u8 = undefined;
        std.debug.print("  fail entry: {s}: {s}\n", .{ entry_path, error_report.formatErrorReason(&reason_buf, err) });
        issues += 1;
        break :blk null;
    };
    if (entry_stat) |stat| {
        if (stat.kind == .directory) {
            std.debug.print("  fail entry: {s}: expected a file, but found a directory\n", .{entry_path});
            issues += 1;
        } else {
            std.debug.print("  ok entry: {s}\n", .{entry_path});
        }
    }
    const asset_base_stat = cwd.statFile(io, asset_base_dir, .{}) catch |err| blk: {
        var reason_buf: [256]u8 = undefined;
        std.debug.print("  fail asset base: {s}: {s}\n", .{ asset_base_dir, error_report.formatErrorReason(&reason_buf, err) });
        issues += 1;
        break :blk null;
    };
    if (asset_base_stat) |stat| {
        if (stat.kind != .directory) {
            std.debug.print("  fail asset base: {s}: expected a directory\n", .{asset_base_dir});
            issues += 1;
        } else {
            std.debug.print("  ok asset base: {s}\n", .{asset_base_dir});
        }
    }
    return issues;
}

fn doctorTools(allocator: std.mem.Allocator, environ: std.process.Environ) !usize {
    std.debug.print("\nrender tools:\n", .{});
    var available: usize = 0;
    for (doctor_tools) |tool| {
        const found = try findOnPath(allocator, environ, tool.name);
        if (found) |path| {
            defer allocator.free(path);
            std.debug.print("  ok {s}: {s}\n", .{ tool.name, path });
            available += 1;
        } else {
            std.debug.print("  info {s}: not found ({s})\n", .{ tool.name, tool.purpose });
        }
    }
    if (available != 0) return 0;
    std.debug.print("  warn LaTeX engine: neither pdflatex nor lualatex was found\n", .{});
    return 1;
}

fn doctorTreeSitter(
    io: std.Io,
    allocator: std.mem.Allocator,
    configured_languages: ?[]const utils.highlight.Language,
) !usize {
    std.debug.print("\ntree-sitter:\n", .{});
    if (utils.tree_sitter_cache.pathExists(allocator, build_options.tree_sitter_cache_root)) {
        std.debug.print("  ok cache: {s}\n", .{build_options.tree_sitter_cache_root});
    } else {
        std.debug.print("  info cache: {s} not found\n", .{build_options.tree_sitter_cache_root});
    }
    if (utils.tree_sitter_cache.pathExists(allocator, build_options.tree_sitter_bundle_root)) {
        std.debug.print("  ok bundle: {s}\n", .{build_options.tree_sitter_bundle_root});
    } else {
        std.debug.print("  info bundle: {s} not found\n", .{build_options.tree_sitter_bundle_root});
    }
    std.debug.print("  ok manifest hash: {s}\n", .{build_options.tree_sitter_manifest_hash});
    std.debug.print("  ok runtime ABI range: {d}..{d}\n", .{
        render_compiler.tree_sitter_min_compatible_language_version,
        render_compiler.tree_sitter_language_version,
    });

    var default_config: ?utils.highlight.Config = null;
    defer if (default_config) |*cfg| cfg.deinit(allocator);
    const languages = configured_languages orelse blk: {
        default_config = try utils.highlight.defaultConfig(allocator);
        break :blk default_config.?.languages;
    };

    var report = try render_compiler.treeSitterHealthReport(allocator, io, languages);
    defer report.deinit(allocator);

    if (report.items.len == 0) {
        std.debug.print("  fail languages: no configured highlight languages\n", .{});
        return 1;
    }

    std.debug.print("  ok configured names: {d}\n", .{report.configured_languages});
    for (report.items) |item| {
        switch (item.status) {
            .ok => std.debug.print(
                "  ok {s}: parser={s}, query={s}, captures={d}, mapped={d}\n",
                .{ item.name, item.parser, item.query, item.capture_count, item.mapped_capture_count },
            ),
            .warning => std.debug.print(
                "  warn {s}: parser={s}, query={s}: {s}\n",
                .{ item.name, item.parser, item.query, item.detail },
            ),
            .fail => std.debug.print(
                "  fail {s}: parser={s}, query={s}: {s}\n",
                .{ item.name, item.parser, item.query, item.detail },
            ),
        }
    }
    return report.failures + report.warnings;
}

fn findOnPath(allocator: std.mem.Allocator, environ: std.process.Environ, name: []const u8) !?[]u8 {
    if (std.mem.indexOfAny(u8, name, "/\\")) |_| {
        return if (isExecutable(allocator, name)) try allocator.dupe(u8, name) else null;
    }

    const path_env = std.process.Environ.getAlloc(environ, allocator, "PATH") catch |err| switch (err) {
        error.EnvironmentVariableMissing => return null,
        else => |e| return e,
    };
    defer allocator.free(path_env);

    var it = std.mem.splitScalar(u8, path_env, std.fs.path.delimiter);
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const candidate = try std.fs.path.join(allocator, &.{ dir, name });
        if (isExecutable(allocator, candidate)) return candidate;
        allocator.free(candidate);
    }
    return null;
}

fn isExecutable(allocator: std.mem.Allocator, path: []const u8) bool {
    const zpath = allocator.dupeZ(u8, path) catch return false;
    defer allocator.free(zpath);
    return std.c.access(zpath.ptr, std.c.X_OK) == 0;
}

fn resolveProjectOrUsage(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: CommandOptions,
) !project.Resolved {
    var resolved = project.resolve(allocator, io, options.input_path, options.project_path, options.asset_base_dir) catch |err| {
        if (err == error.MissingInputPath) {
            return failUsage("missing input path or --project", .{});
        }
        if (project.isConfigError(err)) {
            if (try printProjectConfigErrorForOptions(allocator, io, options, err)) {
                return error.DiagnosticsFailed;
            }
        }
        if (error_report.isFileSystemError(err)) {
            if (try printProjectConfigAccessErrorForOptions(allocator, options, err)) {
                return error.DiagnosticsFailed;
            }
        }
        return err;
    };
    errdefer resolved.deinit(allocator);
    try validateResolvedEntryPath(allocator, io, options, &resolved);
    return resolved;
}

fn printProjectConfigAccessErrorForOptions(
    allocator: std.mem.Allocator,
    options: CommandOptions,
    err: anyerror,
) !bool {
    const maybe_config_path = try projectConfigPathForOptions(allocator, options);
    const config_path = maybe_config_path orelse return false;
    defer allocator.free(config_path);
    const message = switch (err) {
        error.IsDir => try std.fmt.allocPrint(
            allocator,
            "ProjectConfigIsDirectory: expected an ss.toml file, but found a directory: {s}",
            .{config_path},
        ),
        error.FileNotFound => try std.fmt.allocPrint(
            allocator,
            "ProjectConfigNotFound: project configuration file was not found: {s}",
            .{config_path},
        ),
        else => blk: {
            if (!error_report.isFileSystemError(err)) return false;
            var reason_buf: [256]u8 = undefined;
            break :blk try std.fmt.allocPrint(
                allocator,
                "ProjectConfigReadFailed: could not read project configuration '{s}': {s}",
                .{ config_path, error_report.formatErrorReason(&reason_buf, err) },
            );
        },
    };
    defer allocator.free(message);
    error_report.print(.{
        .path = config_path,
        .source = "",
        .severity = .@"error",
        .message = message,
        .span = null,
    });
    return true;
}

const EntryPathProblem = enum {
    not_found,
    is_directory,
};

fn validateResolvedEntryPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: CommandOptions,
    resolved: *const project.Resolved,
) !void {
    const stat = std.Io.Dir.cwd().statFile(io, resolved.entry_path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            try printEntryPathDiagnostic(allocator, io, options, resolved, .not_found);
            return error.DiagnosticsFailed;
        },
        else => {
            if (!error_report.isFileSystemError(err)) return err;
            var message_buf: [8192]u8 = undefined;
            const code = if (options.input_path != null) "InputAccessFailed" else "ProjectEntryAccessFailed";
            const operation = if (options.input_path != null) "inspect input file" else "inspect project entry file";
            error_report.print(.{
                .path = resolved.entry_path,
                .source = "",
                .severity = .@"error",
                .message = error_report.formatPathFailure(&message_buf, code, operation, resolved.entry_path, err),
                .span = null,
            });
            return error.DiagnosticsFailed;
        },
    };
    if (stat.kind != .directory) return;
    try printEntryPathDiagnostic(allocator, io, options, resolved, .is_directory);
    return error.DiagnosticsFailed;
}

fn printEntryPathDiagnostic(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: CommandOptions,
    resolved: *const project.Resolved,
    problem: EntryPathProblem,
) !void {
    const explicit_input = options.input_path != null;
    const message = if (explicit_input)
        switch (problem) {
            .not_found => try std.fmt.allocPrint(
                allocator,
                "InputNotFound: input file was not found: {s}",
                .{resolved.entry_path},
            ),
            .is_directory => try std.fmt.allocPrint(
                allocator,
                "InputIsDirectory: input path is a directory: {s}; use `--project {s}` to load its ss.toml",
                .{ resolved.entry_path, resolved.entry_path },
            ),
        }
    else switch (problem) {
        .not_found => try std.fmt.allocPrint(
            allocator,
            "ProjectEntryNotFound: project entry file was not found: {s}",
            .{resolved.entry_path},
        ),
        .is_directory => try std.fmt.allocPrint(
            allocator,
            "ProjectEntryIsDirectory: project entry must be a file, but found a directory: {s}",
            .{resolved.entry_path},
        ),
    };
    defer allocator.free(message);

    if (!explicit_input) {
        if (resolved.project_file) |config_path| {
            const config_source = utils.fs.readFileAlloc(io, allocator, config_path) catch null;
            if (config_source) |source_text| {
                defer allocator.free(source_text);
                error_report.print(.{
                    .path = config_path,
                    .source = source_text,
                    .severity = .@"error",
                    .message = message,
                    .span = project.tomlKeySpan(source_text, "project", "entry"),
                });
                return;
            }
        }
    }

    error_report.print(.{
        .path = resolved.entry_path,
        .source = "",
        .severity = .@"error",
        .message = message,
        .span = null,
    });
}

fn printProjectConfigErrorForOptions(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: CommandOptions,
    err: anyerror,
) !bool {
    const maybe_config_path = try projectConfigPathForOptions(allocator, options);
    const config_path = maybe_config_path orelse return false;
    defer allocator.free(config_path);
    const source = utils.fs.readFileAlloc(io, allocator, config_path) catch return false;
    defer allocator.free(source);
    const message = project.configErrorMessage(err) orelse return false;
    error_report.print(.{
        .path = config_path,
        .source = source,
        .severity = .@"error",
        .message = message,
        .span = project.configErrorSpan(source, err),
    });
    return true;
}

fn projectConfigPathForOptions(allocator: std.mem.Allocator, options: CommandOptions) !?[]u8 {
    if (options.project_path) |arg| {
        const absolute = try project.absolutePath(allocator, arg);
        defer allocator.free(absolute);
        if (std.mem.endsWith(u8, absolute, ".toml")) return try allocator.dupe(u8, absolute);
        return try std.fs.path.join(allocator, &.{ absolute, "ss.toml" });
    }
    if (options.input_path) |input| {
        const absolute = try project.absolutePath(allocator, input);
        defer allocator.free(absolute);
        const dir = std.fs.path.dirname(absolute) orelse ".";
        return try project.discoverPath(allocator, dir);
    }
    return try project.discoverPath(allocator, ".");
}

fn runWatchCommand(
    io: std.Io,
    allocator: std.mem.Allocator,
    mode: watcher.Mode,
    options: CommandOptions,
) !void {
    var resolved = project.resolve(allocator, io, options.input_path, options.project_path, options.asset_base_dir) catch |err| {
        if (watchRecoverableProjectError(options, err)) {
            try printWatchProjectError(io, allocator, options, err);
            try waitForWatchProject(io, allocator, mode, options, err);
            return;
        }
        if (err == error.MissingInputPath) return failUsage("missing input path or --project", .{});
        if (error_report.isFileSystemError(err)) {
            try printWatchProjectError(io, allocator, options, err);
            return error.DiagnosticsFailed;
        }
        return err;
    };
    defer resolved.deinit(allocator);
    applyDiagnosticOptions(options, &resolved);
    try runResolvedWatch(io, allocator, mode, options, &resolved);
}

fn waitForWatchProject(
    io: std.Io,
    allocator: std.mem.Allocator,
    mode: watcher.Mode,
    options: CommandOptions,
    first_error: anyerror,
) !void {
    const interval_ms = @max(options.interval_ms, 50);
    std.debug.print("watch: project configuration is unavailable: {s}; waiting every {d}ms\n", .{ project.configErrorMessage(first_error) orelse "project configuration could not be loaded", interval_ms });
    var last_error = first_error;
    while (true) {
        const sleep_ms: i64 = @intCast(@min(interval_ms, @as(u64, std.math.maxInt(i64))));
        try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(sleep_ms), .awake);

        var resolved = project.resolve(allocator, io, options.input_path, options.project_path, options.asset_base_dir) catch |err| {
            if (watchRecoverableProjectError(options, err)) {
                if (err != last_error) {
                    try printWatchProjectError(io, allocator, options, err);
                    std.debug.print("watch: project configuration is still unavailable: {s}\n", .{project.configErrorMessage(err) orelse "project configuration could not be loaded"});
                    last_error = err;
                }
                continue;
            }
            if (err == error.MissingInputPath) return failUsage("missing input path or --project", .{});
            if (error_report.isFileSystemError(err)) {
                try printWatchProjectError(io, allocator, options, err);
                return error.DiagnosticsFailed;
            }
            return err;
        };
        defer resolved.deinit(allocator);
        std.debug.print("watch: project configuration is valid\n", .{});
        applyDiagnosticOptions(options, &resolved);
        try runResolvedWatch(io, allocator, mode, options, &resolved);
        return;
    }
}

fn printWatchProjectError(
    io: std.Io,
    allocator: std.mem.Allocator,
    options: CommandOptions,
    err: anyerror,
) !void {
    if (project.isConfigError(err)) {
        if (try printProjectConfigErrorForOptions(allocator, io, options, err)) return;
        const maybe_config_path = try projectConfigPathForOptions(allocator, options);
        if (maybe_config_path) |config_path| {
            defer allocator.free(config_path);
            error_report.print(.{
                .path = config_path,
                .source = "",
                .severity = .@"error",
                .message = project.configErrorMessage(err) orelse "ProjectConfigInvalid: ss.toml is invalid; fix the reported configuration and save the file to resume watching",
                .span = null,
            });
        }
        return;
    }
    if (error_report.isFileSystemError(err)) {
        if (try printProjectConfigAccessErrorForOptions(allocator, options, err)) return;
    }
    if (err == error.MissingInputPath) {
        const current_dir = try project.absolutePath(allocator, ".");
        defer allocator.free(current_dir);
        const expected_config = try std.fs.path.join(allocator, &.{ current_dir, "ss.toml" });
        defer allocator.free(expected_config);
        error_report.print(.{
            .path = expected_config,
            .source = "",
            .severity = .@"error",
            .message = "WatchInputUnavailable: no input file was given and no ss.toml was found; pass an input file or --project, or create ss.toml to resume watching",
            .span = null,
        });
    }
}

fn watchRecoverableProjectError(options: CommandOptions, err: anyerror) bool {
    return project.isConfigError(err) or
        (options.input_path == null and err == error.MissingInputPath) or
        (options.project_path != null and error_report.isFileSystemError(err));
}

fn runResolvedWatch(
    io: std.Io,
    allocator: std.mem.Allocator,
    mode: watcher.Mode,
    options: CommandOptions,
    resolved: *const project.Resolved,
) !void {
    const output_path = if (mode == .render)
        options.output_path orelse try utils.fs.siblingPathWithExtension(
            allocator,
            resolved.entry_path,
            if (options.format == .pdf) "pdf" else "html",
        )
    else
        options.output_path;
    if (output_path) |path| try validateOutputParentOrCliError(io, path);
    if (mode == .render) {
        if (output_path) |path| try validateOutputPathConflicts(io, allocator, resolved, &.{.{ .path = path, .option = "--output" }});
    }
    try watcher.run(io, allocator, mode, .{
        .input_path = resolved.entry_path,
        .output_path = output_path,
        .asset_base_dir = resolved.asset_base_dir,
        .project_file = resolved.project_file,
        .highlight_languages = resolved.highlight.languages,
        .format = options.format,
        .jobs = options.jobs,
        .interval_ms = options.interval_ms,
        .quiet = options.quiet,
    });
}

fn runDebugCommand(
    io: std.Io,
    allocator: std.mem.Allocator,
    args: []const []const u8,
) !void {
    if (wantsCommandHelp(args) or (args.len == 2 and std.mem.eql(u8, args[0], "layout") and isHelpArg(args[1]))) {
        _ = cli_help.command(.stdout, "debug");
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[0], "schedule") and isHelpArg(args[1])) {
        _ = cli_help.command(.stdout, "debug");
        return;
    }
    if (args.len == 3 and std.mem.eql(u8, args[0], "layout") and (std.mem.eql(u8, args[1], "conflicts") or std.mem.eql(u8, args[1], "trace")) and isHelpArg(args[2])) {
        _ = cli_help.command(.stdout, "debug");
        return;
    }
    if (args.len == 0) return failUsage("missing debug topic", .{});
    const topic = args[0];

    if (std.mem.eql(u8, topic, "schedule")) {
        const options = try parseCommandOptions(args[1..]);
        applyDiagnosticOptions(options, null);
        const output_path = options.output_path orelse return failUsage("missing --output for ss debug schedule", .{});
        try validateOutputParentOrCliError(io, output_path);
        var resolved = try resolveProjectOrUsage(allocator, io, options);
        defer resolved.deinit(allocator);
        applyDiagnosticOptions(options, &resolved);
        try validateOutputPathConflicts(io, allocator, &resolved, &.{.{ .path = output_path, .option = "--output" }});
        var progress = commandProgress(5, options);
        try app.writeScheduleTraceJson(io, allocator, .{
            .input_path = resolved.entry_path,
            .asset_base_dir = resolved.asset_base_dir,
            .layout_jobs = options.jobs,
        }, output_path, &progress);
        return;
    }

    if (std.mem.eql(u8, topic, "layout")) {
        if (args.len < 2) return failUsage("missing debug layout topic", .{});
        const layout_topic = args[1];
        const options = try parseCommandOptions(args[2..]);
        applyDiagnosticOptions(options, null);
        const output_path = options.output_path orelse return failUsage("missing --output for ss debug layout {s}", .{layout_topic});
        try validateOutputParentOrCliError(io, output_path);
        var resolved = try resolveProjectOrUsage(allocator, io, options);
        defer resolved.deinit(allocator);
        applyDiagnosticOptions(options, &resolved);
        try validateOutputPathConflicts(io, allocator, &resolved, &.{.{ .path = output_path, .option = "--output" }});

        if (std.mem.eql(u8, layout_topic, "trace")) {
            var progress = commandProgress(6, options);
            try app.writeLayoutTraceJson(io, allocator, .{
                .input_path = resolved.entry_path,
                .asset_base_dir = resolved.asset_base_dir,
                .layout_jobs = options.jobs,
            }, output_path, &progress);
            return;
        }
        if (std.mem.eql(u8, layout_topic, "conflicts")) {
            var progress = commandProgress(8, options);
            try app.writeLayoutConflictReportFile(io, allocator, .{
                .input_path = resolved.entry_path,
                .asset_base_dir = resolved.asset_base_dir,
                .layout_jobs = options.jobs,
            }, output_path, &progress);
            return;
        }
        return failUsage("unknown debug layout topic: {s}", .{layout_topic});
    }

    return failUsage("unknown debug topic: {s}", .{topic});
}

fn validateOutputParentOrCliError(io: std.Io, output_path: []const u8) !void {
    utils.fs.validateOutputParent(io, output_path) catch |err| switch (err) {
        error.OutputParentNotFound => {
            const parent = std.fs.path.dirname(output_path) orelse ".";
            return failCli("output parent directory does not exist: {s}", .{parent});
        },
        error.OutputParentNotDirectory => {
            const parent = std.fs.path.dirname(output_path) orelse ".";
            return failCli("output parent path is not a directory: {s}", .{parent});
        },
        else => {
            if (!error_report.isFileSystemError(err)) return err;
            var message_buf: [8192]u8 = undefined;
            const parent = std.fs.path.dirname(output_path) orelse ".";
            return failCli("{s}", .{error_report.formatPathFailure(&message_buf, "OutputPathAccessFailed", "inspect output parent", parent, err)});
        },
    };
    const output_stat = std.Io.Dir.cwd().statFile(io, output_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => {
            if (!error_report.isFileSystemError(err)) return err;
            var message_buf: [8192]u8 = undefined;
            return failCli("{s}", .{error_report.formatPathFailure(&message_buf, "OutputPathAccessFailed", "inspect output path", output_path, err)});
        },
    };
    if (output_stat.kind == .directory) {
        return failCli("output path is a directory: {s}", .{output_path});
    }
}

const OutputTarget = struct {
    path: []const u8,
    option: []const u8,
};

fn validateOutputPathConflicts(
    io: std.Io,
    allocator: std.mem.Allocator,
    resolved: *const project.Resolved,
    outputs: []const OutputTarget,
) !void {
    for (outputs) |output| {
        if (try project.pathsReferToSameFile(allocator, io, output.path, resolved.entry_path)) {
            const absolute = try project.absolutePath(allocator, output.path);
            defer allocator.free(absolute);
            return failCli(
                "OutputPathConflictsWithInput: {s} resolves to the input file '{s}'; choose a different output path",
                .{ output.option, absolute },
            );
        }
        if (resolved.project_file) |project_file| {
            if (try project.pathsReferToSameFile(allocator, io, output.path, project_file)) {
                const absolute = try project.absolutePath(allocator, output.path);
                defer allocator.free(absolute);
                return failCli(
                    "OutputPathConflictsWithProject: {s} resolves to project configuration '{s}'; choose a different output path",
                    .{ output.option, absolute },
                );
            }
        }
    }

    for (outputs, 0..) |left, left_index| {
        for (outputs[left_index + 1 ..]) |right| {
            if (!try project.pathsReferToSameFile(allocator, io, left.path, right.path)) continue;
            const absolute = try project.absolutePath(allocator, left.path);
            defer allocator.free(absolute);
            return failCli(
                "OutputPathsConflict: {s} and {s} resolve to the same file '{s}'; choose different output paths",
                .{ left.option, right.option, absolute },
            );
        }
    }
}

fn runCacheCommand(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (wantsCommandHelp(args)) {
        _ = cli_help.command(.stdout, "cache");
        return;
    }
    if (args.len < 1) return failUsage("missing cache target", .{});
    if (std.mem.eql(u8, args[0], "project")) return runProjectCacheCommand(io, allocator, args[1..]);
    if (std.mem.eql(u8, args[0], "tree-sitter")) return runTreeSitterCacheCommand(io, allocator, args[1..]);
    return failUsage("unknown cache target: {s}", .{args[0]});
}

fn runProjectCacheCommand(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (wantsCommandHelp(args)) {
        _ = cli_help.command(.stdout, "cache");
        return;
    }
    if (args.len < 1) return failUsage("missing project cache command", .{});
    if (args.len == 1 and std.mem.eql(u8, args[0], "clear")) {
        utils.render_cache.clear(io) catch |err| switch (err) {
            error.ActiveRenderCacheLease => return failCli("project render cache is currently in use", .{}),
            else => return err,
        };
        std.debug.print("cleared project render cache: {s}\n", .{utils.render_cache.path});
        return;
    }
    if (args.len == 1 and std.mem.eql(u8, args[0], "stats")) {
        const stats = try utils.render_cache.stats(io, allocator);
        printCacheStats(stats);
        return;
    }
    return failUsage("unknown project cache command: {s}", .{args[0]});
}

fn runTreeSitterCacheCommand(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (wantsCommandHelp(args)) {
        _ = cli_help.command(.stdout, "cache");
        return;
    }
    if (args.len < 1) return failUsage("missing tree-sitter cache command", .{});
    if (args.len == 1 and std.mem.eql(u8, args[0], "stats")) {
        try printTreeSitterCacheStats(io, allocator);
        return;
    }
    if (args.len == 1 and std.mem.eql(u8, args[0], "clear")) {
        const before = try utils.tree_sitter_cache.stats(io, allocator, build_options.tree_sitter_cache_root);
        try utils.tree_sitter_cache.clear(io, build_options.tree_sitter_cache_root);
        std.debug.print("cleared tree-sitter cache: {s}\n", .{build_options.tree_sitter_cache_root});
        std.debug.print("removed: ", .{});
        printByteSize(before.bytes);
        std.debug.print("\n", .{});
        return;
    }
    if (args.len == 1 and std.mem.eql(u8, args[0], "prune")) {
        const before = try utils.tree_sitter_cache.stats(io, allocator, build_options.tree_sitter_cache_root);
        const result = try utils.tree_sitter_cache.prune(
            io,
            allocator,
            build_options.tree_sitter_cache_root,
            build_options.tree_sitter_manifest_hash,
        );
        const after = try utils.tree_sitter_cache.stats(io, allocator, build_options.tree_sitter_cache_root);
        std.debug.print("pruned tree-sitter cache: {s}\n", .{build_options.tree_sitter_cache_root});
        std.debug.print("removed bundles: {d}\n", .{result.removed_bundles});
        std.debug.print("removed build dirs: {d}\n", .{result.removed_build_dirs});
        std.debug.print("removed source dirs: {d}\n", .{result.removed_source_dirs});
        std.debug.print("freed: ", .{});
        printByteSize(before.bytes -| after.bytes);
        std.debug.print("\n", .{});
        return;
    }
    return failUsage("unknown tree-sitter cache command: {s}", .{args[0]});
}

fn printTreeSitterCacheStats(io: std.Io, allocator: std.mem.Allocator) !void {
    const total = try utils.tree_sitter_cache.stats(io, allocator, build_options.tree_sitter_cache_root);
    const current = try utils.tree_sitter_cache.stats(io, allocator, build_options.tree_sitter_bundle_root);
    const bundles = try utils.tree_sitter_cache.bundleCount(io, allocator, build_options.tree_sitter_cache_root);
    std.debug.print("tree-sitter cache: {s}\n", .{build_options.tree_sitter_cache_root});
    std.debug.print("current manifest hash: {s}\n", .{build_options.tree_sitter_manifest_hash});
    std.debug.print("current bundle: {s}\n", .{build_options.tree_sitter_bundle_root});
    std.debug.print("bundles: {d}\n", .{bundles});
    std.debug.print("total:\n", .{});
    printCacheTotals(total.files, total.directories, total.bytes);
    std.debug.print("current bundle:\n", .{});
    printCacheTotals(current.files, current.directories, current.bytes);
}

fn run(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const io = init.io;
    const environ = init.minimal.environ;
    const args = try init.minimal.args.toSlice(allocator);
    try applyColorArgs(args);

    if (args.len < 2) {
        cli_help.general(.stdout);
        return;
    }

    const cmd = args[1];
    if (std.mem.eql(u8, cmd, "help")) {
        if (helpTopic(args[2..])) |topic| {
            if (!cli_help.command(.stdout, topic)) return failUsage("unknown help topic: {s}", .{topic});
        } else {
            cli_help.general(.stdout);
        }
        return;
    }
    if (std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) {
        cli_help.general(.stdout);
        return;
    }
    if (std.mem.eql(u8, cmd, "--version") or std.mem.eql(u8, cmd, "-V") or std.mem.eql(u8, cmd, "version")) {
        if (std.mem.eql(u8, cmd, "version") and wantsCommandHelp(args[2..])) {
            _ = cli_help.command(.stdout, "version");
            return;
        }
        version();
        return;
    }

    if (std.mem.eql(u8, cmd, "check")) {
        if (wantsCommandHelp(args[2..])) {
            _ = cli_help.command(.stdout, "check");
            return;
        }
        const options = try parseCommandOptions(args[2..]);
        applyDiagnosticOptions(options, null);
        var resolved = try resolveProjectOrUsage(allocator, io, options);
        defer resolved.deinit(allocator);
        applyDiagnosticOptions(options, &resolved);
        var progress = commandProgress(6, options);
        try app.checkFile(io, allocator, .{
            .input_path = resolved.entry_path,
            .asset_base_dir = resolved.asset_base_dir,
            .layout_jobs = options.jobs,
            .highlight_languages = resolved.highlight.languages,
        }, &progress);
        return;
    }

    if (std.mem.eql(u8, cmd, "dump")) {
        if (wantsCommandHelp(args[2..])) {
            _ = cli_help.command(.stdout, "dump");
            return;
        }
        const options = try parseCommandOptions(args[2..]);
        applyDiagnosticOptions(options, null);
        var resolved = try resolveProjectOrUsage(allocator, io, options);
        defer resolved.deinit(allocator);
        applyDiagnosticOptions(options, &resolved);
        if (options.output_path) |output_path| {
            try validateOutputParentOrCliError(io, output_path);
            try validateOutputPathConflicts(io, allocator, &resolved, &.{.{ .path = output_path, .option = "--output" }});
            var progress = commandProgress(7, options);
            try app.writeContextJson(io, allocator, .{
                .input_path = resolved.entry_path,
                .asset_base_dir = resolved.asset_base_dir,
                .layout_jobs = options.jobs,
                .highlight_languages = resolved.highlight.languages,
            }, output_path, &progress);
        } else {
            var progress = commandProgress(7, options);
            try app.printContextJson(io, allocator, .{
                .input_path = resolved.entry_path,
                .asset_base_dir = resolved.asset_base_dir,
                .layout_jobs = options.jobs,
                .highlight_languages = resolved.highlight.languages,
            }, &progress);
        }
        return;
    }

    if (std.mem.eql(u8, cmd, "render")) {
        if (wantsCommandHelp(args[2..])) {
            _ = cli_help.command(.stdout, "render");
            return;
        }
        const options = try parseCommandOptions(args[2..]);
        applyDiagnosticOptions(options, null);
        var resolved = try resolveProjectOrUsage(allocator, io, options);
        defer resolved.deinit(allocator);
        applyDiagnosticOptions(options, &resolved);
        const output_path = options.output_path orelse try utils.fs.siblingPathWithExtension(
            allocator,
            resolved.entry_path,
            if (options.format == .pdf) "pdf" else "html",
        );
        try validateOutputParentOrCliError(io, output_path);
        if (options.diagnostics_json_path) |diagnostics_json_path| try validateOutputParentOrCliError(io, diagnostics_json_path);
        var output_targets = [_]OutputTarget{
            .{ .path = output_path, .option = "--output" },
            .{ .path = options.diagnostics_json_path orelse output_path, .option = "--diagnostics-json" },
        };
        const output_target_count: usize = if (options.diagnostics_json_path == null) 1 else 2;
        try validateOutputPathConflicts(io, allocator, &resolved, output_targets[0..output_target_count]);
        var progress = commandProgress(app.render_progress_steps, options);
        const render_options = app.RenderOptions{
            .jobs = options.jobs,
            .highlight_languages = resolved.highlight.languages,
        };
        const source = app.SourceRequest{
            .input_path = resolved.entry_path,
            .asset_base_dir = resolved.asset_base_dir,
            .layout_jobs = options.jobs,
            .highlight_languages = resolved.highlight.languages,
        };
        switch (options.format) {
            .pdf => try app.writePdf(io, allocator, .{
                .source = source,
                .output_path = output_path,
                .options = .{
                    .render = render_options,
                    .diagnostics_json_path = options.diagnostics_json_path,
                },
            }, &progress),
            .html => try app.writeHtml(io, allocator, .{
                .source = source,
                .output_path = output_path,
                .options = .{
                    .render = render_options,
                    .diagnostics_json_path = options.diagnostics_json_path,
                },
            }, &progress),
        }
        return;
    }

    if (std.mem.eql(u8, cmd, "init")) {
        if (wantsCommandHelp(args[2..])) {
            _ = cli_help.command(.stdout, "init");
            return;
        }
        const options = try parseInitOptions(args[2..]);
        try initProject(io, allocator, options);
        return;
    }

    if (std.mem.eql(u8, cmd, "doctor")) {
        if (wantsCommandHelp(args[2..])) {
            _ = cli_help.command(.stdout, "doctor");
            return;
        }
        const options = try parseDoctorOptions(args[2..]);
        try runDoctor(io, allocator, environ, options);
        return;
    }

    if (std.mem.eql(u8, cmd, "debug")) {
        try runDebugCommand(io, allocator, args[2..]);
        return;
    }

    if (std.mem.eql(u8, cmd, "lsp")) {
        if (wantsCommandHelp(args[2..])) {
            _ = cli_help.command(.stdout, "lsp");
            return;
        }
        try lsp.run(io, std.heap.smp_allocator);
        return;
    }

    if (std.mem.eql(u8, cmd, "watch")) {
        if (wantsCommandHelp(args[2..]) or (args.len == 4 and (std.mem.eql(u8, args[2], "check") or std.mem.eql(u8, args[2], "render")) and isHelpArg(args[3]))) {
            _ = cli_help.command(.stdout, "watch");
            return;
        }
        if (args.len < 3) {
            return failUsage("missing watch mode", .{});
        }
        const mode: watcher.Mode = if (std.mem.eql(u8, args[2], "check"))
            .check
        else if (std.mem.eql(u8, args[2], "render"))
            .render
        else {
            return failUsage("unknown watch mode: {s}", .{args[2]});
        };
        const options = try parseCommandOptions(args[3..]);
        applyDiagnosticOptions(options, null);
        try runWatchCommand(io, allocator, mode, options);
        return;
    }

    if (std.mem.eql(u8, cmd, "cache")) {
        try runCacheCommand(io, allocator, args[2..]);
        return;
    }

    if (std.mem.eql(u8, cmd, "completion")) {
        if (wantsCommandHelp(args[2..])) {
            _ = cli_help.command(.stdout, "completion");
            return;
        }
        const options = try parseCompletionOptions(args[2..]);
        try cli_completion.run(io, allocator, options);
        return;
    }

    return failUsage("unknown command: {s}", .{cmd});
}

pub fn main(init: std.process.Init) void {
    run(init) catch |err| {
        if (!error_report.isExpectedCliError(err)) error_report.printUnexpectedCliError(err);
        utils.measure_profile.printIfEnabled();
        std.process.exit(1);
    };
    utils.measure_profile.printIfEnabled();
}
