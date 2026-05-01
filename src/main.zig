const std = @import("std");
const app = @import("app.zig");
const utils = @import("utils");
const error_report = utils.err;

fn usage() void {
    std.debug.print(
        \\Usage:
        \\ss <command> [arguments]
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
        const input_path = if (args.len >= 3) args[2] else "demo/ss.ss";
        try app.checkFile(io, allocator, input_path);
        return;
    }

    if (std.mem.eql(u8, cmd, "dump")) {
        const input_path = if (args.len >= 3) args[2] else "demo/ss.ss";
        if (args.len >= 4) {
            const output_path = args[3];
            var progress = app.Progress.init(7);
            try app.writeIrJsonFile(io, allocator, input_path, output_path, &progress);
        } else {
            var progress = app.Progress.init(6);
            try app.printIrJsonForFile(io, allocator, input_path, &progress);
        }
        return;
    }

    if (std.mem.eql(u8, cmd, "render")) {
        const input_path = if (args.len >= 3) args[2] else "demo/ss.ss";
        const output_path = if (args.len >= 4) args[3] else try utils.fs.siblingPathWithExtension(allocator, input_path, "pdf");
        var progress = app.Progress.init(8);
        try app.writePdfForFile(io, allocator, input_path, output_path, &progress);
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
