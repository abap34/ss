const std = @import("std");
const core = @import("core");
const parser = @import("parser.zig");
const pdf = @import("render/pdf.zig");
const editor_info = @import("editor_info.zig");
const typecheck = @import("parser/typecheck.zig");
const utils = @import("utils");
const error_report = utils.err;

pub const Progress = struct {
    total: usize,
    current: usize = 0,
    started_at_ns: i128,
    last_step_at_ns: i128,

    pub fn init(total: usize) Progress {
        const now = monotonicNowNs();
        return .{
            .total = total,
            .started_at_ns = now,
            .last_step_at_ns = now,
        };
    }

    pub fn step(self: *Progress, label: []const u8) void {
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

pub const CompiledFile = struct {
    allocator: std.mem.Allocator,
    source: []u8,
    program: parser.Program,
    index: typecheck.ProgramIndex,
    engine: core.Engine,

    pub fn deinit(self: *CompiledFile) void {
        self.engine.deinit();
        self.index.deinit();
        self.program.deinit(self.allocator);
        self.allocator.free(self.source);
    }

    pub fn takeEngine(self: *CompiledFile) core.Engine {
        const engine = self.engine;
        self.index.deinit();
        self.program.deinit(self.allocator);
        self.allocator.free(self.source);
        self.* = undefined;
        return engine;
    }
};

pub fn buildFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8, progress: ?*Progress) !core.Engine {
    var compiled = try compileFile(io, allocator, path, progress);
    errdefer compiled.deinit();
    return compiled.takeEngine();
}

pub fn compileFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8, progress: ?*Progress) !CompiledFile {
    if (progress) |p| p.step("Read source");
    const source = try utils.fs.readFileAlloc(io, allocator, path);
    errdefer allocator.free(source);
    if (progress) |p| p.step("Parse");
    var program = try parseSource(allocator, source, path);
    errdefer program.deinit(allocator);

    if (progress) |p| p.step("Analyze");
    var index = try typecheck.loadProgramIndexForPath(allocator, io, path, program);
    errdefer index.deinit();

    if (progress) |p| p.step("Lower program");
    var engine = try core.Engine.init(allocator);
    errdefer engine.deinit();
    engine.asset_base_dir = try allocator.dupe(u8, std.fs.path.dirname(path) orelse ".");
    parser.lowerToEngineWithIndex(program, source, path, &engine, &index) catch |err| {
        switch (err) {
            error.ConstraintConflict, error.NegativeConstraintSize => error_report.printConstraintFailure(path, source, &engine, err, core.dump.formatConstraint),
            else => error_report.printEngineDiagnostics(path, source, &engine),
        }
        return err;
    };
    error_report.printEngineDiagnostics(path, source, &engine);
    if (error_report.hasErrorDiagnostics(&engine)) return error.DiagnosticsFailed;
    if (progress) |p| p.step("Solve constraints");
    return .{
        .allocator = allocator,
        .source = source,
        .program = program,
        .index = index,
        .engine = engine,
    };
}

pub fn checkFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !void {
    var engine = try buildFile(io, allocator, path, null);
    defer engine.deinit();
    std.debug.print("ok {s}\n", .{path});
}

pub fn writeEditorInfoFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !void {
    var compiled = try compileFile(io, allocator, path, null);
    defer compiled.deinit();
    try editor_info.writeEditorInfoJsonWithIndex(
        allocator,
        compiled.source,
        compiled.program,
        &compiled.engine,
        &compiled.index,
    );
}

pub fn printEngineDumpForFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8, progress: *Progress) !void {
    var engine = try buildFile(io, allocator, path, progress);
    defer engine.deinit();
    progress.step("Print dump");
    const dump = try engine.dumpToString(allocator);
    defer allocator.free(dump);
    std.debug.print("{s}", .{dump});
}

pub fn writeEngineJsonFile(io: std.Io, allocator: std.mem.Allocator, input_path: []const u8, output_path: []const u8, progress: *Progress) !void {
    var engine = try buildFile(io, allocator, input_path, progress);
    defer engine.deinit();
    progress.step("Serialize JSON");
    const json = try engine.dumpJsonToString(allocator);
    defer allocator.free(json);
    try utils.fs.writeFile(io, output_path, json);
    progress.step("Done");
}

pub fn writeEnginePdfFile(io: std.Io, allocator: std.mem.Allocator, input_path: []const u8, output_path: []const u8, progress: *Progress) !void {
    var engine = try buildFile(io, allocator, input_path, progress);
    defer engine.deinit();
    progress.step("Serialize render IR");
    progress.step("Render PDF");
    const pdf_data = try pdf.renderDocumentToPdf(allocator, io, &engine);
    defer allocator.free(pdf_data);
    try utils.fs.writeFile(io, output_path, pdf_data);
    progress.step("Done");
}

fn parseSource(allocator: std.mem.Allocator, source: []const u8, path: []const u8) !parser.Program {
    return parser.parse(allocator, source) catch |err| {
        error_report.printParseError(path, source, err, parser.lastParseDiagnostic());
        return err;
    };
}

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
