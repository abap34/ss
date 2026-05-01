const std = @import("std");
const core = @import("core");
const parser = @import("parser.zig");
const pdf = @import("render/pdf.zig");
const editor_info = @import("editor_info.zig");
const error_report = @import("utils").err;

const Progress = struct {
    total: usize,
    current: usize = 0,
    started_at_ns: i128,
    last_step_at_ns: i128,

    fn init(total: usize) Progress {
        const now = monotonicNowNs();
        return .{
            .total = total,
            .started_at_ns = now,
            .last_step_at_ns = now,
        };
    }

    fn step(self: *Progress, label: []const u8) void {
        const now = monotonicNowNs();
        const stage_elapsed_ns = now - self.last_step_at_ns;
        const total_elapsed_ns = now - self.started_at_ns;
        self.current += 1;
        self.last_step_at_ns = now;
        printProgress(
            self.current,
            self.total,
            label,
            @intCast(@divTrunc(stage_elapsed_ns, std.time.ns_per_ms)),
            @intCast(@divTrunc(total_elapsed_ns, std.time.ns_per_ms)),
        );
    }
};

fn monotonicNowNs() i128 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    return @as(i128, ts.sec) * std.time.ns_per_s + @as(i128, ts.nsec);
}

fn printProgress(current: usize, total: usize, label: []const u8, stage_elapsed_ms: i64, total_elapsed_ms: i64) void {
    const width: usize = 18;
    const filled = if (total == 0) width else @min(width, (current * width) / total);
    var stage_buf: [32]u8 = undefined;
    var total_buf: [32]u8 = undefined;
    const stage_text = formatDurationMsText(stage_elapsed_ms, &stage_buf) catch "<?>";
    const total_text = formatDurationMsText(total_elapsed_ms, &total_buf) catch "<?>";
    std.debug.print("[", .{});
    var i: usize = 0;
    while (i < width) : (i += 1) {
        if (i < filled) {
            if (i + 1 == filled and filled < width) {
                std.debug.print(">", .{});
            } else {
                std.debug.print("=", .{});
            }
        } else {
            std.debug.print(" ", .{});
        }
    }
    std.debug.print("] {d}/{d} {s:<19}  ({s:>8}, total {s:>8})\n", .{
        current,
        total,
        label,
        stage_text,
        total_text,
    });
}

fn formatDurationMsText(value: i64, buf: []u8) ![]const u8 {
    if (value < 1000) {
        return std.fmt.bufPrint(buf, "{d}ms", .{value});
    }

    const seconds = @as(f64, @floatFromInt(value)) / 1000.0;
    if (seconds < 10.0) {
        return std.fmt.bufPrint(buf, "{d:.2}s", .{seconds});
    } else if (seconds < 100.0) {
        return std.fmt.bufPrint(buf, "{d:.1}s", .{seconds});
    } else {
        return std.fmt.bufPrint(buf, "{d:.0}s", .{seconds});
    }
}

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

fn readFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited);
}

fn parseSource(allocator: std.mem.Allocator, source: []const u8, path: []const u8) !parser.Program {
    return parser.parse(allocator, source) catch |err| {
        printParseError(path, source, err);
        return err;
    };
}

fn buildFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8, progress: ?*Progress) !core.Engine {
    if (progress) |p| p.step("Read source");
    const source = try readFile(io, allocator, path);
    defer allocator.free(source);
    if (progress) |p| p.step("Parse");
    var program = try parseSource(allocator, source, path);
    defer program.deinit(allocator);

    if (progress) |p| p.step("Lower program");
    var engine = try core.Engine.init(allocator);
    errdefer engine.deinit();
    engine.asset_base_dir = try allocator.dupe(u8, std.fs.path.dirname(path) orelse ".");
    parser.lowerToEngineWithPath(program, source, path, &engine, io) catch |err| {
        switch (err) {
            error.ConstraintConflict, error.NegativeConstraintSize => printConstraintFailure(path, source, &engine, err),
            else => printEngineDiagnostics(path, source, &engine),
        }
        return err;
    };
    printEngineDiagnostics(path, source, &engine);
    if (hasErrorDiagnostics(&engine)) return error.DiagnosticsFailed;
    if (progress) |p| p.step("Solve constraints");
    return engine;
}

fn printParseError(path: []const u8, source: []const u8, err: anyerror) void {
    const diagnostic = parser.lastParseDiagnostic() orelse {
        var message_buf: [128]u8 = undefined;
        error_report.print(.{
            .path = path,
            .source = source,
            .severity = .@"error",
            .message = std.fmt.bufPrint(&message_buf, "{s}: {s}", .{ @errorName(err), @errorName(err) }) catch @errorName(err),
            .span = null,
        });
        return;
    };
    var message_buf: [256]u8 = undefined;
    const message = formatParseDiagnostic(&message_buf, diagnostic);
    error_report.print(.{
        .path = path,
        .source = source,
        .severity = .@"error",
        .message = message,
        .span = .{ .start = diagnostic.span.start, .end = diagnostic.span.end },
    });
}

