const std = @import("std");

const Allocator = std.mem.Allocator;

pub const max_batch_entries: usize = 1024;
pub const max_batch_source_bytes: usize = 4 * 1024 * 1024;
pub const preamble_read_limit: usize = 4 * 1024 * 1024;
pub const metrics_read_limit: usize = 1024 * 1024;

pub const FragmentKind = enum {
    inline_math,
    display_math,
    body,
};

pub const Entry = struct {
    source: []const u8,
    kind: FragmentKind,
};

pub const Metrics = struct {
    baseline_ratio: f64,
    reference_height_ratio: f64,
};

pub fn batchChunkEnd(entries: []const Entry, start: usize) usize {
    std.debug.assert(start < entries.len);
    var end = start;
    var source_bytes: usize = 0;
    while (end < entries.len and end - start < max_batch_entries) : (end += 1) {
        const entry_bytes = entries[end].source.len;
        if (end > start and entry_bytes > max_batch_source_bytes -| source_bytes) break;
        source_bytes +|= entry_bytes;
    }
    return @max(end, start + 1);
}

pub fn documentSource(
    allocator: Allocator,
    preamble: []const u8,
    entries: []const Entry,
) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator,
        \\ \documentclass{article}
        \\ \usepackage[active,tightpage]{preview}
        \\ \PreviewBorder=0pt
        \\ \usepackage{amsmath,amssymb}
        \\ \usepackage{graphicx}
        \\ \usepackage{xcolor}
        \\ \newwrite\ssmetrics
        \\
    );
    try out.appendSlice(allocator, preamble);
    try out.appendSlice(allocator,
        \\ \pagestyle{empty}
        \\ \begin{document}
        \\ \immediate\openout\ssmetrics=main.ssm
        \\
    );
    for (entries) |entry| {
        const fragment = try latexFragment(allocator, entry.source, entry.kind);
        defer allocator.free(fragment);
        if (entry.kind == .body) {
            try out.appendSlice(allocator,
                \\ \immediate\write\ssmetrics{body}
                \\ \begin{preview}
                \\
            );
            try out.appendSlice(allocator, fragment);
            try out.appendSlice(allocator,
                \\ \end{preview}
                \\
            );
            continue;
        }
        try out.appendSlice(allocator, "\\setbox0=\\hbox{");
        try out.appendSlice(allocator, fragment);
        try out.appendSlice(allocator, "}\n\\setbox1=\\hbox{");
        try out.appendSlice(allocator, referenceFragment(entry.kind));
        try out.appendSlice(allocator,
            \\ }
            \\ \immediate\write\ssmetrics{\number\wd0,\number\ht0,\number\dp0,\number\ht1,\number\dp1}
            \\ \begin{preview}
            \\ \copy0
            \\ \end{preview}
            \\
        );
    }
    try out.appendSlice(allocator,
        \\ \immediate\closeout\ssmetrics
        \\ \end{document}
        \\
    );
    return out.toOwnedSlice(allocator);
}

pub fn parseMetrics(
    allocator: Allocator,
    contents: []const u8,
    entries: []const Entry,
) ![]?Metrics {
    const metrics = try allocator.alloc(?Metrics, entries.len);
    errdefer allocator.free(metrics);
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        if (count >= entries.len) return error.InvalidLatexMetrics;
        metrics[count] = try parseMetric(trimmed, entries[count].kind);
        count += 1;
    }
    if (count != entries.len) return error.InvalidLatexMetrics;
    return metrics;
}

fn parseMetric(line: []const u8, kind: FragmentKind) !?Metrics {
    if (kind == .body) {
        if (!std.mem.eql(u8, line, "body")) return error.InvalidLatexMetrics;
        return null;
    }
    var fields = std.mem.tokenizeAny(u8, line, " \t,");
    const width_sp = try parseMetricField(&fields);
    const height_sp = try parseMetricField(&fields);
    const depth_sp = try parseMetricField(&fields);
    const reference_height_sp = try parseMetricField(&fields);
    const reference_depth_sp = try parseMetricField(&fields);
    if (fields.next() != null) return error.InvalidLatexMetrics;
    const total_height_sp = std.math.add(i64, height_sp, depth_sp) catch return error.InvalidLatexMetrics;
    const reference_total_height_sp = std.math.add(i64, reference_height_sp, reference_depth_sp) catch return error.InvalidLatexMetrics;
    if (width_sp <= 0 or total_height_sp <= 0 or reference_total_height_sp <= 0) {
        return error.InvalidLatexMetrics;
    }
    return .{
        .baseline_ratio = @as(f64, @floatFromInt(depth_sp)) / @as(f64, @floatFromInt(total_height_sp)),
        .reference_height_ratio = @as(f64, @floatFromInt(reference_total_height_sp)) / @as(f64, @floatFromInt(total_height_sp)),
    };
}

fn parseMetricField(fields: anytype) !i64 {
    return std.fmt.parseInt(i64, fields.next() orelse return error.InvalidLatexMetrics, 10) catch
        return error.InvalidLatexMetrics;
}

fn latexFragment(allocator: Allocator, source: []const u8, kind: FragmentKind) ![]u8 {
    return switch (kind) {
        .inline_math => std.fmt.allocPrint(allocator, "$\\mathstrut {s}$\n", .{source}),
        .display_math => std.fmt.allocPrint(allocator, "$\\displaystyle\\mathstrut {s}$\n", .{source}),
        .body => allocator.dupe(u8, source),
    };
}

fn referenceFragment(kind: FragmentKind) []const u8 {
    return switch (kind) {
        .inline_math => "$\\mathstrut$",
        .display_math => "$\\displaystyle\\mathstrut$",
        .body => "",
    };
}
