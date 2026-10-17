const std = @import("std");
const allocation_testing = @import("allocation_testing");
const core = @import("core");

const markdown = core.markdown;
const testing = std.testing;

test "core markdown spec: table blocks preserve columns rows and inline runs" {
    const allocator = testing.allocator;
    var doc = try markdown.parseMarkdownContent(allocator,
        \\| Name | Score |
        \\| :--- | ---: |
        \\| Ada | **10** |
        \\| Ken | 8 |
    );
    defer doc.deinit();

    try testing.expectEqual(@as(usize, 1), doc.blocks.items.len);
    const block = doc.blocks.items[0];
    try testing.expectEqual(markdown.BlockKind.table, block.kind);
    try testing.expectEqual(@as(usize, 2), block.table.?.columns);
    try testing.expectEqual(@as(usize, 3), block.table.?.rows.items.len);
    try testing.expect(block.table.?.rows.items[0].header);
    try testing.expectEqual(markdown.Align.left, block.table.?.rows.items[0].cells.items[0].alignment);
    try testing.expectEqual(markdown.Align.right, block.table.?.rows.items[0].cells.items[1].alignment);
    try testing.expectEqual(markdown.RunKind.bold, block.table.?.rows.items[1].cells.items[1].lines.items[0].runs.items[0].kind);
}

test "core markdown spec: table column count expands to widest row" {
    const allocator = testing.allocator;
    var table = markdown.TableData{ .columns = 2 };
    defer table.rows.deinit(allocator);
    var row = markdown.TableRow{};
    defer row.cells.deinit(allocator);
    var cells = [_]markdown.TableCell{ .{}, .{}, .{} };

    try row.cells.append(allocator, &cells[0]);
    try row.cells.append(allocator, &cells[1]);
    try row.cells.append(allocator, &cells[2]);
    try table.rows.append(allocator, &row);

    try testing.expectEqual(@as(usize, 2), table.columns);
    try testing.expectEqual(@as(usize, 3), table.rows.items[0].cells.items.len);
    try testing.expectEqual(@as(usize, 3), markdown.tableColumnCount(table));
}

test "table separator widths preserve alignment and decimal lengths" {
    var doc = try markdown.parseMarkdownContent(testing.allocator,
        \\| Name | Description | Notes | Extra |
        \\| :---{100.5pt} | :---:{1fr} | ---:{ 2.5fr } | ---{auto} |
        \\| A | Example | Memo | Value |
    );
    defer doc.deinit();
    const table = doc.blocks.items[0].table.?;
    try testing.expectEqual(@as(f32, 100.5), table.column_widths[0].fixed);
    try testing.expectEqual(@as(f32, 1), table.column_widths[1].fraction);
    try testing.expectEqual(@as(f32, 2.5), table.column_widths[2].fraction);
    try testing.expectEqual(markdown.TableColumnWidth.auto, table.column_widths[3]);
    for (table.rows.items) |row| {
        try testing.expectEqual(markdown.Align.left, row.cells.items[0].alignment);
        try testing.expectEqual(markdown.Align.center, row.cells.items[1].alignment);
        try testing.expectEqual(markdown.Align.right, row.cells.items[2].alignment);
    }
}

test "table widths support omitted annotations optional pipes and nested tables" {
    var doc = try markdown.parseMarkdownContent(testing.allocator,
        \\> Name | Description | Notes
        \\> ---{100pt} | --- | ---{2fr}
        \\> A | Example
    );
    defer doc.deinit();
    const table = doc.blocks.items[0].quote.?.blocks.items[0].table.?;
    try testing.expectEqual(@as(f32, 100), table.column_widths[0].fixed);
    try testing.expectEqual(@as(f32, 1), table.column_widths[1].fraction);
    try testing.expectEqual(@as(f32, 2), table.column_widths[2].fraction);
    try testing.expectEqual(@as(usize, 3), table.rows.items[1].cells.items.len);
}

