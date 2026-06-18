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
        \\  ss <command> [arguments]
        \\  ss help [command]
        \\
        \\Commands:
        \\  check [input.ss]                       Parse and type-check
        \\  dump [input.ss] [output.json]          Write IR JSON
        \\  render [input.ss] [output]             Render PDF or HTML
        \\  init [dir]                             Create ss.toml and starter slides
        \\  doctor                                 Check project and render tools
        \\  lsp                                    Run the language server over stdio
        \\  watch check [input.ss]                 Re-run check when files change
        \\  watch render [input.ss] [output]       Re-render PDF or HTML when files change
        \\  cache stats                            Show render cache size
        \\  cache clear                            Clear the managed render cache
        \\
        \\Global:
        \\  --version, -V                          Show the ss version and source commit
        \\
        \\Project flags:
        \\  --project FILE_OR_DIR                  Resolve entrypoint and asset base from ss.toml
        \\  --asset-base-dir DIR                   Resolve relative assets from DIR
        \\
        \\Render flags:
        \\  --format pdf|html                      Select render output format
        \\  --output FILE                          Write output to FILE
        \\  --cache-id ID                          Stable PDF page cache identity
        \\
        \\Other flags:
        \\  --interval-ms N                        Poll interval for watch commands
        \\  --entry FILE                           Entry file for ss init
        \\  --force                                Allow ss init to overwrite generated files
        \\  --strict                               Make ss doctor fail when it finds issues
        \\
        \\Examples:
        \\  ss help
        \\  ss help render
        \\  ss check slide.ss
        \\  ss dump slide.ss
        \\  ss dump slide.ss out.json
        \\  ss dump --project . --output .ss-cache/dump.json
        \\  ss render slide.ss slide.pdf
        \\  ss render slide.ss slide.html
        \\  ss render slide.ss --format html
        \\  ss render --project . --output slide.pdf
        \\  ss render --project . --format html --output slide.html
        \\  ss init slides
        \\  ss doctor --project slides
        \\  ss watch check slide.ss
        \\  ss watch render slide.ss slide.pdf
        \\  ss cache clear
        \\  ss cache stats
        \\  zig build run -- check slide.ss
        \\  zig build run -- render slide.ss slide.pdf
        \\
    , .{});
}

fn usageFor(command: []const u8) !void {
    if (std.mem.eql(u8, command, "check")) {
        std.debug.print(
            \\Usage:
            \\  ss check [input.ss] [--project FILE_OR_DIR] [--asset-base-dir DIR]
            \\
            \\Parse, load modules, type-check, evaluate, and solve layout.
            \\
        , .{});
        return;
    }
    if (std.mem.eql(u8, command, "dump")) {
        std.debug.print(
            \\Usage:
            \\  ss dump [input.ss] [output.json]
            \\  ss dump [input.ss] --output output.json
            \\
            \\Write compiler IR JSON for tooling and debugging.
            \\
        , .{});
        return;
    }
    if (std.mem.eql(u8, command, "render")) {
        std.debug.print(
            \\Usage:
            \\  ss render [input.ss] [output]
            \\  ss render [input.ss] --output output --format pdf|html
            \\
            \\Render a deck as PDF or static HTML. Without --format, .html and .htm outputs select HTML;
            \\other outputs select PDF. Without an output path, ss writes input.pdf or input.html.
            \\
            \\Examples:
            \\  ss render slide.ss slide.pdf
            \\  ss render slide.ss slide.html
            \\  ss render slide.ss --format html
            \\  ss render --project . --output slide.pdf
            \\  ss render --project . --format html --output slide.html
            \\
        , .{});
        return;
    }
    if (std.mem.eql(u8, command, "watch")) {
        std.debug.print(
            \\Usage:
            \\  ss watch check [input.ss] [--interval-ms N]
            \\  ss watch render [input.ss] [output] [--format pdf|html] [--interval-ms N]
            \\
            \\Poll project inputs and rerun check or render after changes.
            \\
        , .{});
        return;
    }
    if (std.mem.eql(u8, command, "init")) {
        std.debug.print(
            \\Usage:
            \\  ss init [dir] [--entry FILE] [--force]
            \\
            \\Create an ss.toml and a starter slide deck.
            \\
        , .{});
        return;
    }
    if (std.mem.eql(u8, command, "doctor")) {
        std.debug.print(
            \\Usage:
            \\  ss doctor [input.ss] [--project FILE_OR_DIR] [--asset-base-dir DIR] [--strict]
            \\
            \\Check project discovery and external render tools.
            \\
        , .{});
        return;
    }
    if (std.mem.eql(u8, command, "cache")) {
        std.debug.print(
            \\Usage:
            \\  ss cache stats
            \\  ss cache clear
            \\
            \\Inspect or clear the managed render cache under .ss-cache/render.
            \\
        , .{});
        return;
    }
    if (std.mem.eql(u8, command, "lsp")) {
        std.debug.print(
            \\Usage:
            \\  ss lsp
            \\
            \\Run the ss language server over stdio.
            \\
        , .{});
        return;
    }
    return failUsage("unknown help topic: {s}", .{command});
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
    cache_id: ?[]const u8 = null,
    render_format: ?app.RenderFormat = null,
    interval_ms: u64 = 500,
};

