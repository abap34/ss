const std = @import("std");
const core = @import("core");
const wrap_layout = core.render_wrap;
const scene = @import("../scene.zig");
const atoms_mod = @import("atoms.zig");
const highlight = @import("highlight.zig");

pub const TextPaint = core.render_policy.TextPaint;
pub const Line = core.markdown.Line;
pub const Run = core.markdown.Run;
pub const TexPreambleEntry = core.render_env.TexPreambleEntry;

pub const PlainTextOptions = struct {
    font: scene.FontFace,
    color: scene.Color,
    font_size: f32,
    line_height: f32,
    wrap: bool = false,
    preserve_leading_space: bool = false,
    trim_trailing_empty_line: bool = false,
    highlighting: ?highlight.Request = null,
};

pub const ResourceResolver = struct {
    context: *anyopaque,
    appendMath: *const fn (
        context: *anyopaque,
        allocator: std.mem.Allocator,
        atoms: *std.ArrayList(atoms_mod.Atom),
        source: []const u8,
        preamble: []const TexPreambleEntry,
        mode: @import("../input.zig").MathMode,
        text: TextPaint,
    ) anyerror!void,
    appendIcon: *const fn (
        context: *anyopaque,
        allocator: std.mem.Allocator,
        atoms: *std.ArrayList(atoms_mod.Atom),
        source: []const u8,
        text: TextPaint,
    ) anyerror!void,
    appendDisplayMathBlock: *const fn (
        context: *anyopaque,
        allocator: std.mem.Allocator,
        page: *scene.Page,
        node_id: scene.NodeId,
        frame: scene.Frame,
        source: []const u8,
        preamble: []const TexPreambleEntry,
        text: TextPaint,
    ) anyerror!void,
};

pub fn textItemFromLines(
    allocator: std.mem.Allocator,
    node_id: scene.NodeId,
    frame: scene.Frame,
    lines: []const Line,
    text: TextPaint,
    wrap: bool,
    preamble: []const TexPreambleEntry,
    resolver: ?ResourceResolver,
) !scene.TextItem {
    var item = scene.TextItem{ .node_id = node_id, .frame = frame, .clip = true };
    errdefer item.deinit(allocator);
    var baseline = frame.y + text.font_size;
    for (lines) |line| {
        var atoms = std.ArrayList(atoms_mod.Atom).empty;
        defer atoms.deinit(allocator);
        try appendRunAtoms(allocator, &atoms, line.runs.items, text, preamble, resolver);
        try appendAtomLines(allocator, &item, frame.y, baseline, frame.width, atoms.items, text, text.line_height, wrap, false);
        baseline = if (item.lines.items.len == 0)
            baseline + text.line_height
        else
            item.lines.items[item.lines.items.len - 1].baseline_y + text.line_height;
    }
    if (lines.len == 0) {
        const line = scene.TextLine{ .baseline_y = baseline, .line_height = text.line_height };
        try item.lines.append(allocator, line);
    }
    return item;
}

pub fn textItemFromRunSlice(
    allocator: std.mem.Allocator,
    node_id: scene.NodeId,
    frame: scene.Frame,
    runs: []const Run,
    text: TextPaint,
    wrap: bool,
    preamble: []const TexPreambleEntry,
    resolver: ?ResourceResolver,
) !scene.TextItem {
    var item = scene.TextItem{ .node_id = node_id, .frame = frame, .clip = true };
    errdefer item.deinit(allocator);
    const baseline = frame.y + text.font_size;
    var atoms = std.ArrayList(atoms_mod.Atom).empty;
    defer atoms.deinit(allocator);
    try appendRunAtoms(allocator, &atoms, runs, text, preamble, resolver);
    try appendAtomLines(allocator, &item, frame.y, baseline, frame.width, atoms.items, text, text.line_height, wrap, false);
    return item;
}

pub fn plainTextItem(
    allocator: std.mem.Allocator,
    node_id: scene.NodeId,
    frame: scene.Frame,
    content: []const u8,
    text: TextPaint,
    font: scene.FontFace,
    color: scene.Color,
    font_size: f32,
    wrap: bool,
) !scene.TextItem {
    return plainTextItemWithOptions(allocator, node_id, frame, content, text, .{
        .font = font,
        .color = color,
        .font_size = font_size,
        .line_height = text.line_height,
        .wrap = wrap,
    });
}

