const std = @import("std");
const Reference = @import("utils").render_cache.LatexReference;
const testing = std.testing;

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