const CommandMode = enum {
    check,
    dump,
    render,
    watch_check,
    watch_render,

    fn allowsOutput(self: CommandMode) bool {
        return switch (self) {
            .dump, .render, .watch_render => true,
            .check, .watch_check => false,
        };
    }

    fn allowsRenderFormat(self: CommandMode) bool {
        return switch (self) {
            .render, .watch_render => true,
            .check, .dump, .watch_check => false,
        };
    }

    fn allowsCacheId(self: CommandMode) bool {
        return switch (self) {
            .render, .watch_render => true,
            .check, .dump, .watch_check => false,
        };
    }

    fn allowsInterval(self: CommandMode) bool {
        return switch (self) {
            .watch_check, .watch_render => true,
            .check, .dump, .render => false,
        };
    }
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

fn parseCommandOptions(args: []const []const u8, mode: CommandMode) !CommandOptions {
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
            if (!mode.allowsOutput()) return failUsage("--output is not valid for this command", .{});
            if (i + 1 >= args.len) return failUsage("missing value for --output", .{});
            if (options.output_path != null) return failUsage("output path specified more than once", .{});
            options.output_path = args[i + 1];
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--cache-id")) {
            if (!mode.allowsCacheId()) return failUsage("--cache-id is only valid for render commands", .{});
            if (i + 1 >= args.len) return failUsage("missing value for --cache-id", .{});
            options.cache_id = args[i + 1];
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--format")) {
            if (!mode.allowsRenderFormat()) return failUsage("--format is only valid for render commands", .{});
            if (i + 1 >= args.len) return failUsage("missing value for --format", .{});
            if (options.render_format != null) return failUsage("render format specified more than once", .{});
            options.render_format = try parseRenderFormat(args[i + 1]);
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--interval-ms")) {
            if (!mode.allowsInterval()) return failUsage("--interval-ms is only valid for watch commands", .{});
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
                if (!mode.allowsOutput()) return failUsage("too many arguments: {s}", .{arg});
                if (options.output_path != null) return failUsage("output path specified more than once", .{});
                options.output_path = arg;
            },
            else => return failUsage("too many arguments: {s}", .{arg}),
        }
        positional_index += 1;
    }
    return options;
}

fn parseRenderFormat(value: []const u8) !app.RenderFormat {
    if (std.mem.eql(u8, value, "pdf")) return .pdf;
    if (std.mem.eql(u8, value, "html")) return .html;
    return failUsage("unknown render format: {s}", .{value});
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
    \\- Run `ss render --project . --output slide.pdf`.
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
    std.debug.print("\nnext:\n  ss render --project {s} --output slide.pdf\n", .{options.dir});
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
    const render_format = resolveRenderFormat(options);
    try validateRenderOptionCombination(render_format, options);
    const output_path = if (mode == .render)
        options.output_path orelse try utils.fs.siblingPathWithExtension(allocator, resolved.entry_path, renderExtension(render_format))
    else
        options.output_path;
    if (output_path) |path| try validateOutputParentOrCliError(io, path);
    try watcher.run(io, allocator, mode, .{
        .input_path = resolved.entry_path,
        .output_path = output_path,
        .asset_base_dir = resolved.asset_base_dir,
        .project_file = resolved.project_file,
        .cache_id = options.cache_id,
        .render_format = render_format,
        .highlight_languages = resolved.highlight.languages,
        .interval_ms = options.interval_ms,
    });
}

