const std = @import("std");
const render = @import("render");
const resources = @import("resources.zig");

const css_line_box_baseline_fraction: f64 = 0.875;

pub const css =
    \\:root { color-scheme: light dark; --ss-canvas: #e8edf3; }
    \\* { box-sizing: border-box; }
    \\html, body { margin: 0; min-height: 100%; background: var(--ss-canvas); }
    \\body { display: flex; flex-direction: column; align-items: center; gap: 24pt; padding: 24pt; }
    \\.ss-page { position: relative; flex: none; overflow: hidden; background: white; box-shadow: 0 2pt 12pt rgb(15 23 42 / 18%); }
    \\.ss-item { position: absolute; transform-origin: 0 0; }
    \\.ss-semantic { display: contents; margin: 0; padding: 0; }
    \\.ss-text { white-space: pre; }
    \\.ss-text-run { position: absolute; white-space: pre; font-kerning: none; }
    \\.ss-text-cluster { position: absolute; top: 0; white-space: pre; }
    \\.ss-line { height: 0; border-top-style: solid; }
    \\.ss-image { display: block; object-fit: fill; }
    \\.ss-math { display: flex; align-items: center; justify-content: center; }
    \\.ss-math math { margin: 0; padding: 0; }
    \\.ss-pdf { overflow: hidden; }
    \\.ss-pdf canvas, .ss-pdf .textLayer, .ss-pdf .annotationLayer { position: absolute; inset: 0; width: 100%; height: 100%; }
    \\.ss-pdf .textLayer { overflow: hidden; line-height: 1; opacity: 1; }
    \\.ss-pdf .textLayer span { position: absolute; color: transparent; white-space: pre; transform-origin: 0 0; }
    \\.ss-link { position: absolute; display: block; }
    \\.ss-destination { position: absolute; width: 0; height: 0; }
    \\@media print { body { gap: 0; padding: 0; background: transparent; } .ss-page { box-shadow: none; break-after: page; } }
;

pub fn styleSheet(allocator: std.mem.Allocator, ir: *const render.Ir, assets: *const resources.Set) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, css);
    var emitted = std.StringHashMap(void).init(allocator);
    defer {
        var keys = emitted.keyIterator();
        while (keys.next()) |key| allocator.free(key.*);
        emitted.deinit();
    }
    for (ir.pages) |page| {
        for (page.items.items) |item| {
            if (item != .text) continue;
            const value = item.text;
            for (value.layout.runs) |run| {
                const font_resource = run.font_resource orelse continue;
                const path = assets.fontPath(font_resource, run.font_index) orelse return error.MissingHtmlResource;
                const key = try std.fmt.allocPrint(allocator, "{s}:{d}:{s}:{s}", .{ path, value.font_weight, fontStyle(value.font_style), fontStretch(value.font_stretch) });
                if (emitted.contains(key)) {
                    allocator.free(key);
                    continue;
                }
                try emitted.put(key, {});
                try out.appendSlice(allocator, "@font-face { font-family: '");
                try appendFontFamily(allocator, &out, path);
                try out.appendSlice(allocator, "'; src: url('");
                try appendCssUrl(allocator, &out, path);
                try appendFormat(allocator, &out, "'); font-weight:{d}; font-style:{s}; font-stretch:{s}; ascent-override:80%; descent-override:20%; line-gap-override:0%; }}\n", .{
                    value.font_weight, fontStyle(value.font_style), fontStretch(value.font_stretch),
                });
            }
        }
    }
    return try out.toOwnedSlice(allocator);
}

pub fn generate(allocator: std.mem.Allocator, ir: *const render.Ir, assets: *const resources.Set) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\">" ++
        "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">" ++
        "<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; img-src 'self' data:; style-src 'self' 'unsafe-inline'; script-src 'self'; worker-src 'self'; connect-src 'self'; font-src 'self'\">" ++
        "<title>ss document</title><link rel=\"stylesheet\" href=\"ss.css\"></head><body><main class=\"ss-document\">");
    for (ir.pages) |*page| try appendPage(allocator, &out, ir, page, assets);
    try out.appendSlice(allocator, "</main>");
    if (assets.has_pdf) try out.appendSlice(allocator, "<script type=\"module\" src=\"ss.js\"></script>");
    try out.appendSlice(allocator, "</body></html>\n");
    return try out.toOwnedSlice(allocator);
}