pub fn plainTextItemWithOptions(
    allocator: std.mem.Allocator,
    node_id: scene.NodeId,
    frame: scene.Frame,
    content: []const u8,
    text: TextPaint,
    options: PlainTextOptions,
) !scene.TextItem {
    var item = scene.TextItem{ .node_id = node_id, .frame = frame, .clip = true };
    errdefer item.deinit(allocator);

    var highlighted_spans = if (options.highlighting) |request|
        try highlight.collectSpans(allocator, request, content)
    else
        std.ArrayList(highlight.Span).empty;
    defer highlighted_spans.deinit(allocator);

    var baseline = frame.y + options.font_size;
    var lines = std.mem.splitScalar(u8, content, '\n');
    var line_start: usize = 0;
    while (lines.next()) |line_text| {
        if (options.trim_trailing_empty_line and line_text.len == 0 and lines.index == null and content.len > 0 and content[content.len - 1] == '\n') break;
        var atoms = std.ArrayList(atoms_mod.Atom).empty;
        defer atoms.deinit(allocator);
        try appendPlainTextAtoms(
            allocator,
            &atoms,
            content,
            line_start,
            line_start + line_text.len,
            options.font,
            options.color,
            options.font_size,
            highlighted_spans.items,
        );
        try appendAtomLines(
            allocator,
            &item,
            frame.y,
            baseline,
            frame.width,
            atoms.items,
            text,
            options.line_height,
            options.wrap,
            options.preserve_leading_space,
        );
        baseline = if (item.lines.items.len == 0)
            baseline + options.line_height
        else
            item.lines.items[item.lines.items.len - 1].baseline_y + options.line_height;
        line_start = @min(line_start + line_text.len + 1, content.len);
    }
    if (content.len == 0 and item.lines.items.len == 0) {
        try item.lines.append(allocator, .{ .baseline_y = baseline, .line_height = options.line_height });
    }
    return item;
}

pub fn visualLineCountFromLines(
    allocator: std.mem.Allocator,
    lines: []const Line,
    text: TextPaint,
    width: f32,
    preamble: []const TexPreambleEntry,
    resolver: ?ResourceResolver,
) !usize {
    if (lines.len == 0) return 1;
    var total: usize = 0;
    for (lines) |line| {
        var atoms = std.ArrayList(atoms_mod.Atom).empty;
        defer atoms.deinit(allocator);
        try appendRunAtoms(allocator, &atoms, line.runs.items, text, preamble, resolver);
        const measured = try toMeasuredAtoms(allocator, atoms.items, text);
        defer allocator.free(measured);
        total += wrap_layout.visualLineCount(measured, width, false);
    }
    return @max(total, 1);
}

fn appendRunAtoms(
    allocator: std.mem.Allocator,
    atoms: *std.ArrayList(atoms_mod.Atom),
    runs: []const Run,
    text: TextPaint,
    preamble: []const TexPreambleEntry,
    resolver: ?ResourceResolver,
) !void {
    for (runs) |run| {
        switch (run.kind) {
            .math => if (resolver) |r|
                try r.appendMath(r.context, allocator, atoms, run.text, preamble, .@"inline", text)
            else
                try atoms_mod.appendTextAtoms(allocator, atoms, run.text, text.font, text.color, text.font_size, null, run.strikethrough),
            .display_math => if (resolver) |r|
                try r.appendMath(r.context, allocator, atoms, run.text, preamble, .display, text)
            else
                try atoms_mod.appendTextAtoms(allocator, atoms, run.text, text.font, text.color, text.font_size, null, run.strikethrough),
            .icon => if (resolver) |r| {
                const icon_source = run.icon orelse run.text;
                try r.appendIcon(r.context, allocator, atoms, icon_source, text);
            } else {
                try atoms_mod.appendTextAtoms(allocator, atoms, run.text, text.font, text.color, text.font_size, null, run.strikethrough);
            },
            .bold => try atoms_mod.appendTextAtoms(allocator, atoms, run.text, text.bold_font, text.markdown_bold_color orelse text.color, text.font_size, null, run.strikethrough),
            .italic => try atoms_mod.appendTextAtoms(allocator, atoms, run.text, text.italic_font, text.color, text.font_size, null, run.strikethrough),
            .code => try atoms_mod.appendTextAtoms(allocator, atoms, run.text, text.code_font, text.color, text.font_size, null, run.strikethrough),
            .link => try atoms_mod.appendTextAtoms(allocator, atoms, run.text, text.font, text.link_color, text.font_size, run.url, run.strikethrough),
            .text => try atoms_mod.appendTextAtoms(allocator, atoms, run.text, text.font, text.color, text.font_size, null, run.strikethrough),
        }
    }
}

