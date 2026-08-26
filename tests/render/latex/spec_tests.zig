const std = @import("std");
const latex = @import("render_latex");

const testing = std.testing;

test "render LaTeX spec: one document builder emits mixed fragments in order" {
    const entries = [_]latex.Entry{
        .{ .source = "x + y", .kind = .inline_math },
        .{ .source = "\\begin{minipage}{2cm}body\\end{minipage}", .kind = .body },
        .{ .source = "a + b", .kind = .display_math },
    };
    const source = try latex.documentSource(testing.allocator, "\\newcommand{\\token}{value}\n", &entries);
    defer testing.allocator.free(source);

    try testing.expectEqual(@as(usize, entries.len), std.mem.count(u8, source, "\\begin{preview}"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, source, "\\immediate\\write\\ssmetrics{body}"));
    try testing.expectEqual(@as(usize, 0), std.mem.count(u8, source, "{1,1,0,1,0}"));
    try testing.expect(std.mem.indexOf(u8, source, "$\\mathstrut x + y$") != null);
    try testing.expect(std.mem.indexOf(u8, source, "$\\displaystyle\\mathstrut a + b$") != null);
}

test "render LaTeX spec: metric records distinguish bodies from measured mathematics" {
    const entries = [_]latex.Entry{
        .{ .source = "x", .kind = .inline_math },
        .{ .source = "body", .kind = .body },
        .{ .source = "y", .kind = .display_math },
    };
    const metrics = try latex.parseMetrics(
        testing.allocator,
        "100,30,10,20,5\nbody\n80,24,6,18,2\n",
        &entries,
    );
    defer testing.allocator.free(metrics);

    try testing.expectApproxEqAbs(@as(f64, 0.25), metrics[0].?.baseline_ratio, 0.000_001);
    try testing.expectApproxEqAbs(@as(f64, 0.625), metrics[0].?.reference_height_ratio, 0.000_001);
    try testing.expect(metrics[1] == null);
    try testing.expectApproxEqAbs(@as(f64, 0.2), metrics[2].?.baseline_ratio, 0.000_001);
}

test "render LaTeX spec: metric record kinds must match their entries" {
    const entries = [_]latex.Entry{.{ .source = "body", .kind = .body }};
    try testing.expectError(
        error.InvalidLatexMetrics,
        latex.parseMetrics(testing.allocator, "1,1,0,1,0\n", &entries),
    );
}

test "render LaTeX spec: batch limits retain dense slide workloads" {
    try testing.expect(latex.max_batch_entries >= 600);
    try testing.expect(latex.max_batch_source_bytes >= 1024 * 1024);

    const count_entries = try testing.allocator.alloc(latex.Entry, latex.max_batch_entries + 1);
    defer testing.allocator.free(count_entries);
    for (count_entries) |*entry| entry.* = .{ .source = "x", .kind = .inline_math };
    try testing.expectEqual(latex.max_batch_entries, latex.batchChunkEnd(count_entries, 0));
    try testing.expectEqual(count_entries.len, latex.batchChunkEnd(count_entries, latex.max_batch_entries));

    const source_a = try testing.allocator.alloc(u8, 3 * 1024 * 1024);
    defer testing.allocator.free(source_a);
    const source_b = try testing.allocator.alloc(u8, 2 * 1024 * 1024);
    defer testing.allocator.free(source_b);
    const byte_entries = [_]latex.Entry{
        .{ .source = source_a, .kind = .inline_math },
        .{ .source = source_b, .kind = .inline_math },
    };
    try testing.expectEqual(@as(usize, 1), latex.batchChunkEnd(&byte_entries, 0));
}
