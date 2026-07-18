const std = @import("std");
const core = @import("core");
const render = @import("render");
const resources = @import("resources.zig");

const document_css =
    \\:root { color-scheme: light dark; --ss-canvas: #e8edf3; }
    \\* { box-sizing: border-box; }
    \\html, body { margin: 0; width: 100%; height: 100%; overflow: hidden; background: var(--ss-canvas); }
    \\.ss-document { position: fixed; inset: 0; overflow: hidden; }
    \\.ss-document > .ss-page { display: none; position: absolute; left: 50%; top: 50%; transform: translate(-50%, -50%) scale(var(--ss-page-scale, 1)); transform-origin: center; }
    \\.ss-document > .ss-page[data-ss-active="true"] { display: block; }
    \\.ss-runtime-error { position: fixed; left: 50%; bottom: 16px; z-index: 2147483647; max-width: min(720px, calc(100% - 32px)); transform: translateX(-50%); padding: 10px 14px; border: 1px solid #b94838; border-radius: 6px; color: #fff; background: #7f281f; box-shadow: 0 4px 18px rgb(0 0 0 / 25%); font: 13px/1.4 system-ui, sans-serif; }
;

pub const fragment_css =
    \\* { box-sizing: border-box; }
    \\.ss-page { position: relative; flex: none; overflow: hidden; isolation: isolate; background: white; box-shadow: 0 2pt 12pt rgb(15 23 42 / 18%); }
    \\.ss-item { position: absolute; transform-origin: 0 0; }
    \\.ss-semantic-layer { position: absolute; width: 1px; height: 1px; padding: 0; margin: -1px; overflow: hidden; clip: rect(0, 0, 0, 0); clip-path: inset(50%); white-space: nowrap; border: 0; }
    \\.ss-text { white-space: pre; }
    \\.ss-text-run { position: absolute; white-space: pre; font-kerning: none; font-synthesis: none; }
    \\.ss-text-cluster { position: absolute; top: 0; white-space: pre; }
    \\.ss-line { display: block; }
    \\.ss-image { display: block; object-fit: fill; }
    \\.ss-math { display: block; }
    \\.ss-math-text { position: absolute; white-space: pre; }
    \\.ss-math-rule { position: absolute; }
    \\.ss-mathml { position: absolute; width: 1px; height: 1px; padding: 0; margin: -1px; overflow: hidden; clip: rect(0, 0, 0, 0); clip-path: inset(50%); white-space: nowrap; border: 0; }
    \\.ss-pdf { overflow: hidden; }
    \\.ss-pdf > canvas, .ss-pdf-layer { position: absolute; inset: 0; width: 100%; height: 100%; }
    \\.ss-pdf > canvas { display: block; }
    \\.ss-pdf-layer { overflow: hidden; }
    \\.ss-pdf-layer-content { position: absolute; left: 0; top: 0; transform-origin: 0 0; }
    \\.ss-pdf .textLayer, .ss-pdf .annotationLayer { position: absolute; inset: 0; width: 100%; height: 100%; transform-origin: 0 0; }
    \\.ss-pdf .textLayer { overflow: visible; line-height: 1; opacity: 1; text-align: initial; text-size-adjust: none; forced-color-adjust: none; user-select: text; }
    \\.ss-pdf .textLayer :is(span, br) { position: absolute; color: transparent; white-space: pre; cursor: text; transform-origin: 0 0; }
    \\.ss-pdf .textLayer > :not(.markedContent), .ss-pdf .textLayer .markedContent span:not(.markedContent) { z-index: 1; }
    \\.ss-pdf .textLayer span.markedContent { top: 0; height: 0; }
    \\.ss-pdf .textLayer span[role="img"] { cursor: default; user-select: none; }
    \\.ss-pdf .ss-pdf-annotations, .ss-pdf .annotationLayer { pointer-events: none; }
    \\.ss-pdf .annotationLayer section { position: absolute; box-sizing: border-box; pointer-events: auto; transform-origin: 0 0; }
    \\.ss-pdf .annotationLayer .linkAnnotation > a { position: absolute; inset: 0; width: 100%; height: 100%; }
    \\.ss-pdf [data-main-rotation="90"] { transform: rotate(90deg) translateY(-100%); }
    \\.ss-pdf [data-main-rotation="180"] { transform: rotate(180deg) translate(-100%, -100%); }
    \\.ss-pdf [data-main-rotation="270"] { transform: rotate(270deg) translateX(-100%); }
    \\.ss-link { position: absolute; display: block; }
    \\.ss-destination { position: absolute; width: 0; height: 0; }
;

const print_css =
    \\html[data-ss-print-layout], html[data-ss-print-layout] body { width: auto; height: auto; overflow: visible; background: transparent; }
    \\html[data-ss-print-layout] .ss-document { position: static; overflow: visible; }
    \\html[data-ss-print-layout] .ss-document > .ss-page { display: block; position: relative; left: auto; top: auto; transform: none; box-shadow: none; break-after: page; }
    \\@media print { html, body { width: auto; height: auto; overflow: visible; background: transparent; } .ss-document { position: static; overflow: visible; } .ss-document > .ss-page { display: block; position: relative; left: auto; top: auto; transform: none; box-shadow: none; break-after: page; } }
;

pub fn styleSheet(allocator: std.mem.Allocator, ir: *const render.Ir, assets: resources.References, standalone: bool) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    if (standalone) try out.appendSlice(allocator, document_css);
    try out.appendSlice(allocator, fragment_css);
    if (standalone) try out.appendSlice(allocator, print_css);
    for (ir.fonts.instances) |font| {
        const source = assets.fontSource(font.resource, font.face_index) orelse return error.MissingHtmlResource;
        try out.appendSlice(allocator, "@font-face { font-family: '");
        try appendFontFamily(allocator, &out, font.id);
        try out.appendSlice(allocator, "'; src: ");
        switch (source) {
            .resource => |path| {
                try out.appendSlice(allocator, "url('");
                try appendCssUrl(allocator, &out, path);
                try out.appendSlice(allocator, "')");
            },
            .local => {
                try out.appendSlice(allocator, "local(");
                try appendCssString(allocator, &out, font.family);
                try out.append(allocator, ')');
            },
        }
        try appendFormat(allocator, &out, "; font-weight:{d}; font-style:{s}; font-stretch:{s}; font-display:block; }}\n", .{
            font.weight,
            fontStyle(font.style),
            fontStretch(font.stretch),
        });
    }
    return try out.toOwnedSlice(allocator);
}

pub const PdfRuntime = struct {
    import_map: []const u8,
    renderer_module: []const u8,
    pdfjs_module: []const u8,
    worker_module: []const u8,
    license: []const u8,
};

pub const Runtime = struct {
    resource_module: []const u8,
    navigation_module: []const u8,
    text_module: []const u8,
    pdf: ?PdfRuntime,
};

pub fn generate(
    allocator: std.mem.Allocator,
    ir: *const render.Ir,
    assets: resources.References,
    style_sheet_url: []const u8,
    runtime: Runtime,
) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\">" ++
        "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">" ++
        "<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; img-src data: blob:; style-src 'unsafe-inline' data: blob:; script-src 'unsafe-inline' data:; worker-src data: blob:; connect-src data: blob:; font-src data: blob:\">" ++
        "<title>ss document</title><style>html:not([data-ss-ready]):not([data-ss-error]) body{visibility:hidden}</style>" ++
        "<script type=\"text/plain\" data-ss-stylesheet>");
    try appendText(allocator, &out, style_sheet_url);
    try out.appendSlice(allocator, "</script></head><body>");
    const content = try fragment(allocator, ir, assets);
    defer allocator.free(content);
    try out.appendSlice(allocator, content);
    try appendEmbeddedResources(allocator, &out, assets);
    if (runtime.pdf) |pdf| {
        try out.appendSlice(allocator, "<script type=\"text/plain\" data-ss-third-party-license=\"pdf.js\">");
        try appendText(allocator, &out, pdf.license);
        try out.appendSlice(allocator, "</script>");
        try appendPdfImportMap(allocator, &out, pdf);
    }
    try out.appendSlice(allocator, "<script type=\"module\">let resourceStore=null,pdfRuntime=null,pdfController=null;const reportError=error=>{const message=error instanceof Error?error.message:String(error);document.documentElement.dataset.ssError=message;let alert=document.querySelector('.ss-runtime-error');if(!alert){alert=document.createElement('div');alert.className='ss-runtime-error';alert.setAttribute('role','alert');document.body.append(alert)}alert.textContent=message;console.error(error)};try{const navigation=await import(\"");
    try out.appendSlice(allocator, runtime.navigation_module);
    try out.appendSlice(allocator, "\");const pager=navigation.start(document);const resources=await import(\"");
    try out.appendSlice(allocator, runtime.resource_module);
    try out.appendSlice(allocator, "\");resourceStore=await resources.prepareDocumentResources(document);const text=await import(\"");
    try out.appendSlice(allocator, runtime.text_module);
    try out.appendSlice(allocator, "\");await text.alignTextBaselines(document);addEventListener(\"beforeunload\",()=>{void pdfRuntime?.disposePdfRuntime();resourceStore?.dispose()},{once:true});");
    if (runtime.pdf) |pdf| {
        try out.appendSlice(allocator, "const renderer=await import(\"");
        try out.appendSlice(allocator, pdf.renderer_module);
        try out.appendSlice(allocator, "\");pdfRuntime=renderer;pdfController=await renderer.renderPdfPages(document,()=>import(\"");
        try out.appendSlice(allocator, pdf.pdfjs_module);
        try out.appendSlice(allocator, "\"),\"");
        try out.appendSlice(allocator, pdf.worker_module);
        try out.appendSlice(allocator, "\",{resolveSource:resourceStore.resolve,onError:reportError});");
    }
    try out.appendSlice(allocator, "const prepareForPrint=()=>pager.prepareForPrint(()=>pdfController?.renderAll());const finishPrint=()=>{pager.finishPrint();pdfController?.restoreAfterPrint()};const nativePrint=window.print.bind(window);const printDocument=async()=>{await prepareForPrint();try{nativePrint()}finally{finishPrint()}};const requestPrint=()=>{void printDocument().catch(reportError)};pager.setPrintHandler(requestPrint);window.print=requestPrint;globalThis.ssDocument=Object.freeze({prepareForPrint,finishPrint,print:printDocument});pager.refresh();document.documentElement.dataset.ssReady=\"true\"}catch(error){void pdfRuntime?.disposePdfRuntime();resourceStore?.dispose();if(!document.documentElement.dataset.ssError)reportError(error);throw error}</script>");
    try out.appendSlice(allocator, "</body></html>\n");
    return try out.toOwnedSlice(allocator);
}