test "table widths reject invalid units nonpositive values and nonfinite lengths" {
    for ([_][]const u8{ "", "pt", "0pt", "-1pt", "0fr", "1px", "25%", "nanpt", "infpt", "1.2.3pt", "1 pt", "9999999999999999999999999999999999999999999pt" }) |token| {
        const source = try std.fmt.allocPrint(testing.allocator, "| A | B |\n| ---{{{s}}} | --- |", .{token});
        defer testing.allocator.free(source);
        try testing.expectError(error.InvalidMarkdownTableColumnWidth, markdown.parseMarkdownContent(testing.allocator, source));
    }
}

test "unclosed table width annotations remain ordinary Markdown" {
    var doc = try markdown.parseMarkdownContent(testing.allocator, "| A | B |\n| ---{100pt | --- |\n| x | y |");
    defer doc.deinit();
    try testing.expectEqual(markdown.BlockKind.paragraph, doc.blocks.items[0].kind);
}

test "table widths divide remaining space after fixed and automatic columns" {
    const table = markdown.TableData{ .column_widths = &.{ .{ .fixed = 100 }, .auto, .{ .fraction = 1 }, .{ .fraction = 2 } } };
    var widths: [4]f32 = undefined;
    markdown.resolveTableColumnWidths(table, 500, &.{ 0, 40, 0, 0 }, &widths);
    try testing.expectEqualSlices(f32, &.{ 100, 40, 120, 240 }, &widths);
}

test "automatic table widths redistribute unused shares and constrain large contents" {
    const table = markdown.TableData{ .column_widths = &.{ .auto, .auto, .auto } };
    var widths: [3]f32 = undefined;
    markdown.resolveTableColumnWidths(table, 300, &.{ 30, 1000, 1000 }, &widths);
    try testing.expectEqualSlices(f32, &.{ 30, 135, 135 }, &widths);
    markdown.resolveTableColumnWidths(table, 300, &.{ 30, 50, 70 }, &widths);
    try testing.expectEqualSlices(f32, &.{ 30, 50, 70 }, &widths);
}

test "fixed table widths preserve overflow and omitted widths share remaining space" {
    const table = markdown.TableData{ .column_widths = &.{.{ .fixed = 100 }} };
    var widths: [3]f32 = undefined;
    markdown.resolveTableColumnWidths(table, 300, &.{ 0, 0, 0 }, &widths);
    try testing.expectEqualSlices(f32, &.{ 100, 100, 100 }, &widths);
    markdown.resolveTableColumnWidths(table, 50, &.{ 0, 0, 0 }, &widths);
    try testing.expectEqualSlices(f32, &.{ 100, 0, 0 }, &widths);
}

test "core markdown spec: links preserve target URLs on link runs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var layout = try markdown.parseTextLayoutContent(allocator, "[external](https://example.com) [internal](#target)");
    defer layout.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), layout.lines.items.len);
    const runs = layout.lines.items[0].runs.items;
    try testing.expectEqual(@as(usize, 3), runs.len);
    try testing.expectEqual(markdown.RunKind.link, runs[0].kind);
    try testing.expectEqualStrings("external", runs[0].text);
    try testing.expectEqualStrings("https://example.com", runs[0].url.?);
    try testing.expectEqual(markdown.RunKind.text, runs[1].kind);
    try testing.expectEqualStrings(" ", runs[1].text);
    try testing.expectEqual(markdown.RunKind.link, runs[2].kind);
    try testing.expectEqualStrings("internal", runs[2].text);
    try testing.expectEqualStrings("#target", runs[2].url.?);
}