fn appendPage(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    ir: *const render.Ir,
    page: *const render.Page,
    assets: *const resources.Set,
) !void {
    try appendFormat(allocator, out, "<section class=\"ss-page\" data-ss-page-id=\"{d}\" data-ss-page-index=\"{d}\" style=\"width:{d:.6}pt;height:{d:.6}pt\">", .{
        page.page_id, page.index + 1, normalized(page.width), normalized(page.height),
    });
    for (page.destinations.items) |destination| {
        try out.appendSlice(allocator, "<span class=\"ss-destination\" id=\"");
        try appendAttribute(allocator, out, destination.name);
        try appendFormat(allocator, out, "\" style=\"left:{d:.6}pt;top:{d:.6}pt\"></span>", .{ normalized(destination.point.x), normalized(destination.point.y) });
    }
    for (page.items.items) |item| if (item.header().semantic_id == null) try appendItem(allocator, out, ir, item, assets);
    for (page.reading_order) |semantic_id| {
        const semantic = ir.semantics.find(semantic_id) orelse return error.InvalidSemantics;
        try appendSemanticStart(allocator, out, semantic);
        for (page.items.items) |item| {
            if (item.header().semantic_id == semantic_id) try appendItem(allocator, out, ir, item, assets);
        }
        try appendSemanticEnd(allocator, out, semantic);
    }
    for (page.links.items) |link| {
        try out.appendSlice(allocator, "<a class=\"ss-link\" href=\"");
        if (link.kind == .destination) try out.append(allocator, '#');
        try appendAttribute(allocator, out, link.target);
        try appendRectStyle(allocator, out, link.rect);
        try out.appendSlice(allocator, " aria-label=\"Link\"></a>");
    }
    try out.appendSlice(allocator, "</section>");
}

fn appendSemanticStart(allocator: std.mem.Allocator, out: *std.ArrayList(u8), semantic: *const render.SemanticNode) !void {
    const tag = semanticTag(semantic.*);
    try appendFormat(allocator, out, "<{s} class=\"ss-semantic\" data-ss-semantic-id=\"{d}\"", .{ tag, semantic.id });
    if (semantic.alt_text) |alt| {
        try out.appendSlice(allocator, " aria-label=\"");
        try appendAttribute(allocator, out, alt);
        try out.append(allocator, '"');
    }
    try out.append(allocator, '>');
    if (semantic.role == .code) try out.appendSlice(allocator, "<code>");
}

fn appendSemanticEnd(allocator: std.mem.Allocator, out: *std.ArrayList(u8), semantic: *const render.SemanticNode) !void {
    if (semantic.role == .code) try out.appendSlice(allocator, "</code>");
    try appendFormat(allocator, out, "</{s}>", .{semanticTag(semantic.*)});
}

fn semanticTag(semantic: render.SemanticNode) []const u8 {
    return switch (semantic.role) {
        .document => "main",
        .page => "section",
        .heading => switch (semantic.heading_level orelse 2) {
            1 => "h1",
            2 => "h2",
            3 => "h3",
            4 => "h4",
            5 => "h5",
            else => "h6",
        },
        .paragraph => "p",
        .list => "ul",
        .list_item => "li",
        .table => "table",
        .table_row => "tr",
        .table_header => "th",
        .table_cell => "td",
        .figure => "figure",
        .caption => "figcaption",
        .code => "pre",
        .math, .link, .group, .decoration => "div",
    };
}

