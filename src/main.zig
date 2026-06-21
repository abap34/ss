const std = @import("std");
const app = @import("app.zig");
const build_options = @import("build_options");
const utils = @import("utils");
const watcher = @import("watch.zig");
const project = @import("project.zig");
const lsp = @import("lsp.zig");
const error_report = utils.err;

fn usage() void {
    std.debug.print(
        \\Usage:
        \\ss <command> [arguments] [--asset-base-dir DIR] [--project FILE_OR_DIR] [--output FILE] [--jobs N] [--cache-id ID]
        \\
        \\Commands:
        \\  help
        \\    Show this help message
        \\  check [input.ss]
        \\    Parse and type-check; print diagnostics when needed
        \\  dump [input.ss] [output.json]
        \\    Print IR JSON, or write it when output path is given
        \\  render [input.ss] [output.pdf]
        \\    Render PDF to the specified path
        \\  init [dir]
        \\    Create a new ss.toml and starter slide deck
        \\  doctor
        \\    Check project discovery and render tool availability
        \\  debug schedule [input.ss]
        \\    Write the inferred dependency graph and execution order as JSON
        \\  debug layout-trace [input.ss]
        \\    Write the layout solver trace as JSON
        \\  lsp
        \\    Run the ss language server over stdio
        \\  watch check [input.ss]
        \\    Re-run check when the project changes
        \\  watch render [input.ss] [output.pdf]
        \\    Re-render PDF when the project changes
        \\  cache clear
        \\    Clear the managed render cache under .ss-cache/render
        \\  cache stats
        \\    Print managed render cache file, directory, and size totals
        \\
        \\Flags:
        \\  --version, -V
        \\    Show the ss version and source commit
        \\  --asset-base-dir DIR
        \\    Resolve relative assets/themes from DIR instead of the input file directory
        \\  --project FILE_OR_DIR
        \\    Resolve the entrypoint and asset base from ss.toml
        \\  --output FILE
        \\    Write dump/render output to FILE when the input comes from ss.toml
        \\  --jobs N
        \\    Number of parallel render jobs; render also reads SS_RENDER_JOBS
        \\  --cache-id ID
        \\    Stable render cache identity for snapshot-based render inputs
        \\  --diagnostics-json FILE
        \\    Write machine-readable diagnostics JSON for render
        \\  --interval-ms N
        \\    Poll interval for watch commands
        \\  --entry FILE
        \\    Entry file to create with ss init
        \\  --force
        \\    Allow ss init to overwrite generated files
        \\  --strict
        \\    Make ss doctor exit non-zero when it finds issues
        \\
        \\Examples:
        \\  ss help
        \\  ss check slide.ss
        \\  ss dump slide.ss
        \\  ss dump slide.ss out.json
        \\  ss dump --project . --output .ss-cache/dump.json
        \\  ss render slide.ss out.pdf
        \\  ss render --project . --output .ss-cache/render.pdf
        \\  ss debug schedule --project . --output .ss-cache/schedule.json
        \\  ss debug layout-trace --project . --output .ss-cache/layout-trace.json
        \\  ss init slides
        \\  ss doctor --project slides
        \\  ss watch check slide.ss
        \\  ss watch render slide.ss out.pdf
        \\  ss cache clear
        \\  ss cache stats
        \\  zig build run -- check slide.ss
        \\  zig build run -- render slide.ss out.pdf
        \\
    , .{});
}

fn failUsage(comptime fmt: []const u8, args: anytype) error{InvalidUsage} {
    std.debug.print(fmt ++ "\n\n", args);
    usage();
    return error.InvalidUsage;
}

fn failCli(comptime fmt: []const u8, args: anytype) error{InvalidUsage} {
    std.debug.print(fmt ++ "\n", args);
    return error.InvalidUsage;
}

fn version() void {
    var buffer: [128]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "ss {s} ({s})\n", .{ build_options.version, build_options.commit }) catch return;
    utils.io.writeStdoutAll(text) catch {};
}

