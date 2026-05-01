const std = @import("std");
const core = @import("core");
const parser = @import("parser.zig");
const pdf = @import("render/pdf.zig");
const dump = @import("dump.zig");
const typecheck = @import("parser/typecheck.zig");
const theme_loader = @import("theme_loader.zig");
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

pub fn buildFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8, progress: ?*Progress) !core.Ir {
    if (progress) |p| p.step("Read source");
    const source = try utils.fs.readFileAlloc(io, allocator, path);
    errdefer allocator.free(source);
    if (progress) |p| p.step("Parse");
    var program = try parseSource(allocator, source, path);
    errdefer program.deinit(allocator);

    if (progress) |p| p.step("Load index");
    var index = typecheck.loadProgramIndexForPath(allocator, io, path, program) catch |err| {
        if (err == error.UnknownTheme) {
            const base_dir = std.fs.path.dirname(path) orelse ".";
            const theme_name = program.theme_name orelse "default";
            const message = try theme_loader.formatUnknownThemeMessage(allocator, io, base_dir, theme_name);
            defer allocator.free(message);
            error_report.print(.{
                .path = path,
                .source = source,
                .severity = .@"error",
                .message = message,
                .span = null,
            });
        }
        return err;
    };
    errdefer index.deinit();

    var ir = try typecheck.buildIr(allocator, path, source, program, &index);
    defer index.deinit();
    errdefer ir.deinit();

    if (progress) |p| p.step("Typecheck");
    typecheck.typecheckProgram(allocator, &ir) catch |err| {
        error_report.printIrDiagnostics(ir.projectPath(), ir.projectSource(), &ir);
        return err;
    };

    if (error_report.hasIrErrors(&ir)) {
        error_report.printIrDiagnostics(ir.projectPath(), ir.projectSource(), &ir);
        return error.DiagnosticsFailed;
    }

    if (progress) |p| p.step("Lower and solve");
    parser.lowerToIr(&ir) catch |err| {
        switch (err) {
            error.ConstraintConflict, error.NegativeConstraintSize => error_report.printConstraintFailure(ir.projectPath(), ir.projectSource(), &ir, err, core.formatConstraint),
            else => error_report.printIrDiagnostics(ir.projectPath(), ir.projectSource(), &ir),
        }
        return err;
    };
    error_report.printIrDiagnostics(ir.projectPath(), ir.projectSource(), &ir);
    if (error_report.hasIrErrors(&ir)) return error.DiagnosticsFailed;
    return ir;
}

pub fn checkFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !void {
    var ir = try buildFile(io, allocator, path, null);
    defer ir.deinit();
    std.debug.print("ok {s}\n", .{path});
}

pub fn printIrJsonForFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8, progress: *Progress) !void {
    var ir = try buildFile(io, allocator, path, progress);
    defer ir.deinit();
    progress.step("Print dump");
    const text = try dump.toOwnedString(allocator, &ir);
    defer allocator.free(text);
    std.debug.print("{s}", .{text});
}

pub fn writeIrJsonFile(io: std.Io, allocator: std.mem.Allocator, input_path: []const u8, output_path: []const u8, progress: *Progress) !void {
    var ir = try buildFile(io, allocator, input_path, progress);
    defer ir.deinit();
    progress.step("Serialize JSON");
    const json = try dump.toOwnedString(allocator, &ir);
    defer allocator.free(json);
    try utils.fs.writeFile(io, output_path, json);
    progress.step("Done");
}

pub fn writePdfForFile(io: std.Io, allocator: std.mem.Allocator, input_path: []const u8, output_path: []const u8, progress: *Progress) !void {
    var ir = try buildFile(io, allocator, input_path, progress);
    defer ir.deinit();
    progress.step("Serialize render IR");
    progress.step("Render PDF");
    const pdf_data = try pdf.renderDocumentToPdf(allocator, io, &ir);
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