fn appendItem(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    ir: *const render.Ir,
    item: render.Item,
    assets: *const resources.Set,
) !void {
    const header = item.header();
    switch (item) {
        .fill_rect => |value| {
            try appendItemStart(allocator, out, "div", "ss-box", header);
            try appendRectStyle(allocator, out, value.rect);
            try appendFormat(allocator, out, "background:{s}\"></div>", .{color(value.color)});
        },
        .rounded_rect => |value| {
            try appendItemStart(allocator, out, "div", "ss-box", header);
            try appendRectStyle(allocator, out, value.rect);
            if (value.fill) |fill| try appendFormat(allocator, out, "background:{s};", .{color(fill)});
            if (value.stroke) |stroke| try appendFormat(allocator, out, "border:{d:.6}pt solid {s};", .{ normalized(value.line_width), color(stroke) });
            try appendFormat(allocator, out, "border-radius:{d:.6}pt\"></div>", .{normalized(value.radius)});
        },
        .stroke_line => |value| {
            const dx = value.end.x - value.start.x;
            const dy = value.end.y - value.start.y;
            try appendItemStart(allocator, out, "div", "ss-line", header);
            try appendFormat(allocator, out, "left:{d:.6}pt;top:{d:.6}pt;width:{d:.6}pt;border-top-width:{d:.6}pt;border-top-color:{s};transform:rotate({d:.9}rad);", .{
                normalized(value.start.x), normalized(value.start.y), normalized(@sqrt(dx * dx + dy * dy)), normalized(value.line_width), color(value.color), normalized(std.math.atan2(dy, dx)),
            });
            if (value.dash_on > 0 and value.dash_off > 0) try out.appendSlice(allocator, "border-top-style:dashed;");
            try out.appendSlice(allocator, "\"></div>");
        },
        .text => |value| {
            try appendItemStart(allocator, out, "span", "ss-text", header);
            try appendFormat(allocator, out, "left:{d:.6}pt;top:{d:.6}pt;width:{d:.6}pt;height:{d:.6}pt\">", .{
                normalized(value.x), normalized(value.y), normalized(value.width), normalized(value.layout.logical_bounds.height),
            });
            for (value.layout.runs, 0..) |run, run_index| {
                _ = lineForRun(&value.layout, run_index) orelse return error.InvalidTextLayout;
                const run_top = run.baseline_y - value.font_size * css_line_box_baseline_fraction;
                try appendFormat(allocator, out, "<span class=\"ss-text-run\" style=\"left:{d:.6}pt;top:{d:.6}pt;font-family:", .{
                    normalized(run.x), normalized(run_top),
                });
                if (run.font_resource) |font_resource| {
                    const path = assets.fontPath(font_resource, run.font_index) orelse return error.MissingHtmlResource;
                    try out.append(allocator, '\'');
                    try appendFontFamily(allocator, out, path);
                    try out.append(allocator, '\'');
                } else {
                    try appendCssString(allocator, out, run.font_family);
                }
                try appendFormat(allocator, out, ";width:{d:.6}pt;height:{d:.6}pt;font-size:{d:.6}pt;font-weight:{d};font-style:{s};font-stretch:{s};line-height:{d:.6}pt;color:{s}\">", .{
                    normalized(run.advance),
                    normalized(value.font_size),
                    normalized(value.font_size),
                    value.font_weight,
                    fontStyle(value.font_style),
                    fontStretch(value.font_stretch),
                    normalized(value.font_size),
                    color(value.color),
                });
                const clusters = value.layout.clusters[run.cluster_range.start..run.cluster_range.end];
                if (clusters.len == 0) {
                    try appendText(allocator, out, value.layout.source_text[run.source.start..run.source.end]);
                } else {
                    for (clusters) |cluster| {
                        try appendFormat(allocator, out, "<span class=\"ss-text-cluster\" style=\"left:{d:.6}pt;width:{d:.6}pt\">", .{
                            normalized(cluster.x), normalized(cluster.advance),
                        });
                        try appendText(allocator, out, value.layout.source_text[cluster.source.start..cluster.source.end]);
                        try out.appendSlice(allocator, "</span>");
                    }
                }
                try out.appendSlice(allocator, "</span>");
            }
            try out.appendSlice(allocator, "</span>");
        },
        .raster => |value| {
            const path = assets.path(.raster, value.resource) orelse return error.MissingHtmlResource;
            try appendItemStart(allocator, out, "img", "ss-image", header);
            try appendRectStyle(allocator, out, value.rect);
            try out.appendSlice(allocator, "\" alt=\"\" src=\"");
            try appendAttribute(allocator, out, path);
            try out.appendSlice(allocator, "\">");
        },
        .svg => |value| {
            const path = assets.path(.svg, value.resource) orelse return error.MissingHtmlResource;
            if (value.tint) |tint| {
                try appendItemStart(allocator, out, "span", "ss-image", header);
                try appendRectStyle(allocator, out, value.rect);
                try appendFormat(allocator, out, "background:{s};mask:url('", .{color(tint)});
                try appendCssUrl(allocator, out, path);
                try out.appendSlice(allocator, "') center/100% 100% no-repeat\"></span>");
            } else {
                try appendItemStart(allocator, out, "img", "ss-image", header);
                try appendRectStyle(allocator, out, value.rect);
                try out.appendSlice(allocator, "\" alt=\"\" src=\"");
                try appendAttribute(allocator, out, path);
                try out.appendSlice(allocator, "\">");
            }
        },
        .math => |value| {
            const tree = ir.math.find(value.tree) orelse return error.InvalidMathTree;
            if (tree.input_kind == .raw) return error.UnsupportedMathSyntax;
            try appendItemStart(allocator, out, "span", "ss-math", header);
            try appendRectStyle(allocator, out, value.rect);
            try appendFormat(allocator, out, "font-size:{d:.6}pt\"><math xmlns=\"http://www.w3.org/1998/Math/MathML\" display=\"block\">", .{
                normalized(@max(value.rect.height * 0.65, 1)),
            });
            try appendMathNode(allocator, out, tree, tree.root, 0);
            try out.appendSlice(allocator, "</math></span>");
        },
        .pdf_page => |value| {
            const path = assets.path(.pdf, value.resource) orelse return error.MissingHtmlResource;
            try appendItemStart(allocator, out, "div", "ss-pdf", header);
            try appendRectStyle(allocator, out, value.rect);
            try out.appendSlice(allocator, "\" data-pdf-src=\"");
            try appendAttribute(allocator, out, path);
            try appendFormat(allocator, out, "\" data-page=\"{d}\" data-box=\"{s}\"><canvas></canvas><div class=\"textLayer\"></div><div class=\"annotationLayer\"></div></div>", .{
                value.page_index + 1, @tagName(value.box),
            });
        },
    }
}

