const std = @import("std");
const app = @import("app.zig");
const utils = @import("utils");
const error_report = utils.err;

fn usage() void {
    std.debug.print(
        \\Usage:
        \\ss <command> [arguments] [--asset-base-dir DIR]
        \\
        \\Commands:
        \\  check [input.ss]
        \\    Parse and type-check; print diagnostics when needed
        \\  dump [input.ss] [output.json]
        \\    Print IR JSON, or write it when output path is given
        \\  render [input.ss] [output.pdf]
        \\    Render PDF to the specified path
        \\
        \\Flags:
        \\  --help, -h
        \\    Show this help message
        \\  --asset-base-dir DIR
        \\    Resolve relative assets/themes from DIR instead of the input file directory
        \\
        \\Examples:
        \\  ss --help
        \\  ss check demo/ss.ss
        \\  ss dump demo/ss.ss
        \\  ss dump demo/ss.ss out.json
        \\  ss render demo/ss.ss out.pdf
        \\  zig build run -- check demo/ss.ss
        \\  zig build run -- render demo/ss.ss out.pdf
        \\
    , .{});
}

const CommandOptions = struct {
    input_path: ?[]const u8 = null,
    output_path: ?[]const u8 = null,
    asset_base_dir: ?[]const u8 = null,
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

    if (std.mem.eql(u8, cmd, "check")) {
        const options = try parseCommandOptions(args[2..]);
        const input_path = options.input_path orelse "demo/ss.ss";
        if (options.asset_base_dir) |asset_base_dir| {
            try app.checkFileWithAssetBase(io, allocator, input_path, asset_base_dir);
        } else {
            try app.checkFile(io, allocator, input_path);
        }
        return;
    }

    if (std.mem.eql(u8, cmd, "dump")) {
        const options = try parseCommandOptions(args[2..]);
        const input_path = options.input_path orelse "demo/ss.ss";
        if (options.output_path) |output_path| {
            var progress = app.Progress.init(7);
            if (options.asset_base_dir) |asset_base_dir| {
                try app.writeIrJsonFileWithAssetBase(io, allocator, input_path, asset_base_dir, output_path, &progress);
            } else {
                try app.writeIrJsonFile(io, allocator, input_path, output_path, &progress);
            }
        } else {
            var progress = app.Progress.init(6);
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
        const input_path = options.input_path orelse "demo/ss.ss";
        const output_path = options.output_path orelse try utils.fs.siblingPathWithExtension(allocator, input_path, "pdf");
        var progress = app.Progress.init(8);
        if (options.asset_base_dir) |asset_base_dir| {
            try app.writePdfForFileWithAssetBase(io, allocator, input_path, asset_base_dir, output_path, &progress);
        } else {
            try app.writePdfForFile(io, allocator, input_path, output_path, &progress);
        }
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