fn appendPdfImportMap(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    pdf: PdfRuntime,
) !void {
    try out.appendSlice(allocator, "<script type=\"importmap\">");
    try out.appendSlice(allocator, pdf.import_map);
    try out.appendSlice(allocator, "</script>");
}

fn appendEmbeddedResources(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    references: resources.References,
) !void {
    if (!references.isEmbedded()) return;
    for (references.set.assets) |asset| {
        const data = asset.embedded_data orelse continue;
        const reference = asset.embedded_reference orelse return error.MissingHtmlResource;
        try out.appendSlice(allocator, "<script type=\"application/octet-stream\" data-ss-resource=\"");
        try appendAttribute(allocator, out, reference);
        try out.appendSlice(allocator, "\" data-media-type=\"");
        try appendAttribute(allocator, out, asset.media_type);
        try out.appendSlice(allocator, "\">");
        try out.appendSlice(allocator, data);
        try out.appendSlice(allocator, "</script>");
    }
}

pub fn fragment(allocator: std.mem.Allocator, ir: *const render.Ir, assets: resources.References) ![]u8 {
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
    assets: resources.References,
) !void {
    try appendFormat(allocator, out, "<section class=\"ss-page\" data-ss-page-id=\"{d}\" data-ss-page-index=\"{d}\" data-ss-active=\"{s}\" aria-hidden=\"{s}\" aria-label=\"", .{
        page.page_id,                             page.index + 1,
        if (page.index == 0) "true" else "false", if (page.index == 0) "false" else "true",
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
        try appendSemanticNode(allocator, out, ir, semantic_id, 0);
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
    ir: *const render.Ir,
    semantic_id: render.SemanticId,
    depth: usize,
) !void {
    const tree = &ir.semantics;
    if (depth > tree.nodes.len) return error.InvalidSemantics;
    const semantic = tree.find(semantic_id) orelse return error.InvalidSemantics;
    const math_tree = if (semantic.role == .math)
        ir.math.find(semantic.math_tree orelse return error.InvalidSemantics) orelse return error.InvalidSemantics
    else
        null;
    const raw_math = if (math_tree) |value| value.input_kind == .raw else false;
    const tag = if (raw_math) "span" else semanticTag(semantic.*);
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
        if (!raw_math) {
            try out.appendSlice(allocator, " aria-label=\"");
            try appendAttribute(allocator, out, alt);
            try out.append(allocator, '"');
        }
    }
    if (semantic.role == .math) {
        try out.appendSlice(allocator, " class=\"ss-mathml\"");
        if (raw_math) {
            try out.appendSlice(allocator, " role=\"math\" aria-label=\"");
            try appendAttribute(allocator, out, semantic.alt_text orelse math_tree.?.source);
            try out.append(allocator, '"');
        } else {
            try out.appendSlice(allocator, " xmlns=\"http://www.w3.org/1998/Math/MathML\"");
            try appendFormat(allocator, out, " display=\"{s}\"", .{if (math_tree.?.input_kind == .@"inline") "inline" else "block"});
        }
    }
    try out.append(allocator, '>');
    if (semantic.role == .code) try out.appendSlice(allocator, "<code>");
    if (semantic.role == .math and !raw_math) {
        try appendMathNode(allocator, out, math_tree.?, math_tree.?.root, 0);
    } else if (semantic.text) |value| try appendText(allocator, out, value);
    for (semantic.children) |child| try appendSemanticNode(allocator, out, ir, child, depth + 1);
    if (semantic.role == .code) try out.appendSlice(allocator, "</code>");
    try appendFormat(allocator, out, "</{s}>", .{tag});
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
        .math => "math",
        .text => "span",
        .group, .decoration => "div",
    };
}