fn appendMathNode(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    tree: *const render.MathTree,
    node_id: render.MathNodeId,
    depth: usize,
) !void {
    if (depth > tree.nodes.len) return error.InvalidMathTree;
    const node = tree.find(node_id) orelse return error.InvalidMathTree;
    const tag: []const u8 = switch (node.kind) {
        .row => "mrow",
        .identifier => "mi",
        .number => "mn",
        .operator => "mo",
        .text => "mtext",
        .space => "mspace",
        .fraction => "mfrac",
        .square_root => "msqrt",
        .superscript => "msup",
        .subscript => "msub",
        .subscript_superscript => "msubsup",
        .raw_tex => return error.UnsupportedMathSyntax,
    };
    try appendFormat(allocator, out, "<{s}", .{tag});
    if (node.kind == .space) try out.appendSlice(allocator, " width=\"0.25em\"");
    try out.append(allocator, '>');
    if (node.text) |value| try appendText(allocator, out, value);
    for (node.children) |child| try appendMathNode(allocator, out, tree, child, depth + 1);
    try appendFormat(allocator, out, "</{s}>", .{tag});
}

fn appendItemStart(allocator: std.mem.Allocator, out: *std.ArrayList(u8), tag: []const u8, class: []const u8, header: render.ItemHeader) !void {
    try appendFormat(allocator, out, "<{s} class=\"ss-item {s}\" data-ss-item-id=\"{d}\"", .{ tag, class, header.item_id });
    if (header.node_id) |node_id| try appendFormat(allocator, out, " data-ss-node-id=\"{d}\"", .{node_id});
    if (header.semantic_id) |semantic_id| {
        try appendFormat(allocator, out, " data-ss-semantic-id=\"{d}\"", .{semantic_id});
    } else {
        try out.appendSlice(allocator, " aria-hidden=\"true\"");
    }
    try appendFormat(allocator, out, " style=\"z-index:{d};opacity:{d:.6};", .{ header.paint_index, normalized(header.opacity) });
}

