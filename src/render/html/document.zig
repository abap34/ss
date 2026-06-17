const std = @import("std");
const scene = @import("../scene.zig");

pub fn appendDocument(allocator: std.mem.Allocator, out: *std.ArrayList(u8), document: *const scene.Document) !void {
    try out.appendSlice(allocator,
        \\<!doctype html>
        \\<html lang="en">
        \\<head>
        \\<meta charset="utf-8">
        \\<meta name="viewport" content="width=device-width, initial-scale=1">
        \\<title>ss render</title>
        \\<style>
        \\:root { color-scheme: light dark; }
        \\* { box-sizing: border-box; }
        \\body {
        \\  margin: 0;
        \\  background: #f3f4f6;
        \\  color: #111827;
        \\  font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
        \\}
        \\.deck {
        \\  display: grid;
        \\  gap: 32px;
        \\  justify-items: center;
        \\  padding: 32px 16px;
        \\}
        \\.page {
        \\  background: #ffffff;
        \\  box-shadow: 0 10px 28px rgb(0 0 0 / 18%);
        \\  max-width: 100%;
        \\  overflow: hidden;
        \\}
        \\.page > svg {
        \\  display: block;
        \\  height: auto;
        \\  max-width: 100%;
        \\}
        \\text { dominant-baseline: alphabetic; white-space: pre; }
        \\image { pointer-events: none; }
        \\@media (prefers-color-scheme: dark) {
        \\  body { background: #111827; color: #f9fafb; }
        \\}
        \\@media print {
        \\  body { background: #ffffff; }
        \\  .deck { display: block; padding: 0; }
        \\  .page { box-shadow: none; break-after: page; margin: 0 auto; }
        \\}
        \\</style>
        \\</head>
        \\<body>
        \\<main class="deck">
        \\
    );

    for (document.pages.items) |page| {
        try appendPage(allocator, out, document, page);
    }

    try out.appendSlice(allocator,
        \\</main>
        \\</body>
        \\</html>
        \\
    );
}

fn appendPage(allocator: std.mem.Allocator, out: *std.ArrayList(u8), document: *const scene.Document, page: scene.Page) !void {
    try out.appendSlice(allocator, "<section class=\"page\" aria-label=\"");
    try appendAttributeEscaped(allocator, out, page.label);
    try out.appendSlice(allocator, "\" style=\"width:");
    try appendFloat(allocator, out, page.frame.width);
    try out.appendSlice(allocator, "px\">\n<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 ");
    try appendFloat(allocator, out, page.frame.width);
    try out.append(allocator, ' ');
    try appendFloat(allocator, out, page.frame.height);
    try out.appendSlice(allocator, "\" width=\"");
    try appendFloat(allocator, out, page.frame.width);
    try out.appendSlice(allocator, "\" height=\"");
    try appendFloat(allocator, out, page.frame.height);
    try out.appendSlice(allocator, "\">\n");

    for (page.items.items, 0..) |item, item_index| {
        switch (item) {
            .shape => |shape| try appendShapeItem(allocator, out, shape),
            .text => |text| try appendTextItem(allocator, out, document, page.index, item_index, text),
            .resource => |resource| try appendResourceItem(allocator, out, document, page.index, item_index, resource),
        }
    }

    try out.appendSlice(allocator, "</svg>\n</section>\n");
}

fn appendShapeItem(allocator: std.mem.Allocator, out: *std.ArrayList(u8), item: scene.ShapeItem) !void {
    try out.appendSlice(allocator, "<rect x=\"");
    try appendFloat(allocator, out, item.frame.x);
    try out.appendSlice(allocator, "\" y=\"");
    try appendFloat(allocator, out, item.frame.y);
    try out.appendSlice(allocator, "\" width=\"");
    try appendFloat(allocator, out, @max(0, item.frame.width));
    try out.appendSlice(allocator, "\" height=\"");
    try appendFloat(allocator, out, @max(0, item.frame.height));
    try out.appendSlice(allocator, "\" rx=\"");
    try appendFloat(allocator, out, @max(0, item.radius));
    try out.appendSlice(allocator, "\" ry=\"");
    try appendFloat(allocator, out, @max(0, item.radius));
    try out.appendSlice(allocator, "\" fill=\"");
    try appendOptionalColorValue(allocator, out, item.fill, "none");
    try out.appendSlice(allocator, "\" stroke=\"");
    try appendOptionalColorValue(allocator, out, item.stroke, "none");
    try out.appendSlice(allocator, "\" stroke-width=\"");
    try appendFloat(allocator, out, @max(0, item.line_width));
    try out.append(allocator, '"');
    if (item.dash) |dash| {
        try out.appendSlice(allocator, " stroke-dasharray=\"");
        try appendFloat(allocator, out, dash.on);
        try out.append(allocator, ' ');
        try appendFloat(allocator, out, dash.off);
        try out.append(allocator, '"');
    }
    try out.appendSlice(allocator, "/>\n");
}

fn appendTextItem(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    document: *const scene.Document,
    page_index: usize,
    item_index: usize,
    item: scene.TextItem,
) !void {
    if (item.clip) try appendClipPath(allocator, out, page_index, item_index, item.frame);
    try out.appendSlice(allocator, "<g");
    if (item.clip) {
        try out.appendSlice(allocator, " clip-path=\"url(#clip-");
        try appendInt(allocator, out, page_index);
        try out.append(allocator, '-');
        try appendInt(allocator, out, item_index);
        try out.appendSlice(allocator, ")\"");
    }
    try out.appendSlice(allocator, ">\n");

    for (item.lines.items) |line| {
        for (line.spans.items) |span| {
            switch (span) {
                .glyphs => |glyphs| try appendGlyphSpan(allocator, out, item, line, glyphs),
                .resource => |resource| try appendInlineResourceSpan(allocator, out, document, item, resource),
            }
        }
    }

    try out.appendSlice(allocator, "</g>\n");
}

fn appendGlyphSpan(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    item: scene.TextItem,
    line: scene.TextLine,
    span: scene.GlyphSpan,
) !void {
    if (span.link_url) |url| {
        try out.appendSlice(allocator, "<a href=\"");
        try appendAttributeEscaped(allocator, out, url);
        try out.appendSlice(allocator, "\">");
    }
    try out.appendSlice(allocator, "<text x=\"");
    try appendFloat(allocator, out, item.frame.x + span.x);
    try out.appendSlice(allocator, "\" y=\"");
    try appendFloat(allocator, out, line.baseline_y);
    try out.appendSlice(allocator, "\" fill=\"");
    try appendColorValue(allocator, out, span.color);
    try out.appendSlice(allocator, "\" font-family=\"");
    try appendAttributeEscaped(allocator, out, span.font.family);
    try out.appendSlice(allocator, "\" font-size=\"");
    try appendFloat(allocator, out, @max(1, span.font_size));
    try out.appendSlice(allocator, "\" font-weight=\"");
    try appendInt(allocator, out, span.font.weight);
    try out.appendSlice(allocator, "\" font-style=\"");
    try appendAttributeEscaped(allocator, out, @tagName(span.font.style));
    try out.append(allocator, '"');
    if (span.strikethrough) try out.appendSlice(allocator, " text-decoration=\"line-through\"");
    try out.append(allocator, '>');
    try appendTextEscaped(allocator, out, span.text);
    try out.appendSlice(allocator, "</text>");
    if (span.link_url != null) try out.appendSlice(allocator, "</a>");
    try out.append(allocator, '\n');
}

fn appendInlineResourceSpan(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    document: *const scene.Document,
    item: scene.TextItem,
    span: scene.InlineResourceSpan,
) !void {
    const resource = document.resourceById(span.resource_id) orelse return;
    if (span.link_url) |url| {
        try out.appendSlice(allocator, "<a href=\"");
        try appendAttributeEscaped(allocator, out, url);
        try out.appendSlice(allocator, "\">");
    }
    try appendImageElement(allocator, out, resource, .{
        .x = item.frame.x + span.x,
        .y = item.frame.y + span.y,
        .width = span.width,
        .height = span.height,
    }, null);
    if (span.link_url != null) try out.appendSlice(allocator, "</a>");
}

fn appendResourceItem(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    document: *const scene.Document,
    page_index: usize,
    item_index: usize,
    item: scene.ResourceItem,
) !void {
    const resource = document.resourceById(item.resource_id) orelse return;
    if (item.clip) try appendClipPath(allocator, out, page_index, item_index, item.frame);
    try appendImageElement(allocator, out, resource, item.frame, if (item.clip) .{
        .page_index = page_index,
        .item_index = item_index,
    } else null);
}

const ClipRef = struct {
    page_index: usize,
    item_index: usize,
};

fn appendImageElement(allocator: std.mem.Allocator, out: *std.ArrayList(u8), resource: *const scene.Resource, frame: scene.Frame, clip: ?ClipRef) !void {
    const href = try resourceHref(allocator, resource.path);
    defer allocator.free(href);
    try out.appendSlice(allocator, "<image href=\"");
    try appendAttributeEscaped(allocator, out, href);
    try out.appendSlice(allocator, "\" x=\"");
    try appendFloat(allocator, out, frame.x);
    try out.appendSlice(allocator, "\" y=\"");
    try appendFloat(allocator, out, frame.y);
    try out.appendSlice(allocator, "\" width=\"");
    try appendFloat(allocator, out, @max(1, frame.width));
    try out.appendSlice(allocator, "\" height=\"");
    try appendFloat(allocator, out, @max(1, frame.height));
    try out.appendSlice(allocator, "\" preserveAspectRatio=\"xMidYMid meet\"");
    if (clip) |clip_ref| {
        try out.appendSlice(allocator, " clip-path=\"url(#clip-");
        try appendInt(allocator, out, clip_ref.page_index);
        try out.append(allocator, '-');
        try appendInt(allocator, out, clip_ref.item_index);
        try out.appendSlice(allocator, ")\"");
    }
    try out.appendSlice(allocator, "/>\n");
}

fn appendClipPath(allocator: std.mem.Allocator, out: *std.ArrayList(u8), page_index: usize, item_index: usize, frame: scene.Frame) !void {
    try out.appendSlice(allocator, "<defs><clipPath id=\"clip-");
    try appendInt(allocator, out, page_index);
    try out.append(allocator, '-');
    try appendInt(allocator, out, item_index);
    try out.appendSlice(allocator, "\"><rect x=\"");
    try appendFloat(allocator, out, frame.x);
    try out.appendSlice(allocator, "\" y=\"");
    try appendFloat(allocator, out, frame.y);
    try out.appendSlice(allocator, "\" width=\"");
    try appendFloat(allocator, out, @max(1, frame.width));
    try out.appendSlice(allocator, "\" height=\"");
    try appendFloat(allocator, out, @max(1, frame.height));
    try out.appendSlice(allocator, "\"/></clipPath></defs>\n");
}

fn resourceHref(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const absolute = if (std.fs.path.isAbsolute(path))
        try allocator.dupe(u8, path)
    else
        try std.fs.path.resolve(allocator, &.{path});
    defer allocator.free(absolute);

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "file://");
    for (absolute) |byte| {
        const normalized = if (byte == '\\') '/' else byte;
        try appendUriByte(allocator, &out, normalized);
    }
    return out.toOwnedSlice(allocator);
}

fn appendUriByte(allocator: std.mem.Allocator, out: *std.ArrayList(u8), byte: u8) !void {
    if (std.ascii.isAlphanumeric(byte) or byte == '/' or byte == ':' or byte == '-' or byte == '_' or byte == '.' or byte == '~') {
        try out.append(allocator, byte);
        return;
    }
    const hex = "0123456789ABCDEF";
    try out.append(allocator, '%');
    try out.append(allocator, hex[byte >> 4]);
    try out.append(allocator, hex[byte & 0x0f]);
}

fn appendOptionalColorValue(allocator: std.mem.Allocator, out: *std.ArrayList(u8), maybe: ?scene.Color, fallback: []const u8) !void {
    const color = maybe orelse {
        try out.appendSlice(allocator, fallback);
        return;
    };
    try appendColorValue(allocator, out, color);
}

fn appendColorValue(allocator: std.mem.Allocator, out: *std.ArrayList(u8), color: scene.Color) !void {
    const r = clampColor(color.r);
    const g = clampColor(color.g);
    const b = clampColor(color.b);
    const text = try std.fmt.allocPrint(allocator, "rgb({d} {d} {d})", .{ r, g, b });
    defer allocator.free(text);
    try out.appendSlice(allocator, text);
}

fn clampColor(value: f32) u8 {
    return @intFromFloat(@round(@min(@max(value, 0), 1) * 255));
}

fn appendTextEscaped(allocator: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    for (text) |byte| {
        switch (byte) {
            '&' => try out.appendSlice(allocator, "&amp;"),
            '<' => try out.appendSlice(allocator, "&lt;"),
            '>' => try out.appendSlice(allocator, "&gt;"),
            else => try out.append(allocator, byte),
        }
    }
}

fn appendAttributeEscaped(allocator: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    for (text) |byte| {
        switch (byte) {
            '&' => try out.appendSlice(allocator, "&amp;"),
            '<' => try out.appendSlice(allocator, "&lt;"),
            '>' => try out.appendSlice(allocator, "&gt;"),
            '"' => try out.appendSlice(allocator, "&quot;"),
            '\'' => try out.appendSlice(allocator, "&#39;"),
            else => try out.append(allocator, byte),
        }
    }
}

fn appendInt(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: anytype) !void {
    const text = try std.fmt.allocPrint(allocator, "{d}", .{value});
    defer allocator.free(text);
    try out.appendSlice(allocator, text);
}

fn appendFloat(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: f32) !void {
    const text = try std.fmt.allocPrint(allocator, "{d:.4}", .{value});
    defer allocator.free(text);
    try out.appendSlice(allocator, text);
}