fn appendItem(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    ir: *const render.Ir,
    item: render.Item,
    assets: resources.References,
) !void {
    const header = item.header();
    switch (item) {
        .fill_rect => |value| {
            try appendItemStart(allocator, out, "div", "ss-box", header, .{ .x = value.rect.x, .y = value.rect.y }, null, .{});
            try appendRectStyle(allocator, out, value.rect);
            try out.appendSlice(allocator, "background:");
            try appendColor(allocator, out, value.color);
            try out.appendSlice(allocator, "\"></div>");
        },
        .rounded_rect => |value| {
            const half_stroke = if (value.stroke != null) @max(value.line_width / 2, 0) else 0;
            const css_rect = render.Rect{
                .x = value.rect.x - half_stroke,
                .y = value.rect.y - half_stroke,
                .width = value.rect.width + half_stroke * 2,
                .height = value.rect.height + half_stroke * 2,
            };
            try appendItemStart(allocator, out, "div", "ss-box", header, .{ .x = css_rect.x, .y = css_rect.y }, null, .{});
            try appendRectStyle(allocator, out, css_rect);
            if (value.fill) |fill| {
                try out.appendSlice(allocator, "background:");
                try appendColor(allocator, out, fill);
                try out.append(allocator, ';');
            }
            if (value.stroke) |stroke| {
                try appendFormat(allocator, out, "border:{d:.6}pt solid ", .{normalized(value.line_width)});
                try appendColor(allocator, out, stroke);
                try out.append(allocator, ';');
            }
            try appendFormat(allocator, out, "border-radius:{d:.6}pt\"></div>", .{normalized(value.radius + half_stroke)});
        },
        .stroke_line => |value| {
            const dx = value.end.x - value.start.x;
            const dy = value.end.y - value.start.y;
            const rotation = std.math.atan2(dy, dx);
            try appendItemStart(allocator, out, "div", "ss-line", header, value.start, .{
                .rotation = rotation,
                .translate_y = -value.line_width / 2,
            }, .{});
            try appendFormat(allocator, out, "left:{d:.6}pt;top:{d:.6}pt;width:{d:.6}pt;height:{d:.6}pt;", .{
                normalized(value.start.x), normalized(value.start.y), normalized(@sqrt(dx * dx + dy * dy)), normalized(value.line_width),
            });
            if (value.dash_on > 0 and value.dash_off > 0) {
                try out.appendSlice(allocator, "background:repeating-linear-gradient(to right,");
                try appendColor(allocator, out, value.color);
                try out.appendSlice(allocator, " 0,");
                try appendColor(allocator, out, value.color);
                try appendFormat(allocator, out, " {d:.6}pt,transparent {d:.6}pt,transparent {d:.6}pt);", .{
                    normalized(value.dash_on),
                    normalized(value.dash_on),
                    normalized(value.dash_on + value.dash_off),
                });
            } else {
                try out.appendSlice(allocator, "background:");
                try appendColor(allocator, out, value.color);
                try out.append(allocator, ';');
            }
            try out.appendSlice(allocator, "\"></div>");
        },
        .text => |value| {
            try appendItemStart(allocator, out, "span", "ss-text", header, .{ .x = value.x, .y = value.y }, null, .{});
            try appendFormat(allocator, out, "left:{d:.6}pt;top:{d:.6}pt;width:{d:.6}pt;height:{d:.6}pt\">", .{
                normalized(value.x), normalized(value.y), normalized(value.width), normalized(value.layout.logical_bounds.height),
            });
            try appendTextRuns(allocator, out, ir, &value.layout, value.font_size, value.color);
            try out.appendSlice(allocator, "</span>");
        },
        .raster => |value| {
            const path = assets.reference(.raster, value.resource) orelse return error.MissingHtmlResource;
            try appendItemStart(allocator, out, "img", "ss-image", header, .{ .x = value.rect.x, .y = value.rect.y }, null, .{});
            try appendRectStyle(allocator, out, value.rect);
            try out.appendSlice(allocator, if (assets.isEmbedded()) "\" alt=\"\" data-ss-src=\"" else "\" alt=\"\" src=\"");
            try appendAttribute(allocator, out, path);
            try out.appendSlice(allocator, "\">");
        },
        .svg => |value| {
            const path = assets.reference(.svg, value.resource) orelse return error.MissingHtmlResource;
            if (value.tint) |tint| {
                try appendItemStart(allocator, out, "span", "ss-image", header, .{ .x = value.rect.x, .y = value.rect.y }, null, .{});
                try appendRectStyle(allocator, out, value.rect);
                try out.appendSlice(allocator, "background:");
                try appendColor(allocator, out, tint);
                try out.appendSlice(allocator, ";mask:url('");
                try appendCssUrl(allocator, out, path);
                try out.appendSlice(allocator, "') center/100% 100% no-repeat\"></span>");
            } else {
                try appendItemStart(allocator, out, "img", "ss-image", header, .{ .x = value.rect.x, .y = value.rect.y }, null, .{});
                try appendRectStyle(allocator, out, value.rect);
                try out.appendSlice(allocator, if (assets.isEmbedded()) "\" alt=\"\" data-ss-src=\"" else "\" alt=\"\" src=\"");
                try appendAttribute(allocator, out, path);
                try out.appendSlice(allocator, "\">");
            }
        },
        .math => |value| {
            const tree = ir.math.find(value.tree) orelse return error.InvalidMathTree;
            switch (value.content) {
                .structured => |structured| {
                    if (tree.input_kind == .raw) return error.InvalidMathTree;
                    const layout = structured.layout;
                    try appendItemStart(allocator, out, "span", "ss-math", header, .{ .x = value.rect.x, .y = value.rect.y }, null, .{});
                    try appendRectStyle(allocator, out, value.rect);
                    try out.appendSlice(allocator, "\">");
                    for (layout.elements) |element| switch (element) {
                        .text => |text| {
                            try appendFormat(allocator, out, "<span class=\"ss-math-text\" style=\"left:{d:.6}pt;top:{d:.6}pt;width:{d:.6}pt;height:{d:.6}pt\">", .{
                                normalized(text.x),
                                normalized(text.y),
                                normalized(text.layout.logical_bounds.width),
                                normalized(text.layout.logical_bounds.height),
                            });
                            try appendTextRuns(allocator, out, ir, &text.layout, text.font_size, structured.color);
                            try out.appendSlice(allocator, "</span>");
                        },
                        .rule => |rule| {
                            try appendFormat(allocator, out, "<span class=\"ss-math-rule\" style=\"left:{d:.6}pt;top:{d:.6}pt;width:{d:.6}pt;height:{d:.6}pt;background:", .{
                                normalized(rule.rect.x),
                                normalized(rule.rect.y),
                                normalized(rule.rect.width),
                                normalized(rule.rect.height),
                            });
                            try appendColor(allocator, out, structured.color);
                            try out.appendSlice(allocator, "\"></span>");
                        },
                    };
                    try out.appendSlice(allocator, "</span>");
                },
                .raw_pdf => |raw| {
                    if (tree.input_kind != .raw) return error.InvalidMathTree;
                    const path = assets.reference(.math_pdf, raw.resource) orelse return error.MissingHtmlResource;
                    const resource = ir.resources.find(raw.resource) orelse return error.MissingHtmlResource;
                    const metadata = switch (resource.metadata) {
                        .math_pdf => |metadata| metadata,
                        else => return error.MissingHtmlResource,
                    };
                    try appendPdfViewer(allocator, out, header, value.rect, "ss-math ss-pdf", path, raw.page_index, raw.box, &metadata, false);
                },
            }
        },
        .pdf_page => |value| {
            const path = assets.reference(.pdf, value.resource) orelse return error.MissingHtmlResource;
            const resource = ir.resources.find(value.resource) orelse return error.MissingHtmlResource;
            const metadata = switch (resource.metadata) {
                .pdf => |metadata| metadata,
                else => return error.MissingHtmlResource,
            };
            try appendPdfViewer(allocator, out, header, value.rect, "ss-pdf", path, value.page_index, value.box, &metadata, value.copy_annotations);
        },
    }
}

