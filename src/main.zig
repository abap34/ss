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
        \\ss <command> [arguments] [--asset-base-dir DIR] [--project FILE_OR_DIR] [--output FILE] [--jobs N]
        \\
        \\Commands:
        \\  check [input.ss]
        \\    Parse and type-check; print diagnostics when needed
        \\  dump [input.ss] [output.json]
        \\    Print IR JSON, or write it when output path is given
        \\  render [input.ss] [output.pdf]
        \\    Render PDF to the specified path
        \\  init [dir]
        \\    Create a new ss.toml and starter slide deck
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
        \\  --help, -h
        \\    Show this help message
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
        \\  --interval-ms N
        \\    Poll interval for watch commands
        \\  --entry FILE
        \\    Entry file to create with ss init
        \\  --force
        \\    Allow ss init to overwrite generated files
        \\
        \\Examples:
        \\  ss --help
        \\  ss check slide.ss
        \\  ss dump slide.ss
        \\  ss dump slide.ss out.json
        \\  ss dump --project . --output .ss-cache/dump.json
        \\  ss render slide.ss out.pdf
        \\  ss render --project . --output .ss-cache/render.pdf
        \\  ss init slides
        \\  ss watch check slide.ss
        \\  ss watch render slide.ss out.pdf
        \\  ss cache clear
        \\  ss cache stats
        \\  zig build run -- check slide.ss
        \\  zig build run -- render slide.ss out.pdf
        \\
    , .{});
}

fn version() void {
    std.debug.print("ss {s} ({s})\n", .{ build_options.version, build_options.commit });
}

fn printCacheStats(stats: app.CacheStats) void {
    std.debug.print("render cache: {s}\n", .{app.render_cache_path});
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
    interval_ms: u64 = 500,
};

const InitOptions = struct {
    dir: []const u8 = ".",
    entry: []const u8 = "slide.ss",
    force: bool = false,
};