fn formatParseDiagnostic(buf: []u8, diagnostic: parser.ParseDiagnostic) []const u8 {
    return switch (diagnostic.err) {
        error.UnterminatedString => "UnterminatedString: unterminated string",
        error.UnterminatedEscape => "UnterminatedEscape: unterminated escape sequence",
        error.InvalidEscape => "InvalidEscape: invalid escape sequence",
        error.UnknownAnchor => "UnknownAnchor: unknown anchor name",
        else => blk: {
            const expected = diagnostic.expected orelse @errorName(diagnostic.err);
            const found = diagnostic.found orelse "unknown token";
            break :blk std.fmt.bufPrint(buf, "{s}: expected {s}, found {s}", .{ parseDiagnosticCode(diagnostic.err), expected, found }) catch @errorName(diagnostic.err);
        },
    };
}

fn parseDiagnosticCode(err: anyerror) []const u8 {
    return switch (err) {
        error.ExpectedString => "ExpectedString",
        error.ExpectedIdentifier => "ExpectedIdentifier",
        error.ExpectedKeyword => "ExpectedKeyword",
        error.ExpectedChar => "ExpectedPunctuation",
        error.ExpectedLineBreak => "ExpectedLineBreak",
        error.ExpectedEnd => "ExpectedEnd",
        error.ExpectedNumber => "ExpectedNumber",
        error.ExpectedTypeAnnotation => "ExpectedTypeAnnotation",
        error.ExpectedReturn => "ExpectedReturn",
        error.InvalidSemanticSort => "InvalidSemanticSort",
        else => @errorName(err),
    };
}

fn printEngineDiagnostics(path: []const u8, source: []const u8, engine: *core.Engine) void {
    for (engine.diagnostics.items) |diagnostic| {
        const message = formatEngineDiagnostic(engine.allocator, diagnostic) catch @tagName(diagnostic.phase);
        defer if (!std.mem.eql(u8, message, @tagName(diagnostic.phase))) engine.allocator.free(message);
        const span = if (error_report.spanFromOrigin(diagnostic.origin)) |origin_span|
            origin_span
        else if (diagnostic.node_id) |node_id| blk: {
            const node = engine.getNode(node_id) orelse break :blk null;
            break :blk error_report.spanFromOrigin(node.origin);
        } else null;
        error_report.print(.{
            .path = path,
            .source = source,
            .severity = switch (diagnostic.severity) {
                .warning => .warning,
                .@"error" => .@"error",
            },
            .message = message,
            .span = span,
        });
    }
}

fn hasErrorDiagnostics(engine: *const core.Engine) bool {
    for (engine.diagnostics.items) |diagnostic| {
        if (diagnostic.severity == .@"error") return true;
    }
    return false;
}

fn formatEngineDiagnostic(allocator: std.mem.Allocator, diagnostic: core.Diagnostic) ![]const u8 {
    return switch (diagnostic.data) {
        .user_report => |data| std.fmt.allocPrint(allocator, "UserReport: {s}", .{data.message}),
        .asset_not_found => |data| std.fmt.allocPrint(
            allocator,
            "AssetNotFound: {s} (resolved to {s})",
            .{ data.requested_path, data.resolved_path },
        ),
        .asset_invalid => |data| std.fmt.allocPrint(allocator, "InvalidAsset: {s}", .{data.reason}),
        .type_mismatch => |data| std.fmt.allocPrint(
            allocator,
            "{s}: expected {s}, got {s}",
            .{ @tagName(data.code), @tagName(data.expected), @tagName(data.actual) },
        ),
        .recursive_function => |data| std.fmt.allocPrint(
            allocator,
            "RecursiveFunction: recursive function cycle involving {s}",
            .{data.function_name},
        ),
        .unresolved_frame => |data| std.fmt.allocPrint(
            allocator,
            "UnresolvedFrame: missing_horizontal={s} missing_vertical={s}",
            .{
                if (data.missing_horizontal) "true" else "false",
                if (data.missing_vertical) "true" else "false",
            },
        ),
        .page_overflow => |data| std.fmt.allocPrint(
            allocator,
            "PageOverflow: left={d:.1} right={d:.1} top={d:.1} bottom={d:.1}",
            .{ data.overflow_left, data.overflow_right, data.overflow_top, data.overflow_bottom },
        ),
    };
}

fn printConstraintOrigin(source: []const u8, label: []const u8, origin: ?[]const u8) void {
    error_report.printLabeledOrigin(source, label, origin);
}