test "core markdown spec: strikethrough marks inline runs without changing style kind" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var layout = try markdown.parseTextLayoutContent(allocator, "before ~~gone~~ ~~**bold gone**~~");
    defer layout.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), layout.lines.items.len);
    const runs = layout.lines.items[0].runs.items;
    try testing.expectEqual(@as(usize, 4), runs.len);
    try testing.expectEqual(markdown.RunKind.text, runs[0].kind);
    try testing.expect(!runs[0].strikethrough);
    try testing.expectEqual(markdown.RunKind.text, runs[1].kind);
    try testing.expect(runs[1].strikethrough);
    try testing.expectEqualStrings("gone", runs[1].text);
    try testing.expectEqual(markdown.RunKind.bold, runs[3].kind);
    try testing.expect(runs[3].strikethrough);
    try testing.expectEqualStrings("bold gone", runs[3].text);
}

test "core markdown spec: underscore marks underline without changing style kind" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var layout = try markdown.parseTextLayoutContent(allocator, "plain _under_ _**bold under**_");
    defer layout.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), layout.lines.items.len);
    const runs = layout.lines.items[0].runs.items;
    try testing.expectEqual(@as(usize, 4), runs.len);
    try testing.expectEqual(markdown.RunKind.text, runs[0].kind);
    try testing.expect(!runs[0].underline);
    try testing.expectEqual(markdown.RunKind.text, runs[1].kind);
    try testing.expect(runs[1].underline);
    try testing.expectEqualStrings("under", runs[1].text);
    try testing.expectEqual(markdown.RunKind.bold, runs[3].kind);
    try testing.expect(runs[3].underline);
    try testing.expectEqualStrings("bold under", runs[3].text);
}

test "highlight spans compose with inline formatting links code math and icons" {
    var layout = try markdown.parseTextLayoutContent(testing.allocator, "==plain **bold** *italic* _under_ ~~gone~~ `code` [link](https://example.com) $x$ ![star](fa:star)==");
    defer layout.deinit(testing.allocator);
    var underlined = false;
    var deleted = false;
    for (layout.lines.items[0].runs.items) |run| {
        try testing.expect(run.highlighted);
        underlined = underlined or run.underline;
        deleted = deleted or run.strikethrough;
    }
    for ([_]markdown.RunKind{ .text, .bold, .italic, .code, .link, .math, .icon }) |kind| {
        var found = false;
        for (layout.lines.items[0].runs.items) |run| found = found or run.kind == kind;
        try testing.expect(found);
    }
    try testing.expect(underlined and deleted);
}

test "highlight delimiters respect escapes code whitespace and unmatched runs" {
    for ([_][]const u8{ "\\==literal==", "`==code==`", "== spaced==", "==spaced ==", "===long===", "=single=", "====", "==unclosed" }) |source| {
        var layout = try markdown.parseTextLayoutContent(testing.allocator, source);
        defer layout.deinit(testing.allocator);
        for (layout.lines.items) |line| for (line.runs.items) |run| try testing.expect(!run.highlighted);
    }
    var layout = try markdown.parseTextLayoutContent(testing.allocator, "plain ==marked== after");
    defer layout.deinit(testing.allocator);
    const runs = layout.lines.items[0].runs.items;
    try testing.expect(!runs[0].highlighted);
    try testing.expect(runs[1].highlighted);
    try testing.expectEqualStrings("marked", runs[1].text);
    try testing.expectEqual(@as(usize, 8), runs[1].source_start);
    try testing.expectEqual(@as(usize, 14), runs[1].source_end);
    try testing.expect(!runs[2].highlighted);
}

test "highlight spans persist across soft breaks in block Markdown" {
    var doc = try markdown.parseMarkdownContent(testing.allocator, "==first\nsecond==");
    defer doc.deinit();
    const paragraph = doc.blocks.items[0].paragraph.?;
    for (paragraph.lines.items) |line| for (line.runs.items) |run| try testing.expect(run.highlighted);
}

