const std = @import("std");
const core = @import("core");
const ast = @import("ast");
const parser = @import("syntax.zig");
const stage1 = @import("stage1.zig");
const pdf = @import("render/pdf.zig");
const dump = @import("dump.zig");
const typecheck = @import("sema/typecheck.zig");
const module_loader = @import("modules/loader.zig");
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
    const asset_base_dir = std.fs.path.dirname(path) orelse ".";
    return buildFileWithAssetBase(io, allocator, path, asset_base_dir, progress);
}

pub fn buildFileWithAssetBase(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    asset_base_dir: []const u8,
    progress: ?*Progress,
) !core.Ir {
    var source = try utils.fs.readFileAlloc(io, allocator, path);
    errdefer allocator.free(source);
    if (progress) |p| p.step("Read source");

    var program = try parseSource(allocator, source, path);
    errdefer program.deinit(allocator);
    if (progress) |p| p.step("Parse");

    var index = typecheck.loadProgramIndex(allocator, io, asset_base_dir, program) catch |err| {
        if (err == error.UnknownImport and program.imports.items.len != 0) {
            const message = try module_loader.formatUnknownImportMessage(allocator, asset_base_dir, program.imports.items[0].spec);
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
    if (progress) |p| p.step("Load index");

    var ir = typecheck.buildIr(allocator, path, asset_base_dir, &source, &program, &index) catch |err| {
        if (err == error.UnknownImport and program.imports.items.len != 0) {
            const message = try module_loader.formatUnknownImportMessage(allocator, asset_base_dir, program.imports.items[0].spec);
            defer allocator.free(message);
            error_report.print(.{
                .path = path,
                .source = source,
                .severity = .@"error",
                .message = message,
                .span = .{
                    .start = program.imports.items[0].span.start,
                    .end = program.imports.items[0].span.end,
                },
            });
        } else if (err != error.DiagnosticsFailed) {
            std.debug.print("error: {s}\n", .{@errorName(err)});
        }
        return err;
    };
    defer index.deinit();
    errdefer ir.deinit();

    typecheck.typecheckProgram(allocator, &ir) catch |err| {
        error_report.printIrDiagnostics(ir.projectPath(), ir.projectSource(), &ir);
        return err;
    };
    if (progress) |p| p.step("Typecheck");

    if (error_report.hasIrErrors(&ir)) {
        error_report.printIrDiagnostics(ir.projectPath(), ir.projectSource(), &ir);
        return error.DiagnosticsFailed;
    }

    stage1.lowerToIr(&ir) catch |err| {
        switch (err) {
            error.ConstraintConflict, error.NegativeConstraintSize => error_report.printConstraintFailure(ir.projectPath(), ir.projectSource(), &ir, err, core.formatConstraint),
            else => error_report.printIrDiagnostics(ir.projectPath(), ir.projectSource(), &ir),
        }
        return err;
    };
    if (progress) |p| p.step("Lower and solve");
    error_report.printIrDiagnostics(ir.projectPath(), ir.projectSource(), &ir);
    if (error_report.hasIrErrors(&ir)) return error.DiagnosticsFailed;
    return ir;
}

pub fn checkFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !void {
    var ir = try buildFile(io, allocator, path, null);
    defer ir.deinit();
    std.debug.print("ok {s}\n", .{path});
}

pub fn checkFileWithAssetBase(io: std.Io, allocator: std.mem.Allocator, path: []const u8, asset_base_dir: []const u8) !void {
    var ir = try buildFileWithAssetBase(io, allocator, path, asset_base_dir, null);
    defer ir.deinit();
    std.debug.print("ok {s}\n", .{path});
}

pub fn printIrJsonForFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8, progress: *Progress) !void {
    var ir = try buildFile(io, allocator, path, progress);
    defer ir.deinit();
    const text = try dump.toOwnedString(allocator, &ir);
    defer allocator.free(text);
    progress.step("Serialize JSON");
    std.debug.print("{s}", .{text});
    progress.step("Print dump");
}

pub fn printIrJsonForFileWithAssetBase(io: std.Io, allocator: std.mem.Allocator, path: []const u8, asset_base_dir: []const u8, progress: *Progress) !void {
    var ir = try buildFileWithAssetBase(io, allocator, path, asset_base_dir, progress);
    defer ir.deinit();
    const text = try dump.toOwnedString(allocator, &ir);
    defer allocator.free(text);
    progress.step("Serialize JSON");
    std.debug.print("{s}", .{text});
    progress.step("Print dump");
}

pub fn writeIrJsonFile(io: std.Io, allocator: std.mem.Allocator, input_path: []const u8, output_path: []const u8, progress: *Progress) !void {
    var ir = try buildFile(io, allocator, input_path, progress);
    defer ir.deinit();
    const json = try dump.toOwnedString(allocator, &ir);
    defer allocator.free(json);
    progress.step("Serialize JSON");
    try utils.fs.writeFile(io, output_path, json);
    progress.step("Write JSON");
}

pub fn writeIrJsonFileWithAssetBase(io: std.Io, allocator: std.mem.Allocator, input_path: []const u8, asset_base_dir: []const u8, output_path: []const u8, progress: *Progress) !void {
    var ir = try buildFileWithAssetBase(io, allocator, input_path, asset_base_dir, progress);
    defer ir.deinit();
    const json = try dump.toOwnedString(allocator, &ir);
    defer allocator.free(json);
    progress.step("Serialize JSON");
    try utils.fs.writeFile(io, output_path, json);
    progress.step("Write JSON");
}

pub fn writePdfForFile(io: std.Io, allocator: std.mem.Allocator, input_path: []const u8, output_path: []const u8, progress: *Progress) !void {
    var ir = try buildFile(io, allocator, input_path, progress);
    defer ir.deinit();
    const pdf_data = try pdf.renderDocumentToPdf(allocator, io, &ir);
    defer allocator.free(pdf_data);
    progress.step("Render PDF");
    try utils.fs.writeFile(io, output_path, pdf_data);
    progress.step("Write PDF");
}

pub fn writePdfForFileWithAssetBase(io: std.Io, allocator: std.mem.Allocator, input_path: []const u8, asset_base_dir: []const u8, output_path: []const u8, progress: *Progress) !void {
    var ir = try buildFileWithAssetBase(io, allocator, input_path, asset_base_dir, progress);
    defer ir.deinit();
    const pdf_data = try pdf.renderDocumentToPdf(allocator, io, &ir);
    defer allocator.free(pdf_data);
    progress.step("Render PDF");
    try utils.fs.writeFile(io, output_path, pdf_data);
    progress.step("Write PDF");
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
