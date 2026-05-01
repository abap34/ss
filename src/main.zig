const std = @import("std");
const app = @import("app.zig");
const utils = @import("utils");

fn usage() void {
    std.debug.print(
        \\Usage:
        \\ss <command> [arguments]
        \\
        \\Commands:
        \\  check-file [input.ss]
        \\    Parse and type-check; print diagnostics when needed
        \\  editor-info-file [input.ss]
        \\    Print editor support info (hints/functions/variables metadata) as JSON
        \\  dump-file [input.ss]
        \\    Print engine dump as human-readable text
        \\  dump-json-file [input.ss] [output-path]
        \\    Write engine info to a JSON file
        \\  render-pdf-file [input.ss] [output-path]
        \\    Render PDF to the specified path
        \\
        \\Flags:
        \\  --help, -h
        \\    Show this help message
        \\
        \\Examples:
        \\  ss --help
        \\  ss check-file demo/ss.ss
        \\  ss editor-info-file demo/ss.ss
        \\  ss dump-file demo/ss.ss
        \\  ss dump-json-file demo/ss.ss
        \\  ss render-pdf-file demo/ss.ss out.pdf
        \\  zig build run -- check-file demo/ss.ss
        \\  zig build run -- editor-info-file demo/ss.ss
        \\  zig build run -- render-pdf-file demo/ss.ss out.pdf
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

    if (std.mem.eql(u8, cmd, "check-file")) {
        const input_path = if (args.len >= 3) args[2] else "demo/ss.ss";
        try app.checkFile(io, allocator, input_path);
        return;
    }

    if (std.mem.eql(u8, cmd, "editor-info-file")) {
        const input_path = if (args.len >= 3) args[2] else "demo/ss.ss";
        try app.writeEditorInfoFile(io, allocator, input_path);
        return;
    }

    if (std.mem.eql(u8, cmd, "dump-file")) {
        const input_path = if (args.len >= 3) args[2] else "demo/ss.ss";
        var progress = app.Progress.init(4);
        try app.printEngineDumpForFile(io, allocator, input_path, &progress);
        return;
    }

    if (std.mem.eql(u8, cmd, "dump-json-file")) {
        const input_path = if (args.len >= 3) args[2] else "demo/ss.ss";
        const output_path = if (args.len >= 4) args[3] else try utils.fs.siblingPathWithExtension(allocator, input_path, "json");
        var progress = app.Progress.init(6);
        try app.writeEngineJsonFile(io, allocator, input_path, output_path, &progress);
        return;
    }

    if (std.mem.eql(u8, cmd, "render-pdf-file")) {
        const input_path = if (args.len >= 3) args[2] else "demo/ss.ss";
        const output_path = if (args.len >= 4) args[3] else try utils.fs.siblingPathWithExtension(allocator, input_path, "pdf");
        var progress = app.Progress.init(7);
        try app.writeEnginePdfFile(io, allocator, input_path, output_path, &progress);
        return;
    }

    usage();
}

pub fn main(init: std.process.Init) void {
    run(init) catch |err| {
        switch (err) {
            error.UnknownFunction,
            error.UnknownQuery,
            error.UnknownTransform,
            error.UnknownIdentifier,
            error.ExpectedString,
            error.ExpectedIdentifier,
            error.ExpectedKeyword,
            error.ExpectedChar,
            error.ExpectedLineBreak,
            error.ExpectedEnd,
            error.ExpectedNumber,
            error.ExpectedTypeAnnotation,
            error.ExpectedReturn,
            error.UnterminatedString,
            error.UnterminatedEscape,
            error.InvalidEscape,
            error.UnknownAnchor,
            error.ReturnOutsideFunction,
            error.InvalidThemeModule,
            error.FunctionDoesNotReturnValue,
            error.InvalidArity,
            error.InvalidSemanticSort,
            error.RecursiveFunction,
            error.ExpectedSelection,
            error.ExpectedConstraintSet,
            error.ExpectedStringArgument,
            error.ExpectedNumberArgument,
            error.ExpectedStyleArgument,
            error.ExpectedAnchor,
            error.ExpectedObject,
            error.UnknownRole,
            error.UnknownPayloadKind,
            error.PageCannotBeConstraintTarget,
            error.MissingHighlightTarget,
            error.UnsupportedFragmentRoot,
            error.FunctionDidNotReturnValue,
            error.ConstraintConflict,
            error.NegativeConstraintSize,
            error.DiagnosticsFailed,
            => {},
            else => std.debug.print("error: {s}\n", .{@errorName(err)}),
        }
        std.process.exit(1);
    };
}