test "core markdown spec: task list markers are consumed" {
    const allocator = testing.allocator;
    var doc = try markdown.parseMarkdownContent(allocator,
        \\- [x] done
        \\- [ ] open
    );
    defer doc.deinit();

    try testing.expectEqual(@as(usize, 1), doc.blocks.items.len);
    const block = doc.blocks.items[0];
    try testing.expectEqual(markdown.BlockKind.bullet_list, block.kind);
    try testing.expectEqual(@as(usize, 2), block.list.?.items.items.len);

    const first = block.list.?.items.items[0].blocks.items[0].paragraph.?.lines.items[0].runs.items[0];
    const second = block.list.?.items.items[1].blocks.items[0].paragraph.?.lines.items[0].runs.items[0];
    try testing.expectEqualStrings("done", first.text);
    try testing.expectEqualStrings("open", second.text);
}

test "core markdown spec: block quotes preserve nested block structure" {
    const allocator = testing.allocator;
    var doc = try markdown.parseMarkdownContent(allocator,
        \\before
        \\
        \\> outer paragraph
        \\>
        \\> > nested paragraph
        \\>
        \\> - quoted item
        \\
        \\after
    );
    defer doc.deinit();

    try testing.expectEqual(@as(usize, 3), doc.blocks.items.len);
    const quote = doc.blocks.items[1];
    try testing.expectEqual(markdown.BlockKind.block_quote, quote.kind);
    try testing.expectEqual(@as(usize, 3), quote.quote.?.blocks.items.len);
    try testing.expectEqual(markdown.BlockKind.paragraph, quote.quote.?.blocks.items[0].kind);
    try testing.expectEqual(markdown.BlockKind.block_quote, quote.quote.?.blocks.items[1].kind);
    try testing.expectEqual(markdown.BlockKind.bullet_list, quote.quote.?.blocks.items[2].kind);
    try testing.expectEqualStrings("outer paragraph", quote.quote.?.blocks.items[0].paragraph.?.lines.items[0].runs.items[0].text);
    try testing.expectEqualStrings("nested paragraph", quote.quote.?.blocks.items[1].quote.?.blocks.items[0].paragraph.?.lines.items[0].runs.items[0].text);
    try testing.expectEqualStrings("quoted item", quote.quote.?.blocks.items[2].list.?.items.items[0].blocks.items[0].paragraph.?.lines.items[0].runs.items[0].text);
}

test "core markdown spec: fenced code blocks count embedded physical lines" {
    const allocator = testing.allocator;
    var doc = try markdown.parseMarkdownContent(allocator,
        \\before
        \\
        \\```shape
        \\program ::= init <polygon> ; <command>
        \\command ::= <op> | <command> ; <command>
        \\           | while <cond> do <command> end
        \\```
        \\
        \\after
    );
    defer doc.deinit();

    try testing.expectEqual(@as(usize, 3), doc.blocks.items.len);
    const block = doc.blocks.items[1];
    try testing.expectEqual(markdown.BlockKind.code_block, block.kind);
    try testing.expectEqualStrings("shape", block.language.?);
    try testing.expectEqual(@as(usize, 3), markdown.codeBlockPhysicalLineCount(block));
}

test "core markdown spec: fenced code blocks preserve blank physical lines without trailing phantom lines" {
    const allocator = testing.allocator;
    var doc = try markdown.parseMarkdownContent(allocator,
        \\```
        \\alpha
        \\
        \\beta
        \\```
    );
    defer doc.deinit();

    try testing.expectEqual(@as(usize, 1), doc.blocks.items.len);
    const block = doc.blocks.items[0];
    try testing.expectEqual(markdown.BlockKind.code_block, block.kind);
    try testing.expectEqual(@as(usize, 3), markdown.codeBlockPhysicalLineCount(block));
}

test "code line highlights accept ranges spaces duplicates and arbitrary order" {
    var doc = try markdown.parseMarkdownContent(
        testing.allocator,
        "```zig {5, 2 - 3, 2, 3-5}\nfirst\n\nthird\nfourth\nfifth\n```\n\n```zig\nplain\n```",
    );
    defer doc.deinit();
    const block = doc.blocks.items[0];
    try testing.expectEqualStrings("zig", block.language.?);
    try testing.expectEqual(@as(usize, 5), markdown.codeBlockPhysicalLineCount(block));
    try testing.expect(!block.highlightsCodeLine(0));
    try testing.expect(!block.highlightsCodeLine(1));
    for (2..6) |line| try testing.expect(block.highlightsCodeLine(line));
    try testing.expect(!block.highlightsCodeLine(6));
    try testing.expectEqual(@as(usize, 0), doc.blocks.items[1].code_line_highlights.len);
}