fn appendPdfViewer(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    header: render.ItemHeader,
    rect: render.Rect,
    class: []const u8,
    path: []const u8,
    page_index: usize,
    box_kind: core.render_policy.PdfPageBox,
    metadata: *const render.PdfResourceMetadata,
    copy_annotations: bool,
) !void {
    if (page_index >= metadata.pages.len) return error.MissingHtmlResource;
    const page = &metadata.pages[page_index];
    const box = page.box(box_kind);
    try appendItemStart(allocator, out, "div", class, header, .{ .x = rect.x, .y = rect.y }, null, .{
        .hide_from_accessibility = !copy_annotations,
    });
    try appendRectStyle(allocator, out, rect);
    try out.appendSlice(allocator, "\" data-pdf-src=\"");
    try appendAttribute(allocator, out, path);
    try appendFormat(allocator, out, "\" data-page=\"{d}\" data-box=\"{s}\" data-view-box=\"{d:.9},{d:.9},{d:.9},{d:.9}\" data-rotation=\"{d}\" data-canvas-background=\"transparent\" data-copy-annotations=\"{s}\"><div class=\"ss-pdf-layer ss-pdf-text\" aria-hidden=\"true\"></div><div class=\"ss-pdf-layer ss-pdf-annotations\"></div></div>", .{
        page_index + 1,
        @tagName(box_kind),
        normalized(box.left),
        normalized(box.bottom),
        normalized(box.right),
        normalized(box.top),
        page.rotation,
        if (copy_annotations) "true" else "false",
    });
}