fn printCacheStats(stats: utils.render_cache.Stats) void {
    std.debug.print("render cache: {s}\n", .{utils.render_cache.path});
    std.debug.print("files: {d}\n", .{stats.files});
    std.debug.print("directories: {d}\n", .{stats.directories});
    std.debug.print("size: ", .{});
    printByteSize(stats.bytes);
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
    cache_id: ?[]const u8 = null,
    diagnostics_json_path: ?[]const u8 = null,
    interval_ms: u64 = 500,
};

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
        if (std.mem.eql(u8, arg, "--jobs")) {
            if (i + 1 >= args.len) return failUsage("missing value for --jobs", .{});
            options.jobs = std.fmt.parseUnsigned(usize, args[i + 1], 10) catch {
                return failUsage("invalid --jobs value: {s}", .{args[i + 1]});
            };
            if (options.jobs.? == 0) return failUsage("--jobs must be greater than zero", .{});
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--cache-id")) {
            if (i + 1 >= args.len) return failUsage("missing value for --cache-id", .{});
            options.cache_id = args[i + 1];
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--diagnostics-json")) {
            if (i + 1 >= args.len) return failUsage("missing value for --diagnostics-json", .{});
            options.diagnostics_json_path = args[i + 1];
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
        if (utils.fs.fileExists(allocator, project_path)) {
            std.debug.print("init: {s} already exists; pass --force to overwrite it\n", .{project_path});
            failed = true;
        }
        if (utils.fs.fileExists(allocator, entry_path)) {
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
    required: bool = false,
};

const doctor_tools = [_]DoctorTool{
    .{ .name = "qpdf", .purpose = "PDF assembly and normalization", .required = true },
    .{ .name = "magick", .purpose = "raster image conversion and resizing" },
    .{ .name = "pdftocairo", .purpose = "PDF/vector asset conversion" },
    .{ .name = "pdflatex", .purpose = "LaTeX math rendering" },
};

fn runDoctor(
    io: std.Io,
    allocator: std.mem.Allocator,
    environ: std.process.Environ,
    options: DoctorOptions,
) !void {
    std.debug.print("ss doctor\n", .{});
    std.debug.print("version: {s} ({s})\n\n", .{ build_options.version, build_options.commit });

    var issues: usize = 0;
    issues += try doctorProject(io, allocator, options);
    issues += try doctorTools(allocator, environ);

    if (issues == 0) {
        std.debug.print("\ndoctor: ok\n", .{});
        return;
    }

    std.debug.print("\ndoctor: {d} issue(s) found", .{issues});
    if (!options.strict) std.debug.print(" (use --strict to fail on issues)", .{});
    std.debug.print("\n", .{});
    if (options.strict) return error.DoctorIssues;
}

fn doctorProject(io: std.Io, allocator: std.mem.Allocator, options: DoctorOptions) !usize {
    std.debug.print("project:\n", .{});
    if (options.input_path == null and options.project_path == null and options.asset_base_dir == null) {
        var discovered = project.discover(allocator, io, ".") catch |err| {
            std.debug.print("  fail ss.toml: {s}\n", .{@errorName(err)});
            return 1;
        };
        if (discovered) |*cfg| {
            defer cfg.deinit(allocator);
            return doctorResolvedProject(allocator, cfg.path, cfg.entry, cfg.asset_base_dir);
        }
        std.debug.print("  warn ss.toml: not found from current directory\n", .{});
        return 1;
    }

    var resolved = project.resolve(allocator, io, options.input_path, options.project_path, options.asset_base_dir) catch |err| {
        std.debug.print("  fail resolve: {s}\n", .{@errorName(err)});
        return 1;
    };
    defer resolved.deinit(allocator);
    return doctorResolvedProject(
        allocator,
        resolved.project_file orelse "(explicit input)",
        resolved.entry_path,
        resolved.asset_base_dir,
    );
}

fn doctorResolvedProject(
    allocator: std.mem.Allocator,
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
    if (utils.fs.fileExists(allocator, entry_path)) {
        std.debug.print("  ok entry: {s}\n", .{entry_path});
    } else {
        std.debug.print("  fail entry: {s} not found\n", .{entry_path});
        issues += 1;
    }
    if (utils.fs.fileExists(allocator, asset_base_dir)) {
        std.debug.print("  ok asset base: {s}\n", .{asset_base_dir});
    } else {
        std.debug.print("  fail asset base: {s} not found\n", .{asset_base_dir});
        issues += 1;
    }
    return issues;
}

fn doctorTools(allocator: std.mem.Allocator, environ: std.process.Environ) !usize {
    std.debug.print("\nrender tools:\n", .{});
    var issues: usize = 0;
    for (doctor_tools) |tool| {
        const found = try findOnPath(allocator, environ, tool.name);
        if (found) |path| {
            defer allocator.free(path);
            std.debug.print("  ok {s}: {s}\n", .{ tool.name, path });
        } else if (tool.required) {
            std.debug.print("  fail {s}: not found ({s})\n", .{ tool.name, tool.purpose });
            issues += 1;
        } else {
            std.debug.print("  warn {s}: not found ({s})\n", .{ tool.name, tool.purpose });
            issues += 1;
        }
    }
    return issues;
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
    return project.resolve(allocator, io, options.input_path, options.project_path, options.asset_base_dir) catch |err| {
        if (err == error.MissingInputPath) {
            return failUsage("missing input path or --project", .{});
        }
        return err;
    };
}

fn runWatchCommand(
    io: std.Io,
    allocator: std.mem.Allocator,
    mode: watcher.Mode,
    options: CommandOptions,
) !void {
    var resolved = project.resolve(allocator, io, options.input_path, options.project_path, options.asset_base_dir) catch |err| {
        if (project.isConfigError(err)) {
            try waitForWatchProject(io, allocator, mode, options, err);
            return;
        }
        if (err == error.MissingInputPath) return failUsage("missing input path or --project", .{});
        return err;
    };
    defer resolved.deinit(allocator);
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
    std.debug.print("watch: ss.toml is invalid: {s}; waiting every {d}ms\n", .{ @errorName(first_error), interval_ms });
    var last_error = first_error;
    while (true) {
        const sleep_ms: i64 = @intCast(@min(interval_ms, @as(u64, std.math.maxInt(i64))));
        try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(sleep_ms), .awake);

        var resolved = project.resolve(allocator, io, options.input_path, options.project_path, options.asset_base_dir) catch |err| {
            if (watchRecoverableProjectError(options, err)) {
                if (err != last_error) {
                    std.debug.print("watch: still waiting for ss.toml: {s}\n", .{@errorName(err)});
                    last_error = err;
                }
                continue;
            }
            if (err == error.MissingInputPath) return failUsage("missing input path or --project", .{});
            return err;
        };
        defer resolved.deinit(allocator);
        std.debug.print("watch: ss.toml is valid\n", .{});
        try runResolvedWatch(io, allocator, mode, options, &resolved);
        return;
    }
}

