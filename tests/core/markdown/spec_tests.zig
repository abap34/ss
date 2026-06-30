const std = @import("std");
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

test "core markdown spec: indented lines stay paragraphs instead of code blocks" {
    const allocator = testing.allocator;
    var doc = try markdown.parseMarkdownContent(allocator, "    not code");
    defer doc.deinit();

    try testing.expectEqual(@as(usize, 1), doc.blocks.items.len);
    try testing.expectEqual(markdown.BlockKind.paragraph, doc.blocks.items[0].kind);
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
