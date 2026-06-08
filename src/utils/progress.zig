const std = @import("std");

pub const Progress = struct {
    total: usize,
    current: usize = 0,
    started_at_ns: i128,
    last_step_at_ns: i128,
    detail_active: bool = false,

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
        const replace_detail = self.detail_active;
        if (replace_detail) {
            self.detail_active = false;
            std.debug.print("\r", .{});
        }
        printProgress(
            self.current,
            self.total,
            label,
            @intCast(@divTrunc(stage_elapsed_ns, std.time.ns_per_ms)),
            @intCast(@divTrunc(total_elapsed_ns, std.time.ns_per_ms)),
            replace_detail,
        );
    }

    pub fn detail(self: *Progress, label: []const u8, detail_current: usize, detail_total: usize) void {
        const now = monotonicNowNs();
        const stage_elapsed_ns = now - self.last_step_at_ns;
        const total_elapsed_ns = now - self.started_at_ns;
        self.detail_active = true;
        std.debug.print("\r", .{});
        printProgressDetail(
            @min(self.current + 1, self.total),
            self.total,
            label,
            detail_current,
            detail_total,
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

fn printProgress(current: usize, total: usize, label: []const u8, stage_elapsed_ms: i64, total_elapsed_ms: i64, clear_eol: bool) void {
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
    std.debug.print("] {d}/{d} {s:<19}  ({s:>8}, total {s:>8})", .{
        current,
        total,
        label,
        stage_text,
        total_text,
    });
    if (clear_eol) std.debug.print("\x1b[K", .{});
    std.debug.print("\n", .{});
}

fn printProgressDetail(current: usize, total: usize, label: []const u8, detail_current: usize, detail_total: usize, stage_elapsed_ms: i64, total_elapsed_ms: i64) void {
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
    std.debug.print("] {d}/{d} {s:<11} {d}/{d:<5}  ({s:>8}, total {s:>8})\x1b[K", .{
        current,
        total,
        label,
        detail_current,
        detail_total,
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