fn appendPlainTextAtoms(
    allocator: std.mem.Allocator,
    atoms: *std.ArrayList(atoms_mod.Atom),
    content: []const u8,
    line_start: usize,
    line_end: usize,
    font: scene.FontFace,
    plain_color: scene.Color,
    font_size: f32,
    spans: []const highlight.Span,
) !void {
    if (spans.len == 0) {
        try atoms_mod.appendTextAtoms(allocator, atoms, content[line_start..line_end], font, plain_color, font_size, null, false);
        return;
    }
    var pos = line_start;
    while (pos < line_end) {
        var next = highlight.nextBoundary(spans, pos, line_end);
        if (next <= pos) next = @min(pos + 1, line_end);
        const color = highlight.colorAt(spans, pos, next) orelse plain_color;
        try atoms_mod.appendTextAtoms(allocator, atoms, content[pos..next], font, color, font_size, null, false);
        pos = next;
    }
}

fn appendAtomLines(
    allocator: std.mem.Allocator,
    item: *scene.TextItem,
    frame_y: f32,
    first_baseline: f32,
    width: f32,
    atoms: []const atoms_mod.Atom,
    text: TextPaint,
    line_height: f32,
    wrap: bool,
    preserve_leading_space: bool,
) !void {
    var baseline = first_baseline;
    var line = scene.TextLine{ .baseline_y = baseline, .line_height = line_height };
    errdefer line.deinit(allocator);
    if (atoms.len == 0) {
        try item.lines.append(allocator, line);
        return;
    }
    var cursor = wrap_layout.Cursor{ .preserve_leading_space = preserve_leading_space };
    var has_content = false;
    for (atoms, 0..) |atom, index| {
        const measured = wrap_layout.Atom{
            .width = atom.width,
            .advance = atoms_mod.advance(atoms, index, text.emoji_spacing, text.inline_math_spacing),
            .is_space = atom.is_space,
        };
        switch (cursor.next(measured, width, wrap)) {
            .skip => continue,
            .break_then_draw => {
                try item.lines.append(allocator, line);
                line = scene.TextLine{ .baseline_y = baseline + line_height, .line_height = line_height };
                baseline += line_height;
                cursor = .{ .preserve_leading_space = preserve_leading_space };
                has_content = false;
            },
            .draw => {},
        }
        switch (atom.kind) {
            .glyphs => try line.spans.append(allocator, .{ .glyphs = .{
                .x = cursor.offset,
                .text = try allocator.dupe(u8, atom.text),
                .font = atom.font,
                .font_size = atom.font_size,
                .color = atom.color,
                .link_url = if (atom.link_url) |url| try allocator.dupe(u8, url) else null,
                .strikethrough = atom.strikethrough,
            } }),
            .resource => if (atom.resource_id) |resource_id| try line.spans.append(allocator, .{ .resource = .{
                .x = cursor.offset,
                .y = baseline - atom.height * 0.8 - frame_y,
                .width = atom.width,
                .height = atom.height,
                .resource_id = resource_id,
                .tint = atom.tint,
            } }),
        }
        has_content = true;
        cursor.advance(measured.advance);
    }
    if (has_content or item.lines.items.len == 0) try item.lines.append(allocator, line) else line.deinit(allocator);
}

fn toMeasuredAtoms(allocator: std.mem.Allocator, atoms: []const atoms_mod.Atom, text: TextPaint) ![]wrap_layout.Atom {
    const measured = try allocator.alloc(wrap_layout.Atom, atoms.len);
    errdefer allocator.free(measured);
    for (atoms, 0..) |atom, index| {
        measured[index] = .{
            .width = atom.width,
            .advance = atoms_mod.advance(atoms, index, text.emoji_spacing, text.inline_math_spacing),
            .is_space = atom.is_space,
        };
    }
    return measured;
}
