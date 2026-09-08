const std = @import("std");
const Reference = @import("utils").render_cache.LatexReference;
const testing = std.testing;
const cache = @import("utils").render_cache;

test "render cache reference: geometry and the batch PDF name are preserved" {
    const reference = try Reference.parse("2\t123.5\t24\t-1.5\t18\tlatex-batch-example.pdf\n");
    try testing.expectEqual(@as(usize, 2), reference.page_index);
    try testing.expectEqual(@as(f32, 123.5), reference.width);
    try testing.expectEqual(@as(f32, 24), reference.height);
    try testing.expectEqual(@as(f32, -1.5), reference.baseline_from_bottom);
    try testing.expectEqual(@as(f32, 18), reference.reference_height);
    try testing.expectEqualStrings("latex-batch-example.pdf", reference.pdf_name);
}

test "render cache reference: malformed geometry and paths are rejected" {
    const malformed = [_][]const u8{
        "0\t1\t1\t0\t1",
        "0\t1\t1\t0\t1\tfile.pdf\textra",
        "0\t1\t1\t0\t1\t../file.pdf",
        "0\t1\t1\t0\t1\t/absolute.pdf",
        "0\t1\t1\t0\t1\tanother.ref",
        "-1\t1\t1\t0\t1\tfile.pdf",
        "0\tNaN\t1\t0\t1\tfile.pdf",
        "0\t1\tinf\t0\t1\tfile.pdf",
        "0\t1\t1\tinf\t1\tfile.pdf",
        "0\t1\t1\t0\t0\tfile.pdf",
        "0\t0\t1\t0\t1\tfile.pdf",
    };
    for (malformed) |contents| try testing.expectError(error.InvalidPdfCache, Reference.parse(contents));
}

test "render cache reference: dependency metadata does not obscure the PDF group" {
    const reference = try Reference.parse("0\t10\t20\t0\t20\tbatch.pdf\n{\"version\":1,\"inputs\":[]}\n");
    try testing.expectEqualStrings("batch.pdf", reference.pdf_name);
    try testing.expectEqualStrings("{\"version\":1,\"inputs\":[]}", reference.dependencies);
}

test "render cache reference: output manifests expose their document dependency" {
    var lines = std.mem.splitScalar(u8, cache.PdfReference.version ++ "\ndocument\t" ++ "ab" ** 32 ++ "\nassembly\tfull\npages\t0\n", '\n');
    const digest = try cache.PdfReference.document(&lines);
    try testing.expectEqualSlices(u8, &([_]u8{0xab} ** 32), &digest);
    try testing.expectEqualStrings("assembly\tfull", lines.next().?);
    for ([_][]const u8{ "old\ndocument\t" ++ "ab" ** 32, cache.PdfReference.version ++ "\ndocument\tshort", cache.PdfReference.version ++ "\ndocument\t" ++ "zz" ** 32 }) |text| {
        var invalid = std.mem.splitScalar(u8, text, '\n');
        try testing.expectError(error.InvalidOutputManifest, cache.PdfReference.document(&invalid));
    }
}

test "render cache published resources: ownership survives copies and allocation failures" {
    try testing.checkAllAllocationFailures(testing.allocator, publishedOwnership, .{});
}

fn publishedOwnership(allocator: std.mem.Allocator) !void {
    const lease = (try cache.PublishedLease.create(allocator, testing.io, &.{ "editor/assets/font.woff", "editor/assets/name\nwith\"delimiters.svg" })).?;
    var owner: ?*cache.PublishedLease = lease;
    defer if (owner) |value| value.deinit();
    const retained = lease.retain();
    defer retained.deinit();
    lease.deinit();
    owner = null;
    try testing.expectEqual(@as(usize, 1), retained.references.load(.monotonic));
    const stat = try std.Io.Dir.cwd().statFile(testing.io, retained.manifest_path, .{});
    try testing.expect(stat.size > 0);
}

test "render cache published resources: empty sets and invalid paths create no lease" {
    try testing.expectEqual(null, try cache.PublishedLease.create(testing.allocator, testing.io, &.{}));
    for ([_][]const u8{ "", "/root/font.woff", "editor/../font.woff", "./editor/font.woff", "editor//font.woff" }) |path| {
        try testing.expectError(error.InvalidPublishedResourcePath, cache.PublishedLease.create(testing.allocator, testing.io, &.{path}));
    }
}
