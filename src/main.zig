const std = @import("std");
const app = @import("app.zig");
const build_options = @import("build_options");
const utils = @import("utils");
const watcher = @import("watch.zig");
const error_report = utils.err;

fn usage() void {
    std.debug.print(
        \\Usage:
        \\ss <command> [arguments] [--asset-base-dir DIR] [--jobs N]
        \\
        \\Commands:
        \\  check [input.ss]
        \\    Parse and type-check; print diagnostics when needed
        \\  dump [input.ss] [output.json]
        \\    Print IR JSON, or write it when output path is given
        \\  render [input.ss] [output.pdf]
        \\    Render PDF to the specified path
        \\  watch check [input.ss]
        \\    Re-run check when the project changes
        \\  watch render [input.ss] [output.pdf]
        \\    Re-render PDF when the project changes
        \\  cache clear
        \\    Clear the managed render cache under .ss-cache/render
        \\
        \\Flags:
        \\  --help, -h
        \\    Show this help message
        \\  --version, -V
        \\    Show the ss version and source commit
        \\  --asset-base-dir DIR
        \\    Resolve relative assets/themes from DIR instead of the input file directory
        \\  --jobs N
        \\    Number of parallel render jobs; render also reads SS_RENDER_JOBS
        \\  --interval-ms N
        \\    Poll interval for watch commands
        \\
        \\Examples:
        \\  ss --help
        \\  ss check slide.ss
        \\  ss dump slide.ss
        \\  ss dump slide.ss out.json
        \\  ss render slide.ss out.pdf
        \\  ss watch check slide.ss
        \\  ss watch render slide.ss out.pdf
        \\  ss cache clear
        \\  zig build run -- check slide.ss
        \\  zig build run -- render slide.ss out.pdf
        \\
    , .{});
}

fn version() void {
    std.debug.print("ss {s} ({s})\n", .{ build_options.version, build_options.commit });
}

const CommandOptions = struct {
    input_path: ?[]const u8 = null,
    output_path: ?[]const u8 = null,
    asset_base_dir: ?[]const u8 = null,
    jobs: ?usize = null,
    interval_ms: u64 = 500,
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
            1 => options.output_path = arg,
            else => return error.TooManyArguments,
        }
        positional_index += 1;
    }
    return options;
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
        const input_path = options.input_path orelse "demo/01-language-tour.ss";
        if (options.asset_base_dir) |asset_base_dir| {
            try app.checkFileWithAssetBase(io, allocator, input_path, asset_base_dir);
        } else {
            try app.checkFile(io, allocator, input_path);
        }
        return;
    }

    if (std.mem.eql(u8, cmd, "dump")) {
        const options = try parseCommandOptions(args[2..]);
        const input_path = options.input_path orelse "demo/01-language-tour.ss";
        if (options.output_path) |output_path| {
            var progress = app.Progress.init(7);
            if (options.asset_base_dir) |asset_base_dir| {
                try app.writeIrJsonFileWithAssetBase(io, allocator, input_path, asset_base_dir, output_path, &progress);
            } else {
                try app.writeIrJsonFile(io, allocator, input_path, output_path, &progress);
            }
        } else {
            var progress = app.Progress.init(7);
            if (options.asset_base_dir) |asset_base_dir| {
                try app.printIrJsonForFileWithAssetBase(io, allocator, input_path, asset_base_dir, &progress);
            } else {
                try app.printIrJsonForFile(io, allocator, input_path, &progress);
            }
        }
        return;
    }

    if (std.mem.eql(u8, cmd, "render")) {
        const options = try parseCommandOptions(args[2..]);
        const input_path = options.input_path orelse "demo/01-language-tour.ss";
        const output_path = options.output_path orelse try utils.fs.siblingPathWithExtension(allocator, input_path, "pdf");
        var progress = app.Progress.init(7);
        const render_options = app.RenderOptions{ .jobs = options.jobs };
        if (options.asset_base_dir) |asset_base_dir| {
            try app.writePdfForFileWithAssetBaseAndOptions(io, allocator, input_path, asset_base_dir, output_path, render_options, &progress);
        } else {
            try app.writePdfForFileWithOptions(io, allocator, input_path, output_path, render_options, &progress);
        }
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