fn resolveRenderFormat(options: CommandOptions) app.RenderFormat {
    if (options.render_format) |format| return format;
    if (options.output_path) |output_path| {
        const ext = std.fs.path.extension(output_path);
        if (std.ascii.eqlIgnoreCase(ext, ".html") or std.ascii.eqlIgnoreCase(ext, ".htm")) return .html;
    }
    return .pdf;
}

fn validateRenderOptionCombination(format: app.RenderFormat, options: CommandOptions) !void {
    if (format == .html and options.cache_id != null) {
        return failUsage("--cache-id is only valid for PDF render output", .{});
    }
}

fn renderExtension(format: app.RenderFormat) []const u8 {
    return switch (format) {
        .pdf => "pdf",
        .html => "html",
    };
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
        if (args.len >= 3) {
            try usageFor(args[2]);
            return;
        }
        usage();
        return;
    }
    if (std.mem.eql(u8, cmd, "--version") or std.mem.eql(u8, cmd, "-V")) {
        version();
        return;
    }

    if (std.mem.eql(u8, cmd, "check")) {
        if (args.len >= 3 and std.mem.eql(u8, args[2], "--help")) {
            try usageFor("check");
            return;
        }
        const options = try parseCommandOptions(args[2..], .check);
        var resolved = try resolveProjectOrUsage(allocator, io, options);
        defer resolved.deinit(allocator);
        try app.checkFileWithAssetBase(io, allocator, resolved.entry_path, resolved.asset_base_dir);
        return;
    }

    if (std.mem.eql(u8, cmd, "dump")) {
        if (args.len >= 3 and std.mem.eql(u8, args[2], "--help")) {
            try usageFor("dump");
            return;
        }
        const options = try parseCommandOptions(args[2..], .dump);
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
        if (args.len >= 3 and std.mem.eql(u8, args[2], "--help")) {
            try usageFor("render");
            return;
        }
        const options = try parseCommandOptions(args[2..], .render);
        var resolved = try resolveProjectOrUsage(allocator, io, options);
        defer resolved.deinit(allocator);
        const render_format = resolveRenderFormat(options);
        try validateRenderOptionCombination(render_format, options);
        const output_path = options.output_path orelse try utils.fs.siblingPathWithExtension(allocator, resolved.entry_path, renderExtension(render_format));
        try validateOutputParentOrCliError(io, output_path);
        var progress = utils.progress.Progress.init(8);
        const render_options = app.RenderOptions{
            .format = render_format,
            .cache_id = options.cache_id,
            .highlight_languages = resolved.highlight.languages,
        };
        try app.writeRenderFileWithAssetBaseAndOptions(io, allocator, resolved.entry_path, resolved.asset_base_dir, output_path, render_options, &progress);
        return;
    }

    if (std.mem.eql(u8, cmd, "init")) {
        if (args.len >= 3 and std.mem.eql(u8, args[2], "--help")) {
            try usageFor("init");
            return;
        }
        const options = try parseInitOptions(args[2..]);
        try initProject(io, allocator, options);
        return;
    }

    if (std.mem.eql(u8, cmd, "doctor")) {
        if (args.len >= 3 and std.mem.eql(u8, args[2], "--help")) {
            try usageFor("doctor");
            return;
        }
        const options = try parseDoctorOptions(args[2..]);
        try runDoctor(io, allocator, environ, options);
        return;
    }

    if (std.mem.eql(u8, cmd, "lsp")) {
        if (args.len >= 3 and std.mem.eql(u8, args[2], "--help")) {
            try usageFor("lsp");
            return;
        }
        try lsp.run(io, std.heap.smp_allocator);
        return;
    }

    if (std.mem.eql(u8, cmd, "watch")) {
        if (args.len >= 3 and std.mem.eql(u8, args[2], "--help")) {
            try usageFor("watch");
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
        const options = try parseCommandOptions(args[3..], if (mode == .render) .watch_render else .watch_check);
        try runWatchCommand(io, allocator, mode, options);
        return;
    }

    if (std.mem.eql(u8, cmd, "cache")) {
        if (args.len >= 3 and std.mem.eql(u8, args[2], "--help")) {
            try usageFor("cache");
            return;
        }
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