test "code line highlights count blank source lines in nested and language free fences" {
    var doc = try markdown.parseMarkdownContent(testing.allocator,
        \\> ~~~ {1, 3}
        \\>
        \\> middle
        \\>
        \\> ~~~
        \\
        \\- Item
        \\
        \\  ```unknown {2}
        \\  first
        \\  last
        \\  ```
    );
    defer doc.deinit();
    const quoted = doc.blocks.items[0].quote.?.blocks.items[0];
    try testing.expect(quoted.language == null);
    try testing.expectEqual(@as(usize, 3), markdown.codeBlockPhysicalLineCount(quoted));
    try testing.expect(quoted.highlightsCodeLine(1));
    try testing.expect(!quoted.highlightsCodeLine(2));
    try testing.expect(quoted.highlightsCodeLine(3));
    const nested = doc.blocks.items[1].list.?.items.items[0].blocks.items[1];
    try testing.expectEqualStrings("unknown", nested.language.?);
    try testing.expect(nested.highlightsCodeLine(2));
}

test "code line highlights accept CRLF unterminated fences and unrelated metadata" {
    var doc = try markdown.parseMarkdownContent(testing.allocator, "```zig\t{ 1 - 2 }\r\nfirst\r\nlast");
    defer doc.deinit();
    try testing.expect(doc.blocks.items[0].highlightsCodeLine(2));
    var unrelated = try markdown.parseMarkdownContent(testing.allocator, "```zig title=example\nfirst\n```");
    defer unrelated.deinit();
    try testing.expectEqualStrings("zig", unrelated.blocks.items[0].language.?);
    try testing.expectEqual(@as(usize, 0), unrelated.blocks.items[0].code_line_highlights.len);
}

test "code line highlights reject malformed specifications" {
    const invalid = [_][]const u8{
        "{}",     "{ }",                                          "{0}",    "{2-1}", "{-1}",    "{+1}",  "{1.5}", "{a}",
        "{1,}",   "{,1}",                                         "{1,,2}", "{1-}",  "{1-2-3}", "{1 2}", "{1",    "{1} extra",
        "{1}{2}", "{999999999999999999999999999999999999999999}",
    };
    for (invalid) |annotation| {
        const content = try std.fmt.allocPrint(testing.allocator, "```zig {s}\nfirst\nsecond\n```", .{annotation});
        defer testing.allocator.free(content);
        try testing.expectError(error.InvalidMarkdownCodeLineHighlight, markdown.parseMarkdownContent(testing.allocator, content));
    }
}

test "code line highlights reject nonexistent lines including the trailing phantom and empty blocks" {
    for ([_][]const u8{
        "```zig {3}\nfirst\nsecond\n```",
        "```zig {1-3}\nfirst\nsecond\n```",
        "``` {1}\n```",
        "``` {2}\n\n```",
    }) |content| {
        try testing.expectError(error.MarkdownCodeLineHighlightOutOfBounds, markdown.parseMarkdownContent(testing.allocator, content));
    }
    var blank = try markdown.parseMarkdownContent(testing.allocator, "``` {1}\n\n```");
    defer blank.deinit();
    try testing.expect(blank.blocks.items[0].highlightsCodeLine(1));
}

test "core markdown spec: indented lines stay paragraphs instead of code blocks" {
    const allocator = testing.allocator;
    var doc = try markdown.parseMarkdownContent(allocator, "    not code");
    defer doc.deinit();

    try testing.expectEqual(@as(usize, 1), doc.blocks.items.len);
    try testing.expectEqual(markdown.BlockKind.paragraph, doc.blocks.items[0].kind);
}