fn watchRecoverableProjectError(options: CommandOptions, err: anyerror) bool {
    return project.isConfigError(err) or
        (options.input_path == null and err == error.MissingInputPath) or
        (options.project_path != null and err == error.FileNotFound);
}

fn runResolvedWatch(
    io: std.Io,
    allocator: std.mem.Allocator,
    mode: watcher.Mode,
    options: CommandOptions,
    resolved: *const project.Resolved,
) !void {
    const output_path = if (mode == .render)
        options.output_path orelse try utils.fs.siblingPathWithExtension(allocator, resolved.entry_path, "pdf")
    else
        options.output_path;
    if (output_path) |path| try validateOutputParentOrCliError(io, path);
    try watcher.run(io, allocator, mode, .{
        .input_path = resolved.entry_path,
        .output_path = output_path,
        .asset_base_dir = resolved.asset_base_dir,
        .project_file = resolved.project_file,
        .highlight_languages = resolved.highlight.languages,
        .jobs = options.jobs,
        .cache_id = options.cache_id,
        .interval_ms = options.interval_ms,
    });
}

fn runDebugCommand(
    io: std.Io,
    allocator: std.mem.Allocator,
    args: []const []const u8,
) !void {
    if (args.len == 0) return failUsage("missing debug topic", .{});
    const topic = args[0];
    const options = try parseCommandOptions(args[1..]);
    const output_path = options.output_path orelse return failUsage("missing --output for ss debug {s}", .{topic});
    try validateOutputParentOrCliError(io, output_path);

    var resolved = try resolveProjectOrUsage(allocator, io, options);
    defer resolved.deinit(allocator);

    if (std.mem.eql(u8, topic, "schedule")) {
        var progress = utils.progress.Progress.init(6);
        try app.writeScheduleTraceJsonFileWithAssetBase(io, allocator, resolved.entry_path, resolved.asset_base_dir, output_path, &progress);
        return;
    }

    if (std.mem.eql(u8, topic, "layout-trace")) {
        var progress = utils.progress.Progress.init(6);
        try app.writeLayoutTraceJsonFileWithAssetBase(io, allocator, resolved.entry_path, resolved.asset_base_dir, output_path, &progress);
        return;
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
        else => return err,
    };
}

