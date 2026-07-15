const std = @import("std");
const render = @import("render");
const resources = @import("resources.zig");

const document_css =
    \\:root { color-scheme: light dark; --ss-canvas: #e8edf3; }
    \\* { box-sizing: border-box; }
    \\html, body { margin: 0; min-height: 100%; background: var(--ss-canvas); }
    \\body { display: flex; flex-direction: column; align-items: center; gap: 24pt; padding: 24pt; }
;

pub const fragment_css =
    \\* { box-sizing: border-box; }
    \\.ss-page { position: relative; flex: none; overflow: hidden; isolation: isolate; background: white; box-shadow: 0 2pt 12pt rgb(15 23 42 / 18%); }
    \\.ss-item { position: absolute; transform-origin: 0 0; }
    \\.ss-semantic-layer { position: absolute; width: 1px; height: 1px; padding: 0; margin: -1px; overflow: hidden; clip: rect(0, 0, 0, 0); clip-path: inset(50%); white-space: nowrap; border: 0; }
    \\.ss-text { white-space: pre; }
    \\.ss-text-run { position: absolute; white-space: pre; font-kerning: none; font-synthesis: none; }
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
;

const print_css =
    \\@media print { body { gap: 0; padding: 0; background: transparent; } .ss-page { box-shadow: none; break-after: page; } }
;

pub fn styleSheet(allocator: std.mem.Allocator, ir: *const render.Ir, assets: *const resources.Set, standalone: bool) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    if (standalone) try out.appendSlice(allocator, document_css);
    try out.appendSlice(allocator, fragment_css);
    if (standalone) try out.appendSlice(allocator, print_css);
    for (ir.fonts.instances) |font| {
        const path = assets.fontPath(font.resource, font.face_index) orelse return error.MissingHtmlResource;
        try out.appendSlice(allocator, "@font-face { font-family: '");
        try appendFontFamily(allocator, &out, font.id);
        try out.appendSlice(allocator, "'; src: url('");
        try appendCssUrl(allocator, &out, path);
        try appendFormat(allocator, &out, "'); font-weight:{d}; font-style:{s}; font-stretch:{s}; ascent-override:{d:.9}%; descent-override:{d:.9}%; line-gap-override:{d:.9}%; font-display:block; }}\n", .{
            font.weight,
            fontStyle(font.style),
            fontStretch(font.stretch),
            normalized(font.ascent_ratio * 100),
            normalized(font.descent_ratio * 100),
            normalized(font.line_gap_ratio * 100),
        });
    }
    return try out.toOwnedSlice(allocator);
}

pub fn generate(allocator: std.mem.Allocator, ir: *const render.Ir, assets: *const resources.Set) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\">" ++
        "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">" ++
        "<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; img-src 'self' data:; style-src 'self' 'unsafe-inline'; script-src 'self'; worker-src 'self'; connect-src 'self'; font-src 'self'\">" ++
        "<title>ss document</title><link rel=\"stylesheet\" href=\"ss.css\"></head><body>");
    const content = try fragment(allocator, ir, assets);
    defer allocator.free(content);
    try out.appendSlice(allocator, content);
    if (assets.has_pdf) try out.appendSlice(allocator, "<script type=\"module\" src=\"ss.js\"></script>");
    try out.appendSlice(allocator, "</body></html>\n");
    return try out.toOwnedSlice(allocator);
}

pub fn fragment(allocator: std.mem.Allocator, ir: *const render.Ir, assets: *const resources.Set) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "<main class=\"ss-document\">");
    for (ir.pages) |*page| try appendPage(allocator, &out, ir, page, assets);
    try out.appendSlice(allocator, "</main>");
    return try out.toOwnedSlice(allocator);
}

fn appendPage(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    ir: *const render.Ir,
    page: *const render.Page,
    assets: *const resources.Set,
) !void {
    try appendFormat(allocator, out, "<section class=\"ss-page\" data-ss-page-id=\"{d}\" data-ss-page-index=\"{d}\" aria-label=\"", .{
        page.page_id, page.index + 1,
    });
    try appendAttribute(allocator, out, page.name);
    try appendFormat(allocator, out, "\" style=\"width:{d:.6}pt;height:{d:.6}pt\">", .{ normalized(page.width), normalized(page.height) });
    for (page.destinations.items) |destination| {
        try out.appendSlice(allocator, "<span class=\"ss-destination\" id=\"");
        try appendAttribute(allocator, out, destination.name);
        try appendFormat(allocator, out, "\" style=\"left:{d:.6}pt;top:{d:.6}pt\"></span>", .{ normalized(destination.point.x), normalized(destination.point.y) });
    }
    for (page.items.items) |item| try appendItem(allocator, out, ir, item, assets);
    try out.appendSlice(allocator, "<div class=\"ss-semantic-layer\">");
    for (page.reading_order) |semantic_id| {
        try appendSemanticNode(allocator, out, &ir.semantics, semantic_id, 0);
    }
    try out.appendSlice(allocator, "</div>");
    for (page.links.items) |link| {
        try out.appendSlice(allocator, "<a class=\"ss-link\" href=\"");
        if (link.kind == .destination) try out.append(allocator, '#');
        try appendAttribute(allocator, out, link.target);
        try appendRectStyle(allocator, out, link.rect);
        try out.appendSlice(allocator, " aria-label=\"Link\"></a>");
    }
    try out.appendSlice(allocator, "</section>");
}