fn appendRectStyle(allocator: std.mem.Allocator, out: *std.ArrayList(u8), rect: render.Rect) !void {
    try appendFormat(allocator, out, "left:{d:.6}pt;top:{d:.6}pt;width:{d:.6}pt;height:{d:.6}pt;", .{
        normalized(rect.x), normalized(rect.y), normalized(rect.width), normalized(rect.height),
    });
}

fn appendText(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: []const u8) !void {
    for (value) |byte| switch (byte) {
        '&' => try out.appendSlice(allocator, "&amp;"),
        '<' => try out.appendSlice(allocator, "&lt;"),
        '>' => try out.appendSlice(allocator, "&gt;"),
        else => try out.append(allocator, byte),
    };
}

fn appendAttribute(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: []const u8) !void {
    for (value) |byte| switch (byte) {
        '&' => try out.appendSlice(allocator, "&amp;"),
        '<' => try out.appendSlice(allocator, "&lt;"),
        '>' => try out.appendSlice(allocator, "&gt;"),
        '"' => try out.appendSlice(allocator, "&quot;"),
        '\'' => try out.appendSlice(allocator, "&#39;"),
        else => try out.append(allocator, byte),
    };
}

fn appendCssString(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: []const u8) !void {
    try out.append(allocator, '\'');
    for (value) |byte| switch (byte) {
        '\'', '\\' => {
            try out.append(allocator, '\\');
            try out.append(allocator, byte);
        },
        '\n', '\r', '\x0c' => try out.append(allocator, ' '),
        else => try out.append(allocator, byte),
    };
    try out.append(allocator, '\'');
}

fn appendCssUrl(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: []const u8) !void {
    for (value) |byte| switch (byte) {
        '\'', '"', '(', ')', '\\' => return error.InvalidHtmlResourceName,
        else => try out.append(allocator, byte),
    };
}

fn appendFontFamily(allocator: std.mem.Allocator, out: *std.ArrayList(u8), relative_path: []const u8) !void {
    const base = std.fs.path.stem(relative_path);
    if (base.len < 16) return error.InvalidHtmlResourceName;
    try out.appendSlice(allocator, "ss-font-");
    try out.appendSlice(allocator, base[0..16]);
}

fn lineForRun(layout: *const render.TextLayout, run_index: usize) ?render.TextLine {
    for (layout.lines) |line| {
        if (run_index >= line.run_range.start and run_index < line.run_range.end) return line;
    }
    return null;
}

fn appendFormat(allocator: std.mem.Allocator, out: *std.ArrayList(u8), comptime format: []const u8, args: anytype) !void {
    const text = try std.fmt.allocPrint(allocator, format, args);
    defer allocator.free(text);
    try out.appendSlice(allocator, text);
}

fn normalized(value: f64) f64 {
    return if (value == 0) 0 else value;
}

fn color(value: anytype) []const u8 {
    const Palette = struct {
        var buffers: [8][64]u8 = undefined;
        var next: usize = 0;
    };
    const slot = Palette.next;
    Palette.next = (Palette.next + 1) % Palette.buffers.len;
    return std.fmt.bufPrint(&Palette.buffers[slot], "rgb({d:.6}% {d:.6}% {d:.6}%)", .{
        @as(f64, value.r) * 100, @as(f64, value.g) * 100, @as(f64, value.b) * 100,
    }) catch "rgb(0% 0% 0%)";
}

fn fontStyle(value: anytype) []const u8 {
    return switch (value) {
        .normal => "normal",
        .italic => "italic",
        .oblique => "oblique",
    };
}

fn fontStretch(value: anytype) []const u8 {
    return switch (value) {
        .ultra_condensed => "ultra-condensed",
        .extra_condensed => "extra-condensed",
        .condensed => "condensed",
        .semi_condensed => "semi-condensed",
        .normal => "normal",
        .semi_expanded => "semi-expanded",
        .expanded => "expanded",
        .extra_expanded => "extra-expanded",
        .ultra_expanded => "ultra-expanded",
    };
}