fn run(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const io = init.io;
    const environ = init.minimal.environ;
    const args = try init.minimal.args.toSlice(allocator);

    if (args.len < 2) {
        usage();
        return;
    }

    const cmd = args[1];
    if (std.mem.eql(u8, cmd, "help")) {
        usage();
        return;
    }
    if (std.mem.eql(u8, cmd, "--version") or std.mem.eql(u8, cmd, "-V") or std.mem.eql(u8, cmd, "version")) {
        version();
        return;
    }

    if (std.mem.eql(u8, cmd, "check")) {
        const options = try parseCommandOptions(args[2..]);
        var resolved = try resolveProjectOrUsage(allocator, io, options);
        defer resolved.deinit(allocator);
        try app.checkFileWithAssetBase(io, allocator, resolved.entry_path, resolved.asset_base_dir);
        return;
    }

    if (std.mem.eql(u8, cmd, "dump")) {
        const options = try parseCommandOptions(args[2..]);
        var resolved = try resolveProjectOrUsage(allocator, io, options);
        defer resolved.deinit(allocator);
        if (options.output_path) |output_path| {
            try validateOutputParentOrCliError(io, output_path);
            var progress = utils.progress.Progress.init(8);
            try app.writeIrJsonFileWithAssetBase(io, allocator, resolved.entry_path, resolved.asset_base_dir, output_path, &progress);
        } else {
            var progress = utils.progress.Progress.init(8);
            try app.printIrJsonForFileWithAssetBase(io, allocator, resolved.entry_path, resolved.asset_base_dir, &progress);
        }
        return;
    }

    if (std.mem.eql(u8, cmd, "render")) {
        const options = try parseCommandOptions(args[2..]);
        var resolved = try resolveProjectOrUsage(allocator, io, options);
        defer resolved.deinit(allocator);
        const output_path = options.output_path orelse try utils.fs.siblingPathWithExtension(allocator, resolved.entry_path, "pdf");
        try validateOutputParentOrCliError(io, output_path);
        if (options.diagnostics_json_path) |diagnostics_json_path| try validateOutputParentOrCliError(io, diagnostics_json_path);
        var progress = utils.progress.Progress.init(8);
        const render_options = app.RenderOptions{
            .jobs = options.jobs,
            .cache_id = options.cache_id,
            .highlight_languages = resolved.highlight.languages,
        };
        try app.writePdfForFileWithAssetBaseAndWriteOptions(io, allocator, resolved.entry_path, resolved.asset_base_dir, output_path, .{
            .render = render_options,
            .diagnostics_json_path = options.diagnostics_json_path,
        }, &progress);
        return;
    }

    if (std.mem.eql(u8, cmd, "init")) {
        const options = try parseInitOptions(args[2..]);
        try initProject(io, allocator, options);
        return;
    }

    if (std.mem.eql(u8, cmd, "doctor")) {
        const options = try parseDoctorOptions(args[2..]);
        try runDoctor(io, allocator, environ, options);
        return;
    }

    if (std.mem.eql(u8, cmd, "debug")) {
        try runDebugCommand(io, allocator, args[2..]);
        return;
    }

    if (std.mem.eql(u8, cmd, "lsp")) {
        try lsp.run(io, std.heap.smp_allocator);
        return;
    }

    if (std.mem.eql(u8, cmd, "watch")) {
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
        try runWatchCommand(io, allocator, mode, options);
        return;
    }

    if (std.mem.eql(u8, cmd, "cache")) {
        if (args.len == 3 and std.mem.eql(u8, args[2], "clear")) {
            utils.render_cache.clear(io, allocator) catch |err| switch (err) {
                error.ActiveRenderCacheLease => return failCli("render cache is currently in use", .{}),
                else => return err,
            };
            std.debug.print("cleared render cache: {s}\n", .{utils.render_cache.path});
            return;
        }
        if (args.len == 3 and std.mem.eql(u8, args[2], "stats")) {
            const stats = try utils.render_cache.stats(io, allocator);
            printCacheStats(stats);
            return;
        }
        if (args.len < 3) return failUsage("missing cache command", .{});
        return failUsage("unknown cache command: {s}", .{args[2]});
    }

    return failUsage("unknown command: {s}", .{cmd});
}

pub fn main(init: std.process.Init) void {
    run(init) catch |err| {
        if (!error_report.isExpectedCliError(err)) std.debug.print("error: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
}