fn appendSemanticNode(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    tree: *const render.SemanticTree,
    semantic_id: render.SemanticId,
    depth: usize,
) !void {
    if (depth > tree.nodes.len) return error.InvalidSemantics;
    const semantic = tree.find(semantic_id) orelse return error.InvalidSemantics;
    const tag = semanticTag(semantic.*);
    try appendFormat(allocator, out, "<{s} data-ss-semantic-id=\"{d}\"", .{ tag, semantic.id });
    if (semantic.role == .list and semantic.list_ordered.? and semantic.list_start.? != 1) {
        try appendFormat(allocator, out, " start=\"{d}\"", .{semantic.list_start.?});
    }
    if (semantic.language) |language| {
        try out.appendSlice(allocator, " lang=\"");
        try appendAttribute(allocator, out, language);
        try out.append(allocator, '"');
    }
    if (semantic.role == .link) {
        try out.appendSlice(allocator, " href=\"");
        if (semantic.link_kind.? == .destination) try out.append(allocator, '#');
        try appendAttribute(allocator, out, semantic.link_target.?);
        try out.append(allocator, '"');
    }
    if (semantic.alt_text) |alt| {
        try out.appendSlice(allocator, " aria-label=\"");
        try appendAttribute(allocator, out, alt);
        try out.append(allocator, '"');
    }
    if (semantic.role == .math) try out.appendSlice(allocator, " role=\"math\"");
    try out.append(allocator, '>');
    if (semantic.role == .code) try out.appendSlice(allocator, "<code>");
    if (semantic.text) |value| try appendText(allocator, out, value);
    for (semantic.children) |child| try appendSemanticNode(allocator, out, tree, child, depth + 1);
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
        .list => if (semantic.list_ordered orelse false) "ol" else "ul",
        .list_item => "li",
        .table => "table",
        .table_row => "tr",
        .table_header => "th",
        .table_cell => "td",
        .figure => "figure",
        .caption => "figcaption",
        .code => "pre",
        .link => "a",
        .math, .text => "span",
        .group, .decoration => "div",
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
            try appendItemStart(allocator, out, "div", "ss-box", header, .{ .x = value.rect.x, .y = value.rect.y }, null);
            try appendRectStyle(allocator, out, value.rect);
            try appendFormat(allocator, out, "background:{s}\"></div>", .{color(value.color)});
        },
        .rounded_rect => |value| {
            try appendItemStart(allocator, out, "div", "ss-box", header, .{ .x = value.rect.x, .y = value.rect.y }, null);
            try appendRectStyle(allocator, out, value.rect);
            if (value.fill) |fill| try appendFormat(allocator, out, "background:{s};", .{color(fill)});
            if (value.stroke) |stroke| try appendFormat(allocator, out, "border:{d:.6}pt solid {s};", .{ normalized(value.line_width), color(stroke) });
            try appendFormat(allocator, out, "border-radius:{d:.6}pt\"></div>", .{normalized(value.radius)});
        },
        .stroke_line => |value| {
            const dx = value.end.x - value.start.x;
            const dy = value.end.y - value.start.y;
            const rotation = std.math.atan2(dy, dx);
            try appendItemStart(allocator, out, "div", "ss-line", header, value.start, rotation);
            try appendFormat(allocator, out, "left:{d:.6}pt;top:{d:.6}pt;width:{d:.6}pt;border-top-width:{d:.6}pt;border-top-color:{s};", .{
                normalized(value.start.x), normalized(value.start.y), normalized(@sqrt(dx * dx + dy * dy)), normalized(value.line_width), color(value.color),
            });
            if (value.dash_on > 0 and value.dash_off > 0) try out.appendSlice(allocator, "border-top-style:dashed;");
            try out.appendSlice(allocator, "\"></div>");
        },
        .text => |value| {
            try appendItemStart(allocator, out, "span", "ss-text", header, .{ .x = value.x, .y = value.y }, null);
            try appendFormat(allocator, out, "left:{d:.6}pt;top:{d:.6}pt;width:{d:.6}pt;height:{d:.6}pt\">", .{
                normalized(value.x), normalized(value.y), normalized(value.width), normalized(value.layout.logical_bounds.height),
            });
            for (value.layout.runs, 0..) |run, run_index| {
                _ = lineForRun(&value.layout, run_index) orelse return error.InvalidTextLayout;
                const font = ir.fonts.find(run.font_instance) orelse return error.MissingRenderFont;
                const ascent = value.font_size * font.ascent_ratio;
                const descent = value.font_size * font.descent_ratio;
                const run_top = run.baseline_y - ascent;
                try out.appendSlice(allocator, "<span class=\"ss-text-run\"");
                if (run.language.len != 0) {
                    try out.appendSlice(allocator, " lang=\"");
                    try appendAttribute(allocator, out, run.language);
                    try out.append(allocator, '"');
                }
                try appendFormat(allocator, out, " dir=\"{s}\" style=\"left:{d:.6}pt;top:{d:.6}pt;font-family:", .{
                    if (run.direction == .left_to_right) "ltr" else "rtl",
                    normalized(run.x),
                    normalized(run_top),
                });
                try out.append(allocator, '\'');
                try appendFontFamily(allocator, out, font.id);
                try out.append(allocator, '\'');
                try appendFormat(allocator, out, ";width:{d:.6}pt;height:{d:.6}pt;font-size:{d:.6}pt;font-weight:{d};font-style:{s};font-stretch:{s};line-height:{d:.6}pt;color:{s};", .{
                    normalized(run.advance),
                    normalized(ascent + descent),
                    normalized(value.font_size),
                    font.weight,
                    fontStyle(font.style),
                    fontStretch(font.stretch),
                    normalized(ascent + descent),
                    color(value.color),
                });
                try appendFontSettings(allocator, out, font);
                try out.appendSlice(allocator, "\">");
                const clusters = value.layout.clusters[run.cluster_range.start..run.cluster_range.end];
                if (clusters.len == 0) {
                    try appendText(allocator, out, value.layout.source_text[run.source.start..run.source.end]);
                } else {
                    const order = try allocator.alloc(usize, clusters.len);
                    defer allocator.free(order);
                    for (order, 0..) |*entry, index| entry.* = index;
                    std.mem.sort(usize, order, clusters, struct {
                        fn lessThan(values: []const render.TextCluster, lhs: usize, rhs: usize) bool {
                            return values[lhs].source.start < values[rhs].source.start;
                        }
                    }.lessThan);
                    for (order) |cluster_index| {
                        const cluster = clusters[cluster_index];
                        try appendFormat(allocator, out, "<span class=\"ss-text-cluster\" style=\"left:{d:.6}pt;width:{d:.6}pt\">", .{
                            normalized(cluster.x), normalized(cluster.advance_x),
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
            try appendItemStart(allocator, out, "img", "ss-image", header, .{ .x = value.rect.x, .y = value.rect.y }, null);
            try appendRectStyle(allocator, out, value.rect);
            try out.appendSlice(allocator, "\" alt=\"\" src=\"");
            try appendAttribute(allocator, out, path);
            try out.appendSlice(allocator, "\">");
        },
        .svg => |value| {
            const path = assets.path(.svg, value.resource) orelse return error.MissingHtmlResource;
            if (value.tint) |tint| {
                try appendItemStart(allocator, out, "span", "ss-image", header, .{ .x = value.rect.x, .y = value.rect.y }, null);
                try appendRectStyle(allocator, out, value.rect);
                try appendFormat(allocator, out, "background:{s};mask:url('", .{color(tint)});
                try appendCssUrl(allocator, out, path);
                try out.appendSlice(allocator, "') center/100% 100% no-repeat\"></span>");
            } else {
                try appendItemStart(allocator, out, "img", "ss-image", header, .{ .x = value.rect.x, .y = value.rect.y }, null);
                try appendRectStyle(allocator, out, value.rect);
                try out.appendSlice(allocator, "\" alt=\"\" src=\"");
                try appendAttribute(allocator, out, path);
                try out.appendSlice(allocator, "\">");
            }
        },
        .math => |value| {
            const tree = ir.math.find(value.tree) orelse return error.InvalidMathTree;
            if (tree.input_kind == .raw) return error.UnsupportedMathSyntax;
            try appendItemStart(allocator, out, "span", "ss-math", header, .{ .x = value.rect.x, .y = value.rect.y }, null);
            try appendRectStyle(allocator, out, value.rect);
            try appendFormat(allocator, out, "font-size:{d:.6}pt\"><math xmlns=\"http://www.w3.org/1998/Math/MathML\" display=\"block\">", .{
                normalized(@max(value.rect.height * 0.65, 1)),
            });
            try appendMathNode(allocator, out, tree, tree.root, 0);
            try out.appendSlice(allocator, "</math></span>");
        },
        .pdf_page => |value| {
            const path = assets.path(.pdf, value.resource) orelse return error.MissingHtmlResource;
            try appendItemStart(allocator, out, "div", "ss-pdf", header, .{ .x = value.rect.x, .y = value.rect.y }, null);
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

fn appendItemStart(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    tag: []const u8,
    class: []const u8,
    header: render.ItemHeader,
    origin: render.Point,
    local_rotation: ?f64,
) !void {
    try appendFormat(allocator, out, "<{s} class=\"ss-item {s}\" data-ss-item-id=\"{d}\"", .{ tag, class, header.item_id });
    if (header.node_id) |node_id| try appendFormat(allocator, out, " data-ss-node-id=\"{d}\"", .{node_id});
    if (header.semantic_id) |semantic_id| try appendFormat(allocator, out, " data-ss-semantic-id=\"{d}\"", .{semantic_id});
    try out.appendSlice(allocator, " aria-hidden=\"true\"");
    try appendFormat(allocator, out, " style=\"z-index:{d};opacity:{d:.6};mix-blend-mode:{s};", .{
        header.paint_index,
        normalized(header.opacity),
        @tagName(header.blend_mode),
    });
    try appendItemTransform(allocator, out, header.transform, origin, local_rotation);
    if (header.clip) |clip| switch (clip) {
        .rect => |rect| try appendFormat(allocator, out, "clip-path:polygon({d:.6}pt {d:.6}pt,{d:.6}pt {d:.6}pt,{d:.6}pt {d:.6}pt,{d:.6}pt {d:.6}pt);", .{
            normalized(rect.x - origin.x),
            normalized(rect.y - origin.y),
            normalized(rect.x + rect.width - origin.x),
            normalized(rect.y - origin.y),
            normalized(rect.x + rect.width - origin.x),
            normalized(rect.y + rect.height - origin.y),
            normalized(rect.x - origin.x),
            normalized(rect.y + rect.height - origin.y),
        }),
    };
}

fn appendItemTransform(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    transform: render.Transform,
    origin: render.Point,
    local_rotation: ?f64,
) !void {
    const translated_x = transform.xx * origin.x + transform.xy * origin.y + transform.x0 - origin.x;
    const translated_y = transform.yx * origin.x + transform.yy * origin.y + transform.y0 - origin.y;
    const transformed = translated_x != 0 or translated_y != 0 or transform.xx != 1 or transform.yx != 0 or transform.xy != 0 or transform.yy != 1;
    if (!transformed and local_rotation == null) return;
    try appendFormat(allocator, out, "transform:translate({d:.9}pt,{d:.9}pt) matrix({d:.12},{d:.12},{d:.12},{d:.12},0,0)", .{
        normalized(translated_x),
        normalized(translated_y),
        normalized(transform.xx),
        normalized(transform.yx),
        normalized(transform.xy),
        normalized(transform.yy),
    });
    if (local_rotation) |rotation| try appendFormat(allocator, out, " rotate({d:.12}rad)", .{normalized(rotation)});
    try out.append(allocator, ';');
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

fn appendFontFamily(allocator: std.mem.Allocator, out: *std.ArrayList(u8), id: render.FontInstanceId) !void {
    try out.appendSlice(allocator, "ss-font-");
    const hex = std.fmt.bytesToHex(id, .lower);
    try out.appendSlice(allocator, &hex);
}

fn appendFontSettings(allocator: std.mem.Allocator, out: *std.ArrayList(u8), font: *const render.FontInstance) !void {
    if (font.variations.len != 0) {
        try out.appendSlice(allocator, "font-variation-settings:");
        for (font.variations, 0..) |variation, index| {
            if (index != 0) try out.append(allocator, ',');
            try appendFormat(allocator, out, "'{s}' {d:.9}", .{ &variation.tag, normalized(variation.value) });
        }
        try out.append(allocator, ';');
    }
    if (font.features.len != 0) {
        try out.appendSlice(allocator, "font-feature-settings:");
        for (font.features, 0..) |feature, index| {
            if (index != 0) try out.append(allocator, ',');
            try appendFormat(allocator, out, "'{s}' {d}", .{ &feature.tag, feature.value });
        }
        try out.append(allocator, ';');
    }
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