fn parseCommandOptions(args: []const []const u8) !CommandOptions {
    var options = CommandOptions{};
    var positional_index: usize = 0;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--asset-base-dir")) {
            if (i + 1 >= args.len) return error.MissingAssetBaseDirValue;
            options.asset_base_dir = args[i + 1];
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--project")) {
            if (i + 1 >= args.len) return error.MissingProjectValue;
            options.project_path = args[i + 1];
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--output")) {
            if (i + 1 >= args.len) return error.MissingOutputValue;
            if (options.output_path != null) return error.DuplicateOutputPath;
            options.output_path = args[i + 1];
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--jobs")) {
            if (i + 1 >= args.len) return error.MissingJobsValue;
            options.jobs = try std.fmt.parseUnsigned(usize, args[i + 1], 10);
            if (options.jobs.? == 0) return error.InvalidJobsValue;
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--interval-ms")) {
            if (i + 1 >= args.len) return error.MissingIntervalValue;
            options.interval_ms = try std.fmt.parseUnsigned(u64, args[i + 1], 10);
            if (options.interval_ms == 0) return error.InvalidIntervalValue;
            i += 1;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--")) return error.UnknownFlag;
        switch (positional_index) {
            0 => options.input_path = arg,
            1 => {
                if (options.output_path != null) return error.DuplicateOutputPath;
                options.output_path = arg;
            },
            else => return error.TooManyArguments,
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
            if (i + 1 >= args.len) return error.MissingEntryValue;
            options.entry = args[i + 1];
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--force")) {
            options.force = true;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--")) return error.UnknownFlag;
        if (saw_dir) return error.TooManyArguments;
        options.dir = arg;
        saw_dir = true;
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
    \\import std:themes/default
    \\
    \\page title
    \\title_page(
    \\  "Hello, ss",
    \\  "Write slides as programs.",
    \\  "ss init"
    \\)
    \\end
    \\
    \\page body
    \\let title = slide_title "First slide"
    \\let body = text <<
    \\- Edit slide.ss.
    \\- Run `ss render --project . --output deck.pdf`.
    \\>>
    \\
    \\body.top == title.bottom - 32
    \\page_no()
    \\end
    \\
    ;
}

fn initProject(io: std.Io, allocator: std.mem.Allocator, options: InitOptions) !void {
    if (std.fs.path.isAbsolute(options.entry)) {
        std.debug.print("init: --entry must be relative to the project directory\n", .{});
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

fn run(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(allocator);

    if (args.len < 2) {
        usage();
        return;
    }

    const cmd = args[1];
    if (std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h") or std.mem.eql(u8, cmd, "help")) {
        usage();
        return;
    }
    if (std.mem.eql(u8, cmd, "--version") or std.mem.eql(u8, cmd, "-V") or std.mem.eql(u8, cmd, "version")) {
        version();
        return;
    }

    if (std.mem.eql(u8, cmd, "check")) {
        const options = try parseCommandOptions(args[2..]);
        var resolved = try project.resolve(allocator, io, options.input_path, options.project_path, options.asset_base_dir);
        defer resolved.deinit(allocator);
        try app.checkFileWithAssetBase(io, allocator, resolved.entry_path, resolved.asset_base_dir);
        return;
    }

    if (std.mem.eql(u8, cmd, "dump")) {
        const options = try parseCommandOptions(args[2..]);
        var resolved = try project.resolve(allocator, io, options.input_path, options.project_path, options.asset_base_dir);
        defer resolved.deinit(allocator);
        if (options.output_path) |output_path| {
            var progress = app.Progress.init(7);
            try app.writeIrJsonFileWithAssetBase(io, allocator, resolved.entry_path, resolved.asset_base_dir, output_path, &progress);
        } else {
            var progress = app.Progress.init(7);
            try app.printIrJsonForFileWithAssetBase(io, allocator, resolved.entry_path, resolved.asset_base_dir, &progress);
        }
        return;
    }

    if (std.mem.eql(u8, cmd, "render")) {
        const options = try parseCommandOptions(args[2..]);
        var resolved = try project.resolve(allocator, io, options.input_path, options.project_path, options.asset_base_dir);
        defer resolved.deinit(allocator);
        const output_path = options.output_path orelse try utils.fs.siblingPathWithExtension(allocator, resolved.entry_path, "pdf");
        var progress = app.Progress.init(7);
        const render_options = app.RenderOptions{ .jobs = options.jobs };
        try app.writePdfForFileWithAssetBaseAndOptions(io, allocator, resolved.entry_path, resolved.asset_base_dir, output_path, render_options, &progress);
        return;
    }

    if (std.mem.eql(u8, cmd, "init")) {
        const options = try parseInitOptions(args[2..]);
        try initProject(io, allocator, options);
        return;
    }

    if (std.mem.eql(u8, cmd, "lsp")) {
        try lsp.run(io, allocator);
        return;
    }

    if (std.mem.eql(u8, cmd, "watch")) {
        if (args.len < 3) {
            usage();
            return;
        }
        const mode: watcher.Mode = if (std.mem.eql(u8, args[2], "check"))
            .check
        else if (std.mem.eql(u8, args[2], "render"))
            .render
        else {
            usage();
            return;
        };
        const options = try parseCommandOptions(args[3..]);
        const input_path = options.input_path orelse "demo/01-language-tour.ss";
        const asset_base_dir = options.asset_base_dir orelse std.fs.path.dirname(input_path) orelse ".";
        const output_path = if (mode == .render)
            options.output_path orelse try utils.fs.siblingPathWithExtension(allocator, input_path, "pdf")
        else
            options.output_path;
        try watcher.run(io, allocator, mode, .{
            .input_path = input_path,
            .output_path = output_path,
            .asset_base_dir = asset_base_dir,
            .jobs = options.jobs,
            .interval_ms = options.interval_ms,
        });
        return;
    }

    if (std.mem.eql(u8, cmd, "cache")) {
        if (args.len == 3 and std.mem.eql(u8, args[2], "clear")) {
            try app.clearRenderCache(io);
            std.debug.print("cleared render cache: {s}\n", .{app.render_cache_path});
            return;
        }
        if (args.len == 3 and std.mem.eql(u8, args[2], "stats")) {
            const stats = try app.renderCacheStats(io, allocator);
            printCacheStats(stats);
            return;
        }
        usage();
        return;
    }

    usage();
}

pub fn main(init: std.process.Init) void {
    run(init) catch |err| {
        if (!error_report.isExpectedCliError(err)) std.debug.print("error: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
}