fn printConstraintFailure(path: []const u8, source: []const u8, engine: *const core.Engine, err: anyerror) void {
    const failure = engine.last_constraint_failure orelse {
        std.debug.print("constraint error: {s}\n", .{@errorName(err)});
        return;
    };
    const kind_text = switch (failure.kind) {
        .conflict => "ConstraintConflict: constraint conflict",
        .negative_size => "NegativeConstraintSize: negative size from constraints",
    };
    const constraint_text = core.dump.formatConstraint(engine.allocator, failure.constraint) catch "";
    defer if (constraint_text.len > 0) engine.allocator.free(constraint_text);
    const existing_text = if (failure.existing_constraint) |constraint|
        core.dump.formatConstraint(engine.allocator, constraint) catch ""
    else
        "";
    defer if (existing_text.len > 0) engine.allocator.free(existing_text);

    if (failure.constraint.origin) |origin| {
        if (error_report.parseByteOrigin(origin)) |span| {
            error_report.print(.{
                .path = path,
                .source = source,
                .severity = .@"error",
                .message = kind_text,
                .span = span,
            });
            if (failure.existing_constraint != null) {
                printConstraintOrigin(source, "other constraint", failure.existing_constraint.?.origin);
            }
            if (constraint_text.len > 0 and existing_text.len == 0) {
                std.debug.print("  constraint: {s}\n", .{constraint_text});
            }
            return;
        }
    }

    if (path.len != 0) {
        std.debug.print("{s}: error: {s}\n", .{ path, kind_text });
    } else {
        std.debug.print("{s}\n", .{kind_text});
    }
    if (failure.existing_constraint != null) {
        printConstraintOrigin(source, "other constraint", failure.existing_constraint.?.origin);
    }
    if (constraint_text.len > 0 and existing_text.len == 0) {
        std.debug.print("  constraint: {s}\n", .{constraint_text});
        printConstraintOrigin(source, "constraint", failure.constraint.origin);
    }
}

fn writeFile(io: std.Io, path: []const u8, bytes: []const u8) !void {
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = path,
        .data = bytes,
        .flags = .{ .truncate = true },
    });
}

fn printEngineDump(allocator: std.mem.Allocator, engine: *core.Engine) !void {
    const dump = try engine.dumpToString(allocator);
    defer allocator.free(dump);
    std.debug.print("{s}", .{dump});
}

fn writeEngineJson(
    io: std.Io,
    allocator: std.mem.Allocator,
    output_path: []const u8,
    engine: *core.Engine,
) !void {
    const json = try engine.dumpJsonToString(allocator);
    defer allocator.free(json);
    try writeFile(io, output_path, json);
}

fn writeEnginePdf(
    io: std.Io,
    allocator: std.mem.Allocator,
    output_path: []const u8,
    engine: *core.Engine,
) !void {
    const pdf_data = try pdf.renderDocumentToPdf(allocator, io, engine);
    defer allocator.free(pdf_data);
    try writeFile(io, output_path, pdf_data);
}

fn defaultSiblingOutputPath(
    allocator: std.mem.Allocator,
    input_path: []const u8,
    ext: []const u8,
) ![]const u8 {
    const dir = std.fs.path.dirname(input_path) orelse ".";
    const stem = std.fs.path.stem(input_path);
    return std.fmt.allocPrint(allocator, "{s}/{s}.{s}", .{ dir, stem, ext });
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
        var engine = try buildFile(io, allocator, input_path, null);
        defer engine.deinit();
        std.debug.print("ok {s}\n", .{input_path});
        return;
    }

    if (std.mem.eql(u8, cmd, "editor-info-file")) {
        const input_path = if (args.len >= 3) args[2] else "demo/ss.ss";
        const source = try readFile(io, allocator, input_path);
        defer allocator.free(source);
        var program = try parseSource(allocator, source, input_path);
        defer program.deinit(allocator);
        var engine = try buildFile(io, allocator, input_path, null);
        defer engine.deinit();
        try editor_info.writeEditorInfoJson(allocator, io, input_path, source, program, &engine);
        return;
    }

    if (std.mem.eql(u8, cmd, "dump-file")) {
        const input_path = if (args.len >= 3) args[2] else "demo/ss.ss";
        var progress = Progress.init(4);
        var engine = try buildFile(io, allocator, input_path, &progress);
        defer engine.deinit();

        progress.step("Print dump");
        try printEngineDump(allocator, &engine);
        return;
    }

    if (std.mem.eql(u8, cmd, "dump-json-file")) {
        const input_path = if (args.len >= 3) args[2] else "demo/ss.ss";
        const output_path = if (args.len >= 4) args[3] else try defaultSiblingOutputPath(allocator, input_path, "json");
        var progress = Progress.init(6);
        var engine = try buildFile(io, allocator, input_path, &progress);
        defer engine.deinit();

        progress.step("Serialize JSON");
        try writeEngineJson(io, allocator, output_path, &engine);
        progress.step("Done");
        return;
    }

    if (std.mem.eql(u8, cmd, "render-pdf-file")) {
        const input_path = if (args.len >= 3) args[2] else "demo/ss.ss";
        const output_path = if (args.len >= 4) args[3] else try defaultSiblingOutputPath(allocator, input_path, "pdf");
        var progress = Progress.init(7);
        var engine = try buildFile(io, allocator, input_path, &progress);
        defer engine.deinit();

        progress.step("Serialize render IR");
        progress.step("Render PDF");
        try writeEnginePdf(io, allocator, output_path, &engine);
        progress.step("Done");
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