fn appendTextRuns(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    ir: *const render.Ir,
    layout: *const render.TextLayout,
    font_size: f64,
    text_color: core.render_policy.Color,
) !void {
    for (layout.runs, 0..) |run, run_index| {
        _ = lineForRun(layout, run_index) orelse return error.InvalidTextLayout;
        const font = ir.fonts.find(run.font_instance) orelse return error.MissingRenderFont;
        const ascent = font_size * font.ascent_ratio;
        const descent = font_size * font.descent_ratio;
        const run_top = run.baseline_y - ascent;
        try appendFormat(allocator, out, "<span class=\"ss-text-run\" data-ss-baseline-y=\"{d:.6}\"", .{normalized(run.baseline_y)});
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
        try out.appendSlice(allocator, "',");
        try appendCssString(allocator, out, font.family);
        try out.appendSlice(allocator, ",sans-serif");
        try appendFormat(allocator, out, ";width:{d:.6}pt;height:{d:.6}pt;font-size:{d:.6}pt;font-weight:{d};font-style:{s};font-stretch:{s};line-height:{d:.6}pt;color:", .{
            normalized(run.advance),
            normalized(ascent + descent),
            normalized(font_size),
            font.weight,
            fontStyle(font.style),
            fontStretch(font.stretch),
            normalized(ascent + descent),
        });
        try appendColor(allocator, out, text_color);
        try out.append(allocator, ';');
        try appendFontSettings(allocator, out, font);
        try out.appendSlice(allocator, "\">");
        const clusters = layout.clusters[run.cluster_range.start..run.cluster_range.end];
        if (clusters.len == 0) {
            try appendText(allocator, out, layout.source_text[run.source.start..run.source.end]);
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
                try appendText(allocator, out, layout.source_text[cluster.source.start..cluster.source.end]);
                try out.appendSlice(allocator, "</span>");
            }
        }
        try out.appendSlice(allocator, "</span>");
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

const ItemStartOptions = struct {
    hide_from_accessibility: bool = true,
};

fn appendItemStart(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    tag: []const u8,
    class: []const u8,
    header: render.ItemHeader,
    origin: render.Point,
    local_transform: ?LocalTransform,
    options: ItemStartOptions,
) !void {
    try appendFormat(allocator, out, "<{s} class=\"ss-item {s}\" data-ss-item-id=\"{d}\"", .{ tag, class, header.item_id });
    if (header.node_id) |node_id| try appendFormat(allocator, out, " data-ss-node-id=\"{d}\"", .{node_id});
    if (header.semantic_id) |semantic_id| try appendFormat(allocator, out, " data-ss-semantic-id=\"{d}\"", .{semantic_id});
    if (options.hide_from_accessibility) try out.appendSlice(allocator, " aria-hidden=\"true\"");
    try appendFormat(allocator, out, " style=\"z-index:{d};opacity:{d:.6};mix-blend-mode:{s};", .{
        header.paint_index,
        normalized(header.opacity),
        @tagName(header.blend_mode),
    });
    try appendItemTransform(allocator, out, header.transform, origin, local_transform);
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

const LocalTransform = struct {
    rotation: f64 = 0,
    translate_y: f64 = 0,
};

fn appendItemTransform(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    transform: render.Transform,
    origin: render.Point,
    local_transform: ?LocalTransform,
) !void {
    const translated_x = transform.xx * origin.x + transform.xy * origin.y + transform.x0 - origin.x;
    const translated_y = transform.yx * origin.x + transform.yy * origin.y + transform.y0 - origin.y;
    const transformed = translated_x != 0 or translated_y != 0 or transform.xx != 1 or transform.yx != 0 or transform.xy != 0 or transform.yy != 1;
    if (!transformed and local_transform == null) return;
    try appendFormat(allocator, out, "transform:translate({d:.9}pt,{d:.9}pt) matrix({d:.12},{d:.12},{d:.12},{d:.12},0,0)", .{
        normalized(translated_x),
        normalized(translated_y),
        normalized(transform.xx),
        normalized(transform.yx),
        normalized(transform.xy),
        normalized(transform.yy),
    });
    if (local_transform) |local| {
        try appendFormat(allocator, out, " rotate({d:.12}rad) translate(0,{d:.9}pt)", .{
            normalized(local.rotation),
            normalized(local.translate_y),
        });
    }
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

fn appendColor(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: anytype) !void {
    try appendFormat(allocator, out, "rgb({d:.6}% {d:.6}% {d:.6}%)", .{
        @as(f64, value.r) * 100, @as(f64, value.g) * 100, @as(f64, value.b) * 100,
    });
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