test "core markdown spec: headings preserve their semantic level" {
    const allocator = testing.allocator;
    var doc = try markdown.parseMarkdownContent(allocator, "### Precise heading");
    defer doc.deinit();

    try testing.expectEqual(@as(usize, 1), doc.blocks.items.len);
    const block = doc.blocks.items[0];
    try testing.expectEqual(markdown.BlockKind.heading, block.kind);
    try testing.expectEqual(@as(?u8, 3), block.heading_level);
    try testing.expectEqualStrings("Precise heading", block.paragraph.?.lines.items[0].runs.items[0].text);
}

test "core markdown spec: html blocks do not suppress markdown parsing" {
    const allocator = testing.allocator;
    var doc = try markdown.parseMarkdownContent(allocator,
        \\<div>
        \\**bold**
        \\</div>
    );
    defer doc.deinit();

    var saw_bold = false;
    for (doc.blocks.items) |block| {
        const paragraph = block.paragraph orelse continue;
        for (paragraph.lines.items) |line| {
            for (line.runs.items) |run| {
                if (run.kind == .bold and std.mem.eql(u8, run.text, "bold")) saw_bold = true;
            }
        }
    }
    try testing.expect(saw_bold);
}

fn parseInlineWithAllocator(allocator: std.mem.Allocator) !void {
    var layout = try markdown.parseTextLayoutContent(allocator, "[link](https://example.com) ![icon](fa:star) **bold** _underlined_ ~~deleted~~ ==marked== $x$");
    defer layout.deinit(allocator);
    try testing.expect(layout.lines.items.len > 0);
    try testing.expect(layout.lines.items[0].runs.items.len > 0);
}

test "inline Markdown preserves callback errors and releases partial runs" {
    try allocation_testing.checkAllAllocationFailures(testing.allocator, parseInlineWithAllocator, .{});
}

fn parseBlocksWithAllocator(allocator: std.mem.Allocator) !void {
    var doc = try markdown.parseMarkdownContent(allocator,
        \\# Heading
        \\Paragraph [link](https://example.com) ![icon](fa:star).
        \\> Quote with **bold** and $x$.
        \\>
        \\> - One
        \\> - Two
        \\1. Ordered
        \\2. Items
        \\~~~zig {1}
        \\const n = 1;
        \\~~~
        \\| Left | Right |
        \\| :---{auto} | ---:{2fr} |
        \\| A | B |
    );
    defer doc.deinit();
    try testing.expect(doc.blocks.items.len > 0);
}

test "block Markdown preserves callback errors across allocation failures" {
    try allocation_testing.checkAllAllocationFailures(testing.allocator, parseBlocksWithAllocator, .{});
}

test "plain text preserves markup and source spans without creating assets" {
    const content = "**literal** $math$ &amp; <tag>\r\n\n日本語";
    var layout = try markdown.parsePlainTextContent(testing.allocator, content);
    defer layout.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), layout.lines.items.len);
    for (layout.lines.items) |line| {
        try testing.expectEqual(@as(usize, 1), line.runs.items.len);
        const run = line.runs.items[0];
        try testing.expectEqual(markdown.RunKind.text, run.kind);
        try testing.expectEqualStrings(content[run.source_start..run.source_end], run.text);
        try testing.expect(run.url == null and run.icon == null);
    }
    try testing.expectEqualStrings("**literal** $math$ &amp; <tag>", layout.lines.items[0].runs.items[0].text);
}

test "plain text layout releases partial allocations" {
    try allocation_testing.checkAllAllocationFailures(testing.allocator, plainTextAllocationFailure, .{});
}

fn plainTextAllocationFailure(allocator: std.mem.Allocator) !void {
    var layout = try markdown.parsePlainTextContent(allocator, "First\r\n\nLast\n");
    defer layout.deinit(allocator);
}
